-- A route is a sequence of destinations, independent of a street graph.
-- Functions only. Preserve all locations, publications, visits and graph data.
set lock_timeout='5s';

create or replace function app_private.portal_location(_portal_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select app_private.routing_position(l.marker_latitude,l.marker_longitude,
    l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)
  from app_private.portal_private_locations l where l.portal_id=_portal_id
$$;

create or replace function app_private.portal_location_ready(_portal_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from app_private.portal_private_locations l where l.portal_id=_portal_id
    and nullif(trim(l.street),'') is not null and nullif(trim(l.house_number),'') is not null
    and (app_private.portal_location(l.portal_id)->>'valid')::boolean)
$$;

create or replace function app_private.start_point_destination_ready(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select p.active and nullif(trim(p.private_address),'') is not null
    and (app_private.start_point_location(p.id)->>'valid')::boolean
    and (p.linked_portal_id is null or exists(select 1 from app_private.portals portal
      where portal.id=p.linked_portal_id and portal.event_id=p.event_id and portal.lifecycle_status<>'archived'
        and (not p.counts_as_first_portal_visit or app_private.portal_location_ready(portal.id))))
    from app_private.start_points p where p.id=_point_id),false)
$$;

-- Compatibility name for existing callers; this no longer certifies a path.
create or replace function app_private.start_point_safe_connection(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select app_private.start_point_destination_ready(_point_id)
$$;

-- Straight-line distance; travel time uses a 35% allowance at 1.1 m/s, minimum
-- one minute. This is an estimate, never a verified path or provider response.
create or replace function app_private.destination_estimate(
  _from_lat numeric,_from_lon numeric,_to_lat numeric,_to_lon numeric)
returns table(distance_m bigint,duration_seconds bigint,edge_ids uuid[])
language sql immutable set search_path='' as $$
  select d.meters,greatest(60,ceil(d.meters*1.35/1.1)::bigint),array[]::uuid[]
  from (select ceil(app_private.location_distance_m(_from_lat,_from_lon,_to_lat,_to_lon))::bigint meters
    where _from_lat between -90 and 90 and _to_lat between -90 and 90
      and _from_lon between -180 and 180 and _to_lon between -180 and 180) d
$$;

create or replace function app_private.start_point_readiness(_point_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.start_points; l jsonb; portal app_private.portals; reason text; confirmation timestamptz;
begin
  select * into p from app_private.start_points where id=_point_id;
  if p.id is null then return null; end if;
  l:=app_private.start_point_location(p.id);
  if not (l->>'valid')::boolean then reason:='START_POINT_'||(l->>'reason');
  elsif nullif(trim(p.private_address),'') is null then reason:='START_POINT_ADDRESS_MISSING'; end if;
  if reason is null and p.linked_portal_id is not null then
    select * into portal from app_private.portals where id=p.linked_portal_id and event_id=p.event_id;
    if portal.id is null or portal.lifecycle_status='archived' then reason:='LINKED_PORTAL_NOT_AVAILABLE';
    elsif p.counts_as_first_portal_visit and not app_private.portal_location_ready(portal.id) then
      reason:='LINKED_START_PORTAL_POSITION_INVALID'; end if;
  end if;
  confirmation:=app_private.start_point_confirmation(p.id);
  return jsonb_build_object('location',l,'canConfirm',reason is null,'confirmationReason',reason,
    'confirmed',confirmation is not null and reason is null,'confirmedAt',case when reason is null then confirmation end,
    'routeReady',app_private.start_point_destination_ready(p.id),'linkedPortalName',portal.name);
end;
$$;

revoke all on function app_private.portal_location(uuid),app_private.portal_location_ready(uuid),
  app_private.start_point_destination_ready(uuid),app_private.destination_estimate(numeric,numeric,numeric,numeric)
  from public,anon,authenticated;

-- Explicit replacements from the deployed function definitions.
CREATE OR REPLACE FUNCTION api.admin_startregie_confirm_point(_event_slug text, _point_id uuid, _expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; p app_private.start_points; readiness jsonb; current_confirmation timestamptz;
begin
  select * into e from app_private.events where slug=_event_slug;
  if e.id is null or auth.uid() is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from app_private.events where id=e.id for no key update;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
  select * into p from app_private.start_points where id=_point_id and event_id=e.id for update;
  if p.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode='P0002'; end if;
  if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  readiness:=app_private.start_point_readiness(p.id);
  if not (readiness->>'canConfirm')::boolean then
    raise exception '%',readiness->>'confirmationReason' using errcode='23514',
      detail=coalesce(readiness->>'linkedPortalName',p.public_label); end if;
  -- Confirmation concerns this stored destination, not optional street data.
  if not p.active then
    update app_private.start_points set active=true,version=version+1,updated_at=statement_timestamp()
      where id=p.id returning * into p;
  end if;
  current_confirmation:=app_private.start_point_confirmation(p.id);
  if current_confirmation is null then
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(e.id,auth.uid(),'start_point.confirmed','start_point',p.id,jsonb_build_object('version',p.version,
        'enabled',true,'locationHash',app_private.start_point_location_hash(p.id),'source',readiness->'location'->>'source'));
  end if;
  perform realtime.send(jsonb_build_object('resource','start_point','id',p.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',p.id,'version',p.version,'confirmed',true,'active',true,
    'readiness',app_private.start_point_readiness(p.id));
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.start_point_ready_at(_point_id uuid, _starts_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select app_private.start_point_safe_connection(p.id)
    and (p.available_from is null or _starts_at>=p.available_from)
    and (p.available_until is null or _starts_at<p.available_until)
    and (p.linked_portal_id is null or exists(select 1 from app_private.portals portal
      join app_private.portal_private_locations location on location.portal_id=portal.id and app_private.portal_location_ready(portal.id)
      where portal.id=p.linked_portal_id and portal.approval_status='approved' and portal.lifecycle_status='active'
        and portal.operation_status in ('open','scheduled') and exists(select 1 from app_private.portal_windows w
          where w.portal_id=portal.id and _starts_at>=w.opens_at and _starts_at<w.closes_at)))
    from app_private.start_points p where p.id=_point_id),false)
$function$;


CREATE OR REPLACE FUNCTION api.admin_startregie_move_group(_group_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _expected_group_version integer, _preference_match text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); group_record app_private.walking_groups; point_record app_private.start_points;
  settings app_private.event_route_settings; portal_record app_private.portals; slot_record app_private.start_slots;
  schedule_record app_private.group_schedule_revisions; result jsonb; group_children integer; occupied_groups integer; occupied_children integer;
begin
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if actor is null or group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if exists(select 1 from app_private.group_runs where group_id=group_record.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  if _expected_group_version is distinct from group_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  select * into point_record from app_private.start_points
    where id = _start_point_id and event_id = group_record.event_id and active for update;
  if point_record.id is null then raise exception 'START_POINT_NOT_AVAILABLE' using errcode = '23514'; end if;
  if not app_private.start_point_safe_connection(point_record.id) then raise exception 'START_POINT_NOT_VERIFIED' using errcode='23514'; end if;
  if not (app_private.start_point_location(point_record.id)->>'valid')::boolean then
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
        and _starts_at >= portal_window.opens_at and _starts_at < portal_window.closes_at) then
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
$function$;


CREATE OR REPLACE FUNCTION api.admin_startregie_slots_prepare(_event_slug text, _starts_at timestamp with time zone[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  where point.event_id = event_record.id and app_private.start_point_destination_ready(point.id)
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
$function$;


CREATE OR REPLACE FUNCTION api.admin_save_route_settings(_event_slug text, _settings jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  current_settings app_private.event_route_settings;
  next_mode text;
  next_final_portal uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_settings) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into current_settings from app_private.event_route_settings where event_id = v_event_id for update;
  if current_settings.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  next_mode := coalesce(_settings ->> 'plannerMode', current_settings.planner_mode);
  next_final_portal := coalesce(nullif(_settings ->> 'finalPortalId', '')::uuid, current_settings.final_portal_id);
  if next_mode not in ('disabled', 'shadow', 'dynamic') then raise exception 'INVALID_PLANNER_MODE' using errcode = '22023'; end if;
  if next_final_portal is not null and not exists (
    select 1 from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
    where portal.id = next_final_portal and portal.event_id = v_event_id and portal.approval_status = 'approved'
  ) then raise exception 'FINAL_PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  update app_private.event_route_settings set
    first_start_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'firstStartAt'), first_start_at),
    early_preference_latest_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'earlyPreferenceLatestAt'), early_preference_latest_at),
    later_preference_earliest_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'laterPreferenceEarliestAt'), later_preference_earliest_at),
    global_ordinary_stop_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'globalOrdinaryStopAt'), global_ordinary_stop_at),
    allowed_personal_stop_times = case when _settings ? 'allowedStopTimes'
      then array(select value::timestamptz from jsonb_array_elements_text(_settings -> 'allowedStopTimes') value order by value::timestamptz)
      else allowed_personal_stop_times end,
    ordinary_visit_seconds = coalesce((_settings ->> 'ordinaryVisitSeconds')::integer, ordinary_visit_seconds),
    route_buffer_seconds = coalesce((_settings ->> 'bufferSeconds')::integer, route_buffer_seconds),
    final_portal_id = next_final_portal,
    finale_opens_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleOpensAt'), finale_opens_at),
    finale_last_arrival_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleLastArrivalAt'), finale_last_arrival_at),
    finale_closes_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleClosesAt'), finale_closes_at),
    finale_show_seconds = coalesce((_settings ->> 'finaleShowSeconds')::integer, finale_show_seconds),
    finale_turnover_seconds = coalesce((_settings ->> 'finaleTurnoverSeconds')::integer, finale_turnover_seconds),
    finale_planning_transfer_seconds = coalesce((_settings ->> 'finalePlanningTransferSeconds')::integer, finale_planning_transfer_seconds),
    finale_max_concurrent_groups = coalesce((_settings ->> 'finaleMaxGroups')::integer, finale_max_concurrent_groups),
    finale_max_concurrent_children = coalesce((_settings ->> 'finaleMaxChildren')::integer, finale_max_concurrent_children),
    finale_safe_approach = case when _settings ? 'finaleSafeApproach' then nullif(trim(_settings ->> 'finaleSafeApproach'), '') else finale_safe_approach end,
    finale_waiting_area = case when _settings ? 'finaleWaitingArea' then nullif(trim(_settings ->> 'finaleWaitingArea'), '') else finale_waiting_area end,
    finale_exit_route = case when _settings ? 'finaleExitRoute' then nullif(trim(_settings ->> 'finaleExitRoute'), '') else finale_exit_route end,
    finale_accessible_entrance = case when _settings ? 'finaleAccessibleEntrance' then nullif(trim(_settings ->> 'finaleAccessibleEntrance'), '') else finale_accessible_entrance end,
    finale_contact = case when _settings ? 'finaleContact' then nullif(trim(_settings ->> 'finaleContact'), '') else finale_contact end,
    emergency_destination_name = case when _settings ? 'emergencyDestinationName' then nullif(trim(_settings ->> 'emergencyDestinationName'), '') else emergency_destination_name end,
    emergency_instructions = case when _settings ? 'emergencyInstructions' then nullif(trim(_settings ->> 'emergencyInstructions'), '') else emergency_instructions end,
    finale_available = coalesce((_settings ->> 'finaleAvailable')::boolean, finale_available),
    planner_mode = next_mode,
    updated_by = actor,
    version = version + 1
  where event_id = v_event_id returning * into current_settings;

  if current_settings.planner_mode in ('shadow', 'dynamic') and (
    current_settings.first_start_at is null or current_settings.global_ordinary_stop_at is null
    or current_settings.final_portal_id is null or current_settings.finale_opens_at is null
    or current_settings.finale_last_arrival_at is null or current_settings.finale_closes_at is null
  ) then raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514'; end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'route_settings.updated', 'event', v_event_id,
    jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode);
