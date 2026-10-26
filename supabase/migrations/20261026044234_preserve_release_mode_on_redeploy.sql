-- A redeploy of the same mode must not reopen registration or move its dates.
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
  if event_record.settings ->> 'releaseMode' is distinct from _mode then
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


revoke all on function api.configure_release_mode(text,text) from public,anon,authenticated;
grant execute on function api.configure_release_mode(text,text) to service_role;
