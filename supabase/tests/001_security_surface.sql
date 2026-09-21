begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

select ok(not has_schema_privilege('anon', 'app_private', 'usage'), 'anon cannot use private schema');
select ok(has_schema_privilege('authenticated', 'app_private', 'usage'), 'authenticated can resolve narrowly granted storage and realtime helpers');
select ok(not has_table_privilege('authenticated', 'app_private.registrations', 'select'), 'browser cannot select registrations directly');
select ok(not has_table_privilege('authenticated', 'app_private.route_plan_stops', 'select'), 'browser cannot select route stops directly');
select ok(not has_table_privilege('authenticated', 'app_private.route_plan_stops', 'insert'), 'browser cannot mutate route stops directly');
select ok(has_function_privilege('anon', 'api.event_public_snapshot(text)', 'execute'), 'public snapshot is callable anonymously');
select ok(not has_function_privilege('anon', 'api.group_snapshot(uuid)', 'execute'), 'group snapshot is not anonymous');
select ok(has_function_privilege('authenticated', 'api.group_snapshot(uuid)', 'execute'), 'authenticated role can invoke protected snapshot');
select ok(not has_function_privilege('authenticated', 'api.worker_claim_outbox(integer,integer)', 'execute'), 'mail worker is unavailable to browsers');
select ok(has_function_privilege('service_role', 'api.worker_claim_outbox(integer,integer)', 'execute'), 'mail worker is available to service role');
select is((select phase::text from app_private.events where slug = 'duindorp-halloween-2026'), 'registration_open', 'local seed opens registration only for tests');
select is((select count(*)::integer from app_private.portals), 30, 'local fixtures provide thirty test portals');
select is((select count(*)::integer from storage.buckets where public), 0, 'all configured storage buckets are private');
select is((select count(*)::integer from pg_tables where schemaname = 'app_private' and not rowsecurity), 0, 'RLS is enabled on every private table');

select * from finish();
rollback;
