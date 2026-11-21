# ArbGuard Phase 2 — Real Arbitrum coverage: Aave V3 + Uniswap V3 adapters

**Status:** spec, 20 Nov 2026. No code written against it yet.
**Scope:** `ArbGuard.sol` (two new rules + two new `Action`/`Policy` fields),
two new adapter contracts (`AaveAdapter.sol`, `UniswapV3Adapter.sol`),
deploy script (Sepolia adapter note), fork tests on Arbitrum One.
No public-chain deployment in this phase; the Sepolia deployment of the
adapters is an open question (§6 Q1).
**Design constraints carried over from Phase 1 (non-negotiable):**
- No `ViolationBlocked` event — a reverted transaction cannot leave a
  persistent event; blocked attempts surface via the revert reason and
  `simulateCheck()` only (`ARCHITECTURE.md`, "The reverted-tx event note").
  The same applies to the adapters: an adapter function that reverts
  leaves no event. The adapter must not claim otherwise.
- `check()` and `simulateCheck()` stay in lock-step: same rules, same order,
  same thresholds. Every new rule gets a paired mirror test (extend
  `Mirror.t.sol`).
- All arithmetic is Solidity 0.8 checked arithmetic; overflow reverts
  (fail-closed).
- **All 159 currently passing Phase 1 tests must still pass.** The 2
  gas-target failures (SWAP Chainlink+TWAP 126,848, THROTTLED 129,593 vs
  the 120k target) stay as the only failures; Phase 2 does not re-baseline
  them and does not silently drop them. Any new failure is a spec
  violation, not a test to fix.
- The Stylus checker stays out of this phase: adapter logic needs external
  calls, which cannot be pure functions. The Solidity path remains the
  enforcement path.
- `ArbGuard.sol` must stay under the 24,576-byte EIP-170 limit. It is
  22,275 bytes after the Phase 1 slimming, so the budget for the new rules
  is 2,301 bytes. If the implementation exceeds it, slim by deduplication
  (as in Phase 1), never by dropping a rule. Verify with
  `forge build --sizes` (§5.4).

## 0. The trust flaw Phase 2 fixes

Phase 1 made the guard honest about prices and hard to switch off, but it
only guards contracts that call `check()` — the demo `GuardedVault` and
`GuardedPool`, which Muhammed's team wrote. The protocols that actually
hold money on Arbitrum (Aave V3, Uniswap V3) do not call `check()` and
never will: their code is deployed, audited, and immutable. A guard that
only protects contracts written for it protects nothing real.

Phase 2 closes that gap with **adapters**: thin, stateless pass-through
contracts that sit between the user and the real protocol. The user calls
the adapter instead of the pool; the adapter runs `ArbGuard.check()`
first, then forwards the call unchanged. The adapter holds no funds and
keeps no balances — tokens flow through it to the real protocol, and
Aave aTokens / Uniswap position NFTs go to the user, never to the adapter.
If the adapter is bypassed (the user calls the pool directly), the guard
simply does not apply — the adapter is an opt-in firewall, not a protocol
upgrade, and the spec says so plainly. What the adapter *does* guarantee:
any action routed through it cannot break the policy, and any action that
would break it reverts before the protocol call executes.

Two new rules come with the adapters, because the Phase 1 rules do not
cover the two ways a lending pool and an AMM actually die:

1. **Health factor.** Aave liquidates a position when its health factor
   drops below 1. A borrow (or a collateral withdrawal) that pushes a
   user's health factor toward liquidation is the lending-pool equivalent
   of a drain: the value is still there, but the user's position is
   doomed and the protocol eats bad debt. Phase 1 has no rule for it.
2. **Reserve drain.** Aave's USDC reserve on Arbitrum One is ~99.99%
   utilised (verified live, §1.1): about 10,174 USDC of available
   liquidity against ~160.9M supplied. A single large borrow can take
   the whole available balance. The per-block outflow cap bounds the
   *rate*, but a reserve that is already nearly empty needs a rule about
   the *share of what is left*. Same shape on Uniswap: a swap that takes
   most of a pool's available tokenOut is a drain even when the price
   rule passes.

## 1. Aave V3 adapter

### 1.1 Verified address inventory + live reserve state (read live, 20 Nov 2026)

All addresses below were verified by direct `cast call` against the
public Arbitrum One RPC (`https://arb1.arbitrum.io/rpc`), starting from
the PoolAddressesProvider and following its own getters — no address was
taken from a docs page without an on-chain read. See Appendix A for the
raw outputs.

**Aave V3 — Arbitrum One market ("Arbitrum Aave Market")**

