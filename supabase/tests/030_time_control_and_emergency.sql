begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

create temporary table timed_state(
  group_id uuid primary key,
  child_ids uuid[],
  group_version integer,
  run_id uuid,
  short_code text
) on commit drop;
insert into timed_state(group_id, child_ids, group_version)
select walking_group.id, array_agg(registration_child.id order by registration_child.id), walking_group.version
from app_private.walking_groups walking_group
join app_private.group_registrations assignment on assignment.group_id = walking_group.id and assignment.superseded_at is null
join app_private.registration_children registration_child on registration_child.registration_id = assignment.registration_id
where walking_group.id in (
  '23000000-0000-0000-0000-000000000002',
  '23000000-0000-0000-0000-000000000003',
  '23000000-0000-0000-0000-000000000004'
)
group by walking_group.id, walking_group.version;
grant select, update on timed_state to authenticated;

update app_private.portal_windows set opens_at = now() - interval '1 hour', closes_at = now() + interval '5 hours'
where portal_id in (select id from app_private.portals where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026'));
update app_private.start_slots set starts_at = now() - interval '2 minutes'
where id = '20000000-0000-0000-0000-000000000001';
update app_private.event_route_settings set
  first_start_at = now() - interval '1 hour', global_ordinary_stop_at = now() + interval '2 hours',
  ordinary_visit_seconds = 60, route_buffer_seconds = 0,
  final_portal_id = '12000000-0000-0000-0000-000000000030',
  finale_opens_at = now() - interval '10 minutes', finale_last_arrival_at = now() + interval '4 hours',
  finale_closes_at = now() + interval '5 hours', finale_show_seconds = 60, finale_turnover_seconds = 0,
  finale_max_concurrent_groups = 10, finale_max_concurrent_children = 100,
  emergency_destination_name = 'Fictieve veilige verzamelplek',
  emergency_instructions = 'Blijf bij de verantwoordelijke volwassene en meld je bij de organisatie.',
  finale_available = true, planner_mode = 'dynamic'
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');

insert into app_private.group_schedule_revisions(
  group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
  expected_finale_arrival_at, preference_match, created_by, published_at
)
select state.group_id, 1, 'published', '20000000-0000-0000-0000-000000000001',
  now() + interval '2 hours', now() + interval '3 hours', 'neutral',
  'f0000000-0000-0000-0000-000000000001', now()
from timed_state state;
update app_private.walking_groups walking_group set route_mode = 'dynamic', status = 'ready',
  current_schedule_revision_id = schedule.id, version = walking_group.version + 1
from app_private.group_schedule_revisions schedule
where schedule.group_id = walking_group.id and schedule.state = 'published'
  and walking_group.id in (select group_id from timed_state);
update timed_state state set group_version = walking_group.version
from app_private.walking_groups walking_group where walking_group.id = state.group_id;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update timed_state set run_id = (api.run_start(
    group_id, child_ids[1:1], group_version,
    'timed-start-' || group_id::text, 'timed-start-hash-' || group_id::text
  ) ->> 'runId')::uuid where group_id = '23000000-0000-0000-0000-000000000002' $$,
  'the first timed-control group starts with one ordinary destination'
);
select lives_ok(
  $$ update timed_state set run_id = (api.run_start(
    group_id, child_ids[1:1], group_version,
    'timed-start-' || group_id::text, 'timed-start-hash-' || group_id::text
  ) ->> 'runId')::uuid where group_id = '23000000-0000-0000-0000-000000000003' $$,
  'a second simultaneous group receives another capacity-safe destination'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.run_stops where run_id in (select run_id from timed_state where run_id is not null) and stop_kind = 'ordinary' and state = 'active'),
  2,
  'both groups have exactly one active ordinary reservation'
);
update app_private.group_schedule_revisions set effective_ordinary_stop_at = now() - interval '1 minute'
where group_id = '23000000-0000-0000-0000-000000000002' and state = 'published';

set local role service_role;
select lives_ok(
  $$ select api.worker_dispatch_due_groups('duindorp-halloween-2026', 50) $$,
  'the minute worker evaluates a group even without a recent scan'
);

