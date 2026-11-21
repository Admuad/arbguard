# ArbGuard Phase 1 — Oracle-fed prices + policy hardening

**Status:** spec, 19 Nov 2026. No code written against it yet.
**Scope:** `ArbGuard.sol` (+ `GuardedVault.sol` / `GuardedPool.sol` call sites,
deploy script, frontend policy form). No public-chain deployment in this phase.
**Design constraints carried over from v1 (non-negotiable):**
- No `ViolationBlocked` event — a reverted transaction cannot leave a
  persistent event; blocked attempts surface via the revert reason and
  `simulateCheck()` only (`ARCHITECTURE.md`, "The reverted-tx event note").
- `check()` and `simulateCheck()` stay in lock-step: same rules, same order,
  same thresholds. Every new rule gets a paired mirror test.
- All arithmetic is Solidity 0.8 checked arithmetic; overflow reverts
  (fail-closed).
- The Stylus checker stays out of this phase: oracle resolution needs
  external calls, which cannot be pure functions. The Solidity path remains
  the enforcement path.

## 0. The trust flaw Phase 1 fixes

In v1 the price-deviation rule compares the execution `price` against
`twapPrice` — a field the *caller* supplies in the `Action` struct. The
guarded protocol is trusted to hand the guard an honest reference price.
A compromised protocol (or an attacker who controls the calling path)
passes a friendly reference and the rule never fires. The rule is only as
honest as its caller.