| Contract | Address (verified on-chain) |
|---|---|
| PoolAddressesProvider | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` |
| Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| PoolDataProvider | `0x243Aa95cAC2a25651eda86e80bEe66114413c43b` |
| AaveOracle | `0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7` |
| ACLManager | `0xa72636CbcAa8F5FF95B2cc47F3CDEe83F3294a0B` |

The Pool, PoolDataProvider, AaveOracle and ACLManager addresses above
were all returned by the PoolAddressesProvider's own getters
(`getPool()`, `getPoolDataProvider()`, `getPriceOracle()`,
`getACLManager()`), and `getMarketId()` returns `"Arbitrum Aave Market"`.
The PoolDataProvider address starts `0x243Aa95cAC2a2565` as expected.
Any future redeployment is detected by re-reading the provider — the
adapter stores the Pool address as immutable at deployment and the spec
requires the deploy script to re-derive it from the provider, never to
hard-code a stale copy.

**Reserve state at read (20 Nov 2026, block time ~1795188200)**

| Reserve | aToken | Variable debt token | Total supplied | Total variable debt | Available liquidity | Utilisation |
|---|---|---|---|---|---|---|
| WETH `0x82aF…Bab1` (18 dec) | `0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8` | `0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351` | ~100,792 WETH | ~52,924 WETH | ~47,868 WETH | ~52.5% |
| USDC `0xaf88…5831` (6 dec) | `0x724dc807b04555b71ed48a6896b6F41593b8C637` | `0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6` | ~160,893,354 USDC | ~160,883,179 USDC | **~10,174 USDC** | **~99.99%** |

Notes:
- Stable debt is `address(0)` for both reserves (stable borrowing is
  disabled); the adapter only supports variable-rate borrows
  (`interestRateMode == 2`). A call with mode 1 reverts `AdapterError`.
- WETH: LTV 81%, liquidation threshold 84%, liquidation bonus 5%,
  reserve factor 15%, liquidity rate ~0.80% APR, variable borrow rate
  ~1.78% APR.
- USDC: liquidation threshold 78%, liquidation bonus 5%, reserve factor
  10%. **LTV reads 0** on `getReserveConfigurationData` for the native
  USDC reserve (usage-as-collateral is enabled but the LTV is zero), so
  USDC cannot be used as collateral on this market. The fork test must
  confirm the LTV reading and the spec flags it (§6 Q5); the adapter's
  health-factor projection must use the live LTV, not an assumed 80%.
- The USDC near-exhaustion is the live proof that the reserve-drain rule
  matters: a borrow of even 5,000 USDC takes ~49% of everything left.
  The fork test uses exactly this (§5.2).
- `Pool.getReservesList()` returns 20 reserves. The adapter supports any
  of them; the fork tests cover WETH and USDC only.
- AaveOracle: WETH $1,671.59, USDC $0.99982 at read; `BASE_CURRENCY` is
  `address(0)` (USD), `BASE_CURRENCY_UNIT` is 1e8. `getAssetsPrices`
  agrees with the individual `getAssetPrice` reads.
- `Pool.getUserAccountData` works (empty account returns zeros and
  health factor `type(uint256).max`). **`PoolDataProvider.getUserAccountData`
  reverted on a direct `cast call` in this pass** while the Pool's
  identical function returned cleanly — the adapter must use the **Pool's**
  `getUserAccountData` as its read, and the fork test must confirm
  whether the Provider variant works under Foundry (possible ABI quirk
  in the direct call, not necessarily a contract fault). Do not guess
  which one is right; the fork test decides (§5.2).

### 1.2 Adapter design — pass-through, no custody

`AaveAdapter.sol` (new file in `contracts/src/`). Immutable references
set at deployment: `ArbGuard`, `IPool`, `IPoolDataProvider`,
`IAaveOracle`. No owner, no upgrade path, no token balances held between
calls (any dust from rounding is swept to the caller, never retained).

**Guarded functions** (each calls `ArbGuard.check()` before forwarding):
- `borrow(asset, amount, interestRateMode, onBehalfOf)` — `interestRateMode`
  must be 2 (variable); `onBehalfOf` must be `msg.sender` (the adapter
  never borrows for a third party — that would let one user drain another
  user's credit line through the guard's blind spot).
- `withdraw(asset, amount, to)` — collateral withdrawal. `to` must be
  `msg.sender` (same reason: the withdrawn collateral belongs to the
  caller).
- `repay` and `supply` are **not guarded**: repaying can only improve a
  health factor, and supplying can only improve it. Calling `check()` for
  them would spend gas to prove a tautology. The spec requires the
  adapter to expose plain pass-through `supply`/`repay` wrappers (so a
  user can do their whole flow through one contract) with a comment
  stating they are intentionally unguarded, and the unit tests assert
  that a supply/repay path does not touch the outflow windows.

**What the adapter passes to `check()`** (per borrow/withdraw):

| `Action` field | Value for the Aave adapter |
|---|---|
| `kind` | `BORROW` / `WITHDRAW` |
| `token` | the reserve asset |
| `tokenIn` | `address(0)` (no swap) |
| `amountOut` | USD value of the amount, 1e18-scaled (via AaveOracle, §1.5) |
| `amountIn` | 0 |
| `price` | 0 (no swap) |
| `tvl` | reserve available liquidity, USD 1e18 (§1.4) |
| `healthFactorAfter` | projected post-action health factor, 1e18 (§1.3) |
| `availableLiquidity` | reserve available liquidity, USD 1e18 (§1.4) |

**Unit convention (normative).** For adapter policies, `amountOut`,
`tvl` and `availableLiquidity` are **USD 1e18**, and the policy caps
(`maxOutflowPerBlock/Hour/Day`, `maxSingleShareBps`) are denominated in
USD. The guard itself does not know or care about units — it enforces
the numbers it is given — so the unit convention lives in the adapter
and in the policy-registration helper, which must set a `usdDenominated`
marker (see §3.1) and revert if an adapter policy is registered without
it. Demo (non-adapter) policies stay in raw token units, exactly as in
Phase 1. Mixing the two conventions in one policy is a configuration
error the tests must catch: the fork test registers the adapter policy
with raw-unit caps and asserts the helper reverts.

**Forwarding.** After `check()` passes, the adapter forwards the call to
the Pool with identical arguments (`borrow(asset, amount, 2, 0, msg.sender,
address(this))` — note `referralCode 0` and the adapter as the
`onBehalfOf` caller is **not** used; the Pool call is made with
`onBehalfOf == msg.sender` so the debt is booked to the user, and the
borrowed tokens are sent to `msg.sender`). For `withdraw`, the Pool's
`withdraw(asset, amount, msg.sender)` sends the underlying to the user.
The adapter never receives tokens: `borrow` sends to the user directly,
`withdraw` sends to the user directly. If a future Pool version changes
that flow, the adapter must be re-audited — the spec requires a comment
to that effect at each forwarding call.

### 1.3 Health-factor projection (the new rule)

**Rule (new Reason `HEALTH_FACTOR`).** A `BORROW` or `WITHDRAW` whose
projected post-action health factor is below the policy minimum reverts.

The adapter computes the projection **before** calling `check()`, from
the Pool's own current account data plus the action's amounts — it does
not execute first and measure after, because `check()` is a
check-then-effect gate and the projection must be available to it:

```
(totalCollateralBase, totalDebtBase, , currentLiquidationThreshold, ltv, )
    = pool.getUserAccountData(msg.sender)          // base currency (USD), 1e8-scaled
