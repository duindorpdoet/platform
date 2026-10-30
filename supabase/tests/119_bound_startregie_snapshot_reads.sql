begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select is((select cardinality(string_to_array(prosrc,'app_private.joint_route_source_hash('))-1
 from pg_proc where oid='app_private.admin_startregie_snapshot_before_publication_readiness(text)'::regprocedure),1,
 'snapshot performs one event-wide source calculation, independent of group count');
select is((select cardinality(string_to_array(prosrc,'app_private.start_ops_route_revision(e.id)'))-1
 from pg_proc where oid='app_private.admin_startregie_snapshot_before_publication_readiness(text)'::regprocedure),0,
 'group projection does not repeat the event-wide route revision calculation');
select is((select cardinality(string_to_array(prosrc,'app_private.start_schedule_reservations(_event_id)'))-1
 from pg_proc where oid='app_private.assert_start_schedule_capacity_readonly(uuid,uuid[])'::regprocedure),1,
 'publication preflight materializes departure reservations once for all selected groups');



select ok(not has_function_privilege('anon',
 'app_private.start_ops_route_preview_with_context(uuid,text,integer,jsonb)','EXECUTE'),
 'anonymous users cannot call the context-aware private route reader');
select ok(not has_function_privilege('authenticated',
 'app_private.start_ops_route_preview_with_context(uuid,text,integer,jsonb)','EXECUTE'),
 'authenticated users cannot supply a fabricated route source context');
select ok(not has_function_privilege('authenticated',
 'app_private.assert_group_schedule_timing_with_source(uuid,uuid,timestamptz,timestamptz,text)','EXECUTE'),
 'publication timing with a supplied source hash stays private');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table bounded_snapshot_fixture as
 select e.id event_id,
 (select count(*) from app_private.group_start_publications) publications,
 (select count(*) from app_private.group_runs) runs,
 (select count(*) from app_private.email_outbox) mails,
 api.admin_startregie_snapshot(e.slug) snapshot
 from app_private.events e where e.slug='duindorp-halloween-2026';

select is((snapshot#>>'{ops,routeRevision}')::integer,
 app_private.start_ops_route_revision(event_id),
 'the bounded snapshot exposes the same fresh route revision')
 from bounded_snapshot_fixture;
select ok(not exists(
 select 1 from jsonb_array_elements(snapshot#>'{ops,groups}') g
 where (g->>'routeRevision')::integer is distinct from (snapshot#>>'{ops,routeRevision}')::integer),
 'all group cards share the revision from this one snapshot')
 from bounded_snapshot_fixture;
select ok(not exists(
 select 1 from jsonb_each(snapshot#>'{ops,routes}') route
 where (route.value->>'revision')::integer is distinct from (snapshot#>>'{ops,routeRevision}')::integer),
 'all expected routes share the revision from this one snapshot')
 from bounded_snapshot_fixture;
select is(snapshot->'publicationReadiness',app_private.start_publication_readiness(event_id),
 'the snapshot retains the complete stored publication readiness')
 from bounded_snapshot_fixture;

-- A second statement after a write MUST compute a new source context even in
-- the same transaction: a transaction-local GUC cache would fail this check.
update app_private.event_route_settings set route_buffer_seconds=route_buffer_seconds+1
 where event_id=(select event_id from bounded_snapshot_fixture);
select isnt((api.admin_startregie_snapshot('duindorp-halloween-2026')#>>'{ops,routeRevision}')::integer,
 (snapshot#>>'{ops,routeRevision}')::integer,
 'a later read in the same transaction observes changed route inputs')
 from bounded_snapshot_fixture;
select is(jsonb_build_array((select count(*) from app_private.group_start_publications),
 (select count(*) from app_private.group_runs),(select count(*) from app_private.email_outbox)),
 jsonb_build_array(publications,runs,mails),
 'snapshot reads do not publish starts, start runs or enqueue participant messages')
 from bounded_snapshot_fixture;

select set_config('request.jwt.claims','{"role":"anon"}',true);
select throws_ok($$select api.admin_startregie_snapshot('duindorp-halloween-2026')$$,
 '42501','NOT_AUTHORIZED','the existing admin authorization remains mandatory');

select * from finish();
rollback;
