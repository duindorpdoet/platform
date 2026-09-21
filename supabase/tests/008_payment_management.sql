begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

select ok(not has_function_privilege('authenticated', 'api.payment_confirm(uuid,integer,text,text,text,text)', 'execute'), 'legacy unversioned payment confirmation is not callable by browsers');
select ok(has_function_privilege('authenticated', 'api.payment_confirm_versioned(uuid,integer,integer,text,text,text,text)', 'execute'), 'authenticated actors can call the capability-checked versioned confirmation');
select ok(not has_function_privilege('anon', 'api.admin_payments_snapshot(text)', 'execute'), 'payment management projection is not public');

create temporary table payment_values(payment_id uuid, partial_result jsonb, registration_ten_id uuid, payment_ten_id uuid) on commit drop;
insert into payment_values(payment_id, registration_ten_id, payment_ten_id)
select
  (select id from app_private.payment_requests where reference = 'PAY-FIXTURE-7'),
  (select id from app_private.registrations where reference = 'FIXTURE-10'),
  (select id from app_private.payment_requests where reference = 'PAY-FIXTURE-10');
grant select, update on payment_values to authenticated;
update app_private.payment_requests set status = 'reported', version = 1 where id = (select payment_id from payment_values);
delete from app_private.payment_entries where request_id = (select payment_id from payment_values);
update app_private.payment_requests set status = 'awaiting_payment', version = 1 where id = (select payment_ten_id from payment_values);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
select lives_ok(
  $$ select api.registration_report_payment((select registration_ten_id from payment_values), 1) $$,
  'parent can report an awaiting payment for their own household'
);
set local role postgres;
select is((select status::text from app_private.payment_requests where id = (select payment_ten_id from payment_values)), 'reported', 'parent report never promotes payment to confirmed');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_payments_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot enumerate payment administration'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$ select api.admin_payments_snapshot('duindorp-halloween-2026') $$, 'payments manager can read the bounded payment projection');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
select throws_ok(
  $$ select api.payment_confirm_versioned((select payment_id from payment_values), 1, 400, 'TEST-PARENT', 'Onbevoegde bevestiging', 'parent-confirm-key', 'parent-confirm-hash') $$,
  '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot confirm their own payment'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update payment_values set partial_result = api.payment_confirm_versioned((select payment_id from payment_values), 1, 400, 'TEST-PARTIAL-400', 'Eerste gecontroleerde deelbetaling', 'admin-confirm-partial', 'admin-confirm-partial-hash') $$,
  'payments manager records a versioned partial payment'
);
select is((select partial_result->>'status' from payment_values), 'partial', 'partial ledger balance derives partial status');
select is(
  api.payment_confirm_versioned((select payment_id from payment_values), 1, 400, 'TEST-PARTIAL-400', 'Eerste gecontroleerde deelbetaling', 'admin-confirm-partial', 'admin-confirm-partial-hash'),
  (select partial_result from payment_values),
  'same confirmation key replays without a duplicate ledger entry'
);
select is(
  api.payment_confirm_versioned((select payment_id from payment_values), 2, 1000, 'TEST-REMAINDER-1000', 'Resterende gecontroleerde betaling', 'admin-confirm-rest', 'admin-confirm-rest-hash')->>'status',
  'confirmed',
  'second versioned entry completes the exact server-side amount'
);
set local role postgres;
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id = (select payment_id from payment_values)), 1400, 'append-only payment ledger equals the requested amount without duplicates');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.payment_confirm_versioned((select payment_id from payment_values), 2, 100, 'TEST-STALE', 'Verouderde dubbele bevestiging', 'admin-confirm-stale', 'admin-confirm-stale-hash') $$,
  '40001', 'STALE_VERSION', 'stale concurrent confirmation cannot append another payment'
);
select ok(
  jsonb_path_exists(api.admin_payments_snapshot('duindorp-halloween-2026'), '$[*] ? (@.reference == "PAY-FIXTURE-7" && @.status == "confirmed" && @.netCollectedCents == 1400)'),
  'management projection derives the confirmed status and net ledger amount'
);

select * from finish();
rollback;