collateralAfter = totalCollateralBase  (+ amountUSD for a supply, unchanged for borrow)
debtAfter       = totalDebtBase        (+ amountUSD for a borrow, unchanged for withdraw)
thresholdAfter  = currentLiquidationThreshold      // unchanged by a single-asset action
healthFactorAfter = collateralAfter * thresholdAfter / debtAfter   (1e18-scaled)
```

For a **borrow**: `debtAfter = totalDebtBase + amountUSD`; collateral
unchanged. For a **withdraw** (collateral removal): `collateralAfter =
totalCollateralBase - amountUSD`; debt unchanged; the threshold used is
the account's current liquidation threshold (the weighted average across
the user's collateral — read live, not assumed). Edge cases:
- `debtAfter == 0` → health factor is infinite; the adapter passes
  `type(uint256).max` and the rule passes (no debt, nothing to liquidate).
- `collateralAfter == 0 && debtAfter > 0` → health factor is 0; the rule
  fires (the user would be instantly liquidatable).
- `amountUSD` uses AaveOracle prices, the same source Aave uses for its
  own health factor — so the projection and Aave's post-action number
  should agree. The fork test asserts they agree within 1% (§5.2);
  if they ever diverge by more, the projection formula is wrong and the
  test must fail loudly with both numbers.

**Policy field:** `minHealthFactorBps` (uint16, §3.1). `0` = rule off.
When set, valid range is 10000–50000 (1.0×–5.0×); below 1.0× is already
liquidatable, so a minimum under 1.0× is a configuration error and
`registerPolicy`/`proposePolicyUpdate` revert `InvalidPolicy`.
**Demo default for the adapter policy: 12500 (1.25×).** Rationale: Aave
liquidates at 1.0×; 1.25× leaves a 25% buffer for price moves between
the borrow and any keeper response. A protocol that wants tighter
protection sets 15000; one that wants looser sets 11000. The spec does
not bless a value below 11000 for a production policy.

**Worked example (live state, §1.1).** User supplies 100 WETH
(~$167,159 at $1,671.59). LTV 81%, liquidation threshold 84%.
Borrowing WETH (available ~47,868, so liquidity is not the binding
constraint): at 67 WETH borrowed (~$111,976 debt), HF =
167,159 × 0.84 / 111,976 ≈ 1.254 — just above the 1.25 floor, passes.
At 68 WETH borrowed (~$113,648 debt), HF ≈ 1.236 — below the floor,
reverts `HEALTH_FACTOR`. The fork test uses exactly these numbers (§5.2).
Borrowing USDC cannot reach the boundary (only ~10,174 USDC available),
which is why the fork test borrows WETH for the health-factor case and
USDC for the reserve-drain case.

### 1.4 Reserve-drain rule (the new rule)

**Rule (new Reason `RESERVE_DRAIN`).** A `BORROW`, `WITHDRAW` or `SWAP`
that takes more than `maxReserveDrainBps` of the reserve's (or pool's)
available liquidity in one action reverts.

```
amountOut * 10_000 > availableLiquidity * maxReserveDrainBps  →  RESERVE_DRAIN
```

`availableLiquidity` is the reserve's available balance **before** the
action, in the same units as `amountOut` (USD 1e18 for adapter actions).
The adapter reads it as `totalAToken - totalStableDebt - totalVariableDebt`
from `PoolDataProvider.getReserveData(asset)`, and the fork test asserts
that number equals `IERC20(asset).balanceOf(pool)` (the Pool holds the
underlying; the two must agree — if they diverge, the adapter is reading
the wrong definition of "available" and the test fails with both numbers).

**Policy field:** `maxReserveDrainBps` (uint16, §3.1). `0` = rule off.
When set, valid range is 1–10000. **Demo default for the adapter policy:
5000 (50%).** Rationale: no single action should take more than half of
what is left; combined with the per-block outflow cap, that bounds both
the rate and the share. The USDC reserve is the live demonstration:
available ~10,174 USDC, so a 5,000 USDC borrow (49% of available) passes
and a 5,100 USDC borrow (50.1%) reverts `RESERVE_DRAIN` — the fork test
asserts exactly that boundary (§5.2).

**Why this is not the single-share rule.** `SINGLE_SHARE` compares
`amountOut` against `tvl` (the total value at risk). The drain rule
compares against `availableLiquidity` (what can actually leave right
now). They are different denominators and both matter: a borrow can be
a small share of total supplied (passes `SINGLE_SHARE`) while taking
everything left (fails `RESERVE_DRAIN`) — which is exactly the USDC
state today (a 10,000 USDC borrow is 0.006% of total supplied but 98% of
available). The adapter passes `tvl = availableLiquidity` for its
`BORROW`/`WITHDRAW` actions, so for the Aave adapter the two rules
coincide in the denominator but still differ in the threshold
(`maxSingleShareBps` vs `maxReserveDrainBps`) and in the reason
reported. The spec keeps both: `SINGLE_SHARE` is the generic rule,
`RESERVE_DRAIN` is the adapter-specific one with its own threshold and
its own revert reason, so a receipt names the actual failure.

### 1.5 USD normalisation — AaveOracle, not Chainlink directly

The adapter converts amounts to USD with `AaveOracle.getAssetPrice(asset)`
(1e8-scaled USD). Reasons: (a) it is the price Aave itself uses for
health factors, so the adapter's USD values and Aave's accounting agree
by construction; (b) one call covers every reserve, including long-tail
assets with no direct Chainlink feed; (c) it is a single, audited,
already-trusted price source for this market.

Trust note (honest, not hidden): AaveOracle is Chainlink-backed, but it
is Aave's wrapper, not the raw feeds. If AaveOracle is compromised or
stale, the adapter's USD values are wrong in the same direction as
Aave's own accounting — the guard would then enforce wrong limits, but
Aave itself would be mispricing liquidations at the same time, so the
adapter is no worse than the protocol it guards. The fork test asserts
AaveOracle is within 1% of the raw Chainlink feeds for WETH and USDC at
test time (§5.2); a larger divergence fails the test with both prices.
The adapter does **not** cross-check AaveOracle against Chainlink on
every call (that would double the oracle gas on the borrow path); the
cross-check lives in the fork test and in the keeper bot's monitoring,
not in the hot path. This is a deliberate scope decision, flagged as an
open question (§6 Q6).

### 1.6 Aave adapter interface

```solidity
/// @notice Pass-through guard for Aave V3 (Arbitrum One market).
/// Holds no funds. aTokens and debt are booked to msg.sender, never to
/// this contract. Supply/repay are intentionally unguarded (§1.2).
interface IAaveAdapter {
    function borrow(address asset, uint256 amount, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function supply(address asset, uint256 amount, address onBehalfOf) external; // unguarded
    function repay(address asset, uint256 amount, address onBehalfOf) external;  // unguarded
    function getProjectedHealthFactor(address user, address asset, uint256 amount, bool isBorrow)
        external view returns (uint256 healthFactorAfter);
    function getAvailableLiquidity(address asset) external view returns (uint256 availableUsd1e18);
    function getUsdValue(address asset, uint256 amount) external view returns (uint256 usd1e18);
}

error AdapterError(string reason);           // e.g. stable borrow, third-party onBehalfOf
error AdapterNotConfigured(address asset);   // reserve not in the adapter's allowlist
```

Notes:
- `borrow`/`withdraw` revert `AdapterError` when `interestRateMode`
  would be stable (the adapter always passes mode 2), when
  `onBehalfOf`/`to != msg.sender`, or when the asset is not in the
  adapter's reserve allowlist (set at deployment from
  `getReservesList()`; the deploy script records the allowlist).
- `getProjectedHealthFactor` is the exact function `borrow`/`withdraw`
  use internally, exposed as a view so the frontend simulator and the
  fork tests can call it directly and compare it against Aave's
  post-action `getUserAccountData`. The two must agree within 1%.
- The adapter stores no per-user state. Its only storage (besides
  immutables) is the reserve allowlist.
- The adapter's policy is registered by the **owner** (the ArbGuard
  owner) for the adapter's address, with `usdDenominated == true`
  (§3.1). The adapter itself never registers or updates a policy.

## 2. Uniswap V3 adapter

### 2.1 Verified pool inventory (read live, 20 Nov 2026)

All addresses below were verified by direct `cast call` against the
public Arbitrum One RPC. See Appendix A for the raw outputs.

**Uniswap V3 — Arbitrum One**

| Contract | Address (verified on-chain) |
|---|---|
| Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| NonfungiblePositionManager (NPM) | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` (18 dec) |
| USDC (native Circle) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` (6 dec) |

| Pool (WETH/USDC) | Address | Fee | Liquidity at read | slot0 tick at read |
|---|---|---|---|---|
| 0.05% (canonical) | `0xC6962004f452bE9203591991D15f6b388e09E8D0` | 500 | ~6.73e17 | −202104 |
| 0.3% | `0xc473e2aEE3441BF9240Be85eb122aBB059A3B57c` | 3000 | ~1.43e17 | −202089 |
| 1% | `0x42FC852A750BA93D5bf772ecdc857e87a86403a9` | 10000 | (not read — see note) | — |

Notes:
- The 0.05% pool is the canonical pool (already verified in Phase 1,
  §1.2; re-read 20 Nov 2026: token0 WETH, token1 USDC, fee 500,
  `observe([1800, 0])` works, observation cardinality 9000, tick spacing
  10, slot0 tick −202104 — the spot has moved from Phase 1's −201488,
  which is expected for a live pool). The fork tests use this pool.
- The 0.3% and 1% pool addresses were returned by
  `Factory.getPool(WETH, USDC, fee)` — the adapter resolves pools the
  same way at runtime (§2.3), so these addresses are recorded here as
  the fork-test fixtures, not as hard-coded adapter constants.
- `NPM.factory()` returns the factory address above. NPM has code.
- **QuoterV2 DOES exist on Arbitrum One** at `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`
  (8,273 bytes of code, verified live 20 Nov). CORRECTION 20 Nov ~18:00 WAT: the
  address cited in the first draft of this spec
  (`0x61fFE014bA17989E743c5F6cB21bF969a070F44e`) was TRUNCATED (38 hex chars,
  not 40) and naturally returned empty code — that "no code" reading was an
  artifact of the bad address, not a fact about the chain. The adapter still
  **must not** call a quoter to price a swap; it computes the expected
  execution price itself from `slot0` + `liquidity` (§2.4), by design, to
  avoid the revert-based quoting pattern. Any doc, test or frontend line
  that cites the truncated QuoterV2 address is wrong.
  (The SwapRouter02 address was not verified in this pass — the adapter
  does not route through it, so it is out of scope for this spec.)

### 2.2 Adapter design — guard the swap, guard the position

`UniswapV3Adapter.sol` (new file in `contracts/src/`). Immutable
references: `ArbGuard`, `IUniswapV3Factory`, `INonfungiblePositionManager`.
No custody: tokens flow user → pool and pool → user; the adapter never
holds a balance between calls.

**Guarded functions:**
- `swap(pool, tokenIn, amountIn, sqrtPriceLimitX96, recipient)` —
  a swap through a real V3 pool. `recipient` must be `msg.sender`.
  The adapter (a) resolves the pool's TWAP and Chainlink references
  through the guard's existing oracle machinery (§2.3), (b) computes
  the expected execution price from `slot0` + `liquidity` (§2.4),
  (c) calls `ArbGuard.check()` with a `SWAP` action, then (d) calls
  `pool.swap(...)` with the user as recipient.
- `decreaseLiquidity(tokenId, liquidity, amount0Min, amount1Min)` and
  `collect(tokenId, ...)` — liquidity removal through the NPM. Treated
  as a `WITHDRAW`: `amountOut` is the USD value removed, `tvl` is the
  position's total USD value (read from `NPM.positions(tokenId)` +
  the pool's current price), so the single-share rule bounds one
  removal to a share of that position. `recipient` must be `msg.sender`.

**What the adapter passes to `check()` for a swap:**

| `Action` field | Value for the V3 adapter |
|---|---|
| `kind` | `SWAP` |
| `token` | tokenOut |
| `tokenIn` | tokenIn |
| `amountOut` | expected tokenOut, **USD 1e18** (§1.5 convention, via AaveOracle or Chainlink — see §2.4 note) |
| `amountIn` | amountIn, USD 1e18 |
| `price` | expected execution price, **raw token units, 1e18-scaled** (Phase 1 convention — the price rule needs raw units) |
| `tvl` | pool's available tokenOut reserve, USD 1e18 (§2.5) |
| `healthFactorAfter` | 0 (not applicable) |
| `availableLiquidity` | pool's available tokenOut reserve, USD 1e18 (§2.5) |

**The split-unit note (read this).** For a swap, `price` stays in raw
token units because the Phase 1 price-deviation rule compares it against
a raw TWAP reference — changing that would break the rule. But
`amountOut`/`amountIn`/`tvl`/`availableLiquidity` are USD 1e18, because
the outflow, single-share and drain rules need comparable units across
pairs. The adapter owns this split and the unit tests must pin it: a
test that passes a raw-unit `amountOut` to a USD policy must fail, and
a test that passes a USD `price` must fail the price comparison. This
is the most error-prone seam in Phase 2 and the spec calls it out
explicitly rather than burying it.

**Oracle wiring (reuses Phase 1, nothing new in the guard).** The
adapter's policy registers, per token, an `OracleConfig` with the
Chainlink feed (Phase 1 §1.1: ETH/USD `0x639F…`, USDC/USD `0x5083…`,
both re-read fresh 20 Nov 2026, §2.1 note) **and** the real V3 pool as
`uniswapPool` (the 0.05% pool `0xC696…` for WETH/USDC). The guard's
existing resolution (§1.3 of the Phase 1 spec) then does the work:
Chainlink primary, TWAP cross-check, disagreement fails closed, TWAP
fallback. The adapter adds no oracle code of its own — it only
*configures* the guard's oracles with the real pool. That is the point
of Phase 2 for Uniswap: Phase 1 built the TWAP cross-check against a
mock pool in tests; Phase 2 wires it to the real pool and proves it on
a fork.

### 2.3 Pool resolution — from the factory, never hard-coded

The adapter never hard-codes a pool address. For a swap it resolves
the pool as `factory.getPool(tokenIn, tokenOut, fee)` where `fee` is a
parameter the caller passes (500, 3000 or 10000). If the factory returns
`address(0)` (no pool for that fee tier), the adapter reverts
`AdapterError("no pool for fee tier")` before calling `check()` — a
missing pool is a configuration error, not a silent skip.

The `OracleConfig.uniswapPool` registered for the policy must be the
same pool the adapter resolves for that pair/fee. The deploy script
registers the 0.05% pool for WETH/USDC (the canonical, deepest pool);
a policy that wants the 0.3% pool registers a separate policy (or a
separate adapter deployment) with that pool. One policy, one pool per
pair — the spec does not allow a policy to list two pools for the same
pair and pick at runtime, because the TWAP reference would then be
ambiguous and the mirror tests could not pin which pool supplied it.

### 2.4 Execution-price computation (no quoter)

The adapter computes the expected execution price itself, from the
pool's live state, using the same constant-product math the pool
uses — by design, to avoid the revert-based quoting pattern (QuoterV2
does exist on Arbitrum One at `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`,
see the corrected note in §2.1). For a swap of `amountIn` of tokenIn:

1. Read `slot0` → `sqrtPriceX96`, `tick`. Read `liquidity`.
2. Compute the expected `amountOut` from the V3 swap math over the
   current tick's liquidity (single-tick approximation: the adapter
   assumes the swap does not cross a tick boundary; if it would — i.e.
   the computed price moves the tick beyond the current tick's range —
   the adapter uses the multi-tick walk, or reverts `AdapterError`
   ("swap crosses tick") and leaves the multi-tick case to a later
   phase — see §6 Q7). The implementation must state which it does;
   the fork test pins it.
3. `price = amountOut * 1e18 / amountIn` (raw token units, Phase 1
   convention), passed as `Action.price`.

The fork test asserts the adapter's computed `amountOut` matches the
pool's actual output within 0.5% for swaps up to the policy's
`maxPriceDeviationBps` boundary (§5.2). If the approximation drifts
beyond that, the price rule would compare a wrong execution price
against the TWAP and either false-positive (blocking legitimate swaps)
or false-negative (letting a pushed swap through) — so the 0.5%
bound is a correctness requirement, not a nice-to-have.

**USD conversion for the swap's `amountOut`/`amountIn`.** The adapter
converts the expected token amounts to USD with the same source it
uses for the Aave adapter (AaveOracle), so the two adapters share one
USD convention. The fork test asserts the AaveOracle USD value of the
swap is within 1% of the Chainlink-implied USD value at test time.

### 2.5 Concentrated-liquidity positions (NPM)

"Watching concentrated-liquidity positions" means the adapter reads the
position before acting on it, and the guard bounds what one action can
take from it:

- `decreaseLiquidity` / `collect`: the adapter reads
  `NPM.positions(tokenId)` → `(tickLower, tickUpper, liquidity, ...)`,
  computes the position's current USD value from the pool's `slot0`
  price and the position's liquidity (a position entirely out of range
  is worth its single-token residue — the adapter must handle that case
  and the unit test must cover it), and passes that value as `tvl`.
  The single-share rule then bounds one removal to
  `maxSingleShareBps` of the position's value.
- The adapter verifies the position's owner is `msg.sender` (via
  `NPM.ownerOf(tokenId)`) before forwarding — otherwise one user could
  decrease another user's position through the adapter.
- The adapter does **not** mint positions (`mint` is an inflow — adding
  liquidity can only deepen the pool) and does not need to guard it,
  but it exposes an unguarded pass-through `mint` wrapper for flow
  completeness, marked as intentionally unguarded like Aave `supply`
  (§1.2).

**What the adapter does not do (scope honesty).** It does not track a
position's impermanent loss, does not rebalance ranges, and does not
enforce anything about *where* a position's ticks sit. A position
concentrated in a range the price has left is worth less — the adapter
reads its *current* value, not its *deposited* value, so the share rule
is computed on what is actually there. Range placement itself is the
liquidity provider's decision, not a guardable invariant in this phase.

### 2.6 Uniswap V3 adapter interface

```solidity
/// @notice Pass-through guard for Uniswap V3 swaps and NPM positions.
/// Holds no funds. Tokens and NFTs belong to msg.sender throughout.
interface IUniswapV3Adapter {
    function swap(address pool, address tokenIn, uint256 amountIn, uint160 sqrtPriceLimitX96)
        external returns (uint256 amountOut);
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external;
    function collect(uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)
        external;
    function mintPosition(...) external; // unguarded pass-through, §2.5
    function resolvePool(address tokenA, address tokenB, uint24 fee)
        external view returns (address pool);
    function getExpectedOutput(address pool, address tokenIn, uint256 amountIn)
        external view returns (uint256 amountOut, uint256 price1e18);
    function getPositionValue(uint256 tokenId) external view returns (uint256 valueUsd1e18);
}

error AdapterError(string reason);
error AdapterNotConfigured(address pool); // pool not in the adapter's allowlist
```

Notes:
- `swap` resolves the pool from the factory when the caller passes
  `address(0)` as `pool`, or uses the passed pool after verifying
  `factory.getPool(token0, token1, fee) == pool` (a caller-supplied pool
  that the factory does not recognise is rejected — the adapter never
  trusts a caller-supplied pool address on its own).
- The adapter's policy is registered by the owner for the adapter's
  address, with `usdDenominated == true` and the real pool in the
  `OracleConfig` (§2.2).
- `getExpectedOutput` is the exact function `swap` uses internally,
  exposed as a view so the frontend simulator and the fork tests can
  call it directly and compare it against the pool's actual output
  (within 0.5%, §2.4).

## 3. Consolidated interface (Phase 2)

### 3.1 Struct deltas

```solidity
struct Policy {
    uint256 maxOutflowPerBlock;
    uint256 maxOutflowPerHour;
    uint256 maxOutflowPerDay;
    uint16 maxSingleShareBps;
    uint16 maxPriceDeviationBps;
    uint16 throttleBps;
    uint32 cooldownSeconds;
    uint32 policyTimelockSeconds;
    bool enabled;
    bool usdDenominated;        // NEW: true = amountOut/tvl/availableLiquidity are USD 1e18
    uint16 minHealthFactorBps;  // NEW: 0 = rule off; else 10000..50000 (1.0x..5.0x)
    uint16 maxReserveDrainBps;  // NEW: 0 = rule off; else 1..10000
}

struct Action {
    ActionKind kind;
    address token;
    address tokenIn;
    uint256 amountOut;
    uint256 amountIn;
    uint256 price;
    uint256 tvl;
    uint256 healthFactorAfter;  // NEW: projected post-action HF, 1e18; 0 = not provided
    uint256 availableLiquidity; // NEW: reserve/pool available before the action, same units as amountOut
}

enum Reason {
    NONE,
    OUTFLOW_PER_BLOCK,
    OUTFLOW_PER_HOUR,
    OUTFLOW_PER_DAY,
    SINGLE_SHARE,
    PRICE_DEVIATION,
    BREAKER_TRIPPED,
    ORACLE_STALE,       // reserved (Phase 1 note)
    ORACLE_DISAGREEMENT,
    ORACLE_UNAVAILABLE,
    SEQUENCER_DOWN,
    HEALTH_FACTOR,      // NEW (§1.3)
    RESERVE_DRAIN       // NEW (§1.4)
}
// Mode, OracleConfig, PriceConfig, PendingUpdate unchanged.
```

Validation additions in `_validatePolicy`:
- `minHealthFactorBps` is 0 or in [10000, 50000]; otherwise
  `InvalidPolicy("minHealthFactorBps out of range")`.
- `maxReserveDrainBps` is 0 or in [1, 10000]; otherwise
  `InvalidPolicy("maxReserveDrainBps out of range")`.
- `usdDenominated` is a plain bool, no validation — but the adapter
  registration helper (in the deploy script / adapter, not in the
  guard) must revert if an adapter policy is registered with
  `usdDenominated == false`, and the fork test asserts that.
- The new fields are part of the timelocked policy update (§2.1 of the
  Phase 1 spec): changing `minHealthFactorBps` or `maxReserveDrainBps`
  is a limit change and goes through propose/execute like any other cap.
  Lowering `minHealthFactorBps` is loosening, so it is timelocked; there
  is no "tighten immediately" carve-out in this phase (see §6 Q8).

### 3.2 New / changed functions

| Function | Access | Notes |
|---|---|---|
| `registerPolicy(protocol, Policy, PriceConfig)` | owner | Validates the two new fields (§3.1). |
| `proposePolicyUpdate` / `executePolicyUpdate` / `cancelPolicyUpdate` | owner | Unchanged shape; the pending struct now carries the new fields. |
| `check(protocol, Action)` | protocol only | New order (§3.4): health-factor and reserve-drain rules added after single-share, before price. |
| `simulateCheck(protocol, Action)` | view | Mirrors `check()` exactly, including the two new rules. |
| `AaveAdapter.borrow / withdraw` (+ unguarded `supply` / `repay`) | anyone (user) | §1.2, §1.6. |
| `AaveAdapter.getProjectedHealthFactor / getAvailableLiquidity / getUsdValue` | view | §1.6. |
| `UniswapV3Adapter.swap / decreaseLiquidity / collect` (+ unguarded `mintPosition`) | anyone (user) | §2.2, §2.6. |
| `UniswapV3Adapter.resolvePool / getExpectedOutput / getPositionValue` | view | §2.6. |

No new ArbGuard events. `CheckPassed` is emitted by `check()` for
adapter actions exactly as for demo actions — the adapter's passing
calls are visible in the event feed the same way. No new ArbGuard
errors: the two new rules surface as `ArbGuardViolation(HEALTH_FACTOR)`
and `ArbGuardViolation(RESERVE_DRAIN)`. The adapters have their own
errors (`AdapterError`, `AdapterNotConfigured`, §1.6/§2.6).

### 3.3 Updated `check()` order (normative)

```
1. caller == protocol, else NotProtocol
2. policy exists, else UnknownPolicy
3. sequencer check (SWAP only), else SEQUENCER_DOWN
4. !enabled or paused → BREAKER_TRIPPED
5. outflow windows (effective caps after throttle scaling):
   block → OUTFLOW_PER_BLOCK; hour → OUTFLOW_PER_HOUR; day → OUTFLOW_PER_DAY
6. single share → SINGLE_SHARE
7. health factor (BORROW/WITHDRAW only, when minHealthFactorBps > 0):
   healthFactorAfter < minHealthFactorBps * 1e14  →  HEALTH_FACTOR
   (minHealthFactorBps is in bps where 10000 = 1.0x, so the 1e18-scaled
   floor is minHealthFactorBps * 1e14)
8. reserve drain (BORROW/WITHDRAW/SWAP, when maxReserveDrainBps > 0):
   amountOut * 10_000 > availableLiquidity * maxReserveDrainBps  →  RESERVE_DRAIN
9. swaps only: resolve reference (§1.3 Phase 1) → compare → PRICE_DEVIATION
   (or ORACLE_DISAGREEMENT / ORACLE_UNAVAILABLE / SEQUENCER_DOWN)
10. emit CheckPassed
```

`simulateCheck` runs the identical sequence as a view and returns
`(false, reason)` at the first failing step, `(true, NONE)` if all pass.
The health-factor and drain rules read only the `Action` fields and the
`Policy` — they make no external calls inside the guard, so
`simulateCheck` stays a pure view over stored state plus the oracle
reads the price rule already makes. (The adapter's projection math lives
in the adapter, not in the guard; the guard trusts the projected
`healthFactorAfter` the adapter passes, exactly as it trusts the
`amountOut` the caller passes. The fork test is what proves the
projection is honest — see §5.2. This trust boundary is stated here
deliberately: the guard enforces declared numbers; the adapter is
responsible for computing them truthfully.)

**Rule-applicability note.** The health-factor rule fires only when
`minHealthFactorBps > 0` **and** `kind` is `BORROW` or `WITHDRAW`; for
other kinds `healthFactorAfter` is ignored (the adapter passes 0). The
drain rule fires only when `maxReserveDrainBps > 0` **and** `kind` is
`BORROW`, `WITHDRAW` or `SWAP`. A policy with both new fields at 0
behaves exactly like a Phase 1 policy — which is why all 159 Phase 1
tests must still pass unchanged (§5.4): their policies set both fields
to 0 and their actions pass 0 for both new fields.

## 4. Migration (Phase 1 → Phase 2)

This is a **breaking change to the `Policy` and `Action` structs**
(two new fields each), but **not** a breaking change to any deployed
contract: Phase 1 contracts are not upgradeable, so Phase 2 deploys as
a new `ArbGuard` (same name, new deployment) plus the two new adapter
contracts. The Sepolia Phase 1 deployment
(`0x9D733954…`, `SEPOLIA-DEPLOYMENT.md`) stays live as the Phase 1 demo;
it is not upgraded or replaced in this phase.

What changes where:
- `ArbGuard.sol`: `Policy` + `Action` structs (§3.1), `_validatePolicy`
  additions, two new branches in `_evaluateInvariants` (§3.3 steps 7–8),
  two new `Reason` variants. `_simulateInvariants` picks both up
  automatically (shared `_evaluateInvariants`) — the implementation
  must verify that is still true and the mirror tests pin it.
- `GuardedVault.sol` / `GuardedPool.sol`: add the two new `Action`
  fields (`healthFactorAfter: 0`, `availableLiquidity: 0`) to their
  `Action` literals. No behaviour change — their policies set both new
  policy fields to 0, so the new rules are off for the demos.
- `Attacker.sol`: unchanged (it attacks the demo vault/pool; the new
  rules are off there).
- New files: `contracts/src/AaveAdapter.sol`,
  `contracts/src/UniswapV3Adapter.sol` (§1.6, §2.6).
- `contracts/script/DeploySepolia.s.sol`: unchanged in this phase (the
  adapters are not deployed to Sepolia until §6 Q1 is answered).
  A new `DeployAdapters.s.sol` (Arbitrum One fork / Sepolia, when
  decided) registers the adapter policies with `usdDenominated == true`,
  the real pool in the V3 `OracleConfig`, and the demo defaults
  (`minHealthFactorBps` 12500, `maxReserveDrainBps` 5000).
- `apps/web`: the policy form gains the two new fields (health-factor
  floor, reserve-drain cap) plus a USD-denominated toggle that is forced
  on for adapter policies; the attack simulator gains Aave borrow and
  V3 swap scenarios that call the adapters on the fork; the live feed
  shows the new revert reasons (`HEALTH_FACTOR`, `RESERVE_DRAIN`) from
  receipts. The simulator's `simulateCheck` usage is unchanged in shape.
- `docs/ARCHITECTURE.md`: update the invariant model (five checks → seven),
  the trust assumptions (adapter trust boundary, §3.3 note; AaveOracle
  trust, §1.5), and close the "real TWAP source" open question for the
  V3 pool (the real pool is now wired, §2.2). Add the adapter pattern to
  the system overview diagram.
- `docs/INTEGRATION.md`: new section for adapter integration (how a
  protocol or user routes through an adapter; the opt-in nature of the
  firewall; the USD convention).
- `docs/DEPLOY-CHECKLIST.md`: new adapter addresses (when deployed),
  adapter policy values, the verified address inventory (§1.1, §2.1).

## 5. Test plan

### 5.1 Unit tests (new files; mocks in `test/`, never `src/`)

- `HealthFactor.t.sol` — projection math: borrow pushes HF below the
  floor → `HEALTH_FACTOR`; exactly at the floor (1.25×) passes; above
  passes; debt-after-zero → infinite HF passes; collateral-after-zero
  with debt → HF 0 → reverts; rule off (`minHealthFactorBps == 0`) →
  never fires even with a terrible HF; `minHealthFactorBps` below 10000
  reverts at registration; `WITHDRAW` of collateral that pushes HF below
  the floor reverts; `SWAP` ignores `healthFactorAfter` (rule does not
  apply to swaps); `simulateCheck` mirror for every case.
- `ReserveDrain.t.sol` — borrow taking 49% of available passes, 51%
  reverts `RESERVE_DRAIN` (with `maxReserveDrainBps` 5000); rule off
  (`maxReserveDrainBps == 0`) → never fires; drain rule applies to
  `SWAP` as well as `BORROW`/`WITHDRAW`; empty reserve + positive amount
  reverts; empty reserve + zero amount passes; `maxReserveDrainBps`
  above 10000 reverts at registration; mirror tests.
- `AdapterUnits.t.sol` — the split-unit seam (§2.2 note): a USD policy
  with a raw-unit `amountOut` is caught by the fork test's magnitude
  check (amounts differ by ~1e12); a USD `price` fails the price
  comparison; `usdDenominated == false` on an adapter policy reverts
  at registration (helper-level); demo policies keep raw units and
  still pass.
- `AaveAdapter.t.sol` (mock Aave) — mocks in `test/`: `MockAavePool`
  (scriptable `getUserAccountData`, `getReserveData`, `borrow`,
  `withdraw`, `supply`, `repay`), `MockPoolDataProvider`,
  `MockAaveOracle` (scriptable prices). Tests: borrow forwards to the
  pool with debt booked to the user (not the adapter); `onBehalfOf !=
  msg.sender` reverts `AdapterError`; stable-borrow mode reverts;
  non-allowlisted asset reverts `AdapterNotConfigured`; supply/repay
  do not touch the outflow windows (assert window values unchanged);
  projected HF matches the mock's post-action HF exactly (the mock
  computes it the same way Aave does); `getAvailableLiquidity` equals
  `totalAToken - totalDebt` from the mock.
- `UniswapV3Adapter.t.sol` (mock V3) — mocks: `MockV3Pool` (scriptable
  `slot0`, `liquidity`, `observe`, `swap`), `MockFactory`,
  `MockNPM` (scriptable `positions`, `ownerOf`). Tests: pool resolution
  from the factory; `address(0)` pool for an unknown fee tier reverts;
  caller-supplied pool not recognised by the factory reverts;
  `getExpectedOutput` matches the mock's swap output within 0.5%;
  `decreaseLiquidity` for a position not owned by the caller reverts;
  position value uses the *current* price (out-of-range position worth
  its residue, not its deposit); `collect` forwards to the caller.
- `Mirror.t.sol` (extend) — the table-driven lock-step test gains rows
  for `HEALTH_FACTOR` and `RESERVE_DRAIN`: for every rule in §3.3,
  `check()` reverts with reason R **iff** `simulateCheck()` returns
  `(false, R)`.

### 5.2 Fork tests (Arbitrum One, `https://arb1.arbitrum.io/rpc`)

Fork tests run against the **real** Aave V3 Pool and the **real** Uniswap
V3 pools. Public RPC, forge-cached; no key needed. The fork block must
be pinned (record the block number in the test file) so the reserve
numbers are reproducible — the spec's live-state numbers (§1.1, §2.1)
are from 20 Nov 2026 and will drift; the tests assert *relationships*
(boundaries, ratios, agreement within a tolerance), not the exact
20 Nov values, except where a boundary is defined by a live number
(the USDC ~10,174 available is asserted as "within 20% of the recorded
value" with the recorded value in a comment, so a drift fails loudly
rather than silently passing on a different state).

- `AaveFork.t.sol` (new):
  - Setup: fork One; deploy `ArbGuard` + `AaveAdapter` (pointed at the
    real Pool / PoolDataProvider / AaveOracle, §1.1); register the
    adapter policy (`usdDenominated == true`, `minHealthFactorBps`
    12500, `maxReserveDrainBps` 5000, USD outflow caps sized from §1.1:
    per-block $100,000, per-hour $1,000,000, per-day $5,000,000 —
    demo numbers, tuned so a single whale borrow is the binding
    constraint, not the caps).
  - Funding: `deal` WETH to a test user; user supplies WETH via the
    adapter (assert supply passes and does not touch the outflow
    window).
  - **Health-factor boundary (WETH borrow).** Supply 100 WETH. Borrow
    67 WETH → passes (projected HF ≈ 1.254). Borrow 68 WETH → reverts
    `HEALTH_FACTOR` (projected HF ≈ 1.236). Assert the adapter's
    projected HF equals Aave's actual post-action HF (read via
    `Pool.getUserAccountData` after a passing borrow) within 1%.
    (Numbers from the §1.3 worked example; the test recomputes them
    from live prices, it does not hard-code $1,671.59.)
  - **Reserve-drain boundary (USDC borrow).** Supply WETH as collateral.
    Borrow 5,000 USDC → passes (~49% of the ~10,174 available).
    Borrow 5,100 USDC → reverts `RESERVE_DRAIN` (~50.1%). Assert the
    adapter's available-liquidity read equals
    `IERC20(USDC).balanceOf(pool)` (both numbers printed on failure).
  - **Outflow cap (USD).** A borrow within the HF and drain rules but
    above the per-block USD cap reverts `OUTFLOW_PER_BLOCK` — proving
    the Phase 1 windows still bind on adapter actions, in USD.
  - **Collateral withdrawal.** Withdraw WETH collateral that pushes HF
    below 1.25 → reverts `HEALTH_FACTOR`; a smaller withdrawal passes.
  - **AaveOracle vs Chainlink.** Assert AaveOracle WETH and USDC prices
    are within 1% of the raw Chainlink feeds (§2.1 note) at test time.
  - **Provider quirk.** Call both `Pool.getUserAccountData` and
    `PoolDataProvider.getUserAccountData` for the same user and assert
    they agree (or record which one the adapter must use — §1.1 note).
    If the Provider variant reverts under Foundry as it did on the
    direct call, the test documents that and the adapter uses the
    Pool's version.
  - **LTV confirmation.** Read `getReserveConfigurationData` for USDC
    and assert the LTV value; if it reads 0 (§1.1 note), the test
    records that USDC is borrow-only collateral and the adapter's
    projection uses the live value.
