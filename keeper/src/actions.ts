/**
 * actions.ts — throttle/trip sends and the dry-run path (§1.5).
 *
 * The bot only ever calls the keeper functions `throttle` and `trip`.
 * It never moves funds, never calls check() as a transaction, never
 * updates a policy, never manages keepers, never resets/unthrottles.
 * In dry-run mode nothing is sent: the exact transaction that WOULD be
 * sent is logged instead (function, policyId, duration, evidence,
 * estimated gas when estimable).
 */
import { toHex, type Address, type Chain, type Hash, type PublicClient, type WalletClient } from 'viem';
import type { Account, Transport } from 'viem';
import { GUARD_ABI } from './guard.js';

export type ActionKind = 'throttle' | 'trip';

export interface PlannedAction {
  kind: ActionKind;
  policyId: number;
  /** Throttle duration (throttle only). */
  durationSeconds?: number;
  evidence: string;
}

export interface DryRunPlan extends PlannedAction {
  estimatedGas: bigint | null;
  gasNote: string | null;
}

export function evidenceBytes(evidence: string): `0x${string}` {
  return toHex(new TextEncoder().encode(evidence));
}

/**
 * Dry-run planning: describe the exact transaction that would be sent
 * and estimate its gas when possible. Gas estimation needs a registered
 * keeper key; when the key is not registered (normal before addKeeper)
 * the estimate fails and is reported as null — that is expected, not an
 * error.
 */
export async function planAction(
  publicClient: PublicClient,
  guard: Address,
  keeperAddress: Address | null,
  action: PlannedAction,
): Promise<DryRunPlan> {
  let estimatedGas: bigint | null = null;
  let gasNote: string | null = null;
  if (!keeperAddress) {
    gasNote = 'no keeper key configured; gas estimate unavailable';
  } else {
    try {
      estimatedGas =
        action.kind === 'throttle'
          ? await publicClient.estimateContractGas({
              address: guard,
              abi: GUARD_ABI,
              functionName: 'throttle',
              args: [BigInt(action.policyId), action.durationSeconds ?? 0, evidenceBytes(action.evidence)],
              account: keeperAddress,
            })
          : await publicClient.estimateContractGas({
              address: guard,
              abi: GUARD_ABI,
              functionName: 'trip',
              args: [BigInt(action.policyId), evidenceBytes(action.evidence)],
              account: keeperAddress,
            });
    } catch (err) {
      gasNote = `gas estimate failed (keeper may not be registered yet): ${(err as Error).message.slice(0, 200)}`;
    }
  }
  return { ...action, estimatedGas, gasNote };
}

/** Send a throttle/trip transaction (live mode only). Returns the tx hash. */
export async function sendAction(
  walletClient: WalletClient<Transport, Chain, Account>,
  publicClient: PublicClient,
  guard: Address,
  action: PlannedAction,
): Promise<Hash> {
  const hash =
    action.kind === 'throttle'
      ? await walletClient.writeContract({
          address: guard,
          abi: GUARD_ABI,
          functionName: 'throttle',
          args: [BigInt(action.policyId), action.durationSeconds ?? 0, evidenceBytes(action.evidence)],
        })
      : await walletClient.writeContract({
          address: guard,
          abi: GUARD_ABI,
          functionName: 'trip',
          args: [BigInt(action.policyId), evidenceBytes(action.evidence)],
        });
  // Wait for one confirmation so the next cycle reads the new mode.
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}
