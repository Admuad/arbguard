// End-to-end verification of the frontend's exact live calls against a
// local Anvil demo deployment. Run AFTER the AnvilDemo broadcast +
// write-local-env.mjs (see apps/web/LOCAL-DEMO.md):
//   cd apps/web && node scripts/e2e-anvil.mjs
//
// Uses only Anvil's well-known default account #0 (local only, never a
// real key). Re-seeds the attacker first: the demo broadcast itself already
// consumed the unguarded drain + price push once, so this script mints
// fresh mWETH to the Attacker, re-deposits 900 into the unguarded vault
// and re-approves the unguarded pool before re-running the attacks.
// The guarded attacks always revert and consume nothing.
//
// Asserts (each printed PASS/FAIL):
//   getPolicy(0)/getPolicy(1) return the demo policies
//   simulateCheck drain 900 mWETH on guarded vault -> (false, OUTFLOW_PER_BLOCK)
//   simulateCheck swap 1000 mWETH on guarded pool -> (false, PRICE_DEVIATION)
//   drainOnly on unguarded vault succeeds and the vault balance drops
//   drainOnly on guarded vault reverts ArbGuardViolation(1), balance unchanged
//   pushPriceAndSwap on unguarded pool succeeds
//   pushPriceAndSwap on guarded pool reverts (3), reserves unchanged
//   getLogs returns PolicyRegistered + CheckPassed events
// Exit code 0 only if every assertion passes.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  encodeFunctionData,
  formatEther,
  http,
  parseEther,
  parseEventLogs,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = dirname(fileURLToPath(import.meta.url));
const webDir = join(here, "..");
const repoDir = join(webDir, "..", "..");

function loadAbi(contractFile, contractName) {
  const p = join(repoDir, "contracts", "out", contractFile, `${contractName}.json`);
  return JSON.parse(readFileSync(p, "utf8")).abi;
}

const ARB_GUARD_ABI = loadAbi("ArbGuard.sol", "ArbGuard");
const VAULT_ABI = loadAbi("GuardedVault.sol", "GuardedVault");
const POOL_ABI = loadAbi("GuardedPool.sol", "GuardedPool");
const ATTACKER_ABI = loadAbi("Attacker.sol", "Attacker");
const TOKEN_ABI = loadAbi("MockERC20.sol", "MockERC20");

// Anvil default account #0 — local only, never a real key.
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const account = privateKeyToAccount(DEPLOYER_KEY);

// Frontend's exact config: read apps/web/.env.local (written by write-local-env.mjs).
const env = {};
for (const line of readFileSync(join(webDir, ".env.local"), "utf8").split("\n")) {
  const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
  if (m) env[m[1]] = m[2].trim();
}
const A = {
  guard: env.NEXT_PUBLIC_ARB_GUARD_ADDRESS,
  guardedVault: env.NEXT_PUBLIC_GUARDED_VAULT_ADDRESS,
  unguardedVault: env.NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS,
  guardedPool: env.NEXT_PUBLIC_GUARDED_POOL_ADDRESS,
  unguardedPool: env.NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS,
  attacker: env.NEXT_PUBLIC_ATTACKER_ADDRESS,
  mweth: env.NEXT_PUBLIC_MWETH_ADDRESS,
  musdc: env.NEXT_PUBLIC_MUSDC_ADDRESS,
};
const RPC = env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545";
const DEPLOY_BLOCK = BigInt(env.NEXT_PUBLIC_DEPLOY_BLOCK || "0");

const publicClient = createPublicClient({ transport: http(RPC) });
const walletClient = createWalletClient({ account, transport: http(RPC) });

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
}

const fmt = (v) => `${formatEther(v)}`;

