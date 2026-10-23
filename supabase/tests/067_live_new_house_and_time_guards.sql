begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table ops_house(eid uuid,event_version integer,group_version integer,schedule_id uuid,run_id uuid,stop_id uuid,stop_hash text,
  child_id uuid,new_portal uuid,new_node uuid,new_version integer,expected_arrival timestamptz);
insert into ops_house(eid,event_version,group_version,child_id)
select e.id,e.settings_version,g.version,(select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id
  where a.group_id=g.id and a.superseded_at is null and c.participation_status='active' limit 1)
from app_private.events e join app_private.walking_groups g on g.event_id=e.id and g.id='23000000-0000-0000-0000-000000000001'
where e.slug='duindorp-halloween-2026';
grant select,update on ops_house to authenticated;
select is(app_private.parse_amsterdam_instant('2026-10-31T17:30:00+01:00'),'2026-10-31T16:30:00Z'::timestamptz,'server parses an explicit Amsterdam event time');
select throws_ok($$select app_private.parse_amsterdam_instant('2026-03-29T02:30:00+01:00')$$,'22023','INVALID_AMSTERDAM_TIME','server rejects a spring-gap wall time');
select throws_ok($$select app_private.parse_amsterdam_instant('2026-10-25T01:30:00Z')$$,'22023','AMBIGUOUS_AMSTERDAM_TIME','server rejects the ambiguous autumn hour');
select throws_ok($$select app_private.parse_amsterdam_instant('2026-10-31T17:30')$$,'22023','INVALID_AMSTERDAM_TIME','server JSON commands require an explicit UTC instant or offset');

update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '5 hours';
update app_private.event_route_settings set first_start_at=clock_timestamp()-interval '5 minutes',global_ordinary_stop_at=clock_timestamp()+interval '1 hour',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '4 hours',
  finale_closes_at=clock_timestamp()+interval '5 hours',ordinary_visit_seconds=60,route_buffer_seconds=0,
  finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic'
