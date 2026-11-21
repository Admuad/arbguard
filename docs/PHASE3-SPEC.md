# ArbGuard Phase 3 — Operability: keeper bot, live dashboard, video, submission package

**Status:** spec, 20 Nov 2026. No code written against it yet.
**Scope:** keeper bot (`keeper/`, new), dashboard page (`apps/web/app/dashboard/`,
new) + frontend env config, demo-video plan (script + storyboard only),
submission package (checklist + materials). No contract changes in this
phase. No public-chain deployment in this phase; no submission sent in
this phase.
**Design constraints carried over from Phases 1–2 (non-negotiable):**
- No `ViolationBlocked` event — a reverted transaction cannot leave a
  persistent event; blocked attempts surface via the revert reason and
  `simulateCheck()` only (`ARCHITECTURE.md`, "The reverted-tx event note").
  The same applies to the keeper bot and the dashboard: neither may claim
  to show on-chain blocked-attack events. The bot reads persistent events
  (`CheckPassed`, `BreakerTripped`, `ThrottleSet`, …) and live state; the
  dashboard shows those plus the simulator's locally recorded blocked
  attempts. Any doc, pitch or video line that says "watch blocked attacks
  in the live feed" is wrong.
- `check()` and `simulateCheck()` stay in lock-step. Phase 3 writes no
  contract code, so there is nothing to drift — but the dashboard's
  simulator usage and the bot's `simulateCheck` reads must use the same
  `Action` shape as the contracts (Phase 2 struct: `healthFactorAfter`,
  `availableLiquidity`, no `twapPrice`, `tokenIn` for swaps).
- The keeper bot only calls keeper functions (`throttle` / `trip`). It
  never moves funds, never calls `check()` as a transaction, never
  updates a policy, never manages keepers, never resets/unthrottles.
  Those are owner functions and the bot must not hold the owner key.
- The dashboard reads live on-chain data via viem/wagmi. No hard-coded
  balances, caps, modes or prices in the UI. A number on the dashboard
  that did not come from a chain read (or from an event log) is a bug.
- All 237 currently passing tests must still pass. The 2 known failures
  are the Phase 1 gas-target misses (SWAP Chainlink+TWAP 126,848 /
  THROTTLED 129,593 vs the 120k target); Phase 3 does not re-baseline
  them. `ArbGuard` is 23,705 bytes (871 under the 24,576-byte EIP-170
  limit) — Phase 3 adds no contract code, so the size does not move.

## 0. The operability gap Phase 3 closes

Phases 1–2 built a guard that works on-chain and proved it on forks:
oracle-fed prices with a TWAP cross-check, a 24-hour timelock, a keeper
set, throttle mode, hour/day velocity windows, a health-factor floor and
a reserve-drain cap for Aave V3 and Uniswap V3 adapters — 237/239 tests
passing, adapters proven on an Arbitrum One fork (AaveFork 13/13,
UniswapV3Fork 7/7). What does not exist yet is the part that makes the
guard *operable* by a real protocol team:

1. **Nobody is watching.** The keeper role exists on-chain (up to 10
   keepers per policy, any keeper may `throttle` or `trip`), but no
   process watches the guard's state and acts on it. A keeper nobody
   watches is a breaker nobody trips (`INTEGRATION.md` §8 says so
   plainly). Phase 3 builds the watcher — and constrains it, so the
   watcher itself cannot become the attack.
2. **Nothing shows the live deployment.** The Sepolia deployment is live
   (20 Nov 2026, §5) but the frontend has no page for it: its env config
   still has no Sepolia addresses, and its generated ABI is still the v1
   ABI (§2.6, §6). A judge who opens the app today sees a local-Anvil
   demo, not the live chain.
3. **No video covers the whole system.** The 90-second spine in
   `DEMO-SCRIPT.md` covers the v1 drain and price-push only. It says
   nothing about the adapters, the keeper, or the dashboard — the three
   things that distinguish this submission from a two-rule demo.
4. **No submission package exists.** The São Paulo Open House deadline
   is 28 Feb 2027. The repo, docs, demo links and test evidence are
   scattered across this workspace; nothing assembles them into the
   checklist a submission needs.

Phase 3 is deliberately the smallest phase that closes those four gaps.
It adds no new invariant, no new rule, no new contract. If a Phase 3
item needs a contract change to work, that item is out of scope and goes
in §7 as an open question — the spec does not smuggle a Phase 4 in
through the back door.

## 1. Keeper bot

### 1.1 What it is — and what it is not

