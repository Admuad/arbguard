// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Health-factor rule tests (spec §5.1): the guard-level rule only
/// — the adapter's projection math is covered by AaveAdapter.t.sol and the
/// fork test. The guard trusts the projected `healthFactorAfter` the caller
/// passes; these tests pin the rule's thresholds and applicability.
contract HealthFactorTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D1000 + _freshId));
    }

    /// @notice Fresh policy with generous caps (outflow/share never bind)
    /// and the given health-factor floor. Drain off.
    function _policyWithHF(uint16 minHF) internal returns (uint256 pid, address protocol) {
        protocol = _freshProtocol();
        Policy memory p = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxOutflowPerHour: 0,
            maxOutflowPerDay: 0,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: minHF,
            maxReserveDrainBps: 0
        });
        pid = guard.registerPolicy(protocol, p, priceConfig());
        guard.addKeeper(pid, keeper);
    }

    function _borrow(uint256 hfAfter) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.BORROW,
            token: address(0),
            tokenIn: address(0),
            amountOut: 10 ether,
            amountIn: 0,
            price: 0,
            tvl: 1000 ether,
            healthFactorAfter: hfAfter,
            availableLiquidity: 1000 ether
        });
    }

    function _withdraw(uint256 hfAfter) internal pure returns (Action memory) {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: address(0),
            tokenIn: address(0),
            amountOut: 10 ether,
            amountIn: 0,
            price: 0,
            tvl: 1000 ether,
            healthFactorAfter: hfAfter,
            availableLiquidity: 1000 ether
        });
    }

    function _swapWithHF(uint256 hfAfter) internal view returns (Action memory) {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1 ether,
            tvl: 1000 ether,
            healthFactorAfter: hfAfter,
            availableLiquidity: 1000 ether
        });
    }

    /// @notice Lock-step assertion: simulateCheck and check() agree.
    function _runCase(string memory name, address protocol, Action memory action, bool expectedOk, Reason expectedReason)
        internal
    {
        (bool ok, Reason reason) = guard.simulateCheck(protocol, action);
        assertEq(ok, expectedOk, string.concat(name, ": simulateCheck ok"));
        assertEq(uint8(reason), uint8(expectedReason), string.concat(name, ": simulateCheck reason"));
        if (expectedOk) {
            vm.prank(protocol);
            guard.check(protocol, action);
        } else {
            vm.prank(protocol);
            vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, expectedReason));
            guard.check(protocol, action);
        }
    }

    function test_HF_BelowFloor_Reverts() public {
        (, address p) = _policyWithHF(12500); // floor 1.25x
        // HF 1.236x < 1.25x floor.
        _runCase("hf-below-floor", p, _borrow(1236e15), false, Reason.HEALTH_FACTOR);
    }

    function test_HF_ExactlyAtFloor_Passes() public {
        (, address p) = _policyWithHF(12500);
        // HF exactly 1.25x == floor: the rule is `< floor`, so equality passes.
        _runCase("hf-at-floor", p, _borrow(12500e14), true, Reason.NONE);
    }

    function test_HF_AboveFloor_Passes() public {
        (, address p) = _policyWithHF(12500);
        // HF 1.254x > 1.25x floor (the spec §1.3 worked example: 67 WETH borrow).
        _runCase("hf-above-floor", p, _borrow(1254e15), true, Reason.NONE);
    }

    function test_HF_Infinite_Passes() public {
        (, address p) = _policyWithHF(12500);
        // No debt after the action: infinite health factor.
        _runCase("hf-infinite", p, _borrow(type(uint256).max), true, Reason.NONE);
    }

    function test_HF_ZeroWithDebt_Reverts() public {
        (, address p) = _policyWithHF(12500);
        // Collateral fully withdrawn while debt remains: HF 0.
        _runCase("hf-zero", p, _borrow(0), false, Reason.HEALTH_FACTOR);
    }

    function test_HF_RuleOff_NeverFires() public {
        (, address p) = _policyWithHF(0); // rule off
        _runCase("hf-off-terrible", p, _borrow(0), true, Reason.NONE);
        _runCase("hf-off-zero", p, _withdraw(0), true, Reason.NONE);
    }

    function test_HF_WithdrawBelowFloor_Reverts() public {
        (, address p) = _policyWithHF(12500);
        _runCase("hf-withdraw-below", p, _withdraw(1100e15), false, Reason.HEALTH_FACTOR);
    }

    function test_HF_WithdrawAboveFloor_Passes() public {
        (, address p) = _policyWithHF(12500);
        _runCase("hf-withdraw-above", p, _withdraw(1500e15), true, Reason.NONE);
    }

    function test_HF_SwapIgnoresHealthFactor() public {
        (, address p) = _policyWithHF(12500);
        // A swap with a terrible healthFactorAfter passes: the rule does
        // not apply to swaps (no oracle is configured, so the price rule
        // is skipped too).
        _runCase("hf-swap-ignored", p, _swapWithHF(0), true, Reason.NONE);
    }

    function test_HF_FloorBelowOne_RevertsAtRegistration() public {
        address protocol = _freshProtocol();
        Policy memory bad = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxOutflowPerHour: 0,
            maxOutflowPerDay: 0,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 9999, // below 1.0x: already liquidatable
            maxReserveDrainBps: 0
        });
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "minHealthFactorBps out of range"));
        guard.registerPolicy(protocol, bad, priceConfig());
    }

    function test_HF_FloorAboveFive_RevertsAtRegistration() public {
        address protocol = _freshProtocol();
        Policy memory bad = Policy({
            maxOutflowPerBlock: 10_000 ether,
            maxOutflowPerHour: 0,
            maxOutflowPerDay: 0,
            maxSingleShareBps: 10_000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 50001, // above 5.0x
            maxReserveDrainBps: 0
        });
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "minHealthFactorBps out of range"));
        guard.registerPolicy(protocol, bad, priceConfig());
    }

    function test_HF_FloorBounds_Accepted() public {
        // 10000 (1.0x) and 50000 (5.0x) are the valid edges.
        (, address p1) = _policyWithHF(10000);
        _runCase("hf-floor-1x", p1, _borrow(10000e14), true, Reason.NONE);
        (, address p2) = _policyWithHF(50000);
        _runCase("hf-floor-5x-below", p2, _borrow(49999e14), false, Reason.HEALTH_FACTOR);
    }
}
