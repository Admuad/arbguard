# ArbGuard — BUILD LOG

## 2026-11-10 ~00:53 WAT — Frontend completion phase (this phase)

**FRONTEND COMPLETE: policy form, attack simulator, live event feed,
integration page, Vercel readiness — all verified end-to-end against live
local Anvil.** Two slices ran in parallel (frontend wiring + docs/Vercel),
coordinator verified the final tree directly: `forge test` **40/40**,
`npm run build` green (**8 pages**: `/`, `/feed`, `/integrate`, `/policies`,
`/simulator` + `_not-found`).

- **Env-driven config:** `apps/web/lib/contracts.ts` reads 12
  `NEXT_PUBLIC_*` vars (see `apps/web/.env.example`); `isDeployed` is
  computed (true only when arbGuard + both vaults + both pools + attacker +
  both tokens are set/non-zero). `apps/web/lib/wagmi.ts` adds the
  `localhost` chain (31337, RPC from `NEXT_PUBLIC_RPC_URL`). ABIs
  regenerated via `scripts/generate-abis.mjs` and verified byte-identical
  to the backup. Live Sepolia wiring after the real deploy is now a config
  change (env vars), not a rebuild.
- **Attack simulator — live path rewritten (was broken):** the old code
  called `vault.withdraw(1 ether)` directly (passes the cap even guarded)
  and `swap(ZERO_ADDRESS, …)` (reverts `InvalidToken`, not
  `PRICE_DEVIATION`). Now it calls the Attacker contract
  (`drainOnly(vault, 10 ether, 200)` / `pushPriceAndSwap(pool, mWETH,
  1000 ether)`, explicit gas so reverting txs are broadcast), waits for
  the receipt, reads before/after balances (vault mWETH, pool reserves),
  and shows tx hash / block / status / balances / the decoded
  `ArbGuardViolation` reason (via `decodeErrorResult` against the real
  ABI, no hardcoded selector). Guarded reverts are recorded to a session
  store (`localStorage["arbguard:blocked-attempts"]` + window event).
  Honest simulated mode kept while `!isDeployed`, with corrected demo
  numbers (vault 1900→1000 unguarded; reserves 1000/1000→2000/500).
- **Event feed — fixed (was broken):** the hand-written `parseAbi`
  signatures did NOT match the real ABI (PolicyRegistered keeper is not
  indexed; BreakerTripped has a `bytes evidence` param; BreakerReset has
  no second param; CheckPassed has an `address token` param) and would
  have misdecoded every log. Now uses the real `ARB_GUARD_ABI` +
  `parseEventLogs`. Added a "Blocked attempts (this session)" section
  (session store + event listener) and a "Preview with simulateCheck"
  panel (drain-900 / swap-1000 buttons building the exact `Action`
  structs with live tvl/price/twapPrice), with the note that blocked
  attempts never appear on-chain.
- **Policy form:** no logic change needed; added the owner-only note
  (local Anvil: connected wallet must be the deployer/owner). Verified
  live: owner `registerPolicy` succeeds (policyId 2, reads back),
  non-owner reverts `OwnableUnauthorizedAccount`.