`keeper/` is a Node/TypeScript watcher (viem, no framework) that polls
the live guard on Arbitrum Sepolia and, when a trigger rule fires (§1.4),
calls `throttle()` — and only in the narrow, separately gated case in
§1.4, `trip()` — from a dedicated testnet-only keeper key. It is the
off-chain half of the graduated response Phase 1 specified ("the keeper
bot's first response to an anomaly is throttle; its second, if the
anomaly confirms, is trip", Phase 1 §2.3).

It is **not** an AI anomaly detector, not a monitoring dashboard, and
not a second guard. It evaluates deterministic thresholds over on-chain
state it reads itself. It does not decide that something "looks
suspicious" in any fuzzy sense; every action it takes names the rule,
the numbers that fired it, and the transaction it sent. If it cannot
name those three things, it does not act.

It is also **not** the primary mechanism. The guard reverts exploit
transactions on-chain with no bot involved — that is the whole point of
ArbGuard (`ARCHITECTURE.md`: "No auto-pause by an off-chain bot as the
primary mechanism"). The bot exists for the cases the guard cannot close
by itself: a slow bleed under the per-block cap (bounded by the hour/day
windows, but still worth throttling early), an oracle that has gone
stale or started disagreeing, and a confirmed incident that needs the
breaker tripped before a human is at a keyboard. If the bot is down, the
guard still works. That sentence must be true of the shipped bot, and
the runbook (§1.7) must say so.

### 1.2 Layout and stack

```
keeper/
  package.json          # viem, dotenv, typescript; no framework, no DB
  tsconfig.json
  .env.example          # every variable below, blank placeholders only
  src/
    index.ts            # entry: load config, verify keeper, start loop
    config.ts           # env parsing + validation (fails fast, §1.3)
    guard.ts            # viem reads: getPolicy, getMode, getKeepers,
                        #   outflow windows, getReferencePrice, balances
    triggers.ts         # pure trigger evaluation (§1.4) — no I/O, unit-tested
    actions.ts          # throttle/trip sends, dry-run path, receipts
    events.ts           # getLogs polling for CheckPassed / BreakerTripped /
                        #   ThrottleSet / PolicyUpdate* from DEPLOY_BLOCK
    log.ts              # structured JSON logs, one line per decision (§1.6)
  test/
    triggers.test.ts    # table-driven: every rule in §1.4, fire + no-fire
  README.md             # runbook (§1.7), condensed for the operator
  RUNBOOK.md            # full runbook (§1.7)
```

Stack decisions (normative):
- **viem only** for chain access (the frontend already uses viem/wagmi;
  one client library across the repo). No ethers, no web3.js.
- **Polling, not subscriptions.** The bot polls on a fixed interval
  (§1.3) and uses `getLogs` with an explicit block range per poll. A
  websocket subscription that silently drops is a watcher that stops
  watching without saying so; a poll loop that fails logs an error every
  cycle and is visible. `watchContractEvent` is not used.
- **No database.** State is (a) the chain itself, (b) a JSON log file
  the operator can grep, (c) an optional append-only decisions log
  (`keeper/decisions.log`, one JSON line per evaluation — see §1.6).
  The bot re-derives everything it needs from chain reads on each
  cycle, so restarting it loses nothing.
- **Single process, single chain, single guard.** One bot watches one
  `ArbGuard` deployment (Sepolia by default; an Arbitrum One fork for
  testing, §1.8). Watching two chains from one process is out of scope.
- **TypeScript, strict mode.** The trigger rules are the safety-critical
  surface; they live in `triggers.ts` as pure functions over a plain
  state object, so they are unit-testable without a chain (§1.8).

### 1.3 Configuration

All configuration is environment variables; there are no hard-coded
addresses, thresholds or keys in source. `.env.example` lists every
variable with a blank placeholder. `.env` is gitignored (same rule as
`contracts/.env` — never commit it, never print it).

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `KEEPER_RPC_URL` | yes | — | RPC endpoint. Sepolia: `https://sepolia-rollup.arbitrum.io/rpc`. Fork testing: the local Anvil fork URL. |
| `KEEPER_GUARD_ADDRESS` | yes | — | ArbGuard address. Sepolia: `0x9D733954c71920a51291d730fc48422d94d5C306`. |
| `KEEPER_CHAIN_ID` | yes | `421614` | `421614` Sepolia, `42161` One, `31337` fork. The bot asserts the chain id it connects to matches this value and exits if it does not. |
| `KEEPER_PRIVATE_KEY` | yes, unless dry-run | — | **Testnet-only keeper key.** A fresh key, funded with a small Sepolia ETH balance, registered as a keeper via `addKeeper` by the owner. NEVER the deployer/owner key, NEVER the fresh bounty wallet (`0xc7ba…`), NEVER the compromised wallet (`0x5978…`). See §1.5. |
| `KEEPER_POLICY_IDS` | no | `0,1` | Comma-separated policy ids to watch. Sepolia: `0` (GuardedVault), `1` (GuardedPool). |
| `KEEPER_DEPLOY_BLOCK` | no | `earliest` | First block for event scans (same value as the frontend's `NEXT_PUBLIC_DEPLOY_BLOCK`, §2.5). |
| `KEEPER_POLL_SECONDS` | no | `30` | Poll interval. Range 10–300; below 10 is rejected (RPC discipline, §1.6). |
| `KEEPER_DRY_RUN` | no | `true` | **Default true.** When true, the bot logs what it WOULD do and sends nothing (§1.5). Live mode requires explicitly setting `KEEPER_DRY_RUN=false`. |
| `KEEPER_ALLOW_TRIP` | no | `false` | **Default false.** When false, the bot may throttle but never trip, even if a trip rule fires — it logs `TRIP_BLOCKED_BY_CONFIG` instead. Trip requires explicitly setting `KEEPER_ALLOW_TRIP=true` (§1.4). |
| `KEEPER_THROTTLE_SECONDS` | no | `86400` | Duration passed to `throttle()` (24 h). Range 3600–604800. `0` (indefinite) is rejected: a bot throttle must always expire on its own. |
| `KEEPER_HOUR_USE_PCT` | no | `80` | §1.4 rule T1 threshold (percent of the hour cap). Range 50–95. |
| `KEEPER_DAY_USE_PCT` | no | `80` | §1.4 rule T2 threshold. Range 50–95. |
| `KEEPER_LARGE_PASS_PCT` | no | `50` | §1.4 rule T3 threshold (one `CheckPassed` amountOut as a percent of the block cap). Range 25–90. |
| `KEEPER_ORACLE_FAIL_POLLS` | no | `3` | §1.4 rule T4: consecutive failed `getReferencePrice` polls before acting. Range 1–10. |
| `KEEPER_LOG_FILE` | no | `decisions.log` | Append-only JSON decisions log, relative to `keeper/`. |

Startup validation (fails fast, exits non-zero, logs the reason):
- `KEEPER_GUARD_ADDRESS` is a valid address and has code on the
  configured chain (`eth_getCode` != `0x`); otherwise exit — a bot
  pointed at an empty address would watch nothing and say nothing.
- The keeper address derived from `KEEPER_PRIVATE_KEY` (when not
  dry-run) is in `getKeepers(policyId)` for every watched policy;
  otherwise exit with `KEEPER_NOT_REGISTERED` — the bot must never run
  live and discover at 3 a.m. that it cannot call `throttle()`.
  In dry-run mode this check is a warning, not an exit: dry-run must
  work before the keeper is registered.
- The chain id read from the RPC matches `KEEPER_CHAIN_ID`; otherwise
  exit — a Sepolia key must never send on mainnet by misconfiguration.
- `KEEPER_POLL_SECONDS`, thresholds and durations are inside their
  ranges above; otherwise exit with the offending variable named.

### 1.4 Trigger rules (normative)

The bot evaluates these rules once per poll cycle, per watched policy,
in the order below. The first rule that fires wins for that cycle; the
bot takes at most **one action per policy per cycle** (one throttle or
one trip), then logs the decision and moves on. Evaluation order matters
because a trip rule must not be shadowed by a throttle rule on the same
cycle.

State the bot reads each cycle, per policy (all via viem `readContract`
/ `multicall`, batched where the client supports it — one batch per
policy per cycle, not one call per field):
- `getPolicy(policyId)` (caps, `throttleBps`, `cooldownSeconds`,
  `enabled`), `getMode(policyId)` (effective mode, auto-expiry applied),
  `getKeepers(policyId)`, `outflowInBlock` + `outflowBlock`,
  `outflowInHour` + `outflowHour`, `outflowInDay` + `outflowDay`,
  `pausedUntil`, `throttleUntil`, `getPriceConfig(policyId)`,
  `getReferencePrice(policyId, mWETH, mUSDC)` and the reverse direction
  (a swap pair the policy actually prices; on Sepolia this reverts
  `ORACLE_UNAVAILABLE` — see rule T4 and §2.4).
- Events since the last cycle (`getLogs`, `CheckPassed` for the policy,
  `BreakerTripped`, `ThrottleSet`, `ThrottleCleared`, `BreakerReset`,
  `PolicyUpdateProposed` / `PolicyUpdateExecuted`,
  `OracleConfigUpdateProposed` / `OracleConfigUpdateExecuted`).
- Vault/pool balances for context (not a trigger input by themselves):
  `balanceOf` of mWETH/mUSDC at the guarded vault and pool.

**Preconditions (checked before any trigger, every cycle).** If any
holds, the bot takes no action for that policy this cycle and logs why:
- P1. `getMode` is `PAUSED` → no action (the breaker is already doing
  the strongest thing). Log `SKIP_ALREADY_PAUSED` with `pausedUntil`.
- P2. `getMode` is `THROTTLED` and `throttleUntil` is in the future (or
  `0`, indefinite) → no action (already degraded; re-throttling would
  only reset the clock). Log `SKIP_ALREADY_THROTTLED`.
- P3. Policy `enabled == false` → no action. Log `SKIP_DISABLED`.
- P4. The last action the bot took for this policy was less than
  `KEEPER_POLL_SECONDS * 2` ago and the mode has not changed since →
  no action (anti-flap: one throttle per incident, not one per poll).
  The bot records its own last-action timestamp per policy in memory
  (and in the decisions log); a restart clears it, which is acceptable
  because P2 also guards against re-throttling.

**Throttle rules (first response).** Any one firing causes a
`throttle(policyId, KEEPER_THROTTLE_SECONDS, evidence)` call (or a
dry-run log line). `evidence` is the UTF-8 bytes of a short string
naming the rule and the numbers, e.g.
`"keeper-bot T1 hour-use 84% policy 0"`. The evidence string is part of
the on-chain record (`ThrottleSet` carries no evidence field — the
`throttle()` call's `evidence` argument is stored only in the
transaction input data, so the same string must also appear in the
bot's log line; the log is the readable copy).

| Rule | Condition (per policy, per cycle) | Why it fires |
|---|---|---|
| T1 — hour-window burn | `outflowInHour / maxOutflowPerHour >= KEEPER_HOUR_USE_PCT%` (default 80%), with `maxOutflowPerHour > 0` and the hour window current (`outflowHour == block.timestamp / 3600`) | A slow bleed under the block cap. At 80% of the hour cap the hour window will bind within minutes if the rate holds; throttling to 10% caps buys the owner a day to look. Demo numbers (policy 0: hour cap 2,000 ether): fires at 1,600 ether in the current hour. |
| T2 — day-window burn | `outflowInDay / maxOutflowPerDay >= KEEPER_DAY_USE_PCT%` (default 80%), with `maxOutflowPerDay > 0` and the day window current | Same shape over a day. Fires later than T1 by construction; if T1 already throttled, P2 suppresses this. It matters when the hour window rolls over mid-bleed and T1 resets. |
| T3 — large passing action | A `CheckPassed` event in this cycle with `amountOut >= KEEPER_LARGE_PASS_PCT%` (default 50%) of the effective block cap, on a policy whose mode is NORMAL | One legitimate-looking action took half the block's allowance. It passed — the guard did not object — but the concentration is worth degrading limits for. Note the deliberate asymmetry: a *passing* large action is a throttle signal; a *reverted* action is not (see the box below). |
| T4 — oracle blind | `getReferencePrice` for the policy's swap pair reverts (or returns unusable) for `KEEPER_ORACLE_FAIL_POLLS` (default 3) consecutive polls, where the previous poll cycle succeeded | The price rule cannot see. On a chain with a configured pair, swaps already fail closed (`ORACLE_UNAVAILABLE`), so this is not about swaps — it is about withdrawing and borrowing while the protocol is flying blind on price. Throttle the outflow caps until the oracle is back. On Sepolia this rule can NEVER arm: the pair is unconfigured, so `getReferencePrice` returns unusable on every poll with no prior successful probe (see the Sepolia note below). The bot must therefore NOT run T4 against Sepolia policy 1 — it is disabled there (`KEEPER_ORACLE_FAIL_POLLS=0`). |
| T5 — timelock proposal | A `PolicyUpdateProposed` (or `OracleConfigUpdateProposed`) event appears for a watched policy, and the bot has not already logged it | Not a throttle by itself: a proposed limit change is the owner acting, and the 24-hour timelock is the protection. The bot logs `PROPOSAL_SEEN` with `executableAt` and alerts (log level `warn`), so a compromised-owner proposal is noticed during the timelock window instead of after execution. It does NOT throttle on a proposal — throttling the owner's own proposal would be the bot fighting the owner. If the proposal is hostile, the response is human (revoke the owner key, cancel via `cancelPolicyUpdate`), not automatic. |

**Trip rules (second response, gated).** A trip rule firing causes a
`trip(policyId, evidence)` call ONLY if `KEEPER_ALLOW_TRIP=true`;
otherwise the bot logs `TRIP_BLOCKED_BY_CONFIG` (level `warn`) with the
rule and the numbers, and takes no on-chain action. The default
deployment is throttle-only. Trip is a breaker that pauses the protocol;
it must never be the bot's first idea.

| Rule | Condition | Why it fires |
|---|---|---|
| R1 — confirmed drain shape | T1 or T2 fired AND a `CheckPassed` event in the same cycle shows an outflow that would have been a drain on the *unguarded* control (same amount withdrawn from the unguarded vault/pool in the same window — read the control's balances/events) | Two independent signals: the guarded policy is burning its window AND the same actor is draining the control. One signal is an anomaly; two is an incident. |
| R2 — oracle disagreement storm | `getReferencePrice` reverts `ORACLE_DISAGREEMENT` for `KEEPER_ORACLE_FAIL_POLLS` consecutive polls AND a swap attempt reverted `ORACLE_DISAGREEMENT` in the same window (observed via a failed transaction receipt the operator reports, or via `simulateCheck` returning `(false, ORACLE_DISAGREEMENT)` for a live swap the bot probes with the current pool price) | The two oracle sources disagree persistently while swaps are being attempted — the price the guard would enforce is contested. Trip until a human decides which source to trust. |
| R3 — manual | The operator runs the bot once with `KEEPER_TRIP_ONCE=<policyId>` (a one-shot env var, §1.7) | A human has confirmed an incident off-chain and wants the breaker tripped without opening a console. The bot verifies the caller is a registered keeper, sends one `trip()`, logs it, and exits. This is the only trip path that does not need two signals. |

**The rule the bot must NEVER implement.** The bot must NOT auto-trip
(or auto-throttle) on a `CheckPassed` revert — i.e. on a transaction
that reverted with `ArbGuardViolation`. There is no on-chain event for
a reverted check (see the header constraints), so the bot cannot observe
reverts from event logs at all; and even if it could (by watching
failed receipts or `simulateCheck` returning `(false, reason)`), a
revert is the guard *working*, not an incident. A drain attempt that
reverts moved zero funds. Treating reverts as incidents would let an
attacker trip the breaker at will by spamming failing transactions —
a griefing vector that turns the guard's success into a denial of
service. The spec states this as a normative prohibition, not a
suggestion: any implementation that trips on revert observations is
non-compliant. `simulateCheck` is used by the bot only as a *read* for
rule R2's probe (and the probe result is logged, never acted on alone).

**Sepolia note (T4).** On Sepolia the ETH/USD feed
`0xbF13EE58Bf62500FE87e7389faB633ff95dec029` is stale
(`updatedAt` 1729103473, 16 Oct 2024). CORRECTION 20 Nov ~19:00 WAT
(verified live by the coordinator and both Phase 3 implementation
agents): `getReferencePrice` for the WETH/USDC pair does NOT revert —
it returns `(0, address(0))`, because the pair is unconfigured (mUSDC
has no feed, no TWAP pool), so the price rule is skipped and swaps
pass. `ORACLE_UNAVAILABLE` only fires for a *configured* pair whose
sources read unusable (proven in the SepoliaFork test with a mock USDC
feed completing the pair — not on the live deploy). The probe is
therefore unusable on every Sepolia poll, and T4 additionally requires
a prior successful probe, so T4 can never arm on Sepolia. The Sepolia
deployment runs with T4 **disabled** (`KEEPER_ORACLE_FAIL_POLLS=0`,
meaning off — `0` is the only out-of-range value the config accepts
for this variable, documented here so the `1–10` range in §1.3 reads
as "1–10, or 0 to disable"). The stale-feed state is instead displayed
on the dashboard (§2.4) as the expected, by-design condition it is.
T4 is re-enabled only on a chain with a fresh feed (Arbitrum One, or
a Sepolia deployment with a mock feed — see §7 Q1).

**Threshold rationale.** The defaults (80% window burn, 50% large-pass,
3 failed oracle polls, 24-hour throttle) are chosen so the bot acts
*before* a window binds but *after* normal activity: a legitimate user
rarely takes 80% of an hour's allowance, and never takes 50% of a
block cap in one passing call without being a whale the owner wants to
know about. The thresholds are env-tunable because the right values
depend on the protocol's real traffic, which the demo does not have.
The implementation must log the threshold values at startup so a later
audit can reproduce any decision from the log alone.

### 1.5 Safety design

- **Least privilege by construction.** The keeper key can only
  `throttle` and `trip` (plus read). It cannot `reset`, `unthrottle`,
  change a policy, manage keepers, or move funds. The worst a
  compromised keeper key can do is pause one policy for one cooldown
  (trip) or degrade its caps for 24 hours (throttle) — a denial of
  service, not a theft. The owner removes the compromised keeper with
  `removeKeeper` (immediate, owner-only) and the bot is re-keyed. The
  runbook (§1.7) gives the exact commands.
- **Testnet-only key, small balance.** The keeper key is generated
  fresh for this purpose, funded with only enough Sepolia ETH for weeks
  of `throttle`/`trip` calls (each is a single cheap transaction; at
  Sepolia gas prices a 0.01 ETH balance is many months of operation).
  It is never the deployer key (the deployer is the owner — holding it
  would let a bot compromise rewrite policies), never a wallet that
  holds real funds, never reused across chains. The key lives in
  `keeper/.env` (gitignored, mode 600) and nowhere else — not in the
  repo, not in the frontend env, not in a chat log.
- **Dry-run is the default.** `KEEPER_DRY_RUN` defaults to `true`.
  A fresh checkout that runs the bot does nothing on-chain until the
  operator explicitly opts into live mode. The dry-run path logs the
  exact transaction it *would* send (function, policyId, duration,
  evidence string, estimated gas) and the trigger that caused it.
  The operator's first live run must be preceded by a dry-run run that
  shows at least one full poll cycle with no unexpected decisions.
- **No secret leaves the process.** The bot never logs the private key,
  never sends it anywhere, never includes it in an error message. A log
  line that contains a key is a bug, not a debugging aid.
- **Fail-closed on RPC trouble.** If a poll cycle's reads fail (RPC
  error, timeout, chain-id mismatch), the bot logs the error and
  retries next cycle. It never acts on partial state: a trigger
  evaluation that is missing any input it needs is skipped for that
  cycle with `SKIP_PARTIAL_STATE`. It never trips on the *absence* of
  data.
- **Rate discipline.** One batched read per policy per poll cycle, one
  `getLogs` call per cycle (bounded block range), at most one write per
  policy per cycle, poll interval ≥ 10 s. That is ≤ ~4 requests/second
  by construction, within the API discipline in the repo (Etherscan /
  Alchemy quotas are separate budgets; the bot uses the public RPC by
  default and must stay under ~4 req/sec against it too). No retries on
  429: on a 429 the bot backs off one full poll interval and logs it.
- **Idempotency.** Preconditions P1–P4 (§1.4) make every action safe to
  re-evaluate: a throttle that already landed suppresses the next one,
  and a trip that already landed suppresses everything until the
  cooldown passes. The bot never sends the same action twice for one
  incident.

### 1.6 Observability

Every poll cycle appends one JSON line per watched policy to
`keeper/decisions.log` (and to stdout), with exactly these fields:

```json
{
  "ts": "2026-11-20T19:00:00.000Z",
  "chainId": 421614,
  "guard": "0x9D733954c71920a51291d730fc48422d94d5C306",
  "policyId": 0,
  "mode": "NORMAL",
  "decision": "NO_ACTION",
  "reason": "T1 hour-use 12% < 80%",
  "hourUsePct": 12,
  "dayUsePct": 3,
  "blockUsePct": 5,
  "dryRun": true,
  "txHash": null
}
```

`decision` is one of `NO_ACTION`, `WOULD_THROTTLE` (dry-run),
`THROTTLE_SENT`, `WOULD_TRIP` (dry-run), `TRIP_SENT`,
`TRIP_BLOCKED_BY_CONFIG`, `SKIP_ALREADY_PAUSED`,
`SKIP_ALREADY_THROTTLED`, `SKIP_DISABLED`, `SKIP_PARTIAL_STATE`,
`PROPOSAL_SEEN`, `ERROR`. `reason` always names the rule and the
numbers. `txHash` is set when a transaction was actually sent.
Startup logs one line with the full (non-secret) config: guard address,
chain id, policy ids, thresholds, dry-run flag, allow-trip flag. No
line ever contains the private key.

Alerting: the bot has no alerting channel in this phase (no email, no
webhook, no Telegram — see §7 Q7). The decisions log is the alerting
surface: the operator tails it, and any `THROTTLE_SENT` / `TRIP_SENT` /
`TRIP_BLOCKED_BY_CONFIG` / `PROPOSAL_SEEN` line is the signal. A future
phase may add a webhook that posts exactly those four decision types
and nothing else; it must not post every `NO_ACTION` line.

### 1.7 Runbook

`keeper/RUNBOOK.md` is the operator's document. It must contain, in
this order: prerequisites (Node 20+, Sepolia ETH for the keeper key,
owner available to run `addKeeper`); setup (copy `.env.example`, fill
the five required variables, `npm install`); dry-run first (run with
defaults, confirm one full cycle logs `NO_ACTION` and the startup
config line, then force a trigger in dry-run against a fork — §1.8);
going live (owner runs `addKeeper`, operator sets
`KEEPER_DRY_RUN=false`, restarts, confirms the startup line shows
`dryRun: false`); the incident playbook (below); recovery (owner
`unthrottle` / `reset` commands with `cast`, and the fact that a
throttle auto-expires after `KEEPER_THROTTLE_SECONDS` while a trip
auto-resumes after `cooldownSeconds`); key rotation (generate a new
key, fund it, owner `addKeeper` for the new key, owner `removeKeeper`
for the old key, update `keeper/.env`, restart — in that order, so
there is never a moment with no keeper); and shutdown (stop the
process; the guard keeps working — say so explicitly).

Incident playbook (the runbook's core, verbatim in intent):
1. The bot throttles (or the operator sees `TRIP_BLOCKED_BY_CONFIG`).
   Do not immediately unthrottle. Read the decision log line: it names
   the rule and the numbers.
2. Check the dashboard (§2) and Arbiscan: which policy, what outflow,
   which addresses, is the unguarded control also moving?
3. If it is a false positive (a legitimate whale, a known large
   withdrawal), the owner runs `unthrottle(policyId)` (owner-only,
   immediate) and the operator notes the thresholds to tune.
4. If it is a real incident and the bot only throttled (default), a
   human trips the breaker: `cast send <guard> "trip(uint256,bytes)"
   <policyId> 0x<evidence>` from a keeper or owner key — or re-run the
   bot once with `KEEPER_TRIP_ONCE=<policyId>` (§1.4 R3). Never trip
   from the bot's key by hand unless that key is a registered keeper.
5. After the incident, the owner `reset(policyId)`s once the cooldown
   has passed (reset before the cooldown reverts `BreakerStillActive`),
   or waits for auto-resume. `reset()` returns to NORMAL, not to
   THROTTLED (Phase 1 §2.3 decision); re-throttle with one call if the
   worry persists.
6. Post-mortem: append the incident to the decisions log's human-readable
   companion (`keeper/INCIDENTS.md`, one section per incident: date,
   rule, numbers, action, outcome). The bot does not write this file;
   the operator does.

### 1.8 Test plan (keeper bot)

- `test/triggers.test.ts` (table-driven, no chain): for every rule in
  §1.4, a fire case and a no-fire case at the boundary (hour-use 79%
  vs 80%, 80% vs 81%; large-pass 49% vs 50%; oracle failures 2 vs 3
  consecutive polls); preconditions P1–P4 each suppressing an otherwise
  firing rule; the never-rule (a revert observation must not produce
  any action — assert the trigger module has no code path that takes a
  revert as an input); evidence strings contain the rule id and the
  numbers.
- Fork test (Foundry Anvil fork of Sepolia, or local Anvil with the
  demo contracts): start the bot in dry-run against the fork, drive
  outflow to 85% of the hour cap via the Attacker contract, assert the
  bot logs `WOULD_THROTTLE` with rule T1 and sends nothing; then run
  with `KEEPER_DRY_RUN=false` and a funded keeper key, assert a real
  `ThrottleSet` event lands and the policy reads THROTTLED with the
  configured `throttleUntil`; assert a second cycle logs
  `SKIP_ALREADY_THROTTLED` and sends nothing.
- Negative fork test: run the drain attack against the guarded vault
  (it reverts), assert the bot takes no action — the revert is the guard
  working, and the bot's log shows `NO_ACTION` for those cycles.
- Config test: missing `KEEPER_GUARD_ADDRESS` exits non-zero; a guard
  address with no code exits non-zero; a keeper key not registered
  exits non-zero in live mode and warns in dry-run; a chain-id mismatch
  exits non-zero; `KEEPER_POLL_SECONDS=5` exits non-zero.
- The bot's test evidence is recorded in §4.4 when run; the spec
  requires the fork test above to exist before the bot is called done,
  not after.

## 2. Live dashboard

### 2.1 What it is

A new page, `apps/web/app/dashboard/page.tsx` (route `/dashboard`),
that shows the live Sepolia deployment: the guard, its two policies,
the vault/pool balances, recent guard events, and the Sepolia stale-feed
state. It extends the existing frontend — it does not replace the
simulator (`/simulator`), the policy form (`/policies`) or the event
feed (`/feed`). The dashboard is the *read-only* view of the live
system; the simulator stays the place where attacks are run, and the
policy form stays the place where policies are changed (timelocked,
owner-only).

Design rules (normative):
- **Live reads only.** Every number comes from a viem/wagmi read
  (`useReadContract` / `useReadContracts` for state, `getLogs` via the
  public client for events) against `NEXT_PUBLIC_RPC_URL` on chain
  `421614`. No hard-coded balances, caps, modes or prices anywhere in
  the page. The only hard-coded values are the contract addresses from
  env (§2.5) and the display labels.
- **Gated on `isDeployed`.** When `isDeployed` is false (env not set),
  the page shows the not-deployed state with the exact env vars that
  are missing — the same gating the live paths already use
  (`lib/contracts.ts`). It never shows placeholder numbers.
- **Honest about reverts.** The page must not show blocked attacks as
  on-chain events. It shows (a) persistent events (§2.3), (b) the
  simulator's locally recorded blocked attempts (the existing
  `BLOCKED_ATTEMPTS_KEY` localStorage mechanism in `contracts.ts`),
  labelled as "recorded in this browser session", and (c) the stale-feed
  state (§2.4) as an expected condition, not an error.
- **Refreshes without a reload.** Reads refresh on a 30-second poll
  (wagmi `refetchInterval: 30_000`); the events list refreshes with the
  same poll. No manual refresh button is the primary mechanism, though
  one may exist.

### 2.2 Panels and data sources

| Panel | Contents | Data source (all live) |
|---|---|---|
| Header | Guard address (link to Sepolia Arbiscan), chain `421614`, owner address, `isDeployed` state, last refresh time | `owner()` read; env addresses; `CONTRACT_ADDRESSES` |
| Policy 0 — GuardedVault | Mode badge (NORMAL / THROTTLED / PAUSED, from `getMode`), enabled flag, caps: block / hour / day (raw token units, mWETH 18 dec), single-share bps, price-deviation bps, `throttleBps`, cooldown, timelock delay, keepers list, `pausedUntil` / `throttleUntil` (human time, or "—"), effective caps when THROTTLED (registered × throttleBps, shown alongside the registered caps, labelled as effective) | `getPolicy(0)`, `getMode(0)`, `getKeepers(0)`, `getPriceConfig(0)`, `pausedUntil(0)`, `throttleUntil(0)` |
| Policy 1 — GuardedPool | Same fields as policy 0, for the pool | `getPolicy(1)`, `getMode(1)`, `getKeepers(1)`, `getPriceConfig(1)`, `pausedUntil(1)`, `throttleUntil(1)` |
| Balances | GuardedVault mWETH (+ mUSDC if held), UnguardedVault mWETH, GuardedPool mWETH / mUSDC reserves, UnguardedPool reserves, Attacker mWETH balance + shares in each vault | `balanceOf` on mWETH/mUSDC per holder; `shares` / `totalShares` on the vaults; `reserve0` / `reserve1` on the pools |
| Outflow windows | Current block / hour / day cumulative outflow per policy, with the window id (block number, hour id, day id) and the utilisation percent against each cap (a bar, not just a number) | `outflowInBlock` + `outflowBlock`, `outflowInHour` + `outflowHour`, `outflowInDay` + `outflowDay` per policy |
| Oracle / stale-feed | Sepolia ETH/USD feed address, latest answer, `updatedAt` (human date), staleness (age in days), `getReferencePrice` result — returns `(0, address(0))` because the pair is unconfigured, so the price rule is skipped and swaps pass (CORRECTED 20 Nov, see §2.4) — displayed as "stale feed, pair unconfigured: price rule skipped", not as an error banner; note that no USDC/USD and no sequencer feed exist on Sepolia | Direct `latestRoundData()` read on `0xbF13EE58Bf62500FE87e7389faB633ff95dec029`; `getReferencePrice(1, mWETH, mUSDC)` call (display the returned price and source) |
| Recent events | Last 20 guard events, newest first: `PolicyRegistered`, `CheckPassed`, `BreakerTripped`, `BreakerReset`, `ThrottleSet`, `ThrottleCleared`, `KeeperAdded`, `KeeperRemoved`, `PolicyUpdateProposed`, `PolicyUpdateExecuted`, `OracleConfigSet`; each row: event name, policyId, block number, transaction hash (Arbiscan link), human time | `getLogs` from `DEPLOY_FROM_BLOCK` to latest, filtered to the guard address, decoded with the regenerated ABI (§2.6); `CheckPassed` rows show kind + amountOut |
| Blocked attempts (this browser) | The simulator's locally recorded blocked attempts (revert reason, attack, target, tx hash), labelled "recorded in this browser session — reverted transactions leave no on-chain event" | Existing `BLOCKED_ATTEMPTS_KEY` localStorage mechanism; no chain read |
| Keeper status | Keeper bot state as the *bot* reports it — see §2.3 note. Until the bot exposes a status endpoint, this panel shows the on-chain facts only: keeper addresses per policy (from `getKeepers`), and whether a throttle/trip is currently active. It must not claim the bot is running. | `getKeepers(policyId)`, `getMode`, `throttleUntil`, `pausedUntil` |

**Keeper-status note (read this).** The dashboard cannot know whether
the bot process is alive — there is no bot endpoint in this phase, and
inventing one ("bot: online") from the absence of on-chain events would
be a lie of the same shape as the `ViolationBlocked` lie. The panel
shows only what the chain proves (who the keepers are, whether a
throttle/trip is active) and, if the operator wants a liveness signal,
links to the decisions log (§1.6). A future phase may add a bot status
endpoint the dashboard polls; until then the panel says "bot status:
unknown — see keeper/decisions.log" when no endpoint is configured.
That sentence is a feature, not a gap to paper over.

**Empty-state rule.** When a policy has no events yet, or a balance is
zero, the panel shows the zero honestly ("0 events since deploy block",
"0 mWETH") — never a spinner that never resolves, never a cached
number from a previous session.

### 2.3 Events — what the dashboard can and cannot show

The dashboard's event list is `getLogs` over the real guard events.
The full set it decodes (after the ABI regeneration in §2.6):
`PolicyRegistered`, `PolicyUpdated`, `PolicyEnabled`,
`PolicyUpdateProposed`, `PolicyUpdateExecuted`, `PolicyUpdateCancelled`,
`KeeperAdded`, `KeeperRemoved`, `ThrottleSet`, `ThrottleCleared`,
`CheckPassed`, `BreakerTripped`, `BreakerReset`, `OracleConfigSet`,
`OracleConfigRemoved`, `OracleConfigUpdateProposed`,
`OracleConfigUpdateExecuted`, `OracleConfigUpdateCancelled`,
`PriceConfigUpdated`. It scans from `NEXT_PUBLIC_DEPLOY_BLOCK` (§2.5),
in bounded ranges (the viem `getLogs` block-range limit for the public
RPC is respected by chunking the scan — the implementation must chunk,
not request the whole range in one call).

What it cannot show, and must say so on the page (one line under the
events list, not buried in a doc): blocked attacks. A reverted
`check()` leaves no event. The blocked-attack evidence is the
simulator's receipt panel and the locally recorded attempts (§2.2),
and the video (§3) shows the receipt, not the feed, as the proof.

### 2.4 The Sepolia stale-feed state (displayed, not hidden)

The dashboard's oracle panel is the one place in the product where the
Sepolia deployment looks "broken" to a fresh eye: the ETH/USD feed
answers $2,626.84 with `updatedAt` 1729103473 (16 Oct 2024). CORRECTION
20 Nov ~19:00 WAT (verified live by the coordinator and both Phase 3
implementation agents): the pool pair is UNCONFIGURED (mUSDC has no
feed, no TWAP pool), so `getReferencePrice(1, mWETH, mUSDC)` returns
`(0, address(0))` instead of reverting, the price rule is skipped, and
swaps on the deployed Sepolia pool PASS — a 1,000 mWETH swap and even a
40% price push pass. The earlier claim that "every swap check fails
closed with `ORACLE_UNAVAILABLE`" is WRONG for this deployment:
`ORACLE_UNAVAILABLE` only fires for a *configured* pair whose sources
read unusable, which was proven in the SepoliaFork test (mock USDC feed
completing the pair), not on the live deploy. The panel must present
the honest state: the feed is stale (last update 16 Oct 2024), the pair
is unconfigured so the price rule is skipped, and the staleness guard
itself is proven in the fork tests, not by the live Sepolia swaps. It
must also state the two absences: no USDC/USD feed and no sequencer
feed exist on Sepolia, so the Sepolia deployment prices ETH/USD only,
and skips the sequencer check (`sequencerFeed == address(0)`). A visitor
who reads only this panel should understand why the guarded pool's swap
path does NOT revert on Sepolia and why that is the honest consequence
of an unconfigured pair — not a guard failure.

### 2.5 Frontend env config (live Sepolia addresses)

The dashboard work includes the env config that `SEPOLIA-DEPLOYMENT.md`
records as not done yet. The values below are the live Sepolia
deployment of 20 Nov 2026 (~16:02 WAT). They go in `apps/web/.env.local`
for local dev and in the Vercel dashboard env vars for production —
never committed, never in `.env.example` (which keeps blank placeholders).

```
NEXT_PUBLIC_CHAIN_ID=421614
NEXT_PUBLIC_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
NEXT_PUBLIC_ARB_GUARD_ADDRESS=0x9D733954c71920a51291d730fc48422d94d5C306
NEXT_PUBLIC_GUARDED_VAULT_ADDRESS=0xEa182E47829D76569dc50CcADD2bFafe462A0E3D
NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS=0x68510BE7104F72a40e14ba72dCB2362c5a315148
NEXT_PUBLIC_GUARDED_POOL_ADDRESS=0x3b1714FE7583789C10528dD43Dbb18729269679E
NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS=0x374049DF4b73B381E530805182F94D2cDf0F6826
NEXT_PUBLIC_ATTACKER_ADDRESS=0x590180b5Ab993A1Af5bBDa12Ad430a442091B4C1
NEXT_PUBLIC_MWETH_ADDRESS=0x67984d4a140b32f782A53A76Ba94C1E2aFED299d
NEXT_PUBLIC_MUSDC_ADDRESS=0xF280b7003291045b114937Cd2CFF3FA502bBAe72
NEXT_PUBLIC_DEPLOY_BLOCK=<deploy block — see note below>
```

`NEXT_PUBLIC_DEPLOY_BLOCK` is **not** filled in here, deliberately: the
value was not recorded in `SEPOLIA-DEPLOYMENT.md`, and the broadcast
log's transaction entries do not carry a directly usable block number
in the field checked for this spec. The implementation must derive it
from the deployment itself — the block number of the first deployment
transaction (the ArbGuard creation), read from Sepolia Arbiscan
(`https://sepolia.arbiscan.io/address/0x9D733954c71920a51291d730fc48422d94d5C306`)
or from `contracts/broadcast/DeploySepolia.s.sol/421614/run-latest.json`
— and record the derivation in `DEPLOY-CHECKLIST.md` when it is set.
Do not guess it, do not use a round number, do not leave the dashboard
scanning from genesis ("earliest") in production: a genesis scan on
Sepolia is slow and returns nothing before the deploy block anyway.
Until the value is set, the dashboard's event list shows the
not-configured state for the events panel only.

Policy values the dashboard will display (recorded here so the
implementation can sanity-check its reads, not so it can hard-code
them — the page reads them live; if a live read disagrees with this
table, the live read wins and the table is stale):
- Policy 0 (GuardedVault): block cap 100 ether, hour cap 2,000 ether,
  day cap 10,000 ether (Phase 1 §2.4 demo defaults), single-share
  5000 bps, price-deviation 500 bps, `throttleBps` 1000 (10%),
  cooldown 3600 s, timelock 86400 s, keeper = deployer
  `0xE670974a278A47a0A311dA4Ab780d714acb0EfF0`.
- Policy 1 (GuardedPool): block cap 10,000 ether, hour cap 200,000
  ether, day cap 1,000,000 ether, single-share 10000 bps,
  price-deviation 500 bps, `throttleBps` 1000, cooldown 3600 s,
  timelock 86400 s, keeper = deployer.
(These are the `DEPLOY-CHECKLIST.md` dry-run values as recorded for the
live deploy; the hour/day caps are the Phase 1 demo defaults. The
dashboard must verify them live on first load and the implementer must
correct this table if the live reads differ — the table is a
sanity-check, not a source of truth.)

### 2.6 Frontend ABI regeneration (required, not optional)

`apps/web/lib/contracts.ts` is generated from the compiled Foundry
artifacts (`node scripts/generate-abis.mjs`) — but the checked-in copy
is **stale at v1**. Read on 20 Nov 2026 it still carries the v1 `Action`
struct (with `twapPrice`, without `tokenIn`, `healthFactorAfter` or
`availableLiquidity`), the v1 `Policy` struct (single `keeper` field,
no hour/day windows, no `throttleBps`, no timelock, no
`usdDenominated`, no health-factor/drain fields), the v1
`REASON_NAMES` array (only `NONE`, `OUTFLOW_PER_BLOCK`,
`SINGLE_SHARE`, `PRICE_DEVIATION`, `BREAKER_TRIPPED` — missing
`OUTFLOW_PER_HOUR`, `OUTFLOW_PER_DAY`, `ORACLE_DISAGREEMENT`,
`ORACLE_UNAVAILABLE`, `SEQUENCER_DOWN`, `HEALTH_FACTOR`,
`RESERVE_DRAIN`), the removed `updatePolicy` function, and no
`throttle` / `unthrottle` / `addKeeper` / `removeKeeper` /
`getKeepers` / `getMode` / `getReferencePrice` /
`getPriceConfig` / `getPendingUpdate` entries. The dashboard cannot be
built on this ABI: it cannot read a policy, a mode, a keeper set, or a
reference price, and it would mis-decode every Phase 1/2 event.

Phase 3 therefore requires, as its first frontend step, regenerating
the ABI from the current compiled artifacts:

```bash
cd contracts && forge build && cd ../apps/web && node scripts/generate-abis.mjs
```

and verifying the regenerated `contracts.ts` contains: the Phase 2
`Action` (9 fields) and `Policy` (12 fields) structs; `REASON_NAMES`
with all 13 reasons in enum order (`NONE`, `OUTFLOW_PER_BLOCK`,
`OUTFLOW_PER_HOUR`, `OUTFLOW_PER_DAY`, `SINGLE_SHARE`,
`PRICE_DEVIATION`, `BREAKER_TRIPPED`, `ORACLE_STALE`,
`ORACLE_DISAGREEMENT`, `ORACLE_UNAVAILABLE`, `SEQUENCER_DOWN`,
`HEALTH_FACTOR`, `RESERVE_DRAIN`); `ACTION_KIND_NAMES` unchanged
(`WITHDRAW`, `MINT`, `SWAP`, `BORROW`); the keeper/throttle/timelock/
oracle view functions; and the full event set in §2.3. The regenerated
file is committed; the "GENERATED — do not hand-edit" header stays.
`VAULT_ABI`, `POOL_ABI`, `ATTACKER_ABI` and `TOKEN_ABI` are unaffected
unless the demo contracts changed (they did not in Phase 2 beyond the
two new `Action` fields in their `check()` literals — verify, do not
assume). The adapter ABIs (`AaveAdapter`, `UniswapV3Adapter`) are NOT
added to `contracts.ts` in this phase: the adapters are not deployed to
Sepolia (§5), so the dashboard has no adapter deployment to read. When
an adapter deployment exists, its ABI and addresses are added the same
way — that is a later step, not a Phase 3 shortcut.

### 2.7 Test plan (dashboard)

- Env test: with the Sepolia `.env.local` from §2.5, `isDeployed` is
  true and every address in `CONTRACT_ADDRESSES` is non-zero; without
  it, `isDeployed` is false and the dashboard shows the not-deployed
  state (no placeholder numbers).
- Read test (against a local Anvil fork of Sepolia, or live Sepolia
  read-only): the dashboard's reads return the policy values in §2.5's
  table (or the table is corrected); balances match `cast call`
  `balanceOf` for the same holders; `getMode` returns the live mode;
  `getReferencePrice` for the pool pair reverts `ORACLE_UNAVAILABLE`
  and the oracle panel displays the by-design message, not an error.
- Events test: `getLogs` from the derived deploy block returns the
  deployment's `PolicyRegistered` events (policy 0 and 1) and every
  `CheckPassed` since; the list renders newest-first with Arbiscan
  links that resolve.
- Regression: `npm run build` passes with the regenerated ABI; the
  simulator, policy form and feed pages still build and still work
  against the local Anvil demo (their behaviour is unchanged — the
  dashboard adds a route, it does not edit their pages).
- Mobile check: the dashboard is checked on a phone viewport (the
  user reviews on his phone; mobile fit is a dealbreaker for this
  repo's UIs). Policy cards stack; the events table scrolls
  horizontally rather than overflowing the page.

## 3. Video — demo video plan (script + storyboard, 2–3 min)

### 3.1 Build method (normative)

The video is built the SpendGuard v9 way: **real UI stills + motion
graphics, not a screen recording and not generated video**. Video
generation is not available for this account/region (403, do not retry),
and generated video cannot render a real interface anyway. The build
is: capture real stills from the live frontend (dashboard, simulator,
Arbiscan receipts, Foundry fork-test terminal output), animate them
with slow smooth push-ins and a single cross-dissolve transition style,
short on-screen captions throughout, and a continuous calm-authority
voiceover that opens on the point. No raw screen recording, no jerky
scrolling, no silence while scrolling (the v8 faults from the
SpendGuard video — fixed in v9 — are the checklist here). Captions
carry the story on their own: if no voiceover is recorded,
captions-only is acceptable, exactly as `DEMO-SCRIPT.md` allows.
**Do not generate video in this phase** — this section is the plan
only. Never mention other teams in the video at all.

Assets to capture before editing (all real, none mocked up):
- Dashboard stills (§2): policy cards for policy 0 and 1, balances,
  outflow-window bars, the oracle panel showing the stale feed, the
  events list.
- Simulator stills: unguarded drain receipt (success), guarded drain
  receipt (reverted, `OUTFLOW_PER_BLOCK` highlighted), unguarded
  price-push receipt, guarded price-push receipt (reverted,
  `PRICE_DEVIATION` highlighted) — the same attack code, same starting
  balances, both sides.
- Fork-test terminal output: `AaveFork` 13/13 and `UniswapV3Fork` 7/7
  passing, with the boundary numbers visible (67 vs 68 WETH,
  5,000 vs 5,100 USDC).
- Keeper-bot terminal output: a dry-run cycle logging `WOULD_THROTTLE`
  (T1) and a live `ThrottleSet` event on Arbiscan.
- Arbiscan pages: the guard contract, a `CheckPassed` transaction, a
  `ThrottleSet` transaction. Real links or none — never a placeholder
  address on screen.

### 3.2 Script — 150-second spine (extends the 90-second spine)

The 90-second spine in `DEMO-SCRIPT.md` (segments 1–4) is retained
verbatim as segments 1–3 and the first half of segment 6 below. The
new material is segment 4 (adapters, fork proof) and segment 5 (keeper
bot + dashboard). Total target 150 seconds (2.5 min); hard cap 180
seconds. One continuous take per segment in the source stills; cut
between segments, never mid-attack.

**Segment 1 — The problem (0–15s).** Unchanged from `DEMO-SCRIPT.md`:
title card ("The on-chain circuit breaker for Arbitrum"); "DeFi lost
$1.8 billion to exploits in 2025"; "almost every loss was the same
shape — one transaction that should never have been allowed"; "Same
vault. Same attack. One difference: ArbGuard." On-screen text as in
the 90-second script.

**Segment 2 — Attack 1: the drain (15–45s).** Unchanged from
`DEMO-SCRIPT.md`: unguarded vault drains (receipt: success, balance
~0); guarded vault, same attack, receipt reverted,
`ArbGuardViolation(OUTFLOW_PER_BLOCK)`, balance unchanged. **Key frame
(hold 2s):** the reverted receipt next to the unchanged balance. This
is the whole product in one frame. Do not rush past it.

**Segment 3 — Attack 2: the price push (45–70s).** Unchanged from
`DEMO-SCRIPT.md`: unguarded pool price moves 40%; guarded pool, same
swap, reverted `PRICE_DEVIATION`, price unchanged.

**Segment 4 — Attack 3 and 4: the real protocols (70–110s).** The new
proof segment. It must not fake a live Aave/Uniswap demo — the
adapters are fork-proven, not Sepolia-deployed (§5) — so the visuals
are the fork-test terminal and the adapter code, and the voiceover says
so plainly.

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 70–78s | Terminal: `AaveFork` 13/13 passing; adapter code, `borrow` with the guard check highlighted | "The demo vault is not the point. Real money sits in Aave and Uniswap — so ArbGuard guards those too, through adapters, without changing them." | `Adapters: guard Aave + Uniswap without changing them` |
| 78–88s | Terminal close-up: health-factor boundary — borrow 67 WETH passes, 68 WETH reverts | "Borrow sixty-seven WETH against a hundred supplied, and the health factor holds. Sixty-eight, and the guard reverts it — the position would be liquidatable." | `HEALTH_FACTOR — 67 WETH passes, 68 reverts` |
| 88–98s | Terminal close-up: reserve-drain boundary — borrow 5,000 USDC passes, 5,100 reverts; USDC available ~10,174 | "Aave's USDC reserve is ninety-nine point nine nine percent used. Five thousand out passes. Fifty-one hundred takes more than half of what is left, and reverts." | `RESERVE_DRAIN — 5,000 passes, 5,100 reverts` |
| 98–110s | Terminal: `UniswapV3Fork` 7/7; pool still, `getExpectedOutput` vs actual output | "Same for Uniswap. A swap through the adapter is checked against Chainlink and the pool's own TWAP — and a swap that would drain the pool reverts before it executes." | `UniswapV3Fork 7/7 — TWAP cross-check on the real pool` |

Honesty line for the edit (segment 4): the voiceover must say
"proven on an Arbitrum One fork" — never "live on Aave" or "live on
Uniswap". The adapters are not deployed to any public chain (§5). A
judge who replays the fork test gets the same numbers; a judge who
looks for a Sepolia adapter deployment will not find one, and the video
must not imply otherwise.

**Segment 5 — The keeper bot + dashboard (110–140s).**

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 110–118s | Dashboard still: policy cards, mode badges NORMAL, outflow bars | "And when the guard is live, someone has to watch it. The dashboard shows both policies, their caps, and how much of each window is used — live from Sepolia." | `Live on Sepolia — policies, caps, windows` |
| 118–128s | Terminal: keeper bot dry-run log, `WOULD_THROTTLE` T1, hour-use 84%; then the live `ThrottleSet` event on Arbiscan | "The keeper bot watches the same numbers. When an hour's outflow hits eighty percent, it throttles the policy to ten percent for a day — and logs exactly why." | `Keeper bot — throttle at 80% hour use` |
| 128–140s | Dashboard oracle panel: stale feed, last update 16 Oct 2024, pair unconfigured so the price rule is skipped | "Sepolia's price feed has not updated since 2024, and the pool pair is unconfigured — so the dashboard shows the price rule as skipped, honestly, instead of pretending the swap would revert." | `Stale feed — pair unconfigured, price rule skipped` |

**Segment 6 — The integration + links (140–150s).** The 90-second
script's segment 4, extended by one line: code editor, the guarded
`withdraw()` with the single `check()` call highlighted ("ten lines.
One check() call, before the sensitive action"); policy form sliders;
end card: repo URL, frontend URL, "Solidity firewall — Stylus checker
on the roadmap". Add the keeper-bot line to the end card's caption:
"Keeper bot watches it. Dashboard shows it." Total 150 seconds.

### 3.3 Storyboard and honesty notes

- **Storyboard file:** `docs/VIDEO-STORYBOARD.md` (new, written in
  this phase alongside the video plan) — one row per shot in §3.2 with
  the source asset (file path or URL), the caption text, and the
  voiceover line. The storyboard is the edit checklist: no shot is
  rendered until its source asset exists and is real.
- **Show the receipt, not just the UI** (carried over from
  `DEMO-SCRIPT.md`): the Arbiscan receipt (or the simulator's receipt
  panel) with the revert reason visible is the evidence; a green/red
  banner alone is not.
- **Do not claim the live feed shows blocked attacks as on-chain
  events** — a reverted tx leaves no persistent event. The blocked
  attack is visible in the receipt + unchanged balance.
- **Do not claim Stylus** if the Solidity fallback shipped — say
  "invariant checks in Solidity; Stylus checker on the roadmap".
  (Stylus activations are paused chain-wide since 2 Oct 2026; the
  checker is built, tested, and deployable when activations resume —
  `ARCHITECTURE.md`.)
- **Do not call the demo pool's reference a TWAP in the voiceover.**
  Phase 1 replaced the v1 proxy with oracle-fed references; where the
  demo still uses the pool's own price, name it as the pool's price.
- **Do not claim live Aave/Uniswap guarding** (§3.2 segment 4 note).
- **No deployed addresses are final until verified:** use the real
  Arbiscan links (§2.5) or none at all — never a placeholder address
  on screen. The contracts are not yet verified on Arbiscan (§6), so
  the video shows the Arbiscan address pages, not a "verified" badge
  it does not have.
- **Voiceover:** one voice, calm-authority, professional (the SpendGuard
  v9 standard). Whose voice is §7 Q5. No "Alright, so this is ArbGuard"
  opening, no filler overload, no awkward silence; the voiceover opens
  on the point ("DeFi lost $1.8 billion…") and never stops mid-segment.
- **Captions:** on throughout; the caption text in §3.2 is the caption
  text, not a paraphrase. If no voiceover is recorded, captions-only is
  acceptable.

### 3.4 Video acceptance (before the link goes in the submission)

- [ ] Every shot's source asset exists and is real (dashboard stills
  from the live Sepolia frontend, receipts from real transactions or
  the simulator, terminal output from a real `forge test` run).
- [ ] The 2-second key frame (reverted receipt + unchanged balance) is
  held, not rushed.
- [ ] The segment-4 honesty line ("proven on an Arbitrum One fork")
  is in the voiceover and the captions.
- [ ] No other team is mentioned. No placeholder address appears.
- [ ] Runtime 120–180 seconds. Captions throughout. Uploaded unlisted
  (YouTube, or per HackQuest's field) and linked from the README and
  the submission (§4).

## 4. Submission package — São Paulo Open House

### 4.1 The event (recorded, not re-verified in this phase)

- Event: Arbitrum Open House, São Paulo — 8–28 Feb 2027, 100% online.
- Submission deadline: **28 Feb 2027, 11:59 PM BRT**.
- Winners announced: 8 Mar 2027. Prize pool: **$115,000**.
- Submission target (repo decision, carried over): **Fri 26 Feb 2027**
  — submit two days early, so a last-minute breakage is a fix, not a
  miss. Nothing is submitted in this phase; §4 is the package and the
  checklist, and the actual submission needs Muhammed's explicit
  go-ahead on the exact submission (standing boundary: submissions need
  his go-ahead on the exact action).
- Repo: `Admuad/arbguard` (public). The submission links the repo, the
  live frontend, and the video — not a zip, not a private link.

### 4.2 Checklist

| # | Item | Status at spec time (20 Nov 2026) | Evidence / location |
|---|---|---|---|
| 1 | Repo public, README current | Done (pushed 18 Nov; README must be updated for Phase 3: dashboard + keeper bot + video links) | `github.com/Admuad/arbguard` |
| 2 | Contracts: ArbGuard + adapters, 237/239 tests passing | Done (Phase 2 implemented 20 Nov; 237/239, the 2 failures are the known Phase 1 gas-target misses, not re-baselined) | `contracts/`, `forge test` output |
| 3 | Contract size: ArbGuard 23,705 bytes | Done (871 under the 24,576-byte EIP-170 limit) | `forge build --sizes` |
| 4 | Fork evidence: AaveFork 13/13, UniswapV3Fork 7/7 on Arbitrum One (pinned block 525,970,897) | Done (Phase 2) | `contracts/test/` fork tests |
| 5 | Sepolia deployment live | Done 20 Nov 2026 (Phase 1 contracts; adapters NOT deployed, §5) | §2.5 addresses; `SEPOLIA-DEPLOYMENT.md` |
| 6 | Contracts verified on Arbiscan | **BLOCKER** — not verified, no `ARBISCAN_API_KEY` (§6) | — |
| 7 | Frontend env config with live Sepolia addresses | **Not done** — part of Phase 3 (§2.5) | `apps/web/.env.local` + Vercel env |
| 8 | Frontend ABI regenerated (Phase 2 structs/events) | **Not done** — part of Phase 3 (§2.6) | `apps/web/lib/contracts.ts` |
| 9 | Dashboard page live (`/dashboard`) | Not done — part of Phase 3 (§2) | `apps/web/app/dashboard/` |
| 10 | Keeper bot running (dry-run proven, then live) | Not done — part of Phase 3 (§1) | `keeper/` |
| 11 | Demo video (2–3 min, §3) | Plan only — part of Phase 3 (§3); generation is a later step, not in this spec | `docs/VIDEO-STORYBOARD.md` + video link |
| 12 | Docs current: ARCHITECTURE, INTEGRATION, DEPLOY-CHECKLIST, DEMO-SCRIPT | Update in Phase 3 (see §4.3) | `docs/` |
| 13 | Submission text (title, description, links) drafted | Not done — drafted in Phase 3 (§4.4), sent only on his go-ahead | §4.4 |
| 14 | Arbitrum One deployment (credibility deployment, mock tokens only) | Not done; needs his explicit go-ahead on the exact step (final week only, `DEPLOY-CHECKLIST.md`) | — |

### 4.3 Docs to update in Phase 3

- `ARCHITECTURE.md`: add the keeper bot and the dashboard to the
  system overview (the bot as an off-chain keeper, not an enforcement
  path); record that the guard works with the bot down; close the
  Phase 2 open question on Sepolia adapters with the §5 decision.
- `INTEGRATION.md`: add a keeper-bot section (how a protocol team runs
  the bot against their own deployment: env vars, keeper registration,
  dry-run first) and a dashboard section (what the dashboard shows and
  what it cannot show — the no-`ViolationBlocked` line, again).
- `DEPLOY-CHECKLIST.md`: record the frontend env config (§2.5) once
  set, the derived `NEXT_PUBLIC_DEPLOY_BLOCK`, the keeper-bot
  deployment (host, keeper address, dry-run → live date), and the
  Arbiscan verification status once unblocked.
- `DEMO-SCRIPT.md`: note that the 90-second spine is extended by §3.2
  (150-second spine) and point at `VIDEO-STORYBOARD.md`; do not rewrite
  the 90-second spine in place (it is the source the new script extends).
- `README.md` (repo root): links — live frontend (dashboard URL),
  Sepolia Arbiscan addresses, video link, test evidence (237/239),
  fork evidence, and the one-line pitch ("reverts the exploit
  transaction before the money moves").

### 4.4 Submission materials (draft content, not a submission)

- **Title:** ArbGuard — the on-chain circuit breaker for Arbitrum.
- **One-line pitch:** It reverts the exploit transaction before the
  money moves.
- **Description (draft, ~150 words, to be approved verbatim before
  sending):** ArbGuard is a plug-in, on-chain firewall for Arbitrum
  protocols. A protocol registers its limits and calls `check()` before
  each sensitive function; any transaction that breaks the limits
  reverts before funds move. Phase 1 added oracle-fed reference prices
  (Chainlink primary, Uniswap V3 TWAP cross-check, 2% disagreement
  fails closed), a 24-hour timelock, a 10-keeper set, throttle mode and
  hour/day velocity windows. Phase 2 added Aave V3 and Uniswap V3
  adapters — a health-factor floor (1.25×) and a reserve-drain cap
  (50%) — proven on an Arbitrum One fork (AaveFork 13/13,
  UniswapV3Fork 7/7). Phase 3 added the operability layer: a keeper bot
  that throttles on window burn and a live Sepolia dashboard. Live on
  Arbitrum Sepolia; 237/239 Foundry tests passing; ArbGuard 23,705
  bytes.
- **Links:** repo (`github.com/Admuad/arbguard`), live frontend
  (dashboard URL — Vercel, once deployed), video link (§3.4), Sepolia
  Arbiscan guard address
  (`https://sepolia.arbiscan.io/address/0x9D733954c71920a51291d730fc48422d94d5C306`).
- **Test evidence to attach:** `forge test` output (237/239, with the
  2 gas-target misses named, not hidden), `forge build --sizes`
  (23,705 bytes), fork-test output (AaveFork 13/13, UniswapV3Fork 7/7
  at pinned block 525,970,897), keeper-bot fork test output (§1.8).
- **What NOT to put in the submission:** no Stylus claim (Solidity
  path ships; Stylus checker on the roadmap — activations paused
  chain-wide since 2 Oct 2026); no "live on Aave/Uniswap" claim
  (fork-proven, §5); no blocked-attack event claim; no placeholder
  addresses; no unverified-contract badge the contracts do not have
  (§6).

### 4.5 Freeze rule

From the submission target (26 Feb 2027) backwards: no new features
after 19 Feb 2027. The last week is verification only — re-run the
full test suite, re-verify the Sepolia deployment reads on the
dashboard, re-watch the video, re-check every link in the submission.
A feature that is not proven by 19 Feb does not ship; it goes in the
roadmap section of the README. (This mirrors the v0.1 spec freeze in
`ARCHITECTURE.md`: no new features without cutting something of equal
size.)

## 5. Sepolia adapter decision (VERIFIED LIVE 20 Nov 2026 — recorded, not re-verified)

This section records the coordinator's live verification of 20 Nov
2026 as the decision, with the evidence as supplied. It was not
re-verified from scratch for this spec, and the spec does not re-run
the checks: the decision stands on the evidence below unless new
on-chain state contradicts it, in which case the decision is revisited
and this section is corrected with the new evidence and date.

### 5.1 Evidence

1. **`DeployAdapters.s.sol` hardcodes Arbitrum One addresses** —
   PoolAddressesProvider
   `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb`, Uniswap Factory
   `0x1F98431c8aD98523631AE4a59f267346ea31F984` (plus NPM
   `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`, WETH
   `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`, USDC
   `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, the Chainlink feeds and
   the WETH/USDC pool `0xC6962004f452bE9203591991D15f6b388e09E8D0`).
   On Arbitrum Sepolia those addresses have **NO code** (`cast code`
   returns `0x`), so the script would revert on its first provider
   getter (`getPool()` against an empty address). It must NOT be run
   on Sepolia as written.
2. **Aave V3 DOES exist on Arbitrum Sepolia at Sepolia-specific
   addresses** — provider
   `0xB25a5D144626a0D488e52AE717A051a2E9997076`, market "Aave V3
   Arbitrum Sepolia Testnet Market", pool
   `0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff`, 2 reserves — **BUT the
   Pool holds 0 USDC and 0 WETH: zero available liquidity.** Guarding
   it proves nothing: there is nothing to drain, no health factor to
   push, no reserve to empty. A borrow/withdraw demo against an empty
   market is a test of the adapter's error paths, not of the guard.
3. **Uniswap V3 factory at the canonical address has no code on
   Sepolia; no verified V3 pool exists there.** There is nothing for
   the V3 adapter to resolve a pool from, and no TWAP to cross-check.
4. The adapters' real evidence is therefore the Arbitrum One fork
   tests (AaveFork 13/13, UniswapV3Fork 7/7, pinned block
   525,970,897). A Sepolia adapter deploy against mocks would only
   re-test what unit tests already cover (mock Aave / mock V3 pools,
   `AaveAdapter.t.sol` / `UniswapV3Adapter.t.sol`).

### 5.2 Decision

**Do NOT deploy the Phase 2 adapters to Sepolia.** The adapters stay
fork-proven only. The Sepolia deployment remains the Phase 1 demo
(guarded/unguarded vault + pool, mock mWETH/mUSDC), which is what the
dashboard (§2) shows and what the video (§3) demonstrates live. The
adapters appear in the video only as fork evidence (§3.2 segment 4),
labelled as such.

Consequences recorded here so no later step re-opens them silently:
- `DeployAdapters.s.sol` is not run against Sepolia. If it is ever run
  against Arbitrum One, it needs Muhammed's explicit go-ahead on that
  exact step (it deploys to mainnet; the `DEPLOY-CHECKLIST.md` rule
  applies).
- The dashboard has no adapter deployment to show (§2.6: adapter ABIs
  are not added to `contracts.ts` in this phase).
- The submission says "fork-proven on Arbitrum One", never "live on
  Aave/Uniswap" (§4.4).
- Phase 2 spec §6 Q1 ("Adapters on Arbitrum Sepolia?") is answered by
  this decision: no — verified 20 Nov 2026, evidence above.

### 5.3 Open question (not a blocker)

If a Sepolia adapter demo is ever wanted, it needs either a **funded
real Sepolia Aave market** (someone supplies WETH/USDC to the Sepolia
pool `0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff` so there is liquidity
to guard — testnet tokens, but a real market state) or **mock protocol
deployments** (deploy mock Aave Pool / mock V3 factory+pool on Sepolia
and point the adapters at them — which re-tests the unit-test mocks
on a live chain, proving deployment plumbing, not guard logic).
Record as an open question (§7 Q1), not a blocker: nothing in Phase 3
depends on it.

## 6. Blockers (recorded, not solved)

Blockers are facts that stop a Phase 3 item until they are resolved.
The spec records them; it does not invent solutions for them.

1. **Contracts NOT verified on Arbiscan — no `ARBISCAN_API_KEY`.**
   The Sepolia deployment (20 Nov 2026) was deployed without
   `--verify`. Until verification lands, the dashboard links to
   Arbiscan address pages that show bytecode, not source; the video
   cannot show a "verified" badge; and the submission cannot claim
   verification. Resolution needs an Arbiscan API key (Muhammed
   provides it) and a `forge verify-contract` run per contract, or a
   redeploy with `--verify`. Do not work around it by linking to a
   different explorer or by screenshotting source as if it were
   verified.
2. **Frontend env config with live Sepolia addresses is not done yet.**
   The dashboard work (§2.5) includes it — this is a Phase 3 task, not
   an external blocker, but the dashboard cannot show the live
   deployment until it is set (local `.env.local` + Vercel dashboard
   env vars), and `NEXT_PUBLIC_DEPLOY_BLOCK` still needs deriving
   (§2.5 note).
3. **Frontend ABI is stale at v1** (§2.6). The dashboard cannot be
   built until `contracts.ts` is regenerated from the current
   artifacts. This is a Phase 3 task (regenerate + verify), listed here
   because it blocks §2, not because it needs anything external.
4. **No keeper key provisioned.** The bot (§1) needs a fresh
   testnet-only keeper key, funded with a small Sepolia ETH balance,
   and the owner must register it with `addKeeper` for policies 0 and
   1. Until that happens the bot runs in dry-run only — which is the
   safe default, not a failure, but it means no live throttle/trip
   until the key exists. The key must be generated fresh (never
   hand-typed, never reused); the deployer/owner key is not the keeper
   key.
5. **No always-on host is specified for the keeper bot.** The bot is a
   long-running process; this VM is a work machine, not a host. Where
   it runs 24/7 (his Ubuntu box, a small VPS, or not at all — dry-run
   on demand) is §7 Q2. Until a host is chosen, the bot is a run-on-
   demand tool, and the submission must not claim 24/7 monitoring.

## 7. Open questions (flagged, not guessed)

1. **Sepolia adapter demo (§5.3).** Funded real Sepolia Aave market,
   or mock protocol deployments — or neither (fork evidence only,
   the current decision)? If a demo is wanted, who funds the Sepolia
   market and with what?
2. **Keeper-bot host.** Where does the bot run 24/7 — his Ubuntu box,
   a VPS, or run-on-demand only? Who pays for the host, if anything?
   Until answered, the bot ships as a run-on-demand tool (§6.5).
3. **Trip authority.** Default is throttle-only (`KEEPER_ALLOW_TRIP`
   false). Does the team want the bot to be able to trip at all, and
   if so, under which rules — R1/R2 as specified, or human-only trip
   (R3) with the bot as a throttle-only watcher? Confirm before the
   first live run.
4. **Throttle duration default.** Spec: 24 h (`KEEPER_THROTTLE_SECONDS`
   86400). Confirm; 1 h and 7 d are the plausible alternatives. A
   shorter throttle is friendlier to legitimate users; a longer one
   buys more investigation time.
5. **Video voiceover.** Whose voice — Muhammed's (as `DEMO-SCRIPT.md`
   assumes), or a professional voiceover (the SpendGuard v9
   calm-authority standard)? Confirm before recording; the script is
   written voice-agnostic.
6. **Dashboard hosting.** Vercel is the decided host for the frontend
   (SpendGuard precedent; `DEPLOY-CHECKLIST.md` says deploy the
   frontend to Vercel after env). Confirm the ArbGuard frontend goes
   to Vercel (new project or existing), and who sets the env vars
   there.
7. **Keeper alerting channel.** The bot logs decisions (§1.6) and has
   no alerting channel in this phase. Is a channel wanted (webhook,
   Telegram, email), and if so, which one — and who owns the receiving
   end? Until answered, the decisions log is the alerting surface.
8. **Arbitrum One deployment.** The credibility deployment (mock
   tokens only, small value) is final-week only and needs his explicit
   go-ahead on the exact step. Is it wanted at all, or is Sepolia-only
   acceptable for the submission? Confirm before the freeze (§4.5).
9. **Oracle T4 on a fresh-feed chain.** If the guard is ever deployed
   where the feed is fresh (Arbitrum One), T4 is re-enabled with
   `KEEPER_ORACLE_FAIL_POLLS=3`. Confirm the re-enable is a deliberate
   step at that time, not an automatic config copy from Sepolia (where
   T4 is disabled by design, §1.4).
10. **Health-factor / drain thresholds on the dashboard.** The
    dashboard shows the adapter policy values only when an adapter
    deployment exists (§2.6). No adapter policy is shown for Sepolia
    (there is none). Confirm the dashboard does not show adapter
    panels with fork-test numbers as if they were live.
11. **Video upload target.** YouTube unlisted (as `DEMO-SCRIPT.md`
    assumes) or HackQuest's own field? Confirm before upload; the
    submission needs the final URL, not a placeholder.
12. **Submission target date.** Spec: submit Fri 26 Feb 2027 (two days
    early). Confirm; the hard deadline is 28 Feb 2027 11:59 PM BRT.

## Appendix A — Evidence inventory (read for this spec, 20 Nov 2026)

- `docs/PHASE1-SPEC.md` (783 lines, 19 Nov 2026) and
  `docs/PHASE2-SPEC.md` (1,060 lines, 20 Nov 2026) — style model for
  this spec; Phase 2's fork evidence and adapter interface are cited
  from it, not re-derived.
- `docs/ARCHITECTURE.md` — invariant model (seven checks, Phase 2),
  adapter trust boundary, the reverted-tx event note, Stylus pause
  (2 Oct 2026), threat model. The keeper bot is the off-chain half of
  the breaker the threat model assumes a human operates.
- `docs/INTEGRATION.md` — keeper setup (§5, manual `trip()`), adapter
  integration (§9), deploy checklist (§8). Phase 3's bot automates the
  manual `trip()` path and only that path.
- `docs/DEPLOY-CHECKLIST.md` — Sepolia dry-run evidence (29/29 txs),
  live Sepolia addresses, adapter deployment pending note.
- `docs/DEMO-SCRIPT.md` — 90-second spine, retained as §3.2 segments
  1–3 and 6.
- `docs/SEPOLIA-DEPLOYMENT.md` — live Sepolia deployment (20 Nov 2026
  ~16:02 WAT): deployer `0xE670974a278A47a0A311dA4Ab780d714acb0EfF0`,
  guard `0x9D733954c71920a51291d730fc48422d94d5C306`, vaults, pools,
  attacker, mWETH/mUSDC; stale-feed decision; "contracts NOT verified
  on Arbiscan yet"; "frontend env config still needs these addresses".
- `docs/PHASE1-FRONTEND-NOTES.md` — Phase 1 interface changes; gas
  note (swap `check()` ~125k, over the 120k target); contract-size
  warning (25,401 bytes at the time — since slimmed to 23,705 bytes
  after Phase 2).
- `contracts/src/ArbGuard.sol` — keeper functions read for this spec:
  `addKeeper` / `removeKeeper` / `isKeeper` / `getKeepers` (max 10,
  owner-only, immediate), `throttle(policyId, durationSeconds,
  evidence)` (keeper/owner, `durationSeconds == 0` indefinite),
  `unthrottle` (owner-only), `trip(policyId, evidence)` (keeper/owner),
  `reset` (owner-only, returns to NORMAL, reverts while throttled and
  while the cooldown has not elapsed), `getMode` (effective mode with
  auto-expiry), `getPolicy` / `getPriceConfig` / `getOracleConfig` /
  `getPendingUpdate` / `getReferencePrice`; events `PolicyRegistered`,
  `KeeperAdded` / `KeeperRemoved`, `ThrottleSet` / `ThrottleCleared`,
  `BreakerTripped` / `BreakerReset`, `CheckPassed`,
  `PolicyUpdateProposed` / `PolicyUpdateExecuted`,
  `OracleConfigSet`, `PriceConfigUpdated`. No `ViolationBlocked`
  event — by design.
- `contracts/src/AaveAdapter.sol` / `UniswapV3Adapter.sol` — adapter
  interface skimmed only: guarded `borrow` / `withdraw` (Aave) and
  `swap` / `decreaseLiquidity` / `collect` (V3); unguarded `supply` /
  `repay` / `mintPosition`; USD 1e18 convention for adapter policies;
  available liquidity read as the Pool's actual token balance (the
  Phase 2 live finding that the formula overstates it ~400x).
- `apps/web/lib/contracts.ts` — read 20 Nov 2026: generated ABI is
  stale at v1 (§2.6); `isDeployed` is computed from the seven live-path
  addresses; `DEPLOY_FROM_BLOCK` from `NEXT_PUBLIC_DEPLOY_BLOCK`
  ("earliest" when unset); `BLOCKED_ATTEMPTS_KEY` localStorage
  mechanism for simulator-recorded blocked attempts.
- `apps/web/.env.example` — env var names (§2.5); all blank
  placeholders; `NEXT_PUBLIC_CHAIN_ID` 31337 / 421614 / 42161.
- `contracts/script/DeployAdapters.s.sol` — hardcodes Arbitrum One
  addresses (provider `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb`,
  factory `0x1F98431c8aD98523631AE4a59f267346ea31F984`); adapter policy
  defaults (HF 1.25×, drain 50%, Aave caps $200k/$1M/$5M, V3 caps
  $50k/$500k/$2M). Must not be run on Sepolia as written (§5.1).
- Test evidence cited (not re-run in this spec): 237/239 Foundry
  tests passing (2 known Phase 1 gas-target misses); ArbGuard 23,705
  bytes; AaveFork 13/13 and UniswapV3Fork 7/7 on Arbitrum One at pinned
  block 525,970,897; Sepolia fork dry-run 29/29 txs (10 Nov 2026,
  re-proven 19 Nov).
- Sepolia adapter evidence (§5.1): supplied by the coordinator as
  verified live 20 Nov 2026 — recorded, not re-verified for this spec.
  No private key was read for this spec
  (`sepolia-deployer-key.env` and `contracts/.env` were not opened).
