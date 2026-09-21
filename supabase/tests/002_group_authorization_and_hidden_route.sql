begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.group_snapshot('23000000-0000-0000-0000-000000000001') $$,
  'current leader can read the assigned group'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.group_snapshot('23000000-0000-0000-0000-000000000001') $$,
  'household member can read their assigned group'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.group_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED', 'a second household cannot read another group'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.group_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED', 'an unrelated portal owner cannot read a group'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_start('23000000-0000-0000-0000-000000000099', array[]::uuid[], 1, 'empty-start-test', 'empty') $$,
  '23514', 'EMPTY_GROUP', 'an empty group can never start'
);

set local role postgres;
create temporary table test_ids(child_registration_id uuid, run_id uuid) on commit drop;
insert into test_ids(child_registration_id)
select registration_child.id
from app_private.registration_children registration_child
join app_private.registrations registration on registration.id = registration_child.registration_id
where registration.reference = 'FIXTURE-1';
grant select, update on test_ids to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
update test_ids set run_id = (api.run_start(
  '23000000-0000-0000-0000-000000000001',
  array[(select child_registration_id from test_ids)],
  1,
  'start-size-one',
  'stable-request'
)->>'runId')::uuid;
select ok((select run_id is not null from test_ids), 'leader starts a non-empty group');

select is(
  api.run_start('23000000-0000-0000-0000-000000000001', array[(select child_registration_id from test_ids)], 1, 'start-size-one', 'stable-request')->>'runId',
  (select run_id::text from test_ids),
  'same idempotency key returns the original run'
);

select throws_ok(
  $$ select api.run_start('23000000-0000-0000-0000-000000000001', array[(select child_registration_id from test_ids)], 1, 'start-size-one', 'changed-request') $$,
  '23505', 'IDEMPOTENCY_CONFLICT', 'reused key with another payload is rejected'
);

select ok(
  position('Testpoort 02' in api.group_snapshot('23000000-0000-0000-0000-000000000001')::text) = 0,
  'snapshot does not reveal the next portal'
);
select ok(
  position('12000000-0000-0000-0000-000000000002' in api.group_snapshot('23000000-0000-0000-0000-000000000001')::text) = 0,
  'snapshot does not reveal a future portal identifier'
);

select * from finish();
rollback;
