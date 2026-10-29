begin;
create extension if not exists pgtap with schema extensions;
create function pg_temp.fixture_route_registration() returns uuid language plpgsql as $$
declare h uuid;r uuid;c uuid;begin
 insert into app_private.households(label,primary_contact_user_id) values('Synthetische planbordfixture','f0000000-0000-0000-0000-000000000001') returning id into h;
 insert into app_private.household_members(household_id,user_id,relation_role) values(h,'f0000000-0000-0000-0000-000000000001','owner');
 insert into app_private.registrations(event_id,household_id,status,reference,submitted_at)
 select id,h,'submitted','DPH-2026-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),clock_timestamp()
 from app_private.events where slug='duindorp-halloween-2026' returning id into r;
 insert into app_private.children(household_id,first_name,age_at_event) values(h,'Synthetisch kind',8) returning id into c;
 insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)
 select event_id,r,c,250 from app_private.registrations where id=r;
 return r;end $$;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table bounded(eid uuid,snapshot jsonb,hash text,visits jsonb,plans jsonb,mail_count bigint,command jsonb);
insert into bounded(eid,mail_count) select id,(select count(*) from app_private.email_outbox) from app_private.events where slug='duindorp-halloween-2026';

-- Mark existing synthetic groups initialized, including intentionally empty routes.
-- Looking at that empty accepted state must never regenerate it.
insert into app_private.live_route_plans(group_id,event_id,schedule_id)
select g.id,g.event_id,g.current_schedule_revision_id from app_private.walking_groups g where g.event_id=(select eid from bounded)
on conflict(group_id) do nothing;

