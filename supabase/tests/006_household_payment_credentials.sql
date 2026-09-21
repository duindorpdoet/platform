begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

select ok(not has_function_privilege('anon', 'api.household_invite_create(text,text,text,text)', 'execute'), 'anonymous users cannot create household invitations');
select ok(not has_function_privilege('anon', 'api.payment_refund(uuid,integer,text,text,text,text)', 'execute'), 'anonymous users cannot record refunds');
select ok(not has_function_privilege('anon', 'api.portal_rotate_credential(uuid,integer,text)', 'execute'), 'anonymous users cannot rotate portal credentials');

create temporary table lifecycle_values(
  invite_result jsonb,
  invite_token text,
  revoked_invite_id uuid,
  revoked_invite_token text,
  expired_invite_id uuid,
  expired_invite_token text,
  refund_result jsonb,
  credential_result jsonb,
  payment_one_id uuid,
  payment_five_id uuid
) on commit drop;
insert into lifecycle_values(payment_one_id, payment_five_id)
select
  (select id from app_private.payment_requests where reference = 'PAY-FIXTURE-1'),
  (select id from app_private.payment_requests where reference = 'PAY-FIXTURE-5');
grant select, update on lifecycle_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(api.household_access_snapshot('duindorp-halloween-2026')->>'canManage', 'true', 'household owner can manage access');
select lives_ok(
  $$ update lifecycle_values set invite_result = api.household_invite_create('duindorp-halloween-2026', 'parent-b@example.invalid', 'invite-parent-b-001', 'invite-parent-b-hash-001') $$,
  'owner can create an addressed invitation'
);

set local role postgres;
update lifecycle_values set invite_token = (
  select payload->>'inviteToken' from app_private.email_outbox
  where message_type = 'household_invite' and recipient_email = 'parent-b@example.invalid'
  order by created_at desc limit 1
);
select is((select count(*)::integer from app_private.email_outbox where message_type = 'household_invite' and recipient_email = 'parent-b@example.invalid'), 1, 'invitation is queued exactly once in the durable outbox');
select ok(not ((select invite_result from lifecycle_values) ? 'inviteToken'), 'idempotency receipt does not expose the invitation secret');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.household_invite_create('duindorp-halloween-2026', 'parent-b@example.invalid', 'invite-parent-b-001', 'invite-parent-b-hash-001'),
  (select invite_result from lifecycle_values),
  'invitation replay returns the stored result without queueing duplicate mail'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.household_invite_accept((select invite_token from lifecycle_values)) $$,
  '42501', 'RECIPIENT_MISMATCH', 'a logged-in user with another address cannot consume the invitation'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$ select api.household_invite_accept((select invite_token from lifecycle_values)) $$, 'matching verified recipient can consume the invitation once');
select is(api.household_access_snapshot('duindorp-halloween-2026')->>'canManage', 'false', 'invited adult receives household access without owner rights');
select throws_ok(
  $$ select api.household_invite_create('duindorp-halloween-2026', 'nobody@example.invalid', 'adult-cannot-invite', 'adult-cannot-invite-hash') $$,
  '42501', 'NOT_AUTHORIZED', 'invited adult cannot create further invitations'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.household_member_revoke('duindorp-halloween-2026', 'b0000000-0000-0000-0000-000000000001', (api.household_access_snapshot('duindorp-halloween-2026')->>'version')::integer, 'Gezinstoegang ingetrokken in test') $$,
  'owner can revoke the second adult with a reason and current version'
);
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(api.household_access_snapshot('duindorp-halloween-2026'), null::jsonb, 'revoked adult immediately loses household projection access');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update lifecycle_values set revoked_invite_id = (api.household_invite_create('duindorp-halloween-2026', 'parent-b@example.invalid', 'invite-revoke-001', 'invite-revoke-hash-001')->>'id')::uuid $$,
  'owner can create a replacement invitation after revoking membership'
);
set local role postgres;
update lifecycle_values set revoked_invite_token = (
  select payload->>'inviteToken' from app_private.email_outbox
  where message_type = 'household_invite' and recipient_email = 'parent-b@example.invalid'
  order by created_at desc limit 1
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.household_invite_revoke((select revoked_invite_id from lifecycle_values), (api.household_access_snapshot('duindorp-halloween-2026')->>'version')::integer, 'Uitnodiging bewust ingetrokken') $$,
  'owner can revoke an unconsumed invitation'
);
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.household_invite_accept((select revoked_invite_token from lifecycle_values)) $$,
  '23514', 'INVITE_NOT_AVAILABLE', 'revoked invitation can no longer be consumed'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update lifecycle_values set expired_invite_id = (api.household_invite_create('duindorp-halloween-2026', 'admin@example.invalid', 'invite-expire-001', 'invite-expire-hash-001')->>'id')::uuid $$,
  'owner can create a separately addressed invitation for expiry testing'
);
set local role postgres;
update lifecycle_values set expired_invite_token = (
  select payload->>'inviteToken' from app_private.email_outbox
  where message_type = 'household_invite' and recipient_email = 'admin@example.invalid'
  order by created_at desc limit 1
);
update app_private.household_invites set created_at = now() - interval '2 days', expires_at = now() - interval '1 day'
where id = (select expired_invite_id from lifecycle_values);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.household_invite_accept((select expired_invite_token from lifecycle_values)) $$,
  '23514', 'INVITE_NOT_AVAILABLE', 'expired invitation can no longer be consumed'
);

