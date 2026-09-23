begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token,
  email_change_token_new, email_change, phone_change_token, email_change_token_current,
  reauthentication_token, created_at, updated_at
)
select fixture.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', fixture.email,
       crypt('local-test-only', gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
       '', '', '', '', '', '', '', now(), now()
from (values
  ('b0000000-0000-0000-0000-000000000002'::uuid, 'together-target@example.invalid'),
  ('b0000000-0000-0000-0000-000000000003'::uuid, 'together-invalid@example.invalid')
) fixture(id, email)
on conflict (id) do nothing;

create temporary table together_code_values(
  source_registration uuid,
  source_code text,
  target_registration uuid
) on commit drop;
insert into together_code_values values (null, null, null);
grant select, update on together_code_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.registration_save_draft(
    'duindorp-halloween-2026',
    '{"adult":{"name":"Bron ouder","phone":"0611111111"},"children":[{"name":"Bron kind","age":"8","accessibilityNote":""}],"togetherCode":"","marketingConsent":false}'::jsonb,
    null
  ) $$,
  'the first household saves a registration without an incoming code'
);
select lives_ok(
  $$ update together_code_values set source_registration = (
    api.registration_submit('duindorp-halloween-2026', 'terms-test', 'privacy-test', 'together-source', 'together-source-hash')->>'id'
  )::uuid $$,
  'the first household submits and receives its own code'
);
set local role postgres;
update together_code_values
set source_code = registration.together_code
from app_private.registrations registration
where registration.id = together_code_values.source_registration;
select matches((select source_code from together_code_values), '^[A-HJ-NP-Z2-9]{4}$', 'the generated code contains exactly four unambiguous characters');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok(
  $$ select api.registration_save_draft(
    'duindorp-halloween-2026',
    jsonb_build_object(
      'adult', jsonb_build_object('name', 'Volgende ouder', 'phone', '0622222222'),
      'children', jsonb_build_array(jsonb_build_object('name', 'Volgend kind', 'age', '9', 'accessibilityNote', '')),
      'togetherCode', (select source_code from together_code_values),
      'marketingConsent', false
    ),
    null
  ) $$,
  'a second household can save the shared four-character code'
);
select lives_ok(
  $$ update together_code_values set target_registration = (
    api.registration_submit('duindorp-halloween-2026', 'terms-test', 'privacy-test', 'together-target', 'together-target-hash')->>'id'
  )::uuid $$,
  'the second household can submit with an existing code'
);

set local role postgres;
select is(
  (select source_membership.party_id
   from app_private.together_memberships source_membership
   where source_membership.registration_id = (select source_registration from together_code_values) and source_membership.left_at is null),
  (select target_membership.party_id
   from app_private.together_memberships target_membership
   where target_membership.registration_id = (select target_registration from together_code_values) and target_membership.left_at is null),
  'both registrations are linked to the same planner party'
);
select isnt(
  (select together_code from app_private.registrations where id = (select source_registration from together_code_values)),
  (select together_code from app_private.registrations where id = (select target_registration from together_code_values)),
  'every registration keeps its own unique share code'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,togetherCount}',
  '2',
  'the participant snapshot reports the linked registration count without exposing identities'
);

set local role postgres;
select ok(not exists (select 1 from app_private.registrations where together_code = 'ZZZZ'), 'the unknown-code fixture is not already allocated');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select lives_ok(
  $$ select api.registration_save_draft(
    'duindorp-halloween-2026',
    '{"adult":{"name":"Onbekende ouder","phone":"0633333333"},"children":[{"name":"Onbekend kind","age":"10","accessibilityNote":""}],"togetherCode":"ZZZZ","marketingConsent":false}'::jsonb,
    null
  ) $$,
  'a syntactically valid code can be saved without revealing whether it exists'
);
select throws_ok(
  $$ select api.registration_submit('duindorp-halloween-2026', 'terms-test', 'privacy-test', 'together-invalid', 'together-invalid-hash') $$,
  '22023', 'INVALID_TOGETHER_CODE', 'an unknown code is rejected atomically during submission'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.registrations registration
   join app_private.household_members member on member.household_id = registration.household_id
   where member.user_id = 'b0000000-0000-0000-0000-000000000003'),
  0,
  'a rejected code leaves no partial registration behind'
);
select ok(
  not exists (select 1 from app_private.registration_drafts where payload ? 'togetherPreference'),
  'free-text together preferences are absent from all drafts'
);
select ok(
  (select count(*) = count(distinct together_code) from app_private.registrations),
  'the database uniqueness constraint remains satisfied after linked submissions'
);

select * from finish();
rollback;
