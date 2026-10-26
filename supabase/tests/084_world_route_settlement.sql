begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table awards(eid uuid,run_id uuid,stop_id uuid,version integer,child_ids uuid[],participants uuid[],physical bigint,chapters bigint);
insert into awards(eid) select id from app_private.events where slug='duindorp-halloween-2026';
-- Two worlds are absent for the complete evening; retained active houses use a represented type.
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='circuswereld') where p.world_id in(select id from app_private.worlds where slug in ('heksenrijk','vampierrijk'));
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='anders') where p.id='12000000-0000-0000-0000-000000000001';
select ok((select missing_worlds @> array['heksenrijk','vampierrijk'] and cardinality(missing_worlds)=2 from app_private.world_coverage_policies where event_id=(select eid from awards) order by version desc limit 1),'coverage records exactly the two absent canonical worlds');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update awards set run_id=(api.run_start('23000000-0000-0000-0000-000000000002',array(select rc.id from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null),1,'world-start-01','world-start-01')->>'runId')::uuid;
update awards a set stop_id=r.current_stop_id,version=r.version from app_private.group_runs r where r.id=a.run_id;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=awards.run_id and attendance='present'),'world-arrival-01') from awards$$,'real scan with all children staying outside records legitimate arrival rewards');
update awards a set child_ids=array(select rc.child_id from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=a.run_id and rp.attendance='present'),participants=array(select id from app_private.run_participants where run_id=a.run_id and attendance='present'),physical=(select count(*) from app_private.poortenboek_passport_seals where run_id=a.run_id),chapters=(select count(*) from app_private.poortenboek_story_chapters where child_id in(select child_id from app_private.run_stop_arrivals where run_id=a.run_id));
select is((select count(*) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),(select cardinality(child_ids)::bigint from awards),'one permanent missing-world award per present child at first candy arrival');
select is((select count(*) from app_private.poortenboek_passport_seals where run_id=(select run_id from awards)),(select physical from awards),'bonus collection creates no extra physical visits');
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=awards.run_id and attendance='present'),'world-arrival-01') from awards$$,'duplicate scanner retry returns original command result');
select is((select count(*) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),(select cardinality(child_ids)::bigint from awards),'duplicate scan does not draw a second random world');

-- Accepted manual route contains a future suitable Anders stop after the real arrival.
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='anders') where p.id='12000000-0000-0000-0000-000000000003';
insert into app_private.live_route_plans(group_id,event_id) select '23000000-0000-0000-0000-000000000002',eid from awards;
insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,kind,source,run_stop_id) select eid,'23000000-0000-0000-0000-000000000002',1,'12000000-0000-0000-0000-000000000001',clock_timestamp(),300,'ordinary','manual',stop_id from awards;
insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,kind,source) select eid,'23000000-0000-0000-0000-000000000002',2,'12000000-0000-0000-0000-000000000003',clock_timestamp()+interval '20 minutes',300,'ordinary','expected' from awards;
select app_private.settle_child_worlds(id,'route_settlement') from app_private.run_participants where run_id=(select run_id from awards);
select is((select count(*) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),(select cardinality(child_ids)::bigint from awards),'future accepted candy stop defers the final fallback');
update app_private.live_route_visits set portal_id='12000000-0000-0000-0000-000000000004' where group_id='23000000-0000-0000-0000-000000000002' and sequence=2;
update app_private.live_route_plans set version=version+1 where group_id='23000000-0000-0000-0000-000000000002';
select is((select count(*) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),(select 2*cardinality(child_ids)::bigint from awards),'removing the last accepted future candy stop settles at the latest proven own arrival');
select is((select count(distinct run_stop_id) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),1::bigint,'route settlement references one actual house and invents no arrival');
select is((select count(*) from app_private.poortenboek_passport_seals where run_id=(select run_id from awards)),(select physical from awards),'route settlement preserves physical progress');
-- Reintroducing a missing theme never retracts earned compensation.
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='vampierrijk') where p.id='12000000-0000-0000-0000-000000000004';
select is((select count(*) from app_private.child_world_awards where child_id=any((select child_ids from awards)::uuid[])),(select 2*cardinality(child_ids)::bigint from awards),'late theme addition retains every earned collection record');
update app_private.portals set operation_status='paused' where id='12000000-0000-0000-0000-000000000004';
select app_private.refresh_world_coverage((select eid from awards));
select ok(not (select missing_worlds @> array['vampierrijk'] from app_private.world_coverage_policies where event_id=(select eid from awards) order by version desc limit 1),'temporary pause does not make a represented world absent');
select * from finish();
rollback;
