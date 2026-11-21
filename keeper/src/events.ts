/**
 * events.ts — getLogs polling (PHASE3-SPEC.md §1.2, §1.4).
 *
 * Polling, not subscriptions: one getLogs call per cycle with an
 * explicit block range, chunked (max 2000 blocks per call) so a long
 * first scan from the deploy block never exceeds the RPC's range limit.
 *
 * Only persistent events are read. A reverted check leaves NO event
 * on-chain, so there is nothing here that could observe a revert — by
 * construction the bot cannot trip on reverts (the never-rule, §1.4).
 */
import { parseEventLogs, type Address, type PublicClient } from 'viem';
import { GUARD_ABI } from './guard.js';

export interface CycleEvents {
  /** Largest CheckPassed amountOut this cycle (any kind), null when none. */
  largestPassAmountOut: bigint | null;
  checkPassedCount: number;
  breakerTripped: boolean;
  throttleSet: boolean;
  throttleCleared: boolean;
  breakerReset: boolean;
  /** A timelock proposal seen this cycle, with its executableAt. */
  proposalSeen: { executableAt: bigint } | null;
  /** Raw decoded event names seen (for the log line's reason text). */
  eventNames: string[];
}

/** Max blocks per getLogs call (public-RPC range discipline). */
export const LOG_CHUNK_BLOCKS = 2000n;

function emptyCycle(): CycleEvents {
  return {
    largestPassAmountOut: null,
    checkPassedCount: 0,
    breakerTripped: false,
    throttleSet: false,
    throttleCleared: false,
    breakerReset: false,
    proposalSeen: null,
    eventNames: [],
  };
}

/**
 * Scan guard logs from `fromBlock` (inclusive) to `toBlock` (inclusive),
 * split into per-policy buckets. `fromBlock` is normally
 * lastScannedBlock + 1; the first scan starts at KEEPER_DEPLOY_BLOCK.
 */
export async function scanEvents(
  publicClient: PublicClient,
  guard: Address,
  fromBlock: bigint,
  toBlock: bigint,
  policyIds: number[],
): Promise<Map<number, CycleEvents>> {
  const perPolicy = new Map<number, CycleEvents>();
  for (const id of policyIds) perPolicy.set(id, emptyCycle());
  if (toBlock < fromBlock) return perPolicy;

  for (let start = fromBlock; start <= toBlock; start += LOG_CHUNK_BLOCKS) {
    const end = start + LOG_CHUNK_BLOCKS - 1n > toBlock ? toBlock : start + LOG_CHUNK_BLOCKS - 1n;
    const logs = await publicClient.getLogs({ address: guard, fromBlock: start, toBlock: end });
    const parsed = parseEventLogs({ abi: GUARD_ABI, logs, strict: false });
    for (const log of parsed) {
      const args = log.args as unknown as Record<string, unknown>;
      const pid = typeof args.policyId === 'bigint' ? Number(args.policyId) : -1;
      if (!perPolicy.has(pid)) continue; // not a watched policy
      const bucket = perPolicy.get(pid) as CycleEvents;
      bucket.eventNames.push(log.eventName);
      switch (log.eventName) {
        case 'CheckPassed': {
          bucket.checkPassedCount += 1;
          const amountOut = args.amountOut as bigint;
          if (bucket.largestPassAmountOut === null || amountOut > bucket.largestPassAmountOut) {
            bucket.largestPassAmountOut = amountOut;
          }
          break;
        }
        case 'BreakerTripped':
          bucket.breakerTripped = true;
          break;
        case 'ThrottleSet':
          bucket.throttleSet = true;
          break;
        case 'ThrottleCleared':
          bucket.throttleCleared = true;
          break;
        case 'BreakerReset':
          bucket.breakerReset = true;
          break;
        case 'PolicyUpdateProposed':
        case 'OracleConfigUpdateProposed': {
          const executableAt = args.executableAt as bigint;
          if (bucket.proposalSeen === null || executableAt > bucket.proposalSeen.executableAt) {
            bucket.proposalSeen = { executableAt };
          }
          break;
        }
        default:
          break;
      }
    }
  }
  return perPolicy;
}
