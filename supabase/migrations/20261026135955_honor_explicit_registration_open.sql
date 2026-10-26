-- Opening a channel must take effect in both the public snapshot and submission.
-- Existing rows are repaired by the trusted release command after reconciliation,
-- only when their deadline matches the old generated 25 October default.
create or replace function api.admin_set_registration_channel(
  _event_slug text,
  _channel text,
  _open boolean,
  _expected_settings_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  setting_key text;
  previous_value boolean;
  previous_open_at timestamptz;
  previous_close_at timestamptz;
begin
  if _channel not in ('groups', 'portals')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or (_channel = 'groups' and app_private.has_capability(event_record.id, 'registration_manage', actor))
    or (_channel = 'portals' and app_private.has_capability(event_record.id, 'portals_manage', actor))
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.settings_version <> _expected_settings_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  setting_key := case when _channel = 'groups' then 'groupRegistrationOpen' else 'portalRegistrationOpen' end;
  previous_value := coalesce((event_record.settings ->> setting_key)::boolean, _channel = 'portals');
  previous_open_at := event_record.registration_open_at;
  previous_close_at := event_record.registration_close_at;
  update app_private.events
  set registration_open_at = case when _channel = 'groups' and _open and registration_open_at > now() then null else registration_open_at end,
      registration_close_at = case when _channel = 'groups' and _open and registration_close_at <= now() then null else registration_close_at end,
      settings = settings || jsonb_build_object(setting_key, _open),
      settings_version = settings_version + 1
  where id = event_record.id
  returning * into event_record;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    event_record.id,
    actor,
    'registration_channel.updated',
    'event',
    event_record.id,
    jsonb_build_object('channel', _channel, 'from', previous_value, 'to', _open, 'reason', left(trim(_reason), 500),
      'registrationWindow', jsonb_build_object(
        'previousOpenAt', previous_open_at, 'previousCloseAt', previous_close_at,
        'openAt', event_record.registration_open_at, 'closeAt', event_record.registration_close_at))
  );

  return jsonb_build_object(
    'settingsVersion', event_record.settings_version,
    'groupRegistrationOpen', coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false),
    'portalRegistrationOpen', coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, true)
  );
end;
$$;

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
  if event_record.settings ->> 'releaseMode' is distinct from _mode then
  update app_private.events
  set phase = case when _mode in ('staging_test_open', 'production_open') then 'registration_open'::app_private.event_phase else 'draft'::app_private.event_phase end,
      registration_open_at = case when _mode in ('staging_test_open', 'production_open') then now() - interval '1 minute' else null end,
      registration_close_at = null,
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
  elsif _mode in ('staging_test_open', 'production_open')
    and event_record.phase = 'registration_open'
    and coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false)
    and event_record.registration_close_at = make_timestamptz(extract(year from event_record.local_date)::integer, 10, 25, 23, 59, 0, event_record.timezone)
    and event_record.registration_close_at <= now()
    and event_record.local_date >= (now() at time zone event_record.timezone)::date then
    -- Repair only the legacy generated deadline on an explicitly open upcoming
    -- event. Custom deadlines, operator closures and completed events survive.
    update app_private.events
    set registration_close_at = null, settings_version = settings_version + 1
    where id = event_record.id returning * into event_record;
    insert into app_private.audit_events(event_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, 'registration_window.legacy_deadline_removed', 'event', event_record.id,
      jsonb_build_object('previousCloseAt', make_timestamptz(extract(year from event_record.local_date)::integer, 10, 25, 23, 59, 0, event_record.timezone),
        'closeAt', null, 'reason', 'Honor the open registration channel after the legacy automatic deadline'));
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


revoke all on function api.configure_release_mode(text,text) from public,anon,authenticated;
grant execute on function api.configure_release_mode(text,text) to service_role;
