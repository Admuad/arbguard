// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, Action, ActionKind, Reason} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Reserve-drain rule tests (spec §5.1): the guard-level rule only.
/// The adapter's available-liquidity read is covered by AaveAdapter.t.sol
/// and the fork test.
contract ReserveDrainTest is Fixture {
    uint256 internal _freshId;

    function _freshProtocol() internal returns (address) {
        _freshId++;
        return address(uint160(0xF00D2000 + _freshId));
    }

    /// @notice Fresh policy with generous outflow/share caps and the given
    /// drain cap (bps of available liquidity). HF off.
    function _policyWithDrain(uint16 drainBps) internal returns (uint256 pid, address protocol) {
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
            minHealthFactorBps: 0,
            maxReserveDrainBps: drainBps
        });
        pid = guard.registerPolicy(protocol, p, priceConfig());
        guard.addKeeper(pid, keeper);
    }

    function _action(ActionKind kind, uint256 amountOut, uint256 available) internal pure returns (Action memory) {
        return Action({
            kind: kind,
            token: address(0),
            tokenIn: address(0),
            amountOut: amountOut,
            amountIn: 0,
            price: 0,
            tvl: 100_000 ether,
            healthFactorAfter: type(uint256).max,
            availableLiquidity: available
        });
    }

    function _swap(uint256 amountOut, uint256 available) internal view returns (Action memory) {
        return Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: amountOut,
            amountIn: amountOut,
            price: 1 ether,
            tvl: 100_000 ether,
            healthFactorAfter: 0,
            availableLiquidity: available
        });
    }

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

    function test_Drain_FortyNinePercent_Passes() public {
        (, address p) = _policyWithDrain(5000); // 50% cap
        // 49% of available passes (the spec §1.4 USDC case: 5,000 of ~10,174).
        _runCase("drain-49pct", p, _action(ActionKind.BORROW, 4900 ether, 10000 ether), true, Reason.NONE);
    }

    function test_Drain_FiftyOnePercent_Reverts() public {
        (, address p) = _policyWithDrain(5000);
        // 51% of available reverts (the spec §1.4 USDC case: 5,100 of ~10,174).
        _runCase("drain-51pct", p, _action(ActionKind.BORROW, 5100 ether, 10000 ether), false, Reason.RESERVE_DRAIN);
    }

    function test_Drain_ExactlyFiftyPercent_Passes() public {
        (, address p) = _policyWithDrain(5000);
        // Exactly 50% == cap: the rule is `>`, so equality passes.
        _runCase("drain-50pct", p, _action(ActionKind.BORROW, 5000 ether, 10000 ether), true, Reason.NONE);
    }

    function test_Drain_RuleOff_NeverFires() public {
        (, address p) = _policyWithDrain(0); // rule off
        _runCase("drain-off", p, _action(ActionKind.BORROW, 10000 ether, 10000 ether), true, Reason.NONE);
    }

    function test_Drain_AppliesToWithdraw() public {
        (, address p) = _policyWithDrain(5000);
        _runCase("drain-withdraw", p, _action(ActionKind.WITHDRAW, 6000 ether, 10000 ether), false, Reason.RESERVE_DRAIN);
    }

    function test_Drain_AppliesToSwap() public {
        (, address p) = _policyWithDrain(5000);
        // A swap taking 60% of the pool's available tokenOut reverts
        // (no oracle configured, so the price rule is skipped and the
        // drain rule is what binds).
        _runCase("drain-swap", p, _swap(6000 ether, 10000 ether), false, Reason.RESERVE_DRAIN);
        _runCase("drain-swap-pass", p, _swap(4000 ether, 10000 ether), true, Reason.NONE);
    }

    function test_Drain_EmptyReserve_PositiveAmount_Reverts() public {
        (, address p) = _policyWithDrain(5000);
        _runCase("drain-empty", p, _action(ActionKind.BORROW, 1 ether, 0), false, Reason.RESERVE_DRAIN);
    }

    function test_Drain_EmptyReserve_ZeroAmount_Passes() public {
        (, address p) = _policyWithDrain(5000);
        _runCase("drain-empty-zero", p, _action(ActionKind.BORROW, 0, 0), true, Reason.NONE);
    }

    function test_Drain_AboveMax_RevertsAtRegistration() public {
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
            minHealthFactorBps: 0,
            maxReserveDrainBps: 10001 // above 10000
        });
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.InvalidPolicy.selector, "maxReserveDrainBps out of range"));
        guard.registerPolicy(protocol, bad, priceConfig());
    }

    function test_Drain_ShareAndDrain_BothActive() public {
        // Single-share (50% of tvl) and drain (50% of available) can both
        // be set; the share rule is evaluated first (rule order §3.3).
        // amountOut 600 vs tvl 1000 = 60% > 50% share -> SINGLE_SHARE,
        // even though 600 vs available 10000 = 6% would pass drain.
        // This needs its own policy: _policyWithDrain sets share to 100%.
        address protocol = _freshProtocol();
        Policy memory pol = Policy({
            maxOutflowPerBlock: 100_000 ether,
            maxOutflowPerHour: 0,
            maxOutflowPerDay: 0,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: false,
            minHealthFactorBps: 0,
            maxReserveDrainBps: 5000
        });
        uint256 pid = guard.registerPolicy(protocol, pol, priceConfig());
        guard.addKeeper(pid, keeper);
        Action memory a = _action(ActionKind.BORROW, 600 ether, 10000 ether);
        a.tvl = 1000 ether;
        _runCase("share-before-drain", protocol, a, false, Reason.SINGLE_SHARE);
    }
}
