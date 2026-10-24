import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';
import { writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { makeEveningLoadFixture, eveningLoadFixtureSql } from './evening-load-fixture.mjs';
const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const secret = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY, site = process.env.APP_URL;
const local = process.env.APP_ENVIRONMENT === 'test' && ['127.0.0.1', 'localhost'].includes(new URL(url).hostname);
assert.ok(local || (process.env.APP_ENVIRONMENT === 'staging' && site === 'https://staging-halloween.duindorpdoet.nl' && new URL(url).hostname === `${process.env.SUPABASE_PROJECT_REF}.supabase.co`), 'only explicitly configured isolated local or staging environments');
assert.ok(key && secret && site, 'explicit application and Auth configuration required');
const directory = join(process.env.RUNNER_TEMP ?? '/tmp', `duindorp-evening-load-${Date.now()}`);
await mkdir(directory, { recursive: true, mode: 0o700 });
async function query(sql, readOnly = true) {
    if (local) {
        const { sql: run } = await import('./together-fixtures.mjs');
        const value = run(sql);
        return value ? JSON.parse(value) : null;
    }
    const result = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: sql, read_only: readOnly }), signal: AbortSignal.timeout(150000) });
    if (!result.ok)
        throw new Error(`LOAD_SQL_${result.status}`);
    const rows = await result.json();
    return rows[0]?.value ?? rows;
}
// Compare each original business row by a hash of its actual primary key and
// full contents. New owned fixture rows are allowed; changes/deletions are not.
const protectedTables = ['events', 'profiles', 'households', 'household_members', 'children', 'registrations', 'registration_children', 'payment_requests', 'walking_groups', 'group_registrations', 'group_leaders', 'route_plan_versions', 'route_plan_stops', 'group_start_publications', 'group_schedule_revisions', 'portal_credentials', 'group_runs', 'run_stops', 'run_participants', 'run_stop_arrivals', 'poortenboek_passport_seals', 'portal_reservations'];
const catalog = await query(`select jsonb_agg(jsonb_build_object('name',c.relname,'pk',(select jsonb_agg(a.attname order by k.ordinality) from pg_index i cross join lateral unnest(i.indkey) with ordinality k(attnum,ordinality) join pg_attribute a on a.attrelid=c.oid and a.attnum=k.attnum where i.indrelid=c.oid and i.indisprimary)) order by c.relname) as value from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private' and c.relname=any(array[${protectedTables.map(x => `'${x}'`).join(',')}])`);
assert.equal(catalog.length, protectedTables.length);
const snapshots = () => query(`select jsonb_build_object(${catalog.map(({ name, pk }) => { assert.match(name, /^[a-z_]+$/); assert.ok(pk?.length); return `'${name}',(select coalesce(jsonb_object_agg(encode(sha256(convert_to(jsonb_build_array(${pk.map(col => { assert.match(col, /^[a-z_]+$/); return `r."${col}"`; }).join(',')})::text,'UTF8')),'hex'),encode(sha256(convert_to(to_jsonb(r)::text,'UTF8')),'hex')),'{}'::jsonb) from app_private."${name}" r)`; }).join(',')}) as value`);
if (!local) {
    const health = await (await fetch(`${site}/api/health`, { signal: AbortSignal.timeout(15000) })).json();
    assert.equal(health.environment, 'staging');
    assert.equal(health.revision, process.env.GITHUB_SHA, 'measure the exact deployed revision');
}
const before = await snapshots();
const number = (name, fallback) => process.env[name] ? Number(process.env[name]) : fallback;
const fixture = makeEveningLoadFixture({ families: number('LOAD_FAMILIES', 200), portals: number('LOAD_PORTALS', 30), admins: number('LOAD_ADMINS', 4), observers: number('LOAD_OBSERVERS', 20) });
await writeFile(join(directory, 'private-fixture.json'), JSON.stringify(fixture), { mode: 0o600 });
const networkSamples=[];
async function observedFetch(input,init){const began=performance.now();let rpc;try{rpc=new URL(typeof input==='string'?input:input.url??String(input)).pathname.match(/\/rest\/v1\/rpc\/([a-z_]+)$/)?.[1];}catch{}try{const response=await fetch(input,init);networkSamples.push({status:response.status,ms:performance.now()-began,rpc});return response;}catch(error){networkSamples.push({status:0,ms:performance.now()-began,rpc});throw error;}}
const privileged = createClient(url, secret, { global:{fetch:observedFetch},auth: { persistSession: false, autoRefreshToken: false } }), clients = new Map(), channels = [], created = [];
const report = { environment: local ? 'local' : 'staging', revision: process.env.GITHUB_SHA ?? process.env.APP_REVISION ?? 'local', fixtureEvent: fixture.slug, counts: { ...fixture.counts, groups: fixture.groups.length, distinctIdentities: fixture.actors.length }, phases: [], databaseSamples: [], realtime: { attempts: 0, subscribed: 0, errors: 0, messages: 0, byRole: { family: 0, portal: 0, admin: 0, observer: 0 } }, limitations: ['Generated synthetic walking graph; no physical route or camera proof.','Native SDK role RPC waves and actual private subscriptions; not 254 rendered browsers or an automatic RPC request for every broadcast.', 'VPS HTTP phase measures the real authenticated application shell; scoped fixture route RPCs run on the actual linked Supabase service.', 'Observers exercise read requests using the existing live-support capability in the isolated test event.'] };
async function recordPreservation(){
 const after=await snapshots(),changes=[];let compared=0;
 for(const [table,rows] of Object.entries(before))for(const [id,hash]of Object.entries(rows)){compared++;if(after[table]?.[id]!==hash)changes.push({table,rowKeyHash:id});}
 report.preservation={originalTables:catalog.length,originalRows:compared,changedOriginalRows:changes.length};
 return changes;
}
async function pool(items, concurrency, fn) { let cursor = 0, failure; await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => { while (cursor < items.length && !failure) {
    const index = cursor++;
    try {
        await fn(items[index], index);
    }
    catch (error) {
        failure = error;
    }
} })); if (failure)
    throw failure; }
