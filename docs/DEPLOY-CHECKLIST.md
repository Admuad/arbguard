# ArbGuard — Deploy Checklist (Arbitrum Sepolia, then Arbitrum One)

**Status (2026-11-10): DRY-RUN PROVEN, NOT DEPLOYED.** The Sepolia deploy script
was executed end-to-end against a local Anvil fork of live Sepolia:
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, 29/29 transactions, all status 1,
all contracts deployed (incl. the Attacker demo helper, added 2026-11-10),
both policies registered, demo liquidity seeded, attacker funded, and live
state verified afterwards with `cast` (owner, policies, vault balances,
attacker shares). Nothing has been deployed to any public chain yet.

## Dry-run evidence (local Sepolia fork, 2026-11-10 — current)

- Fork point: Sepolia block 327705313 (live at the time); deployer = Anvil
  account #0 key (local only), funded on the fork with `anvil_setBalance`.
- Deployed addresses on the fork (deterministic for the test deployer key —
  the REAL deploy will produce DIFFERENT addresses; do not hard-code these):
  - ArbGuard: `0x545f3eb0C632814A6a6eD6ffB1b42c63d5898E1e`
  - mWETH: `0x6c1F06112619C3A3bAa93D20F32248727B4b6b8C`
  - mUSDC: `0x8773FA5824FACC3aEcaF7ddC686E481B4d4B01B5`
  - GuardedVault: `0x31081621cE924aF11b963dBFcFeaccD39edAc052` (policyId 0)
  - UnguardedVault: `0x69f2EA841C41416d63E6a0301af086Fc0B277Ff7`
  - GuardedPool: `0x16E70cb94457Fff084F8236805243cC5C5F8753A` (policyId 1)
  - UnguardedPool: `0x31a326c386dcC80CDA4705d8c040EdD842822857`
  - Attacker: `0x84cbb9582173Ae60068e314252c8384f6293d2E7`
  - Keeper (= deployer in the dry run): `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- Total gas for all 29 txs: **6,763,777** — at 0.01 gwei ≈ 0.00007 ETH, at
  0.1 gwei ≈ 0.0007 ETH. Any faucet drip covers it many times over.
- Live-state checks after the dry run (all passed): `owner()` = deployer;
  `getPolicy(0)` = 100 ether outflow / 5000 bps share / 500 bps deviation /
  3600s cooldown / keeper = deployer / enabled = true; `getPolicy(1)` =
  10000 ether / 10000 / 500 / 3600 / keeper / true; GuardedVault and
  UnguardedVault mWETH balance = 1900 ether each (1000 deployer + 900
  attacker); Attacker shares = 900 ether in each vault; Attacker mWETH
  balance = 1100 ether (2900 minted − 1800 deposited; 1000 approved per
  pool for the price push); GuardedPool reserves = 1000/1000 ether.
- Broadcast artifacts: `contracts/broadcast/DeploySepolia.s.sol/421614/run-latest.json`
  (29 receipts, all status 0x1).
- Earlier dry run (same day, before the Attacker was added to the script):
  21/21 txs, 5,922,331 gas — superseded by the 29-tx run above.
- Gotcha found and fixed in the dry run: on a Sepolia fork the Anvil
  default accounts are NOT funded (fork uses real Sepolia state) — the
  first broadcast attempt failed gas estimation ("allowance: 0") until the
  deployer was funded with `anvil_setBalance`. The real deploy needs a
  funded deployer key (see below); the script itself is proven.

## What Muhammed needs to provide (his steps only)

1. **GitHub repo** — create public `github.com/Admuad/arbguard` and push
   this tree (Fred prepares everything else).
2. **Sepolia ETH for gas** — a faucet drip to the deployer address. Faucet:
   Arbitrum Sepolia faucet via Alchemy (linked from the HackQuest Open House
   resource tab). Needed: ~0.001 ETH is far more than enough (measured
   ~0.00006 ETH at 0.01 gwei). No other funds needed — the demo uses mock
   tokens minted by the deploy script itself.
3. **Deployer key** — a FRESH testnet-only private key (generate a new one;
   never reuse a real wallet, never the fresh bounty wallet, never the
   compromised wallet). The deployer becomes the ArbGuard owner (via
   `Ownable2Step`) and the default keeper. Put it in `contracts/.env` as
   `PRIVATE_KEY=0x...` — `.env` is gitignored (root `.gitignore` lines 24–26).
   Optionally set `KEEPER=<address>` to use a separate keeper.
4. **Arbiscan API key (optional, for `--verify`)** — only needed if he wants
   the contracts verified on Arbiscan in the same command; can verify later.

## Real Sepolia deploy — exact commands

```bash
cd contracts  # from the repo root
source .env            # PRIVATE_KEY, optionally KEEPER, ARBISCAN_API_KEY
export PATH="$HOME/.foundry/bin:$PATH"
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY
```

Notes:
- The `:DeploySepolia` suffix is REQUIRED on forge 1.9.0 — the bare
  `script/DeploySepolia.s.sol` form errors out ("contract source info
  format must be `<path>:<contractname>`"). Script headers and
  `contracts/README.md` were fixed to the working form in this phase.
- `--verify` uses Arbiscan's Sepolia explorer
  (`https://sepolia.arbiscan.io`). If verification fails, the deploy still
  stands — verify later with `forge verify-contract`.
