# ArbGuard keeper bot — RUNBOOK

Operator's document for the Phase 3 keeper bot
(`PHASE3-SPEC.md` §1). Read this before running the bot live.
The condensed version is `README.md`.

> **If this bot stops, the guard still works.** The guard reverts
> exploit transactions on-chain with no bot involved. The bot is a
> graduated response (throttle first, trip only when gated and
> confirmed), not the primary mechanism.

## 1. Prerequisites

- Node 20+ and npm.
- Sepolia ETH for the keeper key: ~0.01 ETH funds months of
  `throttle`/`trip` calls (each is one cheap transaction).
- The owner (holder of the deployer key) available to run `addKeeper`
  — the bot cannot add itself, and must never hold the owner key.
- The live deployment (Arbitrum Sepolia, chain `421614`):
  - ArbGuard: `0x9D733954c71920a51291d730fc48422d94d5C306`
  - GuardedVault (policy 0): `0xEa182E47829D76569dc50CcADD2bFafe462A0E3D`
  - GuardedPool (policy 1): `0x3b1714FE7583789C10528dD43Dbb18729269679E`
  - Deploy block: `331084418` (ArbGuard creation tx
    `0x37b7e8c8ecdf22d0f96862e6c61a91684eb2261b1768398325ba95c93e68fec1`)

## 2. Setup

```bash
cd keeper
cp .env.example .env        # .env is gitignored — never commit it
npm install
```

Fill in `.env`. The five required variables:

| Variable | Sepolia value |
|---|---|
| `KEEPER_RPC_URL` | `https://sepolia-rollup.arbitrum.io/rpc` |
| `KEEPER_GUARD_ADDRESS` | `0x9D733954c71920a51291d730fc48422d94d5C306` |
| `KEEPER_CHAIN_ID` | `421614` |
| `KEEPER_PRIVATE_KEY` | fresh testnet-only keeper key (see §3) |
| `KEEPER_DEPLOY_BLOCK` | `331084418` |

Everything else has a safe default (see `.env.example`). The
Sepolia deployment runs with `KEEPER_ORACLE_FAIL_POLLS=0` (T4
disabled — §6) and `KEEPER_ALLOW_TRIP=false` (throttle-only).

## 3. The keeper key

- The key in `keeper/.env` was generated fresh for this bot
  (`0xE65FB824123892e190816C9b2766F3934Fd80C88`) and is testnet-only.
  It holds no funds yet and is **not registered** as a keeper.
- It is NEVER the deployer/owner key, NEVER the fresh bounty wallet
  (`0xc7ba…`), NEVER the compromised wallet (`0x5978…`).
- The key lives in `keeper/.env` (mode 600) and nowhere else — not
  in the repo, not in the frontend env, not in a chat log. The bot
  never logs it.
- To rotate the key, generate a new one and follow §8 (key rotation).

## 4. Dry-run first

Dry-run is the default (`KEEPER_DRY_RUN=true`). A fresh checkout
that runs the bot does nothing on-chain until the operator
explicitly opts into live mode.

```bash
npm run build
npm test            # 27 unit tests, trigger rules only, no chain
timeout 100 npm start
```

Confirm before going live:

1. The startup line shows the full non-secret config
   (`dryRun: true`, `allowTrip: false`, thresholds, `contractVersion`).
2. A `KEEPER_NOT_REGISTERED` **warning** appears (not an error):
   dry-run must work before the keeper is registered.
3. At least one full poll cycle logs `NO_ACTION` per policy, e.g.:

```json
{"ts":"2026-11-20T18:50:33.041Z","chainId":421614,"guard":"0x9D733954c71920a51291d730fc48422d94d5C306","policyId":0,"mode":"NORMAL","decision":"NO_ACTION","reason":"T1 hour-use 0% < 80%; T2 day-use 0% < 80%; T3 block-use 0% (no large pass); oracle probe unusable, T4 disabled","hourUsePct":0,"dayUsePct":0,"blockUsePct":0,"dryRun":true,"txHash":null}
```

4. No transaction is sent. Check: `decisions.log` has no
   `THROTTLE_SENT`/`TRIP_SENT` line, and the guard's mode on
   Arbiscan is unchanged.

To force a trigger in dry-run, run the fork test (§9): it drives
outflow to 86% of the hour cap on a local Anvil chain and asserts
the bot logs `WOULD_THROTTLE` (T1) and sends nothing.

## 5. Going live

1. **Fund the keeper key** with ~0.01 Sepolia ETH (enough for months).
2. **Owner runs `addKeeper`** for the bot's keeper address, for both
   policies (owner-only, immediate):

