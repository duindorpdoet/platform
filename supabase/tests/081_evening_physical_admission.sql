begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table finale_test(event_id uuid,g1 uuid,g2 uuid,g3 uuid,g4 uuid,slot_id uuid,pub1 uuid,pub2 uuid,pub3 uuid,pub4 uuid,run1 uuid,run2 uuid,run3 uuid,res1 uuid,res2 uuid,res3 uuid);
insert into finale_test(event_id,g1,g2,g3,g4) select id,'23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002','23000000-0000-0000-0000-000000000003','23000000-0000-0000-0000-000000000004' from app_private.events where slug='duindorp-halloween-2026';
grant all on finale_test to authenticated;
update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours';
update app_private.start_slots set starts_at=now()-interval '1 minute';
update app_private.event_route_settings set first_start_at=now()-interval '2 hours',global_ordinary_stop_at=now()+interval '2 hours',
 allowed_personal_stop_times=array[now()+interval '1 hour'],ordinary_visit_seconds=60,route_buffer_seconds=0,
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=now()-interval '1 hour',finale_last_arrival_at=now()+interval '4 hours',
 finale_closes_at=now()+interval '5 hours',finale_show_seconds=60,finale_turnover_seconds=120,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic',
 finale_waiting_area='',finale_safe_approach='' where event_id=(select event_id from finale_test);
create function pg_temp.publish_finale(gid uuid,target timestamptz,slot uuid default null) returns uuid language plpgsql as $$
declare sid uuid; pub uuid;
begin
 update app_private.group_schedule_revisions set state='superseded' where group_id=gid and state='published';
 insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
  select g.id,coalesce((select max(revision) from app_private.group_schedule_revisions where group_id=g.id),0)+1,'published',coalesce(slot,g.start_slot_id),now()+interval '2 hours',target,'neutral',clock_timestamp()
  from app_private.walking_groups g where g.id=gid returning id into sid;
 update app_private.walking_groups set route_mode='dynamic',current_schedule_revision_id=sid,start_slot_id=coalesce(slot,start_slot_id),version=version+1 where id=gid;
 select id into pub from app_private.group_start_publications where schedule_id=sid;
 return pub;
