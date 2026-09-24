begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

select is((select system_code from app_private.portal_applications order by system_number limit 1), 'P-01', 'portal application codes start at P-01');
select is((select max(system_code) from app_private.portal_applications where system_number = 30), 'P-30', 'portal application backfill is deterministic');
select is((select system_code from app_private.walking_groups order by system_number limit 1), 'G-01', 'group codes start at G-01');
select is((select max(system_code) from app_private.walking_groups where system_number = 5), 'G-05', 'group backfill is deterministic');
select is((select code from app_private.walking_groups where system_code = 'G-01'), 'G-01',
  'the legacy public group-code field is a compatibility alias for the stable system code');
select is((select portal.system_code from app_private.portals portal where portal.id = '12000000-0000-0000-0000-000000000001'),
  (select application.system_code from app_private.portal_applications application where application.id = '11000000-0000-0000-0000-000000000001'),
  'an approved portal keeps the code assigned to its application');
select ok((select credential.short_code_hash <> digest(portal.system_code, 'sha256')
  from app_private.portal_credentials credential join app_private.portals portal on portal.id = credential.portal_id
  where credential.revoked_at is null limit 1), 'display codes remain separate from secret scan credentials');

insert into app_private.portal_applications(event_id, applicant_user_id)
values ((select id from app_private.events where slug = 'duindorp-halloween-2026'), 'e0000000-0000-0000-0000-000000000001');
select is((select max(system_code) from app_private.portal_applications where system_number = 31), 'P-31', 'the portal counter allocates the next code');
delete from app_private.portal_applications where system_code = 'P-31';
insert into app_private.portal_applications(event_id, applicant_user_id)
values ((select id from app_private.events where slug = 'duindorp-halloween-2026'), 'e0000000-0000-0000-0000-000000000001');
select is((select max(system_code) from app_private.portal_applications where system_number = 32), 'P-32', 'deleted identities are not recycled');
select is((select last_value from app_private.event_identity_counters
  where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026') and entity_kind = 'portal'), 32,
  'the event-scoped portal counter advances atomically');

select ok(not has_function_privilege('anon', 'api.group_name_update(uuid,integer,text)', 'execute'), 'anonymous clients cannot rename groups');
select ok(not has_function_privilege('anon', 'api.admin_portal_operations_snapshot(text)', 'execute'), 'anonymous clients cannot read portal operations');
select ok(not has_function_privilege('anon', 'api.registration_exact_preferences_save(uuid,timestamptz,timestamptz,integer)', 'execute'), 'anonymous clients cannot save exact preferences');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.group_name_update('23000000-0000-0000-0000-000000000001', 1, '  De   Schaduwlopers  ')$$,
  'the current group leader can choose a group name');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,displayName}', 'De Schaduwlopers',
  'the participant snapshot exposes the normalized chosen name');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,systemCode}', 'G-01',
  'the participant snapshot exposes the stable system code');
select throws_ok($$select api.group_name_update('23000000-0000-0000-0000-000000000001', 1, 'Andere naam')$$,
  '40001', 'STALE_VERSION', 'a stale rename cannot overwrite a newer group name');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.group_name_update('23000000-0000-0000-0000-000000000001', 2, 'Onbevoegd')$$,
  '42501', 'NOT_AUTHORIZED', 'a participant who is not the leader cannot rename a group');
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary participant cannot read portal contact operations');

set local role postgres;
insert into app_private.event_capabilities(event_id, user_id, capability, granted_by)
values ((select id from app_private.events where slug = 'duindorp-halloween-2026'),
  'a0000000-0000-0000-0000-000000000001', 'groups_manage', 'f0000000-0000-0000-0000-000000000001');
update app_private.portal_applications set private_draft_data = private_draft_data ||
  '{"contactName":"Test contactpersoon","phone":"0612345678"}'::jsonb
where id = '11000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  '42501', 'NOT_AUTHORIZED', 'groups_manage alone cannot read house addresses or phone numbers');

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,
  'an event administrator can read the bounded portal operations projection');
select is(api.admin_portal_operations_snapshot('duindorp-halloween-2026') #>> '{portals,0,systemCode}', 'P-01',
  'the operations projection includes the stable portal code');
select is(api.admin_portal_operations_snapshot('duindorp-halloween-2026') #>> '{portals,0,phone}', '0612345678',
  'the operations projection includes the private phone only for an authorized organizer');
