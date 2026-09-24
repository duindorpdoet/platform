begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

select is((select price_cents from app_private.events where slug = 'duindorp-halloween-2026'), 250,
  'new registrations use 250 cents per child');
select is((select (settings ->> 'maxGroupSize')::integer from app_private.events where slug = 'duindorp-halloween-2026'), 20,
  'event starts with the twenty-child group limit');
select is((select amount_cents from app_private.payment_requests where reference = 'PAY-FIXTURE-10'), 2000,
  'historical confirmed payment requests retain their original price');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(api.registration_preferences_snapshot('duindorp-halloween-2026') #>> '{event,priceCents}', '250',
  'the registration UI gets the current authoritative contribution');
select throws_ok($$ select api.admin_set_group_size_limit('duindorp-halloween-2026', 21,
  (api.admin_dashboard('duindorp-halloween-2026') #>> '{event,settingsVersion}')::integer,
  'Een te grote groep voor de nieuwe avond') $$,
  '22023', 'VALIDATION_ERROR', 'even an administrator cannot configure more than twenty children');
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($test$
  select api.registration_save_draft('duindorp-halloween-2026',
    jsonb_build_object('adult', jsonb_build_object('name','Ouder','phone','0612345678'),
      'children', (select jsonb_agg(jsonb_build_object('name','Kind ' || number,'age','8')) from generate_series(1,21) number)), null)
$test$, '23514', 'GROUP_SIZE_LIMIT_EXCEEDED', 'direct registration API calls cannot save a twenty-one-child signup');
reset role;

-- Grow a fixture that already has a party and an assigned group to exactly 20.
select lives_ok($test$
  with children as (
    insert into app_private.children(household_id, first_name, age_at_event)
    select registration.household_id, 'Grenskind ' || number, 8
    from app_private.registrations registration cross join generate_series(1,10) number
    where registration.reference = 'FIXTURE-10'
    returning id, household_id
  )
  insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
  select registration.event_id, registration.id, children.id, 250
  from children join app_private.registrations registration on registration.household_id = children.household_id
  where registration.reference = 'FIXTURE-10'
$test$, 'exactly twenty children in a registration, party and assigned group are accepted');

insert into app_private.children(household_id, first_name, age_at_event)
select household_id, 'Kind eenentwintig', 8 from app_private.registrations where reference = 'FIXTURE-10';
select throws_ok($test$
  insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
  select registration.event_id, registration.id, child.id, 250
  from app_private.registrations registration join app_private.children child on child.household_id = registration.household_id
  where registration.reference = 'FIXTURE-10' and child.first_name = 'Kind eenentwintig'
$test$, '23514', 'GROUP_SIZE_LIMIT_EXCEEDED', 'a twenty-first child is rejected in the database');

select throws_ok($test$
  update app_private.group_registrations set group_id = (
    select assignment.group_id from app_private.group_registrations assignment
    join app_private.registrations registration on registration.id = assignment.registration_id
    where registration.reference = 'FIXTURE-10' and assignment.superseded_at is null
  ) where registration_id = (select id from app_private.registrations where reference = 'FIXTURE-1') and superseded_at is null
$test$, '23514', 'GROUP_SIZE_LIMIT_EXCEEDED', 'direct organizer assignment cannot create a twenty-one-child group');

select throws_ok($test$
  update app_private.together_memberships set party_id = (
    select membership.party_id from app_private.together_memberships membership
    join app_private.registrations registration on registration.id = membership.registration_id
    where registration.reference = 'FIXTURE-10' and membership.left_at is null
  ) where registration_id = (select id from app_private.registrations where reference = 'FIXTURE-1') and left_at is null
$test$, '23514', 'GROUP_SIZE_LIMIT_EXCEEDED', 'joining another household cannot bypass the twenty-child ceiling');
create temporary table rejected_merge_request(id uuid) on commit drop;
grant select on rejected_merge_request to authenticated;
with request as (
  insert into app_private.together_join_requests(event_id, source_party_id, target_party_id,
    requested_by_registration_id, requested_code, child_count_at_request, group_limit_at_request)
  select source.event_id, source_membership.party_id, target_membership.party_id,
    source.id, target.together_code, 1, 20
  from app_private.registrations source
  join app_private.together_memberships source_membership on source_membership.registration_id = source.id and source_membership.left_at is null
  cross join app_private.registrations target
  join app_private.together_memberships target_membership on target_membership.registration_id = target.id and target_membership.left_at is null
  where source.reference = 'FIXTURE-1' and target.reference = 'FIXTURE-10'
  returning id
) insert into rejected_merge_request select id from request;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($test$
  select api.admin_decide_together_request((select id from rejected_merge_request), 1, 'accept', true,
    'Deze expliciete uitzondering mag twintig niet overschrijden')
$test$, '23514', 'GROUP_SIZE_LIMIT_EXCEEDED', 'an audited override cannot accept a twenty-one-child merge');
reset role;
select is((select status from app_private.together_join_requests where id = (select id from rejected_merge_request)),
  'pending', 'a rejected over-capacity merge rolls back its membership and decision changes');

select is((select count(*)::integer from app_private.registration_children child join app_private.registrations registration on registration.id = child.registration_id
  where registration.reference = 'FIXTURE-10' and child.participation_status = 'active'), 20,
  'rejected changes leave the original group intact');
select ok(not has_function_privilege('authenticated', 'app_private.enforce_twenty_child_limit()', 'execute'),
  'capacity guards are not exposed as participant RPCs');
select * from finish();
rollback;