end $$;
create function pg_temp.start_finale_group(gid uuid,key text) returns uuid language sql security invoker as $$
 select (api.run_start(gid,array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(gid)) v),
 (api.group_snapshot(gid)#>>'{group,version}')::integer,key,key)->>'runId')::uuid
$$;
grant execute on function pg_temp.start_finale_group(uuid,text) to authenticated;
create function pg_temp.token(sid uuid) returns text language sql security definer set search_path='' as $$
 select 'TEST-PORTAL-'||right(coalesce(s.portal_id,p.portal_id)::text,2)||'-TOKEN' from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=sid
$$;
grant execute on function pg_temp.token(uuid) to authenticated;
create temp table admission_state(group_id uuid,run_id uuid,stop_id uuid,version integer,original_booking jsonb);
grant all on admission_state to authenticated;
update app_private.portals set operation_status='closed' where id not in ('12000000-0000-0000-0000-000000000028','12000000-0000-0000-0000-000000000030');
update app_private.portal_windows set visit_minutes=1,buffer_minutes=0,max_children_per_visit=6,max_concurrent_groups=1 where portal_id='12000000-0000-0000-0000-000000000028';
update app_private.walking_groups set desired_ordinary_visits=1 where id in(select g1 from finale_test union select g2 from finale_test);
update finale_test set pub1=pg_temp.publish_finale(g1,clock_timestamp()+interval '3 hours'),pub2=pg_temp.publish_finale(g2,clock_timestamp()+interval '3 hours');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
insert into admission_state(group_id,run_id) select g1,pg_temp.start_finale_group(g1,'admission-first-group') from finale_test;
update admission_state set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select is(api.group_snapshot((select g1 from finale_test))#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000028','first real start releases the only eligible physical house');
set local role postgres;
update app_private.portal_reservations set reserved_from=now()+interval '90 minutes',service_until=now()+interval '91 minutes',reserved_until=now()+interval '91 minutes' where run_id=(select run_id from admission_state) and kind='ordinary' and status='active';
set local role authenticated;
insert into admission_state(group_id,run_id) select g2,pg_temp.start_finale_group(g2,'admission-second-group') from finale_test;
update admission_state set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select is(api.group_snapshot((select g2 from finale_test))#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000028','second real start can use a nonoverlapping expected reception interval');
set local role postgres;
update app_private.portal_reservations set reserved_from=now()+interval '100 minutes',service_until=now()+interval '101 minutes',reserved_until=now()+interval '101 minutes' where run_id=(select run_id from admission_state where group_id=(select g2 from finale_test)) and kind='ordinary' and status='active';
update admission_state t set original_booking=(select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='ordinary' and b.status='active');
select is((select count(*)::integer from app_private.portal_reservations a join app_private.portal_reservations b on a.portal_id=b.portal_id and a.group_id<>b.group_id and a.reserved_from<b.reserved_until and a.reserved_until>b.reserved_from where a.kind='ordinary' and b.kind='ordinary' and a.status='active' and b.status='active'),0,'the fixture starts with genuinely nonoverlapping expected bookings');
set local role authenticated;
select lives_ok($$select api.run_scan_validate(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN') from admission_state where group_id=(select g2 from finale_test)$$,'preflight can accept before any actual group has entered');
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN','qr') from admission_state where group_id=(select g1 from finale_test)$$,'first actual early arrival claims physical reception now');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.run_support_override(run_id,stop_id,version,'Support mag de actuele fysieke huiscapaciteit niet passeren') from admission_state where group_id=(select g2 from finale_test)$$,'23514','PORTAL_CAPACITY_EXCEEDED','manual support admission uses the same actual physical capacity');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.run_scan_validate(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN') from admission_state where group_id=(select g2 from finale_test)$$,'23514','PORTAL_CAPACITY_EXCEEDED','new preflight sees the actual earlier occupancy');
select throws_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN','qr') from admission_state where group_id=(select g2 from finale_test)$$,'23514','PORTAL_CAPACITY_EXCEEDED','definitive direct scan cannot rely on an earlier preflight');
select throws_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN',(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'admission-second-blocked') from admission_state where group_id=(select g2 from finale_test)$$,'23514','PORTAL_CAPACITY_EXCEEDED','compound arrival uses the same physical admission boundary');
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence where run_stop_id in(select stop_id from admission_state)),1,'rejected group receives no false scan proof');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id in(select run_id from admission_state)),0,'capacity conflict creates no arrival facts');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id in(select run_id from admission_state)),0,'capacity conflict creates no seals');
select ok((select starts_at<now()+interval '1 minute' from app_private.ordinary_portal_bookings((select event_id from finale_test),'12000000-0000-0000-0000-000000000028',clock_timestamp()) where group_id=(select g1 from finale_test) and source='reservation'),'physical projection begins at the actual accepted scan, not the later ETA');
select is((select to_jsonb(b) from app_private.portal_reservations b where b.run_id=(select run_id from admission_state where group_id=(select g1 from finale_test)) and b.kind='ordinary' and b.status='active'),(select original_booking from admission_state where group_id=(select g1 from finale_test)),'actual admission does not rewrite the original expected reservation');
set local role authenticated;
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN','qr') from admission_state where group_id=(select g1 from finale_test)$$,'already accepted scan retry is not counted as a second physical admission');
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN',(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'admission-first-completed') from admission_state where group_id=(select g1 from finale_test)$$,'valid first scan completes inclusively even with the original later ETA');
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-28-TOKEN','qr') from admission_state where group_id=(select g2 from finale_test)$$,'second actual group can enter after first completion releases physical capacity');
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence where run_stop_id in(select stop_id from admission_state)),2,'sequential accepted groups each have exactly one actual scan');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from admission_state where group_id=(select g1 from finale_test))),1,'outside first child keeps the actual arrival');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from admission_state where group_id=(select g1 from finale_test))),1,'outside first child keeps the normal inclusive seal');
select ok(not has_function_privilege('authenticated','app_private.physical_portal_usage(uuid,uuid,uuid,timestamptz,timestamptz,integer,timestamptz)','execute'),'shared physical usage cannot enumerate private reception plans');
select * from finish();
rollback;
