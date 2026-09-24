-- Copy the exact, soft schedule preferences collected in the registration
-- wizard. The confirmed group schedule remains a separate organizer decision.
create or replace function app_private.copy_registration_exact_preferences_from_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft jsonb;
  preferred_start timestamptz;
  desired_end timestamptz;
  settings app_private.event_route_settings;
begin
  select payload into draft from app_private.registration_drafts
  where event_id = new.event_id and household_id = new.household_id;
  if nullif(trim(coalesce(draft ->> 'desiredEndAt', '')), '') is null then return new; end if;
  begin
    desired_end := (draft ->> 'desiredEndAt')::timestamptz;
    preferred_start := case when nullif(trim(coalesce(draft ->> 'preferredStartAt', '')), '') is null
      then null else (draft ->> 'preferredStartAt')::timestamptz end;
  exception when others then
    raise exception 'INVALID_EXACT_PREFERENCES' using errcode = '22023';
  end;
  perform app_private.validate_exact_preferences(new.event_id, preferred_start, desired_end);
  select * into settings from app_private.event_route_settings where event_id = new.event_id;
  new.preferred_start_at := preferred_start;
  new.desired_end_at := desired_end;
  new.requested_ordinary_stop_at := least(desired_end, settings.global_ordinary_stop_at);
  return new;
end;
$$;

create trigger registrations_copy_exact_preferences
before insert on app_private.registrations
for each row execute function app_private.copy_registration_exact_preferences_from_draft();

revoke execute on function app_private.copy_registration_exact_preferences_from_draft() from public, anon, authenticated;
