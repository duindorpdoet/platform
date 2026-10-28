begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
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
update journey set run_id=(api.run_start('23000000-0000-0000-0000-000000000002',
  (select array_agg(id) from (select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id
    where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null and c.participation_status='active' order by c.id limit 2) present),
  (select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'no-street-run-start','no-street-run-start')->>'runId')::uuid;
update journey j set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=j.run_id;

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table intent(snapshot jsonb,visit_id uuid,target uuid,command jsonb,preview jsonb,result jsonb,before_hash text,mails bigint);
insert into intent(snapshot,mails) select api.admin_live_planboard_snapshot('duindorp-halloween-2026'),(select count(*) from app_private.email_outbox);
update intent set visit_id=(select id from app_private.live_route_visits where group_id='23000000-0000-0000-0000-000000000002' and run_stop_id is null and kind='ordinary' order by sequence limit 1),target=(select p.id from app_private.portals p where p.id<>'12000000-0000-0000-0000-000000000030' and not exists(select 1 from app_private.live_route_visits v where v.group_id='23000000-0000-0000-0000-000000000002' and v.portal_id=p.id) and p.lifecycle_status='active' and app_private.portal_location_ready(p.id) order by p.id limit 1),before_hash=(select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=(select stop_id from journey));
update intent set command=jsonb_build_object('action','move','visitId',visit_id,'portalId',target,'startsAt',date_trunc('hour',clock_timestamp())+(ceil(extract(minute from clock_timestamp())/10)+2)*interval '10 minutes','shiftFollowing',true);
update intent set preview=api.admin_live_planboard_preview('duindorp-halloween-2026',command,snapshot->>'inputHash');
select lives_ok($$update intent set result=api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Een volgende poort van de lopende groep bewust aanpassen','live-run-route-intent-01')$$,'started group uses evening route intent rather than rewriting its original start');
select is((select md5(to_jsonb(s)::text) from app_private.run_stops s where s.id=(select stop_id from journey)),(select before_hash from intent),'manual future edit preserves every field of the current operational stop');
select is((select count(*) from app_private.email_outbox),(select mails from intent),'future route edit on a live group creates no historical time correction mail');
select throws_ok($$select api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',clock_timestamp(),(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'neutral','Lopende groep mag startregie niet omzeilen')$$,'23514','GROUP_ALREADY_STARTED','original start regie remains protected for a started group');
select ok(exists(select 1 from jsonb_array_elements(api.portal_arrivals_snapshot((select target from intent))->'arrivals') a where a->>'groupId'='23000000-0000-0000-0000-000000000002' and a->>'source'='route_intent'),'receiving portal sees the same accepted future route expectation');
update journey set credential=(select 'TEST-PORTAL-'||right(portal_id::text,2)||'-TOKEN' from app_private.run_stops where id=stop_id),choices=(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=journey.run_id and attendance='present');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update journey set arrival=api.run_arrive_and_advance(run_id,stop_id,run_version,credential,choices,'live-run-intent-arrival-01');
select ok(not exists(select 1 from app_private.run_stops s where s.run_id=(select run_id from journey) and s.portal_id=(select target from intent)),'future manual appointment waits until its genuine dispatch interval');
select lives_ok($$select app_private.dispatch_next_stop((select run_id from journey),(select starts_at from app_private.live_route_visits where id=(select visit_id from intent)),false,null)$$,'dispatcher rechecks capacity and releases the manually intended gate when due');
select is((select s.portal_id from app_private.group_runs r join app_private.run_stops s on s.id=r.current_stop_id where r.id=(select run_id from journey)),(select target from intent),'actual dispatch respects the manually selected next portal');
select ok((api.group_snapshot('23000000-0000-0000-0000-000000000002')->'run'->'currentStop') is not null,'authorized group receives its new actual current destination');
select * from finish();
rollback;
