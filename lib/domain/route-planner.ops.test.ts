import { it as test } from 'vitest';
import assert from 'node:assert/strict';
import { proposePlan, evaluatePartyPreferences, type PlanningInput, type ExistingPlanningSchedule } from './route-planner';

const at = (time: string) => `2026-10-31T${time}:00+01:00`;
const base: PlanningInput = {
  parties: [{ id: 'new-family', childCount: 2, preferredStartAt: at('18:30'), paymentEligible: true }],
  starts: [
    { id: 'slot-a', startPointId: 'point-a', startsAt: at('18:30'), maxGroups: 2, maxChildren: 10 },
    { id: 'slot-b', startPointId: 'point-a', startsAt: at('18:40'), maxGroups: 2, maxChildren: 10 },
  ],
  targetGroupSize: 6, maxGroupSize: 10,
  globalOrdinaryStopAt: at('20:30'), finaleOpensAt: at('19:00'), finaleLastArrivalAt: at('21:30'), finaleClosesAt: at('22:00'),
  maxGroupOverrunSeconds: 1800, finaleShowSeconds: 360, finaleTurnoverSeconds: 0, finalePlanningTransferSeconds: 600, finaleMaxGroups: 2, finaleMaxChildren: 20,
  earlyPreferenceLatestAt: at('18:00'), laterPreferenceEarliestAt: at('18:15'), preferenceGreenMinutes: 15, preferenceAmberMinutes: 30,
};
const existing: ExistingPlanningSchedule = { id: 'saved-A', startId: 'slot-a', childCount: 4, expectedFinaleArrivalAt: at('20:40'), partyIds: ['saved-family'] };

test('OPS04: opposite exact preferences remain individually red despite a matching average', () => {
  const result = proposePlan({ ...base, parties: [
    { id: 'early-family', childCount: 2, preferredStartAt: at('17:30') },
    { id: 'late-family', childCount: 2, preferredStartAt: at('19:30') },
  ] });
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.groups.length, 1);
  const group = result.groups[0];
  assert.equal(group.preferenceMatch, 'large_deviation');
  assert.equal(group.maxPreferenceDeviationMinutes, 60);
  assert.deepEqual(group.preferenceDetails.map(p => [p.partyId, p.deviationMinutes, p.match]), [
    ['early-family', 60, 'large_deviation'], ['late-family', 60, 'large_deviation'],
  ]);
  assert.ok(group.warnings.includes('HOUSEHOLD_START_PREFERENCE_DEVIATION'));
  assert.ok(group.explanation.includes('60 minuten'));
  assert.ok(!group.explanation.includes('exact op'));
});

test('OPS04: the group badge includes an early household boundary alongside an exact neutral preference', () => {
  const result = evaluatePartyPreferences([
    { id: 'early', childCount: 1, startPreference: 'early' },
    { id: 'exact', childCount: 1, preferredStartAt: at('18:30') },
  ], at('18:30'), base);
  assert.equal(result.preferenceMatch, 'large_deviation');
  assert.equal(result.maxPreferenceDeviationMinutes, 30);
  assert.equal(result.preferenceDetails.find(p => p.partyId === 'exact')!.match, 'good');
  assert.equal(result.preferenceDetails.find(p => p.partyId === 'early')!.match, 'large_deviation');
});

test('OPS08: a later batch uses the remaining group capacity of the saved first batch', () => {
  const result = proposePlan({ ...base, starts: [{ ...base.starts[0], maxGroups: 1 }], existingSchedules: [existing] });
  assert.deepEqual(result.groups, []);
  assert.ok(result.conflicts.some(c => c.code === 'START_CAPACITY_EXCEEDED'));
});

test('OPS08: existing children consume start capacity even with remaining group slots', () => {
  const result = proposePlan({ ...base, starts: [{ ...base.starts[0], maxChildren: 5 }], existingSchedules: [existing] });
  assert.deepEqual(result.groups, []);
  assert.ok(result.conflicts.some(c => c.code === 'START_CAPACITY_EXCEEDED'));
});

