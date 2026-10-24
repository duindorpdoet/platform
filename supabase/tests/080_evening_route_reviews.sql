begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table ops_values(eid uuid,event_version integer,first_schedule uuid,first_revision integer,first_group_version integer,first_key text default gen_random_uuid()::text,publication_count integer,route jsonb,latest jsonb,review jsonb,published jsonb);
insert into ops_values(eid,event_version,first_group_version,publication_count)
select e.id,e.settings_version,g.version,(select count(*) from app_private.group_start_publications)
  from app_private.events e join app_private.walking_groups g on g.event_id=e.id and g.id='23000000-0000-0000-0000-000000000001'
  where e.slug='duindorp-halloween-2026';
grant select,update on ops_values to authenticated;
update app_private.event_route_settings set first_start_at='2026-10-31T15:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',
  finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',
  finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic'
where event_id=(select eid from ops_values);
update app_private.walking_groups set desired_ordinary_visits=3 where id='23000000-0000-0000-0000-000000000001';
create temp table protected_ops_rows as select 'registration' kind,md5(jsonb_agg(to_jsonb(r) order by r.id)::text) fingerprint
  from app_private.registration_children r union all select 'credentials',md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.portal_credentials r
  union all select 'seals',md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text),'[]'::jsonb)::text) from app_private.poortenboek_passport_seals r;

