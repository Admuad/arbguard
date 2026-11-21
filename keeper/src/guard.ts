/**
 * guard.ts — viem reads against ArbGuard (PHASE3-SPEC.md §1.4).
 *
 * One batched read per policy per poll cycle (viem `multicall`), one
 * batched balance read per cycle, one `getLogs` call per cycle (chunked,
 * see events.ts). No subscriptions. All reads are `allowFailure: true`
 * so one reverting call cannot poison the batch; a failed core read
 * makes the policy SKIP_PARTIAL_STATE instead of acting on partial data.
 *
 * Minimal ABI: only the functions and events the bot needs, copied from
 * contracts/src/ArbGuard.sol. The bot never calls check() as a
 * transaction, never moves funds, never updates a policy, never manages
 * keepers.
 */
import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  parseAbi,
  parseAbiItem,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { KeeperConfig } from './config.js';

// ---------------------------------------------------------------- ABI
export const GUARD_ABI = parseAbi([
  // getPolicy: the live Sepolia guard is the PHASE 1 contract (verified
  // 20 Nov 2026: getPolicy returns 288 bytes = 9 words), deployed before
  // Phase 2 added usdDenominated / minHealthFactorBps /
  // maxReserveDrainBps. The first 9 fields are identical in both
  // phases, so this 9-field tuple decodes on either deployment; the
  // Phase 2 tail is detected separately (detectPolicyLayout) and is not
  // needed by any trigger rule.
  'function getPolicy(uint256 policyId) view returns ((uint256 maxOutflowPerBlock, uint256 maxOutflowPerHour, uint256 maxOutflowPerDay, uint16 maxSingleShareBps, uint16 maxPriceDeviationBps, uint16 throttleBps, uint32 cooldownSeconds, uint32 policyTimelockSeconds, bool enabled) policy)',
  'function getMode(uint256 policyId) view returns (uint8)',
  'function getKeepers(uint256 policyId) view returns (address[])',
  'function getPriceConfig(uint256 policyId) view returns ((uint32 twapSeconds, uint16 maxOracleDeviationBps, uint32 chainlinkStaleAfter, address sequencerFeed) priceConfig)',
  'function getReferencePrice(uint256 policyId, address tokenIn, address tokenOut) view returns (uint256 price1e18, address source)',
  'function getProtocol(uint256 policyId) view returns (address)',
  'function outflowInBlock(uint256 policyId) view returns (uint256)',
  'function outflowBlock(uint256 policyId) view returns (uint256)',
  'function outflowInHour(uint256 policyId) view returns (uint256)',
  'function outflowHour(uint256 policyId) view returns (uint256)',
  'function outflowInDay(uint256 policyId) view returns (uint256)',
  'function outflowDay(uint256 policyId) view returns (uint256)',
  'function pausedUntil(uint256 policyId) view returns (uint256)',
  'function throttleUntil(uint256 policyId) view returns (uint256)',
  'function throttle(uint256 policyId, uint32 durationSeconds, bytes evidence)',
  'function trip(uint256 policyId, bytes evidence)',
  // NOTE: simulateCheck is NOT in this ABI — its Action layout differs
  // between Phase 1 (7 fields) and Phase 2 (9 fields); the R2 probe
  // uses the versioned SIMULATE_V1_ABI / SIMULATE_V2_ABI instead.
  'error ArbGuardViolation(uint8 reason)',
  'event PolicyRegistered(uint256 indexed policyId, address indexed protocol)',
  'event PolicyUpdateProposed(uint256 indexed policyId, uint256 executableAt)',
  'event PolicyUpdateExecuted(uint256 indexed policyId)',
  'event KeeperAdded(uint256 indexed policyId, address indexed keeper)',
  'event KeeperRemoved(uint256 indexed policyId, address indexed keeper)',
  'event ThrottleSet(uint256 indexed policyId, address indexed tripper, uint256 throttleUntil)',
  'event ThrottleCleared(uint256 indexed policyId)',
  'event CheckPassed(uint256 indexed policyId, address indexed protocol, uint8 kind, address token, uint256 amountOut)',
  'event BreakerTripped(uint256 indexed policyId, address indexed tripper, uint256 pausedUntil, bytes evidence)',
  'event BreakerReset(uint256 indexed policyId)',
  'event OracleConfigUpdateProposed(uint256 indexed policyId, address indexed token, uint256 executableAt)',
  'event OracleConfigUpdateExecuted(uint256 indexed policyId, address indexed token)',
]);

