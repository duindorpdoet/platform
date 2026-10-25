begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- Reproduce the production inventory: saved address positions, no usable graph.
-- Do not replace the production data with the fully connected seed graph.
create temp table original_edges as select id,approved_at from app_private.walking_edges;
create temp table original_nodes as select id,walking_node_id from app_private.start_points;
update app_private.walking_edges set approved_at=null;
update app_private.start_points set walking_node_id=null,verified_at=null,
  geocoded_latitude=52.09,geocoded_longitude=4.26,latitude=52.09,longitude=4.26,
  marker_latitude=null,marker_longitude=null,location_source='address',version=version+1
where id='20000000-0000-0000-0000-000000000001';
create temp table protected as
 select 'publications' kind,md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) hash from app_private.group_start_publications t
 union all select 'credentials',md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) from app_private.portal_credentials t
 union all select 'children',md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) from app_private.registration_children t;
create temp table state(snapshot jsonb, confirmation jsonb, save_result jsonb, version integer, unassigned integer, audit_count integer);
insert into state(version,unassigned) select version,(select count(*) from app_private.walking_groups where current_schedule_revision_id is null) from app_private.start_points where id='20000000-0000-0000-0000-000000000001';
grant select,update on state to authenticated;
set local role authenticated;
update state set confirmation=api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',version);
update state set snapshot=api.admin_startregie_snapshot('duindorp-halloween-2026');
select is((select confirmation->>'confirmed' from state),'true','saved official position can be confirmed without a manual override or graph');
select is((select p->>'confirmed' from state,jsonb_array_elements(snapshot->'startPoints') p where p->>'id'='20000000-0000-0000-0000-000000000001'),'true','fresh server snapshot retains the successful confirmation');
select ok(not exists(select 1 from state,jsonb_array_elements(snapshot->'warnings') w where w->>'resourceId'='20000000-0000-0000-0000-000000000001' and w->>'code'='MISSING_MARKER'),'saved address position is not reported as a missing marker');
select ok(not exists(select 1 from state,jsonb_array_elements(snapshot->'warnings') w where w->>'code'='WALKING_ROUTE_MISSING'),'no walking network is required for the house-sequence flow');
select is((select count(*)::integer from state,jsonb_array_elements(snapshot->'ops'->'groups') g where g->>'state'='unassigned'),(select unassigned from state),'point confirmation assigns no groups');
set local role postgres;
select ok(app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'saved confirmed destination is usable without inventing a street route');