/** Decode ArbGuardViolation(reason) from a viem call error, or null. */
function decodeViolation(error) {
  const candidates = [];
  const seen = new Set();
  const walk = (value, depth) => {
    if (value == null || depth > 6 || seen.has(value)) return;
    seen.add(value);
    if (typeof value === "string") {
      for (const m of value.matchAll(/0x[0-9a-fA-F]{8,}/g)) candidates.push(m[0]);
      return;
    }
    if (typeof value !== "object") return;
    if (typeof value.data === "string" && value.data.startsWith("0x")) candidates.push(value.data);
    if (typeof value.message === "string") walk(value.message, depth + 1);
    if (value.cause !== undefined) walk(value.cause, depth + 1);
  };
  walk(error, 0);
  // Try every candidate: decodeErrorResult matches on the ABI, so no
  // hardcoded selector is needed (the live selector is 0xe63ab918).
  for (const data of candidates) {
    try {
      const d = decodeErrorResult({ abi: ARB_GUARD_ABI, data });
      if (d.errorName === "ArbGuardViolation") return d.args[0];
    } catch {
      // try next candidate
    }
  }
  return null;
}

async function sendAndWait(fn, label) {
  const hash = await fn();
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") console.log(`  note: ${label} tx ${hash} status=${receipt.status}`);
  return receipt;
}

