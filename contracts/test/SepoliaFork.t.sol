// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Reason, Action, ActionKind, OracleConfig, Policy, PriceConfig} from "../src/ArbGuard.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAggregatorV3} from "./Mocks.sol";

/// @notice Fork tests against live Arbitrum Sepolia state.
///
/// Forks the latest Sepolia block via the public RPC, deploys the full
/// fixture on top of it, and proves both attacks are blocked on the
/// guarded contracts using live-chain block numbers and timestamps.
/// The outflow window keys on `block.number` and the breaker on
/// `block.timestamp`, so running on a real Sepolia fork (rather than a
/// fresh local chain) exercises the exact values the contracts will
/// see in production.
///
/// NOTE — Arbitrum `block.number` semantics (verified live 2026-11-10):
/// inside a contract, `block.number` returns the L1 block number, not
/// the L2 number (L2 is only via ArbSys.arbBlockNumber()). Consequence
/// for ArbGuard: the per-block outflow window is really a per-L1-block
/// window (~12s on Arbitrum, ~48 L2 blocks), which is TIGHTER than a
/// per-L2-block window would be (the cap binds over 12s, not 250ms).
/// The design is sound as-is; docs should say "per L1 block" honestly
/// rather than "per block". No contract change needed.
///
/// Run:  forge test --match-contract SepoliaForkTest -vv
/// RPC responses are cached by forge in ~/.foundry/cache, so re-runs
/// are cheap. No Alchemy key needed — the public Sepolia RPC is used
/// (the Alchemy connector has no Sepolia host registered).
contract SepoliaForkTest is Fixture {
    string internal constant SEPOLIA_RPC = "https://sepolia-rollup.arbitrum.io/rpc";

    function setUp() public override {
        vm.createSelectFork(SEPOLIA_RPC);
        super.setUp();
    }

    function test_Fork_IsLiveSepoliaState() public view {
        assertEq(block.chainid, 421614);
        // Arbitrum semantics, verified live 2026-11-10 (see ForkDiag run):
        // `block.number` inside a contract returns the L1 block number
        // (~12.1M on Sepolia), while the L2 block number (~327.7M) is
        // only available via ArbSys.arbBlockNumber(). Both are asserted
        // so a fork on the wrong chain (or a local chain) fails loudly.
        assertGt(block.number, 12_000_000); // L1 Sepolia height
        (bool ok, bytes memory ret) =
            address(0x0000000000000000000000000000000000000064).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        require(ok, "arbBlockNumber call failed");
        assertGt(abi.decode(ret, (uint256)), 327_000_000); // L2 Sepolia height
        assertGt(block.timestamp, 0);
    }

    function test_Fork_Drain_RevertsOnGuardedVault() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK));
        attacker.drainVault(guardedVault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(guardedVault)), 1000 ether);
    }

    function test_Fork_Drain_SucceedsOnUnguardedVault() public {
        attacker.drainVault(unguardedVault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(unguardedVault)), 1000 ether);
        assertEq(asset.balanceOf(address(attacker)), 10_000 ether);
    }

    function test_Fork_PricePush_RevertsOnGuardedPool() public {
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.PRICE_DEVIATION));
        attacker.pushPriceAndSwap(guardedPool, address(asset), 1000 ether);
        assertEq(guardedPool.reserve0(), 1000 ether);
        assertEq(guardedPool.reserve1(), 1000 ether);
    }

    function test_Fork_PricePush_SucceedsOnUnguardedPool() public {
        uint256 out = attacker.pushPriceAndSwap(unguardedPool, address(asset), 1000 ether);
        assertEq(out, 500 ether);
        assertEq(unguardedPool.reserve0(), 2000 ether);
        assertEq(unguardedPool.reserve1(), 500 ether);
    }

    function test_Fork_NormalWithdraw_PassesOnGuardedVault() public {
        vm.prank(victim);
        guardedVault.withdraw(50 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 950 ether);
    }

    function test_Fork_BreakerTrip_BlocksAndAutoResumes() public {
        // Keeper trips the breaker: guarded withdraws revert while paused.
        vm.prank(keeper);
        guard.trip(vaultPolicyId, "fork test: suspected drain");
        assertGt(guard.pausedUntil(vaultPolicyId), block.timestamp);

        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.BREAKER_TRIPPED));
        guardedVault.withdraw(10 ether);

        // reset() before the cooldown ends reverts.
        uint256 until = guard.pausedUntil(vaultPolicyId);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.BreakerStillActive.selector, until));
        guard.reset(vaultPolicyId);

        // Warp past the 1h cooldown: auto-resume with no reset call.
        vm.warp(block.timestamp + 3601);
        vm.prank(victim);
        guardedVault.withdraw(10 ether);
        assertEq(asset.balanceOf(address(guardedVault)), 990 ether);
    }

    // ------------------------------------------- Phase 1: oracle staleness
    /// @notice Real Sepolia ETH/USD feed (0xbF13EE58...) is STALE since
    /// 16 Oct 2024 (updatedAt 1729103473). Paired with a fresh mock USDC
    /// feed so the Chainlink pair is complete, a swap must revert
    /// ORACLE_UNAVAILABLE: the stale feed is invalid, there is no TWAP
    /// pool, and no usable source remains. This is the staleness guard
    /// proven against live chain state (spec §1.6 / §5.2).
    function test_Fork_StaleSepoliaEthFeed_RevertsOracleUnavailable() public {
        address sepoliaEthFeed = 0xbF13EE58Bf62500FE87e7389faB633ff95dec029;
        // Sanity: the feed really is stale on this fork.
        (,,, uint256 updatedAt,) = MockAggregatorV3(sepoliaEthFeed).latestRoundData();
        assertLt(updatedAt, block.timestamp - 7200, "feed is not stale on this fork");
        assertLt(updatedAt, 1729103473 + 86400, "feed updatedAt moved unexpectedly");

        address protocol = address(0xF00D);
        uint256 pid = guard.registerPolicy(protocol, poolPolicy(), priceConfig());
        // Fresh mock USDC feed ($1.00, 8 dec) completes the pair.
        // tokenDecimals 18 for both: the mock ERC20s are both 18 dec.
        MockAggregatorV3 usdcF = new MockAggregatorV3(1e8, block.timestamp, 8);
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: sepoliaEthFeed,
                uniswapPool: address(0),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            pid,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(usdcF),
                uniswapPool: address(0),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );

        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1 ether,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.ORACLE_UNAVAILABLE));
        guard.check(protocol, swap);
    }

    /// @notice Fresh mock feeds on the fork: the same swap passes, proving
    /// the ORACLE_UNAVAILABLE above is caused by the stale feed, not by
    /// the fork environment or the policy. (The fixture pool policy
    /// already proves this via its mock oracles; this test pins it on a
    /// fresh policy with no TWAP pool, Chainlink-only.)
    function test_Fork_FreshMockFeeds_PassOnFork() public {
        address protocol = address(0xF00E);
        uint256 pid = guard.registerPolicy(protocol, poolPolicy(), priceConfig());
        MockAggregatorV3 wethF = new MockAggregatorV3(1e8, block.timestamp, 8);
        MockAggregatorV3 usdcF = new MockAggregatorV3(1e8, block.timestamp, 8);
        guard.setOracleConfig(
            pid,
            address(asset),
            OracleConfig({
                chainlinkFeed: address(wethF),
                uniswapPool: address(0),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        guard.setOracleConfig(
            pid,
            address(token1),
            OracleConfig({
                chainlinkFeed: address(usdcF),
                uniswapPool: address(0),
                feedDecimals: 8,
                tokenDecimals: 18
            })
        );
        Action memory swap = Action({
            kind: ActionKind.SWAP,
            token: address(token1),
            tokenIn: address(asset),
            amountOut: 10 ether,
            amountIn: 10 ether,
            price: 1 ether,
            tvl: 1000 ether,
            healthFactorAfter: 0,
            availableLiquidity: 0
        });
        vm.prank(protocol);
        guard.check(protocol, swap);
        // And the reference price reads back 1.0 (both feeds $1.00, both 18 dec).
        (uint256 ref,) = guard.getReferencePrice(pid, address(asset), address(token1));
        assertEq(ref, 1 ether);
    }
}
