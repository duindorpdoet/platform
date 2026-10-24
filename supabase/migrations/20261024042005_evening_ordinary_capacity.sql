
alter table app_private.portal_reservations add column service_until timestamptz;
alter table app_private.portal_reservations add column bound_stop_id uuid references app_private.run_stops(id) on delete restrict;
create unique index ordinary_reservation_bound_stop_active on app_private.portal_reservations(bound_stop_id)
  where bound_stop_id is not null and kind='ordinary' and status in ('held','active');
create index portal_reservations_bound_stop_fk on app_private.portal_reservations(bound_stop_id) where bound_stop_id is not null;
alter table app_private.portal_reservations add constraint portal_reservation_service_interval
  check (service_until is null or (service_until>reserved_from and service_until<=reserved_until));

create or replace function app_private.validate_ordinary_reservation()
returns trigger language plpgsql security definer set search_path='' as $function$
declare assessment jsonb;
begin
  if new.bound_stop_id is not null and not exists(select 1 from app_private.run_stops s
    join app_private.group_runs r on r.id=s.run_id and r.group_id=new.group_id
    join app_private.walking_groups g on g.id=r.group_id and g.event_id=new.event_id
    left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
    where s.id=new.bound_stop_id and s.run_id=new.run_id and coalesce(s.portal_id,ps.portal_id)=new.portal_id)
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  if new.kind<>'ordinary' or new.status not in ('held','active') then return new; end if;
  if tg_op='UPDATE' and row(new.portal_id,new.group_id,new.run_id,new.child_count,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.child_count,old.reserved_from,old.reserved_until,old.service_until)
    then return new; end if;
  perform app_private.lock_evening_event(new.event_id);
  if not exists(select 1 from app_private.walking_groups g where g.id=new.group_id and g.event_id=new.event_id)
    or (new.run_id is not null and not exists(select 1 from app_private.group_runs r where r.id=new.run_id and r.group_id=new.group_id and r.status in ('ready','live','paused')))
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  -- Shrinking an existing current booking never evicts the released destination.
  if tg_op='UPDATE' and new.child_count<=old.child_count and row(new.portal_id,new.group_id,new.run_id,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.reserved_from,old.reserved_until,old.service_until) then return new; end if;
  assessment:=app_private.assess_ordinary_portal(new.event_id,new.group_id,new.portal_id,new.reserved_from,new.child_count,
    statement_timestamp(),coalesce(new.service_until,new.reserved_until),new.reserved_until);
  if not (assessment->>'eligible')::boolean then raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text; end if;
  return new;
end;
$function$;
create trigger evening_ordinary_reservation_guard before insert or update on app_private.portal_reservations
for each row execute function app_private.validate_ordinary_reservation();

create or replace function app_private.complete_bound_reservation()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if new.state='completed' and old.state is distinct from new.state then
    update app_private.portal_reservations set
      status=case when new.outcome='system_skipped' then 'cancelled'::app_private.reservation_status else 'completed'::app_private.reservation_status end,
      cancelled_reason=case when new.outcome='system_skipped' then 'Bestemming expliciet gewijzigd' else cancelled_reason end,
      version=version+1
    where bound_stop_id=new.id and id is distinct from new.reservation_id and status in ('held','active');
  end if;
  return new;
end;
$function$;
create trigger evening_complete_bound_reservation after update of state on app_private.run_stops
for each row execute function app_private.complete_bound_reservation();

create or replace function app_private.release_terminal_reservations()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if new.status in ('completed','stopped') and old.status is distinct from new.status then
    update app_private.portal_reservations set status='cancelled',cancelled_reason='Tocht afgerond of veilig afgemeld',version=version+1
      where run_id=new.id and status in ('held','active');
  end if;
  return new;
end;
$function$;
create trigger evening_terminal_reservations after update of status on app_private.group_runs
for each row execute function app_private.release_terminal_reservations();

create or replace function app_private.resize_present_reservations()
returns trigger language plpgsql security definer set search_path='' as $function$
declare present_children integer;
begin
  if row(new.attendance,new.departed_at) is not distinct from row(old.attendance,old.departed_at) then return new; end if;
  select count(*) into present_children from app_private.run_participants p where p.run_id=new.run_id and p.attendance='present' and p.departed_at is null;
  if present_children=0 then
    update app_private.portal_reservations set status='cancelled',cancelled_reason='Geen aanwezige deelnemers meer',version=version+1
      where run_id=new.run_id and status in ('held','active');
  else
    update app_private.portal_reservations set child_count=present_children,version=version+1
      where run_id=new.run_id and status in ('held','active') and child_count<>present_children;
  end if;
  return new;
