begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

create temporary table security_values(party jsonb) on commit drop;
insert into security_values values (null);
grant select, update on security_values to authenticated;

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
select lives_ok(
  $$ update security_values set party = api.together_create('22000000-0000-0000-0000-000000000001', 'Samen maar gescheiden') $$,
  'first household creates a together party'
);
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select lives_ok(
  $$ select api.together_join('22000000-0000-0000-0000-000000000002', (select party->>'inviteCode' from security_values)) $$,
  'second household joins by together code'
);
set local role postgres;
select ok(
  not app_private.is_household_member('21000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000005'),
  'together membership grants no access to the other household'
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select is(
  api.household_access_snapshot('duindorp-halloween-2026')->>'id',
  '21000000-0000-0000-0000-000000000002',
  'joined parent still receives only their own household projection'
);

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
