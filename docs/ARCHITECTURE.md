# ArbGuard — Architecture (spec freeze v0.1)

**Status:** spec freeze, Week 0 (Mon 9 – Tue 11 Nov 2026, working schedule).
No new features may enter this spec after Tue 11 Nov 2026 without cutting
something of equal size. See `../research_notes/arbitrum-buildathon-entry-2026-11-09.md`
§3–§5 for the full build plan (kept outside this repo).

## One-line pitch

ArbGuard is the on-chain circuit breaker for Arbitrum: it **reverts the
exploit transaction before the money moves**.

## What it is — and what it is not

ArbGuard is **enforcement, not detection**. Monitors, alert bots and
post-mortem dashboards tell you after the money is gone. Audits and scanners
tell you before deployment. ArbGuard sits in the middle: a plug-in,
on-chain firewall that a protocol calls before its sensitive functions
execute, and that reverts the transaction when the protocol's own declared
invariants break.

The HackQuest gallery for this buildathon already lists one security-like
project, InvariantSnipe — an invariant *oracle* (detection/monitoring).
ArbGuard is deliberately the other side of that line: it does not watch and
report, it **stops the transaction**. Every pitch, demo and doc should lead
with the revert, not with the dashboard.

## System overview

```
                    ┌──────────────────────────────┐
                    │        ArbGuard.sol         │
                    │  (Solidity — registry +      │
                    │   enforcement entry point)   │
                    │                              │
                    │  registerPolicy()            │
                    │  check()  ──► revert on      │
                    │    violation                 │
                    │  trip() / reset()            │
                    │  PolicyRegistered /          │
                    │  CheckPassed / Violation-    │
                    │  Blocked / BreakerTripped /  │
                    │  BreakerReset                │
                    └──────┬───────────────┬───────┘
                           │               │ cross-contract call
              calls check()│               ▼
              before the   │     ┌─────────────────────┐
              sensitive    │     │ ArbGuardChecker    │
              action       │     │ (Stylus / Rust —    │
                           │     │  gas-optimised pure │
                    ┌──────┴─────┴───────┐  invariant math) │
                    │ GuardedVault       │     └─────────────────────┘
                    │ GuardedPool        │
                    │ (demo victims)     │
                    └────────────────────┘
```

Components (v1):

| Component | Language | Role |
|---|---|---|
| `ArbGuard.sol` | Solidity 0.8.28 | Policy registry, `check()` entry point, breaker state, events |
| `ArbGuardChecker` | Rust / Stylus | Gas-optimised invariant math (pure functions, no storage on the pass path) |
| `GuardedVault.sol` / `UnguardedVault.sol` | Solidity | Demo victim #1 — ERC-4626-style vault; guarded vs control deployment |
| `GuardedPool.sol` | Solidity | Demo victim #2 — constant-product AMM, price-deviation rule |
| `Attacker.sol` | Solidity | `drainVault()` + `pushPriceAndSwap()` demo/test helpers |
| `apps/web` | Next.js 15 + wagmi/viem | Policy form, attack simulator, live event feed |

## The invariant model

A protocol registers a `Policy` for itself:

```solidity
struct Policy {
    uint256 maxOutflowPerBlock;   // max net value out of the protocol per block (wei of the guarded asset)
    uint256 maxSingleShareBps;    // max single withdrawal as a share of TVL, in basis points (1 bps = 0.01%)
    uint256 maxPriceDeviationBps; // max allowed price move vs the TWAP reference, in basis points
    uint256 cooldownSeconds;      // how long a tripped breaker stays paused
    address keeper;               // address allowed to trip the breaker (plus the owner)
    bool    enabled;
    // Phase 2 additions (see "Rules 5-6" below):
    bool    usdDenominated;       // true: caps/amounts are USD 1e18 (adapter policies); false: raw token units
    uint16  minHealthFactorBps;   // min post-action health factor, bps of 1e18 (0 = rule off; else 10000-50000)
    uint16  maxReserveDrainBps;   // max share of available liquidity one action may take, bps (0 = off; else 1-10000)
}
```

`check()` enforces five rules in v2 (Phase 2). **Any one failing reverts the whole
transaction** with `ArbGuardViolation(reason)` — nothing moves, no partial
state change survives. (A sixth rule, reserve conservation, is specified
below as Rule 4 but is **not enforced** — see the note there.)