- **Copy fixes:** landing page now says Arbitrum Open House **São Paulo
  2027, $115,000, submit Fri Feb 26, 2027** (deadline Feb 28, 11:59 PM
  BRT) with honest Stylus framing ("Solidity invariant math ships; the
  Stylus checker is built and tested, deployment blocked by the chain-wide
  activation pause"). Layout header "GuardRail" → "ArbGuard"; nav link to
  `/integrate`. New `apps/web/app/integrate/page.tsx` (10-line guide,
  code blocks copied verbatim from `docs/INTEGRATION.md`).
- **Local demo tooling:** `apps/web/scripts/write-local-env.mjs` (maps
  `run-latest.json` by contract name; distinguishes the two GuardedPools
  by constructor arg, MockERC20s by deploy order; writes `.env.local` +
  deploy block) and `apps/web/LOCAL-DEMO.md` (full flow + reset notes).
  `apps/web/scripts/e2e-anvil.mjs` (viem E2E script, re-seeds the
  attacker since the demo consumes the unguarded attacks once).
- **INTEGRATION.md fixes (docs slice):** §6 removed non-existent
  `RESERVE_CONSERVATION` (real reasons: OUTFLOW_PER_BLOCK, SINGLE_SHARE,
  PRICE_DEVIATION, BREAKER_TRIPPED; NONE is the simulateCheck-only
  sentinel); §7 template rewritten to the real Attacker pattern (the old
  one called undefined `vault.setPolicyId()` / `vault.drainInOneTx()` /
  `vault.totalAssets()`); §4 added the missing `tvl` field to both
  `Action` literals; §5 corrected `reset()` (cannot end the pause early —
  it reverts `BreakerStillActive` before cooldown); §9 removed the false
  "checker address" claim (v1 has no checker address to set). Coordinator
  also fixed the same `RESERVE_CONSERVATION` drift in
  `docs/ARCHITECTURE.md:210`.
- **Vercel readiness (no deploy):** `apps/web/vercel.json` (framework
  nextjs, build/install commands, no secrets), full 12-var
  `.env.example`, README Vercel section (import repo, root directory
  `apps/web`, env vars, deploy) + local Anvil demo section.
- **Secret scan clean** (docs slice, repo-wide grep): only the documented
  Anvil default account #0 key in `contracts/script/AnvilDemo.s.sol:17`.
- **Anvil E2E (`node scripts/e2e-anvil.mjs`) — 11/11 PASS** (run 3×):
  env addresses set; `getPolicy(0)` = demo vault policy; `getPolicy(1)` =
  demo pool policy; `simulateCheck` drain 900 → `(false,
  OUTFLOW_PER_BLOCK)`; `simulateCheck` swap 1000 → `(false,
  PRICE_DEVIATION)`; normal withdraw 1 mWETH succeeds; `drainOnly`
  unguarded succeeds (vault 1900→1000); `drainOnly` guarded reverts
  `ArbGuardViolation(1)`, balance unchanged (1898→1898 — the number is
  1898 because the E2E script re-seeds with slightly different amounts);
  `pushPriceAndSwap` unguarded succeeds, reserves move; guarded reverts
  (3), reserves 1000/1000 unchanged; `getLogs` returns PolicyRegistered
  (2) + CheckPassed (3).
- **CORRECTIONS found this phase:** (1) `contracts/script/AnvilDemo.s.sol:17`
  had a one-hex-digit typo in the Anvil account #0 key (`…f4f3ff80` →
  `…f4f2ff80`) — the typo'd key derives unfunded `0x7f22…`, so no
  broadcast tx could ever land; fixed (comment only). (2) This log's
  revert selector `0x75db3afb` was wrong — the live selector for
  `ArbGuardViolation(uint8)` is `0xe63ab918` (verified with `cast sig`
  and the demo's own revert data `0xe63ab918…0001`); corrected in the
  log. (The log never contained the bad key string itself — only the
  selector was wrong.)
- **DeploySepolia gap CLOSED (coordinator):** the script deployed the
  same contract set as the demo but NO Attacker — on Sepolia the
  simulator's live path would have had no Attacker address and fallen
  back to simulated mode. The script now deploys + funds the Attacker
  (900 mWETH deposited into each vault, 1000 mWETH approved per pool,
  mirroring AnvilDemo) and logs its address. **Dry-run re-proven on a
  local Sepolia fork (block 327705313): 29/29 txs, all status 1, total
  gas 6,763,777** (~0.00007 ETH at 0.01 gwei); live state verified with
  `cast` (owner, both policies, vault balances 1900/1900, attacker
  shares 900/900, attacker mWETH 1100 = 2900 minted − 1800 deposited,
  pool reserves 1000/1000). `docs/DEPLOY-CHECKLIST.md` updated (new
  evidence, attacker address, post-deploy wiring now env vars, not
  editing `contracts.ts`).
- **Quirks recorded:** (a) forge 1.9.0 broadcast of AnvilDemo aborts on
  the reverting demo txs (pre-broadcast simulation fails; even with
  `--skip-simulation` the broadcast stops at the first reverting tx,
  30/33 land, exit 1) — last 3 txs completed with `cast send
  --gas-limit`; documented in `apps/web/LOCAL-DEMO.md`. (b) viem 2.30
  `getLogs` with `abi` alone neither typechecks nor decodes — the feed
  and E2E use `getLogs({address, fromBlock})` + `parseEventLogs({abi:
  ARB_GUARD_ABI, strict: false})` instead. (c) Anvil fork startup is
  slow through the VM egress proxy (~14s to first RPC response) — the
  dry-run scripts now poll for readiness instead of a fixed sleep.
- **Note on a stale flag:** the frontend slice flagged INTEGRATION.md
  §4 (missing `tvl`) and §7 (`setPolicyId`) as uncompilable — that read
  predates the docs slice; verified current: `tvl` is present (§4) and
  no `setPolicyId`/`drainInOneTx` references remain. Resolved, no action.

## 2026-11-10 ~00:50 WAT — Rename to ArbGuard + Sepolia fork tests + deploy readiness (this phase)

**RENAME GuardRail → ArbGuard: DONE and verified.** Reason: "Guardrail"
(guardrail.ai) is a commercial blockchain-security platform in the same space;
ArbGuard is distinct and Arbitrum-specific. Renamed across the whole repo:
`contracts/src/GuardRail.sol` → `ArbGuard.sol` (contract `ArbGuard`,
interface `IArbGuard`, error `ArbGuardViolation`), `contracts/test/GuardRail.t.sol`
→ `ArbGuard.t.sol`, Stylus crate `guardrail-checker` → `arbguard-checker`,
all frontend/docs/README/CI text, repo URL `github.com/Admuad/arbguard`.
`GuardedVault` / `GuardedPool` / `UnguardedVault` and "guarded" kept (no
collision). Verification: repo-wide `grep -ri guardrail` (excl. lib/, target/,
node_modules, out/, cache/, this log's history below) returns NOTHING; no
file still named `*GuardRail*`; `forge test` 33/33 before the fork suite was
added; `npm run build` green (7 pages); `cargo test` 20/20.
NOTE: this log's entries below the rename keep the old name — they are a
dated historical record, not stale references. The workspace directory stays
`~/workspace/guardrail/` (parent's instruction); only the project/brand name
changed.

**SEPOLIA FORK TESTS: DONE, 7/7 green.** New `contracts/test/SepoliaFork.t.sol`
forks live Arbitrum Sepolia via the public RPC (Alchemy has no Sepolia host)
and proves, on real Sepolia state: drain reverts on the guarded vault
(`ArbGuardViolation(OUTFLOW_PER_BLOCK)`) and succeeds on the unguarded one;
price-push reverts on the guarded pool (`PRICE_DEVIATION`) and succeeds on
the unguarded one; normal withdraw passes; breaker trip blocks, `reset()`
before cooldown reverts, auto-resume after warp past cooldown. Full suite
now **40 tests passing, 0 failed** (33 + 7 fork). Two findings from the fork
work: (1) the public Sepolia RPC is a NON-archive node — a pinned-block fork
fails ("missing trie node"), so the suite forks "latest at run time";
(2) **Arbitrum `block.number` returns the L1 block number, not L2**
(verified live: `block.number` 12,100,877 vs `ArbSys.arbBlockNumber()`
327,699,444). Consequence: ArbGuard's outflow window is really a per-L1-block
window (~12s, ~48 L2 blocks) — TIGHTER than a per-L2-block window would be,
so the design is sound as-is; docs should say "per L1 block" honestly.
No contract change needed.

**DEPLOY READINESS: DRY-RUN PROVEN on a local Sepolia fork, NOT deployed.**
`DeploySepolia.s.sol` executed end-to-end on an Anvil fork of live Sepolia:
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, 21/21 txs, all status 1, both
policies registered, demo liquidity seeded; live state verified with `cast`
(owner, `getPolicy(0)`, vault balance 1000 mWETH). Total gas 5,922,331
(~0.00006 ETH at 0.01 gwei) — any faucet drip covers it. Full checklist:
`docs/DEPLOY-CHECKLIST.md`. Gotchas fixed: (a) `forge script` on 1.9.0
requires the `path:Contract` form — all script headers + `contracts/README.md`
fixed; (b) on a Sepolia fork the Anvil default accounts are NOT funded —
the deployer must be funded (real deploy: faucet ETH to the deployer key).
Anvil demo re-run after the rename: unguarded drain 1,900 → 1,000, guarded
reverts, balance 1,900; price-push guarded reverts, reserves 1000/1000.

**STYLUS PAUSE RE-CHECK (2026-11-10): STILL PAUSED.** `cargo stylus check
--endpoint https://sepolia-rollup.arbitrum.io/rpc` — build succeeds (5.7 KB),
then the same error: "Stylus activations appear to be paused on this chain
(activation gas charge is 18446744073709551615)". Solidity fallback remains
the shipping path. Next re-check Mon 11 Jan 2027.

## 2026-11-09 ~23:22 — Week 0 started + DEADLINE CORRECTION

**Deadline correction (live-browser check, 23:20 WAT):** the HackQuest Dubai page is largely a
placeholder. Its only stated dates are **Dec 30–31, 2030** (registration and submission) with reward
announcement Feb 13, 2031 — plainly placeholder dates. Most details are marked "TBD" / "Coming
soon". The 6 Dec 2026 / 5 Dec 2026 dates came from aggregators and are NOT confirmed on the live
page — the page contradicts them.

**Confirmed on the live page:** $30,000 USD total prize pool, status "Upcoming", online, 86+
community, **1 project in the gallery: InvariantSnipe** (a security-like invariant oracle — a
near-neighbour; GuardRail must stay sharply differentiated as *enforcement*, not detection).
No named tracks, no judging criteria, no registration mechanics, no submission checklist, no
Dubai-specific terms — all unpublished.

**What changes:** the Sat 5 Dec submit date is now **PROVISIONAL, not confirmed. Do not sprint
on it.** Week 0/1 milestones below are kept as a working build schedule, not a deadline. GuardRail
has standalone value as a sellable tool and a direct-audit talking point regardless of this event.
If the organiser later publishes real dates, the schedule re-tightens then.

**Pace decision (2026-11-10 ~00:07, Muhammed via Fred):** keep building at FULL pace on the
Week 0/1 scope. No scope cuts to chase the provisional date, no sprinting — steady full pace. The
core product (spec, scaffold, core contracts, Anvil drain demo, Stylus hello-world) is worth
building regardless of the event date. If the date-confirmation work comes back showing the event
is not running in Dec 2026, re-plan the submission target then — the build does not stop.

## DATE VERDICT (2026-11-10 ~00:10) — new confirmed target: São Paulo 2027
- **December 2026 Dubai run is UNPUBLISHED, not a deadline.** No official source confirms it:
  Foundation blog (14 Apr 2026) postponed Dubai "until further notice" and never posted a
  reschedule; the Dubai microsite has no dates and no Dubai card; the Telegram group has 26
  members. The 6 Dec date exists only in two aggregators with no cited source.
- **Confirmed submission target: Arbitrum Open House São Paulo — Online Buildathon 2027.**
  Event period Feb 8–28, 2027; **submission deadline Feb 28, 2027, 11:59 PM BRT**; winners
  Mar 8, 2027; **$115,000 USD**; 100% online; open to everyone (confirmed by the official T&C
  PDF, updated 23 Oct 2026). ~3 months of runway from Nov 10.
- **Dubai is a watch item only:** re-check its listing weekly at most, and only if a
  "registration open" post appears.
- **Aevum ($1,500, registration opens 16 Nov) remains the firmer near-term dated option, but it
  is a different build — do NOT fold it into GuardRail.**
- Submission-phase verification still owed for São Paulo: tracks, prize split, payout currency,
  judging criteria, registration mechanics (from the official T&C PDF).

## REVISED MILESTONES — submit Fri Feb 26, 2027 (2 days before the Feb 28, 11:59 PM BRT deadline)
- [x] **Week 0 — Spec freeze: DONE Nov 9.** Docs, scaffold, README/CI, name check.
- [x] **Week 1 — Core contracts + Anvil demo: DONE Nov 10.** `forge test` 33/33 green; Anvil
  drain demo proven live (see below). Frontend ABIs regenerated from real contracts
  (`apps/web/scripts/generate-abis.mjs`); `npm run build` green.
- [x] **Stylus checker: BUILT + TESTED, NOT DEPLOYABLE (chain pause, 2026-11-10).** See
  "Stylus pause" section below. `cargo test` 20/20, WASM 5,686 bytes compressed, ABI exported
  (selectors verified). The checker is ready to deploy the moment activations resume.
- [x] **Rename GuardRail → ArbGuard: DONE Nov 10.** Repo-wide, verified clean
  (grep, `forge test`, `npm run build`, `cargo test`); see the phase section
  at the top of this log.
- [x] **Sepolia fork tests: DONE Nov 10.** `SepoliaFork.t.sol`, 7/7 green on
  live Sepolia state; full suite 40/40. `block.number` = L1 height finding
  recorded above.
- [x] **Deploy readiness: DRY-RUN DONE Nov 10.** Sepolia deploy script proven
  end-to-end on a local Sepolia fork (21/21 txs); checklist in
  `docs/DEPLOY-CHECKLIST.md`. **Real deploy still needs Muhammed** (fresh
  testnet-only deployer key + Sepolia faucet ETH) — NOT done in this run.
- [ ] **Nov 10 – Nov 28 — Sepolia (Solidity path).** Real deploy v0.1 to
  Arbitrum Sepolia + verify on Arbiscan (needs Muhammed's deployer key +
  Sepolia faucet ETH). GuardRail.sol ships with the Solidity invariant math;
  the Stylus checker wires in behind the same interface when the pause lifts
  — no contract changes needed.
- [ ] **Stylus hard gate: Mon 11 Jan 2027 (re-check the pause).** If activations have resumed,
  deploy the checker and wire it in; if the pause is still in effect, the Solidity checker
  ships as-is (it already is the shipping path — the gate is now a pause re-check, not a
  build-or-cut decision). Re-check signal: `cargo stylus check --endpoint
  https://sepolia-rollup.arbitrum.io/rpc` passing.
- [x] **Frontend completion: DONE Nov 10 (early).** Policy form, simulator, feed wired to local Anvil (env-driven config; live Sepolia wiring is a config change after the real deploy); `/integrate` page; Vercel readiness (config only, no deploy); `npm run build` green (8 pages); `forge test` 40/40. Live Sepolia wiring + Vercel deploy + Arbitrum One v1.0 still pending (his deploy key + faucet ETH).
- [ ] **Jan 19 – Feb 12 — Hardening.** Expanded invariant tests, self-audit pass over our own
  contracts, gas optimization, demo video draft, integration docs polish.
- [ ] **Feb 15 – Feb 26 — Polish + submit.** Code freeze Fri Feb 19; video + README final
  Feb 24; submission dry run Feb 25; **submit Fri Feb 26**; Feb 27–28 buffer.

## Anvil drain demo — PROVEN live 2026-11-10 (script: contracts/script/AnvilDemo.s.sol)
- Drain: unguarded vault 1,900 → 1,000 mWETH in one tx; guarded reverts
  `ArbGuardViolation(OUTFLOW_PER_BLOCK)` (revert data `0xe63ab918...0001`), balance stays 1,900.
- Price push: unguarded swap succeeds (500 mUSDC out, reserves 2000/500); guarded reverts
  `ArbGuardViolation(PRICE_DEVIATION)` (`0xe63ab918...0003`), reserves unchanged 1000/1000.
- Run: `anvil --port 8545` + `forge script script/AnvilDemo.s.sol --rpc-url
  http://127.0.0.1:8545 --broadcast` with Anvil's default account #0 key (local only).
  Cosmetic quirk: the script exits 1 because the two guarded-attack txs revert on-chain by
  design (caught by try/catch; the demo completes and logs everything).
- `Attacker.drainOnly()` added 2026-11-10 (drain loop without a deposit in the same call, so
  the guarded revert does not roll the deposit back); `forge test` still 33/33 after the change.

## STYLUS PAUSE — chain-level blocker, verified 2026-11-10 (coordinator re-checked live)
- **Stylus activations are PAUSED on Arbitrum Sepolia AND Arbitrum One.** `cargo stylus check`
  fails on both with: `Stylus activations appear to be paused on this chain (activation gas
  charge is 18446744073709551615)`. This is the Security Council's 2 Oct 2026 pause (activation
  gas set to 2⁶⁴−1); a resumption proposal went through a temperature-check vote ending 5 Nov
  2026 with no live date. **No new Stylus contract can be activated on either chain right now —
  for anyone, not just us.** The toolchain is proven working; this is chain state, not a
  code/toolchain failure.
- Toolchain pinned (stylus/README.md): rustc/cargo 1.91.0, wasm32-unknown-unknown target,
  cargo-stylus 0.10.10, stylus-sdk 0.10.10 (correction: the 0.6.x line in the original brief was
  stale — current line is 0.10.x). Hello-world Counter builds + tests green; release WASM 5.3 KB.
- Checker (stylus/src/lib.rs): 3 pure overflow-safe fail-closed functions (`check_outflow`,
  `check_price_deviation`, `check_share`), `cargo test` 20/20 (verified by coordinator),
  release WASM 15,268 bytes / 5,686 compressed (under the 24 KB limit), ABI exported, selectors
  verified with cast: checkOutflow 0x932511af, checkPriceDeviation 0x2e2742ce, checkShare
  0x22b033b8. Deploy command with placeholders in stylus/README.md. No deploy run, no secrets.
- Environment gotchas recorded in stylus/README.md (rustup interrupt fix; cargo HTTP stalls
  through the VM egress proxy → pre-fetch crates with curl; /tmp is a 512 MB tmpfs — never build
  there, use TMPDIR=$HOME/.cargo-build-tmp; `cargo stylus new` template test bug; rclite lock
  conflict fix).
- Consequence: the "built with Stylus" submission story becomes "Stylus checker built, tested,
  and ABI-exported; deployment blocked by the chain-wide activation pause (Oct 2026–present);
  Solidity fallback ships" — honest framing, and every Stylus entrant faces the same pause.

**Toolchain (verified 2026-11-09):** Foundry 1.9.0 (forge/cast/anvil at `~/.foundry/bin`, add to
PATH), Node v24.22.1, npm 10.9.4, git 2.43.0. Rust/cargo NOT installed — Stylus slice installs
rustup + cargo-stylus and pins versions.

## Week 0 — Spec freeze (9–11 Nov, working schedule)
- [x] Spec freeze doc (`docs/ARCHITECTURE.md` v0.1) + `docs/INTEGRATION.md` + `docs/DEMO-SCRIPT.md` — **DONE 2026-11-09 ~23:41** (375/241/76 lines; invariant model, threat model, trust assumptions, TWAP-proxy + drain-mechanism honesty notes, 90-second video script)
- [x] Toolchain pin (Foundry, cargo-stylus, Node) + Stylus "hello world" compiling (`cargo stylus check`) — **Foundry 1.9.0 + Node 24 pinned; cargo-stylus pending (Stylus slice running)**
- [x] Repo scaffold at `~/workspace/guardrail/` (local only — Muhammed creates github.com/Admuad/guardrail) — **DONE**: README, MIT LICENSE, .gitignore, GitHub Actions CI (3 jobs, YAML validated, not run yet), Next.js 15 scaffold — **verified by coordinator: `npm run build` green, all 4 routes prerendered**
- [x] Name check: "GuardRail" vs HackQuest archive (fallbacks: ArbGuard, Breaker, Invariant) — **DONE: no prior HackQuest/Open House project named GuardRail. FLAG: the name exists commercially elsewhere — "Guardrail" (guardrail.ai), a blockchain-security platform backed by Coinbase Ventures/Haun Ventures (Feb 2026 launch). No rename done; coordinator decision needed before repo creation.**
- [x] README skeleton, LICENSE (MIT), .gitignore, GitHub Actions CI — **DONE (see above); secret scan clean**

## Week 1 — Core contracts (12–18 Nov, working schedule)
- [x] `GuardRail.sol` (policy registry, `check()`, `trip()`/`reset()`, events) — Solidity invariant math first (Stylus is a later swap, not load-bearing) — **DONE 2026-11-09 ~23:33, verified by coordinator: `forge test` 33 passed / 0 failed / 0 skipped** (target ≥25). OZ v5.4.0 pinned. Design decisions: ViolationBlocked = `simulateCheck` view, NO event (reverted tx leaves no persistent event); TWAP = last-price-per-block proxy (v1, documented); drain = loop drain, not reentrancy (documented honestly). Deploy scripts written, NOT run.
- [ ] `GuardedVault` / `UnguardedVault` / `GuardedPool` / `Attacker` / `MockERC20` — done as part of the above (same slice)
- [ ] Foundry tests: ≥25, all passing — **DONE, 33 passing (see above)**
- [x] Anvil drain demo working locally (guarded reverts, unguarded drains) — **DONE, proven live 2026-11-10 — see "Anvil drain demo" section above**
- [ ] Deploy scripts prepared (`DeploySepolia.s.sol`, `DeployMainnet.s.sol`) — NOT run (needs Muhammed's deployer key + Sepolia faucet ETH) — **DONE, scripts written; commands in contracts/README.md**

## Needs Muhammed (not in this run)
- Create public GitHub repo `github.com/Admuad/arbguard` (renamed from guardrail)
- Deploy transactions (sign from his wallet) + Sepolia faucet ETH — see `docs/DEPLOY-CHECKLIST.md` for the exact commands and the ~0.001 ETH needed
- HackQuest registration/submission, video voiceover, X post

## Blockers
- None yet. Stylus toolchain install is the known risk (hard gate Mon 23 Nov per plan — now a
  working-schedule gate, not a deadline gate: if Stylus is not deployed + passing on Sepolia by
  then, cut it and ship the Solidity checker).
