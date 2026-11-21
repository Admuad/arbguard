# Video Brief for Jake — ArbGuard Demo Video

**Prepared by:** Fred (Muhammad's AI assistant), 20 Nov 2026
**For:** Jake, video producer
**Subject:** ArbGuard — demo video for the Arbitrum Open House (São Paulo), submission deadline 28 Feb 2027

> **Assumption — please confirm:** This brief covers **ArbGuard**, the Arbitrum circuit-breaker Muhammed built and deployed to Arbitrum Sepolia. It does NOT cover SpendGuard (his Aevum entry, which already has a demo video, v9). If you meant SpendGuard, say so and I will write a separate brief.

> **How to use this brief:** Everything in it is factual, drawn from the repo, the live deployment, and the project docs. Anything I could not verify is marked **[UNVERIFIED]** or listed in the questions at the end. Do not invent features, numbers, or claims beyond what is written here. If a detail is missing, ask Muhammed — do not guess.

---

## 1. THE APP

**App name:** ArbGuard (formerly GuardRail — use "ArbGuard" everywhere; "GuardRail" is the old name and must not appear in the video).

**One-sentence pitch:** ArbGuard is an on-chain circuit breaker for Arbitrum: it reverts the exploit transaction before the money moves.

**The problem it solves, in plain words:** DeFi protocols lose money when an attacker moves far too much value, or at a far worse price, in a single transaction — a drain that empties a vault, or a swap that pushes the price 40% in one go. The tools that exist today either warn you after the money is already gone (monitors, dashboards) or check the code before it is deployed (audits, scanners). Nothing sits in the middle and stops the bad transaction itself, on-chain, in real time. ArbGuard is that missing piece: a protocol declares its limits (how much can leave per block, how big one withdrawal can be, how far the price may move), and ArbGuard reverts any transaction that breaks them. The money never moves.

**Who it is for:** Small and mid-size DeFi protocols on Arbitrum that cannot afford a $100,000 audit or a 24/7 security team, but can afford a 10-line integration. Also for the hackathon judges and future users who need to see the block happen, not read about it.

**Live website URL(s):** **[MISSING — see questions at the end.]** The frontend is a Next.js app in the repo (`apps/web`). It runs locally at `http://localhost:3000`. No live deployed URL has been confirmed. Do not put a frontend URL on screen unless Muhammed confirms one.

**GitHub repo URL:** https://github.com/Admuad/arbguard (public).

**Tech stack:**
- Smart contracts: Solidity 0.8.28, Foundry (tests, scripts, deployment)
- Frontend: Next.js 15, TypeScript, wagmi + viem, RainbowKit (wallet connection)
- Keeper bot: Node.js / TypeScript + viem (off-chain watcher; dry-run by default)
- Rust / Stylus checker: built and tested, **NOT wired into the live path** — Arbitrum paused all new Stylus contract activations chain-wide on 2 Oct 2026, so the checker cannot be deployed while the pause holds. The video must say "invariant checks in Solidity; Stylus checker on the roadmap" and must NOT claim Stylus is live.
- Blockchain / network: Arbitrum Sepolia testnet (live deployment) and Arbitrum One (fork tests only — no mainnet deployment).

---

## 2. THE HACKATHON

**Hackathon name and organizer:** Arbitrum Open House, São Paulo, 8–28 February 2027. 100% online. Organizer: Arbitrum Foundation (run on the HackQuest platform).

**Judging criteria:** **[UNVERIFIED — template only, not confirmed for São Paulo.]** The only criteria on file come from the Arbitrum Buildathon series template (not a São Paulo-specific page, which is JS-rendered and could not be read as text). The template lists five criteria:
1. Innovation
2. Technical implementation
3. Use of Arbitrum technology
4. Potential impact
5. Presentation quality

The template also notes: "Novelty projects will receive a bonus consideration." Decisions are final, no appeal. **Jake / Muhammed must confirm the exact São Paulo criteria and any weights from the HackQuest page before the video is finalised** — do not present the template list as the official São Paulo criteria.

**Submission deadline:** 28 February 2027, 11:59 PM BRT. Winners announced 8 March 2027. Prize pool: $115,000. (Internal submission target: Friday 26 February 2027.)

**Demo video requirements:**
- Length: 2–3 minutes. Hard cap 180 seconds. Target 150 seconds (2.5 min).
- Format: motion graphics built from real UI stills — **not** a raw screen recording, and **not** AI-generated video (generated video cannot render a real interface). Slow smooth push-ins, one transition style (cross-dissolve), short on-screen captions throughout, continuous voiceover.
- Delivery: upload unlisted to YouTube (or as the HackQuest submission field requires) and link it from the repo README and the submission. **[UNVERIFIED: the exact HackQuest submission field requirements for the video have not been confirmed from the official page.]**
- The video must show the receipt, not just the UI: the Arbiscan receipt (or the simulator's receipt panel) with the revert reason visible is the evidence. A green/red banner alone is not proof.

---

## 3. FEATURES

Listed in order of importance for the demo. Each feature is real and shipped; the notes say what the user sees.

### 1. The revert — a drain attack is blocked (the core proof)
What it does: when an attacker loops `withdraw()` inside a single transaction to empty a vault, ArbGuard's per-block outflow rule fires and the **entire transaction reverts**. Nothing moves, no partial state survives.
Why it matters: this is the whole product in one frame. Every other feature supports it.
What the user sees: the attack simulator runs the same drain attack on two vaults side by side. The unguarded vault drains to ~0. The guarded vault shows a reverted receipt with the reason `ArbGuardViolation(OUTFLOW_PER_BLOCK)` and the balance unchanged.

### 2. The price-push block
What it does: a swap that would move the execution price beyond the policy's allowed deviation from the reference price reverts with `PRICE_DEVIATION`.
Why it matters: it stops oracle-manipulation and flash-loan price-push swaps.
What the user sees: the simulator runs a price-push swap (price moves 40%) on the unguarded pool — it goes through. The same swap on the guarded pool reverts with `ArbGuardViolation(PRICE_DEVIATION)` and the price does not move.

### 3. Oracle-fed prices — Chainlink + Uniswap V3 TWAP cross-check
What it does: the guard reads the reference price itself from on-chain oracles. Chainlink is primary; the Uniswap V3 TWAP (read from the pool via `observe()`) cross-checks it. If the two disagree by more than 200 basis points (2%), the guard refuses to give a reference price (`ORACLE_DISAGREEMENT`).
Why it matters: the guard does not trust a caller-supplied price. The reference is computed on-chain.
What the user sees: on the dashboard oracle panel, the Chainlink and TWAP references side by side. On Sepolia the panel honestly shows the feed is stale (see §6 and "What not to do").

### 4. Aave V3 adapter — health-factor and reserve-drain rules
What it does: ArbGuard guards real Aave V3 positions through an adapter, without changing Aave. Two new rules: a borrow or withdrawal that would leave the account's health factor below the floor reverts (`HEALTH_FACTOR`); a single action that would take more than the allowed share of the reserve's available liquidity reverts (`RESERVE_DRAIN`).
Why it matters: real money sits in Aave, not in demo vaults. This is the proof the guard works on a real protocol.
What the user sees: fork-test terminal output, not a live demo — the adapters are proven on an Arbitrum One fork, **not** deployed to any public chain. The video must say "proven on an Arbitrum One fork", never "live on Aave". Boundary numbers: borrow 67 WETH passes, 68 WETH reverts; borrow 5,000 USDC passes, 5,100 USDC reverts.

### 5. Uniswap V3 adapter — TWAP cross-check and drain cap on real pools
What it does: swaps through a real Uniswap V3 pool are checked against Chainlink and the pool's own TWAP, and a swap that would drain the pool reverts before it executes.
Why it matters: same as above — the guard works on a real AMM, not just the demo pool.
What the user sees: fork-test terminal output (`UniswapV3Fork` 7/7) and adapter code. Same honesty rule as feature 4: "proven on an Arbitrum One fork", never "live on Uniswap".

### 6. Keeper bot — someone watches the guard
What it does: an off-chain bot watches the guard's policies and, when an hour's outflow hits 80% of the cap, throttles the policy to 10% of its caps for a day — buying the owner time to look. It can also trip the breaker (pause the protocol for the cooldown). It only calls keeper functions; it never moves funds and never holds more than a testnet-only key. Dry-run is the default.
Why it matters: a guard nobody watches is a guard nobody trusts.
What the user sees: a terminal log of a dry-run cycle (`WOULD_THROTTLE`), then a live `ThrottleSet` event on Arbiscan. The bot is **not yet live** — it is built, tested, and dry-run verified, but its key is unfunded and it is not registered as a keeper. The video must not claim the bot is running live.

### 7. Live dashboard
What it does: a page that reads live from the Sepolia deployment — both policies, their caps, how much of each outflow window is used, vault and pool balances, and the guard's real events.
Why it matters: judges can see the guard is actually deployed and working, not a slide deck.
What the user sees: policy cards, outflow-window bars, balances, the oracle panel, and the events list, all from live Sepolia reads (not hard-coded numbers).

### 8. Policy form — set four limits, deploy a policy
What it does: a form with sliders for the four main limits (outflow per block, per hour, per day, single-share cap, price deviation). The owner deploys the policy on-chain.
Why it matters: the guard is opt-in and declarative — a protocol chooses its own limits.
What the user sees: sliders and a deploy button on the Policies page.

### 9. Ten-line integration — one `check()` call
What it does: a protocol integrates ArbGuard by calling `check()` once, before its sensitive function, with the action's details. That is the whole integration.
Why it matters: adoption. A 10-line change is a decision a small team can make in an afternoon.
What the user sees: a code editor shot of the guarded `withdraw()` with the single `check()` call highlighted, and the 10-line diff.

### 10. Breaker trip / reset + cooldown
What it does: a keeper (or the owner) can trip the breaker at any time, pausing every guarded function for the cooldown period. After the cooldown passes, the guard resumes automatically — no 3 a.m. multisig scramble. Only the owner can reset it early.
Why it matters: when an attack is spotted, the protocol can pause before the next transaction.
What the user sees: the breaker state on the dashboard and the `BreakerTripped` / `BreakerReset` events in the feed.

### Explicitly NOT features (do not show or claim these)
- **Stylus checker in the live path.** Built and tested, NOT wired in. Say "on the roadmap" only.
- **Reserve conservation (Rule 4).** Specified in the architecture, NOT enforced. Do not cite it as a shipped protection.
- **A live feed of blocked attacks.** A reverted transaction leaves no persistent on-chain event, so there is no `ViolationBlocked` event and the dashboard cannot show blocked attacks as feed entries. Blocked attacks are visible only in the receipt and the unchanged balance.
- **Live Aave/Uniswap guarding.** Fork-proven only. Never "live on Aave" or "live on Uniswap".
- **Swaps failing closed on the live Sepolia deploy.** They do not — the pool pair is unconfigured, so the price rule is skipped and a 40% push would pass (see §6).

---

## 4. THE DEMO FLOW, STEP BY STEP

The video follows the 150-second spine (6 segments). The exact journey, in order:

### Before recording — setup
- Network: **Arbitrum Sepolia** (chain ID 421614). Both vaults are already funded with the same mock balances (1,900 mWETH each: 1,000 seed + 900 attacker deposit) and both pools hold the same liquidity (1,000 mWETH + 1,000 mUSDC). The deploy script seeded all of this; Jake does not need to fund anything.
- Browser tabs ready: the frontend simulator, and the Arbiscan pages for the guarded and unguarded vaults.
- One continuous take per segment; cut between segments, never mid-attack. The unguarded drain and the guarded revert must be the **same attack code against the same starting balances** — that is the proof. Do not re-record one side with different parameters.

### Wallet steps (exact)
1. **Open the frontend** (locally at `http://localhost:3000`, or the live URL once confirmed). The RainbowKit **Connect Wallet** button is in the header.
2. **Click Connect Wallet.** RainbowKit shows the wallet options. The user picks their wallet (MetaMask / injected wallet, or WalletConnect).
   - **Note:** the frontend's WalletConnect project ID is currently blank in the local config. WalletConnect-based wallets may not connect without a real project ID. An injected wallet (MetaMask) works without it. **[Confirm with Muhammed which wallet Jake should use for the demo.]**
3. **Wallet prompts to switch network** (if the wallet is not already on Arbitrum Sepolia). The user approves the switch to Arbitrum Sepolia in the wallet popup.
4. **Wallet prompts to connect** (approve the connection). The user approves. The header now shows the connected address.
5. **Go to the Simulator page.** Select the target (Unguarded vault / Guarded vault / Unguarded pool / Guarded pool), select the attack (Drain / Price push), click **Run**.
6. **Wallet prompts to confirm the transaction.** The attack is a real on-chain transaction sent to the Attacker contract. The wallet shows the transaction details and the gas fee (paid in Sepolia ETH — a tiny amount, well under 0.001 ETH per attack). The user clicks **Confirm**.
   - For the **unguarded** attack: the transaction succeeds. The receipt appears showing success, and the vault balance animates to ~0 (drain) or the price moves 40% (price push).
   - For the **guarded** attack: the wallet's pre-flight simulation may flag that the transaction will revert before it is broadcast. The simulator catches this, re-runs the call statically to capture the revert data, and displays the failed receipt with the revert reason (`ArbGuardViolation(OUTFLOW_PER_BLOCK)` or `ArbGuardViolation(PRICE_DEVIATION)`) and the before/after balances side by side — the balance does not move.
7. **What the user sees on screen at each step:** the simulator panel (target, attack, Run button), the wallet popup (network switch, then transaction confirmation), the receipt panel (success or reverted, with the reason highlighted), and the before/after balances.

### What the demo needs
- A real wallet (MetaMask or equivalent) with Arbitrum Sepolia configured.
- Sepolia ETH for gas (a small amount; the deployer holds ~0.0986 ETH, but the demo wallet needs its own small drip — a faucet drip is enough).
- The mock tokens are already in the vaults and pools; Jake does not need to mint or fund them.
- No real funds are at risk at any point — everything is mock tokens on a testnet.

### The six segments (150 seconds total)
| Segment | Time | What happens |
|---|---|---|
| 1. The problem | 0–15s | Title card. "DeFi lost $1.8 billion to exploits in 2025." **[UNVERIFIED figure — see §6.]** "Almost every loss was the same shape — one transaction that should never have been allowed." Two vaults side by side. |
| 2. Attack 1: the drain | 15–45s | Unguarded vault drains (receipt: success, balance ~0). Same attack on the guarded vault: receipt **reverted**, `OUTFLOW_PER_BLOCK`, balance unchanged. **Key frame (hold 2s):** the reverted receipt next to the unchanged balance. This is the whole product in one frame. Do not rush past it. |
| 3. Attack 2: the price push | 45–70s | Unguarded pool price moves 40%. Guarded pool, same swap: reverted `PRICE_DEVIATION`, price unchanged. |
| 4. Attacks 3 and 4: the real protocols | 70–110s | Fork-test terminal: `AaveFork` 13/13, health-factor boundary (67 WETH passes, 68 reverts), reserve-drain boundary (5,000 USDC passes, 5,100 reverts). `UniswapV3Fork` 7/7, TWAP cross-check on the real pool. Voiceover must say "proven on an Arbitrum One fork" — never "live on Aave" or "live on Uniswap". |
| 5. Keeper bot + dashboard | 110–140s | Dashboard stills: policy cards, mode badges, outflow bars, live from Sepolia. Keeper bot dry-run log (`WOULD_THROTTLE` at 80% hour use), then a live `ThrottleSet` event on Arbiscan. Dashboard oracle panel: stale feed (last update 16 Oct 2024), pair unconfigured so the price rule is skipped — shown honestly, not as a revert. |
| 6. Integration + links | 140–150s | Code editor: the guarded `withdraw()` with the single `check()` call highlighted ("ten lines. One check() call."). Policy form sliders. End card: repo URL, frontend URL, "Solidity firewall — Stylus checker on the roadmap". Add the line: "Keeper bot watches it. Dashboard shows it." |

---

## 5. SCREENS

The app is a Next.js website. Routes (all under the same site; the local base is `http://localhost:3000` — prepend the live URL once confirmed):

| Screen | URL path | What it shows | What the user does there |
|---|---|---|---|
| Home / Overview | `/` | Hero: "The on-chain circuit breaker for Arbitrum." Sub-line: "ArbGuard reverts the exploit transaction before the money moves." Three value props: "Enforcement, not detection", "Same attack, two vaults", "10 lines to integrate". Links to the simulator and the policy form. | Reads the pitch, clicks through to the simulator or the policy form. |
| Attack simulator | `/simulator` | "Attack simulator" heading. Target selector (Guarded / Unguarded vault, Guarded / Unguarded pool), attack selector (Drain / Price push), Run button, receipt panel (success or reverted with the reason), before/after balances. | Connects a wallet, picks a target and an attack, clicks Run, confirms in the wallet, reads the receipt. |
| Create a policy | `/policies` | "Create a policy" heading. A form with sliders for the limits (outflow per block/hour/day, single-share cap, price deviation, cooldown, throttle). Deploy button. | Sets the four limits, deploys the policy on-chain (wallet confirmation required). |
| Integrate | `/integrate` | "Integrate ArbGuard in 10 lines" heading. The guarded `withdraw()` code with the single `check()` call highlighted, and the 10-line diff. | Reads the integration code. |
| Live event feed | `/feed` | "Live event feed" heading. Real, persistent ArbGuard events from the deployed contracts: `PolicyRegistered`, `CheckPassed`, `BreakerTripped`, `BreakerReset`. | Watches real events as they happen on Sepolia. Note: blocked attacks do NOT appear here (a reverted tx leaves no event). |
| Live dashboard | `/dashboard` | Policy cards for policy 0 and 1, balances, outflow-window bars, the oracle panel (showing the stale feed), and the events list. All read live from Sepolia, refreshed every 30 seconds. | Views the live state of the deployment. |

---

## 6. FACTS AND NUMBERS

Only real numbers, each with its source. Anything not verified is marked.

**Tests (source: `forge test`, run 21 Nov 2026):**
- 244 passed, 0 failed, 244 total (CI green). The Phase 1 gas tests pass
  under the 250k target (revised 21 Nov 2026 from 120k after the
  real-fork measurement; mock SWAP ~127k, real-fork warm ~226k).
- All 159 Phase 1 tests still pass. New Phase 2 suites: AaveAdapter 14/14, UniswapV3Adapter 13/13, HealthFactor 12/12, ReserveDrain 10/10, AdapterUnits 4/4, Mirror 8/8, AaveFork 13/13, UniswapV3Fork 7/7.
- Keeper bot unit tests: 27/27. Keeper Anvil fork test: 10/10.

**Contract size (source: `forge build --sizes`):**
- ArbGuard: 23,705 bytes deployed — 871 bytes under the 24,576-byte EIP-170 limit.
- AaveAdapter: 5,089 bytes. UniswapV3Adapter: 12,890 bytes.

**Live Sepolia deployment, Phase 2 (source: on-chain reads, 20 Nov 2026; deploy block 331140442):**
- ArbGuard: `0xef9efc433d6069f6ab7776d8889b8dae6b66146f`
- GuardedVault: `0xfc39b73dbadcaa2bbcfd0faa0043d4ef3ca468db` — holds 1,900 mWETH (1,000 seed + 900 attacker deposit)
- GuardedPool: `0x1496cbde3ee3b0cb302f23a7d6a7cace2b57366a` — holds 1,000 mWETH seed liquidity
- Attacker: `0x12a0d6356f235361023c7b5a36a1ed73d47195ec`
- mWETH: `0x694dab209bb231bfb2b86737198ee2e2f30bd9ae`. mUSDC: `0x604d40a5d31c821c489fa8a502d27454308835c1`
- Deployer: `0xE670974a278A47a0A311dA4Ab780d714acb0EfF0`, ~0.0986 ETH remaining after the deploy (deploy cost ~0.0005 ETH).
- The earlier Phase 1 deployment (ArbGuard `0x9D733954c71920a51291d730fc48422d94d5C306`, block 331084418) still exists on-chain but is superseded.

**Fork-test evidence (source: Foundry fork tests, Arbitrum One block 525,970,897):**
- Aave health-factor boundary: borrow 67 WETH passes, 68 WETH reverts.
- Aave reserve-drain boundary: borrow 5,000 USDC passes, 5,100 USDC reverts.
- Aave USDC on Arbitrum One is ~99.99% utilised (~10,174 USDC available of ~160.9M supplied).
- TWAP manipulation-cost test: pushing the price 5% costs the attacker far more than the guard would let through (the test asserts the cost exceeds the extractable cap). **[The specific dollar figures from earlier notes (~$293,926 loss vs ~$43,799 extractable) were NOT re-verified from the test output in this brief — do not put dollar figures on screen unless Muhammed confirms them.]**

**Policy caps, live Sepolia deployment (source: `DeploySepolia.s.sol`):**
- Vault policy (policy 0): max outflow 100 ether/block, 2,000/hour, 10,000/day; single-share cap 50% (5,000 bps); price deviation 5% (500 bps); throttle 10% (1,000 bps); cooldown 3,600s.
- Pool policy (policy 1): max outflow 10,000 ether/block, 200,000/hour, 1,000,000/day; single-share cap 100% (10,000 bps); price deviation 5%; throttle 10%; cooldown 3,600s.

**Keeper bot (source: `keeper/` runbook and dry-run log):**
- Throttle trigger: hour outflow at 80% of the cap → throttle the policy to 10% of its caps for 24 hours.
- Dry-run verified on Sepolia: 3 cycles × 2 policies, all `NO_ACTION`.

**Hackathon (source: project goal file and Phase 3 spec):**
- Prize pool: $115,000. Event: 8–28 Feb 2027. Deadline: 28 Feb 2027, 11:59 PM BRT. Winners: 8 Mar 2027.

**Claims in the video that must be phrased exactly as written here:**
- "ArbGuard reverts the exploit transaction before the money moves." (Verified: the drain and price-push demos do this.)
- "Ten lines. One check() call." (Verified: the integration is a single `check()` call before the sensitive action.)
- "Proven on an Arbitrum One fork." (For the Aave/Uniswap adapters — verified by the fork tests. Never "live on Aave" or "live on Uniswap".)
- "Invariant checks in Solidity; Stylus checker on the roadmap." (Verified: the Stylus checker is built and tested but not wired in, and activations are paused.)

**[UNVERIFIED — do not state as fact without confirmation:]**
- "DeFi lost $1.8 billion to exploits in 2025." This figure is stated in the project docs and demo script, but its primary source (e.g. Rekt Database, DefiLlama, Chainalysis) was not verified in this brief. Either confirm the source with Muhammed or drop the number and say "DeFi loses billions to exploits every year" — or use no number at all.
- The exact São Paulo judging criteria and weights (see §2).
- The exact HackQuest submission field requirements for the video (see §2).

---

## 7. TONE AND STYLE FOR THE VIDEO

**Feel:** clean, sleek, and alive — like a top-brand motion-graphics video (PayPal-style). Real UI stills animated with slow, smooth push-ins. One transition style only (300ms cross-dissolve). Short caption phrases in a dark pill so the video works muted. No raw screen recording, no jerky scrolling, no silence while scrolling, no mouse narration.

**Script voice:** it must sound like a real person talking, not AI. Natural sentences, normal everyday words. No rhyming, no matching adjectives, no staccato lists, no disconnected fragments with no prepositions. No "Alright, so this is ArbGuard" opening, no filler, no awkward silence. The voiceover opens on the point. Calm-authority register — a person who knows what they built, explaining it plainly.

**Brand colors and visual style (source: the live frontend, `apps/web/app/globals.css`):**
- Background: very dark navy/black `#0a0e14`.
- Text: light gray `#e5e7eb`.
- Accent: green `#22c55e` (used for sliders and highlights).
- The UI is dark-themed throughout. The video should match: dark background, light text, green accents, clean sans-serif type. No blue tint anywhere.
- Logo: **[MISSING — no logo file was found in the repo. Confirm with Muhammed whether there is an ArbGuard logo, and where it lives.]** The demo script mentions a title card with the ArbGuard logo; do not invent one.

**Never mention other teams in the video.** No competitor names, no other hackathon entries.

---

## 8. WHAT NOT TO DO

- Do not invent features, numbers, or claims. Everything in the video must trace to this brief, the repo, or the live deployment.
- Do not claim anything the app cannot actually do. In particular:
  - Do not claim the Stylus checker is live. It is built, tested, and **not** wired in. Say "on the roadmap" only.
  - Do not claim the live feed shows blocked attacks. A reverted transaction leaves no on-chain event, so blocked attacks never appear in the feed. They are visible only in the receipt and the unchanged balance.
  - Do not claim live Aave or Uniswap guarding. The adapters are proven on an Arbitrum One fork, **not** deployed to any public chain. Say "proven on an Arbitrum One fork" every time.
  - Do not claim swaps fail closed on the live Sepolia deploy. They do not: the pool pair is unconfigured (mUSDC has no feed, no TWAP pool), so the price rule is skipped and a 40% push would pass. The dashboard shows this honestly.
  - Do not claim Rule 4 (reserve conservation) is enforced. It is specified, not implemented.
  - Do not call the demo pool's price a TWAP. It is a v1 proxy (`lastPrice`, updated at most once per block), not a production TWAP.
  - Do not use placeholder addresses on screen. Real Arbiscan links or none at all.
  - Do not use the old name "GuardRail" anywhere.
  - Do not use the old Phase 1 deployment addresses (ArbGuard `0x9D73...`). The live addresses are the Phase 2 ones in §6.
- Flag anything you are unsure about instead of guessing. If a shot cannot be sourced from a real asset (a real UI still, a real receipt, a real terminal output), do not render it — ask Muhammed.

---

## QUESTIONS FOR MUHAMMED (before Jake starts)

1. **Is this brief for ArbGuard or SpendGuard?** I assumed ArbGuard (Arbitrum Open House). If you meant SpendGuard, I will write a separate brief.
2. **Live frontend URL:** is the ArbGuard frontend deployed anywhere (Vercel or otherwise)? If so, what is the URL? If not, the video uses the local build (`http://localhost:3000`) for stills.
3. **Logo:** is there an ArbGuard logo file? Where does it live?
4. **Wallet for the demo:** which wallet should Jake use to record the simulator (MetaMask?), and is there a WalletConnect project ID to set? The local config currently has it blank, so WalletConnect-based wallets may not connect.
5. **Voiceover:** who records it — you, or a voiceover artist? (The 90-second script says "Muhammed's voice".)
6. **Music:** does Jake pick the music, or do you? (For SpendGuard you picked the music yourself — same here?)
7. **The $1.8B figure:** is there a primary source Jake should cite for "DeFi lost $1.8 billion to exploits in 2025", or should he drop the number?
8. **Judging criteria and submission checklist:** can you confirm the exact São Paulo criteria, weights, and what the HackQuest submission form asks for (repo link? contract address? video link? README? pitch deck?) — the official page is JS-rendered and I could not read it as text.
9. **Sepolia ETH for the demo wallet:** who funds the demo wallet, and how much? (Each attack costs well under 0.001 ETH in gas; a small faucet drip is enough.)
10. **Video length:** target 150 seconds (2.5 min) within the 2–3 min requirement — is that right, or do you want the full 3 minutes?
