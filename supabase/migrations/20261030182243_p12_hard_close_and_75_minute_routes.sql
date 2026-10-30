-- Reviewed organization policy for this event only. Existing accepted route
-- versions keep their immutable walking policy; the physical closing is real.
set lock_timeout = '5s';

do $policy$
declare event_record app_private.events; close_at timestamptz;
begin
 select * into event_record from app_private.events
 where slug='duindorp-halloween-2026' for no key update;
 if event_record.id is null then return; end if;
 perform pg_advisory_xact_lock(hashtextextended(event_record.id::text||':route-dispatch',0));
 perform 1 from app_private.event_route_settings where event_id=event_record.id for update;
 if exists(select 1 from app_private.event_route_settings where event_id=event_record.id
   and max_total_walking_seconds not in(3900,4500)) then
  raise exception 'ROUTE_WALKING_POLICY_REQUIRES_REVIEW' using errcode='23514';
 end if;
 close_at:=(event_record.local_date+time '19:00') at time zone event_record.timezone;

 -- Never silently turn a different physical address into P-12.
 if exists(select 1 from app_private.portals p join app_private.portals alias
   on alias.event_id=p.event_id and alias.id<>p.id
    and app_private.portal_physical_identity(alias.id)=app_private.portal_physical_identity(p.id)
   where p.event_id=event_record.id and p.system_code='P-12'
    and alias.lifecycle_status='active' and alias.approval_status='approved'
    and alias.operation_status in('open','scheduled') and alias.system_code is distinct from 'P-12') then
  raise exception 'P12_PHYSICAL_ALIAS_REQUIRES_REVIEW' using errcode='23514';
 end if;
 if exists(select 1 from app_private.portal_windows w join app_private.portals p on p.id=w.portal_id
   where p.event_id=event_record.id and p.system_code='P-12' and w.opens_at>=close_at) then
  raise exception 'P12_HARD_CLOSE_BEFORE_OPENING' using errcode='23514';
 end if;
 if exists(select 1 from app_private.portal_windows w join app_private.portals p on p.id=w.portal_id
   where p.event_id=event_record.id and p.system_code='P-12'
    and w.closes_at not in(close_at,close_at+interval '10 minutes')) then
  raise exception 'P12_CLOSING_POLICY_REQUIRES_REVIEW' using errcode='23514';
 end if;

 update app_private.event_route_settings set max_total_walking_seconds=4500,
  route_policy_version=route_policy_version+1
 where event_id=event_record.id and max_total_walking_seconds is distinct from 4500;
 update app_private.portals set ordinary_hard_close=true,ordinary_end_grace_seconds=0,version=version+1
 where event_id=event_record.id and system_code='P-12'
  and(not ordinary_hard_close or ordinary_end_grace_seconds<>0);
 update app_private.portal_windows w set closes_at=close_at
 from app_private.portals p where p.id=w.portal_id and p.event_id=event_record.id
  and p.system_code='P-12' and w.closes_at is distinct from close_at;
end $policy$;

-- A hard close always means zero grace, including raw RPC callers. The normal
-- authorized save wrappers retain their locks, versions and command receipts.
create or replace function app_private.apply_portal_planning_policy(_portal uuid,_payload jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.validate_portal_planning_policy(_payload);
 update app_private.portals set
  arrival_headway_seconds=case when _payload?'arrivalHeadwaySeconds' then (_payload->>'arrivalHeadwaySeconds')::integer else arrival_headway_seconds end,
  ordinary_end_grace_seconds=case when coalesce((_payload->>'ordinaryHardClose')::boolean,ordinary_hard_close) then 0
   when _payload?'ordinaryEndGraceSeconds' then (_payload->>'ordinaryEndGraceSeconds')::integer else ordinary_end_grace_seconds end,
  ordinary_hard_close=case when _payload?'ordinaryHardClose' then (_payload->>'ordinaryHardClose')::boolean else ordinary_hard_close end,
  accessibility_status=case when _payload?'accessibilityStatus' then _payload->>'accessibilityStatus' else accessibility_status end
 where id=_portal;
end $$;

-- Older stored route plans must also finish the real buffer by a hard close.
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
    and (not (select p.ordinary_hard_close from app_private.portals p where p.id=new.portal_id)
      or new.planned_departure_at+make_interval(mins=>candidate.buffer_minutes)<=candidate.closes_at)
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
    where existing.plan_version_id = new.plan_version_id and existing.id is distinct from new.id
      and app_private.portal_physical_identity(existing.portal_id)=app_private.portal_physical_identity(new.portal_id)
  ) then raise exception 'DUPLICATE_PHYSICAL_VISIT' using errcode = '23514'; end if;

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
$function$
;

