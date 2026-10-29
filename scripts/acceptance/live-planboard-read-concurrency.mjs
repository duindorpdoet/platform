import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createTogetherFixtures, requireLocalTogetherDatabase, sql, parallelSql } from "./together-fixtures.mjs";

const container = requireLocalTogetherDatabase();
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const claims = `select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);`;
const ids = Array.from({ length: 5 }, () => ({ group: randomUUID(), plan: randomUUID() }));
const registrations = createTogetherFixtures(5, 1, 1).map(party => party.members[0].id);
const mailBefore = sql("select count(*) from app_private.email_outbox");
const acceptedBefore=sql("select count(*) from app_private.joint_route_plan_versions");
sql(`insert into app_private.live_route_plans(group_id,event_id,schedule_id)
 select id,event_id,current_schedule_revision_id from app_private.walking_groups
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026') on conflict(group_id) do nothing;
 ${ids.map((entry, index) => `insert into app_private.walking_groups(id,event_id,code,status,route_mode,start_slot_id)
 select ${quote(entry.group)},id,'SYNTHETIC-READ-RACE-${index}','draft','legacy',(select start_slot_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002') from app_private.events where slug='duindorp-halloween-2026';
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(${quote(entry.group)},${quote(registrations[index])},1);
 insert into app_private.route_plan_versions(id,group_id,revision,state,generated_by,input_hash)
 values(${quote(entry.plan)},${quote(entry.group)},1,'valid','f0000000-0000-0000-0000-000000000001','read-race-${index}');
 insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 values(${quote(entry.plan)},1,'12000000-0000-0000-0000-000000000001','2026-10-31T18:30:00+01'::timestamptz+interval '${index * 10} minutes','2026-10-31T18:35:00+01'::timestamptz+interval '${index * 10} minutes'),
 (${quote(entry.plan)},2,'12000000-0000-0000-0000-000000000002','2026-10-31T18:45:00+01'::timestamptz+interval '${index * 10} minutes','2026-10-31T18:50:00+01'::timestamptz+interval '${index * 10} minutes');
 update app_private.route_plan_versions set state='published',published_at=clock_timestamp() where id=${quote(entry.plan)};
 update app_private.walking_groups set current_plan_version_id=${quote(entry.plan)} where id=${quote(entry.group)};`).join("\n")}`);
const snapshot = `begin;${claims} select jsonb_build_object('hash',s->>'inputHash','pending',(s->>'initializationPending')::integer,
 'reviewGroups',(select count(distinct id) from jsonb_array_elements(s->'warnings') warning cross join lateral jsonb_array_elements_text(warning->'groupIds') group_id(id)
  where warning->>'code'='JOINT_ROUTE_REVIEW_REQUIRED' and id in(${ids.map(entry => quote(entry.group))})))
 from(select api.admin_live_planboard_snapshot('duindorp-halloween-2026') s) snapshot;commit;`;
// Three independent connections initialize only lightweight metadata under the
// existing lock. None may silently calculate/approve independent physical routes.
const coldResponses=await Promise.all(Array.from({ length: 3 }, () => parallelSql(snapshot)));
for(const response of coldResponses){const value=JSON.parse(response.split("\n").at(-1));assert.equal(value.pending,0);assert.equal(value.reviewGroups,5);}
assert.equal(sql(`select count(*) from app_private.live_route_plans where group_id in(${ids.map(entry => quote(entry.group))})`), "5");
assert.equal(sql(`select count(*) from app_private.live_route_visits where group_id in(${ids.map(entry => quote(entry.group))}) and retired_at is null`), "0");
assert.equal(sql("select count(*) from app_private.joint_route_plan_versions"),acceptedBefore);
assert.equal(sql(`select count(*) from app_private.live_route_plans where group_id in(${ids.map(entry => quote(entry.group))}) and version<>1`), "0");
// Store one explicit manual intention as fixture input. A warm snapshot must
// preserve it even while an accepted joint version is still absent.
const intention=randomUUID();
sql(`insert into app_private.live_route_visits(id,event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
 select ${quote(intention)},id,${quote(ids[0].group)},1,'12000000-0000-0000-0000-000000000001','2026-10-31T18:40:00+01',300,120,'ordinary','manual'
 from app_private.events where slug='duindorp-halloween-2026';`);
const intentions=()=>sql(`select md5(coalesce(jsonb_agg(to_jsonb(v) order by id)::text,'')) from app_private.live_route_visits v where group_id in(${ids.map(entry=>quote(entry.group))})`);
const storedIntentions=intentions();
const baseline = JSON.parse((await parallelSql(snapshot)).split("\n").at(-1));
assert.equal(baseline.pending, 0);assert.equal(baseline.reviewGroups,5);

// Hold the actual event writer row lock in another connection. A warm read must
// succeed with a short lock_timeout, proving it no longer waits for that lock.
let readyResolve, readyReject;
const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
const lock = spawn("docker", ["exec", "-i", "-e", "PGAPPNAME=planboard-read-lock-regression", container, "psql", "-U", "postgres", "-d", "postgres", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]);
let lockOutput = "", lockError = "";
lock.stdout.on("data", chunk => { lockOutput += chunk; if (lockOutput.includes("EVENT_LOCK_HELD")) readyResolve(); });
lock.stderr.on("data", chunk => { lockError += chunk; });
lock.on("error", readyReject);
const finished = new Promise((resolve, reject) => lock.on("exit", code => {
  if (code === 0) resolve(); else reject(new Error(lockError));
  if (!lockOutput.includes("EVENT_LOCK_HELD")) readyReject(new Error("Event lock was not acquired"));
}));
lock.stdin.end(`begin;do $$ begin perform 1 from app_private.events where slug='duindorp-halloween-2026' for update;end $$;
 select 'EVENT_LOCK_HELD';select pg_sleep(5);rollback;`);
await ready;
assert.equal(sql("select count(*) from pg_stat_activity where application_name='planboard-read-lock-regression' and wait_event='PgSleep'"), "1", "the event writer lock is still held during the read test");
const warm = snapshot.replace("begin;", "begin;set local lock_timeout='250ms';");
const responses = await Promise.all(Array.from({ length: 3 }, () => parallelSql(warm)));
await finished;
for (const response of responses) assert.deepEqual(JSON.parse(response.split("\n").at(-1)), baseline);
assert.equal(sql(`select count(*) from app_private.live_route_plans where group_id in(${ids.map(entry => quote(entry.group))}) and version<>1`), "0");
assert.equal(intentions(),storedIntentions,"warm readers preserve every stored intent identity, time and version");
assert.equal(sql("select count(*) from app_private.joint_route_plan_versions"),acceptedBefore);
const commandKey=randomUUID(),command={action:"move",visitId:intention,portalId:"12000000-0000-0000-0000-000000000001",startsAt:"2026-10-31T18:40:00+01",shiftFollowing:false};
sql(`update app_private.live_route_visits set version=version+1 where id=${quote(intention)}`);
await assert.rejects(parallelSql(`begin;${claims} select api.admin_live_planboard_apply('duindorp-halloween-2026',${quote(JSON.stringify(command))}::jsonb,${quote(baseline.hash)},false,'Synthetische verouderde opdracht mag niet alsnog worden toegepast',${quote(commandKey)});rollback;`),/STALE_VERSION/);
assert.equal(sql(`select count(*) from app_private.command_receipts where idempotency_key=${quote(commandKey)}`),"0");
assert.equal(sql("select count(*) from app_private.email_outbox"), mailBefore);
console.log(JSON.stringify({ code: "LIVE_PLANBOARD_READ_CONCURRENCY_VERIFIED", coldReaders: 3, warmReaders: 3, initializedGroups: 5,
  automaticallyInitializedVisits: 0, requiresJointReviewGroups: 5, explicitStoredIntentions: 1, noDuplicateIntent: true, warmHashStable: true, warmReadIgnoresEventWriterLock: true, staleApplyRejected: true, noAutomaticAcceptance: true, noMail: true }));
