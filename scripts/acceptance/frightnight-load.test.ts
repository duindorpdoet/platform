import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { assertLoadBinding, coalesceSnapshot, databaseCounterDelta, loadPlan, LOAD_STEPS, percentile, reconnectOffsets, recoverQueuedCommand, stopReasons, summarize, type LoadSample, type QueuedLoadCommand } from './frightnight-load.mjs';
const sample = (latencyMs: number, unexpected = false): LoadSample => ({ latencyMs, unexpected, status: unexpected ? 503 : 200 });
const queued: QueuedLoadCommand = { commandId: '00000000-0000-4000-8000-000000000001', operation: 'journey.complete', payload: { destinationId: '00000000-0000-4000-8000-000000000002', expectedVersion: 3 } };
const env = { NODE_ENV: 'test' as const, APP_ENVIRONMENT: 'staging', APP_URL: 'https://staging-halloween.duindorpdoet.nl', SUPABASE_PROJECT_REF: 'nocteiuvohesvqbowchw', NEXT_PUBLIC_SUPABASE_URL: 'https://nocteiuvohesvqbowchw.supabase.co', EVENT_SLUG: 'frightnight-2027-test', FRIGHTNIGHT_ENABLED: 'true', FRIGHTNIGHT_PROJECT_REF: 'nocteiuvohesvqbowchw', FRIGHTNIGHT_PAYMENT_PROVIDER: 'contract', FRIGHTNIGHT_MAIL_MODE: 'sink', FRIGHTNIGHT_HARDWARE_ENABLED: 'false', GITHUB_SHA: 'a'.repeat(40), FRIGHTNIGHT_VERIFIED_RELEASE_SHA: 'a'.repeat(40), FRIGHTNIGHT_LOAD_APPROVAL: 'nocteiuvohesvqbowchw:staging:duindorphalloweenstg', NEXT_PUBLIC_SUPABASE_ANON_KEY: 'fixture-not-a-key', SUPABASE_SERVICE_ROLE_KEY: 'fixture-not-a-key', SUPABASE_ACCESS_TOKEN: 'fixture-not-a-token' };

describe('bounded staging load metrics and assumptions', () => {
  it('derives a test budget from 100 configured places plus 25%, without attendance claims', () => {
    const plan = loadPlan();
    expect(plan.steps).toEqual([12, 25, 50, 100, 125]);
    expect(plan.peakPhones).toBe(100 * 1.25);
    expect(plan.attendanceForecast).toBe(false);
    expect(plan.actorLimit).toBe(125);
    expect(loadPlan(100, 25).steps).toEqual([12, 25]);
    expect(() => loadPlan(150, 125)).toThrow('REVIEWED_100_PLACE_TEST_BUDGET_REQUIRED');
    expect(() => loadPlan(100, 126)).toThrow();
  });
  it('computes nearest-rank tail percentiles without mutating samples or rounding away the stop boundary', () => {
    const values = [99, 1, 7, 4];
    expect(percentile(values, .5)).toBe(4);
    expect(percentile(values, .95)).toBe(99);
    expect(values).toEqual([99, 1, 7, 4]);
    expect(percentile([], .99)).toBeNull();
    expect(() => percentile([NaN], .95)).toThrow('INVALID_METRIC_SAMPLE');
    expect(() => summarize([], -1)).toThrow('INVALID_METRIC_WINDOW');
  });
  it('stops on p95 over two seconds, exact one-percent unexpected errors or any integrity error', () => {
    const boundary = summarize(Array.from({ length: 100 }, () => sample(2000)), 1000);
    expect(stopReasons(boundary)).toEqual([]);
    expect(stopReasons(summarize(Array.from({ length: 100 }, () => sample(2000.01))))).toContain('P95_ABOVE_2_SECONDS');
    const onePercent = summarize([...Array.from({ length: 99 }, () => sample(20)), sample(20, true)]);
    expect(onePercent.unexpectedRate).toBe(.01);
    expect(stopReasons(onePercent)).toContain('UNEXPECTED_ERRORS_AT_LEAST_1_PERCENT');
    expect(stopReasons(summarize(Array.from({ length: 125 }, () => sample(20))), ['duplicateVisits'])).toContain('INTEGRITY_duplicateVisits');
    expect(stopReasons(summarize([]))).toEqual([]);
  });
  it('reports actual requests and status counts instead of conflating phones with requests', () => {
    const result = summarize([sample(10), sample(50), sample(100, true)], 2000);
    expect(result).toMatchObject({ requests: 3, unexpected: 1, p50Ms: 50, p95Ms: 100, p99Ms: 100, requestsPerSecond: 1.5, statusCounts: { '200': 2, '503': 1 } });
  });
  it('reports aggregate database deltas and refuses reset or regressing counters', () => {
    const before = { statsReset: '2026-11-03T00:00:00Z', commits: 100, rollbacks: 2, blocksRead: 10, blocksHit: 1000, deadlocks: 0, tempFiles: 0, tempBytes: 0, blockReadMs: 1.5, blockWriteMs: 0 };
    const after = { ...before, commits: 140, blocksRead: 13, blocksHit: 2000, blockReadMs: 2.2 };
    expect(databaseCounterDelta(before, after)).toMatchObject({ reset: false, counters: { commits: 40, blocksRead: 3, blocksHit: 1000, deadlocks: 0 } });
    expect(databaseCounterDelta(before, { ...after, statsReset: '2026-11-03T01:00:00Z' })).toEqual({ reset: true, counters: null });
    expect(databaseCounterDelta(before, { ...after, blocksHit: 0 })).toEqual({ reset: true, counters: null });
    expect(databaseCounterDelta(null, after)).toEqual({ reset: true, counters: null });
  });
  it('spreads reconnects deterministically inside a bounded window and refuses a larger fixture budget', () => {
    const offsets = reconnectOffsets(125, 'repeatable-run');
    expect(offsets).toEqual(reconnectOffsets(125, 'repeatable-run'));
    expect(Math.min(...offsets)).toBeGreaterThanOrEqual(0);
    expect(Math.max(...offsets)).toBeLessThanOrEqual(5000);
    expect(new Set(offsets).size).toBeGreaterThan(100);
    expect(offsets).not.toEqual(Array.from({ length: 125 }, () => 0));
    expect(() => reconnectOffsets(126, 'run')).toThrow('INVALID_RECONNECT_BUDGET');
  });
  it('coalesces six simultaneous subscribers, then permits a genuinely new snapshot', async () => {
    const read = vi.fn(async () => ({ version: 7 }));
    const shared = coalesceSnapshot(read);
    const replies = await Promise.all(Array.from({ length: 6 }, shared));
    expect(read).toHaveBeenCalledTimes(1);
    expect(replies.every(reply => reply === replies[0])).toBe(true);
    await shared();
    expect(read).toHaveBeenCalledTimes(2);
  });
});