select matches(api.admin_portal_operations_snapshot('duindorp-halloween-2026') #>> '{portals,0,formattedAddress}',
  '^NIET-BESTAAND TESTADRES', 'the operations projection uses the canonical verified private location');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select ok(position('0612345678' in api.event_public_snapshot('duindorp-halloween-2026')::text) = 0,
  'the public event snapshot does not expose the portal phone number');
select ok(position('NIET-BESTAAND TESTADRES' in api.event_public_snapshot('duindorp-halloween-2026')::text) = 0,
  'the public event snapshot does not expose the canonical private address');

set local role postgres;
insert into app_private.households(id, label, primary_contact_user_id)
values ('21000000-0000-0000-0000-000000000099', 'Exact preference test', 'b0000000-0000-0000-0000-000000000001');
insert into app_private.household_members(household_id, user_id, relation_role)
values ('21000000-0000-0000-0000-000000000099', 'b0000000-0000-0000-0000-000000000001', 'owner');
update app_private.event_route_settings
set global_ordinary_stop_at = timestamptz '2026-10-31 20:30+01'
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');
insert into app_private.registration_drafts(event_id, household_id, payload)
values ((select id from app_private.events where slug = 'duindorp-halloween-2026'),
  '21000000-0000-0000-0000-000000000099',
  '{"startPreference":"indifferent","ordinaryStopAt":"2026-10-31T21:00:00+01:00","preferredStartAt":"2026-10-31T17:00:00+01:00","desiredEndAt":"2026-10-31T21:00:00+01:00"}'::jsonb);
insert into app_private.registrations(id, event_id, household_id, reference, status)
values ('22000000-0000-0000-0000-000000000099',
  (select id from app_private.events where slug = 'duindorp-halloween-2026'),
  '21000000-0000-0000-0000-000000000099', 'EXACT-PREF-TEST', 'submitted');
select is((select requested_ordinary_stop_at from app_private.registrations where id = '22000000-0000-0000-0000-000000000099'),
  timestamptz '2026-10-31 20:30+01', 'a 21:00 exact desired end is capped at the global ordinary-stop boundary');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.registration_exact_preferences_save(
  '22000000-0000-0000-0000-000000000099', timestamptz '2026-10-31 17:00+01',
  timestamptz '2026-10-31 21:00+01', 1)$$, 'a household adult can save exact Amsterdam event-time preferences');
select is(api.registration_preferences_snapshot('duindorp-halloween-2026') #>> '{preferredStartAt}', '2026-10-31T16:00:00+00:00',
  'the exact preferred start is stored as an unambiguous timestamp');
select is(jsonb_array_length(api.registration_preferences_snapshot('duindorp-halloween-2026') #> '{event,allowedStartTimes}'), 6,
  'the snapshot offers six configured start times from 17:00 through 19:30');
select is(jsonb_array_length(api.registration_preferences_snapshot('duindorp-halloween-2026') #> '{event,allowedEndTimes}'), 13,
  'the snapshot offers thirteen configured end times from 18:00 through 21:00');
select throws_ok($$select api.registration_exact_preferences_save(
  '22000000-0000-0000-0000-000000000099', timestamptz '2026-10-31 17:15+01',
  timestamptz '2026-10-31 20:15+01', 2)$$,
  '22023', 'INVALID_PREFERRED_START_AT', 'an off-step preferred start is rejected');

set local role postgres;
update app_private.start_slots set starts_at = timestamptz '2026-10-31 19:00+01'
where id = '20000000-0000-0000-0000-000000000001';
insert into app_private.group_schedule_revisions(
  group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
  expected_finale_arrival_at, preference_match, published_at
) values (
  '23000000-0000-0000-0000-000000000001', 99, 'published',
  '20000000-0000-0000-0000-000000000001', timestamptz '2026-10-31 20:30+01',
  timestamptz '2026-10-31 21:00+01', 'large_deviation', now()
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.registration_exact_preferences_request_change(
  '22000000-0000-0000-0000-000000000001', timestamptz '2026-10-31 17:00+01',
  timestamptz '2026-10-31 18:00+01', 'Wij willen veel eerder stoppen')$$,
  '22023', 'DESIRED_END_NOT_AFTER_CONFIRMED_START',
  'a requested end time cannot precede the already published factual start');

select * from finish();
rollback;
