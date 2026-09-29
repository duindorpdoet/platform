-- Startregie turns the legacy start configuration form into a versioned,
-- operational planning surface. Official addresses remain separate from the
-- effective routing marker so a hof entrance can be used without rewriting
-- contact data.

alter table app_private.start_points alter column private_address drop not null;
alter table app_private.start_points
  add column public_label text,
  add column point_type text not null default 'gathering'
    check (point_type in ('gathering', 'portal')),
  add column linked_portal_id uuid references app_private.portals(id) on delete restrict,
  add column public_arrival_instructions text,
  add column internal_notes text,
  add column available_from timestamptz,
  add column available_until timestamptz,
  add column safe_approach text,
  add column counts_as_first_portal_visit boolean not null default false,
  add column contact_name text,
  add column contact_phone text,
  add column geocoded_latitude numeric(9,6),
  add column geocoded_longitude numeric(9,6),
  add column marker_latitude numeric(9,6),
  add column marker_longitude numeric(9,6),
  add column location_source text not null default 'address'
    check (location_source in ('address', 'manual')),
  add column marker_reason text,
  add column marker_updated_by uuid references auth.users(id),
  add column marker_updated_at timestamptz,
  add column walking_node_updated_at timestamptz,
  add constraint start_points_availability_order check (
    available_from is null or available_until is null or available_from < available_until
  ),
  add constraint start_points_linked_portal_kind check (
    (point_type = 'portal' and linked_portal_id is not null)
    or (point_type = 'gathering' and linked_portal_id is null)
  ),
  add constraint start_points_geocoded_pair check ((geocoded_latitude is null) = (geocoded_longitude is null)),
  add constraint start_points_marker_pair check ((marker_latitude is null) = (marker_longitude is null)),
  add constraint start_points_geocoded_latitude check (geocoded_latitude is null or geocoded_latitude between -90 and 90),
  add constraint start_points_geocoded_longitude check (geocoded_longitude is null or geocoded_longitude between -180 and 180),
  add constraint start_points_marker_latitude check (marker_latitude is null or marker_latitude between -90 and 90),
  add constraint start_points_marker_longitude check (marker_longitude is null or marker_longitude between -180 and 180),
  add constraint start_points_manual_marker_reason check (
    location_source <> 'manual' or char_length(trim(coalesce(marker_reason, ''))) between 5 and 500
  );

update app_private.start_points
set public_label = name,
    geocoded_latitude = latitude,
    geocoded_longitude = longitude,
    walking_node_updated_at = case when walking_node_id is not null then coalesce(verified_at, updated_at) end
where public_label is null;

alter table app_private.start_points alter column public_label set not null;

create or replace function app_private.start_point_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.public_label := coalesce(nullif(trim(new.public_label), ''), new.name);
  new.geocoded_latitude := coalesce(new.geocoded_latitude, new.latitude);
  new.geocoded_longitude := coalesce(new.geocoded_longitude, new.longitude);
  return new;
end;
$$;

create trigger start_points_apply_defaults
before insert on app_private.start_points
for each row execute function app_private.start_point_defaults();

alter table app_private.portal_private_locations
  alter column street drop not null,
  alter column house_number drop not null,
  alter column postal_code drop not null,
  add column geocoded_latitude numeric(9,6),
  add column geocoded_longitude numeric(9,6),
  add column marker_latitude numeric(9,6),
  add column marker_longitude numeric(9,6),
  add column location_source text not null default 'address'
    check (location_source in ('address', 'manual')),
  add column marker_reason text,
  add column marker_updated_by uuid references auth.users(id),
  add column marker_updated_at timestamptz,
  add column walking_node_updated_at timestamptz,
  add constraint portal_locations_geocoded_pair check ((geocoded_latitude is null) = (geocoded_longitude is null)),
  add constraint portal_locations_marker_pair check ((marker_latitude is null) = (marker_longitude is null)),
  add constraint portal_locations_manual_marker_reason check (
    location_source <> 'manual' or char_length(trim(coalesce(marker_reason, ''))) between 5 and 500
  );

update app_private.portal_private_locations
set geocoded_latitude = latitude,
    geocoded_longitude = longitude,
    walking_node_updated_at = coalesce(verified_at, updated_at)
where geocoded_latitude is null and latitude is not null;

alter table app_private.portals alter column application_id drop not null;
alter table app_private.portals
  add column lifecycle_status text not null default 'active'
    check (lifecycle_status in ('concept', 'registered', 'approved', 'active', 'archived')),
  add column record_source text not null default 'resident_registration'
    check (record_source in ('resident_registration', 'manual')),
  add column color text,
  add column contact_name text,
  add column contact_phone text,
  add column contact_email text,
  add column accessibility_notes text,
  add column internal_notes text,
  add column candidate_start_point boolean not null default false,
  add column archived_at timestamptz,
  add column archived_by uuid references auth.users(id);

alter table app_private.portals
  drop constraint if exists portals_approval_status_check,
  add constraint portals_approval_status_check check (
    approval_status in ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'withdrawn')
  );

-- Codes stay immutable once a portal is approved, while a manually created
-- concept may still be corrected before activation.
create or replace function app_private.prevent_system_identity_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.event_id is distinct from old.event_id
     or (
       (new.system_number is distinct from old.system_number or new.system_code is distinct from old.system_code)
       and not (
         tg_table_name = 'portals'
         and coalesce(to_jsonb(old) ->> 'record_source', '') = 'manual'
         and coalesce(to_jsonb(old) ->> 'lifecycle_status', '') in ('concept', 'registered')
       )
     ) then
    raise exception 'SYSTEM_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

alter table app_private.event_route_settings
  add column start_interval_minutes integer not null default 15
    check (start_interval_minutes in (5, 10, 15, 20, 30, 60)),
  add column preference_green_minutes integer not null default 15
    check (preference_green_minutes between 0 and 120),
  add column preference_amber_minutes integer not null default 30
    check (preference_amber_minutes between 1 and 180),
  add constraint route_settings_preference_thresholds check (preference_green_minutes < preference_amber_minutes);

create table app_private.location_change_history (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  resource_type text not null check (resource_type in ('start_point', 'portal', 'final_portal')),
  resource_id uuid not null,
  address_latitude numeric(9,6),
  address_longitude numeric(9,6),
  marker_latitude numeric(9,6),
  marker_longitude numeric(9,6),
  location_source text not null check (location_source in ('address', 'manual')),
  reason text,
  changed_by uuid not null references auth.users(id),
  changed_at timestamptz not null default now()
);

create index location_change_history_resource_idx
  on app_private.location_change_history(event_id, resource_type, resource_id, changed_at desc);

