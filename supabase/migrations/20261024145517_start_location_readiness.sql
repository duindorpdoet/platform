-- Separate saved location, organizational confirmation and walking readiness.
-- Functions only: no backfill, geocoding or changes to existing event records.
set lock_timeout='5s';

create or replace function app_private.routing_position(
  _marker_lat numeric,_marker_lon numeric,_address_lat numeric,_address_lon numeric,
  _legacy_lat numeric,_legacy_lon numeric)
returns jsonb language plpgsql immutable set search_path='' as $$
declare lat numeric; lon numeric; source text;
begin
  -- Select a pair, never combine one half of an override with another source.
  if _marker_lat is not null or _marker_lon is not null then
    lat:=_marker_lat;lon:=_marker_lon;source:='manual';
  elsif _address_lat is not null or _address_lon is not null then
    lat:=_address_lat;lon:=_address_lon;source:='address';
  else lat:=_legacy_lat;lon:=_legacy_lon;source:='address'; end if;
  if lat is null and lon is null then
    return jsonb_build_object('valid',false,'source',source,'reason','POSITION_MISSING','latitude',null,'longitude',null);
  end if;
  if lat is null or lon is null or not (lat between -90 and 90 and lon between -180 and 180) then
    return jsonb_build_object('valid',false,'source',source,'reason','POSITION_INVALID','latitude',null,'longitude',null);
  end if;
  return jsonb_build_object('valid',true,'source',source,'reason',null,'latitude',lat,'longitude',lon);
end;
$$;

create or replace function app_private.start_point_location(_point_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select app_private.routing_position(p.marker_latitude,p.marker_longitude,p.geocoded_latitude,p.geocoded_longitude,p.latitude,p.longitude)
  from app_private.start_points p where p.id=_point_id
$$;

create or replace function app_private.start_point_location_hash(_point_id uuid)
returns text language sql stable security definer set search_path='' as $$
  select encode(extensions.digest(jsonb_build_object('location',app_private.start_point_location(p.id),
    'address',p.private_address,'linkedPortalId',p.linked_portal_id,'countsAsFirstVisit',p.counts_as_first_portal_visit,
    'firstPortalLocation',case when p.counts_as_first_portal_visit then
      app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude) end)::text,'sha256'),'hex')
  from app_private.start_points p left join app_private.portal_private_locations l on l.portal_id=p.linked_portal_id
  where p.id=_point_id
$$;

create or replace function app_private.start_point_confirmation(_point_id uuid)
returns timestamptz language sql stable security definer set search_path='' as $$
  select a.created_at from app_private.start_points p join app_private.audit_events a
    on a.event_id=p.event_id and a.resource_type='start_point' and a.resource_id=p.id and a.action='start_point.confirmed'
  where p.id=_point_id and p.active and (case when a.minimal_change ? 'locationHash' then
    a.minimal_change->>'locationHash'=app_private.start_point_location_hash(p.id)
    else a.minimal_change->>'version'=p.version::text end)
  order by a.created_at desc,a.id desc limit 1
$$;

-- This remains the planning dependency; confirming a location never fabricates it.
create or replace function app_private.start_point_safe_connection(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select p.active and (app_private.start_point_location(p.id)->>'valid')::boolean
    and (p.linked_portal_id is null or exists(select 1 from app_private.portals portal
      where portal.id=p.linked_portal_id and portal.event_id=p.event_id and portal.lifecycle_status<>'archived'
        and (not p.counts_as_first_portal_visit or exists(select 1 from app_private.portal_private_locations l where l.portal_id=portal.id
          and (app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->>'valid')::boolean))))
    and n.id is not null and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=p.event_id
      and edge.approved_at is not null and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    from app_private.start_points p left join app_private.walking_nodes n on n.id=p.walking_node_id and n.event_id=p.event_id
    where p.id=_point_id),false)
$$;

