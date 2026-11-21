/**
 * config.ts — env parsing + validation (PHASE3-SPEC.md §1.3).
 * Fails fast: any invalid value exits non-zero with the offending
 * variable named. No secret is ever logged.
 */
import { isAddress } from 'viem';

export interface KeeperConfig {
  rpcUrl: string;
  guardAddress: `0x${string}`;
  chainId: number;
  /** Undefined in dry-run when no key is configured (read-only dry-run). */
  privateKey?: `0x${string}`;
  policyIds: number[];
  /** Deploy block for event scans; 'earliest' when unset. */
  deployBlock: bigint | 'earliest';
  pollSeconds: number;
  dryRun: boolean;
  allowTrip: boolean;
  throttleSeconds: number;
  hourUsePct: number;
  dayUsePct: number;
  largePassPct: number;
  /** 0 = T4 disabled (Sepolia). Otherwise 1–10. */
  oracleFailPolls: number;
  /** One-shot manual trip (R3). Undefined when not set. */
  tripOnce?: number;
  logFile: string;
  // Context addresses (optional; balances are context only, never triggers).
  mwethAddress?: `0x${string}`;
  musdcAddress?: `0x${string}`;
  guardedVaultAddress?: `0x${string}`;
  unguardedVaultAddress?: `0x${string}`;
  guardedPoolAddress?: `0x${string}`;
  unguardedPoolAddress?: `0x${string}`;
}

function fail(variable: string, message: string): never {
  throw new Error(`config error: ${variable}: ${message}`);
}

function required(name: string): string {
  const v = process.env[name];
  if (v === undefined || v.trim() === '') fail(name, 'is required but not set');
  return v.trim();
}

function optionalAddress(name: string): `0x${string}` | undefined {
  const v = process.env[name];
  if (v === undefined || v.trim() === '') return undefined;
  if (!isAddress(v.trim())) fail(name, `not a valid address: ${v.trim()}`);
  return v.trim() as `0x${string}`;
}

function intInRange(name: string, def: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return def;
  const n = Number(raw.trim());
  if (!Number.isInteger(n)) fail(name, `not an integer: ${raw}`);
  if (n < min || n > max) fail(name, `out of range ${min}..${max}: ${n}`);
  return n;
}

function boolWithDefault(name: string, def: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return def;
  const v = raw.trim().toLowerCase();
  if (v === 'true') return true;
  if (v === 'false') return false;
  fail(name, `not a boolean (true/false): ${raw}`);
  return def; // unreachable; keeps TS happy
}

