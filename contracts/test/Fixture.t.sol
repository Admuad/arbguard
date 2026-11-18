// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbGuard, Policy, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";
import {Attacker} from "../src/Attacker.sol";

/// @notice Shared fixture: ArbGuard + mock tokens + guarded/unguarded
/// vaults and pools, with policies registered and victim/attacker funded.
/// Vault policy: 100 ether/block outflow, 50% single share, 5% deviation,
/// 1h cooldown. Pool policy: 10,000 ether/block outflow, 100% single
/// share, 5% deviation, 1h cooldown.
contract Fixture is Test {
    ArbGuard internal guard;
    MockERC20 internal asset; // mock WETH
    MockERC20 internal token1; // mock USDC
    GuardedVault internal guardedVault;
    UnguardedVault internal unguardedVault;
    GuardedPool internal guardedPool;
    GuardedPool internal unguardedPool;
    Attacker internal attacker;

    address internal keeper = makeAddr("keeper");
    address internal victim = makeAddr("victim");
    address internal stranger = makeAddr("stranger");

    uint256 internal vaultPolicyId;
    uint256 internal poolPolicyId;

    function vaultPolicy() internal view returns (Policy memory) {
        return Policy({
            maxOutflowPerBlock: 100 ether,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
    }

    function poolPolicy() internal view returns (Policy memory) {
        return Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
    }

    function setUp() public virtual {
        guard = new ArbGuard();
        asset = new MockERC20("Mock WETH", "mWETH");
        token1 = new MockERC20("Mock USDC", "mUSDC");
        guardedVault = new GuardedVault(asset, guard);
        unguardedVault = new UnguardedVault(asset);
        guardedPool = new GuardedPool(asset, token1, guard);
        unguardedPool = new GuardedPool(asset, token1, IArbGuard(address(0)));
        attacker = new Attacker();

        vaultPolicyId = guard.registerPolicy(address(guardedVault), vaultPolicy());
        poolPolicyId = guard.registerPolicy(address(guardedPool), poolPolicy());

        asset.mint(victim, 10_000 ether);
        token1.mint(victim, 10_000 ether);
        asset.mint(address(attacker), 10_000 ether);
        token1.mint(address(attacker), 10_000 ether);

        vm.startPrank(victim);
        asset.approve(address(guardedVault), type(uint256).max);
        asset.approve(address(unguardedVault), type(uint256).max);
        asset.approve(address(guardedPool), type(uint256).max);
        asset.approve(address(unguardedPool), type(uint256).max);
        token1.approve(address(guardedPool), type(uint256).max);
        token1.approve(address(unguardedPool), type(uint256).max);
        vm.stopPrank();

        attacker.approve(address(asset), address(guardedVault), type(uint256).max);
        attacker.approve(address(asset), address(unguardedVault), type(uint256).max);
        attacker.approve(address(asset), address(guardedPool), type(uint256).max);
        attacker.approve(address(asset), address(unguardedPool), type(uint256).max);
        attacker.approve(address(token1), address(guardedPool), type(uint256).max);
        attacker.approve(address(token1), address(unguardedPool), type(uint256).max);

        // Victim seeds both vaults (1,000 each) and both pools (1,000/1,000).
        vm.startPrank(victim);
        guardedVault.deposit(1000 ether);
        unguardedVault.deposit(1000 ether);
        guardedPool.addLiquidity(1000 ether, 1000 ether);
        unguardedPool.addLiquidity(1000 ether, 1000 ether);
        vm.stopPrank();
    }
}