- `UniswapV3Fork.t.sol` (new; or extend `ArbitrumOneFork.t.sol`):
  - Setup: fork One; deploy `ArbGuard` + `UniswapV3Adapter`; register
    the adapter policy with the real 0.05% pool in the `OracleConfig`
    (Chainlink ETH/USD + USDC/USD + pool `0xC696…`), USD outflow caps
    (per-block $50,000, per-hour $500,000, per-day $2,000,000 — demo
    numbers).
  - **Normal swap passes.** A small WETH→USDC swap through the adapter
    passes all rules; assert the adapter's computed `amountOut` matches
    the pool's actual output within 0.5%.
  - **Price-push reverts.** A large swap that pushes the execution price
    5% from the TWAP reverts `PRICE_DEVIATION` while the oracles stay
    fresh (the Phase 1 One-fork test shape, now through the real
    adapter instead of the demo pool).
  - **TWAP cross-check on the real pool.** Assert the guard's reference
    price (via `getReferencePrice`) matches a direct `observe()` call
    on `0xC696…` and the Chainlink ratio within 200 bps — the Phase 1
    assertion, re-proven through the adapter's wiring.
  - **Drain rule on a swap.** A swap that would take more than 50% of
    the pool's available tokenOut reverts `RESERVE_DRAIN`.
  - **Position removal.** Mint a real NPM position on the fork (funded
    with `deal`), then `decreaseLiquidity` for more than
    `maxSingleShareBps` of the position's value → reverts
    `SINGLE_SHARE`; a smaller removal passes. Assert the position value
    is computed from the *current* price.
  - **No-quoter note.** The test asserts the adapter never calls a
    quoter — the adapter computes the execution price in-adapter by
    design (QuoterV2 does exist on Arbitrum One at the corrected
    address in §2.1; the "non-existent" claim in the first draft was
    based on a truncated address and is corrected there).
    has no quoter call, but the test file carries a comment citing §2.1
    so a future edit does not reintroduce it.
