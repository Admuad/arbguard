// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";
import {Attacker} from "../src/Attacker.sol";

/// @notice Deploy ArbGuard + demo victims to Arbitrum Sepolia.
///
/// DO NOT RUN without a funded deployer key. Requires env:
///   PRIVATE_KEY   deployer's private key (never commit it)
///   KEEPER        (optional) keeper address; defaults to the deployer
///   ARBISCAN_API_KEY (only for --verify)
///
/// Run:
///   cd contracts
///   source .env            # sets PRIVATE_KEY (and optionally KEEPER)
///   forge script script/DeploySepolia.s.sol:DeploySepolia \
///     --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
///     --broadcast --verify \
///     --etherscan-api-key $ARBISCAN_API_KEY
///
/// The script deploys, registers both policies, and seeds demo liquidity.
/// It mints mock tokens to the deployer for the demo only, and deploys +
/// funds the Attacker demo helper (900 mWETH deposited into each vault,
/// 1000 mWETH approved for the pool push) so the frontend simulator's
/// live path works on Sepolia without a second setup step.
///
/// SEPOLIA ORACLE NOTE (Phase 1): the real Sepolia ETH/USD Chainlink feed
/// (0xbF13EE58Bf62500FE87e7389faB633ff95dec029) is STALE — its last update
/// is 16 Oct 2024, ~2 years old; Chainlink does not maintain testnet Data
/// Feeds. There is no USDC/USD feed and no verified sequencer feed on
/// Sepolia. This script therefore registers the real stale ETH/USD feed
/// for the pool (so the staleness guard is demonstrably live: a swap
/// check against it fails closed with ORACLE_UNAVAILABLE unless a TWAP
/// is also configured) and sets sequencerFeed to address(0). Fresh-price
/// swap demos on Sepolia use the mock-oracle route in the fork tests, not
/// the stale live feed. See docs/PHASE1-SPEC.md §1.1 and §6 Q1/Q2.
contract DeploySepolia is Script {
    // Real Sepolia Chainlink ETH/USD proxy (STALE, see header note).
    address internal constant SEPOLIA_ETH_USD = 0xbF13EE58Bf62500FE87e7389faB633ff95dec029;

    /// @notice Everything the deploy creates, passed between the small
    /// helpers so `run()` never holds a dozen live locals.
    struct Deployment {
        ArbGuard guard;
        MockERC20 weth;
        MockERC20 usdc;
        GuardedVault guardedVault;
        UnguardedVault unguardedVault;
        GuardedPool guardedPool;
        GuardedPool unguardedPool;
        Attacker attacker;
        uint256 vaultPolicyId;
        uint256 poolPolicyId;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envOr("KEEPER", deployer);

        vm.startBroadcast(deployerKey);
        Deployment memory d = _deployAndConfigure(keeper);
        _seed(d, deployer);
        vm.stopBroadcast();

        console.log("ArbGuard:        ", address(d.guard));
        console.log("mWETH:            ", address(d.weth));
        console.log("mUSDC:            ", address(d.usdc));
        console.log("GuardedVault:     ", address(d.guardedVault), " policyId: ", d.vaultPolicyId);
        console.log("UnguardedVault:   ", address(d.unguardedVault));
        console.log("GuardedPool:      ", address(d.guardedPool), " policyId: ", d.poolPolicyId);
        console.log("UnguardedPool:    ", address(d.unguardedPool));
        console.log("Attacker:         ", address(d.attacker));
        console.log("Keeper:           ", keeper);
        console.log("SEPOLIA ORACLE: real ETH/USD feed is STALE (last update 16 Oct 2024);");
        console.log("swap checks against it fail closed with ORACLE_UNAVAILABLE (by design).");
        console.log("No USDC/USD feed and no sequencer feed exist on Sepolia.");
    }

    function _deployAndConfigure(address keeper) internal returns (Deployment memory d) {
        d.guard = new ArbGuard();
        d.weth = new MockERC20("Mock WETH", "mWETH");
        d.usdc = new MockERC20("Mock USDC", "mUSDC");

        d.guardedVault = new GuardedVault(d.weth, d.guard);
        d.unguardedVault = new UnguardedVault(d.weth);
        d.guardedPool = new GuardedPool(d.weth, d.usdc, d.guard);
        d.unguardedPool = new GuardedPool(d.weth, d.usdc, IArbGuard(address(0)));
        d.attacker = new Attacker();

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
            sequencerFeed: address(0) // no verified Sepolia sequencer feed
        });
        d.vaultPolicyId = d.guard.registerPolicy(address(d.guardedVault), vaultPolicy, priceConfig);
        d.poolPolicyId = d.guard.registerPolicy(address(d.guardedPool), poolPolicy, priceConfig);
        d.guard.addKeeper(d.vaultPolicyId, keeper);
        d.guard.addKeeper(d.poolPolicyId, keeper);

        // Oracle config for the pool: the real (stale) Sepolia ETH/USD feed
        // on the mock WETH token. Mock tokens are 18 decimals; the feed has
        // 8 decimals. No USDC feed exists on Sepolia, so the mock USDC gets
        // no Chainlink feed and the pair is incomplete: a swap's Chainlink
        // leg cannot form, and with no TWAP pool either the price rule is
        // skipped for Sepolia demo swaps (the honest Sepolia state).
        // The staleness guard itself is proven in SepoliaFork.t.sol, where
        // a mock USDC feed completes the pair and the real stale ETH feed
        // forces ORACLE_UNAVAILABLE.
        d.guard.setOracleConfig(
            d.poolPolicyId,
            address(d.weth),
            OracleConfig({
                chainlinkFeed: SEPOLIA_ETH_USD,
                uniswapPool: address(0),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
    }

    function _seed(Deployment memory d, address deployer) internal {
        // Demo seed: deployer funds both vaults and both pools.
        d.weth.mint(deployer, 10_000 ether);
        d.usdc.mint(deployer, 10_000 ether);
        d.weth.approve(address(d.guardedVault), 1000 ether);
        d.weth.approve(address(d.unguardedVault), 1000 ether);
        d.weth.approve(address(d.guardedPool), 1000 ether);
        d.weth.approve(address(d.unguardedPool), 1000 ether);
        d.usdc.approve(address(d.guardedPool), 1000 ether);
        d.usdc.approve(address(d.unguardedPool), 1000 ether);
        d.guardedVault.deposit(1000 ether);
        d.unguardedVault.deposit(1000 ether);
        d.guardedPool.addLiquidity(1000 ether, 1000 ether);
        d.unguardedPool.addLiquidity(1000 ether, 1000 ether);

        // Attacker for the frontend simulator's live path: funded with
        // 900 mWETH deposited into each vault (shares held, drainable via
        // drainOnly) + 1000 mWETH approved for the pool price push.
        // Mirrors contracts/script/AnvilDemo.s.sol. The attacker is a demo
        // helper, not a protocol contract — its address goes in the
        // frontend env config (NEXT_PUBLIC_ATTACKER_ADDRESS) so the
        // simulator can run real attacks on Sepolia.
        d.weth.mint(address(d.attacker), 2900 ether);
        d.attacker.approve(address(d.weth), address(d.guardedVault), 900 ether);
        d.attacker.approve(address(d.weth), address(d.unguardedVault), 900 ether);
        d.attacker.approve(address(d.weth), address(d.guardedPool), 1000 ether);
        d.attacker.approve(address(d.weth), address(d.unguardedPool), 1000 ether);
        d.attacker.drainVault(d.guardedVault, 900 ether, 10 ether, 0);
        d.attacker.drainVault(d.unguardedVault, 900 ether, 10 ether, 0);
    }
}
