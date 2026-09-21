begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

create temporary table live_values(
  children_one uuid[], children_five uuid[], children_seven uuid[], children_ten uuid[],
  run_one uuid, stop_one uuid, credential_token text,
  run_five uuid, stop_five uuid, participants_five uuid[], bulk_result jsonb,
  run_seven uuid, stop_seven uuid, participants_seven uuid[],
  run_ten uuid, stop_ten uuid, participants_ten uuid[]
) on commit drop;
insert into live_values(children_one, children_five, children_seven, children_ten)
select
  (select array_agg(registration_child.id order by registration_child.id) from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-1'),
  (select array_agg(registration_child.id order by registration_child.id) from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-5'),
  (select array_agg(registration_child.id order by registration_child.id) from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-7'),
  (select array_agg(registration_child.id order by registration_child.id) from app_private.registration_children registration_child join app_private.registrations registration on registration.id = registration_child.registration_id where registration.reference = 'FIXTURE-10');
grant select, update on live_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_start('23000000-0000-0000-0000-000000000001', (select children_one from live_values), 1, 'parent-start-denied', 'parent-start-denied-hash') $$,
  '42501', 'NOT_AUTHORIZED', 'parent cannot start their assigned group'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_assign_group_leader_by_email('23000000-0000-0000-0000-000000000001', 'leader-b@example.invalid', 1, 'Groepsleider vervangen voor acceptatietest') $$,
  'groups manager assigns a new leader with an audited revision'
);
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_start('23000000-0000-0000-0000-000000000001', (select children_one from live_values), 2, 'old-leader-start', 'old-leader-start-hash') $$,
  '42501', 'NOT_AUTHORIZED', 'old leader immediately loses mutation rights'
);
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update live_values set run_one = (api.run_start('23000000-0000-0000-0000-000000000001', (select children_one from live_values), 2, 'new-leader-start', 'new-leader-start-hash')->>'runId')::uuid $$,
  'new leader can start using the new group version'
);
set local role postgres;
update live_values values set stop_one = run.current_stop_id from app_private.group_runs run where run.id = values.run_one;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update live_values set credential_token = api.portal_rotate_credential('12000000-0000-0000-0000-000000000001', 1, 'Credential vervangen voor intrekkingstest')->>'credential' $$,
  'portal owner rotates the active credential before scan tests'
);
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_scan((select run_one from live_values), (select stop_one from live_values), 2, 'TEST-PORTAL-01-TOKEN', 'qr') $$,
  '22023', 'WRONG_PORTAL', 'revoked previous QR token creates no evidence'
);
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_scan((select run_one from live_values), (select stop_one from live_values), 2, 'https://attacker.invalid/not-a-portal', 'qr') $$,
  '22023', 'WRONG_PORTAL', 'arbitrary QR text is treated only as an opaque credential and rejected'
);
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence where run_stop_id = (select stop_one from live_values)), 0, 'rejected QR creates no scan evidence');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_scan((select run_one from live_values), (select stop_one from live_values), 2, 'TEST-PORTAL-01-TOKEN', 'qr') $$,
  '42501', 'NOT_AUTHORIZED', 'parent cannot scan a portal'
);
select throws_ok(
  $$ select api.run_complete_stop((select run_one from live_values), (select stop_one from live_values), 2, true, 'parent-complete-denied', 'parent-complete-denied-hash') $$,
  '42501', 'NOT_AUTHORIZED', 'parent cannot complete a stop'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update live_values set run_five = (api.run_start('23000000-0000-0000-0000-000000000002', (select children_five[1:3] from live_values), 1, 'mixed-start', 'mixed-start-hash')->>'runId')::uuid $$,
  'leader starts three present participants for mixed outcome'
);
set local role postgres;
update live_values values set stop_five = run.current_stop_id,
  participants_five = (select array_agg(participant.id order by participant.registration_child_id) from app_private.run_participants participant where participant.run_id = run.id and participant.attendance = 'present')
from app_private.group_runs run where run.id = values.run_five;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_scan((select run_five from live_values), (select stop_five from live_values), 2, (select credential_token from live_values), 'qr') $$,
  'leader scans before recording mixed attendance'
);
select lives_ok(
  $$ select api.run_update_participant((select run_five from live_values), (select stop_five from live_values), (select participants_five[1] from live_values), 'visited', 2, 1, null) $$,
  'leader records one visited participant'
);
select lives_ok(
  $$ update live_values set bulk_result = api.run_bulk_skip_pending((select run_five from live_values), (select stop_five from live_values), 2, 'Overige ouders bevestigen overslaan', 'bulk-skip-mixed', 'bulk-skip-mixed-hash') $$,
  'bulk command skips only the two remaining pending participants'
);
select is((select bulk_result->>'changedCount' from live_values), '2', 'bulk result reports only changed pending rows');
set local role postgres;
select ok(
  (select count(*) = 1 from app_private.stop_participant_statuses where run_stop_id = (select stop_five from live_values) and status = 'visited')
  and (select count(*) = 2 from app_private.stop_participant_statuses where run_stop_id = (select stop_five from live_values) and status = 'skipped'),
  'bulk skip preserves visited and changes only pending statuses'
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.run_bulk_skip_pending((select run_five from live_values), (select stop_five from live_values), 2, 'Overige ouders bevestigen overslaan', 'bulk-skip-mixed', 'bulk-skip-mixed-hash'),
  (select bulk_result from live_values),
  'bulk skip retry returns one stored logical result'
);
select is(
  api.run_complete_stop((select run_five from live_values), (select stop_five from live_values), 2, false, 'mixed-complete', 'mixed-complete-hash')->>'outcome',
  'mixed',
  'visited and skipped participants complete with mixed outcome'
);

