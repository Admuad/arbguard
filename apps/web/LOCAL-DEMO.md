# ArbGuard — Local Anvil demo

Run the whole frontend against a live local deployment: the same drain +
price-push attacks the Foundry tests prove, through the real UI, on Anvil.
$0 cost, no public chain, no real funds. Everything below uses Anvil's
well-known default account #0 — **local only, never a real key**.

## 1. Start Anvil

```bash
anvil --port 8545
```

Leave it running in its own terminal. Anvil account #0 is
`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (private key
`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`).

## 2. Run the demo broadcast

From `contracts/` (Anvil must be up):

```bash
export PATH="$HOME/.foundry/bin:$PATH"
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/AnvilDemo.s.sol:AnvilDemo \
  --rpc-url http://127.0.0.1:8545 --broadcast --skip-simulation
```

`--skip-simulation` is required: the demo deliberately includes two
transactions that revert on-chain (the guarded drain and the guarded price
push), and forge 1.9.0's pre-broadcast simulation aborts the whole run with
"Simulated execution failed" before sending anything if it is left on. With
it skipped, every transaction is broadcast; the two guarded attacks land as
reverted transactions (status 0), which is the demo working as designed.

This deploys ArbGuard, mWETH/mUSDC, guarded + unguarded vaults and pools,
and the Attacker; registers both policies; seeds 1000/1000 into each vault
and pool; and runs both attacks once (unguarded drain succeeds, guarded
reverts — by design). The script exits 1 because the two guarded-attack
transactions revert on-chain by design (caught by try/catch; the demo
completes and logs everything). That exit code is expected, not a failure.

**Forge quirk (1.9.0):** the broadcast stops at the first transaction whose
gas estimation fails — the guarded `drainOnly` (tx 30 of 33). So only 30 of
33 transactions land from the broadcast itself, and the two price-push
transactions never get sent. Finish the demo by sending the last three
calls yourself with explicit gas limits (estimation refuses reverting
transactions, so `--gas-limit` is required). Addresses are in the demo log
and in `contracts/broadcast/AnvilDemo.s.sol/31337/run-latest.json`:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC=http://127.0.0.1:8545
ATT=<Attacker address>; GV=<GuardedVault>; GP=<GuardedPool>; UP=<UnguardedPool>; MW=<mWETH>
# guarded drain — expect status 0 (reverted, the guard working)
cast send $ATT "drainOnly(address,uint256,uint256)" $GV 10000000000000000000 200 \
  --private-key $PK --rpc-url $RPC --gas-limit 3000000
# unguarded price push — expect status 1 (success, reserves 1000/1000 -> 2000/500)
cast send $ATT "pushPriceAndSwap(address,address,uint256)" $UP $MW 1000000000000000000000 \
  --private-key $PK --rpc-url $RPC --gas-limit 1000000
# guarded price push — expect status 0 (reverted)
cast send $ATT "pushPriceAndSwap(address,address,uint256)" $GP $MW 1000000000000000000000 \
  --private-key $PK --rpc-url $RPC --gas-limit 1000000
```

(The `e2e-anvil.mjs` script re-seeds the attacker and re-runs all of this
itself, so it does not depend on these three transactions.)

## 3. Write the frontend env file

```bash
cd apps/web
node scripts/write-local-env.mjs
```

This reads `contracts/broadcast/AnvilDemo.s.sol/31337/run-latest.json` and
writes `apps/web/.env.local` with all the `NEXT_PUBLIC_*` addresses,
`CHAIN_ID=31337`, `RPC_URL=http://127.0.0.1:8545` and the deploy block.
Re-run it after every fresh demo broadcast (addresses change each run).

## 4. Run the frontend

```bash
npm run dev
```

Open http://localhost:3000 and connect **Anvil account #0** in your wallet
(MetaMask → add network localhost:8545, chain 31337, import the account #0
private key above — local only). The dummy WalletConnect project ID in
`.env.local` means WalletConnect itself will not connect; use an injected
wallet (MetaMask / Rabby) pointed at localhost instead.

## 5. What to try

- **/simulator** — Run the drain on Unguarded (vault 1900 → 1000 mWETH),
  then on Guarded (reverts `ArbGuardViolation(OUTFLOW_PER_BLOCK)`, balance
  stays 1900). Run the price push on Unguarded (reserves 1000/1000 →
  2000/500), then on Guarded (reverts `ArbGuardViolation(PRICE_DEVIATION)`).
  Each run shows the real receipt: tx hash, block, status, balances
  before/after, decoded revert reason.
- **/feed** — On-chain events (`PolicyRegistered`, `CheckPassed` from any
  passing guarded action), the `simulateCheck` preview buttons, and the
  "Blocked attempts (this session)" list fed by the simulator.
- **/policies** — `registerPolicy` is owner-only: the connected wallet must
  be the deployer/owner account (Anvil account #0). Any other account's
  transaction reverts.

## Reset

The unguarded drain and price push consume the attacker's funds/shares, so
each attack only works **once** per deployment:

- The unguarded drain empties the attacker's shares in the unguarded vault.
- The unguarded price push spends the attacker's 1000 mWETH.
- The guarded attacks always revert and consume nothing — they can be
  re-run as often as you like.

To reset, stop Anvil, restart it, and re-run steps 2–3 (fresh deployment,
fresh addresses, fresh `.env.local`). Restart `npm run dev` too, so Next.js
picks up the new env file.
