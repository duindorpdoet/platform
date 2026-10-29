begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
create temp table linked_start(eid uuid,event_version integer,point_id uuid,point_version integer,schedule_id uuid,run_id uuid,stop_id uuid,run_version integer,first_child uuid,starts_at timestamptz,fixture jsonb,proposal jsonb);
insert into linked_start(eid,event_version,starts_at) select id,settings_version,date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '20 minutes' from app_private.events where slug='duindorp-halloween-2026';
update linked_start set fixture=pg_temp.joint_canonical_fixture(starts_at);
update linked_start set point_id=(fixture#>>'{source,pointId}')::uuid;
update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour' where portal_id in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002');

-- Prepare both real immutable appointments before reviewing their shared
-- physical calendar. Publishing either appointment still grants no seal.
update app_private.start_points set point_type='portal',linked_portal_id='12000000-0000-0000-0000-000000000001',counts_as_first_portal_visit=true,version=version+1 where id=(select point_id from linked_start);
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update linked_start set point_version=(select version from app_private.start_points where id=point_id);
do $$begin
 perform api.admin_startregie_verify_point('duindorp-halloween-2026',(select point_id from linked_start),(select point_version from linked_start),true,'Fictieve expliciet gecontroleerde aansluiting bij het starthuis');
end $$;
update linked_start set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001',point_id,starts_at,(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'neutral','Geïsoleerde vertrekafspraak bij een gekoppeld starthuis')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(select revision from app_private.group_schedule_revisions where id=(select schedule_id from linked_start)),(select event_version from linked_start));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from linked_start)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from linked_start),'revision',(select revision from app_private.group_schedule_revisions where id=(select schedule_id from linked_start)))),(select event_version from linked_start),gen_random_uuid()::text);
end $$;
select is((select count(*)::integer from app_private.poortenboek_passport_seals),0,'publishing the linked start house grants no seal');

-- A second stored appointment explicitly opts out of counting the same house.
-- Its separate finale remains ten minutes later, without extra capacity.
update app_private.start_points set counts_as_first_portal_visit=false,version=version+1 where id=(select point_id from linked_start);
update app_private.event_route_settings set finale_planning_transfer_seconds=1200 where event_id=(select eid from linked_start);
update linked_start set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002',point_id,starts_at-interval '10 minutes',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'neutral','Tweede fictieve groep telt het starthuis expliciet niet mee')->>'id')::uuid;
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000002',(select revision from app_private.group_schedule_revisions where id=(select schedule_id from linked_start)),(select event_version from linked_start));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from linked_start)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from linked_start),'revision',(select revision from app_private.group_schedule_revisions where id=(select schedule_id from linked_start)))),(select event_version from linked_start),gen_random_uuid()::text);
end $$;
update app_private.event_route_settings set finale_planning_transfer_seconds=600 where event_id=(select eid from linked_start);

-- New journeys require an explicitly accepted shared route. Real incoming
-- travel is retained; the two immediate first doors are different houses.
create function pg_temp.linked_house_proposal()returns jsonb language plpgsql as $$
declare input jsonb:=api.admin_joint_route_planning_input('duindorp-halloween-2026');proposal jsonb:=pg_temp.joint_proposal();plans jsonb:='[]';plan jsonb;g jsonb;p jsonb;finale jsonb;incoming jsonb;outgoing jsonb;win jsonb;arrival timestamptz;first_id text;
begin
 for plan in select *from jsonb_array_elements(proposal->'groups') loop
  if plan->>'groupId' in('23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002')then
   first_id:=case when plan->>'groupId'='23000000-0000-0000-0000-000000000001'then '12000000-0000-0000-0000-000000000001'else '12000000-0000-0000-0000-000000000002'end;
   select *into g from jsonb_array_elements(input->'groups')item where item->>'id'=plan->>'groupId';
   select *into p from jsonb_array_elements(input->'portals')item where item->>'id'=first_id;
   select *into finale from jsonb_array_elements(input->'portals')item where item->>'id'=g#>>'{finale,portalId}';
   select *into incoming from jsonb_array_elements(input->'legs')leg where leg->>'from'=g->>'startNodeId'and leg->>'to'=p->>'nodeId';
   select *into outgoing from jsonb_array_elements(input->'legs')leg where leg->>'from'=p->>'nodeId'and leg->>'to'=finale->>'nodeId';
   arrival:=clock_timestamp()-interval '5 seconds'+make_interval(secs=>(incoming->>'seconds')::integer);
   select *into win from jsonb_array_elements(p->'windows')w where arrival>=(w->>'opensAt')::timestamptz and arrival<(w->>'arrivalClosesAt')::timestamptz limit 1;
   plan:=jsonb_set(plan,'{visits}',jsonb_build_array(jsonb_build_object('portalId',first_id,'kind','ordinary','sequence',1,'startsAt',arrival,
    'visitSeconds',win->'visitSeconds','bufferSeconds',win->'bufferSeconds','walkSeconds',incoming->'seconds','walkMeters',incoming->'meters'),
    (plan->'visits'->1)||jsonb_build_object('walkSeconds',outgoing->'seconds','walkMeters',outgoing->'meters')));
  end if;
  plans:=plans||jsonb_build_array(plan);
 end loop;
 return pg_temp.joint_rehash(jsonb_set(proposal,'{groups}',plans));
end $$;
update linked_start set proposal=pg_temp.linked_house_proposal();
do $$begin
 perform api.admin_joint_route_plan_apply('duindorp-halloween-2026',(select proposal from linked_start),true,'Expliciet beoordeelde synthetische routes voor de echte starthuisscan',gen_random_uuid()::text);
end $$;

select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update linked_start set first_child=(select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id where a.group_id='23000000-0000-0000-0000-000000000001'and a.superseded_at is null order by c.id limit 1);
update linked_start set run_id=(api.run_start('23000000-0000-0000-0000-000000000001',array[first_child],(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'linked-house-actual-start','linked-house-actual-start')->>'runId')::uuid;
update linked_start l set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=l.run_id;
select is((select portal_id from app_private.run_stops where id=(select stop_id from linked_start)),'12000000-0000-0000-0000-000000000001'::uuid,'the explicitly counted start house becomes the first actual released stop');
select is((select count(*)::integer from app_private.poortenboek_passport_seals),0,'run_start at that house still grants no seal');
select lives_ok($$select api.run_arrive_and_advance((select run_id from linked_start),(select stop_id from linked_start),(select run_version from linked_start),'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped')from app_private.run_participants where run_id=(select run_id from linked_start)and attendance='present'),'linked-house-actual-arrival')$$,'a real scan confirms arrival even when the child stays outside');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from linked_start)),1,'only that actual arrival grants the personal start-house seal');

update linked_start set first_child=(select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id where a.group_id='23000000-0000-0000-0000-000000000002'and a.superseded_at is null order by c.id limit 1);
update linked_start set run_id=(api.run_start('23000000-0000-0000-0000-000000000002',array[first_child],(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'noncounted-house-actual-start','noncounted-house-actual-start')->>'runId')::uuid;
update linked_start l set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=l.run_id;
select isnt((select portal_id from app_private.run_stops where id=(select stop_id from linked_start)),'12000000-0000-0000-0000-000000000001'::uuid,'opted-out start house is not reintroduced as a normal destination');
select is((select count(*)::integer from app_private.run_participants where run_id=(select run_id from linked_start)and attendance='absent'),4,'the other four registered children remain explicitly absent');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from linked_start)),0,'neither the present nor absent children gain a seal merely by starting');
select *from finish();
rollback;