create table app_private.start_planning_versions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  version integer not null check (version > 0),
  state text not null default 'published' check (state in ('published', 'superseded')),
  schedule_ids uuid[] not null,
  snapshot jsonb not null,
  published_by uuid not null references auth.users(id),
  published_at timestamptz not null default now(),
  reason text not null,
  unique (event_id, version)
);

create unique index start_planning_one_published_idx
  on app_private.start_planning_versions(event_id) where state = 'published';
create index start_points_event_status_idx on app_private.start_points(event_id, active, point_type);
create index start_points_linked_portal_idx on app_private.start_points(linked_portal_id) where linked_portal_id is not null;
create unique index start_slots_point_exact_unique on app_private.start_slots(start_point_id, starts_at) where start_point_id is not null;
create index group_schedule_current_board_idx on app_private.group_schedule_revisions(start_slot_id, state, group_id);

alter table app_private.location_change_history enable row level security;
alter table app_private.start_planning_versions enable row level security;
revoke all on table app_private.location_change_history from public, anon, authenticated;
revoke all on table app_private.start_planning_versions from public, anon, authenticated;

create or replace function app_private.location_distance_m(
  _latitude_a numeric,
  _longitude_a numeric,
  _latitude_b numeric,
  _longitude_b numeric
)
returns numeric
language sql
immutable
security invoker
set search_path = ''
as $$
  select case when _latitude_a is null or _longitude_a is null or _latitude_b is null or _longitude_b is null then null
    else 6371000 * 2 * asin(sqrt(
      power(sin(radians((_latitude_b - _latitude_a)::double precision) / 2), 2)
      + cos(radians(_latitude_a::double precision)) * cos(radians(_latitude_b::double precision))
      * power(sin(radians((_longitude_b - _longitude_a)::double precision) / 2), 2)
    )) end
$$;