const ERC20_ABI = parseAbi(['function balanceOf(address account) view returns (uint256)']);

/**
 * simulateCheck Action layouts. Phase 1's Action has 7 fields; Phase 2
 * added healthFactorAfter + availableLiquidity (9 fields). The probe
 * must encode the layout the LIVE contract expects, or the call data
 * is misaligned — so the layout detected at startup picks the ABI.
 */
const SIMULATE_V1_ABI = parseAbi([
  'function simulateCheck(address protocol, (uint8 kind, address token, address tokenIn, uint256 amountOut, uint256 amountIn, uint256 price, uint256 tvl) action) view returns (bool ok, uint8 reason)',
]);
const SIMULATE_V2_ABI = parseAbi([
  'function simulateCheck(address protocol, (uint8 kind, address token, address tokenIn, uint256 amountOut, uint256 amountIn, uint256 price, uint256 tvl, uint256 healthFactorAfter, uint256 availableLiquidity) action) view returns (bool ok, uint8 reason)',
]);

/** Which contract generation the live guard is (detected, not assumed). */
export type ContractVersion = 1 | 2;

/**
 * Detect the live guard's Policy layout from the raw getPolicy return
 * length: 288 bytes (9 words) = Phase 1, 384 bytes (12 words) = Phase 2.
 * Throws on any other length — a guard that answers getPolicy in an
 * unknown shape is not a guard this bot understands.
 */
export async function detectPolicyLayout(
  publicClient: PublicClient,
  guard: Address,
): Promise<ContractVersion> {
  const data = encodeFunctionData({
    abi: parseAbi(['function getPolicy(uint256 policyId) view returns (uint256)']),
    functionName: 'getPolicy',
    args: [0n],
  });
  const { data: raw } = await publicClient.call({ to: guard, data });
  if (!raw) throw new Error('getPolicy returned no data');
  const bytes = (raw.length - 2) / 2;
  if (bytes === 288) return 1;
  if (bytes === 384) return 2;
  throw new Error(`getPolicy returned ${bytes} bytes (expected 288 for Phase 1 or 384 for Phase 2)`);
}

/** Reason enum order (ArbGuard.sol). Index 8 = ORACLE_DISAGREEMENT. */
export const REASON_NAMES = [
  'NONE',
  'OUTFLOW_PER_BLOCK',
  'OUTFLOW_PER_HOUR',
  'OUTFLOW_PER_DAY',
  'SINGLE_SHARE',
  'PRICE_DEVIATION',
  'BREAKER_TRIPPED',
  'ORACLE_STALE',
  'ORACLE_DISAGREEMENT',
  'ORACLE_UNAVAILABLE',
  'SEQUENCER_DOWN',
  'HEALTH_FACTOR',
  'RESERVE_DRAIN',
] as const;

export const MODE_NAMES = ['NORMAL', 'THROTTLED', 'PAUSED'] as const;

// ---------------------------------------------------------------- types
export interface PolicyState {
  policyId: number;
  protocol: Address;
  mode: (typeof MODE_NAMES)[number];
  enabled: boolean;
  throttleUntil: bigint;
  pausedUntil: bigint;
  maxOutflowPerBlock: bigint;
  maxOutflowPerHour: bigint;
  maxOutflowPerDay: bigint;
  outflowInBlock: bigint;
  outflowBlock: bigint;
  outflowInHour: bigint;
  outflowHour: bigint;
  outflowInDay: bigint;
  outflowDay: bigint;
  keepers: Address[];
  /** True when any required read failed: caller must SKIP_PARTIAL_STATE. */
  partial: boolean;
  partialReason: string | null;
}

export type OracleProbe =
  | { status: 'ok'; price: bigint; source: Address }
  | { status: 'unusable'; detail: string }
  | { status: 'reverted'; reasonName: string | null; detail: string }
  | { status: 'skipped'; detail: string };

export interface BalanceContext {
  guardedVaultWeth: bigint | null;
  unguardedVaultWeth: bigint | null;
  guardedPoolWeth: bigint | null;
  guardedPoolUsdc: bigint | null;
  unguardedPoolWeth: bigint | null;
  unguardedPoolUsdc: bigint | null;
}

// ---------------------------------------------------------------- clients
export interface GuardClients {
  publicClient: PublicClient;
  walletClient: WalletClient<Transport, Chain, Account> | null;
  keeperAddress: Address | null;
}