### Rule 1 — Max outflow per block

The cumulative net outflow of the guarded asset in the current block
(`windowOutflow`) plus the amount this action would move out must not exceed
`maxOutflowPerBlock`.

```
windowOutflow[block.number] + amountOut <= maxOutflowPerBlock
```

This is the rule that stops a drain: a single transaction can only ever
move a bounded amount out, no matter how many times it loops the sensitive
function inside that transaction (see "The drain mechanism" below).

### Rule 2 — Max single-withdrawal share of TVL

A single withdrawal must not exceed `maxSingleShareBps` of the protocol's
total value locked at the time of the call.

```
amountOut * 10_000 <= tvl * maxSingleShareBps
```

Stops one whale-sized withdrawal from emptying a vault even when the
per-block cap alone would allow it.

### Rule 3 — Price deviation vs TWAP

For swaps, the execution price must stay within `maxPriceDeviationBps` of
the reference price.

```
|price - twapPrice| * 10_000 <= twapPrice * maxPriceDeviationBps
```

Stops oracle-manipulation / flash-loan price-push swaps: a swap that moves
the price 40% when the policy allows 5% reverts.

### Rule 4 — Reserve conservation *(specified, not enforced in v1)*

After the action, the protocol's recorded reserves must still reconcile:
the balance the protocol *should* hold (opening reserves + inflows −
outflows) must equal the balance it *does* hold. A mismatch means value
leaked somewhere the other rules did not model, and the transaction reverts.

```
actualBalance == expectedBalance
```

**v1 status: not implemented.** `check()` is called *before* the action,
so it cannot observe post-action balances, and the v1 `Action` struct
carries no reserve/balance fields and `Reason` has no reserve-mismatch
variant. Enforcing this rule needs a post-action confirm step (a second
call after the state change, or the protocol passing expected balances
into `check()`), which is a v2 design item — not a one-line addition.
The README, the threat model below, and the submission all say "five
enforced invariants" until that step exists. Do not cite Rule 4 as a
shipped protection.

### Rule 5 — Health factor floor (Phase 2, BORROW/WITHDRAW only)

For borrows and withdrawals, the projected post-action health factor must
stay at or above `minHealthFactorBps` (1e18-scaled; the floor is
`minHealthFactorBps * 1e14`). A health factor of `type(uint256).max`
means "no debt" and always passes.

```
healthFactorAfter < minHealthFactorBps * 1e14  →  HEALTH_FACTOR
```

Stops a borrow or collateral withdrawal that would leave the account
under-collateralised. Swaps ignore this rule (a Uniswap position carries
no debt). The adapter computes the projected factor from the Pool's own
`getUserAccountData` plus the action's amounts; the guard only enforces
the floor. `minHealthFactorBps == 0` disables the rule.

### Rule 6 — Reserve drain cap (Phase 2, BORROW/WITHDRAW/SWAP)

A single action must not take more than `maxReserveDrainBps` of the
reserve's available liquidity.

```
amountOut * 10_000 > availableLiquidity * maxReserveDrainBps  →  RESERVE_DRAIN
```

Stops one action from emptying a reserve even when the per-block outflow
cap alone would allow it. `availableLiquidity` is the reserve's real
balance (the adapter reads `balanceOf(pool)` for Aave, the pool's token
balance for V3) — not a formula, after the Phase 2 finding that the
spec's `totalAToken − totalStableDebt − totalVariableDebt` formula
overstates Aave's available liquidity ~400x. `maxReserveDrainBps == 0`
disables the rule.

### Check order (Phase 2, spec §3.4)

caller → policy exists → sequencer (SWAP only) → enabled/paused →
outflow windows → single share → health factor → reserve drain → price
(swaps only). `simulateCheck` mirrors `check()` via the shared
`_evaluateInvariants`, so the two cannot drift.

## Adapter trust boundary (Phase 2)

The adapters (`AaveAdapter`, `UniswapV3Adapter`) are thin, stateless
pass-throughs: the user calls the adapter instead of the pool, the adapter
runs `ArbGuard.check()` first, then forwards the call unchanged. The
adapter holds no funds between calls (it forwards borrowed/withdrawn
tokens to the caller in the same transaction and sweeps rounding dust
back). aTokens and position NFTs go to the user, never the adapter.

