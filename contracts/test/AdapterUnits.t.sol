// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig, OracleConfig, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {AdapterError} from "../src/AaveAdapter.sol";
import {AdapterPolicyHelper} from "../script/DeployAdapters.s.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3, MockUniswapV3Pool} from "./Mocks.sol";

/// @notice External wrapper so the adapter-policy helper (an internal
/// library function, inlined at the call site) can be invoked through a
/// real external call — `vm.expectRevert` only catches reverts from
/// sub-calls, not from code inlined into the test contract itself.
/// The wrapper also deploys the guard it registers against, so it is the
/// owner `registerPolicy` requires.
contract AdapterPolicyHelperCaller {
    function deployGuard() external returns (ArbGuard) {
        return new ArbGuard();
    }

    function register(ArbGuard guard, address adapter, Policy memory policy, PriceConfig memory pc)
        external
        returns (uint256)
    {
        return AdapterPolicyHelper.registerAdapterPolicy(guard, adapter, policy, pc);
    }
}

/// @notice Split-unit seam tests (spec §2.2 note, §5.1): for a swap, `price`
/// stays in RAW token units (the price rule compares it against a raw TWAP
/// reference) while `amountOut` / `amountIn` / `tvl` / `availableLiquidity`
/// are USD 1e18 for adapter policies. The adapter owns this split; these
/// tests pin it. The magnitude check (a raw-unit amountOut against a USD
/// policy is off by ~1e12) is asserted in the fork test; here the helper
/// and the price side are pinned.
contract AdapterUnitsTest is Fixture {
    /// @notice The adapter registration helper reverts unless the policy
    /// is USD-denominated.
    function test_AdapterPolicyHelper_RevertsWhenNotUsdDenominated() public {
        Policy memory raw = Policy({
            maxOutflowPerBlock: 100_000 ether,
            maxOutflowPerHour: 1_000_000 ether,
            maxOutflowPerDay: 5_000_000 ether,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false, // wrong for an adapter policy
            minHealthFactorBps: 12500,
            maxReserveDrainBps: 5000
        });
        address adapter = address(0xADA9);
        AdapterPolicyHelperCaller caller = new AdapterPolicyHelperCaller();
        ArbGuard freshGuard = caller.deployGuard();
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "adapter policy must be usdDenominated"));
        caller.register(freshGuard, adapter, raw, priceConfig());
        // And the helper accepts a USD-denominated policy.
        Policy memory usd = raw;
        usd.usdDenominated = true;
        uint256 pid = caller.register(freshGuard, adapter, usd, priceConfig());
        assertEq(freshGuard.getProtocol(pid), adapter);
    }

    /// @notice A USD `price` fails the price comparison: the reference is
    /// raw (1.0 for the mock tokens), so a USD-denominated price (e.g.
    /// $1,671 for WETH/USDC) deviates by orders of magnitude and reverts
    /// PRICE_DEVIATION, while the raw price passes.
    function test_SplitUnit_UsdPrice_FailsPriceComparison() public {
        // The fixture pool policy has mock oracles with reference 1.0.
        Action memory rawPrice = Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1 ether, // raw: 1 token1 per token0
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 1000 ether
        });
        vm.prank(address(guardedPool));
        guard.check(address(guardedPool), rawPrice);

        Action memory usdPrice = Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1671 ether, // USD price, NOT raw: deviates ~167100% from ref 1.0
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 1000 ether
        });
        vm.prank(address(guardedPool));
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.PRICE_DEVIATION));
        guard.check(address(guardedPool), usdPrice);
        // simulateCheck agrees.
        (bool ok, Reason reason) = guard.simulateCheck(address(guardedPool), usdPrice);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.PRICE_DEVIATION));
    }

    /// @notice Demo (non-adapter) policies keep raw units and still pass:
    /// the fixture's raw-unit vault/pool policies are unchanged by Phase 2
    /// (their new fields are 0 / false) and a normal demo withdrawal passes.
    function test_SplitUnit_DemoPolicies_KeepRawUnits() public {
        Policy memory vault = guard.getPolicy(vaultPolicyId);
        assertFalse(vault.usdDenominated);
        assertEq(vault.minHealthFactorBps, 0);
        assertEq(vault.maxReserveDrainBps, 0);
        vm.prank(victim);
        guardedVault.withdraw(10 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 990 ether);
    }

    /// @notice The helper's demo defaults carry the spec values: HF floor
    /// 1.25x, drain cap 50%, USD-denominated.
    function test_AdapterPolicyHelper_DemoDefaults() public {
        Policy memory p =
            AdapterPolicyHelper.adapterPolicy(200_000 ether, 1_000_000 ether, 5_000_000 ether, 10_000);
        assertTrue(p.usdDenominated);
        assertEq(p.minHealthFactorBps, 12500);
        assertEq(p.maxReserveDrainBps, 5000);
        assertEq(p.maxOutflowPerBlock, 200_000 ether);
        assertEq(p.throttleBps, 1000);
        PriceConfig memory pc = AdapterPolicyHelper.adapterPriceConfig(address(0));
        assertEq(pc.twapSeconds, 1800);
        assertEq(pc.maxOracleDeviationBps, 200);
        assertEq(pc.sequencerFeed, address(0));
    }
}