end;
$function$;
create trigger evening_present_reservation_size after update of attendance,departed_at on app_private.run_participants
for each row execute function app_private.resize_present_reservations();
revoke all on function app_private.validate_ordinary_reservation(),app_private.complete_bound_reservation(),app_private.release_terminal_reservations(),app_private.resize_present_reservations() from public,anon,authenticated;

-- Read-only projections shared by preview, assignment and legacy validation.
-- Mutations acquire lock_evening_event before reading this projection and writing
-- a reservation. No existing route, visit, credential or participant is rewritten.
create or replace function app_private.ordinary_portal_bookings(
  _event_id uuid, _portal_id uuid, _decision_at timestamptz
) returns table(group_id uuid, booking_id uuid, starts_at timestamptz, ends_at timestamptz,
  children integer, historical boolean, source text)
language sql stable security definer set search_path='' as $function$
with latest_runs as materialized (
  select distinct on (r.group_id) r.* from app_private.group_runs r
  join app_private.walking_groups g on g.id=r.group_id
  where g.event_id=_event_id order by r.group_id,r.created_at desc,r.id desc
), live_bookings as (
  select b.group_id,b.id,b.reserved_from,
    case when r.current_stop_id is not null and b.status='active'
      and exists(select 1 from app_private.run_stops s where s.id=r.current_stop_id and (s.reservation_id=b.id or b.bound_stop_id=s.id) and s.state='active')
      then greatest(b.reserved_until,_decision_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,60)+coalesce(cfg.route_buffer_seconds,0)))
      else b.reserved_until end as ends_at,
    b.child_count,false as historical,'reservation'::text as source
  from app_private.portal_reservations b
  left join latest_runs r on r.id=b.run_id
  left join app_private.event_route_settings cfg on cfg.event_id=b.event_id
  where b.event_id=_event_id and b.portal_id=_portal_id and b.kind='ordinary'
    and b.status in ('held','active')
    and (b.run_id is null or r.status in ('ready','live','paused'))
    and (b.expires_at is null or b.expires_at>_decision_at
      or (b.status='active' and exists(select 1 from app_private.run_stops s where s.id=r.current_stop_id and (s.reservation_id=b.id or b.bound_stop_id=s.id) and s.state='active')))
), legacy_current as (
  select r.group_id,s.id,coalesce(s.opened_at,r.started_at,_decision_at),
    greatest(coalesce(ps.planned_departure_at,_decision_at),
      _decision_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,60)+coalesce(cfg.route_buffer_seconds,0))),
    (select count(*)::integer from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null),
    false,'legacy_current'::text
  from latest_runs r join app_private.walking_groups g on g.id=r.group_id
  left join app_private.event_route_settings cfg on cfg.event_id=g.event_id
  join app_private.run_stops s on s.id=r.current_stop_id and s.state='active'
  left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
  where r.status in ('live','paused') and s.reservation_id is null
    and coalesce(s.portal_id,ps.portal_id)=_portal_id
    and not exists(select 1 from app_private.portal_reservations b where b.bound_stop_id=s.id and b.status in ('held','active'))
    and coalesce(s.stop_kind::text,'ordinary')='ordinary'
), planned as (
  select p.group_id,s.id,s.planned_arrival_at,s.planned_departure_at+make_interval(mins=>w.buffer_minutes),
    (select count(*)::integer from app_private.group_registrations a
      join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
      where a.group_id=p.group_id and a.superseded_at is null),false,'legacy_plan'::text
  from app_private.route_plan_stops s
  join app_private.route_plan_versions p on p.id=s.plan_version_id and p.state in ('valid','published')
  join app_private.walking_groups g on g.id=p.group_id and g.event_id=_event_id
  join lateral (select pw.buffer_minutes from app_private.portal_windows pw
    where pw.portal_id=s.portal_id and s.planned_arrival_at>=pw.opens_at and s.planned_departure_at<=pw.closes_at
    order by pw.opens_at,pw.id limit 1) w on true
  left join latest_runs r on r.group_id=p.group_id
  where s.portal_id=_portal_id and not (
    coalesce(r.status in ('live','paused'),false) or
    (coalesce(r.status in ('completed','stopped'),false) and
      (r.active_plan_version_id=p.id or r.created_at>=coalesce(p.published_at,p.created_at))))
), actual as (
  select r.group_id,s.id,min(a.arrived_at),max(a.arrived_at)+interval '1 microsecond',
    count(distinct a.child_id)::integer,true,'arrival'::text
  from app_private.run_stop_arrivals a join app_private.group_runs r on r.id=a.run_id
  join app_private.run_stops s on s.id=a.run_stop_id
  left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
  where a.event_id=_event_id and a.arrived and coalesce(s.portal_id,ps.portal_id)=_portal_id
    and coalesce(s.stop_kind::text,'ordinary')='ordinary'
  group by r.group_id,s.id
)
select * from live_bookings union all select * from legacy_current
union all select * from planned union all select * from actual;
$function$;

