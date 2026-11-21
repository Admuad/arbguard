// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig, OracleConfig, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3, MockUniswapV3Pool, MockSequencerFeed} from "./Mocks.sol";

/// @notice Oracle resolution tests (spec §1.8): Chainlink primary + TWAP
/// cross-check, decimal scaling, the failure matrix, sequencer, and the
/// simulateCheck mirror for every revert. The fixture already registers
/// mock oracles on the pool policy (both tokens $1.00, TWAP tick 0, so the
/// reference is 1.0); fresh policies are registered per scenario where a
/// different oracle setup is needed.
contract OracleTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D0000 + _freshId));
    }

    /// @notice Register a fresh policy for `protocol` with the given oracle
    /// configs (a config with neither a feed nor a pool is skipped, i.e.
    /// that token has no oracle). Returns (policyId, protocol).
    function _registerFresh(OracleConfig memory cfgIn, OracleConfig memory cfgOut, PriceConfig memory pc)
        internal
        returns (uint256 policyId, address protocol)
    {
        protocol = _freshProtocol();
        policyId = guard.registerPolicy(protocol, vaultPolicy(), pc);
        if (cfgIn.chainlinkFeed != address(0) || cfgIn.uniswapPool != address(0)) {
            guard.setOracleConfig(policyId, address(asset), cfgIn);
        }
        if (cfgOut.chainlinkFeed != address(0) || cfgOut.uniswapPool != address(0)) {
            guard.setOracleConfig(policyId, address(token1), cfgOut);
        }
    }

    function _swapAction(uint256 price) internal view returns (Action memory) {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: price,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
    }

    function _withdrawAction(uint256 amountOut) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            tokenIn: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
    }

    function _bothFeeds(uint256 answerIn, uint256 answerOut) internal returns (MockAggregatorV3, MockAggregatorV3) {
        MockAggregatorV3 feedIn = new MockAggregatorV3(int256(answerIn), block.timestamp, 8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(int256(answerOut), block.timestamp, 8);
        return (feedIn, feedOut);
    }

    // ------------------------------------------------------- Chainlink primary
    function test_ChainlinkOnly_18_18() public view {
        // Fixture: both feeds $1.00 (8 dec), both tokens 18 dec, TWAP tick 0.
        // Both sources agree at 1.0; Chainlink wins, source is tokenOut's feed.
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1 ether);
        assertEq(source, address(usdcFeed));
    }

    function test_ChainlinkOnly_6decUSDC_vs_18decWETH() public {
        // WETH 18 dec, ETH/USD 8 dec at $1,735.60197194; USDC 6 dec,
        // USDC/USD 8 dec at $0.99989. The 1e18-scaled raw price of USDC per
        // WETH is 1.735792909e9 (exact mulDiv value, computed off-chain).
        // The OracleConfig tokenDecimals is what the guard uses; the mock
        // ERC20s are both 18 dec, so the 6-dec side is carried by the config.
        // Chainlink-only (no TWAP pool): the mock pool's tick 0 would be a
        // 1:1 price and would disagree with Chainlink's $1,735.
        (MockAggregatorV3 wethF, MockAggregatorV3 usdcF) = _bothFeeds(173560197194, 99989000);
        (uint256 pid,) = _registerFresh(
            OracleConfig({chainlinkFeed: address(wethF), uniswapPool: address(0), feedDecimals: 8, tokenDecimals: 18}),
            OracleConfig({chainlinkFeed: address(usdcF), uniswapPool: address(0), feedDecimals: 8, tokenDecimals: 6}),
            priceConfig()
        );
        (uint256 ref, address source) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(ref, 1735792909);
        assertEq(source, address(usdcF));
        // Reverse direction (USDC -> WETH): 1e18-scaled raw WETH per USDC.
        // Exact value 99989000*1e30 // 173560197194 (single mulDiv, one
        // rounding); the old two-step mulDiv rounded twice and pinned
        // ...727000000000000.
        (uint256 refRev,) = guard.getReferencePrice(pid, address(token1), address(asset));
        assertEq(refRev, 576105591123727033577848240);
    }

    function test_ChainlinkOnly_FeedDecimalsConversion() public {
        // Feeds with 18 decimals instead of 8: answers $1.00 at 1e18 scale.
        // Chainlink-only (no TWAP pool), so the reference is purely the
        // feed-decimals conversion.
        MockAggregatorV3 feedIn = new MockAggregatorV3(1e18, block.timestamp, 18);
        MockAggregatorV3 feedOut = new MockAggregatorV3(1e18, block.timestamp, 18);
        (uint256 pid,) = _registerFresh(
            OracleConfig({
                chainlinkFeed: address(feedIn), uniswapPool: address(0), feedDecimals: 18, tokenDecimals: 18
            }),
            OracleConfig({
                    chainlinkFeed: address(feedOut), uniswapPool: address(0), feedDecimals: 18, tokenDecimals: 18
                }),
            priceConfig()
        );
        (uint256 ref,) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(ref, 1 ether);
    }

    // ------------------------------------------------------------ TWAP fallback
    function test_TwapOnly_BothDirections() public {
        // No Chainlink feeds at all: TWAP-only. Tick 10000 -> price ~2.718.
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(asset), address(token1), 10000);
        (uint256 pid,) = _registerFresh(
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(pool), feedDecimals: 0, tokenDecimals: 18}),
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(pool), feedDecimals: 0, tokenDecimals: 18}),
            priceConfig()
        );
        (uint256 refFwd, address srcFwd) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(srcFwd, address(pool));
        // 1.0001^10000 = 2.7181459268; TickMath rounding is < 1e-9 relative.
        assertApproxEqRel(refFwd, 2718145926824925696, 1e14); // 0.01%
        // Reverse direction inverts: ref_rev = 1e36 / ref_fwd.
        (uint256 refRev, address srcRev) = guard.getReferencePrice(pid, address(token1), address(asset));
        assertEq(srcRev, address(pool));
        assertApproxEqRel(refRev, 1e36 / refFwd, 1e14);
        // And the product is 1e36 (the inversion is exact up to rounding).
        assertApproxEqRel(refFwd * refRev / 1e18, 1e18, 1e14);
    }

    function test_TwapOnly_NegativeTick() public {
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(asset), address(token1), -100);
        (uint256 pid,) = _registerFresh(
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(pool), feedDecimals: 0, tokenDecimals: 18}),
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(pool), feedDecimals: 0, tokenDecimals: 18}),
            priceConfig()
        );
        (uint256 ref,) = guard.getReferencePrice(pid, address(asset), address(token1));
        // 1.0001^-100 = 0.9900503287.
        assertApproxEqRel(ref, 990050328741210624, 1e14);
    }

    // ------------------------------------------------------- agreement / dispute
    function test_BothAgree_ChainlinkWins() public {
        // Chainlink $1.00 (ref 1e18); TWAP tick 100 (~1.01005e18, 100.5 bps
        // away, inside the 200 bps band). Chainlink wins: ref and source
        // are Chainlink's, not the TWAP's.
        mockPool.setTwapTick(100);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1 ether);
        assertEq(source, address(usdcFeed));
    }

    function test_Disagreement_201bps_Reverts() public {
        // Deviation is measured relative to Chainlink (the primary):
        // weth feed $1.02051230, usdc $1.00, TWAP 1e18. Chainlink ref
        // 1.0205123e18; |cl - twap| / cl = 201.00 bps > 200 -> disagreement.
        wethFeed.setAnswer(102051230);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_DISAGREEMENT));
        guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        // Mirror: simulateCheck returns (false, ORACLE_DISAGREEMENT).
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.ORACLE_DISAGREEMENT));
    }

    function test_Disagreement_199bps_Passes() public {
        // weth feed $1.0203, usdc $1.00, TWAP 1e18. Chainlink ref
        // 1.0203e18; |cl - twap| / cl = 198.96 bps < 200 -> inside the
        // band, Chainlink wins.
        wethFeed.setAnswer(102030000);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1020300000000000000);
        assertEq(source, address(usdcFeed));
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), _swapAction(1020300000000000000));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_Disagreement_TickBoundary_199_vs_198() public {
        // Tick-based boundary: tick 199 -> TWAP ~1.020098e18, ~200.98 bps
        // from Chainlink 1e18 -> ORACLE_DISAGREEMENT.
        mockPool.setTwapTick(199);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_DISAGREEMENT));
        guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        // Tick 198 -> TWAP ~1.019996e18, ~199.96 bps -> inside the band.
        mockPool.setTwapTick(198);
        (uint256 ref,) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1 ether);
    }

    function test_Disagreement_LargeTick_Reverts() public {
        // TWAP tick 1000 (~1.105e18, 1051 bps away) vs Chainlink 1e18.
        mockPool.setTwapTick(1000);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_DISAGREEMENT));
        guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
    }

    // ------------------------------------------------------------- failure matrix
    function test_ChainlinkStale_TwapUsed() public {
        // Chainlink stale (updatedAt 7201 s ago, past chainlinkStaleAfter
        // 7200) -> TWAP is used. TWAP tick 100 makes the value
        // distinguishable from Chainlink's 1e18. Foundry starts at
        // block.timestamp 1, so warp to a realistic time first.
        vm.warp(1_000_000);
        mockPool.setTwapTick(100);
        wethFeed.setUpdatedAt(block.timestamp - 7201);
        usdcFeed.setUpdatedAt(block.timestamp - 7201);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(source, address(mockPool));
        assertApproxEqRel(ref, 1010049662092875392, 1e14);
    }

    function test_ChainlinkStale_AndTwapMissing_RevertsUnavailable() public {
        // Chainlink stale AND the TWAP pool reverts (OLD) -> no usable
        // source -> ORACLE_UNAVAILABLE (not ORACLE_STALE; see spec §1.6).
        vm.warp(1_000_000);
        wethFeed.setUpdatedAt(block.timestamp - 7201);
        usdcFeed.setUpdatedAt(block.timestamp - 7201);
        mockPool.setRevert(true);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_UNAVAILABLE));
        guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.ORACLE_UNAVAILABLE));
    }

    function test_ChainlinkAnswerZero_TwapUsed() public {
        // Answer <= 0 is unreadable -> TWAP fallback.
        mockPool.setTwapTick(100);
        wethFeed.setAnswer(0);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(source, address(mockPool));
        assertApproxEqRel(ref, 1010049662092875392, 1e14);
        // Negative answer is unreadable too.
        wethFeed.setAnswer(-5);
        (ref, source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(source, address(mockPool));
    }

    function test_ChainlinkAnsweredInRound_Lt_RoundId_TwapUsed() public {
        // answeredInRound < roundId is unreadable -> TWAP fallback.
        mockPool.setTwapTick(100);
        wethFeed.setRound(2, 1);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(source, address(mockPool));
        assertApproxEqRel(ref, 1010049662092875392, 1e14);
    }

    function test_ChainlinkReverts_TwapUsed() public {
        mockPool.setTwapTick(100);
        wethFeed.setRevert(true);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(source, address(mockPool));
        assertApproxEqRel(ref, 1010049662092875392, 1e14);
    }

    function test_TwapObserveReverts_ChainlinkUsed() public {
        mockPool.setRevert(true);
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1 ether);
        assertEq(source, address(usdcFeed));
    }

    function test_BothFail_RevertsUnavailable() public {
        // Chainlink reverts AND TWAP reverts -> ORACLE_UNAVAILABLE.
        wethFeed.setRevert(true);
        usdcFeed.setRevert(true);
        mockPool.setRevert(true);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_UNAVAILABLE));
        guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
    }

    function test_TwapWrongPair_ChainlinkUsed() public {
        // The registered pool prices a different pair -> TWAP invalid,
        // Chainlink used. (Pool token0/token1 are unrelated addresses.)
        MockUniswapV3Pool wrongPool = new MockUniswapV3Pool(address(0xAAAA), address(0xBBBB), 0);
        (uint256 pid,) = _registerFresh(
            OracleConfig({
                chainlinkFeed: address(wethFeed), uniswapPool: address(wrongPool), feedDecimals: 8, tokenDecimals: 18
            }),
            OracleConfig({
                chainlinkFeed: address(usdcFeed), uniswapPool: address(wrongPool), feedDecimals: 8, tokenDecimals: 18
            }),
            priceConfig()
        );
        (uint256 ref, address source) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(ref, 1 ether);
        assertEq(source, address(usdcFeed));
    }

    function test_NoOracleConfigured_PriceRuleSkipped() public {
        // Fresh policy with no oracle config at all: getReferencePrice
        // returns (0, address(0)) and a swap at any price passes.
        (uint256 pid, address protocol) = _registerFresh(
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            priceConfig()
        );
        (uint256 ref, address source) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(ref, 0);
        assertEq(source, address(0));
        // A swap at a wildly off price passes: the rule is skipped (v1).
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(0.01 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        // And the real check passes too (prank as the protocol).
        vm.prank(protocol);
        guard.check(protocol, _swapAction(0.01 ether));
    }

    // ------------------------------------------------- reference vs check parity
    function test_GetReferencePrice_EqualsCheckPrice() public {
        // getReferencePrice returns exactly the price check() uses: a swap
        // at the reference passes, a swap 6% above it reverts
        // PRICE_DEVIATION (pool cap is 5%).
        (uint256 ref,) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), _swapAction(ref));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        (ok, reason) = guard.simulateCheck(address(guardedPool), _swapAction(ref * 106 / 100));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.PRICE_DEVIATION));
        // At exactly the 5% boundary the check passes (the rule is strict >).
        (ok, reason) = guard.simulateCheck(address(guardedPool), _swapAction(ref * 105 / 100));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    // ---------------------------------------------------------------- sequencer
    function _registerWithSequencer(MockSequencerFeed seq) internal returns (uint256 pid, address protocol) {
        PriceConfig memory pc = priceConfig();
        pc.sequencerFeed = address(seq);
        return _registerFresh(
            OracleConfig({
                chainlinkFeed: address(wethFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            }),
            OracleConfig({
                chainlinkFeed: address(usdcFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            }),
            pc
        );
    }

    function test_SequencerDown_BlocksSwapOnly() public {
        // answer == 1 means down (startedAt is irrelevant when down).
        MockSequencerFeed seq = new MockSequencerFeed(1, block.timestamp);
        (uint256 pid, address protocol) = _registerWithSequencer(seq);
        // Swap reverts SEQUENCER_DOWN (and so does getReferencePrice).
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.SEQUENCER_DOWN));
        guard.getReferencePrice(pid, address(asset), address(token1));
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SEQUENCER_DOWN));
        // A non-swap (withdraw) is NOT sequencer-gated: it passes.
        (ok, reason) = guard.simulateCheck(protocol, _withdrawAction(10 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_SequencerGracePeriod_BlocksSwap() public {
        // Answer 0 (up) but restarted just now (startedAt == block.timestamp),
        // inside the 3600 s grace period -> SEQUENCER_DOWN.
        MockSequencerFeed seq = new MockSequencerFeed(0, block.timestamp);
        (uint256 pid, address protocol) = _registerWithSequencer(seq);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SEQUENCER_DOWN));
        // After the grace period elapses the same feed reads up.
        vm.warp(block.timestamp + 3601);
        (ok, reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        pid; // silence unused warning (pid is asserted via protocol)
    }

    function test_SequencerStartedAtZero_TreatedAsUp() public {
        // startedAt == 0 (uninitialized feed) is treated as up.
        MockSequencerFeed seq = new MockSequencerFeed(0, 0);
        (, address protocol) = _registerWithSequencer(seq);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_SequencerReverts_FailClosed() public {
        // A reverting sequencer feed fails closed: SEQUENCER_DOWN.
        MockSequencerFeed seq = new MockSequencerFeed(0, block.timestamp);
        seq.setRevert(true);
        (, address protocol) = _registerWithSequencer(seq);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SEQUENCER_DOWN));
    }

    function test_SequencerCheckedBeforePriceReads() public {
        // Sequencer down AND oracles broken: the reason is SEQUENCER_DOWN,
        // proving the sequencer is checked before any price read.
        MockSequencerFeed seq = new MockSequencerFeed(1, block.timestamp);
        (, address protocol) = _registerWithSequencer(seq);
        wethFeed.setRevert(true);
        usdcFeed.setRevert(true);
        mockPool.setRevert(true);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _swapAction(1 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SEQUENCER_DOWN));
    }

    // ------------------------------------------------------- oracle config guards
    function test_SetOracleConfig_FeedDecimalsMismatchReverts() public {
        // The feed's live decimals() must match the registered feedDecimals.
        MockAggregatorV3 feed = new MockAggregatorV3(1e8, block.timestamp, 8);
        (uint256 pid,) = _registerFresh(
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            priceConfig()
        );
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.OracleConfigInvalid.selector, "feedDecimals mismatch"));
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(feed),
                uniswapPool: address(0),
                feedDecimals: 6, // feed really has 8
                tokenDecimals: 18
            })
        );
    }

    function test_SetOracleConfig_TokenDecimalsOver18Reverts() public {
        (uint256 pid,) = _registerFresh(
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0}),
            priceConfig()
        );
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.OracleConfigInvalid.selector, "tokenDecimals > 18"));
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(0), uniswapPool: address(mockPool), feedDecimals: 0, tokenDecimals: 19
            })
        );
    }
}
