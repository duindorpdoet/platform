begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temporary table parent_child_change_test (
  added jsonb,
  removed jsonb
) on commit drop;
grant select, update on parent_child_change_test to authenticated;
insert into parent_child_change_test default values;

select ok(
  not has_function_privilege('anon', 'api.registration_child_add(uuid,integer,text,integer,text)', 'execute'),
  'anonymous visitors cannot add children'
);
select ok(
  not has_function_privilege('anon', 'api.registration_child_remove(uuid,integer,integer)', 'execute'),
  'anonymous visitors cannot remove children'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000084","role":"authenticated"}', true);
select throws_ok(
  $$ select api.registration_child_add(
    '22000000-0000-0000-0000-000000000083', 1, 'Niet van mij', 8, null
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'another household cannot add a child'
);
select throws_ok(
  $$ select api.registration_child_remove(
    '26000083-0000-0000-0000-000000000001', 1, 1
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'another household cannot remove a child'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,childrenEditable}',
  'true',
  'children are editable before the group is final'
);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,children,0,canRemove}',
  'true',
  'an unpaid child is directly removable'
);
select throws_ok(
  $$ select api.registration_child_add(
    '22000000-0000-0000-0000-000000000083', 999, 'Te laat', 8, null
  ) $$,
  '40001', 'STALE_VERSION',
  'a stale browser cannot overwrite the registration'
);
select lives_ok(
  $$ update parent_child_change_test
     set added = api.registration_child_add(
       '22000000-0000-0000-0000-000000000083', 1, 'Nieuw kind', 7, 'Rustige begeleiding'
     ) $$,
  'a parent can add a child before final assignment'
);
reset role;

select is(
  (select count(*)::integer
   from app_private.registration_children
   where registration_id = '22000000-0000-0000-0000-000000000083'
     and participation_status = 'active'),
  4,
  'the new child is active'
);
select is(
  (select price_snapshot_cents
   from app_private.registrations
   where id = '22000000-0000-0000-0000-000000000083'),
  1000,
  'the registration total includes the new child'
);
select is(
  (select amount_cents
   from app_private.payment_requests
   where id = '28000000-0000-0000-0000-000000000083'),
  1000,
  'the payment total includes the new child'
);
select is(
  (select child.first_name
   from app_private.registration_children registration_child
   join app_private.children child on child.id = registration_child.child_id
   where registration_child.id = (select (added ->> 'registrationChildId')::uuid from parent_child_change_test)),
  'Nieuw kind',
  'the child profile is created for the household'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}', true);
select lives_ok(
  $$ update parent_child_change_test
     set removed = api.registration_child_remove(
       (added ->> 'registrationChildId')::uuid,
       (added ->> 'version')::integer,
       1
     ) $$,
  'the parent can remove the unpaid child again'
);
reset role;

select is(
  (select participation_status
   from app_private.registration_children
   where id = (select (added ->> 'registrationChildId')::uuid from parent_child_change_test)),
  'cancelled',
  'removal keeps an auditable cancelled registration-child record'
);
select ok(
  (select archived_at is not null
   from app_private.children
   where id = (
     select child_id from app_private.registration_children
     where id = (select (added ->> 'registrationChildId')::uuid from parent_child_change_test)
   )),
  'the removed child profile is archived'
);
select is(
  (select price_snapshot_cents
   from app_private.registrations
   where id = '22000000-0000-0000-0000-000000000083'),
  750,
  'removing the child restores the registration total'
);

update app_private.payment_requests
set status = 'confirmed', version = version + 1
where id = '28000000-0000-0000-0000-000000000083';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}', true);
select throws_ok(
  $$ select api.registration_child_remove(
    '26000083-0000-0000-0000-000000000001',
    (api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,version}')::integer,
    1
  ) $$,
  '23514', 'CHILD_ALREADY_PAID',
  'a paid child cannot be removed without organizer review'
);
reset role;

insert into app_private.walking_groups(
  id, event_id, code, status
)
select
  '23000000-0000-0000-0000-000000000083',
  id,
  'PARENT-CHANGE-LOCK',
  'ready'
from app_private.events
where slug = 'duindorp-halloween-2026';

insert into app_private.group_registrations(
  group_id, registration_id, published_at, assignment_revision
)
values (
  '23000000-0000-0000-0000-000000000083',
  '22000000-0000-0000-0000-000000000083',
  now(),
  1
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,childrenEditable}',
  'false',
  'the final group assignment locks child maintenance'
);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,childrenLockedReason}',
  'group_finalized',
  'the snapshot explains why direct changes are locked'
);
select throws_ok(
  $$ select api.registration_child_add(
    '22000000-0000-0000-0000-000000000083',
    (api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,version}')::integer,
    'Na indeling', 8, null
  ) $$,
  '23514', 'CHILDREN_LOCKED',
  'a parent cannot add a child after final group assignment'
);

select * from finish();
rollback;
