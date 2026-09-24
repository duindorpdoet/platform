begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

select ok(
  not has_function_privilege('anon', 'api.portal_registration_begin(text,text,text,text,text,text,text,text,text)', 'execute'),
  'the pre-OTP intake command is not callable by an anonymous browser'
);
select ok(
  has_function_privilege('service_role', 'api.portal_registration_begin(text,text,text,text,text,text,text,text,text)', 'execute'),
  'only the trusted server may create a pre-OTP intake'
);
select ok(
  not has_table_privilege('anon', 'app_private.portal_registration_intakes', 'select'),
  'anonymous visitors cannot read private contact or address intake rows'
);

set local role service_role;
select lives_ok(
  $$ select api.portal_registration_begin(
    'duindorp-halloween-2026', 'parent-size-5@example.invalid', 'Nieuwe bewoner', '0612345678',
    '', '', '', '', repeat('a', 64)
  ) $$,
  'the trusted endpoint stores the minimum house details before sending an OTP'
);
reset role;

select is(
  (select count(*)::integer from app_private.portal_registration_intakes where normalized_email = 'parent-size-5@example.invalid'),
  1,
  'one private concept intake is keyed by normalized email'
);
select is(
  (select private_address from app_private.portal_registration_intakes where normalized_email = 'parent-size-5@example.invalid'),
  '{}'::jsonb,
  'contact-only registration stores an empty private address object'
);
select is(
  (select count(*)::integer from app_private.portals portal
    join app_private.portal_applications application on application.id = portal.application_id
    where application.applicant_user_id = 'a0000000-0000-0000-0000-000000000005'),
  0,
  'an unclaimed concept never becomes a public or routable portal'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_registration_claim('duindorp-halloween-2026') $$,
  'the account with the verified matching email can claim the intake after OTP'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,status}',
  'draft',
  'claiming creates a valid private draft without the additional profile fields'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #> '{application,draft,address}',
  '{}'::jsonb,
  'Mijn huis starts with optional address fields left empty'
);
select lives_ok(
  $$ select api.portal_application_save(
    'duindorp-halloween-2026',
    api.portal_snapshot('duindorp-halloween-2026') #> '{application,draft}',
    (api.portal_snapshot('duindorp-halloween-2026') #>> '{application,version}')::integer
  ) $$,
  'a contact-only house concept can be saved with server-side defaults'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,draft,requestedWorldSlug}',
  'anders',
  'the candy-only category is the default'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,draft,availableFrom}',
  '17:00',
  'house availability starts at 17:00 by default'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,draft,availableUntil}',
  '21:00',
  'house availability ends at 21:00 by default'
);
select lives_ok(
  $$ select api.portal_application_submit(
    (api.portal_snapshot('duindorp-halloween-2026') #>> '{application,id}')::uuid,
    (api.portal_snapshot('duindorp-halloween-2026') #>> '{application,version}')::integer,
    'contact-only-house-submit', 'contact-only-house-submit-hash'
  ) $$,
  'only verified email, contact name and phone are required for submission'
);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,status}',
  'submitted',
  'the minimal house application reaches the review queue'
);
select lives_ok(
  $$ select api.portal_registration_claim('duindorp-halloween-2026') $$,
  'repeating the claim is idempotent for the same account'
);
reset role;

select is(
  (select count(*)::integer from app_private.portal_applications
    where applicant_user_id = 'a0000000-0000-0000-0000-000000000005'
      and event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026')),
  1,
  'repeated OTP or claim delivery cannot create a duplicate house application'
);
select is(
  (select count(*)::integer from app_private.portals portal
    join app_private.portal_applications application on application.id = portal.application_id
    where application.applicant_user_id = 'a0000000-0000-0000-0000-000000000005'),
  0,
  'the incomplete draft remains absent from approved portal data'
);

select throws_ok(
  $$ select api.portal_application_save(
    'duindorp-halloween-2026', jsonb_build_object('contactName', repeat('x', 70000)), null
  ) $$,
  '22023', 'VALIDATION_ERROR',
  'direct authenticated RPC calls cannot persist an oversized private draft'
);

set local role service_role;
select lives_ok(
  $$ select api.portal_registration_begin(
    'duindorp-halloween-2026', 'parent-size-5@example.invalid', 'Gewijzigde naam', '0698765432',
    'ANDERE FICTIEVE STRAAT', '99', 'A', '2584AB', repeat('b', 64)
  ) $$,
  'a duplicate public submission for an already claimed email is acknowledged without a second house'
);
reset role;
select is(
  (select count(*)::integer from app_private.portal_registration_intakes where normalized_email = 'parent-size-5@example.invalid'),
  1,
  'the unique email constraint remains intact after a duplicate submission'
);

select * from finish();
rollback;
