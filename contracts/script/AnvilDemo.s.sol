// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig, IArbGuard} from "../src/ArbGuard.sol";
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
    /// @notice Everything the demo deploys, passed between the small
    /// helpers so `run()` never holds a dozen live locals.
    struct Demo {
        ArbGuard guard;
        MockERC20 weth;
        MockERC20 usdc;
        GuardedVault guardedVault;
        UnguardedVault unguardedVault;
        GuardedPool guardedPool;
        GuardedPool unguardedPool;
        Attacker attacker;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        Demo memory d = _deployAndConfigure(deployer);
        _seed(d, deployer);
        _attack1(d);
        _attack2(d);
        vm.stopBroadcast();
        console.log("=== demo complete ===");
    }

    function _deployAndConfigure(address deployer) internal returns (Demo memory d) {
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
            twapSeconds: 1800, maxOracleDeviationBps: 200, chainlinkStaleAfter: 7200, sequencerFeed: address(0)
        });
        d.guard.registerPolicy(address(d.guardedVault), vaultPolicy, priceConfig);
        d.guard.registerPolicy(address(d.guardedPool), poolPolicy, priceConfig);
        d.guard.addKeeper(0, deployer);
        d.guard.addKeeper(1, deployer);

        // Mock oracles for the demo pool (both tokens $1.00, TWAP tick 0,
        // so the reference price is 1.0). Without these the price rule is
        // skipped and the price-push demo would succeed. These mocks live
        // in this script (not src/): they are demo-only, never production.
        DemoFeed wethFeed = new DemoFeed(1e8, 8);
        DemoFeed usdcFeed = new DemoFeed(1e8, 8);
        DemoPool demoPool = new DemoPool(address(d.weth), address(d.usdc));
        d.guard
            .setOracleConfig(
                1,
                address(d.weth),
                OracleConfig({
                    chainlinkFeed: address(wethFeed), uniswapPool: address(demoPool), feedDecimals: 8, tokenDecimals: 18
                })
            );
        d.guard
            .setOracleConfig(
                1,
                address(d.usdc),
                OracleConfig({
                    chainlinkFeed: address(usdcFeed), uniswapPool: address(demoPool), feedDecimals: 8, tokenDecimals: 18
                })
            );

        console.log("=== ArbGuard Anvil demo ===");
        console.log("ArbGuard:       ", address(d.guard));
        console.log("GuardedVault:    ", address(d.guardedVault));
        console.log("UnguardedVault:  ", address(d.unguardedVault));
        console.log("GuardedPool:     ", address(d.guardedPool));
        console.log("UnguardedPool:   ", address(d.unguardedPool));
    }

    function _seed(Demo memory d, address deployer) internal {
        // Seed both vaults with 1000 mWETH and both pools with 1000/1000.
        d.weth.mint(deployer, 20_000 ether);
        d.usdc.mint(deployer, 20_000 ether);
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

        // Fund the attacker: 900 mWETH to deposit into each vault + 1000 for the pool push.
        d.weth.mint(address(d.attacker), 2900 ether);
        d.attacker.approve(address(d.weth), address(d.guardedVault), 900 ether);
        d.attacker.approve(address(d.weth), address(d.unguardedVault), 900 ether);
        d.attacker.approve(address(d.weth), address(d.guardedPool), 1000 ether);
        d.attacker.approve(address(d.weth), address(d.unguardedPool), 1000 ether);
    }

    function _attack1(Demo memory d) internal {
        // Attacker first deposits 900 into each vault (drainVault with 0
        // iterations = deposit only, separate tx so the guarded revert
        // below does not roll the deposit back).
        d.attacker.drainVault(d.guardedVault, 900 ether, 10 ether, 0);
        d.attacker.drainVault(d.unguardedVault, 900 ether, 10 ether, 0);
        console.log("--- Attack 1: drain (900 ether in 10-ether chunks, cap 100/block) ---");
        console.log("GuardedVault balance before:  ", d.weth.balanceOf(address(d.guardedVault)) / 1 ether, "mWETH");
        console.log("UnguardedVault balance before:", d.weth.balanceOf(address(d.unguardedVault)) / 1 ether, "mWETH");

        d.attacker.drainOnly(d.unguardedVault, 10 ether, 200);
        console.log(
            "UNGUARDED drain SUCCEEDED. Balance after:", d.weth.balanceOf(address(d.unguardedVault)) / 1 ether, "mWETH"
        );

        try d.attacker.drainOnly(d.guardedVault, 10 ether, 200) {
            console.log("GUARDED drain SUCCEEDED (UNEXPECTED - guard failed!)");
        } catch (bytes memory reason) {
            console.log("GUARDED drain REVERTED as expected. Revert data:");
            console.logBytes(reason);
        }
        console.log(
            "GuardedVault balance after:   ", d.weth.balanceOf(address(d.guardedVault)) / 1 ether, "mWETH (unchanged)"
        );
    }

    function _attack2(Demo memory d) internal {
        // 1000 mWETH into a 1000/1000 pool (~50% move).
        console.log("--- Attack 2: price push (1000 mWETH into 1000/1000 pool) ---");
        uint256 out = d.attacker.pushPriceAndSwap(d.unguardedPool, address(d.weth), 1000 ether);
        console.log("UNGUARDED swap SUCCEEDED. Received:", out / 1 ether, "mUSDC");
        (uint256 r0, uint256 r1) = (d.unguardedPool.reserve0(), d.unguardedPool.reserve1());
        console.log("UnguardedPool reserves after (mWETH):", r0 / 1 ether);
        console.log("UnguardedPool reserves after (mUSDC):", r1 / 1 ether);

        try d.attacker.pushPriceAndSwap(d.guardedPool, address(d.weth), 1000 ether) returns (uint256 outG) {
            console.log("GUARDED swap SUCCEEDED (UNEXPECTED - guard failed!). Received:", outG / 1 ether);
        } catch (bytes memory reason) {
            console.log("GUARDED swap REVERTED as expected. Revert data:");
            console.logBytes(reason);
        }
        (r0, r1) = (d.guardedPool.reserve0(), d.guardedPool.reserve1());
        console.log("GuardedPool reserves after (mWETH):", r0 / 1 ether);
        console.log("GuardedPool reserves after (mUSDC):", r1 / 1 ether, "(unchanged)");
    }
}

/// @notice Demo-only mock Chainlink feed (fixed $1.00 answer, fresh).
/// Lives in this script, not src/: demo-only, never production.
contract DemoFeed {
    int256 public answer;
    uint8 public decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Demo-only mock Uniswap V3 pool (constant TWAP tick 0, i.e. a
/// 1.0 reference price). Lives in this script, not src/: demo-only.
contract DemoPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 0; // TWAP tick 0 for any window
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }
}