select ok(not has_function_privilege('authenticated','app_private.published_start_projection(uuid,timestamptz)','execute'),'participants cannot supply their own release clock');
select ok(not has_table_privilege('authenticated','app_private.group_start_publications','select'),'published private snapshots are not directly readable');
select ok(app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'an active start with existing route data needs no physical-inspection form');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,false,'')$$,'legacy tabs can confirm without an inspection checkbox or approach');
select lives_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1)$$,'one confirmation records the organizational choice');
select lives_ok($$select api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,true,'Gecontroleerde fictieve aanloop via de stoep en het zebrapad')$$,'explicit verification succeeds at a real approved fixture node');
select lives_ok($$update ops_values set first_schedule=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-31T16:30:00Z',(select first_group_version from ops_values),'neutral','Nieuwe fictieve vertrekafspraak als concept')->>'id')::uuid$$,'a working start assignment is saved through the real command');
set local role postgres;
update ops_values set first_revision=s.revision from app_private.group_schedule_revisions s where s.id=first_schedule;
select is((select route_mode from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'legacy','saving a correction does not switch the previously published dispatch mode');
select is((select count(*)::integer from app_private.group_start_publications),(select publication_count from ops_values),'saving a concept creates no participant publication');
select is((select confirmed_at from app_private.group_schedule_revisions where id=(select first_schedule from ops_values)),null::timestamptz,'saving does not implicitly confirm');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,start,startsAt}','2026-10-31T17:30:00+00:00','the previously published time remains active during a new concept');
select ok(api.group_snapshot('23000000-0000-0000-0000-000000000001')::text not like '%NIET-BESTAAND TESTADRES%','parent response contains no early start address');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',999,(select event_version from ops_values))$$,'40001','STALE_REVISION','a stale confirmation cannot confirm a replacement revision');
select lives_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(select first_revision from ops_values),(select event_version from ops_values))$$,'the actual current revision can be explicitly confirmed');
select is(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,routes}','{}'::jsonb,'initial Startregie snapshot does not eagerly calculate every group route');
update ops_values set route=api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001');
select ok((select route->>'fingerprint' ~ '^[0-9a-f]{64}$' from ops_values),'actual route has a server SHA-256 fingerprint');
select ok((select (route->>'feasible')::boolean from ops_values),'configured confirmed draft has a feasible real route');
select is((select api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'fingerprint' from ops_values),(select route->>'fingerprint' from ops_values),'repeated unchanged preparation retains the same fingerprint');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','participant cannot enumerate private future route addresses');
select throws_ok($$select api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(select (route->>'revision')::integer from ops_values),(select route->>'fingerprint' from ops_values))$$,'42501','NOT_AUTHORIZED','participant cannot record an organizer route review');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',0,(select route->>'fingerprint' from ops_values))$$,'40001','STALE_ROUTE','review requires the displayed actual route revision');
update ops_values set review=api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(route->>'revision')::integer,route->>'fingerprint');
select is((select api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(route->>'revision')::integer,route->>'fingerprint') from ops_values),(select review from ops_values),'same actor and displayed route review is idempotent');
select ok((api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')#>>'{review,isCurrent}')::boolean,'review persists in a later actual server response');
set local role postgres;
select is((select actor_id from app_private.evening_route_reviews limit 1),'f0000000-0000-0000-0000-000000000001'::uuid,'private review stores the authenticated organizer identity');
select is((select count(*)::integer from app_private.evening_route_reviews),1,'retry does not duplicate immutable review evidence');
select throws_ok($$update app_private.evening_route_reviews set actor_label='vervalst'$$,'55000','ROUTE_EVIDENCE_IMMUTABLE','recorded review cannot be edited');
select throws_ok($$delete from app_private.evening_route_calculations$$,'55000','ROUTE_EVIDENCE_IMMUTABLE','recorded input and result snapshots cannot be removed');
select ok((select fingerprint=encode(extensions.digest(convert_to(jsonb_build_object('input',input_snapshot,'result',canonical_result)::text,'UTF8'),'sha256'),'hex') from app_private.evening_route_calculations limit 1),'fingerprint is actually computed from canonical input and result snapshots');
update app_private.portals set operation_status='closed' where id=(select (p->>'portalId')::uuid from ops_values t cross join lateral jsonb_array_elements(t.route->'stops') p where p->>'kind'='ordinary' order by (p->>'sequence')::integer desc limit 1);
set local role authenticated;
update ops_values set latest=api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001');
select isnt((select latest->>'fingerprint' from ops_values),(select route->>'fingerprint' from ops_values),'changed physical availability invalidates the old fingerprint');
select ok(not (select (latest#>>'{review,isCurrent}')::boolean from ops_values),'old review is retained and shown as no longer current');
select ok((select jsonb_array_length(latest#>'{diff,removed}')>0 from ops_values),'changed preview gives a real removed-house diff');
select throws_ok($$select api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(select (latest->>'revision')::integer from ops_values),(select route->>'fingerprint' from ops_values))$$,'40001','STALE_ROUTE','old hash cannot be reviewed against a new result');
select throws_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',(select first_revision from ops_values))),(select event_version from ops_values),'reviews-no-fingerprint')$$,'40001','EXPECTED_ROUTE_FINGERPRINT_REQUIRED','old client publication cannot create a new release without fingerprints');
select throws_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',(select first_revision from ops_values))),(select event_version from ops_values),'reviews-stale-fingerprint',jsonb_build_array(jsonb_build_object('groupId','23000000-0000-0000-0000-000000000001','fingerprint',(select route->>'fingerprint' from ops_values))))$$,'40001','STALE_ROUTE','publication cannot silently calculate a new route in place of the reviewed choice');
set local role postgres;
create temp table blocked_finale_edge as select edge.id,edge.closed_at from app_private.walking_edges edge join app_private.walking_nodes n on n.id=edge.to_node_id or n.id=edge.from_node_id where n.portal_id='12000000-0000-0000-0000-000000000030' limit 1;
update app_private.walking_edges set closed_at=clock_timestamp() where id=(select id from blocked_finale_edge);
set local role authenticated;
select ok(not (api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'feasible')::boolean,'broken finale connection produces a real hard route blocker');
select lives_ok($$select api.admin_startregie_review_route('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'revision')::integer,api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'fingerprint')$$,'organizer can record having seen a blocked route without making it feasible');
select throws_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',(select first_revision from ops_values))),(select event_version from ops_values),'reviews-blocked-publish',jsonb_build_array(jsonb_build_object('groupId','23000000-0000-0000-0000-000000000001','fingerprint',api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'fingerprint')))$$,'23514','ROUTE_NOT_FEASIBLE','marking a route reviewed does not bypass hard route feasibility');
set local role postgres;
update app_private.walking_edges edge set closed_at=old.closed_at from blocked_finale_edge old where edge.id=old.id;
set local role authenticated;
update ops_values set published=api.admin_startregie_publish_times('duindorp-halloween-2026',array[first_schedule],jsonb_build_array(jsonb_build_object('id',first_schedule,'revision',first_revision)),event_version,'reviews-actual-publish',jsonb_build_array(jsonb_build_object('groupId','23000000-0000-0000-0000-000000000001','fingerprint',latest->>'fingerprint')));
select ok((select published->>'published'='1' from ops_values),'feasible current route publishes even when its new version was not manually marked reviewed');
select is(api.admin_startregie_route_preview('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001')->>'fingerprint',(select latest->>'fingerprint' from ops_values),'publishing unchanged semantic start and finale does not immediately invalidate its route fingerprint');
select is((select api.admin_startregie_publish_times('duindorp-halloween-2026',array[first_schedule],jsonb_build_array(jsonb_build_object('id',first_schedule,'revision',first_revision)),event_version,'reviews-actual-publish',jsonb_build_array(jsonb_build_object('groupId','23000000-0000-0000-0000-000000000001','fingerprint',latest->>'fingerprint'))) from ops_values),(select published from ops_values),'publication retry with the original fingerprint returns the committed result');
set local role postgres;
select is((select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.registration_children r),(select fingerprint from protected_ops_rows where kind='registration'),'reviews and publication preserve original child IDs and membership relations');
select is((select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.portal_credentials r),(select fingerprint from protected_ops_rows where kind='credentials'),'route checks and publication do not rotate QR credentials');
select ok(not has_table_privilege('authenticated','app_private.evening_route_calculations','select'),'private canonical inputs are inaccessible to participants');
select ok(not has_table_privilege('authenticated','app_private.evening_route_reviews','select'),'private reviews are exposed only through scoped organizer RPCs');
select * from finish();
rollback;
