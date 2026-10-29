begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/ready_live_planboard.inc
\ir fixtures/legacy-start-available.inc
create temp table entrance_case(gid uuid,portal uuid,children uuid[],key uuid default gen_random_uuid(),new_key uuid default gen_random_uuid(),version integer,run uuid,leader jsonb,parent jsonb,publication_hash text);
insert into entrance_case(gid,portal) values('23000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001');
grant select,update on entrance_case to authenticated;
-- Preserve official address A, but point to the actual entrance B. No participant data.
update app_private.portal_private_locations set latitude=52.09,longitude=4.26,geocoded_latitude=52.09,geocoded_longitude=4.26,
 marker_latitude=52.091234,marker_longitude=4.261234,location_source='manual',marker_reason='INTERNAL-AUDIT-REASON-NEVER-PUBLIC'
 where portal_id=(select portal from entrance_case);
update app_private.portal_applications set private_draft_data=private_draft_data||'{"entrance":"Ingang via het hof achter het huis; volg het steegje links.","contactName":"PRIVATE-CONTACT-NEVER-PUBLIC"}'::jsonb where id=(select application_id from app_private.portals where id=(select portal from entrance_case));
update app_private.portals set public_entrance_instructions='FUTURE-ENTRANCE-NEVER-PUBLIC' where id='12000000-0000-0000-0000-000000000002';
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
select p.event_id,p.group_id,'fixture-entrance-available',p.revision,p.starts_at,clock_timestamp(),p.point_snapshot||jsonb_build_object(
 'private_address','FICTIEF OFFICIEEL STARTADRES A, 0000AA Teststad','latitude',52.09,'longitude',4.26,'geocoded_latitude',52.09,'geocoded_longitude',4.26,
 'marker_latitude',52.091111,'marker_longitude',4.261111,'public_arrival_instructions','START VIA HOF B','marker_reason','PRIVATE START AUDIT'),p.slot_snapshot
from app_private.current_start_publication((select gid from entrance_case)) p;
select is(app_private.published_start_projection((select gid from entrance_case),(select starts_at-interval '61 minutes' from app_private.current_start_publication((select gid from entrance_case))))->>'coordinate',null::text,'start pin remains hidden before T-60');
select is(app_private.published_start_projection((select gid from entrance_case),(select starts_at-interval '61 minutes' from app_private.current_start_publication((select gid from entrance_case))))->>'arrivalInstructions',null::text,'start entrance instructions remain hidden before release');
select is(app_private.published_start_projection((select gid from entrance_case),(select starts_at-interval '60 minutes' from app_private.current_start_publication((select gid from entrance_case))))->'coordinate','[4.261111,52.091111]'::jsonb,'released start uses exact frozen manual entrance B in GeoJSON order');
select is(app_private.routing_coordinate(app_private.routing_position(52.1,null,52.09,4.26,null,null)),'null'::jsonb,'incomplete override produces no mixed or fictitious pin');
select is(app_private.routing_coordinate(app_private.routing_position(91,4.26,52.09,4.26,null,null)),'null'::jsonb,'invalid override stays explicitly unusable');
select is(app_private.routing_coordinate(app_private.routing_position(null,null,52.09,4.26,null,null)),'[4.26,52.09]'::jsonb,'complete address pair remains a valid fallback when no manual override exists');
-- Actual private planned sequence uses the same effective pairs; a route estimate is not a street router.
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.start_points set marker_latitude=52.091111,marker_longitude=4.261111,location_source='manual',marker_reason='Synthetische handmatige startingang',version=version+1 where id='20000000-0000-0000-0000-000000000001';
update app_private.portal_windows set opens_at='2026-10-31T14:00Z',closes_at='2026-10-31T22:00Z';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00Z',global_ordinary_stop_at='2026-10-31T19:30Z',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00Z',finale_last_arrival_at='2026-10-31T20:30Z',finale_closes_at='2026-10-31T21:00Z',
 finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic';
