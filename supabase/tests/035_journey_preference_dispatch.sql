begin;
create extension if not exists pgtap with schema extensions;
create function pg_temp.rehearsal_short_code(stopid uuid) returns text language sql security definer set search_path='' as $$
 select 'TEST-'||right(coalesce(s.portal_id,p.portal_id)::text,2) from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=stopid
$$;
grant execute on function pg_temp.rehearsal_short_code(uuid) to authenticated;
select plan(6);
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
update app_private.start_slots set starts_at = date_bin(interval '10 minutes', now(), timestamptz '2000-01-01 00:00:00Z') - interval '10 minutes'
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
    now() + interval '3 hours', 'neutral', 'f0000000-0000-0000-0000-000000000001'
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

update app_private.group_schedule_revisions set state='published', published_at=now() where id=(select schedule_id from dynamic_state);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',(select group_version from dynamic_state),1)$$,'leader chooses one ordinary visit before start');
update dynamic_state set group_version=group_version+1;
update dynamic_state set run_id=(api.run_start('23000000-0000-0000-0000-000000000001',array[(select child_id from dynamic_state)],(select group_version from dynamic_state),'pref-start','pref-start')->>'runId')::uuid;
select throws_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,version}')::integer,5)$$,
'23514','JOURNEY_ALREADY_STARTED','live journey changes require organization support');
do $$ declare s jsonb; begin
s:=api.group_snapshot('23000000-0000-0000-0000-000000000001');
perform api.run_bulk_skip_pending((s#>>'{run,id}')::uuid,(s#>>'{run,currentStop,id}')::uuid,(s#>>'{run,version}')::integer,'Test veilig samen overslaan','pref-skip','pref-skip');
perform api.run_scan((s#>>'{run,id}')::uuid,(s#>>'{run,currentStop,id}')::uuid,(s#>>'{run,version}')::integer,pg_temp.rehearsal_short_code((s#>>'{run,currentStop,id}')::uuid),'short_code');
perform api.run_complete_stop((s#>>'{run,id}')::uuid,(s#>>'{run,currentStop,id}')::uuid,(s#>>'{run,version}')::integer,true,'pref-skip-done','pref-skip-done');
end $$;
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,currentStop,kind}','finale','a physically reached house counts toward the visit limit even when every child stays outside');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from dynamic_state)),1,'the outside child has a real arrival fact for that first ordinary house');
set local role authenticated;
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,status}','live','reaching the chosen count does not finish the route before the show');
set local role postgres;
select is((select count(*)::integer from app_private.portal_reservations where run_id=(select run_id from dynamic_state) and kind='finale' and status='active'),1,'exactly one active finale reservation remains');
select * from finish();
rollback;
