begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

select ok(not has_function_privilege('anon', 'api.admin_portal_operations_snapshot(text)', 'execute'),
  'anonymous clients cannot read private map details');
select ok(not has_function_privilege('anon', 'api.admin_group_composition_snapshot(text)', 'execute'),
  'anonymous clients cannot read group composition');
select ok(not has_function_privilege('anon', 'api.admin_group_move_registration(text,uuid,uuid)', 'execute'),
  'anonymous clients cannot move registrations');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'a parent cannot read private portal map details');
select throws_ok($$select api.admin_group_composition_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'a parent cannot read the organizer group board');
select throws_ok($$select api.admin_group_move_registration(
  'duindorp-halloween-2026', '22000000-0000-0000-0000-000000000083', null)$$,
  '42501', 'NOT_AUTHORIZED', 'a parent cannot change organizer assignments');

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'a group leader cannot read private portal map details');

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'a portal owner cannot read other portal private details');

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  'an event administrator can read the bounded private map projection');
select is(api.admin_portal_operations_snapshot('duindorp-halloween-2026') #>> '{portals,0,coordinate,0}', '4.270100',
  'the private map returns the verified longitude in GeoJSON order');
select is(api.admin_portal_operations_snapshot('duindorp-halloween-2026') #>> '{portals,0,coordinate,1}', '52.100100',
  'the private map returns the verified latitude in GeoJSON order');

create temp table created_group as
select (api.admin_group_create('duindorp-halloween-2026', 'Test indeling') ->> 'id')::uuid as id;
select lives_ok($$select api.admin_group_move_registration(
  'duindorp-halloween-2026', '22000000-0000-0000-0000-000000000083',
  (select id from created_group))$$, 'an organizer can place an unassigned registration');
select is((
  select group_item ->> 'childCount'
  from jsonb_array_elements(api.admin_group_composition_snapshot('duindorp-halloween-2026') -> 'groups') group_item
  where group_item ->> 'id' = (select id::text from created_group)
), '3', 'the board immediately shows the new group child total');
select is(jsonb_array_length(api.admin_group_composition_snapshot('duindorp-halloween-2026') -> 'unassigned'), 4,
  'the moved registration disappears from the unassigned list');

select * from finish();
rollback;
