# ArbGuard — Solidity core (`contracts/`)

Foundry project. Solidity 0.8.28, optimizer on (200 runs).
OpenZeppelin Contracts **v5.4.0** (pinned tag, see `foundry.lock`);
forge-std from `foundry-rs/forge-std` (floating, see `foundry.lock`).

## Layout

| File | What it is |
|---|---|
| `src/ArbGuard.sol` | Policy registry + enforcement entry point (`check`, `trip`, `reset`, `simulateCheck`) |
| `src/MockERC20.sol` | Mock ERC20 with public mint (tests/demo only) |
| `src/GuardedVault.sol` | Minimal 1:1 vault; `withdraw()` calls the guard first; `address(0)` guard = unguarded |
| `src/UnguardedVault.sol` | Thin subclass of `GuardedVault` with guard `address(0)` — the demo's control, same logic |
| `src/GuardedPool.sol` | Constant-product AMM (x·y=k, no fee); `swap()` guarded by the price-deviation rule |
| `src/Attacker.sol` | Demo/test helper: loop drain + price-push swap |
| `test/` | `ArbGuard.t.sol`, `AttackBlocked.t.sol`, `Breaker.t.sol`, `Invariants.t.sol`, `Fixture.t.sol`, `SepoliaFork.t.sol` (live-Sepolia fork suite) |
| `script/` | `DeploySepolia.s.sol`, `DeployMainnet.s.sol`, `AnvilDemo.s.sol` — deploy scripts dry-run proven on a local Sepolia fork (21/21 txs, see `docs/DEPLOY-CHECKLIST.md`); **never run against a public chain yet** |

## Commands

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build
forge test            # 40 tests, all passing (15 ArbGuard + 9 AttackBlocked + 8 Breaker + 1 invariant test covering 2 invariants + 7 Sepolia fork)
forge fmt
```

Deploy (requires a funded deployer key — do NOT run without Muhammed's go-ahead):

```bash
source .env           # PRIVATE_KEY, optionally KEEPER, ARBISCAN_API_KEY
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
# Mainnet (final week only): same, with script/DeployMainnet.s.sol
# and --rpc-url https://arb1.arbitrum.io/rpc
```

## Design decisions (recorded)

1. **No `ViolationBlocked` event — deliberate.** A reverted tx cannot leave a
   persistent event on-chain (events roll back with the revert), so emitting
   one from `check()` would be unobservable fiction. Blocked attempts surface
   via (a) the `ArbGuardViolation(reason)` revert in the failed receipt and
   (b) the `simulateCheck()` view, which runs the identical invariant logic
   without mutating state so the frontend simulator can preview pass/fail.
   `CheckPassed` is emitted (success path persists, so the event is real).
   Documented at the top of `ArbGuard.sol`.
2. **`Reason.NONE` sentinel.** `simulateCheck` returns `(true, NONE)` on
   success; `NONE` is never used in a revert.
3. **TWAP is a v1 proxy, not an oracle.** `GuardedPool` stores the last
   execution price per direction, refreshed at most once per block. It lags
   by up to a block and is gameable across blocks — a production deployment
   must plug in a real TWAP / Chainlink feed as `twapPrice`. Documented in
   `GuardedPool.sol`.
4. **`Attacker.drainVault` is a loop drain, not reentrancy.** Plain ERC20s
   have no recipient callback and the vault's accounting is correct, so the
   attacker can only withdraw its own shares. The attack is a burst
   withdrawal by a large holder: many small withdrawals in one tx, each under
   the single-share limit, cumulatively over the per-block outflow cap.
   Documented in `Attacker.sol`.
5. **One policy per protocol address.** `check()` only accepts calls from the
   registered protocol (`msg.sender == protocol`). Owner = deployer via
   `Ownable2Step`; keeper may only trip, never change limits.
6. **Invariant math lives in `_checkInvariants()`** inside `ArbGuard.sol`
   (Solidity fallback first, per plan §4). The Stylus checker replaces that
   one function later; `_simulateInvariants()` must stay in lock-step with it.
7. **Checked arithmetic throughout** (Solidity 0.8 default): an overflow in
   the bps multiplications reverts the tx — fail-closed, the safe direction
   for a firewall.
8. **Lint notes:** `forge build` reports `calls-loop` warnings in
   `Attacker.sol` (the loop IS the attack) and `reentrancy-*` warnings in the
   vault/pool (the guard `check` is an external call before state updates —
   mitigated by `nonReentrant` on `deposit`/`withdraw`/`swap`).

## Test policy values (fixture)

- Vault: 100 ether/block outflow, 50% single share, 5% price deviation, 1h cooldown.
- Pool: 10,000 ether/block outflow, 100% single share, 5% price deviation, 1h cooldown.
