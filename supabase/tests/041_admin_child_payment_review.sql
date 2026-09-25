begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temporary table payment_review_test(batch jsonb) on commit drop;
grant select, update on payment_review_test to authenticated;
insert into payment_review_test values (null);

select ok(
  not has_function_privilege('anon', 'api.admin_child_payment_mark_unpaid(uuid,integer)', 'execute'),
  'anonymous users cannot decide a reported payment'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$select api.admin_child_payment_publish(
    'duindorp-halloween-2026',
    '[{"id":"25000083-0000-0000-0000-000000000001","version":1},{"id":"25000084-0000-0000-0000-000000000001","version":1}]',
    '25000083-0000-0000-0000-000000000001',
    'https://betaalverzoek.ing.nl/verzoek/cross-registration',
    'Betaallink gepubliceerd via beheeromgeving',
    'cross-registration'
  )$$,
  '23514',
  'CHILDREN_MUST_SHARE_REGISTRATION',
  'one child payment link cannot mix registrations'
);
update payment_review_test
set batch = api.admin_child_payment_publish(
  'duindorp-halloween-2026',
  '[{"id":"25000084-0000-0000-0000-000000000001","version":1}]',
  '25000084-0000-0000-0000-000000000001',
  'https://betaalverzoek.ing.nl/verzoek/admin-review',
  'Betaallink gepubliceerd via beheeromgeving',
  'admin-review-publish'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000084","role":"authenticated"}', true);
update payment_review_test
set batch = api.child_payment_report(
  (batch->>'id')::uuid,
  (batch->>'version')::integer
);
select is((select batch->>'status' from payment_review_test), 'reported', 'parent report waits for admin review');
select throws_ok(
  $$select api.admin_child_payment_mark_unpaid((select (batch->>'id')::uuid from payment_review_test),(select (batch->>'version')::integer from payment_review_test))$$,
  '42501',
  'NOT_AUTHORIZED',
  'parent cannot decide the review outcome'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
update payment_review_test
set batch = api.admin_child_payment_mark_unpaid(
  (batch->>'id')::uuid,
  (batch->>'version')::integer
);
select is((select batch->>'status' from payment_review_test), 'awaiting_payment', 'admin can mark the reported payment link unpaid');
select is((select batch->>'externalUrl' from payment_review_test), 'https://betaalverzoek.ing.nl/verzoek/admin-review', 'unpaid decision restores the existing payment link');
select throws_ok(
  $$select api.admin_child_payment_mark_unpaid((select (batch->>'id')::uuid from payment_review_test),(select (batch->>'version')::integer from payment_review_test))$$,
  '23514',
  'INVALID_TRANSITION',
  'only a reported payment can be marked unpaid'
);

reset role;
select is(
  (select count(*)::integer from app_private.audit_events where resource_id = (select (batch->>'id')::uuid from payment_review_test) and action = 'payment.child_marked_unpaid'),
  1,
  'the automatic status decision remains auditable'
);

select * from finish();
rollback;
