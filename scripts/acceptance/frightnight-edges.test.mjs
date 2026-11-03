import test from 'node:test';
import assert from 'node:assert/strict';
import { runEdgeAcceptance } from './frightnight-edges.mjs';
import { runRegieAcceptance } from './frightnight-regie.mjs';

const revision = 'a'.repeat(40);
const parent = '00000000-0000-4000-8000-000000000001';
const people = Array.from({ length: 5 }, (_, index) => ({ id: `00000000-0000-4000-8000-00000000000${index + 2}`, email: `edge-${index}@example.invalid`, context: {} }));
const scope = { base: 'https://staging-halloween.duindorpdoet.nl', slug: 'frightnight-2027-test-acceptance-guard', eventId: parent, run: 'guard-only', admin: people[0], a: people[1], b: people[2], resident: people[3], support: people[4], armContract: async () => { throw new Error('Guard fixture must never arm a sandbox'); }, assert: (value, code) => assert.ok(value, code), literal: value => `'${String(value).replaceAll("'", "''")}'` };

async function guarded(overrides, expected, rowCount = 5, environment = {}) {
  const previous = Object.fromEntries(['GITHUB_SHA', 'FRIGHTNIGHT_VERIFIED_RELEASE_SHA', 'FRIGHTNIGHT_PAYMENT_PROVIDER'].map(key => [key, process.env[key]]));
  Object.assign(process.env, { GITHUB_SHA: revision, FRIGHTNIGHT_VERIFIED_RELEASE_SHA: revision, FRIGHTNIGHT_PAYMENT_PROVIDER: 'contract', ...environment });
  let reads = 0; let writes = 0; let commands = 0;
  try {
    await assert.rejects(runEdgeAcceptance({ ...scope, sql: async (_query, write) => { if (write) writes++; else reads++; return [{ n: rowCount }]; }, app: async () => { commands++; }, ...overrides }), new RegExp(expected));
    assert.equal(writes, 0); assert.equal(commands, 0);
    return reads;
  } finally {
    for (const [key, value] of Object.entries(previous)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
}

test('edge acceptance rejects production and local origins before any database request', async () => {
  for (const base of ['https://halloween.duindorpdoet.nl', 'http://127.0.0.1:3137']) assert.equal(await guarded({ base }, 'EDGE_STAGING_ORIGIN_REQUIRED'), 0);
});
test('edge acceptance requires a separate own acceptance parent', async () => {
  assert.equal(await guarded({ slug: 'frightnight-2027-test' }, 'EDGE_PARENT_SCOPE_REQUIRED'), 0);
});
test('edge acceptance rejects existing real actors before reading or writing fixtures', async () => {
  assert.equal(await guarded({ a: { ...people[1], email: 'existing@example.org' } }, 'EDGE_EXISTING_INVALID_ACTORS_REQUIRED'), 0);
});
test('edge acceptance requires all existing actors to belong to the exact new parent run', async () => {
  assert.equal(await guarded({}, 'EDGE_ACTOR_RUN_BINDING_REQUIRED', 4), 1);
});

test('edge acceptance requires exact verified published revision before any database request', async () => {
  assert.equal(await guarded({}, 'EDGE_VERIFIED_RELEASE_REQUIRED', 5, { FRIGHTNIGHT_VERIFIED_RELEASE_SHA: 'b'.repeat(40) }), 0);
});
test('edge acceptance refuses an unknown configured payment provider before fixture creation', async () => {
  assert.equal(await guarded({}, 'EDGE_CONFIGURED_PROVIDER_REQUIRED', 5, { FRIGHTNIGHT_PAYMENT_PROVIDER: 'unknown' }), 0);
});
test('edge acceptance requires the authoritative child-sandbox helper for both configured providers', async () => {
  for (const provider of ['contract', 'mollie']) assert.equal(await guarded({ armContract: undefined }, 'EDGE_CONTRACT_ARM_HELPER_REQUIRED', 5, { FRIGHTNIGHT_PAYMENT_PROVIDER: provider }), 0);
});
test('Mollie configuration never bypasses the fresh synthetic actor binding', async () => {
  assert.equal(await guarded({}, 'EDGE_ACTOR_RUN_BINDING_REQUIRED', 4, { FRIGHTNIGHT_PAYMENT_PROVIDER: 'mollie' }), 1);
});

test('regie acceptance requires a server sandbox helper before any fixture read', async () => {
  const previous = [process.env.GITHUB_SHA, process.env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA];
  Object.assign(process.env, { GITHUB_SHA: revision, FRIGHTNIGHT_VERIFIED_RELEASE_SHA: revision });
  let reads = 0;
  try {
    await assert.rejects(runRegieAcceptance({ ...scope, armContract: undefined, sql: async () => { reads++; } }), /REGIE_CONTRACT_ARM_HELPER_REQUIRED/);
    assert.equal(reads, 0);
  } finally {
    for (const [index, key] of ['GITHUB_SHA', 'FRIGHTNIGHT_VERIFIED_RELEASE_SHA'].entries()) if (previous[index] === undefined) delete process.env[key]; else process.env[key] = previous[index];
  }
});

for (const fault of ['wrong-event', 'stale-run', 'missing-readback']) test(`Mollie-configured edge stops before seed/checkout on sandbox ${fault}`, async () => {
  const previous = Object.fromEntries(['GITHUB_SHA', 'FRIGHTNIGHT_VERIFIED_RELEASE_SHA', 'FRIGHTNIGHT_PAYMENT_PROVIDER'].map(key => [key, process.env[key]]));
  Object.assign(process.env, { GITHUB_SHA: revision, FRIGHTNIGHT_VERIFIED_RELEASE_SHA: revision, FRIGHTNIGHT_PAYMENT_PROVIDER: 'mollie' });
  const childId = '00000000-0000-4000-8000-000000000009';
  const originalRun = '00000000-0000-4000-8000-000000000010';
  const nextRun = '00000000-0000-4000-8000-000000000011';
  const state = { id: childId, slug: '', runId: originalRun, environment: 'staging', test: true, closed: false, version: 1, paymentPolicy: 'configured', sandboxRunId: null, contractSandboxArmed: false };
  const operations = [];
  const context = { setOffline: async () => {}, request: {
    get: async url => ({ ok: () => true, json: async () => url.endsWith('/api/health') ? { paymentProvider: 'mollie' } : { data: { event: { ...state } } } }),
    post: async (_url, options) => ({ ok: () => true, json: async () => ({ data: { selected: options.data.slug } }) }),
  } };
  const actors = people.map(actor => ({ ...actor, context }));
  const app = async (_actor, operation, payload) => {
    operations.push(operation);
    if (operation === 'test.copy') state.slug = payload.slug;
    if (operation === 'test.reset') state.runId = nextRun;
    if (operation === 'admin.settings') { state.closed = payload.closed; state.version++; }
    return { status: 200, value: { ok: true, result: { eventId: childId } } };
  };
  const armContract = async ({ slug, eventId }) => ({ slug, eventId: fault === 'wrong-event' ? parent : eventId, runId: fault === 'stale-run' ? nextRun : originalRun, provider: 'contract' });
  const sql = async query => query.includes('from auth.users where') ? [{ n: 5 }] : query.includes('not synthetic') ? [{ n: 0 }] : [{ digest: 'unchanged-parent', orders: 'unchanged-orders', ledger: 'unchanged-ledger', audit_count: 1 }];
  try {
    await assert.rejects(runEdgeAcceptance({ ...scope, admin: actors[0], a: actors[1], b: actors[2], resident: actors[3], support: actors[4], app, sql, armContract, checked: () => {}, report: { checks: [], screenshots: [] } }), fault === 'missing-readback' ? /EDGE_CONTRACT_ARM_READBACK_REQUIRED/ : /EDGE_CONTRACT_ARM_BINDING_MISMATCH/);
    assert.equal(operations.includes('test.seed'), false);
    assert.equal(operations.includes('payment.checkout'), false);
    assert.equal(state.closed, true);
    assert.equal(state.runId, nextRun);
  } finally {
    for (const [key, value] of Object.entries(previous)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
});
