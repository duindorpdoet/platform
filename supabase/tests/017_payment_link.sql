begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

update app_private.payment_requests
set id = '26000000-0000-0000-0000-000000000901', status = 'awaiting_link', external_url = null, version = 1
where registration_id = '22000000-0000-0000-0000-000000000001';

select ok(not has_function_privilege('anon', 'api.payment_set_external_link(uuid,integer,text,text)', 'execute'), 'an anonymous visitor cannot attach a payment link');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.payment_set_external_link(
    '26000000-0000-0000-0000-000000000901',
    1, 'https://www.tikkie.me/pay/test-only-reference', 'Ouder mag geen link instellen'
  ) $$,
  '42501', 'NOT_AUTHORIZED', 'a household cannot attach its own alleged payment link'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.payment_set_external_link(
    '26000000-0000-0000-0000-000000000901',
    1, 'https://evil.example.invalid/pay/test-only-reference', 'Ongeldige provider wordt geweigerd'
  ) $$,
  '22023', 'VALIDATION_ERROR', 'an arbitrary external payment URL is rejected'
);
select lives_ok(
  $$ select api.payment_set_external_link(
    '26000000-0000-0000-0000-000000000901',
    1, 'https://www.tikkie.me/pay/test-only-reference', 'Handmatig aangemaakte Tikkie voor deze inschrijving'
  ) $$,
  'a payment manager can attach an HTTPS Tikkie link'
);
select is(
  (select item ->> 'externalUrl' from jsonb_array_elements(api.admin_payments_snapshot('duindorp-halloween-2026')) item where item ->> 'id' = '26000000-0000-0000-0000-000000000901'),
  'https://www.tikkie.me/pay/test-only-reference',
  'the private payment dashboard can restore the exact link for a controlled correction'
);

set local role postgres;
select is((select status::text from app_private.payment_requests where registration_id = '22000000-0000-0000-0000-000000000001'), 'awaiting_payment', 'attaching or opening a link does not confirm payment');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,externalUrl}',
  'https://www.tikkie.me/pay/test-only-reference',
  'the household receives the exact organization-provided link in its private snapshot'
);
select lives_ok(
  $$ select api.registration_report_payment('22000000-0000-0000-0000-000000000001', 2) $$,
  'the household can only report that it used the payment link'
);

set local role postgres;
select is((select status::text from app_private.payment_requests where registration_id = '22000000-0000-0000-0000-000000000001'), 'reported', 'a household report remains unconfirmed pending organization control');
select ok((select minimal_change::text from app_private.audit_events where action = 'payment.external_link_set' order by created_at desc limit 1) not like '%https://%', 'the audit event records provider and reason without copying the full payment URL');

select * from finish();
rollback;
