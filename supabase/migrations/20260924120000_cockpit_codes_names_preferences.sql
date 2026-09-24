-- Stable event-scoped identities, editable group names, exact schedule preferences,
-- and organizer-only portal contact operations.

create table app_private.event_identity_counters (
  event_id uuid not null references app_private.events(id) on delete cascade,
  entity_kind text not null check (entity_kind in ('portal', 'group')),
  last_value integer not null default 0 check (last_value >= 0),
  updated_at timestamptz not null default now(),
  primary key (event_id, entity_kind)
);

alter table app_private.event_identity_counters enable row level security;
revoke all on table app_private.event_identity_counters from public, anon, authenticated;

alter table app_private.portal_applications
  add column system_number integer,
  add column system_code text;

alter table app_private.portals
  add column system_number integer,
  add column system_code text;

alter table app_private.walking_groups
  add column system_number integer,
  add column system_code text,
  add column display_name text;

with numbered as (
  select id, row_number() over (partition by event_id order by created_at, id)::integer as value
  from app_private.portal_applications
)
update app_private.portal_applications application
set system_number = numbered.value,
    system_code = 'P-' || lpad(numbered.value::text, 2, '0')
from numbered where numbered.id = application.id;

update app_private.portals portal
set system_number = application.system_number,
    system_code = application.system_code
from app_private.portal_applications application
where application.id = portal.application_id;

with numbered as (
  select id, row_number() over (partition by event_id order by created_at, id)::integer as value
  from app_private.walking_groups
)
update app_private.walking_groups walking_group
set system_number = numbered.value,
    system_code = 'G-' || lpad(numbered.value::text, 2, '0')
from numbered where numbered.id = walking_group.id;

-- The legacy code column was already a public label, never a credential. Keep it
-- as a compatibility alias for the new stable code so older projections cannot
-- accidentally show a different identifier. The temporary value avoids unique
-- constraint collisions during a mixed-format backfill.
update app_private.walking_groups set code = 'identity-migration-' || id::text;
update app_private.walking_groups set code = system_code;

insert into app_private.event_identity_counters(event_id, entity_kind, last_value)
select event_id, 'portal', max(system_number) from app_private.portal_applications group by event_id
union all
select event_id, 'group', max(system_number) from app_private.walking_groups group by event_id
on conflict (event_id, entity_kind) do update
set last_value = greatest(app_private.event_identity_counters.last_value, excluded.last_value),
    updated_at = now();

alter table app_private.portal_applications
  alter column system_number set not null,
  alter column system_code set not null,
  add constraint portal_applications_system_number_positive check (system_number > 0),
  add constraint portal_applications_system_code_format check (system_code ~ '^P-[0-9]{2,}$'),
  add constraint portal_applications_event_system_number_unique unique (event_id, system_number),
  add constraint portal_applications_event_system_code_unique unique (event_id, system_code);

alter table app_private.portals
  alter column system_number set not null,
  alter column system_code set not null,
  add constraint portals_system_number_positive check (system_number > 0),
  add constraint portals_system_code_format check (system_code ~ '^P-[0-9]{2,}$'),
  add constraint portals_event_system_number_unique unique (event_id, system_number),
  add constraint portals_event_system_code_unique unique (event_id, system_code);

alter table app_private.walking_groups
  alter column system_number set not null,
  alter column system_code set not null,
  add constraint walking_groups_system_number_positive check (system_number > 0),
  add constraint walking_groups_system_code_format check (system_code ~ '^G-[0-9]{2,}$'),
  add constraint walking_groups_display_name_length check (display_name is null or char_length(display_name) between 2 and 80),
  add constraint walking_groups_event_system_number_unique unique (event_id, system_number),
  add constraint walking_groups_event_system_code_unique unique (event_id, system_code);

