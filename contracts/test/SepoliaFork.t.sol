// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Fork tests against live Arbitrum Sepolia state.
///
/// Forks the latest Sepolia block via the public RPC, deploys the full
/// fixture on top of it, and proves both attacks are blocked on the
/// guarded contracts using live-chain block numbers and timestamps.
/// The outflow window keys on `block.number` and the breaker on
/// `block.timestamp`, so running on a real Sepolia fork (rather than a
/// fresh local chain) exercises the exact values the contracts will
/// see in production.
///
/// NOTE — Arbitrum `block.number` semantics (verified live 2026-11-10):
/// inside a contract, `block.number` returns the L1 block number, not
/// the L2 number (L2 is only via ArbSys.arbBlockNumber()). Consequence
/// for ArbGuard: the per-block outflow window is really a per-L1-block
/// window (~12s on Arbitrum, ~48 L2 blocks), which is TIGHTER than a
/// per-L2-block window would be (the cap binds over 12s, not 250ms).
/// The design is sound as-is; docs should say "per L1 block" honestly
/// rather than "per block". No contract change needed.
///
/// Run:  forge test --match-contract SepoliaForkTest -vv
/// RPC responses are cached by forge in ~/.foundry/cache, so re-runs
/// are cheap. No Alchemy key needed — the public Sepolia RPC is used
/// (the Alchemy connector has no Sepolia host registered).
contract SepoliaForkTest is Fixture {
    string internal constant SEPOLIA_RPC = "https://sepolia-rollup.arbitrum.io/rpc";

    function setUp() public override {
        vm.createSelectFork(SEPOLIA_RPC);
        super.setUp();
    }

    function test_Fork_IsLiveSepoliaState() public view {
        assertEq(block.chainid, 421614);
        // Arbitrum semantics, verified live 2026-11-10 (see ForkDiag run):
        // `block.number` inside a contract returns the L1 block number
        // (~12.1M on Sepolia), while the L2 block number (~327.7M) is
        // only available via ArbSys.arbBlockNumber(). Both are asserted
        // so a fork on the wrong chain (or a local chain) fails loudly.
        assertGt(block.number, 12_000_000); // L1 Sepolia height
        (bool ok, bytes memory ret) =
            address(0x0000000000000000000000000000000000000064).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        require(ok, "arbBlockNumber call failed");
        assertGt(abi.decode(ret, (uint256)), 327_000_000); // L2 Sepolia height
        assertGt(block.timestamp, 0);
    }

    function test_Fork_Drain_RevertsOnGuardedVault() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        attacker.drainVault(guardedVault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(guardedVault)), 1000 ether);
    }

    function test_Fork_Drain_SucceedsOnUnguardedVault() public {
        attacker.drainVault(unguardedVault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(unguardedVault)), 1000 ether);
        assertEq(asset.balanceOf(address(attacker)), 10_000 ether);
    }

    function test_Fork_PricePush_RevertsOnGuardedPool() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.PRICE_DEVIATION));
        attacker.pushPriceAndSwap(guardedPool, address(asset), 1000 ether);
        assertEq(guardedPool.reserve0(), 1000 ether);
        assertEq(guardedPool.reserve1(), 1000 ether);
    }

    function test_Fork_PricePush_SucceedsOnUnguardedPool() public {
        uint256 out = attacker.pushPriceAndSwap(unguardedPool, address(asset), 1000 ether);
        assertEq(out, 500 ether);
        assertEq(unguardedPool.reserve0(), 2000 ether);
        assertEq(unguardedPool.reserve1(), 500 ether);
    }

    function test_Fork_NormalWithdraw_PassesOnGuardedVault() public {
        vm.prank(victim);
        guardedVault.withdraw(50 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 950 ether);
    }

    function test_Fork_BreakerTrip_BlocksAndAutoResumes() public {
        // Keeper trips the breaker: guarded withdraws revert while paused.
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "fork test: suspected drain");
        assertGt(guard.pausedUntil(vaultPolicyId), block.timestamp);

        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guardedVault.withdraw(10 ether);

        // reset() before the cooldown ends reverts.
        uint256 until = guard.pausedUntil(vaultPolicyId);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.BreakerStillActive.selector, until));
        guard.reset(vaultPolicyId);

        // Warp past the 1h cooldown: auto-resume with no reset call.
        vm.warp(block.timestamp + 3601);
        vm.prank(victim);
        guardedVault.withdraw(10 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 990 ether);
    }
}
