/**
 * triggers.test.ts — table-driven tests for every rule in §1.4.
 * No chain: pure trigger evaluation only. Run with `npm test`.
 *
 * Boundaries: hour-use 79% vs 80% (and 80% vs 81%), large-pass 49% vs
 * 50%, oracle failures 2 vs 3 consecutive polls. Preconditions P1–P4
 * each suppressing an otherwise firing rule. The never-rule: a revert
 * observation must not produce any action — asserted by checking the
 * trigger module's auditable input surface has no revert input.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  TRIGGER_INPUT_KEYS,
  evaluateTriggers,
  type PolicySnapshot,
  type TriggerThresholds,
} from '../src/triggers.js';

const ETHER = 10n ** 18n;

const THRESHOLDS: TriggerThresholds = {
  hourUsePct: 80,
  dayUsePct: 80,
  largePassPct: 50,
  oracleFailPolls: 3,
  pollSeconds: 30,
};

function baseSnapshot(overrides: Partial<PolicySnapshot> = {}): PolicySnapshot {
  return {
    policyId: 0,
    mode: 'NORMAL',
    enabled: true,
    throttleUntil: 0n,
    pausedUntil: 0n,
    maxOutflowPerBlock: 100n * ETHER,
    maxOutflowPerHour: 2000n * ETHER,
    maxOutflowPerDay: 10000n * ETHER,
    outflowInBlock: 0n,
    outflowInHour: 0n,
    outflowInDay: 0n,
    hourCurrent: true,
    dayCurrent: true,
    now: 1_764_000_000,
    largePassAmountOut: null,
    oracleFailuresConsecutive: 0,
    oracleEverSucceeded: true,
    oracleDisagreementStreak: 0,
    oracleProbeDisagreement: false,
    controlDrainObserved: false,
    proposalSeen: null,
    lastAction: null,
    nowMs: 1_764_000_000_000,
    partialState: false,
    ...overrides,
  };
}

const DRY = { dryRun: true, allowTrip: false };
const DRY_TRIP = { dryRun: true, allowTrip: true };

// ---------------------------------------------------------------- T1
test('T1 fires at exactly 80% hour-use (boundary: 79% no-fire, 80% fire, 81% fire)', () => {
  const noFire = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1580n * ETHER }), // 79%
    THRESHOLDS,
    DRY,
  );
  assert.equal(noFire.decision, 'NO_ACTION');
  assert.match(noFire.reason, /hour-use 79%/);

  const fire = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1600n * ETHER }), // 80% of 2000
    THRESHOLDS,
    DRY,
  );
  assert.equal(fire.decision, 'WOULD_THROTTLE');
  assert.equal(fire.rule, 'T1');
  assert.match(fire.reason, /T1 hour-use 80% >= 80%/);
  assert.match(fire.evidence ?? '', /keeper-bot T1 hour-use 80% policy 0/);

  const above = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1620n * ETHER }), // 81%
    THRESHOLDS,
    DRY,
  );
  assert.equal(above.decision, 'WOULD_THROTTLE');
  assert.equal(above.rule, 'T1');
});

test('T1 does not fire when the hour window is stale (outflow belongs to a past hour)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInHour: 2000n * ETHER, hourCurrent: false }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
});

test('T1 does not fire when the hour cap is 0 (window unenforced)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ maxOutflowPerHour: 0n, outflowInHour: 999n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
});

// ---------------------------------------------------------------- T2
test('T2 fires at 80% day-use when the hour window has rolled over', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInDay: 8000n * ETHER, outflowInHour: 0n }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'WOULD_THROTTLE');
  assert.equal(r.rule, 'T2');
  assert.match(r.reason, /T2 day-use 80% >= 80%/);
});

test('T2 no-fire at 79% day-use', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInDay: 7900n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
});

// ---------------------------------------------------------------- T3
test('T3 fires at 50% of the block cap on one passing action (49% no-fire, 50% fire)', () => {
  const noFire = evaluateTriggers(
    baseSnapshot({ largePassAmountOut: 49n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(noFire.decision, 'NO_ACTION');

  const fire = evaluateTriggers(
    baseSnapshot({ largePassAmountOut: 50n * ETHER }), // 50% of 100
    THRESHOLDS,
    DRY,
  );
  assert.equal(fire.decision, 'WOULD_THROTTLE');
  assert.equal(fire.rule, 'T3');
  assert.match(fire.evidence ?? '', /keeper-bot T3 large-pass 50% policy 0/);
});

test('T3 does not fire when the mode is not NORMAL', () => {
  // A THROTTLED policy is suppressed by P2 before T3 is ever evaluated.
  const r = evaluateTriggers(
    baseSnapshot({
      mode: 'THROTTLED',
      throttleUntil: 1_764_086_400n,
      now: 1_764_000_000,
      largePassAmountOut: 90n * ETHER,
    }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_ALREADY_THROTTLED');
});

// ---------------------------------------------------------------- T4
test('T4 fires at 3 consecutive oracle failures after a prior success (2 no-fire, 3 fire)', () => {
  const two = evaluateTriggers(
    baseSnapshot({ oracleFailuresConsecutive: 2, oracleEverSucceeded: true }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(two.decision, 'NO_ACTION');

  const three = evaluateTriggers(
    baseSnapshot({ oracleFailuresConsecutive: 3, oracleEverSucceeded: true }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(three.decision, 'WOULD_THROTTLE');
  assert.equal(three.rule, 'T4');
  assert.match(three.reason, /T4 oracle blind.*3 consecutive polls/);
});

test('T4 does not fire when the oracle never succeeded (no prior success to lose)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ oracleFailuresConsecutive: 99, oracleEverSucceeded: false }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
});

test('T4 is disabled when oracleFailPolls is 0 (Sepolia config)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ oracleFailuresConsecutive: 99, oracleEverSucceeded: true }),
    { ...THRESHOLDS, oracleFailPolls: 0 },
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
});

// ---------------------------------------------------------------- T5
test('T5 logs PROPOSAL_SEEN and does not throttle on a proposal', () => {
  const r = evaluateTriggers(
    baseSnapshot({ proposalSeen: { executableAt: 1_764_086_400n } }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'PROPOSAL_SEEN');
  assert.equal(r.rule, 'T5');
  assert.equal(r.evidence, null);
  assert.match(r.reason, /executable at 1764086400/);
});

// ---------------------------------------------------------------- R1 / R2
test('R1 fires only with two signals: T1 + control drain; T1 alone only throttles', () => {
  const oneSignal = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1600n * ETHER, controlDrainObserved: false }),
    THRESHOLDS,
    DRY_TRIP,
  );
  assert.equal(oneSignal.decision, 'WOULD_THROTTLE');
  assert.equal(oneSignal.rule, 'T1');

  const twoSignals = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1600n * ETHER, controlDrainObserved: true }),
    THRESHOLDS,
    DRY_TRIP,
  );
  assert.equal(twoSignals.decision, 'WOULD_TRIP');
  assert.equal(twoSignals.rule, 'R1');
  assert.match(twoSignals.reason, /R1 confirmed drain shape/);
});

test('R1 is blocked by config by default: TRIP_BLOCKED_BY_CONFIG, no on-chain action', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1600n * ETHER, controlDrainObserved: true }),
    THRESHOLDS,
    DRY, // allowTrip: false
  );
  assert.equal(r.decision, 'TRIP_BLOCKED_BY_CONFIG');
  assert.equal(r.rule, 'R1');
});

test('R2 fires only on disagreement streak + probe agreement; streak alone does not trip', () => {
  const streakOnly = evaluateTriggers(
    baseSnapshot({ oracleDisagreementStreak: 3, oracleProbeDisagreement: false }),
    THRESHOLDS,
    DRY_TRIP,
  );
  assert.notEqual(streakOnly.decision, 'WOULD_TRIP');

  const both = evaluateTriggers(
    baseSnapshot({ oracleDisagreementStreak: 3, oracleProbeDisagreement: true }),
    THRESHOLDS,
    DRY_TRIP,
  );
  assert.equal(both.decision, 'WOULD_TRIP');
  assert.equal(both.rule, 'R2');
});

test('R2 is blocked by config by default', () => {
  const r = evaluateTriggers(
    baseSnapshot({ oracleDisagreementStreak: 3, oracleProbeDisagreement: true }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'TRIP_BLOCKED_BY_CONFIG');
  assert.equal(r.rule, 'R2');
});

// ---------------------------------------------------------------- Preconditions
test('P1 suppresses a firing T1 when PAUSED', () => {
  const r = evaluateTriggers(
    baseSnapshot({ mode: 'PAUSED', pausedUntil: 1_764_003_600n, outflowInHour: 2000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_ALREADY_PAUSED');
  assert.match(r.reason, /P1/);
});

test('P2 suppresses a firing T1 when THROTTLED with a future deadline', () => {
  const r = evaluateTriggers(
    baseSnapshot({ mode: 'THROTTLED', throttleUntil: 1_764_086_400n, outflowInHour: 2000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_ALREADY_THROTTLED');
  assert.match(r.reason, /P2/);
});

test('P2 suppresses a firing T1 when THROTTLED indefinitely (throttleUntil 0)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ mode: 'THROTTLED', throttleUntil: 0n, outflowInHour: 2000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_ALREADY_THROTTLED');
});

test('P3 suppresses a firing T1 when the policy is disabled', () => {
  const r = evaluateTriggers(
    baseSnapshot({ enabled: false, outflowInHour: 2000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_DISABLED');
  assert.match(r.reason, /P3/);
});

test('P4 anti-flap suppresses a re-fire within 2x poll interval when the mode has not changed', () => {
  const r = evaluateTriggers(
    baseSnapshot({
      outflowInHour: 2000n * ETHER,
      lastAction: { atMs: 1_764_000_000_000 - 30_000, mode: 'NORMAL' },
      nowMs: 1_764_000_000_000,
    }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'NO_ACTION');
  assert.match(r.reason, /P4 anti-flap/);
});

test('P4 does not suppress after 2x poll interval has passed', () => {
  const r = evaluateTriggers(
    baseSnapshot({
      outflowInHour: 2000n * ETHER,
      lastAction: { atMs: 1_764_000_000_000 - 61_000, mode: 'NORMAL' },
      nowMs: 1_764_000_000_000,
    }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'WOULD_THROTTLE');
  assert.equal(r.rule, 'T1');
});

test('P4 does not suppress when the mode changed since the last action', () => {
  const r = evaluateTriggers(
    baseSnapshot({
      outflowInHour: 2000n * ETHER,
      lastAction: { atMs: 1_764_000_000_000 - 10_000, mode: 'THROTTLED' },
      nowMs: 1_764_000_000_000,
    }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'WOULD_THROTTLE');
});

test('partial state skips evaluation with SKIP_PARTIAL_STATE even when T1 would fire', () => {
  const r = evaluateTriggers(
    baseSnapshot({ partialState: true, outflowInHour: 2000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.decision, 'SKIP_PARTIAL_STATE');
});

// ---------------------------------------------------------------- Order
test('a trip rule is not shadowed by a throttle rule on the same cycle (R1 wins over T1)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInHour: 2000n * ETHER, controlDrainObserved: true }),
    THRESHOLDS,
    DRY_TRIP,
  );
  assert.equal(r.rule, 'R1');
  assert.equal(r.decision, 'WOULD_TRIP');
});

test('T1 wins over T2 when both fire (first rule wins)', () => {
  const r = evaluateTriggers(
    baseSnapshot({ outflowInHour: 1600n * ETHER, outflowInDay: 8000n * ETHER }),
    THRESHOLDS,
    DRY,
  );
  assert.equal(r.rule, 'T1');
});

// ---------------------------------------------------------------- Never-rule
test('never-rule: the trigger module has no code path that takes a revert as an input', () => {
  // The auditable input surface: no key carries a reverted transaction
  // or a failed check. (oracleFailuresConsecutive counts failed oracle
  // *reads* — a view call returning nothing usable — not reverted
  // transactions; a revert observation still cannot be expressed.)
  const forbiddenSubstrings = ['revert', 'failedtx', 'txreceipt', 'simulatecheck'];
  const forbiddenExact = new Set(['failed', 'failure']);
  for (const key of TRIGGER_INPUT_KEYS) {
    for (const word of forbiddenSubstrings) {
      assert.ok(
        !key.toLowerCase().includes(word),
        `trigger input "${key}" mentions "${word}" — a revert input exists`,
      );
    }
    assert.ok(!forbiddenExact.has(key.toLowerCase()), `trigger input "${key}" is a revert input`);
  }
  // And a cycle with no passing-action signal and no outflow is
  // NO_ACTION even if (hypothetically) checks reverted off-chain: the
  // rules only see the snapshot above, and this snapshot says nothing.
  const r = evaluateTriggers(baseSnapshot(), THRESHOLDS, DRY_TRIP);
  assert.equal(r.decision, 'NO_ACTION');
});

// ---------------------------------------------------------------- Evidence
test('every firing rule produces an evidence string naming the rule and the numbers', () => {
  const cases: Array<{ snap: Partial<PolicySnapshot>; rule: string }> = [
    { snap: { outflowInHour: 1600n * ETHER }, rule: 'T1' },
    { snap: { outflowInDay: 8000n * ETHER }, rule: 'T2' },
    { snap: { largePassAmountOut: 50n * ETHER }, rule: 'T3' },
    { snap: { oracleFailuresConsecutive: 3, oracleEverSucceeded: true }, rule: 'T4' },
    { snap: { outflowInHour: 1600n * ETHER, controlDrainObserved: true }, rule: 'R1' },
  ];
  for (const { snap, rule } of cases) {
    const r = evaluateTriggers(baseSnapshot(snap), THRESHOLDS, DRY_TRIP);
    assert.equal(r.rule, rule);
    assert.ok(r.evidence !== null, `${rule} evidence is null`);
    assert.ok(r.evidence.includes(rule), `${rule} evidence missing rule id`);
    assert.ok(r.evidence.includes('policy 0'), `${rule} evidence missing policy id`);
  }
});
