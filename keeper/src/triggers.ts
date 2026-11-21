/**
 * triggers.ts — pure trigger evaluation (PHASE3-SPEC.md §1.4). No I/O.
 *
 * Evaluation order (normative): preconditions P1–P4, then trip rules
 * R1–R2 (a trip must never be shadowed by a throttle on the same cycle),
 * then throttle rules T1–T4, then T5 (proposal seen — log only, never a
 * throttle). First firing rule wins; at most one action per policy per
 * cycle.
 *
 * THE NEVER-RULE (normative prohibition, §1.4): this module has NO input
 * for reverts, failed transactions, or `simulateCheck` failures. A
 * reverted check is the guard working — zero funds moved — and treating
 * reverts as incidents would let an attacker trip the breaker at will by
 * spamming failing transactions. There is deliberately no code path here
 * that takes a revert as an input; `TRIGGER_INPUT_KEYS` below is the
 * auditable list of everything the rules can see. `simulateCheck` is
 * used by the bot only as a read for R2's probe, and the probe result is
 * never acted on alone.
 */

export type ModeName = 'NORMAL' | 'THROTTLED' | 'PAUSED';

export type Decision =
  | 'NO_ACTION'
  | 'WOULD_THROTTLE'
  | 'THROTTLE_SENT'
  | 'WOULD_TRIP'
  | 'TRIP_SENT'
  | 'TRIP_BLOCKED_BY_CONFIG'
  | 'SKIP_ALREADY_PAUSED'
  | 'SKIP_ALREADY_THROTTLED'
  | 'SKIP_DISABLED'
  | 'SKIP_PARTIAL_STATE'
  | 'PROPOSAL_SEEN'
  | 'ERROR';

/** Everything a trigger rule may observe, per policy per cycle. */
export interface PolicySnapshot {
  policyId: number;
  mode: ModeName;
  enabled: boolean;
  /** 0 = indefinite throttle. */
  throttleUntil: bigint;
  pausedUntil: bigint;
  maxOutflowPerBlock: bigint;
  maxOutflowPerHour: bigint;
  maxOutflowPerDay: bigint;
  outflowInBlock: bigint;
  outflowInHour: bigint;
  outflowInDay: bigint;
  /** True when the stored hour window is the current hour. */
  hourCurrent: boolean;
  /** True when the stored day window is the current day. */
  dayCurrent: boolean;
  /** Chain time (latest block timestamp), unix seconds. */
  now: number;
  /** Largest CheckPassed amountOut seen this cycle, null when none. */
  largePassAmountOut: bigint | null;
  /** Consecutive polls where getReferencePrice reverted or was unusable. */
  oracleFailuresConsecutive: number;
  /** True once a getReferencePrice probe has ever succeeded (T4 needs a
   *  prior success: a feed that never worked is not a new failure). */
  oracleEverSucceeded: boolean;
  /** Consecutive polls where getReferencePrice reverted ORACLE_DISAGREEMENT. */
  oracleDisagreementStreak: number;
  /** True when this cycle's simulateCheck probe for a live swap returned
   *  (false, ORACLE_DISAGREEMENT). Second signal for R2. */
  oracleProbeDisagreement: boolean;
  /** True when the unguarded control's balance fell this cycle. Second
   *  signal for R1: the same actor draining the control. */
  controlDrainObserved: boolean;
  /** A PolicyUpdateProposed / OracleConfigUpdateProposed event seen this cycle. */
  proposalSeen: { executableAt: bigint } | null;
  /** The bot's own last action for this policy (P4 anti-flap). */
  lastAction: { atMs: number; mode: ModeName } | null;
  /** Wall-clock now, ms. Compared against lastAction.atMs. */
  nowMs: number;
  /** True when any required read was missing this cycle: never act on
   *  partial state (fail-closed, §1.5). */
  partialState: boolean;
}

export interface TriggerThresholds {
  hourUsePct: number;
  dayUsePct: number;
  largePassPct: number;
  /** 0 = T4 (and R2's streak) disabled. */
  oracleFailPolls: number;
  pollSeconds: number;
}

export interface TriggerResult {
  decision: Decision;
  /** Always names the rule and the numbers. */
  reason: string;
  /** Firing rule id (T1–T5, R1–R3) or null. */
  rule: string | null;
  /** Evidence string for the on-chain call (also logged), or null. */
  evidence: string | null;
}

/**
 * Auditable input surface. A revert / failed transaction / simulateCheck
 * failure is not among these keys and cannot reach any rule.
 */
export const TRIGGER_INPUT_KEYS: Array<keyof PolicySnapshot> = [
  'policyId',
  'mode',
  'enabled',
  'throttleUntil',
  'pausedUntil',
  'maxOutflowPerBlock',
  'maxOutflowPerHour',
  'maxOutflowPerDay',
  'outflowInBlock',
  'outflowInHour',
  'outflowInDay',
  'hourCurrent',
  'dayCurrent',
  'now',
  'largePassAmountOut',
  'oracleFailuresConsecutive',
  'oracleEverSucceeded',
  'oracleDisagreementStreak',
  'oracleProbeDisagreement',
  'controlDrainObserved',
  'proposalSeen',
  'lastAction',
  'nowMs',
  'partialState',
];

