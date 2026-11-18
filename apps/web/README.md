# ArbGuard web frontend

Next.js 15 (App Router) + TypeScript + Tailwind CSS + wagmi v2 + viem v2 +
RainbowKit. Wallet networks: Arbitrum Sepolia (demo) and Arbitrum One.

## Run

```bash
npm install
npm run dev
```

## WalletConnect project ID

Set `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` in `.env.local` (copy
`.env.example` first). Get a free project ID at
https://cloud.walletconnect.com. Without it the app still builds — a dummy
placeholder ID is used — but wallet connection will not work.

## Deployment status

Contracts are **not deployed yet** on any public chain (a Sepolia deploy
dry-run passed on a local fork — see `docs/DEPLOY-CHECKLIST.md`). The
ABIs in `lib/contracts.ts` are generated from the real contracts via
`scripts/generate-abis.mjs` (run `forge build` in `contracts/`, then
`node scripts/generate-abis.mjs` here — do not hand-edit them).
Deployment addresses are env-driven (see `.env.example`) and `isDeployed`
is computed from them, so the UI stays in simulation / empty-feed mode
until real addresses are filled in: the policy form shows a transaction
preview, the simulator runs in explicit simulation mode, and the feed
shows an empty state.

## Deploy to Vercel

No build-setting changes needed — `vercel.json` in this directory already
sets the framework (`nextjs`), build command (`npm run build`) and install
command (`npm install`).

1. Import the repo in Vercel.
2. Set the **root directory to `apps/web`** (required when the repo is
   imported at its root — `vercel.json` sits in `apps/web/`, so no
   `rootDirectory` override is needed inside the file itself).
3. Set the environment variables from `.env.example` (Project Settings →
   Environment Variables). For production, use the Sepolia deployment
   addresses — fill them in after the real deploy (see
   `docs/DEPLOY-CHECKLIST.md`).
4. Deploy.

## Local Anvil demo

Run the full drain / price-push demo against a local Anvil chain, with
this frontend pointed at the local deployment. See
[`LOCAL-DEMO.md`](LOCAL-DEMO.md) for the step-by-step.