create or replace function app_private.start_point_readiness(_point_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.start_points; l jsonb; linked_location jsonb; portal app_private.portals; reason text; confirmation timestamptz;
begin
  select * into p from app_private.start_points where id=_point_id;
  if p.id is null then return null; end if;
  l:=app_private.start_point_location(p.id);
  if not (l->>'valid')::boolean then reason:='START_POINT_'||(l->>'reason'); end if;
  if reason is null and p.linked_portal_id is not null then
    select * into portal from app_private.portals where id=p.linked_portal_id and event_id=p.event_id;
    if portal.id is null or portal.lifecycle_status='archived' then reason:='LINKED_PORTAL_NOT_AVAILABLE';
    elsif p.counts_as_first_portal_visit then
      select app_private.routing_position(x.marker_latitude,x.marker_longitude,x.geocoded_latitude,x.geocoded_longitude,x.latitude,x.longitude)
        into linked_location from app_private.portal_private_locations x where x.portal_id=portal.id;
      if not coalesce((linked_location->>'valid')::boolean,false) then reason:='LINKED_START_PORTAL_POSITION_INVALID'; end if;
    end if;
  end if;
  confirmation:=app_private.start_point_confirmation(p.id);
  return jsonb_build_object('location',l,'canConfirm',reason is null,'confirmationReason',reason,
    'confirmed',confirmation is not null and reason is null,'confirmedAt',case when reason is null then confirmation end,
    'routeReady',app_private.start_point_safe_connection(p.id),'linkedPortalName',portal.name);
end;
$$;

create or replace function api.admin_startregie_confirm_point(_event_slug text,_point_id uuid,_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; p app_private.start_points; node_id uuid; readiness jsonb; current_confirmation timestamptz;
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
  -- Retain the previous automatic use of the existing graph, independently of
  -- location confirmation. Never create/approve a node or edge here.
  select n.id into node_id from app_private.walking_nodes n where n.event_id=e.id and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=e.id and edge.approved_at is not null
      and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    order by (n.id=p.walking_node_id) desc nulls last,
      app_private.location_distance_m((readiness->'location'->>'latitude')::numeric,
        (readiness->'location'->>'longitude')::numeric,n.coordinate[1]::numeric,n.coordinate[0]::numeric),n.id limit 1;
  if not p.active or p.walking_node_id is distinct from coalesce(node_id,p.walking_node_id) then
    update app_private.start_points set active=true,walking_node_id=coalesce(node_id,walking_node_id),
      version=version+1,updated_at=statement_timestamp() where id=p.id returning * into p;
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
$$;

create or replace function api.admin_startregie_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    where w->>'code'<>'MISSING_MARKER'),'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object(
      'code',case when not (r->>'canConfirm')::boolean then 'MISSING_MARKER' else 'WALKING_ROUTE_MISSING' end,
      'resourceId',p.id,'resourceType','start_point','action','kaart',
      'message',p.public_label||' — '||case r->>'confirmationReason'
        when 'START_POINT_POSITION_MISSING' then 'Geen opgeslagen positie — plaats een marker.'
        when 'START_POINT_POSITION_INVALID' then 'Ongeldige positie — controleer de coördinaten en sla opnieuw op.'
        when 'LINKED_PORTAL_NOT_AVAILABLE' then 'Gekoppelde poort niet beschikbaar — controleer deze poort.'
        when 'LINKED_START_PORTAL_POSITION_INVALID' then 'De gekoppelde eerste poort '||coalesce(r->>'linkedPortalName','')||' heeft geen geldige positie — controleer de poortmarker.'
        else 'Wandelroute ontbreekt — laat de organisatie het gecontroleerde wandelnetwerk aansluiten. De startlocatie kun je wel bevestigen.' end) order by p.name)
      from app_private.start_points p cross join lateral(select app_private.start_point_readiness(p.id) r) c
      where p.event_id=e.id and p.active and (not (r->>'canConfirm')::boolean or not (r->>'routeReady')::boolean)), '[]'::jsonb),true);
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
$$;


-- Keep the established write/audit/slot synchronization, but validate the full
-- pair and return the actual stored projection. A rejected write is atomic.
do $$ begin
  if to_regprocedure('app_private.admin_location_marker_save_before_readiness(text,text,uuid,numeric,numeric,text,boolean,integer)') is null then
    alter function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) set schema app_private;
    alter function app_private.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) rename to admin_location_marker_save_before_readiness;
  end if;
end $$;
revoke all on function app_private.admin_location_marker_save_before_readiness(text,text,uuid,numeric,numeric,text,boolean,integer) from public,anon,authenticated;

