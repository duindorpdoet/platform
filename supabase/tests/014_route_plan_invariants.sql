begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

update app_private.group_registrations
set superseded_at = now()
where registration_id = '22000000-0000-0000-0000-000000000001' and superseded_at is null;
insert into app_private.walking_groups(id, event_id, code, status, start_slot_id)
select '23000000-0000-0000-0000-000000000050', event.id, 'TEST-VALIDATION', 'draft', '20000000-0000-0000-0000-000000000001'
from app_private.events event where event.slug = 'duindorp-halloween-2026';
insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
values ('23000000-0000-0000-0000-000000000050', '22000000-0000-0000-0000-000000000001', 2);
insert into app_private.route_plan_versions(id, group_id, revision, state, generated_by, input_hash)
values ('24000000-0000-0000-0000-000000000050', '23000000-0000-0000-0000-000000000050', 1, 'valid', 'f0000000-0000-0000-0000-000000000001', 'route-validation-fixture');
update app_private.walking_groups
set current_plan_version_id = '24000000-0000-0000-0000-000000000050'
where id = '23000000-0000-0000-0000-000000000050';

select is(
  app_private.has_approved_walking_path(
    (select id from app_private.events where slug = 'duindorp-halloween-2026'),
    '13000000-0000-0000-0000-000000000999',
    '13000000-0000-0000-0000-000000000006'
  ),
  true,
  'approved graph connects the verified start to a portal through real edges'
);

update app_private.portal_windows set max_concurrent_groups = 4
where portal_id = '12000000-0000-0000-0000-000000000001';
select throws_ok(
  $$
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    values ('24000000-0000-0000-0000-000000000050', 1, '12000000-0000-0000-0000-000000000001', '2026-10-31 18:31:00+01', '2026-10-31 18:36:00+01')
  $$,
  '23514', 'PORTAL_CAPACITY_EXCEEDED', 'overlapping intervals count against portal concurrency even with different arrival timestamps'
);

update app_private.portal_windows set max_concurrent_groups = 10
where portal_id = '12000000-0000-0000-0000-000000000001';
select lives_ok(
  $$
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    values ('24000000-0000-0000-0000-000000000050', 1, '12000000-0000-0000-0000-000000000001', '2026-10-31 18:30:00+01', '2026-10-31 18:35:00+01')
  $$,
  'route-ready first stop within capacity is accepted'
);
select throws_ok(
  $$
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    values ('24000000-0000-0000-0000-000000000050', 2, '12000000-0000-0000-0000-000000000007', '2026-10-31 18:38:00+01', '2026-10-31 18:43:00+01')
  $$,
  '23514', 'DUPLICATE_PORTAL_OR_WORLD', 'one route cannot silently repeat a world or portal'
);

update app_private.walking_edges set closed_at = now()
where external_id = 'fixture-edge-1-2';
select throws_ok(
  $$
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    values ('24000000-0000-0000-0000-000000000050', 2, '12000000-0000-0000-0000-000000000002', '2026-10-31 18:38:00+01', '2026-10-31 18:43:00+01')
  $$,
  '23514', 'NO_SAFE_WALKING_PATH', 'closed graph connection blocks a route stop instead of drawing a straight line'
);
update app_private.walking_edges set closed_at = null
where external_id = 'fixture-edge-1-2';
select lives_ok(
  $$
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    values ('24000000-0000-0000-0000-000000000050', 2, '12000000-0000-0000-0000-000000000002', '2026-10-31 18:38:00+01', '2026-10-31 18:43:00+01')
  $$,
  'approved graph connection allows the next route stop'
);

update app_private.walking_edges set closed_at = now()
where external_id = 'fixture-edge-1-2';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_publish_plans('duindorp-halloween-2026', array['24000000-0000-0000-0000-000000000050']::uuid[], 'Publicatie na verplichte hervalidatie') $$,
  '23514', 'NO_SAFE_WALKING_PATH', 'publication revalidates graph state and rejects a newly closed edge'
);
set local role postgres;
select is(
  (select state::text from app_private.route_plan_versions where id = '24000000-0000-0000-0000-000000000050'),
  'valid',
  'failed revalidation leaves the plan unpublished'
);
update app_private.walking_edges set closed_at = null
where external_id = 'fixture-edge-1-2';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_publish_plans('duindorp-halloween-2026', array['24000000-0000-0000-0000-000000000050']::uuid[], 'Publicatie na volledige hercontrole') $$,
  'currently valid route publishes after server-side revalidation'
);
set local role postgres;
select is(
  (select state::text from app_private.route_plan_versions where id = '24000000-0000-0000-0000-000000000050'),
  'published',
  'validated plan state is published'
);
select is(
  (select status from app_private.walking_groups where id = '23000000-0000-0000-0000-000000000050'),
  'ready',
  'validated group becomes ready only after publication'
);
select ok(
  exists (
    select 1 from app_private.audit_events
    where action = 'route_plan.published' and resource_type = 'route_plan_batch'
      and minimal_change->>'planCount' = '1'
  ),
  'successful publication creates an audit event'
);

select * from finish();
rollback;
