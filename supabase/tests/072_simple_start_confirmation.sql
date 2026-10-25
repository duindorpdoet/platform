begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table originals as select 'publications' kind,md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]'::jsonb)::text) hash from app_private.group_start_publications p
 union all select 'credentials',md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c
 union all select 'children',md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c;
-- Existing manually configured start: no linked portal, approach or inspection.
update app_private.start_points set safe_approach=null,walking_node_id=null,
 walking_connection_verified_at=null,walking_connection_verified_by=null,
 marker_latitude=52.12,marker_longitude=4.29,version=version+1 where id='20000000-0000-0000-0000-000000000001';
create temp table point_version as select version before from app_private.start_points where id='20000000-0000-0000-0000-000000000001';
grant select on point_version to authenticated;
set local role authenticated;
select lives_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select before from point_version))$$,'existing start is confirmed with only its ID and expected version');
select lives_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select before from point_version))$$,'repeating the same unchanged confirmation is idempotent');
set local role postgres;
update app_private.start_points set marker_longitude=4.290001,version=version+1 where id='20000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select before from point_version))$$,'40001','STALE_VERSION','a genuinely stale editor cannot confirm a newer marker');
select throws_ok($$select api.admin_startregie_confirm_point('unknown-event','20000000-0000-0000-0000-000000000001',1)$$,'42501','NOT_AUTHORIZED','a different event cannot confirm this point');
set local role postgres;
select ok(app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'valid stored destination needs no graph or 75m form');
select is((select safe_approach from app_private.start_points where id='20000000-0000-0000-0000-000000000001'),null::text,'confirmation requires and invents no approach text');
select is((select walking_connection_verified_at from app_private.start_points where id='20000000-0000-0000-0000-000000000001'),null::timestamptz,'organizational confirmation is not stored as physical inspection');
select ok(exists(select 1 from app_private.audit_events where resource_id='20000000-0000-0000-0000-000000000001' and action='start_point.confirmed' and actor_id=auth.uid()),'organizational confirmation has an actual actor and audit record');
select is((select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]'::jsonb)::text) from app_private.group_start_publications p),(select hash from originals where kind='publications'),'existing published appointments remain exactly intact');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c),(select hash from originals where kind='credentials'),'QR codes are unchanged');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),(select hash from originals where kind='children'),'children and registration relations are unchanged');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1)$$,'42501','NOT_AUTHORIZED','participant cannot confirm organizational start points');
select ok(not has_function_privilege('anon','api.admin_startregie_confirm_point(text,uuid,integer)','execute'),'anonymous caller cannot execute confirmation');
select * from finish();
rollback;