The guard is the only trust anchor: it is the sole caller the adapters
obey for `check()`, and a policy is registered per adapter (one policy
per adapter, not per reserve — spec §6 Q2). Bypassing the adapter
(calling the pool directly) means the guard does not apply; the firewall
is opt-in. The AaveOracle is trusted for USD pricing in the adapter hot
path (spec §6 Q3); the guard's own reference cross-checks Chainlink
against the Uniswap TWAP, and the fork test pins AaveOracle vs Chainlink
within 1% for both assets.

The "real TWAP source" open question from Phase 1 is closed: the guard
reads the TWAP from the pool itself via `observe()` and cross-checks it
against Chainlink, with the 200 bps disagreement rule. The adapter
computes execution prices in-adapter (no Quoter call).

## How `check()` is called

**One line, before the sensitive action.** The guarded protocol calls
`check()` *before* any state change or token transfer in the sensitive
function — check-then-effect ordering, never effect-then-check:

```solidity
function withdraw(uint256 shares) external nonReentrant {
    // ... compute assets owed ...
    arbGuard.check(protocol, Action({
        kind: ActionKind.WITHDRAW,
        token: address(asset),
        amountOut: assets,
        amountIn: 0,
        price: 0,
        twapPrice: 0
    }));
    // ... only now: burn shares, transfer assets ...
}
```

