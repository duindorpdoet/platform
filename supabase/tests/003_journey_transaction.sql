begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

create temporary table journey_ids(
  registration_child_id uuid,
  run_id uuid,
  stop_id uuid,
  participant_id uuid,
  status_id uuid
) on commit drop;
insert into journey_ids(registration_child_id)
select registration_child.id
from app_private.registration_children registration_child
join app_private.registrations registration on registration.id = registration_child.registration_id
where registration.reference = 'FIXTURE-5'
order by registration_child.id
limit 1;
grant select, update on journey_ids to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
update journey_ids set run_id = (api.run_start(
  '23000000-0000-0000-0000-000000000002',
  array[(select registration_child_id from journey_ids)],
  1,
  'journey-start',
  'journey-start-hash'
)->>'runId')::uuid;

set local role postgres;
update journey_ids ids set
  stop_id = run.current_stop_id,
  participant_id = participant.id
from app_private.group_runs run
join app_private.run_participants participant on participant.run_id = run.id and participant.attendance = 'present'
where run.id = ids.run_id;
update journey_ids ids set status_id = status.id
from app_private.stop_participant_statuses status
where status.run_stop_id = ids.stop_id and status.run_participant_id = ids.participant_id;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_update_participant((select run_id from journey_ids), (select stop_id from journey_ids), (select participant_id from journey_ids), 'skipped', 2, 1, null) $$,
  'a parent can skip their own child'
);
select throws_ok(
  $$ select api.run_update_participant((select run_id from journey_ids), (select stop_id from journey_ids), (select participant_id from journey_ids), 'visited', 2, 2, null) $$,
  '42501', 'NOT_AUTHORIZED', 'a parent cannot record a visit'
);
select lives_ok(
  $$ select api.run_update_participant((select run_id from journey_ids), (select stop_id from journey_ids), (select participant_id from journey_ids), 'pending', 2, 2, null) $$,
  'a parent can undo their own skip while stop is active'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_update_participant((select run_id from journey_ids), (select stop_id from journey_ids), (select participant_id from journey_ids), 'visited', 2, 3, null) $$,
  '23514', 'SCAN_REQUIRED', 'visited requires scan evidence'
);
select lives_ok(
  $$ select api.run_scan((select run_id from journey_ids), (select stop_id from journey_ids), 2, 'TEST-PORTAL-01-TOKEN', 'qr') $$,
  'leader can record valid scan evidence'
);
select lives_ok(
  $$ select api.run_update_participant((select run_id from journey_ids), (select stop_id from journey_ids), (select participant_id from journey_ids), 'visited', 2, 3, null) $$,
  'leader records a visit after valid scan'
);
select lives_ok(
  $$ select api.run_complete_stop((select run_id from journey_ids), (select stop_id from journey_ids), 2, false, 'complete-first', 'complete-hash') $$,
  'resolved scanned stop completes atomically'
);
select is(
  api.run_complete_stop((select run_id from journey_ids), (select stop_id from journey_ids), 2, false, 'complete-first', 'complete-hash')->>'outcome',
  'visited',
  'retry returns the stored completion result'
);
select throws_ok(
  $$ select api.run_complete_stop((select run_id from journey_ids), (select stop_id from journey_ids), 2, false, 'stale-second-device', 'other-hash') $$,
  '40001', 'STALE_VERSION', 'a stale second device cannot complete again'
);

select * from finish();
rollback;