test('OPS08: existing finale occupation blocks an otherwise available start', () => {
  const result = proposePlan({ ...base, existingSchedules: [existing], finaleMaxGroups: 1, finaleOpensAt: at('20:40'), finaleLastArrivalAt: at('20:45') });
  assert.deepEqual(result.groups, []);
  assert.ok(result.conflicts.some(c => c.code === 'FINALE_CAPACITY_EXCEEDED'));
});

test('OPS08: a second batch waits until a real gap in the finale reservation', () => {
  const result = proposePlan({ ...base, existingSchedules: [existing], finaleMaxGroups: 1 });
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.groups[0].expectedFinaleArrivalAt, new Date(at('20:46')).toISOString());
});

test('OPS08: identical snapshot rows count once, assigned households are not planned a second time', () => {
  const result = proposePlan({ ...base, parties: [{ id: 'saved-family', childCount: 4 }, ...base.parties], existingSchedules: [existing, { ...existing }] });
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.groups.length, 1);
  assert.deepEqual(result.groups[0].partyIds, ['new-family']);
  assert.equal(result.groups[0].childCount, 2);
});

test('OPS08: conflicting duplicate revisions stop the proposal rather than underestimate occupation', () => {
  const result = proposePlan({ ...base, existingSchedules: [existing, { ...existing, childCount: 1 }] });
  assert.deepEqual(result.groups, []);
  assert.ok(result.conflicts.some(c => c.code === 'EXISTING_SCHEDULE_CONFLICT'));
});

test('OPS08: current draft and published revision reserve both starts and one overlapping finale group', () => {
  const old = { ...existing, groupId: 'group-A' };
  const draft = { ...old, id: 'draft-A', startId: 'slot-b' };
  const result = proposePlan({ ...base, starts: [
    { ...base.starts[0], maxGroups: 1 },
    { ...base.starts[0], id: 'slot-b', startsAt: at('19:00'), maxGroups: 2 },
    { ...base.starts[0], id: 'slot-c', startsAt: at('19:10'), maxGroups: 2 },
  ], existingSchedules: [old, draft], finaleMaxGroups: 2 });
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.groups[0].startId, 'slot-c');
  assert.equal(result.groups[0].expectedFinaleArrivalAt, new Date(at('20:40')).toISOString());
});

test('OPS08: two revisions of the same group reserve one physical departure, leaving the next slot free', () => {
  const old = { ...existing, groupId: 'group-A' };
  const result = proposePlan({ ...base, existingSchedules: [old, { ...old, id: 'draft-A' }] });
  assert.deepEqual(result.conflicts, []);
  assert.equal(result.groups.length, 1);
  assert.equal(result.groups[0].startId, 'slot-b');
});

test('OPS08: same-start draft with a changed finale time retains both possible finale windows', () => {
  const old = { ...existing, groupId: 'group-A' };
  const draft = { ...old, id: 'draft-A', expectedFinaleArrivalAt: at('20:50') };
  const result = proposePlan({ ...base, existingSchedules: [old, draft], finaleMaxGroups: 1 });
  assert.deepEqual(result.conflicts, []);
  // Both alternative reservations stay blocked. Six minutes less ordinary route
  // scores better than sixteen minutes waiting after ordinary closure.
  assert.equal(result.groups[0].expectedFinaleArrivalAt, new Date(at('20:34')).toISOString());
});

test('OPS08: malformed existing reservations block a proposal', () => {
  const result = proposePlan({ ...base, existingSchedules: [{ ...existing, childCount: -3 }] });
  assert.deepEqual(result.groups, []);
  assert.ok(result.conflicts.some(c => c.code === 'INVALID_EXISTING_RESERVATION'));
});

test('planner stays deterministic and keeps paid/unpaid markers with preexisting reservations', () => {
  const input = { ...base, parties: [{ id: 'b', childCount: 2, paymentEligible: false }, { id: 'a', childCount: 2 }], existingSchedules: [existing] };
  const forward = proposePlan(input);
  const backward = proposePlan({ ...input, parties: [...input.parties].reverse(), existingSchedules: [...input.existingSchedules].reverse() });
  assert.deepEqual(forward, backward);
  assert.deepEqual(forward.conflicts, []);
  assert.ok(forward.groups[0].warnings.includes('PAYMENT_NOT_CONFIRMED'));
});