where event_id=(select eid from ops_house);
update app_private.walking_groups set desired_ordinary_visits=2 where id='23000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$begin perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,true,'Fictieve gecontroleerde vertrekstoep');end $$;
update ops_house set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',clock_timestamp()-interval '1 minute',(select group_version from ops_house),'neutral','Geïsoleerde start voor de nieuwe-huisproef')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,(select event_version from ops_house));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from ops_house)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from ops_house),'revision',1)),(select event_version from ops_house),gen_random_uuid()::text);
end $$;
update ops_house set group_version=g.version from app_private.walking_groups g where g.id='23000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update ops_house set run_id=(api.run_start('23000000-0000-0000-0000-000000000001',array[(select child_id from ops_house)],(select group_version from ops_house),'new-house-start-fixture','new-house-start-fixture')->>'runId')::uuid;
set local role postgres;
update ops_house set stop_id=r.current_stop_id from app_private.group_runs r where r.id=run_id;
update ops_house set stop_hash=md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=stop_id;
select is((select portal_id from app_private.run_stops where id=(select stop_id from ops_house)),'12000000-0000-0000-0000-000000000001'::uuid,'the original first destination is actually released before the new house exists');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from ops_house)),0,'starting a route fabricates no arrivals');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update ops_house set new_portal=(api.admin_manual_portal_save('duindorp-halloween-2026',null,
  jsonb_build_object('name','Synthetische nieuwe poort','worldSlug',(select w.slug from app_private.worlds w join app_private.portals p on p.world_id=w.id where p.id='12000000-0000-0000-0000-000000000002'),
    'description','Afzonderlijke nieuwe-huisfixture','intensity',1,'approvalStatus','approved','lifecycleStatus','active','operationStatus','scheduled',
    'street','FICTIEVE NIEUWE TESTSTRAAT','houseNumber','1','postalCode','0000XX','city','Testomgeving',
    'latitude',(select coordinate[1] from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001'),
    'longitude',(select coordinate[0]+0.00001 from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001'),
    'plannedOpensAt',clock_timestamp()+interval '2 minutes','plannedClosesAt',clock_timestamp()+interval '4 hours',
    'maxGroups',1,'maxChildren',100,'visitMinutes',1,'bufferMinutes',0),null,'Nieuwe fictieve poort via de echte handmatige invoer')->>'id')::uuid;
update ops_house set new_node=n.id,new_version=p.version from app_private.walking_nodes n join app_private.portals p on p.id=n.portal_id where p.id=new_portal;
select ok(not app_private.portal_has_verified_walking_connection((select new_portal from ops_house)),'coordinates and approval alone do not approve a new walking connection');
select is((select verified_at from app_private.walking_nodes where id=(select new_node from ops_house)),null::timestamptz,'the real manual-input command does not auto-verify a walking node');
select is((select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=(select stop_id from ops_house)),(select stop_hash from ops_house),'creating a new house preserves the entire already-released stop');
set local role authenticated;
select throws_ok($$select api.admin_verify_portal_walking_connection('duindorp-halloween-2026',(select new_portal from ops_house),(select new_version from ops_house),false,'Fictieve veilige aanloop',true)$$,'23514','SAFE_CONNECTION_REQUIRED','a new walking edge cannot be approved without the safety checkbox');
select lives_ok($$select api.admin_verify_portal_walking_connection('duindorp-halloween-2026',(select new_portal from ops_house),(select new_version from ops_house),true,'Gecontroleerde fictieve aanloop vanaf de veilige stoep',true)$$,'explicit authorized verification connects the house to an actual approved fixture edge');
set local role postgres;
select ok(app_private.portal_has_verified_walking_connection((select new_portal from ops_house)),'verified new house is now a safe route candidate');
select is((select count(*)::integer from app_private.walking_edges where approved_at is not null and closed_at is null and (from_node_id=(select new_node from ops_house) or to_node_id=(select new_node from ops_house))),1,'verification creates one reviewed connection rather than synthetic proof for the whole network');
select is((select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=(select stop_id from ops_house)),(select stop_hash from ops_house),'new-house approval still does not replace the current destination or pending arrival');
select ok(exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'stops') stop where stop->>'portalId'=(select new_portal::text from ops_house)),'a house opening later is included when the estimated arrival falls within its window');
update ops_house set expected_arrival=(select (stop->>'plannedArrivalAt')::timestamptz from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'stops') stop where stop->>'portalId'=new_portal::text);
update app_private.portal_windows set closes_at=(select expected_arrival from ops_house) where portal_id=(select new_portal from ops_house);
select ok(not exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'stops') stop where stop->>'portalId'=(select new_portal::text from ops_house)),'a portal closing exactly at arrival is excluded');
update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '4 hours' where portal_id=(select new_portal from ops_house);
select is((select current_stop_id from app_private.group_runs where id=(select run_id from ops_house)),(select stop_id from ops_house),'recalculating previews and windows keeps the current released stop fixed');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create function pg_temp.new_house_arrive(_credential text,_key text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; choices jsonb;
begin
 select * into r from app_private.group_runs where id=(select run_id from pg_temp.ops_house);
 select jsonb_object_agg(id::text,'skipped') into choices from app_private.run_participants where run_id=r.id and attendance='present';
 return api.run_arrive_and_advance(r.id,r.current_stop_id,r.version,_credential,choices,_key);
end $$;
set local role postgres;
-- Own the temporary helper as postgres, while api.run_arrive_and_advance still
-- checks the real JWT actor. The helper only supplies synthetic fixture IDs.
alter function pg_temp.new_house_arrive(text,text) owner to postgres;
grant execute on function pg_temp.new_house_arrive(text,text) to authenticated;
set local role authenticated;
select lives_ok($$select pg_temp.new_house_arrive('TEST-PORTAL-01-TOKEN','new-house-first-arrival')$$,'the existing current arrival completes without being rewritten by new-house planning');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,currentStop,portal,id}',(select new_portal::text from ops_house),'the newly verified manual house can become the next actual destination');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from ops_house)),1,'the outside child receives exactly one real arrival at the first house');
select is((select count(*)::integer from app_private.run_stops where run_id=(select run_id from ops_house) and state='completed'),1,'new-house planning preserves completed stop history');
insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from)
select new_portal,extensions.digest('TEST-NEW-HOUSE-OPS-TOKEN','sha256'),extensions.digest('NEWOPS','sha256'),1,clock_timestamp()-interval '1 minute' from ops_house;
update app_private.portals set operation_status='open' where id=(select new_portal from ops_house);
set local role authenticated;
select lives_ok($$select pg_temp.new_house_arrive('TEST-NEW-HOUSE-OPS-TOKEN','new-house-second-arrival')$$,'the second outside arrival uses the actual new portal credential');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,currentStop,kind}','finale','the selected two-house maximum includes physically reached outside visits');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from ops_house)),2,'new dispatch does not manufacture a finale arrival');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from ops_house)),2,'only the two genuinely reached houses grant seals');
select * from finish();
rollback;
