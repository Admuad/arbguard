// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Reason, Action, ActionKind, OracleConfig, PriceConfig} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3} from "./Mocks.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
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

/// @notice Minimal Chainlink AggregatorV3 interface with historical rounds
/// (for the heartbeat confirmation test).
interface IAggregatorV3Full {
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Fork tests against live Arbitrum One state.
///
/// Forks Arbitrum One via the public RPC and resolves the reference price
/// for WETH→USDC against the REAL Chainlink feeds and the REAL WETH/USDC
/// 0.05% pool (0xC696...). This pins the TWAP decimal formula (spec §1.5
/// deviation, verified live): the TWAP reference must match the Chainlink
/// reference within the 200 bps tolerance, and must match a direct
/// `observe()` computation. Also proves the sequencer feed reads 0 (up)
/// and that a 5%-pushed execution price reverts PRICE_DEVIATION.
///
/// Run:  forge test --match-contract ArbitrumOneForkTest -vv
/// RPC responses are cached by forge in ~/.foundry/cache, so re-runs are
/// cheap. No key needed — the public Arbitrum One RPC is used.
contract ArbitrumOneForkTest is Fixture {
    string internal constant ARB_ONE_RPC = "https://arb1.arbitrum.io/rpc";

    // Real Arbitrum One addresses (verified live 20 Nov 2026).
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address internal constant WETH_USDC_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    // Policy id for the real-token policy registered in setUp.
    uint256 internal realPolicyId;

    function setUp() public override {
        vm.createSelectFork(ARB_ONE_RPC);
        super.setUp();

        // Real-token policy: same limits as the pool policy, but with the
        // real Chainlink feeds + real pool, and the real sequencer feed.
        // WETH 18 dec, USDC 6 dec, both feeds 8 dec.
        realPolicyId = guard.registerPolicy(address(0xBEEF), poolPolicy(), priceConfigWithSequencer());
        guard.setOracleConfig(
            realPolicyId,
            WETH,
            OracleConfig({chainlinkFeed: ETH_USD_FEED, uniswapPool: WETH_USDC_POOL, feedDecimals: 8, tokenDecimals: 18})
        );
        guard.setOracleConfig(
            realPolicyId,
            USDC,
            OracleConfig({chainlinkFeed: USDC_USD_FEED, uniswapPool: WETH_USDC_POOL, feedDecimals: 8, tokenDecimals: 6})
        );
    }

    function priceConfigWithSequencer() internal pure returns (PriceConfig memory) {
        return PriceConfig({
            twapSeconds: 1800, maxOracleDeviationBps: 200, chainlinkStaleAfter: 7200, sequencerFeed: SEQUENCER_FEED
        });
    }

    function test_Fork_IsLiveArbitrumOne() public view {
        assertEq(block.chainid, 42161);
        // Arbitrum block.number is the L1 block number (~26.4M at the
        // fork block), not the L2 number.
        assertGt(block.number, 20_000_000); // L1 height on Arbitrum One
        assertGt(block.timestamp, 0);
    }

    /// @notice The sequencer feed reads 0 (up) on the fork.
    function test_Fork_SequencerReadsUp() public view {
        // latestRoundData returns (roundId, answer, startedAt, updatedAt,
        // answeredInRound); answer is the 2nd value.
        (, int256 answer,,,) = MockAggregatorV3(SEQUENCER_FEED).latestRoundData();
        assertEq(answer, 0); // 0 = sequencer up
    }

    /// @notice The TWAP reference matches a direct `observe()` computation
    /// and agrees with Chainlink within 200 bps. This pins the TWAP
    /// decimal formula (spec §1.5 deviation): the spec's formula with the
    /// decimal correction would be off by 1e12 and fail here.
    function test_Fork_ReferenceMatchesDirectObserve() public {
        (uint256 ref, address source) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        // Chainlink wins when both agree; the source is tokenOut's feed
        // (USDC) by the _oracleSetup convention (see Oracle.t.sol).
        assertEq(source, USDC_USD_FEED);
        assertGt(ref, 0);

        // Direct observe() on the real pool: compute the TWAP tick and
        // the reference price the same way the guard does, and assert the
        // guard's TWAP matches. (We compare via the Chainlink reference:
        // the guard returns Chainlink when both agree, so we verify the
        // TWAP agrees with Chainlink within 200 bps by checking that
        // getReferencePrice succeeded — a disagreement would revert.
        // The direct observe() value is computed below and logged.)
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(WETH_USDC_POOL).observe(secondsAgos);
        int256 delta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
        int256 twapTick = delta / 1800;
        if (delta < 0 && delta % 1800 != 0) twapTick -= 1;
        emit log_named_int("direct observe() TWAP tick", twapTick);
        emit log_named_uint("guard reference (Chainlink, 1e18)", ref);

        // The TWAP tick should be near the spot tick (within a few ticks
        // of -201721 as read live 20 Nov 2026; the fork may have moved).
        // We assert it is in a sane range, not an exact value, because
        // the fork block moves.
        assertGt(twapTick, -250000);
        assertLt(twapTick, -150000);

        // Cross-check: the Chainlink ETH/USD price and the TWAP-implied
        // price agree within 200 bps. Recompute the TWAP reference in
        // the test (same formula as the guard) and compare.
        uint256 twapRef = _twapRefFromTick(twapTick);
        uint256 diff = ref > twapRef ? ref - twapRef : twapRef - ref;
        assertLe(diff * 10_000, ref * 200, "TWAP disagrees with Chainlink by >200 bps");
        emit log_named_uint("direct TWAP reference (1e18)", twapRef);
    }

    /// @notice A 5%-pushed execution price reverts PRICE_DEVIATION while
    /// the oracles stay fresh. The reference is ~$1,735; a price 5% above
    /// it (105% of ref) is outside the 5% maxPriceDeviationBps (500 bps).
    /// The +1 counters integer-division rounding: (ref*105)/100 floors,
    /// so without it the deviation is a hair under 5% and passes.
    function test_Fork_FivePercentPushedSwap_RevertsPriceDeviation() public {
        (uint256 ref,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        uint256 pushedPrice = (ref * 105) / 100 + 1; // strictly > 5% above ref
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: pushedPrice,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.PRICE_DEVIATION));
        guard.check(protocol, swap);
    }

