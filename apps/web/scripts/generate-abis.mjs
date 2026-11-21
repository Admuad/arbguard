// Regenerates apps/web/lib/contracts.ts from the compiled Foundry artifacts.
// Canonical source: contracts/out/*.sol/*.json (relative to repo root)
// Run:  cd contracts && forge build && cd ../apps/web && node scripts/generate-abis.mjs
// Do NOT hand-edit the generated ABIs in lib/contracts.ts — re-run this script.
//
// ADDRESSES ARE ENV-DRIVEN (not baked in): the generated file reads every
// contract address from the NEXT_PUBLIC_* env vars (see .env.example) and
// falls back to the zero address when one is unset. `isDeployed` is true
// only when all seven live-path addresses are set and non-zero. The ABIs
// below are the only baked-in part; they come from the compiled artifacts.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webDir = join(here, "..");
const outDir = join(webDir, "..", "..", "contracts", "out");

function abiOf(contractFile, contractName) {
  const p = join(outDir, contractFile, `${contractName}.json`);
  const json = JSON.parse(readFileSync(p, "utf8"));
  return json.abi;
}

const arbGuard = abiOf("ArbGuard.sol", "ArbGuard");
const vault = abiOf("GuardedVault.sol", "GuardedVault");
const pool = abiOf("GuardedPool.sol", "GuardedPool");
const attacker = abiOf("Attacker.sol", "Attacker");
const token = abiOf("MockERC20.sol", "MockERC20");

const ts = `/**
 * Contract addresses + ABIs for ArbGuard.
 *
 * GENERATED — do not hand-edit. Regenerate with:
 *   cd contracts && forge build && cd ../apps/web && node scripts/generate-abis.mjs
 * Source of truth for the ABIs: the compiled Foundry artifacts in contracts/out/.
 *
 * ADDRESSES ARE ENV-DRIVEN: every address below is read from its
 * NEXT_PUBLIC_* env var (see apps/web/.env.example) and falls back to the
 * zero address when unset. For a local demo, run
 *   node apps/web/scripts/write-local-env.mjs
 * after the AnvilDemo broadcast — it writes apps/web/.env.local with the
 * deployed addresses. For Sepolia, fill in the deployed addresses the
 * same way. \`isDeployed\` is true only when all seven live-path
 * addresses (arbGuard, guardedVault, unguardedVault, guardedPool,
 * attacker, mweth, musdc) are set and non-zero, and the UI gates all
 * live calls behind it.
 *
 * NOTE (design decision, see contracts/src/ArbGuard.sol): there is NO
 * ViolationBlocked event — a reverted tx leaves no persistent event.
 * Blocked attempts surface via the ArbGuardViolation revert reason and
 * via simulateCheck(). The events below are the real ones.
 */
import type { Abi } from "viem";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

/** Read an address env var; anything missing/malformed becomes the zero address. */
function envAddress(value: string | undefined): \`0x\${string}\` {
  return value && /^0x[a-fA-F0-9]{40}$/.test(value)
    ? (value as \`0x\${string}\`)
    : ZERO_ADDRESS;
}

export const CONTRACT_ADDRESSES = {
  arbGuard: envAddress(process.env.NEXT_PUBLIC_ARB_GUARD_ADDRESS),
  guardedVault: envAddress(process.env.NEXT_PUBLIC_GUARDED_VAULT_ADDRESS),
  unguardedVault: envAddress(process.env.NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS),
  guardedPool: envAddress(process.env.NEXT_PUBLIC_GUARDED_POOL_ADDRESS),
  unguardedPool: envAddress(process.env.NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS),
  attacker: envAddress(process.env.NEXT_PUBLIC_ATTACKER_ADDRESS),
  mweth: envAddress(process.env.NEXT_PUBLIC_MWETH_ADDRESS),
  musdc: envAddress(process.env.NEXT_PUBLIC_MUSDC_ADDRESS),
  arbGuardChecker: ZERO_ADDRESS, // TBD — Stylus checker (no env var yet)
} as const;

/** Chain id from NEXT_PUBLIC_CHAIN_ID (31337 local Anvil | 421614 Sepolia | 42161 One). */
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 31337);

/** RPC URL for the localhost transport (default Anvil http://127.0.0.1:8545). */
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545";

/**
 * First block to scan for ArbGuard events (NEXT_PUBLIC_DEPLOY_BLOCK).
 * A decimal block number, or "earliest" when unset/invalid.
 */
export const DEPLOY_FROM_BLOCK: bigint | "earliest" =
  process.env.NEXT_PUBLIC_DEPLOY_BLOCK && /^\\d+$/.test(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
    ? BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
    : "earliest";

/** True only when every address the live paths need is set and non-zero. */
export const isDeployed =
  CONTRACT_ADDRESSES.arbGuard !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.guardedVault !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.unguardedVault !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.guardedPool !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.attacker !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.mweth !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.musdc !== ZERO_ADDRESS;

/** ArbGuard Reason enum (contracts/src/ArbGuard.sol): NONE=0 .. RESERVE_DRAIN=12. */
export const REASON_NAMES = [
  "NONE",
  "OUTFLOW_PER_BLOCK",
  "OUTFLOW_PER_HOUR",
  "OUTFLOW_PER_DAY",
  "SINGLE_SHARE",
  "PRICE_DEVIATION",
  "BREAKER_TRIPPED",
  "ORACLE_STALE",
  "ORACLE_DISAGREEMENT",
  "ORACLE_UNAVAILABLE",
  "SEQUENCER_DOWN",
  "HEALTH_FACTOR",
  "RESERVE_DRAIN",
] as const;

/** ActionKind enum (contracts/src/ArbGuard.sol): WITHDRAW=0, MINT=1, SWAP=2, BORROW=3. */
export const ACTION_KIND_NAMES = ["WITHDRAW", "MINT", "SWAP", "BORROW"] as const;

/** localStorage key + window event for blocked attempts recorded this session. */
export const BLOCKED_ATTEMPTS_KEY = "arbguard:blocked-attempts";
export const BLOCKED_ATTEMPT_EVENT = "arbguard:blocked-attempt";

export type BlockedAttempt = {
  ts: number;
  attack: string;
  target: string;
  reason: string;
  txHash?: string;
};

export const ARB_GUARD_ABI = ${JSON.stringify(arbGuard, null, 2)} as const satisfies Abi;

export const VAULT_ABI = ${JSON.stringify(vault, null, 2)} as const satisfies Abi;

export const POOL_ABI = ${JSON.stringify(pool, null, 2)} as const satisfies Abi;

export const ATTACKER_ABI = ${JSON.stringify(attacker, null, 2)} as const satisfies Abi;

export const TOKEN_ABI = ${JSON.stringify(token, null, 2)} as const satisfies Abi;
`;

writeFileSync(join(webDir, "lib", "contracts.ts"), ts);
console.log("Wrote lib/contracts.ts");
console.log(`  ARB_GUARD_ABI entries: ${arbGuard.length}`);
console.log(`  VAULT_ABI entries: ${vault.length}`);
console.log(`  POOL_ABI entries: ${pool.length}`);
console.log(`  ATTACKER_ABI entries: ${attacker.length}`);
console.log(`  TOKEN_ABI entries: ${token.length}`);