update app_private.start_points set latitude=null,longitude=null,geocoded_latitude=null,geocoded_longitude=null,walking_node_id=null,version=version+1
where id='20000000-0000-0000-0000-000000000001';
update state set version=(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001');
set local role authenticated;
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'23514','START_POINT_POSITION_MISSING','missing saved position cannot return a false confirmation');
set local role postgres;
select is(app_private.routing_position(null,null,52.09,4.26,null,null)->>'source','address','official coordinates require no manual override flag');
select is(app_private.routing_position(52.1,null,52.09,4.26,null,null)->>'valid','false','an incomplete manual override never borrows half of the address');
select is(app_private.routing_position(null,null,null,null,52.09,4.26)->>'valid','true','historical complete address coordinates remain usable');
select is(app_private.routing_position('NaN',4.26,null,null,null,null)->>'valid','false','non-finite numeric values are rejected');
select is(app_private.routing_position(91,4.26,null,null,null,null)->>'valid','false','out-of-range latitude is rejected');
select is(app_private.routing_position(null,null,null,null,null,null)->>'reason','POSITION_MISSING','absence stays absent; no map-center fallback');
update app_private.start_points set latitude=52.09,longitude=4.26,geocoded_latitude=52.09,geocoded_longitude=4.26,version=version+1
where id='20000000-0000-0000-0000-000000000001';
update state set version=(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001');
set local role authenticated;
update state set save_result=api.admin_location_marker_save('duindorp-halloween-2026','start_point','20000000-0000-0000-0000-000000000001',52.091234,4.261234,'Gecontroleerde handmatige hofingang',false,version);
select is((select save_result->'location'->>'source' from state),'manual','write returns the actual manual source');
select is((select save_result->>'latitude' from state),'52.091234','write returns the stored latitude with its precision');
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'40001','STALE_VERSION','old editor cannot confirm a newer marker');
update state set version=(save_result->>'version')::integer;
select throws_ok($$select api.admin_location_marker_save('duindorp-halloween-2026','start_point','20000000-0000-0000-0000-000000000001',null,4.26,'Geen volledige positie opgeslagen',false,(select version from state))$$,'22023','INVALID_COORDINATE','null coordinate write is rejected rather than succeeding with zero rows');
select throws_ok($$select api.admin_location_marker_save('duindorp-halloween-2026','start_point','20000000-0000-0000-0000-000000000001',52.1,181,'Ongeldige positie wordt geweigerd',false,(select version from state))$$,'22023','INVALID_COORDINATE','invalid write cannot replace the saved manual pin');
select throws_ok($$select api.admin_location_marker_save('duindorp-halloween-2026','start_point','20000000-0000-0000-0000-000000000001',52.1,4.26,'Verouderde editor wordt geweigerd',false,(select version-1 from state))$$,'40001','STALE_VERSION','stale editor cannot replace the newer manual pin');
update state set confirmation=api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',version);
set local role postgres;
select is((select marker_latitude from app_private.start_points where id='20000000-0000-0000-0000-000000000001'),52.091234::numeric,'failed writes leave the existing marker intact');
select is((select geocoded_latitude from app_private.start_points where id='20000000-0000-0000-0000-000000000001'),52.09::numeric,'manual marker does not rewrite the official address');
update state set audit_count=(select count(*) from app_private.audit_events where resource_id='20000000-0000-0000-0000-000000000001' and action='start_point.confirmed');
set local role authenticated;
select lives_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'double confirmation at the same version is safe');
update state set snapshot=api.admin_startregie_snapshot('duindorp-halloween-2026');
select is((select p->'readiness'->'location'->>'longitude' from state,jsonb_array_elements(snapshot->'startPoints') p where p->>'id'='20000000-0000-0000-0000-000000000001'),'4.261234','fresh server projection reads the saved manual longitude');
select is((select p->'readiness'->>'confirmed' from state,jsonb_array_elements(snapshot->'startPoints') p where p->>'id'='20000000-0000-0000-0000-000000000001'),'true','manual confirmation remains visible after a fresh read');
select ok(not has_function_privilege('authenticated','app_private.start_point_readiness(uuid)','execute'),'private location helper is not a public cross-event lookup');
set local role postgres;
select is((select count(*)::integer from app_private.audit_events where resource_id='20000000-0000-0000-0000-000000000001' and action='start_point.confirmed'),(select audit_count from state),'idempotent confirmation creates no duplicate confirmation history');
-- Official-address maintenance must not change the effective manual marker or
-- its organizational confirmation. No physical inspection is manufactured.
update app_private.start_points set geocoded_latitude=52.092,geocoded_longitude=4.262,version=version+1 where id='20000000-0000-0000-0000-000000000001';
select is(app_private.start_point_location('20000000-0000-0000-0000-000000000001')->>'latitude','52.091234','background address update retains effective manual position');
select ok(app_private.start_point_confirmation('20000000-0000-0000-0000-000000000001') is not null,'unrelated address geocode does not erase manual position confirmation');
-- Exercise the other real write boundary: routine portal/address editing must
-- retain an existing manual marker and the matching walking-node position.
create temp table portal_case(id uuid,version integer,world_slug text);
grant select,update on portal_case to authenticated;
insert into portal_case select null,null,slug from app_private.worlds order by sort_order limit 1;
set local role authenticated;
update portal_case set (id,version)=(select (r->>'id')::uuid,(r->>'version')::integer from
 (select api.admin_manual_portal_save('duindorp-halloween-2026',null,jsonb_build_object('name','Synthetische markerbehoudpoort','worldSlug',world_slug,'latitude',52.09,'longitude',4.26),null,'Synthetische poort voor markerbehoud') r) c);
