// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig, IArbGuard} from "../src/ArbGuard.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {UnguardedVault} from "../src/UnguardedVault.sol";
import {GuardedPool} from "../src/GuardedPool.sol";
import {Attacker} from "../src/Attacker.sol";
import {MockAggregatorV3, MockUniswapV3Pool} from "./Mocks.sol";

/// @notice Shared fixture: ArbGuard + mock tokens + guarded/unguarded
/// vaults and pools, with policies registered and victim/attacker funded.
/// Vault policy: 100 ether/block outflow, 2000 ether/hour, 10000 ether/day,
/// 50% single share, 5% deviation, 1h cooldown, 24h timelock, throttle 10%.
/// Pool policy: 10,000 ether/block outflow, 200000 ether/hour,
/// 1000000 ether/day, 100% single share, 5% deviation, 1h cooldown.
/// Price config: 1800 s TWAP, 200 bps max oracle deviation, 7200 s
/// Chainlink staleness, no sequencer feed (Sepolia has none verified).
/// No oracle configs are registered by default: the demo pool's swaps skip
/// the price rule unless a test registers feeds/a pool (see Oracle.t.sol).
/// The deployer (this test contract) is the owner; the fixture registers
/// the deployer as the first keeper of each policy.
contract Fixture is Test {
    ArbGuard internal guard;
    MockERC20 internal asset; // mock WETH
    MockERC20 internal token1; // mock USDC
    GuardedVault internal guardedVault;
    UnguardedVault internal unguardedVault;
    GuardedPool internal guardedPool;
    GuardedPool internal unguardedPool;
    Attacker internal attacker;

    // Mock oracles for the demo pool (both tokens at $1.00, TWAP tick 0,
    // so the reference price is 1.0). Registered on the pool policy only;
    // the vault does non-swap actions and never reads oracles.
    MockAggregatorV3 internal wethFeed;
    MockAggregatorV3 internal usdcFeed;
    MockUniswapV3Pool internal mockPool;

    address internal keeper = makeAddr("keeper");
    address internal victim = makeAddr("victim");
    address internal stranger = makeAddr("stranger");

    uint256 internal vaultPolicyId;
    uint256 internal poolPolicyId;

    function vaultPolicy() internal view returns (Policy memory) {
        return Policy({
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
    }

    function poolPolicy() internal view returns (Policy memory) {
        return Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxSingleShareBps: 10_000,
            maxOutflowPerHour: 200_000 ether,
            maxOutflowPerDay: 1_000_000 ether,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 0,
            maxReserveDrainBps: 0
        });
    }

    function priceConfig() internal pure returns (PriceConfig memory) {
        return PriceConfig({
            twapSeconds: 1800,
            maxOracleDeviationBps: 200,
            chainlinkStaleAfter: 7200,
            sequencerFeed: address(0)
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

        vaultPolicyId = guard.registerPolicy(address(guardedVault), vaultPolicy(), priceConfig());
        poolPolicyId = guard.registerPolicy(address(guardedPool), poolPolicy(), priceConfig());
        guard.addKeeper(vaultPolicyId, keeper);
        guard.addKeeper(poolPolicyId, keeper);

        // Mock oracles for the pool policy: both tokens $1.00 via Chainlink
        // (8 decimals, fresh), TWAP tick 0 via the mock pool. Reference 1.0.
        wethFeed = new MockAggregatorV3(1e8, block.timestamp, 8);
        usdcFeed = new MockAggregatorV3(1e8, block.timestamp, 8);
        mockPool = new MockUniswapV3Pool(address(asset), address(token1), 0);
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(wethFeed),
                uniswapPool: address(mockPool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            poolPolicyId,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(usdcFeed),
                uniswapPool: address(mockPool),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );

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