    /// @notice The same swap at the reference price passes.
    function test_Fork_SwapAtReference_Passes() public {
        (uint256 ref,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: ref,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        guard.check(protocol, swap);
    }

    /// @notice TWAP manipulation-cost test (spec §1.8). Simulates a large
    /// swap that pushes the pool price 5%, holds it by warping 1800 s
    /// (on a fork there are no arbitrageurs, so the pushed price holds),
    /// and measures the attacker's loss vs the outflow cap the guard
    /// would have let through. Records the order-of-magnitude cost; if
    /// the cost is ever BELOW the extractable value, the window or the
    /// cap is wrong and the test fails loudly with the numbers.
    ///
    /// The extractable value uses a REALISTIC cap for this pool, not the
    /// fixture's mock 10,000-ether cap (which is $17.5M on real WETH and
    /// would make any manipulation look cheap by comparison). The pool
    /// holds ~$26M; a per-block outflow cap of 25 WETH (~$43,700, ~0.17%
    /// of TVL) is a plausible risk limit for a guarded protocol. The
    /// test asserts the cost to push the price 5% exceeds that cap.
    /// A post-push reference read is expected to revert ORACLE_DISAGREEMENT
    /// (the guard correctly detects the manipulated TWAP diverging from
    /// Chainlink); that revert is caught and logged, not a failure.
    function test_Fork_TwapManipulationCost() public {
        (uint256 refBefore,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        emit log_named_uint("reference before push (1e18)", refBefore);

        // Fund this contract with WETH and swap a large amount to push
        // the price. Use the SwapRouter (0xE592427A0AEce92De3Edee1F18E0157C05861564).
        address router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
        uint256 wethAmount = 1500 ether; // 1500 WETH (~$2.6M at $1,735)
        deal(WETH, address(this), wethAmount);
        (bool okApprove,) = WETH.call(abi.encodeWithSignature("approve(address,uint256)", router, wethAmount));
        require(okApprove, "WETH approve failed");

        // exactInputSingle: WETH -> USDC, fee 500 (0.05%), push price down
        // (selling WETH lowers the WETH price). We measure the loss.
        uint256 usdcBefore = _erc20Balance(USDC, address(this));
        uint256 usdcOut = ISwapRouter(router)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp + 3600,
                    amountIn: wethAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        uint256 usdcAfter = _erc20Balance(USDC, address(this));
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance mismatch");

        // Attacker's loss: the value of WETH sold (at pre-push ref) minus
        // the USDC received. refBefore is 1e18-scaled USDC-per-WETH.
        uint256 expectedUsdcRaw = (wethAmount * refBefore) / 1e18;
        uint256 lossRawUsdc = expectedUsdcRaw > usdcOut ? expectedUsdcRaw - usdcOut : 0;
        emit log_named_uint("WETH sold (wei)", wethAmount);
        emit log_named_uint("USDC received (raw 6dec)", usdcOut);
        emit log_named_uint("expected USDC at pre-push price (raw)", expectedUsdcRaw);
        emit log_named_uint("attacker loss (raw USDC, 6dec)", lossRawUsdc);
        emit log_named_uint("attacker loss (USD, 1e18)", (lossRawUsdc * 1e18) / 1e6);

        // Hold the pushed price by warping the full TWAP window (1800 s).
        vm.warp(block.timestamp + 1800);
        // The guard must now see Chainlink and the manipulated TWAP
        // diverge by >200 bps and refuse to give a reference. This is the
        // CORRECT fail-closed behaviour, asserted strictly: the revert
        // must be ORACLE_DISAGREEMENT, not any other reason. (Verified
        // 21 Nov 2026: the revert data is ArbGuardViolation(8).)
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_DISAGREEMENT));
        guard.getReferencePrice(realPolicyId, WETH, USDC);

        // Extractable value: a realistic per-block outflow cap of 25 WETH
        // (~$43,700) valued at the pre-push reference, in raw USDC.
        uint256 extractableRawUsdc = (25 ether * refBefore) / 1e18;
        emit log_named_uint("extractable (25 WETH cap, raw USDC)", extractableRawUsdc);
        emit log_named_uint("extractable (USD, 1e18)", (extractableRawUsdc * 1e18) / 1e6);

        // FAIL LOUDLY if the manipulation cost is below the extractable value.
        assertGt(
            lossRawUsdc,
            extractableRawUsdc,
            "TWAP MANIPULATION IS PROFITABLE: cost < extractable value; window or cap is wrong"
        );
    }

