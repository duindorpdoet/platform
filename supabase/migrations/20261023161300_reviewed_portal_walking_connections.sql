-- Coordinates alone never approve a new walking connection.
alter table app_private.portal_private_locations
  add column if not exists walking_connection_verified_at timestamptz,
  add column if not exists walking_connection_verified_by uuid references auth.users(id),
  add column if not exists safe_walking_approach text;

create or replace function app_private.portal_has_verified_walking_connection(_portal_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from app_private.portal_private_locations l
    join app_private.walking_nodes n on n.portal_id=l.portal_id and n.verified_at is not null
    where l.portal_id=_portal_id and l.verified_at is not null
      and abs(n.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<0.000001
      and abs(n.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<0.000001
      and exists(select 1 from app_private.walking_edges edge where edge.event_id=n.event_id and edge.approved_at is not null
        and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id)))
$$;

create or replace function app_private.invalidate_moved_walking_node()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if row(new.coordinate[0],new.coordinate[1]) is distinct from row(old.coordinate[0],old.coordinate[1]) then
    new.verified_at:=null;new.verified_by:=null;
    update app_private.walking_edges set approved_at=null,approved_by=null
      where event_id=old.event_id and (from_node_id=old.id or to_node_id=old.id) and approved_at is not null;
  end if;
  return new;
end;
$$;
drop trigger if exists invalidate_moved_walking_node on app_private.walking_nodes;
create trigger invalidate_moved_walking_node before update of coordinate on app_private.walking_nodes
for each row execute function app_private.invalidate_moved_walking_node();

create or replace function api.admin_verify_portal_walking_connection(
  _event_slug text,_portal_id uuid,_expected_version integer,_safe_connection_checked boolean,
  _safe_approach text,_step_free_checked boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; p app_private.portals; l app_private.portal_private_locations;
  anchor app_private.walking_nodes; own_node app_private.walking_nodes; distance numeric; lat numeric; lon numeric;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not (app_private.has_capability(e.id,'portals_manage',auth.uid())
    or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.portals where id=_portal_id and event_id=e.id for update;
  if p.id is null or p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if _safe_connection_checked is distinct from true or length(trim(coalesce(_safe_approach,''))) not between 1 and 1000 then
    raise exception 'SAFE_CONNECTION_REQUIRED' using errcode='23514'; end if;
  if p.approval_status<>'approved' or p.lifecycle_status not in ('approved','active') then raise exception 'PORTAL_NOT_APPROVED' using errcode='23514'; end if;
  select * into l from app_private.portal_private_locations where portal_id=p.id for update;
  lat:=coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude);lon:=coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude);
  if lat is null or lon is null then raise exception 'LOCATION_REQUIRED' using errcode='23514'; end if;
  select n.* into anchor from app_private.walking_nodes n where n.event_id=e.id and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=e.id and edge.approved_at is not null and edge.closed_at is null
      and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    order by app_private.location_distance_m(lat,lon,n.coordinate[1]::numeric,n.coordinate[0]::numeric),n.id limit 1;
  distance:=app_private.location_distance_m(lat,lon,anchor.coordinate[1]::numeric,anchor.coordinate[0]::numeric);
  if anchor.id is null or distance is null or distance>75 then raise exception 'CONNECTION_TOO_FAR' using errcode='23514'; end if;
  select * into own_node from app_private.walking_nodes where portal_id=p.id and event_id=e.id order by id limit 1 for update;
  if own_node.id is null then
    insert into app_private.walking_nodes(event_id,kind,portal_id,coordinate,verified_at,verified_by)
      values(e.id,'portal',p.id,point(lon,lat),clock_timestamp(),auth.uid()) returning * into own_node;
  else
    update app_private.walking_nodes set coordinate=point(lon,lat) where id=own_node.id;
    update app_private.walking_nodes set verified_at=clock_timestamp(),verified_by=auth.uid() where id=own_node.id returning * into own_node;
  end if;
  if own_node.id<>anchor.id then
    insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,
      wheelchair_accessible,approved_at,approved_by,geometry_geojson)
    values(e.id,own_node.id,anchor.id,greatest(1,ceil(distance)::integer),greatest(1,ceil(distance/1.1)::integer),
      _step_free_checked is true,clock_timestamp(),auth.uid(),jsonb_build_object('type','LineString','coordinates',
        jsonb_build_array(jsonb_build_array(lon,lat),jsonb_build_array(anchor.coordinate[0],anchor.coordinate[1]))));
  end if;
  update app_private.portal_private_locations set walking_connection_verified_at=clock_timestamp(),walking_connection_verified_by=auth.uid(),
    safe_walking_approach=trim(_safe_approach),verified_at=clock_timestamp(),verified_by=auth.uid() where portal_id=p.id;
  update app_private.portals set version=version+1 where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'portal.walking_connection_verified','portal',p.id,jsonb_build_object('version',p.version,
      'walkingNodeId',own_node.id,'anchorNodeId',anchor.id,'estimatedMeters',ceil(distance),'stepFreeChecked',_step_free_checked));
  perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',p.id,'version',p.version,'walkingConnectionVerified',true);
end;
$$;

create or replace function app_private.invalidate_portal_walking_connection()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if row(new.street,new.house_number,new.addition,new.postal_code,new.latitude,new.longitude,new.geocoded_latitude,new.geocoded_longitude,new.marker_latitude,new.marker_longitude)
    is distinct from row(old.street,old.house_number,old.addition,old.postal_code,old.latitude,old.longitude,old.geocoded_latitude,old.geocoded_longitude,old.marker_latitude,old.marker_longitude) then
    new.walking_connection_verified_at:=null;new.walking_connection_verified_by:=null;
  end if;
  return new;
end;
$$;
drop trigger if exists invalidate_portal_walking_connection on app_private.portal_private_locations;
create trigger invalidate_portal_walking_connection before update on app_private.portal_private_locations
for each row execute function app_private.invalidate_portal_walking_connection();

revoke all on function app_private.portal_has_verified_walking_connection(uuid),app_private.invalidate_moved_walking_node(),
  app_private.invalidate_portal_walking_connection() from public,anon,authenticated;
revoke all on function api.admin_verify_portal_walking_connection(text,uuid,integer,boolean,text,boolean) from public,anon;
grant execute on function api.admin_verify_portal_walking_connection(text,uuid,integer,boolean,text,boolean) to authenticated;