select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001'));
select app_private.withdraw_group_appointment('23000000-0000-0000-0000-000000000002','Synthetische seedstart bewust vervangen door ingang B');
update app_private.start_points set counts_as_first_portal_visit=true where id='20000000-0000-0000-0000-000000000001';
update app_private.walking_groups set desired_ordinary_visits=2 where id='23000000-0000-0000-0000-000000000002';
select api.admin_startregie_move_group('23000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','2026-10-31T16:30Z',
 (select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002'),'neutral','Synthetische planning met handmatige ingang');
select pg_temp.ready_live_planboard('duindorp-halloween-2026');
select is(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')#>'{start,coordinate}','[4.261111,52.091111]'::jsonb,'actual explicitly reviewed sequence starts from stored manual entrance B');
select ok(exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')->'stops') stop where stop->>'portalId'=(select portal::text from entrance_case) and stop->'coordinate'='[4.261234,52.091234]'::jsonb),'actual route preview uses house entrance B while retaining address A');
select ok(not exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')->'stops') stop where stop->'coordinate' is distinct from app_private.routing_coordinate(app_private.portal_location((stop->>'portalId')::uuid))),'every planned stop including finale uses the canonical validated pair');

select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000002',(select s.revision from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id where g.id='23000000-0000-0000-0000-000000000002'),(select settings_version from app_private.events where slug='duindorp-halloween-2026'));
select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select current_schedule_revision_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002')],
 (select jsonb_build_array(jsonb_build_object('id',g.current_schedule_revision_id,'revision',s.revision)) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id where g.id='23000000-0000-0000-0000-000000000002'),
 (select settings_version from app_private.events where slug='duindorp-halloween-2026'),'marker-frozen-start-publication');
update app_private.start_points set marker_latitude=52.092222,marker_longitude=4.262222,version=version+1 where id='20000000-0000-0000-0000-000000000001';
select is(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')#>'{start,coordinate}','[4.261111,52.091111]'::jsonb,'published start remains frozen at entrance B after the current point is edited to C');
insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at)
 select '23000000-0000-0000-0000-000000000002',p.schedule_id,'live',statement_timestamp() from app_private.current_start_publication('23000000-0000-0000-0000-000000000002') p;
select is(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')#>'{start,coordinate}','[4.261111,52.091111]'::jsonb,'begun run preview retains frozen published entrance B independently of current draft C');
insert into app_private.group_runs(group_id,active_plan_version_id,status,started_at,finished_at,created_at)
 select id,current_plan_version_id,'completed',statement_timestamp()-interval '1 hour',statement_timestamp(),statement_timestamp()+interval '1 minute'
 from app_private.walking_groups where id='23000000-0000-0000-0000-000000000002';
select is(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000002')#>'{start,coordinate}','[4.261111,52.091111]'::jsonb,'newer completed history cannot replace the older live run frozen entrance B with current draft C');

select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000002','2026-10-31T16:30Z')->'coordinate','[4.261111,52.091111]'::jsonb,'parent start and published preview retain the same frozen destination');

update entrance_case set publication_hash=(select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p);
update entrance_case c set children=(select array_agg(rc.id) from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id=c.gid and a.superseded_at is null);
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update entrance_case set run=(api.run_start(gid,children,1,'marker-start','marker-start')->>'runId')::uuid;
update entrance_case set leader=api.group_snapshot(gid);
select is((select leader#>'{run,currentStop,portal,coordinate}' from entrance_case),'[4.261234,52.091234]'::jsonb,'leader current destination uses manual entrance B instead of official address A');
select is((select leader#>>'{run,currentStop,portal,address}' from entrance_case),'NIET-BESTAAND TESTADRES 1','official address text stays A');
select is((select leader#>>'{run,currentStop,portal,publicEntranceInstructions}' from entrance_case),'Ingang via het hof achter het huis; volg het steegje links.','approved existing entrance instruction is reused');
select ok((select position('INTERNAL-AUDIT-REASON' in leader::text)=0 and position('PRIVATE-CONTACT' in leader::text)=0 and position('FUTURE-ENTRANCE' in leader::text)=0 and position('PRIVATE START AUDIT' in leader::text)=0 from entrance_case),'payload contains no internal marker reason, contacts or future entrance');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update entrance_case set parent=api.group_snapshot(gid);
select is((select parent#>'{run,currentStop,portal}' from entrance_case),(select leader#>'{run,currentStop,portal}' from entrance_case),'ordinary parent and leader receive the same released destination');
select is((select parent#>>'{group,start,arrivalInstructions}' from entrance_case),'START VIA HOF B','ordinary parent sees the released start entrance too');
select throws_ok($$select api.portal_room_update(portal,'details',jsonb_build_object('name','Verboden wijziging','description','','version',1,'publicEntranceInstructions','Geen rechten'),key) from entrance_case$$,'42501','NOT_AUTHORIZED','ordinary parent cannot change public portal entrance');
set local role postgres;
update app_private.portal_private_locations set marker_latitude=null,marker_longitude=null where portal_id=(select portal from entrance_case);
select is(api.group_snapshot((select gid from entrance_case))#>'{run,currentStop,portal,coordinate}','[4.26,52.09]'::jsonb,'released snapshot switches to the complete address pair when the override is removed');
update app_private.portal_private_locations set marker_latitude=91,marker_longitude=4.261234 where portal_id=(select portal from entrance_case);
select is(api.group_snapshot((select gid from entrance_case))#>'{run,currentStop,portal,coordinate}','null'::jsonb,'invalid saved manual pin leaves usable text but no invented address or centre pin');
select is(api.group_snapshot((select gid from entrance_case))#>>'{run,currentStop,portal,address}','NIET-BESTAAND TESTADRES 1','invalid pin retains the official text destination');
update app_private.portal_private_locations set marker_latitude=52.091234,marker_longitude=4.261234 where portal_id=(select portal from entrance_case);
update entrance_case set version=(select version from app_private.portals where id=portal);
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.portal_room_update(portal,'details',jsonb_build_object('name','Testpoort 01','description','Fictieve poort','version',version,'publicEntranceInstructions','Nieuwe publieksingang via het hof'),key) from entrance_case$$,'authorized portal owner can edit the public entrance in existing details command');
select is(api.portal_room_snapshot('duindorp-halloween-2026',(select portal from entrance_case))#>>'{portal,publicEntranceInstructions}','Nieuwe publieksingang via het hof','Poortkamer re-reads the stored public instruction');
select throws_ok($$select api.portal_room_update(portal,'details',jsonb_build_object('name','Testpoort 01','description','Fictieve poort','version',version,'publicEntranceInstructions',repeat('x',501)),new_key) from entrance_case$$,'40001','STALE_VERSION','old portal editor cannot overwrite a newer entrance');
select throws_ok($$select api.portal_room_update(portal,'details',jsonb_build_object('name','Testpoort 01','description','Fictieve poort','version',version+1,'publicEntranceInstructions',repeat('x',501)),new_key) from entrance_case$$,'P0001','INVALID_DETAILS','public entrance length is enforced by direct RPC');
select lives_ok($$select api.portal_room_update(portal,'details',jsonb_build_object('name','Testpoort 01','description','Fictieve poort','version',version,'publicEntranceInstructions','Nieuwe publieksingang via het hof'),key) from entrance_case$$,'same details receipt is safe to replay');
set local role postgres;
select is((select version from app_private.portals where id=(select portal from entrance_case)),(select version+1 from entrance_case),'repeated save does not increment twice');
select is((select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p),(select publication_hash from entrance_case),'editing public text does not rewrite any publication');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.admin_location_marker_save('duindorp-halloween-2026','portal',portal,52.092222,4.262222,'Andere ingang voor al lopende groep',false,version+1) from entrance_case$$,'23514','RESOLVE_ACTIVE_VISITS_FIRST','moving an already released active destination requires handling the actual visit first');
set local role postgres;
select is(app_private.portal_location((select portal from entrance_case))->>'latitude','52.091234','rejected active change preserves actual destination B');
-- General address maintenance cannot bypass the same active-destination guard.
update app_private.portal_private_locations set marker_latitude=null,marker_longitude=null where portal_id=(select portal from entrance_case);
select throws_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',portal,'{"latitude":52.092222,"longitude":4.262222}'::jsonb,version+1,'Adrespositie verplaatsen tijdens lopend bezoek') from entrance_case$$,'23514','RESOLVE_ACTIVE_VISITS_FIRST','general portal editor cannot redirect an active address-source destination');
select is(app_private.portal_location((select portal from entrance_case))->>'latitude','52.090000','rejected general edit preserves original address pair');

select ok(not has_function_privilege('authenticated','app_private.portal_public_entrance(uuid)','execute'),'public entrance helper cannot enumerate hidden portal instructions');
select ok(not has_function_privilege('authenticated','api.group_snapshot_before_destination(uuid)','execute'),'previous snapshot remains inaccessible to direct clients');
select * from finish();
rollback;