`check()` is a view-style enforcement call on the pass path: it reads the
policy, runs the three rules (the Stylus checker, when deployed, would
take over the arithmetic behind the same interface — see "Stylus checker
role" below; it is **not wired in v1**), records the outflow window, and
either returns silently or reverts. The protocol never needs to branch on
a return value — **a revert is the signal**.

`Action` encodes the kind (`WITHDRAW` / `MINT` / `SWAP` / `BORROW`), the
token, `amountOut`, `amountIn`, and for swaps the execution `price` and the
`twapPrice` reference. Rules that do not apply to a given kind are skipped
(e.g. price deviation is only evaluated for swaps).

## Breaker trip / reset + cooldown semantics

- **`trip(policyId, evidence)`** — callable by the policy's `keeper` or the
  protocol owner at any time. Sets `pausedUntil = block.timestamp +
  cooldownSeconds` and emits `BreakerTripped`. While the breaker is tripped,
  `check()` reverts every guarded action for that policy
  (`ArbGuardViolation(BREAKER_TRIPPED)`).
- **Auto-resume** — after `pausedUntil` passes, `check()` passes again
  automatically. There is no 3 a.m. multisig scramble to unpause; the
  cooldown is the pause.
- **`reset(policyId)`** — owner-only. Clears the trip early (before the
  cooldown expires) and emits `BreakerReset`. Used when the owner has
  confirmed the threat is over. The keeper cannot reset — tripping is easy
  and cheap, un-tripping requires the owner.
- **Policy updates** — only the protocol owner may update a policy
  (`updatePolicy`), and updates take effect immediately for the next call.
  There is no timelock on policy updates in v1 (see Trust assumptions).

## Events

| Event | When |
|---|---|
| `PolicyRegistered(policyId, protocol, owner)` | A policy is registered |
| `CheckPassed(policyId, protocol, kind, amountOut)` | A guarded action passed all rules |
| `ViolationBlocked(policyId, protocol, reason)` | **Not emitted in v1 — there is no such event in the contract.** A reverted call cannot leave a persistent event (see the note below); the row is kept here only so nobody re-adds it expecting it to work. |
| `BreakerTripped(policyId, by, pausedUntil)` | Keeper/owner trips the breaker |
| `BreakerReset(policyId, by)` | Owner resets the breaker early |

### The reverted-tx event note — read this before building the feed

**A reverted transaction leaves no persistent event on chain.** When
`check()` reverts with `ArbGuardViolation(reason)`, the EVM rolls back
every state change in that transaction — including any event the call
would have emitted. There is therefore no on-chain `ViolationBlocked`
event for a blocked attack, and no event log a dashboard can subscribe to
after the fact.

Blocked attempts are surfaced in three other ways, and the product is
designed around them:

1. **The revert reason.** `ArbGuardViolation(OUTFLOW_PER_BLOCK)` (or
   `PRICE_DEVIATION`, `SINGLE_SHARE`, `BREAKER_TRIPPED`) is visible in the transaction receipt and on
   Arbiscan. It names the rule that fired.
2. **Unchanged balances.** The vault/pool balances after the blocked tx
   are identical to before it — the demo's proof is the balance that did
   not move.
3. **The frontend simulator.** The attack simulator in `apps/web` runs the
   attack, catches the revert, and displays the failed receipt, the revert
   reason and the before/after balances side by side. That is the
   user-visible record of a blocked attack.

`ViolationBlocked` is **not defined anywhere in the contract** — the
`ArbGuard.sol` header documents the deliberate decision not to emit one,
because a reverted transaction rolls its events back with its state.
It could only exist behind a future non-reverting reporting path (e.g. an
off-chain keeper log or a `checkView()` that returns a result instead of
reverting), but **v1 must not claim the dashboard shows on-chain
blocked-attack events**. The live feed page shows `PolicyRegistered`,
`CheckPassed`, `BreakerTripped` and `BreakerReset` — real, persistent
events — and the simulator shows blocked attempts from the receipt. Any
doc, pitch or video line that says "watch blocked attacks in the live
feed" is wrong until a non-reverting reporting path exists.

## Stylus checker role

The hot-path invariant math — outflow comparison, share comparison, price
deviation — is designed to run in a **Stylus (Rust) contract**
(`ArbGuardChecker`) for gas efficiency, behind the same interface as the
Solidity math. The checker exposes three pure functions:

- `check_outflow(amount_out, window_outflow, max_outflow) -> bool`
- `check_price_deviation(price, twap, max_bps) -> bool`
- `check_share(amount_out, tvl, max_bps) -> bool`

Pure functions, no storage writes on the pass path. The Rust surface is
deliberately tiny: it is the smallest Stylus contract that honestly earns
the "built with Stylus" claim.

**v1 status: built and tested, NOT wired in.** `ArbGuard.sol` has no
checker address and makes no cross-contract call — the Solidity
`_checkInvariants()` is the enforcement path, and the Stylus integration
is a Week 2 wiring slice (see `stylus/README.md` for the suggested
integration). Do not describe the Stylus checker as running in the live
path until that wiring lands and is tested on Sepolia.

**Fallback (decided in advance, not in a crisis):** the invariant math is
implemented in Solidity inside `ArbGuard.sol` first, behind an internal
`_checkInvariants()`, and the system works end-to-end *before* any Rust is
written. The Stylus checker is a gas-optimisation swap, not a load-bearing
dependency. **The Mon 23 Nov deploy gate is superseded:** Arbitrum paused
all new Stylus contract activations on 2 Oct 2026 (verified 9 Nov 2026
against Sepolia and One — see `stylus/README.md`), so no checker can be
deployed or pass on Sepolia while the pause holds, through no fault of
this code. The Solidity path ships; the Stylus version is documented as
"roadmap — checker built, tested, and deployable the moment activations
resume". A fake Stylus claim is worse than an honest Solidity
implementation.

## The drain mechanism — documented honestly

The demo drain attack works by **looping `withdraw()` inside a single
transaction**, not by ERC777-hook reentrancy. Plain ERC20 tokens have no
recipient callback, so there is no hook for an attacker contract to
re-enter through on a standard token transfer. The attacker contract
simply calls `withdraw()` repeatedly in one transaction:

```solidity
function drainVault(address vault, uint256 times) external {
    for (uint256 i = 0; i < times; i++) {
        vault.withdraw(sharesPerCall);
    }
}
```

On the **unguarded** vault this empties it (each call is individually
"valid"). On the **guarded** vault the per-block outflow rule fires on the
call that would push the block's cumulative outflow over the cap, and the
*entire* transaction reverts — including the earlier withdrawals in the
loop. That is the demo: one attack, two vaults, one drains, one reverts.

ArbGuard does not claim to stop reentrancy in general — the demo vaults
still use `ReentrancyGuard` for that, as any vault should. ArbGuard stops
the *economic* shape of the drain (too much value out, too fast), whatever
call pattern produces it.

## Threat model

### What ArbGuard stops

- **Single-transaction drains** — repeated withdrawals / mints / borrows
  in one tx that would move more than the per-block cap or more than the
  single-share cap out of the protocol.
- **Price-push swaps** — flash-loan / oracle-manipulation swaps that move
  the execution price beyond the allowed deviation from the TWAP reference.
- **Ongoing attacks, via the breaker** — once an attack is spotted, a
  keeper trips the breaker and every guarded function pauses for the
  cooldown, buying time to fix the underlying bug.

Reserve-breaking actions (recorded reserves no longer reconciling with
actual balances) are **not** stopped in v1 — Rule 4 is specified but not
enforced (see above); that is a v2 item.

### What ArbGuard does NOT stop

- **Slow multi-block drains under the cap.** An attacker who stays under
  `maxOutflowPerBlock` every block can still bleed a protocol over hours
  or days. ArbGuard bounds the *rate* of loss; it does not bound the
  total loss over a long attack. Tight caps and a vigilant keeper are the
  mitigation, and the policy form should say so.
- **Governance compromise.** If the attacker controls the protocol owner
  key, they can update the policy (raise the caps to infinity) or reset
  the breaker. ArbGuard enforces the policy the owner set — it cannot
  protect a protocol from its own owner.
- **A malicious protocol owner.** Same point from the other side: the
  owner is trusted to set honest limits. ArbGuard is a guard against
  *exploits*, not against a rug by the team.
- **Bugs in the guarded function itself** that do not break any of the three
  enforced invariants (e.g. a logic error that mis-allocates value *between* users
  without moving net outflow or reserves). ArbGuard is not an audit.
- **Off-chain / social attacks** — phishing, compromised deploy keys used
  to upgrade the protocol contract itself (outside `check()`'s view),
  front-running that stays within the caps.

## Trust assumptions

1. **The protocol must call `check()` correctly.** ArbGuard can only
   enforce what it is asked to check. If a protocol adds a new sensitive
   function and forgets the `check()` call, or passes a wrong `amountOut`
   / `tvl`, that path is unguarded. Integration is one line per function,
   but the line has to actually be there, before the state change.
2. **Keeper / owner honesty.** The keeper can trip the breaker (a
   denial-of-service vector if the keeper is malicious — they can pause
   the protocol for one cooldown at a time). The owner can reset the
   breaker and rewrite the policy. Both roles must be held by parties the
   protocol trusts; in production the owner should be a multisig or
   timelock, not an EOA.
3. **TWAP proxy simplification (v1).** A real TWAP oracle is out of v1
   scope. The demo pool stores `lastPrice`, updated at most once per
   block, and uses it as the reference price for the deviation rule. This
   is a **v1 proxy, not a TWAP**: a single-block price is manipulable
   within that block, and a real deployment should plug in a proper TWAP
   (e.g. Uniswap V3 TWAP, Chainlink) as the `twapPrice` input. The
   deviation rule is only as good as the reference it is given.
4. **The Stylus checker is trusted code called by `ArbGuard.sol` — once
   wired.** In v1 there is no checker address and no cross-contract call,
   so this assumption does not apply yet. When the wiring lands: if the
   checker address is set wrong, or the checker is upgraded to something
   that always returns `true`, enforcement silently disappears. The
   checker address is set once at deployment and is not upgradeable
   in v1.
5. **Block-number windows assume Arbitrum block production.** The
   per-block outflow window keys on `block.number`; on Arbitrum, blocks
   are produced quickly and regularly, so a per-block cap is a meaningful
   rate limit. The same numbers would mean something different on a
   chain with 12-second blocks.

## Non-goals for v1 (do not build these)

- No AI/ML anomaly detection (deterministic invariants only).
- No cross-chain / bridge guarding (single chain: Arbitrum Sepolia, then
  Arbitrum One).
- No token, no governance, no fees.
- No auto-pause by an off-chain bot as the primary mechanism (keeper
  `trip()` is manual in v1).
- No Uniswap V4 hook version (roadmap only).

## Open questions (for the Week 0 review)

1. Exact `Policy` field order / types — the contracts slice owns the final
   ABI; this doc's struct is the frozen *shape*, the ABI is the contracts
   slice's to confirm.
2. Whether `check()` should also enforce a per-*transaction* cap in
   addition to the per-block cap (the loop-drain is already caught by the
   block window, so this is probably redundant — decide in Week 1).
3. Real TWAP source for the post-v1 pool (Uniswap V3 TWAP vs Chainlink) —
   out of v1 scope, but the choice affects the `twapPrice` plumbing.

---

*Spec freeze v0.1 — 9 Nov 2026. Author: Fred (frontend + docs slice).
Reviewer: Muhammed (30 min, async).*