set local role postgres;
insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
select payment.id, payment.amount_cents, 'payment', 'f0000000-0000-0000-0000-000000000001', now(), 'TEST-COLLECTED-1', 'Lokale fixturebetaling'
from app_private.payment_requests payment where payment.reference = 'PAY-FIXTURE-1';
insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
select payment.id, payment.amount_cents, 'payment', 'f0000000-0000-0000-0000-000000000001', now(), 'TEST-COLLECTED-5', 'Lokale fixturebetaling'
from app_private.payment_requests payment where payment.reference = 'PAY-FIXTURE-5';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.payment_refund((select payment_one_id from lifecycle_values), 200, 'TEST-REFUND-UNAUTHORIZED', 'Onbevoegde terugbetaling', 'refund-parent-1', 'refund-parent-hash-1') $$,
  '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot record a refund'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update lifecycle_values set refund_result = api.payment_refund((select payment_one_id from lifecycle_values), 200, 'TEST-REFUND-1', 'Volledig buiten de app terugbetaald', 'refund-admin-1', 'refund-admin-hash-1') $$,
  'payments manager records a completed external refund'
);
set local role postgres;
select is((select status::text from app_private.payment_requests where reference = 'PAY-FIXTURE-1'), 'refunded', 'full refund changes the derived request status');
select is((select sum(entry.amount_cents)::integer from app_private.payment_entries entry join app_private.payment_requests payment on payment.id = entry.request_id where payment.reference = 'PAY-FIXTURE-1'), 0, 'refund ledger remains append-only and nets to zero');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.payment_refund((select payment_one_id from lifecycle_values), 200, 'TEST-REFUND-1', 'Volledig buiten de app terugbetaald', 'refund-admin-1', 'refund-admin-hash-1'),
  (select refund_result from lifecycle_values),
  'same refund idempotency key returns the stored safe result'
);
select throws_ok(
  $$ select api.payment_refund((select payment_five_id from lifecycle_values), 1200, 'TEST-REFUND-TOO-HIGH', 'Te hoge terugbetaling geweigerd', 'refund-admin-2', 'refund-admin-hash-2') $$,
  '23514', 'REFUND_EXCEEDS_COLLECTED', 'refund cannot exceed the append-only collected balance'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update lifecycle_values set credential_result = api.portal_rotate_credential('12000000-0000-0000-0000-000000000001', 1, 'QR vervangen voor lokale acceptatie') $$,
  'portal owner can rotate their credential with an audit reason'
);
select is(char_length((select credential_result->>'credential' from lifecycle_values)), 64, 'rotated QR credential has 256 bits of random material');
select is(char_length((select credential_result->>'shortCode' from lifecycle_values)), 12, 'manual fallback code has twelve hexadecimal characters');

set local role postgres;
select ok(
  (select count(*) = 1 from app_private.portal_credentials where portal_id = '12000000-0000-0000-0000-000000000001' and version = 1 and revoked_at is not null)
  and (select count(*) = 1 from app_private.portal_credentials where portal_id = '12000000-0000-0000-0000-000000000001' and version = 2 and revoked_at is null and token_hash = extensions.digest(convert_to((select credential_result->>'credential' from lifecycle_values), 'utf8'), 'sha256')),
  'old credential is revoked and only the new credential hash is retained'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.portal_rotate_credential('12000000-0000-0000-0000-000000000001', 1, 'Verouderde tweede rotatie') $$,
  '40001', 'STALE_VERSION', 'stale concurrent credential rotation is rejected'
);
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.portal_rotate_credential('12000000-0000-0000-0000-000000000001', 2, 'Onbevoegde QR-rotatie') $$,
  '42501', 'NOT_AUTHORIZED', 'unrelated parent cannot rotate a portal credential'
);

select * from finish();
rollback;
