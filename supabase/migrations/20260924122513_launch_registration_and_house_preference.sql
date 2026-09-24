-- Release opening is an explicit service-role action, never a side effect of migration.
create or replace function api.configure_release_mode(_event_slug text, _mode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare event_record app_private.events;
begin
  if _mode not in ('staging_test_open', 'production_closed', 'production_open') then raise exception 'INVALID_MODE' using errcode = '22023'; end if;
  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  -- Ordinary redeploys must preserve a later operator closure or event phase.
  if _mode <> 'production_open' or event_record.settings ->> 'releaseMode' is distinct from 'production_open' then
  update app_private.events
  set phase = case when _mode in ('staging_test_open', 'production_open') then 'registration_open'::app_private.event_phase else 'draft'::app_private.event_phase end,
      registration_open_at = case when _mode in ('staging_test_open', 'production_open') then now() - interval '1 minute' else null end,
      registration_close_at = case when _mode in ('staging_test_open', 'production_open') then make_timestamptz(extract(year from local_date)::integer, 10, 25, 23, 59, 0, timezone) else null end,
      settings = settings
        || jsonb_build_object('registrationPublished', _mode in ('staging_test_open', 'production_open'), 'releaseMode', _mode)
        || case when _mode in ('staging_test_open', 'production_open')
          then jsonb_build_object('groupRegistrationOpen', true, 'portalRegistrationOpen', case when _mode = 'staging_test_open' then true else coalesce((settings ->> 'portalRegistrationOpen')::boolean, true) end)
          else '{}'::jsonb
        end,
      settings_version = settings_version + 1
  where slug = _event_slug returning * into event_record;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into app_private.audit_events(event_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, 'release.mode_configured', 'event', event_record.id, jsonb_build_object('mode', _mode));
  end if;
  return jsonb_build_object(
    'releaseMode', event_record.settings ->> 'releaseMode',
    'phase', event_record.phase,
    'registrationPublished', event_record.settings -> 'registrationPublished',
    'groupRegistrationOpen', event_record.settings -> 'groupRegistrationOpen',
    'portalRegistrationOpen', event_record.settings -> 'portalRegistrationOpen'
  );
end;
$$;


alter table app_private.walking_groups add column desired_ordinary_visits integer
  check (desired_ordinary_visits between 1 and 1000);

create or replace function api.group_journey_preference(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare snapshot jsonb; g app_private.walking_groups;
begin
  -- Reuse the established group access check, without adding any address projection.
  snapshot := api.group_snapshot(_group_id);
  select * into g from app_private.walking_groups where id = _group_id;
  return jsonb_build_object('desiredOrdinaryVisits', g.desired_ordinary_visits, 'version', g.version,
    'supported', g.route_mode = 'dynamic',
    'canEdit', g.route_mode = 'dynamic' and app_private.is_current_leader(_group_id, auth.uid()) and not exists(
      select 1 from app_private.group_runs where group_id = _group_id));
end;
$$;

create or replace function api.group_journey_preference_save(_group_id uuid, _expected_version integer, _desired_ordinary_visits integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g app_private.walking_groups; actor uuid := auth.uid();
begin
  select * into g from app_private.walking_groups where id = _group_id for update;
  if actor is null or g.id is null or not app_private.is_current_leader(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if g.route_mode <> 'dynamic' then raise exception 'DYNAMIC_JOURNEY_REQUIRED' using errcode = '23514'; end if;
  if _expected_version is distinct from g.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if exists(select 1 from app_private.group_runs where group_id = _group_id) then
    raise exception 'JOURNEY_ALREADY_STARTED' using errcode = '23514';
  end if;
  if _desired_ordinary_visits is not null and _desired_ordinary_visits not between 1 and 1000 then
    raise exception 'INVALID_VISIT_PREFERENCE' using errcode = '22023';
  end if;
  update app_private.walking_groups set desired_ordinary_visits = _desired_ordinary_visits,
    version = version + 1, updated_at = now() where id = _group_id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values(g.event_id, actor, 'group.journey_preference_updated', 'walking_group', g.id,
    jsonb_build_object('desiredOrdinaryVisits', _desired_ordinary_visits));
  perform realtime.send(jsonb_build_object('resource', 'walking_group', 'id', g.id),
    'snapshot_changed', 'group:' || g.id::text, true);
  return api.group_journey_preference(_group_id);
end;
$$;

-- Keep the existing dispatcher and all reservation/time/safety checks. The optional
-- group preference only chooses the existing terminal branch after actual visits.
alter function app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid)
  rename to dispatch_next_stop_before_visit_preference;
create or replace function app_private.dispatch_next_stop(
  _run_id uuid, _decision_at timestamptz default clock_timestamp(),
  _force_finale boolean default false, _preferred_portal_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r app_private.group_runs; requested integer; visited integer; reached boolean := false;
begin
  select * into r from app_private.group_runs where id = _run_id for update;
  select desired_ordinary_visits into requested from app_private.walking_groups where id = r.group_id;
  if requested is not null then
    select count(*) into visited from app_private.run_stops where run_id = _run_id
      and stop_kind = 'ordinary' and state = 'completed' and outcome in ('visited', 'mixed');
    reached := visited >= requested;
  end if;
  return app_private.dispatch_next_stop_before_visit_preference(
    _run_id, _decision_at, _force_finale or reached, case when reached then null else _preferred_portal_id end);
end;
$$;

revoke all on function api.group_journey_preference(uuid) from public, anon, authenticated;
revoke all on function api.group_journey_preference_save(uuid,integer,integer) from public, anon, authenticated;
grant execute on function api.group_journey_preference(uuid) to authenticated;
grant execute on function api.group_journey_preference_save(uuid,integer,integer) to authenticated;
revoke all on function app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid) from public, anon, authenticated;
revoke all on function app_private.dispatch_next_stop_before_visit_preference(uuid,timestamptz,boolean,uuid) from public, anon, authenticated;
revoke all on function api.configure_release_mode(text,text) from public, anon, authenticated;
grant execute on function api.configure_release_mode(text,text) to service_role;

-- Store the approved evening hours, leaving route activation/location approval to
-- the existing organizer workflow. No house or finale is implicitly published.
update app_private.event_route_settings r set
  first_start_at = (e.local_date + time '17:00') at time zone e.timezone,
  global_ordinary_stop_at = (e.local_date + time '20:30') at time zone e.timezone,
  finale_closes_at = (e.local_date + time '21:00') at time zone e.timezone,
  finale_last_arrival_at = least(coalesce(r.finale_last_arrival_at, 'infinity'::timestamptz),
    ((e.local_date + time '21:00') at time zone e.timezone) - make_interval(secs => r.finale_show_seconds + r.finale_turnover_seconds)),
  version = r.version + 1
from app_private.events e where e.id = r.event_id and e.slug = 'duindorp-halloween-2026';
