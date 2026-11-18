// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ArbGuard, Policy, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

contract ArbGuardTest is Fixture {
    address internal freshProtocol = address(0xBEEF);

    function _policy() internal view returns (Policy memory) {
        return Policy({
            maxOutflowPerBlock: 100 ether,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
    }

    function _withdrawAction(uint256 amountOut, uint256 tvl) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            twapPrice: 0,
            tvl: tvl
        });
    }

    function test_RegisterPolicy_ReturnsIdAndStoresPolicy() public {
        uint256 id = guard.registerPolicy(freshProtocol, _policy());
        assertEq(id, 2); // 0 = vault, 1 = pool from the fixture
        Policy memory stored = guard.getPolicy(id);
        assertEq(stored.maxOutflowPerBlock, 100 ether);
        assertEq(stored.maxSingleShareBps, 5000);
        assertEq(stored.maxPriceDeviationBps, 500);
        assertEq(stored.cooldownSeconds, 3600);
        assertEq(stored.keeper, keeper);
        assertTrue(stored.enabled);
        assertEq(guard.getPolicyId(freshProtocol), id);
        assertEq(guard.getProtocol(id), freshProtocol);
    }

    function test_RegisterPolicy_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(guard));
        emit ArbGuard.PolicyRegistered(2, freshProtocol, keeper);
        guard.registerPolicy(freshProtocol, _policy());
    }

    function test_RegisterPolicy_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.registerPolicy(freshProtocol, _policy());
    }

    function test_RegisterPolicy_ZeroProtocolReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "protocol is zero address"));
        guard.registerPolicy(address(0), _policy());
    }

    function test_RegisterPolicy_BpsOver10000Reverts() public {
        Policy memory bad = _policy();
        bad.maxSingleShareBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "maxSingleShareBps > 10000"));
        guard.registerPolicy(freshProtocol, bad);

        bad = _policy();
        bad.maxPriceDeviationBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "maxPriceDeviationBps > 10000"));
        guard.registerPolicy(freshProtocol, bad);
    }

    function test_RegisterPolicy_CooldownZeroReverts() public {
        Policy memory bad = _policy();
        bad.cooldownSeconds = 0;
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "cooldownSeconds is zero"));
        guard.registerPolicy(freshProtocol, bad);
    }

    function test_RegisterPolicy_DuplicateProtocolReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.PolicyAlreadyRegistered.selector, address(guardedVault)));
        guard.registerPolicy(address(guardedVault), _policy());
    }

    function test_UpdatePolicy_ChangesLimits() public {
        Policy memory updated = _policy();
        updated.maxOutflowPerBlock = 42 ether;
        updated.maxSingleShareBps = 1000;
        guard.updatePolicy(vaultPolicyId, updated);
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 42 ether);
        assertEq(guard.getPolicy(vaultPolicyId).maxSingleShareBps, 1000);
    }

    function test_UpdatePolicy_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.updatePolicy(vaultPolicyId, _policy());
    }

    function test_UpdatePolicy_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicyId.selector, 999));
        guard.updatePolicy(999, _policy());
    }

    function test_SetEnabled_FalseBlocksCheck() public {
        // Check passes while enabled (prank as the registered protocol).
        vm.prank(address(guardedVault));
        guard.check(address(guardedVault), _withdrawAction(10 ether, 1000 ether));

        guard.setEnabled(vaultPolicyId, false);
        assertFalse(guard.getPolicy(vaultPolicyId).enabled);

        vm.prank(address(guardedVault));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guard.check(address(guardedVault), _withdrawAction(10 ether, 1000 ether));

        // Re-enable and the check passes again.
        guard.setEnabled(vaultPolicyId, true);
        vm.prank(address(guardedVault));
        guard.check(address(guardedVault), _withdrawAction(10 ether, 1000 ether));
    }

    function test_Check_OnlyProtocolMayCall() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NotProtocol.selector, stranger, address(guardedVault)));
        guard.check(address(guardedVault), _withdrawAction(10 ether, 1000 ether));
    }

    function test_Check_UnknownProtocolReverts() public {
        address unknown = address(0xCAFE);
        vm.prank(unknown);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicy.selector, unknown));
        guard.check(unknown, _withdrawAction(10 ether, 1000 ether));
    }

    function test_SimulateCheck_MirrorsCheck() public {
        // Passing action: (true, NONE).
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedVault), _withdrawAction(10 ether, 1000 ether));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.NONE));

        // Single-share breach (90 of 100 tvl = 90% > 50% cap; outflow 90 <= 100 ok).
        (ok, reason) = guard.simulateCheck(address(guardedVault), _withdrawAction(90 ether, 100 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.SINGLE_SHARE));

        // Outflow breach (150 > 100 cap in this block).
        (ok, reason) = guard.simulateCheck(address(guardedVault), _withdrawAction(150 ether, 10_000 ether));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OUTFLOW_PER_BLOCK));

        // Price-deviation breach (swap at half the reference price).
        Action memory swapAction = Action({
            kind: ActionKind.SWAP,
            token: address(0),
            amountOut: 10 ether,
            amountIn: 20 ether,
            price: 0.5 ether,
            twapPrice: 1 ether,
            tvl: 1000 ether
        });
        (ok, reason) = guard.simulateCheck(address(guardedVault), swapAction);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.PRICE_DEVIATION));

        // And the real check reverts with the same reason for the share case.
        vm.prank(address(guardedVault));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.SINGLE_SHARE));
        guard.check(address(guardedVault), _withdrawAction(90 ether, 100 ether));
    }

    function test_SimulateCheck_UnknownProtocolReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownPolicy.selector, freshProtocol));
        guard.simulateCheck(freshProtocol, _withdrawAction(1 ether, 100 ether));
    }
}
