// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, OracleConfig} from "../src/ArbGuard.sol";
import {UniswapV3Adapter, AdapterError, AdapterNotConfigured, INonfungiblePositionManager, IUniswapV3Factory} from "../src/UniswapV3Adapter.sol";
import {IAaveOracle} from "../src/AaveAdapter.sol";
import {TickMath, SqrtPriceMath} from "../src/libraries/UniswapMath.sol";
import {AdapterPolicyHelper} from "../script/DeployAdapters.s.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockV3Pool, MockV3Factory, MockNPM, MockAaveOracle} from "./AdapterMocks.sol";

/// @notice Uniswap V3 adapter unit tests (spec §5.1) with mock V3 contracts.
/// The mock pool is a 1.0-price pool (sqrtPrice 2^96, tick 0, TWAP tick 0)
/// with a 0.05% fee; the mock feeds are $1.00 each, so the guard reference
/// price is 1.0 and a small swap at price ~1.0 passes the price rule.
contract UniswapV3AdapterTest is Fixture {
    MockV3Pool internal mockV3Pool;
    MockV3Factory internal mockFactory;
    MockNPM internal mockNpm;
    MockAaveOracle internal mockOracle;
    UniswapV3Adapter internal v3;
    uint256 internal v3PolicyId;

    uint24 internal constant FEE = 500; // 0.05%
    int24 internal constant SPACING = 10;

    function setUp() public override {
        super.setUp();
        mockV3Pool = new MockV3Pool(address(asset), address(token1), FEE, SPACING);
        // Mid-group tick (5 in group [0,10)) so a small zeroForOne swap
        // stays in the group, and deep liquidity so a 10-ether swap moves
        // the price by ~0.01% (~1 tick). A 900-ether swap still crosses.
        mockV3Pool.setSlot0(TickMath.getSqrtRatioAtTick(5), 5);
        mockV3Pool.setLiquidity(100_000 ether);
        mockFactory = new MockV3Factory();
        mockFactory.setPool(address(asset), address(token1), FEE, address(mockV3Pool));
        mockNpm = new MockNPM();
        // The mock NPM values positions at the same price as the pool.
        mockNpm.setPoolPrice(TickMath.getSqrtRatioAtTick(5), 5);
        mockOracle = new MockAaveOracle();
        mockOracle.setPrice(address(asset), 166_001_000_000); // $1,660.01
        mockOracle.setPrice(address(token1), 99_982_000); // $0.99982
        v3 = new UniswapV3Adapter(
            guard,
            IUniswapV3Factory(address(mockFactory)),
            INonfungiblePositionManager(address(mockNpm)),
            IAaveOracle(address(mockOracle))
        );

        // V3 policy via the helper: USD caps $50k/$500k/$2M, single-share
        // 50%, drain 50%, HF floor off (0). Oracle configs use the
        // fixture's $1.00 mock feeds and the fixture mock pool (TWAP 0).
        Policy memory p = AdapterPolicyHelper.adapterPolicy(50_000 ether, 500_000 ether, 2_000_000 ether, 5000);
        p.minHealthFactorBps = 0;
        v3PolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard, address(v3), p, AdapterPolicyHelper.adapterPriceConfig(address(0))
        );
        guard.addKeeper(v3PolicyId, keeper);
        guard.setOracleConfig(
            v3PolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(wethFeed),
                uniswapPool: address(mockV3Pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            v3PolicyId,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(usdcFeed),
                uniswapPool: address(mockV3Pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );

        // Fund the mock pool so swaps can pay out, and the mock NPM so
        // collect can pay out owed tokens (the real NPM holds the
        // position's tokens; the mock accrues owed without receiving them,
        // so it needs a balance to pay from).
        token1.mint(address(mockV3Pool), 10_000 ether);
        asset.mint(address(mockV3Pool), 10_000 ether);
        token1.mint(address(mockNpm), 10_000 ether);
        asset.mint(address(mockNpm), 10_000 ether);
        vm.startPrank(victim);
        asset.approve(address(v3), type(uint256).max);
        token1.approve(address(v3), type(uint256).max);
        vm.stopPrank();
    }

    function test_V3_ResolvePool_KnownTier() public view {
        assertEq(v3.resolvePool(address(asset), address(token1), FEE), address(mockV3Pool));
        // Argument order does not matter (factory sorts).
        assertEq(v3.resolvePool(address(token1), address(asset), FEE), address(mockV3Pool));
    }

    function test_V3_ResolvePool_UnknownTier_ReturnsZero() public view {
        assertEq(v3.resolvePool(address(asset), address(token1), 3000), address(0));
    }

    function test_V3_Swap_ZeroPool_Reverts() public {
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "pool address required"));
        v3.swap(address(0), address(asset), 10 ether, 0);
    }

    function test_V3_Swap_UnrecognisedPool_Reverts() public {
        MockV3Pool other = new MockV3Pool(address(asset), address(token1), FEE, SPACING);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterNotConfigured.selector, address(other)));
        v3.swap(address(other), address(asset), 10 ether, 0);
    }

    function test_V3_Swap_Passes_AndPaysUser() public {
        uint256 beforeIn = asset.balanceOf(victim);
        uint256 beforeOut = token1.balanceOf(victim);
        vm.prank(victim);
        uint256 amountOut = v3.swap(address(mockV3Pool), address(asset), 10 ether, 0);
        // The mock pool pays at 1.0 with no fee; the adapter's expected
        // output deducts the 0.05% fee, so the actual is within 0.5%.
        assertApproxEqRel(amountOut, 10 ether, 0.005 ether, "swap output within 0.5% of expected");
        assertEq(asset.balanceOf(victim), beforeIn - 10 ether, "tokenIn pulled from user");
        assertEq(token1.balanceOf(victim), beforeOut + amountOut, "tokenOut paid to user");
    }

    function test_V3_ExpectedOutput_MatchesMockSwap() public {
        (uint256 expectedOut, uint256 price) = v3.getExpectedOutput(address(mockV3Pool), address(asset), 10 ether);
        // Execution price ~1.0 (the pool is at 1.0, small swap, fee 0.05%).
        assertApproxEqRel(price, 1 ether, 0.01 ether, "execution price ~1.0");
        vm.prank(victim);
        uint256 actual = v3.swap(address(mockV3Pool), address(asset), 10 ether, 0);
        assertApproxEqRel(actual, expectedOut, 0.005 ether, "actual within 0.5% of expected");
    }

    function test_V3_TickCross_Reverts() public {
        // A swap large enough to push the price out of the current
        // tick-spacing group reverts (single-tick approximation, spec §2.2).
        // The mock pool holds 1,000 ether of liquidity; swapping 900 ether
        // of token0 moves the price far past the group boundary.
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "swap crosses tick"));
        v3.swap(address(mockV3Pool), address(asset), 900 ether, 0);
    }

    function test_V3_DecreaseLiquidity_NonOwner_Reverts() public {
        mockNpm.setPosition(1, address(attacker), address(asset), address(token1), FEE, -100, 100, 100 ether, 0, 0);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "caller does not own position"));
        v3.decreaseLiquidity(1, 10 ether, 0, 0);
    }

    function test_V3_DecreaseLiquidity_Passes_AndAccruesOwed() public {
        mockNpm.setPosition(1, victim, address(asset), address(token1), FEE, -100, 100, 100 ether, 0, 0);
        // Position value: 100 ether of liquidity at price ~1.0005, in
        // range, is ~$787 (mostly token0). Removing 10% removes ~$79,
        // under the $50k outflow cap and under the 50% single-share of
        // the position's value. The removed tokens accrue as owed at the
        // mock's real V3 amounts; collect pays exactly those amounts.
        vm.prank(victim);
        v3.decreaseLiquidity(1, 10 ether, 0, 0);
        uint256 before0 = asset.balanceOf(victim);
        uint256 before1 = token1.balanceOf(victim);
        vm.prank(victim);
        (uint256 collected0, uint256 collected1) = v3.collect(1, victim, type(uint128).max, type(uint128).max);
        assertGt(collected0, 0, "collected token0 is non-zero");
        assertGt(collected1, 0, "collected token1 is non-zero");
        assertEq(asset.balanceOf(victim), before0 + collected0, "token0 paid to user");
        assertEq(token1.balanceOf(victim), before1 + collected1, "token1 paid to user");
        // The collected amounts are the V3 amounts for 10% of the
        // position: ~0.047 ether token0 and ~0.052 ether token1.
        assertApproxEqRel(collected0, 0.047 ether, 0.05 ether, "collected token0 ~ 10% of position token0");
        assertApproxEqRel(collected1, 0.052 ether, 0.05 ether, "collected token1 ~ 10% of position token1");
    }

    function test_V3_DecreaseLiquidity_OverSingleShare_Reverts() public {
        mockNpm.setPosition(1, victim, address(asset), address(token1), FEE, -100, 100, 100 ether, 0, 0);
        // Removing 60 ether of liquidity is 60% of the position's value,
        // over the 50% single-share cap.
        vm.prank(victim);
        vm.expectRevert();
        v3.decreaseLiquidity(1, 60 ether, 0, 0);
    }

    function test_V3_OutOfRangePosition_WorthItsResidue() public {
        // Position entirely above the current tick (tick 5 < tickLower
        // 100): it holds only token0 residue. Its value is exactly the
        // USD value of that residue, computed independently here with the
        // same SqrtPriceMath. (An above-range position holds only the
        // expensive token, so it can be worth MORE than the same
        // liquidity in range — the in-range position holds a mix that
        // includes cheap token1 — so the assertion is the exact residue,
        // not a comparison between the two.)
        mockNpm.setPosition(2, victim, address(asset), address(token1), FEE, 100, 200, 100 ether, 0, 0);
        uint256 residue0 = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtRatioAtTick(100), TickMath.getSqrtRatioAtTick(200), 100 ether, false
        );
        assertEq(v3.getPositionValue(2), v3.getUsdValue(address(asset), residue0), "out-of-range = token0 residue");
        assertGt(residue0, 0, "residue is non-zero");
        // In-range position: both tokens, at the pool's current price.
        mockNpm.setPosition(3, victim, address(asset), address(token1), FEE, -100, 100, 100 ether, 0, 0);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(5);
        uint256 in0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtRatioAtTick(100), 100 ether, false);
        uint256 in1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(-100), sqrtP, 100 ether, false);
        uint256 expectedIn = v3.getUsdValue(address(asset), in0) + v3.getUsdValue(address(token1), in1);
        assertEq(v3.getPositionValue(3), expectedIn, "in-range = both tokens at current price");
    }

    function test_V3_MintPosition_OwnedByCaller_ExcessRefunded() public {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(asset),
            token1: address(token1),
            fee: FEE,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: victim,
            deadline: block.timestamp + 1 hours
        });
        vm.prank(victim);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v3.mintPosition(params);
        assertEq(mockNpm.ownerOf(tokenId), victim, "NFT minted to caller");
        assertGt(liquidity, 0);
        assertEq(amount0, 10 ether);
        assertEq(amount1, 10 ether);
        // The adapter holds no residue after the mint (excess refunded).
        assertEq(asset.balanceOf(address(v3)), 0);
        assertEq(token1.balanceOf(address(v3)), 0);
    }

    function test_V3_MintPosition_RecipientOther_Reverts() public {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(asset),
            token1: address(token1),
            fee: FEE,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(attacker),
            deadline: block.timestamp + 1 hours
        });
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "recipient must be msg.sender"));
        v3.mintPosition(params);
    }
}