async function main() {
  console.log("== ArbGuard frontend E2E against Anvil ==");
  console.log(`RPC: ${RPC}  deploy block: ${DEPLOY_BLOCK}`);

  // 0. Sanity: every address the frontend needs is set and non-zero.
  const zero = "0x0000000000000000000000000000000000000000";
  check(
    "env: all 8 contract addresses set and non-zero",
    Object.values(A).every((v) => v && v.toLowerCase() !== zero),
    Object.entries(A).map(([k, v]) => `${k}=${v}`).join(" "),
  );

  // Re-seed (demo broadcast already consumed the unguarded attacks once):
  // mint 1900 mWETH to the Attacker, deposit 900 into the unguarded vault,
  // re-approve the unguarded pool for the 1000 mWETH push. The guarded
  // vault still holds the attacker's 900 shares from the demo (its drain
  // reverted, so the deposit survived).
  await sendAndWait(
    () => walletClient.writeContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "mint", args: [A.attacker, parseEther("1900")] }),
    "mint to attacker",
  );
  await sendAndWait(
    () => walletClient.writeContract({ address: A.attacker, abi: ATTACKER_ABI, functionName: "approve", args: [A.mweth, A.unguardedVault, parseEther("900")] }),
    "attacker approve unguarded vault",
  );
  await sendAndWait(
    () => walletClient.writeContract({ address: A.attacker, abi: ATTACKER_ABI, functionName: "approve", args: [A.mweth, A.unguardedPool, parseEther("1000")] }),
    "attacker approve unguarded pool",
  );
  await sendAndWait(
    () =>
      walletClient.writeContract({
        address: A.attacker,
        abi: ATTACKER_ABI,
        functionName: "drainVault",
        args: [A.unguardedVault, parseEther("900"), parseEther("10"), 0n],
      }),
    "attacker deposit 900 into unguarded vault",
  );

  // 1-2. Demo policies.
  const p0 = await publicClient.readContract({ address: A.guard, abi: ARB_GUARD_ABI, functionName: "getPolicy", args: [0n] });
  check(
    "getPolicy(0) = demo vault policy",
    p0.maxOutflowPerBlock === parseEther("100") &&
      p0.maxSingleShareBps === 5000 &&
      p0.maxPriceDeviationBps === 500 &&
      p0.cooldownSeconds === 3600 &&
      p0.keeper.toLowerCase() === account.address.toLowerCase() &&
      p0.enabled === true,
    `maxOutflow=${fmt(p0.maxOutflowPerBlock)} shareBps=${p0.maxSingleShareBps} keeper=${p0.keeper}`,
  );
  const p1 = await publicClient.readContract({ address: A.guard, abi: ARB_GUARD_ABI, functionName: "getPolicy", args: [1n] });
  check(
    "getPolicy(1) = demo pool policy",
    p1.maxOutflowPerBlock === parseEther("10000") &&
      p1.maxSingleShareBps === 10000 &&
      p1.maxPriceDeviationBps === 500 &&
      p1.enabled === true,
    `maxOutflow=${fmt(p1.maxOutflowPerBlock)} devBps=${p1.maxPriceDeviationBps}`,
  );

  // 3. simulateCheck: drain 900 mWETH on the guarded vault.
  const vaultTvl = await publicClient.readContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [A.guardedVault] });
  const [okDrain, reasonDrain] = await publicClient.readContract({
    address: A.guard,
    abi: ARB_GUARD_ABI,
    functionName: "simulateCheck",
    args: [A.guardedVault, { kind: 0, token: A.mweth, amountOut: parseEther("900"), amountIn: 0n, price: 0n, twapPrice: 0n, tvl: vaultTvl }],
  });
  check("simulateCheck drain 900 on guarded vault -> (false, OUTFLOW_PER_BLOCK)", okDrain === false && reasonDrain === 1, `ok=${okDrain} reason=${reasonDrain} tvl=${fmt(vaultTvl)}`);

  // 4. simulateCheck: swap 1000 mWETH on the guarded pool (same Action the pool builds).
  const [amountOut, twap, reserveOut] = await Promise.all([
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "getAmountOut", args: [A.mweth, parseEther("1000")] }),
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "lastPrice01", args: [] }),
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
  ]);
  const price = (amountOut * 10n ** 18n) / parseEther("1000");
  const [okSwap, reasonSwap] = await publicClient.readContract({
    address: A.guard,
    abi: ARB_GUARD_ABI,
    functionName: "simulateCheck",
    args: [A.guardedPool, { kind: 2, token: A.musdc, amountOut, amountIn: parseEther("1000"), price, twapPrice: twap, tvl: reserveOut }],
  });
  check("simulateCheck swap 1000 on guarded pool -> (false, PRICE_DEVIATION)", okSwap === false && reasonSwap === 3, `ok=${okSwap} reason=${reasonSwap} amountOut=${fmt(amountOut)} price=${fmt(price)} twap=${fmt(twap)}`);

  // 5. Normal guarded withdraw passes (and emits CheckPassed for the getLogs check).
  const normal = await sendAndWait(
    () => walletClient.writeContract({ address: A.guardedVault, abi: VAULT_ABI, functionName: "withdraw", args: [parseEther("1")] }),
    "deployer withdraw 1 mWETH from guarded vault",
  );
  check("normal withdraw 1 mWETH from guarded vault succeeds", normal.status === "success", `block ${normal.blockNumber}`);

  // 6. drainOnly on the UNGUARDED vault succeeds, balance drops by 900.
  const unguardedBefore = await publicClient.readContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [A.unguardedVault] });
  const drainU = await sendAndWait(
    () => walletClient.writeContract({ address: A.attacker, abi: ATTACKER_ABI, functionName: "drainOnly", args: [A.unguardedVault, parseEther("10"), 200n] }),
    "drainOnly unguarded vault",
  );
  const unguardedAfter = await publicClient.readContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [A.unguardedVault] });
  check(
    "drainOnly on unguarded vault succeeds, balance drops 900",
    drainU.status === "success" && unguardedBefore - unguardedAfter === parseEther("900"),
    `before=${fmt(unguardedBefore)} after=${fmt(unguardedAfter)}`,
  );

  // 7. drainOnly on the GUARDED vault reverts ArbGuardViolation(1), balance unchanged.
  // Explicit gas so the reverting tx is broadcast (estimation would refuse it).
  const guardedBefore = await publicClient.readContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [A.guardedVault] });
  const drainGHash = await walletClient.writeContract({
    address: A.attacker, abi: ATTACKER_ABI, functionName: "drainOnly",
    args: [A.guardedVault, parseEther("10"), 200n], gas: 3_000_000n,
  });
  const drainG = await publicClient.waitForTransactionReceipt({ hash: drainGHash });
  const guardedAfter = await publicClient.readContract({ address: A.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [A.guardedVault] });
  let reasonG = null;
  try {
    await publicClient.call({
      account,
      to: A.attacker,
      data: encodeFunctionData({ abi: ATTACKER_ABI, functionName: "drainOnly", args: [A.guardedVault, parseEther("10"), 200n] }),
    });
  } catch (err) {
    reasonG = decodeViolation(err);
  }
  check(
    "drainOnly on guarded vault reverts ArbGuardViolation(1), balance unchanged",
    drainG.status === "reverted" && reasonG === 1 && guardedAfter === guardedBefore,
    `status=${drainG.status} reason=${reasonG} before=${fmt(guardedBefore)} after=${fmt(guardedAfter)}`,
  );

  // 8. pushPriceAndSwap on the UNGUARDED pool succeeds, reserves move.
  const [uR0Before, uR1Before] = await Promise.all([
    publicClient.readContract({ address: A.unguardedPool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
    publicClient.readContract({ address: A.unguardedPool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
  ]);
  const pushU = await sendAndWait(
    () => walletClient.writeContract({ address: A.attacker, abi: ATTACKER_ABI, functionName: "pushPriceAndSwap", args: [A.unguardedPool, A.mweth, parseEther("1000")] }),
    "pushPriceAndSwap unguarded pool",
  );
  const [uR0After, uR1After] = await Promise.all([
    publicClient.readContract({ address: A.unguardedPool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
    publicClient.readContract({ address: A.unguardedPool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
  ]);
  check(
    "pushPriceAndSwap on unguarded pool succeeds, reserves move",
    pushU.status === "success" && uR0After === uR0Before + parseEther("1000") && uR1After < uR1Before,
    `before=${fmt(uR0Before)}/${fmt(uR1Before)} after=${fmt(uR0After)}/${fmt(uR1After)}`,
  );

  // 9. pushPriceAndSwap on the GUARDED pool reverts (3), reserves unchanged.
  const [gR0Before, gR1Before] = await Promise.all([
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
  ]);
  const pushGHash = await walletClient.writeContract({
    address: A.attacker, abi: ATTACKER_ABI, functionName: "pushPriceAndSwap",
    args: [A.guardedPool, A.mweth, parseEther("1000")], gas: 1_000_000n,
  });
  const pushG = await publicClient.waitForTransactionReceipt({ hash: pushGHash });
  const [gR0After, gR1After] = await Promise.all([
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
    publicClient.readContract({ address: A.guardedPool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
  ]);
  let reasonP = null;
  try {
    await publicClient.call({
      account,
      to: A.attacker,
      data: encodeFunctionData({ abi: ATTACKER_ABI, functionName: "pushPriceAndSwap", args: [A.guardedPool, A.mweth, parseEther("1000")] }),
    });
  } catch (err) {
    reasonP = decodeViolation(err);
  }
  check(
    "pushPriceAndSwap on guarded pool reverts (3), reserves unchanged",
    pushG.status === "reverted" && reasonP === 3 && gR0After === gR0Before && gR1After === gR1Before,
    `status=${pushG.status} reason=${reasonP} reserves=${fmt(gR0After)}/${fmt(gR1After)}`,
  );

  // 10. getLogs (the feed's exact call) returns PolicyRegistered + CheckPassed.
  // Note: viem 2.30's getLogs only accepts `abi` together with `event`/
  // `events`, and with `abi` alone it returns raw, undecodable logs —
  // decode with parseEventLogs, exactly as the feed component does.
  const rawLogs = await publicClient.getLogs({ address: A.guard, fromBlock: DEPLOY_BLOCK });
  const logs = parseEventLogs({ abi: ARB_GUARD_ABI, logs: rawLogs, strict: false });
  const names = logs.map((l) => l.eventName);
  const nRegistered = names.filter((n) => n === "PolicyRegistered").length;
  const nPassed = names.filter((n) => n === "CheckPassed").length;
  check(
    "getLogs returns PolicyRegistered + CheckPassed events",
    nRegistered >= 2 && nPassed >= 1,
    `total=${logs.length} PolicyRegistered=${nRegistered} CheckPassed=${nPassed}`,
  );

  const failed = results.filter((r) => !r.ok);
  console.log(`\n== ${results.length - failed.length}/${results.length} assertions passed ==`);
  if (failed.length > 0) {
    console.log("FAILED:");
    for (const f of failed) console.log(`  - ${f.name}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("E2E crashed:", err);
  process.exit(1);
});
