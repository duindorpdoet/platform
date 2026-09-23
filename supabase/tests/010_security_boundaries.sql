begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"role":"admin"},"app_metadata":{"role":"admin"}}',
  true
);
select is(
  jsonb_array_length(api.my_context('duindorp-halloween-2026')->'capabilities'),
  0,
  'editable JWT metadata does not grant a database capability'
);
select throws_ok(
  $$ select api.admin_dashboard('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED', 'forged admin metadata cannot read the admin projection'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select matches(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,togetherCode}',
  '^[A-HJ-NP-Z2-9]{4}$',
  'a participant receives only a four-character non-personal together code'
);
set local role postgres;
select ok(
  (select count(*) = count(distinct together_code) from app_private.registrations),
  'together codes are unique across every registration'
);
select ok(
  to_regprocedure('api.together_snapshot(text)') is null,
  'the old post-registration together snapshot is retired'
);
select ok(
  to_regprocedure('api.together_create(uuid,text)') is null,
  'visitors can no longer create a free-text together group'
);
select ok(
  to_regprocedure('api.together_join(uuid,text)') is null,
  'visitors can no longer replace the code chosen during signup'
);
select ok(
  to_regprocedure('api.together_leave(uuid,text)') is null,
  'visitors can no longer silently leave a planned code group'
);
select ok(
  not exists (
    select 1 from app_private.together_parties
    where public_label !~ '^Samenloop(code)? [A-Z0-9]{4,6}$'
  ),
  'planner parties retain no visitor-authored names'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'paused', 1, 'Onbevoegde statuswijziging') $$,
  '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot mutate another resident portal'
);
select ok(
  app_private.can_access_realtime_topic('group:23000000-0000-0000-0000-000000000001'),
  'participating parent can resolve their own group realtime topic'
);
select ok(
  not app_private.can_access_realtime_topic('group:23000000-0000-0000-0000-000000000002'),
  'participating parent cannot resolve another group realtime topic'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(
  app_private.can_access_realtime_topic('portal:12000000-0000-0000-0000-000000000001'),
  'portal owner can resolve their own portal realtime topic'
);
select ok(
  app_private.can_access_application_asset('e0000000-0000-0000-0000-000000000001/11000000-0000-0000-0000-000000000001/photo.webp'),
  'portal applicant can resolve their own private application object path'
);
select ok(
  app_private.can_access_portal_document('12000000-0000-0000-0000-000000000001/qr.png'),
  'portal owner can resolve their own QR document path'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(
  not app_private.can_access_realtime_topic('portal:12000000-0000-0000-0000-000000000001'),
  'ordinary parent cannot resolve a resident realtime topic'
);
select ok(
  not app_private.can_access_application_asset('e0000000-0000-0000-0000-000000000001/11000000-0000-0000-0000-000000000001/photo.webp'),
  'ordinary parent cannot resolve another applicant private object path'
);
select ok(
  not app_private.can_access_portal_document('12000000-0000-0000-0000-000000000001/qr.png'),
  'ordinary parent cannot resolve another resident QR document path'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(
  app_private.can_access_application_asset('e0000000-0000-0000-0000-000000000001/11000000-0000-0000-0000-000000000001/photo.webp'),
  'portal reviewer can open an applicant private image through a short-lived signed URL'
);
set local role postgres;
select is(
  (select count(*)::integer from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname in ('application owners upload private images', 'application owners update private images')),
  0,
  'browsers cannot bypass server-side image signature validation with a direct storage write'
);

set local role service_role;
select lives_ok(
  $test$
    do $do$
    begin
      for attempt in 1..5 loop
        perform api.submit_public_contact(
          'duindorp-halloween-2026', 'Afzender', 'attacker-target@example.invalid',
          'Testonderwerp ' || attempt, 'Testbericht voor duurzame begrenzing', 'contact-rate-fixture'
        );
      end loop;
    end
    $do$
  $test$,
  'five contact submissions in one durable subject bucket are accepted'
);
set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'contact_notification'),
  5,
  'accepted contact submissions each create one durable notification'
);
select ok(
  not exists (
    select 1 from app_private.email_outbox
    where message_type = 'contact_notification' and recipient_email <> 'halloween@duindorpdoet.nl'
  ),
  'public contact sender input can never select the outbox recipient'
);
set local role service_role;
select throws_ok(
  $$ select api.submit_public_contact('duindorp-halloween-2026', 'Afzender', 'another-target@example.invalid', 'Zesde poging', 'Moet begrensd worden', 'contact-rate-fixture') $$,
  'P0001', 'RATE_LIMITED', 'sixth contact submission in the same durable bucket is rejected'
);

select lives_ok(
  $test$
    do $do$
    begin
      for attempt in 1..3 loop
        perform api.submit_public_sponsor(
          'duindorp-halloween-2026', 'Sponsor', 'attacker-sponsor-target@example.invalid',
          'dienst', 1000, 'Sponsorbericht', 'sponsor-rate-fixture'
        );
      end loop;
    end
    $do$
  $test$,
  'three sponsor submissions in one durable subject bucket are accepted'
);
set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'sponsor_notification'),
  3,
  'accepted sponsor submissions each create one durable notification'
);
select ok(
  not exists (
    select 1 from app_private.email_outbox
    where message_type = 'sponsor_notification' and recipient_email <> 'halloween@duindorpdoet.nl'
  ),
  'public sponsor sender input can never select the outbox recipient'
);
set local role service_role;
select throws_ok(
  $$ select api.submit_public_sponsor('duindorp-halloween-2026', 'Sponsor', 'another-sponsor-target@example.invalid', 'dienst', 1000, 'Vierde sponsorbericht', 'sponsor-rate-fixture') $$,
  'P0001', 'RATE_LIMITED', 'fourth sponsor submission in the same durable bucket is rejected'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $test$
    do $do$
    begin
      for attempt in 1..5 loop
        perform api.household_invite_create(
          'duindorp-halloween-2026',
          format('invite-target-%s@example.invalid', attempt),
          format('invite-key-%s', attempt),
          format('invite-hash-%s', attempt)
        );
      end loop;
    end
    $do$
  $test$,
  'five household invitations in the durable actor bucket are accepted'
);
select throws_ok(
  $$ select api.household_invite_create('duindorp-halloween-2026', 'invite-target-6@example.invalid', 'invite-key-6', 'invite-hash-6') $$,
  'P0001', 'RATE_LIMITED', 'sixth household invitation in the durable actor bucket is rejected'
);
set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'household_invite' and recipient_email like 'invite-target-%@example.invalid'),
  5,
  'rate-limited household invitations create no sixth outbox task'
);

select * from finish();
rollback;