update portal_case set version=(api.admin_location_marker_save('duindorp-halloween-2026','portal',id,52.091111,4.261111,'Expliciet gecontroleerde handmatige poortingang',false,version)->>'version')::integer;
select lives_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',id,jsonb_build_object('name','Synthetische markerbehoudpoort','worldSlug',world_slug,'latitude',52.092222,'longitude',4.262222),version,'Adres bijwerken behoudt de handmatige routingpositie') from portal_case$$,'real portal edit preserves explicit manual position');
set local role postgres;
select is((select marker_latitude from app_private.portal_private_locations where portal_id=(select id from portal_case)),52.091111::numeric,'portal address edit cannot overwrite the manual marker');
select is((select coordinate[1]::numeric from app_private.walking_nodes where portal_id=(select id from portal_case)),52.091111::numeric,'portal address edit cannot move the graph away from the manual marker');
-- A genuinely required first house is validated by ID, independently of names.
update app_private.start_points set point_type='portal',linked_portal_id='12000000-0000-0000-0000-000000000003',counts_as_first_portal_visit=true,version=version+1 where id='20000000-0000-0000-0000-000000000001';
update app_private.portal_private_locations set latitude=null,longitude=null,geocoded_latitude=null,geocoded_longitude=null,marker_latitude=null,marker_longitude=null where portal_id='12000000-0000-0000-0000-000000000003';
update state set version=(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001');
set local role authenticated;
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'23514','LINKED_START_PORTAL_POSITION_INVALID','required first-house position gives a targeted failure');
set local role postgres;
update app_private.start_points set point_type='gathering',linked_portal_id=null,counts_as_first_portal_visit=false,version=version+1 where id='20000000-0000-0000-0000-000000000001';
update state set version=(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001');
set local role authenticated;
select lives_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'unrelated invalid house cannot block a valid start location');
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','99999999-0000-0000-0000-000000000001',1)$$,'P0002','START_POINT_NOT_FOUND','wrong record identity is rejected');
select throws_ok($$select api.admin_startregie_confirm_point('wrong-event','20000000-0000-0000-0000-000000000001',(select version from state))$$,'42501','NOT_AUTHORIZED','wrong event is rejected');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_location_marker_save('duindorp-halloween-2026','start_point','20000000-0000-0000-0000-000000000001',52.09,4.26,'Onbevoegde aanpassing wordt geweigerd',false,(select version from state))$$,'42501','NOT_AUTHORIZED','participant cannot mutate the marker');
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from state))$$,'42501','NOT_AUTHORIZED','participant cannot confirm a start location');
set local role postgres;
update app_private.walking_edges e set approved_at=o.approved_at from original_edges o where o.id=e.id;
update app_private.start_points p set walking_node_id=o.walking_node_id from original_nodes o where o.id=p.id;
select ok(app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'valid own graph remains usable when an unrelated portal has no position');
update app_private.start_points set point_type='portal',linked_portal_id='12000000-0000-0000-0000-000000000003',counts_as_first_portal_visit=true where id='20000000-0000-0000-0000-000000000001';
select ok(not app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'required invalid first-house position blocks planning even when own position and graph are valid');
select is((select md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) from app_private.group_start_publications t),(select hash from protected where kind='publications'),'location repair preserves all existing published starts');
select is((select md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) from app_private.portal_credentials t),(select hash from protected where kind='credentials'),'location repair preserves QR credentials');
select is((select md5(coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb)::text) from app_private.registration_children t),(select hash from protected where kind='children'),'location repair preserves children and group membership');
select * from finish();
rollback;