- After the deploy, copy the printed addresses into the frontend env
  config — `apps/web/.env.local` for local dev, or the Vercel dashboard
  env vars for production (see `apps/web/.env.example` for the exact
  variable names: `NEXT_PUBLIC_ARB_GUARD_ADDRESS`,
  `NEXT_PUBLIC_GUARDED_VAULT_ADDRESS`, `NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS`,
  `NEXT_PUBLIC_GUARDED_POOL_ADDRESS`, `NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS`,
  `NEXT_PUBLIC_ATTACKER_ADDRESS`, `NEXT_PUBLIC_MWETH_ADDRESS`,
  `NEXT_PUBLIC_MUSDC_ADDRESS`, plus `NEXT_PUBLIC_CHAIN_ID=421614` and
  `NEXT_PUBLIC_DEPLOY_BLOCK=<deploy block>`). `isDeployed` is computed
  from those vars — no code change, no editing `lib/contracts.ts`. Then
  `npm run build` and deploy the frontend to Vercel.

## Post-deploy verification commands

```bash
export PATH="$HOME/.foundry/bin:$PATH"
# <ARB_GUARD> = deployed ArbGuard address; replace all <...> placeholders.
cast call <ARB_GUARD> "owner()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc
cast call <ARB_GUARD> "getPolicy(uint256)(uint256,uint16,uint16,uint32,address,bool)" 0 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc
cast call <M_WETH> "balanceOf(address)(uint256)" <GUARDED_VAULT> \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc
# Arbiscan links (Sepolia):
#   https://sepolia.arbiscan.io/address/<ARB_GUARD>
#   https://sepolia.arbiscan.io/address/<GUARDED_VAULT>
#   https://sepolia.arbiscan.io/address/<GUARDED_POOL>
```

Expected: owner = deployer; policy 0 = 100 ether / 5000 / 500 / 3600 /
keeper / true; GuardedVault mWETH balance = 1000 ether.

## Arbitrum One deploy (final week only — needs his explicit go-ahead)

Same flow, pointed at mainnet. Mock tokens only, small value — the
credibility deployment for judges, not a production launch.

```bash
cd contracts  # from the repo root
source .env
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --broadcast --verify \
  --etherscan-api-key $ARBISCAN_API_KEY
```

Gas: same ~6.8M gas as Sepolia, but at mainnet gas prices — a few dollars
of ETH (his call; Sepolia-only is acceptable if he says no).

## What NOT to do

- Never deploy with the fresh bounty wallet (`0xc7ba...`) or the compromised
  wallet (`0x5978...`) as the deployer. Fresh testnet-only key only.
- Never commit `.env` or any private key. `.env` is gitignored; double-check
  with `git status` before the first push.
- Never run the deploy scripts against a public chain without Muhammed's
  explicit go-ahead on that exact step.

## Re-verification (2026-11-19, latest Sepolia fork)

Re-ran the same script against a fresh local fork of live Sepolia with the
correct Anvil #0 key: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, 29/29
transactions, all status 1. Live-state checks passed: owner = deployer,
policy 0 = 100 ether / 5000 / 500 / 3600 / keeper / true, GuardedVault
mWETH = 1900 ether. Deployed addresses this run (fork-only, not real):
ArbGuard `0x2bcc4171591ceb29b410313cd984554ad85a99c7`.

Note: an earlier re-run the same day failed every send with "allowance: 0"
because the deployer key used had a one-character typo (`...f3ff80` instead
of `...f2ff80`), deriving an unfunded address. Lesson recorded in AGENTS.md:
never hand-type a key; derive it and check `cast wallet address` first.

## Adapter deployment (Phase 2 — PENDING, not deployed)

- No adapter is deployed to any public chain yet. The deploy script
  `contracts/script/DeployAdapters.s.sol` is written and deploys the
  guard + both adapters, derives the Aave Pool/DataProvider/Oracle from
  the PoolAddressesProvider and the reserve allowlist from
  `Pool.getReservesList()`, and registers the adapter policies (Aave:
  $200k/$1M/$5M caps, HF 1.25x, drain 50%; V3: $50k/$500k/$2M caps,
  single-share 50%, drain 50%, HF off, real 0.05% pool + sequencer).
- **Do NOT run it against any live chain yet (spec §6 Q1):** Aave and
  Uniswap deployments on Arbitrum Sepolia are NOT verified. Verify them
  first, then deploy the adapters to Sepolia and record the addresses
  here before any Arbitrum One deployment.
- When deployed, record here: ArbGuard, AaveAdapter, UniswapV3Adapter
  addresses, the policy IDs, and the oracle-config transactions.
- Sepolia Phase 1 addresses (live, 20 Nov 2026 — see
  `SEPOLIA-DEPLOYMENT.md`): ArbGuard
  `0x9D733954c71920a51291d730fc48422d94d5C306`, GuardedVault
  `0xEa182E47829D76569dc50CcADD2bFafe462A0E3D`, GuardedPool
  `0x3b1714FE7583789C10528dD43Dbb18729269679E`, Attacker
  `0x590180b5Ab993A1Af5bBDa12Ad430a442091B4C1`.
