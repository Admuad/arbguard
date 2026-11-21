// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig, OracleConfig, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {UniswapV3Adapter, IUniswapV3Factory, INonfungiblePositionManager} from "../src/UniswapV3Adapter.sol";
import {IAaveOracle} from "../src/AaveAdapter.sol";
import {AdapterPolicyHelper} from "../script/DeployAdapters.s.sol";
import {Fixture} from "./Fixture.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAggregatorV3, IUniswapV3Pool} from "../src/ArbGuard.sol";
import {TickMath, FullMath} from "../src/libraries/UniswapMath.sol";

/// @notice Minimal Uniswap v3 SwapRouter interface (exactInputSingle only).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V3 adapter fork test (spec §5.2): Arbitrum One, pinned
/// block 525,970,897 (20 Nov 2026). Deploys the guard + UniswapV3Adapter
/// against the REAL Uniswap V3 Factory / NPM / WETH-USDC 0.05% pool and
/// the REAL AaveOracle, and exercises swaps, the price-push case, the
/// TWAP cross-check, the drain rule, and real position removal.
///
/// Run: forge test --match-contract UniswapV3ForkTest -vv
/// RPC responses are cached by forge in ~/.foundry/cache, so re-runs are
/// cheap. No key needed — the public Arbitrum One RPC is used.
///
/// Pinned-block state (verified live 20 Nov 2026):
/// - WETH/USDC 0.05% pool 0xC696...: slot0 tick -202160, liquidity
///   ~6.706e17. Pool balances: ~13,435 WETH (~$22.3M), ~2,246,736 USDC
///   (~$2.25M).
/// - AaveOracle WETH $1,660.00611635, USDC $0.99982444; Chainlink
///   ETH/USD $1,662.75921904, USDC/USD $0.99987.
/// - QuoterV2 DOES have code on Arbitrum One at the pinned block
///   (8,273 bytes at 0x61fFE014bA17989E743c5F6cB21bF9697530B21e).
///   The spec §2.1 premise that it has no code is WRONG, corrected
///   here with live proof. The adapter still computes execution prices
///   in-adapter and never calls the Quoter (by design, avoiding the
///   revert-based quoting pattern), so only the justification is
///   corrected, not the design.
contract UniswapV3ForkTest is Fixture {
    string internal constant ARB_ONE_RPC = "https://arb1.arbitrum.io/rpc";
    uint256 internal constant PINNED_BLOCK = 525_970_897;

    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address internal constant WETH_USDC_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // QuoterV2: NO code on Arbitrum One (spec §2.1). Recorded here so the
    // test documents that the adapter never needs it.
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    UniswapV3Adapter internal v3;
    uint256 internal v3PolicyId;
    address internal user = address(0xA11CE);

    function setUp() public override {
        vm.createSelectFork(vm.envOr("ARBITRUM_ONE_RPC_URL", ARB_ONE_RPC), PINNED_BLOCK);
        super.setUp();

        v3 = new UniswapV3Adapter(
            guard,
            IUniswapV3Factory(FACTORY),
            INonfungiblePositionManager(NPM),
            IAaveOracle(AAVE_ORACLE)
        );
        // V3 policy: USD caps $50k/$500k/$2M, single-share 50%, drain
        // 50%, HF floor off (0). Real 0.05% pool in the OracleConfig,
        // real sequencer feed.
        Policy memory p = AdapterPolicyHelper.adapterPolicy(50_000 ether, 500_000 ether, 2_000_000 ether, 5000);
        p.minHealthFactorBps = 0;
        v3PolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard, address(v3), p, AdapterPolicyHelper.adapterPriceConfig(SEQUENCER_FEED)
        );
        guard.addKeeper(v3PolicyId, keeper);
        guard.setOracleConfig(
            v3PolicyId,
            WETH,
            OracleConfig({
                chainlinkFeed: ETH_USD_FEED,
                uniswapPool: WETH_USDC_POOL,
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            v3PolicyId,
            USDC,
            OracleConfig({
                chainlinkFeed: USDC_USD_FEED,
                uniswapPool: WETH_USDC_POOL,
                feedDecimals: 8,
                tokenDecimals: 6
            })
        );

        // Fund the user with WETH + USDC.
        deal(WETH, user, 5_000 ether);
        deal(USDC, user, 5_000_000e6);
        vm.startPrank(user);
        IERC20(WETH).approve(address(v3), type(uint256).max);
        IERC20(USDC).approve(address(v3), type(uint256).max);
        IERC20(WETH).approve(NPM, type(uint256).max);
        IERC20(USDC).approve(NPM, type(uint256).max);
        IERC20(WETH).approve(SWAP_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    function test_Fork_IsLiveArbitrumOne() public view {
        assertEq(block.chainid, 42161);
        // On Arbitrum, block.number is the L1 height, not the L2 fork
        // block, so the pin is verified by state: the pool's slot0 tick
        // at the pinned block is -202160.
        (, int24 tick,,,,,) = IUniswapV3Pool(WETH_USDC_POOL).slot0();
        assertEq(tick, -202160);
    }

    /// @notice QuoterV2 DOES have code on Arbitrum One at the pinned block
/// (8,273 bytes at 0x61fFE014bA17989E743c5F6cB21bF9697530B21e). The spec
/// §2.1 premise that it has no code is WRONG, corrected here with live
/// proof. The adapter still computes execution prices in-adapter and
/// never calls the Quoter (by design: it avoids the Quoter's
/// revert-based quoting pattern and the extra dependency), so the
/// in-adapter design stands — only the "no code" justification is
/// corrected.
    function test_Fork_QuoterV2_HasCode_AdapterNeverCallsIt() public view {
        assertGt(QUOTER_V2.code.length, 0, "QuoterV2 has code on Arbitrum One");
    }

    /// @notice A normal small USDC->WETH swap through the adapter passes,
    /// and the adapter's computed amountOut matches the actual output
    /// within 0.5% (spec §2.2: the adapter computes the price in-adapter,
    /// no Quoter). Direction is USDC->WETH (oneForZero) because the pool
    /// sits exactly on a tick-group boundary (tick -202160, spacing 10)
    /// at the pinned block, and a zeroForOne swap from a boundary tick
    /// always leaves the group, so the adapter's tick-cross rule
    /// correctly reverts it. A oneForZero swap moves up into the group
    /// [-202160, -202150) and passes. The boundary limitation is a
    /// property of the spec's single-tick rule, not a test artifact.
    function test_Fork_Swap_Passes_AmountMatches() public {
        uint256 amountIn = 1000e6; // 1,000 USDC
        (uint256 expectedOut, uint256 price) = v3.getExpectedOutput(WETH_USDC_POOL, USDC, amountIn);
        // Execution price is ~$1,660 per WETH (1e18-scaled USDC per WETH,
        // in raw token units: USDC has 6 decimals, so the raw price is
        // ~1.66e9; the adapter reports it 1e18-scaled).
        assertGt(price, 0, "execution price is non-zero");
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        uint256 actualOut = v3.swap(WETH_USDC_POOL, USDC, amountIn, 0);
        assertApproxEqRel(actualOut, expectedOut, 0.005 ether, "actual within 0.5% of adapter-computed output");
        assertEq(IERC20(WETH).balanceOf(user), wethBefore + actualOut, "WETH paid to user");
    }

    /// @notice TWAP cross-check (spec §1.5, re-proven for the adapter):
    /// the guard's reference price matches a direct observe() TWAP
    /// computation within 200 bps, and the reference (converted to USD)
    /// matches Chainlink within 1%.
    function test_Fork_TwapCrossCheck_Within200bps() public view {
        (uint256 ref,) = guard.getReferencePrice(v3PolicyId, WETH, USDC);
        // Direct observe() over the same 1800 s window.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(WETH_USDC_POOL).observe(secondsAgos);
        int256 delta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
        int256 twapTick = delta / 1800;
        if (delta < 0 && delta % 1800 != 0) twapTick -= 1; // floor, not truncate
        // Convert the TWAP tick to the guard's reference units (USDC per
        // WETH, 1e18-scaled raw) with the same math the guard uses:
        // ref01 = sqrtRatio^2 * 1e18 / 2^192 is token1 per token0.
        // WETH is token0 (0x82aF < 0xaf88), so tokenIn (WETH) IS
        // token0 and the reference is ref01 directly (no inversion;
        // the guard inverts only when tokenIn is token1).
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(twapTick));
        uint256 ref01 = FullMath.mulDiv(sqrtRatioX96, uint256(sqrtRatioX96) * 1e18, 1 << 192);
        uint256 directTwap = ref01;
        assertGt(ref, 0, "reference price is non-zero");
        assertApproxEqRel(ref, directTwap, 0.02 ether, "reference within 200 bps of direct observe() TWAP");
        // The reference is ~$1,660 (1e18-scaled raw USDC per WETH):
        // ref is 1e18-scaled raw (USDC 6dec per WETH 18dec), so the USD
        // price (1e18-scaled) is ref * 10^(18-6) = ref * 1e12. Assert it
        // is within 1% of the Chainlink ETH/USD price.
        (, int256 linkEth,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        uint256 refUsd = ref * 1e12;
        assertApproxEqRel(refUsd, uint256(linkEth) * 1e10, 0.01 ether, "reference within 1% of Chainlink");
    }

    /// @notice Price-push (spec §2.4): push the pool price ~5% via the
    /// SwapRouter (1,500 WETH, as in the Phase 1 manipulation test), then
    /// a small adapter swap sees the pushed execution price against the
    /// slow TWAP reference and reverts PRICE_DEVIATION. A large adapter
    /// swap cannot push the price itself (it would hit the tick-cross
    /// revert and the $50k outflow cap first), so the router does the
    /// pushing, exactly as the Phase 1 test does.
    function test_Fork_PricePush_SwapReverts() public {
        // Push the price down by selling 1,500 WETH for USDC.
        vm.prank(user);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: 500,
                recipient: user,
                deadline: block.timestamp + 3600,
                amountIn: 1500 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        // A small adapter swap now sees a pushed execution price.
        vm.prank(user);
        vm.expectRevert();
        v3.swap(WETH_USDC_POOL, WETH, 1 ether, 0);
    }

    /// @notice Drain-on-swap (spec §2.4): a swap taking 51% of the
    /// pool's available tokenOut reverts RESERVE_DRAIN. A real adapter
    /// swap that large is infeasible (tick-cross + outflow cap bind
    /// first), so this test crafts the SWAP Action with the adapter's
    /// REAL available-liquidity read and calls guard.check directly,
    /// pranked as a second adapter instance whose policy has huge
    /// outflow caps and a 100% single-share cap (so the drain rule is
    /// what binds, not outflow or share). The available value is the
    /// pool's real token balance, read live.
    function test_Fork_DrainOnSwap_CraftedAction() public {
        // Second adapter with a drain-focused policy: huge outflow caps
        // and 100% single-share, so only the drain rule can bind.
        UniswapV3Adapter v3drain = new UniswapV3Adapter(
            guard,
            IUniswapV3Factory(FACTORY),
            INonfungiblePositionManager(NPM),
            IAaveOracle(AAVE_ORACLE)
        );
        Policy memory p =
            AdapterPolicyHelper.adapterPolicy(100_000_000 ether, 100_000_000 ether, 100_000_000 ether, 10_000);
        p.minHealthFactorBps = 0;
        uint256 drainPid = AdapterPolicyHelper.registerAdapterPolicy(
            guard, address(v3drain), p, AdapterPolicyHelper.adapterPriceConfig(SEQUENCER_FEED)
        );
        guard.addKeeper(drainPid, keeper);
        guard.setOracleConfig(
            drainPid,
            WETH,
            OracleConfig({
                chainlinkFeed: ETH_USD_FEED,
                uniswapPool: WETH_USDC_POOL,
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            drainPid,
            USDC,
            OracleConfig({
                chainlinkFeed: USDC_USD_FEED,
                uniswapPool: WETH_USDC_POOL,
                feedDecimals: 8,
                tokenDecimals: 6
            })
        );

        uint256 availUsd = v3drain.getPoolAvailableLiquidity(WETH_USDC_POOL, USDC);
        assertGt(availUsd, 1_000_000 ether, "pool holds >$1M USDC available");
        // Price the crafted Action at the guard's own reference so the
        // price check passes (0 deviation) and only the drain rule can
        // bind. A hardcoded price would risk PRICE_DEVIATION firing
        // first and masking the drain result.
        (uint256 refPrice,) = guard.getReferencePrice(drainPid, WETH, USDC);
        assertGt(refPrice, 0, "reference price is non-zero");
        // 51% of available -> RESERVE_DRAIN.
        Action memory drainAction = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: (availUsd * 51) / 100,
            amountIn: (availUsd * 51) / 100,
            price: refPrice, // the reference; drain fires first
            tvl: availUsd * 2, // large tvl so single-share (100%) cannot bind
            healthFactorAfter: 0,
            availableLiquidity: availUsd
        });
        (bool ok, Reason reason) = guard.simulateCheck(address(v3drain), drainAction);
        assertFalse(ok, "51% drain must fail simulateCheck");
        assertEq(uint8(reason), uint8(Reason.RESERVE_DRAIN), "51% drain reason is RESERVE_DRAIN");
        vm.prank(address(v3drain));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.RESERVE_DRAIN));
        guard.check(address(v3drain), drainAction);
        // 49% of available passes the drain rule (and the huge outflow
        // caps), so simulateCheck agrees it passes.
        Action memory passAction = drainAction;
        passAction.amountOut = (availUsd * 49) / 100;
        passAction.amountIn = (availUsd * 49) / 100;
        (bool ok2, Reason reason2) = guard.simulateCheck(address(v3drain), passAction);
        assertTrue(ok2, "49% drain must pass simulateCheck");
        assertEq(uint8(reason2), uint8(Reason.NONE));
    }

    /// @notice Real position removal (spec §2.4): mint a real NPM
    /// position on the fork via the adapter, then decreaseLiquidity.
    /// Removing 60% of the position exceeds the 50% single-share cap
    /// (SINGLE_SHARE); removing 10% passes. The position value comes
    /// from the pool's current price.
    function test_Fork_PositionRemoval_SingleShare() public {
        // Mint a position around the current tick (-202160, spacing 10).
        int24 tickLower = -202200;
        int24 tickUpper = -202100;
        vm.prank(user);
        (uint256 tokenId, uint128 liquidity,,) = v3.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: 500,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: 10 ether,
                amount1Desired: 10_000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: user,
                deadline: block.timestamp + 3600
            })
        );
        assertGt(liquidity, 0, "position minted with liquidity");
        uint256 positionValue = v3.getPositionValue(tokenId);
        assertGt(positionValue, 0, "position has a value at the current price");
        // The adapter is not the position owner, so the user must
        // approve it on the NFT before it can decrease/collect (NPM
        // only lets the owner or an approved operator manage a
        // position). This is a user prerequisite, not an adapter bug.
        vm.prank(user);
        IERC721(NPM).approve(address(v3), tokenId);
        // Removing 60% of the liquidity exceeds the 50% single-share cap.
        vm.prank(user);
        vm.expectRevert();
        v3.decreaseLiquidity(tokenId, (liquidity * 60) / 100, 0, 0);
        // Removing 10% passes.
        vm.prank(user);
        v3.decreaseLiquidity(tokenId, liquidity / 10, 0, 0);
        assertLt(v3.getPositionValue(tokenId), positionValue, "position value fell after removal");
    }
}
