begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table linked_start(eid uuid,event_version integer,point_version integer,schedule_id uuid,run_id uuid,stop_id uuid,run_version integer,first_child uuid);
insert into linked_start(eid,event_version) select id,settings_version from app_private.events where slug='duindorp-halloween-2026';
update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '5 hours';
update app_private.event_route_settings set first_start_at=clock_timestamp()-interval '5 minutes',global_ordinary_stop_at=clock_timestamp()+interval '1 hour',final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '4 hours',finale_closes_at=clock_timestamp()+interval '5 hours',ordinary_visit_seconds=60,route_buffer_seconds=0,finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic' where event_id=(select eid from linked_start);
update app_private.start_points set point_type='portal',linked_portal_id='12000000-0000-0000-0000-000000000001',counts_as_first_portal_visit=true,version=version+1 where id='20000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update linked_start set point_version=(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001');
do $$begin perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select point_version from linked_start),true,'Fictieve expliciet gecontroleerde aansluiting bij het starthuis');end $$;
update linked_start set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',clock_timestamp()-interval '1 minute',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'neutral','Geïsoleerde vertrekafspraak bij een gekoppeld starthuis')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,(select event_version from linked_start));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from linked_start)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from linked_start),'revision',1)),(select event_version from linked_start),gen_random_uuid()::text);
end $$;
select is((select count(*)::integer from app_private.poortenboek_passport_seals),0,'publishing the linked start house grants no seal');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update linked_start set first_child=(select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id where a.group_id='23000000-0000-0000-0000-000000000001' and a.superseded_at is null limit 1);
update linked_start set run_id=(api.run_start('23000000-0000-0000-0000-000000000001',array[first_child],(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'linked-house-actual-start','linked-house-actual-start')->>'runId')::uuid;
update linked_start l set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=l.run_id;
select is((select portal_id from app_private.run_stops where id=(select stop_id from linked_start)),'12000000-0000-0000-0000-000000000001'::uuid,'the explicitly counted start house becomes the first actual released stop');
select is((select count(*)::integer from app_private.poortenboek_passport_seals),0,'run_start at that house still grants no seal');
select lives_ok($$select api.run_arrive_and_advance((select run_id from linked_start),(select stop_id from linked_start),(select run_version from linked_start),'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=(select run_id from linked_start) and attendance='present'),'linked-house-actual-arrival')$$,'a real scan confirms arrival even when the child stays outside');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from linked_start)),1,'only that actual arrival grants the personal start-house seal');

-- A later group's immutable appointment opts out of counting the same start house.
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.start_points set counts_as_first_portal_visit=false,version=version+1 where id='20000000-0000-0000-0000-000000000001';
update linked_start set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001',clock_timestamp()-interval '30 seconds',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'neutral','Tweede fictieve groep telt het starthuis expliciet niet mee')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000002',1,(select event_version from linked_start));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from linked_start)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from linked_start),'revision',1)),(select event_version from linked_start),gen_random_uuid()::text);
end $$;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update linked_start set first_child=(select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null order by c.id limit 1);
update linked_start set run_id=(api.run_start('23000000-0000-0000-0000-000000000002',array[first_child],(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'noncounted-house-actual-start','noncounted-house-actual-start')->>'runId')::uuid;
update linked_start l set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=l.run_id;
select isnt((select portal_id from app_private.run_stops where id=(select stop_id from linked_start)),'12000000-0000-0000-0000-000000000001'::uuid,'opted-out start house is not reintroduced as a normal destination');
select is((select count(*)::integer from app_private.run_participants where run_id=(select run_id from linked_start) and attendance='absent'),4,'the other four registered children remain explicitly absent');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from linked_start)),0,'neither the present nor absent children gain a seal merely by starting');
select * from finish();
rollback;
