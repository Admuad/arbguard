// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, PriceConfig, IArbGuard} from "../src/ArbGuard.sol";
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
///
/// Oracle config (verified live 19 Nov 2026, see docs/PHASE1-SPEC.md §1.1):
/// ETH/USD 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 (8 dec),
/// USDC/USD 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3 (8 dec),
/// WETH/USDC 0.05% pool 0xC6962004f452bE9203591991D15f6b388e09E8D0,
/// L2 sequencer uptime 0xFdB631F5EE196F0ed6FAa767959853A9F217697D.
///
/// NOTE — no oracle config is registered in this script. The demo pool
/// holds MOCK tokens (priced 1:1 in the demo), not the real WETH/USDC, so
/// the real feeds would misprice them (ETH/USD ~$1,735 vs the demo's 1.0)
/// and every demo swap would revert PRICE_DEVIATION. Oracle wiring is
/// proven in the fork tests (ArbitrumOneFork.t.sol) against the REAL
/// tokens, and a real deployment registers these feeds for the real
/// tokens. The sequencer feed IS wired (it is token-independent).
/// The addresses above are recorded here so the deployer can register
/// them with one setOracleConfig call per real token when the pool holds
/// real tokens.
contract DeployMainnet is Script {
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant WETH_USDC_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

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
            sequencerFeed: SEQUENCER_FEED
        });
        uint256 vaultPolicyId = guard.registerPolicy(address(guardedVault), vaultPolicy, priceConfig);
        uint256 poolPolicyId = guard.registerPolicy(address(guardedPool), poolPolicy, priceConfig);
        guard.addKeeper(vaultPolicyId, keeper);
        guard.addKeeper(poolPolicyId, keeper);

        // No oracle config is registered for the mock tokens (see header
        // note). The sequencer feed is wired via PriceConfig above.

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