    /// @notice Gas of a SWAP check() against the REAL Chainlink feeds and
    /// the REAL Uniswap pool (not mocks). This is the true cost a protocol
    /// pays on Arbitrum One. The mock-based Gas.t.sol number (127,475)
    /// uses MockAggregatorV3, whose latestRoundData is far cheaper than a
    /// real Chainlink proxy-plus-aggregator read, and it skips the
    /// sequencer feed. Measured here: 226,019 gas warm (21 Nov 2026).
    /// Log both calls; assert the warm cost stays under the 250k target.
    function test_Fork_Gas_Swap_RealOracles() public {
        (uint256 ref,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: ref,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        guard.check(protocol, swap);
        uint256 cold = vm.lastCallGas().gasTotalUsed;
        vm.prank(protocol);
        guard.check(protocol, swap);
        uint256 warm = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("check() SWAP real oracles cold", cold);
        emit log_named_uint("check() SWAP real oracles warm", warm);
        assertLt(warm, 250_000, "check() SWAP real oracles warm exceeded the 250k gas target");
    }

    /// @notice TWAP fallback on a REAL fork (spec §1.3/§1.4): warp past
    /// `chainlinkStaleAfter` (7200 s) so BOTH Chainlink feeds go stale,
    /// then the guard must degrade gracefully to the on-chain TWAP
    /// instead of failing closed. The pool's observe() extrapolates with
    /// the current tick (no swaps happened during the warp), so the TWAP
    /// reference is the spot price — close to the pre-warp Chainlink
    /// reference. Proves the secondary source actually saves the check
    /// on live state, not just against mocks (Oracle.t.sol covers the
    /// same path with MockAggregatorV3). Also proves a swap at the TWAP
    /// price passes, i.e. the fallback is usable, not just readable.
    function test_Fork_TwapFallback_WhenChainlinkStale() public {
        (uint256 refBefore,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        emit log_named_uint("reference before warp (1e18)", refBefore);

        // Warp 9000 s: safely past the 7200 s staleAfter for both feeds
        // (each feed's updatedAt can be up to ~5 min behind the fork
        // block; 9000 s covers that plus the 7200 s bound).
        vm.warp(block.timestamp + 9000);

        // The reference must now come from the TWAP (source = pool),
        // and must be close to the pre-warp Chainlink reference (the
        // spot price has not moved; the TWAP is the spot tick).
        (uint256 refAfter, address source) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        assertEq(source, WETH_USDC_POOL, "stale Chainlink did not fall back to the TWAP pool");
        assertGt(refAfter, 0);
        uint256 diff = refAfter > refBefore ? refAfter - refBefore : refBefore - refAfter;
        assertLe(diff * 10_000, refBefore * 200, "TWAP fallback reference diverged >200 bps from pre-warp Chainlink");
        emit log_named_uint("TWAP fallback reference after warp (1e18)", refAfter);

        // A swap at the TWAP price passes: the fallback saves the check.
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: refAfter,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        guard.check(protocol, swap);
    }

    /// @notice Reverse-direction reference on a REAL fork (USDC -> WETH):
    /// exercises the TWAP inversion path (`ref = 1e36 / ref01`) against
    /// the live pool, and the Chainlink ratio in the opposite direction.
    /// The reverse reference must be the inverse of the forward reference
    /// within the 200 bps cross-check tolerance, and the source must be
    /// tokenOut's feed (ETH/USD) by the _oracleSetup convention.
    function test_Fork_ReverseDirection_UsdcToWeth() public {
        (uint256 refForward, address sourceForward) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        (uint256 refReverse, address sourceReverse) = guard.getReferencePrice(realPolicyId, USDC, WETH);
        assertEq(sourceForward, USDC_USD_FEED, "forward source should be tokenOut (USDC) feed");
        assertEq(sourceReverse, ETH_USD_FEED, "reverse source should be tokenOut (WETH) feed");
        assertGt(refForward, 0);
        assertGt(refReverse, 0);

        // refReverse should equal 1e36 / refForward (both 1e18-scaled).
        uint256 expectedReverse = 1e36 / refForward;
        uint256 diff = refReverse > expectedReverse ? refReverse - expectedReverse : expectedReverse - refReverse;
        assertLe(diff * 10_000, expectedReverse * 200, "reverse reference is not the inverse of the forward reference");
        emit log_named_uint("forward reference WETH->USDC (1e18)", refForward);
        emit log_named_uint("reverse reference USDC->WETH (1e18)", refReverse);
        emit log_named_uint("expected reverse (1e36 / forward)", expectedReverse);

        // A reverse swap at the reference price passes.
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: WETH,
            tokenIn: USDC,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: refReverse,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        guard.check(protocol, swap);
    }

    /// @notice Chainlink heartbeat confirmation (spec §1.1 footnote, §6 Q6):
    /// the published heartbeat values (ETH/USD 3600 s, USDC/USD ~24 h)
    /// are the basis for `chainlinkStaleAfter` (7200 s). Confirm on-chain
    /// by reading the last 5 rounds of each feed via getRoundData and
    /// measuring the updatedAt deltas between consecutive rounds. The
    /// feeds update far more often than the heartbeat (deviation-triggered
    /// updates), so the max delta must be well inside it; assert it stays
    /// within 2x the published heartbeat, which validates the staleAfter
    /// bound. Measured 21 Nov 2026: ETH/USD max 90 s, USDC/USD max 271 s.
    function test_Fork_ChainlinkHeartbeat_Confirmed() public {
        uint256 ethMaxDelta = _maxUpdatedAtDelta(ETH_USD_FEED, 5);
        uint256 usdcMaxDelta = _maxUpdatedAtDelta(USDC_USD_FEED, 5);
        emit log_named_uint("ETH/USD max updatedAt delta over 5 rounds (s)", ethMaxDelta);
        emit log_named_uint("USDC/USD max updatedAt delta over 5 rounds (s)", usdcMaxDelta);
        // Published heartbeats: ETH/USD 3600 s, USDC/USD 86400 s.
        // The feeds must never go more than 2 heartbeats without an update.
        assertLt(ethMaxDelta, 2 * 3600, "ETH/USD feed gap exceeds 2x its 3600s heartbeat");
        assertLt(usdcMaxDelta, 2 * 86400, "USDC/USD feed gap exceeds 2x its 86400s heartbeat");
        // And both must update well inside chainlinkStaleAfter (7200 s),
        // or the guard would spuriously fail closed on a healthy feed.
        assertLt(ethMaxDelta, 7200, "ETH/USD feed gap exceeds chainlinkStaleAfter 7200s");
        assertLt(usdcMaxDelta, 7200, "USDC/USD feed gap exceeds chainlinkStaleAfter 7200s");
    }

    /// @notice Gas of a SWAP check() in THROTTLED mode against the REAL
    /// oracles (spec §5.3 lists throttled-mode gas; Gas.t.sol measures it
    /// only with mocks). Throttling adds the mode lookup and scaled-cap
    /// math on top of the full oracle path. The fixture pool policy's
    /// block cap (10,000 ether) throttles to 1,000 ether, so the 10-ether
    /// swap still passes. Assert the warm cost stays under the 250k target.
    function test_Fork_Gas_Swap_Throttled_RealOracles() public {
        (uint256 ref,) = guard.getReferencePrice(realPolicyId, WETH, USDC);
        guard.throttle(realPolicyId, 3600, "fork gas test: throttled mode");
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: USDC,
            tokenIn: WETH,
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: ref,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        address protocol = address(0xBEEF);
        vm.prank(protocol);
        guard.check(protocol, swap);
        uint256 cold = vm.lastCallGas().gasTotalUsed;
        vm.prank(protocol);
        guard.check(protocol, swap);
        uint256 warm = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("check() SWAP real oracles THROTTLED cold", cold);
        emit log_named_uint("check() SWAP real oracles THROTTLED warm", warm);
        assertLt(warm, 250_000, "check() SWAP real oracles THROTTLED warm exceeded the 250k gas target");
    }

    // ------------------------------------------------------------ helpers
    /// @notice Max updatedAt gap (seconds) between consecutive rounds,
    /// over the last `n` rounds of a Chainlink feed (latest round plus
    /// n-1 predecessors via getRoundData). Used by the heartbeat test.
    function _maxUpdatedAtDelta(address feed, uint256 n) internal view returns (uint256 maxDelta) {
        (uint80 roundId,,,,) = IAggregatorV3Full(feed).latestRoundData();
        uint256 prevUpdatedAt;
        for (uint256 i = 0; i < n; i++) {
            (,,, uint256 updatedAt,) = IAggregatorV3Full(feed).getRoundData(roundId - uint80(i));
            if (i > 0) {
                uint256 delta = prevUpdatedAt - updatedAt;
                if (delta > maxDelta) maxDelta = delta;
            }
            prevUpdatedAt = updatedAt;
        }
    }

    /// @notice Recompute the TWAP reference from a tick, using the same
    /// formula as the guard (single mulDiv, no decimal correction).
    /// WETH is token0 and USDC is token1 in the 0xC696 pool, so the
    /// reference is ref01 (token1 per token0), no inversion.
    function _twapRefFromTick(int256 twapTick) internal pure returns (uint256) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(twapTick));
        return FullMath.mulDiv(sqrtRatioX96, uint256(sqrtRatioX96) * 1e18, 1 << 192);
    }

    function _erc20Balance(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(ret, (uint256));
    }
}
