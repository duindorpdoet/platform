begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

create temporary table dynamic_state(
  child_id uuid,
  group_version integer,
  schedule_id uuid,
  run_id uuid
) on commit drop;

insert into dynamic_state(child_id, group_version)
select registration_child.id, walking_group.version
from app_private.registration_children registration_child
join app_private.registrations registration on registration.id = registration_child.registration_id and registration.reference = 'FIXTURE-1'
cross join app_private.walking_groups walking_group
where walking_group.id = '23000000-0000-0000-0000-000000000001';

update app_private.portal_windows set opens_at = now() - interval '1 hour', closes_at = now() + interval '5 hours'
where portal_id in (select id from app_private.portals where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026'));
update app_private.start_slots set starts_at = now() + interval '1 hour'
where id = '20000000-0000-0000-0000-000000000001';
update app_private.event_route_settings set
  first_start_at = now() - interval '1 hour',
  global_ordinary_stop_at = now() + interval '2 hours',
  allowed_personal_stop_times = array[now() + interval '1 hour'],
  ordinary_visit_seconds = 60,
  route_buffer_seconds = 0,
  final_portal_id = '12000000-0000-0000-0000-000000000030',
  finale_opens_at = now() - interval '10 minutes',
  finale_last_arrival_at = now() + interval '4 hours',
  finale_closes_at = now() + interval '5 hours',
  finale_show_seconds = 60,
  finale_turnover_seconds = 0,
  finale_max_concurrent_groups = 1,
  finale_max_concurrent_children = 10,
  finale_available = true,
  planner_mode = 'dynamic'
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');

with inserted as (
  insert into app_private.group_schedule_revisions(
    group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
    expected_finale_arrival_at, preference_match, created_by
  ) values (
    '23000000-0000-0000-0000-000000000001', 1, 'draft',
    '20000000-0000-0000-0000-000000000001', now() + interval '2 hours',
    now() + interval '1 hour', 'neutral', 'f0000000-0000-0000-0000-000000000001'
  ) returning id
)
update dynamic_state set schedule_id = inserted.id from inserted;
update app_private.walking_groups walking_group set
  route_mode = 'dynamic', current_schedule_revision_id = state.schedule_id,
  status = 'ready', version = version + 1
from dynamic_state state where walking_group.id = '23000000-0000-0000-0000-000000000001';
update dynamic_state set group_version = walking_group.version
from app_private.walking_groups walking_group
where walking_group.id = '23000000-0000-0000-0000-000000000001';
grant select, update on dynamic_state to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') -> 'group' -> 'start',
  'null'::jsonb,
  'a draft schedule never exposes its exact start point through the participant RPC'
);
select throws_ok(
  $$ select api.run_start(
    '23000000-0000-0000-0000-000000000001', array[(select child_id from dynamic_state)],
    (select group_version from dynamic_state), 'dynamic-unpublished', 'dynamic-unpublished-hash'
  ) $$,
  '23514', 'SCHEDULE_NOT_PUBLISHED', 'a dynamic group cannot start from a concept schedule'
);

set local role postgres;
update app_private.group_schedule_revisions set state = 'published', published_at = now()
where id = (select schedule_id from dynamic_state);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select isnt(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') -> 'group' -> 'start',
  null::jsonb,
  'the exact assigned start becomes visible only after explicit publication'
);
select throws_ok(
  $$ select api.run_start(
    '23000000-0000-0000-0000-000000000001', array[(select child_id from dynamic_state)],
    (select group_version from dynamic_state), 'dynamic-too-early', 'dynamic-too-early-hash'
  ) $$,
  '23514', 'START_TIME_NOT_REACHED', 'presence cannot start a group before its exact assigned time'
);