/** Integer percent (floor) of `used` against `cap`; 0 when cap is 0. */
export function usePct(used: bigint, cap: bigint): number {
  if (cap <= 0n) return 0;
  return Number((used * 100n) / cap);
}

/** True when `used` is at least `pct` percent of `cap` (exact, no float). */
export function atLeastPct(used: bigint, cap: bigint, pct: number): boolean {
  if (cap <= 0n) return false;
  return used * 100n >= cap * BigInt(pct);
}

function evidenceFor(rule: string, detail: string, policyId: number): string {
  return `keeper-bot ${rule} ${detail} policy ${policyId}`;
}

/**
 * Evaluate one policy for one poll cycle. Pure: same snapshot +
 * thresholds always give the same decision.
 */
export function evaluateTriggers(
  snap: PolicySnapshot,
  t: TriggerThresholds,
  opts: { dryRun: boolean; allowTrip: boolean },
): TriggerResult {
  const pid = snap.policyId;

  // --- Preconditions (§1.4). Any one holding means no action. ---
  if (snap.partialState) {
    return {
      decision: 'SKIP_PARTIAL_STATE',
      reason: `partial state for policy ${pid}: a required read failed this cycle, no action taken`,
      rule: null,
      evidence: null,
    };
  }
  // P1. Breaker already doing the strongest thing.
  if (snap.mode === 'PAUSED') {
    return {
      decision: 'SKIP_ALREADY_PAUSED',
      reason: `P1 policy ${pid} already PAUSED until ${snap.pausedUntil}`,
      rule: null,
      evidence: null,
    };
  }
  // P2. Already degraded; re-throttling would only reset the clock.
  if (snap.mode === 'THROTTLED' && (snap.throttleUntil === 0n || snap.throttleUntil > BigInt(snap.now))) {
    return {
      decision: 'SKIP_ALREADY_THROTTLED',
      reason:
        snap.throttleUntil === 0n
          ? `P2 policy ${pid} already THROTTLED (indefinite)`
          : `P2 policy ${pid} already THROTTLED until ${snap.throttleUntil}`,
      rule: null,
      evidence: null,
    };
  }
  // P3. Disabled policy.
  if (!snap.enabled) {
    return {
      decision: 'SKIP_DISABLED',
      reason: `P3 policy ${pid} disabled`,
      rule: null,
      evidence: null,
    };
  }
  // P4. Anti-flap: one throttle per incident, not one per poll.
  if (
    snap.lastAction !== null &&
    snap.nowMs - snap.lastAction.atMs < t.pollSeconds * 2 * 1000 &&
    snap.lastAction.mode === snap.mode
  ) {
    const agoS = Math.floor((snap.nowMs - snap.lastAction.atMs) / 1000);
    return {
      decision: 'NO_ACTION',
      reason:
        `P4 anti-flap policy ${pid}: last action ${agoS}s ago (< ${t.pollSeconds * 2}s) ` +
        `and mode unchanged (${snap.mode})`,
      rule: null,
      evidence: null,
    };
  }

  const hourPct = usePct(snap.hourCurrent ? snap.outflowInHour : 0n, snap.maxOutflowPerHour);
  const dayPct = usePct(snap.dayCurrent ? snap.outflowInDay : 0n, snap.maxOutflowPerDay);
  const blockPct = usePct(snap.outflowInBlock, snap.maxOutflowPerBlock);

  // --- Throttle signals (computed first: R1 needs T1/T2). ---
  const t1 =
    snap.maxOutflowPerHour > 0n &&
    snap.hourCurrent &&
    atLeastPct(snap.outflowInHour, snap.maxOutflowPerHour, t.hourUsePct);
  const t2 =
    snap.maxOutflowPerDay > 0n &&
    snap.dayCurrent &&
    atLeastPct(snap.outflowInDay, snap.maxOutflowPerDay, t.dayUsePct);
  const t3 =
    snap.mode === 'NORMAL' &&
    snap.largePassAmountOut !== null &&
    atLeastPct(snap.largePassAmountOut, snap.maxOutflowPerBlock, t.largePassPct);
  const t4 =
    t.oracleFailPolls > 0 &&
    snap.oracleEverSucceeded &&
    snap.oracleFailuresConsecutive >= t.oracleFailPolls;

  // --- Trip rules (gated, checked before any throttle rule). ---
  const r1 = (t1 || t2) && snap.controlDrainObserved;
  if (r1) {
    const which = t1 ? 'T1' : 'T2';
    const use = t1 ? hourPct : dayPct;
    const detail = `confirmed-drain ${which} ${use}% + control drain policy ${pid}`;
    if (!opts.allowTrip) {
      return {
        decision: 'TRIP_BLOCKED_BY_CONFIG',
        reason:
          `R1 confirmed drain shape policy ${pid}: ${which} fired at ${use}% ` +
          `and the unguarded control drained in the same cycle; trip blocked (KEEPER_ALLOW_TRIP=false)`,
        rule: 'R1',
        evidence: evidenceFor('R1', detail, pid),
      };
    }
    return {
      decision: opts.dryRun ? 'WOULD_TRIP' : 'TRIP_SENT',
      reason:
        `R1 confirmed drain shape policy ${pid}: ${which} fired at ${use}% ` +
        `and the unguarded control drained in the same cycle`,
      rule: 'R1',
      evidence: evidenceFor('R1', detail, pid),
    };
  }

  const r2 =
    t.oracleFailPolls > 0 &&
    snap.oracleDisagreementStreak >= t.oracleFailPolls &&
    snap.oracleProbeDisagreement;
  if (r2) {
    if (!opts.allowTrip) {
      return {
        decision: 'TRIP_BLOCKED_BY_CONFIG',
        reason:
          `R2 oracle disagreement storm policy ${pid}: ORACLE_DISAGREEMENT for ` +
          `${snap.oracleDisagreementStreak} consecutive polls and the simulateCheck probe ` +
          `returned ORACLE_DISAGREEMENT; trip blocked (KEEPER_ALLOW_TRIP=false)`,
        rule: 'R2',
        evidence: evidenceFor('R2', `oracle-disagreement x${snap.oracleDisagreementStreak}`, pid),
      };
    }
    return {
      decision: opts.dryRun ? 'WOULD_TRIP' : 'TRIP_SENT',
      reason:
        `R2 oracle disagreement storm policy ${pid}: ORACLE_DISAGREEMENT for ` +
        `${snap.oracleDisagreementStreak} consecutive polls and the simulateCheck probe ` +
        `returned ORACLE_DISAGREEMENT`,
      rule: 'R2',
      evidence: evidenceFor('R2', `oracle-disagreement x${snap.oracleDisagreementStreak}`, pid),
    };
  }

  // --- Throttle rules (first firing rule wins). ---
  const throttleDecision = opts.dryRun ? 'WOULD_THROTTLE' : 'THROTTLE_SENT';
  if (t1) {
    return {
      decision: throttleDecision,
      reason: `T1 hour-use ${hourPct}% >= ${t.hourUsePct}% policy ${pid} (hour cap ${snap.maxOutflowPerHour})`,
      rule: 'T1',
      evidence: evidenceFor('T1', `hour-use ${hourPct}%`, pid),
    };
  }
  if (t2) {
    return {
      decision: throttleDecision,
      reason: `T2 day-use ${dayPct}% >= ${t.dayUsePct}% policy ${pid} (day cap ${snap.maxOutflowPerDay})`,
      rule: 'T2',
      evidence: evidenceFor('T2', `day-use ${dayPct}%`, pid),
    };
  }
  if (t3) {
    const largePct = usePct(snap.largePassAmountOut as bigint, snap.maxOutflowPerBlock);
    return {
      decision: throttleDecision,
      reason:
        `T3 large passing action policy ${pid}: CheckPassed amountOut ` +
        `${snap.largePassAmountOut} is ${largePct}% of the block cap (threshold ${t.largePassPct}%)`,
      rule: 'T3',
      evidence: evidenceFor('T3', `large-pass ${largePct}%`, pid),
    };
  }
  if (t4) {
    return {
      decision: throttleDecision,
      reason:
        `T4 oracle blind policy ${pid}: getReferencePrice failed for ` +
        `${snap.oracleFailuresConsecutive} consecutive polls (threshold ${t.oracleFailPolls})`,
      rule: 'T4',
      evidence: evidenceFor('T4', `oracle-fail x${snap.oracleFailuresConsecutive}`, pid),
    };
  }

  // --- T5: a proposal is noticed, never throttled on. ---
  if (snap.proposalSeen !== null) {
    return {
      decision: 'PROPOSAL_SEEN',
      reason:
        `T5 policy update proposed for policy ${pid}, executable at ` +
        `${snap.proposalSeen.executableAt} (timelock window — human response, not a throttle)`,
      rule: 'T5',
      evidence: null,
    };
  }

  const oracleNote =
    t.oracleFailPolls === 0
      ? 'oracle probe unusable, T4 disabled'
      : snap.oracleFailuresConsecutive > 0
        ? `oracle failing x${snap.oracleFailuresConsecutive} (< ${t.oracleFailPolls})`
        : 'oracle ok';
  return {
    decision: 'NO_ACTION',
    reason:
      `T1 hour-use ${hourPct}% < ${t.hourUsePct}%; T2 day-use ${dayPct}% < ${t.dayUsePct}%; ` +
      `T3 block-use ${blockPct}% (no large pass); ${oracleNote}`,
    rule: null,
    evidence: null,
  };
}
