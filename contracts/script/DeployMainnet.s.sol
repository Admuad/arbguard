// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";

/// @notice Deploy ArbGuard + demo victims to Arbitrum One (final week only).
///
/// Same flow as DeploySepolia, pointed at mainnet. Mock tokens only, small
/// value — this is the credibility deployment for judges, not a production
/// launch. DO NOT RUN without the deployer's explicit go-ahead and a funded
/// key. Requires env:
///   PRIVATE_KEY   deployer's private key (never commit it)
///   KEEPER        (optional) keeper address; defaults to the deployer
///   ARBISCAN_API_KEY (only for --verify)
///
/// Run:
///   cd contracts
///   source .env            # sets PRIVATE_KEY (and optionally KEEPER)
///   forge script script/DeployMainnet.s.sol:DeployMainnet \
///     --rpc-url https://arb1.arbitrum.io/rpc \
///     --broadcast --verify \
///     --etherscan-api-key $ARBISCAN_API_KEY
contract DeployMainnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envOr("KEEPER", deployer);

        vm.startBroadcast(deployerKey);

        ArbGuard guard = new ArbGuard();
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH");
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");

        GuardedVault guardedVault = new GuardedVault(weth, guard);
        UnguardedVault unguardedVault = new UnguardedVault(weth);
        GuardedPool guardedPool = new GuardedPool(weth, usdc, guard);
        GuardedPool unguardedPool = new GuardedPool(weth, usdc, IArbGuard(address(0)));

        Policy memory vaultPolicy = Policy({
            maxOutflowPerBlock: 100 ether,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
        Policy memory poolPolicy = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: keeper,
            enabled: true
        });
        uint256 vaultPolicyId = guard.registerPolicy(address(guardedVault), vaultPolicy);
        uint256 poolPolicyId = guard.registerPolicy(address(guardedPool), poolPolicy);

        // Demo seed: deployer funds both vaults and both pools.
        weth.mint(deployer, 10_000 ether);
        usdc.mint(deployer, 10_000 ether);
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

        vm.stopBroadcast();

        console.log("ArbGuard:        ", address(guard));
        console.log("mWETH:            ", address(weth));
        console.log("mUSDC:            ", address(usdc));
        console.log("GuardedVault:     ", address(guardedVault), " policyId: ", vaultPolicyId);
        console.log("UnguardedVault:   ", address(unguardedVault));
        console.log("GuardedPool:      ", address(guardedPool), " policyId: ", poolPolicyId);
        console.log("UnguardedPool:    ", address(unguardedPool));
        console.log("Keeper:           ", keeper);
    }
}