export function chainFor(config: KeeperConfig): Chain {
  // Minimal chain object: the bot only needs id + rpc URL. No hard-coded
  // chain metadata beyond what the operator configured — except the
  // canonical Multicall3 address, which viem needs to batch reads and
  // which is the same on every EVM chain (deployed by the Multicall3
  // project, not by us). Without it viem refuses multicall entirely.
  return {
    id: config.chainId,
    name: config.chainId === 421614 ? 'Arbitrum Sepolia' : `chain-${config.chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } },
    contracts: {
      multicall3: {
        address: '0xcA11bde05977b3631167028862bE2a173976CA11',
        blockCreated: 0,
      },
    },
  } as Chain;
}

export function createClients(config: KeeperConfig): GuardClients {
  const chain = chainFor(config);
  const publicClient = createPublicClient({ chain, transport: http(config.rpcUrl) });
  if (!config.privateKey) return { publicClient, walletClient: null, keeperAddress: null };
  const account = privateKeyToAccount(config.privateKey);
  const walletClient = createWalletClient({ account, chain, transport: http(config.rpcUrl) });
  return { publicClient, walletClient, keeperAddress: account.address };
}

// ---------------------------------------------------------------- reads
/** One batched read, with the same {status, result} shape either way. */
export type BatchedRead =
  | { status: 'success'; result: unknown }
  | { status: 'failure'; error: Error };

/**
 * Batch reads via Multicall3, falling back to parallel individual calls
 * when the chain has no Multicall3 (a fresh Anvil has no code at the
 * canonical address; real chains do). The fallback keeps the same
 * allowFailure semantics per call. Either way the per-cycle request
 * count stays ~1/second, inside the §1.5 rate discipline.
 */
export async function batchedReads(
  publicClient: PublicClient,
  contracts: Array<{
    address: Address;
    abi: unknown;
    functionName: string;
    args?: readonly unknown[];
  }>,
): Promise<BatchedRead[]> {
  try {
    // viem's multicall typing is generic over the contracts tuple; call
    // it through a loose alias so one helper serves every read shape.
    const multicall = publicClient.multicall as unknown as (args: {
      allowFailure: boolean;
      contracts: Array<{
        address: Address;
        abi: unknown;
        functionName: string;
        args?: readonly unknown[];
      }>;
    }) => Promise<
      Array<{ status: 'success'; result: unknown } | { status: 'failure'; error: Error }>
    >;
    const results = await multicall({ allowFailure: true, contracts });
    const mapped = results.map((r) =>
      r.status === 'success'
        ? { status: 'success' as const, result: r.result }
        : { status: 'failure' as const, error: r.error },
    );
    // viem does NOT throw when the Multicall3 contract itself is
    // missing (fresh Anvil has no code at the canonical address) — it
    // resolves every call as a failure. All-failed is the signal to
    // fall back to individual calls; a partially-failed batch is real
    // per-call data and is returned as-is.
    if (mapped.every((r) => r.status === 'failure')) {
      return individualReads(publicClient, contracts);
    }
    return mapped;
  } catch {
    return individualReads(publicClient, contracts);
  }
}

async function individualReads(
  publicClient: PublicClient,
  contracts: Array<{
    address: Address;
    abi: unknown;
    functionName: string;
    args?: readonly unknown[];
  }>,
): Promise<BatchedRead[]> {
  return Promise.all(
    contracts.map(async (c) => {
      try {
        const result = await publicClient.readContract(c as never);
        return { status: 'success' as const, result: result as unknown };
      } catch (err) {
        return { status: 'failure' as const, error: err as Error };
      }
    }),
  );
}
/**
 * One batched read per policy: policy, mode, keepers, protocol, outflow
 * windows, pause/throttle deadlines. The oracle probe is two separate
 * calls (mWETH->mUSDC and the reverse) because a reverting probe must
 * not fail the batch.
 */
export async function readPolicyState(
  publicClient: PublicClient,
  guard: Address,
  policyId: number,
): Promise<PolicyState> {
  const base = { address: guard, abi: GUARD_ABI } as const;
  const results = await batchedReads(publicClient, [
    { ...base, functionName: 'getPolicy', args: [BigInt(policyId)] },
    { ...base, functionName: 'getMode', args: [BigInt(policyId)] },
    { ...base, functionName: 'getKeepers', args: [BigInt(policyId)] },
    { ...base, functionName: 'getProtocol', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowInBlock', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowBlock', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowInHour', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowHour', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowInDay', args: [BigInt(policyId)] },
    { ...base, functionName: 'outflowDay', args: [BigInt(policyId)] },
    { ...base, functionName: 'pausedUntil', args: [BigInt(policyId)] },
    { ...base, functionName: 'throttleUntil', args: [BigInt(policyId)] },
  ]);

  const failed = results
    .map((r, i) => ({ r, i }))
    .filter(({ r }) => r.status === 'failure')
    .map(({ i }) => i);
  if (failed.length > 0) {
    return partialState(policyId, `multicall reads failed at indexes ${failed.join(',')}`);
  }

  const policy = (results[0] as unknown as { result: Record<string | number, unknown> }).result;

  // viem decodes a named tuple as an object keyed by component name
  // (numeric indices are NOT populated), so read by name with an
  // index fallback.
  const pick = (name: string, idx: number): unknown => policy[name] ?? policy[idx];
  const maxOutflowPerBlock = pick('maxOutflowPerBlock', 0) as bigint;
  const maxOutflowPerHour = pick('maxOutflowPerHour', 1) as bigint;
  const maxOutflowPerDay = pick('maxOutflowPerDay', 2) as bigint;
  const enabled = pick('enabled', 8) as boolean;
  const modeNum = (results[1] as { result: number }).result;
  const keepers = (results[2] as unknown as { result: Address[] }).result;
  const protocol = (results[3] as { result: Address }).result;
  const get = (i: number): bigint => (results[i] as { result: bigint }).result;

  return {
    policyId,
    protocol,
    mode: MODE_NAMES[modeNum] ?? 'NORMAL',
    enabled,
    throttleUntil: get(11),
    pausedUntil: get(10),
    maxOutflowPerBlock,
    maxOutflowPerHour,
    maxOutflowPerDay,
    outflowInBlock: get(4),
    outflowBlock: get(5),
    outflowInHour: get(6),
    outflowHour: get(7),
    outflowInDay: get(8),
    outflowDay: get(9),
    keepers,
    partial: false,
    partialReason: null,
  };
}

function partialState(policyId: number, reason: string): PolicyState {
  return {
    policyId,
    protocol: '0x0000000000000000000000000000000000000000',
    mode: 'NORMAL',
    enabled: false,
    throttleUntil: 0n,
    pausedUntil: 0n,
    maxOutflowPerBlock: 0n,
    maxOutflowPerHour: 0n,
    maxOutflowPerDay: 0n,
    outflowInBlock: 0n,
    outflowBlock: 0n,
    outflowInHour: 0n,
    outflowHour: 0n,
    outflowInDay: 0n,
    outflowDay: 0n,
    keepers: [],
    partial: true,
    partialReason: reason,
  };
}

/**
 * Oracle probe for the policy's swap pair (mWETH -> mUSDC and reverse).
 * A successful call that returns price 0 / source 0x0 is "unusable":
 * on live Sepolia the pair is incomplete (only mWETH has a feed, no
 * TWAP pool), so getReferencePrice returns (0, address(0)) WITHOUT
 * reverting — the price rule is skipped for the pair. That is the honest
 * Sepolia state, not an error; T4 treats it as a failed probe.
 */
export async function probeOracle(
  publicClient: PublicClient,
  guard: Address,
  policyId: number,
  tokenIn: Address | undefined,
  tokenOut: Address | undefined,
): Promise<OracleProbe> {
  if (!tokenIn || !tokenOut) {
    return { status: 'skipped', detail: 'token addresses not configured (KEEPER_MWETH_ADDRESS / KEEPER_MUSDC_ADDRESS)' };
  }
  for (const [tin, tout] of [
    [tokenIn, tokenOut],
    [tokenOut, tokenIn],
  ] as Array<[Address, Address]>) {
    try {
      const [price, source] = await publicClient.readContract({
        address: guard,
        abi: GUARD_ABI,
        functionName: 'getReferencePrice',
        args: [BigInt(policyId), tin, tout],
      });
      if (price === 0n || source === '0x0000000000000000000000000000000000000000') {
        return { status: 'unusable', detail: `getReferencePrice(${tin}->${tout}) returned price 0 / no source (pair has no usable oracle)` };
      }
      return { status: 'ok', price, source };
    } catch (err) {
      const reasonName = reasonNameFromError(err);
      return { status: 'reverted', reasonName, detail: errorText(err) };
    }
  }
  return { status: 'skipped', detail: 'unreachable' };
}

/** Extract the ArbGuardViolation reason name from a viem revert error, if present. */
export function reasonNameFromError(err: unknown): string | null {
  const text = errorText(err);
  const m = text.match(/ArbGuardViolation\((\d+)\)/);
  if (m) {
    const idx = Number(m[1]);
    return REASON_NAMES[idx] ?? `UNKNOWN(${idx})`;
  }
  for (const name of REASON_NAMES) {
    if (text.includes(name)) return name;
  }
  return null;
}

export function errorText(err: unknown): string {
  if (err instanceof Error) return err.message.slice(0, 500);
  return String(err).slice(0, 500);
}

/**
 * R2 probe (read-only): simulateCheck for a minimal 1-wei swap through
 * the policy's protocol, encoded in the LIVE contract's Action layout
 * (`version`). Returns true only when the probe returns
 * (false, ORACLE_DISAGREEMENT). Any other outcome — pass, another
 * reason, or a read error — is false: the probe is never acted on alone.
 */
export async function probeSwapDisagreement(
  publicClient: PublicClient,
  guard: Address,
  policyId: number,
  protocol: Address,
  tokenIn: Address,
  tokenOut: Address,
  version: ContractVersion,
): Promise<boolean> {
  try {
    if (version === 1) {
      const [ok, reason] = await publicClient.readContract({
        address: guard,
        abi: SIMULATE_V1_ABI,
        functionName: 'simulateCheck',
        args: [
          protocol,
          {
            kind: 2, // SWAP
            token: tokenOut,
            tokenIn,
            amountOut: 1n,
            amountIn: 1n,
            price: 10n ** 18n,
            tvl: 10_000n * 10n ** 18n,
          },
        ],
      });
      return !ok && REASON_NAMES[reason] === 'ORACLE_DISAGREEMENT';
    }
    const [ok, reason] = await publicClient.readContract({
      address: guard,
      abi: SIMULATE_V2_ABI,
      functionName: 'simulateCheck',
      args: [
        protocol,
        {
          kind: 2, // SWAP
          token: tokenOut,
          tokenIn,
          amountOut: 1n,
          amountIn: 1n,
          price: 10n ** 18n,
          tvl: 10_000n * 10n ** 18n,
          healthFactorAfter: 0n,
          availableLiquidity: 0n,
        },
      ],
    });
    return !ok && REASON_NAMES[reason] === 'ORACLE_DISAGREEMENT';
  } catch {
    return false;
  }
}

/** Context balances (one batched read per cycle; never trigger inputs). */
export async function readBalances(
  publicClient: PublicClient,
  config: KeeperConfig,
): Promise<BalanceContext> {
  const empty: BalanceContext = {
    guardedVaultWeth: null,
    unguardedVaultWeth: null,
    guardedPoolWeth: null,
    guardedPoolUsdc: null,
    unguardedPoolWeth: null,
    unguardedPoolUsdc: null,
  };
  const { mwethAddress, musdcAddress, guardedVaultAddress, unguardedVaultAddress, guardedPoolAddress, unguardedPoolAddress } = config;
  if (!mwethAddress) return empty;
  const calls: Array<{ token: Address; holder: Address; key: keyof BalanceContext }> = [];
  const add = (token: Address | undefined, holder: Address | undefined, key: keyof BalanceContext) => {
    if (token && holder) calls.push({ token, holder, key });
  };
  add(mwethAddress, guardedVaultAddress, 'guardedVaultWeth');
  add(mwethAddress, unguardedVaultAddress, 'unguardedVaultWeth');
  add(mwethAddress, guardedPoolAddress, 'guardedPoolWeth');
  add(musdcAddress, guardedPoolAddress, 'guardedPoolUsdc');
  add(mwethAddress, unguardedPoolAddress, 'unguardedPoolWeth');
  add(musdcAddress, unguardedPoolAddress, 'unguardedPoolUsdc');
  if (calls.length === 0) return empty;
  const results = await batchedReads(
    publicClient,
    calls.map((c) => ({
      address: c.token,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [c.holder],
    })),
  );
  const out: BalanceContext = { ...empty };
  calls.forEach((c, i) => {
    const r = results[i];
    if (r.status === 'success') out[c.key] = r.result as bigint;
  });
  return out;
}

/** Latest block number + timestamp (chain time for window checks). */
export async function getLatestBlock(publicClient: PublicClient): Promise<{ number: bigint; timestamp: number }> {
  const block = await publicClient.getBlock({ blockTag: 'latest' });
  return { number: block.number, timestamp: Number(block.timestamp) };
}

export { parseAbiItem };
export type { Hex };
