-- Portal management hotfix: no existing rows are changed by this migration.
-- Scoped portal editor: organization portal managers do not need group-planning access.
create or replace function api.admin_portal_editor_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
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
        'candidateStartPoint', portal.candidate_start_point,
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
$$;
revoke all on function api.admin_portal_editor_snapshot(text) from public,anon;
grant execute on function api.admin_portal_editor_snapshot(text) to authenticated;

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
  node_id uuid; current_window record;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'portals_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
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
    raise exception 'INVALID_AVAILABILITY' using errcode='22023';
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
    geocoded_latitude = case when app_private.portal_private_locations.marker_latitude is null then excluded.geocoded_latitude else app_private.portal_private_locations.geocoded_latitude end,
    geocoded_longitude = case when app_private.portal_private_locations.marker_longitude is null then excluded.geocoded_longitude else app_private.portal_private_locations.geocoded_longitude end,
    marker_latitude = case when app_private.portal_private_locations.marker_latitude is not null then excluded.latitude end,
    marker_longitude = case when app_private.portal_private_locations.marker_longitude is not null then excluded.longitude end,
    latitude = excluded.latitude, longitude = excluded.longitude,
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
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, case when _portal_id is null then 'portal.manual_created' else 'portal.admin_updated' end,
    'portal', portal_record.id, jsonb_build_object('code', portal_record.system_code, 'lifecycle', portal_record.lifecycle_status,
      'source', portal_record.record_source, 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', portal_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', portal_record.id, 'code', portal_record.system_code,
    'version', portal_record.version, 'lifecycleStatus', portal_record.lifecycle_status);
end;
$function$;

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
declare actor uuid := auth.uid(); portal_record app_private.portals; relation_count integer; active_assignments integer; v_event_id uuid;
begin
  select event_id into v_event_id from app_private.portals where id=_portal_id;
  if actor is null or v_event_id is null or not (app_private.has_capability(v_event_id,'portals_manage',actor)
    or app_private.has_capability(v_event_id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from app_private.events where id=v_event_id for update;
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
  if active_assignments > 0 then raise exception 'RESOLVE_ACTIVE_ASSIGNMENTS_FIRST:%', active_assignments using errcode = '23514'; end if;
  if exists(select 1 from app_private.portal_reservations where portal_id=portal_record.id and status in ('held','active'))
    or exists(select 1 from app_private.run_stops stop join app_private.group_runs run on run.current_stop_id=stop.id
      where stop.portal_id=portal_record.id and run.status in ('ready','live','paused')) then
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
$$;


revoke all on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text),api.admin_manual_portal_remove(uuid,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text),api.admin_manual_portal_remove(uuid,integer,text) to authenticated;

-- Keep registration history while reflecting the current managed portal details.
do $$ begin
  if to_regprocedure('app_private.admin_portal_management_snapshot_before_hotfix(text)') is null then
    alter function api.admin_portal_management_snapshot(text) set schema app_private;
    alter function app_private.admin_portal_management_snapshot(text) rename to admin_portal_management_snapshot_before_hotfix;
  end if;
end $$;
revoke all on function app_private.admin_portal_management_snapshot_before_hotfix(text) from public,anon,authenticated;
create or replace function api.admin_portal_management_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
  base:=app_private.admin_portal_management_snapshot_before_hotfix(_event_slug);
  return jsonb_set(base,'{registrations}',coalesce((select jsonb_agg(
    case when p.id is null then item else item||jsonb_build_object(
      'portalArchived',p.lifecycle_status='archived',
      'status',case when p.lifecycle_status='archived' then 'closed' else item->>'status' end,
      'contactName',coalesce(p.contact_name,item->>'contactName'),
      'phone',coalesce(p.contact_phone,item->>'phone'),'email',coalesce(p.contact_email,item->>'email'),
      'address',case when l.portal_id is null then item->'address' else jsonb_build_object(
        'street',l.street,'houseNumber',l.house_number,'addition',l.addition,'postalCode',l.postal_code,'city',l.city) end,
      'draft',coalesce(item->'draft','{}'::jsonb)||jsonb_build_object('portalName',p.name,'description',p.description,'intensity',p.intensity,
        'accessibility',p.accessibility_notes)) end order by ordinality)
    from jsonb_array_elements(base->'registrations') with ordinality as rows(item,ordinality)
    left join app_private.portals p on p.id=(item->>'portalId')::uuid
    left join app_private.portal_private_locations l on l.portal_id=p.id),'[]'::jsonb),true);
end;
$$;
revoke all on function api.admin_portal_management_snapshot(text) from public,anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;
