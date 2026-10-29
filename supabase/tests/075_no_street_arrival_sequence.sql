begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/prepolicy-dynamic-run.inc
create temp table journey(eid uuid,event_version integer,schedule_id uuid,run_id uuid,stop_id uuid,run_version integer,
  stop_hash text,publication_hash text,credential text,choices jsonb,arrival jsonb,new_portal uuid,route_revision integer);
insert into journey(eid,event_version) select id,settings_version from app_private.events where slug='duindorp-halloween-2026';
grant select,update on journey to authenticated;
update app_private.walking_edges set approved_at=null;
update app_private.walking_nodes set verified_at=null;
update app_private.start_points set walking_node_id=null,verified_at=null,version=version+1;
update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '5 hours';
update app_private.event_route_settings set first_start_at=date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '30 minutes',global_ordinary_stop_at=clock_timestamp()+interval '1 hour',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '4 hours',
  finale_closes_at=clock_timestamp()+interval '5 hours',ordinary_visit_seconds=60,route_buffer_seconds=0,
  finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic'
where event_id=(select eid from journey);
update app_private.payment_requests set status='awaiting_link' where registration_id in(select registration_id from app_private.group_registrations where group_id='23000000-0000-0000-0000-000000000002' and superseded_at is null);
update app_private.walking_groups set desired_ordinary_visits=2 where id='23000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$begin perform api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',
  (select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001'));end $$;
update journey set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',
  date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '10 minutes',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),
  'neutral','Synthetische avond zonder straatnetwerk')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000002',1,(select event_version from journey));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from journey)],
   jsonb_build_array(jsonb_build_object('id',(select schedule_id from journey),'revision',1)),(select event_version from journey),'no-street-live-publication');
end $$;
update journey set publication_hash=(select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p);
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update journey set run_id=(pg_temp.prepolicy_dynamic_run('23000000-0000-0000-0000-000000000002',
  (select array_agg(id) from (select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id
    where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null and c.participation_status='active' order by c.id limit 2) present),
  (select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'no-street-run-start','no-street-run-start')->>'runId')::uuid;
update journey j set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=j.run_id;
select is((select count(*)::integer from app_private.run_participants where run_id=(select run_id from journey) and attendance='present'),2,'fixture starts two genuinely present children');
select ok((select stop_id is not null from journey),'real run automatically releases its first house without any graph');
select is((select count(*)::integer from app_private.run_stops where run_id=(select run_id from journey)),1,'only one destination is actually released');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from journey)),0,'dispatch does not fabricate arrivals');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from journey)),0,'dispatch does not fabricate child seals');
update journey set stop_hash=(select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=stop_id),
  route_revision=app_private.start_ops_route_revision(eid);
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update journey set new_portal=(api.admin_manual_portal_save('duindorp-halloween-2026',null,jsonb_build_object(
  'name','Nieuwe geschikte poort zonder paden','worldSlug',(select slug from app_private.worlds order by sort_order desc limit 1),
  'description','Synthetische nieuwe bestemming','intensity',1,'approvalStatus','approved','lifecycleStatus','active','operationStatus','scheduled',
  'street','FICTIEVE NIEUWE TESTSTRAAT','houseNumber','1','postalCode','0000XX','city','Testomgeving',
  'latitude',52.10,'longitude',4.26,'plannedOpensAt',date_trunc('day',clock_timestamp())-interval '12 hours',
  'plannedClosesAt',date_trunc('day',clock_timestamp())+interval '36 hours',
  'maxGroups',1,'maxChildren',100,'visitMinutes',1,'bufferMinutes',0),null,'Nieuw synthetisch huis zonder wandelkoppeling')->>'id')::uuid;
select ok(app_private.portal_location_ready((select new_portal from journey)),'new approved valid house is a candidate without a graph verification');
select ok(not app_private.portal_has_verified_walking_connection((select new_portal from journey)),'optional graph data is not falsely marked verified');
select isnt(app_private.start_ops_route_revision((select eid from journey)),(select route_revision from journey),'new suitable house visibly changes the private sequence revision');
select is((select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=(select stop_id from journey)),(select stop_hash from journey),'new house preserves every field of the already released stop');
select is((select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p),(select publication_hash from journey),'new candidate does not silently republish the appointment');
update app_private.portals set operation_status='closed' where id not in ((select portal_id from app_private.run_stops where id=(select stop_id from journey)),(select new_portal from journey),'12000000-0000-0000-0000-000000000030');
update journey set credential=(select 'TEST-PORTAL-'||right(portal_id::text,2)||'-TOKEN' from app_private.run_stops where id=stop_id),
  choices=(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=journey.run_id and attendance='present');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update journey set arrival=api.run_arrive_and_advance(run_id,stop_id,run_version,credential,choices,'no-street-first-arrival');
