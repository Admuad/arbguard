/**
 * index.ts — entry: load config, verify keeper, start the poll loop.
 *
 * Startup validation (fails fast, exits non-zero, §1.3):
 *  - guard address has code on the configured chain;
 *  - the chain id read from the RPC matches KEEPER_CHAIN_ID;
 *  - in live mode the keeper key is registered for every watched policy
 *    (KEEPER_NOT_REGISTERED); in dry-run this is a warning only, so
 *    dry-run works before the keeper is registered.
 *
 * The bot polls on a fixed interval and uses getLogs with an explicit
 * block range per poll. No subscriptions, no retries on 429 (back off
 * one full poll interval and log it). If the bot is down, the guard
 * still works — the bot is a graduated response, not the primary
 * mechanism.
 */
import 'dotenv/config';
import { getAddress } from 'viem';
import { loadConfig, publicConfig, type KeeperConfig } from './config.js';
import {
  GUARD_ABI,
  createClients,
  detectPolicyLayout,
  errorText,
  getLatestBlock,
  probeOracle,
  probeSwapDisagreement,
  readBalances,
  readPolicyState,
  type BalanceContext,
  type GuardClients,
  type OracleProbe,
} from './guard.js';
import { scanEvents, type CycleEvents } from './events.js';
import { evaluateTriggers, usePct, type PolicySnapshot, type TriggerThresholds } from './triggers.js';
import { planAction, sendAction, type PlannedAction } from './actions.js';
import { DecisionLog, type DecisionLine } from './log.js';

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

function isRateLimited(err: unknown): boolean {
  const text = errorText(err);
  return text.includes('429') || text.toLowerCase().includes('rate limit') || text.toLowerCase().includes('too many requests');
}

interface OracleStreak {
  failuresConsecutive: number;
  everSucceeded: boolean;
  disagreementStreak: number;
}

interface PolicyRuntime {
  oracle: OracleStreak;
  lastAction: { atMs: number; mode: 'NORMAL' | 'THROTTLED' | 'PAUSED' } | null;
  prevControlWeth: bigint | null;
}

function classifyProbe(probe: OracleProbe, streak: OracleStreak): void {
  switch (probe.status) {
    case 'ok':
      streak.failuresConsecutive = 0;
      streak.everSucceeded = true;
      streak.disagreementStreak = 0;
      break;
    case 'unusable':
      streak.failuresConsecutive += 1;
      streak.disagreementStreak = 0;
      break;
    case 'reverted':
      streak.failuresConsecutive += 1;
      streak.disagreementStreak =
        probe.reasonName === 'ORACLE_DISAGREEMENT' ? streak.disagreementStreak + 1 : 0;
      break;
    case 'skipped':
      break;
  }
}

async function loadConfigOrExit(): Promise<KeeperConfig> {
  try {
    return loadConfig();
  } catch (err) {
    console.error(`startup failed: ${(err as Error).message}`);
    process.exit(1);
  }
}

