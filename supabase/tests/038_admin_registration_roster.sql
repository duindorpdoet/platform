begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select ok(
  not has_function_privilege('anon', 'api.admin_registrations_snapshot(text)', 'execute'),
  'anonymous visitors cannot read the registration roster'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_registrations_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'a participant cannot read other registrations'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(
  jsonb_array_length(api.admin_registrations_snapshot('duindorp-halloween-2026')) > 0,
  'an event administrator sees submitted registrations'
);
select ok(
  (api.admin_registrations_snapshot('duindorp-halloween-2026') -> 0) ?&
    array['id', 'reference', 'parentName', 'parentEmail', 'groupName', 'children'],
  'the roster includes the list and detail fields required by the backoffice'
);
select ok(
  jsonb_array_length(api.admin_registrations_snapshot('duindorp-halloween-2026') -> 0 -> 'children') > 0,
  'registration details include the registered children'
);
select ok(
  (api.admin_registrations_snapshot('duindorp-halloween-2026') -> 0 ->> 'groupName') <> '',
  'every registration has an immediately usable group label before planning'
);

select * from finish();
rollback;