- `SepoliaFork.t.sol` (extend, existing): the Sepolia stale-feed test
  still passes (real stale ETH/USD → `ORACLE_UNAVAILABLE`). The
  adapters are **not** fork-tested on Sepolia in this phase (§6 Q1).

### 5.3 Gas benchmarks

- `Gas.t.sol` (extend): add adapter cases and record the numbers.
  - Aave `borrow` check (HF projection + drain + outflow, no swap):
    **target ≤ 150k gas** for the `check()` portion (excluding the
    Pool call itself).
  - Aave `withdraw` check: **target ≤ 150k gas**.
  - V3 `swap` check (Chainlink + TWAP + drain): **target ≤ 180k gas**
    for the `check()` portion (excluding the pool swap itself).
  - V3 `decreaseLiquidity` check: **target ≤ 150k gas**.
  - The Phase 1 targets are unchanged: swap-with-both-oracles stays
    under the 120k target *as a reported number* — its current 126,848
    is a known miss, not re-baselined. If a Phase 2 change moves any
    Phase 1 gas number by more than 5%, the test output must say so.
  - If a Phase 2 target is missed, the implementation reports it — the
    target is not silently dropped (Phase 1 §5.3 rule, carried over).

### 5.4 Regression + size gate (normative)

- **All 159 currently passing Phase 1 tests must still pass.**
  `forge test` must report 159+ passing and the only failures must be
  the 2 known Phase 1 gas-target failures (or fewer, if Phase 2 work
  happens to bring them under target — a fix is welcome, a new failure
  is not). Any other failure blocks the phase.
