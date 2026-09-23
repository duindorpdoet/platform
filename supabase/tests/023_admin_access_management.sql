begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

select ok(
  not has_function_privilege('anon', 'api.admin_access_snapshot(text)', 'execute'),
  'anonymous visitors cannot enumerate administrators'
);
select ok(
  not has_function_privilege('anon', 'api.admin_set_user_capabilities(text,text,text[],text[],text)', 'execute'),
  'anonymous visitors cannot change administrator capabilities'
);
select ok(
  has_function_privilege('authenticated', 'api.admin_access_snapshot(text)', 'execute'),
  'authenticated users can reach the access snapshot authorization boundary'
);
select ok(
  has_function_privilege('authenticated', 'api.admin_set_user_capabilities(text,text,text[],text[],text)', 'execute'),
  'authenticated users can reach the capability mutation authorization boundary'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"role":"admin"}}', true);
select throws_ok(
  $$ select api.admin_access_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'an ordinary authenticated user cannot enumerate administrators'
);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-b@example.invalid',
    array['portals_manage'],
    '{}'::text[],
    'Onbevoegde poging vanuit de contracttest'
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'an ordinary authenticated user cannot grant capabilities'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (
    select jsonb_array_length(member -> 'capabilities')
    from jsonb_array_elements(api.admin_access_snapshot('duindorp-halloween-2026') -> 'members') member
    where member ->> 'email' = 'admin@example.invalid'
  ),
  7,
  'the event administrator can see the seeded administrator and all capabilities'
);

set local role postgres;
update auth.users
set email_confirmed_at = null
where id = 'b0000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-b@example.invalid',
    array['portals_manage'],
    '{}'::text[],
    'Account is nog niet per e-mail bevestigd'
  ) $$,
  '23514', 'CONFIRMED_USER_REQUIRED',
  'capabilities can only be granted to a confirmed Auth user'
);
set local role postgres;
update auth.users
set email_confirmed_at = now()
where id = 'b0000000-0000-0000-0000-000000000001';

create temporary table admin_access_values(
  operation text primary key,
  result jsonb not null
);
grant select, insert on admin_access_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into admin_access_values(operation, result)
     select 'partial-grant', api.admin_set_user_capabilities(
       'duindorp-halloween-2026',
       'parent-a@example.invalid',
       array['registration_manage','portals_manage'],
       '{}'::text[],
       'Helpt tijdelijk met inschrijvingen en locaties'
     ) $$,
  'an event administrator can grant a least-privilege capability set'
);
select is(
  (select result -> 'capabilities' from admin_access_values where operation = 'partial-grant'),
  '["portals_manage","registration_manage"]'::jsonb,
  'the returned capability set is normalized and deterministic'
);

set local role postgres;
select is(
  (
    select count(*)::integer
    from app_private.event_capabilities
    where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026')
      and user_id = 'a0000000-0000-0000-0000-000000000001'
      and revoked_at is null
  ),
  2,
  'only the selected capabilities are active for the target user'
);
select ok(
  exists (
    select 1
    from app_private.audit_events
    where action = 'event.capabilities_changed'
      and actor_id = 'f0000000-0000-0000-0000-000000000001'
      and resource_id = 'a0000000-0000-0000-0000-000000000001'
      and minimal_change -> 'added' = '["portals_manage","registration_manage"]'::jsonb
  ),
  'the grant records the actor, target and minimal capability change in the audit log'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-a@example.invalid',
    array['groups_manage'],
    '{}'::text[],
    'Verouderd beheerscherm mag niet overschrijven'
  ) $$,
  '40001', 'STALE_VERSION',
  'a stale administration screen cannot overwrite newer capabilities'
);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-a@example.invalid',
    array['not_a_real_capability'],
    array['portals_manage','registration_manage'],
    'Ongeldige rechten moeten worden geweigerd'
  ) $$,
  '22023', 'VALIDATION_ERROR',
  'unknown capability names are rejected'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_access_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'a scoped operational manager cannot enumerate administrators'
);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-b@example.invalid',
    array['groups_manage'],
    '{}'::text[],
    'Operationeel beheer mag geen rechten uitdelen'
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'a scoped operational manager cannot grant capabilities'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into admin_access_values(operation, result)
     select 'promote', api.admin_set_user_capabilities(
       'duindorp-halloween-2026',
       'parent-a@example.invalid',
       array['event_admin','portals_manage','registration_manage'],
       array['portals_manage','registration_manage'],
       'Wordt tweede hoofdbeheerder van het evenement'
     ) $$,
  'an existing scoped manager can be promoted to event administrator'
);

set local role postgres;
select is(
  (
    select count(distinct user_id)::integer
    from app_private.event_capabilities
    where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026')
      and capability = 'event_admin'
      and revoked_at is null
  ),
  2,
  'the event has two active event administrators after promotion'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into admin_access_values(operation, result)
     select 'remove-original', api.admin_set_user_capabilities(
       'duindorp-halloween-2026',
       'admin@example.invalid',
       '{}'::text[],
       array['content_manage','event_admin','groups_manage','live_support','payments_manage','portals_manage','registration_manage'],
       'Oude beheerder draagt alle verantwoordelijkheden over'
     ) $$,
  'an event administrator can be removed after another event administrator exists'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_set_user_capabilities(
    'duindorp-halloween-2026',
    'parent-a@example.invalid',
    array['portals_manage','registration_manage'],
    array['event_admin','portals_manage','registration_manage'],
    'Laatste hoofdbeheerder mag niet verdwijnen'
  ) $$,
  '23514', 'LAST_EVENT_ADMIN',
  'the last active event administrator cannot remove their own administrator capability'
);

set local role postgres;
select is(
  (
    select count(*)::integer
    from app_private.event_capabilities
    where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026')
      and user_id = 'f0000000-0000-0000-0000-000000000001'
      and revoked_at is null
  ),
  0,
  'all capabilities of the replaced administrator are inactive'
);
select ok(
  exists (
    select 1
    from app_private.audit_events
    where action = 'event.capabilities_changed'
      and actor_id = 'f0000000-0000-0000-0000-000000000001'
      and resource_id = 'f0000000-0000-0000-0000-000000000001'
      and jsonb_array_length(minimal_change -> 'removed') = 7
  ),
  'complete removal is recorded as one audited capability change'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.admin_access_snapshot('duindorp-halloween-2026') -> 'members'),
  1,
  'the access snapshot lists only users with active capabilities'
);

select * from finish();
rollback;
