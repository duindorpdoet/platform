// Local-only ENV04 proof. Secrets stay in memory; this never contacts staging.
import { readFileSync, writeFileSync, openSync, closeSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';
import { createRequire } from 'node:module';
import { randomUUID, createHash } from 'node:crypto';
import net from 'node:net';

const root = '/home/codex/repos/duindorphalloween-frightnight-2027';
const base = 'http://127.0.0.1:3140';
const gateway = 'http://127.0.0.1:63561';
const guard = new URL('./network-guard.mjs', import.meta.url).pathname;
await import(guard);
const require = createRequire(root + '/package.json');
const { createServerClient } = require('@supabase/ssr');
const qaEnv = parseEnv(readFileSync(root + '/.env.local', 'utf8'));
const assert = (condition, code) => { if (!condition) throw new Error(code); };
assert(qaEnv.NEXT_PUBLIC_SUPABASE_URL === gateway, 'LOCAL_GATEWAY_REQUIRED');
assert(qaEnv.FRIGHTNIGHT_PAYMENT_PROVIDER === 'contract', 'CONTRACT_ONLY_QA_REQUIRED');
assert(qaEnv.APP_URL === 'https://staging-halloween.duindorpdoet.nl', 'UNCHANGED_CHECKOUT_ORIGIN_REQUIRED');
const persona = JSON.parse(readFileSync('/tmp/frightnight-local-gateway/personas.json', 'utf8')).admin;
assert(persona.session?.user?.email?.endsWith('@example.invalid'), 'SYNTHETIC_LOCAL_ACTOR_REQUIRED');
const jar = new Map();
const client = createServerClient(gateway, qaEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY, {
  cookies: { getAll: () => [...jar].map(([name, value]) => ({ name, value })), setAll: cookies => cookies.forEach(cookie => jar.set(cookie.name, cookie.value)) },
});
const authenticated = await client.auth.signInWithPassword({ email: persona.session.user.email, password: persona.password });
assert(!authenticated.error && authenticated.data.session?.user.id === persona.id, 'EXISTING_SYNTHETIC_SESSION_REQUIRED');
const hash = value => createHash('sha256').update(value).digest('hex');
const literal = value => "'" + String(value).replaceAll("'", "''") + "'";
function sql(query) {
  const result = execFileSync('docker', ['exec', '-i', 'supabase_db_duindorp_event_close_20261101', 'psql', '-U', 'postgres', '-d', 'frightnight_2027_dev', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], { input: query, encoding: 'utf8', maxBuffer: 1024 * 1024 });
  return JSON.parse(result.trim());
}
let server;
let eventId;
let runId;
const ownedSlug = 'frightnight-2027-test-env04-' + randomUUID().slice(0, 8);
const report = { startedAt: new Date().toISOString(), localOnly: true, origin: base, buildId: readFileSync(root + '/.next/BUILD_ID', 'utf8').trim(), sourceRevision: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), checks: [], serverPids: [], remoteWrites: 0, otpRequests: 0, externalDeliveryClaim: false };
report.variantPids = {};
report.standaloneEnvironmentFilePresence = Object.fromEntries(['.env', '.env.local', '.env.production', '.env.production.local'].map(name => { try { readFileSync(root + '/.next/standalone/' + name); return [name, true]; } catch { return [name, false]; } }));
async function request(path, body) {
  const response = await fetch(base + path, { method: body ? 'POST' : 'GET', headers: { Cookie: [...jar].map(([key, value]) => key + '=' + value).join('; '), ...(body ? { Origin: base, 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(15000) });
  for (const cookie of response.headers.getSetCookie()) { const pair = cookie.split(';')[0]; const index = pair.indexOf('='); jar.set(pair.slice(0, index), pair.slice(index + 1)); }
  const text = await response.text();
  let data; try { data = JSON.parse(text); } catch { data = null; }
  return { status: response.status, data, bodyIsNonempty: text.length > 0 };
}
async function command(operation, payload = {}, key = randomUUID()) {
  const result = await request('/api/frightnight/command', { commandId: key, operation, payload });
  assert(result.status === 200, 'LOCAL_COMMAND_' + operation.replaceAll('.', '_') + '_' + result.status + '_' + (result.data?.error?.code ?? 'ERROR'));
  return result.data.data;
}
async function snapshot() {
  const result = await request('/api/frightnight/snapshot');
  assert(result.status === 200, 'LOCAL_SNAPSHOT_REQUIRED');
  return result.data.data;
}
function fingerprint() {
  return sql(`select json_build_object('legacyOutboxCount',(select count(*) from app_private.email_outbox),'legacyOutboxDigest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(m) order by m.id)::text,''),'sha256'),'hex') from app_private.email_outbox m),'ownOrders',(select count(*) from app_private.fn_orders where event_id=${literal(eventId)}::uuid),'ownLedger',(select count(*) from app_private.fn_ledger where event_id=${literal(eventId)}::uuid),'ownSink',(select count(*) from app_private.fn_mail_sink where event_id=${literal(eventId)}::uuid),'unsafeOwnSink',(select count(*) from app_private.fn_mail_sink where event_id=${literal(eventId)}::uuid and (environment<>'staging' or delivery_mode<>'sink')),'ownAudit',(select count(*) from app_private.fn_audit where event_id=${literal(eventId)}::uuid),'ordersDigest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(o) order by o.id)::text,''),'sha256'),'hex') from app_private.fn_orders o where o.event_id=${literal(eventId)}::uuid),'sinkDigest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(m) order by m.id)::text,''),'sha256'),'hex') from app_private.fn_mail_sink m where m.event_id=${literal(eventId)}::uuid))`);
}
async function freePort() {
  const test = net.createServer();
  await new Promise((resolve, reject) => { test.once('error', reject); test.listen(3140, '127.0.0.1', resolve); });
  await new Promise(resolve => test.close(resolve));
}
async function start(mode) {
  await freePort();
  const childEnv = { PATH: process.env.PATH, LANG: 'C.UTF-8', ...qaEnv, HOSTNAME: '127.0.0.1', PORT: '3140', NEXT_PUBLIC_SITE_URL: base, ALLOWED_ORIGINS: base };
  if (mode === 'missing') delete childEnv.FRIGHTNIGHT_MAIL_MODE; else childEnv.FRIGHTNIGHT_MAIL_MODE = mode;
  assert(childEnv.APP_URL === qaEnv.APP_URL, 'CHECKOUT_ORIGIN_CHANGED');
  const log = openSync('/tmp/frightnight-env04-' + mode + '.log', 'w', 0o600);
  server = spawn(process.execPath, ['--import', guard, root + '/.next/standalone/server.js'], { cwd: root, env: childEnv, stdio: ['ignore', log, log] });
  closeSync(log);
  report.serverPids.push(server.pid);
  report.variantPids[mode] ??= server.pid;
  const expires = Date.now() + 15000;
  while (Date.now() < expires) {
    if (server.exitCode !== null) throw new Error('LOCAL_SERVER_START_FAILED');
    const open = await new Promise(resolve => { const socket = net.connect({ port: 3140, host: '127.0.0.1' }); socket.once('connect', () => { socket.destroy(); resolve(true); }); socket.once('error', () => resolve(false)); });
    if (open) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('LOCAL_SERVER_START_TIMEOUT');
}
async function stop() {
  if (!server) return;
  const stopped = new Promise(resolve => server.once('exit', resolve));
  server.kill('SIGTERM');
  await Promise.race([stopped, new Promise(resolve => setTimeout(resolve, 3000))]);
  if (server.exitCode === null) { server.kill('SIGKILL'); await stopped; }
  server = null;
}
try {
  await start('missing');
  const original = await snapshot();
  assert(original.actor.capabilities.includes('event_admin'), 'LOCAL_ADMIN_REQUIRED');
  const copied = await command('test.copy', { slug: ownedSlug });
  eventId = copied.result.eventId;
  const selected = await request('/api/frightnight/edition', { slug: ownedSlug });
  assert(selected.status === 200, 'OWN_PRIVATE_EDITION_SELECTION_FAILED');
  const initial = await snapshot(); runId = initial.event.runId;
  assert(initial.event.id === eventId && initial.event.slug === ownedSlug && initial.event.test && initial.event.environment === 'staging', 'OWN_PRIVATE_EDITION_REQUIRED');
  report.edition = { slug: ownedSlug, eventId, runId, syntheticActorSha256: hash(persona.id) };
  await command('test.payment.sandbox', { confirmation: ownedSlug, runId });
  await command('test.seed');
  const seeded = await snapshot();
  const registration = seeded.registrations.find(row => row.paymentStatus !== 'paid');
  assert(registration?.id && seeded.event.runId === runId, 'OWN_SYNTHETIC_REGISTRATION_REQUIRED');
  const registrationScope = sql(`select json_build_object('owned',exists(select 1 from app_private.fn_registrations where id=${literal(registration.id)}::uuid and event_id=${literal(eventId)}::uuid and run_id=${literal(runId)}::uuid and synthetic and owner_id is null))`);
  assert(registrationScope.owned, 'OWN_OWNERLESS_SEED_REGISTRATION_REQUIRED');
  const before = fingerprint();
  const key = randomUUID();
  await command('test.payment', { registrationId: registration.id, status: 'paid', scenario: 'normal' }, key);
  const first = fingerprint();
  await command('test.payment', { registrationId: registration.id, status: 'paid', scenario: 'normal' }, key);
  const after = fingerprint();
  assert(after.ownSink > before.ownSink && after.unsafeOwnSink === 0, 'MISSING_MODE_NOT_DURABLE_SINK_ONLY');
  assert(after.ownSink === first.ownSink && after.ownOrders === first.ownOrders && after.ownLedger === first.ownLedger, 'MISSING_MODE_RETRY_CHANGED_FINANCIAL_EFFECT');
  assert(after.legacyOutboxCount === before.legacyOutboxCount && after.legacyOutboxDigest === before.legacyOutboxDigest, 'MISSING_MODE_LEGACY_MAIL_EFFECT');
  report.checks.push({ label: 'missing runtime mail policy defaults to durable sink, actual paid command and retry', status: 'passed', variablePresent: false, sinkRecordsAdded: after.ownSink - before.ownSink, unintendedLegacyOutboxRows: 0, legacyOutboxContentUnchanged: true, unsafeSinkRecords: 0, duplicateFinancialEffect: false });
  await stop();
  await start('allowlist');
  const allowlistedSnapshot = await snapshot();
  const secondRegistration = allowlistedSnapshot.registrations.find(row => row.paymentStatus !== 'paid');
  assert(secondRegistration?.id, 'SECOND_OWN_SEED_REGISTRATION_REQUIRED');
  const secondScope = sql(`select json_build_object('owned',exists(select 1 from app_private.fn_registrations where id=${literal(secondRegistration.id)}::uuid and event_id=${literal(eventId)}::uuid and run_id=${literal(runId)}::uuid and synthetic and owner_id is null))`);
  assert(secondScope.owned, 'SECOND_OWN_OWNERLESS_SEED_REGISTRATION_REQUIRED');
  const beforeAllowlist = fingerprint();
  await command('test.payment', { registrationId: secondRegistration.id, status: 'paid', scenario: 'normal' });
  const afterAllowlist = fingerprint();
  assert(afterAllowlist.ownSink === beforeAllowlist.ownSink + 1 && afterAllowlist.unsafeOwnSink === 0 && afterAllowlist.legacyOutboxCount === beforeAllowlist.legacyOutboxCount && afterAllowlist.legacyOutboxDigest === beforeAllowlist.legacyOutboxDigest, 'ALLOWLIST_MODE_ESCAPED_DATABASE_SINK');
  report.checks.push({ label: 'valid allowlist runtime policy still cannot escape database staging sink', status: 'passed', sinkRecordsAdded: 1, unsafeSinkRecords: 0, unintendedLegacyOutboxRows: 0, legacyOutboxContentUnchanged: true });
  await stop();
  await start('live');
  const beforeInvalid = fingerprint();
  const invalidSnapshot = await request('/api/frightnight/snapshot');
  const invalidCommand = await request('/api/frightnight/command', { commandId: randomUUID(), operation: 'test.payment', payload: { registrationId: registration.id, status: 'paid', scenario: 'normal' } });
  const afterInvalid = fingerprint();
  assert(invalidSnapshot.status >= 400 && invalidCommand.status >= 400 && invalidCommand.bodyIsNonempty, 'INVALID_MAIL_POLICY_NOT_FAIL_CLOSED');
  assert(Object.hasOwn(invalidCommand.data?.error?.fields ?? {}, 'FRIGHTNIGHT_MAIL_MODE'), 'INVALID_EFFECTIVE_MAIL_POLICY_NOT_REPORTED');
  assert(JSON.stringify(beforeInvalid) === JSON.stringify(afterInvalid), 'INVALID_MAIL_POLICY_CHANGED_DATABASE');
  report.checks.push({ label: 'invalid live runtime mail policy blocks real snapshot and payment handler before mutation', status: 'passed', snapshotStatus: invalidSnapshot.status, commandStatus: invalidCommand.status, visibleFailure: true, apiErrorCode: invalidCommand.data?.error?.code ?? null, databaseAggregatesUnchanged: true, unintendedLegacyOutboxRows: 0, additionalSinkRecords: 0 });
  report.status = 'passed';
} catch (error) { report.status = 'failed'; report.failure = /^[A-Z0-9_]+$/.test(error.message) ? error.message : 'LOCAL_HARNESS_FAILED'; process.exitCode = 1; }
finally {
  await stop();
  if (eventId && runId) {
    try {
      await start('missing');
      const current = await snapshot();
      assert(current.event.id === eventId && current.event.slug === ownedSlug && current.event.runId === runId, 'LOCAL_CLEANUP_SCOPE_REQUIRED');
      const financialBefore = fingerprint();
      await command('test.reset', { confirmation: ownedSlug, runId });
      const reset = await snapshot();
      await command('admin.settings', { closed: true, expectedVersion: reset.event.version, confirmation: ownedSlug, reason: 'Eigen lokale ENV04-variant afgerond; behoud financiële en auditgegevens' });
      const financialAfter = fingerprint();
      assert(financialBefore.ordersDigest === financialAfter.ordersDigest && financialBefore.sinkDigest === financialAfter.sinkDigest && financialBefore.ownLedger === financialAfter.ownLedger && financialBefore.legacyOutboxDigest === financialAfter.legacyOutboxDigest, 'LOCAL_CLEANUP_HISTORY_CHANGED');
      report.cleanup = { status: 'passed', exactOwnEditionOnly: true, archivedAndClosed: true, authDeleted: 0, historicalDataDeleted: 0, financialAndMailHistoryPreserved: true };
    } catch { report.cleanup = { status: 'failed', blindReset: false }; report.status = 'failed'; process.exitCode = 1; }
    await stop();
  }
  const rows = readFileSync('/tmp/frightnight-env04-network.jsonl', 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)).filter(row => report.serverPids.includes(row.pid) || row.pid === process.pid);
  const network = rows.filter(row => row.phase === 'fetch');
  report.effectiveRuntimePolicy = { missingAfterNextInitialization: network.some(row => row.pid === report.variantPids.missing && row.mailPolicyClass === 'missing' && row.mailPolicyVariablePresent === false), allowlistAfterNextInitialization: network.some(row => row.pid === report.variantPids.allowlist && row.mailPolicyClass === 'allowlist' && row.mailPolicyVariablePresent === true), invalidFieldReportedByRealHandler: report.checks.some(check => check.apiErrorCode === 'VALIDATION_ERROR') };
  report.network = { nativeFetchGuard: true, calls: network.length, blockedExternalAttempts: network.filter(row => row.blocked).length, externalDeliveries: 0, note: 'Only loopback native fetch permitted; no SMTP/PSP provider proof is claimed.' };
  if (!Object.values(report.effectiveRuntimePolicy).every(Boolean)) { report.status = 'failed'; report.failure = 'EFFECTIVE_RUNTIME_POLICY_NOT_PROVEN'; process.exitCode = 1; }
  if (report.network.blockedExternalAttempts !== 0) { report.status = 'failed'; report.failure = 'UNEXPECTED_EXTERNAL_NETWORK_ATTEMPT'; process.exitCode = 1; }
  report.completedAt = new Date().toISOString();
  report.sourceSha256 = { harness: hash(readFileSync(import.meta.filename)), networkGuard: hash(readFileSync(guard)), serverEnv: hash(readFileSync(root + '/lib/config/server-env.ts')), compiledServer: hash(readFileSync(root + '/.next/standalone/server.js')) };
  writeFileSync(root + '/docs/frightnight-2027/evidence/local-final-mail-policy/report.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ status: report.status, checks: report.checks.length, cleanup: report.cleanup?.status, failure: report.failure, externalAttempts: report.network.blockedExternalAttempts }));
}