- **Contract size:** `forge build --sizes` must show `ArbGuard` ≤ 24,576
  bytes (currently 22,275; budget 2,301 for the new rules) and each
  adapter ≤ 24,576 bytes. If `ArbGuard` exceeds the limit, slim by
  deduplication (Phase 1 pattern), never by dropping a rule.
- **No new external dependencies** beyond what Phase 1 already uses
  (OpenZeppelin, Uniswap V3 core interfaces, Foundry). The Aave
  interfaces (`IPool`, `IPoolDataProvider`, `IAaveOracle`) are defined
  locally in the adapter files (minimal interfaces, only the functions
  used) — the spec does not add the full Aave V3 repo as a dependency.

## 6. Open questions (flagged, not guessed)

1. **Adapters on Arbitrum Sepolia?** Aave V3 and Uniswap V3 deployments
   on Arbitrum Sepolia were not verified in this pass. If they do not
   exist there, the Sepolia demo keeps the mock vault/pool path and the
   adapters are One-fork-only until a Sepolia deployment is confirmed.
   Verify by reading the Aave and Uniswap deployment addresses for
   chain 421614 before any Sepolia adapter deployment is attempted.
2. **One policy per adapter, or one policy per reserve/pool?** Spec:
   one policy per adapter, USD-normalised (§1.2). Alternative: one
   policy per (adapter, reserve) — needs either one adapter contract
   per reserve or a policy-per-token concept in the guard. Confirm the
   one-policy choice; if a protocol wants per-reserve caps, it deploys
   one adapter per reserve.