select lives_ok(
  $$ update live_values set run_seven = (api.run_start('23000000-0000-0000-0000-000000000003', (select children_seven[1:2] from live_values), 1, 'missing-status-start', 'missing-status-hash')->>'runId')::uuid $$,
  'leader starts two participants for completeness and departure tests'
);
set local role postgres;
update live_values values set stop_seven = run.current_stop_id,
  participants_seven = (select array_agg(participant.id order by participant.registration_child_id) from app_private.run_participants participant where participant.run_id = run.id and participant.attendance = 'present')
from app_private.group_runs run where run.id = values.run_seven;
delete from app_private.stop_participant_statuses where run_stop_id = (select stop_seven from live_values) and run_participant_id = (select participants_seven[2] from live_values);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_bulk_skip_pending((select run_seven from live_values), (select stop_seven from live_values), 2, 'Aanwezige statussen overslaan voor test', 'bulk-missing', 'bulk-missing-hash') $$,
  'existing pending status can be resolved without fabricating a missing row'
);
select throws_ok(
  $$ select api.run_complete_stop((select run_seven from live_values), (select stop_seven from live_values), 2, true, 'missing-complete', 'missing-complete-hash') $$,
  '23514', 'INCOMPLETE_STATUS_SET', 'missing participant status row blocks completion at the table invariant'
);
set local role postgres;
insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
values ((select stop_seven from live_values), (select participants_seven[2] from live_values));
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.run_mark_departed((select run_seven from live_values), (select stop_seven from live_values), (select participants_seven[1] from live_values), 2, 'Eerste kind vertrekt gecontroleerd')->>'remainingParticipants',
  '1',
  'one departing child updates roster while run stays active'
);
select is(
  api.run_mark_departed((select run_seven from live_values), (select stop_seven from live_values), (select participants_seven[2] from live_values), 3, 'Laatste kind vertrekt gecontroleerd')->>'status',
  'stopped',
  'last departing child stops rather than successfully completes the group'
);

select lives_ok(
  $$ update live_values set run_ten = (api.run_start('23000000-0000-0000-0000-000000000004', (select children_ten[1:2] from live_values), 1, 'departed-visited-start', 'departed-visited-hash')->>'runId')::uuid $$,
  'leader starts two participants for departed-visited history test'
);
set local role postgres;
update live_values values set stop_ten = run.current_stop_id,
  participants_ten = (select array_agg(participant.id order by participant.registration_child_id) from app_private.run_participants participant where participant.run_id = run.id and participant.attendance = 'present')
from app_private.group_runs run where run.id = values.run_ten;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$ select api.run_scan((select run_ten from live_values), (select stop_ten from live_values), 2, (select credential_token from live_values), 'qr') $$, 'leader scans before a visited child departs');
select lives_ok($$ select api.run_update_participant((select run_ten from live_values), (select stop_ten from live_values), (select participants_ten[1] from live_values), 'visited', 2, 1, null) $$, 'first child receives visited status');
select lives_ok($$ select api.run_mark_departed((select run_ten from live_values), (select stop_ten from live_values), (select participants_ten[1] from live_values), 2, 'Bezocht kind vertrekt tijdens tocht') $$, 'visited child can depart without erasing visit evidence');
select lives_ok($$ select api.run_update_participant((select run_ten from live_values), (select stop_ten from live_values), (select participants_ten[2] from live_values), 'skipped', 3, 1, 'Afgestemd met ouder bij de poort') $$, 'remaining child can be skipped after roster version change');
select is(
  api.run_complete_stop((select run_ten from live_values), (select stop_ten from live_values), 3, false, 'departed-mixed-complete', 'departed-mixed-hash')->>'outcome',
  'mixed',
  'departed visited child plus remaining skipped child preserves mixed outcome'
);
set local role postgres;
select ok(
  exists (select 1 from app_private.stop_participant_statuses where run_stop_id = (select stop_ten from live_values) and run_participant_id = (select participants_ten[1] from live_values) and status = 'visited' and not required_for_completion),
  'departure excludes completion requirement without rewriting visited history'
);

select * from finish();
rollback;
