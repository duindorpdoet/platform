create table if not exists app_private.portal_maintenance_drafts (
 portal_id uuid primary key references app_private.portals(id) on delete cascade,payload jsonb not null,actor_id uuid not null references auth.users(id),updated_at timestamptz not null default clock_timestamp());
alter table app_private.portal_maintenance_drafts enable row level security;
revoke all on app_private.portal_maintenance_drafts from public,anon,authenticated;
create or replace function api.admin_portal_change_impact(_portal_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.portals;
begin
 select * into p from app_private.portals where id=_portal_id;
 if p.id is null or not(app_private.has_capability(p.event_id,'portals_manage',auth.uid()) or app_private.has_capability(p.event_id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return jsonb_build_object('portalId',p.id,'version',p.version,'name',p.name,'code',p.system_code,
 'draftGroups',coalesce((select jsonb_agg(jsonb_build_object('code',g.system_code,'startsAt',slot.starts_at)) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id and s.state='draft' join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points point on point.id=slot.start_point_id where point.linked_portal_id=p.id and g.retired_at is null),'[]'),
 'publishedGroups',coalesce((select jsonb_agg(jsonb_build_object('code',g.system_code,'startsAt',pub.starts_at)) from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub where pub.point_snapshot->>'linked_portal_id'=p.id::text),'[]'),
 'pendingStops',(select count(*) from app_private.run_stops s join app_private.group_runs r on r.current_stop_id=s.id and r.status in ('live','paused') left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where coalesce(s.portal_id,ps.portal_id)=p.id),
 'reservations',(select count(*) from app_private.portal_reservations r where r.portal_id=p.id and r.status in ('held','active')),
 'finale',exists(select 1 from app_private.event_route_settings s where s.final_portal_id=p.id));
end $$;
revoke all on function api.admin_portal_change_impact(uuid) from public,anon;
grant execute on function api.admin_portal_change_impact(uuid) to authenticated;


CREATE OR REPLACE FUNCTION api.admin_manual_portal_save(_event_slug text, _portal_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
<<portal_save>>
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
  node_id uuid; current_window record; routing jsonb;
begin
  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'portals_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if jsonb_typeof(_payload) is distinct from 'object' or char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
  -- Active incomplete legacy records can retain safe edits as a maintenance draft without changing live status.
  if _payload->>'saveMode'='draft' and _portal_id is not null and exists(select 1 from app_private.portals p where p.id=_portal_id and p.event_id=event_record.id and p.lifecycle_status='active') then
    select * into portal_record from app_private.portals where id=_portal_id and event_id=event_record.id for update;
    if portal_record.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
    insert into app_private.portal_maintenance_drafts(portal_id,payload,actor_id) values(_portal_id,_payload,actor) on conflict(portal_id) do update set payload=excluded.payload,actor_id=excluded.actor_id,updated_at=clock_timestamp();
    update app_private.portals set version=version+1 where id=_portal_id returning * into portal_record;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(event_record.id,actor,'portal.maintenance_draft_saved','portal',_portal_id,jsonb_build_object('reason',_reason));
    return jsonb_build_object('id',_portal_id,'version',portal_record.version,'draftSaved',true,'lifecycleStatus',portal_record.lifecycle_status);
  end if;
  -- Share the dispatch mutex before locking a portal so a concurrent route cannot select a removed record.
  perform pg_advisory_xact_lock(hashtextextended(event_record.id::text || ':route-dispatch', 0));
  select * into world_record from app_private.worlds
    where event_id = event_record.id and slug = _payload ->> 'worldSlug';
  if world_record.id is null or lifecycle not in ('concept', 'registered', 'approved', 'active', 'archived')
    or approval not in ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'withdrawn')
    or operation not in ('scheduled', 'open', 'paused', 'closed')
    or char_length(trim(coalesce(_payload ->> 'name', ''))) not between 2 and 120
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if lifecycle = 'archived' then raise exception 'USE_PORTAL_REMOVE_COMMAND' using errcode='23514'; end if;
  if (opens_at is null) <> (closes_at is null) or (opens_at is not null and opens_at >= closes_at) then
    if lifecycle='active' then raise exception 'INVALID_AVAILABILITY' using errcode='22023';end if;
    -- Preserve the incomplete draft fields privately; only complete valid windows become operational.
    select min(w.opens_at),max(w.closes_at) into opens_at,closes_at from app_private.portal_windows w where w.portal_id=_portal_id;
  end if;
  if (latitude is not null or longitude is not null) and not (app_private.routing_position(null,null,latitude,longitude,null,null)->>'valid')::boolean then
    raise exception 'INVALID_COORDINATE' using errcode='22023'; end if;
  if jsonb_typeof(_payload->'routingMarker')='object' and not coalesce((_payload->'routingMarker'->>'restoreFromAddress')::boolean,false) then
    routing:=app_private.routing_position((_payload->'routingMarker'->>'latitude')::numeric,(_payload->'routingMarker'->>'longitude')::numeric,null,null,null,null);
  else
    select app_private.routing_position(l.marker_latitude,l.marker_longitude,portal_save.latitude,portal_save.longitude,null,null) into routing
      from app_private.portal_private_locations l join app_private.portals p on p.id=l.portal_id and p.event_id=event_record.id where l.portal_id=_portal_id;
    routing:=coalesce(routing,app_private.routing_position(null,null,latitude,longitude,null,null));
  end if;
  if lifecycle = 'active' and (approval <> 'approved' or not (routing->>'valid')::boolean or opens_at is null or closes_at is null or opens_at >= closes_at) then
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
    geocoded_latitude = excluded.geocoded_latitude,
    geocoded_longitude = excluded.geocoded_longitude,
    marker_latitude = app_private.portal_private_locations.marker_latitude,
    marker_longitude = app_private.portal_private_locations.marker_longitude,
    latitude = coalesce(app_private.portal_private_locations.marker_latitude,excluded.latitude),
    longitude = coalesce(app_private.portal_private_locations.marker_longitude,excluded.longitude),
    verified_at = case when coalesce(app_private.portal_private_locations.marker_latitude, excluded.latitude) is not null then now() end,
    verified_by = case when coalesce(app_private.portal_private_locations.marker_latitude, excluded.latitude) is not null then actor end,
    updated_at = now();
  select count(*)::integer window_count,min(w.opens_at) opens_at,max(w.closes_at) closes_at,
    max(w.visit_minutes) visit_minutes,max(w.buffer_minutes) buffer_minutes,
    max(w.max_concurrent_groups) max_groups,max(w.max_children_per_visit) max_children
    into current_window from app_private.portal_windows w where w.portal_id=portal_record.id;
  if row(opens_at,closes_at,coalesce((_payload->>'visitMinutes')::integer,5),coalesce((_payload->>'bufferMinutes')::integer,2),
    coalesce((_payload->>'maxGroups')::integer,1),coalesce((_payload->>'maxChildren')::integer,20))
    is distinct from row(current_window.opens_at,current_window.closes_at,coalesce(current_window.visit_minutes,5),
      coalesce(current_window.buffer_minutes,2),coalesce(current_window.max_groups,1),coalesce(current_window.max_children,20)) then
    if current_window.window_count>1 then raise exception 'MULTIPLE_AVAILABILITY_WINDOWS' using errcode='23514'; end if;
    if opens_at is null then
      delete from app_private.portal_windows where portal_id=portal_record.id;
    elsif current_window.window_count=1 then
      update app_private.portal_windows set opens_at=portal_save.opens_at,
        closes_at=portal_save.closes_at,visit_minutes=coalesce((_payload->>'visitMinutes')::integer,5),
        buffer_minutes=coalesce((_payload->>'bufferMinutes')::integer,2),
        max_concurrent_groups=coalesce((_payload->>'maxGroups')::integer,1),max_children_per_visit=coalesce((_payload->>'maxChildren')::integer,20)
        where portal_id=portal_record.id;
    else
      insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit)
        values(portal_record.id,opens_at,closes_at,coalesce((_payload->>'visitMinutes')::integer,5),coalesce((_payload->>'bufferMinutes')::integer,2),
          coalesce((_payload->>'maxGroups')::integer,1),coalesce((_payload->>'maxChildren')::integer,20));
    end if;
  end if;
  -- Address maintenance preserves the effective manual pin and its graph node.
  select coalesce(x.marker_latitude,x.geocoded_latitude,x.latitude),coalesce(x.marker_longitude,x.geocoded_longitude,x.longitude)
    into latitude,longitude from app_private.portal_private_locations x where x.portal_id=portal_record.id;
  if latitude is not null then
    select id into node_id from app_private.walking_nodes where portal_id = portal_record.id limit 1;
    if node_id is null then
      insert into app_private.walking_nodes(event_id, kind, portal_id, coordinate, verified_at, verified_by)
      values (event_record.id, 'portal', portal_record.id, point(longitude, latitude), null, null) returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(longitude, latitude) where id = node_id;
    end if;
  end if;
  if coalesce((_payload ->> 'isFinal')::boolean, false) and not exists(select 1 from app_private.event_route_settings where event_id=event_record.id and final_portal_id=portal_record.id) then
    if not coalesce((_payload ->> 'confirmFinal')::boolean, false) then raise exception 'FINAL_PORTAL_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
    update app_private.event_route_settings set final_portal_id = portal_record.id, updated_at = now(), updated_by = actor,
      version = version + 1 where event_id = event_record.id;
  end if;
  -- Only a conscious edit in the routing editor may replace an override.
  if jsonb_typeof(_payload->'routingMarker')='object' then
    perform api.admin_location_marker_save(_event_slug,'portal',portal_record.id,
      (_payload->'routingMarker'->>'latitude')::numeric,(_payload->'routingMarker'->>'longitude')::numeric,
      _payload->'routingMarker'->>'reason',coalesce((_payload->'routingMarker'->>'restoreFromAddress')::boolean,false),portal_record.version);
    select * into portal_record from app_private.portals where id=portal_record.id;
  end if;
  if _payload ? 'candidateStartPoint' then
    perform app_private.sync_portal_start_choice(portal_record.id,coalesce((_payload->>'candidateStartPoint')::boolean,false));
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, case when _portal_id is null then 'portal.manual_created' else 'portal.admin_updated' end,
    'portal', portal_record.id, jsonb_build_object('code', portal_record.system_code, 'lifecycle', portal_record.lifecycle_status,
      'source', portal_record.record_source, 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', portal_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  if lifecycle<>'active' then
    insert into app_private.portal_maintenance_drafts(portal_id,payload,actor_id) values(portal_record.id,_payload,actor) on conflict(portal_id) do update set payload=excluded.payload,actor_id=excluded.actor_id,updated_at=clock_timestamp();
  else delete from app_private.portal_maintenance_drafts where portal_id=portal_record.id;end if;
  return jsonb_build_object('id', portal_record.id, 'code', portal_record.system_code,
    'version', portal_record.version, 'lifecycleStatus', portal_record.lifecycle_status);
end;
$function$
;


CREATE OR REPLACE FUNCTION api.admin_portal_editor_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_record app_private.events; actor uuid:=auth.uid();
begin
  select * into event_record from app_private.events where slug=_event_slug;
  if actor is null or event_record.id is null or not (app_private.has_capability(event_record.id,'portals_manage',actor)
    or app_private.has_capability(event_record.id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  return jsonb_build_object(
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'code', portal.system_code, 'systemCode', portal.system_code,
        'name', portal.name, 'world', world.name, 'worldSlug', world.slug,
        'color', coalesce(portal.color, '#d59658'), 'description', portal.description,
        'maintenanceDraft',(select d.payload from app_private.portal_maintenance_drafts d where d.portal_id=portal.id),
        'intensity',portal.intensity,'accessibilityNotes',portal.accessibility_notes,'internalNotes',portal.internal_notes,
        'street',location.street,'houseNumber',location.house_number,'addition',location.addition,
        'visitMinutes',portal_window.visit_minutes,'bufferMinutes',portal_window.buffer_minutes,'windowCount',portal_window.window_count,
        'walkingConnectionVerified',app_private.portal_has_verified_walking_connection(portal.id),
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
        'candidateStartPoint', exists(select 1 from app_private.start_points sp where sp.linked_portal_id=portal.id and sp.active),
        'isFinal', portal.id = settings.final_portal_id, 'version', portal.version
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_applications application on application.id = portal.application_id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join lateral (select min(opens_at) opens_at, max(closes_at) closes_at,
        max(max_concurrent_groups) max_concurrent_groups, max(max_children_per_visit) max_children_per_visit,
        max(visit_minutes) visit_minutes,max(buffer_minutes) buffer_minutes,count(*)::integer window_count
        from app_private.portal_windows where portal_id = portal.id) portal_window on true
      left join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = event_record.id and portal.lifecycle_status <> 'archived'
    ), '[]'::jsonb)
  );
end;
$function$
;


CREATE OR REPLACE FUNCTION api.portal_arrivals_snapshot(_portal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      where stop.portal_id = portal_record.id and walking_group.retired_at is null and walking_group.current_plan_version_id=plan.id
      union all
      select walking_group.id, walking_group.system_code, walking_group.display_name,
        reservation.reserved_from, reservation.reserved_until,
        case reservation.status when 'active' then 'active' when 'completed' then 'completed' else 'planned' end,
        'assigned'
      from app_private.portal_reservations reservation
      join app_private.walking_groups walking_group on walking_group.id = reservation.group_id
      where reservation.portal_id = portal_record.id and reservation.status in ('held', 'active', 'completed')
      union all
      select g.id,g.system_code,g.display_name,pub.starts_at,pub.starts_at+make_interval(secs=>coalesce(app_private.portal_service_seconds(portal_record.id,pub.starts_at),600)),
        'confirmed_start','assigned'
      from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub
      where pub.point_snapshot->>'linked_portal_id'=portal_record.id::text
        and not exists(select 1 from app_private.portal_reservations b where b.group_id=g.id and b.portal_id=portal_record.id and b.status in ('held','active','completed'))
        and not app_private.group_has_visited_portal(g.event_id,g.id,portal_record.id)
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
        'groupId',enriched.group_id,'displayName',enriched.display_name,'groupCode', enriched.group_code, 'systemCode', enriched.group_code,
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
$function$
;


CREATE OR REPLACE FUNCTION api.admin_manual_portal_remove(_portal_id uuid, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); portal_record app_private.portals; relation_count integer; active_assignments integer; v_event_id uuid;
begin
  select event_id into v_event_id from app_private.portals where id=_portal_id;
  if actor is null or v_event_id is null or not (app_private.has_capability(v_event_id,'portals_manage',actor)
    or app_private.has_capability(v_event_id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from app_private.events where id=v_event_id for no key update;
  perform pg_advisory_xact_lock(hashtextextended(v_event_id::text || ':route-dispatch', 0));
  select * into portal_record from app_private.portals where id = _portal_id for update;
  if actor is null or portal_record.id is null or not (
    app_private.has_capability(portal_record.event_id, 'portals_manage', actor)
    or app_private.has_capability(portal_record.event_id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
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
  if active_assignments > 0 or exists(select 1 from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub where pub.point_snapshot->>'linked_portal_id'=portal_record.id::text) then raise exception 'RESOLVE_ACTIVE_ASSIGNMENTS_FIRST:%', active_assignments using errcode = '23514'; end if;
  if exists(select 1 from app_private.portal_reservations where portal_id=portal_record.id and status in ('held','active'))
    or exists(select 1 from app_private.run_stops stop join app_private.group_runs run on run.current_stop_id=stop.id
      where coalesce(stop.portal_id,(select ps.portal_id from app_private.route_plan_stops ps where ps.id=stop.plan_stop_id))=portal_record.id and run.status in ('ready','live','paused')) then
    raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514';
  end if;
  select (select count(*) from app_private.portal_reservations where portal_id = portal_record.id)
    + (select count(*) from app_private.route_plan_stops where portal_id = portal_record.id)
    + (select count(*) from app_private.audit_events where resource_type = 'portal' and resource_id = portal_record.id)
  into relation_count;
  if portal_record.record_source = 'manual' and portal_record.lifecycle_status = 'concept' and relation_count <= 1
    and not exists (select 1 from app_private.start_points where linked_portal_id = portal_record.id) then
    begin
      delete from app_private.portals where id = portal_record.id;
      return jsonb_build_object('id', _portal_id, 'deleted', true, 'archived', false);
    exception when foreign_key_violation then null; -- Preserve any additional historical references.
    end;
  end if;
  update app_private.start_points set active = false, updated_at = now(), version = version + 1
    where linked_portal_id = portal_record.id;
  update app_private.portals set lifecycle_status = 'archived', approval_status = 'withdrawn', operation_status='closed',
    archived_at = now(), archived_by = actor, updated_at = now(), version = version + 1
    where id = portal_record.id returning * into portal_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal_record.event_id, actor, 'portal.archived', 'portal', portal_record.id,
    jsonb_build_object('reason', left(trim(_reason), 500), 'historicalRelations', relation_count));
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', portal_record.id),
    'snapshot_changed', 'admin-event:' || portal_record.event_id::text, true);
  return jsonb_build_object('id', portal_record.id, 'deleted', false, 'archived', true, 'version', portal_record.version);
end;
$function$
;
