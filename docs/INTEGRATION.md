# ArbGuard — Integration Guide

**For a protocol dev. Ten lines, two minutes, one revert that saves your TVL.**

ArbGuard is an on-chain circuit breaker: you declare four limits for your
protocol, add one `check()` call before each sensitive function, and any
transaction that breaks your limits reverts before funds move. It is
**enforcement, not detection** — there is no alert to read after the money
is gone, because the money never moves.

Full design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## 1. Install

```bash
forge install Admuad/arbguard
```

(Repo is created by the project owner; until then, copy `src/ArbGuard.sol`
into your project. No other dependency — ArbGuard only needs OpenZeppelin
`ReentrancyGuard` in your own contracts, not in itself.)

## 2. Import and wire it up

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ArbGuard} from "arbguard/src/ArbGuard.sol";

contract MyVault {
    ArbGuard public immutable arbGuard;
    uint256 public immutable policyId;

    constructor(address _arbGuard, uint256 _policyId) {
        arbGuard = ArbGuard(_arbGuard);
        policyId = _policyId;
    }
}
```

## 3. Register a policy

Register once per protocol (or once per guarded contract). Four numbers +
a keeper address. Do this from your owner account, or from the frontend
policy form at `/policies`.

```solidity
uint256 policyId = arbGuard.registerPolicy(address(myVault), Policy({
    maxOutflowPerBlock:   10 ether,  // max net outflow per block
    maxSingleShareBps:    500,       // max single withdrawal: 5% of TVL
    maxPriceDeviationBps: 500,       // max price move vs TWAP: 5%
    cooldownSeconds:      3600,      // breaker pause: 1 hour
    keeper:               0xYourKeeperAddress,
    enabled:              true
}));
```

**Picking the numbers:** set `maxOutflowPerBlock` above your largest
legitimate single-block outflow (look at your last 30 days of blocks) and
below the amount that would hurt if it left in one attack. Set
`maxSingleShareBps` so no single user can take more than a small slice of
TVL in one call. Set `maxPriceDeviationBps` above your normal worst-case
slippage, below the move an oracle-manipulation attack needs. When in
doubt, start tight and loosen — a false revert on a legitimate whale
withdrawal is annoying; a missed drain is fatal. Note the honest limit:
an attacker who stays *under* the cap every block can still bleed you
slowly — ArbGuard bounds the rate of loss, it does not make slow drains
impossible. See `ARCHITECTURE.md` § Threat model.

## 4. Add the one `check()` call — before the sensitive action

This is the whole integration. One call, **before** any state change or
token transfer (check-then-effect, never effect-then-check):

```solidity
function withdraw(uint256 shares) external nonReentrant {
    uint256 assets = previewRedeem(shares);

    arbGuard.check(address(this), Action({
        kind: ActionKind.WITHDRAW,
        token: address(asset),
        amountOut: assets,
        amountIn: 0,
        price: 0,
        twapPrice: 0,
        tvl: asset.balanceOf(address(this)) // value at risk before the withdrawal
    }));

    _burn(msg.sender, shares);
    asset.transfer(msg.sender, assets);
}
```

For a swap, pass the execution price and the TWAP reference so the
price-deviation rule can fire:

```solidity
arbGuard.check(address(this), Action({
    kind: ActionKind.SWAP,
    token: address(tokenOut),
    amountOut: amountOut,
    amountIn: amountIn,
    price: executionPrice,
    twapPrice: twapPrice,
    tvl: reserveOut // value at risk before the swap (pass the reserve/TVL to enforce the single-share rule)
}));
```

That is the 10-line diff: import, two state variables, constructor wiring,
one `registerPolicy`, one `check()` per sensitive function.

## 5. Keeper setup

The keeper is the address allowed to trip the breaker when something looks
wrong. It can be a human (your on-call dev), a multisig, or a monitoring
bot — in v1 it is a manual call:

```solidity
// From the keeper or owner account, any time:
arbGuard.trip(policyId, "suspicious outflow spike, investigating");
```

While tripped, every guarded action for that policy reverts. The breaker
**auto-resumes** after `cooldownSeconds` — nobody needs to unpause it at
3 a.m. The owner can clear the pause with `reset(policyId)` once the
cooldown has elapsed. `reset()` cannot end the pause early: called before
the cooldown elapses it reverts with `BreakerStillActive`. Only the owner
can reset; the keeper cannot.

## 6. What the revert looks like

A blocked transaction reverts with:

```
ArbGuardViolation(OUTFLOW_PER_BLOCK)
```

(or `PRICE_DEVIATION`, `SINGLE_SHARE`, `BREAKER_TRIPPED`). The revert
reason names the rule that fired, and it is visible in the transaction
receipt and on Arbiscan. (`NONE` never appears in a revert — it is the
`simulateCheck` sentinel for "would pass".)

**Important:** a reverted transaction leaves no persistent event on chain
— the EVM rolls back everything, including events. There is no on-chain
`ViolationBlocked` event to subscribe to for a blocked attack. You see the
block in the receipt (revert reason) and in the fact that balances did not
move. The ArbGuard frontend simulator shows exactly that: the failed
receipt, the revert reason, and before/after balances. Do not build a
monitor that waits for a `ViolationBlocked` event in v1 — it will never
fire for a reverted call. See `ARCHITECTURE.md` § "The reverted-tx event
note".

## 7. Test it (Foundry template)

The template below uses the repo's own demo contracts
(`GuardedVault`, `MockERC20`, `Attacker`) so it compiles as-is against
`contracts/src/` — the same setup as `contracts/test/AttackBlocked.t.sol`,
which is the reference. `Attacker.drainVault()` deposits, then loops
`withdraw()` in one transaction; on a guarded vault the withdrawal that
crosses the per-block cap reverts the whole transaction (deposit
included), so the vault balance is unchanged.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbGuard, Policy, Reason} from "arbguard/src/ArbGuard.sol";
import {GuardedVault} from "arbguard/src/GuardedVault.sol";
import {MockERC20} from "arbguard/src/MockERC20.sol";
import {Attacker} from "arbguard/src/Attacker.sol";

contract MyVaultGuardedTest is Test {
    ArbGuard arbGuard;
    MockERC20 asset;
    GuardedVault vault;
    Attacker attacker;
    uint256 policyId;
    address victim = makeAddr("victim");

    function setUp() public {
        arbGuard = new ArbGuard();
        asset = new MockERC20("Mock WETH", "mWETH");
        vault = new GuardedVault(asset, arbGuard);
        attacker = new Attacker();
        policyId = arbGuard.registerPolicy(address(vault), Policy({
            maxOutflowPerBlock: 100 ether,
            maxSingleShareBps: 5000,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: address(this),
            enabled: true
        }));
        // Victim seeds the vault; attacker is funded for the drain attempt.
        asset.mint(victim, 10_000 ether);
        asset.mint(address(attacker), 10_000 ether);
        attacker.approve(address(asset), address(vault), type(uint256).max);
        vm.prank(victim);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        vault.deposit(1000 ether);
    }

    function test_normalWithdrawPasses() public {
        vm.prank(victim);
        vault.withdraw(50 ether); // under every cap: must succeed
        assertEq(asset.balanceOf(address(vault)), 950 ether);
    }

    function test_drainReverts() public {
        // Loop withdrawals past the per-block cap in one tx:
        // the whole tx must revert and the vault balance must be unchanged.
        vm.expectRevert(
            abi.encodeWithSelector(ArbGuard.ArbGuardViolation.selector, Reason.OUTFLOW_PER_BLOCK)
        );
        attacker.drainVault(vault, 900 ether, 90 ether, 20);
        assertEq(asset.balanceOf(address(vault)), 1000 ether);
    }

    function test_breakerTripPausesAndAutoResumes() public {
        arbGuard.trip(policyId, "test");
        vm.prank(victim);
        vm.expectRevert();
        vault.withdraw(1 ether);
        vm.warp(block.timestamp + 3601);
        vm.prank(victim);
        vault.withdraw(1 ether); // cooldown over: works again
    }
}
```

