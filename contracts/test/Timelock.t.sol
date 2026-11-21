// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig, PendingUpdate, PendingOracleUpdate} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3} from "./Mocks.sol";

/// @notice Timelock tests (spec §2.1): propose/execute/cancel, early and
/// late execution, double proposals, delay changes applying only to later
/// proposals, setEnabled(false) immediate vs setEnabled(true) timelocked,
/// oracle-config swap timelocked vs initial registration immediate,
/// setPriceConfig timelocked.
contract TimelockTest is Fixture {
    uint256 internal constant DELAY = 86400; // fixture timelock
    uint256 internal constant WINDOW = 604800; // 7-day execution window

    function _updatedPolicy(uint256 blockCap) internal view returns (Policy memory p) {
        p = vaultPolicy();
        p.maxOutflowPerBlock = blockCap;
    }

    function test_ProposeExecute_AppliesPolicyAndPrice() public {
        Policy memory updated = _updatedPolicy(42 ether);
        PriceConfig memory newPrice = priceConfig();
        newPrice.twapSeconds = 3600;
        guard.proposePolicyUpdate(vaultPolicyId, updated, newPrice);
        // Not applied yet.
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 100 ether);
        assertEq(guard.getPriceConfig(vaultPolicyId).twapSeconds, 1800);
        // Early execute reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.TimelockNotElapsed.selector, block.timestamp + DELAY));
        guard.executePolicyUpdate(vaultPolicyId);
        // After the delay it applies (both policy and price config).
        vm.warp(block.timestamp + DELAY);
        guard.executePolicyUpdate(vaultPolicyId);
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 42 ether);
        assertEq(guard.getPriceConfig(vaultPolicyId).twapSeconds, 3600);
        // The pending slot is cleared.
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, 0);
        assertEq(pending.proposedAt, 0);
    }

    function test_Propose_EmitsEvent_AndStoresPending() public {
        Policy memory updated = _updatedPolicy(42 ether);
        vm.expectEmit(true, false, false, true, address(guard));
        emit ArbGuard.PolicyUpdateProposed(vaultPolicyId, block.timestamp + DELAY);
        guard.proposePolicyUpdate(vaultPolicyId, updated, priceConfig());
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, block.timestamp + DELAY);
        assertEq(pending.proposedAt, block.timestamp);
        assertEq(pending.policy.maxOutflowPerBlock, 42 ether);
    }

    function test_DoubleProposal_Reverts() public {
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.PendingUpdateExists.selector, vaultPolicyId));
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(43 ether), priceConfig());
    }

    function test_Cancel_ClearsPending_ExecuteReverts() public {
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        vm.expectEmit(true, false, false, true, address(guard));
        emit ArbGuard.PolicyUpdateCancelled(vaultPolicyId);
        guard.cancelPolicyUpdate(vaultPolicyId);
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, 0);
        // The policy is unchanged.
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 100 ether);
        // Executing after cancel reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NoPendingUpdate.selector, vaultPolicyId));
        guard.executePolicyUpdate(vaultPolicyId);
    }

    function test_Execute_NoPending_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NoPendingUpdate.selector, vaultPolicyId));
        guard.executePolicyUpdate(vaultPolicyId);
    }

    function test_Execute_Late_RevertsProposalExpired() public {
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        uint256 proposedAt = block.timestamp;
        // Warp past the 7-day execution window.
        vm.warp(proposedAt + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ProposalExpired.selector, proposedAt));
        guard.executePolicyUpdate(vaultPolicyId);
        // The policy is unchanged and the proposal is still pending
        // (it must be re-proposed or cancelled).
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 100 ether);
    }

    function test_Execute_AtWindowEnd_Succeeds() public {
        // Executing exactly at proposedAt + 7 days is still inside the
        // window (the check is block.timestamp > proposedAt + WINDOW).
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        vm.warp(block.timestamp + WINDOW);
        guard.executePolicyUpdate(vaultPolicyId);
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 42 ether);
    }

    function test_DelayShortening_AppliesOnlyToLaterProposals() public {
        // Propose a delay shortening (86400 -> 3600). The proposal itself
        // is still gated by the CURRENT delay (86400), not the proposed one.
        Policy memory shorter = vaultPolicy();
        shorter.policyTimelockSeconds = 3600;
        guard.proposePolicyUpdate(vaultPolicyId, shorter, priceConfig());
        // Executing after only the NEW delay (3600) still reverts.
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.TimelockNotElapsed.selector, block.timestamp - 3600 + DELAY));
        guard.executePolicyUpdate(vaultPolicyId);
        // After the CURRENT delay it executes, and the delay is now 3600.
        vm.warp(block.timestamp + (DELAY - 3600));
        guard.executePolicyUpdate(vaultPolicyId);
        assertEq(guard.getPolicy(vaultPolicyId).policyTimelockSeconds, 3600);
        // A LATER proposal is gated by the NEW delay (3600).
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(55 ether), priceConfig());
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, block.timestamp + 3600);
        vm.warp(block.timestamp + 3600);
        guard.executePolicyUpdate(vaultPolicyId);
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 55 ether);
    }

    function test_Propose_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
    }

    function test_Execute_OnlyOwner() public {
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        vm.warp(block.timestamp + DELAY);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.executePolicyUpdate(vaultPolicyId);
    }

    function test_Cancel_OnlyOwner() public {
        guard.proposePolicyUpdate(vaultPolicyId, _updatedPolicy(42 ether), priceConfig());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        guard.cancelPolicyUpdate(vaultPolicyId);
    }

    // ------------------------------------------------------------ setEnabled
    function test_SetEnabled_False_IsImmediate() public {
        guard.setEnabled(vaultPolicyId, false);
        assertFalse(guard.getPolicy(vaultPolicyId).enabled);
        // No pending update is created by disabling.
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, 0);
    }

    function test_SetEnabled_True_IsTimelocked() public {
        guard.setEnabled(vaultPolicyId, false);
        assertFalse(guard.getPolicy(vaultPolicyId).enabled);
        // Re-enable proposes a pending update; still disabled until executed.
        guard.setEnabled(vaultPolicyId, true);
        assertFalse(guard.getPolicy(vaultPolicyId).enabled);
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, block.timestamp + DELAY);
        assertTrue(pending.policy.enabled);
        // Early execute reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.TimelockNotElapsed.selector, block.timestamp + DELAY));
        guard.executePolicyUpdate(vaultPolicyId);
        // After the delay it re-enables.
        vm.warp(block.timestamp + DELAY);
        guard.executePolicyUpdate(vaultPolicyId);
        assertTrue(guard.getPolicy(vaultPolicyId).enabled);
    }

    function test_SetEnabled_True_WhenAlreadyEnabled_IsNoop() public {
        // Re-enabling an already-enabled policy is a harmless no-op that
        // does not create a pending update.
        guard.setEnabled(vaultPolicyId, true);
        assertTrue(guard.getPolicy(vaultPolicyId).enabled);
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.executableAt, 0);
    }

    // ---------------------------------------------------------- setPriceConfig
    function test_SetPriceConfig_IsTimelocked() public {
        PriceConfig memory newPrice = priceConfig();
        newPrice.twapSeconds = 3600;
        newPrice.maxOracleDeviationBps = 500;
        guard.setPriceConfig(vaultPolicyId, newPrice);
        // Not applied yet.
        assertEq(guard.getPriceConfig(vaultPolicyId).twapSeconds, 1800);
        assertEq(guard.getPriceConfig(vaultPolicyId).maxOracleDeviationBps, 200);
        // The policy itself is carried unchanged in the pending update.
        PendingUpdate memory pending = guard.getPendingUpdate(vaultPolicyId);
        assertEq(pending.policy.maxOutflowPerBlock, 100 ether);
        assertEq(pending.price.twapSeconds, 3600);
        vm.warp(block.timestamp + DELAY);
        guard.executePolicyUpdate(vaultPolicyId);
        assertEq(guard.getPriceConfig(vaultPolicyId).twapSeconds, 3600);
        assertEq(guard.getPriceConfig(vaultPolicyId).maxOracleDeviationBps, 500);
        // The policy is unchanged.
        assertEq(guard.getPolicy(vaultPolicyId).maxOutflowPerBlock, 100 ether);
    }

    function test_SetPriceConfig_DoubleProposal_Reverts() public {
        guard.setPriceConfig(vaultPolicyId, priceConfig());
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.PendingUpdateExists.selector, vaultPolicyId));
        guard.setPriceConfig(vaultPolicyId, priceConfig());
    }

    // ---------------------------------------------------------- oracle timelock
    function test_OracleConfig_InitialRegistration_IsImmediate() public {
        // A fresh policy has no oracle config; the first registration
        // applies immediately (no pending update).
        address fresh = address(0xF00D);
        uint256 pid = guard.registerPolicy(fresh, vaultPolicy(), priceConfig());
        MockAggregatorV3 feed = new MockAggregatorV3(1e8, block.timestamp, 8);
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(feed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
        OracleConfig memory stored = guard.getOracleConfig(pid, address(asset));
        assertEq(stored.chainlinkFeed, address(feed));
        PendingOracleUpdate memory pending = guard.getPendingOracleConfig(pid, address(asset));
        assertEq(pending.executableAt, 0);
    }

    function test_OracleConfig_Swap_IsTimelocked() public {
        // The fixture pool policy already has an oracle config for asset.
        // Swapping the feed is timelocked: the old feed stays until the
        // pending update executes. The new feed is $1.50 and the TWAP tick
        // is set to 4055 (~1.5e18) so the two sources agree once the new
        // feed is live (a $2.00 feed would disagree with the tick-0 TWAP).
        MockAggregatorV3 newFeed = new MockAggregatorV3(15e7, block.timestamp, 8);
        mockPool.setTwapTick(4055);
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(newFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
        // Still the old feed.
        OracleConfig memory stored = guard.getOracleConfig(poolPolicyId, address(asset));
        assertEq(stored.chainlinkFeed, address(wethFeed));
        // A pending update is stored.
        PendingOracleUpdate memory pending = guard.getPendingOracleConfig(poolPolicyId, address(asset));
        assertEq(pending.executableAt, block.timestamp + DELAY);
        assertEq(pending.config.chainlinkFeed, address(newFeed));
        // Early execute reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.TimelockNotElapsed.selector, block.timestamp + DELAY));
        guard.executeOracleConfigUpdate(poolPolicyId, address(asset));
        // After the delay the new feed applies, and the reference price
        // moves to $1.50 (newFeed $1.50 vs usdcFeed $1.00).
        vm.warp(block.timestamp + DELAY);
        guard.executeOracleConfigUpdate(poolPolicyId, address(asset));
        stored = guard.getOracleConfig(poolPolicyId, address(asset));
        assertEq(stored.chainlinkFeed, address(newFeed));
        // The warp aged the feeds past chainlinkStaleAfter; refresh them
        // so the reference reads Chainlink.
        newFeed.setUpdatedAt(block.timestamp);
        usdcFeed.setUpdatedAt(block.timestamp);
        (uint256 ref,) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 15e17);
    }

    function test_OracleConfig_DoublePending_Reverts() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(2e8, block.timestamp, 8);
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(newFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
        vm.expectRevert(
            abi.encodeWithSelector(ArbGuard.PendingOracleUpdateExists.selector, poolPolicyId, address(asset))
        );
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(newFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
    }

    function test_OracleConfig_Cancel_DropsPending() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(2e8, block.timestamp, 8);
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(newFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
        guard.cancelOracleConfigUpdate(poolPolicyId, address(asset));
        PendingOracleUpdate memory pending = guard.getPendingOracleConfig(poolPolicyId, address(asset));
        assertEq(pending.executableAt, 0);
        // The old feed is still in place.
        OracleConfig memory stored = guard.getOracleConfig(poolPolicyId, address(asset));
        assertEq(stored.chainlinkFeed, address(wethFeed));
        // Executing after cancel reverts.
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.NoPendingOracleUpdate.selector, poolPolicyId, address(asset)));
        guard.executeOracleConfigUpdate(poolPolicyId, address(asset));
    }

    function test_OracleConfig_Removal_IsTimelocked() public {
        // Removing an oracle config loosens the price rule, so it is
        // timelocked like any other change.
        guard.removeOracleConfig(poolPolicyId, address(asset));
        // Still there until executed.
        OracleConfig memory stored = guard.getOracleConfig(poolPolicyId, address(asset));
        assertEq(stored.chainlinkFeed, address(wethFeed));
        vm.warp(block.timestamp + DELAY);
        guard.executeOracleConfigUpdate(poolPolicyId, address(asset));
        stored = guard.getOracleConfig(poolPolicyId, address(asset));
        assertEq(stored.chainlinkFeed, address(0));
        assertEq(stored.uniswapPool, address(0));
        // With the asset config gone, the Chainlink pair is incomplete;
        // the TWAP pool on token1 still resolves, so the reference is the
        // TWAP (tick 0 -> 1e18). Removing token1 too would skip the rule.
        (uint256 ref, address source) = guard.getReferencePrice(poolPolicyId, address(asset), address(token1));
        assertEq(ref, 1 ether);
        assertEq(source, address(mockPool));
    }

    function test_OracleConfig_Removal_UnknownToken_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.UnknownOracle.selector, address(0xDEAD)));
        guard.removeOracleConfig(poolPolicyId, address(0xDEAD));
    }

    function test_OracleConfig_Execute_Late_RevertsProposalExpired() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(2e8, block.timestamp, 8);
        guard.setOracleConfig(
            poolPolicyId,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(newFeed), uniswapPool: address(mockPool), feedDecimals: 8, tokenDecimals: 18
            })
        );
        uint256 proposedAt = block.timestamp;
        vm.warp(proposedAt + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ProposalExpired.selector, proposedAt));
        guard.executeOracleConfigUpdate(poolPolicyId, address(asset));
    }
}