create or replace function api.admin_location_marker_save(_event_slug text,_resource_type text,_resource_id uuid,
  _latitude numeric,_longitude numeric,_reason text,_restore_from_address boolean,_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved jsonb; l jsonb; p app_private.start_points; portal_location app_private.portal_private_locations;
begin
  if _restore_from_address is null then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  if not _restore_from_address and not (app_private.routing_position(_latitude,_longitude,null,null,null,null)->>'valid')::boolean then
    raise exception 'INVALID_COORDINATE' using errcode='22023'; end if;
  saved:=app_private.admin_location_marker_save_before_readiness(_event_slug,_resource_type,_resource_id,
    _latitude,_longitude,_reason,_restore_from_address,_expected_version);
  if saved->>'id' is distinct from _resource_id::text or saved->>'version' is null then
    raise exception 'LOCATION_WRITE_NOT_CONFIRMED' using errcode='40001'; end if;
  if _resource_type='start_point' then
    select * into p from app_private.start_points where id=_resource_id;
    l:=app_private.start_point_location(p.id);
  else
    select * into portal_location from app_private.portal_private_locations where portal_id=_resource_id;
    l:=app_private.routing_position(portal_location.marker_latitude,portal_location.marker_longitude,
      portal_location.geocoded_latitude,portal_location.geocoded_longitude,portal_location.latitude,portal_location.longitude);
  end if;
  if not coalesce((l->>'valid')::boolean,false) then raise exception 'INVALID_COORDINATE' using errcode='22023'; end if;
  return saved||jsonb_build_object('latitude',l->'latitude','longitude',l->'longitude','location',l,
    'readiness',case when _resource_type='start_point' then app_private.start_point_readiness(_resource_id) end);
end;
$$;
revoke all on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) from public,anon;
grant execute on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) to authenticated;

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
  return jsonb_build_object('id', portal_record.id, 'code', portal_record.system_code,
    'version', portal_record.version, 'lifecycleStatus', portal_record.lifecycle_status);
end;
$function$;

revoke all on function app_private.routing_position(numeric,numeric,numeric,numeric,numeric,numeric),
  app_private.start_point_location(uuid),app_private.start_point_location_hash(uuid),
  app_private.start_point_confirmation(uuid),app_private.start_point_readiness(uuid),
  app_private.start_point_safe_connection(uuid) from public,anon,authenticated;
revoke all on function api.admin_startregie_confirm_point(text,uuid,integer),api.admin_startregie_snapshot(text),
  api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_startregie_confirm_point(text,uuid,integer),api.admin_startregie_snapshot(text),
  api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;

-- The start form must report the same readiness as the map and fresh snapshot.
do $$ begin
  if to_regprocedure('app_private.admin_startregie_start_point_save_before_readiness(text,uuid,jsonb,integer,text)') is null then
    alter function api.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) set schema app_private;
    alter function app_private.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) rename to admin_startregie_start_point_save_before_readiness;
  end if;
