-- Organizational confirmation is a single action. It is not a declaration of
-- physical inspection. Existing publication snapshots and configured data stay.
set lock_timeout='5s';

create or replace function api.admin_startregie_confirm_point(
  _event_slug text,_point_id uuid,_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; p app_private.start_points; node_id uuid;
begin
  select * into e from app_private.events where slug=_event_slug;
  if e.id is null or auth.uid() is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from app_private.events where id=e.id for no key update;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
  select * into p from app_private.start_points where id=_point_id and event_id=e.id for update;
  if p.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode='P0002'; end if;
  if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  -- Reuse the existing graph without a distance limit or additional operator
  -- form. Missing route data is handled by route planning, never invented here.
  select n.id into node_id from app_private.walking_nodes n where n.event_id=e.id and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=e.id and edge.approved_at is not null
      and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    order by (n.id=p.walking_node_id) desc,
      app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
        coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric),n.id limit 1;
  if not p.active or p.walking_node_id is distinct from coalesce(node_id,p.walking_node_id) then
    update app_private.start_points set active=true,walking_node_id=coalesce(node_id,walking_node_id),
      version=version+1,updated_at=statement_timestamp() where id=p.id returning * into p;
  end if;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'start_point.confirmed','start_point',p.id,jsonb_build_object('version',p.version,'enabled',true));
  perform realtime.send(jsonb_build_object('resource','start_point','id',p.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',p.id,'version',p.version,'confirmed',true,'active',true);
end;
$$;
revoke all on function api.admin_startregie_confirm_point(text,uuid,integer) from public,anon;
grant execute on function api.admin_startregie_confirm_point(text,uuid,integer) to authenticated;

-- Old browser tabs can still use this signature. It now records the same
-- organizational choice, without manufacturing physical-inspection evidence.
create or replace function api.admin_startregie_verify_point(
  _event_slug text,_point_id uuid,_expected_version integer,
  _safe_connection_checked boolean,_safe_approach text)
returns jsonb language sql security definer set search_path='' as $$
  select api.admin_startregie_confirm_point(_event_slug,_point_id,_expected_version)
$$;
revoke all on function api.admin_startregie_verify_point(text,uuid,integer,boolean,text) from public,anon;
grant execute on function api.admin_startregie_verify_point(text,uuid,integer,boolean,text) to authenticated;

create or replace function app_private.start_point_safe_connection(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select p.active
    and (p.linked_portal_id is null or exists(select 1 from app_private.portals portal
      where portal.id=p.linked_portal_id and portal.event_id=p.event_id and portal.lifecycle_status<>'archived'))
    and coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude) is not null
    and coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude) is not null
    and n.id is not null
    from app_private.start_points p left join app_private.walking_nodes n
      on n.id=p.walking_node_id and n.event_id=p.event_id where p.id=_point_id),false)
$$;
revoke all on function app_private.start_point_safe_connection(uuid) from public,anon,authenticated;
