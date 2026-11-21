// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, PriceConfig, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";
import {Attacker} from "../src/Attacker.sol";

/// @notice Deploy-only variant of AnvilDemo.s.sol for the keeper bot fork
/// test (keeper/test/fork-test.sh). Same deployment, same policies, same
/// seeds — but it does NOT run the attacks. AnvilDemo cannot be broadcast
/// as-is: its guarded drain / price-push calls are separate broadcast
/// transactions that revert on-chain by design, so `forge script
/// --broadcast` fails gas estimation on them. This script deploys and
/// seeds only; the fork test drives the attacks itself with `cast`.
///
/// No oracle configs are registered here: like live Sepolia, the pair is
/// incomplete, so getReferencePrice returns (0, address(0)) and the
/// bot's oracle probe reports "unusable" — the honest state for this
/// deployment. (The mock-oracle route lives in AnvilDemo.s.sol.)
///
/// Run (from contracts/):
///   anvil --port 8546 > /tmp/anvil.log 2>&1 &
///   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///     forge script script/DeployFork.s.sol:DeployFork \
///     --rpc-url http://127.0.0.1:8546 --broadcast
///
/// The key above is Anvil's well-known default account #0 — local only,
/// never a real key. No public chain, no real funds.
contract DeployFork is Script {
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
            maxOutflowPerHour: 2000 ether,
            maxOutflowPerDay: 10000 ether,
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
        Policy memory poolPolicy = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxOutflowPerHour: 200_000 ether,
            maxOutflowPerDay: 1_000_000 ether,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 0,
            maxReserveDrainBps: 0
        });
        PriceConfig memory priceConfig = PriceConfig({
            twapSeconds: 1800,
            maxOracleDeviationBps: 200,
            chainlinkStaleAfter: 7200,
            sequencerFeed: address(0)
        });
        guard.registerPolicy(address(guardedVault), vaultPolicy, priceConfig);
        guard.registerPolicy(address(guardedPool), poolPolicy, priceConfig);
        guard.addKeeper(0, deployer);
        guard.addKeeper(1, deployer);

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

        weth.mint(address(attacker), 2900 ether);
        attacker.approve(address(weth), address(guardedVault), 900 ether);
        attacker.approve(address(weth), address(unguardedVault), 900 ether);
        attacker.approve(address(weth), address(guardedPool), 1000 ether);
        attacker.approve(address(weth), address(unguardedPool), 1000 ether);
        attacker.drainVault(guardedVault, 900 ether, 10 ether, 0);
        attacker.drainVault(unguardedVault, 900 ether, 10 ether, 0);
        vm.stopBroadcast();

        console.log("ArbGuard:       ", address(guard));
        console.log("mWETH:           ", address(weth));
        console.log("mUSDC:           ", address(usdc));
        console.log("GuardedVault:    ", address(guardedVault));
        console.log("UnguardedVault:  ", address(unguardedVault));
        console.log("GuardedPool:     ", address(guardedPool));
        console.log("UnguardedPool:   ", address(unguardedPool));
        console.log("Attacker:        ", address(attacker));
        console.log("=== fork deploy complete ===");
    }
}