```bash
# from the deployer/owner key — NEVER from the bot's key
cast send 0x9D733954c71920a51291d730fc48422d94d5C306 \
  "addKeeper(uint256,address)" 0 0xE65FB824123892e190816C9b2766F3934Fd80C88 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --private-key <OWNER_KEY>
cast send 0x9D733954c71920a51291d730fc48422d94d5C306 \
  "addKeeper(uint256,address)" 1 0xE65FB824123892e190816C9b2766F3934Fd80C88 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --private-key <OWNER_KEY>
```

3. **Set `KEEPER_DRY_RUN=false`** in `keeper/.env` and restart:

```bash
npm start
```

4. Confirm the startup line shows `dryRun: false` and
   `keeperRegistered: true`. If the keeper is not registered, the
   bot exits with `KEEPER_NOT_REGISTERED` instead of running live
   and discovering at 3 a.m. that it cannot call `throttle()`.

## 6. The Sepolia oracle state (read this before tuning T4)

On Sepolia the ETH/USD Chainlink feed
(`0xbF13EE58Bf62500FE87e7389faB633ff95dec029`) is stale
(`updatedAt` 16 Oct 2024), and the mWETH/mUSDC pair is incomplete
(only mWETH has a feed, no TWAP pool), so `getReferencePrice`
returns `(0, address(0))` — price 0, no source — **without
reverting**. The bot's probe therefore reports "unusable" on every
poll, forever. That is the expected, by-design Sepolia state, not
an error, and the decisions log says so
(`oracle probe unusable, T4 disabled`).

T4 is therefore **disabled** on Sepolia
(`KEEPER_ORACLE_FAIL_POLLS=0`, the only out-of-range value the
config accepts). Re-enable it only on a chain with a fresh feed
(Arbitrum One, or a Sepolia deployment with a mock feed).

Two further notes the spec's §1.4 text gets slightly wrong for
this deployment, recorded here so nobody "fixes" the bot to match
the spec's wording:

- The spec says `getReferencePrice` *reverts* `ORACLE_UNAVAILABLE`
  on Sepolia. It does not: the pair is incomplete, so the guard
  returns `(0, address(0))` and the price rule is skipped. The bot
  treats "returns unusable" the same as "reverts" for T4, and T4
  additionally requires a prior successful probe, so a feed that
  never worked cannot fire it.
- The spec's §2.5 policy table and the live reads agree for the
  caps; but the live guard is the **Phase 1 contract**
  (`getPolicy` returns 9 words / 288 bytes), deployed 20 Nov ~16:02
  before Phase 2 was implemented. The bot detects the layout at
  startup (`contractVersion: 1` in the startup line) and reads the
  shared 9-field prefix, which is identical in Phase 2. If the
  guard is ever redeployed with Phase 2 code, the bot detects
  `contractVersion: 2` and encodes its `simulateCheck` probe in the
  9-field Action layout. No config change is needed either way.

## 7. How to interpret the decisions log

