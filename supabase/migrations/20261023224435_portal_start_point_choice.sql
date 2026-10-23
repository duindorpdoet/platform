-- The organization's yes/no choice is sufficient for portal-linked starts.
-- Existing independent gathering points retain their own configuration.
create or replace function app_private.sync_portal_start_choice(_portal_id uuid,_enabled boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare p app_private.portals; sp app_private.start_points; l app_private.portal_private_locations;
  node_id uuid; lat numeric; lon numeric; w record;
begin
  select * into p from app_private.portals where id=_portal_id;
  select * into sp from app_private.start_points where linked_portal_id=p.id order by active desc,created_at,id limit 1 for update;
  if not _enabled then
    update app_private.start_points set active=false,version=version+1,updated_at=statement_timestamp()
      where linked_portal_id=p.id and active;
    return sp.id;
  end if;
  select * into l from app_private.portal_private_locations where portal_id=p.id;
  lat:=coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude,sp.latitude);
  lon:=coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude,sp.longitude);
  select n.id into node_id from app_private.walking_nodes n where n.event_id=p.event_id and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=p.event_id and edge.approved_at is not null
      and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    order by (n.portal_id=p.id) desc nulls last,
      app_private.location_distance_m(lat,lon,n.coordinate[1]::numeric,n.coordinate[0]::numeric),n.id limit 1;
  node_id:=coalesce(node_id,sp.walking_node_id);
  select min(opens_at) opens_at,max(closes_at) closes_at,max(max_concurrent_groups) max_groups,
    max(max_children_per_visit) max_children into w from app_private.portal_windows where portal_id=p.id;
  if sp.id is null then
    insert into app_private.start_points(event_id,name,public_label,point_type,linked_portal_id,private_address,
      latitude,longitude,geocoded_latitude,geocoded_longitude,walking_node_id,active,
      max_gathering_groups,max_gathering_children,available_from,available_until,contact_name,contact_phone)
    values(p.event_id,p.name,p.name,'portal',p.id,nullif(concat_ws(' ',l.street,l.house_number,l.addition),''),
      lat,lon,lat,lon,node_id,true,coalesce(w.max_groups,1),coalesce(w.max_children,app_private.event_group_size_limit(p.event_id)),
      w.opens_at,w.closes_at,p.contact_name,p.contact_phone) returning * into sp;
  else
    -- A yes/no toggle changes availability only. Existing names, locations,
    -- capacities and published appointments keep their configured values.
    update app_private.start_points set active=true,version=version+1,updated_at=statement_timestamp()
      where id=sp.id returning * into sp;
  end if;
  return sp.id;
end;
$$;
revoke all on function app_private.sync_portal_start_choice(uuid,boolean) from public,anon,authenticated;

create or replace function api.admin_portal_start_point_set(_portal_id uuid,_enabled boolean,_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; eid uuid; actor uuid:=auth.uid(); point_id uuid;
begin
  select event_id into eid from app_private.portals where id=_portal_id;
  if actor is null or eid is null or not (app_private.has_capability(eid,'portals_manage',actor)
    or app_private.has_capability(eid,'groups_manage',actor) or app_private.has_capability(eid,'event_admin',actor)) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _enabled is null then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  perform 1 from app_private.events where id=eid for no key update;
  perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
  select * into p from app_private.portals where id=_portal_id for update;
  if p.id is null or p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if p.lifecycle_status='archived' then raise exception 'PORTAL_NOT_FOUND' using errcode='P0002'; end if;
  point_id:=app_private.sync_portal_start_choice(p.id,_enabled);
  update app_private.portals set candidate_start_point=_enabled,version=version+1,updated_at=statement_timestamp()
    where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(eid,actor,'portal.start_point_changed','portal',p.id,jsonb_build_object('enabled',_enabled,'startPointId',point_id));
  perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed','admin-event:'||eid,true);
  return jsonb_build_object('id',p.id,'version',p.version,'startPoint',_enabled,'startPointId',point_id);
end;
$$;
revoke all on function api.admin_portal_start_point_set(uuid,boolean,integer) from public,anon;
grant execute on function api.admin_portal_start_point_set(uuid,boolean,integer) to authenticated;

-- No physical-inspection claim is fabricated: linked portal starts use the
-- organization's selection, stored coordinates and the existing routing graph.
create or replace function app_private.start_point_safe_connection(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select p.active and case when p.linked_portal_id is not null then
      exists(select 1 from app_private.portals portal where portal.id=p.linked_portal_id and portal.lifecycle_status<>'archived')
      and coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude) is not null and n.id is not null
    else p.walking_connection_verified_at is not null and length(trim(coalesce(p.safe_approach,'')))>0 and n.verified_at is not null
      and exists(select 1 from app_private.walking_edges edge where edge.event_id=p.event_id and edge.approved_at is not null
        and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
      and app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
        coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)<=75 end
    from app_private.start_points p left join app_private.walking_nodes n on n.id=p.walking_node_id and n.event_id=p.event_id where p.id=_point_id),false)
$$;

create or replace function app_private.invalidate_start_point_connection()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if row(new.private_address,new.latitude,new.longitude,new.geocoded_latitude,new.geocoded_longitude,
      new.marker_latitude,new.marker_longitude,new.walking_node_id,new.safe_approach,new.linked_portal_id)
    is distinct from row(old.private_address,old.latitude,old.longitude,old.geocoded_latitude,old.geocoded_longitude,
      old.marker_latitude,old.marker_longitude,old.walking_node_id,old.safe_approach,old.linked_portal_id) then
    new.walking_connection_verified_at:=null;new.walking_connection_verified_by:=null;
  end if;
  -- Turning a portal off affects new assignments; immutable published appointments survive.
  if old.linked_portal_id is null and old.active and not new.active and exists(select 1 from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    where slot.start_point_id=old.id and g.status not in ('finished','cancelled')) then
    raise exception 'START_POINT_IN_USE' using errcode='23514'; end if;
  return new;
end;
$$;
revoke all on function app_private.start_point_safe_connection(uuid),app_private.invalidate_start_point_connection() from public,anon,authenticated;