The ArbGuard repo's own test suite (`contracts/test/`) is the reference:
`ArbGuard.t.sol` (policy CRUD, access control, cooldown),
`AttackBlocked.t.sol` (drain + price-push blocked on guarded, succeed on
unguarded), `Breaker.t.sol` (trip / auto-resume / reset),
`Invariants.t.sol` (outflow window never exceeded while guarded).

## 8. Deploy checklist

- [ ] Deploy (or use the deployed) `ArbGuard` on Arbitrum Sepolia first —
  free, fast, verified on Arbiscan.
- [ ] Register your policy; record the `policyId` and the `ArbGuard`
  address in your own README.
- [ ] Verify the guarded contract on Arbiscan so the `check()` call is
  readable.
- [ ] Run the drain test against the Sepolia deployment, not just Anvil.
- [ ] Set the keeper to an address that is actually monitored. A keeper
  nobody watches is a breaker nobody trips.
- [ ] For mainnet (Arbitrum One): owner should be a multisig or timelock,
  not an EOA. The owner can rewrite the policy and reset the breaker.

## 9. FAQ

**Does ArbGuard stop reentrancy?** No — that is `ReentrancyGuard`'s job,
and your vault should still use it. ArbGuard stops the *economic* shape
of a drain (too much value out, too fast), whatever call pattern produces
it. The demo drain loops `withdraw()` in one tx; plain ERC20 has no
recipient callback to re-enter through.

**What if a legitimate whale withdrawal trips the breaker?** It reverts,
the whale retries after the block window resets, and you loosen the cap.
A false positive costs a retry; a false negative costs the vault.

**Can I use ArbGuard without the Stylus checker?** Yes. The Solidity
invariant math in `ArbGuard.sol` is the shipping path in v1. There is no
checker address to set — the Stylus checker swaps in behind the same
interface once chain activations resume (Stylus activations are paused
chain-wide as of the 2 Oct 2026 Security Council pause, so the Solidity
path is what ships).

**Is there a fee?** No token, no governance, no fees in v1.

**Where do I get help?** Open an issue on the repo or ask in the Arbitrum
Discord `#open-house` channel.
