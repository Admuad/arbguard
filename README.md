# ArbGuard

**The on-chain circuit breaker for Arbitrum: it reverts the exploit transaction before the money moves.**

DeFi lost ~$1.8B to exploits in 2025, and almost every loss followed the same shape: one transaction (or a short burst) moved far more value, or at a far worse price, than the protocol's normal operation ever should. Existing tools alert *after* the money is gone, or audit code *before* deployment. ArbGuard sits in the middle: a plug-in, on-chain firewall that any Arbitrum protocol bolts onto its sensitive functions in ~10 lines. Before the sensitive action executes, the protocol calls `ArbGuard.check(...)`; ArbGuard enforces the protocol's own declared invariants — max net outflow per block, max single-withdrawal share of TVL, price-deviation vs TWAP, reserve-balance conservation — and **reverts the transaction** if any invariant breaks. If an attack is in progress, any keeper (or the protocol owner) can trip the breaker and pause the guarded functions for a cooldown window.

**Enforcement, not detection.** Monitors watch and report. ArbGuard stops the transaction. That is the whole product, and the demo proves it: the same drain attack empties the unguarded vault and reverts on the guarded one.

> **Event status:** ArbGuard is being built for the Arbitrum Open House São Paulo — Online Buildathon 2027 (Feb 8–28, 2027; submission deadline **Feb 28, 2027, 11:59 PM BRT**; $115,000 prize pool). The Dec 2026 Dubai run is unpublished — no official source confirms it — so São Paulo is the submission target. ArbGuard has standalone value as a sellable security tool regardless of the event.

## How it works

```
  Protocol's sensitive function            ArbGuard.sol
  ┌─────────────────────────┐      ┌──────────────────────────┐
  │ withdraw() / swap()     │      │ registerPolicy()         │
  │   │                     │      │ check() ──► revert on    │
  │   ├─► arbGuard.check()─┼─────►│   violation              │
  │   │   (BEFORE any state │      │ trip() / reset()         │
  │   │    change)          │      │ PolicyRegistered /       │
  │   └─► burn, transfer    │      │ CheckPassed /            │
  │       (only if check    │      │ BreakerTripped /         │
  │        passed)          │      │ BreakerReset             │
  └─────────────────────────┘      └──────────┬───────────────┘
                                              │ cross-contract call
                                              ▼
                                   ┌──────────────────────────┐
                                   │ ArbGuardChecker         │
                                   │ (Stylus / Rust —         │
                                   │  gas-optimised pure      │
                                   │  invariant math;         │
                                   │  roadmap, not wired      │
                                   │  in v1 — see below)      │
                                   └──────────────────────────┘
```

The three enforced invariants (`docs/ARCHITECTURE.md`):

1. **Max outflow per block** — cumulative net outflow in the current block must stay under the policy cap. This is what stops a looped drain.
2. **Max single-withdrawal share of TVL** — one withdrawal cannot exceed `maxSingleShareBps` of TVL.
3. **Price deviation vs TWAP** — a swap's execution price must stay within `maxPriceDeviationBps` of the reference price. Stops flash-loan price-push swaps.

A fourth invariant, **reserve conservation** (recorded reserves reconcile with actual balances after the action), is specified in `docs/ARCHITECTURE.md` (Rule 4) but is **not enforced in v1**: `check()` runs *before* the action, so it cannot verify post-action balances. Enforcing it needs a post-action confirm step and is a v2 item — the README and spec say so plainly rather than claiming four enforced rules.

A keeper or the owner can trip the breaker at any time (`trip()`); guarded functions pause for the policy's cooldown and **auto-resume** — no 3 a.m. multisig scramble. The owner can end the pause early with `reset()`.

## The demo (90 seconds)

Same attack, two vaults — see [`docs/DEMO-SCRIPT.md`](docs/DEMO-SCRIPT.md):

1. **Drain:** `drainVault()` loops `withdraw()` in one tx. Unguarded vault → balance ~0. Guarded vault → tx reverts `ArbGuardViolation(OUTFLOW_PER_BLOCK)`, balance unchanged.
2. **Price push:** a large swap moves the pool price 40%. Unguarded pool → goes through. Guarded pool → reverts `ArbGuardViolation(PRICE_DEVIATION)`.
3. **Integration:** the 10-line diff, the policy dashboard, the Arbiscan links.

Demo video: *TBD — recorded in the final week; link will go here.*

## Repository layout

```
arbguard/
├── README.md
├── LICENSE (MIT)
├── .github/workflows/ci.yml
├── contracts/          # Foundry project — ArbGuard.sol, GuardedVault, GuardedPool, Attacker, tests
├── stylus/             # Rust Stylus checker — check_outflow / check_price_deviation / check_share
├── apps/web/           # Next.js 15 frontend — policy form, attack simulator, live event feed
└── docs/
    ├── ARCHITECTURE.md # spec freeze v0.1 — invariant model, threat model, trust assumptions
    ├── INTEGRATION.md  # the 10-line guide for a protocol dev
    └── DEMO-SCRIPT.md  # the 90-second video script
```

