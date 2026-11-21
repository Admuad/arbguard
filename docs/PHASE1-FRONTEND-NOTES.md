# ArbGuard Phase 1 — Frontend Notes

What the web app (`apps/web`) needs to know about the Phase 1 contract rewrite.
No frontend code was changed in this phase.

## Breaking changes to the contract interface

- `Action` struct: `twapPrice` is GONE. New field `tokenIn` (address(0) for
  non-swaps). `price` is still the 1e18-scaled execution price (tokenOut per
  tokenIn). The guard now resolves the reference price itself from oracles;
  the frontend must NOT supply a reference price anymore.
- `Policy` struct: `keeper` (single address) is GONE. Keepers are now a
  per-policy set (max 10), managed by `addKeeper` / `removeKeeper` /
  `isKeeper` / `getKeepers`. New fields: `maxOutflowPerHour`,
  `maxOutflowPerDay`, `throttleBps`, `policyTimelockSeconds`.
- `Reason` enum gained: `OUTFLOW_PER_HOUR`, `OUTFLOW_PER_DAY`,
  `ORACLE_STALE` (reserved, never returned by check), `ORACLE_DISAGREEMENT`,
  `ORACLE_UNAVAILABLE`, `SEQUENCER_DOWN`.
- New `Mode` enum: `NORMAL`, `THROTTLED`, `PAUSED`. Read it via `getMode(policyId)`.
  `modeOf(policyId)` is the stored mode; `getMode` applies auto-expiry.
- New structs: `OracleConfig`, `PriceConfig`, `PendingUpdate`,
  `PendingOracleUpdate`.

## New calls the frontend should use

- `simulateCheck(protocol, action)` — unchanged signature, but now also
  returns the oracle reasons above. Use it to preview before sending; it
  mirrors `check()` exactly (same rules, same order, same thresholds).
- `getReferencePrice(policyId, tokenIn, tokenOut)` — returns
  `(price1e18, source)`. `source` is the Chainlink feed or Uniswap pool
  that supplied the price, or `address(0)` when no oracle is configured
  (price rule skipped). Reverts with the same reason `check()` would.
- `getMode(policyId)`, `getPolicy`, `getPriceConfig`, `getOracleConfig`,
  `getPendingUpdate`, `getPendingOracleConfig`, `getKeepers`, `getPolicyId`,
  `getProtocol` — read-only views for the dashboard.

## Behaviour the UI must reflect

- Policy / price / oracle changes are TIMELOCKED (default 24h). The UI must
  show pending updates (`getPendingUpdate`, `getPendingOracleConfig`) with
  their `executableAt`, and only offer Execute after the delay. Disabling a
  policy (`setEnabled(false)`) is immediate; re-enabling is timelocked.
- `trip` / `throttle` are immediate and can be called by any keeper or the
  owner. `reset` / `unthrottle` are owner-only. `reset()` returns to NORMAL
  (not to THROTTLED). A throttled policy cannot be `reset()`; use `unthrottle`.
- Throttle scales the block/hour/day caps by `throttleBps` (default 10%);
  price and share rules are unchanged. The UI should show the effective
  (throttled) caps when mode is THROTTLED.
- A swap whose oracles disagree by more than `maxOracleDeviationBps`
  (default 200 bps) reverts `ORACLE_DISAGREEMENT`; a swap with no usable
  oracle reverts `ORACLE_UNAVAILABLE`. Both surface via `simulateCheck`
  before the user sends the transaction.
- The L2 sequencer being down (or within 1h of restart) reverts
  `SEQUENCER_DOWN` for swaps only. The UI should surface this distinctly
  from a price problem.

## Gas (for the UI's benefit)

- A swap `check()` with both oracles costs ~125k gas warm (measured
  125,433 with mocks; ~226k warm against the real Chainlink feeds and
  pool on an Arbitrum One fork). Both are UNDER the spec's 250k target
  (revised 21 Nov 2026 from 120k after the real-fork measurement).
  Budget ~230k gas for a guarded swap call in the UI's estimates.
  `simulateCheck` for the same swap is ~88.6k (view, no state change).

## Contract size warning

- `ArbGuard` is 25,401 bytes, 825 bytes over the 24,576-byte mainnet
  (EIP-170) limit. It deploys and runs on Anvil, but a real mainnet /
  Sepolia deployment will fail until the contract is slimmed down
  (split, or move a view/admin surface out). Flag for Phase 3.

## What did NOT change

- `GuardedVault` / `GuardedPool` addresses and their user-facing
  functions are unchanged. `Attacker.sol` is unchanged.
- `CheckPassed` is still emitted on success; there is still no
  `ViolationBlocked` event (reverts cannot emit).
- The Sepolia question (mock feed vs ETH-only) is still pending
  Muhammed's decision; the frontend should not assume either.
