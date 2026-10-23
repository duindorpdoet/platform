-- Admin-only expected routes. Approved walking edges are used where available;
-- geographic fallback is explicitly provisional and never authorizes dispatch.
create or replace function app_private.start_ops_route_revision(_event_id uuid)
returns integer language sql stable security definer set search_path='' as $$
  select ('x'||substr(md5(jsonb_build_object('pool',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('location',to_jsonb(l),
    'windows',(select jsonb_agg(to_jsonb(w) order by w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id)::text
    from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id where p.event_id=_event_id),''),
    'settings',(select to_jsonb(s) from app_private.event_route_settings s where s.event_id=_event_id),
    'edges',(select jsonb_agg(to_jsonb(edge) order by edge.id) from app_private.walking_edges edge where edge.event_id=_event_id),
    'groups',(select jsonb_agg(jsonb_build_array(g.id,g.desired_ordinary_visits,g.current_schedule_revision_id,r.version,r.current_stop_id) order by g.id)
      from app_private.walking_groups g left join app_private.group_runs r on r.group_id=g.id where g.event_id=_event_id))::text),1,7))::bit(28)::integer
$$;

create or replace function app_private.start_ops_route_preview(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; point app_private.start_points;
  slot app_private.start_slots; settings app_private.event_route_settings; r app_private.group_runs;
  source_node uuid; last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'; warnings jsonb:='[]'; chosen uuid[]:='{}'; candidate record; path record;
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
  last_lon:=coalesce(point.marker_longitude,point.geocoded_longitude,point.longitude);
  last_lat:=coalesce(point.marker_latitude,point.geocoded_latitude,point.latitude);
  start_time:=slot.starts_at; at_time:=slot.starts_at;
  if r.id is not null then
    at_time:=greatest(at_time,clock_timestamp());
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
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',clock_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      coalesce(point.marker_longitude,point.geocoded_longitude,point.longitude),coalesce(point.marker_latitude,point.geocoded_latitude,point.latitude)),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$$;

create or replace function api.admin_startregie_start_point_from_portal(_event_slug text,_portal_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; p app_private.portals; l app_private.portal_private_locations; existing app_private.start_points;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.portals where id=_portal_id and event_id=e.id and approval_status='approved' and lifecycle_status='active';
  select * into l from app_private.portal_private_locations where portal_id=p.id and verified_at is not null;
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
$$;
revoke all on function app_private.start_ops_route_revision(uuid),app_private.start_ops_route_preview(uuid) from public,anon,authenticated;
revoke all on function api.admin_startregie_start_point_from_portal(text,uuid) from public,anon;
grant execute on function api.admin_startregie_start_point_from_portal(text,uuid) to authenticated;