end;
$function$;


CREATE OR REPLACE FUNCTION api.admin_start_slot_save(_event_slug text, _slot_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _max_groups integer, _max_children integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  slot app_private.start_slots;
  route_settings app_private.event_route_settings; effective_location jsonb;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into point from app_private.start_points where id = _start_point_id and event_id = v_event_id and active;
  select * into route_settings from app_private.event_route_settings where event_id = v_event_id;
  effective_location:=app_private.start_point_location(point.id);
  if point.id is null or not app_private.start_point_destination_ready(point.id) or _max_groups < 1 or _max_children < 1
     or (route_settings.first_start_at is not null and _starts_at < route_settings.first_start_at)
     or (route_settings.global_ordinary_stop_at is not null and _starts_at >= route_settings.global_ordinary_stop_at)
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _slot_id is null then
    insert into app_private.start_slots(
      event_id, name, location_name, private_address, latitude, longitude, location_verified_at,
      starts_at, max_groups, max_children, start_point_id
    ) values (
      v_event_id, point.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point.name, point.private_address, (effective_location->>'latitude')::numeric, (effective_location->>'longitude')::numeric, coalesce(app_private.start_point_confirmation(point.id),point.verified_at),
      _starts_at, _max_groups, _max_children, point.id
    ) returning * into slot;
  else
    update app_private.start_slots set starts_at = _starts_at, max_groups = _max_groups,
      max_children = _max_children, start_point_id = point.id, location_name = point.name,
      private_address = point.private_address, latitude = (effective_location->>'latitude')::numeric, longitude = (effective_location->>'longitude')::numeric,
      location_verified_at = point.verified_at
    where id = _slot_id and event_id = v_event_id returning * into slot;
    if slot.id is null then raise exception 'START_SLOT_NOT_FOUND' using errcode = 'P0002'; end if;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_slot.saved', 'start_slot', slot.id, jsonb_build_object('startsAt', slot.starts_at, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at);
end;
$function$;


CREATE OR REPLACE FUNCTION api.admin_start_point_save(_event_slug text, _point_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  node_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_payload) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if nullif(_payload ->> 'walkingNodeId', '') is not null then
    select event_id into node_event_id from app_private.walking_nodes
    where id = (_payload ->> 'walkingNodeId')::uuid and kind in ('start', 'junction');
    if node_event_id is distinct from v_event_id then raise exception 'START_NODE_NOT_VERIFIED' using errcode = '23514'; end if;
  end if;
  if coalesce((_payload ->> 'verified')::boolean, false) and (
    not coalesce((app_private.routing_position(null,null,
      nullif(_payload->>'latitude','')::numeric,nullif(_payload->>'longitude','')::numeric,null,null)->>'valid')::boolean,false)
    or nullif(trim(_payload->>'privateAddress'),'') is null
  ) then raise exception 'START_POINT_NOT_ROUTE_READY' using errcode = '23514'; end if;
  if _point_id is null then
    insert into app_private.start_points(
      event_id, name, private_address, latitude, longitude, walking_node_id, accessible,
      accessibility_notes, max_gathering_groups, max_gathering_children, verified_at, verified_by
    ) values (
      v_event_id, trim(_payload ->> 'name'), trim(_payload ->> 'privateAddress'),
      nullif(_payload ->> 'latitude', '')::numeric, nullif(_payload ->> 'longitude', '')::numeric,
      nullif(_payload ->> 'walkingNodeId', '')::uuid, nullif(_payload ->> 'accessible', '')::boolean,
      nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      coalesce((_payload ->> 'maxGroups')::integer, 1), coalesce((_payload ->> 'maxChildren')::integer, 20),
      case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end
    ) returning * into point;
  else
    select * into point from app_private.start_points where id = _point_id and event_id = v_event_id for update;
    if point.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if point.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.start_points set
      name = trim(_payload ->> 'name'), private_address = trim(_payload ->> 'privateAddress'),
      latitude = nullif(_payload ->> 'latitude', '')::numeric, longitude = nullif(_payload ->> 'longitude', '')::numeric,
      walking_node_id = nullif(_payload ->> 'walkingNodeId', '')::uuid,
      accessible = nullif(_payload ->> 'accessible', '')::boolean,
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      max_gathering_groups = coalesce((_payload ->> 'maxGroups')::integer, max_gathering_groups),
      max_gathering_children = coalesce((_payload ->> 'maxChildren')::integer, max_gathering_children),
      verified_at = case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      verified_by = case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end,
      version = version + 1
    where id = point.id returning * into point;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_point.saved', 'start_point', point.id,
    jsonb_build_object('version', point.version, 'verified', point.verified_at is not null, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', point.id, 'version', point.version, 'verified', point.verified_at is not null);
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.validate_route_plan_stop()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  plan_record record;
  window_record app_private.portal_windows;
  portal_world_id uuid;
  active_children integer;
  overlapping_groups integer;
begin
  select plan.id as plan_id, plan.state, walking_group.id as group_id, walking_group.event_id,
         slot.external_id as start_external_id
    into plan_record
  from app_private.route_plan_versions plan
  join app_private.walking_groups walking_group on walking_group.id = plan.group_id
  join app_private.start_slots slot on slot.id = walking_group.start_slot_id
  where plan.id = new.plan_version_id;
  if plan_record.plan_id is null then raise exception 'INVALID_ROUTE_PLAN' using errcode = '23514'; end if;
  if new.position < 1 or new.planned_departure_at <= new.planned_arrival_at then
    raise exception 'INVALID_ROUTE_TIMING' using errcode = '23514';
  end if;

  select portal.world_id into portal_world_id
  from app_private.portals portal
  join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
  where portal.id = new.portal_id and portal.event_id = plan_record.event_id and portal.approval_status = 'approved' and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled');
  if portal_world_id is null then raise exception 'PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  select candidate.* into window_record
  from app_private.portal_windows candidate
  where candidate.portal_id = new.portal_id
    and new.planned_arrival_at >= candidate.opens_at
    and new.planned_departure_at <= candidate.closes_at
    and new.planned_departure_at = new.planned_arrival_at + make_interval(mins => candidate.visit_minutes)
  order by candidate.opens_at limit 1;
  if window_record.id is null then raise exception 'PORTAL_WINDOW_CONFLICT' using errcode = '23514'; end if;

  select count(*) into active_children
  from app_private.group_registrations assignment
  join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
  where assignment.group_id = plan_record.group_id and assignment.superseded_at is null;
  if active_children = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if active_children > window_record.max_children_per_visit then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  if exists (
    select 1 from app_private.route_plan_stops existing
    join app_private.portals portal on portal.id = existing.portal_id
    where existing.plan_version_id = new.plan_version_id and existing.id is distinct from new.id
      and (existing.portal_id = new.portal_id or portal.world_id = portal_world_id)
  ) then raise exception 'DUPLICATE_PORTAL_OR_WORLD' using errcode = '23514'; end if;

  select count(distinct existing_plan.group_id) into overlapping_groups
  from app_private.route_plan_stops existing
  join app_private.route_plan_versions existing_plan on existing_plan.id = existing.plan_version_id
  where existing.portal_id = new.portal_id and existing.id is distinct from new.id
    and existing_plan.group_id <> plan_record.group_id
    and existing_plan.state in ('valid', 'published')
    and existing.planned_arrival_at < new.planned_departure_at
    and existing.planned_departure_at > new.planned_arrival_at;
  if overlapping_groups >= window_record.max_concurrent_groups then raise exception 'PORTAL_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  return new;
end;
$function$;


CREATE OR REPLACE FUNCTION api.run_start(_group_id uuid, _present_registration_child_ids uuid[], _expected_group_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
  dispatch_result jsonb;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_present_registration_child_ids), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id
        and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  if group_record.route_mode = 'dynamic' then
    select * into schedule from app_private.group_schedule_revisions
    where group_id = group_record.id and state = 'published'
    order by revision desc limit 1;
    if schedule.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode = '23514'; end if;
    if clock_timestamp() < (select starts_at from app_private.group_start_publications where schedule_id=schedule.id order by publication_order desc limit 1) then
      raise exception 'START_TIME_NOT_REACHED' using errcode = '23514';
    end if;
    if exists (
      select 1 from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where assignment.group_id = _group_id and assignment.superseded_at is null
        and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
    ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at)
    values (_group_id, null, schedule.id, 'live', clock_timestamp()) returning id into v_run_id;
  else
    select id into plan_id from app_private.route_plan_versions
    where group_id = _group_id and state = 'published' order by revision desc limit 1;
    if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.group_start_publications where group_id=_group_id) then
    raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514'; end if;
  if clock_timestamp() < (select starts_at from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1) then raise exception 'START_TIME_NOT_REACHED' using errcode='23514'; end if;

    if exists(select 1 from app_private.route_plan_stops stop
      where stop.plan_version_id=plan_id and stop.position=1
        and not app_private.portal_location_ready(stop.portal_id)) then
      raise exception 'PORTAL_NOT_ROUTE_READY' using errcode='23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, status, started_at)
    values (_group_id, plan_id, 'live', clock_timestamp()) returning id into v_run_id;
  end if;

  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids)
      then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null
    and registration_child.participation_status = 'active';

  if group_record.route_mode = 'dynamic' then
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := app_private.dispatch_next_stop(v_run_id, clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id = v_run_id;
  else
    insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
    select v_run_id, stop.id, stop.position,
      case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when stop.position = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
    select id into first_stop_id from app_private.run_stops where run_id = v_run_id and sequence = 1;
    if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
    update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select first_stop_id, participant.id from app_private.run_participants participant
    where participant.run_id = v_run_id and participant.attendance = 'present';
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := jsonb_build_object('decision', 'legacy', 'stopId', first_stop_id);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (v_run_id, first_stop_id, 'run.started', actor, jsonb_build_object('routeMode', group_record.route_mode));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id, jsonb_build_object('routeMode', group_record.route_mode));
  result := jsonb_build_object('runId', v_run_id, 'dispatch', dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, result, now() + interval '2 days') returning * into receipt;
  return receipt.safe_result;