create or replace function app_private.assess_ordinary_portal(
  _event_id uuid, _group_id uuid, _portal_id uuid, _arrival_at timestamptz, _children integer,
  _decision_at timestamptz default statement_timestamp(), _visit_end timestamptz default null,
  _occupied_until timestamptz default null
) returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare p app_private.portals; cfg app_private.event_route_settings; w app_private.portal_windows;
  codes jsonb:='[]'; reasons jsonb:='[]'; visit_end timestamptz; occupied_until timestamptz;
  peak_groups integer:=0; peak_children integer:=0; total_children integer:=0;
  visit_seconds integer; buffer_seconds integer;
begin
  select * into p from app_private.portals where id=_portal_id and event_id=_event_id;
  select * into cfg from app_private.event_route_settings where event_id=_event_id;
  if p.id is null then return jsonb_build_object('eligible',false,'blockingCodes',jsonb_build_array('PORTAL_NOT_ROUTE_READY'),'reasons',jsonb_build_array('Deze poort hoort niet bij dit evenement.')); end if;
  if _children is null or _children<=0 then codes:=codes||'"EMPTY_GROUP"'::jsonb; reasons:=reasons||'"Er zijn geen aanwezige kinderen om toe te wijzen."'::jsonb; end if;
  if p.approval_status<>'approved' or p.lifecycle_status<>'active' then
    codes:=codes||'"PORTAL_NOT_APPROVED"'::jsonb; reasons:=reasons||'"Deze poort is niet goedgekeurd en actief."'::jsonb; end if;
  if p.operation_status not in ('open','scheduled') then
    codes:=codes||'"PORTAL_NOT_OPEN"'::jsonb; reasons:=reasons||jsonb_build_array(case when p.operation_status='paused' then 'Deze poort heeft pauze.' else 'Deze poort ontvangt geen nieuwe groepen.' end); end if;
  if not exists(select 1 from app_private.portal_private_locations l where l.portal_id=p.id and l.verified_at is not null)
    or not app_private.portal_has_verified_walking_connection(p.id) then
    codes:=codes||'"PORTAL_NOT_VERIFIED"'::jsonb; reasons:=reasons||'"Locatie en veilige wandelverbinding zijn nog niet bevestigd."'::jsonb; end if;
  select pw.* into w from app_private.portal_windows pw where pw.portal_id=p.id and _arrival_at>=pw.opens_at and _arrival_at<pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,pw.visit_minutes*60)))<=pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(mins=>pw.visit_minutes))>=_arrival_at+make_interval(mins=>pw.visit_minutes)
    order by pw.opens_at,pw.id limit 1;
  if w.id is null then
    codes:=codes||'"PORTAL_WINDOW_CONFLICT"'::jsonb; reasons:=reasons||'"De verwachte aankomst en het bezoek passen niet binnen de openingstijd."'::jsonb;
  else
    visit_end:=coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,w.visit_minutes*60)));
    occupied_until:=greatest(visit_end,coalesce(_occupied_until,visit_end+make_interval(secs=>greatest(cfg.route_buffer_seconds,w.buffer_minutes*60))));
    visit_seconds:=extract(epoch from visit_end-_arrival_at)::integer;
    buffer_seconds:=extract(epoch from occupied_until-visit_end)::integer;
    if _children>w.max_children_per_visit then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb;
      reasons:=reasons||jsonb_build_array(format('%s kinderen; deze poort kan maximaal %s kinderen ontvangen.',_children,w.max_children_per_visit)); end if;
    with bookings as materialized (
      select * from app_private.ordinary_portal_bookings(_event_id,p.id,_decision_at)
      where not historical and group_id<>_group_id and starts_at<occupied_until and ends_at>_arrival_at
    ), ticks as (select _arrival_at at_time union select starts_at from bookings where starts_at>_arrival_at and starts_at<occupied_until),
    per_group as (select t.at_time,b.group_id,max(b.children) children from ticks t join bookings b on b.starts_at<=t.at_time and b.ends_at>t.at_time group by t.at_time,b.group_id),
    totals as (select at_time,count(*)::integer groups,coalesce(sum(children),0)::integer children from per_group group by at_time)
    select coalesce(max(groups),0)+1,coalesce(max(children),0)+_children into peak_groups,peak_children from totals;
    if peak_groups>w.max_concurrent_groups then
      codes:=codes||'"PORTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('Dit tijdvak heeft ruimte voor %s gelijktijdige groepen; het is al bezet.',w.max_concurrent_groups)); end if;
    if peak_children>w.max_children_per_visit and not (_children>w.max_children_per_visit) then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('In dit tijdvak zouden %s kinderen tegelijk aankomen; er is ruimte voor %s.',peak_children,w.max_children_per_visit)); end if;
    with bookings as materialized (select * from app_private.ordinary_portal_bookings(_event_id,p.id,_decision_at)),
    history as (select group_id,sum(children)::integer children from bookings where historical group by group_id),
    future as (select b.group_id,max(b.children)::integer children from bookings b where not b.historical and b.ends_at>_decision_at
      and b.group_id<>_group_id and not exists(select 1 from history h where h.group_id=b.group_id) group by b.group_id)
    select coalesce((select sum(children) from history where group_id<>_group_id),0)
      +coalesce((select sum(children) from future),0)
      +greatest(_children,coalesce((select children from history where group_id=_group_id),0)) into total_children;
    if w.max_children_total is not null and total_children>w.max_children_total then
      codes:=codes||'"PORTAL_TOTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('De totale ontvangstcapaciteit van %s kinderen bij deze poort is bereikt.',w.max_children_total)); end if;
  end if;
  return jsonb_build_object('eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
    'windowId',w.id,'plannedArrivalAt',_arrival_at,'plannedDepartureAt',visit_end,'occupiedUntil',occupied_until,
    'visitSeconds',visit_seconds,'bufferSeconds',buffer_seconds,'capacity',jsonb_build_object('groupChildren',_children,
      'maxChildren',w.max_children_per_visit,'maxGroups',w.max_concurrent_groups,'peakGroups',peak_groups,
      'peakChildren',peak_children,'totalChildren',total_children,'maxChildrenTotal',w.max_children_total));
