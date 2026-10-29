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
const snapshot = `begin;${claims} select jsonb_build_object('hash',s->>'inputHash','pending',(s->>'initializationPending')::integer)
 from(select api.admin_live_planboard_snapshot('duindorp-halloween-2026') s) snapshot;commit;`;
// Three different admins/readers initialize a finite batch under the existing
// initialization lock, without duplicates or rebuilding another reader's plan.
await Promise.all(Array.from({ length: 3 }, () => parallelSql(snapshot)));
assert.equal(sql(`select count(*) from app_private.live_route_plans where group_id in(${ids.map(entry => quote(entry.group))})`), "5");
assert.equal(sql(`select count(*) from app_private.live_route_visits where group_id in(${ids.map(entry => quote(entry.group))}) and retired_at is null`), "10");
assert.equal(sql(`select count(*) from app_private.live_route_plans where group_id in(${ids.map(entry => quote(entry.group))}) and version<>1`), "0");
const baseline = JSON.parse((await parallelSql(snapshot)).split("\n").at(-1));
assert.equal(baseline.pending, 0);

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
assert.equal(sql("select count(*) from app_private.email_outbox"), mailBefore);
console.log(JSON.stringify({ code: "LIVE_PLANBOARD_READ_CONCURRENCY_VERIFIED", coldReaders: 3, warmReaders: 3, initializedGroups: 5,
  initializedVisits: 10, noDuplicateIntent: true, warmHashStable: true, warmReadIgnoresEventWriterLock: true, noMail: true }));
