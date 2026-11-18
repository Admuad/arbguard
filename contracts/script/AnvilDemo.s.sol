// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";
import {Attacker} from "../src/Attacker.sol";

/// @notice Local Anvil demo: the same drain + price-push attacks against the
/// guarded and unguarded deployments, in one scripted run.
///
/// Run (from contracts/):
///   anvil --port 8545 > /tmp/anvil.log 2>&1 &
///   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///     forge script script/AnvilDemo.s.sol:AnvilDemo --rpc-url http://127.0.0.1:8545 --broadcast
///   pkill -f "anvil --port 8545"
///
/// The deployer key above is Anvil's well-known default account #0 — local
/// only, never a real key. No public chain, no real funds.
contract AnvilDemo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        ArbGuard guard = new ArbGuard();
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH");
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");
        GuardedVault guardedVault = new GuardedVault(weth, guard);
        UnguardedVault unguardedVault = new UnguardedVault(weth);
        GuardedPool guardedPool = new GuardedPool(weth, usdc, guard);
        GuardedPool unguardedPool = new GuardedPool(weth, usdc, IArbGuard(address(0)));
        Attacker attacker = new Attacker();

        Policy memory vaultPolicy = Policy({
            maxOutflowPerBlock: 100 ether,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: deployer,
            enabled: true
        });
        Policy memory poolPolicy = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: deployer,
            enabled: true
        });
        guard.registerPolicy(address(guardedVault), vaultPolicy);
        guard.registerPolicy(address(guardedPool), poolPolicy);

        // Seed both vaults with 1000 mWETH and both pools with 1000/1000.
        weth.mint(deployer, 20_000 ether);
        usdc.mint(deployer, 20_000 ether);
        weth.approve(address(guardedVault), 1000 ether);
        weth.approve(address(unguardedVault), 1000 ether);
        weth.approve(address(guardedPool), 1000 ether);
        weth.approve(address(unguardedPool), 1000 ether);
        usdc.approve(address(guardedPool), 1000 ether);
        usdc.approve(address(unguardedPool), 1000 ether);
        guardedVault.deposit(1000 ether);
        unguardedVault.deposit(1000 ether);
        guardedPool.addLiquidity(1000 ether, 1000 ether);
        unguardedPool.addLiquidity(1000 ether, 1000 ether);

        // Fund the attacker: 900 mWETH to deposit into each vault + 1000 for the pool push.
        weth.mint(address(attacker), 2900 ether);
        attacker.approve(address(weth), address(guardedVault), 900 ether);
        attacker.approve(address(weth), address(unguardedVault), 900 ether);
        attacker.approve(address(weth), address(guardedPool), 1000 ether);
        attacker.approve(address(weth), address(unguardedPool), 1000 ether);

        console.log("=== ArbGuard Anvil demo ===");
        console.log("ArbGuard:       ", address(guard));
        console.log("GuardedVault:    ", address(guardedVault));
        console.log("UnguardedVault:  ", address(unguardedVault));
        console.log("GuardedPool:     ", address(guardedPool));
        console.log("UnguardedPool:   ", address(unguardedPool));

        // --- Attack 1: drain. Attacker first deposits 900 into each vault
        // (drainVault with 0 iterations = deposit only, separate tx so the
        // guarded revert below does not roll the deposit back).
        attacker.drainVault(guardedVault, 900 ether, 10 ether, 0);
        attacker.drainVault(unguardedVault, 900 ether, 10 ether, 0);
        console.log("--- Attack 1: drain (900 ether in 10-ether chunks, cap 100/block) ---");
        console.log("GuardedVault balance before:  ", weth.balanceOf(address(guardedVault)) / 1 ether, "mWETH");
        console.log("UnguardedVault balance before:", weth.balanceOf(address(unguardedVault)) / 1 ether, "mWETH");

        attacker.drainOnly(unguardedVault, 10 ether, 200);
        console.log(
            "UNGUARDED drain SUCCEEDED. Balance after:", weth.balanceOf(address(unguardedVault)) / 1 ether, "mWETH"
        );

        try attacker.drainOnly(guardedVault, 10 ether, 200) {
            console.log("GUARDED drain SUCCEEDED (UNEXPECTED - guard failed!)");
        } catch (bytes memory reason) {
            console.log("GUARDED drain REVERTED as expected. Revert data:");
            console.logBytes(reason);
        }
        console.log(
            "GuardedVault balance after:   ", weth.balanceOf(address(guardedVault)) / 1 ether, "mWETH (unchanged)"
        );

        // --- Attack 2: price push. 1000 mWETH into a 1000/1000 pool (~50% move).
        console.log("--- Attack 2: price push (1000 mWETH into 1000/1000 pool) ---");
        uint256 out = attacker.pushPriceAndSwap(unguardedPool, address(weth), 1000 ether);
        console.log("UNGUARDED swap SUCCEEDED. Received:", out / 1 ether, "mUSDC");
        (uint256 r0, uint256 r1) = (unguardedPool.reserve0(), unguardedPool.reserve1());
        console.log("UnguardedPool reserves after (mWETH):", r0 / 1 ether);
        console.log("UnguardedPool reserves after (mUSDC):", r1 / 1 ether);

        try attacker.pushPriceAndSwap(guardedPool, address(weth), 1000 ether) returns (uint256 outG) {
            console.log("GUARDED swap SUCCEEDED (UNEXPECTED - guard failed!). Received:", outG / 1 ether);
        } catch (bytes memory reason) {
            console.log("GUARDED swap REVERTED as expected. Revert data:");
            console.logBytes(reason);
        }
        (r0, r1) = (guardedPool.reserve0(), guardedPool.reserve1());
        console.log("GuardedPool reserves after (mWETH):", r0 / 1 ether);
        console.log("GuardedPool reserves after (mUSDC):", r1 / 1 ether, "(unchanged)");

        vm.stopBroadcast();
        console.log("=== demo complete ===");
    }
}