end;
$function$;
revoke all on function app_private.ordinary_portal_bookings(uuid,uuid,timestamptz),
  app_private.assess_ordinary_portal(uuid,uuid,uuid,timestamptz,integer,timestamptz,timestamptz,timestamptz) from public,anon,authenticated;

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
  source_node_id uuid;
  target_node_id uuid;
  active_children integer;
  overlapping_groups integer;
  assessment jsonb;
begin
  select plan.id as plan_id, plan.state, walking_group.id as group_id, walking_group.event_id,
         slot.external_id as start_external_id
    into plan_record
  from app_private.route_plan_versions plan
  join app_private.walking_groups walking_group on walking_group.id = plan.group_id
  join app_private.start_slots slot on slot.id = walking_group.start_slot_id
  where plan.id = new.plan_version_id;
  perform app_private.lock_evening_event(plan_record.event_id);
  if plan_record.plan_id is null then raise exception 'INVALID_ROUTE_PLAN' using errcode = '23514'; end if;
  if new.position < 1 or new.planned_departure_at <= new.planned_arrival_at then
    raise exception 'INVALID_ROUTE_TIMING' using errcode = '23514';
  end if;

  select portal.world_id into portal_world_id
  from app_private.portals portal
  join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
  where portal.id = new.portal_id and portal.event_id = plan_record.event_id and portal.approval_status = 'approved';
  if portal_world_id is null then raise exception 'PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  select candidate.* into window_record
  from app_private.portal_windows candidate
  where candidate.portal_id = new.portal_id
    and new.planned_arrival_at >= candidate.opens_at
    and new.planned_departure_at <= candidate.closes_at
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
    join app_private.portals portal on portal.id = existing.portal_id
    where existing.plan_version_id = new.plan_version_id and existing.id is distinct from new.id
      and (existing.portal_id = new.portal_id or portal.world_id = portal_world_id)
  ) then raise exception 'DUPLICATE_PORTAL_OR_WORLD' using errcode = '23514'; end if;

  assessment:=app_private.assess_ordinary_portal(plan_record.event_id,plan_record.group_id,new.portal_id,
    new.planned_arrival_at,active_children,statement_timestamp(),new.planned_departure_at,
    new.planned_departure_at+make_interval(mins=>window_record.buffer_minutes));
  if not (assessment->>'eligible')::boolean then
    raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text;
  end if;

  select node.id into target_node_id
  from app_private.walking_nodes node
  where node.event_id = plan_record.event_id and node.kind = 'portal' and node.portal_id = new.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if new.position = 1 then
    select node.id into source_node_id
    from app_private.walking_nodes node
    where node.event_id = plan_record.event_id and node.kind = 'start'
      and node.external_id = plan_record.start_external_id and node.verified_at is not null
    order by node.id limit 1;
  else
    select node.id into source_node_id
    from app_private.route_plan_stops previous_stop
    join app_private.walking_nodes node on node.portal_id = previous_stop.portal_id
      and node.event_id = plan_record.event_id and node.kind = 'portal' and node.verified_at is not null
    where previous_stop.plan_version_id = new.plan_version_id and previous_stop.position = new.position - 1
    order by node.id limit 1;
  end if;
  if not app_private.has_approved_walking_path(plan_record.event_id, source_node_id, target_node_id) then
    raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.validate_portal_total_capacity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; assessment jsonb; children integer;