async function phase(name, items, fn, concurrency = items.length) { const started = performance.now(), networkBefore=networkSamples.length, times = [], errors = {}; await pool(items, concurrency, async (item, i) => { const began = performance.now(); try {
    await fn(item, i);
}
catch (error) {
    const code = error.code || error.status || error.name || 'error';
        if(!report.phaseFailureDetails)report.phaseFailureDetails={};
        report.phaseFailureDetails[name]??=String(error.message).slice(0,1000);
    errors[code] = (errors[code] ?? 0) + 1;
} times.push(performance.now() - began); }); times.sort((a, b) => a - b); const p = n => Math.round(times[Math.max(0, Math.ceil(times.length * n) - 1)] ?? 0); const network=networkSamples.slice(networkBefore),requestTimes=network.map(sample=>sample.ms).sort((a,b)=>a-b),responseStatuses={};for(const sample of network)responseStatuses[sample.status]=(responseStatuses[sample.status]??0)+1;
const byRpc={};for(const rpc of new Set(network.map(s=>s.rpc).filter(Boolean))){const calls=network.filter(s=>s.rpc===rpc),ms=calls.map(s=>s.ms).sort((a,b)=>a-b),statuses={};for(const call of calls)statuses[call.status]=(statuses[call.status]??0)+1;byRpc[rpc]={requests:calls.length,statuses,p95Ms:Math.round(ms[Math.max(0,Math.ceil(ms.length*.95)-1)]??0)};}
const result = { name, operations:items.length, requests:network.length, responseStatuses,byRpc,requestP95Ms:Math.round(requestTimes[Math.max(0,Math.ceil(requestTimes.length*.95)-1)]??0), concurrency, errors, failed: Object.values(errors).reduce((a, b) => a + b, 0), elapsedMs: Math.round(performance.now() - started), p50Ms: p(.5), p95Ms: p(.95), p99Ms: p(.99), maxMs: p(1), overClientDeadline: times.filter(t => t > 8000).length }; report.phases.push(result); console.log(JSON.stringify(result)); return result; }
async function rpc(actor, name, args) { const client = clients.get(actor.id); assert.ok(client, 'independent authenticated identity'); const result = await client.schema('api').rpc(name, args).abortSignal(AbortSignal.timeout(60000)); if (result.error) {
    const error = new Error(name);
    error.code = result.error.code || `HTTP_${result.status || 'NETWORK'}`;
    throw error;
} return result.data; }
async function metrics() { try {
    report.databaseSamples.push(await query("select jsonb_build_object('at',clock_timestamp(),'connections',count(*),'active',count(*) filter(where state='active'),'waiting',count(*) filter(where wait_event_type='Lock'),'maximum',current_setting('max_connections')::integer) as value from pg_stat_activity where datname=current_database()"));
}
catch {
    report.databaseMetricErrors = (report.databaseMetricErrors ?? 0) + 1;
} }
let sampling = false, timer, probeFinished = false;
try {
    // These identities share one runner IP. Prepare their sessions below the
    // actual token-bucket refill rate; the measured live phases still run with
    // all identities at once. Never change the project's abuse protections.
    let loginSpacingMs = 0;
    if (!local) {
        const response = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/config/auth`, {
            headers: { Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}` },
            signal: AbortSignal.timeout(15000),
        });
        assert.ok(response.ok, 'read the actual Auth preparation limit');
        // Auth's apilimiter divides this field by 60*5, not by an hour.
        const config = await response.json(), perFiveMinutes = Number(config.rate_limit_token_refresh);
        assert.ok(Number.isFinite(perFiveMinutes) && perFiveMinutes > 0, 'known positive token request limit');
        loginSpacingMs = Math.ceil(300000 / perFiveMinutes) + 150;
        report.authPreparation = { tokenRequestsPerFiveMinutes: perFiveMinutes, minimumSpacingMs: loginSpacingMs, concurrency: 1 };
        report.limitations.push('Independent sessions are prepared sequentially within the configured shared-IP Auth limit; this is not a simultaneous sign-in capacity test.');
        console.log(JSON.stringify({ name: 'shared-ip-auth-preparation', ...report.authPreparation }));
    }
    // Admin createUser confirms only these synthetic accounts; it sends no mail.
    await pool(fixture.actors, 5, async (actor) => { const result = await privileged.auth.admin.createUser({ id: actor.id, email: actor.email, password: actor.password, email_confirm: true, app_metadata: { evening_load: fixture.slug } }); if (result.error)
        throw new Error(`LOAD_ACCOUNT_${result.error.code ?? result.error.status}`); assert.equal(result.data.user.id, actor.id); created.push(actor); });
    await query(eveningLoadFixtureSql(fixture), false);
    const login = await phase('distinct-account-logins', fixture.actors, async (actor, index) => {
        if (index > 0 && loginSpacingMs) await new Promise(resolve => setTimeout(resolve, loginSpacingMs));
        const client = createClient(url, key, { global:{fetch:observedFetch},auth: { persistSession: false, autoRefreshToken: false } }), signed = await client.auth.signInWithPassword({ email: actor.email, password: actor.password }); if (signed.error) {
        const error = new Error('LOGIN');
        error.code = signed.error.code ?? signed.error.status;
        throw error;
    } clients.set(actor.id, client); actor.session = signed.data.session;
        if (!local && (index + 1) % 25 === 0) console.log(JSON.stringify({ name: 'shared-ip-auth-progress', prepared: index + 1, total: fixture.actors.length }));
    }, local ? 20 : 1);
    assert.equal(login.failed, 0, 'all independent login attempts must succeed');
    await metrics();
    timer = setInterval(() => { if (!sampling) {
        sampling = true;
        void metrics().finally(() => { sampling = false; });
    } }, 1000);
    const families=fixture.actors.filter(a=>a.kind==='family');
    const leaders=fixture.groups.map(g=>families.find(a=>a.groupId===g.id));
    async function readActor(actor){
        if(actor.kind==='family')return rpc(actor,'group_snapshot',{_group_id:actor.groupId});
        if(actor.kind==='portal'){
            const room=await rpc(actor,'portal_room_snapshot',{_event_slug:fixture.slug,_portal_id:actor.portalId});
            assert.equal(room.userId,actor.id);
            actor.topics=[room.portalTopic,room.communityTopic];
            assert.ok(actor.topics.every(topic=>typeof topic==='string'));
            return room;
        }
        return Promise.all(['admin_dashboard','admin_evening_cockpit','admin_portal_operations_snapshot'].map(name=>rpc(actor,name,{_event_slug:fixture.slug})));
    }
    const initialReads=await phase('before-start-role-snapshots',fixture.actors,readActor);
    assert.equal(initialReads.failed,0,'all roles load their actual application RPCs');
    assert.ok(initialReads.p95Ms<=8000,'initial role snapshots must fit the actual eight-second client deadline');
    await phase('private-realtime-subscriptions',fixture.actors,async actor=>{
        const client=clients.get(actor.id);
        await client.realtime.setAuth(actor.session.access_token);
        const topics=actor.kind==='family'?[`group:${actor.groupId}`]:actor.kind==='portal'?actor.topics:[`admin-event:${fixture.eventId}`];
        for(const topic of topics){
            report.realtime.attempts++;
            await new Promise((resolve,reject)=>{
                let settled=false;
                const deadline=setTimeout(()=>{if(!settled){settled=true;report.realtime.errors++;reject(new Error('REALTIME_DEADLINE'));}},15000);
                const channel=client.channel(topic,{config:{private:true}})
                    .on('broadcast',{event:'snapshot_changed'},()=>{report.realtime.messages++;report.realtime.byRole[actor.kind]++;})
                    .subscribe(status=>{
                        if(settled&&!probeFinished&&['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status))report.realtime.errors++;
                        if(status==='SUBSCRIBED'&&!settled){settled=true;clearTimeout(deadline);report.realtime.subscribed++;resolve();}
                        else if(['CHANNEL_ERROR','TIMED_OUT'].includes(status)&&!settled){settled=true;clearTimeout(deadline);report.realtime.errors++;reject(new Error('REALTIME_SUBSCRIBE'));}
                    });
                channels.push([client,channel]);
            });
        }
    },20);
    await phase('concurrent-group-starts', leaders, async (actor) => { const [snapshot, roster] = await Promise.all([rpc(actor, 'group_snapshot', { _group_id: actor.groupId }), rpc(actor, 'group_roster', { _group_id: actor.groupId })]); await rpc(actor, 'run_start', { _group_id: actor.groupId, _present_registration_child_ids: roster.map(c => c.registrationChildId), _expected_group_version: snapshot.group.version, _idempotency_key: `${fixture.slug}-start-${actor.groupId}`, _request_hash: 'owned-staging-load-start' }); });
    for (let round = 1; round <= 3; round++)
        await phase(`live-role-snapshots-${round}`, fixture.actors, readActor);
    await phase('authenticated-vps-application-shell', fixture.actors, async (actor) => { const name = `sb-${new URL(url).hostname.split('.')[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(actor.session)).toString('base64url')}`, cookie = Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => `${value.length <= 3180 ? name : `${name}.${i}`}=${value.slice(i * 3180, (i + 1) * 3180)}`).join('; '); const response = await observedFetch(`${site}/omgeving`, { headers: { Cookie: cookie }, redirect: 'follow', signal: AbortSignal.timeout(30000) }); assert.equal(response.status, 200); await response.arrayBuffer(); });
    const arrivals = [];
    await phase('simultaneous-real-arrivals', leaders, async (actor) => { const snapshot = await rpc(actor, 'group_snapshot', { _group_id: actor.groupId }), run = snapshot.run; assert.ok(run.currentStop, 'a real reserved destination is required'); const house = fixture.houses.find(h => h.id === run.currentStop.portal.id); assert.ok(house); const args = { _run_id: run.id, _expected_stop_id: run.currentStop.id, _expected_run_version: run.version, _credential: house.token, _participant_choices: Object.fromEntries(run.participants.map(p => [p.id, 'skipped'])), _idempotency_key: `${fixture.slug}-arrive-${actor.groupId}` }; const receipt = await rpc(actor, 'run_arrive_and_advance', args); arrivals.push({ actor, args, receipt }); });
    await phase('two-independent-client-arrival-retries', arrivals.flatMap(item => [item, item]), async ({ actor, args, receipt }) => { const independent = createClient(url, key, { global: { fetch:observedFetch,headers: { Authorization: `Bearer ${actor.session.access_token}` } }, auth: { persistSession: false, autoRefreshToken: false } }); const result = await independent.schema('api').rpc('run_arrive_and_advance', args).abortSignal(AbortSignal.timeout(60000)); assert.equal(result.error, null); assert.deepEqual(result.data, receipt); });
    let expectedArrivals = fixture.counts.families;
    await phase('owner-close-versus-pending-arrival', [leaders[0]], async (actor) => {
        const original = await rpc(actor, 'group_snapshot', { _group_id: actor.groupId }), run = original.run;
        assert.ok(run.currentStop);
        const house = fixture.houses.find(h => h.id === run.currentStop.portal.id), owner = fixture.actors.find(a => a.kind === 'portal' && a.portalId === house.id);
        const version = await query(`select version as value from app_private.portals where id='${house.id}'`);
        const args = { _run_id: run.id, _expected_stop_id: run.currentStop.id, _expected_run_version: run.version, _credential: house.token, _participant_choices: Object.fromEntries(run.participants.map(p => [p.id, 'skipped'])), _idempotency_key: `${fixture.slug}-close-race` };
        const [closed, arrived] = await Promise.all([clients.get(owner.id).schema('api').rpc('portal_set_operational_state', { _portal_id: house.id, _state: 'closed', _expected_version: version, _reason: 'Uitsluitend fictieve stagingproef: eigenaar sluit tijdens een onzekere aankomst' }).abortSignal(AbortSignal.timeout(60000)), clients.get(actor.id).schema('api').rpc('run_arrive_and_advance', args).abortSignal(AbortSignal.timeout(60000))]);
        assert.equal(closed.error, null, `Close RPC: ${closed.error?.code} ${closed.error?.message}`);
        const after = await rpc(actor, 'group_snapshot', { _group_id: actor.groupId });
        if (arrived.error) {
            assert.equal(arrived.error.message, 'PORTAL_UNAVAILABLE', `Arrival after close: ${arrived.error.code} ${arrived.error.message}`);
            assert.equal(after.run.currentStop.id, run.currentStop.id);
            assert.equal(after.run.history.length, original.run.history.length);
            report.closeRace = { outcome: 'closure-before-arrival', pendingInstructionRetained: true, newArrivals: 0 };
        }
        else {
            assert.equal(after.run.history.length, original.run.history.length + 1);
            assert.deepEqual(await rpc(actor, 'run_arrive_and_advance', args), arrived.data);
            expectedArrivals += run.participants.length;
            report.closeRace = { outcome: 'arrival-before-closure', originalReceiptRetained: true, newArrivals: run.participants.length };
        }
    });
    await phase('after-arrival-role-snapshots', fixture.actors, readActor);
    await metrics();
    clearInterval(timer);
    timer = null;
    const invariants = await query(`select jsonb_build_object('arrivals',(select count(*) from app_private.run_stop_arrivals where event_id='${fixture.eventId}'),'seals',(select count(*) from app_private.poortenboek_passport_seals s join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id where g.event_id='${fixture.eventId}'),'runs',(select count(*) from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where g.event_id='${fixture.eventId}'),'overbookedOrdinary',(select count(*) from(select portal_id from app_private.portal_reservations where event_id='${fixture.eventId}' and kind='ordinary' and status='active' group by portal_id having count(*)>1) occupied)) as value`);
    assert.equal(invariants.arrivals, expectedArrivals);
    assert.equal(invariants.seals, expectedArrivals);
    assert.equal(invariants.runs, fixture.groups.length);
    assert.equal(invariants.overbookedOrdinary, 0);
    report.invariants = invariants;
    assert.deepEqual(await recordPreservation(), [], 'all pre-existing business IDs and full contents retained');
    assert.equal(report.realtime.subscribed, report.realtime.attempts);assert.ok(report.realtime.attempts>=fixture.actors.length);
    assert.equal(report.realtime.errors, 0, 'private channels remained connected during the measured load');
    assert.ok(report.realtime.messages > 0, 'actual domain broadcasts observed');
    assert.ok(report.phases.every(p => p.failed === 0), 'all measured phase requests succeeded');
    assert.ok(report.phases.filter(p => /^(before-start-role-snapshots|after-arrival-role-snapshots|live-role-snapshots|concurrent-group-starts|simultaneous-real-arrivals)/.test(p.name)).every(p => p.p95Ms <= 8000), 'route and role snapshot p95 must fit the actual eight-second client deadline');
    report.status = 'pass';
}
catch (error) {
    report.status = 'fail';
    report.failure = error.message;
    throw error;
}
finally {
    probeFinished = true;
    if (timer)
        clearInterval(timer);
    await Promise.allSettled(channels.map(([client, channel]) => client.removeChannel(channel)));
    for(const client of clients.values()) client.realtime.disconnect();
    // Keep append-only synthetic history, revoke sessions and prevent new logins.
    async function retryAuth(command){
        for(let attempt=0;attempt<6;attempt++){
            try{
                const result=await command();
                if(!result.error)return result;
                if(result.error.status&&result.error.status<500&&result.error.status!==429)throw result.error;
            }catch(error){if(error.status&&error.status<500&&error.status!==429)throw error;}
            if(attempt<5)await new Promise(resolve=>setTimeout(resolve,250*2**attempt));
        }
        throw new Error('SYNTHETIC_AUTH_CLEANUP_UNAVAILABLE');
    }
    let secured = 0;
    await pool(created, 4, async actor => {
        try {
            const client=clients.get(actor.id);
            if(client&&actor.session)await retryAuth(()=>privileged.auth.admin.signOut(actor.session.access_token,'global'));
            const result=await retryAuth(()=>privileged.auth.admin.updateUserById(actor.id,{ban_duration:'876000h',password:randomUUID()+randomUUID()}));
            if(Date.parse(result.data.user.banned_until)>Date.now()+86400000)secured++;
        }catch{/* Fail after writing the aggregate report; keep the primary failure. */}
    });
    report.syntheticAccountsSecured = secured;
    if (secured !== created.length) {
        report.status = 'fail';
        report.cleanupFailure = 'SYNTHETIC_ACCOUNT_REVOCATION_INCOMPLETE';
    }
    if(!report.preservation){try{const changes=await recordPreservation();if(changes.length)report.preservationFailure='ORIGINAL_BUSINESS_ROWS_CHANGED';}catch{report.preservationFailure='ORIGINAL_BUSINESS_ROW_COMPARISON_UNAVAILABLE';}}
    await writeFile(join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
    if (process.env.LOAD_REPORT_PATH)
        await writeFile(process.env.LOAD_REPORT_PATH, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ status: report.status, report: join(directory, 'report.json'), counts: report.counts, realtime: report.realtime, preservation: report.preservation }));
    assert.equal(secured, created.length, 'test accounts must be secured after the probe');
}