end;
$function$;


CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'readiness',app_private.start_point_readiness(p.id),
    'confirmed',app_private.start_point_readiness(p.id)->'confirmed',
    'latitude',app_private.start_point_location(p.id)->'latitude','longitude',app_private.start_point_location(p.id)->'longitude',
    'locationSource',app_private.start_point_location(p.id)->'source',
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'location',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude),
    'latitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'latitude',
    'longitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'longitude',
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item left join app_private.portal_private_locations l on l.portal_id=(item->>'id')::uuid),'[]'::jsonb),true);
  -- Replace only the obsolete marker test. Unassigned groups, capacity and
  -- publication checks remain independent and unchanged.
  base:=jsonb_set(base,'{warnings}',coalesce((select jsonb_agg(w) from jsonb_array_elements(base->'warnings') w
    where w->>'code' not in ('MISSING_MARKER','WALKING_ROUTE_MISSING')),'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object(
      'code','MISSING_MARKER','resourceId',p.id,'resourceType','start_point','action','kaart',
      'message',p.public_label||' — '||case r->>'confirmationReason'
        when 'START_POINT_POSITION_MISSING' then 'Geen opgeslagen positie — plaats een marker.'
        when 'START_POINT_POSITION_INVALID' then 'Ongeldige positie — controleer de coördinaten en sla opnieuw op.'
        when 'START_POINT_ADDRESS_MISSING' then 'Adres ontbreekt — vul het adres van deze startlocatie in.'
        when 'LINKED_PORTAL_NOT_AVAILABLE' then 'Gekoppelde poort niet beschikbaar — controleer deze poort.'
        when 'LINKED_START_PORTAL_POSITION_INVALID' then 'De gekoppelde eerste poort '||coalesce(r->>'linkedPortalName','')||' heeft geen geldig adres en positie — controleer deze poort.'
        else 'Controleer het opgeslagen adres en de marker van deze startlocatie.' end) order by p.name)
      from app_private.start_points p cross join lateral(select app_private.start_point_readiness(p.id) r) c
      where p.event_id=e.id and p.active and not (r->>'canConfirm')::boolean), '[]'::jsonb),true);
  base:=jsonb_set(base,'{stats,missingMarkers}',to_jsonb((select count(*) from app_private.start_points p
    where p.event_id=e.id and p.active and not (app_private.start_point_location(p.id)->>'valid')::boolean)),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.group_start_publications p1 where p1.group_id=g.id order by p1.publication_order desc limit 1) pub on true
    where g.event_id=e.id;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.start_ops_route_revision(_event_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select ('x'||substr(md5(jsonb_build_object('pool',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('location',to_jsonb(l),
    'windows',(select jsonb_agg(to_jsonb(w) order by w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id)::text
    from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id where p.event_id=_event_id),''),
    'settings',(select to_jsonb(s) from app_private.event_route_settings s where s.event_id=_event_id),
    'groups',(select jsonb_agg(jsonb_build_array(g.id,g.desired_ordinary_visits,g.current_schedule_revision_id,r.version,r.current_stop_id) order by g.id)
      from app_private.walking_groups g left join app_private.group_runs r on r.group_id=g.id where g.event_id=_event_id))::text),1,7))::bit(28)::integer
$function$;


CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop_before_visit_preference(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  settings app_private.event_route_settings;
  source_lat numeric; source_lon numeric; final_lat numeric; final_lon numeric; frozen_position jsonb;
  needs_step_free boolean;
  v_child_count integer;
  candidate record;
  finale_reservation_id uuid;
  ordinary_reservation_id uuid;
  next_stop_id uuid;
  next_sequence integer;
  potential_count integer := 0;
  finale_path record;
  earliest_finale timestamptz;
  decision_number integer;
  candidate_summary jsonb := '[]'::jsonb;
begin
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.status <> 'live' or run_record.current_stop_id is not null then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = run_record.schedule_revision_id and state = 'published';
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(group_record.event_id::text || ':route-dispatch', 0));

  update app_private.portal_reservations set status = 'expired', version = version + 1
  where event_id = group_record.event_id and status = 'held' and expires_at <= _decision_at;
  select count(*) into v_child_count from app_private.run_participants where run_id = _run_id and attendance = 'present';
  select exists (
    select 1 from app_private.run_participants participant
    join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
    join app_private.children child on child.id = registration_child.child_id
    where participant.run_id = _run_id and participant.attendance = 'present'
      and nullif(trim(child.accessibility_note), '') is not null
  ) into needs_step_free;
  select coalesce(max(sequence), 0) + 1 into next_sequence from app_private.run_stops where run_id = _run_id;
  select coalesce(max(sequence), 0) + 1 into decision_number from app_private.dispatch_decisions where run_id = _run_id;

  select (app_private.portal_location(stop.portal_id)->>'latitude')::numeric,
    (app_private.portal_location(stop.portal_id)->>'longitude')::numeric into source_lat,source_lon
  from app_private.run_stops stop where stop.run_id=_run_id and stop.plan_stop_id is null and stop.state='completed'
  order by stop.sequence desc limit 1;
  if source_lat is null or source_lon is null then
    select app_private.routing_position((p.point_snapshot->>'marker_latitude')::numeric,(p.point_snapshot->>'marker_longitude')::numeric,
      (p.point_snapshot->>'geocoded_latitude')::numeric,(p.point_snapshot->>'geocoded_longitude')::numeric,
      (p.point_snapshot->>'latitude')::numeric,(p.point_snapshot->>'longitude')::numeric) into frozen_position
    from app_private.group_start_publications p where p.group_id=group_record.id and p.schedule_id=run_record.schedule_revision_id
    order by p.publication_order desc limit 1;
    source_lat:=(frozen_position->>'latitude')::numeric; source_lon:=(frozen_position->>'longitude')::numeric;
  end if;
  if source_lat is null or source_lon is null then raise exception 'SOURCE_POSITION_INVALID' using errcode='23514'; end if;
  select (app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,
    (app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric into final_lat,final_lon;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.event_id=group_record.event_id
      and portal.approval_status='approved' and portal.lifecycle_status='active'
      and app_private.portal_location_ready(portal.id) and portal.operation_status in ('open', 'scheduled')
  ) then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_UNAVAILABLE',
      'De eindpoort is niet veilig beschikbaar. Activeer de voorbereide noodafsluiting.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
    values (group_record.event_id, _run_id, decision_number, 'emergency', jsonb_build_object('decidedAt', _decision_at), candidate_summary,
      'Eindpoort niet beschikbaar; geen adres automatisch gepubliceerd');
    return jsonb_build_object('decision', 'emergency', 'paused', true);
  end if;

  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      select portal.id as portal_id, portal.world_id, portal.name,
        source_path.distance_m as incoming_distance_m, source_path.duration_seconds as incoming_seconds,
        source_path.edge_ids as incoming_edge_ids,
        final_path.duration_seconds as finale_seconds,
        _decision_at + make_interval(secs => source_path.duration_seconds::integer) as arrival_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) as departure_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) as earliest_finale_at,
        source_path.duration_seconds
          + case when portal.world_id = (
              select previous_portal.world_id from app_private.run_stops previous_stop
              join app_private.portals previous_portal on previous_portal.id = previous_stop.portal_id
              where previous_stop.run_id = _run_id and previous_stop.state = 'completed'
              order by previous_stop.sequence desc limit 1
            ) then 120 else 0 end
          + (select count(*) * 30 from app_private.portal_reservations pressure
             where pressure.portal_id = portal.id and pressure.status in ('held', 'active')) as score
      from app_private.portals portal
      left join app_private.portal_applications application on application.id = portal.application_id
      join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
      cross join lateral app_private.destination_estimate(source_lat,source_lon,coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude)) source_path
      cross join lateral app_private.destination_estimate(coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude),final_lat,final_lon) final_path
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
        and exists (
          select 1 from app_private.portal_windows portal_window
          where portal_window.portal_id = portal.id
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) >= portal_window.opens_at
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) < portal_window.closes_at
            and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer) <= portal_window.closes_at
            and portal_window.max_children_per_visit>=v_child_count
        )
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at
        and not exists (
          select 1 from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')
            and (reservation.expires_at is null or reservation.expires_at > _decision_at)
            and reservation.reserved_from < _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer)
            and reservation.reserved_until > _decision_at + make_interval(secs => source_path.duration_seconds::integer)
        )
      order by score, incoming_distance_m, portal.id
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds)
      ) returning id into ordinary_reservation_id;
      insert into app_private.run_stops(
        run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at
      ) values (
        _run_id, candidate.portal_id, ordinary_reservation_id, 'ordinary', next_sequence, 'active', _decision_at
      ) returning id into next_stop_id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop_id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
      insert into app_private.dispatch_decisions(
        event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
        input_snapshot, candidate_summary, reason
      ) values (
        group_record.event_id, _run_id, decision_number, candidate.portal_id, 'ordinary', 'ordinary',
        jsonb_build_object(
          'decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op geschatte reistijd, beschikbaarheid en finalehaalbaarheid'
      );
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'ordinary', 'portalId', candidate.portal_id));
      return jsonb_build_object('decision', 'ordinary', 'stopId', next_stop_id, 'portalId', candidate.portal_id);
    end loop;

    if _preferred_portal_id is not null then
      raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;

    select count(*) into potential_count
    from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
    cross join lateral app_private.destination_estimate(source_lat,source_lon,coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude)) source_path
    cross join lateral app_private.destination_estimate(coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude),final_lat,final_lon) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at;
    if potential_count > 0 then
      insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
      values (group_record.event_id, _run_id, decision_number, 'wait',
        jsonb_build_object('decidedAt', _decision_at, 'effectiveStopAt', schedule.effective_ordinary_stop_at),
        candidate_summary, 'Veilige kandidaten zijn tijdelijk bezet; opnieuw beoordelen');
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select group_record.event_id, group_record.id, _run_id, 'warning', 'NO_CURRENT_CAPACITY',
        'Geen gewone poort is nu reserveerbaar; automatische herbeoordeling is nodig.'
      where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'NO_CURRENT_CAPACITY');
      return jsonb_build_object('decision', 'wait', 'retryAfterSeconds', 120);
    end if;
  end if;

  select * into finale_path from app_private.destination_estimate(source_lat,source_lon,final_lat,final_lon);
  if finale_path.duration_seconds is null then raise exception 'FINAL_PORTAL_POSITION_INVALID' using errcode = '23514'; end if;
  earliest_finale := _decision_at + make_interval(secs => finale_path.duration_seconds::integer);
  finale_reservation_id := app_private.try_reserve_finale(_run_id, earliest_finale, _decision_at);
  if finale_reservation_id is null then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_WINDOW_FULL',
      'Geen veilig aankomstvenster bij de eindpoort beschikbaar; handmatige herplanning vereist.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_WINDOW_FULL');
    return jsonb_build_object('decision', 'wait', 'finaleFull', true);
  end if;
  update app_private.portal_reservations set status = 'active', version = version + 1 where id = finale_reservation_id;
  insert into app_private.run_stops(run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at)
  values (_run_id, settings.final_portal_id, finale_reservation_id, 'finale', next_sequence, 'active', _decision_at)
  returning id into next_stop_id;
  insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
  select next_stop_id, participant.id from app_private.run_participants participant
  where participant.run_id = _run_id and participant.attendance = 'present';
  update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
  insert into app_private.dispatch_decisions(
    event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
    input_snapshot, candidate_summary, reason
  ) values (
    group_record.event_id, _run_id, decision_number, settings.final_portal_id, 'finale', 'finale',
    jsonb_build_object('decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.start_ops_route_preview(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; point app_private.start_points;
  slot app_private.start_slots; settings app_private.event_route_settings; r app_private.group_runs;
  last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; chosen uuid[]:='{}'::uuid[]; candidate record;
  meters bigint:=0; seconds bigint:=0; walk_m bigint; walk_s bigint; provisional boolean:=false;
  remaining integer; visited integer:=0; child_count integer; fixed_portal uuid;
  preserved_portal uuid; eligible integer; step_free boolean;
begin
  select * into g from app_private.walking_groups where id=_group_id;
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id;
  select * into slot from app_private.start_slots where id=coalesce(s.start_slot_id,g.start_slot_id);
  select * into point from app_private.start_points where id=slot.start_point_id;
  select * into settings from app_private.event_route_settings where event_id=g.event_id;
  if point.id is null or slot.id is null then return jsonb_build_object('groupId',g.id,'hasConfirmedStart',false,'stops','[]'::jsonb,'warnings',jsonb_build_array('Kies en bevestig eerst een startpunt en tijd.')); end if;
  select * into r from app_private.group_runs where group_id=g.id order by created_at desc limit 1;
  select count(*) into child_count from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
  select exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id
    join app_private.children c on c.id=rc.child_id where a.group_id=g.id and a.superseded_at is null
      and rc.participation_status='active' and nullif(trim(c.accessibility_note),'') is not null) into step_free;
  last_lon:=(app_private.start_point_location(point.id)->>'longitude')::numeric;
  last_lat:=(app_private.start_point_location(point.id)->>'latitude')::numeric;
  start_time:=slot.starts_at; at_time:=slot.starts_at;
  if r.id is not null then
    at_time:=greatest(at_time,statement_timestamp());
    select coalesce(array_agg(coalesce(rs.portal_id,ps.portal_id)),array[]::uuid[]),
      count(*) filter(where coalesce(rs.stop_kind::text,'ordinary')='ordinary' and rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=rs.id))
    into chosen,visited from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
    where rs.run_id=r.id and rs.state='completed';
    select coalesce(rs.portal_id,ps.portal_id) into preserved_portal from app_private.run_stops rs
      left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=r.current_stop_id;
    select (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'longitude')::numeric,
      (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'latitude')::numeric into last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    last_lon:=coalesce(last_lon,(app_private.start_point_location(point.id)->>'longitude')::numeric);
    last_lat:=coalesce(last_lat,(app_private.start_point_location(point.id)->>'latitude')::numeric);
  end if;
  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;
  if not point.counts_as_first_portal_visit and point.linked_portal_id is not null and point.linked_portal_id is distinct from preserved_portal then
    chosen:=array_append(chosen,point.linked_portal_id);
  elsif point.counts_as_first_portal_visit and r.id is null then fixed_portal:=point.linked_portal_id; end if;
  select count(*) into eligible from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
    where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')
      and p.id<>settings.final_portal_id;

  loop
    exit when remaining<=0 and preserved_portal is null;
    select q.* into candidate from (
      select p.id,p.name,p.system_code,p.world_id,w.name world,l.*,
        coalesce(m.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
          coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))))::bigint walk_m,
        m.duration_seconds::bigint walk_s,
        true geographic,
        final_path.duration_seconds final_seconds
      from app_private.portals p join app_private.worlds w on w.id=p.world_id
      join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
      left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true
      left join lateral app_private.destination_estimate(coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) final_path on true
      where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen))
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
        and (p.id=preserved_portal or not step_free or exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free'))
        and (preserved_portal is null or p.id=preserved_portal)
        and (preserved_portal is not null or fixed_portal is null or p.id=fixed_portal)
    ) q where q.walk_s is not null and (q.id=preserved_portal or (
      at_time+make_interval(secs=>(q.walk_s+settings.ordinary_visit_seconds+settings.route_buffer_seconds)::integer)<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and q.final_seconds is not null
      and at_time+make_interval(secs=>(q.walk_s+settings.ordinary_visit_seconds+settings.route_buffer_seconds+q.final_seconds)::integer)<=settings.finale_last_arrival_at
      and exists(select 1 from app_private.portal_windows win where win.portal_id=q.id
        and at_time+make_interval(secs=>q.walk_s::integer)>=win.opens_at
        and at_time+make_interval(secs=>q.walk_s::integer)<win.closes_at
        and at_time+make_interval(secs=>(q.walk_s+settings.ordinary_visit_seconds)::integer)<=win.closes_at
        and win.max_children_per_visit>=child_count)))
    order by q.walk_s,q.walk_m,q.id limit 1;
    if candidate.id is null then
      if fixed_portal is not null then warnings:=warnings||jsonb_build_array('De gekoppelde eerste poort past niet veilig in dit tijdvenster. Controleer de afspraak.'); end if;
      exit;
    end if;
    walk_m:=candidate.walk_m; walk_s:=candidate.walk_s;
    provisional:=provisional or candidate.geographic;
    at_time:=at_time+make_interval(secs=>walk_s::integer);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world',candidate.world,'kind','ordinary',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,
      'status',case when candidate.id=preserved_portal then 'current' else 'expected' end));
    meters:=meters+walk_m; seconds:=seconds+walk_s+settings.ordinary_visit_seconds+settings.route_buffer_seconds;
    at_time:=at_time+make_interval(secs=>settings.ordinary_visit_seconds+settings.route_buffer_seconds);
    last_lon:=coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude);
    last_lat:=coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude);
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null and app_private.portal_location_ready(candidate.id) and candidate.duration_seconds is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude),coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude))))::bigint;
    walk_s:=candidate.duration_seconds;
    provisional:=true;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','finale',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>settings.finale_last_arrival_at or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('De eindpoort heeft geen geldig opgeslagen adres of marker — controleer de eindpoort.'); end if;
  if provisional then warnings:=warnings||jsonb_build_array('Afstanden zijn hemelsbreed; reistijden zijn schattingen. Kies zelf hoe je naar de volgende poort gaat.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      (app_private.start_point_location(point.id)->>'longitude')::numeric,(app_private.start_point_location(point.id)->>'latitude')::numeric),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'distanceMethod','straight_line','travelTimeEstimated',true,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$;

-- Compatibility path for choosing a start from an existing approved house.
CREATE OR REPLACE FUNCTION api.admin_startregie_start_point_from_portal(_event_slug text, _portal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; p app_private.portals; l app_private.portal_private_locations; existing app_private.start_points;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.portals where id=_portal_id and event_id=e.id and approval_status='approved' and lifecycle_status='active';
  select * into l from app_private.portal_private_locations where portal_id=p.id and app_private.portal_location_ready(p.id);
  if p.id is null or l.portal_id is null then raise exception 'LINKED_PORTAL_NOT_AVAILABLE' using errcode='23514'; end if;
  select * into existing from app_private.start_points where event_id=e.id and linked_portal_id=p.id and active order by id limit 1;
  if existing.id is not null then return jsonb_build_object('id',existing.id,'version',existing.version,'reused',true); end if;
  return api.admin_startregie_start_point_save(_event_slug,null,jsonb_build_object(
    'pointType','portal','linkedPortalId',p.id,'countsAsFirstPortalVisit',true,'name',p.name,'publicLabel',p.name,
    'privateAddress',concat_ws(' ',l.street,l.house_number,l.addition),'geocodedLatitude',coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),
    'geocodedLongitude',coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),'active',true,
    'maxGroups',1,'maxChildren',coalesce((select max(max_children_per_visit) from app_private.portal_windows where portal_id=p.id),app_private.event_group_size_limit(e.id))),
    null,'Goedgekeurde poort overnemen als te controleren startpunt');
end;
$function$;