begin
  select wg.* into g from app_private.route_plan_versions p join app_private.walking_groups wg on wg.id=p.group_id where p.id=new.plan_version_id;
  select count(*) into children from app_private.group_registrations a
    join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
    where a.group_id=g.id and a.superseded_at is null;
  assessment:=app_private.assess_ordinary_portal(g.event_id,g.id,new.portal_id,new.planned_arrival_at,children,
    statement_timestamp(),new.planned_departure_at);
  if assessment->'blockingCodes' ? 'PORTAL_TOTAL_CAPACITY_EXCEEDED' then
    raise exception 'PORTAL_TOTAL_CAPACITY_EXCEEDED' using errcode='23514',detail=(assessment->'reasons')::text;
  end if;
  return new;
end;
$function$;

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
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
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

  select node.id into source_node_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
  join app_private.walking_nodes node on node.portal_id = coalesce(stop.portal_id,old_stop.portal_id) and node.event_id = group_record.event_id and node.verified_at is not null
  where stop.run_id = _run_id and stop.state = 'completed'
    and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=stop.id)
  order by stop.sequence desc limit 1;
  if source_node_id is null then
    select (p.point_snapshot->>'walking_node_id')::uuid into source_node_id
    from app_private.group_start_publications p
    where p.group_id=group_record.id and p.schedule_id=run_record.schedule_revision_id
    order by p.publication_order desc limit 1;
  end if;
  select node.id into final_node_id from app_private.walking_nodes node
  where node.event_id = group_record.event_id and node.kind = 'portal'
    and node.portal_id = settings.final_portal_id and node.verified_at is not null
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
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
        and (physical.assessment->>'eligible')::boolean
        and (physical.assessment->>'occupiedUntil')::timestamptz <= schedule.effective_ordinary_stop_at
        and (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>final_path.duration_seconds::integer) <= settings.finale_last_arrival_at
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
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at;
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
  if finale_reservation_id is null then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_WINDOW_FULL',
      'Geen veilig aankomstvenster bij de eindpoort beschikbaar; handmatige herplanning vereist.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_WINDOW_FULL');
    return jsonb_build_object('decision', 'wait', 'finaleFull', true);
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

CREATE OR REPLACE FUNCTION app_private.start_ops_route_preview(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  last_lon:=coalesce(point.marker_longitude,point.geocoded_longitude,point.longitude);
  last_lat:=coalesce(point.marker_latitude,point.geocoded_latitude,point.latitude);
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
    select q.*,coalesce((physical.assessment->>'visitSeconds')::integer,settings.ordinary_visit_seconds) visit_seconds,
      coalesce((physical.assessment->>'bufferSeconds')::integer,settings.route_buffer_seconds) buffer_seconds into candidate from (
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
    ) q cross join lateral (select app_private.assess_ordinary_portal(g.event_id,g.id,q.id,
      at_time+make_interval(secs=>q.walk_s::integer),child_count,statement_timestamp()) assessment) physical
    where q.walk_s is not null and (q.id=preserved_portal or (
      at_time+make_interval(secs=>(q.walk_s+settings.ordinary_visit_seconds+settings.route_buffer_seconds)::integer)<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and q.final_seconds is not null
      and at_time+make_interval(secs=>(q.walk_s+settings.ordinary_visit_seconds+settings.route_buffer_seconds+q.final_seconds)::integer)<=settings.finale_last_arrival_at
      and (physical.assessment->>'eligible')::boolean
      and (physical.assessment->>'occupiedUntil')::timestamptz<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>q.final_seconds::integer)<=settings.finale_last_arrival_at))
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
    meters:=meters+walk_m; seconds:=seconds+walk_s+candidate.visit_seconds+candidate.buffer_seconds;
    at_time:=at_time+make_interval(secs=>candidate.visit_seconds+candidate.buffer_seconds);
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
      coalesce(point.marker_longitude,point.geocoded_longitude,point.longitude),coalesce(point.marker_latitude,point.geocoded_latitude,point.latitude)),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$
;