3. **AaveOracle vs Chainlink in the hot path.** Spec: AaveOracle only,
   cross-checked in the fork test (§1.5). Alternative: cross-check
   AaveOracle against Chainlink on every adapter call (extra ~14k gas
   per borrow). Confirm the fork-test-only cross-check is acceptable.
4. **Health-factor floor default.** Spec: 12500 (1.25×). Confirm;
   15000 (1.5×) is the more conservative alternative.
5. **USDC LTV reads 0.** `getReserveConfigurationData` for native USDC
   returns LTV 0 (§1.1). Confirm whether that is the live market state
   (USDC borrow-only) or an ABI field-order quirk in the read. The fork
   test decides; the adapter must use the live value either way.
6. **PoolDataProvider.getUserAccountData reverted on direct call**
   (§1.1). Confirm under Foundry whether it works; the adapter uses
   the Pool's version until then.
7. **Multi-tick swaps in the V3 adapter.** Spec: the adapter computes
   the execution price from the current tick's liquidity and either
   walks multiple ticks or reverts `AdapterError` for a swap that would
   cross a tick (§2.4). The implementation must pick one and the fork
   test must pin it. Walking is more correct; reverting is simpler and
   fail-closed.
8. **Tightening the health-factor floor immediately?** Spec: changing
   `minHealthFactorBps` is timelocked like any cap change, including
   raising it (tightening). Alternative: allow immediate *tightening*
   (raising the floor) and timelock only loosening — the fail-closed
   direction should arguably be free. Confirm; the timelocked default
   is the conservative choice.
