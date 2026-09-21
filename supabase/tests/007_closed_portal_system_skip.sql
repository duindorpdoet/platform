begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

select ok(has_function_privilege('authenticated', 'api.run_system_skip(uuid,uuid,integer,text,text,text)', 'execute'), 'authenticated actors can call the capability-checked system-skip command');

create temporary table system_skip_values(
  registration_one_child_id uuid,
  registration_five_child_id uuid,
  run_one_id uuid,
  run_one_version integer,
  stop_one_id uuid,
  participant_one_id uuid,
  system_skip_result jsonb,
  run_five_id uuid,
  run_five_version integer,
  stop_five_id uuid,
  participant_five_id uuid
) on commit drop;
insert into system_skip_values(registration_one_child_id, registration_five_child_id)
select
  (select registration_child.id from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-1'),
  (select registration_child.id from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-5' order by registration_child.id limit 1);
grant select, update on system_skip_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update system_skip_values set run_one_id = (api.run_start('23000000-0000-0000-0000-000000000001', array[(select registration_one_child_id from system_skip_values)], 1, 'closed-start-1', 'closed-start-hash-1')->>'runId')::uuid $$,
  'leader starts the first fixture group'
);
set local role postgres;
update system_skip_values values set
  stop_one_id = run.current_stop_id,
  run_one_version = run.version,
  participant_one_id = participant.id
from app_private.group_runs run
join app_private.run_participants participant on participant.run_id = run.id and participant.attendance = 'present'
where run.id = values.run_one_id;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'closed', 1, 'Poort gesloten voor systeemskiptest') $$,
  'portal owner closes the active portal with optimistic versioning'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_scan((select run_one_id from system_skip_values), (select stop_one_id from system_skip_values), (select run_one_version from system_skip_values), 'TEST-PORTAL-01-TOKEN', 'qr') $$,
  '22023', 'WRONG_PORTAL', 'closed portal rejects a new physical scan'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_support_override((select run_one_id from system_skip_values), (select stop_one_id from system_skip_values), (select run_one_version from system_skip_values), 'Gecontroleerd bewijs voor gesloten-poorttest') $$,
  'support override can preserve separately audited emergency evidence'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_update_participant((select run_one_id from system_skip_values), (select stop_one_id from system_skip_values), (select participant_one_id from system_skip_values), 'visited', (select run_one_version from system_skip_values), 1, null) $$,
  '23514', 'PORTAL_UNAVAILABLE', 'closed portal invariant blocks a new visit even after an emergency scan override'
);
select lives_ok(
  $$ update system_skip_values set system_skip_result = api.run_system_skip((select run_one_id from system_skip_values), (select stop_one_id from system_skip_values), (select run_one_version from system_skip_values), 'Poort is door bewoner gesloten', 'system-skip-one', 'system-skip-one-hash') $$,
  'leader can explicitly system-skip the closed current portal'
);
set local role postgres;
select is((select outcome::text from app_private.run_stops where id = (select stop_one_id from system_skip_values)), 'system_skipped', 'closed portal has a distinct system-skipped outcome');
select is((select sequence from app_private.run_stops stop join app_private.group_runs run on run.current_stop_id = stop.id where run.id = (select run_one_id from system_skip_values)), 2, 'system skip atomically unlocks exactly the next stop');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.run_system_skip((select run_one_id from system_skip_values), (select stop_one_id from system_skip_values), (select run_one_version from system_skip_values), 'Poort is door bewoner gesloten', 'system-skip-one', 'system-skip-one-hash'),
  (select system_skip_result from system_skip_values),
  'system skip replay returns the stored result without advancing twice'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'open', 2, 'Poort heropend voor pauzetest') $$,
  'portal owner reopens with the new version'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update system_skip_values set run_five_id = (api.run_start('23000000-0000-0000-0000-000000000002', array[(select registration_five_child_id from system_skip_values)], 1, 'paused-start-5', 'paused-start-hash-5')->>'runId')::uuid $$,
  'leader starts a second group for pause and recorded-visit checks'
);
set local role postgres;
update system_skip_values values set
  stop_five_id = run.current_stop_id,
  run_five_version = run.version,
  participant_five_id = participant.id
from app_private.group_runs run
join app_private.run_participants participant on participant.run_id = run.id and participant.attendance = 'present'
where run.id = values.run_five_id;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_scan((select run_five_id from system_skip_values), (select stop_five_id from system_skip_values), (select run_five_version from system_skip_values), 'TEST-PORTAL-01-TOKEN', 'qr') $$,
  'open portal accepts the valid physical credential'
);
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'paused', 3, 'Korte veiligheidspauze voor test') $$,
  'portal owner pauses the portal'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_update_participant((select run_five_id from system_skip_values), (select stop_five_id from system_skip_values), (select participant_five_id from system_skip_values), 'visited', (select run_five_version from system_skip_values), 1, null) $$,
  '23514', 'PORTAL_UNAVAILABLE', 'pause blocks a new visited mutation despite earlier scan evidence'
);
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'open', 4, 'Veiligheidspauze opgeheven') $$,
  'versioned reopen permits visits again'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_update_participant((select run_five_id from system_skip_values), (select stop_five_id from system_skip_values), (select participant_five_id from system_skip_values), 'visited', (select run_five_version from system_skip_values), 1, null) $$,
  'leader records the scanned visit after confirmed reopen'
);
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001', 'closed', 5, 'Poort sluit na geregistreerd bezoek') $$,
  'portal can close after a visit was already recorded'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_system_skip((select run_five_id from system_skip_values), (select stop_five_id from system_skip_values), (select run_five_version from system_skip_values), 'Poort sloot na geregistreerd bezoek', 'system-skip-five', 'system-skip-five-hash') $$,
  '23514', 'VISIT_ALREADY_RECORDED', 'system skip never overwrites an already recorded visit'
);

select * from finish();
rollback;
