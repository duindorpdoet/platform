begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

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
  target_registration uuid,
  join_request uuid,
  join_request_version integer
) on commit drop;
insert into together_code_values values (null, null, null, null, null);
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
insert into app_private.walking_groups(id, event_id, code, status, display_name)
select
  '29000000-0000-0000-0000-000000000024', event_id,
  'EMAIL-RECIPIENT-TEST', 'draft', 'De Testgroep'
from app_private.registrations
where id = (select source_registration from together_code_values);
insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
values (
  '29000000-0000-0000-0000-000000000024',
  (select source_registration from together_code_values),
  1
);


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
update together_code_values
set join_request = request.id,
    join_request_version = request.version
from app_private.together_join_requests request
where request.requested_by_registration_id = together_code_values.target_registration;
select is(
  (select count(*)::integer from app_private.email_outbox
   where message_type = 'group_merge_requested'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  1,
  'a join request queues one actionable message for the head group'
);
select is(
  (select recipient_ref from app_private.email_outbox
   where message_type = 'group_merge_requested'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  'b0000000-0000-0000-0000-000000000001',
  'the pending request goes to the target head household rather than the requester'
);
select is(
  (select payload ->> 'groupName' from app_private.email_outbox
   where message_type = 'group_merge_requested'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  'De Testgroep',
  'the pending request payload identifies the editable head-group name'
);
select matches(
  (select payload ->> 'systemCode' from app_private.email_outbox
   where message_type = 'group_merge_requested'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  '^G-[0-9]{2,}$',
  'the pending request payload includes the stable system code when available'
);


select isnt(
  (select source_membership.party_id
   from app_private.together_memberships source_membership
   where source_membership.registration_id = (select source_registration from together_code_values) and source_membership.left_at is null),
  (select target_membership.party_id
   from app_private.together_memberships target_membership
   where target_membership.registration_id = (select target_registration from together_code_values) and target_membership.left_at is null),
  'a join request keeps both registrations in separate planner parties before organizer approval'
);
select is(
  (select request.status from app_private.together_join_requests request
   where request.id = (select join_request from together_code_values)),
  'pending',
  'joining by code creates a pending request rather than granting immediate membership'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,togetherCount}',
  '1',
  'the participant snapshot does not count a pending household as linked'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.admin_decide_together_request(
    (select join_request from together_code_values),
    (select join_request_version from together_code_values),
    'accept', false, 'Samen lopen is afgestemd.'
  ) #>> '{status}',
  'accepted',
  'an organizer explicitly approves the join request'
);

set local role postgres;
select is(
  (select source_membership.party_id
   from app_private.together_memberships source_membership
   where source_membership.registration_id = (select source_registration from together_code_values) and source_membership.left_at is null),
  (select target_membership.party_id
   from app_private.together_memberships target_membership
   where target_membership.registration_id = (select target_registration from together_code_values) and target_membership.left_at is null),
  'both registrations share one planner party only after approval'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.admin_decide_together_request(
    (select join_request from together_code_values),
    (select join_request_version from together_code_values),
    'accept', false, 'Samen lopen is afgestemd.'
  ) #>> '{status}',
  'accepted',
  'retrying the same approval with the original version returns the recorded decision'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox
   where message_type = 'group_merge_approved'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  2,
  'an approval queues one message for each involved adult contact'
);
select is(
  (select count(distinct recipient_email)::integer from app_private.email_outbox
   where message_type = 'group_merge_approved'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  2,
  'approval recipients are unique by adult contact'
);
select is(
  (select array_agg(recipient_email order by recipient_email) from app_private.email_outbox
   where message_type = 'group_merge_approved'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  array['parent-b@example.invalid', 'together-target@example.invalid']::text[],
  'both source and target adult contacts receive the approval'
);
select ok(
  (select count(*) = count(distinct dedupe_key) from app_private.email_outbox
   where message_type = 'group_merge_approved'
     and payload ->> 'requestId' = (select join_request::text from together_code_values)),
  'a decision retry cannot duplicate mail for a recipient and state'
);

select is(
  (select count(*)::integer
   from app_private.audit_events audit
   where audit.resource_type = 'together_join_request'
     and audit.resource_id = (select join_request from together_code_values)
     and audit.action = 'together.capacity_request_accepted'),
  1,
  'an idempotent approval retry does not duplicate the decision audit event'
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
  'the participant snapshot reports the linked registration count after approval without exposing identities'
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
