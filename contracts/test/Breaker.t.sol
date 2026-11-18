// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

contract BreakerTest is Fixture {
    function test_Trip_ByKeeper_PausesVault() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "suspicious outflow");
        assertGt(guard.pausedUntil(vaultPolicyId), block.timestamp);

        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guardedVault.withdraw(10 ether);
    }

    function test_Trip_ByOwner_PausesVault() public {
        // The test contract deployed the guard, so it is the owner.
        guard.trip(vaultPolicyId, "owner trip");
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guardedVault.withdraw(10 ether);
    }

    function test_Trip_ByStrangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, stranger));
        guard.trip(vaultPolicyId, "nope");
        assertEq(guard.pausedUntil(vaultPolicyId), 0);
    }

    function test_Trip_UnknownPolicyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicyId.selector, 999));
        guard.trip(999, "nope");
    }

    function test_Reset_BeforeCooldownReverts() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "suspicious outflow");
        uint256 until = guard.pausedUntil(vaultPolicyId);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.BreakerStillActive.selector, until));
        guard.reset(vaultPolicyId);
    }

    function test_Reset_AfterCooldown_SucceedsAndWithdrawWorks() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "suspicious outflow");
        vm.warp(block.timestamp + 3601);
        guard.reset(vaultPolicyId);
        assertEq(guard.pausedUntil(vaultPolicyId), 0);

        vm.prank(victim);
        guardedVault.withdraw(10 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 990 ether);
    }

    function test_AutoResume_AfterCooldownWithoutReset() public {
        // No reset call at all: once block.timestamp passes pausedUntil,
        // the check passes on its own — the breaker auto-resumes.
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "suspicious outflow");

        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guardedVault.withdraw(10 ether);

        vm.warp(block.timestamp + 3601);
        vm.prank(victim);
        guardedVault.withdraw(10 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 990 ether);
    }

    function test_Trip_EmitsEvent() public {
        vm.prank(keeper);
        vm.expectEmit(true, true, false, true, address(guard));
        emit ArbGuard.BreakerTripped(vaultPolicyId, keeper, block.timestamp + 3600, "suspicious outflow");
        guard.trip(vaultPolicyId, "suspicious outflow");
    }
}
