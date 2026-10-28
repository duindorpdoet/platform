import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createTogetherFixtures, requireLocalTogetherDatabase, sql, parallelSql } from './together-fixtures.mjs';
requireLocalTogetherDatabase();
const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
const event = 'duindorp-halloween-2026', actor = 'f0000000-0000-0000-0000-000000000001';
const registrations = createTogetherFixtures(2, 1, 1).map((party) => party.members[0].id);
const groups = [randomUUID(), randomUUID()], points = [randomUUID(), randomUUID()];
sql(`update app_private.event_route_settings set first_start_at='2026-10-31T16:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T17:00:00Z',finale_last_arrival_at='2026-10-31T20:30:00Z',
 finale_closes_at='2026-10-31T21:00:00Z',finale_max_concurrent_groups=20,finale_max_concurrent_children=500,planner_mode='dynamic'
 where event_id=(select id from app_private.events where slug=${quote(event)});
 update app_private.portal_windows set opens_at='2026-10-31T16:00:00Z',closes_at='2026-10-31T21:00:00Z' where portal_id='12000000-0000-0000-0000-000000000001';
 insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,max_gathering_groups,max_gathering_children,active,point_type,linked_portal_id)
 select id,(select id from app_private.events where slug=${quote(event)}),'Isolated physical departure alias','FICTIEF VERTREKADRES',52.1,4.27,10,100,true,'portal',
 '12000000-0000-0000-0000-000000000001' from unnest(array[${points.map(quote).join(',')}]::uuid[]) id;
 insert into app_private.walking_groups(id,event_id,code,status,route_mode)
 select id,(select id from app_private.events where slug=${quote(event)}),'RACE-'||id,'draft','dynamic' from unnest(array[${groups.map(quote).join(',')}]::uuid[]) id;
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
 values(${quote(groups[0])},${quote(registrations[0])},1),(${quote(groups[1])},${quote(registrations[1])},1);
 begin; select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);
 select api.admin_startregie_slots_prepare(${quote(event)},array['2026-10-31T16:00:00Z'::timestamptz]); commit;`);
const slots = points.map((point) => sql(`select id from app_private.start_slots where start_point_id=${quote(point)} and starts_at='2026-10-31T16:00:00Z'`));
assert.notEqual(slots[0], slots[1], 'race must use distinct slot IDs for the same physical portal');
const hash = sql(`select app_private.group_operations_hash(id) from app_private.events where slug=${quote(event)}`);
const mailCount = sql('select count(*) from app_private.email_outbox');
const commands = groups.map((group, index) => ({ hash, key: randomUUID(), payload: { groups: [{ key: group, startId: slots[index], effectiveStopAt: '2026-10-31T18:30:00Z', expectedFinaleArrivalAt: '2026-10-31T18:45:00Z', preferenceMatch: 'neutral' }] } }));
function call(command, hold = false) {
  return `begin;set local role authenticated;select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);
    select api.admin_group_operations_apply(${quote(event)},'distribute',${quote(command.hash)},${quote(JSON.stringify(command.payload))}::jsonb,${quote(command.key)});
    ${hold ? 'select pg_sleep(0.2);' : ''}commit;`;
}
const results = await Promise.allSettled(commands.map((command) => parallelSql(call(command, true))));
assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1, 'one competing departure must commit');
assert.equal(results.filter((result) => result.status === 'rejected' && /STALE_GROUP_INPUT/.test(result.reason.message)).length, 1, 'the other transaction must detect stale planning input');
const winner = results.findIndex((result) => result.status === 'fulfilled'), loser = 1 - winner;
const fresh = { ...commands[loser], key: randomUUID(), hash: sql(`select app_private.group_operations_hash(id) from app_private.events where slug=${quote(event)}`) };
await assert.rejects(parallelSql(call(fresh)), /START_DEPARTURE_OCCUPIED/, 'fresh input must still reject another slot ID at the same physical departure');
const retries = await Promise.all([parallelSql(call(commands[winner], true)), parallelSql(call(commands[winner], true))]);
assert.equal(retries[0], retries[1], 'parallel exact retries return the same committed receipt');
assert.equal(sql(`select count(*) from app_private.group_schedule_revisions where group_id in(${groups.map(quote).join(',')})`), '1', 'failed competitors and retries leave exactly one revision');
assert.equal(sql(`select count(*) from app_private.group_registrations where group_id in(${groups.map(quote).join(',')}) and superseded_at is null`), '2', 'both group compositions are preserved');
assert.equal(sql('select count(*) from app_private.email_outbox'), mailCount, 'draft distribution must not enqueue participant mail');
console.log(JSON.stringify({ code: 'START_DEPARTURE_CONCURRENCY_VERIFIED', parallelWriters: 2, oneDeparture: true, aliasSlotBlocked: true, parallelRetryIdempotent: true, membershipsPreserved: true, noMail: true }));