Worse, the v1 demo's reference is not even a TWAP: `GuardedPool` stores the
last execution price, refreshed at most once per block. A patient attacker
walks it across blocks. `ARCHITECTURE.md` says this plainly ("v1 proxy,
not a TWAP") and lists the real-TWAP choice as an open question. Phase 1
answers it: **the guard resolves the reference price itself, from
on-chain oracles the caller cannot influence.**

The same phase fixes the second v1 trust hole, named in the same doc: the
owner can rewrite policy limits instantly, with no delay and no second
party able to intervene. The RNT Lend exploit (18 Nov 2026, ~$954k) was
exactly this shape — a privileged key upgrading limits with no timelock.
Phase 1 adds a timelock, a keeper set, and a graduated response so the
guard itself cannot be switched off silently.

## 1. Oracle-fed reference prices

### 1.1 Verified feed inventory (read live, 19 Nov 2026)

All addresses below were verified by direct `cast call` against the public
RPCs (`https://arb1.arbitrum.io/rpc`, `https://sepolia-rollup.arbitrum.io/rpc`).
See Appendix A for the raw outputs.

**Arbitrum One (chain 42161)**

| Pair | Proxy | Decimals | Answer at read | Heartbeat* | Deviation* |
|---|---|---|---|---|---|
| ETH / USD | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | 8 | $1,771.70 | 3600 s | 0.5% |
| USDC / USD | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` | 8 | $0.99995 | 86400 s | 0.25% |
| L2 sequencer uptime | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` | — | 0 (up) | — | — |

\* Heartbeat / deviation are Chainlink's published reference-data parameters
for these feeds (ETH/USD 3600 s / 0.5% and USDC/USD ~24 h / 0.25% are the
standard values across chains). **Confirm on-chain in fork tests** by
measuring `updatedAt` deltas across consecutive rounds (see §1.7).

Notes:
- Always read the **proxy**, never the underlying aggregator. On
  Arbitrum One the ETH/USD aggregator behind the proxy is
  `0x3607e46698d218B3a5Cae44bF381475C0a5e2ca7` and the USDC/USD aggregator
  is `0x2946220288DbBF77dF0030fCecc2a8348CbBE32C`; those appear in
  Arbiscan traces (Aave's oracle calls the proxy, which calls the
  aggregator). The proxy address never changes; the aggregator can be
  swapped by Chainlink.
- USDC on Arbitrum One is the native Circle token
  `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` (not the bridged
  `0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8`).

**Arbitrum Sepolia (chain 421614)**

| Pair | Proxy | Decimals | Answer at read | Status |
|---|---|---|---|---|
| ETH / USD | `0xbF13EE58Bf62500FE87e7389faB633ff95dec029` | 8 | $2,626.84 | **STALE — `updatedAt` 1729103473 (16 Oct 2024)** |
| USDC / USD | — | — | — | **Not found.** No USDC/USD feed for Arbitrum Sepolia appears in Chainlink's published lists. |
| L2 sequencer uptime | — | — | — | **Not verified.** Chainlink publishes sequencer feeds for mainnets; whether a Sepolia one exists is an open question (§6 Q2). |

The Sepolia ETH/USD feed exists and answers, but its last update is over
two years old: Chainlink does not maintain testnet Data Feeds. Consequences:
- **Sepolia can only demo ETH/USD, and only as a stale-feed negative
  test.** A swap check against the real Sepolia feed must fail closed
  (see §1.4) — that is a feature of the design, and the fork test proves it.
- **Fresh-price fork tests on Sepolia must use a mock feed** (a
  `MockAggregatorV3` deployed in the test, scripted to return fresh
  answers). The mock is test-only; it never ships in `src/`.
- **Arbitrum One fork tests use the real feeds and the real pool**
  (§1.7). The public One RPC works for reads; no key needed.

### 1.2 Uniswap V3 TWAP (verified live, 19 Nov 2026)

Canonical pool for the WETH/USDC pair on Arbitrum One:

| Item | Value (verified on-chain) |
|---|---|
| Pool (WETH/USDC, 0.05%) | `0xC6962004f452bE9203591991D15f6b388e09E8D0` |
| Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| token0 / token1 | WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` / USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| fee | 500 (0.05%) |
| liquidity | ~1.03e18 |
| TVL | ~$26–27M (17 Nov 2026) |
| 24h volume | ~$30M |
| slot0 tick (spot) | −201488 |
| `observe([1800, 0])` | works; 30-min TWAP tick ≈ −201593 |

Mechanics (`IUniswapV3Pool.observe`):
- `observe(uint32[] secondsAgos)` returns `tickCumulatives` and
  `secondsPerLiquidityCumulativeX128` for each requested age.
- TWAP tick over window `T`: `(tickCumulative[now] - tickCumulative[now-T]) / T`.
- Tick to price: `price = 1.0001 ^ tick` (token1 per token0), computed via
  `TickMath.getSqrtRatioAtTick(tick)`: `price = sqrtRatioX96² / 2^192`.
  Scale to the guard's 1e18 convention and correct for token decimals
  (§1.5).
- `observe()` reverts with `OLD` if the requested age is older than the
  oldest stored observation. Pools store at most `observationCardinality`
  observations (this pool: 9000); a 30-minute window is far inside that
  on any active pool, but the guard must still handle the revert (§1.4).
- A pool with low cardinality or no recent swaps cannot serve a long
  window. The policy's `twapSeconds` must fit the pool; the fork test
  asserts `observe()` succeeds for the configured window.

**Manipulation cost.** To move a TWAP by X% over window T, the attacker
must move the spot price and hold it there for T while arbitrageurs trade
against them. Cost grows with pool liquidity, with the square of the
deviation, and with T. For this pool (~$26M TVL): holding ETH/USDC 5% off
for 30 minutes requires roughly 2.5% of pool value (~$650k) in one-sided
liquidity plus the arbitrage loss as the market reverts — low six figures
all-in, before fees. That is the point of the window: a flash-loan
single-block push costs almost nothing, but a 30-minute TWAP push costs
more than the per-block outflow cap lets the attacker extract in the same
window. The exact cost model is validated in a fork test (§1.7, "TWAP
manipulation cost test") rather than asserted here.

**Window choice: 1800 s (30 min) default.** Aave uses 30-minute TWAPs for
volatile pairs; Revert Lend's Arbitrum oracle uses 60-second TWAP intervals
with a 2% Chainlink cross-check. 30 minutes is the conservative middle:
long enough that a flash-loan push is meaningless, short enough to track a
genuinely fast-moving market. Per-policy configurable (`twapSeconds`,
range 300–86400). Low-liquidity pairs should use longer windows.

### 1.3 Resolution design: who wins, and when

Per policy, per token, the owner registers an `OracleConfig` (§1.6).
For a SWAP of `tokenIn -> token` (the Action's `token` is tokenOut), the
guard resolves a reference price for that pair as follows:

1. **Sequencer check first** (if a sequencer feed is configured for the
   chain; `address(0)` on Sepolia until one is verified): read
   `latestRoundData()`. If `answer == 1` (down) → revert
   `ArbGuardViolation(SEQUENCER_DOWN)`. If `startedAt == 0` → treat as up
   (uninitialized feed on Arbitrum, per Chainlink docs). If
   `block.timestamp - startedAt < 3600` (grace period after restart) →
   revert `ArbGuardViolation(SEQUENCER_DOWN)`. Chainlink's recommended
   grace period is 3600 s.
2. **Chainlink (primary).** If both tokens have a configured feed, read
   both `latestRoundData()`s. A feed reading is *valid* iff
   `answer > 0`, `updatedAt != 0`, `answeredInRound >= roundId`, and
   `block.timestamp - updatedAt <= chainlinkStaleAfter` (default 7200 s
   for ETH/USD-class feeds, 90000 s for stablecoin feeds — see §1.6).
   The Chainlink reference is the USD-ratio (§1.5).
3. **TWAP (secondary / cross-check).** If a pool is configured for the
   pair, read `observe([twapSeconds, 0])`. Valid iff the call succeeds.
4. **Combine:**
   - Both valid → compare. If they disagree by more than
     `maxOracleDeviationBps` (default 200, i.e. 2% — the Revert Lend
     precedent) → revert `ArbGuardViolation(ORACLE_DISAGREEMENT)`.
     Otherwise the Chainlink price is the reference.
   - Only Chainlink valid → Chainlink is the reference.
   - Only TWAP valid → TWAP is the reference (Chainlink stale/missing
     degrades gracefully to the on-chain market price).
   - Neither valid → revert `ArbGuardViolation(ORACLE_UNAVAILABLE)`.
5. **No oracle configured for the pair at all** → the price rule is
   skipped, exactly as v1 skips it when `twapPrice == 0`. This is the
   *only* silent-skip case. A policy that declares price protection but
   whose oracles are all unreadable fails closed; a policy that declares
   no oracle gets no price rule. The distinction is deliberate and must
   be preserved in tests.

Precedence summary: Chainlink wins when both agree; disagreement fails
closed; TWAP is the fallback, never the silent override.

### 1.4 Failure matrix

| Situation | Result |
|---|---|
| Sequencer down, or < 3600 s after restart | `SEQUENCER_DOWN` (before any price read) |
| No oracle configured for the pair | Price rule skipped (v1 behaviour) |
| Chainlink stale, TWAP fresh | TWAP reference used |
| Chainlink missing (feed `address(0)`), TWAP fresh | TWAP reference used |
| TWAP reverts (`OLD`, pool empty), Chainlink fresh | Chainlink reference used |
| Both configured, both unreadable/stale | `ORACLE_UNAVAILABLE` |
| Both fresh, disagree > `maxOracleDeviationBps` | `ORACLE_DISAGREEMENT` |
| Chainlink answer ≤ 0, or `answeredInRound < roundId` | That feed treated as unreadable |
| `check()` called for a non-SWAP kind | No price read at all (no oracle gas spent) |

Note the Sepolia consequence: the real Sepolia ETH/USD feed is stale, so
any Sepolia swap check with only Chainlink configured reverts
`ORACLE_UNAVAILABLE` (or falls back to TWAP if a Sepolia pool is
configured). Fork tests assert this exact behaviour against the real
stale feed — it is the cheapest possible proof that the staleness guard
works on live state.

### 1.5 Decimals and scaling

`Action.price` is 1e18-scaled tokenOut per tokenIn, computed from raw
amounts: `price = amountOut * 1e18 / amountIn`. The reference must be in
the same units.

- **Chainlink ratio.** Let `usdIn`, `usdOut` be the feed answers scaled to
  whole USD (divide by `10^feedDecimals`), and `decIn`, `decOut` the token
  decimals. Whole-token price `P = usdIn / usdOut` (tokenOut per tokenIn).
  In raw units: `ref = P * 10^(decOut - decIn) * 1e18`. Compute with
  `mulDiv` semantics (checked arithmetic, overflow reverts fail-closed):
  `ref = (usdIn * 10^decOut * 1e18) / (usdOut * 10^decIn)` — rearranged to
  keep intermediate values small; the implementation must show the
  overflow bound for realistic prices (both feeds ≤ 1e18-scaled, decimals
  ≤ 18; intermediate fits in uint256 for any sane price).
- **TWAP.** `tick → sqrtRatioX96` via `TickMath.getSqrtRatioAtTick`, then
  `price1e18 = sqrtRatioX96² * 10^(decOut - decIn) * 1e18 / 2^192`,
  inverted when the swap direction is token1→token0 (i.e. when
  `tokenIn == token1`, the TWAP gives token1-per-token0, so invert:
  `ref = 1e36 / price1e18` in the matching scale — implement with
  `FullMath.mulDiv` and assert the inversion in tests).
- **Token decimals are stored in `OracleConfig` at registration**, not
  read live via `decimals()` on every check. Rationale: one fewer external
  call per check, and a malicious token cannot lie about its decimals
  mid-flight. The owner sets them; a wrong value is an owner config error,
  caught by the `getReferencePrice` view and the fork tests.
- **Feed decimals are read from the feed once at registration** and stored
  alongside; the implementation must still assert `feed.decimals()` matches
  at registration time (defence against pointing at a wrong contract).

### 1.6 Interface changes (oracle part)

```solidity
/// @notice How the guard prices one token. A token with neither a feed
/// nor a pool has no oracle; swaps involving it skip the price rule.
struct OracleConfig {
    address chainlinkFeed; // AggregatorV3 proxy, or address(0)
    address uniswapPool;   // Uniswap V3 pool for the token's USD pair, or address(0)
    uint8 feedDecimals;    // cached from feed.decimals() at registration
    uint8 tokenDecimals;   // token decimals, set by the owner
}

/// @notice Price source chosen per policy. Stored per policyId.
struct PriceConfig {
    uint32 twapSeconds;            // default 1800
    uint16 maxOracleDeviationBps;  // default 200
    uint32 chainlinkStaleAfter;    // default 7200 (volatile) — see note
    address sequencerFeed;         // address(0) = skip the sequencer check
}
```

Notes:
- `chainlinkStaleAfter` is per-policy, not per-feed, in this spec: 7200 s
  default. Stablecoin-heavy policies should set 90000 s. A per-feed
  stale bound is a possible refinement; it is **not** in Phase 1 scope.
- `OracleConfig` is keyed `mapping(uint256 policyId => mapping(address token => OracleConfig))`.
  For a swap, the guard looks up both `tokenIn` and `token` (tokenOut).
  The TWAP pool is stored on the *pair*: convention — store the pool
  under the tokenOut key? No: a pool belongs to a pair, and either
  direction uses the same pool. Store the pool address in the
  `OracleConfig` of **both** tokens of the pair at registration
  (`setOracleConfig` takes the pool for the pair; the implementation
  writes it to both token entries, or resolves it by trying
  `config[tokenOut].uniswapPool` first, then `config[tokenIn].uniswapPool`).
  Spec decision: **store the pool on both tokens' configs** at
  registration; `getOracleConfig` returns what was set. Simpler to audit.
- `Action` changes: **remove `twapPrice`**; **add `address tokenIn`**
  (the token being sold; `address(0)` for non-SWAP kinds). `price` stays
  as the execution price, 1e18-scaled, tokenOut per tokenIn.
  This is a breaking change for every `check()` caller:
  `GuardedVault` drops `twapPrice: 0`; `GuardedPool` drops its
  `lastPrice01/10` reference and passes `tokenIn`, keeping its local
  `lastPrice*` fields only as a demo display (or deleting them — the
  implementation decides; deleting is cleaner, the "TWAP proxy" comment
  and its warning go away with it).
- New `Reason` variants: `ORACLE_STALE` (kept for a single-source stale
  read — see note), `ORACLE_DISAGREEMENT`, `ORACLE_UNAVAILABLE`,
  `SEQUENCER_DOWN`. Note: when Chainlink is stale but TWAP saves the
  check, no revert happens, so `ORACLE_STALE` fires only when a stale
  read is the *last* available source and it fails — in practice the
  terminal reason is `ORACLE_UNAVAILABLE`. Keep `ORACLE_STALE` in the
  enum for the `simulateCheck` / UI path to distinguish "stale" from
  "missing", but `check()` reverts with `ORACLE_UNAVAILABLE` when no
  source is usable. The implementation must pick one and document it;
  the mirror tests pin whichever is chosen.
- New errors: `OracleConfigInvalid(string reason)`,
  `UnknownOracle(address token)`.
- New events: `OracleConfigSet(uint256 indexed policyId, address indexed token, address feed, address pool)`,
  `OracleConfigRemoved(uint256 indexed policyId, address indexed token)`,
  `PriceConfigUpdated(uint256 indexed policyId)`.
- New functions: `setOracleConfig(uint256 policyId, address token, OracleConfig calldata cfg)` (owner only),
  `removeOracleConfig(uint256 policyId, address token)` (owner only),
  `getOracleConfig(uint256 policyId, address token) returns (OracleConfig)`,
  `setPriceConfig(uint256 policyId, PriceConfig calldata cfg)` (owner only —
  **timelocked**, §2.1, because it changes what counts as a violation),
  `getReferencePrice(uint256 policyId, address tokenIn, address tokenOut) returns (uint256 price1e18, address source)`
  (view; `source` is the feed or pool that supplied the price, `address(0)`
  when no oracle is configured — used by the frontend simulator and the
  fork tests; it shares the resolution code with `check()` so the two
  cannot drift).
- `PriceConfig` changes are timelocked (§2.1). `OracleConfig` changes are
  **also timelocked**: swapping a feed or a pool changes the reference the
  same way loosening a cap does. Only the *initial* registration of an
  oracle config (when none existed) is immediate.

### 1.7 Gas

- Chainlink `latestRoundData()` via proxy: ~3–7k gas per feed (proxy
  SLOADs + aggregator read). Two feeds: ~6–14k.
- Uniswap `observe([T, 0])`: ~10–30k gas (binary search over the
  observation ring + interpolation; more for old windows on busy pools).
- Sequencer feed read: ~3k gas.
- Total added cost per SWAP check with both sources fresh: **~20–50k gas**.
  Non-swap checks pay nothing extra (no oracle read).
- Target: a swap `check()` stays under **250k gas** all-in. Measure in the
  gas-benchmark test (§5) and record the number; if it exceeds the target,
  the implementation must say so rather than silently shipping it.
  (Revised 21 Nov 2026: the original 120k target was set from an estimate
  that understated real oracle costs. Measured on a real Arbitrum One fork
  with real Chainlink feeds, the real Uniswap pool, and the sequencer feed,
  a SWAP check() costs 226,019 gas warm; the mock-based number was 127,475.
  The 250k target is set from the real measurement with ~10% headroom.)

### 1.8 Test plan (oracle part)

Mocks (in `test/`, never `src/`): `MockAggregatorV3` (scriptable
`answer`, `updatedAt`, `decimals`, `roundId`, `answeredInRound`),
`MockUniswapV3Pool` (scriptable `observe()` tick cumulatives; scriptable
revert with `OLD`), `MockSequencerFeed` (scriptable `answer`, `startedAt`).

Unit tests (`Oracle.t.sol`, new):
- Chainlink-only reference: correct 1e18 scaling for 6-dec USDC vs
  18-dec WETH and for 18/18 pairs; feed-decimals conversion.
- TWAP-only reference: tick → price conversion both directions
  (token0→token1 and token1→token0), including the inversion case.
- Both agree → Chainlink wins; both agree within 200 bps → pass.
- Disagreement 201 bps → `ORACLE_DISAGREEMENT`; 199 bps → pass.
- Chainlink stale (updatedAt beyond `chainlinkStaleAfter`) → TWAP used;
  TWAP also stale/missing → `ORACLE_UNAVAILABLE`.
- Chainlink answer ≤ 0 → treated as unreadable; `answeredInRound < roundId`
  → unreadable.
- TWAP `observe()` reverts → Chainlink used; both fail → `ORACLE_UNAVAILABLE`.
- No oracle configured for the pair → price rule skipped, check passes
  (v1 behaviour preserved).
- Sequencer down → `SEQUENCER_DOWN` before any price read; grace period
  (startedAt within 3600 s) → `SEQUENCER_DOWN`; `startedAt == 0` → treated
  as up.
- `getReferencePrice` returns the same price `check()` uses (call both in
  the same test, assert equality).
- `simulateCheck` mirror: for every revert above, `simulateCheck` returns
  `(false, same Reason)`; for every pass, `(true, NONE)`.

Fork tests:
- `SepoliaFork.t.sol` (extend): against the **real stale Sepolia ETH/USD
  feed**, a swap check with only Chainlink configured reverts
  `ORACLE_UNAVAILABLE` — the live proof the staleness guard works.
  Fresh-price paths on Sepolia use `MockAggregatorV3` deployed on the fork.
- `ArbitrumOneFork.t.sol` (new): fork `https://arb1.arbitrum.io/rpc`;
  resolve the reference for WETH→USDC against the **real** Chainlink feeds
  and the **real** `0xC696...` pool; assert the TWAP tick math matches a
  direct `observe()` call; assert the sequencer feed reads 0 (up);
  assert a 5%-pushed execution price reverts `PRICE_DEVIATION` while the
  oracles stay fresh. (Public RPC, forge-cached; no key needed.)
- **TWAP manipulation-cost test** (One fork): simulate a large swap that
  pushes the pool price 5%, hold it by warping 1800 s with the price held
  (via repeated swaps or direct reserve manipulation in the test), and
  measure the attacker's loss vs the outflow cap the guard would have let
  through. Records the order-of-magnitude cost; if the cost is ever *below*
  the extractable value, the window or the cap is wrong and the test must
  fail loudly with the numbers.

## 2. Policy hardening

### 2.1 Timelock on policy updates

**Delay: 24 hours (86400 s) default**, per-policy configurable within
[3600 s, 604800 s] (1 h – 7 days). The delay itself is a policy field and
can only be changed through the timelock (a new delay applies to proposals
made *after* the delay-change executes — the Compound pattern — so the
delay can never be shortened to dodge a pending update).

**Flow (owner only):**
1. `proposePolicyUpdate(policyId, Policy calldata newPolicy, PriceConfig calldata newPrice)` →
   stores `PendingUpdate { Policy policy; PriceConfig price; uint256 executableAt; uint256 proposedAt; }`,
   emits `PolicyUpdateProposed(policyId, executableAt)`. Reverts if a
   proposal is already pending for the policy (`PendingUpdateExists`).
   `executableAt = block.timestamp + policyTimelockSeconds` (the *current*
   delay, not the proposed one).
2. `executePolicyUpdate(policyId)` → callable by the owner only, only when
   `block.timestamp >= executableAt` and `block.timestamp <= proposedAt + 7 days`
   (7-day execution window; after that the proposal lapses and must be
   re-proposed). Applies the new `Policy` + `PriceConfig`, emits
   `PolicyUpdateExecuted(policyId)`, clears the pending slot.
3. `cancelPolicyUpdate(policyId)` → owner only, any time before execution;
   emits `PolicyUpdateCancelled(policyId)`.

**What is timelocked vs immediate:**

| Change | Timelock? | Rationale |
|---|---|---|
| `updatePolicy` (any limit change) | Yes | Loosening a cap is the attack. |
| `PriceConfig` changes | Yes | Changes what counts as a violation. |
| `OracleConfig` changes (feed/pool swap) | Yes, except initial registration | Swapping the reference is equivalent to loosening the rule. |
| `setEnabled(true)` (re-enable) | Yes | Re-enabling is the dangerous direction. |
| `setEnabled(false)` (disable) | **No — immediate** | Disabling is fail-closed; delaying it helps no one. |
| `registerPolicy` (new policy) | No | A new policy guards nothing until the protocol calls `check()` with it; the protocol's own deployment is the review point. |
| Keeper add/remove | No (events emitted) | Keepers can only trip (safe direction). See open question §6 Q5. |
| `trip` / `throttle` | No | Emergency response must be instant. |
| `reset` / `unthrottle` | No (owner only) | Recovery must not wait on a clock. |

**Events:** `PolicyUpdateProposed(uint256 indexed policyId, uint256 executableAt)`,
`PolicyUpdateExecuted(uint256 indexed policyId)`,
`PolicyUpdateCancelled(uint256 indexed policyId)`.
**Errors:** `PendingUpdateExists(uint256 policyId)`, `NoPendingUpdate(uint256 policyId)`,
`TimelockNotElapsed(uint256 executableAt)`, `ProposalExpired(uint256 proposedAt)`.

### 2.2 Multi-keeper support

- `Policy.keeper` (single address) is **removed**. Keepers live in
  `mapping(uint256 policyId => mapping(address => bool)) public isKeeper`
  plus `mapping(uint256 => address[]) private _keepers` for enumeration.
- `addKeeper(policyId, keeper)` / `removeKeeper(policyId, keeper)` — owner
  only, immediate, events `KeeperAdded(policyId, keeper)` /
  `KeeperRemoved(policyId, keeper)`. `removeKeeper` uses swap-and-pop on
  the array. Max 10 keepers per policy (`TooManyKeepers`); the bound keeps
  enumeration gas predictable and forces a real discussion if a protocol
  wants more.
- Any keeper (or the owner) may `trip` or `throttle`. No keeper may
  `reset`, `unthrottle`, change a policy, or manage the keeper set.
- `PolicyRegistered` event drops the `keeper` field (it no longer exists);
  keepers are announced by their own events. The deploy script registers
  the deployer as the first keeper (`KEEPER` env still supported; if unset,
  deployer).
- Migration: v1's single keeper becomes the first entry of the set.
  `NotKeeperOrOwner` error stays, now covering the set.

### 2.3 Graduated response — throttle mode

New `Mode` enum per policy: `NORMAL`, `THROTTLED`, `PAUSED`. Stored as
`mapping(uint256 => Mode) public modeOf` plus `pausedUntil` (v1) and a new
`throttleUntil` (0 = indefinite).

| Mode | Meaning | `check()` behaviour |
|---|---|---|
| NORMAL | Full limits | Caps as registered. |
| THROTTLED | Degraded limits | Effective caps = registered caps × `throttleBps` / 10000. Default `throttleBps` = 1000 (10%). Applies to block, hour, and day windows. Price-deviation and single-share rules unchanged. |
| PAUSED | Frozen | Every `check()` reverts `BREAKER_TRIPPED` (v1 behaviour). |

**Transitions:**
- `throttle(policyId, uint32 durationSeconds, bytes evidence)` — any
  keeper or owner; NORMAL → THROTTLED. `durationSeconds == 0` means
  indefinite; otherwise `throttleUntil = block.timestamp + durationSeconds`.
  Emits `ThrottleSet(policyId, tripper, throttleUntil)`. Reverts if already
  throttled or paused (`AlreadyThrottled` / `BreakerTripped` state).
  Suggested keeper-bot default duration: 86400 s (24 h).
- `unthrottle(policyId)` — owner only; THROTTLED → NORMAL, clears
  `throttleUntil`. Emits `ThrottleCleared(policyId)`.
- `trip(policyId, evidence)` — any keeper or owner; NORMAL or THROTTLED →
  PAUSED, `pausedUntil = block.timestamp + cooldownSeconds` (v1).
  Emits `BreakerTripped` (v1).
- `reset(policyId)` — owner only, after cooldown; PAUSED → NORMAL, clears
  `pausedUntil` (v1). **Spec decision: reset returns to NORMAL, not to
  the pre-trip mode.** The owner has reviewed; if still worried they
  re-throttle with one call. See open question §6 Q4.
- **Auto-expiry:** PAUSED auto-resumes after `pausedUntil` (v1). THROTTLED
  auto-clears after `throttleUntil` when a duration was set; an indefinite
  throttle persists until the owner clears it.
- `simulateCheck` mirrors the mode: THROTTLED uses the scaled caps;
  PAUSED returns `(false, BREAKER_TRIPPED)`.

**Why throttle exists:** tripping is binary — a suspicious-but-unconfirmed
signal (e.g. a large but possibly legitimate withdrawal, an oracle wobble)
should not freeze the protocol, but should not be ignored either. Throttle
buys the same thing a pause buys (time) at a lower cost (legitimate users
keep moving, slowly). The keeper bot's first response to an anomaly is
throttle; its second, if the anomaly confirms, is trip.

`throttleBps` is a `Policy` field (`uint16`, 1–10000, default 1000),
validated at registration/update (`InvalidPolicy` if 0 or > 10000).
Changing it is a timelocked policy update (§2.1).

### 2.4 Velocity windows — per-hour and per-day outflow caps

**Problem (v1, documented):** "An attacker who stays under
`maxOutflowPerBlock` every block can still bleed a protocol over hours or
days." The per-block cap bounds the *rate*; nothing bounds the *total*
over a long attack.

**Design:** two more windows alongside the per-block window, keyed on
**wall-clock time, not block number** (Arbitrum `block.number` is the L1
block number, ~12 s — see `SepoliaFork.t.sol` — so a block-keyed hour
window would be fragile; timestamps are unambiguous):

```solidity
mapping(uint256 => uint256) public outflowInHour;
mapping(uint256 => uint256) public outflowHour;   // block.timestamp / 3600
mapping(uint256 => uint256) public outflowInDay;
mapping(uint256 => uint256) public outflowDay;    // block.timestamp / 86400
```

- New `Policy` fields: `uint256 maxOutflowPerHour; uint256 maxOutflowPerDay;`
- **`0 = that window is not enforced`** (differs deliberately from v1's
  block rule, where 0 = no outflow at all — the new windows must default
  to off, or every existing policy would block everything on migration).
- Enforcement order in `check()`: block → hour → day; first failure
  reverts with `OUTFLOW_PER_BLOCK`, `OUTFLOW_PER_HOUR`, or
  `OUTFLOW_PER_DAY` respectively.
- Throttle scales all three windows (§2.3).
- Windows roll over on first check of a new hour/day (same lazy-reset
  pattern as the block window).
- `simulateCheck` reads the current hour/day windows; a stale window
  counts as zero (mirror of the block-window logic).
- **Suggested demo defaults** (vault policy: block 100 ether): hour
  2,000 ether (20× block), day 10,000 ether (100× block). Rationale: at
  the 100/block cap an attacker could otherwise drain 30,000/hour
  (~300 L1 blocks/hour); the hour cap stops the bleed after ~20 blocks
  (~4 minutes). Pool policy (block 10,000 ether): hour 200,000, day
  1,000,000. These are demo numbers; real policies tune per protocol.
  The spec requires the deploy script to set all three windows, never
  leave hour/day at 0 in the demo.

## 3. Consolidated interface (Phase 1)

### 3.1 Structs

```solidity
struct Policy {
    uint256 maxOutflowPerBlock;
    uint256 maxOutflowPerHour;    // NEW, 0 = unenforced
    uint256 maxOutflowPerDay;     // NEW, 0 = unenforced
    uint16 maxSingleShareBps;
    uint16 maxPriceDeviationBps;
    uint16 throttleBps;           // NEW, default 1000 (10%)
    uint32 cooldownSeconds;
    uint32 policyTimelockSeconds; // NEW, default 86400, range [3600, 604800]
    bool enabled;
    // REMOVED: address keeper (now a per-policy set, §2.2)
}

struct Action {
    ActionKind kind;
    address token;    // tokenOut for swaps
    address tokenIn;  // NEW, token being sold; address(0) for non-swaps
    uint256 amountOut;
    uint256 amountIn;
    uint256 price;    // execution price, 1e18-scaled, tokenOut per tokenIn
    uint256 tvl;
    // REMOVED: uint256 twapPrice (guard resolves it, §1)
}

struct OracleConfig { address chainlinkFeed; address uniswapPool; uint8 feedDecimals; uint8 tokenDecimals; }
struct PriceConfig { uint32 twapSeconds; uint16 maxOracleDeviationBps; uint32 chainlinkStaleAfter; address sequencerFeed; }
struct PendingUpdate { Policy policy; PriceConfig price; uint256 executableAt; uint256 proposedAt; }

enum Reason {
    NONE,
    OUTFLOW_PER_BLOCK,
    OUTFLOW_PER_HOUR,     // NEW
    OUTFLOW_PER_DAY,      // NEW
    SINGLE_SHARE,
    PRICE_DEVIATION,
    BREAKER_TRIPPED,
    ORACLE_STALE,         // NEW (see §1.6 note)
    ORACLE_DISAGREEMENT,  // NEW
    ORACLE_UNAVAILABLE,   // NEW
    SEQUENCER_DOWN        // NEW
}

enum Mode { NORMAL, THROTTLED, PAUSED }  // NEW
```

### 3.2 New / changed functions

| Function | Access | Notes |
|---|---|---|
| `registerPolicy(protocol, Policy, PriceConfig)` | owner | PriceConfig now registered together; validates timelock range, throttleBps, windows. |
| `proposePolicyUpdate(policyId, Policy, PriceConfig)` | owner | §2.1 |
| `executePolicyUpdate(policyId)` | owner | §2.1 |
| `cancelPolicyUpdate(policyId)` | owner | §2.1 |
| `getPendingUpdate(policyId) returns (PendingUpdate)` | view | |
| `setEnabled(policyId, bool)` | owner | `false` immediate; `true` timelocked (§2.1) |
| `addKeeper / removeKeeper(policyId, keeper)` | owner | §2.2, max 10 |
| `getKeepers(policyId) returns (address[])` | view | |
| `throttle(policyId, durationSeconds, evidence)` | keeper/owner | §2.3 |
| `unthrottle(policyId)` | owner | §2.3 |
| `trip(policyId, evidence)` | keeper/owner | unchanged signature, now also from THROTTLED |
| `reset(policyId)` | owner | unchanged, returns to NORMAL |
| `setOracleConfig / removeOracleConfig(policyId, token, ...)` | owner | §1.6, timelocked except initial registration |
| `getOracleConfig(policyId, token)` | view | |
| `setPriceConfig(policyId, PriceConfig)` | owner | timelocked (via propose/execute, not direct) |
| `getReferencePrice(policyId, tokenIn, tokenOut)` | view | §1.6 |
| `getMode(policyId) returns (Mode)` | view | |
| `check(protocol, Action)` | protocol only | order: sequencer → paused → block → hour → day → share → price |
| `simulateCheck(protocol, Action)` | view | mirrors `check()` exactly, incl. mode, throttle, oracle reads |

### 3.3 New events and errors

Events: `PolicyUpdateProposed`, `PolicyUpdateExecuted`,
`PolicyUpdateCancelled`, `KeeperAdded`, `KeeperRemoved`,
`ThrottleSet`, `ThrottleCleared`, `OracleConfigSet`,
`OracleConfigRemoved`, `PriceConfigUpdated`.
(`PolicyRegistered` drops the `keeper` field; `BreakerTripped`,
`BreakerReset`, `CheckPassed`, `PolicyUpdated`, `PolicyEnabled` stay.
`PolicyUpdated` now fires from `executePolicyUpdate`, not from a direct
update — there is no direct update anymore.)

Errors: `PendingUpdateExists`, `NoPendingUpdate`, `TimelockNotElapsed`,
`ProposalExpired`, `TooManyKeepers`, `AlreadyThrottled`,
`OracleConfigInvalid`, plus the v1 set (`ArbGuardViolation`,
`UnknownPolicy`, `UnknownPolicyId`, `PolicyAlreadyRegistered`,
`InvalidPolicy`, `NotProtocol`, `NotKeeperOrOwner`,
`BreakerStillActive`).

### 3.4 Updated `check()` order (normative)

```
1. caller == protocol, else NotProtocol
2. policy exists, else UnknownPolicy
3. sequencer check (if sequencerFeed != address(0)), else SEQUENCER_DOWN
4. !enabled or paused → BREAKER_TRIPPED
5. outflow windows (effective caps after throttle scaling):
   block → OUTFLOW_PER_BLOCK; hour → OUTFLOW_PER_HOUR; day → OUTFLOW_PER_DAY
6. single share → SINGLE_SHARE
7. swaps only: resolve reference (§1.3) → compare → PRICE_DEVIATION
   (or ORACLE_DISAGREEMENT / ORACLE_UNAVAILABLE / SEQUENCER_DOWN)
8. emit CheckPassed
```

`simulateCheck` runs the identical sequence as a view and returns
`(false, reason)` at the first failing step, `(true, NONE)` if all pass.

## 4. Migration (v1 → Phase 1)

This is a **breaking change**. v1 contracts are not upgradeable (no proxy),
so Phase 1 deploys as a new `ArbGuard` (same name, new deployment; the
deploy script records the new addresses and the README notes the v1
deployment as superseded).

What changes where:
- `ArbGuard.sol`: everything in §3.
- `GuardedVault.sol`: drop `twapPrice: 0` from the `Action` literal.
- `GuardedPool.sol`: drop `twapPrice` and the `lastPrice01/10` TWAP proxy
  (delete the fields and the once-per-block refresh; the guard now owns the
  reference). Pass `tokenIn`. The pool's own price display, if the frontend
  uses it, reads the guard's `getReferencePrice` instead.
- `Attacker.sol`: `pushPriceAndSwap` still works unchanged (it attacks the
  pool; the guard's reference now comes from oracles, which is exactly what
  makes the attack fail in the demo).
- `DeploySepolia.s.sol` / `DeployMainnet.s.sol`: new `Policy` literals
  (hour/day windows, `throttleBps`, `policyTimelockSeconds`), `PriceConfig`
  literals, oracle config for WETH/USDC (Sepolia: Chainlink ETH/USD only,
  and the script must log that the feed is stale — the Sepolia demo's swap
  path uses the mock-oracle route in tests, not the stale feed), keeper
  registration via `addKeeper` (deployer first, `KEEPER` env override).
- `apps/web`: policy form gains hour/day caps, throttle %, timelock delay,
  TWAP window, oracle addresses; the attack simulator builds the new
  `Action` (with `tokenIn`, without `twapPrice`); the live feed shows the
  new events (`ThrottleSet`, `PolicyUpdateProposed`, …). The simulator's
  `simulateCheck` usage is unchanged in shape.
- `docs/ARCHITECTURE.md`: update the invariant model (three rules → five
  checks), the trust assumptions (owner timelock, keeper set, oracle
  trust), and close open question 3 (TWAP choice: Chainlink primary +
  Uniswap V3 TWAP cross-check, 1800 s default).
- `docs/DEPLOY-CHECKLIST.md`: new deploy addresses, new policy values,
  oracle config recorded per chain.

## 5. Test plan

### 5.1 Unit tests (new files; mocks in `test/`, never `src/`)

- `Oracle.t.sol` — §1.8 (resolution, scaling, failure matrix, sequencer,
  mirror tests).
- `Timelock.t.sol` — propose/execute/cancel; early execute reverts
  `TimelockNotElapsed`; late execute reverts `ProposalExpired`; double
  proposal reverts; delay shortening takes effect only for later
  proposals; `setEnabled(false)` immediate; `setEnabled(true)` timelocked;
  oracle-config swap timelocked, initial registration immediate.
- `Keepers.t.sol` — add/remove, 10-keeper cap, any keeper trips/throttles,
  non-keeper reverts, keeper cannot reset/update/manage keepers, keeper
  removal by swap-and-pop preserves the set.
- `Throttle.t.sol` — throttle scales block/hour/day caps (assert exact
  effective caps at 1000 bps); unthrottle owner-only; throttle expiry
  (vm.warp past `throttleUntil` → NORMAL); indefinite throttle persists;
  trip from THROTTLED; reset → NORMAL; `simulateCheck` mirrors throttled
  caps.
- `Velocity.t.sol` — hour/day rollover (vm.warp); slow bleed under the
  block cap stopped by the hour cap (assert the exact block where it
  stops); day cap binds after hour cap; 0 = window unenforced; throttle
  scaling on hour/day; mirror tests for `OUTFLOW_PER_HOUR` /
  `OUTFLOW_PER_DAY`.
- `Mirror.t.sol` — a table-driven test: for every rule in §3.4, assert
  `check()` reverts with reason R **iff** `simulateCheck()` returns
  `(false, R)`. This file is the lock-step guarantee; it must grow with
  every future rule.

### 5.2 Fork tests

- `SepoliaFork.t.sol` (extend): real stale Sepolia ETH/USD feed →
  swap check reverts `ORACLE_UNAVAILABLE` (live staleness proof);
  fresh-price paths use `MockAggregatorV3` on the fork; existing drain
  tests re-run against the new struct (hour/day windows set, throttle
  default).
- `ArbitrumOneFork.t.sol` (new): fork `https://arb1.arbitrum.io/rpc`;
  real Chainlink ETH/USD + USDC/USD and the real WETH/USDC pool;
  reference-price resolution matches a direct `observe()` call;
  sequencer feed reads 0; a 5%-pushed swap reverts `PRICE_DEVIATION`;
  TWAP manipulation-cost test (§1.8).

### 5.3 Gas benchmarks

- `Gas.t.sol` (new): measure `check()` gas for WITHDRAW (no oracle),
  SWAP with Chainlink-only, SWAP with Chainlink+TWAP, SWAP in THROTTLED
  mode. Assert the swap-with-both-oracles case stays under 250k gas and
  record the numbers in the test output. If the target is missed, the
  implementation reports it — the target is not silently dropped.

## 6. Open questions (flagged, not guessed)

1. **No USDC/USD feed on Arbitrum Sepolia.** Not found in Chainlink's
   published lists. Confirm against the Chainlink addresses page; if
   absent, Sepolia demos are ETH/USD-only (and stale). Does the team want
   a mock USDC feed deployed on Sepolia for the demo, or ETH-only?
2. **Arbitrum Sepolia sequencer uptime feed.** Not verified to exist.
   If none exists, Sepolia deployments set `sequencerFeed = address(0)`
   (check skipped) and the spec notes it as a testnet-only gap.
3. **Throttle default and scope.** `throttleBps` default 1000 (10%).
   Should the price-deviation rule also tighten in THROTTLED mode (e.g.
   halve `maxPriceDeviationBps`)? Spec says no (caps only); confirm.
4. **Reset destination.** Spec: `reset()` returns to NORMAL. Alternative:
   return to the pre-trip mode (THROTTLED if it was throttled). Confirm.
5. **Keeper removal timelock.** Spec: immediate. Alternative: removal
   timelocked (a compromised owner removing all keepers, then attacking,
   is blunted by the policy timelock anyway). Confirm.
6. **Chainlink heartbeat/deviation parameters for Arbitrum feeds.**
   Published values used (ETH/USD 3600 s / 0.5%, USDC/USD ~24 h / 0.25%).
   Confirm by measuring `updatedAt` deltas across rounds in the One fork
   test.
7. **Proposal execution window.** Spec: 7 days. Confirm.
8. **TWAP window default.** Spec: 1800 s. Alternative: 3600 s (Aave-style).
   Confirm; low-liquidity pairs should use longer windows in any case.
9. **Per-pair vs per-token oracle config.** Spec: feeds per token (USD
   ratio) + pool stored on both tokens of the pair. Confirm the
   both-tokens convention.
10. **Gas ceiling.** Target 250k gas for a swap check with both oracles
    (revised from 120k on 21 Nov 2026 after measuring 226,019 warm on a
    real Arbitrum One fork). Confirm the target; measure in §5.3.
11. **Pyth as a third source.** Out of scope for Phase 1. Revisit if a
    Phase 1 pair has no Chainlink feed (e.g. a long-tail token).
12. **`ORACLE_STALE` vs `ORACLE_UNAVAILABLE`.** Spec keeps both in the
    enum but `check()` reverts with `ORACLE_UNAVAILABLE` when no source is
    usable (§1.6 note). Implementation must pick one behaviour and the
    mirror tests pin it.

## Appendix A — Verification log (19 Nov 2026, live reads)

Arbitrum One (`https://arb1.arbitrum.io/rpc`):
- `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` ETH/USD:
  `latestRoundData` → roundId 36893488147419267445, answer 177170093781
  ($1,771.70), updatedAt 1795109095; `decimals()` → 8;
  `description()` → `"ETH / USD"`.
- `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` USDC/USD:
  answer 99995000 ($0.99995), updatedAt 1795109044; decimals 8;
  description `"USDC / USD"`.
- `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` sequencer:
  answer 0 (up), startedAt 1779307607; description
  `"L2 Sequencer Uptime Status Feed"`.
- `0xC6962004f452bE9203591991D15f6b388e09E8D0` pool:
  token0 WETH, token1 USDC, fee 500, liquidity ~1.03e18, slot0 tick
  −201488, `observe([1800, 0])` returns tick cumulatives
  [−21542904798669, −21543267666301] (TWAP tick ≈ −201593).
- Factory `0x1F98431c8aD98523631AE4a59f267346ea31F984` (read from the NPM
  `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` `factory()`); WETH9
  `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`.

Arbitrum Sepolia (`https://sepolia-rollup.arbitrum.io/rpc`):
- `0xbF13EE58Bf62500FE87e7389faB633ff95dec029` ETH/USD:
  answer 262684000000 ($2,626.84), decimals 8, description `"ETH / USD"`,
  **`updatedAt` 1729103473 (16 Oct 2024) — stale by ~2 years.**

Sources: Chainlink Data Feeds docs (feed addresses page; CRE read-data-feeds
template naming the One ETH/USD proxy; L2 sequencer feeds page naming the
One sequencer feed); Revert Lend Arbitrum deployment (dual-oracle
`CHAINLINK_TWAP_VERIFY` mode, 2% max pool deviation, USDC feed `0x5083…`,
pool `0xC696…`); Arbiscan traces (Aave Oracle V3 → proxy → aggregator).
