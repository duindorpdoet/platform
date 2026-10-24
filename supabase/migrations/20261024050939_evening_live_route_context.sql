-- A released destination keeps its location even when a later editor changes
-- the current portal marker. This is release context, not a claimed arrival.
create table app_private.run_stop_location_snapshots (
 run_stop_id uuid primary key references app_private.run_stops(id) on delete restrict,
 event_id uuid not null references app_private.events(id) on delete restrict,
 run_id uuid not null references app_private.group_runs(id) on delete restrict,
 portal_id uuid not null references app_private.portals(id) on delete restrict,
 walking_node_id uuid references app_private.walking_nodes(id) on delete restrict,
 longitude numeric,latitude numeric,node_longitude numeric,node_latitude numeric,
 address jsonb not null,
 captured_at timestamptz not null default clock_timestamp()
);
create index run_stop_location_event_fk on app_private.run_stop_location_snapshots(event_id);
create index run_stop_location_run_fk on app_private.run_stop_location_snapshots(run_id);
create index run_stop_location_portal_fk on app_private.run_stop_location_snapshots(portal_id);
create index run_stop_location_node_fk on app_private.run_stop_location_snapshots(walking_node_id) where walking_node_id is not null;
alter table app_private.run_stop_location_snapshots enable row level security;
revoke all on app_private.run_stop_location_snapshots from public,anon,authenticated;