create or replace function app_private.nearest_walking_node(
  _event_id uuid,
  _latitude numeric,
  _longitude numeric,
  _allowed_kinds text[] default array['start', 'junction']::text[]
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select node.id
  from app_private.walking_nodes node
  where node.event_id = _event_id
    and node.verified_at is not null
    and node.kind = any(_allowed_kinds)
  order by power((node.coordinate)[0] - _longitude::double precision, 2)
         + power((node.coordinate)[1] - _latitude::double precision, 2), node.id
  limit 1
$$;

revoke execute on function app_private.location_distance_m(numeric,numeric,numeric,numeric) from public, anon, authenticated;
revoke execute on function app_private.nearest_walking_node(uuid,numeric,numeric,text[]) from public, anon, authenticated;

create or replace function api.admin_startregie_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  base jsonb;
  warning_rows jsonb;
  capacity_conflicts integer;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  base := api.admin_route_configuration_snapshot(_event_slug);

  select count(*)::integer into capacity_conflicts
  from (
    select slot.start_point_id, slot.starts_at
    from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    join app_private.start_points point on point.id = slot.start_point_id
    where walking_group.event_id = event_record.id and schedule.state in ('draft', 'published')
    group by slot.start_point_id, slot.starts_at, point.max_gathering_groups, point.max_gathering_children
    having count(*) > point.max_gathering_groups
      or sum((select count(*) from app_private.group_registrations assignment
        join app_private.registration_children child on child.registration_id = assignment.registration_id
          and child.participation_status = 'active'
        where assignment.group_id = schedule.group_id and assignment.superseded_at is null)) > point.max_gathering_children
  ) conflicts;

  select coalesce(jsonb_agg(item order by priority, label), '[]'::jsonb) into warning_rows
  from (
    select 1 priority, 'UNASSIGNED_GROUPS' code,
      count(*)::text || ' routegroep(en) hebben nog geen startpunt.' label,
      'indeling' action, null::uuid resource_id
    from app_private.walking_groups walking_group
    where walking_group.event_id = event_record.id and walking_group.current_schedule_revision_id is null
    having count(*) > 0
    union all
    select 2, 'MISSING_MARKER', 'De marker van ' || point.name || ' is nog niet routeklaar.',
      'kaart', point.id
    from app_private.start_points point
    where point.event_id = event_record.id and point.active
      and (coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude) is null or point.walking_node_id is null)
    union all
    select 3, 'MARKER_DISTANCE', 'De routingmarker van ' || point.name || ' ligt '
      || round(app_private.location_distance_m(point.geocoded_latitude, point.geocoded_longitude,
        point.marker_latitude, point.marker_longitude))::integer || ' meter van het officiële adres.',
      'kaart', point.id
    from app_private.start_points point
    where point.event_id = event_record.id and point.active and point.location_source = 'manual'
      and app_private.location_distance_m(point.geocoded_latitude, point.geocoded_longitude,
        point.marker_latitude, point.marker_longitude) > 100
    union all
    select 4, 'PORTAL_UNAVAILABLE', portal.system_code || ' is niet beschikbaar bij de geplande start van ' || walking_group.system_code || '.',
      'indeling', walking_group.id
    from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    join app_private.start_points point on point.id = slot.start_point_id and point.linked_portal_id is not null
    join app_private.portals portal on portal.id = point.linked_portal_id
    where walking_group.event_id = event_record.id and not exists (
      select 1 from app_private.portal_windows portal_window
      where portal_window.portal_id = portal.id and slot.starts_at between portal_window.opens_at and portal_window.closes_at
    )
    union all
    select 5, 'CAPACITY', capacity_conflicts::text || ' startmoment(en) overschrijden de ingestelde capaciteit.',
      'indeling', null::uuid
    where capacity_conflicts > 0
  ) warnings(priority, code, label, action, resource_id)
  cross join lateral (select jsonb_build_object(
    'code', warnings.code, 'message', warnings.label, 'action', warnings.action, 'resourceId', warnings.resource_id
  ) item) built;

  return jsonb_build_object(
    'eventId', event_record.id,
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'settings', coalesce(base -> 'settings', '{}'::jsonb) || coalesce((
      select jsonb_build_object(
        'startIntervalMinutes', settings.start_interval_minutes,
        'preferenceGreenMinutes', settings.preference_green_minutes,
        'preferenceAmberMinutes', settings.preference_amber_minutes
      ) from app_private.event_route_settings settings where settings.event_id = event_record.id
    ), '{}'::jsonb),
    'startPoints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', point.id, 'name', point.name, 'publicLabel', point.public_label,
        'pointType', point.point_type, 'linkedPortalId', point.linked_portal_id,
        'privateAddress', point.private_address,
        'publicArrivalInstructions', point.public_arrival_instructions,
        'internalNotes', point.internal_notes, 'availableFrom', point.available_from,
        'availableUntil', point.available_until, 'safeApproach', point.safe_approach,
        'countsAsFirstPortalVisit', point.counts_as_first_portal_visit,
        'contactName', point.contact_name, 'contactPhone', point.contact_phone,
        'geocodedLatitude', point.geocoded_latitude, 'geocodedLongitude', point.geocoded_longitude,
        'markerLatitude', point.marker_latitude, 'markerLongitude', point.marker_longitude,
        'latitude', coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude),
        'longitude', coalesce(point.marker_longitude, point.geocoded_longitude, point.longitude),
        'locationSource', point.location_source, 'markerReason', point.marker_reason,
        'markerUpdatedAt', point.marker_updated_at, 'walkingNodeId', point.walking_node_id,
        'walkingNodeUpdatedAt', point.walking_node_updated_at,
        'verified', point.verified_at is not null and point.walking_node_id is not null,
        'accessible', point.accessible, 'accessibilityNotes', point.accessibility_notes,
        'maxGroups', point.max_gathering_groups, 'maxChildren', point.max_gathering_children,
        'active', point.active, 'version', point.version,
        'markerDistanceMeters', round(app_private.location_distance_m(
          point.geocoded_latitude, point.geocoded_longitude, point.marker_latitude, point.marker_longitude
        )),
        'slots', coalesce((select jsonb_agg(jsonb_build_object(
          'id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups,
          'maxChildren', slot.max_children, 'active', slot.active
        ) order by slot.starts_at) from app_private.start_slots slot where slot.start_point_id = point.id), '[]'::jsonb)
      ) order by point.active desc, point.name)
      from app_private.start_points point where point.event_id = event_record.id
    ), '[]'::jsonb),
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'code', portal.system_code, 'systemCode', portal.system_code,
        'name', portal.name, 'world', world.name, 'worldSlug', world.slug,
        'color', coalesce(portal.color, '#d59658'), 'description', portal.description,
        'approvalStatus', portal.approval_status, 'lifecycleStatus', portal.lifecycle_status,
        'operationStatus', portal.operation_status, 'recordSource', portal.record_source,
        'contactName', coalesce(portal.contact_name, application.private_draft_data ->> 'contactName'),
        'phone', coalesce(portal.contact_phone, application.private_draft_data ->> 'phone'),
        'email', coalesce(portal.contact_email, applicant.email),
        'address', concat_ws(' ', location.street, location.house_number, location.addition),
        'postalCode', location.postal_code, 'city', location.city,
        'geocodedLatitude', location.geocoded_latitude,
        'geocodedLongitude', location.geocoded_longitude,
        'markerLatitude', location.marker_latitude, 'markerLongitude', location.marker_longitude,
        'latitude', coalesce(location.marker_latitude, location.geocoded_latitude, location.latitude),
        'longitude', coalesce(location.marker_longitude, location.geocoded_longitude, location.longitude),
        'locationSource', location.location_source, 'markerReason', location.marker_reason,
        'markerUpdatedAt', location.marker_updated_at,
        'plannedOpensAt', portal_window.opens_at, 'plannedClosesAt', portal_window.closes_at,
        'maxGroups', portal_window.max_concurrent_groups, 'maxChildren', portal_window.max_children_per_visit,
        'candidateStartPoint', portal.candidate_start_point,
        'isFinal', portal.id = settings.final_portal_id, 'version', portal.version
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_applications application on application.id = portal.application_id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join lateral (select min(opens_at) opens_at, max(closes_at) closes_at,
        max(max_concurrent_groups) max_concurrent_groups, max(max_children_per_visit) max_children_per_visit
        from app_private.portal_windows where portal_id = portal.id) portal_window on true
      left join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = event_record.id and portal.lifecycle_status <> 'archived'
    ), '[]'::jsonb),
    'groups', coalesce(base -> 'groups', '[]'::jsonb),
    'unassigned', coalesce(base -> 'unassigned', '[]'::jsonb),
    'finaleFlow', coalesce(base -> 'finaleFlow', '[]'::jsonb),
    'warnings', warning_rows,
    'stats', jsonb_build_object(
      'activeStartPoints', (select count(*) from app_private.start_points where event_id = event_record.id and active),
      'plannedGroups', (select count(*) from app_private.walking_groups where event_id = event_record.id and current_schedule_revision_id is not null),
      'unassignedGroups', (select count(*) from app_private.walking_groups where event_id = event_record.id and current_schedule_revision_id is null),
      'withinPreferencePercent', coalesce((select round(100.0 * count(*) filter (where schedule.preference_match in ('good', 'neutral')) / nullif(count(*), 0))
        from app_private.walking_groups walking_group join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
        where walking_group.event_id = event_record.id), 0),
      'capacityConflicts', capacity_conflicts,
      'missingMarkers', (select count(*) from app_private.start_points point where point.event_id = event_record.id and point.active
        and (coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude) is null or point.walking_node_id is null)),
      'unavailableLinkedPortals', (select count(distinct point.linked_portal_id)
        from app_private.walking_groups walking_group
        join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
        join app_private.start_slots slot on slot.id = schedule.start_slot_id
        join app_private.start_points point on point.id = slot.start_point_id and point.linked_portal_id is not null
        where walking_group.event_id = event_record.id and not exists (
          select 1 from app_private.portal_windows portal_window where portal_window.portal_id = point.linked_portal_id
            and slot.starts_at between portal_window.opens_at and portal_window.closes_at)),
      'publicationStatus', coalesce((select 'Gepubliceerd · versie ' || version::text from app_private.start_planning_versions
        where event_id = event_record.id and state = 'published'), 'Nog niet gepubliceerd')
    ),
    'planningVersions', coalesce((select jsonb_agg(jsonb_build_object(
      'id', version.id, 'version', version.version, 'state', version.state,
      'publishedAt', version.published_at, 'reason', version.reason
    ) order by version.version desc) from app_private.start_planning_versions version
      where version.event_id = event_record.id), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_startregie_start_point_save(
  _event_slug text,
  _point_id uuid,
  _payload jsonb,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; effective_latitude numeric; effective_longitude numeric; node_id uuid;
  point_kind text := coalesce(nullif(_payload ->> 'pointType', ''), 'gathering');
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if jsonb_typeof(_payload) <> 'object' or char_length(trim(coalesce(_payload ->> 'name', ''))) not between 2 and 120
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500
    or point_kind not in ('gathering', 'portal') then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if point_kind = 'portal' then
    select * into portal_record from app_private.portals
    where id = nullif(_payload ->> 'linkedPortalId', '')::uuid and event_id = event_record.id;
    if portal_record.id is null or portal_record.lifecycle_status not in ('approved', 'active') then
      raise exception 'LINKED_PORTAL_NOT_AVAILABLE' using errcode = '23514';
    end if;
  end if;
  effective_latitude := coalesce(nullif(_payload ->> 'markerLatitude', '')::numeric,
    nullif(_payload ->> 'geocodedLatitude', '')::numeric);
  effective_longitude := coalesce(nullif(_payload ->> 'markerLongitude', '')::numeric,
    nullif(_payload ->> 'geocodedLongitude', '')::numeric);
  if nullif(_payload ->> 'markerLatitude', '') is not null
    and char_length(trim(coalesce(_payload ->> 'markerReason', ''))) < 5 then
    raise exception 'MARKER_REASON_REQUIRED' using errcode = '22023';
  end if;
  if effective_latitude is not null then
    node_id := app_private.nearest_walking_node(event_record.id, effective_latitude, effective_longitude);
  end if;

  if _point_id is null then
    insert into app_private.start_points(
      event_id, name, public_label, point_type, linked_portal_id, private_address,
      public_arrival_instructions, internal_notes, available_from, available_until,
      max_gathering_groups, max_gathering_children, accessible, accessibility_notes,
      safe_approach, counts_as_first_portal_visit, contact_name, contact_phone,
      geocoded_latitude, geocoded_longitude, marker_latitude, marker_longitude,
      latitude, longitude, location_source, marker_reason, marker_updated_by,
      marker_updated_at, walking_node_id, walking_node_updated_at, verified_at, verified_by, active
    ) values (
      event_record.id, trim(_payload ->> 'name'),
      coalesce(nullif(trim(_payload ->> 'publicLabel'), ''), trim(_payload ->> 'name')),
      point_kind, case when point_kind = 'portal' then portal_record.id end,
      nullif(trim(_payload ->> 'privateAddress'), ''), nullif(trim(_payload ->> 'publicArrivalInstructions'), ''),
      nullif(trim(_payload ->> 'internalNotes'), ''), nullif(_payload ->> 'availableFrom', '')::timestamptz,
      nullif(_payload ->> 'availableUntil', '')::timestamptz,
      coalesce((_payload ->> 'maxGroups')::integer, 1), coalesce((_payload ->> 'maxChildren')::integer, 20),
      nullif(_payload ->> 'accessible', '')::boolean, nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      nullif(trim(_payload ->> 'safeApproach'), ''), coalesce((_payload ->> 'countsAsFirstPortalVisit')::boolean, false),
      nullif(trim(_payload ->> 'contactName'), ''), nullif(trim(_payload ->> 'contactPhone'), ''),
      nullif(_payload ->> 'geocodedLatitude', '')::numeric, nullif(_payload ->> 'geocodedLongitude', '')::numeric,
      nullif(_payload ->> 'markerLatitude', '')::numeric, nullif(_payload ->> 'markerLongitude', '')::numeric,
      effective_latitude, effective_longitude,
      case when nullif(_payload ->> 'markerLatitude', '') is null then 'address' else 'manual' end,
      nullif(trim(_payload ->> 'markerReason'), ''), actor,
      case when effective_latitude is not null then now() end, node_id, case when node_id is not null then now() end,
      case when node_id is not null then now() end, case when node_id is not null then actor end,
      coalesce((_payload ->> 'active')::boolean, true)
    ) returning * into point_record;
  else
    select * into point_record from app_private.start_points where id = _point_id and event_id = event_record.id for update;
    if point_record.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.start_points set
      name = trim(_payload ->> 'name'), public_label = coalesce(nullif(trim(_payload ->> 'publicLabel'), ''), trim(_payload ->> 'name')),
      point_type = point_kind, linked_portal_id = case when point_kind = 'portal' then portal_record.id end,
      private_address = nullif(trim(_payload ->> 'privateAddress'), ''),
      public_arrival_instructions = nullif(trim(_payload ->> 'publicArrivalInstructions'), ''),
      internal_notes = nullif(trim(_payload ->> 'internalNotes'), ''),
      available_from = nullif(_payload ->> 'availableFrom', '')::timestamptz,
      available_until = nullif(_payload ->> 'availableUntil', '')::timestamptz,
      max_gathering_groups = coalesce((_payload ->> 'maxGroups')::integer, max_gathering_groups),
      max_gathering_children = coalesce((_payload ->> 'maxChildren')::integer, max_gathering_children),
      accessible = nullif(_payload ->> 'accessible', '')::boolean,
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      safe_approach = nullif(trim(_payload ->> 'safeApproach'), ''),
      counts_as_first_portal_visit = coalesce((_payload ->> 'countsAsFirstPortalVisit')::boolean, false),
      contact_name = nullif(trim(_payload ->> 'contactName'), ''), contact_phone = nullif(trim(_payload ->> 'contactPhone'), ''),
      geocoded_latitude = nullif(_payload ->> 'geocodedLatitude', '')::numeric,
      geocoded_longitude = nullif(_payload ->> 'geocodedLongitude', '')::numeric,
      marker_latitude = nullif(_payload ->> 'markerLatitude', '')::numeric,
      marker_longitude = nullif(_payload ->> 'markerLongitude', '')::numeric,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when nullif(_payload ->> 'markerLatitude', '') is null then 'address' else 'manual' end,
      marker_reason = nullif(trim(_payload ->> 'markerReason'), ''), marker_updated_by = actor,
      marker_updated_at = case when effective_latitude is not null then now() end,
      walking_node_id = node_id, walking_node_updated_at = case when node_id is not null then now() end,
      verified_at = case when node_id is not null then now() end, verified_by = case when node_id is not null then actor end,
      active = coalesce((_payload ->> 'active')::boolean, active), updated_at = now(), version = version + 1
    where id = point_record.id returning * into point_record;
  end if;

  update app_private.start_slots set location_name = point_record.name, private_address = point_record.private_address,
    latitude = point_record.latitude, longitude = point_record.longitude,
    location_verified_at = point_record.verified_at, max_groups = point_record.max_gathering_groups,
    max_children = point_record.max_gathering_children, updated_at = now()
  where start_point_id = point_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, case when _point_id is null then 'start_point.created' else 'start_point.updated' end,
    'start_point', point_record.id, jsonb_build_object('version', point_record.version, 'type', point_record.point_type,
      'routeReady', point_record.walking_node_id is not null, 'reason', left(trim(_reason), 500)));
  if effective_latitude is not null then
    insert into app_private.location_change_history(event_id, resource_type, resource_id,
      address_latitude, address_longitude, marker_latitude, marker_longitude, location_source, reason, changed_by)
    values (event_record.id, 'start_point', point_record.id, point_record.geocoded_latitude, point_record.geocoded_longitude,
      effective_latitude, effective_longitude, point_record.location_source, point_record.marker_reason, actor);
  end if;
  perform realtime.send(jsonb_build_object('resource', 'start_point', 'id', point_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', point_record.id, 'version', point_record.version,
    'routeReady', point_record.walking_node_id is not null, 'walkingNodeId', point_record.walking_node_id);
end;
$$;

create or replace function api.admin_location_marker_save(
  _event_slug text,
  _resource_type text,
  _resource_id uuid,
  _latitude numeric,
  _longitude numeric,
  _reason text,
  _restore_from_address boolean,
  _expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; location_record app_private.portal_private_locations;
  effective_latitude numeric; effective_longitude numeric; node_id uuid; next_version integer;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or _resource_type not in ('start_point', 'portal', 'final_portal')
    or char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _latitude not between -90 and 90 or _longitude not between -180 and 180 then
    raise exception 'INVALID_COORDINATE' using errcode = '22023';
  end if;

  if _resource_type = 'start_point' then
    if not (app_private.has_capability(event_record.id, 'groups_manage', actor)
      or app_private.has_capability(event_record.id, 'event_admin', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    select * into point_record from app_private.start_points
      where id = _resource_id and event_id = event_record.id for update;
    if point_record.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    effective_latitude := case when _restore_from_address then point_record.geocoded_latitude else _latitude end;
    effective_longitude := case when _restore_from_address then point_record.geocoded_longitude else _longitude end;
    if effective_latitude is null then raise exception 'ADDRESS_LOCATION_MISSING' using errcode = '23514'; end if;
    node_id := app_private.nearest_walking_node(event_record.id, effective_latitude, effective_longitude);
    update app_private.start_points set
      marker_latitude = case when _restore_from_address then null else effective_latitude end,
      marker_longitude = case when _restore_from_address then null else effective_longitude end,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when _restore_from_address then 'address' else 'manual' end,
      marker_reason = case when _restore_from_address then null else trim(_reason) end,
      marker_updated_by = actor, marker_updated_at = now(), walking_node_id = node_id,
      walking_node_updated_at = case when node_id is not null then now() end,
      verified_at = case when node_id is not null then now() end,
      verified_by = case when node_id is not null then actor end,
      updated_at = now(), version = version + 1
    where id = point_record.id returning version into next_version;
    update app_private.start_slots set latitude = effective_latitude, longitude = effective_longitude,
      location_verified_at = case when node_id is not null then now() end, updated_at = now()
    where start_point_id = point_record.id;
  else
    if not (app_private.has_capability(event_record.id, 'portals_manage', actor)
      or app_private.has_capability(event_record.id, 'event_admin', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    select * into portal_record from app_private.portals
      where id = _resource_id and event_id = event_record.id for update;
    select * into location_record from app_private.portal_private_locations where portal_id = _resource_id;
    if portal_record.id is null or location_record.portal_id is null then raise exception 'PORTAL_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from portal_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    effective_latitude := case when _restore_from_address then location_record.geocoded_latitude else _latitude end;
    effective_longitude := case when _restore_from_address then location_record.geocoded_longitude else _longitude end;
    if effective_latitude is null then raise exception 'ADDRESS_LOCATION_MISSING' using errcode = '23514'; end if;
    select id into node_id from app_private.walking_nodes where portal_id = portal_record.id limit 1;
    if node_id is null then
      insert into app_private.walking_nodes(event_id, kind, portal_id, coordinate, verified_at, verified_by)
      values (event_record.id, 'portal', portal_record.id, point(effective_longitude, effective_latitude), now(), actor)
      returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(effective_longitude, effective_latitude),
        verified_at = now(), verified_by = actor where id = node_id;
    end if;
    update app_private.portal_private_locations set
      marker_latitude = case when _restore_from_address then null else effective_latitude end,
      marker_longitude = case when _restore_from_address then null else effective_longitude end,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when _restore_from_address then 'address' else 'manual' end,
      marker_reason = case when _restore_from_address then null else trim(_reason) end,
      marker_updated_by = actor, marker_updated_at = now(), walking_node_updated_at = now(),
      verified_at = now(), verified_by = actor, updated_at = now()
    where portal_id = portal_record.id;
    update app_private.portals set updated_at = now(), version = version + 1
      where id = portal_record.id returning version into next_version;
  end if;

  insert into app_private.location_change_history(event_id, resource_type, resource_id,
    address_latitude, address_longitude, marker_latitude, marker_longitude, location_source, reason, changed_by)
  values (event_record.id, _resource_type, _resource_id,
    case when _resource_type = 'start_point' then point_record.geocoded_latitude else location_record.geocoded_latitude end,
    case when _resource_type = 'start_point' then point_record.geocoded_longitude else location_record.geocoded_longitude end,
    effective_latitude, effective_longitude, case when _restore_from_address then 'address' else 'manual' end, trim(_reason), actor);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'location.marker_moved', _resource_type, _resource_id,
    jsonb_build_object('source', case when _restore_from_address then 'address' else 'manual' end,
      'walkingNodeRecalculated', node_id is not null, 'routeCacheInvalidated', true, 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', _resource_type, 'id', _resource_id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', _resource_id, 'version', next_version,
    'latitude', effective_latitude, 'longitude', effective_longitude,
    'walkingNodeId', node_id, 'routeCacheInvalidated', true);
end;
$$;

create or replace function api.admin_startregie_move_group(
  _group_id uuid,
  _start_point_id uuid,
  _starts_at timestamptz,
  _expected_group_version integer,
  _preference_match text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid(); group_record app_private.walking_groups; point_record app_private.start_points;
  settings app_private.event_route_settings; portal_record app_private.portals; slot_record app_private.start_slots;
  schedule_record app_private.group_schedule_revisions; result jsonb; group_children integer; occupied_groups integer; occupied_children integer;
begin
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if actor is null or group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _expected_group_version is distinct from group_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  select * into point_record from app_private.start_points
    where id = _start_point_id and event_id = group_record.event_id and active for update;
  if point_record.id is null then raise exception 'START_POINT_NOT_AVAILABLE' using errcode = '23514'; end if;
  if point_record.walking_node_id is null or coalesce(point_record.marker_latitude, point_record.geocoded_latitude, point_record.latitude) is null then
    raise exception 'START_POINT_MARKER_INVALID' using errcode = '23514';
  end if;
  if settings.first_start_at is null or settings.global_ordinary_stop_at is null
    or _starts_at < settings.first_start_at or _starts_at > settings.global_ordinary_stop_at then
    raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514';
  end if;
  if (point_record.available_from is not null and _starts_at < point_record.available_from)
    or (point_record.available_until is not null and _starts_at > point_record.available_until) then
    raise exception 'START_POINT_CLOSED' using errcode = '23514';
  end if;
  if point_record.linked_portal_id is not null then
    select * into portal_record from app_private.portals where id = point_record.linked_portal_id;
    if portal_record.lifecycle_status <> 'active' or portal_record.approval_status <> 'approved'
      or not exists (select 1 from app_private.portal_windows portal_window where portal_window.portal_id = portal_record.id
        and _starts_at between portal_window.opens_at and portal_window.closes_at) then
      raise exception 'LINKED_PORTAL_NOT_OPEN' using errcode = '23514';
    end if;
  end if;

  select * into slot_record from app_private.start_slots
    where start_point_id = point_record.id and starts_at = _starts_at and active for update;
  if slot_record.id is null then
    insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
      location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
    values (group_record.event_id, point_record.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point_record.name, point_record.private_address,
      coalesce(point_record.marker_latitude, point_record.geocoded_latitude, point_record.latitude),
      coalesce(point_record.marker_longitude, point_record.geocoded_longitude, point_record.longitude),
      point_record.verified_at, _starts_at, point_record.max_gathering_groups,
      point_record.max_gathering_children, true, point_record.id)
    returning * into slot_record;
  end if;

  select count(*)::integer,
    coalesce(sum((select count(*) from app_private.group_registrations assignment
      join app_private.registration_children child on child.registration_id = assignment.registration_id
        and child.participation_status = 'active'
      where assignment.group_id = other_group.id and assignment.superseded_at is null)), 0)::integer
  into occupied_groups, occupied_children
  from app_private.walking_groups other_group
  join app_private.group_schedule_revisions other_schedule on other_schedule.id = other_group.current_schedule_revision_id
  join app_private.start_slots other_slot on other_slot.id = other_schedule.start_slot_id
  where other_group.event_id = group_record.event_id and other_group.id <> group_record.id
    and other_slot.start_point_id = point_record.id and other_slot.starts_at = _starts_at;
  select count(*)::integer into group_children from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id
      and child.participation_status = 'active'
    where assignment.group_id = group_record.id and assignment.superseded_at is null;
  if occupied_groups + 1 > least(slot_record.max_groups, point_record.max_gathering_groups)
    or occupied_children + group_children > least(slot_record.max_children, point_record.max_gathering_children) then
    raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode = '23514';
  end if;

  select * into schedule_record from app_private.group_schedule_revisions where id = group_record.current_schedule_revision_id;
  if group_record.route_mode <> 'dynamic' then
    update app_private.walking_groups set route_mode = 'dynamic' where id = group_record.id;
  end if;
  result := api.admin_save_group_schedule(
    group_record.id, slot_record.id,
    coalesce(schedule_record.effective_ordinary_stop_at, settings.global_ordinary_stop_at),
    coalesce(schedule_record.expected_finale_arrival_at,
      greatest(settings.finale_opens_at, settings.global_ordinary_stop_at + make_interval(secs => settings.finale_planning_transfer_seconds))),
    schedule_record.queue_number, _preference_match, _reason
  );
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'groupId', group_record.id),
    'snapshot_changed', 'admin-event:' || group_record.event_id::text, true);
  return result || jsonb_build_object('previousStartSlotId', schedule_record.start_slot_id,
    'startPointId', point_record.id, 'startsAt', slot_record.starts_at);
end;
$$;

create or replace function api.admin_startregie_slots_prepare(
  _event_slug text,
  _starts_at timestamptz[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); event_record app_private.events; settings app_private.event_route_settings;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_starts_at), 0) = 0 or cardinality(_starts_at) > 100 then
    raise exception 'INVALID_START_TIMES' using errcode = '22023';
  end if;
  select * into settings from app_private.event_route_settings where event_id = event_record.id;
  if exists (select 1 from unnest(_starts_at) as requested(starts_at)
    where requested.starts_at < settings.first_start_at or requested.starts_at > settings.global_ordinary_stop_at) then
    raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514';
  end if;
  insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
    location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
  select event_record.id, point.name || ' ' || to_char(requested.starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
    point.name, point.private_address,
    coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude),
    coalesce(point.marker_longitude, point.geocoded_longitude, point.longitude),
    point.verified_at, requested.starts_at, point.max_gathering_groups, point.max_gathering_children, true, point.id
  from app_private.start_points point cross join unnest(_starts_at) as requested(starts_at)
  where point.event_id = event_record.id and point.active and point.walking_node_id is not null
    and not exists (select 1 from app_private.start_slots existing
      where existing.start_point_id = point.id and existing.starts_at = requested.starts_at)
  on conflict do nothing;
  return jsonb_build_object('starts', coalesce((select jsonb_agg(jsonb_build_object(
    'id', slot.id, 'startPointId', slot.start_point_id, 'startsAt', slot.starts_at,
    'maxGroups', slot.max_groups, 'maxChildren', slot.max_children
  ) order by slot.starts_at, slot.start_point_id)
  from app_private.start_slots slot
  where slot.event_id = event_record.id and slot.active and slot.starts_at = any(_starts_at)), '[]'::jsonb));
end;
$$;

create or replace function api.admin_startregie_start_point_archive(
  _point_id uuid,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); point_record app_private.start_points; linked_groups integer;
begin
  select * into point_record from app_private.start_points where id = _point_id for update;
  if actor is null or point_record.id is null or not app_private.has_capability(point_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select count(*) into linked_groups from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    where slot.start_point_id = point_record.id;
  if linked_groups > 0 then raise exception 'MOVE_GROUPS_FIRST:%', linked_groups using errcode = '23514'; end if;
  update app_private.start_points set active = false, updated_at = now(), version = version + 1
    where id = point_record.id returning * into point_record;
  update app_private.start_slots set active = false, updated_at = now() where start_point_id = point_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (point_record.event_id, actor, 'start_point.archived', 'start_point', point_record.id,
    jsonb_build_object('reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'start_point', 'id', point_record.id),
    'snapshot_changed', 'admin-event:' || point_record.event_id::text, true);
  return jsonb_build_object('id', point_record.id, 'archived', true, 'version', point_record.version);
end;
$$;

create or replace function api.admin_manual_portal_save(
  _event_slug text,
  _portal_id uuid,
  _payload jsonb,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid(); event_record app_private.events; portal_record app_private.portals;
  world_record app_private.worlds; lifecycle text := coalesce(nullif(_payload ->> 'lifecycleStatus', ''), 'concept');
  approval text := coalesce(nullif(_payload ->> 'approvalStatus', ''), 'draft');
  operation text := coalesce(nullif(_payload ->> 'operationStatus', ''), 'scheduled');
  latitude numeric := nullif(_payload ->> 'latitude', '')::numeric;
  longitude numeric := nullif(_payload ->> 'longitude', '')::numeric;
  opens_at timestamptz := nullif(_payload ->> 'plannedOpensAt', '')::timestamptz;
  closes_at timestamptz := nullif(_payload ->> 'plannedClosesAt', '')::timestamptz;
  system_number_input integer := nullif(_payload ->> 'systemNumber', '')::integer;
  node_id uuid;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'portals_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into world_record from app_private.worlds
    where event_id = event_record.id and slug = _payload ->> 'worldSlug';
  if world_record.id is null or lifecycle not in ('concept', 'registered', 'approved', 'active', 'archived')
    or approval not in ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'withdrawn')
    or operation not in ('scheduled', 'open', 'paused', 'closed')
    or char_length(trim(coalesce(_payload ->> 'name', ''))) not between 2 and 120
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if lifecycle = 'active' and (approval <> 'approved' or latitude is null or opens_at is null or closes_at is null or opens_at >= closes_at) then
    raise exception 'PORTAL_NOT_READY_FOR_ACTIVATION' using errcode = '23514';
  end if;

  if _portal_id is null then
    insert into app_private.portals(event_id, application_id, world_id, name, description, intensity,
      approval_status, operation_status, system_number, lifecycle_status, record_source, color,
      contact_name, contact_phone, contact_email, accessibility_notes, internal_notes, candidate_start_point)
    values (event_record.id, null, world_record.id, trim(_payload ->> 'name'),
      coalesce(nullif(trim(_payload ->> 'description'), ''), ''), coalesce((_payload ->> 'intensity')::smallint, 1),
      approval::app_private.review_status,
      operation::app_private.portal_operation_status, system_number_input, lifecycle, 'manual', nullif(_payload ->> 'color', ''),
      nullif(trim(_payload ->> 'contactName'), ''), nullif(trim(_payload ->> 'contactPhone'), ''),
      nullif(lower(trim(_payload ->> 'contactEmail')), ''), nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      nullif(trim(_payload ->> 'internalNotes'), ''), coalesce((_payload ->> 'candidateStartPoint')::boolean, false))
    returning * into portal_record;
  else
    select * into portal_record from app_private.portals where id = _portal_id and event_id = event_record.id for update;
    if portal_record.id is null then raise exception 'PORTAL_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from portal_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    if portal_record.lifecycle_status not in ('concept', 'registered') and system_number_input is distinct from portal_record.system_number then
      raise exception 'PORTAL_CODE_IS_STABLE' using errcode = '23514';
    end if;
    update app_private.portals set world_id = world_record.id, name = trim(_payload ->> 'name'),
      description = coalesce(nullif(trim(_payload ->> 'description'), ''), ''),
      intensity = coalesce((_payload ->> 'intensity')::smallint, intensity),
      approval_status = approval::app_private.review_status,
      operation_status = operation::app_private.portal_operation_status,
      lifecycle_status = lifecycle, system_number = coalesce(system_number_input, system_number),
      system_code = 'P-' || lpad(coalesce(system_number_input, system_number)::text, 2, '0'),
      color = nullif(_payload ->> 'color', ''), contact_name = nullif(trim(_payload ->> 'contactName'), ''),
      contact_phone = nullif(trim(_payload ->> 'contactPhone'), ''), contact_email = nullif(lower(trim(_payload ->> 'contactEmail')), ''),
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      internal_notes = nullif(trim(_payload ->> 'internalNotes'), ''),
      candidate_start_point = coalesce((_payload ->> 'candidateStartPoint')::boolean, false),
      updated_at = now(), version = version + 1
    where id = portal_record.id returning * into portal_record;
  end if;

  insert into app_private.portal_private_locations(portal_id, street, house_number, addition, postal_code, city,
    latitude, longitude, geocoded_latitude, geocoded_longitude, location_source,
    verified_at, verified_by, walking_node_updated_at)
  values (portal_record.id, nullif(trim(_payload ->> 'street'), ''), nullif(trim(_payload ->> 'houseNumber'), ''),
    nullif(trim(_payload ->> 'addition'), ''), nullif(upper(trim(_payload ->> 'postalCode')), ''),
    coalesce(nullif(trim(_payload ->> 'city'), ''), 'Den Haag'), latitude, longitude, latitude, longitude,
    'address', case when latitude is not null then now() end, case when latitude is not null then actor end,
    case when latitude is not null then now() end)
  on conflict (portal_id) do update set street = excluded.street, house_number = excluded.house_number,
    addition = excluded.addition, postal_code = excluded.postal_code, city = excluded.city,
    geocoded_latitude = excluded.geocoded_latitude, geocoded_longitude = excluded.geocoded_longitude,
    latitude = coalesce(app_private.portal_private_locations.marker_latitude, excluded.latitude),
    longitude = coalesce(app_private.portal_private_locations.marker_longitude, excluded.longitude),
    verified_at = case when coalesce(app_private.portal_private_locations.marker_latitude, excluded.latitude) is not null then now() end,
    verified_by = case when coalesce(app_private.portal_private_locations.marker_latitude, excluded.latitude) is not null then actor end,
    updated_at = now();
  if opens_at is not null and closes_at is not null then
    delete from app_private.portal_windows where portal_id = portal_record.id;
    insert into app_private.portal_windows(portal_id, opens_at, closes_at, visit_minutes, buffer_minutes,
      max_concurrent_groups, max_children_per_visit)
    values (portal_record.id, opens_at, closes_at, coalesce((_payload ->> 'visitMinutes')::integer, 5),
      coalesce((_payload ->> 'bufferMinutes')::integer, 2), coalesce((_payload ->> 'maxGroups')::integer, 1),
      coalesce((_payload ->> 'maxChildren')::integer, 20));
  end if;
  if latitude is not null then
    select id into node_id from app_private.walking_nodes where portal_id = portal_record.id limit 1;
    if node_id is null then
      insert into app_private.walking_nodes(event_id, kind, portal_id, coordinate, verified_at, verified_by)
      values (event_record.id, 'portal', portal_record.id, point(longitude, latitude), now(), actor) returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(longitude, latitude), verified_at = now(), verified_by = actor where id = node_id;
    end if;
  end if;
  if coalesce((_payload ->> 'isFinal')::boolean, false) then
    if not coalesce((_payload ->> 'confirmFinal')::boolean, false) then raise exception 'FINAL_PORTAL_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
    update app_private.event_route_settings set final_portal_id = portal_record.id, updated_at = now(), updated_by = actor,
      version = version + 1 where event_id = event_record.id;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, case when _portal_id is null then 'portal.manual_created' else 'portal.manual_updated' end,
    'portal', portal_record.id, jsonb_build_object('code', portal_record.system_code, 'lifecycle', portal_record.lifecycle_status,
      'source', portal_record.record_source, 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', portal_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', portal_record.id, 'code', portal_record.system_code,
    'version', portal_record.version, 'lifecycleStatus', portal_record.lifecycle_status);
end;
$$;

create or replace function api.admin_manual_portal_remove(
  _portal_id uuid,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); portal_record app_private.portals; relation_count integer; active_assignments integer;
begin
  select * into portal_record from app_private.portals where id = _portal_id for update;
  if actor is null or portal_record.id is null or not (
    app_private.has_capability(portal_record.event_id, 'portals_manage', actor)
    or app_private.has_capability(portal_record.event_id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _expected_version is distinct from portal_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if exists (select 1 from app_private.event_route_settings where final_portal_id = portal_record.id) then
    raise exception 'CHOOSE_REPLACEMENT_FINAL_PORTAL_FIRST' using errcode = '23514';
  end if;
  select count(*) into active_assignments
  from app_private.walking_groups walking_group
  join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
  join app_private.start_slots slot on slot.id = schedule.start_slot_id
  join app_private.start_points point on point.id = slot.start_point_id
  where point.linked_portal_id = portal_record.id;
  if active_assignments > 0 then raise exception 'RESOLVE_ACTIVE_ASSIGNMENTS_FIRST:%', active_assignments using errcode = '23514'; end if;
  select (select count(*) from app_private.portal_reservations where portal_id = portal_record.id)
    + (select count(*) from app_private.route_plan_stops where portal_id = portal_record.id)
    + (select count(*) from app_private.audit_events where resource_type = 'portal' and resource_id = portal_record.id)
  into relation_count;
  if portal_record.record_source = 'manual' and portal_record.lifecycle_status = 'concept' and relation_count <= 1
    and not exists (select 1 from app_private.start_points where linked_portal_id = portal_record.id) then
    delete from app_private.portals where id = portal_record.id;
    return jsonb_build_object('id', _portal_id, 'deleted', true, 'archived', false);
  end if;
  update app_private.start_points set active = false, updated_at = now(), version = version + 1
    where linked_portal_id = portal_record.id;
  update app_private.portals set lifecycle_status = 'archived', approval_status = 'withdrawn',
    archived_at = now(), archived_by = actor, updated_at = now(), version = version + 1
    where id = portal_record.id returning * into portal_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal_record.event_id, actor, 'portal.archived', 'portal', portal_record.id,
    jsonb_build_object('reason', left(trim(_reason), 500), 'historicalRelations', relation_count));
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', portal_record.id),
    'snapshot_changed', 'admin-event:' || portal_record.event_id::text, true);
  return jsonb_build_object('id', portal_record.id, 'deleted', false, 'archived', true, 'version', portal_record.version);
end;
$$;

create or replace function api.admin_startregie_publish(
  _event_slug text,
  _schedule_ids uuid[],
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); event_record app_private.events; result jsonb; next_version integer; version_id uuid;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
  if actor is null or event_record.id is null or not app_private.has_capability(event_record.id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  result := api.admin_publish_group_schedules(_event_slug, _schedule_ids, _reason);
  update app_private.start_planning_versions set state = 'superseded'
    where event_id = event_record.id and state = 'published';
  select coalesce(max(version), 0) + 1 into next_version
    from app_private.start_planning_versions where event_id = event_record.id;
  insert into app_private.start_planning_versions(event_id, version, schedule_ids, snapshot, published_by, reason)
  values (event_record.id, next_version, _schedule_ids,
    jsonb_build_object('scheduleIds', _schedule_ids, 'publishedCount', cardinality(_schedule_ids)), actor, trim(_reason))
  returning id into version_id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'start_planning.published', 'start_planning', version_id,
    jsonb_build_object('version', next_version, 'changedSchedules', cardinality(_schedule_ids), 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'id', version_id, 'version', next_version),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result || jsonb_build_object('planningVersionId', version_id, 'planningVersion', next_version);
end;
$$;

create or replace function api.admin_startregie_settings_save(
  _event_slug text,
  _settings jsonb,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); event_record app_private.events; result jsonb;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce((_settings ->> 'preferenceGreenMinutes')::integer, 15)
    >= coalesce((_settings ->> 'preferenceAmberMinutes')::integer, 30) then
    raise exception 'INVALID_PREFERENCE_THRESHOLDS' using errcode = '22023';
  end if;
  result := api.admin_save_route_settings(_event_slug, _settings, _expected_version, _reason);
  update app_private.event_route_settings set
    start_interval_minutes = coalesce((_settings ->> 'startIntervalMinutes')::integer, start_interval_minutes),
    preference_green_minutes = coalesce((_settings ->> 'preferenceGreenMinutes')::integer, preference_green_minutes),
    preference_amber_minutes = coalesce((_settings ->> 'preferenceAmberMinutes')::integer, preference_amber_minutes)
  where event_id = event_record.id;
  perform realtime.send(jsonb_build_object('resource', 'start_planning_settings', 'eventId', event_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result;
end;
$$;

revoke execute on function api.admin_startregie_snapshot(text) from public, anon;
revoke execute on function api.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) from public, anon;
revoke execute on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) from public, anon;
revoke execute on function api.admin_startregie_move_group(uuid,uuid,timestamptz,integer,text,text) from public, anon;
revoke execute on function api.admin_startregie_slots_prepare(text,timestamptz[]) from public, anon;
revoke execute on function api.admin_startregie_start_point_archive(uuid,integer,text) from public, anon;
revoke execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public, anon;
revoke execute on function api.admin_manual_portal_remove(uuid,integer,text) from public, anon;
revoke execute on function api.admin_startregie_publish(text,uuid[],text) from public, anon;
revoke execute on function api.admin_startregie_settings_save(text,jsonb,integer,text) from public, anon;
grant execute on function api.admin_startregie_snapshot(text) to authenticated;
grant execute on function api.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) to authenticated;
grant execute on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) to authenticated;
grant execute on function api.admin_startregie_move_group(uuid,uuid,timestamptz,integer,text,text) to authenticated;
grant execute on function api.admin_startregie_slots_prepare(text,timestamptz[]) to authenticated;
grant execute on function api.admin_startregie_start_point_archive(uuid,integer,text) to authenticated;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;
grant execute on function api.admin_manual_portal_remove(uuid,integer,text) to authenticated;
grant execute on function api.admin_startregie_publish(text,uuid[],text) to authenticated;
grant execute on function api.admin_startregie_settings_save(text,jsonb,integer,text) to authenticated;