set local role postgres;
select is(
  (select stop_kind::text from app_private.run_stops stop
    join app_private.group_runs run on run.current_stop_id = stop.id
    where run.id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000002')),
  'finale',
  'after the stop boundary an unscanned ordinary assignment is replaced by the terminal portal'
);
select is(
  (select outcome::text from app_private.run_stops
    where run_id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000002')
      and stop_kind = 'ordinary' order by sequence desc limit 1),
  'system_skipped',
  'the timed redirect records why the unconfirmed ordinary stop was not visited'
);

update app_private.portal_reservations
set created_at = now() - interval '2 hours', expires_at = now() - interval '1 minute'
where run_id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000003')
  and kind = 'ordinary' and status = 'active';

set local role service_role;
select lives_ok(
  $$ select api.worker_dispatch_due_groups('duindorp-halloween-2026', 50) $$,
  'the minute worker replans an expired unscanned ordinary reservation'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.run_stops
    where run_id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000003')
      and stop_kind = 'ordinary' and state = 'completed' and outcome = 'system_skipped'),
  1,
  'the expired destination is retained in history as a safe system skip'
);
select is(
  (select stop_kind::text from app_private.run_stops stop
    join app_private.group_runs run on run.current_stop_id = stop.id
    where run.id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000003')),
  'ordinary',
  'an expired destination is replaced by one current capacity-safe ordinary destination'
);

update timed_state state set short_code = 'TEST-' || right(portal.name, 2)
from app_private.group_runs run
join app_private.run_stops stop on stop.id = run.current_stop_id
join app_private.portals portal on portal.id = stop.portal_id
where state.run_id = run.id and state.group_id = '23000000-0000-0000-0000-000000000003';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.run_scan(
    (api.group_snapshot('23000000-0000-0000-0000-000000000003') #>> '{run,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000003') #>> '{run,currentStop,id}')::uuid,
    (api.group_snapshot('23000000-0000-0000-0000-000000000003') #>> '{run,version}')::integer,
    (select short_code from timed_state where group_id = '23000000-0000-0000-0000-000000000003'), 'short_code'
  ) $$,
  'a physical scan distinguishes a visit that is actually in progress'
);

set local role postgres;
update app_private.group_schedule_revisions set effective_ordinary_stop_at = now() - interval '1 minute'
where group_id = '23000000-0000-0000-0000-000000000003' and state = 'published';

set local role service_role;
select lives_ok(
  $$ select api.worker_dispatch_due_groups('duindorp-halloween-2026', 50) $$,
  'the worker also evaluates a scanned visit at the boundary'
);

set local role postgres;
select is(
  (select stop_kind::text from app_private.run_stops stop
    join app_private.group_runs run on run.current_stop_id = stop.id
    where run.id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000003')),
  'ordinary',
  'a truly active visit is not interrupted when the stop boundary passes'
);
select is(
  (select count(*)::integer from app_private.route_alerts
    where run_id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000003')
      and code = 'ACTIVE_VISIT_AFTER_STOP' and status = 'open'),
  1,
  'the leader and organization receive one warning to finish the active visit safely'
);

set local role postgres;
update app_private.event_route_settings set finale_available = false
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update timed_state set run_id = (api.run_start(
    group_id, child_ids[1:1], group_version,
    'timed-start-' || group_id::text, 'timed-start-hash-' || group_id::text
  ) ->> 'runId')::uuid where group_id = '23000000-0000-0000-0000-000000000004' $$,
  'a start attempt with an unavailable finale is retained for safe organization handling'
);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000004') #>> '{run,status}',
  'paused',
  'the dispatcher pauses instead of publishing an ordinary or unsafe emergency address'
);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000004') -> 'run' -> 'currentStop',
  'null'::jsonb,
  'no destination is automatically exposed while the final portal is unavailable'
);
set local role postgres;
select is(
  (select count(*)::integer from app_private.route_alerts
    where run_id = (select run_id from timed_state where group_id = '23000000-0000-0000-0000-000000000004')
      and code = 'FINALE_UNAVAILABLE' and status = 'open'),
  1,
  'the unavailable finale creates an urgent organization alert'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_activate_emergency_closure(
    'duindorp-halloween-2026', 'Laatste poort is tijdens de proefavond veilig uit bedrijf genomen'
  ) $$,
  'only the organization activates the preconfigured emergency closure'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.group_runs where id in (select run_id from timed_state) and status = 'stopped'),
  3,
  'the emergency closure stops each affected dynamic run and cancels further routing'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select matches(
  api.group_snapshot('23000000-0000-0000-0000-000000000004') #>> '{run,emergencyInstruction}',
  '^Noodafsluiting: ga samen naar Fictieve veilige verzamelplek\.',
  'affected groups receive only the organization-approved safe destination instruction'
);

select * from finish();
rollback;
