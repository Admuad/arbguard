// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {Fixture} from "./Fixture.t.sol";

contract AttackBlockedTest is Fixture {
    function test_Drain_SucceedsOnUnguardedVault() public {
        // Attacker bursts 900 out of the unguarded vault in ONE tx
        // (10 x 90). Vault drops from 1,000 (victim) + 900 (attacker) to 1,000.
        attacker.drainVault(unguardedVault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(unguardedVault)), 1000 ether);
        assertEq(asset.balanceOf(address(attacker)), 10_000 ether); // got its 900 back
        assertEq(unguardedVault.shares(address(attacker)), 0);
    }

    function test_Drain_RevertsOnGuardedVault() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        attacker.drainVault(guardedVault, 900 ether, 90 ether, 20);
        // Atomic revert: the whole tx (deposit included) rolls back.
        assertEq(asset.balanceOf(address(guardedVault)), 1000 ether);
        assertEq(guardedVault.shares(address(attacker)), 0);
        assertEq(asset.balanceOf(address(attacker)), 10_000 ether);
    }

    function test_Drain_RevertsEvenWithTinyChunks() public {
        // 1-ether chunks are far under the single-share limit, but the
        // per-block window still accumulates: 101 x 1 ether > 100 cap.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        attacker.drainVault(guardedVault, 500 ether, 1 ether, 200);
        assertEq(asset.balanceOf(address(guardedVault)), 1000 ether);
    }

    function test_NormalWithdraw_PassesOnGuardedVault() public {
        vm.prank(victim);
        guardedVault.withdraw(50 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 950 ether);
        // Victim started with 10,000, seeded 4,000 across vaults/pools.
        assertEq(asset.balanceOf(victim), 6050 ether);
    }

    function test_SingleShare_RevertsOnGuardedVault() public {
        // Separate vault with a huge outflow cap so the share rule is the
        // first failure: withdrawing 500 of 1,900 tvl (26%) > 10% cap.
        GuardedVault vault = new GuardedVault(asset, guard);
        Policy memory policy = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxSingleShareBps: 1000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
        guard.registerPolicy(address(vault), policy);
        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1900 ether);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.SINGLE_SHARE));
        vault.withdraw(500 ether);
        vm.stopPrank();
        assertEq(asset.balanceOf(address(vault)), 1900 ether);
    }

    function test_PricePush_SucceedsOnUnguardedPool() public {
        // 1,000 token0 into a 1,000/1,000 pool moves the execution price
        // to 0.5 (50% away from the 1.0 reference). Unguarded: succeeds.
        uint256 out = attacker.pushPriceAndSwap(unguardedPool, address(asset), 1000 ether);
        assertEq(out, 500 ether);
        assertEq(unguardedPool.reserve0(), 2000 ether);
        assertEq(unguardedPool.reserve1(), 500 ether);
    }

    function test_PricePush_RevertsOnGuardedPool() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.PRICE_DEVIATION));
        attacker.pushPriceAndSwap(guardedPool, address(asset), 1000 ether);
        // Atomic revert: reserves unchanged.
        assertEq(guardedPool.reserve0(), 1000 ether);
        assertEq(guardedPool.reserve1(), 1000 ether);
        assertEq(asset.balanceOf(address(attacker)), 10_000 ether);
    }

    function test_NormalSwap_PassesOnGuardedPool() public {
        // Small swap: ~1% price move, inside the 5% deviation cap.
        vm.prank(victim);
        uint256 out = guardedPool.swap(address(asset), 10 ether, 0);
        assertGt(out, 9 ether);
        assertEq(guardedPool.reserve0(), 1010 ether);
        assertEq(guardedPool.reserve1(), 1000 ether - out);
    }

    function test_SimulateCheck_PredictsBlockedSwap() public {
        // The simulator sees the price-push coming before any tx is sent.
        (bool ok, Reason reason) = guard.simulateCheck(
            address(guardedPool), _swapAction(1000 ether, 500 ether, 0.5 ether, 1 ether, 1000 ether)
        );
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.PRICE_DEVIATION));
    }

    function _swapAction(uint256 amountIn, uint256 amountOut, uint256 price, uint256 twap, uint256 tvl)
        internal
        view
        returns (Action memory)
    {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            amountOut: amountOut,
            amountIn: amountIn,
            price: price,
            twapPrice: twap,
            tvl: tvl
        });
    }
}