set local role postgres;
update app_private.start_slots set starts_at = now() - interval '1 minute'
where id = '20000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update dynamic_state set run_id = (api.run_start(
    '23000000-0000-0000-0000-000000000001', array[(select child_id from dynamic_state)],
    (select group_version from dynamic_state), 'dynamic-start', 'dynamic-start-hash'
  ) ->> 'runId')::uuid $$,
  'a paid group starts after its assigned time and receives one server-selected stop'
);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,kind}',
  'ordinary',
  'the first live assignment is an ordinary portal rather than the terminal portal'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.portal_reservations where run_id = (select run_id from dynamic_state) and kind = 'ordinary' and status = 'active'),
  1,
  'the dispatcher exposes and reserves exactly one ordinary portal at a time'
);
select is(
  (select count(*)::integer from app_private.portal_reservations where run_id = (select run_id from dynamic_state) and kind = 'finale' and status = 'held'),
  1,
  'the dispatcher reserves a feasible finale window before releasing an ordinary portal'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$
declare
  i integer;
  snapshot jsonb;
begin
  for i in 1..7 loop
    snapshot := api.group_snapshot('23000000-0000-0000-0000-000000000001');
    perform api.run_bulk_skip_pending(
      (snapshot #>> '{run,id}')::uuid, (snapshot #>> '{run,currentStop,id}')::uuid,
      (snapshot #>> '{run,version}')::integer, 'Testgroep slaat deze gewone poort veilig samen over',
      'dynamic-skip-' || i, 'dynamic-skip-hash-' || i
    );
    perform api.run_complete_stop(
      (snapshot #>> '{run,id}')::uuid, (snapshot #>> '{run,currentStop,id}')::uuid,
      (snapshot #>> '{run,version}')::integer, true,
      'dynamic-complete-' || i, 'dynamic-complete-hash-' || i
    );
  end loop;
end $$;

set local role postgres;
select cmp_ok(
  (select count(*)::integer from app_private.run_stops where run_id = (select run_id from dynamic_state) and stop_kind = 'ordinary' and state = 'completed'),
  '>=', 7,
  'the continuous route proceeds beyond the former fixed six-stop ceiling'
);
select is(
  (select count(distinct portal_id)::integer from app_private.run_stops where run_id = (select run_id from dynamic_state) and stop_kind = 'ordinary'),
  (select count(*)::integer from app_private.run_stops where run_id = (select run_id from dynamic_state) and stop_kind = 'ordinary'),
  'the dispatcher never gives the same ordinary house to one group twice'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_redirect_group(
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,id}')::uuid,
    'finale', null,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,version}')::integer,
    'Organisatie beëindigt de gewone route veilig voor deze test'
  ) $$,
  'an audited organization action can send a group to the finale through the same reservation dispatcher'
);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,kind}',
  'finale',
  'the currently published destination is now the designated terminal portal'
);

set local role postgres;
update app_private.stop_participant_statuses status set
  status = 'skipped', version = version + 1, changed_by = 'f0000000-0000-0000-0000-000000000001',
  reason = 'test final cannot be skipped', decided_at = now()
where status.run_stop_id = (select current_stop_id from app_private.group_runs where id = (select run_id from dynamic_state));

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.run_complete_stop(
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,version}')::integer,
    true, 'finale-skip-denied', 'finale-skip-denied-hash'
  ) $$,
  '23514', 'FINAL_PORTAL_REQUIRED', 'the terminal finale cannot be completed as an all-skip stop'
);

set local role postgres;
update app_private.stop_participant_statuses status set
  status = 'pending', version = version + 1, changed_by = null, reason = null, decided_at = null
where status.run_stop_id = (select current_stop_id from app_private.group_runs where id = (select run_id from dynamic_state));

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_scan(
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,version}')::integer,
    'TEST-30', 'short_code'
  ) $$,
  'the designated finale credential confirms arrival at the final portal'
);
select lives_ok(
  $$ select api.run_update_participant(
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,participants,0,id}')::uuid,
    'visited',
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,version}')::integer,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,participants,0,statusVersion}')::integer,
    null
  ) $$,
  'the leader records the final show after the finale scan'
);
select lives_ok(
  $$ select api.run_complete_stop(
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,currentStop,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,version}')::integer,
    false, 'finale-complete', 'finale-complete-hash'
  ) $$,
  'completing the visited finale finishes the route'
);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{run,status}',
  'completed',
  'the group is complete only after the final portal is visited'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.run_stops where run_id = (select run_id from dynamic_state) and stop_kind = 'finale' and state = 'completed'),
  1,
  'a normal dynamic route has exactly one completed terminal finale stop'
);
select is(
  (select count(*)::integer from app_private.run_stops where run_id = (select run_id from dynamic_state) and stop_kind = 'ordinary' and portal_id = '12000000-0000-0000-0000-000000000030'),
  0,
  'the designated final portal is never selected as an ordinary house'
);
select is(
  (select count(*)::integer from app_private.portal_reservations where run_id = (select run_id from dynamic_state) and status in ('held', 'active')),
  0,
  'finishing the finale leaves no active capacity claim for the group'
);

select * from finish();
rollback;