`keeper/decisions.log` — one JSON line per watched policy per poll
cycle, plus startup/warning lines on stdout. Fields are exactly
the spec's §1.6 set: `ts, chainId, guard, policyId, mode,
decision, reason, hourUsePct, dayUsePct, blockUsePct, dryRun,
txHash`. `reason` always names the rule and the numbers. No line
ever contains the private key.

`decision` values and what they mean:

| Decision | Meaning / what to do |
|---|---|
| `NO_ACTION` | Nothing fired. Read the reason: it lists T1/T2/T3 utilisation and the oracle state. |
| `WOULD_THROTTLE` | Dry-run: the bot *would* throttle. The reason names the rule, the numbers, the exact call and estimated gas. |
| `THROTTLE_SENT` | Live: `throttle()` sent. `txHash` is set. See the incident playbook (§10). |
| `WOULD_TRIP` | Dry-run: the bot *would* trip (R1/R2/R3 fired). |
| `TRIP_SENT` | Live: `trip()` sent. See the incident playbook (§10). |
| `TRIP_BLOCKED_BY_CONFIG` | A trip rule fired but `KEEPER_ALLOW_TRIP=false` (the default). **This is the signal**: a human must decide whether to trip (§10 step 4). |
| `SKIP_ALREADY_PAUSED` | Breaker already doing the strongest thing. No action. |
| `SKIP_ALREADY_THROTTLED` | Already degraded; re-throttling would only reset the clock. No action. |
| `SKIP_DISABLED` | Policy disabled. No action. |
| `SKIP_PARTIAL_STATE` | A required read failed this cycle. The bot acted on nothing. If this repeats, check the RPC. |
| `PROPOSAL_SEEN` | A timelock proposal appeared (`PolicyUpdateProposed` / `OracleConfigUpdateProposed`). The bot did NOT throttle — a proposal is the owner acting. Read `executableAt` and watch the timelock window (§10). |
| `ERROR` | The whole poll cycle failed (RPC error, chain issue). No action taken. On HTTP 429 the bot backs off one full poll interval and logs it; it never retries a 429. |

Useful greps:

```bash
tail -f decisions.log
grep THROTTLE_SENT decisions.log
grep -E "TRIP_BLOCKED_BY_CONFIG|PROPOSAL_SEEN" decisions.log
```

There is no alerting channel in this phase (no email, webhook or
Telegram). The decisions log is the alerting surface: the operator
tails it, and any `THROTTLE_SENT` / `TRIP_SENT` /
`TRIP_BLOCKED_BY_CONFIG` / `PROPOSAL_SEEN` line is the signal.

## 8. Trigger reference (what makes the bot act)

Evaluated once per poll cycle, per policy, in this order.
Preconditions P1–P4 first, then trip rules R1–R2, then throttle
rules T1–T4, then T5. First firing rule wins; at most one action
per policy per cycle.

- **P1** `PAUSED` → no action. **P2** `THROTTLED` (unexpired) → no
  action. **P3** disabled → no action. **P4** anti-flap: the bot's
  own last action was < 2× poll interval ago and the mode has not
  changed → no action.
- **T1** hour-window burn: `outflowInHour ≥ 80%` of the hour cap
  (current hour only). **T2** day-window burn: same over a day.
  **T3** large passing action: one `CheckPassed` `amountOut ≥ 50%`
  of the block cap. **T4** oracle blind: `getReferencePrice`
  unusable for 3 consecutive polls after a prior success
  (disabled on Sepolia, §6). **T5** timelock proposal: log
  `PROPOSAL_SEEN`, never throttle on a proposal.
- **R1** confirmed drain: T1 or T2 fired AND the unguarded control
  drained in the same cycle. **R2** oracle disagreement storm:
  `ORACLE_DISAGREEMENT` for 3 consecutive polls AND the bot's
  read-only `simulateCheck` probe for a live swap returns
  `ORACLE_DISAGREEMENT`. **R3** manual: run once with
  `KEEPER_TRIP_ONCE=<policyId>` (see §10 step 4).
- Trip rules need `KEEPER_ALLOW_TRIP=true`; otherwise the bot logs
  `TRIP_BLOCKED_BY_CONFIG` and takes no on-chain action.

**The rule the bot must NEVER implement:** it must NOT auto-trip
(or auto-throttle) on a reverted check. A reverted transaction
leaves no on-chain event, and a revert is the guard *working* —
zero funds moved. Treating reverts as incidents would let an
attacker trip the breaker at will by spamming failing
transactions. The trigger module (`src/triggers.ts`) has no input
for reverts at all — there is no code path that takes a revert as
an input — and `test/triggers.test.ts` asserts that. The negative
fork test (§9) proves it live: a reverted guarded drain produces
`NO_ACTION`.

## 9. Tests

```bash
npm test            # 27 unit tests (test/triggers.test.ts, no chain)
bash test/fork-test.sh   # end-to-end on a local Anvil chain (~90s)
```

The fork test (spec §1.8, local-Anvil variant) deploys the demo
via `contracts/script/DeployFork.s.sol` (deploy-only: `AnvilDemo`
cannot be broadcast as-is because its guarded attack calls are
separate broadcast transactions that revert on-chain by design),
then proves: dry-run baseline `NO_ACTION`; a reverted guarded
drain causes no action; outflow driven to 86% of the hour cap
logs `WOULD_THROTTLE` (T1) and sends nothing; `KEEPER_TRIP_ONCE`
in dry-run logs `WOULD_TRIP`; live mode sends a real throttle
(`ThrottleSet` lands, policy reads `THROTTLED`), and the next
cycle logs `SKIP_ALREADY_THROTTLED`; `KEEPER_POLL_SECONDS=5` is
rejected. Last run: **10 passed, 0 failed** (20 Nov 2026).

Local-Anvil note: a Sepolia fork cannot reach 85% hour-use with
the demo's 900-share attacker, so the test deploys the identical
demo locally and drives outflow as the deployer (who holds minted
mWETH). The local deployment is Phase 2 code, which also exercises
the bot's Phase 2 layout path; live Sepolia is Phase 1 (§6).

Two environment notes from building the test:

- A fresh Anvil has no Multicall3 at the canonical address, so
  `multicall` resolves every call as a failure there. The bot
  detects an all-failed batch and falls back to parallel individual
  calls (`batchedReads` in `src/guard.ts`). On Sepolia the
  Multicall3 path is used.
- The public Sepolia RPC ignores `topics` filters on `getLogs`
  (verified 20 Nov 2026: a `CheckPassed`-filtered query returned
  all 6 guard logs). The bot therefore scans unfiltered and filters
  client-side in `src/events.ts`. Do not "optimise" it to a
  topic-filtered query on this endpoint.

## 10. Incident playbook

1. The bot throttles (or the operator sees
   `TRIP_BLOCKED_BY_CONFIG`). **Do not immediately unthrottle.**
   Read the decision log line: it names the rule and the numbers.
2. Check the dashboard and Arbiscan: which policy, what outflow,
   which addresses, is the unguarded control also moving?
3. If it is a false positive (a legitimate whale, a known large
   withdrawal), the owner runs `unthrottle(policyId)` (owner-only,
   immediate) and the operator notes the thresholds to tune.
4. If it is a real incident and the bot only throttled (default), a
   human trips the breaker — either from a keeper/owner key:

```bash
cast send 0x9D733954c71920a51291d730fc48422d94d5C306 \
  "trip(uint256,bytes)" <policyId> 0x<evidence> \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --private-key <KEEPER_OR_KEY>
