import test from 'node:test';
import assert from 'node:assert/strict';
import { runEdgeAcceptance } from './frightnight-edges.mjs';

const revision = 'a'.repeat(40);
const parent = '00000000-0000-4000-8000-000000000001';
const people = Array.from({ length: 5 }, (_, index) => ({ id: `00000000-0000-4000-8000-00000000000${index + 2}`, email: `edge-${index}@example.invalid`, context: {} }));
const scope = { base: 'https://staging-halloween.duindorpdoet.nl', slug: 'frightnight-2027-test-acceptance-guard', eventId: parent, run: 'guard-only', admin: people[0], a: people[1], b: people[2], resident: people[3], support: people[4], assert: (value, code) => assert.ok(value, code), literal: value => `'${String(value).replaceAll("'", "''")}'` };

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
test('edge acceptance refuses external payment providers before fixture creation', async () => {
  assert.equal(await guarded({}, 'EDGE_CONTRACT_ONLY_REQUIRED', 5, { FRIGHTNIGHT_PAYMENT_PROVIDER: 'mollie' }), 0);
});
