// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig, OracleConfig, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3, MockUniswapV3Pool, MockSequencerFeed} from "./Mocks.sol";

/// @notice Lock-step test (spec §5.1): a table-driven test over every rule
/// in §3.4. For each rule, `check()` reverts with reason R **iff**
/// `simulateCheck()` returns `(false, R)`; for passing actions both agree
/// on `(true, NONE)` / success. Each case runs on a FRESH policy so the
/// outflow windows of one case never leak into another. This file is the
/// lock-step guarantee and must grow with every future rule.
contract MirrorTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D0000 + _freshId));
    }

    /// @notice Register a fresh policy with the given caps (share 50%,
    /// deviation 5%, 1h cooldown, 24h timelock, throttleBps 1000) and NO
    /// oracles (the price rule is skipped).
    function _freshPolicy(uint256 blockCap, uint256 hourCap, uint256 dayCap)
        internal
        returns (uint256 pid, address protocol)
    {
        protocol = _freshProtocol();
        Policy memory p = Policy({
            maxOutflowPerBlock: blockCap,
            maxOutflowPerHour: hourCap,
            maxOutflowPerDay: dayCap,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 0,
            maxReserveDrainBps: 0
        });
        pid = guard.registerPolicy(protocol, p, priceConfig());
        guard.addKeeper(pid, keeper);
    }

    /// @notice Register a fresh policy with the fixture's vault caps and the
    /// given oracle sources (a pool and two feeds), so swaps resolve to a
    /// reference price.
    function _freshPolicyWithOracles(MockUniswapV3Pool pool, MockAggregatorV3 feedIn, MockAggregatorV3 feedOut)
        internal
        returns (uint256 pid, address protocol)
    {
        protocol = _freshProtocol();
        pid = guard.registerPolicy(protocol, vaultPolicy(), priceConfig());
        guard.addKeeper(pid, keeper);
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(feedIn),
                uniswapPool: address(pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            pid,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(feedOut),
                uniswapPool: address(pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
    }

    function _withdraw(uint256 amountOut, uint256 tvl) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            tokenIn: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            tvl: tvl,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
    }

    function _swap(uint256 price) internal view returns (Action memory) {
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

    /// @notice The lock-step assertion for one case: simulateCheck returns
    /// (expectedOk, expectedReason) AND check() either succeeds (when
    /// expectedOk) or reverts with ArbGuardViolation(expectedReason).
    /// `name` labels the case so a failure names the rule.
    function _runCase(string memory name, address protocol, Action memory action, bool expectedOk, Reason expectedReason)
        internal
    {
        (bool ok, Reason reason) = guard.simulateCheck(protocol, action);
        assertEq(ok, expectedOk, string.concat(name, ": simulateCheck ok"));
        assertEq(uint8(reason), uint8(expectedReason), string.concat(name, ": simulateCheck reason"));
        if (expectedOk) {
            vm.prank(protocol);
            guard.check(protocol, action);
        } else {
            vm.prank(protocol);
            vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, expectedReason));
            guard.check(protocol, action);
        }
    }

    /// @notice One withdrawal in a fresh block (rolls the block number so
    /// the per-block window resets).
    function _withdrawOnce(address protocol, uint256 amountOut) internal {
        vm.roll(block.number + 1);
        vm.prank(protocol);
        guard.check(protocol, _withdraw(amountOut, 10000 ether));
    }

    function test_Mirror_OutflowAndShare() public {
        // --- 1. Pass (NONE): a small withdrawal under every cap.
        (, address p1) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        _runCase("pass", p1, _withdraw(10 ether, 1000 ether), true, Reason.NONE);

        // --- 2. OUTFLOW_PER_BLOCK: 150 > 100 block cap.
        (, address p2) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        _runCase("outflow-per-block", p2, _withdraw(150 ether, 10000 ether), false, Reason.OUTFLOW_PER_BLOCK);

        // --- 3. OUTFLOW_PER_HOUR: accumulate 2000 in the hour, then one more.
        (, address p3) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(p3, 100 ether);
        vm.roll(block.number + 1); // fresh block so the block rule does not bind
        _runCase("outflow-per-hour", p3, _withdraw(100 ether, 10000 ether), false, Reason.OUTFLOW_PER_HOUR);

        // --- 4. OUTFLOW_PER_DAY: accumulate 500 in the day, then one more.
        (, address p4) = _freshPolicy(100 ether, 0, 500 ether);
        for (uint256 i = 0; i < 5; i++) _withdrawOnce(p4, 100 ether);
        vm.roll(block.number + 1);
        _runCase("outflow-per-day", p4, _withdraw(100 ether, 10000 ether), false, Reason.OUTFLOW_PER_DAY);

        // --- 5. SINGLE_SHARE: 900/1000 = 90% > 50% (block cap is 10000 so
        // it does not bind first).
        (, address p5) = _freshPolicy(10000 ether, 0, 0);
        _runCase("single-share", p5, _withdraw(900 ether, 1000 ether), false, Reason.SINGLE_SHARE);
    }

    function test_Mirror_PriceRules() public {
        // --- 6. PRICE_DEVIATION: swap at 1.06 vs the 1.0 reference (6% > 5%).
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(asset), address(token1), 0);
        MockAggregatorV3 feedIn = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(1e8, block.timestamp, 8);
        (, address p6) = _freshPolicyWithOracles(pool, feedIn, feedOut);
        _runCase("price-deviation", p6, _swap(106e16), false, Reason.PRICE_DEVIATION);
        // And at the reference price it passes.
        _runCase("price-at-reference", p6, _swap(1 ether), true, Reason.NONE);

        // --- 7. ORACLE_DISAGREEMENT: Chainlink $1.00 vs TWAP tick 1000 (~$1.105).
        MockUniswapV3Pool pool7 = new MockUniswapV3Pool(address(asset), address(token1), 1000);
        MockAggregatorV3 feedIn7 = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockAggregatorV3 feedOut7 = new MockAggregatorV3(1e8, block.timestamp, 8);
        (, address p7) = _freshPolicyWithOracles(pool7, feedIn7, feedOut7);
        _runCase("oracle-disagreement", p7, _swap(1 ether), false, Reason.ORACLE_DISAGREEMENT);

        // --- 8. ORACLE_UNAVAILABLE: both feeds revert and the pool reverts.
        MockUniswapV3Pool pool8 = new MockUniswapV3Pool(address(asset), address(token1), 0);
        pool8.setRevert(true);
        MockAggregatorV3 feedIn8 = new MockAggregatorV3(1e8, block.timestamp, 8);
        feedIn8.setRevert(true);
        MockAggregatorV3 feedOut8 = new MockAggregatorV3(1e8, block.timestamp, 8);
        feedOut8.setRevert(true);
        (, address p8) = _freshPolicyWithOracles(pool8, feedIn8, feedOut8);
        _runCase("oracle-unavailable", p8, _swap(1 ether), false, Reason.ORACLE_UNAVAILABLE);
    }

    function test_Mirror_SequencerAndBreaker() public {
        // --- 9. SEQUENCER_DOWN: sequencer reports down; a swap reverts but
        // a non-swap passes (the sequencer check is swaps-only).
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(asset), address(token1), 0);
        MockAggregatorV3 feedIn = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockSequencerFeed seq = new MockSequencerFeed(1, block.timestamp);
        PriceConfig memory pcSeq = priceConfig();
        pcSeq.sequencerFeed = address(seq);
        address p9 = _freshProtocol();
        uint256 pid9 = guard.registerPolicy(p9, vaultPolicy(), pcSeq);
        guard.addKeeper(pid9, keeper);
        guard.setOracleConfig(
            pid9,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(feedIn),
                uniswapPool: address(pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            pid9,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(feedOut),
                uniswapPool: address(pool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        _runCase("sequencer-down-swap", p9, _swap(1 ether), false, Reason.SEQUENCER_DOWN);
        _runCase("sequencer-down-withdraw-passes", p9, _withdraw(10 ether, 1000 ether), true, Reason.NONE);

        // --- 10. BREAKER_TRIPPED (tripped): keeper trips, then any action reverts.
        (uint256 pid10, address p10) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        vm.prank(keeper);
        guard.trip(pid10, "mirror trip");
        _runCase("breaker-tripped", p10, _withdraw(10 ether, 1000 ether), false, Reason.BREAKER_TRIPPED);

        // --- 11. BREAKER_TRIPPED (disabled): setEnabled(false) blocks checks.
        (uint256 pid11, address p11) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        guard.setEnabled(pid11, false);
        _runCase("breaker-disabled", p11, _withdraw(10 ether, 1000 ether), false, Reason.BREAKER_TRIPPED);

        // --- 12. THROTTLED: the throttled block cap (10) binds; a smaller
        // withdrawal passes under the scaled caps.
        (uint256 pid12, address p12) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        vm.prank(keeper);
        guard.throttle(pid12, 3600, "mirror throttle");
        _runCase("throttled-block", p12, _withdraw(11 ether, 1000 ether), false, Reason.OUTFLOW_PER_BLOCK);
        _runCase("throttled-pass", p12, _withdraw(10 ether, 1000 ether), true, Reason.NONE);
    }

    function test_Mirror_OracleStaleNeverReturned() public {
        // --- 13. ORACLE_STALE is never returned: a stale Chainlink feed
        // falls back to TWAP (passes), and stale + broken TWAP is
        // ORACLE_UNAVAILABLE, never ORACLE_STALE.
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(asset), address(token1), 0);
        MockAggregatorV3 feedIn = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockAggregatorV3 feedOut = new MockAggregatorV3(1e8, block.timestamp, 8);
        (, address p13) = _freshPolicyWithOracles(pool, feedIn, feedOut);
        vm.warp(1_000_000);
        feedIn.setUpdatedAt(block.timestamp - 7201);
        feedOut.setUpdatedAt(block.timestamp - 7201);
        // Stale Chainlink, valid TWAP: passes (TWAP fallback), never STALE.
        _runCase("stale-chainlink-twap-fallback", p13, _swap(1 ether), true, Reason.NONE);
        // Stale Chainlink AND broken TWAP: ORACLE_UNAVAILABLE, not STALE.
        pool.setRevert(true);
        _runCase("stale-and-broken-unavailable", p13, _swap(1 ether), false, Reason.ORACLE_UNAVAILABLE);
    }

    function test_Mirror_UnknownPolicy_BothRevert() public {
        // UnknownPolicy is not a Reason (it reverts), but check() and
        // simulateCheck() must agree on it too.
        address unknown = address(0xCAFE);
        vm.prank(unknown);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicy.selector, unknown));
        guard.check(unknown, _withdraw(1 ether, 100 ether));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicy.selector, unknown));
        guard.simulateCheck(unknown, _withdraw(1 ether, 100 ether));
    }

    function test_Mirror_NotProtocol_OnlyCheckReverts() public {
        // NotProtocol is a caller check that simulateCheck cannot mirror
        // (it is a view with no msg.sender requirement): check() reverts
        // NotProtocol when a stranger calls it, while simulateCheck() for
        // the same action returns the rule outcome. Documented here so the
        // asymmetry is explicit, not hidden.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ArbGuard.NotProtocol.selector, stranger, address(guardedVault))
        );
        guard.check(address(guardedVault), _withdraw(10 ether, 1000 ether));
        (bool ok, Reason reason) =
            guard.simulateCheck(address(guardedVault), _withdraw(10 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_Mirror_NoOracleConfigured_PriceSkipped() public {
        // No oracle configured: a swap at any price passes on both.
        (, address p) = _freshPolicy(100 ether, 2000 ether, 10000 ether);
        _runCase("no-oracle-swap-passes", p, _swap(0.01 ether), true, Reason.NONE);
    }

    /// @notice Phase 2 rows (spec §5.1): HEALTH_FACTOR and RESERVE_DRAIN
    /// mirror exactly like the Phase 1 rules. Each case runs on a FRESH
    /// policy so outflow windows never leak between cases.
    function test_Mirror_Phase2Rules() public {
        // --- HEALTH_FACTOR rows (floor 1.25x) ---
        (, address hf) = _freshPolicyWithRules(12500, 0);
        _runCase("hf-below-floor", hf, _borrowHF(1236e15), false, Reason.HEALTH_FACTOR);
        _runCase("hf-at-floor", hf, _borrowHF(12500e14), true, Reason.NONE);
        _runCase("hf-above-floor", hf, _borrowHF(1254e15), true, Reason.NONE);
        _runCase("hf-infinite", hf, _borrowHF(type(uint256).max), true, Reason.NONE);
        _runCase("hf-zero", hf, _borrowHF(0), false, Reason.HEALTH_FACTOR);
        // A swap ignores healthFactorAfter even when it is 0.
        _runCase("hf-swap-ignored", hf, _swapWithHF(0), true, Reason.NONE);
        // Rule off: a terrible HF passes.
        (, address hfOff) = _freshPolicyWithRules(0, 0);
        _runCase("hf-off", hfOff, _borrowHF(0), true, Reason.NONE);

        // --- RESERVE_DRAIN rows (cap 50%) ---
        (, address dr) = _freshPolicyWithRules(0, 5000);
        _runCase("drain-49pct", dr, _withdrawDrain(4900 ether, 10000 ether), true, Reason.NONE);
        _runCase("drain-50pct", dr, _withdrawDrain(5000 ether, 10000 ether), true, Reason.NONE);
        _runCase("drain-51pct", dr, _withdrawDrain(5100 ether, 10000 ether), false, Reason.RESERVE_DRAIN);
        _runCase("drain-swap", dr, _swapDrain(6000 ether, 10000 ether), false, Reason.RESERVE_DRAIN);
        _runCase("drain-empty-positive", dr, _withdrawDrain(1 ether, 0), false, Reason.RESERVE_DRAIN);
        _runCase("drain-empty-zero", dr, _withdrawDrain(0, 0), true, Reason.NONE);
        // Rule off: draining the whole reserve passes.
        (, address drOff) = _freshPolicyWithRules(0, 0);
        _runCase("drain-off", drOff, _withdrawDrain(10000 ether, 10000 ether), true, Reason.NONE);
    }

    /// @notice Fresh policy with generous caps and the given Phase 2 rule
    /// settings (HF floor, drain cap). Share 100% so single-share never
    /// binds before the new rules; the per-block cap is 100,000 so the
    /// outflow windows never bind before the new rules either (the
    /// passing drain cases consume ~10,000 of it in total).
    function _freshPolicyWithRules(uint16 minHF, uint16 drainBps) internal returns (uint256 pid, address protocol) {
        protocol = _freshProtocol();
        Policy memory p = Policy({
            maxOutflowPerBlock: 100_000 ether,
            maxOutflowPerHour: 0,
            maxOutflowPerDay: 0,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: minHF,
            maxReserveDrainBps: drainBps
        });
        pid = guard.registerPolicy(protocol, p, priceConfig());
        guard.addKeeper(pid, keeper);
    }

    function _borrowHF(uint256 hfAfter) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.BORROW,
            token: address(0),
            tokenIn: address(0),
            amountOut: 10 ether,
            amountIn: 0,
            price: 0,
            tvl: 1000 ether,
            healthFactorAfter: hfAfter,
            availableLiquidity: 1000 ether
        });
    }

    function _withdrawDrain(uint256 amountOut, uint256 available) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            tokenIn: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            tvl: 10000 ether,
            healthFactorAfter: type(uint256).max,
            availableLiquidity: available
        });
    }

    function _swapWithHF(uint256 hfAfter) internal view returns (Action memory) {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1 ether,
            tvl: 1000 ether,
            healthFactorAfter: hfAfter,
            availableLiquidity: 1000 ether
        });
    }

    function _swapDrain(uint256 amountOut, uint256 available) internal view returns (Action memory) {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: amountOut,
            amountIn: amountOut,
            price: 1 ether,
            tvl: 10000 ether,
            healthFactorAfter: 0,
            availableLiquidity: available
        });
    }
}
