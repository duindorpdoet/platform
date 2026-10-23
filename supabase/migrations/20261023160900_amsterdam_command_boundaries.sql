-- Validate Amsterdam instants at each real JSON command boundary.

CREATE OR REPLACE FUNCTION api.admin_startregie_start_point_save(_event_slug text, _point_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; effective_latitude numeric; effective_longitude numeric; node_id uuid;
  point_kind text := coalesce(nullif(_payload ->> 'pointType', ''), 'gathering');
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
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
      nullif(trim(_payload ->> 'internalNotes'), ''), app_private.parse_amsterdam_instant(_payload->>'availableFrom'),
      app_private.parse_amsterdam_instant(_payload->>'availableUntil'),
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
      available_from = app_private.parse_amsterdam_instant(_payload->>'availableFrom'),
      available_until = app_private.parse_amsterdam_instant(_payload->>'availableUntil'),
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
$function$
;

CREATE OR REPLACE FUNCTION api.admin_manual_portal_save(_event_slug text, _portal_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); event_record app_private.events; portal_record app_private.portals;
  world_record app_private.worlds; lifecycle text := coalesce(nullif(_payload ->> 'lifecycleStatus', ''), 'concept');
  approval text := coalesce(nullif(_payload ->> 'approvalStatus', ''), 'draft');
  operation text := coalesce(nullif(_payload ->> 'operationStatus', ''), 'scheduled');
  latitude numeric := nullif(_payload ->> 'latitude', '')::numeric;
  longitude numeric := nullif(_payload ->> 'longitude', '')::numeric;
  opens_at timestamptz := app_private.parse_amsterdam_instant(_payload->>'plannedOpensAt');
  closes_at timestamptz := app_private.parse_amsterdam_instant(_payload->>'plannedClosesAt');
  system_number_input integer := nullif(_payload ->> 'systemNumber', '')::integer;
  node_id uuid;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
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
      values (event_record.id, 'portal', portal_record.id, point(longitude, latitude), null, null) returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(longitude, latitude) where id = node_id;
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
$function$
;

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
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes node on node.portal_id = portal.id and node.verified_at is not null
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
$function$
;

CREATE OR REPLACE FUNCTION api.admin_location_marker_save(_event_slug text, _resource_type text, _resource_id uuid, _latitude numeric, _longitude numeric, _reason text, _restore_from_address boolean, _expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; location_record app_private.portal_private_locations;
  effective_latitude numeric; effective_longitude numeric; node_id uuid; next_version integer;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
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
      values (event_record.id, 'portal', portal_record.id, point(effective_longitude, effective_latitude), null, null)
      returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(effective_longitude, effective_latitude) where id = node_id;
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
$function$
;