CREATE OR REPLACE FUNCTION api.redesign_rehearsal(_event_slug text, _scenario text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ownerid uuid:=auth.uid(); realevent uuid; eventid uuid:=gen_random_uuid(); homeid uuid:=gen_random_uuid(); registrationid uuid:=gen_random_uuid();
 groupid uuid:=gen_random_uuid(); planid uuid:=gen_random_uuid(); worldid uuid:=gen_random_uuid(); childids uuid[]:='{}'; rcids uuid[]:='{}'; portalids uuid[]:='{}'; tokens text[]:='{}';
 slotid uuid:=gen_random_uuid(); nodeid uuid; previousnode uuid:=gen_random_uuid(); runid uuid; activeid uuid; r app_private.group_runs; fixtureid uuid; portalid uuid; applicationid uuid; childid uuid; rcid uuid; participantid uuid;
 i integer; n integer; operation jsonb; scenarios jsonb:='{"start": [{"op": "empty", "title": "Start zonder aanwezigen weigeren", "history": 0, "sequence": 0, "status": "before", "seals": [0, 0, 0], "error": "EMPTY_GROUP"}, {"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Twee aanwezige kinderen bereiken de poort", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}, {"op": "snapshot", "title": "Afwezig kind krijgt geen zegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}], "arrival": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Precies de volgende bestemming staat klaar", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "inclusive": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Buiten blijven krijgt dezelfde aankomstzegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "wrong": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "wrong", "title": "Een verkeerde poortcode weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "WRONG_PORTAL"}], "duplicate": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Dezelfde opdracht blijft eenmalig", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "closed": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "close", "title": "Eigen oefenpoort sluiten", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij gesloten poort weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "PORTAL_UNAVAILABLE"}, {"op": "systemskip", "title": "Expliciete systeemoverslag zonder zegel", "history": 1, "sequence": 2, "status": "live", "seals": [0, 0, 0]}], "manual": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "skipall", "title": "Alle kinderen slaan de beleving over", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Zonder aankomst niet afronden", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "SCAN_REQUIRED"}, {"op": "scan", "title": "Alleen code bevestigen zonder definitieve zegels", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Met aankomst iedereen een zegel geven", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "offline": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "offline", "title": "Verbinding weg: geen serveropdracht ontvangen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Na herstel dezelfde aankomst bevestigen", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Herhaalde ontvangst maakt geen duplicaat", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "stale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "stale", "title": "Oude routeversie weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "STALE_VERSION"}], "early": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "departall", "title": "Eigen gezin sluit af zonder finale", "history": 2, "sequence": 0, "status": "stopped", "seals": [2, 2, 2]}], "part-departure": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "departone", "title": "Een kind vertrekt; de groep loopt door", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Vertrokken kind krijgt geen volgende zegel", "history": 2, "sequence": 3, "status": "live", "seals": [2, 1, 2]}], "finale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "arrive", "title": "Aankomst bij poort 3", "history": 3, "sequence": 4, "status": "live", "seals": [3, 3, 3]}, {"op": "arrive", "title": "Aankomst bij poort 4", "history": 4, "sequence": 5, "status": "live", "seals": [4, 4, 4]}, {"op": "arrive", "title": "Finaleaankomst telt ook bij buiten blijven", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "snapshot", "title": "Ieder aanwezig kind heeft precies een finalezegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "repeat", "title": "Geen dubbele finale of zesde zegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}]}'::jsonb; spec jsonb; report jsonb:='[]'; results jsonb; request jsonb; previous jsonb;
 problem text; currentportal uuid; token text; runversion integer; stopid uuid; leavingids uuid[]; choices jsonb; started timestamptz:=clock_timestamp(); tick timestamptz;
 actualhistory integer; actualseq integer; actualstatus text; sealcounts jsonb; view jsonb; ok boolean;
begin
 select id into realevent from app_private.events where slug=_event_slug;
 if ownerid is null or realevent is null or not (app_private.has_capability(realevent,'live_support',ownerid) or app_private.has_capability(realevent,'event_admin',ownerid)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 spec:=scenarios->_scenario;
 if spec is null then raise exception 'INVALID_SCENARIO'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ownerid::text||':redesign-rehearsal',0));
 begin
  insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings) values(eventid,'rehearsal-'||replace(eventid::text,'-',''),'Geïsoleerde generale',(now() at time zone 'Europe/Amsterdam')::date,'live',0,'{"rehearsal":true}');
  insert into app_private.households(id,label,primary_contact_user_id) values(homeid,'Oefengezin',ownerid);
  insert into app_private.household_members(household_id,user_id,relation_role) values(homeid,ownerid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(registrationid,eventid,homeid,'submitted','LAB-'||registrationid::text);
  for i in 1..3 loop
   insert into app_private.children(household_id,first_name,age_at_event) values(homeid,(array['Oefenkind A','Oefenkind B','Oefenkind C'])[i],8) returning id into childid;
   insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registrationid,childid,0) returning id into rcid;
   childids:=array_append(childids,childid);rcids:=array_append(rcids,rcid);
  end loop;
  insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,starts_at,max_groups,max_children) values(slotid,eventid,'lab-start','Oefenstart','Oefenlocatie','Geïsoleerd oefenadres',now()-interval '1 hour',1,20);
  insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at) values(previousnode,eventid,'lab-start','start',point(4.26,52.10),now());
  for i in 1..5 loop
   worldid:=gen_random_uuid();
   insert into app_private.worlds(id,event_id,slug,name,sort_order) values(worldid,eventid,'oefenwereld-'||i,'Oefenwereld '||i,i);
   applicationid:=gen_random_uuid();portalid:=gen_random_uuid();token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status) values(applicationid,eventid,ownerid,'approved');
   insert into app_private.portals(id,event_id,application_id,world_id,name,intensity,operation_status) values(portalid,eventid,applicationid,worldid,'Oefenpoort '||i,1,'open');
   insert into app_private.portal_owners(portal_id,user_id,role) values(portalid,ownerid,'owner');
   insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from) values(portalid,extensions.digest(token,'sha256'),extensions.digest(upper(token),'sha256'),1,now()-interval '1 minute');
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26+i*.0001,now());
   insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit) values(portalid,now()-interval '1 hour',now()+interval '5 hours',3,1,20);
   nodeid:=gen_random_uuid();
   insert into app_private.walking_nodes(id,event_id,kind,portal_id,coordinate,verified_at) values(nodeid,eventid,'portal',portalid,point(4.26+i*.0001,52.10),now());
   insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by) values(eventid,previousnode,nodeid,10,10,now(),ownerid);
   previousnode:=nodeid;
   portalids:=array_append(portalids,portalid);tokens:=array_append(tokens,token);
  end loop;
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id) values(groupid,eventid,'LAB-01','ready',slotid);
  insert into app_private.group_leaders(group_id,user_id,active_from,revision) values(groupid,ownerid,now()-interval '1 minute',1);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(groupid,registrationid,1,now());
  insert into app_private.route_plan_versions(id,group_id,revision,state,input_hash) values(planid,groupid,1,'draft',eventid::text);
  for i in 1..5 loop
   insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at) values(planid,i,portalids[i],now()+i*interval '5 minutes',now()+(i*5+3)*interval '1 minute');
  end loop;
  update app_private.route_plan_versions set state='published',published_at=now() where id=planid;
  update app_private.walking_groups set current_plan_version_id=planid where id=groupid;
  for operation in select * from jsonb_array_elements(spec) loop
   problem:=null;tick:=clock_timestamp();
   select * into r from app_private.group_runs where id=runid;
   if r.id is not null then
    select s.sequence,coalesce(s.portal_id,p.portal_id) into n,currentportal from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=r.current_stop_id;
    token:=tokens[array_position(portalids,currentportal)];
    select jsonb_object_agg(rp.id::text,case when rc.child_id=childids[2] then 'skipped' else 'visited' end) into choices
     from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present';
    request:=jsonb_build_object('run',runid,'stop',r.current_stop_id,'version',r.version,'token',token,'choices',choices,'key',gen_random_uuid()::text);
   end if;
   begin
    case operation->>'op'
    when 'empty' then perform api.run_start(groupid,'{}'::uuid[],(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'empty');
    when 'start' then
      results:=api.run_start(groupid,case when _scenario='start' then rcids[1:2] else rcids end,(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'start');
      runid:=(results->>'runId')::uuid;
      -- A genuine finale flag on the final isolated stop exercises the same completion transaction.
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','held',now(),now()+interval '2 hours',3) returning id into fixtureid;
      update app_private.run_stops set stop_kind='finale',portal_id=portalids[5],reservation_id=fixtureid,plan_stop_id=null where run_id=runid and sequence=5;
    when 'arrive','wrong','stale','repeat' then
      if operation->>'op'='repeat' then request:=previous; end if;
      perform api.run_arrive_and_advance((request->>'run')::uuid,(request->>'stop')::uuid,(request->>'version')::integer-case when operation->>'op'='stale' then 1 else 0 end,
       case when operation->>'op'='wrong' then encode(extensions.gen_random_bytes(32),'hex') else request->>'token' end,request->'choices',request->>'key');
      previous:=request;
    when 'close' then perform api.portal_set_operational_state(currentportal,'closed',(select version from app_private.portals where id=currentportal),'Geïsoleerde generale');
    when 'systemskip' then perform api.run_system_skip(runid,r.current_stop_id,r.version,'Gesloten oefenpoort',gen_random_uuid()::text,'system-skip');
    when 'skipall' then perform api.run_bulk_skip_pending(runid,r.current_stop_id,r.version,'Met oefenouder bevestigd',gen_random_uuid()::text,'skip-all');
    when 'complete' then perform api.run_complete_stop(runid,r.current_stop_id,r.version,true,gen_random_uuid()::text,'manual-complete');
    when 'scan' then perform api.run_scan(runid,r.current_stop_id,r.version,token,'qr');
    when 'departone','departall' then
      select array_agg(rp.id order by rp.id) into leavingids from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present' and (operation->>'op'='departall' or rc.child_id=childids[2]);
      perform api.run_end_early(runid,r.version,leavingids,'Eigen oefengezin sluit af',gen_random_uuid()::text);
      -- Restore the immutable child order used by the measurement projection.
      select array_agg(rc.child_id order by array_position(rcids,rc.id)) into childids from app_private.registration_children rc where rc.id=any(rcids);
    when 'offline' then null; -- Simulated transport omission: deliberately issue no SQL command.
    when 'snapshot' then null;
    else raise exception 'INVALID_SCENARIO';
    end case;
   exception when others then problem:=SQLERRM;
   end;
   select * into r from app_private.group_runs where id=runid;
   select count(*) into actualhistory from app_private.run_stops where run_id=runid and state='completed';
   select coalesce(sequence,0) into actualseq from app_private.run_stops where id=r.current_stop_id;actualseq:=coalesce(actualseq,0);
   actualstatus:=coalesce(r.status::text,'before');
   select jsonb_agg((select count(*) from app_private.poortenboek_passport_seals seal where seal.event_id=eventid and seal.child_id=rc.child_id) order by array_position(rcids,rc.id)) into sealcounts from app_private.registration_children rc where rc.id=any(rcids);
   ok:=problem is not distinct from operation->>'error' and actualhistory=(operation->>'history')::integer and actualseq=(operation->>'sequence')::integer and actualstatus=operation->>'status' and sealcounts=operation->'seals';
   if _scenario='finale' and actualstatus='completed' then ok:=ok and (select count(*)=3 from app_private.poortenboek_passport_seals where event_id=eventid and finale); end if;
   view:=jsonb_build_object('connected',operation->>'op'<>'offline','parent',jsonb_build_object('status',actualstatus,'stop',case when actualseq=0 then 'Geen actieve bestemming' else 'Oefenpoort '||actualseq end,'sequence',actualseq,'version',coalesce(r.version,0),'arrived',actualhistory>0,'endedEarly',r.stopped_reason='all_participants_departed'),
    'gate',jsonb_build_object('name','Geïsoleerde oefenpoort','code','LAB','status',coalesce((select operation_status from app_private.portals where id=currentportal),'open'),'scanned',exists(select 1 from app_private.scan_evidence where run_stop_id=r.current_stop_id)),
    'children',(select jsonb_agg(jsonb_build_object('id',rc.id,'name',c.first_name,'attendance',coalesce(rp.attendance::text,'absent'),'choice','Eigen keuze','seals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id),'finaleSeals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id and finale)) order by array_position(rcids,rc.id)) from app_private.registration_children rc join app_private.children c on c.id=rc.child_id left join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=runid where rc.id=any(rcids)),
    'history',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'name','Oefenpoort '||sequence,'outcome',outcome,'arrived',outcome<>'system_skipped') order by sequence) from app_private.run_stops where run_id=runid and state='completed'),'[]'::jsonb));
   report:=report||jsonb_build_array(jsonb_build_object('title',operation->>'title','expectation',(operation-'op'-'title')::text,'actual',jsonb_build_object('error',problem,'history',actualhistory,'sequence',actualseq,'status',actualstatus,'seals',sealcounts)::text,'passed',coalesce(ok,false),'at',clock_timestamp(),'durationMs',round(extract(epoch from clock_timestamp()-tick)*1000),'command',operation->>'op','view',view));
  end loop;
  raise exception using errcode='P7711',message='ROLLBACK_ISOLATED_REHEARSAL';
 exception when sqlstate 'P7711' then null;
 end;
 return jsonb_build_object('scenarioId',_scenario,'title',_scenario,'startedAt',started,'endedAt',clock_timestamp(),'passed',not exists(select 1 from jsonb_array_elements(report) item where not (item->>'passed')::boolean),'steps',report,'environment','Isolated SQL transaction; fixtures rolled back; external transport is not measured');
end $function$
;
