// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ArbGuard, Policy, PriceConfig, Action, ActionKind, Reason, Mode} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Throttle-mode tests (spec §2.3): THROTTLED scales the block,
/// hour, and day caps by throttleBps/10000 (exact effective caps at
/// 1000 bps = 10%); price and single-share rules are unchanged;
/// unthrottle is owner-only; throttle expiry (timed and indefinite);
/// trip from THROTTLED; reset returns to NORMAL; simulateCheck mirrors
/// the throttled caps.
contract ThrottleTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D0000 + _freshId));
    }

    /// @notice Register a fresh policy with the given caps (share 50%,
    /// deviation 5%, 1h cooldown, 24h timelock, throttleBps as given).
    function _registerCaps(uint256 blockCap, uint256 hourCap, uint256 dayCap, uint16 throttleBps)
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
            throttleBps: throttleBps,
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

    /// @notice Call check() as the protocol (mutates the outflow windows).
    function _check(address protocol, Action memory action) internal {
        vm.prank(protocol);
        guard.check(protocol, action);
    }

    // ------------------------------------------------------- cap scaling
    function test_Throttle_ScalesBlockCap_Exact() public {
        // Vault: block 100 ether, throttleBps 1000 -> effective 10 ether.
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle test");
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.THROTTLED));
        // 10 ether passes (exactly the effective cap).
        (bool ok, Reason reason) =
            guard.simulateCheck(address(guardedVault), _withdraw(10 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        // 11 ether reverts OUTFLOW_PER_BLOCK.
        (ok, reason) = guard.simulateCheck(address(guardedVault), _withdraw(11 ether, 1000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_BLOCK));
        // The real check agrees.
        vm.prank(address(guardedVault));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        guard.check(address(guardedVault), _withdraw(11 ether, 1000 ether));
    }

    function test_Throttle_ScalesHourCap_Exact() public {
        // Fresh policy: block 100, hour 50, day 0 (unenforced), throttle 10%.
        // Effective hour cap when throttled: 50 * 1000 / 10000 = 5 ether.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 50 ether, 0, 1000);
        vm.prank(keeper);
        guard.throttle(pid, 3600, "throttle test");
        // Withdraw 5 ether (hour total 5, exactly the effective cap).
        _check(protocol, _withdraw(5 ether, 1000 ether));
        // One more ether exceeds the throttled hour cap (6 > 5).
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_HOUR));
        guard.check(protocol, _withdraw(1 ether, 1000 ether));
        // In NORMAL mode the same 6 ether total would be fine (cap 50).
        guard.unthrottle(pid);
        _check(protocol, _withdraw(1 ether, 1000 ether));
    }

    function test_Throttle_ScalesDayCap_Exact() public {
        // Fresh policy: block 100, hour 10000 (large), day 20, throttle 10%.
        // Effective day cap when throttled: 20 * 1000 / 10000 = 2 ether.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 10000 ether, 20 ether, 1000);
        vm.prank(keeper);
        guard.throttle(pid, 3600, "throttle test");
        // Withdraw 2 ether (day total 2, exactly the effective cap).
        _check(protocol, _withdraw(2 ether, 1000 ether));
        // One more ether exceeds the throttled day cap (3 > 2). The block
        // cap (10) and hour cap (1000) do not bind here.
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_DAY));
        guard.check(protocol, _withdraw(1 ether, 1000 ether));
    }

    function test_Throttle_FullBps_NoScaling() public {
        // throttleBps 10000 = 100%: throttling changes nothing. Hour/day
        // windows are unenforced (0) so only the block cap binds.
        (uint256 pid, address protocol) = _registerCaps(100 ether, 0, 0, 10000);
        vm.prank(keeper);
        guard.throttle(pid, 3600, "throttle test");
        assertEq(uint8(guard.getMode(pid)), uint8(Mode.THROTTLED));
        // The full 100 ether block cap still applies.
        (bool ok, Reason reason) = guard.simulateCheck(protocol, _withdraw(100 ether, 10000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        (ok, reason) = guard.simulateCheck(protocol, _withdraw(101 ether, 10000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_BLOCK));
    }

    function test_Throttle_PriceAndShareUnchanged() public {
        // Throttle scales caps only. The price rule (swap at the 1.0
        // reference) still passes on the throttled pool.
        vm.prank(keeper);
        guard.throttle(poolPolicyId, 3600, "throttle test");
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), _swap(1 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        // The single-share rule is not scaled by throttle either. Use a
        // fresh policy with a large block cap (throttled to 1000) and a 50%
        // share cap: a 600/1000 (60%) withdraw breaches the share rule even
        // though it is under the throttled block cap.
        (uint256 pid, address protocol) = _registerCaps(10000 ether, 0, 0, 1000);
        vm.prank(keeper);
        guard.throttle(pid, 3600, "throttle test");
        (ok, reason) = guard.simulateCheck(protocol, _withdraw(600 ether, 1000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SINGLE_SHARE));
        // And a 40% share passes (under both the share cap and the
        // throttled block cap).
        (ok, reason) = guard.simulateCheck(protocol, _withdraw(400 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    // ------------------------------------------------------------- transitions
    function test_Throttle_EmitsEvent_AndSetsUntil() public {
        uint256 until = block.timestamp + 3600;
        vm.expectEmit(true, true, false, true, address(guard));
        emit ArbGuard.ThrottleSet(vaultPolicyId, keeper, until);
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "evidence");
        assertEq(guard.throttleUntil(vaultPolicyId), until);
    }

    function test_Throttle_AlreadyThrottled_Reverts() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "first");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.AlreadyThrottled.selector, vaultPolicyId));
        guard.throttle(vaultPolicyId, 3600, "second");
    }

    function test_Throttle_WhenPaused_Reverts() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "trip first");
        uint256 until = guard.pausedUntil(vaultPolicyId);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.BreakerStillActive.selector, until));
        guard.throttle(vaultPolicyId, 3600, "throttle while paused");
    }

    function test_Throttle_NonKeeper_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, stranger));
        guard.throttle(vaultPolicyId, 3600, "stranger");
    }

    function test_Unthrottle_OwnerOnly() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.unthrottle(vaultPolicyId);
        // The owner can.
        vm.expectEmit(true, false, false, true, address(guard));
        emit ArbGuard.ThrottleCleared(vaultPolicyId);
        guard.unthrottle(vaultPolicyId);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.NORMAL));
        assertEq(guard.throttleUntil(vaultPolicyId), 0);
    }

    function test_Unthrottle_WhenNotThrottled_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "policy is not throttled"));
        guard.unthrottle(vaultPolicyId);
    }

    function test_Throttle_Expiry_AutoResumes() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "timed throttle");
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.THROTTLED));
        // Before expiry the throttled cap binds.
        (bool ok, Reason reason) =
            guard.simulateCheck(address(guardedVault), _withdraw(11 ether, 1000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_BLOCK));
        // Warp past throttleUntil: auto-resume to NORMAL, full caps back.
        vm.warp(block.timestamp + 3601);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.NORMAL));
        (ok, reason) = guard.simulateCheck(address(guardedVault), _withdraw(11 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_Throttle_Indefinite_Persists() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 0, "indefinite");
        assertEq(guard.throttleUntil(vaultPolicyId), 0);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.THROTTLED));
        // Warp a year ahead: an indefinite throttle never auto-expires.
        vm.warp(block.timestamp + 365 days);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.THROTTLED));
        // Only the owner clearing it returns to NORMAL.
        guard.unthrottle(vaultPolicyId);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.NORMAL));
    }

    function test_Trip_FromThrottled() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle");
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "escalate to trip");
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.PAUSED));
        assertGt(guard.pausedUntil(vaultPolicyId), block.timestamp);
    }

    function test_Reset_FromThrottled_Reverts() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle");
        vm.expectRevert(
            abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "policy is throttled, use unthrottle")
        );
        guard.reset(vaultPolicyId);
    }

    function test_Reset_AfterTrip_ReturnsToNormal() public {
        // Throttle, then trip, then reset after the cooldown: back to
        // NORMAL (spec decision), not to THROTTLED.
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle");
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "trip");
        vm.warp(block.timestamp + 3601);
        guard.reset(vaultPolicyId);
        assertEq(uint8(guard.getMode(vaultPolicyId)), uint8(Mode.NORMAL));
        // Full caps are back.
        (bool ok, Reason reason) =
            guard.simulateCheck(address(guardedVault), _withdraw(100 ether, 10000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
    }

    function test_SimulateCheck_MirrorsThrottledCaps() public {
        // Lock-step: for a throttled policy, check() reverts iff
        // simulateCheck() returns (false, same reason).
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "throttle");
        (bool ok, Reason reason) =
            guard.simulateCheck(address(guardedVault), _withdraw(11 ether, 1000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_BLOCK));
        vm.prank(address(guardedVault));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        guard.check(address(guardedVault), _withdraw(11 ether, 1000 ether));
        // And a passing amount agrees on both.
        (ok, reason) = guard.simulateCheck(address(guardedVault), _withdraw(10 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));
        vm.prank(address(guardedVault));
        guard.check(address(guardedVault), _withdraw(10 ether, 1000 ether));
    }
}