-- Five independent, stored legacy proposals make cold initialization observable
-- without invoking a dynamic planner or depending on today's clock.
create temp table cold_groups(group_id uuid,plan_id uuid,n integer,registration_id uuid);
insert into cold_groups select gen_random_uuid(),gen_random_uuid(),n,pg_temp.fixture_route_registration() from generate_series(1,6) n;
insert into app_private.walking_groups(id,event_id,code,status,route_mode,start_slot_id)
select group_id,(select eid from bounded),'BOUNDED-SYNTHETIC-'||n,'draft','legacy',
 (select start_slot_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002') from cold_groups;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
select group_id,registration_id,1 from cold_groups;
insert into app_private.route_plan_versions(id,group_id,revision,state,generated_by,input_hash)
select plan_id,group_id,1,'valid','f0000000-0000-0000-0000-000000000001','bounded-proposal-'||n from cold_groups;
insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
select c.plan_id,stop.position,stop.portal_id,stop.starts_at+make_interval(mins=>10*c.n),stop.starts_at+make_interval(mins=>10*c.n)+interval '5 minutes' from cold_groups c cross join(values
 (1,'12000000-0000-0000-0000-000000000001'::uuid,'2026-10-31T18:30:00+01'::timestamptz),
 (2,'12000000-0000-0000-0000-000000000002'::uuid,'2026-10-31T18:45:00+01'::timestamptz)) stop(position,portal_id,starts_at);
update app_private.route_plan_versions set state='published',published_at=clock_timestamp() where id in(select plan_id from cold_groups);
update app_private.walking_groups g set current_plan_version_id=c.plan_id from cold_groups c where c.group_id=g.id;
insert into app_private.live_route_plans(group_id,event_id,version)
select group_id,(select eid from bounded),7 from cold_groups where n=6;
create temp table empty_route as select p.* from app_private.live_route_plans p join cold_groups c on c.group_id=p.group_id where c.n=6;

update bounded set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026');
select is((select count(*) from app_private.live_route_plans p join cold_groups c on c.group_id=p.group_id where c.n<=5),2::bigint,'one cold request initializes at most two physical groups');
select is((select (snapshot->>'initializationPending')::integer from bounded),3,'snapshot explicitly reports the remaining groups instead of pretending completeness');
select throws_ok($$select api.admin_live_planboard_preview('duindorp-halloween-2026','{"action":"move","visitId":"00000000-0000-0000-0000-000000000000"}',snapshot->>'inputHash') from bounded$$,'55000','LIVE_PLANBOARD_INITIALIZING','direct route mutation is blocked while part of the event is still initializing');
update bounded set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026');
select is((select count(*) from app_private.live_route_plans p join cold_groups c on c.group_id=p.group_id where c.n<=5),4::bigint,'second request advances the next bounded batch exactly once');
select is((select (snapshot->>'initializationPending')::integer from bounded),1,'remaining initialization count follows actual saved plans');
update bounded set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026');
select is((select count(*) from app_private.live_route_plans p join cold_groups c on c.group_id=p.group_id where c.n<=5),5::bigint,'subsequent read completes the finite proposal set');
select is((select (snapshot->>'initializationPending')::integer from bounded),0,'completed initialization is reported accurately');
select is((select count(*) from app_private.live_route_visits v join cold_groups c on c.group_id=v.group_id where v.retired_at is null),10::bigint,'bounded batches preserve each complete two-stop proposal without duplicate visits');
select is((select count(*) from app_private.live_route_visits v join empty_route p on p.group_id=v.group_id),0::bigint,'an initialized empty route remains intentionally empty');

update bounded set hash=snapshot->>'inputHash',visits=snapshot->'visits',plans=(select jsonb_agg(to_jsonb(p) order by p.group_id) from app_private.live_route_plans p where p.event_id=bounded.eid);
select is(api.admin_live_planboard_snapshot('duindorp-halloween-2026')->>'inputHash',(select hash from bounded),'warm reads retain exact input hash');
select is(api.admin_live_planboard_snapshot('duindorp-halloween-2026')->'visits',(select visits from bounded),'warm reads preserve all intent identities, times and versions');
select is((select jsonb_agg(to_jsonb(p) order by p.group_id) from app_private.live_route_plans p where p.event_id=(select eid from bounded)),(select plans from bounded),'ordinary refresh never increments any plan version, including an empty one');
select is((select count(*) from app_private.email_outbox),(select mail_count from bounded),'initialization and warm refresh send no participant communication');
select ok(not exists(select 1 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join cold_groups c on c.group_id=r.group_id),'viewing stored proposals creates no operational runs or physical arrivals');
create temp table run_revisions(old_run uuid,new_run uuid);
insert into run_revisions values(gen_random_uuid(),gen_random_uuid());
insert into app_private.group_runs(id,group_id,active_plan_version_id,status,created_at)
select old_run,c.group_id,c.plan_id,'completed',clock_timestamp()-interval '1 hour' from run_revisions cross join cold_groups c where c.n=1;
insert into app_private.group_runs(id,group_id,active_plan_version_id,status,created_at)
select new_run,c.group_id,c.plan_id,'live',clock_timestamp() from run_revisions cross join cold_groups c where c.n=1;
update bounded set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026');
select is((select count(*) from bounded,jsonb_array_elements(snapshot->'groups') item where item->>'id'=(select group_id::text from cold_groups where n=1)),1::bigint,'one physical group appears once after historical run and active run coexist');
select is((select item->>'runId' from bounded,jsonb_array_elements(snapshot->'groups') item where item->>'id'=(select group_id::text from cold_groups where n=1)),(select new_run::text from run_revisions),'snapshot chooses the current active run after a run switch');
update bounded set hash=snapshot->>'inputHash';

-- A later route edit must still invalidate a command based on the former hash.
update bounded set command=jsonb_build_object('action','move','visitId',v.id,'portalId',v.portal_id,'startsAt','2026-10-31T18:40:00+01','shiftFollowing',false)
from app_private.live_route_visits v join cold_groups c on c.group_id=v.group_id where c.n=1 and v.sequence=1;
update app_private.live_route_visits set version=version+1 where group_id=(select group_id from cold_groups where n=1) and sequence=1;
select throws_ok($$select api.admin_live_planboard_apply('duindorp-halloween-2026',command,hash,false,'Verouderde route mag niet worden opgeslagen','bounded-stale-apply-01') from bounded$$,'40001','STALE_VERSION','faster snapshots retain server stale-hash enforcement for direct writes');

select ok(not has_function_privilege('authenticated','api.admin_live_planboard_snapshot_before_worlds(text)','execute'),'clients cannot bypass the authorized snapshot wrapper');
select ok(not has_function_privilege('authenticated','app_private.live_planboard_seed(uuid)','execute'),'clients cannot invoke private initialization');
select ok(not has_function_privilege('authenticated','app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb)','execute'),'clients cannot submit their own authority snapshot');
select ok(not has_function_privilege('authenticated','app_private.portal_interval_available_from_occupancy(uuid,uuid,timestamptz,timestamptz,integer,jsonb)','execute'),'clients cannot substitute fake occupancy');
select ok(not has_table_privilege('authenticated','app_private.live_route_visits','select'),'full future route storage remains private');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.admin_live_planboard_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','ordinary parent cannot obtain the admin route snapshot');
select set_config('request.jwt.claims','{"role":"anon"}',true);
select throws_ok($$select api.admin_live_planboard_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','unauthenticated direct calls remain rejected');

-- Captured occupancy uses distinct physical groups and half-open intervals,
-- while preserving the separate all-evening total-child reception policy.
create temp table reception(portal uuid,own_group uuid,other_group uuid,occupancy jsonb);
insert into reception select '12000000-0000-0000-0000-000000000028',
 (select group_id from cold_groups where n=1),(select group_id from cold_groups where n=2),'[]'::jsonb;
update app_private.portal_windows set opens_at='2026-10-31T18:00:00+01',closes_at='2026-10-31T22:00:00+01',
 max_concurrent_groups=1,max_children_per_visit=8,max_children_total=8 where portal_id=(select portal from reception);
update reception set occupancy=jsonb_build_array(jsonb_build_object('group_id',other_group,'starts_at','2026-10-31T18:00:00+01','ends_at','2026-10-31T18:10:00+01','child_count',4));
select ok(app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:10:00+01','2026-10-31T18:15:00+01',4,occupancy),'touching physical intervals do not overlap') from reception;
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:09:59+01','2026-10-31T18:15:00+01',4,occupancy),'one second overlap still exceeds actual one-group capacity') from reception;
update app_private.portal_windows set max_concurrent_groups=2 where portal_id=(select portal from reception);
update reception set occupancy=occupancy||occupancy||jsonb_build_array(jsonb_build_object('group_id',own_group,'starts_at','2026-10-31T18:00:00+01','ends_at','2026-10-31T18:30:00+01','child_count',99));
select ok(app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:05:00+01','2026-10-31T18:15:00+01',4,occupancy),'alternative reservations of the same physical group count once and own reservation is replaced') from reception;
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:05:00+01','2026-10-31T18:15:00+01',5,occupancy),'deduplication does not bypass the total eight-child limit') from reception;
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:05:00+01','2026-10-31T18:15:00+01',9,'[]'),'per-visit child capacity remains hard') from reception;
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:15:00+01','2026-10-31T18:15:00+01',4,'[]'),'zero-duration interval is rejected') from reception;
select ok(app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T21:55:00+01','2026-10-31T22:00:00+01',4,'[]'),'service ending at physical closing is valid') from reception;
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T21:55:00+01','2026-10-31T22:00:01+01',4,'[]'),'physical closing cannot be exceeded by one second') from reception;
update app_private.portal_windows set max_concurrent_groups=1 where portal_id=(select portal from reception);
update reception set occupancy=jsonb_build_array(jsonb_build_object('group_id',other_group,'starts_at','2026-10-31T18:20:00+01','ends_at','2026-10-31T18:30:00+01','child_count',4));
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:15:00+01','2026-10-31T18:25:00+01',4,occupancy),'later boundaries inside a requested interval remain capacity checked') from reception;
update reception set occupancy=jsonb_build_array(jsonb_build_object('group_id',other_group,'starts_at',null,'ends_at',null,'child_count',5));
select ok(not app_private.portal_interval_available_from_occupancy(portal,own_group,'2026-10-31T18:15:00+01','2026-10-31T18:25:00+01',4,occupancy),'proven historical children still count toward the all-evening total') from reception;
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
select (select eid from bounded),portal,other_group,'ordinary','held','2026-10-31T18:20:00+01','2026-10-31T18:30:00+01',4 from reception;
select ok(not app_private.portal_interval_available(portal,own_group,'2026-10-31T18:15:00+01','2026-10-31T18:25:00+01',4,clock_timestamp()),'dispatcher wrapper enforces real held reservation overlap') from reception;
select ok(app_private.portal_interval_available(portal,own_group,'2026-10-31T18:30:00+01','2026-10-31T18:35:00+01',4,clock_timestamp()),'dispatcher wrapper permits a real touching reservation within total-child limit') from reception;
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
select (select eid from bounded),portal,other_group,'ordinary','held','2026-10-31T18:20:00+01','2026-10-31T18:30:00+01',3 from reception;
update app_private.portal_windows set max_concurrent_groups=2 where portal_id=(select portal from reception);
select ok(app_private.portal_interval_available(portal,own_group,'2026-10-31T18:20:00+01','2026-10-31T18:25:00+01',4,clock_timestamp()),'dispatcher deduplicates real alternative reservations of one physical group') from reception;
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
select (select eid from bounded),portal,(select group_id from cold_groups where n=3),'ordinary','held','2026-10-31T18:40:00+01','2026-10-31T18:45:00+01',1 from reception;
select ok(not app_private.portal_interval_available(portal,own_group,'2026-10-31T18:30:00+01','2026-10-31T18:35:00+01',4,clock_timestamp()),'dispatcher cannot bypass real total-child reception budget using a non-overlapping time') from reception;
select * from finish();
rollback;
