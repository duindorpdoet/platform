begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

select ok(
  not has_function_privilege('anon', 'api.admin_portal_management_snapshot(text)', 'execute'),
  'anonymous visitors cannot read the organizer portal projection'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_portal_management_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'a parent cannot read house contact and address details'
);
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_portal_management_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'a resident cannot read the details of other houses'
);
reset role;

set local role service_role;
select lives_ok(
  $$ select api.portal_registration_begin(
    'duindorp-halloween-2026', 'parent-size-5@example.invalid', 'Concept bewoner', '0611223344',
    'Conceptstraat', '4', '', '2584AB', repeat('c', 64)
  ) $$,
  'a step-one house intake can be stored before OTP is used'
);
reset role;

select matches(
  (select system_code from app_private.portal_registration_intakes
    where normalized_email = 'parent-size-5@example.invalid'),
  '^P-[0-9]{2,}$',
  'the intake receives its permanent portal code immediately'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_portal_management_snapshot('duindorp-halloween-2026') $$,
  'an event administrator can read the management projection'
);
select is((
  select registration ->> 'status'
  from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026') -> 'registrations') registration
  where registration ->> 'email' = 'parent-size-5@example.invalid'
), 'awaiting_otp', 'an unclaimed concept appears with the waiting-for-OTP status');
select is((
  select count(*)::integer
  from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026') -> 'registrations') registration
  where registration ->> 'email' = 'parent-size-5@example.invalid'
), 1, 'the intake appears exactly once');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_registration_claim('duindorp-halloween-2026') $$,
  'the resident can activate the intake after email verification'
);
reset role;

select is(
  (select application.system_code
    from app_private.portal_applications application
    where application.applicant_user_id = 'a0000000-0000-0000-0000-000000000005')::text,
  (select intake.system_code
    from app_private.portal_registration_intakes intake
    where intake.normalized_email = 'parent-size-5@example.invalid')::text,
  'the activated application preserves the code assigned at step one'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((
  select registration ->> 'status'
  from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026') -> 'registrations') registration
  where registration ->> 'email' = 'parent-size-5@example.invalid'
), 'activated_incomplete', 'the same row changes to activated with details still incomplete');
select is((
  select count(*)::integer
  from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026') -> 'registrations') registration
  where registration ->> 'email' = 'parent-size-5@example.invalid'
), 1, 'the linked intake and application remain one row');
select is((
  select timeline_item ->> 'label'
  from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026') -> 'registrations') registration
  cross join lateral jsonb_array_elements(registration -> 'timeline') timeline_item
  where registration ->> 'email' = 'parent-size-5@example.invalid'
    and timeline_item ->> 'label' = 'Bewoner heeft poortomgeving geactiveerd'
), 'Bewoner heeft poortomgeving geactiveerd', 'the activation milestone uses the unambiguous resident wording');
create temp table test_admin_portal_snapshot as
select api.admin_portal_management_snapshot('duindorp-halloween-2026') as value;
reset role;
select is((
  select registration #>> '{address,street}'
  from test_admin_portal_snapshot
  cross join lateral jsonb_array_elements(value -> 'registrations') registration
  where registration ->> 'code' = 'P-01'
), 'NIET-BESTAAND TESTADRES', 'an approved registration falls back to its verified private address');
select is(
  jsonb_array_length((select value -> 'activePortals' from test_admin_portal_snapshot)),
  (select count(*)::integer from app_private.portals portal
    where portal.event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026')
      and portal.approval_status = 'approved'),
  'the active tab contains exactly the approved portal records'
);
select ok(not exists(
  select 1
  from jsonb_array_elements((select value -> 'activePortals' from test_admin_portal_snapshot)) portal_item
  where nullif(portal_item ->> 'portalId', '') is null
), 'every active row is backed by a real portal record');
select * from finish();
rollback;