create or replace function app_private.next_event_identity_number(_event_id uuid, _entity_kind text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare next_value integer;
begin
  if _entity_kind not in ('portal', 'group') then
    raise exception 'INVALID_IDENTITY_KIND' using errcode = '22023';
  end if;
  insert into app_private.event_identity_counters(event_id, entity_kind, last_value, updated_at)
  values (_event_id, _entity_kind, 1, now())
  on conflict (event_id, entity_kind) do update
  set last_value = app_private.event_identity_counters.last_value + 1,
      updated_at = now()
  returning last_value into next_value;
  return next_value;
end;
$$;

create or replace function app_private.assign_portal_application_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.system_number is null then
    new.system_number := app_private.next_event_identity_number(new.event_id, 'portal');
  end if;
  new.system_code := 'P-' || lpad(new.system_number::text, 2, '0');
  return new;
end;
$$;

create or replace function app_private.assign_portal_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare application app_private.portal_applications;
begin
  if new.application_id is not null then
    select * into application from app_private.portal_applications where id = new.application_id;
  end if;
  if application.id is not null then
    if application.event_id <> new.event_id then
      raise exception 'PORTAL_APPLICATION_EVENT_MISMATCH' using errcode = '23514';
    end if;
    new.system_number := application.system_number;
    new.system_code := application.system_code;
  else
    if new.system_number is null then
      new.system_number := app_private.next_event_identity_number(new.event_id, 'portal');
    end if;
    new.system_code := 'P-' || lpad(new.system_number::text, 2, '0');
  end if;
  return new;
end;
$$;

create or replace function app_private.assign_group_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.system_number is null then
    new.system_number := app_private.next_event_identity_number(new.event_id, 'group');
  end if;
  new.system_code := 'G-' || lpad(new.system_number::text, 2, '0');
  new.code := new.system_code;
  return new;
end;
$$;

create or replace function app_private.prevent_system_identity_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.event_id is distinct from old.event_id
     or new.system_number is distinct from old.system_number
     or new.system_code is distinct from old.system_code then
    raise exception 'SYSTEM_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger portal_applications_assign_identity
before insert on app_private.portal_applications
for each row execute function app_private.assign_portal_application_identity();
create trigger portals_assign_identity
before insert on app_private.portals
for each row execute function app_private.assign_portal_identity();
create trigger walking_groups_assign_identity
before insert on app_private.walking_groups
for each row execute function app_private.assign_group_identity();

create trigger portal_applications_identity_immutable
before update on app_private.portal_applications
for each row execute function app_private.prevent_system_identity_change();
create trigger portals_identity_immutable
before update on app_private.portals
for each row execute function app_private.prevent_system_identity_change();
create trigger walking_groups_identity_immutable
before update on app_private.walking_groups
for each row execute function app_private.prevent_system_identity_change();

revoke execute on function app_private.next_event_identity_number(uuid, text) from public, anon, authenticated;
revoke execute on function app_private.assign_portal_application_identity() from public, anon, authenticated;
revoke execute on function app_private.assign_portal_identity() from public, anon, authenticated;
revoke execute on function app_private.assign_group_identity() from public, anon, authenticated;
revoke execute on function app_private.prevent_system_identity_change() from public, anon, authenticated;

create or replace function api.group_name_update(
  _group_id uuid,
  _expected_version integer,
  _display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  normalized_name text;
begin
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if actor is null or group_record.id is null or not (
    app_private.is_current_leader(_group_id, actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor)
    or app_private.has_capability(group_record.event_id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if group_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  normalized_name := nullif(regexp_replace(trim(coalesce(_display_name, '')), '[[:space:]]+', ' ', 'g'), '');
  if normalized_name is not null and (
    char_length(normalized_name) not between 2 and 80
    or normalized_name ~ '[[:cntrl:]]'
    or normalized_name ~ U&'[\200B\200C\200D\2060\FEFF]'
  ) then raise exception 'INVALID_GROUP_NAME' using errcode = '22023'; end if;
  update app_private.walking_groups
  set display_name = normalized_name, version = version + 1, updated_at = now()
  where id = _group_id returning * into group_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.name_updated', 'walking_group', group_record.id,
    jsonb_build_object('systemCode', group_record.system_code, 'displayName', group_record.display_name));
  perform realtime.send(
    jsonb_build_object('resource', 'walking_group', 'id', group_record.id, 'version', group_record.version),
    'snapshot_changed', 'group:' || group_record.id::text, true
  );
  return jsonb_build_object(
    'groupId', group_record.id, 'systemCode', group_record.system_code,
    'displayName', group_record.display_name, 'version', group_record.version
  );
end;
$$;

alter table app_private.registrations
  add column preferred_start_at timestamptz,
  add column desired_end_at timestamptz,
  add constraint registrations_exact_preferences_order check (
    preferred_start_at is null or desired_end_at is null or preferred_start_at < desired_end_at
  );

alter table app_private.event_route_settings
  add column preferred_start_min_local time not null default time '17:00',
  add column preferred_start_max_local time not null default time '19:30',
  add column preferred_start_step_minutes integer not null default 30,
  add column desired_end_min_local time not null default time '18:00',
  add column desired_end_max_local time not null default time '21:00',
  add column desired_end_step_minutes integer not null default 15,
  add constraint event_route_settings_start_local_range check (preferred_start_min_local <= preferred_start_max_local),
  add constraint event_route_settings_end_local_range check (desired_end_min_local <= desired_end_max_local),
  add constraint event_route_settings_start_step check (preferred_start_step_minutes between 5 and 120),
  add constraint event_route_settings_end_step check (desired_end_step_minutes between 5 and 120);

create or replace function app_private.exact_preference_options(_event_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'allowedStartTimes', coalesce((
      select jsonb_agg(to_jsonb(slot at time zone event.timezone) order by slot)
      from generate_series(
        event.local_date + settings.preferred_start_min_local,
        event.local_date + settings.preferred_start_max_local,
        make_interval(mins => settings.preferred_start_step_minutes)
      ) slot
    ), '[]'::jsonb),
    'allowedEndTimes', coalesce((
      select jsonb_agg(to_jsonb(slot at time zone event.timezone) order by slot)
      from generate_series(
        event.local_date + settings.desired_end_min_local,
        event.local_date + settings.desired_end_max_local,
        make_interval(mins => settings.desired_end_step_minutes)
      ) slot
    ), '[]'::jsonb)
  )
  from app_private.events event
  join app_private.event_route_settings settings on settings.event_id = event.id
  where event.id = _event_id
$$;

create or replace function app_private.validate_exact_preferences(
  _event_id uuid,
  _preferred_start_at timestamptz,
  _desired_end_at timestamptz
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  event_record app_private.events;
  settings app_private.event_route_settings;
  local_start timestamp;
  local_end timestamp;
begin
  select * into event_record from app_private.events where id = _event_id;
  select * into settings from app_private.event_route_settings where event_id = _event_id;
  if event_record.id is null or settings.event_id is null or _desired_end_at is null then
    raise exception 'INVALID_EXACT_PREFERENCES' using errcode = '22023';
  end if;
  local_end := _desired_end_at at time zone event_record.timezone;
  if local_end::date <> event_record.local_date
     or local_end::time < settings.desired_end_min_local
     or local_end::time > settings.desired_end_max_local
     or extract(second from local_end) <> 0
     or mod((extract(epoch from (local_end::time - settings.desired_end_min_local)) / 60)::integer,
            settings.desired_end_step_minutes) <> 0 then
    raise exception 'INVALID_DESIRED_END_AT' using errcode = '22023';
  end if;
  if _preferred_start_at is not null then
    local_start := _preferred_start_at at time zone event_record.timezone;
    if local_start::date <> event_record.local_date
       or local_start::time < settings.preferred_start_min_local
       or local_start::time > settings.preferred_start_max_local
       or extract(second from local_start) <> 0
       or mod((extract(epoch from (local_start::time - settings.preferred_start_min_local)) / 60)::integer,
              settings.preferred_start_step_minutes) <> 0
       or _preferred_start_at >= _desired_end_at then
      raise exception 'INVALID_PREFERRED_START_AT' using errcode = '22023';
    end if;
  end if;
end;
$$;

create or replace function api.registration_exact_preferences_save(
  _registration_id uuid,
  _preferred_start_at timestamptz,
  _desired_end_at timestamptz,
  _expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  settings app_private.event_route_settings;
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if actor is null or registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if registration.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if registration.preference_change_status <> 'editable' or exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
    where assignment.registration_id = registration.id and assignment.superseded_at is null
  ) then raise exception 'PREFERENCES_LOCKED' using errcode = '23514'; end if;
  perform app_private.validate_exact_preferences(registration.event_id, _preferred_start_at, _desired_end_at);
  select * into settings from app_private.event_route_settings where event_id = registration.event_id;
  update app_private.registrations
  set preferred_start_at = _preferred_start_at,
      desired_end_at = _desired_end_at,
      requested_ordinary_stop_at = least(_desired_end_at, settings.global_ordinary_stop_at),
      version = version + 1,
      updated_at = now()
  where id = registration.id returning * into registration;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.exact_preferences_updated', 'registration', registration.id,
    jsonb_build_object('preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at));
  return jsonb_build_object(
    'registrationId', registration.id, 'preferredStartAt', registration.preferred_start_at,
    'desiredEndAt', registration.desired_end_at, 'ordinaryStopAt', registration.requested_ordinary_stop_at,
    'version', registration.version, 'editable', true
  );
end;
$$;

create or replace function api.registration_exact_preferences_request_change(
  _registration_id uuid,
  _preferred_start_at timestamptz,
  _desired_end_at timestamptz,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if actor is null or registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  perform app_private.validate_exact_preferences(registration.event_id, _preferred_start_at, _desired_end_at);
  if exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule
      on schedule.group_id = assignment.group_id and schedule.state = 'published'
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    where assignment.registration_id = registration.id and assignment.superseded_at is null
      and _desired_end_at <= slot.starts_at
  ) then raise exception 'DESIRED_END_NOT_AFTER_CONFIRMED_START' using errcode = '22023'; end if;
  update app_private.registrations
  set preference_change_status = 'change_requested', version = version + 1, updated_at = now()
  where id = registration.id returning * into registration;
  insert into app_private.support_cases(event_id, category, reporter, safe_description)
  values (registration.event_id, 'schedule_preference_change', actor,
    left('Exacte gewenste start: ' || coalesce(_preferred_start_at::text, 'geen voorkeur') ||
      '; gewenste eindtijd: ' || _desired_end_at::text || '; ' || trim(_reason), 1000));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.exact_preference_change_requested', 'registration', registration.id,
    jsonb_build_object('preferredStartAt', _preferred_start_at, 'desiredEndAt', _desired_end_at));
  return jsonb_build_object('requested', true, 'changeStatus', registration.preference_change_status, 'version', registration.version);
end;
$$;

create or replace function app_private.validate_group_schedule_exact_preferences()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare starts_at timestamptz;
begin
  select slot.starts_at into starts_at from app_private.start_slots slot where slot.id = new.start_slot_id;
  if exists (
    select 1 from app_private.group_registrations assignment
    join app_private.registrations registration on registration.id = assignment.registration_id
    where assignment.group_id = new.group_id and assignment.superseded_at is null
      and registration.desired_end_at is not null and starts_at >= registration.desired_end_at
  ) then raise exception 'GROUP_START_NOT_BEFORE_DESIRED_END' using errcode = '23514'; end if;
  return new;
end;
$$;

create trigger group_schedule_exact_preferences_guard
before insert or update of start_slot_id, group_id on app_private.group_schedule_revisions
for each row execute function app_private.validate_group_schedule_exact_preferences();

revoke execute on function app_private.exact_preference_options(uuid) from public, anon, authenticated;
revoke execute on function app_private.validate_exact_preferences(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function app_private.validate_group_schedule_exact_preferences() from public, anon, authenticated;

-- Preserve existing authorization and behavior and enrich the snapshot contracts.
alter function api.registration_preferences_snapshot(text) set schema app_private;
alter function app_private.registration_preferences_snapshot(text) rename to registration_preferences_snapshot_before_codes;
revoke execute on function app_private.registration_preferences_snapshot_before_codes(text) from public, anon, authenticated;

create or replace function api.registration_preferences_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; event_record app_private.events; registration app_private.registrations; options jsonb;
begin
  result := app_private.registration_preferences_snapshot_before_codes(_event_slug);
  select * into event_record from app_private.events where slug = _event_slug;
  if result ->> 'registrationId' is not null then
    select * into registration from app_private.registrations where id = (result ->> 'registrationId')::uuid;
  end if;
  options := coalesce(app_private.exact_preference_options(event_record.id),
    jsonb_build_object('allowedStartTimes', '[]'::jsonb, 'allowedEndTimes', '[]'::jsonb));
  result := result || jsonb_build_object('preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at);
  return jsonb_set(result, '{event}', coalesce(result -> 'event', '{}'::jsonb) || options, true);
end;
$$;

alter function api.group_snapshot(uuid) set schema app_private;
alter function app_private.group_snapshot(uuid) rename to group_snapshot_before_codes;
revoke execute on function app_private.group_snapshot_before_codes(uuid) from public, anon, authenticated;

create or replace function api.group_snapshot(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; group_record app_private.walking_groups;
begin
  result := app_private.group_snapshot_before_codes(_group_id);
  select * into group_record from app_private.walking_groups where id = _group_id;
  return jsonb_set(result, '{group}', coalesce(result -> 'group', '{}'::jsonb) || jsonb_build_object(
    'code', group_record.system_code, 'systemCode', group_record.system_code, 'displayName', group_record.display_name
  ), true);
end;
$$;

alter function api.group_viewer_snapshot(uuid) set schema app_private;
alter function app_private.group_viewer_snapshot(uuid) rename to group_viewer_snapshot_before_codes;
revoke execute on function app_private.group_viewer_snapshot_before_codes(uuid) from public, anon, authenticated;

create or replace function api.group_viewer_snapshot(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; group_record app_private.walking_groups;
begin
  result := app_private.group_viewer_snapshot_before_codes(_group_id);
  select * into group_record from app_private.walking_groups where id = _group_id;
  result := jsonb_set(result, '{group}', coalesce(result -> 'group', '{}'::jsonb) || jsonb_build_object(
    'code', group_record.system_code, 'systemCode', group_record.system_code, 'displayName', group_record.display_name
  ), true);
  return result || jsonb_build_object(
    'groupCode', group_record.system_code, 'systemCode', group_record.system_code, 'displayName', group_record.display_name
  );
end;
$$;

alter function api.portal_snapshot(text) set schema app_private;
alter function app_private.portal_snapshot(text) rename to portal_snapshot_before_codes;
revoke execute on function app_private.portal_snapshot_before_codes(text) from public, anon, authenticated;

create or replace function api.portal_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; application app_private.portal_applications; portal app_private.portals;
begin
  result := app_private.portal_snapshot_before_codes(_event_slug);
  if result is null then return null; end if;
  if result #>> '{application,id}' is not null then
    select * into application from app_private.portal_applications where id = (result #>> '{application,id}')::uuid;
  end if;
  result := jsonb_set(result, '{application}', coalesce(result -> 'application', '{}'::jsonb) || jsonb_build_object(
    'code', application.system_code, 'systemCode', application.system_code
  ), true);
  if result #>> '{portal,id}' is not null then
    select * into portal from app_private.portals where id = (result #>> '{portal,id}')::uuid;
    result := jsonb_set(result, '{portal}', coalesce(result -> 'portal', '{}'::jsonb) || jsonb_build_object(
      'code', portal.system_code, 'systemCode', portal.system_code
    ), true);
  end if;
  return result;
end;
$$;

alter function api.admin_route_configuration_snapshot(text) set schema app_private;
alter function app_private.admin_route_configuration_snapshot(text) rename to admin_route_configuration_snapshot_before_codes;
revoke execute on function app_private.admin_route_configuration_snapshot_before_codes(text) from public, anon, authenticated;

create or replace function api.admin_route_configuration_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; event_id uuid; options jsonb; enriched jsonb;
begin
  result := app_private.admin_route_configuration_snapshot_before_codes(_event_slug);
  select id into event_id from app_private.events where slug = _event_slug;
  options := coalesce(app_private.exact_preference_options(event_id), '{}'::jsonb);
  result := jsonb_set(result, '{settings}', coalesce(result -> 'settings', '{}'::jsonb) || options, true);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'code', portal.system_code, 'systemCode', portal.system_code
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'portals', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.portals portal on portal.id = (item ->> 'id')::uuid;
  result := jsonb_set(result, '{portals}', enriched, true);
  select coalesce(jsonb_agg(
    jsonb_set(item || jsonb_build_object(
      'code', walking_group.system_code, 'systemCode', walking_group.system_code, 'displayName', walking_group.display_name
    ), '{registrations}', coalesce((
      select jsonb_agg(registration_item || jsonb_build_object(
        'preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at
      ) order by registration_ordinal)
      from jsonb_array_elements(coalesce(item -> 'registrations', '[]'::jsonb))
        with ordinality registration_entries(registration_item, registration_ordinal)
      left join app_private.registrations registration on registration.id = (registration_item ->> 'id')::uuid
    ), '[]'::jsonb), true) order by ordinal
  ), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'groups', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.walking_groups walking_group on walking_group.id = (item ->> 'id')::uuid;
  result := jsonb_set(result, '{groups}', enriched, true);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'unassigned', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.registrations registration on registration.id = (item ->> 'id')::uuid;
  return jsonb_set(result, '{unassigned}', enriched, true);
end;
$$;

alter function api.admin_evening_cockpit(text) set schema app_private;
alter function app_private.admin_evening_cockpit(text) rename to admin_evening_cockpit_before_codes;
revoke execute on function app_private.admin_evening_cockpit_before_codes(text) from public, anon, authenticated;

create or replace function api.admin_evening_cockpit(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; enriched jsonb;
begin
  result := app_private.admin_evening_cockpit_before_codes(_event_slug);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'groupCode', walking_group.system_code, 'systemCode', walking_group.system_code, 'displayName', walking_group.display_name
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'groups', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.walking_groups walking_group on walking_group.id = (item ->> 'groupId')::uuid;
  result := jsonb_set(result, '{groups}', enriched, true);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'code', portal.system_code, 'systemCode', portal.system_code
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'portals', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.portals portal on portal.id = (item ->> 'id')::uuid;
  return jsonb_set(result, '{portals}', enriched, true);
end;
$$;

create or replace function api.admin_portal_operations_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'portals_manage', actor)
    or app_private.has_capability(event_record.id, 'live_support', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object('eventId', event_record.id, 'portals', coalesce((
    select jsonb_agg(jsonb_build_object(
      'portalId', portal.id, 'applicationId', application.id,
      'code', portal.system_code, 'systemCode', portal.system_code, 'name', portal.name,
      'operationStatus', portal.operation_status, 'approvalStatus', portal.approval_status,
      'contactName', nullif(trim(application.private_draft_data ->> 'contactName'), ''),
      'phone', nullif(trim(application.private_draft_data ->> 'phone'), ''), 'email', applicant.email,
      'address', jsonb_build_object(
        'street', location.street, 'houseNumber', location.house_number, 'addition', location.addition,
        'postalCode', location.postal_code, 'city', location.city
      ),
      'formattedAddress', concat_ws(' ', location.street, location.house_number, location.addition)
        || ', ' || location.postal_code || ' ' || location.city,
      'messageTarget', jsonb_build_object(
        'kind', 'portal', 'portalId', portal.id, 'userId', application.applicant_user_id,
        'label', portal.system_code || ' · ' || portal.name
      ),
      'activeReservations', (select count(*) from app_private.portal_reservations reservation
        where reservation.portal_id = portal.id and reservation.status in ('held', 'active')),
      'expectedChildren', (select coalesce(sum(reservation.child_count), 0) from app_private.portal_reservations reservation
        where reservation.portal_id = portal.id and reservation.status in ('held', 'active'))
    ) order by portal.system_number)
    from app_private.portals portal
    left join app_private.portal_applications application on application.id = portal.application_id
    left join auth.users applicant on applicant.id = application.applicant_user_id
    join app_private.portal_private_locations location on location.portal_id = portal.id
    where portal.event_id = event_record.id and portal.approval_status = 'approved'
  ), '[]'::jsonb));
end;
$$;

create or replace function api.portal_arrivals_snapshot(_portal_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid(); portal_record app_private.portals;
begin
  select * into portal_record from app_private.portals where id = _portal_id;
  if actor is null or portal_record.id is null or not (
    exists (select 1 from app_private.portal_owners owner
      where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null)
    or app_private.has_capability(portal_record.event_id, 'portals_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return (
    with raw_arrivals as (
      select walking_group.id as group_id, walking_group.system_code as group_code, walking_group.display_name,
        stop.planned_arrival_at, stop.planned_departure_at,
        coalesce(run_stop.state::text, 'planned') as state, 'assigned'::text as classification
      from app_private.route_plan_stops stop
      join app_private.route_plan_versions plan on plan.id = stop.plan_version_id and plan.state = 'published'
      join app_private.walking_groups walking_group on walking_group.id = plan.group_id
      left join app_private.group_runs run on run.active_plan_version_id = plan.id
      left join app_private.run_stops run_stop on run_stop.run_id = run.id and run_stop.plan_stop_id = stop.id
      where stop.portal_id = portal_record.id
      union all
      select walking_group.id, walking_group.system_code, walking_group.display_name,
        reservation.reserved_from, reservation.reserved_until,
        case reservation.status when 'active' then 'active' when 'completed' then 'completed' else 'planned' end,
        'assigned'
      from app_private.portal_reservations reservation
      join app_private.walking_groups walking_group on walking_group.id = reservation.group_id
      where reservation.portal_id = portal_record.id and reservation.status in ('held', 'active', 'completed')
      union all
      select walking_group.id, walking_group.system_code, walking_group.display_name,
        schedule.expected_finale_arrival_at,
        schedule.expected_finale_arrival_at + make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds),
        'planned', 'forecast'
      from app_private.group_schedule_revisions schedule
      join app_private.walking_groups walking_group on walking_group.id = schedule.group_id
      join app_private.event_route_settings settings
        on settings.event_id = walking_group.event_id and settings.final_portal_id = portal_record.id
      where schedule.state = 'published' and schedule.expected_finale_arrival_at is not null
        and portal_record.operation_status in ('scheduled', 'open')
        and not exists (select 1 from app_private.portal_reservations reservation
          where reservation.group_id = schedule.group_id and reservation.portal_id = portal_record.id
            and reservation.status in ('held', 'active', 'completed'))
    ), deduplicated as (
      select distinct on (group_id) raw_arrivals.* from raw_arrivals
      order by group_id, case state when 'completed' then 0 when 'active' then 1 else 2 end,
        case classification when 'assigned' then 0 else 1 end, planned_arrival_at
    ), enriched as (
      select deduplicated.*,
        (select count(*)::integer from app_private.group_registrations assignment
         join app_private.registration_children child on child.registration_id = assignment.registration_id
         where assignment.group_id = deduplicated.group_id and assignment.superseded_at is null
           and child.participation_status = 'active') as expected_children
      from deduplicated
    )
    select jsonb_build_object(
      'portalId', portal_record.id, 'portalCode', portal_record.system_code,
      'operationStatus', portal_record.operation_status, 'updatedAt', now(),
      'forecastAvailable', exists (
        select 1 from app_private.event_route_settings settings
        where settings.event_id = portal_record.event_id and settings.final_portal_id = portal_record.id
      ),
      'nextArrivalAt', (select min(planned_arrival_at) from enriched where state <> 'completed'),
      'arrivals', coalesce((select jsonb_agg(jsonb_build_object(
        'groupCode', enriched.group_code, 'systemCode', enriched.group_code,
        'plannedArrivalAt', enriched.planned_arrival_at, 'plannedDepartureAt', enriched.planned_departure_at,
        'expectedChildren', enriched.expected_children, 'state', enriched.state,
        'classification', enriched.classification
      ) order by enriched.planned_arrival_at, enriched.group_code) from enriched), '[]'::jsonb),
      'assignedGroups', coalesce((select count(*) from enriched where classification = 'assigned' and state <> 'completed'), 0),
      'assignedChildren', coalesce((select sum(expected_children) from enriched where classification = 'assigned' and state <> 'completed'), 0),
      'forecastGroups', coalesce((select count(*) from enriched where classification = 'forecast' and state <> 'completed'), 0),
      'forecastChildren', coalesce((select sum(expected_children) from enriched where classification = 'forecast' and state <> 'completed'), 0),
      'completedGroups', coalesce((select count(*) from enriched where state = 'completed'), 0),
      'remainingGroups', coalesce((select count(*) from enriched where state <> 'completed'), 0),
      'expectedTotal', coalesce((select sum(expected_children) from enriched where state <> 'completed'), 0)
    )
  );
end;
$$;

revoke execute on function api.group_name_update(uuid, integer, text) from public, anon;
grant execute on function api.group_name_update(uuid, integer, text) to authenticated;
revoke execute on function api.registration_exact_preferences_save(uuid, timestamptz, timestamptz, integer) from public, anon;
grant execute on function api.registration_exact_preferences_save(uuid, timestamptz, timestamptz, integer) to authenticated;
revoke execute on function api.registration_exact_preferences_request_change(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function api.registration_exact_preferences_request_change(uuid, timestamptz, timestamptz, text) to authenticated;
revoke execute on function api.registration_preferences_snapshot(text) from public, anon;
grant execute on function api.registration_preferences_snapshot(text) to authenticated;
revoke execute on function api.group_snapshot(uuid) from public, anon;
grant execute on function api.group_snapshot(uuid) to authenticated;
revoke execute on function api.group_viewer_snapshot(uuid) from public, anon;
grant execute on function api.group_viewer_snapshot(uuid) to authenticated;
revoke execute on function api.portal_snapshot(text) from public, anon;
grant execute on function api.portal_snapshot(text) to authenticated;
revoke execute on function api.admin_route_configuration_snapshot(text) from public, anon;
grant execute on function api.admin_route_configuration_snapshot(text) to authenticated;
revoke execute on function api.admin_evening_cockpit(text) from public, anon;
grant execute on function api.admin_evening_cockpit(text) to authenticated;
revoke execute on function api.admin_portal_operations_snapshot(text) from public, anon;
grant execute on function api.admin_portal_operations_snapshot(text) to authenticated;
revoke execute on function api.portal_arrivals_snapshot(uuid) from public, anon;
grant execute on function api.portal_arrivals_snapshot(uuid) to authenticated;

alter function api.admin_portal_applications_snapshot(text) set schema app_private;
alter function app_private.admin_portal_applications_snapshot(text) rename to admin_portal_applications_snapshot_before_codes;
revoke execute on function app_private.admin_portal_applications_snapshot_before_codes(text) from public, anon, authenticated;

create or replace function api.admin_portal_applications_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; enriched jsonb;
begin
  result := app_private.admin_portal_applications_snapshot_before_codes(_event_slug);
  select coalesce(jsonb_agg(
    jsonb_set(
      item || jsonb_build_object('code', application.system_code, 'systemCode', application.system_code),
      '{portal}',
      case when item -> 'portal' is null or item -> 'portal' = 'null'::jsonb then 'null'::jsonb
        else (item -> 'portal') || jsonb_build_object('code', portal.system_code, 'systemCode', portal.system_code) end,
      true
    ) order by ordinal
  ), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'applications', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.portal_applications application on application.id = (item ->> 'id')::uuid
  left join app_private.portals portal on portal.application_id = application.id;
  return jsonb_set(result, '{applications}', enriched, true);
end;
$$;

revoke execute on function api.admin_portal_applications_snapshot(text) from public, anon;
grant execute on function api.admin_portal_applications_snapshot(text) to authenticated;


create or replace function app_private.copy_registration_preferences_from_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft jsonb;
  preference text;
  requested_stop text;
  parsed_stop timestamptz;
  route_settings app_private.event_route_settings;
  has_exact_preferences boolean;
begin
  select payload into draft from app_private.registration_drafts
  where event_id = new.event_id and household_id = new.household_id;
  preference := draft ->> 'startPreference';
  requested_stop := draft ->> 'ordinaryStopAt';
  has_exact_preferences := nullif(trim(coalesce(draft ->> 'desiredEndAt', '')), '') is not null;
  if draft ? 'startPreference' and coalesce(preference, '') not in ('early', 'indifferent', 'later') then
    raise exception 'INVALID_START_PREFERENCE' using errcode = '22023';
  end if;
  if preference in ('early', 'indifferent', 'later') then
    new.start_time_preference := preference::app_private.start_time_preference;
  end if;
  if not has_exact_preferences and nullif(trim(requested_stop), '') is not null then
    begin
      parsed_stop := requested_stop::timestamptz;
    exception when others then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end;
    select * into route_settings from app_private.event_route_settings where event_id = new.event_id;
    if route_settings.global_ordinary_stop_at is null
       or parsed_stop > route_settings.global_ordinary_stop_at
       or not (parsed_stop = any(route_settings.allowed_personal_stop_times)) then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end if;
    new.requested_ordinary_stop_at := parsed_stop;
  end if;
  return new;
end;
$$;

revoke execute on function app_private.copy_registration_preferences_from_draft() from public, anon, authenticated;