async function main(): Promise<void> {
  const config = await loadConfigOrExit();

  const log = new DecisionLog(config.logFile);
  const clients: GuardClients = createClients(config);
  const { publicClient } = clients;
  const guard = getAddress(config.guardAddress);

  // --- Startup validation (§1.3). ---
  try {
    const liveChainId = await publicClient.getChainId();
    if (liveChainId !== config.chainId) {
      console.error(
        `startup failed: chain id mismatch: RPC reports ${liveChainId}, KEEPER_CHAIN_ID=${config.chainId}. ` +
          `A Sepolia key must never send on mainnet by misconfiguration.`,
      );
      process.exit(1);
    }
    const code = await publicClient.getCode({ address: guard });
    if (!code || code === '0x') {
      console.error(`startup failed: no code at guard address ${guard} on chain ${config.chainId}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`startup failed: ${(err as Error).message}`);
    process.exit(1);
  }

  // Detect the live guard's Policy layout (Phase 1 = 9 fields, Phase 2
  // = 12 fields). The Sepolia deployment predates Phase 2; the bot
  // reads the shared 9-field prefix either way, and the R2
  // simulateCheck probe is encoded in the detected layout.
  let contractVersion: 1 | 2;
  try {
    contractVersion = await detectPolicyLayout(publicClient, guard);
  } catch (err) {
    console.error(`startup failed: policy layout detection: ${errorText(err)}`);
    process.exit(1);
  }
  let keeperRegistered = false;
  if (clients.keeperAddress) {
    try {
      const registered = await Promise.all(
        config.policyIds.map(async (pid) => {
          const keepers = await publicClient.readContract({
            address: guard,
            abi: GUARD_ABI,
            functionName: 'getKeepers',
            args: [BigInt(pid)],
          });
          return (keepers as `0x${string}`[]).some(
            (k) => k.toLowerCase() === (clients.keeperAddress as string).toLowerCase(),
          );
        }),
      );
      keeperRegistered = registered.every(Boolean);
      if (!keeperRegistered) {
        const missing = config.policyIds.filter((_, i) => !registered[i]);
        const msg =
          `KEEPER_NOT_REGISTERED: keeper ${clients.keeperAddress} is not registered ` +
          `for policy ${missing.join(',')}. The owner must run addKeeper first (see RUNBOOK.md).`;
        if (!config.dryRun) {
          console.error(`startup failed: ${msg}`);
          process.exit(1);
        }
        log.info({ event: 'warning', message: msg });
      }
    } catch (err) {
      console.error(`startup failed: keeper check error: ${errorText(err)}`);
      process.exit(1);
    }
  } else if (!config.dryRun) {
    // Unreachable: loadConfig requires a key in live mode.
    console.error('startup failed: no keeper key in live mode');
    process.exit(1);
  }

  log.info({
    event: 'startup',
    keeper: clients.keeperAddress ?? null,
    keeperRegistered,
    contractVersion: contractVersion,
    ...publicConfig(config),
    note: 'If this bot stops, the guard still works. Dry-run sends nothing.',
  });
  if (!config.mwethAddress || !config.musdcAddress) {
    log.info({
      event: 'warning',
      message:
        'KEEPER_MWETH_ADDRESS / KEEPER_MUSDC_ADDRESS not set: oracle probe and balance context disabled; T4 and R2 cannot fire.',
    });
  }
  if (config.oracleFailPolls === 0) {
    log.info({
      event: 'warning',
      message:
        'T4 disabled (KEEPER_ORACLE_FAIL_POLLS=0). Correct for Sepolia: the ETH/USD feed is stale by design, so the price probe never succeeds there.',
    });
  }

  // --- R3 one-shot manual trip (§1.4). Verifies the caller is a
  // registered keeper, sends one trip(), logs it, exits. ---
  if (config.tripOnce !== undefined) {
    const policyId = config.tripOnce;
    if (!clients.keeperAddress) {
      console.error('startup failed: KEEPER_TRIP_ONCE requires KEEPER_PRIVATE_KEY (the caller must be a registered keeper)');
      process.exit(1);
    }
    if (!keeperRegistered) {
      console.error(
        `startup failed: KEEPER_NOT_REGISTERED: keeper ${clients.keeperAddress} is not registered for policy ${policyId}`,
      );
      process.exit(1);
    }
    const evidence = `keeper-bot R3 manual trip policy ${policyId}`;
    const action: PlannedAction = { kind: 'trip', policyId, evidence };
    if (config.dryRun) {
      const plan = await planAction(publicClient, guard, clients.keeperAddress, action);
      log.append({
        ts: new Date().toISOString(),
        chainId: config.chainId,
        guard,
        policyId,
        mode: 'NORMAL',
        decision: 'WOULD_TRIP',
        reason: `R3 manual trip policy ${policyId} (one-shot, dry-run; estimated gas ${plan.estimatedGas ?? 'unknown'})`,
        hourUsePct: 0,
        dayUsePct: 0,
        blockUsePct: 0,
        dryRun: true,
        txHash: null,
      });
      process.exit(0);
    }
    if (!clients.walletClient) {
      console.error('startup failed: no wallet client for live trip');
      process.exit(1);
    }
    const txHash = await sendAction(clients.walletClient, publicClient, guard, action);
    log.append({
      ts: new Date().toISOString(),
      chainId: config.chainId,
      guard,
      policyId,
      mode: 'NORMAL',
      decision: 'TRIP_SENT',
      reason: `R3 manual trip policy ${policyId} (one-shot)`,
      hourUsePct: 0,
      dayUsePct: 0,
      blockUsePct: 0,
      dryRun: false,
      txHash,
    });
    process.exit(0);
  }

  // --- Poll loop. ---
  const runtime = new Map<number, PolicyRuntime>();
  for (const pid of config.policyIds) {
    runtime.set(pid, {
      oracle: { failuresConsecutive: 0, everSucceeded: false, disagreementStreak: 0 },
      lastAction: null,
      prevControlWeth: null,
    });
  }
  const thresholds: TriggerThresholds = {
    hourUsePct: config.hourUsePct,
    dayUsePct: config.dayUsePct,
    largePassPct: config.largePassPct,
    oracleFailPolls: config.oracleFailPolls,
    pollSeconds: config.pollSeconds,
  };

  let lastScannedBlock: bigint =
    config.deployBlock === 'earliest' ? 0n : config.deployBlock;
  let shuttingDown = false;
  const shutdown = (): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info({ event: 'shutdown', message: 'keeper stopping; the guard keeps working without it' });
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  for (;;) {
    const cycleStart = Date.now();
    try {
      await runCycle(config, clients, log, runtime, thresholds, contractVersion, lastScannedBlock, (next) => {
        lastScannedBlock = next;
      });
    } catch (err) {
      const rateLimited = isRateLimited(err);
      log.info({
        event: 'cycle-error',
        error: errorText(err),
        stack: err instanceof Error ? (err.stack ?? '').slice(0, 1200) : undefined,
        rateLimited,
        note: rateLimited
          ? 'HTTP 429: backing off one full poll interval, no retry (rate discipline §1.5)'
          : 'poll cycle failed; no action taken on partial state; retrying next cycle',
      });
      // Per-policy ERROR lines: the cycle produced no usable state.
      for (const pid of config.policyIds) {
        log.append({
          ts: new Date().toISOString(),
          chainId: config.chainId,
          guard,
          policyId: pid,
          mode: 'UNKNOWN',
          decision: 'ERROR',
          reason: `poll cycle failed: ${errorText(err).slice(0, 200)}`,
          hourUsePct: 0,
          dayUsePct: 0,
          blockUsePct: 0,
          dryRun: config.dryRun,
          txHash: null,
        });
      }
      // Back off an extra poll interval on 429 before the next cycle.
      await sleep(config.pollSeconds * 1000);
      continue;
    }
    const elapsed = Date.now() - cycleStart;
    const waitMs = Math.max(0, config.pollSeconds * 1000 - elapsed);
    await sleep(waitMs);
  }
}

async function runCycle(
  config: KeeperConfig,
  clients: GuardClients,
  log: DecisionLog,
  runtime: Map<number, PolicyRuntime>,
  thresholds: TriggerThresholds,
  contractVersion: 1 | 2,
  lastScannedBlock: bigint,
  setLastScanned: (next: bigint) => void,
): Promise<void> {
  const { publicClient } = clients;
  const guard = getAddress(config.guardAddress);

  const latest = await getLatestBlock(publicClient);
  const events = await scanEvents(
    publicClient,
    guard,
    lastScannedBlock,
    latest.number,
    config.policyIds,
  );
  const balances: BalanceContext = await readBalances(publicClient, config);

  for (const policyId of config.policyIds) {
    const rt = runtime.get(policyId) as PolicyRuntime;
    const ev: CycleEvents = events.get(policyId) as CycleEvents;

    // R1 second signal: the unguarded control's mWETH balance fell
    // since the previous cycle.
    const controlDrainObserved =
      rt.prevControlWeth !== null &&
      balances.unguardedVaultWeth !== null &&
      balances.unguardedVaultWeth < rt.prevControlWeth;
    if (balances.unguardedVaultWeth !== null) rt.prevControlWeth = balances.unguardedVaultWeth;

    const state = await readPolicyState(publicClient, guard, policyId);

    // Oracle probe (this cycle's T4/R2 input). On live Sepolia this
    // returns "unusable" (price 0 / no source) every poll — the pair
    // is incomplete by design — and everSucceeded stays false, so T4
    // cannot fire there even if enabled.
    const probe = await probeOracle(
      publicClient,
      guard,
      policyId,
      config.mwethAddress,
      config.musdcAddress,
    );
    classifyProbe(probe, rt.oracle);

    // R2 second signal: only probe simulateCheck while a disagreement
    // streak is active (the probe is a read; it is never acted on alone).
    let oracleProbeDisagreement = false;
    if (
      rt.oracle.disagreementStreak >= thresholds.oracleFailPolls &&
      thresholds.oracleFailPolls > 0 &&
      config.mwethAddress &&
      config.musdcAddress &&
      state.protocol !== '0x0000000000000000000000000000000000000000'
    ) {
      oracleProbeDisagreement = await probeSwapDisagreement(
        publicClient,
        guard,
        policyId,
        state.protocol,
        config.mwethAddress,
        config.musdcAddress,
        contractVersion,
      );
    }

    const hourCurrent = state.outflowHour === BigInt(Math.floor(latest.timestamp / 3600));
    const dayCurrent = state.outflowDay === BigInt(Math.floor(latest.timestamp / 86400));

    const snapshot: PolicySnapshot = {
      policyId,
      mode: state.mode,
      enabled: state.enabled,
      throttleUntil: state.throttleUntil,
      pausedUntil: state.pausedUntil,
      maxOutflowPerBlock: state.maxOutflowPerBlock,
      maxOutflowPerHour: state.maxOutflowPerHour,
      maxOutflowPerDay: state.maxOutflowPerDay,
      outflowInBlock: state.outflowInBlock,
      outflowInHour: state.outflowInHour,
      outflowInDay: state.outflowInDay,
      hourCurrent,
      dayCurrent,
      now: latest.timestamp,
      largePassAmountOut: ev.largestPassAmountOut,
      oracleFailuresConsecutive: rt.oracle.failuresConsecutive,
      oracleEverSucceeded: rt.oracle.everSucceeded,
      oracleDisagreementStreak: rt.oracle.disagreementStreak,
      oracleProbeDisagreement,
      controlDrainObserved,
      proposalSeen: ev.proposalSeen,
      lastAction: rt.lastAction,
      nowMs: Date.now(),
      partialState: state.partial,
    };

    const result = evaluateTriggers(snapshot, thresholds, {
      dryRun: config.dryRun,
      allowTrip: config.allowTrip,
    });

    let txHash: string | null = null;
    let decision = result.decision;
    let reason = result.reason;

    if (result.decision === 'WOULD_THROTTLE' || result.decision === 'THROTTLE_SENT') {
      const action: PlannedAction = {
        kind: 'throttle',
        policyId,
        durationSeconds: config.throttleSeconds,
        evidence: result.evidence as string,
      };
      if (config.dryRun) {
        const plan = await planAction(publicClient, guard, clients.keeperAddress, action);
        reason += `; dry-run: would send throttle(${policyId}, ${config.throttleSeconds}, "${action.evidence}")` +
          ` estimated gas ${plan.estimatedGas ?? 'unknown'}` +
          (plan.gasNote ? ` (${plan.gasNote})` : '');
      } else if (clients.walletClient) {
        txHash = await sendAction(clients.walletClient, publicClient, guard, action);
        decision = 'THROTTLE_SENT';
        reason += `; tx ${txHash}`;
      }
      rt.lastAction = { atMs: Date.now(), mode: state.mode };
    } else if (result.decision === 'WOULD_TRIP' || result.decision === 'TRIP_SENT') {
      const action: PlannedAction = {
        kind: 'trip',
        policyId,
        evidence: result.evidence as string,
      };
      if (config.dryRun) {
        const plan = await planAction(publicClient, guard, clients.keeperAddress, action);
        reason += `; dry-run: would send trip(${policyId}, "${action.evidence}")` +
          ` estimated gas ${plan.estimatedGas ?? 'unknown'}` +
          (plan.gasNote ? ` (${plan.gasNote})` : '');
      } else if (clients.walletClient) {
        txHash = await sendAction(clients.walletClient, publicClient, guard, action);
        decision = 'TRIP_SENT';
        reason += `; tx ${txHash}`;
      }
      rt.lastAction = { atMs: Date.now(), mode: state.mode };
    }

    const line: DecisionLine = {
      ts: new Date().toISOString(),
      chainId: config.chainId,
      guard,
      policyId,
      mode: state.mode,
      decision,
      reason,
      hourUsePct: usePct(hourCurrent ? state.outflowInHour : 0n, state.maxOutflowPerHour),
      dayUsePct: usePct(dayCurrent ? state.outflowInDay : 0n, state.maxOutflowPerDay),
      blockUsePct: usePct(state.outflowInBlock, state.maxOutflowPerBlock),
      dryRun: config.dryRun,
      txHash,
    };
    log.append(line);
  }

  setLastScanned(latest.number + 1n);
}

main().catch((err) => {
  console.error(`fatal: ${(err as Error).message}`);
  process.exit(1);
});