/** Parse + validate the environment. Throws on the first problem. */
export function loadConfig(): KeeperConfig {
  const rpcUrl = required('KEEPER_RPC_URL');
  const guardRaw = required('KEEPER_GUARD_ADDRESS');
  if (!isAddress(guardRaw)) fail('KEEPER_GUARD_ADDRESS', `not a valid address: ${guardRaw}`);
  const guardAddress = guardRaw as `0x${string}`;

  const chainId = intInRange('KEEPER_CHAIN_ID', 421614, 1, Number.MAX_SAFE_INTEGER);

  const dryRun = boolWithDefault('KEEPER_DRY_RUN', true);
  const allowTrip = boolWithDefault('KEEPER_ALLOW_TRIP', false);

  // KEEPER_PRIVATE_KEY: required in live mode, optional in dry-run.
  let privateKey: `0x${string}` | undefined;
  const keyRaw = process.env.KEEPER_PRIVATE_KEY;
  if (keyRaw !== undefined && keyRaw.trim() !== '') {
    const k = keyRaw.trim();
    if (!/^0x[0-9a-fA-F]{64}$/.test(k)) {
      fail('KEEPER_PRIVATE_KEY', 'must be a 0x-prefixed 32-byte hex key');
    }
    privateKey = k as `0x${string}`;
  } else if (!dryRun) {
    fail('KEEPER_PRIVATE_KEY', 'is required in live mode (KEEPER_DRY_RUN=false)');
  }

  const policyIdsRaw = process.env.KEEPER_POLICY_IDS ?? '0,1';
  const policyIds = policyIdsRaw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '')
    .map((s) => {
      const n = Number(s);
      if (!Number.isInteger(n) || n < 0) fail('KEEPER_POLICY_IDS', `not a non-negative integer: ${s}`);
      return n;
    });
  if (policyIds.length === 0) fail('KEEPER_POLICY_IDS', 'must list at least one policy id');
  if (new Set(policyIds).size !== policyIds.length) {
    fail('KEEPER_POLICY_IDS', 'contains a duplicate policy id');
  }

  let deployBlock: bigint | 'earliest' = 'earliest';
  const deployRaw = process.env.KEEPER_DEPLOY_BLOCK;
  if (deployRaw !== undefined && deployRaw.trim() !== '' && deployRaw.trim() !== 'earliest') {
    let n: bigint;
    try {
      n = BigInt(deployRaw.trim());
    } catch {
      fail('KEEPER_DEPLOY_BLOCK', `not a block number: ${deployRaw}`);
      n = 0n; // unreachable
    }
    if (n < 0n) fail('KEEPER_DEPLOY_BLOCK', `not a block number: ${deployRaw}`);
    deployBlock = n;
  }

  const pollSeconds = intInRange('KEEPER_POLL_SECONDS', 30, 10, 300);
  const throttleSeconds = intInRange('KEEPER_THROTTLE_SECONDS', 86400, 3600, 604800);
  const hourUsePct = intInRange('KEEPER_HOUR_USE_PCT', 80, 50, 95);
  const dayUsePct = intInRange('KEEPER_DAY_USE_PCT', 80, 50, 95);
  const largePassPct = intInRange('KEEPER_LARGE_PASS_PCT', 50, 25, 90);
  // T4: 1–10, or 0 to disable (Sepolia note in §1.4 — the only
  // out-of-range value the config accepts for this variable).
  const oracleFailPollsRaw = process.env.KEEPER_ORACLE_FAIL_POLLS;
  let oracleFailPolls = 3;
  if (oracleFailPollsRaw !== undefined && oracleFailPollsRaw.trim() !== '') {
    const n = Number(oracleFailPollsRaw.trim());
    if (!Number.isInteger(n) || (n !== 0 && (n < 1 || n > 10))) {
      fail('KEEPER_ORACLE_FAIL_POLLS', `out of range 1..10 or 0 to disable: ${oracleFailPollsRaw}`);
    }
    oracleFailPolls = n;
  }

  let tripOnce: number | undefined;
  const tripRaw = process.env.KEEPER_TRIP_ONCE;
  if (tripRaw !== undefined && tripRaw.trim() !== '') {
    const n = Number(tripRaw.trim());
    if (!Number.isInteger(n) || n < 0) fail('KEEPER_TRIP_ONCE', `not a non-negative integer: ${tripRaw}`);
    if (!policyIds.includes(n)) {
      fail('KEEPER_TRIP_ONCE', `policy ${n} is not in KEEPER_POLICY_IDS (${policyIds.join(',')})`);
    }
    tripOnce = n;
  }

  const logFile = (process.env.KEEPER_LOG_FILE ?? 'decisions.log').trim() || 'decisions.log';

  return {
    rpcUrl,
    guardAddress,
    chainId,
    privateKey,
    policyIds,
    deployBlock,
    pollSeconds,
    dryRun,
    allowTrip,
    throttleSeconds,
    hourUsePct,
    dayUsePct,
    largePassPct,
    oracleFailPolls: oracleFailPolls,
    tripOnce,
    logFile,
    mwethAddress: optionalAddress('KEEPER_MWETH_ADDRESS'),
    musdcAddress: optionalAddress('KEEPER_MUSDC_ADDRESS'),
    guardedVaultAddress: optionalAddress('KEEPER_GUARDED_VAULT_ADDRESS'),
    unguardedVaultAddress: optionalAddress('KEEPER_UNGUARDED_VAULT_ADDRESS'),
    guardedPoolAddress: optionalAddress('KEEPER_GUARDED_POOL_ADDRESS'),
    unguardedPoolAddress: optionalAddress('KEEPER_UNGUARDED_POOL_ADDRESS'),
  };
}

/** The startup config line: full non-secret config, for the log (§1.6). */
export function publicConfig(config: KeeperConfig): Record<string, unknown> {
  return {
    guard: config.guardAddress,
    chainId: config.chainId,
    policyIds: config.policyIds,
    deployBlock: config.deployBlock === 'earliest' ? 'earliest' : config.deployBlock.toString(),
    pollSeconds: config.pollSeconds,
    dryRun: config.dryRun,
    allowTrip: config.allowTrip,
    throttleSeconds: config.throttleSeconds,
    hourUsePct: config.hourUsePct,
    dayUsePct: config.dayUsePct,
    largePassPct: config.largePassPct,
    oracleFailPolls: config.oracleFailPolls,
    tripOnce: config.tripOnce ?? null,
    logFile: config.logFile,
    keeperKeyConfigured: config.privateKey !== undefined,
  };
}