select is((select count(distinct run_stop_id)::integer from app_private.run_stop_arrivals where run_id=(select run_id from journey)),1,'real credential confirms one arrival');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from journey)),2,'both present children receive a seal even when they stay outside');
select is((select count(*)::integer from app_private.run_stops where run_id=(select run_id from journey)),2,'successful arrival automatically releases precisely one next stop');
select isnt((select current_stop_id from app_private.group_runs where id=(select run_id from journey)),(select stop_id from journey),'next destination changes only after confirmed arrival');
select is((select api.run_arrive_and_advance(run_id,stop_id,run_version,credential,choices,'no-street-first-arrival') from journey),(select arrival from journey),'retry with the original stop, version and key returns the original receipt');
select is((select count(distinct run_stop_id)::integer from app_private.run_stop_arrivals where run_id=(select run_id from journey)),1,'retry creates no duplicate visit');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from journey)),2,'retry creates no duplicate seals');
select is((select count(*)::integer from app_private.run_stops where run_id=(select run_id from journey)),2,'retry creates no additional next destination');
select ok(not (api.group_snapshot('23000000-0000-0000-0000-000000000002') ? 'ops'),'private future sequence remains absent from the authorized participant response');
select is((select count(*)::integer from app_private.walking_edges where approved_at is not null),0,'arrival and advancement require no new network approval');
select ok((select exists(select 1 from app_private.portal_reservations b join app_private.run_stops s on s.reservation_id=b.id where s.id=journey.stop_id and b.status='completed' and b.reserved_until>clock_timestamp()) from journey),'scan completion retains physical occupancy after next marker is released');
select ok((select app_private.group_has_visited_portal(eid,'23000000-0000-0000-0000-000000000002',(select portal_id from app_private.run_stops where id=stop_id)) from journey),'canonical group visit is recorded independently of current run destination');
select is((select count(*)::integer from app_private.group_portal_visits where group_id='23000000-0000-0000-0000-000000000002'),1,'one canonical visit for all present children and duplicate scans');
select ok(exists(select 1 from app_private.payment_requests where status='awaiting_link' and registration_id in(select registration_id from app_private.group_registrations where group_id='23000000-0000-0000-0000-000000000002' and superseded_at is null)),'unpaid run and scan preserve the real financial state');
select is((select s.portal_id from app_private.group_runs r join app_private.run_stops s on s.id=r.current_stop_id where r.id=(select run_id from journey)),(select new_portal from journey),'a newly suitable available house is automatically dispatched at the next valid choice');
-- Simulate an older plan-stop representation, with the new canonical index absent.
update app_private.run_stops s set plan_stop_id=(select ps.id from app_private.route_plan_stops ps where ps.portal_id=s.portal_id order by ps.position limit 1),portal_id=null,reservation_id=null,stop_kind=null
where s.id=(select stop_id from journey) and exists(select 1 from app_private.route_plan_stops ps where ps.portal_id=s.portal_id);
delete from app_private.group_portal_visits where group_id='23000000-0000-0000-0000-000000000002';
select ok((select app_private.group_has_visited_portal(eid,'23000000-0000-0000-0000-000000000002',coalesce(s.portal_id,ps.portal_id)) from journey j join app_private.run_stops s on s.id=j.stop_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id),'legacy stop relations still resolve a truly visited canonical house without the new index');
-- Starting a new run cannot make the previous real house a fresh candidate.
update app_private.group_runs set status='stopped',current_stop_id=null where id=(select run_id from journey);
insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at) select '23000000-0000-0000-0000-000000000002',schedule_id,'live',clock_timestamp() from journey;
select ok((select app_private.group_has_visited_portal(eid,'23000000-0000-0000-0000-000000000002',coalesce(s.portal_id,ps.portal_id)) from journey j join app_private.run_stops s on s.id=j.stop_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id),'new run identity preserves earlier canonical visit exclusion');
select * from finish();
rollback;