create or replace function app_private.capture_stop_location(_stop_id uuid)
returns void language plpgsql security definer set search_path='' as $function$
begin
 insert into app_private.run_stop_location_snapshots(run_stop_id,event_id,run_id,portal_id,walking_node_id,
  longitude,latitude,node_longitude,node_latitude,address)
 select s.id,g.event_id,r.id,p.id,n.id,
  coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),
  n.coordinate[0]::numeric,n.coordinate[1]::numeric,
  jsonb_build_object('street',l.street,'houseNumber',l.house_number,'addition',l.addition,'postalCode',l.postal_code,'city',l.city)
 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id
 join app_private.walking_groups g on g.id=r.group_id
 left join app_private.route_plan_stops old_stop on old_stop.id=s.plan_stop_id
 join app_private.portals p on p.id=coalesce(s.portal_id,old_stop.portal_id) and p.event_id=g.event_id
 join app_private.portal_private_locations l on l.portal_id=p.id
 left join lateral (select node.* from app_private.walking_nodes node
  where node.portal_id=p.id and node.event_id=g.event_id and node.verified_at is not null
   and abs(node.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<.000001
   and abs(node.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<.000001
   and exists(select 1 from app_private.walking_edges edge where edge.event_id=g.event_id and edge.approved_at is not null and edge.closed_at is null
    and (edge.from_node_id=node.id or edge.to_node_id=node.id)) order by node.id limit 1) n on true
 where s.id=_stop_id and s.state='active'
 on conflict(run_stop_id) do nothing;
end;
$function$;
create or replace function app_private.capture_stop_location_trigger()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 if new.state='active' then perform app_private.capture_stop_location(new.id);end if;
 return new;
end;
$function$;
create trigger evening_capture_stop_location after insert or update of state on app_private.run_stops
for each row execute function app_private.capture_stop_location_trigger();

create or replace function app_private.preserve_stop_location()
returns trigger language plpgsql set search_path='' as $function$
begin raise exception 'RELEASED_LOCATION_IMMUTABLE' using errcode='55000';end;
$function$;
create trigger evening_preserve_stop_location before update or delete on app_private.run_stop_location_snapshots
for each row execute function app_private.preserve_stop_location();

create or replace function app_private.frozen_walking_source(_event_id uuid,_node_id uuid,_longitude numeric,_latitude numeric)
returns uuid language sql stable security definer set search_path='' as $function$
 select node.id from app_private.walking_nodes node where node.event_id=_event_id and node.verified_at is not null
  and (_node_id is not null or (_longitude is not null and _latitude is not null))
  and (_node_id is null or node.id=_node_id or (_longitude is not null and _latitude is not null))
  and (_longitude is null or abs(node.coordinate[0]-_longitude::double precision)<.000001)
  and (_latitude is null or abs(node.coordinate[1]-_latitude::double precision)<.000001)
  and exists(select 1 from app_private.walking_edges edge where edge.event_id=node.event_id and edge.approved_at is not null and edge.closed_at is null
    and (edge.from_node_id=node.id or edge.to_node_id=node.id))
 order by (node.id=_node_id) desc,node.id limit 1
$function$;
revoke all on function app_private.capture_stop_location(uuid),app_private.capture_stop_location_trigger(),app_private.preserve_stop_location(),
 app_private.frozen_walking_source(uuid,uuid,numeric,numeric) from public,anon,authenticated;

create or replace function app_private.evening_route_context(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare g app_private.walking_groups; r app_private.group_runs; s app_private.group_schedule_revisions;
 p app_private.group_start_publications; point app_private.start_points; slot app_private.start_slots; cfg app_private.event_route_settings;
 c app_private.finale_publication_commitments; released app_private.run_stop_location_snapshots;
 decision_at timestamptz:=statement_timestamp(); from_at timestamptz; after_current_at timestamptz;
 is_live boolean; confirmed boolean:=false; step_free boolean; children integer; visited integer:=0; remaining integer;
 point_data jsonb; node_data jsonb; source_node uuid; remaining_node uuid; current_stop jsonb; history jsonb;
 seen uuid[]:='{}'; last_stop uuid; last_portal uuid; current_node uuid; current_portal uuid;
 scan_at timestamptz; arrival_at timestamptz; walk record; service_seconds integer; buffer_seconds integer;
begin
 select * into g from app_private.walking_groups where id=_group_id;
 if g.id is null then return null;end if;
 select * into cfg from app_private.event_route_settings where event_id=g.event_id;
 select * into r from app_private.group_runs where group_id=g.id
  order by (status in ('live','paused','ready')) desc,created_at desc,id desc limit 1;
 is_live:=coalesce(r.status in ('live','paused'),false);
 if is_live then
  select * into p from app_private.group_start_publications where id=app_private.run_start_publication(r.id);
  select * into s from app_private.group_schedule_revisions where id=coalesce(r.schedule_revision_id,p.schedule_id);
  point_data:=p.point_snapshot;from_at:=decision_at;confirmed:=p.id is not null;
  select count(*) into children from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null;
  select exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   join app_private.children ch on ch.id=rc.child_id where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null and nullif(trim(ch.accessibility_note),'') is not null) into step_free;
 else
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id;
  if s.state='draft' and app_private.is_start_confirmation_current(s.id) then
   select * into slot from app_private.start_slots where id=s.start_slot_id;
   select * into point from app_private.start_points where id=slot.start_point_id;
   select jsonb_build_object('id',n.id,'coordinate',jsonb_build_array(n.coordinate[0],n.coordinate[1])) into node_data from app_private.walking_nodes n where n.id=point.walking_node_id and n.event_id=g.event_id;
   point_data:=to_jsonb(point)||jsonb_build_object('walking_node_snapshot',node_data);from_at:=slot.starts_at;
   confirmed:=app_private.start_point_safe_connection(point.id);
  else
   select * into p from app_private.group_start_publications where group_id=g.id order by publication_order desc limit 1;
   if p.id is not null then
    select * into s from app_private.group_schedule_revisions where id=p.schedule_id;
    point_data:=p.point_snapshot;from_at:=p.starts_at;confirmed:=true;
   end if;
  end if;
  select count(*) into children from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
  select exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
   join app_private.children ch on ch.id=rc.child_id where a.group_id=g.id and a.superseded_at is null and nullif(trim(ch.accessibility_note),'') is not null) into step_free;
 end if;
 source_node:=app_private.frozen_walking_source(g.event_id,(point_data->>'walking_node_id')::uuid,
  (point_data#>>'{walking_node_snapshot,coordinate,0}')::numeric,(point_data#>>'{walking_node_snapshot,coordinate,1}')::numeric);
 select * into c from app_private.finale_publication_commitments where publication_id=p.id;
 if is_live then
  select stop.id,coalesce(stop.portal_id,old_stop.portal_id) into last_stop,last_portal from app_private.run_stops stop
   left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   where stop.run_id=r.id and stop.state='completed' and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id)
   order by stop.sequence desc limit 1;
  if last_stop is not null then
   select * into released from app_private.run_stop_location_snapshots where run_stop_id=last_stop;
   if released.run_stop_id is not null then
    source_node:=app_private.frozen_walking_source(g.event_id,released.walking_node_id,released.node_longitude,released.node_latitude);
   else
    -- Controlled legacy identity fallback; no historical IDs are rewritten.
    select node.id into source_node from app_private.walking_nodes node join app_private.portal_private_locations l on l.portal_id=node.portal_id
     where node.event_id=g.event_id and node.portal_id=last_portal and node.verified_at is not null and l.verified_at is not null
      and abs(node.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<.000001
      and abs(node.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<.000001 order by node.id limit 1;
   end if;
  end if;
  select coalesce(array_agg(distinct coalesce(stop.portal_id,old_stop.portal_id) order by coalesce(stop.portal_id,old_stop.portal_id)),'{}'),
    count(distinct coalesce(stop.portal_id,old_stop.portal_id)) filter(where stop.state='completed' and coalesce(stop.stop_kind::text,'ordinary')='ordinary'
     and coalesce(stop.portal_id,old_stop.portal_id) is distinct from coalesce(c.portal_id,cfg.final_portal_id)
     and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id))
   into seen,visited from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   where stop.run_id=r.id and stop.state in ('active','completed');
  select jsonb_build_object('id',stop.id,'planStopId',stop.plan_stop_id,'portalId',portal.id,'code',portal.system_code,'name',portal.name,'world',world.name,
    'sequence',stop.sequence,'kind',coalesce(stop.stop_kind::text,'ordinary'),'status','current',
    'address',case when snap.run_stop_id is not null then concat_ws(' ',snap.address->>'street',snap.address->>'houseNumber',snap.address->>'addition') else concat_ws(' ',l.street,l.house_number,l.addition) end,
    'coordinate',jsonb_build_array(coalesce(snap.longitude,l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(snap.latitude,l.marker_latitude,l.geocoded_latitude,l.latitude)),
    'reservedArrivalAt',b.reserved_from,'scanAccepted',exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id))
   into current_stop from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   join app_private.portals portal on portal.id=coalesce(stop.portal_id,old_stop.portal_id)
   join app_private.worlds world on world.id=portal.world_id join app_private.portal_private_locations l on l.portal_id=portal.id
   left join app_private.run_stop_location_snapshots snap on snap.run_stop_id=stop.id
   left join app_private.portal_reservations b on b.id=stop.reservation_id or b.bound_stop_id=stop.id
   where stop.id=r.current_stop_id and stop.state='active';
 end if;
 if r.id is not null then
  select coalesce(jsonb_agg(jsonb_build_object('id',stop.id,'planStopId',stop.plan_stop_id,'portalId',coalesce(stop.portal_id,old_stop.portal_id),
    'code',portal.system_code,'name',portal.name,'sequence',stop.sequence,'outcome',stop.outcome,'completedAt',stop.completed_at,
    'arrivalConfirmed',exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id)) order by stop.sequence),'[]')
   into history from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   join app_private.portals portal on portal.id=coalesce(stop.portal_id,old_stop.portal_id) where stop.run_id=r.id and stop.state='completed';
 end if;
 remaining:=case when g.desired_ordinary_visits is null then null else greatest(0,g.desired_ordinary_visits-visited) end;
 after_current_at:=from_at;remaining_node:=source_node;
 if current_stop is not null then
  current_portal:=(current_stop->>'portalId')::uuid;
  select * into released from app_private.run_stop_location_snapshots where run_stop_id=r.current_stop_id;
  if released.run_stop_id is not null then current_node:=app_private.frozen_walking_source(g.event_id,released.walking_node_id,released.node_longitude,released.node_latitude);
  else select id into current_node from app_private.walking_nodes where portal_id=current_portal and event_id=g.event_id and verified_at is not null order by id limit 1;end if;
  select min(scanned_at) into scan_at from app_private.scan_evidence where run_stop_id=r.current_stop_id;
  select * into walk from app_private.walking_path_metrics(g.event_id,source_node,current_node,step_free);
  select greatest(1,coalesce(extract(epoch from b.service_until-b.reserved_from)::integer,extract(epoch from ps.planned_departure_at-ps.planned_arrival_at)::integer,cfg.ordinary_visit_seconds,300)),
    greatest(0,extract(epoch from b.reserved_until-b.service_until)::integer) into service_seconds,buffer_seconds
   from app_private.run_stops stop left join app_private.route_plan_stops ps on ps.id=stop.plan_stop_id
   left join app_private.portal_reservations b on b.id=stop.reservation_id or b.bound_stop_id=stop.id where stop.id=r.current_stop_id;
  service_seconds:=coalesce(service_seconds,cfg.ordinary_visit_seconds,300);buffer_seconds:=coalesce(buffer_seconds,cfg.route_buffer_seconds,0);
  arrival_at:=coalesce(scan_at,from_at+make_interval(secs=>walk.duration_seconds::integer));
  after_current_at:=greatest(from_at,arrival_at+make_interval(secs=>service_seconds))+make_interval(secs=>buffer_seconds);
  remaining_node:=current_node;
  current_stop:=current_stop||jsonb_build_object('plannedArrivalAt',arrival_at,'walkMeters',case when scan_at is null then walk.distance_m else 0 end,'walkMinutes',case when scan_at is null then ceil(walk.duration_seconds/60.0) else 0 end);
  if current_stop->>'kind'='ordinary' and remaining is not null then remaining:=greatest(0,remaining-1);end if;
 end if;
 return jsonb_build_object('groupId',g.id,'eventId',g.event_id,'groupCode',g.system_code,'runId',case when is_live then r.id else null end,
  'groupStatus',g.status,'terminal',not is_live and r.status in ('completed','stopped') and p.id is not distinct from app_private.run_start_publication(r.id),
  'runVersion',case when is_live then r.version else null end,'runStatus',case when is_live then r.status else null end,'mode',case when is_live then 'live' else 'preview' end,
  'calculatedFromAt',from_at,'remainingFromAt',after_current_at,'sourceNodeId',source_node,'remainingSourceNodeId',remaining_node,
  'lastConfirmedStopId',last_stop,'lastConfirmedPortalId',last_portal,'childCount',children,'requiresStepFree',step_free,'hasConfirmedStart',confirmed,'publicationId',p.id,'scheduleId',s.id,
  'start',jsonb_build_object('pointId',point_data->>'id','name',point_data->>'name','address',point_data->>'private_address','startsAt',coalesce(p.starts_at,slot.starts_at),
    'coordinate',case when coalesce(point_data->>'marker_longitude',point_data->>'geocoded_longitude',point_data->>'longitude') is not null and coalesce(point_data->>'marker_latitude',point_data->>'geocoded_latitude',point_data->>'latitude') is not null then jsonb_build_array(coalesce(point_data->>'marker_longitude',point_data->>'geocoded_longitude',point_data->>'longitude')::numeric,coalesce(point_data->>'marker_latitude',point_data->>'geocoded_latitude',point_data->>'latitude')::numeric) else null end),
  'ordinaryStopAt',least(s.effective_ordinary_stop_at,cfg.global_ordinary_stop_at),'ordinaryVisitLimit',g.desired_ordinary_visits,'completedOrdinaryVisits',visited,'remainingOrdinaryVisits',remaining,
  'seenPortalIds',to_jsonb(seen),'historyRunId',r.id,'historyIsPreviousRun',not is_live,'history',coalesce(history,'[]'),'currentStop',current_stop,
  'finalePortalId',coalesce(c.portal_id,cfg.final_portal_id),'finaleArrivalAt',coalesce(c.reserved_arrival_at,s.expected_finale_arrival_at),
  'finaleGraceSeconds',coalesce(c.grace_seconds,cfg.finale_turnover_seconds,120),'finaleReserved',c.publication_id is not null,
  'finaleReservationId',(select b.id from app_private.portal_reservations b where b.start_publication_id=c.publication_id),
  'safeWaitingInstruction',c.safe_waiting_instruction);
end;
$function$;
revoke all on function app_private.evening_route_context(uuid) from public,anon,authenticated;

-- A confirmed arrival is durable even when a subsequent logical planning step
-- needs organization review. Transaction/connection failures still propagate so
-- the original durable client command can retry the whole transaction safely.
create or replace function app_private.dispatch_after_confirmed_arrival(_run_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare conflict text:='ROUTE_PLANNING_REQUIRES_REVIEW';
begin
 begin
  return app_private.dispatch_next_stop(_run_id,clock_timestamp());
 exception
  when serialization_failure or deadlock_detected or lock_not_available then raise;
  when others then
   if sqlerrm~'^[A-Z][A-Z0-9_]{1,79}$' then conflict:=sqlerrm;end if;
 end;
 return app_private.pause_for_finale_conflict(_run_id,conflict,clock_timestamp());
end;
$function$;
revoke all on function app_private.dispatch_after_confirmed_arrival(uuid) from public,anon,authenticated;

create or replace function app_private.validate_released_stop_scope()
returns trigger language plpgsql security definer set search_path='' as $function$
declare stop_event_id uuid; stop_group_id uuid; physical_portal uuid; frozen_portal uuid;
begin
 select g.event_id,g.id into stop_event_id,stop_group_id from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=new.run_id;
 select coalesce(new.portal_id,(select ps.portal_id from app_private.route_plan_stops ps where ps.id=new.plan_stop_id)) into physical_portal;
 if stop_event_id is null or not exists(select 1 from app_private.portals p where p.id=physical_portal and p.event_id=stop_event_id)
  or (new.plan_stop_id is not null and not exists(select 1 from app_private.route_plan_stops ps join app_private.route_plan_versions pv on pv.id=ps.plan_version_id where ps.id=new.plan_stop_id and pv.group_id=stop_group_id)) then
  raise exception 'RUN_STOP_SCOPE_CONFLICT' using errcode='23514';
 end if;
 if tg_op='UPDATE' then
  select s.portal_id into frozen_portal from app_private.run_stop_location_snapshots s where s.run_stop_id=old.id;
  if frozen_portal is not null and (new.run_id<>old.run_id or physical_portal<>frozen_portal) then
   raise exception 'RELEASED_STOP_IDENTITY_IMMUTABLE' using errcode='55000';
  end if;
 end if;
 return new;
end;
$function$;
create trigger evening_released_stop_scope before insert or update of run_id,portal_id,plan_stop_id on app_private.run_stops
for each row execute function app_private.validate_released_stop_scope();
revoke all on function app_private.validate_released_stop_scope() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.capture_published_start(_group_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; s app_private.group_schedule_revisions;
  slot app_private.start_slots; p app_private.start_points; plan app_private.route_plan_versions;
  source text; rev integer; pub_at timestamptz;
begin
  select * into g from app_private.walking_groups where id=_group_id;
  if g.id is null then return; end if;
  select * into s from app_private.group_schedule_revisions
    where group_id=g.id and state='published' order by revision desc limit 1;
  if s.id is not null then
    select * into slot from app_private.start_slots where id=s.start_slot_id;
    source := 'schedule:'||s.id; rev:=s.revision; pub_at:=s.published_at;
  elsif g.route_mode='legacy' then
    -- A route-only revision cannot replace an already published departure.
    if exists(select 1 from app_private.group_start_publications where group_id=g.id) then return; end if;
    select * into plan from app_private.route_plan_versions
      where id=g.current_plan_version_id and state='published';
    if plan.id is null or not exists(select 1 from app_private.group_registrations
      where group_id=g.id and superseded_at is null and published_at is not null) then return; end if;
    select * into slot from app_private.start_slots where id=g.start_slot_id;
    source:='legacy:'||plan.id; rev:=plan.revision; pub_at:=plan.published_at;
  else return;
  end if;
  select * into p from app_private.start_points where id=slot.start_point_id;
  if slot.id is null then return; end if;
  insert into app_private.group_start_publications(event_id,group_id,source_key,schedule_id,
    revision,starts_at,published_at,published_by,point_snapshot,slot_snapshot)
  values(g.event_id,g.id,source,s.id,rev,slot.starts_at,coalesce(pub_at,clock_timestamp()),
    auth.uid(),case when p.id is not null then to_jsonb(p)||jsonb_build_object('walking_node_snapshot',(
      select jsonb_build_object('id',n.id,'coordinate',jsonb_build_array(n.coordinate[0],n.coordinate[1]),'verifiedAt',n.verified_at)
      from app_private.walking_nodes n where n.id=p.walking_node_id and n.event_id=g.event_id)) else jsonb_build_object(
      'name',slot.location_name,'private_address',slot.private_address,
      'latitude',slot.latitude,'longitude',slot.longitude,
      'walking_node_id',(select n.id from app_private.walking_nodes n where n.event_id=g.event_id and n.kind='start' and n.external_id=slot.external_id and n.verified_at is not null order by n.id limit 1),
      'walking_node_snapshot',(select jsonb_build_object('id',n.id,'coordinate',jsonb_build_array(n.coordinate[0],n.coordinate[1]),'verifiedAt',n.verified_at)
        from app_private.walking_nodes n where n.event_id=g.event_id and n.kind='start' and n.external_id=slot.external_id and n.verified_at is not null order by n.id limit 1)) end,
    to_jsonb(slot)) on conflict(group_id,source_key) do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.group_snapshot(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; pid uuid; r app_private.group_runs; c app_private.finale_publication_commitments; p uuid; d app_private.dispatch_decisions; b app_private.portal_reservations; released app_private.run_stop_location_snapshots;
begin
 base:=app_private.group_snapshot_before_visit_information(_group_id);
 select * into r from app_private.group_runs where id=(base#>>'{run,id}')::uuid;
 p:=case when r.id is not null then app_private.run_start_publication(r.id) else
   (select pub.id from app_private.group_start_publications pub where pub.group_id=_group_id order by publication_order desc limit 1) end;
 select * into c from app_private.finale_publication_commitments where publication_id=p;
 if c.publication_id is not null then
   base:=jsonb_set(base,'{group,expectedFinaleArrivalAt}',to_jsonb(c.reserved_arrival_at),true);
 end if;
 if r.id is not null and (not coalesce((base#>>'{run,ownEveningFinished}')::boolean,false)
   or coalesce((base#>>'{access,leader}')::boolean,false) or coalesce((base#>>'{access,support}')::boolean,false)) then
   select * into d from app_private.dispatch_decisions where run_id=r.id order by sequence desc limit 1;
   if c.publication_id is not null then
     select * into b from app_private.portal_reservations where start_publication_id=c.publication_id;
     base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('reservedArrivalAt',c.reserved_arrival_at,
       'finaleReservation',jsonb_build_object('id',b.id,'publicationId',c.publication_id,'revision',(select pub.revision from app_private.group_start_publications pub where pub.id=c.publication_id),'reservedArrivalAt',c.reserved_arrival_at)),true);
   end if;
   if r.status='live' and r.current_stop_id is null and d.input_snapshot->>'waitingReason'='finale_window'
     and d.input_snapshot->>'reservationId'=b.id::text then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('waitingReason','finale_window',
        'waitingUntil',d.input_snapshot->'waitingUntil','safeWaitingInstruction',c.safe_waiting_instruction),true);
   elsif r.status='paused' and d.input_snapshot ? 'planningConflict' then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('planningConflict',d.input_snapshot->'planningConflict','safeWaitingInstruction',d.reason,'emergencyInstruction',d.reason),true);
   end if;
 end if;
 if r.current_stop_id is not null then
   select * into b from app_private.portal_reservations where id=(select s.reservation_id from app_private.run_stops s where s.id=r.current_stop_id)
     or bound_stop_id=r.current_stop_id order by created_at desc limit 1;
   if b.id is not null and base#>'{run,currentStop}' is not null and base#>'{run,currentStop}'<>'null'::jsonb then
     base:=jsonb_set(base,'{run,currentStop}',base#>'{run,currentStop}'||jsonb_build_object('reservedArrivalAt',b.reserved_from,
       'arrivalWindow',jsonb_build_object('from',b.reserved_from,'until',case when b.kind='finale' then b.reserved_from+make_interval(secs=>coalesce(c.grace_seconds,(select cfg.finale_turnover_seconds from app_private.event_route_settings cfg join app_private.walking_groups g on g.event_id=cfg.event_id where g.id=r.group_id),120)) else coalesce(b.service_until,b.reserved_until) end)),true);
   end if;
 end if;
 pid:=(base#>>'{run,currentStop,portal,id}')::uuid;
 if pid is not null then
  select * into released from app_private.run_stop_location_snapshots where run_stop_id=(base#>>'{run,currentStop,id}')::uuid and run_id=r.id and portal_id=pid;
  if released.run_stop_id is not null then
   base:=jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||jsonb_build_object(
    'address',concat_ws(' ',released.address->>'street',released.address->>'houseNumber',released.address->>'addition'),
    'postalCode',released.address->>'postalCode','coordinate',case when released.longitude is not null and released.latitude is not null then jsonb_build_array(released.longitude,released.latitude) else null end),true);
  end if;
 end if;

 if pid is null then return base; end if;
 return jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||app_private.portal_visit_information_projection(pid));
end $function$
;

CREATE OR REPLACE FUNCTION app_private.run_finale_details(_run_id uuid, _decision_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; g app_private.walking_groups; p app_private.group_start_publications;
 c app_private.finale_publication_commitments; b app_private.portal_reservations; source_node uuid; target_node uuid;
 children integer; step_free boolean; metrics record; assessment jsonb; problem text; earliest timestamptz;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 select * into p from app_private.group_start_publications where id=app_private.run_start_publication(r.id);
 select * into c from app_private.finale_publication_commitments where publication_id=p.id;
 if c.publication_id is null then return jsonb_build_object('eligible',false,'code','FINAL_RESERVATION_REQUIRED');end if;
 select * into b from app_private.portal_reservations where start_publication_id=p.id;
 select count(*) into children from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null;
 select exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.children child on child.id=rc.child_id where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null and nullif(trim(child.accessibility_note),'') is not null) into step_free;
 source_node:=(app_private.evening_route_context(g.id)->>'sourceNodeId')::uuid;
 select node.id into target_node from app_private.walking_nodes node where node.portal_id=c.portal_id and node.event_id=g.event_id and node.verified_at is not null order by node.id limit 1;
 select * into metrics from app_private.walking_path_metrics(g.event_id,source_node,target_node,step_free);
 earliest:=_decision_at+make_interval(secs=>metrics.duration_seconds::integer);
 assessment:=app_private.assess_finale_reservation(g.event_id,g.id,c.portal_id,c.reserved_arrival_at,c.occupied_until,children,_decision_at);
 if metrics.duration_seconds is null then problem:='NO_SAFE_FINALE_PATH';
 elsif earliest>c.reserved_arrival_at+make_interval(secs=>c.grace_seconds) then problem:='FINAL_RESERVATION_MISSED';
 elsif not (assessment->>'eligible')::boolean then problem:=assessment#>>'{blockingCodes,0}';
 elsif b.id is null or b.status not in ('held','active') or (b.run_id is not null and b.run_id<>r.id)
  or exists(select 1 from app_private.portal_reservations other where other.run_id=r.id and other.kind='finale' and other.status in ('held','active') and other.id<>b.id) then problem:='FINAL_RESERVATION_CONFLICT';
 end if;
 return jsonb_build_object('eligible',problem is null,'code',problem,'publicationId',p.id,'revision',p.revision,
  'reservationId',b.id,'reservedArrivalAt',c.reserved_arrival_at,'waitingUntil',c.reserved_arrival_at-make_interval(secs=>metrics.duration_seconds::integer),
  'safeWaitingInstruction',c.safe_waiting_instruction,'walkSeconds',metrics.duration_seconds,'sourceNodeId',source_node,'portalId',c.portal_id,
  'earliestArrivalAt',earliest,'graceSeconds',c.grace_seconds,'capacity',assessment);
end;
$function$
;

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
  source_node_id uuid;
  final_node_id uuid;
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
  frozen_publication_id uuid; commitment app_private.finale_publication_commitments; finale_details jsonb; waiting_until timestamptz;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.status <> 'live' or run_record.current_stop_id is not null then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = run_record.schedule_revision_id and state = 'published';
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  frozen_publication_id:=app_private.run_start_publication(run_record.id);
  perform app_private.ensure_finale_commitment(frozen_publication_id);
  select * into commitment from app_private.finale_publication_commitments where finale_publication_commitments.publication_id=frozen_publication_id;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
  if commitment.publication_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_REQUIRED',_decision_at);end if;
  finale_details:=app_private.run_finale_details(_run_id,_decision_at);
  if not (finale_details->>'eligible')::boolean then return app_private.pause_for_finale_conflict(_run_id,finale_details->>'code',_decision_at);end if;
  finale_reservation_id:=app_private.try_reserve_finale(_run_id,(finale_details->>'earliestArrivalAt')::timestamptz,_decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  if _decision_at>=(finale_details->>'waitingUntil')::timestamptz then
    if _preferred_portal_id is not null then raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514';end if;
    _force_finale:=true;
  end if;
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

  source_node_id:=(app_private.evening_route_context(group_record.id)->>'sourceNodeId')::uuid;
  select node.id into final_node_id from app_private.walking_nodes node
  where node.event_id = group_record.event_id and node.kind = 'portal'
    and node.portal_id = commitment.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if source_node_id is null or final_node_id is null then raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514'; end if;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.operation_status in ('open', 'scheduled')
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
        (physical.assessment->>'occupiedUntil')::timestamptz as departure_at,
        (physical.assessment->>'plannedDepartureAt')::timestamptz as service_until,
        (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>final_path.duration_seconds::integer) as earliest_finale_at,
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
      join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
      join app_private.walking_nodes portal_node on portal_node.event_id = portal.event_id and portal_node.kind = 'portal'
        and portal_node.portal_id = portal.id and portal_node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
      cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
      cross join lateral (select app_private.assess_ordinary_portal(group_record.event_id,group_record.id,portal.id,
        _decision_at+make_interval(secs=>source_path.duration_seconds::integer),v_child_count,_decision_at) assessment) physical
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.id=frozen_publication_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce((select info.information->>'accessibility' from app_private.portal_visit_information info where info.portal_id=portal.id),application.private_draft_data ->> 'accessibility','') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
        and (physical.assessment->>'eligible')::boolean
        and (physical.assessment->>'occupiedUntil')::timestamptz <= schedule.effective_ordinary_stop_at
        and (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>final_path.duration_seconds::integer) <= commitment.reserved_arrival_at+make_interval(secs=>commitment.grace_seconds)
      order by score, portal.id
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at, service_until
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds), candidate.service_until
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
          'decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op veilige looptijd, beschikbaarheid en finalehaalbaarheid'
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
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes portal_node on portal_node.portal_id = portal.id and portal_node.event_id = group_record.event_id and portal_node.verified_at is not null
    cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
    cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.id=frozen_publication_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= commitment.reserved_arrival_at+make_interval(secs=>commitment.grace_seconds);
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

  select * into finale_path from app_private.walking_path_metrics(group_record.event_id, source_node_id, final_node_id, needs_step_free);
  if finale_path.duration_seconds is null then raise exception 'NO_SAFE_FINALE_PATH' using errcode = '23514'; end if;
  earliest_finale := _decision_at + make_interval(secs => finale_path.duration_seconds::integer);
  finale_reservation_id := app_private.try_reserve_finale(_run_id, earliest_finale, _decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  waiting_until:=commitment.reserved_arrival_at-make_interval(secs=>finale_path.duration_seconds::integer);
  if _decision_at<waiting_until then
    if not exists(select 1 from app_private.dispatch_decisions d where d.run_id=_run_id and d.decision='wait'
      and d.input_snapshot->>'waitingReason'='finale_window'
      and d.input_snapshot->>'reservationId'=finale_reservation_id::text
      and (d.input_snapshot->>'waitingUntil')::timestamptz=waiting_until) then
      insert into app_private.dispatch_decisions(event_id,run_id,sequence,decision,input_snapshot,candidate_summary,reason)
      values(group_record.event_id,_run_id,decision_number,'wait',jsonb_build_object('decidedAt',_decision_at,
        'waitingReason','finale_window','waitingUntil',waiting_until,'reservationId',finale_reservation_id,
        'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction),candidate_summary,'Wachten tot vertrek voor de vaste gepubliceerde finale-afspraak');
    end if;
    return jsonb_build_object('decision','wait','waitingReason','finale_window','waitingUntil',waiting_until,
      'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction,'reservationId',finale_reservation_id);
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
    jsonb_build_object('decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; requested integer; visited integer; reached boolean := false; first_portal uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into r from app_private.group_runs where id = _run_id for update;
  select desired_ordinary_visits into requested from app_private.walking_groups where id = r.group_id;
  if requested is not null then
    visited:=(app_private.evening_route_context(r.group_id)->>'completedOrdinaryVisits')::integer;
    reached := visited >= requested;
  end if;
  if not reached and not exists(select 1 from app_private.run_stops where run_id=_run_id) then
    select (p.point_snapshot->>'linked_portal_id')::uuid into first_portal
      from app_private.group_start_publications p where p.schedule_id=r.schedule_revision_id
      and (p.point_snapshot->>'counts_as_first_portal_visit')::boolean=true
      order by p.publication_order desc limit 1;
  end if;
  return app_private.dispatch_next_stop_before_visit_preference(
    _run_id, _decision_at, _force_finale or reached, case when reached then null else coalesce(first_portal,_preferred_portal_id) end);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.pause_for_finale_conflict(_run_id uuid, _code text, _decision_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; message text;
begin
 select wg.* into g from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where r.id=_run_id;
 message:=case _code when 'NO_SAFE_FINALE_PATH' then 'De gecontroleerde wandelroute vanaf jullie laatste bevestigde plek is niet beschikbaar. Blijf bij jullie groep en vraag de organisatie om hulp.' when 'FINAL_RESERVATION_MISSED' then 'De vaste finale-afspraak is niet meer haalbaar. Blijf bij jullie groep en vraag de organisatie om herplanning.'
  when 'FINAL_RESERVATION_REQUIRED' then 'Er ontbreekt een geldige gepubliceerde finale-afspraak. Vraag de organisatie om hulp.'
  else 'De resterende route moet door de organisatie worden gecontroleerd. Blijf bij jullie groep en vraag om hulp.' end;
 update app_private.group_runs set status='paused',version=version+1 where id=_run_id and status='live';
 insert into app_private.route_alerts(event_id,group_id,run_id,priority,code,message)
  select g.event_id,g.id,_run_id,'urgent',_code,message where not exists(select 1 from app_private.route_alerts where run_id=_run_id and code=_code and status='open');
 insert into app_private.dispatch_decisions(event_id,run_id,sequence,decision,input_snapshot,candidate_summary,reason)
  select g.event_id,_run_id,coalesce(max(d.sequence),0)+1,'wait',jsonb_build_object('decidedAt',_decision_at,'planningConflict',_code),'[]',message
  from app_private.dispatch_decisions d where d.run_id=_run_id;
 return jsonb_build_object('decision','wait','paused',true,'planningConflict',_code,'safeWaitingInstruction',message);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.run_complete_stop(_run_id uuid, _stop_id uuid, _expected_run_version integer, _all_skip_confirmed boolean, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  required_count integer;
  pending_count integer;
  visited_count integer;
  skipped_count integer;
  v_outcome app_private.stop_outcome;
  next_stop app_private.run_stops;
  v_world_id uuid;
  receipt app_private.command_receipts;
  result jsonb;
  dispatch_result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.completeStop:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.completeStop' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash or receipt.safe_result->>'runId' is distinct from _run_id::text then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    if run_record.id is null or not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select count(*) filter (where required_for_completion),
         count(*) filter (where required_for_completion and status = 'pending'),
         count(*) filter (where status = 'visited'),
         count(*) filter (where status = 'skipped')
    into required_count, pending_count, visited_count, skipped_count
  from app_private.stop_participant_statuses where run_stop_id = _stop_id;
  if required_count = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if pending_count > 0 then raise exception 'PENDING_PARTICIPANTS' using errcode = '23514'; end if;
  if not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  if visited_count = 0 and not _all_skip_confirmed then raise exception 'ALL_SKIP_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  v_outcome := case
    when visited_count > 0 and skipped_count > 0 then 'mixed'::app_private.stop_outcome
    when visited_count > 0 then 'visited'::app_private.stop_outcome
    else 'all_skipped'::app_private.stop_outcome end;
  perform p.id from app_private.scan_evidence e join app_private.portal_credentials c on c.id=e.credential_id join app_private.portals p on p.id=c.portal_id where e.run_stop_id=_stop_id for share of p;
  -- Freeze historical presence before departure or later roster changes can occur.
  if not exists(select 1 from app_private.scan_evidence e join app_private.portal_credentials c on c.id=e.credential_id
    join app_private.portals p on p.id=c.portal_id where e.run_stop_id=_stop_id and c.revoked_at is null
    and c.version=e.credential_version and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now()) and p.operation_status in ('open','paused'))
  then raise exception 'WRONG_PORTAL'; end if;
  insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id)
  select g.event_id,_run_id,_stop_id,rp.id,rc.child_id,e.id,true,clock_timestamp(),actor
  from app_private.stop_participant_statuses st join app_private.run_participants rp on rp.id=st.run_participant_id and rp.run_id=_run_id
  join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.walking_groups g on g.id=run_record.group_id
  join app_private.scan_evidence e on e.run_stop_id=st.run_stop_id
  where st.run_stop_id=_stop_id and st.required_for_completion and st.status in ('visited','skipped')
  and rp.attendance='present' and rp.departed_at is null and rc.participation_status='active'
  on conflict do nothing;
  update app_private.run_stops set state = 'completed', outcome = v_outcome,
    completed_at = clock_timestamp(), completion_actor = actor, version = version + 1 where id = _stop_id;
  update app_private.portal_reservations set status = 'completed', version = version + 1
  where id = stop_record.reservation_id;
  select portal.world_id into v_world_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
  where stop.id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, v_world_id, v_outcome);

  if stop_record.stop_kind = 'finale' then
    update app_private.group_runs set status = 'completed', current_stop_id = null,
      finished_at = clock_timestamp(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    dispatch_result := jsonb_build_object('decision', 'completed');
  elsif stop_record.stop_kind = 'ordinary' then
    update app_private.group_runs set current_stop_id = null, version = version + 1
    where id = _run_id returning * into run_record;
    dispatch_result := app_private.dispatch_after_confirmed_arrival(_run_id);
    select * into run_record from app_private.group_runs where id = _run_id;
  else
    select * into next_stop from app_private.run_stops
    where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
    if next_stop.id is null then
      update app_private.group_runs set status = 'completed', current_stop_id = null,
        finished_at = clock_timestamp(), version = version + 1
      where id = _run_id returning * into run_record;
      update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    else
      update app_private.run_stops set state = 'active', opened_at = clock_timestamp(), version = version + 1 where id = next_stop.id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop.id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
      where id = _run_id returning * into run_record;
    end if;
    dispatch_result := jsonb_build_object('decision', case when next_stop.id is null then 'completed' else 'legacy' end);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.completed', actor, jsonb_build_object('outcome', v_outcome));
  result := jsonb_build_object(
    'runId', _run_id, 'status', run_record.status, 'version', run_record.version,
    'completedStopId', _stop_id, 'outcome', v_outcome,
    'hasNextStop', run_record.current_stop_id is not null, 'dispatch', dispatch_result
  );
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.completeStop', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$function$
;
