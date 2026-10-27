begin;
create extension if not exists pgtap with schema extensions;
\ir fixtures/evening-route-publication.inc
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table choice(pid uuid,point_id uuid,schedule_id uuid,publication jsonb);
insert into choice(pid) values('12000000-0000-0000-0000-000000000006');
update app_private.portal_private_locations set latitude=52.120000,longitude=4.290000,geocoded_latitude=52.120000,geocoded_longitude=4.290000 where portal_id=(select pid from choice);
update app_private.portal_windows set max_children_per_visit=100,opens_at='2026-10-31T16:00:00Z',closes_at='2026-10-31T20:30:00Z' where portal_id=(select pid from choice);
select ok(not exists(select 1 from app_private.start_points where linked_portal_id=(select pid from choice)),'portal initially has no start-point record');
update choice set point_id=(api.admin_portal_start_point_set(pid,true,(select version from app_private.portals where id=pid))->>'startPointId')::uuid;
select ok((select active from app_private.start_points where id=(select point_id from choice)),'yes enables a real linked start point');
select ok(app_private.start_point_safe_connection((select point_id from choice)),'portal selection needs no inspection, approach or 75m confirmation');
select is((select walking_connection_verified_at from app_private.start_points where id=(select point_id from choice)),null::timestamptz,'selection does not fabricate a physical walking inspection');
select is((select safe_approach from app_private.start_points where id=(select point_id from choice)),null::text,'approach text is optional for a selected portal');
select is((select item->>'candidateStartPoint' from jsonb_array_elements(api.admin_portal_editor_snapshot('duindorp-halloween-2026')->'portals') item where item->>'id'=(select pid::text from choice)),'true','portal manager shows yes after enable');
select lives_ok($$select api.admin_portal_start_point_set(pid,true,(select version from app_private.portals where id=pid)) from choice$$,'repeated yes reuses the existing linked record');
select is((select count(*)::integer from app_private.start_points where linked_portal_id=(select pid from choice)),1,'repeated yes does not create duplicate start points');
update app_private.event_route_settings set first_start_at='2026-10-31T15:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',
  finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',
  finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic';
select lives_ok($$update choice set schedule_id=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001',point_id,'2026-10-31T16:30:00Z',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'neutral','Start toewijzen met alleen de ja-keuze bij de poort')->>'id')::uuid$$,'yes immediately makes the portal usable for a real group assignment');
select lives_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,(select settings_version from app_private.events where slug='duindorp-halloween-2026'))$$,'selected portal can be confirmed without an inspection command');
select lives_ok($$select pg_temp.publish_fingerprinted('duindorp-halloween-2026',array[(select schedule_id from choice)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from choice),'revision',1)),(select settings_version from app_private.events where slug='duindorp-halloween-2026'),gen_random_uuid()::text)$$,'the selected portal can be published normally');
update choice set publication=(select to_jsonb(p) from app_private.group_start_publications p where group_id='23000000-0000-0000-0000-000000000001' order by publication_order desc limit 1);
select lives_ok($$select api.admin_portal_start_point_set(pid,false,(select version from app_private.portals where id=pid)) from choice$$,'no disables future starts even when a published appointment exists');
select ok(not (select active from app_private.start_points where id=(select point_id from choice)),'no removes the point from new-start availability');
select is((select to_jsonb(p) from app_private.group_start_publications p where group_id='23000000-0000-0000-0000-000000000001' order by publication_order desc limit 1),(select publication from choice),'existing published appointment stays exactly intact');
select throws_ok($$select api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002',(select point_id from choice),'2026-10-31T16:30:00Z',(select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'neutral','Geen nieuwe start indelen na uitschakelen')$$,'23514','START_POINT_NOT_AVAILABLE','no prevents new group assignments');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_portal_start_point_set(pid,true,(select version from app_private.portals where id=pid)) from choice$$,'42501','NOT_AUTHORIZED','participant cannot change organization start selection');
select * from finish();
rollback;