9. **Throttle interaction with the health-factor rule.** Spec: throttle
   scales the outflow caps only (Phase 1 §2.3); the health-factor floor
   and drain cap are unchanged in THROTTLED mode. Alternative: throttle
   also raises the HF floor (e.g. 1.25× → 1.5×) and halves the drain
   cap. Confirm the caps-only scope.
10. **Sepolia adapter demo (if Q1 says the deployments exist).** Which
    reserves/pools does the Sepolia demo use, and does the Sepolia Aave
    market have the same near-exhausted USDC state (unlikely — testnet
    markets are usually empty)? If Sepolia state is thin, the Sepolia
    demo cannot show the drain rule live and the One fork test is the
    only proof. Confirm before promising a Sepolia adapter demo.
11. **V3 adapter for the 0.3% / 1% pools.** Spec: one policy, one pool
    per pair (§2.3); the 0.3% pool is a separate policy/adapter. Confirm
    the demo only wires the 0.05% pool, or whether the 0.3% pool gets a
    second adapter deployment in this phase.
12. **Adapter allowlist updates.** Spec: the reserve/pool allowlist is
    set at deployment and immutable. Alternative: owner-managed
    allowlist (add/remove reserve) — but that is a trust surface (the
    owner could add a malicious pool). Confirm immutable.

## Appendix A — Verification log (20 Nov 2026, live reads)

Arbitrum One (`https://arb1.arbitrum.io/rpc`). All reads by direct
`cast call` / `cast code`; no address below was copied from a docs page
without an on-chain read.

**Aave V3:**
- `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` (PoolAddressesProvider):
  code present; `getPool()` → `0x794a61358D6845594F94dc1DB02A252b5b4814aD`;
  `getPriceOracle()` → `0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7`;
  `getPoolDataProvider()` → `0x243Aa95cAC2a25651eda86e80bEe66114413c43b`;
  `getACLManager()` → `0xa72636CbcAa8F5FF95B2cc47F3CDEe83F3294a0B`;
  `getMarketId()` → `"Arbitrum Aave Market"`.
- `0x794a61358D6845594F94dc1DB02A252b5b4814aD` (Pool):
  `getReservesList()` → 20 reserves including WETH `0x82aF…Bab1` and
  native USDC `0xaf88…5831`; `getUserAccountData(0x…0001)` →
  (0, 0, 0, 0, 0, type(uint256).max); `getReserveNormalizedIncome(WETH)`
  → 1069120763676681050998365952.
- `0x243Aa95cAC2a25651eda86e80bEe66114413c43b` (PoolDataProvider):
  code present; `getReserveTokensAddresses(WETH)` → aToken
  `0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8`, stable debt
  `address(0)`, variable debt
  `0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351`;
  `getReserveTokensAddresses(USDC)` → aToken
  `0x724dc807b04555b71ed48a6896b6F41593b8C637`, stable debt
  `address(0)`, variable debt
  `0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6`;
  `getReserveData(WETH)` → totalAToken 100792278729636418662272,
  totalVariableDebt 52924014427477885376092, liquidityRate
  7960407331753596571213836, variableBorrowRate
  17835746252704496672916839; `getReserveData(USDC)` → totalAToken
  160893354007280, totalVariableDebt 160883179631627;
  `getReserveConfigurationData(WETH)` → decimals 18, LTV 8100,
  liquidationThreshold 8400, liquidationBonus 10500, reserveFactor 1500,
  usageAsCollateral true, borrowingEnabled true, stableBorrowRateEnabled
  false, isActive true, isFrozen false;
  `getReserveConfigurationData(USDC)` → decimals 6, LTV 0,
  liquidationThreshold 7800, liquidationBonus 10500, reserveFactor 1000,
  usageAsCollateral true, borrowingEnabled true, stableBorrowRateEnabled
  false, isActive true, isFrozen false;
  `getUserAccountData` → **reverted on direct call** (see §1.1 note);
  aWETH `totalSupply()` → 100792278856847795212641;
  aUSDC `totalSupply()` → 160893356650182.
- `0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7` (AaveOracle):
  `getAssetPrice(WETH)` → 167386857155 ($1,673.87 at first read) /
  167158856162 ($1,671.59 at second read);
  `getAssetPrice(USDC)` → 99982444 ($0.99982);
  `getAssetsPrices([WETH, USDC])` → [167158856162, 99982444];
  `BASE_CURRENCY()` → `address(0)`; `BASE_CURRENCY_UNIT()` → 100000000.

**Uniswap V3:**
- `0x1F98431c8aD98523631AE4a59f267346ea31F984` (Factory):
  `getPool(WETH, USDC, 500)` → `0xC6962004f452bE9203591991D15f6b388e09E8D0`;
  `getPool(WETH, USDC, 3000)` → `0xc473e2aEE3441BF9240Be85eb122aBB059A3B57c`;
  `getPool(WETH, USDC, 10000)` → `0x42FC852A750BA93D5bf772ecdc857e87a86403a9`.
- `0xC6962004f452bE9203591991D15f6b388e09E8D0` (WETH/USDC 0.05% pool):
  token0 WETH, token1 USDC, fee 500, liquidity 673102687809095515,
  slot0 tick −202104, observationCardinality 9000, tickSpacing 10,
  `observe([1800, 0])` returns tick cumulatives
  [−21558846802890, −21559210100551].
- `0xc473e2aEE3441BF9240Be85eb122aBB059A3B57c` (WETH/USDC 0.3% pool):
  liquidity 143485514450402005, slot0 tick −202089.
- `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` (NPM): code present;
  `factory()` → `0x1F98431c8aD98523631AE4a59f267346ea31F984`.
- `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` (QuoterV2, correct
  address): **code present, 8,273 bytes.** CORRECTION 20 Nov ~18:00 WAT:
  the first draft cited a truncated address
  (`0x61fFE014bA17989E743c5F6cB21bF969a070F44e`, 38 hex chars) which
  returned empty code; the correct address has code.
- WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`: decimals 18.
  USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`: decimals 6.

**Chainlink (re-read fresh, 20 Nov 2026):**
- `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` ETH/USD:
  answer 167125196115 ($1,671.25), updatedAt 1795188274 (fresh).
- `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` USDC/USD:
  answer 99987295 ($0.99987), updatedAt 1795188194 (fresh).

Sources: Aave V3 docs (PoolAddressesProvider pattern — every address
above was then confirmed by the provider's own getters on-chain);
Uniswap V3 docs (factory / NPM addresses — confirmed by
`getPool` and `factory()` reads); Phase 1 spec §1.1–§1.2 (Chainlink
feeds and the canonical pool, re-read 20 Nov 2026).
