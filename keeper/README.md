# ArbGuard keeper bot

Node/TypeScript watcher (viem, polling, no framework, no DB) for the
live ArbGuard on Arbitrum Sepolia. It polls the guard and, when a
deterministic trigger rule fires, calls `throttle()` — and only in
the narrow, separately gated case, `trip()` — from a dedicated
testnet-only keeper key. **Dry-run by default: it logs what it WOULD
do and sends nothing until `KEEPER_DRY_RUN=false`.**

Full operator document: [`RUNBOOK.md`](RUNBOOK.md).
Spec: `../docs/PHASE3-SPEC.md` §1.

## Quick start

```bash
cp .env.example .env   # fill in the five required variables
npm install
npm run build
npm test               # 27 trigger unit tests, no chain
timeout 100 npm start  # dry-run against live Sepolia
```

Live deployment: ArbGuard
`0x9D733954c71920a51291d730fc48422d94d5C306`, policies `0`
(GuardedVault) and `1` (GuardedPool), chain `421614`, deploy block
`331084418`. The bot's keeper key
(`0xE65FB824123892e190816C9b2766F3934Fd80C88`, in `keeper/.env`,
mode 600) is fresh and testnet-only — it is **not registered** yet;
the owner must run `addKeeper` before the bot can go live
(see `RUNBOOK.md` §5).

## Layout

```
keeper/
  package.json / tsconfig.json
  .env.example          # every variable, blank placeholders only
  src/
    index.ts            # entry: config, keeper verification, poll loop
    config.ts           # env parsing + validation (fails fast)
    guard.ts            # viem reads: policy, mode, keepers, outflows,
                        #   oracle probe, balances, R2 simulateCheck probe
    triggers.ts         # pure trigger evaluation (T1–T5, R1–R3) — no I/O
    actions.ts          # throttle/trip sends + dry-run planning
    events.ts           # getLogs polling (chunked, no subscriptions)
    log.ts              # JSON decisions log (decisions.log + stdout)
  test/
    triggers.test.ts    # table-driven: every rule, fire + no-fire
    fork-test.sh        # end-to-end on local Anvil (see RUNBOOK §9)
  README.md / RUNBOOK.md / INCIDENTS.md
```

## What it does, in one paragraph

Once per poll cycle (30s default) per policy it reads the policy,
mode, keepers, outflow windows and the oracle probe in one batched
read, scans guard events since the last cycle, and evaluates the
rules in order: preconditions P1–P4, trip rules R1–R2 (gated by
`KEEPER_ALLOW_TRIP`, default false), throttle rules T1–T4, then T5
(proposal seen — log only, never a throttle). It takes at most one
action per policy per cycle, names the rule, the numbers and the
transaction in the decisions log, and never acts on partial state.
It never trips on reverted checks: the trigger module has no revert
input at all, and the fork test proves a reverted drain produces
`NO_ACTION`.

## Decisions log

`decisions.log` — one JSON line per policy per cycle (spec §1.6
fields). `NO_ACTION`, `WOULD_THROTTLE`, `THROTTLE_SENT`,
`WOULD_TRIP`, `TRIP_SENT`, `TRIP_BLOCKED_BY_CONFIG`,
`SKIP_ALREADY_PAUSED`, `SKIP_ALREADY_THROTTLED`, `SKIP_DISABLED`,
`SKIP_PARTIAL_STATE`, `PROPOSAL_SEEN`, `ERROR`. Tail it; any
`THROTTLE_SENT` / `TRIP_SENT` / `TRIP_BLOCKED_BY_CONFIG` /
`PROPOSAL_SEEN` line is the signal. There is no alerting channel
in this phase.

## Safety

- Least privilege: the keeper key can only `throttle` and `trip`.
  It cannot reset, unthrottle, change a policy, manage keepers, or
  move funds. The worst a compromised keeper key can do is pause
  one policy for one cooldown or degrade its caps for 24 hours.
- Fail-closed on partial state; no retries on 429 (backs off one
  full poll interval); ≤ ~1 request/second by construction.
- If the bot stops, the guard still works.