```

   or by re-running the bot once with
   `KEEPER_TRIP_ONCE=<policyId>` (R3 — the bot verifies the caller
   is a registered keeper, sends one `trip()`, logs it, exits).
   Never trip from the bot's key by hand unless that key is a
   registered keeper.
5. After the incident, the owner `reset(policyId)`s once the
   cooldown has passed (`reset` before the cooldown reverts
   `BreakerStillActive`), or waits for auto-resume. `reset()`
   returns to NORMAL, not to THROTTLED; re-throttle with one call
   if the worry persists.
6. Post-mortem: append the incident to `keeper/INCIDENTS.md` (one
   section per incident: date, rule, numbers, action, outcome).
   The bot does not write this file; the operator does.

Timelock proposals (`PROPOSAL_SEEN`): a proposed limit change is
the owner acting, and the 24-hour timelock is the protection. If
the proposal is hostile, the response is human (revoke the owner
key, cancel via `cancelPolicyUpdate`), not automatic. The bot
never throttles on a proposal.

## 11. Recovery (owner commands)

```bash
GUARD=0x9D733954c71920a51291d730fc48422d94d5C306
RPC=https://sepolia-rollup.arbitrum.io/rpc
# A throttle auto-expires after KEEPER_THROTTLE_SECONDS (24h default).
# Owner can clear it early (owner-only, immediate):
cast send $GUARD "unthrottle(uint256)" <policyId> --rpc-url $RPC --private-key <OWNER_KEY>
# A trip auto-resumes after cooldownSeconds (3600s). Owner reset after
# the cooldown (owner-only; reverts BreakerStillActive before then):
cast send $GUARD "reset(uint256)" <policyId> --rpc-url $RPC --private-key <OWNER_KEY>
# Remove a compromised keeper (owner-only, immediate):
cast send $GUARD "removeKeeper(uint256,address)" <policyId> <keeper> --rpc-url $RPC --private-key <OWNER_KEY>
```

## 12. Key rotation

In this order, so there is never a moment with no keeper:

1. Generate a new key (fresh, testnet-only).
2. Fund it with ~0.01 Sepolia ETH.
3. Owner runs `addKeeper` for the new key, for both policies (§5).
4. Owner runs `removeKeeper` for the old key, for both policies.
5. Update `KEEPER_PRIVATE_KEY` in `keeper/.env`.
6. Restart the bot. Confirm the startup line shows the new keeper
   address and `keeperRegistered: true`.

## 13. Shutdown

Stop the process (`Ctrl-C`, or `kill <pid>`). The bot logs a
shutdown line. **The guard keeps working without it** — say so
explicitly whenever the bot is stopped: the guard reverts exploit
transactions on-chain with no bot involved.

## 14. Config reference

All variables are env vars; there are no hard-coded addresses,
thresholds or keys in source. Full table in `PHASE3-SPEC.md` §1.3
and `.env.example`. Startup validation fails fast (non-zero exit)
on: a guard address with no code; a chain-id mismatch; an
unregistered keeper in live mode; `KEEPER_POLL_SECONDS` outside
10–300; thresholds or durations outside their ranges
(`KEEPER_THROTTLE_SECONDS` 3600–604800, `0` rejected;
`KEEPER_ORACLE_FAIL_POLLS` 1–10, or `0` to disable).
