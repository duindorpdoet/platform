import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { requireLocalTogetherDatabase, sql, parallelSql } from "./together-fixtures.mjs";

requireLocalTogetherDatabase();
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const mailBefore = sql("select count(*) from app_private.email_outbox");
const fixture = JSON.parse(sql(`${readFileSync("supabase/tests/fixtures/legacy-start-available.inc", "utf8")}
 update app_private.events set settings=settings||'{"portalRegistrationOpen":true}'::jsonb where slug='duindorp-halloween-2026';
 update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='circuswereld')
 where p.world_id in(select id from app_private.worlds where slug in('vampierrijk','geestenwereld','besmette-zone'));
 update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='anders') where p.id='12000000-0000-0000-0000-000000000001';
 do $$ declare rid uuid; sid uuid; ver integer; begin
 perform set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
 rid:=(api.run_start('23000000-0000-0000-0000-000000000002',array(select rc.id from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null),1,'world-race-start','world-race-start')->>'runId')::uuid;
 select current_stop_id,version into sid,ver from app_private.group_runs where id=rid;
 perform api.run_arrive_and_advance(rid,sid,ver,'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=rid and attendance='present'),'world-race-arrive');
 end $$;
 update app_private.events set settings=settings||'{"portalRegistrationOpen":false}'::jsonb where slug='duindorp-halloween-2026';
 select jsonb_build_object('event',a.event_id,'child',a.child_id,'stop',a.run_stop_id,'participant',a.run_participant_id)
 from app_private.run_stop_arrivals a join app_private.group_runs r on r.id=a.run_id
 where r.group_id='23000000-0000-0000-0000-000000000002' and a.arrived order by a.child_id limit 1;`));
const total = () => Number(sql(`select count(*) from app_private.child_world_awards where event_id=${quote(fixture.event)} and child_id=${quote(fixture.child)} and origin='compensation'`));
const draw = all => `begin;select app_private.award_missing_worlds(${quote(fixture.event)},${quote(fixture.child)},${quote(fixture.stop)},${quote(fixture.participant)},${all},'${all ? "own_departure" : "arrival"}');select pg_sleep(0.1);commit;`;
assert.equal(total(), 0, "provisional arrival does not draw compensation");
await Promise.all(Array.from({ length: 6 }, () => parallelSql(draw(false))));
assert.equal(total(), 1, "concurrent arrival requests draw exactly one permanent world");
const first = sql(`select world_slug||':'||awarded_at::text from app_private.child_world_awards where event_id=${quote(fixture.event)} and child_id=${quote(fixture.child)} and origin='compensation'`);
await Promise.all(Array.from({ length: 6 }, () => parallelSql(draw(false))));
assert.equal(total(), 1, "retry does not reroll");
assert.equal(sql(`select world_slug||':'||awarded_at::text from app_private.child_world_awards where event_id=${quote(fixture.event)} and child_id=${quote(fixture.child)} and origin='compensation'`), first);
await Promise.all(Array.from({ length: 6 }, () => parallelSql(draw(true))));
assert.equal(total(), 3, "simultaneous final settlement fills only remaining worlds");
assert.equal(sql(`select count(*) from app_private.child_world_awards where event_id=${quote(fixture.event)} and child_id=${quote(fixture.child)} and origin='compensation' and world_slug||':'||awarded_at::text=${quote(first)}`), "1", "original random result survives settlement");
assert.equal(sql("select count(*) from app_private.email_outbox"), mailBefore);
console.log(JSON.stringify({ code: "WORLD_COMPENSATION_CONCURRENCY_VERIFIED", simultaneousWriters: 6, oneArrivalDraw: true, noReroll: true, settlementTotal: 3, noMail: true }));
