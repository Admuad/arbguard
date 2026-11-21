// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Velocity-window tests (spec §2.4): hour/day rollover, the slow
/// bleed under the block cap stopped by the hour cap (exact block where it
/// stops), the day cap binding after the hour cap, 0 = window unenforced,
/// throttle scaling on hour/day, and the simulateCheck mirror for
/// OUTFLOW_PER_HOUR / OUTFLOW_PER_DAY.
contract VelocityTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D0000 + _freshId));
    }

    /// @notice Register a fresh policy with the given caps (share 50%,
    /// deviation 5%, 1h cooldown, 24h timelock, throttleBps 1000).
    function _registerCaps(uint256 blockCap, uint256 hourCap, uint256 dayCap)
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

    function _withdraw(uint256 amountOut) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            tokenIn: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            tvl: 10000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
    }

    /// @notice One withdrawal in a fresh block (the per-block window resets
    /// on a new block number, so each call is an independent block).
    function _withdrawOnce(address protocol, uint256 amountOut) internal {
        vm.roll(block.number + 1);
        vm.prank(protocol);
        guard.check(protocol, _withdraw(amountOut));
    }

    /// @notice Advance to the start of the next wall-clock hour.
    function _nextHour() internal {
        uint256 nextHourStart = (block.timestamp / 3600 + 1) * 3600;
        vm.warp(nextHourStart);
        vm.roll(block.number + 1);
    }

    /// @notice Advance to the start of the next wall-clock day.
    function _nextDay() internal {
        uint256 nextDayStart = (block.timestamp / 86400 + 1) * 86400;
        vm.warp(nextDayStart);
        vm.roll(block.number + 1);
    }

    // ------------------------------------------------------- slow bleed (hour)
    function test_SlowBleed_StoppedByHourCap_ExactBlock() public {
        // Block 100, hour 2000, day 10000. An attacker withdrawing exactly
        // the block cap (100) every block stays under the per-block rule,
        // but the hour cap stops the bleed after 20 blocks (20 * 100 = 2000).
        (uint256 pid, address protocol) = _registerCaps(100 ether, 2000 ether, 10000 ether);
        pid; // the policy is exercised via `protocol`
        uint256 succeeded = 0;
        for (uint256 i = 0; i < 20; i++) {
            _withdrawOnce(protocol, 100 ether);
            succeeded++;
        }
        assertEq(succeeded, 20);
        // The 21st withdrawal (hour total would be 2100 > 2000) reverts
        // OUTFLOW_PER_HOUR, even though it is under the block cap.
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(100 ether));
        // The hour window recorded exactly 2000.
        assertEq(guard.outflowInHour(pid), 2000 ether);
    }

    function test_HourRollover_ResetsWindow() public {
        (uint256 pid, address protocol) = _registerCaps(100 ether, 2000 ether, 0);
        for (uint256 i = 0; i < 20; i++) {
            _withdrawOnce(protocol, 100 ether);
        }
        // Hour cap is hit.
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(100 ether));
        // Warp to the next hour: the window resets and the same withdrawal
        // passes again.
        _nextHour();
        vm.prank(protocol);
        guard.check(protocol, _withdraw(100 ether));
        assertEq(guard.outflowInHour(pid), 100 ether);
    }

    function test_HourBoundary_ExactSecond() public {
        // The hour id is block.timestamp / 3600. A withdrawal in the last
        // second of an hour and one in the first second of the next hour
        // land in different windows.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 100 ether, 0);
        // Fill the hour cap (100) at the end of the current hour.
        uint256 hourEnd = (block.timestamp / 3600 + 1) * 3600 - 1;
        vm.warp(hourEnd);
        _withdrawOnce(protocol, 100 ether);
        assertEq(guard.outflowInHour(pid), 100 ether);
        // One second later (new hour) the window is fresh.
        vm.warp(hourEnd + 1);
        _withdrawOnce(protocol, 100 ether);
        assertEq(guard.outflowInHour(pid), 100 ether);
    }

    // -------------------------------------------------------- day cap
    function test_DayCap_BindsAfterHourCap() public {
        // Block 100, hour 2000, day 5000. Over three hours the hour cap
        // resets each hour, but the day cap accumulates: it binds in the
        // third hour while the hour window is still well under its cap.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 2000 ether, 5000 ether);
        // Hour 1: 20 blocks * 100 = 2000 (hour cap), day total 2000.
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(protocol, 100 ether);
        // Hour 2: 20 more blocks, day total 4000.
        _nextHour();
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(protocol, 100 ether);
        assertEq(guard.outflowInDay(pid), 4000 ether);
        // Hour 3: after 10 blocks the day total hits 5000 (the cap).
        _nextHour();
        for (uint256 i = 0; i < 10; i++) _withdrawOnce(protocol, 100 ether);
        assertEq(guard.outflowInDay(pid), 5000 ether);
        // The 11th block of hour 3: hour total is only 1100 (< 2000), but
        // the day total would be 5100 > 5000 -> OUTFLOW_PER_DAY.
        assertEq(guard.outflowInHour(pid), 1000 ether);
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_DAY));
        guard.check(protocol, _withdraw(100 ether));
    }

    function test_DayRollover_ResetsWindow() public {
        (uint256 pid, address protocol) = _registerCaps(100 ether, 0, 500 ether);
        for (uint256 i = 0; i < 5; i++) _withdrawOnce(protocol, 100 ether);
        // Day cap is hit (500).
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_DAY));
        guard.check(protocol, _withdraw(100 ether));
        // Warp to the next day: the window resets.
        _nextDay();
        vm.prank(protocol);
        guard.check(protocol, _withdraw(100 ether));
        assertEq(guard.outflowInDay(pid), 100 ether);
    }

    function test_EnforcementOrder_BlockBeforeHourBeforeDay() public {
        // Block 100, hour 200, day 200. Fill hour and day to their caps.
        (, address protocol) = _registerCaps(100 ether, 200 ether, 200 ether);
        _withdrawOnce(protocol, 100 ether);
        _withdrawOnce(protocol, 100 ether); // hour 200, day 200 (both at cap)
        // A withdrawal breaching all three reverts with the FIRST rule
        // (block), proving block is checked before hour and day.
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        guard.check(protocol, _withdraw(101 ether));
        // A withdrawal passing block but breaching hour and day reverts
        // with the SECOND rule (hour), proving hour is checked before day.
        // (The first revert changed no state, so the windows are still full.)
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(1 ether));
    }

    // ------------------------------------------------------- 0 = unenforced
    function test_ZeroHourAndDay_Unenforced() public {
        // Hour = 0 and day = 0 mean those windows are not enforced: a
        // 5000-ether bleed over 50 blocks (100/block) never trips them.
        (, address protocol) = _registerCaps(100 ether, 0, 0);
        for (uint256 i = 0; i < 50; i++) {
            _withdrawOnce(protocol, 100 ether);
        }
        // Only the per-block cap binds: 101 in one block reverts.
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        guard.check(protocol, _withdraw(101 ether));
    }

    function test_ZeroHour_OnlyDayEnforced() public {
        // Hour = 0 (unenforced), day = 300: the day cap still binds.
        (, address protocol) = _registerCaps(100 ether, 0, 300 ether);
        for (uint256 i = 0; i < 3; i++) _withdrawOnce(protocol, 100 ether);
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_DAY));
        guard.check(protocol, _withdraw(100 ether));
    }

    // ------------------------------------------------------- throttle scaling
    function test_Throttle_ScalesHourCap_BleedStopsEarlier() public {
        // Same bleed as test_SlowBleed, but throttled (10%): the block cap
        // is 10 and the hour cap is 200, so the attacker can only bleed
        // 10/block and the hour window caps the total bleed at 200 (not
        // 2000). After 20 blocks of 10 the hour total is 200 (the throttled
        // cap) and the 21st block reverts OUTFLOW_PER_HOUR.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 2000 ether, 10000 ether);
        vm.prank(keeper);
        guard.throttle(pid, 3600, "throttle test");
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(protocol, 10 ether);
        assertEq(guard.outflowInHour(pid), 200 ether);
        vm.roll(block.number + 1);
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(10 ether));
    }

    // ------------------------------------------------------------- mirror
    function test_Mirror_OutflowPerHour() public {
        (uint256 pid, address protocol) = _registerCaps(100 ether, 2000 ether, 0);
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(protocol, 100 ether);
        // Roll to a fresh block so the per-block window is empty and the
        // hour window is the binding rule.
        vm.roll(block.number + 1);
        // simulateCheck reads the accumulated window and returns
        // (false, OUTFLOW_PER_HOUR); check() reverts with the same reason.
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _withdraw(100 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_HOUR));
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(100 ether));
        pid;
    }

    function test_Mirror_OutflowPerDay() public {
        (uint256 pid, address protocol) = _registerCaps(100 ether, 0, 500 ether);
        for (uint256 i = 0; i < 5; i++) _withdrawOnce(protocol, 100 ether);
        // Roll to a fresh block so the per-block window is empty and the
        // day window is the binding rule.
        vm.roll(block.number + 1);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _withdraw(100 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_DAY));
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_DAY));
        guard.check(protocol, _withdraw(100 ether));
        pid;
    }

    function test_Mirror_StaleWindowCountsAsZero() public {
        // simulateCheck treats a stale hour window as zero (mirror of the
        // block-window logic): after warping to a new hour, the accumulated
        // outflow no longer counts.
        (, address protocol) = _registerCaps(100 ether, 2000 ether, 0);
        for (uint256 i = 0; i < 20; i++) _withdrawOnce(protocol, 100 ether);
        // Roll to a fresh block so the hour window (not the block window)
        // is the binding rule.
        vm.roll(block.number + 1);
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _withdraw(100 ether));
        assertFalse(ok); // hour cap hit in the current hour
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_HOUR));
        _nextHour();
        (ok, reason) = guard.simulateCheck(protocol, _withdraw(100 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }
}
