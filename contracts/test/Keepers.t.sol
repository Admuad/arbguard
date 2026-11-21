// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Multi-keeper tests (spec §2.2): add/remove, the 10-keeper cap,
/// any keeper may trip/throttle, non-keepers revert, keepers cannot
/// reset/update/manage the keeper set, and removal by swap-and-pop
/// preserves the set. The fixture already registers `keeper` on both
/// policies; the deployer (this test contract) is the owner.
contract KeepersTest is Fixture {
    function test_AddKeeper_StoresAndEnumerates() public {
        address k2 = makeAddr("keeper2");
        address k3 = makeAddr("keeper3");
        guard.addKeeper(vaultPolicyId, k2);
        guard.addKeeper(vaultPolicyId, k3);
        assertTrue(guard.isKeeper(vaultPolicyId, keeper));
        assertTrue(guard.isKeeper(vaultPolicyId, k2));
        assertTrue(guard.isKeeper(vaultPolicyId, k3));
        address[] memory keepers = guard.getKeepers(vaultPolicyId);
        assertEq(keepers.length, 3);
        assertEq(keepers[0], keeper);
        assertEq(keepers[1], k2);
        assertEq(keepers[2], k3);
    }

    function test_AddKeeper_EmitsEvent() public {
        address k2 = makeAddr("keeper2");
        vm.expectEmit(true, true, false, true, address(guard));
        emit ArbGuard.KeeperAdded(vaultPolicyId, k2);
        guard.addKeeper(vaultPolicyId, k2);
    }

    function test_AddKeeper_OnlyOwner() public {
        address k2 = makeAddr("keeper2");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.addKeeper(vaultPolicyId, k2);
    }

    function test_AddKeeper_ZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "keeper is zero address"));
        guard.addKeeper(vaultPolicyId, address(0));
    }

    function test_AddKeeper_DuplicateReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "keeper already added"));
        guard.addKeeper(vaultPolicyId, keeper);
    }

    function test_AddKeeper_TenKeeperCap() public {
        // The fixture already has 1 keeper; add 9 more to reach the cap.
        for (uint256 i = 0; i < 9; i++) {
            guard.addKeeper(vaultPolicyId, address(uint160(0x1000 + i)));
        }
        assertEq(guard.getKeepers(vaultPolicyId).length, 10);
        // The 11th reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.TooManyKeepers.selector, vaultPolicyId));
        guard.addKeeper(vaultPolicyId, address(uint160(0x2000)));
    }

    function test_AddKeeper_CapIsPerPolicy() public {
        // Filling the vault policy to 10 does not affect the pool policy.
        for (uint256 i = 0; i < 9; i++) {
            guard.addKeeper(vaultPolicyId, address(uint160(0x1000 + i)));
        }
        assertEq(guard.getKeepers(vaultPolicyId).length, 10);
        assertEq(guard.getKeepers(poolPolicyId).length, 1);
        guard.addKeeper(poolPolicyId, makeAddr("poolKeeper2"));
        assertEq(guard.getKeepers(poolPolicyId).length, 2);
    }

    function test_RemoveKeeper_SwapAndPopPreservesSet() public {
        address k2 = makeAddr("keeper2");
        address k3 = makeAddr("keeper3");
        address k4 = makeAddr("keeper4");
        guard.addKeeper(vaultPolicyId, k2);
        guard.addKeeper(vaultPolicyId, k3);
        guard.addKeeper(vaultPolicyId, k4);
        // Remove k2 (middle of the array): swap-and-pop moves k4 into
        // k2's slot, so the set is {keeper, k4, k3}.
        vm.expectEmit(true, true, false, true, address(guard));
        emit ArbGuard.KeeperRemoved(vaultPolicyId, k2);
        guard.removeKeeper(vaultPolicyId, k2);
        assertFalse(guard.isKeeper(vaultPolicyId, k2));
        assertTrue(guard.isKeeper(vaultPolicyId, keeper));
        assertTrue(guard.isKeeper(vaultPolicyId, k3));
        assertTrue(guard.isKeeper(vaultPolicyId, k4));
        address[] memory keepers = guard.getKeepers(vaultPolicyId);
        assertEq(keepers.length, 3);
        assertEq(keepers[0], keeper);
        assertEq(keepers[1], k4); // swapped into k2's slot
        assertEq(keepers[2], k3);
        // The removed keeper can no longer trip.
        vm.prank(k2);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, k2));
        guard.trip(vaultPolicyId, "no longer a keeper");
    }

    function test_RemoveKeeper_NotAKeeperReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "not a keeper"));
        guard.removeKeeper(vaultPolicyId, stranger);
    }

    function test_RemoveKeeper_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.removeKeeper(vaultPolicyId, keeper);
    }

    function test_RemoveKeeper_LastKeeperRemovable() public {
        // Removing the only keeper leaves an empty set; the owner can
        // still trip (owner is always authorized).
        guard.removeKeeper(vaultPolicyId, keeper);
        assertEq(guard.getKeepers(vaultPolicyId).length, 0);
        assertFalse(guard.isKeeper(vaultPolicyId, keeper));
        guard.trip(vaultPolicyId, "owner trips with no keepers");
        assertEq(uint8(guard.getMode(vaultPolicyId)), 2); // PAUSED
    }

    function test_KeeperCanTrip() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "keeper trip");
        assertEq(uint8(guard.getMode(vaultPolicyId)), 2); // PAUSED
    }

    function test_KeeperCanThrottle() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "keeper throttle");
        assertEq(uint8(guard.getMode(vaultPolicyId)), 1); // THROTTLED
    }

    function test_NonKeeperCannotTrip() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, stranger));
        guard.trip(vaultPolicyId, "stranger trip");
    }

    function test_NonKeeperCannotThrottle() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, stranger));
        guard.throttle(vaultPolicyId, 3600, "stranger throttle");
    }

    function test_KeeperCannotReset() public {
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "keeper trip");
        vm.warp(block.timestamp + 3601);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.reset(vaultPolicyId);
    }

    function test_KeeperCannotUnthrottle() public {
        vm.prank(keeper);
        guard.throttle(vaultPolicyId, 3600, "keeper throttle");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.unthrottle(vaultPolicyId);
    }

    function test_KeeperCannotUpdatePolicy() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.proposePolicyUpdate(vaultPolicyId, vaultPolicy(), priceConfig());
    }

    function test_KeeperCannotManageKeepers() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.addKeeper(vaultPolicyId, makeAddr("keeper2"));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.removeKeeper(vaultPolicyId, keeper);
    }

    function test_KeeperCannotSetEnabled() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.setEnabled(vaultPolicyId, false);
    }

    function test_KeeperCannotSetOracleConfig() public {
        // Evaluate the config BEFORE the prank: vm.prank applies to the
        // next external call, and evaluating the argument inline would
        // consume the prank on the view call.
        OracleConfig memory cfg = guard.getOracleConfig(poolPolicyId, address(asset));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        guard.setOracleConfig(vaultPolicyId, address(asset), cfg);
    }

    function test_KeeperScopeIsPerPolicy() public {
        // A keeper of the vault policy is NOT a keeper of the pool policy.
        address vaultOnly = makeAddr("vaultOnly");
        guard.addKeeper(vaultPolicyId, vaultOnly);
        assertTrue(guard.isKeeper(vaultPolicyId, vaultOnly));
        assertFalse(guard.isKeeper(poolPolicyId, vaultOnly));
        vm.prank(vaultOnly);
        guard.trip(vaultPolicyId, "vault-only keeper trips the vault");
        assertEq(uint8(guard.getMode(vaultPolicyId)), 2); // PAUSED
        vm.prank(vaultOnly);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotKeeperOrOwner.selector, vaultOnly));
        guard.trip(poolPolicyId, "vault-only keeper cannot trip the pool");
    }
}