-- Legacy manual dispatch performs the same full physical-window check before dispatch.
CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop_before_joint_routes(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; intent app_private.live_route_visits; result jsonb; source jsonb; travel record; earliest_departure timestamptz; child_count integer; stopid uuid; reservationid uuid; finale_id uuid; final_travel record; ordinary_end timestamptz;
begin
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or r.status<>'live' or r.current_stop_id is not null then raise exception 'RUN_NOT_DISPATCHABLE' using errcode='23514'; end if;
 perform pg_advisory_xact_lock(hashtextextended((select event_id from app_private.walking_groups where id=r.group_id)::text||':route-dispatch',0));
 if not _force_finale and exists(select 1 from app_private.live_route_visits manual where manual.group_id=r.group_id and manual.retired_at is null and manual.source='manual') then
  select * into intent from app_private.live_route_visits v where v.group_id=r.group_id and v.kind<>'start' and v.retired_at is null and v.run_stop_id is null
   and not app_private.group_has_visited_portal(v.event_id,v.group_id,v.portal_id) order by v.sequence limit 1 for update;
 end if;
 if intent.id is null then return app_private.dispatch_next_stop_before_live_planboard(_run_id,_decision_at,_force_finale,_preferred_portal_id); end if;
 if _preferred_portal_id is not null and _preferred_portal_id<>intent.portal_id then raise exception 'MANUAL_ROUTE_INTENT_CONFLICT' using errcode='23514'; end if;
 if intent.kind='ordinary' then
  select app_private.portal_location(coalesce(s.portal_id,ps.portal_id)) into source from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where s.run_id=r.id and s.state='completed' order by s.sequence desc limit 1;
  if source is null then select app_private.routing_position((pub.point_snapshot->>'marker_latitude')::numeric,(pub.point_snapshot->>'marker_longitude')::numeric,(pub.point_snapshot->>'geocoded_latitude')::numeric,(pub.point_snapshot->>'geocoded_longitude')::numeric,(pub.point_snapshot->>'latitude')::numeric,(pub.point_snapshot->>'longitude')::numeric) into source from app_private.group_start_publications pub where pub.schedule_id=r.schedule_revision_id order by pub.publication_order desc limit 1; end if;
  select * into travel from app_private.destination_estimate((source->>'latitude')::numeric,(source->>'longitude')::numeric,(app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric);
  if travel.duration_seconds is null then raise exception 'MANUAL_ROUTE_LOCATION_UNAVAILABLE'; end if;
  earliest_departure:=intent.starts_at-make_interval(secs=>travel.duration_seconds::integer);
  if _decision_at<earliest_departure then return jsonb_build_object('decision','wait','retryAfterSeconds',greatest(1,ceil(extract(epoch from earliest_departure-_decision_at)))::integer,'plannedPortalId',intent.portal_id); end if;
 end if;
 begin
  if intent.kind='ordinary' and not exists(select 1 from app_private.portal_effective_windows(intent.portal_id) w where _decision_at+make_interval(secs=>travel.duration_seconds::integer)>=w.opens_at and _decision_at+make_interval(secs=>travel.duration_seconds::integer)<w.arrival_closes_at and _decision_at+make_interval(secs=>travel.duration_seconds::integer+intent.duration_seconds+intent.buffer_seconds)<=w.closes_at and intent.duration_seconds>=w.visit_seconds and intent.buffer_seconds>=w.buffer_seconds) then raise exception 'MANUAL_ROUTE_SERVICE_POLICY_CHANGED'; end if;
  result:=app_private.dispatch_next_stop_before_live_planboard(_run_id,_decision_at,intent.kind='finale',case when intent.kind='finale' then null else intent.portal_id end);
  stopid:=(result->>'stopId')::uuid;
  if stopid is not null and intent.kind='ordinary' then
   select reservation_id into reservationid from app_private.run_stops where id=stopid;
   select count(*) into child_count from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
   if not app_private.portal_interval_available(intent.portal_id,r.group_id,
    _decision_at+make_interval(secs=>travel.duration_seconds::integer),_decision_at+make_interval(secs=>travel.duration_seconds::integer+intent.duration_seconds+intent.buffer_seconds),child_count,_decision_at) then raise exception 'MANUAL_ROUTE_CAPACITY_CHANGED'; end if;
   ordinary_end:=_decision_at+make_interval(secs=>travel.duration_seconds::integer+intent.duration_seconds+intent.buffer_seconds);
   if ordinary_end>(select effective_ordinary_stop_at from app_private.group_schedule_revisions where id=r.schedule_revision_id) then raise exception 'MANUAL_ROUTE_STOP_LIMIT'; end if;
   select journey.* into final_travel from app_private.event_route_settings settings cross join lateral app_private.destination_estimate((app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) journey where settings.event_id=intent.event_id;
   if final_travel.duration_seconds is null then raise exception 'MANUAL_ROUTE_FINALE_UNAVAILABLE';end if;
   finale_id:=app_private.try_reserve_finale(r.id,ordinary_end+make_interval(secs=>final_travel.duration_seconds::integer),_decision_at);
   if finale_id is null then raise exception 'MANUAL_ROUTE_FINALE_UNAVAILABLE';end if;
   update app_private.portal_reservations set reserved_until=ordinary_end,expires_at=greatest(expires_at,ordinary_end+make_interval(secs=>(select reservation_ttl_seconds from app_private.event_route_settings where event_id=intent.event_id))),version=version+1 where id=reservationid;
  end if;
 exception when check_violation or raise_exception then
  insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
  select intent.event_id,r.group_id,r.id,intent.portal_id,'warning','MANUAL_ROUTE_RECHECK','Handmatige route-intentie is niet meer uitvoerbaar. Controleer beschikbaarheid en capaciteit in het live planbord.'
  where not exists(select 1 from app_private.route_alerts where run_id=r.id and code='MANUAL_ROUTE_RECHECK' and status='open');
  return jsonb_build_object('decision','wait','manualIntentBlocked',true,'retryAfterSeconds',120);
 end;
 return result;
end $function$
;