## Deployed addresses

> **TBD — nothing is deployed yet.** No deployment happens in this run (it needs the owner's deployer key + Sepolia faucet ETH). Addresses will be listed here once deployed and verified on Arbiscan, with separate rows for Arbitrum Sepolia (demo) and Arbitrum One (final). **Do not trust any ArbGuard address that is not listed here.**

| Contract | Arbitrum Sepolia | Arbitrum One |
|---|---|---|
| ArbGuard | TBD | TBD |
| GuardedVault | TBD | TBD |
| UnguardedVault | TBD | TBD |
| GuardedPool | TBD | TBD |
| ArbGuardChecker (Stylus) | TBD | TBD |

## Quick start

### Contracts — run the tests

```bash
cd contracts
git submodule update --init --recursive   # first clone only: fetches forge-std + OpenZeppelin
forge test
```

Fork tests run against Arbitrum Sepolia (see `contracts/test/`). **40 tests, all passing** (incl. 7 live Sepolia fork tests).

### Frontend — run the app

```bash
cd apps/web
npm install
npm run dev
```

Open http://localhost:3000. Connect a wallet (RainbowKit) on Arbitrum Sepolia or Arbitrum One.

**WalletConnect project ID:** the frontend reads `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` from the environment. If it is not set, the app falls back to a dummy placeholder ID (`00000000000000000000000000000000`) so that `npm run build` passes without a real key — wallet connection will not work with the dummy ID. For a working wallet connection, create a free project at https://cloud.walletconnect.com, copy `.env.example` to `.env.local`, and set `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` to your real project ID. Never commit `.env.local`.

## Integrate ArbGuard into your protocol (10 lines)

```solidity
import {ArbGuard} from "arbguard/src/ArbGuard.sol";

ArbGuard public immutable arbGuard;

function withdraw(uint256 shares) external nonReentrant {
    uint256 assets = previewRedeem(shares);

    arbGuard.check(address(this), Action({
        kind: ActionKind.WITHDRAW,
        token: address(asset),
        amountOut: assets,
        amountIn: 0,
        price: 0,
        twapPrice: 0
    }));

    _burn(msg.sender, shares);
    asset.transfer(msg.sender, assets);
}
```

Full guide: [`docs/INTEGRATION.md`](docs/INTEGRATION.md).

## Toolchain (pinned)

| Tool | Version |
|---|---|
| Foundry (`forge`) | 1.9.0 |
| Solidity | 0.8.28 |
| Node | 24.x (v24.22.1 verified) |
| npm | 10.9.4 |
| Next.js | 15 (App Router) + TypeScript + Tailwind CSS |
| wagmi / viem | v2 |
| RainbowKit | v2 |
| cargo-stylus / stylus-sdk | **0.10.10 / 0.10.10** (rustc 1.91.0, pinned in `stylus/rust-toolchain.toml`) |

## Honest notes (what ArbGuard does not do)

- **It does not stop slow multi-block drains under the cap.** An attacker who stays under `maxOutflowPerBlock` every block can still bleed a protocol over time. ArbGuard bounds the *rate* of loss, not the total over a long attack.
- **It does not stop governance compromise or a malicious owner.** The owner can rewrite the policy and reset the breaker. ArbGuard enforces the policy the owner set.
- **A reverted tx leaves no persistent event.** A blocked attack has no on-chain `ViolationBlocked` event to subscribe to — the EVM rolls everything back. Blocked attempts are visible in the revert reason + unchanged balances, and in the frontend simulator's failed receipt. See `docs/ARCHITECTURE.md`.
- **The v1 TWAP is a proxy.** The demo pool stores `lastPrice` (updated at most once per block) as the reference price. A production deployment should plug in a real TWAP oracle.
- **Stylus is a gas optimisation, not a load-bearing dependency.** The Solidity invariant math ships first and works standalone; the Stylus checker swaps in when it is deployed and passing. **Status: blocked by the chain, not by the code** — Arbitrum paused all new Stylus contract activations on 2 Oct 2026 (activation gas set to 2^64 − 1), verified against both Sepolia and One on 9 Nov 2026. The checker is built, tested (20/20), and ABI-exported, and deploys the moment activations resume; until then the Solidity path ships and the submission says so plainly. See `stylus/README.md` for the full blocker note and re-check command. The original Mon 23 Nov deploy gate cannot be met while the pause is in effect.
- **The demo drain loops `withdraw()` in one tx** — plain ERC20 has no recipient callback, so there is no ERC777-style reentrancy hook here. ArbGuard stops the economic shape of the drain, not reentrancy in general (the vaults still use `ReentrancyGuard` for that).

## Contributing / security

- No Shannon code, prompts, or findings corpus in this repo — ArbGuard is new code, inspired by the methodology only.
- No private keys, API keys, or secrets in the repo. RPC keys live in environment variables / the Secure Vault only. A secret scan runs before submission.
- Found a bug in ArbGuard itself? Open an issue — do not exploit the demo deployments.

## Licence

MIT — see [LICENSE](LICENSE). Copyright Muhammed Adediran, 2026.
