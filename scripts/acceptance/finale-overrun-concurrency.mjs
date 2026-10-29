import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createTogetherFixtures, requireLocalTogetherDatabase, sql, parallelSql } from "./together-fixtures.mjs";
requireLocalTogetherDatabase();
const quote = v => `'${String(v).replaceAll("'", "''")}'`;
const registrations = createTogetherFixtures(2, 1, 1).map(p => p.members[0].id);
const groups = [randomUUID(), randomUUID()], points = [randomUUID(), randomUUID()];
const actor = "f0000000-0000-0000-0000-000000000001";
sql(`update app_private.event_route_settings set first_start_at='2026-10-31T17:00:00+01',global_ordinary_stop_at='2026-10-31T20:30:00+01',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T19:00:00+01',finale_last_arrival_at='2026-10-31T21:25:00+01',
 finale_closes_at='2026-10-31T21:32:00+01',finale_show_seconds=600,finale_turnover_seconds=120,finale_planning_transfer_seconds=900,
 finale_max_concurrent_groups=1,finale_max_concurrent_children=20,finale_available=true,planner_mode='dynamic'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
 update app_private.registrations set preferred_start_at='2026-10-31T18:30:00+01',desired_end_at='2026-10-31T21:00:00+01',requested_ordinary_stop_at=null where id in(${registrations.map(quote)});
 insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,max_gathering_groups,max_gathering_children,active)
 select id,(select id from app_private.events where slug='duindorp-halloween-2026'),'Synthetic finale race','FICTIEF TESTADRES',52.1,4.27,1,20,true from unnest(array[${points.map(quote)}]::uuid[]) id;
 insert into app_private.walking_groups(id,event_id,code,status,route_mode)
 select id,(select id from app_private.events where slug='duindorp-halloween-2026'),'FINALE-RACE-'||id,'draft','dynamic' from unnest(array[${groups.map(quote)}]::uuid[]) id;
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(${quote(groups[0])},${quote(registrations[0])},1),(${quote(groups[1])},${quote(registrations[1])},1);
 begin;select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);
 select api.admin_startregie_slots_prepare('duindorp-halloween-2026',array['2026-10-31T18:30:00+01'::timestamptz]);commit;`);
const slots = points.map(p => sql(`select id from app_private.start_slots where start_point_id=${quote(p)} and starts_at='2026-10-31T18:30:00+01'`));
const mailBefore = sql("select count(*) from app_private.email_outbox");
const save = (i, arrival) => `begin;set local role authenticated;select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);
 select api.admin_save_group_schedule(${quote(groups[i])},${quote(slots[i])},'2026-10-31T20:20:00+01',${quote(arrival)},null,'good','Synthetische gelijktijdige finale reservering');select pg_sleep(0.2);commit;`;
const saves = await Promise.allSettled([0, 1].map(i => parallelSql(save(i, "2026-10-31T21:05:00+01"))));
assert.equal(saves.filter(r => r.status === "fulfilled").length, 1);
assert.equal(saves.filter(r => r.status === "rejected" && /FINALE_CAPACITY_EXCEEDED/.test(r.reason.message)).length, 1);
const winner = saves.findIndex(r => r.status === "fulfilled"), loser = 1 - winner;
await assert.rejects(parallelSql(save(loser, "2026-10-31T21:20:01+01")), /GROUP_END_TIME_INFEASIBLE/);
// Give both physical groups nonoverlapping fixture publications, then compete
// for the only final live slot. No participant publication command or mail call.
sql(`begin;select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);
 select api.admin_save_group_schedule(${quote(groups[winner])},${quote(slots[winner])},'2026-10-31T20:20:00+01','2026-10-31T20:40:00+01',null,'good','Synthetische voorbereiding van aparte live vensters');
 select api.admin_save_group_schedule(${quote(groups[loser])},${quote(slots[loser])},'2026-10-31T20:20:00+01','2026-10-31T21:00:00+01',null,'good','Synthetische voorbereiding van aparte live vensters');commit;
 update app_private.group_schedule_revisions s set state='published',published_at=clock_timestamp() from app_private.walking_groups g where s.id=g.current_schedule_revision_id and g.id in(${groups.map(quote)});
 insert into app_private.group_runs(group_id,status,schedule_revision_id) select id,'live',current_schedule_revision_id from app_private.walking_groups where id in(${groups.map(quote)});
 insert into app_private.run_participants(run_id,registration_child_id,attendance) select r.id,c.id,'present' from app_private.group_runs r join app_private.group_registrations a on a.group_id=r.group_id and a.superseded_at is null join app_private.registration_children c on c.registration_id=a.registration_id where r.group_id in(${groups.map(quote)});`);
const runs = groups.map(g => sql(`select id from app_private.group_runs where group_id=${quote(g)}`));
const reserve = id => `begin;select jsonb_build_object('id',app_private.try_reserve_finale(${quote(id)},'2026-10-31T21:20:00+01','2026-10-31T21:00:00+01'));select pg_sleep(0.2);commit;`;
const live = await Promise.all(runs.map(id => parallelSql(reserve(id))));
const results = live.map(r => JSON.parse(r).id);
assert.equal(results.filter(Boolean).length, 1);
const liveWinner = results.findIndex(Boolean);
const retries = await Promise.all([parallelSql(reserve(runs[liveWinner])), parallelSql(reserve(runs[liveWinner]))]);
assert.equal(JSON.parse(retries[0]).id, results[liveWinner]);
assert.equal(JSON.parse(retries[1]).id, results[liveWinner]);
assert.equal(sql(`select count(*) from app_private.portal_reservations where run_id in(${runs.map(quote)}) and kind='finale' and status in ('held','active')`), "1");
assert.equal(sql("select count(*) from app_private.email_outbox"), mailBefore);
console.log(JSON.stringify({ code: "FINALE_OVERRUN_CONCURRENCY_VERIFIED", competingScheduleWriters: 2, competingLiveWriters: 2, exactlyOnePlace: true, retriesReuseReservation: true, invalidOverrunRejected: true, noMail: true }));