end $$;
revoke all on function app_private.admin_startregie_start_point_save_before_readiness(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create or replace function api.admin_startregie_start_point_save(_event_slug text,_point_id uuid,_payload jsonb,_expected_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved jsonb; readiness jsonb;
begin
  saved:=app_private.admin_startregie_start_point_save_before_readiness(_event_slug,_point_id,_payload,_expected_version,_reason);
  if saved->>'id' is null or saved->>'version' is null then raise exception 'LOCATION_WRITE_NOT_CONFIRMED' using errcode='40001'; end if;
  readiness:=app_private.start_point_readiness((saved->>'id')::uuid);
  return saved||jsonb_build_object('readiness',readiness,'routeReady',readiness->'routeReady',
    'location',readiness->'location');
end;
$$;
revoke all on function api.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_startregie_start_point_save(text,uuid,jsonb,integer,text) to authenticated;

-- Route previews consume the same effective start pair as the editor/snapshot.
create or replace function app_private.start_ops_route_preview(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; point app_private.start_points;
  slot app_private.start_slots; settings app_private.event_route_settings; r app_private.group_runs;
  source_node uuid; last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; chosen uuid[]:='{}'::uuid[]; candidate record;
  meters bigint:=0; seconds bigint:=0; walk_m bigint; walk_s bigint; provisional boolean:=false;
  remaining integer; visited integer:=0; child_count integer; final_node uuid; fixed_portal uuid;
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
  source_node:=point.walking_node_id;
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
    select n.id,n.coordinate[0]::numeric,n.coordinate[1]::numeric into source_node,last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      join app_private.walking_nodes n on n.portal_id=coalesce(rs.portal_id,ps.portal_id) and n.verified_at is not null
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    source_node:=coalesce(source_node,point.walking_node_id);
    last_lon:=coalesce(last_lon,point.longitude); last_lat:=coalesce(last_lat,point.latitude);
  end if;
  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;
  if not point.counts_as_first_portal_visit and point.linked_portal_id is not null and point.linked_portal_id is distinct from preserved_portal then
    chosen:=array_append(chosen,point.linked_portal_id);
  elsif point.counts_as_first_portal_visit and r.id is null then fixed_portal:=point.linked_portal_id; end if;
  select id into final_node from app_private.walking_nodes where portal_id=settings.final_portal_id and verified_at is not null limit 1;
  select count(*) into eligible from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id and l.verified_at is not null
    join app_private.walking_nodes n on n.portal_id=p.id and n.verified_at is not null
    where p.event_id=g.event_id and app_private.portal_has_verified_walking_connection(p.id) and p.approval_status='approved' and p.lifecycle_status='active'
      and p.operation_status in ('open','scheduled') and p.id<>settings.final_portal_id;

  loop
    exit when remaining<=0 and preserved_portal is null;
    select q.* into candidate from (
      select p.id,p.name,p.system_code,p.world_id,w.name world,l.*,n.id node_id,
        coalesce(m.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
          coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))))::bigint walk_m,
        coalesce(m.duration_seconds,ceil(app_private.location_distance_m(last_lat,last_lon,
          coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))/1.1))::bigint walk_s,
        m.duration_seconds is null or final_path.duration_seconds is null geographic,
        final_path.duration_seconds final_seconds
      from app_private.portals p join app_private.worlds w on w.id=p.world_id
      join app_private.portal_private_locations l on l.portal_id=p.id and l.verified_at is not null
      join app_private.walking_nodes n on n.portal_id=p.id and n.event_id=g.event_id and n.verified_at is not null
      left join lateral app_private.walking_path_metrics(g.event_id,source_node,n.id,step_free) m on true
      left join lateral app_private.walking_path_metrics(g.event_id,n.id,final_node,step_free) final_path on true
      where p.event_id=g.event_id and app_private.portal_has_verified_walking_connection(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen))
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
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
    order by q.walk_s,q.id limit 1;
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
    source_node:=candidate.node_id;
    last_lon:=coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude);
    last_lat:=coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude);
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,n.id node_id,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join app_private.walking_nodes n on n.id=final_node
    left join lateral app_private.walking_path_metrics(g.event_id,source_node,n.id,step_free) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude),coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude))))::bigint;
    walk_s:=coalesce(candidate.duration_seconds,ceil(walk_m/1.1))::bigint;
    provisional:=provisional or candidate.duration_seconds is null;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','final',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>settings.finale_last_arrival_at or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('Er ontbreekt een gecontroleerde finale.'); end if;
  if provisional then warnings:=warnings||jsonb_build_array('Deels geografisch geschat. De stippellijnen zijn geen gecontroleerde straatafslagroute; live vertrek vereist goedgekeurde wandelverbindingen.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      (app_private.start_point_location(point.id)->>'longitude')::numeric,(app_private.start_point_location(point.id)->>'latitude')::numeric),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$$;



create or replace function app_private.portal_has_verified_walking_connection(_portal_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from app_private.portal_private_locations l
    join app_private.walking_nodes n on n.portal_id=l.portal_id and n.verified_at is not null
    where l.portal_id=_portal_id and l.verified_at is not null
      and (app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->>'valid')::boolean
      and abs(n.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<0.000001
      and abs(n.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<0.000001
      and exists(select 1 from app_private.walking_edges edge where edge.event_id=n.event_id and edge.approved_at is not null
        and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id)))
$$;
revoke all on function app_private.start_ops_route_preview(uuid),app_private.portal_has_verified_walking_connection(uuid) from public,anon,authenticated;