describe('503 queue recovery preserves authoritative commands', () => {
  it('retries the same command ID, destination and version after response loss, without early confirmation', async () => {
    const waits: number[] = [], bodies: QueuedLoadCommand[] = [];
    const send = vi.fn(async (body: QueuedLoadCommand) => { bodies.push(structuredClone(body)); return bodies.length === 1 ? { status: 503 } : { status: 200, value: { receipt: 'one' } }; });
    const result = await recoverQueuedCommand(send, queued, { wait: async ms => { waits.push(ms); } });
    expect(result).toMatchObject({ confirmed: true, attempts: 2, state: 'confirmed', value: { receipt: 'one' } });
    expect(bodies).toEqual([queued, queued]);
    expect(waits).toHaveLength(1);
    expect(waits[0]).toBeGreaterThanOrEqual(350);
    expect(waits[0]).toBeLessThanOrEqual(550);
  });
  it('leaves repeated 503s pending after bounded retries and never invents a visit', async () => {
    const send = vi.fn(async () => ({ status: 503 }));
    const result = await recoverQueuedCommand(send, queued, { wait: async () => {}, maxAttempts: 4 });
    expect(send).toHaveBeenCalledTimes(4);
    await expect(recoverQueuedCommand(send, queued, { maxAttempts: 5 })).rejects.toThrow('UNSAFE_QUEUE_RETRY_BUDGET');
    expect(result).toEqual({ state: 'pending-no-confirmation', attempts: 4, confirmed: false });
  });
  it('stops on route conflict and rejects payments or unversioned offline commands', async () => {
    const send = vi.fn(async () => ({ status: 409 }));
    expect(await recoverQueuedCommand(send, queued)).toEqual({ state: 'conflict-fetch-current', attempts: 1, confirmed: false });
    expect(send).toHaveBeenCalledTimes(1);
    await expect(recoverQueuedCommand(send, { ...queued, operation: 'payment.checkout' })).rejects.toThrow('UNSAFE_QUEUED_COMMAND');
  });
});

describe('load execution binding and no-send surface', () => {
  it('accepts only the exact verified staging release with explicit contract-only load scope', () => {
    expect(assertLoadBinding(env).projectRef).toBe('nocteiuvohesvqbowchw');
    for (const change of [{ APP_ENVIRONMENT: 'production' }, { SUPABASE_PROJECT_REF: 'dtubngvxfbupgvgfrjko' }, { FRIGHTNIGHT_PAYMENT_PROVIDER: 'mollie' }, { FRIGHTNIGHT_VERIFIED_RELEASE_SHA: 'b'.repeat(40) }, { FRIGHTNIGHT_LOAD_APPROVAL: '' }]) expect(() => assertLoadBinding({ ...env, ...change })).toThrow();
  });
  it('uses new confirmed password sessions and archiving; never OTP, real provider, auth-delete or legacy reset', () => {
    const source = readFileSync('scripts/acceptance/frightnight-load.mjs', 'utf8');
    expect(source).toContain('createUser({ email, password, email_confirm: true');
    expect(source).toContain('signInWithPassword');
    expect(source).not.toMatch(/signInWithOtp|inviteUserByEmail|deleteUser|truncate|drop table|api\.mollie\.com/i);
    expect(source).toContain("p_command: 'test.reset'");
    expect(source).toContain("synthetic_frightnight_load");
    expect(source).toContain('round <= 5');
    expect(source).toContain("request(b,'party.leave')");
    expect(source).toContain("waitingOnLock");
    expect(source).not.toMatch(/pg_stat_activity[\s\S]{0,100}query\s*[,)]/);
    expect(LOAD_STEPS.at(-1)).toBe(125);
  });
});
