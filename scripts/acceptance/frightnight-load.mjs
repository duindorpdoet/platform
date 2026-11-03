// Bounded post-release staging exercise. Importing this module never uses network
// or credentials. `--plan` is read-only; execution needs the verified release gate.
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { assertFrightnightRelease, assertFrightnightHostedRelease, assertFrightnightContractArm, assertFrightnightContractSnapshot, assertFrightnightContractOrder, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from '../deploy/frightnight-release.mjs';

export const LOAD_STEPS = Object.freeze([12, 25, 50, 100, 125]);
export const LOAD_LIMITS = Object.freeze({ p95Ms: 2_000, unexpectedRate: 0.01, maxActors: 125, maxInFlight: 125, walkDurationMs: 60_000, maxRequestsPerStage: 5_000 });
export function loadPlan(startCapacity = 100, maximum = 125) {
  if (startCapacity !== 100 || !LOAD_STEPS.includes(maximum)) throw new Error('REVIEWED_100_PLACE_TEST_BUDGET_REQUIRED');
  return { configuredStartPlaces: 100, baseline: '100 one-person registrations and 100 phones at one configured start block', margin: '25% staging test margin', peakPhones: 125, attendanceForecast: false, actorLimit: 125, steps: LOAD_STEPS.filter(n => n <= maximum), limits: LOAD_LIMITS, provider: 'contract only; no external PSP calls', fixtureScope: 'fresh sibling edition per step; only this run’s new synthetic actors', notMeasured: ['database/VPS CPU', 'database/VPS memory', 'pool wait duration and individual query timing', 'mobile radio and camera', 'external provider throughput'] };
}
export function percentile(values, quantile) {
  if (!Number.isFinite(quantile) || quantile <= 0 || quantile > 1 || values.some(n => !Number.isFinite(n) || n < 0)) throw new Error('INVALID_METRIC_SAMPLE');
  if (!values.length) return null;
  return [...values].sort((a, b) => a - b)[Math.ceil(values.length * quantile) - 1];
}
export function summarize(samples, elapsedMs = 0) {
  if (!Number.isFinite(elapsedMs) || elapsedMs < 0) throw new Error('INVALID_METRIC_WINDOW');
  const times = samples.map(s => s.latencyMs);
  const unexpected = samples.filter(s => s.unexpected).length;
  const statusCounts = {};
  for (const sample of samples) statusCounts[String(sample.status)] = (statusCounts[String(sample.status)] ?? 0) + 1;
  return { requests: samples.length, unexpected, unexpectedRate: samples.length ? unexpected / samples.length : 0, p50Ms: percentile(times, .5), p95Ms: percentile(times, .95), p99Ms: percentile(times, .99), maxMs: percentile(times, 1), elapsedMs: Math.round(elapsedMs), requestsPerSecond: elapsedMs > 0 ? samples.length * 1000 / elapsedMs : null, statusCounts };
}
export function databaseCounterDelta(before, after) {
  const fields = ['commits','rollbacks','blocksRead','blocksHit','deadlocks','tempFiles','tempBytes','blockReadMs','blockWriteMs'];
  if (!before || !after || before.statsReset !== after.statsReset || fields.some(k => !Number.isFinite(Number(before[k])) || !Number.isFinite(Number(after[k])) || Number(after[k]) < Number(before[k]))) return { reset: true, counters: null };
  return { reset: false, counters: Object.fromEntries(fields.map(k => [k, Number(after[k]) - Number(before[k])])) };
}
export function stopReasons(summary, integrityErrors = []) {
  return [...integrityErrors.map(code => `INTEGRITY_${code}`), ...(summary.p95Ms > LOAD_LIMITS.p95Ms ? ['P95_ABOVE_2_SECONDS'] : []), ...(summary.requests > 0 && summary.unexpectedRate >= LOAD_LIMITS.unexpectedRate ? ['UNEXPECTED_ERRORS_AT_LEAST_1_PERCENT'] : [])];
}
function hash32(value) {
  let hash = 2166136261;
  for (const letter of String(value)) { hash ^= letter.charCodeAt(0); hash = Math.imul(hash, 16777619); }
  return hash >>> 0;
}
export function reconnectOffsets(phones, seed, windowMs = 5_000) {
  if (!Number.isInteger(phones) || phones < 1 || phones > LOAD_LIMITS.maxActors || !Number.isInteger(windowMs) || windowMs < 1) throw new Error('INVALID_RECONNECT_BUDGET');
  return Array.from({ length: phones }, (_, index) => hash32(`${seed}:${index}`) % (windowMs + 1));
}
export function coalesceSnapshot(read) {
  let pending;
  return () => pending ??= Promise.resolve().then(read).finally(() => { pending = undefined; });
}
export async function recoverQueuedCommand(send, command, { wait = ms => new Promise(resolve => setTimeout(resolve, ms)), maxAttempts = 4, seed = command.commandId } = {}) {
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 4) throw new Error('UNSAFE_QUEUE_RETRY_BUDGET');
  if (command.operation !== 'journey.complete' || !command.commandId || !command.payload.destinationId || !Number.isInteger(command.payload.expectedVersion)) throw new Error('UNSAFE_QUEUED_COMMAND');
  let attempts = 0;
  for (; attempts < maxAttempts; attempts++) {
    const response = await send(command);
    if (response.status === 409) return { state: 'conflict-fetch-current', attempts: attempts + 1, confirmed: false };
    if (response.status >= 200 && response.status < 300) return { state: 'confirmed', attempts: attempts + 1, confirmed: true, value: response.value };
    if (![0, 429, 502, 503, 504].includes(response.status)) return { state: 'rejected', attempts: attempts + 1, confirmed: false };
    if (attempts + 1 < maxAttempts) await wait(Math.min(3_000, 350 * 2 ** attempts) + hash32(`${seed}:${attempts}`) % 201);
  }
  return { state: 'pending-no-confirmation', attempts, confirmed: false };
}
export function assertLoadBinding(env) {
  const target = assertFrightnightRelease(env);
  if (!/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? '') || env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA !== env.GITHUB_SHA) throw new Error('VERIFIED_BACKUP_PRESERVATION_AND_RELEASE_REQUIRED');
  if (env.FRIGHTNIGHT_LOAD_APPROVAL !== `${target.projectRef}:staging:duindorphalloweenstg`) throw new Error('EXPLICIT_VERIFIED_STAGING_LOAD_SCOPE_REQUIRED');
  for (const key of ['NEXT_PUBLIC_SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_ACCESS_TOKEN']) if (!env[key]) throw new Error(`LOAD_MISSING_${key}`);
  return target;
}
const sqlLiteral = value => `'${String(value).replaceAll("'", "''")}'`;
const uuid = value => { if (!/^[0-9a-f-]{36}$/.test(value ?? '')) throw new Error('INVALID_FIXTURE_ID'); return `${sqlLiteral(value)}::uuid`; };
const check = (condition, code) => { if (!condition) throw new Error(code); };
const sleep = ms => new Promise(resolve => setTimeout(resolve, Math.max(0, ms)));
const safeError = error => /^[A-Z0-9_:.+-]{1,180}$/.test(error?.message ?? '') ? error.message : 'LOAD_CHECK_OR_TRANSPORT_FAILED';

