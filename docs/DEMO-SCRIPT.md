# ArbGuard — 90-Second Demo Video Script

**Format:** screen recording + voiceover (Muhammed's voice). 2–3 min max
overall; the spine below is 90 seconds. Captions on throughout; if no
voiceover is recorded, captions-only is acceptable — the on-screen text
cues below carry the story on their own.

**Setup before recording:** Arbitrum Sepolia, both vaults funded with the
same mock balances, both pools at the same price. Browser tabs ready:
frontend simulator, Arbiscan pages for the guarded + unguarded vaults.
One continuous take per segment; cut between segments, never mid-attack.

---

## Segment 1 — The problem (0–15s)

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 0–5s | Title card: ArbGuard logo + "The on-chain circuit breaker for Arbitrum" | "DeFi lost $1.8 billion to exploits in 2025." | `DeFi lost ~$1.8B in 2025` |
| 5–10s | Screen: unguarded vault page, balance visible (e.g. 100 mock WETH) | "And almost every loss was the same shape — one transaction that should never have been allowed." | `One transaction. Too much value out. Too fast.` |
| 10–15s | Cursor hovers the vault balance; cut to the two vaults side by side | "Same vault. Same attack. One difference: ArbGuard." | `Unguarded vs Guarded — same attack` |

## Segment 2 — Attack 1: the drain (15–45s)

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 15–25s | Simulator: select **Unguarded vault**, attack **Drain**, click Run | "First, the unguarded vault. The attacker loops withdraw in a single transaction." | `Attack 1: drainVault() — loop withdraw() in one tx` |
| 25–32s | Receipt appears: success. Vault balance animates to ~0 | "It drains. Balance: zero." | `✅ tx succeeded — vault drained` |
| 32–38s | Simulator: select **Guarded vault**, same attack, click Run | "Same attack, same transaction — on the guarded vault." | `Same attack. Guarded vault.` |
| 38–45s | Receipt appears: **reverted**. Revert reason highlighted; balance unchanged | "Reverted. Outflow per block — the transaction never happened, and the balance never moved." | `⛔ REVERTED — ArbGuardViolation(OUTFLOW_PER_BLOCK)` / `Balance unchanged` |

**Key frame (hold 2s):** the reverted receipt next to the unchanged
balance. This is the whole product in one frame. Do not rush past it.

## Segment 3 — Attack 2: the price push (45–70s)

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 45–52s | Simulator: select **Unguarded pool**, attack **Price push**, click Run | "Attack two: a price-push swap. One large swap moves the price forty percent." | `Attack 2: pushPriceAndSwap() — price moves 40%` |
| 52–58s | Receipt: success. Price chart / pool price shows the move | "Unguarded, it goes through. The pool is now mispriced for everyone else." | `✅ tx succeeded — price moved 40%` |
| 58–65s | Simulator: select **Guarded pool**, same attack, click Run | "Guarded, the same swap hits the price-deviation rule." | `Same swap. Guarded pool.` |
| 65–70s | Receipt: **reverted**, reason highlighted; price unchanged | "Reverted. Price deviation. The pool never moved." | `⛔ REVERTED — ArbGuardViolation(PRICE_DEVIATION)` / `Price unchanged` |

## Segment 4 — The integration + links (70–90s)

| Time | Shot | Voiceover | On-screen text |
|---|---|---|---|
| 70–78s | Code editor: the guarded `withdraw()` with the single `check()` call highlighted; the 10-line diff | "And integrating it is ten lines. One check() call, before the sensitive action. That's it." | `10 lines. One check() call.` |
| 78–84s | Frontend policy form: sliders for the four limits; Arbiscan verified-contract links | "Set four limits, deploy a policy, and your protocol reverts the exploit before the money moves." | `Set 4 limits → deploy policy → exploits revert` |
| 84–90s | End card: repo URL, frontend URL, "Invariant firewall in Solidity — Stylus checker on the roadmap" | "ArbGuard. The on-chain circuit breaker for Arbitrum." | `github.com/Admuad/arbguard` / `Solidity firewall — Stylus checker on the roadmap` |

---

## Recording notes

- **One take per attack.** The unguarded drain and the guarded revert must
  be the same attack code against the same starting balances — that is the
  proof. Do not re-record one side with different parameters.
- **Show the receipt, not just the UI.** The Arbiscan receipt (or the
  simulator's receipt panel) with the revert reason visible is the evidence;
  a green/red banner alone is not.
- **Honesty notes for the edit:**
  - Do not claim the live feed shows blocked attacks as on-chain events —
    a reverted tx leaves no persistent event (see `ARCHITECTURE.md`).
    The blocked attack is visible in the receipt + unchanged balance.
  - Do not claim Stylus if the Solidity fallback shipped — say "invariant
    checks in Solidity; Stylus checker on the roadmap" instead.
  - The TWAP reference in the demo pool is a v1 proxy (`lastPrice`,
    updated at most once per block), not a production TWAP — do not call
    it a TWAP in the voiceover.
  - No deployed addresses are final until the Sepolia deployment lands;
    use the real Arbiscan links or none at all — never a placeholder
    address on screen.
- **Assets:** repo URL, frontend URL, Arbiscan links (Sepolia), captions
  file. Upload unlisted to YouTube (or per HackQuest's field) and link from
  the README and the submission.
