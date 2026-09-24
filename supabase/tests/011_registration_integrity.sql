begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

create temporary table registration_values(
  draft_result jsonb,
  submit_result jsonb,
  household_id uuid,
  registration_id uuid
) on commit drop;
insert into registration_values values (null, null, null, null);
grant select, update on registration_values to authenticated;

select is(
  (select count(*)::integer from app_private.household_members where user_id = 'b0000000-0000-0000-0000-000000000001' and revoked_at is null),
  0,
  'new authenticated parent starts without implicit household or elevated role'
);

update app_private.event_route_settings set
  global_ordinary_stop_at = timestamptz '2026-10-31 20:30:00+01',
  allowed_personal_stop_times = array[timestamptz '2026-10-31 19:30:00+01']
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"role":"admin"}}',
  true
);
select lives_ok(
  $test$
    update registration_values
    set draft_result = api.registration_save_draft(
      'duindorp-halloween-2026',
      '{
        "adult":{"name":"Nieuwe ouder","householdLabel":"Door bezoeker gekozen naam","phone":"0612345678"},
        "children":[
          {"id":"25000001-0000-0000-0000-000000000001","name":"Eigen kind één","age":"8","amountCents":1},
          {"name":"Eigen kind twee","age":"10","unitPriceCents":1}
        ],
        "togetherPreference":"Samira de Vries",
        "startPreference":"early",
        "ordinaryStopAt":"2026-10-31T19:30:00+01:00",
        "amountCents":1,
        "marketingConsent":false
      }'::jsonb,
      null
    )
  $test$,
  'ordinary authenticated parent can persist a valid multi-child draft while registration is open'
);

set local role postgres;
update registration_values values
set household_id = member.household_id
from app_private.household_members member
where member.user_id = 'b0000000-0000-0000-0000-000000000001' and member.revoked_at is null;
select ok(
  exists (
    select 1 from app_private.household_members member
    where member.household_id = (select household_id from registration_values)
      and member.user_id = 'b0000000-0000-0000-0000-000000000001'
      and member.relation_role = 'owner' and member.revoked_at is null
  ),
  'draft creation establishes only an owned household for the authenticated parent'
);
select matches(
  (select label from app_private.households where id = (select household_id from registration_values)),
  '^Gezelschap [0-9A-F]{6}$',
  'the server assigns a neutral household label without asking the visitor'
);
select ok(
  not ((select payload -> 'adult' from app_private.registration_drafts where household_id = (select household_id from registration_values)) ? 'householdLabel'),
  'visitor-authored household labels are not retained in the private draft'
);
select is(
  (select payload ->> 'togetherCode' from app_private.registration_drafts where household_id = (select household_id from registration_values)),
  '',
  'a legacy free-text together preference is discarded instead of retaining a person name'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_values set submit_result = api.registration_submit('duindorp-halloween-2026', 'terms-2026-v1', 'privacy-2026-v1', 'registration-submit-1', 'registration-submit-hash-1') $$,
  'ordinary parent can submit the open registration without receiving an operational capability'
);
update registration_values set registration_id = (submit_result->>'id')::uuid;
select is(
  (select submit_result->>'priceCents' from registration_values),
  '500',
  'server computes two children times the authoritative 250-cent event price'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.registrations where household_id = (select household_id from registration_values) and status = 'submitted'),
  1,
  'submission creates exactly one active registration'
);
select is(
  (select start_time_preference::text from app_private.registrations where id = (select registration_id from registration_values)),
  'early',
  'submission copies the soft start preference from the private draft'
);
select is(
  (select requested_ordinary_stop_at from app_private.registrations where id = (select registration_id from registration_values)),
  timestamptz '2026-10-31 19:30:00+01',
  'submission copies an organizer-offered earlier stop moment'
);
select is(
  (select count(*)::integer from app_private.registration_children where registration_id = (select registration_id from registration_values)),
  2,
  'both submitted children are persisted'
);
select ok(
  not exists (
    select 1 from app_private.registration_children
    where registration_id = (select registration_id from registration_values)
      and child_id = '25000001-0000-0000-0000-000000000001'
  ),
  'known UUID supplied by the client cannot attach another household child'
);
select ok(
  not exists (
    select 1
    from app_private.registration_children registration_child
    join app_private.children child on child.id = registration_child.child_id
    where registration_child.registration_id = (select registration_id from registration_values)
      and child.household_id <> (select household_id from registration_values)
  ),
  'every persisted child is owned by the submitting household'
);
select is(
  (select count(*)::integer from app_private.payment_requests where registration_id = (select registration_id from registration_values) and amount_cents = 500),
  1,
  'one payment request carries the server-derived amount'
);
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'registration_received' and payload->>'reference' = (select submit_result->>'reference' from registration_values)),
  1,
  'one durable registration receipt is queued'
);
select ok(
  exists (
    select 1 from app_private.registrations
    where id = (select registration_id from registration_values)
      and terms_version = 'terms-2026-v1' and terms_accepted_at is not null
      and privacy_version = 'privacy-2026-v1' and not marketing_consent
  ),
  'consent versions and timestamp are stored while marketing remains opt-in false'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.registration_submit('duindorp-halloween-2026', 'terms-2026-v1', 'privacy-2026-v1', 'registration-submit-1', 'registration-submit-hash-1'),
  (select submit_result from registration_values),
  'same idempotency key returns the stored logical result'
);
select lives_ok(
  $$ select api.registration_submit('duindorp-halloween-2026', 'terms-2026-v1', 'privacy-2026-v1', 'registration-submit-2', 'registration-submit-hash-2') $$,
  'a separately keyed retry also resolves to the existing registration'
);

set local role postgres;
select ok(
  (select count(*) = 1 from app_private.registrations where household_id = (select household_id from registration_values) and status = 'submitted')
  and (select count(*) = 1 from app_private.payment_requests where registration_id = (select registration_id from registration_values))
  and (select count(*) = 1 from app_private.email_outbox where message_type = 'registration_received' and payload->>'reference' = (select submit_result->>'reference' from registration_values)),
  'all retries leave one registration, one payment request and one receipt task'
);
select is(
  (api.my_context('duindorp-halloween-2026')->'capabilities')::text,
  '[]',
  'registration never grants admin, leader or operational capabilities'
);

set local role postgres;
update app_private.registration_drafts
set payload = jsonb_set(payload, '{ordinaryStopAt}', '"2026-10-31T18:47:00+01:00"'::jsonb)
where household_id = (select household_id from registration_values);
select throws_ok(
  $$ insert into app_private.registrations(event_id, household_id, reference, status)
     select event_id, household_id, 'INVALID-STOP-PREFERENCE', 'cancelled'
     from app_private.registrations where id = (select registration_id from registration_values) $$,
  '22023', 'INVALID_STOP_PREFERENCE',
  'a direct crafted submission cannot select a stop moment the organization did not offer'
);

select * from finish();
rollback;