export async function runStagingLoad(env = process.env, maximum = 125) {
  const target = assertLoadBinding(env);
  const plan = loadPlan(100, maximum);
  const { createClient } = await import('@supabase/supabase-js');
  const { createServerClient } = await import('@supabase/ssr');
  const sbUrl = `https://${target.projectRef}.supabase.co`;
  const run = `${Date.now()}-${randomUUID().slice(0, 8)}`;
  const prefix = `frightnight-2027-test-load-${run}-`;
  const service = createClient(sbUrl, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const report = { scope: 'verified-staging-fresh-synthetic-no-send', revision: env.GITHUB_SHA, origin: target.origin, projectRef: target.projectRef, run, plan, startedAt: new Date().toISOString(), stages: [], contractSandboxes: [], status: 'running', claims: 'no performance result until this script has completed on the verified release', externalProviderRequests: 0, credentialsInArtifacts: false };
  const actors = [], editions = [];
  let before, failed, managementRequests = 0, rpcRequests = 0, appRequests = 0, authCreateRequests = 0, passwordSigninRequests = 0, authSignoutRequests = 0, authRetireRequests = 0, active = 0;
  const waiters = [], pendingWork = new Set(), pendingHttp = new Set(); let maxObservedInFlight = 0;
  function tracked(promise, set) {
    set.add(promise); promise.then(() => set.delete(promise), () => set.delete(promise)); return promise;
  }
  function bounded(action) { return tracked(runBounded(action), pendingWork); }
  async function runBounded(action) {
    if (active >= LOAD_LIMITS.maxInFlight) await new Promise(resolve => waiters.push(resolve)); else active++;
    maxObservedInFlight = Math.max(maxObservedInFlight, active);
    try { return await action(); } finally { const next = waiters.shift(); if (next) next(); else active--; }
  }
  async function sql(query, write = false) {
    managementRequests++;
    // This exact verified target is captured before accessing credentials. Every write
    // below uses captured fresh IDs, exact run prefix and an explicit test guard.
    const response = await fetch(`https://api.supabase.com/v1/projects/${target.projectRef}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ read_only: !write, query: write ? `begin;set local lock_timeout='3s';set local statement_timeout='15s';${query};commit;` : query }), redirect: 'error', signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new Error(`LOAD_MANAGEMENT_${response.status}`);
    return response.json();
  }
  async function rpc(person, name, args) {
    rpcRequests++;
    const response = await fetch(`${sbUrl}/rest/v1/rpc/${name}`, { method: 'POST', headers: { apikey: env.NEXT_PUBLIC_SUPABASE_ANON_KEY, Authorization: `Bearer ${person?.token ?? env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json', 'Content-Profile': 'api' }, body: JSON.stringify(args), signal: AbortSignal.timeout(20_000), redirect: 'error' });
    const result = await response.json();
    if (!response.ok) throw new Error(`LOAD_SETUP_RPC_${response.status}`);
    return result;
  }
  function http(person, path, body) { return tracked(httpRequest(person, path, body), pendingHttp); }
  async function httpRequest(person, path, body) {
    appRequests++;
    const response = await fetch(`${target.origin}${path}`, { method: body ? 'POST' : 'GET', headers: { Cookie: [...person.cookies].map(([k, v]) => `${k}=${v}`).join('; '), Origin: target.origin, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(15_000), redirect: 'error', cache: 'no-store' });
    for (const cookie of response.headers.getSetCookie()) {
      const part = cookie.slice(0, cookie.indexOf(';')); const equals = part.indexOf('=');
      if (equals > 0) { if (part.slice(equals + 1) === '') person.cookies.delete(part.slice(0, equals)); else person.cookies.set(part.slice(0, equals), part.slice(equals + 1)); }
    }
    const value = await response.json();
    return { status: response.status, value: value.data, errorCode: value.error?.code };
  }
  async function databaseStats(label) {
    // Cluster aggregates only: no query texts, usernames, addresses or actor IDs.
    const rows = await sql(`select jsonb_build_object('label',${sqlLiteral(label)},'recordedAt',clock_timestamp(),
      'connections',(select jsonb_build_object('total',count(*),'active',count(*)filter(where state='active'),'idle',count(*)filter(where state='idle'),'idleInTransaction',count(*)filter(where state='idle in transaction'),'waitingOnLock',count(*)filter(where wait_event_type='Lock'),'waitingOnIO',count(*)filter(where wait_event_type='IO')) from pg_stat_activity where datname=current_database()),
      'locks',(select jsonb_build_object('total',count(*),'waiting',count(*)filter(where not l.granted)) from pg_locks l join pg_stat_activity a on a.pid=l.pid where a.datname=current_database()),
      'database',(select jsonb_build_object('backends',numbackends,'commits',xact_commit,'rollbacks',xact_rollback,'blocksRead',blks_read,'blocksHit',blks_hit,'deadlocks',deadlocks,'tempFiles',temp_files,'tempBytes',temp_bytes,'blockReadMs',blk_read_time,'blockWriteMs',blk_write_time,'statsReset',stats_reset) from pg_stat_database where datname=current_database()),
      'ioTimingEnabled',current_setting('track_io_timing')='on') metrics`);
    return rows[0].metrics;
  }
  async function preservation(anchor) {
    const first = await sql(`select coalesce(${anchor ? sqlLiteral(anchor) : 'null'}::timestamptz,clock_timestamp()) anchor`);
    const boundary = first[0].anchor;
    const result = await sql(`select jsonb_build_object(
      'legacy2026',(select md5(coalesce(jsonb_agg(to_jsonb(e) order by e.id)::text,'')) from app_private.events e where e.slug='duindorp-halloween-2026'),
      'legacyRegistrations',(select md5(coalesce(jsonb_agg(to_jsonb(r) order by r.id)::text,'')) from app_private.registrations r join app_private.events e on e.id=r.event_id where e.slug='duindorp-halloween-2026'),
      'legacyPayments',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id)::text,'')) from app_private.payment_requests p),
      'legacyOutboxCount',(select count(*) from app_private.email_outbox),
      'oldAuthCount',(select count(*) from auth.users where created_at is null or created_at<=${sqlLiteral(boundary)}::timestamptz),
      'oldAuthIds',(select md5(coalesce(string_agg(id::text,',' order by id),'')) from auth.users where created_at is null or created_at<=${sqlLiteral(boundary)}::timestamptz),
      'canonicalEvent',(select md5(to_jsonb(e)::text) from app_private.events e where e.slug=${sqlLiteral(target.slug)})) as proof`);
    const tables = await sql("select tablename from pg_tables where schemaname='app_private' and tablename like 'fn\\_%' escape '\\' order by tablename");
    const aggregates = [];
    for (const { tablename } of tables) {
      check(/^fn_[a-z_]+$/.test(tablename), 'UNSAFE_CATALOG_IDENTIFIER');
      aggregates.push(`${sqlLiteral(tablename)},(select md5(coalesce(string_agg(to_jsonb(t)::text,',' order by to_jsonb(t)::text),'')) from app_private.${tablename} t where event_id=(select id from app_private.events where slug=${sqlLiteral(target.slug)}))`);
    }
    const protectedRows = await sql(`select jsonb_build_object(${aggregates.join(',')}) canonical`);
    return { anchor: boundary, ...result[0].proof, canonical: protectedRows[0].canonical };
  }
  function comparePreservation(a, b) {
    return ['legacy2026', 'legacyRegistrations', 'legacyPayments', 'legacyOutboxCount', 'oldAuthCount', 'oldAuthIds', 'canonicalEvent', 'canonical'].filter(key => JSON.stringify(a[key]) !== JSON.stringify(b[key]));
  }
  async function createActor(index) {
    const email = `fnload-${run}-${index}@example.invalid`, password = randomBytes(36).toString('base64url');
    check(email.endsWith('@example.invalid') && email.startsWith(`fnload-${run}-`), 'SYNTHETIC_ACTOR_DOMAIN_REQUIRED');
    authCreateRequests++;
    const created = await service.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { display_name: `Synthetisch testgezin ${index}`, synthetic_frightnight_load: run } });
    check(!created.error && created.data.user, 'SYNTHETIC_AUTH_CREATE_FAILED');
    const person = { id: created.data.user.id, email, cookies: new Map(), token: null, snapshot: null };
    actors.push(person);
    const ssr = createServerClient(sbUrl, env.NEXT_PUBLIC_SUPABASE_ANON_KEY, { cookies: { getAll: () => [...person.cookies].map(([name, value]) => ({ name, value })), setAll: values => values.forEach(({ name, value }) => person.cookies.set(name, value)) } });
    passwordSigninRequests++;
    const signed = await ssr.auth.signInWithPassword({ email, password });
    check(!signed.error && signed.data.session, 'SYNTHETIC_PASSWORD_SESSION_FAILED');
    person.token = signed.data.session.access_token;
  }
  async function fixtureEdition(count, suffix = String(count), restrictive = false, familySizes = null) {
    check(/^[a-z0-9-]+$/.test(suffix), 'INVALID_FIXTURE_SUFFIX');
    const slug = `${prefix}${suffix}`;
    const edition = { slug, id: randomUUID(), actors: actors.slice(0, count), codes: new Map(), runId: null };
    editions.push(edition);
    // Record the fresh ID before dispatch so a lost setup response can still be
    // cleaned up without discovering or touching unrelated editions.
    // Fresh event creation avoids granting any capability in the protected
    // canonical edition. The first new actor is controller only during setup.
    await sql(`do $fresh$begin if exists(select 1 from app_private.events where slug=${sqlLiteral(slug)}) then raise exception 'FRESH_LOAD_EVENT_REQUIRED'; end if; end;$fresh$; with fresh as(insert into app_private.events(id,slug,title,local_date,timezone,phase,price_cents,settings)
      select ${uuid(edition.id)},${sqlLiteral(slug)},'Geïsoleerde FrightNight belastingproef',date '2027-10-30','Europe/Amsterdam','draft',350,jsonb_build_object('engine','frightnight-v1','test',true,'legacyRegistrationDisabled',true,'syntheticLoadRun',${sqlLiteral(run)})
      where not exists(select 1 from app_private.events where slug=${sqlLiteral(slug)}) returning id)
      insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
      select id,${uuid(actors[0].id)},'event_admin',${uuid(actors[0].id)} from fresh returning event_id`, true);
    const created = await sql(`select e.id event_id from app_private.events e join app_private.event_capabilities c on c.event_id=e.id where e.slug=${sqlLiteral(slug)} and e.settings->>'syntheticLoadRun'=${sqlLiteral(run)} and c.user_id=${uuid(actors[0].id)} and c.capability='event_admin' and c.revoked_at is null`);
    check(created.length === 1, 'FRESH_EVENT_REQUIRED');
    check(created[0].event_id === edition.id, 'FRESH_EVENT_ID_MISMATCH');
    await rpc(null, 'frightnight_bootstrap', { p_slug: slug, p_actor: actors[0].id, p_environment: 'staging', p_confirmation: `${target.projectRef}:staging:duindorphalloweenstg` });
    for (const person of actors) await rpc(null, 'frightnight_entry_grant', { p_slug: slug, p_actor: person.id, p_expires_at: new Date(Date.now() + 3_600_000).toISOString(), p_invitation_digest: createHash('sha256').update(`${run}:${slug}:${person.id}`).digest('hex') });
    const unseeded = await rpc(actors[0], 'frightnight_snapshot', { p_slug: slug });
    const contractBinding = { slug, eventId: edition.id, runId: unseeded.event.runId };
    const armed = await rpc(null, 'frightnight_contract_arm', { p_slug: slug, p_actor: actors[0].id, p_run_id: contractBinding.runId, p_confirmation: `${target.projectRef}:staging:duindorphalloweenstg:${slug}:${contractBinding.runId}` });
    assertFrightnightContractArm(armed, contractBinding);
    assertFrightnightContractSnapshot(await rpc(actors[0], 'frightnight_snapshot', { p_slug: slug }), contractBinding);
    edition.contractBinding = contractBinding;
    report.contractSandboxes.push({ ...contractBinding, provider: 'contract', serviceArm: true, actorReadback: true });
    const seed = await rpc(actors[0], 'frightnight_command', { p_slug: slug, p_command: 'test.seed', p_payload: {}, p_key: randomUUID() });
    check(seed.result.scenarioVersion === 1, 'REVIEWED_SEED_VERSION_REQUIRED');
    assertFrightnightContractSnapshot(seed.snapshot, contractBinding);
    edition.startCode = seed.result.startCode;
    edition.runId = seed.snapshot.event.runId;
    edition.codes = new Map(seed.result.zoneCodes.map(z => [z.zoneId, z.code]));
    // The four default ownerless demonstration families are not measured phones.
    // Archive only those fresh unpaid placeholders so active family scope never
    // exceeds the reviewed 125-fixture budget. Auth/history are retained.
    await sql(`update app_private.fn_parties p set state='archived',version=version+1 where p.event_id=${uuid(edition.id)} and p.run_id=${uuid(edition.runId)} and exists(select 1 from app_private.fn_members m join app_private.fn_registrations r on r.id=m.registration_id where m.party_id=p.id and r.synthetic and r.owner_id is null and r.household_id is null and r.payment_status='unpaid');
      update app_private.fn_registrations set status='archived',version=version+1 where event_id=${uuid(edition.id)} and run_id=${uuid(edition.runId)} and synthetic and owner_id is null and household_id is null and payment_status='unpaid'`, true);
    await rpc(actors[0], 'frightnight_command', { p_slug: slug, p_command: 'test.walk.fixture', p_payload: {}, p_key: randomUUID() });
    await sql(`update app_private.fn_zones z set capacity=125 where z.event_id=${uuid(edition.id)} and z.synthetic and z.run_id=${uuid(edition.runId)} and exists(select 1 from app_private.fn_events f where f.event_id=z.event_id and f.environment='staging' and f.is_test)`, true);
    for (const [index, person] of edition.actors.entries()) {
      const persons = familySizes?.[index] ?? 1; check(Number.isInteger(persons) && persons >= 1 && persons <= 5, 'BOUNDED_FUNCTIONAL_FAMILY_REQUIRED');
      const registered = await rpc(person, 'frightnight_command', { p_slug: slug, p_command: 'registration.save', p_payload: { label: familySizes ? 'Synthetisch functioneel samenloopgezin' : 'Synthetisch eenpersoons testgezin', routeType: 'lantern', adults: 1, children: persons - 1, maxIntensity: restrictive && index === 1 ? 1 : 2, avoidSmoke: familySizes ? index === 1 : true, avoidStrobes: familySizes ? index === 1 : true, stepFree: familySizes ? index === 1 : true, consent: true, termsVersion: '2027-test-v1' }, p_key: randomUUID() });
      await sql(`update app_private.fn_registrations r set synthetic=true where r.event_id=${uuid(edition.id)} and r.id=${uuid(registered.snapshot.registration.id)} and r.owner_id=${uuid(person.id)} and exists(select 1 from auth.users u where u.id=r.owner_id and u.email=${sqlLiteral(person.email)} and u.raw_user_meta_data->>'synthetic_frightnight_load'=${sqlLiteral(run)})`, true);
      assertFrightnightContractSnapshot(await rpc(actors[0], 'frightnight_snapshot', { p_slug: slug }), edition.contractBinding);
      const order = await rpc(null, 'frightnight_payment_claim', { p_slug: slug, p_actor: person.id, p_key: randomUUID(), p_configured_provider: env.FRIGHTNIGHT_PAYMENT_PROVIDER });
      assertFrightnightContractOrder(order, edition.contractBinding);
      await rpc(null, 'frightnight_payment_bind', { p_slug: slug, p_order_id: order.order_id, p_provider_ref: `ct_${order.order_id}`, p_checkout_url: null });
      await rpc(null, 'frightnight_payment_confirm', { p_slug: slug, p_provider_ref: `ct_${order.order_id}`, p_status: 'paid', p_amount_cents: order.amount_cents, p_currency: 'EUR', p_provider_event: `load:${order.order_id}:paid`, p_metadata: { order_id: order.order_id, event_id: edition.id, testmode: true, environment: 'staging' } });
      const selected = await http(person, '/api/frightnight/edition', { slug });
      check(selected.status === 200 && selected.value?.selected === slug, 'SIGNED_LOAD_EDITION_SELECTION_FAILED');
    }
    const scope = await sql(`select count(*)::integer families from app_private.fn_registrations where event_id=${uuid(edition.id)} and status<>'archived'`);
    check(scope[0].families === count && scope[0].families <= LOAD_LIMITS.maxActors, 'ACTIVE_FIXTURE_BUDGET_EXCEEDED');
    await sql(`update app_private.event_capabilities set revoked_at=now() where event_id=${uuid(edition.id)} and user_id=${uuid(actors[0].id)} and capability='event_admin' and revoked_at is null`, true);
    return edition;
  }
  async function integrity(edition) {
    const rows = await sql(`select jsonb_build_object(
      'overbooked',(select count(*) from app_private.fn_zones z where z.event_id=${uuid(edition.id)} and (app_private.fn_zone_occupancy(z.id)->>'effectivePersons')::integer>z.capacity),
      'multipleCurrent',(select count(*) from(select party_id from app_private.fn_destinations where event_id=${uuid(edition.id)} and state='current' group by party_id having count(*)>1)x),
      'duplicateVisits',(select count(*) from(select registration_id,destination_id from app_private.fn_visits where event_id=${uuid(edition.id)} group by registration_id,destination_id having count(*)>1)x),
      'duplicateAwards',(select count(*) from(select registration_id,award_key from app_private.fn_awards where event_id=${uuid(edition.id)} group by registration_id,award_key having count(*)>1)x),
      'claims',(select count(*) from app_private.fn_destinations where event_id=${uuid(edition.id)} and state='current'),
      'visits',(select count(*) from app_private.fn_visits where event_id=${uuid(edition.id)}),
      'legacyOutboxCount',(select count(*) from app_private.email_outbox),
      'legacyBindings',(select count(*) from app_private.walking_groups where event_id=${uuid(edition.id)})) proof`);
    const proof = rows[0].proof;
    return { ...proof, errors: ['overbooked', 'multipleCurrent', 'duplicateVisits', 'duplicateAwards', 'legacyBindings'].filter(k => Number(proof[k]) !== 0).concat(proof.legacyOutboxCount !== before.legacyOutboxCount ? ['LEGACY_OUTBOX_CHANGED'] : []) };
  }
  async function exercise(edition) {
    const stage = { phones: edition.actors.length, edition: edition.slug, database: [await databaseStats('before')], phases: [], integrity: [], expectedClientFaults: 0, status: 'running' };
    report.stages.push(stage);
    const all = []; const stageStarted = performance.now();
    let currentPhase = [], phaseName, phaseStarted, stopped = false;
    function gate(proof) {
      const reasons = [...stopReasons(summarize(all), proof?.errors ?? []), ...stopReasons(summarize(currentPhase))];
      if (all.length >= LOAD_LIMITS.maxRequestsPerStage) reasons.push('REQUEST_BUDGET_EXHAUSTED');
      if (reasons.length) { stopped = true; stage.stopReasons = [...new Set([...(stage.stopReasons ?? []), ...reasons])]; }
      return stopped;
    }
    async function measured(person, path, body) {
      if (stopped) return null;
      return bounded(async () => {
        if (stopped) return null;
        const began = performance.now();
        let result;
        try { result = await http(person, path, body); }
        catch { result = { status: 0, errorCode: 'TRANSPORT_FAILED' }; }
        const wrongEdition = result.status === 200 && path.endsWith('/snapshot') && result.value?.event?.slug !== edition.slug;
        const sample = { latencyMs: performance.now() - began, status: result.status, unexpected: result.status !== 200 || wrongEdition };
        currentPhase.push(sample); all.push(sample); gate();
        if (sample.unexpected) return null;
        const snapshot = body ? result.value?.snapshot : result.value;
        if (snapshot) { check(snapshot.event.slug === edition.slug, 'LOAD_RESPONSE_EDITION_MISMATCH'); person.snapshot = snapshot; }
        return result;
      });
    }
    async function phase(name, action, sampleDuring = false) {
      if (stopped) return;
      phaseName = name; currentPhase = []; phaseStarted = performance.now();
      try { const work = [action()]; if (sampleDuring) work.push(databaseStats('during-dispatched-scan-wave').then(value => { stage.database.push(value); })); await Promise.all(work); } catch (error) { stopped = true; while (pendingWork.size) await Promise.allSettled([...pendingWork]); stage.summary = summarize(all, performance.now() - stageStarted); stage.status = 'failed'; throw error; }
      stage.phases.push({ name: phaseName, ...summarize(currentPhase, performance.now() - phaseStarted) });
      const proof = await integrity(edition); stage.integrity.push(proof); gate(proof);
    }
    const get = person => measured(person, '/api/frightnight/snapshot');
    const command = (person, operation, payload, key = randomUUID()) => measured(person, '/api/frightnight/command', { commandId: key, operation, payload });
    await phase('participant-snapshot-baseline', () => Promise.all(edition.actors.map(get)));
    if (stopped) { stage.summary = summarize(all, performance.now() - stageStarted); stage.status = 'stopped'; throw new Error(stage.stopReasons[0]); }
    check(edition.actors.every(a => a.snapshot?.registration?.persons === 1 && a.snapshot.registration.paymentStatus === 'paid' && a.snapshot.actor.capabilities.length === 0), 'MEASURED_ACTORS_MUST_BE_ORDINARY_ONE_PERSON_PAID_FIXTURES');
    await phase('simultaneous-start', () => Promise.all(edition.actors.map(person => command(person, 'journey.start', { code: edition.startCode, expectedVersion: person.snapshot.journey.version }))));
    // Same phones, six independent subscribers each, with a global in-flight cap.
    // This is a bounded naive baseline, not six times the claimed phone count.
    await phase('naive-reconnect-six-independent-subscribers', () => Promise.all(edition.actors.flatMap(person => Array.from({ length: 6 }, () => get(person)))));
    const offsets = reconnectOffsets(edition.actors.length, `${run}:${edition.slug}`);
    const jitterStart = performance.now();
    await phase('jittered-reconnect-six-coalesced-subscribers', () => Promise.all(edition.actors.map(async (person, index) => {
      await sleep(offsets[index] - (performance.now() - jitterStart));
      const shared = coalesceSnapshot(() => get(person));
      await Promise.all(Array.from({ length: 6 }, shared));
    })));
    stage.reconnect = { naiveSubscribersPerPhone: 6, naivePlannedRequests: edition.actors.length * 6, coalescedPlannedRequests: edition.actors.length, jitterWindowMs: 5_000, offsetsDistinct: new Set(offsets).size, maxInFlight: LOAD_LIMITS.maxInFlight };
    const walkStarted = performance.now();
    // At least one full minute of paced walking. Missed ticks are never replayed
    // as a catch-up request storm. Commands carry current server route versions.
    for (let tick = 1; tick <= 12 && !stopped; tick++) {
      await sleep(walkStarted + tick * 5_000 - performance.now());
      if ([1, 4, 7, 10].includes(tick)) await phase(`walk-snapshot-${tick}`, () => Promise.all(edition.actors.map(get)));
      if (tick % 3 !== 0) continue;
      await phase(`walk-scan-${tick / 3}`, () => Promise.all(edition.actors.map(async (person, index) => {
        const live = person.snapshot;
        if (live.journey.state === 'finished') return;
        if (!live.current) { await command(person, 'journey.resume', { expectedVersion: live.journey.version }); return; }
        const body = { destinationId: live.current.id, expectedVersion: live.journey.version, code: edition.codes.get(live.current.zoneId) };
        check(body.code, 'LOAD_CURRENT_CREDENTIAL_NOT_OWN_FIXTURE');
        const key = randomUUID();
        if (tick === 3 && index === 0 && env.FRIGHTNIGHT_LOAD_CLIENT_FAULTS === 'true') {
          let lostResponse, first = true;
          const queued = { commandId: key, operation: 'journey.complete', payload: body };
          const recovered = await recoverQueuedCommand(async pending => {
            const actual = await command(person, pending.operation, pending.payload, pending.commandId);
            if (!actual) return { status: 0 };
            if (first) { first = false; lostResponse = actual.value; person.snapshot = live; stage.expectedClientFaults++; return { status: 503 }; }
            return actual;
          }, queued);
          if (stopped) return;
          check(recovered.confirmed && recovered.attempts === 2 && JSON.stringify(recovered.value?.result) === JSON.stringify(lostResponse?.result), 'INTEGRITY_QUEUED_REPLAY_DIVERGED');
          stage.queueRecovery = { state: recovered.state, attempts: recovered.attempts, responseLostAfterCommit: true, sameCommandAndVersion: true, backendFaultInjected: false };
        } else if (tick === 3 && index === 0) {
          const replies = await Promise.all([command(person, 'journey.complete', body, key), command(person, 'journey.complete', body, key)]);
          if (replies.every(Boolean)) check(JSON.stringify(replies[0].value?.result) === JSON.stringify(replies[1].value?.result), 'INTEGRITY_SCAN_REPLAY_DIVERGED');
        } else await command(person, 'journey.complete', body, key);
      })), tick === 6);
    }
    stage.database.push(await databaseStats('after'));
    stage.databaseDelta = databaseCounterDelta(stage.database[0].database, stage.database.at(-1).database);
    stage.walk = { elapsedMs: Math.round(performance.now() - walkStarted), requiredDurationMs: LOAD_LIMITS.walkDurationMs, finished: edition.actors.filter(a => a.snapshot?.journey.state === 'finished').length, waiting: edition.actors.filter(a => a.snapshot?.journey.state === 'waiting').length };
    if (!stopped) check(stage.walk.elapsedMs >= LOAD_LIMITS.walkDurationMs && stage.walk.finished === edition.actors.length, 'FULL_MINUTE_WALK_NOT_COMPLETED');
    if (!stage.queueRecovery) stage.queueRecovery = { status: 'not-injected', reason: 'Remote client-fault injection not enabled; local contract tests cover bounded 503 recovery.' };
    stage.summary = summarize(all, performance.now() - stageStarted);
    stage.status = stopped ? 'stopped' : 'passed';
    if (stopped) throw new Error(stage.stopReasons[0]);
  }
  async function membershipRaces() {
    report.membershipRaces = [];
    for (let round = 1; round <= 5; round++) {
      const edition = await fixtureEdition(2, `race-${round}`, true, [4,5]);
      const [a, b] = edition.actors, samples = [], began = performance.now();
      const result = { round, scope: 'fresh-two-family-sibling-edition', status: 'running' };
      report.membershipRaces.push(result);
      async function request(person, operation, payload = {}, key = randomUUID(), allowStale = false) {
        const start = performance.now(); let reply;
        try { reply = operation ? await http(person, '/api/frightnight/command', { commandId: key, operation, payload }) : await http(person, '/api/frightnight/snapshot'); }
        catch { reply = { status: 0, errorCode: 'TRANSPORT_FAILED' }; }
        const expectedStale = allowStale && reply.status === 409 && reply.errorCode === 'VERSION_CONFLICT';
        samples.push({ latencyMs: performance.now() - start, status: reply.status, unexpected: reply.status !== 200 && !expectedStale });
        result.summary = summarize(samples, performance.now() - began);
        if (reply.status === 200) {
          const snapshot = operation ? reply.value?.snapshot : reply.value;
          check(snapshot?.event.slug === edition.slug, 'RACE_EDITION_MISMATCH'); person.snapshot = snapshot;
        }
        return reply;
      }
      function gateRace() { const reasons = stopReasons(summarize(samples)); check(reasons.length === 0, reasons[0] ?? 'RACE_FAILED'); }
      for (const person of [a,b]) { check((await request(person)).status === 200, 'RACE_INITIAL_SNAPSHOT_FAILED'); check((await request(person, 'journey.start', { code: edition.startCode, expectedVersion: person.snapshot.journey.version })).status === 200, 'RACE_START_FAILED'); }
      const invited = await request(a, 'party.invite'); check(invited.status === 200 && invited.value.result.token, 'RACE_INVITE_FAILED');
      check((await request(b, 'party.join', { token: invited.value.result.token, consent: true })).status === 200, 'RACE_JOIN_FAILED');
      await Promise.all([request(a),request(b)]); gateRace();
      check(a.snapshot.journey.id === b.snapshot.journey.id && a.snapshot.journey.party.persons === 9 && a.snapshot.journey.party.maxIntensity === 1 && a.snapshot.journey.party.avoidSmoke && a.snapshot.journey.party.avoidStrobes && a.snapshot.journey.party.stepFree, 'INTEGRITY_JOINT_PREFERENCES');
      check(a.snapshot.current && (a.snapshot.current.zone.type === 'candy' || a.snapshot.current.zone.intensity <= 1), 'INTEGRITY_JOINT_INTENSITY');
      // SAM-05: two distinct accounts, two distinct command IDs, one current
      // destination/version. The loser must receive the controlled stale-version
      // response, rather than accidentally consuming the next destination.
      const together = a.snapshot.current;
      const togetherBody = { expectedVersion:a.snapshot.journey.version,destinationId:together.id,code:edition.codes.get(together.zoneId) };
      const bothMembers = await Promise.all([request(a,'journey.complete',togetherBody,randomUUID(),true),request(b,'journey.complete',togetherBody,randomUUID(),true)]);
      gateRace();
      check(bothMembers.filter(r => r.status === 200).length === 1 && bothMembers.filter(r => r.status === 409 && r.errorCode === 'VERSION_CONFLICT').length === 1, 'INTEGRITY_TWO_MEMBER_SCAN_TRANSITION');
      await Promise.all([request(a),request(b)]); gateRace();
      check(a.snapshot.journey.id === b.snapshot.journey.id && a.snapshot.journey.version === b.snapshot.journey.version && a.snapshot.current && a.snapshot.current.id === b.snapshot.current?.id && a.snapshot.current.id !== together.id && a.snapshot.journey.party.maxIntensity === 1 && (a.snapshot.current.zone.type === 'candy' || a.snapshot.current.zone.intensity <= 1) && !a.snapshot.current.zone.smoke && !a.snapshot.current.zone.strobes && a.snapshot.current.zone.stepFree, 'INTEGRITY_TWO_MEMBER_SHARED_CURRENT');
      for (const person of [a,b]) check(person.snapshot.progress.visits.filter(v => v.zoneId === together.zoneId).length === 1 && person.snapshot.progress.awards.filter(v => v.key === 'visit:'+together.zoneId).length === 1, 'INTEGRITY_TWO_MEMBER_PERSONAL_REWARD');
      result.simultaneousMembers = { accounts:2, distinctCommandIds:true, accepted:1, staleVersionConflicts:1, visitsPerFamily:1, awardsPerFamily:1, sharedCurrentCoherent:true };
      result.jointPersons = 9; result.familyPersons = [4,5];
      const joint = a.snapshot.current, shared = { expectedVersion: a.snapshot.journey.version, destinationId: joint.id, code: edition.codes.get(joint.zoneId) }, sharedKey = randomUUID();
      check(shared.code, 'RACE_OWN_QR_REQUIRED');
      const [first, duplicate, left] = await Promise.all([request(a,'journey.complete',shared,sharedKey,true),request(a,'journey.complete',shared,sharedKey,true),request(b,'party.leave')]);
      gateRace(); check(left.status === 200, 'INTEGRITY_MEMBER_LEAVE_REJECTED');
      check(first.status === duplicate.status && [200,409].includes(first.status), 'INTEGRITY_RACING_REPLAY_DIVERGED');
      if (first.status === 200) check(JSON.stringify(first.value?.result) === JSON.stringify(duplicate.value?.result), 'INTEGRITY_RACING_RECEIPT_DIVERGED');
      await Promise.all([request(a),request(b)]); gateRace();
      check(a.snapshot.journey.id !== b.snapshot.journey.id && a.snapshot.journey.party.persons === 4 && b.snapshot.journey.party.persons === 5, 'INTEGRITY_LEAVE_MEMBERSHIP');
      const sharedVisits = a.snapshot.progress.visits.filter(v => v.zoneId === joint.zoneId).length;
      check(sharedVisits === (first.status === 200 ? 1 : 0) && b.snapshot.progress.visits.filter(v => v.zoneId === joint.zoneId).length === sharedVisits, 'INTEGRITY_OWN_HISTORY_AFTER_LEAVE');
      const own = a.snapshot.current, bHistory = JSON.stringify(b.snapshot.progress), ownKey = randomUUID(); check(own, 'RACE_INDEPENDENT_DESTINATION_REQUIRED');
      const body = { expectedVersion:a.snapshot.journey.version,destinationId:own.id,code:edition.codes.get(own.zoneId) };
      const replies = await Promise.all([request(a,'journey.complete',body,ownKey),request(a,'journey.complete',body,ownKey)]); gateRace();
      check(replies.every(r => r.status === 200) && JSON.stringify(replies[0].value?.result) === JSON.stringify(replies[1].value?.result), 'INTEGRITY_INDEPENDENT_REPLAY_DIVERGED');
      await Promise.all([request(a),request(b)]); gateRace();
      check(JSON.stringify(b.snapshot.progress) === bHistory, 'INTEGRITY_OTHER_FAMILY_HISTORY_CHANGED');
      const ownProof = await sql(`select jsonb_build_object('visits',(select count(*) from app_private.fn_visits where destination_id=${uuid(own.id)}),'awards',(select count(*) from app_private.fn_awards where event_id=${uuid(edition.id)} and registration_id=${uuid(a.snapshot.registration.id)} and award_key=${sqlLiteral('visit:'+own.zoneId)})) proof`);
      check(Number(ownProof[0].proof.visits) === 1 && Number(ownProof[0].proof.awards) === 1, 'INTEGRITY_REPLAY_REWARD_COUNT');
      const proof = await integrity(edition); check(proof.errors.length === 0 && proof.claims <= 2, 'INTEGRITY_MEMBERSHIP_CAPACITY');
      result.status = 'passed'; result.memberCompleteLeaveOutcome = first.status === 200 ? 'completed-before-leave' : 'stale-after-leave'; result.jointMaxIntensity = 1; result.independentParties = 2; result.independentReplayVisits = 1; result.independentReplayAwards = 1; result.sharedVisitPerFamily = sharedVisits; result.otherFamilyHistoryUnchanged = true; result.integrity = proof; result.summary = summarize(samples,performance.now()-began);
      await archiveEdition(edition);
      check(comparePreservation(before,await preservation(before.anchor)).length === 0,'INTEGRITY_PROTECTED_DATA_CHANGED');
      result.protectedCanonicalAndLegacyUnchanged = true;
    }
  }
  async function restoreController(edition) {
    await sql(`insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
      select f.event_id,${uuid(actors[0].id)},'event_admin',${uuid(actors[0].id)} from app_private.fn_events f join app_private.events e on e.id=f.event_id
      where e.id=${uuid(edition.id)} and e.slug=${sqlLiteral(edition.slug)} and e.slug like ${sqlLiteral(prefix + '%')} and f.environment='staging' and f.is_test
      and exists(select 1 from auth.users where id=${uuid(actors[0].id)} and email=${sqlLiteral(actors[0].email)} and raw_user_meta_data->>'synthetic_frightnight_load'=${sqlLiteral(run)}) on conflict do nothing`, true);
  }
  async function archiveEdition(edition) {
    check(edition.slug.startsWith(prefix), 'CLEANUP_SCOPE_REJECTED');
    const binding = await sql(`select exists(select 1 from app_private.fn_events where event_id=${uuid(edition.id)}) initialized`);
    if (!binding[0].initialized) {
      await sql(`update app_private.events set phase='archived' where id=${uuid(edition.id)} and slug=${sqlLiteral(edition.slug)}; update app_private.event_capabilities set revoked_at=coalesce(revoked_at,now()) where event_id=${uuid(edition.id)} and user_id=${uuid(actors[0].id)}`, true);
      edition.archived = true; return;
    }
    await restoreController(edition);
    const live = await rpc(actors[0], 'frightnight_snapshot', { p_slug: edition.slug });
    await rpc(actors[0], 'frightnight_command', { p_slug: edition.slug, p_command: 'test.reset', p_payload: { confirmation: edition.slug, runId: live.event.runId }, p_key: randomUUID() });
    await sql(`update app_private.fn_events f set closed=true,version=version+1 where f.event_id=${uuid(edition.id)} and f.environment='staging' and f.is_test and exists(select 1 from app_private.events e where e.id=f.event_id and e.slug=${sqlLiteral(edition.slug)} and e.slug like ${sqlLiteral(prefix + '%')});
      update app_private.event_capabilities set revoked_at=coalesce(revoked_at,now()) where event_id=${uuid(edition.id)} and user_id=${uuid(actors[0].id)} and capability='event_admin'`, true);
    edition.archived = true;
  }
  try {
    const healthResponse = await fetch(`${target.origin}/api/health`, { signal: AbortSignal.timeout(10_000), redirect: 'error' });
    const health = await healthResponse.json();
    check(healthResponse.ok, 'LOAD_LIVE_RELEASE_HEALTH_UNAVAILABLE');
    assertFrightnightHostedRelease(health, env.GITHUB_SHA, env.FRIGHTNIGHT_PAYMENT_PROVIDER);
    const safety = await sql(FRIGHTNIGHT_SAFETY_SQL); assertFrightnightSafety(safety[0].frightnight_safety);
    const capacity = await sql(`select max(s.capacity)::integer places from app_private.fn_start_slots s join app_private.events e on e.id=s.event_id where e.slug=${sqlLiteral(target.slug)}`);
    loadPlan(capacity[0].places, maximum);
    before = await preservation();
    for (let i = 0; i < maximum; i++) await createActor(i);
    check(actors.length <= LOAD_LIMITS.maxActors, 'ACTOR_BUDGET_EXCEEDED');
    for (const count of plan.steps) {
      const edition = await fixtureEdition(count);
      await exercise(edition);
      await archiveEdition(edition);
      const after = await preservation(before.anchor);
      const changed = comparePreservation(before, after);
      check(changed.length === 0, 'INTEGRITY_PROTECTED_DATA_CHANGED');
      report.stages.at(-1).preservation = { unchanged: true, legacyOutboxUnchanged: true, canonicalFingerprintUnchanged: true, originalAuthIdsPreserved: true };
    }
    await membershipRaces();
  } catch (error) { failed = error; report.failure = safeError(error); if (report.stages.at(-1)?.status === 'running') report.stages.at(-1).status = 'failed'; if (report.membershipRaces?.at(-1)?.status === 'running') report.membershipRaces.at(-1).status = 'failed'; }
  finally {
    // No measured command may race the edition reset or session retirement.
    while (pendingWork.size || pendingHttp.size) await Promise.allSettled([...pendingWork,...pendingHttp]);
    const cleanupErrors = [];
    // Auth create may have committed before a lost response. Discover only this
    // run's fresh .invalid metadata so every created identity can be retired;
    // preserve all accounts and never delete an Auth user.
    try {
      const recovered = await sql(`select id from auth.users where raw_user_meta_data->>'synthetic_frightnight_load'=${sqlLiteral(run)} and email like ${sqlLiteral('fnload-'+run+'-%@example.invalid')}`);
      check(recovered.length <= LOAD_LIMITS.maxActors, 'AUTH_FIXTURE_BUDGET_EXCEEDED');
      for (const row of recovered) if (!actors.some(a => a.id === row.id)) actors.push({ id: row.id, token: null });
    } catch { cleanupErrors.push('AUTH_FIXTURE_DISCOVERY_FAILED'); }

    for (const edition of editions.filter(e => !e.archived)) { try { await archiveEdition(edition); } catch { cleanupErrors.push('SIBLING_ARCHIVE_INCOMPLETE'); } }
    for (const person of actors) {
      if (person.token) {
        try { authSignoutRequests++; const result = await service.auth.admin.signOut(person.token, 'global'); check(!result.error, 'LOAD_FIXTURE_SIGNOUT_FAILED'); }
        catch { cleanupErrors.push('SYNTHETIC_SESSION_RETIRE_INCOMPLETE'); }
      }
      try { authRetireRequests++; const result = await service.auth.admin.updateUserById(person.id, { ban_duration: '8760h' }); check(!result.error, 'LOAD_FIXTURE_RETIRE_FAILED'); }
      catch { cleanupErrors.push('SYNTHETIC_AUTH_RETIRE_INCOMPLETE'); }
    }
    if (before) {
      try { const final = await preservation(before.anchor); const changed = comparePreservation(before, final); report.preservation = { unchanged: changed.length === 0, changedDomains: changed }; if (changed.length) failed ??= new Error('INTEGRITY_PROTECTED_DATA_CHANGED'); }
      catch { cleanupErrors.push('FINAL_PRESERVATION_READ_FAILED'); }
    }
    if (cleanupErrors.length) { report.cleanupErrors = cleanupErrors; failed ??= new Error('LOAD_CLEANUP_INCOMPLETE'); }
    report.cleanup = { actorsCreated: actors.length, authDeleted: 0, syntheticEditionsCreated: editions.length, syntheticEditionsArchived: editions.filter(e => e.archived).length, auditOrFinancialRowsDeleted: 0, sessionRetirementFailures: cleanupErrors.filter(x => x === 'SYNTHETIC_SESSION_RETIRE_INCOMPLETE').length, authRetirementFailures: cleanupErrors.filter(x => x === 'SYNTHETIC_AUTH_RETIRE_INCOMPLETE').length };
    report.managementRequests = managementRequests; report.requestCounts = { measuredApp: [...report.stages,...(report.membershipRaces ?? [])].reduce((sum, s) => sum + (s.summary?.requests ?? 0), 0), totalAppIncludingSetup: appRequests, serviceOrActorRpc: rpcRequests, management: managementRequests, authCreate: authCreateRequests, passwordSignin: passwordSigninRequests, authSignout: authSignoutRequests, authRetire: authRetireRequests }; report.maxObservedInFlight = maxObservedInFlight; report.completedAt = new Date().toISOString(); report.status = failed ? 'failed-or-stopped' : 'passed';
    const directory = join(env.RUNNER_TEMP ?? '/tmp', 'frightnight-load'); await mkdir(directory, { recursive: true, mode: 0o700 });
    const encoded = JSON.stringify(report, null, 2) + '\n'; await writeFile(join(directory, 'report.json'), encoded, { mode: 0o600 });
    console.log(JSON.stringify({ frightnightLoad: report.status, revision: report.revision, stages: report.stages.length, actors: actors.length, reportSha256: createHash('sha256').update(encoded).digest('hex') }));
  }
  if (failed) throw new Error(`FRIGHTNIGHT_STAGING_LOAD_STOPPED:${safeError(failed)}`);
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const execute = process.argv.includes('--execute-staging-load');
  const maximum = Number(process.argv.find(arg => arg.startsWith('--maximum='))?.slice('--maximum='.length) ?? 125);
  if (!execute) console.log(JSON.stringify({ execution: false, ...loadPlan(100, maximum), executeFlag: '--execute-staging-load', requiredApproval: 'FRIGHTNIGHT_LOAD_APPROVAL=nocteiuvohesvqbowchw:staging:duindorphalloweenstg' }, null, 2));
  else runStagingLoad(process.env, maximum).catch(error => { console.error(safeError(error)); process.exitCode = 1; });
}
