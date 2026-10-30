-- Route policy approved by the organization on 30 October 2026.
-- Deployment changes policy/functions only: no route, appointment, publication,
-- run, participant, capacity or message is changed by this migration.
set lock_timeout='5s';

-- Append-only evidence for a finale time explicitly approved with a complete
-- independently validated joint calendar. The fixed start publication stays intact.
create table app_private.joint_route_finale_approvals(
 id uuid primary key default gen_random_uuid(),
 accepted_version_id uuid not null references app_private.joint_route_plan_versions(id) deferrable initially deferred,
 schedule_id uuid not null references app_private.group_schedule_revisions(id),
 group_id uuid not null references app_private.walking_groups(id),
 portal_id uuid not null references app_private.portals(id),
 previous_reserved_at timestamptz, proposed_reserved_at timestamptz not null,
 composition_hash text not null,
 approved_by uuid not null references auth.users(id), approved_at timestamptz not null default clock_timestamp(),
 check(previous_reserved_at is distinct from proposed_reserved_at),unique(accepted_version_id,group_id)
);
alter table app_private.joint_route_finale_approvals enable row level security;
revoke all on app_private.joint_route_finale_approvals from public,anon,authenticated;
create trigger preserve_joint_route_finale_approval before update or delete on app_private.joint_route_finale_approvals
 for each row execute function app_private.preserve_joint_route_plan_version();

-- The configured finale can never move away from the event's P-38. Historical
-- synthetic/legacy events without that portal keep their existing fixture finale.
create function app_private.require_p38_finale_setting() returns trigger
language plpgsql security definer set search_path='' as $$
declare canonical uuid;
begin
 select id into canonical from app_private.portals where event_id=new.event_id and system_code='P-38';
 if canonical is not null and new.final_portal_id is distinct from canonical then
  raise exception 'P38_ONLY_FINAL_PORTAL' using errcode='23514';end if;
 return new;
end $$;
create trigger require_p38_finale_setting before insert or update of final_portal_id on app_private.event_route_settings
 for each row execute function app_private.require_p38_finale_setting();
revoke all on function app_private.require_p38_finale_setting() from public,anon,authenticated;

create or replace function app_private.assert_group_schedule_timing(
  _group uuid,_slot uuid,_stop timestamptz,_arrival timestamptz
) returns void language plpgsql security definer set search_path='' as $$
declare settings app_private.event_route_settings; starts_at timestamptz; ids uuid[]; desired_end timestamptz; hard_stop timestamptz;
begin
  select s.* into settings from app_private.event_route_settings s join app_private.start_slots slot on slot.event_id=s.event_id
    join app_private.walking_groups g on g.id=_group and g.event_id=s.event_id where slot.id=_slot;
  select slot.starts_at into starts_at from app_private.start_slots slot where slot.id=_slot;
  select array_agg(distinct r.id),least(settings.global_ordinary_stop_at,
    min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at)) into ids,hard_stop
    from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id and r.status='submitted'
    where a.group_id=_group and a.superseded_at is null;
  desired_end:=app_private.dominant_end_preference(ids);
  if settings.event_id is null or settings.global_ordinary_stop_at is null or settings.finale_opens_at is null or settings.finale_last_arrival_at is null or settings.finale_closes_at is null or _stop is null or _arrival is null or _stop<starts_at or _stop>hard_stop
    or _arrival<greatest(settings.finale_opens_at,starts_at)
    or (_arrival<_stop+make_interval(secs=>settings.finale_planning_transfer_seconds) and not exists(
      select 1 from app_private.joint_route_finale_approvals approval
      join app_private.group_schedule_revisions approved on approved.id=approval.schedule_id
      where approval.group_id=_group and approved.start_slot_id=_slot
       and approved.id=(app_private.route_group_start_context(_group)->>'scheduleId')::uuid
       and approval.composition_hash=app_private.start_group_composition_hash(_group)
       and approval.portal_id=settings.final_portal_id and approval.proposed_reserved_at=_arrival
       and (not exists(select 1 from app_private.joint_route_plan_versions pending where pending.id=approval.accepted_version_id)
        or (app_private.canonical_route_group_current(_group) and exists(
         select 1 from jsonb_array_elements(app_private.canonical_route_group_plan(_group)->'visits') v
         where v->>'kind'='finale' and (v->>'portalId')::uuid=settings.final_portal_id and (v->>'startsAt')::timestamptz=_arrival)))))
    or _arrival>settings.finale_last_arrival_at
    or _arrival+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds)>settings.finale_closes_at
    or (desired_end is not null and _arrival+make_interval(secs=>settings.finale_show_seconds)>
      desired_end+make_interval(secs=>app_private.group_end_overrun_seconds())) then
    raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode='23514';
  end if;
  if not exists(select 1 from app_private.portal_windows w where w.portal_id=settings.final_portal_id
    and _arrival>=w.opens_at and _arrival+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds)<=w.closes_at) then
    raise exception 'FINALE_PHYSICAL_WINDOW_CONFLICT' using errcode='23514';
  end if;
end $$;

create or replace function app_private.joint_route_source_hash(_event uuid) returns text
language sql stable security definer set search_path='' as $$
 select encode(extensions.digest(convert_to(jsonb_build_object(
  'policyVersion',2,
  'event',(select jsonb_build_array(e.settings,e.local_date) from app_private.events e where e.id=_event),
  'settings',(select to_jsonb(s)-array['version','updated_at','updated_by'] from app_private.event_route_settings s where s.event_id=_event),
  'groups',(select jsonb_agg(jsonb_build_array(g.id,g.retired_at,
    app_private.start_group_composition_hash(g.id),app_private.group_ordinary_deadline(g.id),
    ctx.value->'scheduleId',ctx.value->'planId',ctx.value->'startsAt',ctx.value->'expectedFinaleArrivalAt',
    coalesce(nullif(ctx.value->'pointSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    coalesce(nullif(ctx.value->'slotSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    (select jsonb_build_array(p.active,p.accessible,p.available_from,p.available_until,p.max_gathering_groups,p.max_gathering_children) from app_private.start_points p where p.id=(ctx.value#>>'{pointSnapshot,id}')::uuid),
    (select jsonb_build_array(s.active,s.max_groups,s.max_children)from app_private.start_slots s where s.id=(ctx.value#>>'{slotSnapshot,id}')::uuid)) order by g.id)
   from app_private.walking_groups g cross join lateral(select app_private.route_group_start_context(g.id) value) ctx where g.event_id=_event),
  'children',(select jsonb_agg(jsonb_build_array(rc.id,rc.participation_status,c.id,c.step_free_required,app_private.child_step_free_requirement(c.id)) order by rc.id)
   from app_private.registrations r join app_private.registration_children rc on rc.registration_id=r.id join app_private.children c on c.id=rc.child_id where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'registrations',(select jsonb_agg(jsonb_build_array(r.id,r.status,r.preferred_start_at,r.desired_end_at,r.requested_ordinary_stop_at) order by r.id) from app_private.registrations r where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'portals',(select jsonb_agg(jsonb_build_array(p.id,app_private.portal_physical_identity(p.id),p.lifecycle_status,p.approval_status,p.operation_status,
    p.arrival_headway_seconds,p.ordinary_end_grace_seconds,p.ordinary_hard_close,app_private.routing_coordinate(app_private.portal_location(p.id)),
    app_private.portal_accessibility_status(p.id),
    (select jsonb_agg(jsonb_build_array(w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total) order by w.opens_at,w.closes_at,w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id) from app_private.portals p where p.event_id=_event),
  'nodes',(select jsonb_agg(to_jsonb(n) order by n.id) from app_private.walking_nodes n where n.event_id=_event),
  'edges',(select jsonb_agg(to_jsonb(e) order by e.id) from app_private.walking_edges e where e.event_id=_event)
 )::text,'UTF8'),'sha256'),'hex')
$$;

-- A physical visit belongs to the group and to the children who really arrived.
-- Moving a family does not erase a child's history or turn portal aliases into
-- new houses. Administrative gatherings, absent children and unconfirmed stops
-- never create visit history here.
create or replace function app_private.group_has_visited_portal(_event uuid,_group uuid,_portal uuid)
returns boolean language sql stable security definer set search_path='' as $$
 with destination as materialized(select app_private.portal_physical_identity(p.id) physical_id from app_private.portals p where p.id=_portal and p.event_id=_event),
 current_children as materialized(
  select child.child_id from app_private.group_registrations assigned
  join app_private.walking_groups current_group on current_group.id=assigned.group_id and current_group.event_id=_event
  join app_private.registration_children child on child.registration_id=assigned.registration_id and child.participation_status='active'
  where assigned.group_id=_group and assigned.superseded_at is null
  union
  select child.child_id from app_private.group_runs current_run
  join app_private.walking_groups current_group on current_group.id=current_run.group_id and current_group.event_id=_event
  join app_private.run_participants present on present.run_id=current_run.id and present.attendance='present' and present.departed_at is null
  join app_private.registration_children child on child.id=present.registration_child_id and child.participation_status='active'
  where current_run.group_id=_group and current_run.status in('live','paused')
 )
 select exists(select 1 from app_private.group_portal_visits v cross join destination d
  where v.event_id=_event and v.group_id=_group and app_private.portal_physical_identity(v.portal_id)=d.physical_id)
 or exists(select 1 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id and r.group_id=_group
  join app_private.walking_groups g on g.id=r.group_id and g.event_id=_event
  left join app_private.route_plan_stops planned on planned.id=s.plan_stop_id cross join destination d
  where app_private.portal_physical_identity(coalesce(s.portal_id,planned.portal_id))=d.physical_id
   and (exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=s.id and a.event_id=_event and a.arrived)
    or (s.state='completed' and s.outcome in('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=s.id))))
 or exists(select 1 from current_children child
  join app_private.run_stop_arrivals arrived on arrived.child_id=child.child_id and arrived.event_id=_event and arrived.arrived
  join app_private.run_stops stop on stop.id=arrived.run_stop_id
  join app_private.group_runs historical_run on historical_run.id=stop.run_id
  join app_private.walking_groups historical_group on historical_group.id=historical_run.group_id and historical_group.event_id=_event
  left join app_private.route_plan_stops planned on planned.id=stop.plan_stop_id cross join destination d
  where app_private.portal_physical_identity(coalesce(stop.portal_id,planned.portal_id))=d.physical_id)
$$;
revoke all on function app_private.group_has_visited_portal(uuid,uuid,uuid) from public,anon,authenticated;

create or replace function api.admin_joint_route_planning_input(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; settings app_private.event_route_settings;
 groups_json jsonb; portals_json jsonb; legs_json jsonb; before_json jsonb; fixed_json jsonb;
 group_ids uuid[]; diagnostics jsonb;
begin
 select * into e from app_private.events where slug=_event_slug;
 if e.id is null or auth.uid() is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into settings from app_private.event_route_settings where event_id=e.id;

 with raw as materialized (
  select g.*,s.id schedule_id,s.state schedule_state,s.expected_finale_arrival_at,slot.starts_at draft_starts_at,
   point.id point_id,point.active point_active,point.accessible point_accessible,point.available_from,point.available_until,point.max_gathering_groups,point.max_gathering_children,
   slot.max_children slot_max_children,point.linked_portal_id,point.counts_as_first_portal_visit,pub.id publication_id,pub.starts_at published_starts_at,pub.point_snapshot,
   case when pub.id is not null then app_private.routing_position((pub.point_snapshot->>'marker_latitude')::numeric,(pub.point_snapshot->>'marker_longitude')::numeric,
    (pub.point_snapshot->>'geocoded_latitude')::numeric,(pub.point_snapshot->>'geocoded_longitude')::numeric,
    (pub.point_snapshot->>'latitude')::numeric,(pub.point_snapshot->>'longitude')::numeric) else app_private.start_point_location(point.id) end origin,
   (select count(*) from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null)::integer children,
   case when approved.schedule_id is not null then approved.dominant_end_at
    when s.input_snapshot?'dominantEndAt' then (s.input_snapshot->>'dominantEndAt')::timestamptz
    else app_private.dominant_end_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null)) end desired_end
  from app_private.walking_groups g
  cross join lateral(select app_private.route_group_start_context(g.id) value) context
  left join lateral app_private.current_start_publication(g.id) pub on true
  join app_private.group_schedule_revisions s on s.id=(context.value->>'scheduleId')::uuid
  join app_private.start_slots slot on slot.id=s.start_slot_id
  join app_private.start_points point on point.id=coalesce(nullif(context.value#>>'{pointSnapshot,id}','')::uuid,slot.start_point_id)
  left join app_private.registration_management_schedule_preferences approved on approved.group_id=g.id and approved.schedule_id=s.id and approved.composition_hash=app_private.start_group_composition_hash(g.id)
  where g.event_id=e.id and g.retired_at is null and not app_private.admin_registration_group_started(g.id)
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',g.id,'code',g.system_code,'childCount',g.children,'startNodeId','start:'||g.id,
  'startsAt',coalesce(g.published_starts_at,g.draft_starts_at),'startConfirmed',g.publication_id is not null,
  'ordinaryStopAt',app_private.group_ordinary_deadline(g.id),'desiredEndAt',g.desired_end,'maxOrdinaryVisits',null,
  'requiresStepFree',exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null and app_private.child_step_free_requirement(rc.child_id) is true),
  'accessibilityNeedsReview',exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null and app_private.child_step_free_requirement(rc.child_id) is null),
  'fixedFirstPortalId',case when g.publication_id is not null then case when coalesce((g.point_snapshot->>'counts_as_first_portal_visit')::boolean,false) then (g.point_snapshot->>'linked_portal_id')::uuid end else case when g.counts_as_first_portal_visit then g.linked_portal_id end end,
  'excludedPortalIds',coalesce((select jsonb_agg(distinct app_private.portal_physical_identity(p.id) order by app_private.portal_physical_identity(p.id)) from app_private.portals p where p.event_id=e.id and (
    app_private.group_has_visited_portal(e.id,g.id,p.id) or exists(select 1 from app_private.run_stop_arrivals arrival
     join app_private.run_stops stop on stop.id=arrival.run_stop_id left join app_private.route_plan_stops planned on planned.id=stop.plan_stop_id
     join app_private.registration_children rc on rc.child_id=arrival.child_id and rc.participation_status='active'
     join app_private.group_registrations assignment on assignment.registration_id=rc.registration_id and assignment.superseded_at is null
     where arrival.event_id=e.id and arrival.arrived and assignment.group_id=g.id and coalesce(stop.portal_id,planned.portal_id)=p.id))), '[]'),
  'finale',jsonb_build_object('portalId',settings.final_portal_id,'reservedAt',g.expected_finale_arrival_at,
   'latestArrivalAt',app_private.schedule_latest_finale_arrival(g.schedule_id),
   'reservationValid',coalesce(settings.finale_available,false) and exists(select 1 from app_private.portals p cross join lateral app_private.portal_effective_windows(p.id) w where p.id=settings.final_portal_id
    and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in('open','scheduled') and app_private.portal_location_ready(p.id)
    and g.expected_finale_arrival_at>=w.opens_at and g.expected_finale_arrival_at<=w.arrival_closes_at
    and g.expected_finale_arrival_at+make_interval(secs=>w.visit_seconds+w.buffer_seconds)<=w.closes_at
    and g.children<=w.max_children and g.expected_finale_arrival_at<=app_private.schedule_latest_finale_arrival(g.schedule_id))),
  '_latitude',(g.origin->>'latitude')::numeric,'_longitude',(g.origin->>'longitude')::numeric,
  '_pointId',g.point_id,'_pointActive',g.point_active,'_pointAccessible',g.point_accessible,'_availableFrom',g.available_from,'_availableUntil',g.available_until,
  '_maxGatheringGroups',g.max_gathering_groups,'_maxGatheringChildren',g.max_gathering_children,'_slotMaxChildren',g.slot_max_children
 ) order by g.id),'[]') into groups_json from raw g where g.children>0;
 select coalesce(array_agg((item->>'id')::uuid),'{}'::uuid[]) into group_ids from jsonb_array_elements(groups_json) item;

 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'physicalId',app_private.portal_physical_identity(p.id),'code',p.system_code,'name',p.name,'nodeId','portal:'||p.id,'worldSlug',w.slug,
  'finale',app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(settings.final_portal_id),'accessibilityStatus',app_private.portal_accessibility_status(p.id),
  '_latitude',(app_private.portal_location(p.id)->>'latitude')::numeric,'_longitude',(app_private.portal_location(p.id)->>'longitude')::numeric,
  'windows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',win.opens_at,'arrivalClosesAt',win.arrival_closes_at,'closesAt',win.closes_at,
   'visitSeconds',win.visit_seconds,'bufferSeconds',win.buffer_seconds,'maxGroups',win.max_groups,'maxChildren',win.max_children,
   'maxTotalChildren',win.max_total_children,'headwaySeconds',win.headway_seconds,'maxConcurrentChildren',win.max_concurrent_children) order by win.opens_at,win.closes_at)
   from app_private.portal_effective_windows(p.id) win),'[]')) order by p.id),'[]') into portals_json
 from app_private.portals p join app_private.worlds w on w.id=p.world_id
 where p.event_id=e.id and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in('open','scheduled') and app_private.portal_location_ready(p.id);

 if jsonb_array_length(groups_json)>60 or jsonb_array_length(portals_json)>120 then raise exception 'JOINT_PLANNING_SIZE_LIMIT' using errcode='54000';end if;

 with nodes as materialized (
  select item->>'startNodeId' id,(item->>'_latitude')::numeric latitude,(item->>'_longitude')::numeric longitude from jsonb_array_elements(groups_json) item
  union all select item->>'nodeId',(item->>'_latitude')::numeric,(item->>'_longitude')::numeric from jsonb_array_elements(portals_json) item
 ), destinations as materialized (select * from nodes where id like 'portal:%')
 select coalesce(jsonb_agg(jsonb_build_object('from',a.id,'to',b.id,'seconds',travel.duration_seconds,'meters',travel.distance_m) order by a.id,b.id),'[]') into legs_json
 from nodes a cross join destinations b cross join lateral app_private.destination_estimate(a.latitude,a.longitude,b.latitude,b.longitude) travel
 where a.latitude is not null and a.longitude is not null and b.latitude is not null and b.longitude is not null and travel.duration_seconds is not null;

 with previous_physical as materialized (
  select v.id,lag(v.portal_id)over(partition by v.group_id order by v.sequence,v.id) previous_portal
  from app_private.live_route_visits v where v.group_id=any(group_ids) and v.retired_at is null and v.kind<>'start'
 ), leg_lookup as materialized (
  select coalesce(jsonb_object_agg((leg->>'from')||'>'||(leg->>'to'),leg),'{}'::jsonb) legs from jsonb_array_elements(legs_json) leg
 )
 select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'startsAt',item->'startsAt',
  'finaleArrivalAt',finale.starts_at,'expectedCompletionAt',finale.starts_at+make_interval(secs=>finale.duration_seconds),
  'diagnostics','[]'::jsonb,'visits',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'portalId',v.portal_id,'kind',v.kind,'sequence',v.sequence,'startsAt',v.starts_at,
   'visitSeconds',v.duration_seconds,'bufferSeconds',v.buffer_seconds,'walkSeconds',coalesce((travel.value->>'seconds')::integer,0),
   'walkMeters',coalesce((travel.value->>'meters')::integer,0)) order by v.sequence,v.id)
   from app_private.live_route_visits v left join previous_physical previous on previous.id=v.id cross join leg_lookup lookup
   left join lateral(select lookup.legs->(coalesce('portal:'||previous.previous_portal,item->>'startNodeId')||'>portal:'||v.portal_id) value) travel on v.kind<>'start'
   where v.group_id=g.id and v.retired_at is null),'[]')) order by g.id),'[]') into before_json
 from jsonb_array_elements(groups_json) item join app_private.walking_groups g on g.id=(item->>'id')::uuid
 left join lateral(select v.* from app_private.live_route_visits v where v.group_id=g.id and v.retired_at is null and v.kind='finale' order by v.sequence desc,v.id limit 1) finale on true;

 with existing as materialized (
  select p.id portal_id,o.group_id,o.starts_at,o.ends_at,o.child_count from app_private.portals p cross join lateral app_private.portal_occupancy_intervals(p.id,statement_timestamp()) o
  where p.event_id=e.id and not(o.group_id=any(group_ids))
  union all
  select history.portal_id,history.group_id,history.arrived_at,history.arrived_at,
   (select count(distinct arrival.child_id)::integer from app_private.run_stop_arrivals arrival where arrival.run_stop_id=history.first_stop_id and arrival.arrived)
  from app_private.group_portal_visits history where history.event_id=e.id and not(history.group_id=any(group_ids))
 )
 select coalesce(jsonb_agg(jsonb_build_object('groupId',q.group_id,'portalId',q.portal_id,'physicalId',app_private.portal_physical_identity(q.portal_id),'kind',case when q.portal_id=settings.final_portal_id then 'finale' else 'ordinary' end,
  'sequence',1,'startsAt',q.starts_at,'visitSeconds',greatest(0,extract(epoch from q.ends_at-q.starts_at)::integer),'bufferSeconds',0,'children',q.child_count,'walkSeconds',0,'walkMeters',0) order by q.portal_id,q.group_id,q.starts_at,q.ends_at),'[]') into fixed_json
 from (select distinct * from existing where starts_at is not null and ends_at is not null) q;

 select coalesce(jsonb_agg(jsonb_build_object('code','START_APPOINTMENT_REQUIRED','severity','block','groupId',g.id,
  'message','Een actieve groep heeft nog geen opgeslagen startafspraak. Kies deze eerst via de bestaande startindeling.') order by g.id),'[]') into diagnostics
 from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null and not app_private.admin_registration_group_started(g.id)
  and g.current_schedule_revision_id is null and exists(select 1 from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null);
 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','PHYSICAL_PORTAL_POLICY_CONFLICT','severity','block','portalId',p.id,
  'message','Twee actieve poortregistraties voor hetzelfde fysieke huis hebben tegenstrijdige ontvangstgegevens. Controleer vensters, capaciteit en toegankelijkheid; er is geen hogere fictieve capaciteit gekozen.') order by p.id)
  from app_private.portals p where p.event_id=e.id and p.lifecycle_status='active' and p.approval_status='approved' and not app_private.portal_physical_policy_consistent(p.id)),'[]');

 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','START_POINT_UNAVAILABLE','severity','block','groupId',item->>'id',
  'message','De vaste verzamelplek is op het startmoment niet binnen de actuele harde beschikbaarheid. Corrigeer de afspraak via de bestaande startindeling.'))
  from jsonb_array_elements(groups_json) item where not coalesce((item->>'_pointActive')::boolean,false)
   or (item->>'startsAt')::timestamptz<(item->>'_availableFrom')::timestamptz or (item->>'startsAt')::timestamptz>=(item->>'_availableUntil')::timestamptz),'[]');
 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','START_LOCATION_MISSING','severity','block','groupId',item->>'id',
  'message','De vaste verzamelplek heeft geen bruikbare opgeslagen ingangspin voor de looproute.'))
  from jsonb_array_elements(groups_json) item where item->>'_latitude' is null or item->>'_longitude' is null),'[]');
 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','GATHERING_CAPACITY','severity','block','groupId',item->>'id',
  'message','De werkelijke groepsgrootte overschrijdt de aparte verzamelcapaciteit.'))
  from jsonb_array_elements(groups_json) item where (item->>'childCount')::integer>least((item->>'_maxGatheringChildren')::integer,(item->>'_slotMaxChildren')::integer)),'[]');
 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','GATHERING_ACCESSIBILITY','severity','block','groupId',item->>'id',
  'message','De vaste verzamelplek is niet als geschikt drempelvrij bevestigd. Controleer de beschikbaarheid of kies via de bestaande startindeling een geschikte verzamelplek.'))
  from jsonb_array_elements(groups_json) item where ((item->>'requiresStepFree')::boolean and (item->>'_pointAccessible')::boolean is distinct from true)
   or ((item->>'accessibilityNeedsReview')::boolean and (item->>'_pointAccessible')::boolean is false)),'[]');
 diagnostics:=diagnostics||coalesce((select jsonb_agg(jsonb_build_object('code','GATHERING_ACCESSIBILITY_REVIEW','severity','warning','groupId',item->>'id',
  'message','Controleer de toegankelijkheid van de verzamelplek; de behoefte en beschikbaarheid zijn niet automatisch bevestigd.'))
  from jsonb_array_elements(groups_json) item where (item->>'accessibilityNeedsReview')::boolean and item->>'_pointAccessible' is null),'[]');

 if exists(select 1 from app_private.portals p where p.event_id=e.id and p.system_code='P-38' and p.id is distinct from settings.final_portal_id) then
  diagnostics:=diagnostics||jsonb_build_array(jsonb_build_object('code','P38_ONLY_FINAL_PORTAL','severity','block','message','P-38 is de enige fysieke finaleplaats. Herstel de finale-instelling voordat een route wordt berekend.'));
 end if;
 return jsonb_build_object('eventId',e.id,'sourceHash',app_private.joint_route_source_hash(e.id),'boardHash',app_private.live_planboard_hash(e.id),
  'policyVersion','joint-reception-v2','maxGroupOverrunSeconds',app_private.group_end_overrun_seconds(),
  'maxLegWalkingSeconds',900,'maxTotalWalkingSeconds',3600,'needsAnders',false,
  'groups',coalesce((select jsonb_agg(item-array['_latitude','_longitude','_pointId','_pointActive','_pointAccessible','_availableFrom','_availableUntil','_maxGatheringGroups','_maxGatheringChildren','_slotMaxChildren'] order by item->>'id') from jsonb_array_elements(groups_json) item),'[]'),
  'portals',coalesce((select jsonb_agg(item-'_latitude'-'_longitude' order by item->>'id') from jsonb_array_elements(portals_json) item),'[]'),
  'legs',legs_json,'fixedVisits',fixed_json,'before',before_json,'diagnostics',diagnostics);
end $$;

-- Check the linked first physical visit independently of any browser diagnostic
-- or score. Candidate times include exact reception/headway/capacity boundaries.
create function app_private.joint_first_visit_feasible(_input jsonb,_group jsonb,_calendar jsonb,_finale_at timestamptz)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare portal jsonb;leg jsonb;exit_leg jsonb;win jsonb;occupied jsonb;arrival timestamptz;
 earliest timestamptz;latest timestamptz;service integer;buffer integer;physical uuid;children integer;
begin
 select * into portal from jsonb_array_elements(_input->'portals') p where p->>'id'=_group->>'fixedFirstPortalId' and not coalesce((p->>'finale')::boolean,false);
 if portal is null or _finale_at is null then return false;end if;
 physical:=app_private.portal_physical_identity((portal->>'id')::uuid);children:=(_group->>'childCount')::integer;
 if exists(select 1 from jsonb_array_elements_text(_group->'excludedPortalIds') id where id::uuid=physical)
  or ((coalesce((_group->>'requiresStepFree')::boolean,false) or coalesce((_group->>'accessibilityNeedsReview')::boolean,false))
   and portal->>'accessibilityStatus'<>'step_free') then return false;end if;
 select * into leg from jsonb_array_elements(_input->'legs') l where l->>'from'=_group->>'startNodeId' and l->>'to'=portal->>'nodeId';
 select * into exit_leg from jsonb_array_elements(_input->'legs') l where l->>'from'=portal->>'nodeId' and l->>'to'='portal:'||(_group#>>'{finale,portalId}');
 if leg is null or exit_leg is null or (leg->>'seconds')::integer>(_input->>'maxLegWalkingSeconds')::integer
  or (leg->>'seconds')::integer+(exit_leg->>'seconds')::integer>(_input->>'maxTotalWalkingSeconds')::integer then return false;end if;
 select coalesce(jsonb_agg(jsonb_build_object('group_id',v->>'groupId','starts_at',v->>'startsAt',
  'ends_at',(v->>'startsAt')::timestamptz+make_interval(secs=>(v->>'visitSeconds')::integer+(v->>'bufferSeconds')::integer),
  'child_count',(v->>'children')::integer)),'[]') into occupied from jsonb_array_elements(_calendar) v
 where v->>'kind'<>'start' and app_private.portal_physical_identity((v->>'portalId')::uuid)=physical and v->>'groupId'<>_group->>'id';
 for win in select * from jsonb_array_elements(portal->'windows') loop
  service:=(win->>'visitSeconds')::integer;buffer:=(win->>'bufferSeconds')::integer;
  earliest:=greatest((_group->>'startsAt')::timestamptz+make_interval(secs=>(leg->>'seconds')::integer),(win->>'opensAt')::timestamptz);
  latest:=least((win->>'arrivalClosesAt')::timestamptz-interval '1 microsecond',
   (win->>'closesAt')::timestamptz-make_interval(secs=>service+buffer),(_group->>'ordinaryStopAt')::timestamptz-make_interval(secs=>service),
   _finale_at-make_interval(secs=>service+(exit_leg->>'seconds')::integer));
  if children>(win->>'maxChildren')::integer or earliest>latest then continue;end if;
  for arrival in select distinct tick from (
   select earliest tick union all
   select (c->>'starts_at')::timestamptz+make_interval(secs=>(win->>'headwaySeconds')::integer) from jsonb_array_elements(occupied)c union all
   select (c->>'starts_at')::timestamptz-make_interval(secs=>(win->>'headwaySeconds')::integer) from jsonb_array_elements(occupied)c union all
   select (c->>'ends_at')::timestamptz from jsonb_array_elements(occupied)c
  ) boundary where tick between earliest and latest order by tick loop
   if app_private.portal_interval_available_from_occupancy((portal->>'id')::uuid,(_group->>'id')::uuid,arrival,
    arrival+make_interval(secs=>service+buffer),children,occupied) then return true;end if;
  end loop;
 end loop;
 return false;
end $$;
revoke all on function app_private.joint_first_visit_feasible(jsonb,jsonb,jsonb,timestamptz) from public,anon,authenticated;

create or replace function app_private.validate_joint_route_proposal(_input jsonb,_plans jsonb) returns void
language plpgsql stable security definer set search_path='' as $$
declare plan jsonb; expected jsonb; visit jsonb; portal jsonb; leg jsonb; win jsonb;
 calendar jsonb:=coalesce(_input->'fixedVisits','[]');gid uuid;pid uuid;physical uuid;visited uuid[];
 children integer;position integer;ordinary integer;finales integer;walking integer;seconds integer;buffer integer;
 start_at timestamptz;cursor_at timestamptz;finish_at timestamptz;node text;occupied jsonb;needed_step_free boolean;
begin
 if jsonb_typeof(_plans) is distinct from 'array' or jsonb_array_length(_plans)>500 then raise exception 'INVALID_JOINT_ROUTE_PROPOSAL' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(_input->'diagnostics','[]')) d where d->>'severity'='block') then
  raise exception 'JOINT_ROUTE_INPUT_BLOCKED' using errcode='23514',detail=(_input->'diagnostics')::text;end if;
 if jsonb_array_length(_plans)<>jsonb_array_length(_input->'groups') or exists(
  select 1 from jsonb_array_elements(_input->'groups') g where (select count(*) from jsonb_array_elements(_plans) p where p->>'groupId'=g->>'id')<>1) then
  raise exception 'JOINT_ROUTE_GROUP_SET_CHANGED' using errcode='23514';end if;
 for plan in select * from jsonb_array_elements(_plans) loop
  if jsonb_typeof(plan->'visits') is distinct from 'array' or jsonb_array_length(plan->'visits') not between 1 and jsonb_array_length(_input->'portals') then raise exception 'INVALID_JOINT_ROUTE_PROPOSAL' using errcode='22023';end if;
  select * into expected from jsonb_array_elements(_input->'groups') g where g->>'id'=plan->>'groupId';
  if expected is null then raise exception 'JOINT_ROUTE_GROUP_SET_CHANGED' using errcode='23514';end if;
  calendar:=calendar||coalesce((select jsonb_agg(v||jsonb_build_object('groupId',plan->>'groupId','children',(expected->>'childCount')::integer)) from jsonb_array_elements(plan->'visits') v),'[]');
 end loop;
 for plan in select * from jsonb_array_elements(_plans) order by value->>'groupId' loop
  gid:=(plan->>'groupId')::uuid;
  select * into expected from jsonb_array_elements(_input->'groups') g where g->>'id'=gid::text;
  children:=(expected->>'childCount')::integer;cursor_at:=(expected->>'startsAt')::timestamptz;node:=expected->>'startNodeId';
  if not isfinite(cursor_at) or (plan->>'startsAt')::timestamptz is distinct from cursor_at then raise exception 'START_APPOINTMENT_CHANGED' using errcode='23514';end if;
  position:=0;ordinary:=0;finales:=0;walking:=0;
  select coalesce(array_agg(coalesce(app_private.portal_physical_identity(x::uuid),x::uuid)),'{}') into visited from jsonb_array_elements_text(expected->'excludedPortalIds') x;
  if expected->>'fixedFirstPortalId' is not null and (select v->>'portalId' from jsonb_array_elements(plan->'visits') v where (v->>'sequence')::integer=1 limit 1) is distinct from expected->>'fixedFirstPortalId' then
   if app_private.joint_first_visit_feasible(_input,expected,calendar,(plan->>'finaleArrivalAt')::timestamptz) then
    raise exception 'FEASIBLE_FIRST_PORTAL_MUST_BE_PRESERVED' using errcode='23514';end if;
   if not exists(select 1 from jsonb_array_elements(coalesce(plan->'diagnostics','[]')) d where d->>'code' in('FIRST_PORTAL_ALTERNATIVE','FIXED_FIRST_PORTAL_REPLACED')) then
    raise exception 'FIRST_PORTAL_ALTERNATIVE_REVIEW_REQUIRED' using errcode='23514';end if;
  end if;
  for visit in select * from jsonb_array_elements(plan->'visits') order by (value->>'sequence')::integer loop
   position:=position+1;pid:=(visit->>'portalId')::uuid;physical:=app_private.portal_physical_identity(pid);
   if (visit->>'sequence')::integer<>position or visit->>'kind' not in('ordinary','finale') or finales>0 then raise exception 'INVALID_ROUTE_SEQUENCE' using errcode='23514';end if;
   select * into portal from jsonb_array_elements(_input->'portals') p where p->>'id'=pid::text;
   if portal is null or physical is null then raise exception 'PORTAL_UNAVAILABLE' using errcode='23514';end if;
   if physical=any(visited) then raise exception 'DUPLICATE_PHYSICAL_VISIT' using errcode='23514';end if;
   visited:=array_append(visited,physical);
   needed_step_free:=coalesce((expected->>'requiresStepFree')::boolean,false) or coalesce((expected->>'accessibilityNeedsReview')::boolean,false);
   if needed_step_free and portal->>'accessibilityStatus'<>'step_free' then raise exception 'ACCESSIBILITY_UNSUITABLE' using errcode='23514';end if;
   select * into leg from jsonb_array_elements(_input->'legs') l where l->>'from'=node and l->>'to'=portal->>'nodeId';
   start_at:=(visit->>'startsAt')::timestamptz;seconds:=(visit->>'visitSeconds')::integer;buffer:=(visit->>'bufferSeconds')::integer;
   if not isfinite(start_at) or seconds not between 30 and 7200 or buffer not between 0 and 3600 or leg is null
    or start_at<cursor_at+make_interval(secs=>(leg->>'seconds')::integer)
    or (visit->>'walkSeconds')::integer is distinct from (leg->>'seconds')::integer
    or (visit->>'walkMeters')::integer is distinct from (leg->>'meters')::integer then raise exception 'ROUTE_TRAVEL_TIME_INVALID' using errcode='23514';end if;
   walking:=walking+(leg->>'seconds')::integer;
   if visit->>'kind'='ordinary' and (leg->>'seconds')::integer>(_input->>'maxLegWalkingSeconds')::integer then raise exception 'ORDINARY_LEG_WALKING_LIMIT' using errcode='23514';end if;
   if walking>(_input->>'maxTotalWalkingSeconds')::integer then raise exception 'ROUTE_TOTAL_WALKING_BUDGET' using errcode='23514';end if;
   finish_at:=start_at+make_interval(secs=>seconds);
   select * into win from jsonb_array_elements(portal->'windows') w where start_at>=(w->>'opensAt')::timestamptz
    and case when visit->>'kind'='finale' then start_at<=(w->>'arrivalClosesAt')::timestamptz else start_at<(w->>'arrivalClosesAt')::timestamptz end
    and finish_at+make_interval(secs=>buffer)<=(w->>'closesAt')::timestamptz
    and seconds=(w->>'visitSeconds')::integer and buffer=(w->>'bufferSeconds')::integer and children<=(w->>'maxChildren')::integer limit 1;
   if win is null then raise exception 'PORTAL_EFFECTIVE_WINDOW_CONFLICT' using errcode='23514';end if;
   select coalesce(jsonb_agg(jsonb_build_object('group_id',c->>'groupId','starts_at',c->>'startsAt',
    'ends_at',(c->>'startsAt')::timestamptz+make_interval(secs=>(c->>'visitSeconds')::integer+(c->>'bufferSeconds')::integer),'child_count',(c->>'children')::integer)),'[]') into occupied
   from jsonb_array_elements(calendar) c where c->>'kind'<>'start' and app_private.portal_physical_identity((c->>'portalId')::uuid)=physical;
   if not app_private.portal_interval_available_from_occupancy(pid,gid,start_at,finish_at+make_interval(secs=>buffer),children,occupied) then raise exception 'JOINT_ROUTE_ARRIVAL_OR_CAPACITY_CONFLICT' using errcode='23514',detail=jsonb_build_object('groupId',gid,'portalId',pid,'startsAt',start_at)::text;end if;
   if visit->>'kind'='ordinary' then
    ordinary:=ordinary+1;
    if coalesce((portal->>'finale')::boolean,false) or finish_at>(expected->>'ordinaryStopAt')::timestamptz then raise exception 'ORDINARY_STOP_LIMIT' using errcode='23514';end if;
   else
    finales:=finales+1;
    if exists(select 1 from jsonb_array_elements(_input->'portals') p where p->>'code'='P-38' and p->>'id'<>pid::text) then raise exception 'P38_ONLY_FINAL_PORTAL' using errcode='23514';end if;
    if not coalesce((portal->>'finale')::boolean,false) or pid is distinct from (expected#>>'{finale,portalId}')::uuid then raise exception 'FINAL_PORTAL_REQUIRED' using errcode='23514';end if;
    if start_at is distinct from (expected#>>'{finale,reservedAt}')::timestamptz then
     if jsonb_typeof(plan->'finaleChange') is distinct from 'object'
      or plan#>>'{finaleChange,portalId}' is distinct from expected#>>'{finale,portalId}'
      or (plan#>>'{finaleChange,previousReservedAt}')::timestamptz is distinct from (expected#>>'{finale,reservedAt}')::timestamptz
      or (plan#>>'{finaleChange,proposedReservedAt}')::timestamptz is distinct from start_at then
      raise exception 'FINALE_APPOINTMENT_REVIEW_REQUIRED' using errcode='23514';end if;
    elsif plan->'finaleChange' is not null and plan->'finaleChange'<>'null'::jsonb then
     raise exception 'FINALE_CHANGE_MISMATCH' using errcode='23514';
    end if;
    if start_at>(expected#>>'{finale,latestArrivalAt}')::timestamptz
     or finish_at>(expected->>'desiredEndAt')::timestamptz+make_interval(secs=>(_input->>'maxGroupOverrunSeconds')::integer) then raise exception 'GROUP_COMPLETION_LIMIT' using errcode='23514';end if;
    if (plan->>'finaleArrivalAt')::timestamptz is distinct from start_at or (plan->>'expectedCompletionAt')::timestamptz is distinct from finish_at then raise exception 'FINALE_TIMING_MISMATCH' using errcode='23514';end if;
   end if;
   cursor_at:=finish_at;node:=portal->>'nodeId';
  end loop;
  if finales<>1 then raise exception 'FINALE_REQUIRED' using errcode='23514';end if;
  if ordinary=0 and exists(select 1 from jsonb_array_elements(_input->'portals') p where not coalesce((p->>'finale')::boolean,false) and not(app_private.portal_physical_identity((p->>'id')::uuid)=any(visited))) then raise exception 'NO_FEASIBLE_ORDINARY_VISIT' using errcode='23514';end if;
 end loop;
end $$;

create or replace function api.admin_joint_route_plan_apply(_event_slug text,_proposal jsonb,_confirmed boolean,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e app_private.events; input jsonb; old app_private.command_receipts;hashed text;digest text;version app_private.joint_route_plan_versions;
 plan jsonb;visit jsonb;ctx jsonb;gid uuid;seq integer;version_id uuid:=gen_random_uuid();approved_source text;offset_seq integer;visit_count integer:=0;group_count integer:=0;result jsonb;
begin
 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if not coalesce(_confirmed,false) or char_length(trim(coalesce(_reason,''))) not between 10 and 500
  or coalesce(_idempotency_key,'')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  or jsonb_typeof(_proposal) is distinct from 'object' or octet_length(_proposal::text)>2000000 then raise exception 'JOINT_ROUTE_CONFIRMATION_REQUIRED' using errcode='22023';end if;
 hashed:=encode(extensions.digest(jsonb_build_array(e.id,_proposal,_confirmed,trim(_reason))::text,'sha256'),'hex');
 select * into old from app_private.command_receipts where actor_id=auth.uid() and command_type='joint_route.apply' and idempotency_key=_idempotency_key;
 if old.id is not null then if old.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return old.safe_result;end if;
 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
 input:=api.admin_joint_route_planning_input(_event_slug);
 if _proposal->>'sourceHash' is distinct from input->>'sourceHash' or _proposal->>'boardHash' is distinct from input->>'boardHash'
  or _proposal->>'policyVersion' is distinct from input->>'policyVersion' then raise exception 'JOINT_ROUTE_PROPOSAL_STALE' using errcode='40001';end if;
 perform 1 from app_private.walking_groups where event_id=e.id and id in(select(g->>'groupId')::uuid from jsonb_array_elements(_proposal->'groups') g) order by id for update;
 if exists(select 1 from jsonb_array_elements(_proposal->'groups') g where app_private.admin_registration_group_started((g->>'groupId')::uuid)) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514';end if;
 if exists(select 1 from app_private.live_route_visits v where v.group_id in(select(g->>'groupId')::uuid from jsonb_array_elements(_proposal->'groups') g) and v.run_stop_id is not null) then raise exception 'VISIT_PROTECTED' using errcode='23514';end if;
 perform app_private.validate_joint_route_proposal(input,_proposal->'groups');
 digest:=app_private.joint_route_proposal_hash(input->>'sourceHash',input->>'boardHash',_proposal->'groups');
 if digest is distinct from _proposal->>'proposalHash' then raise exception 'JOINT_ROUTE_HASH_MISMATCH' using errcode='23514';end if;
 -- Change only the reserved finale time after explicit review and independent
 -- validation. The FK is deferred until the immutable version is inserted below.
 for plan in select * from jsonb_array_elements(_proposal->'groups') order by value->>'groupId' loop
  if plan->'finaleChange' is not null and plan->'finaleChange'<>'null'::jsonb then
   gid:=(plan->>'groupId')::uuid;ctx:=app_private.route_group_start_context(gid);
   perform 1 from app_private.group_schedule_revisions where id=(ctx->>'scheduleId')::uuid for update;
   insert into app_private.joint_route_finale_approvals(accepted_version_id,schedule_id,group_id,portal_id,previous_reserved_at,proposed_reserved_at,composition_hash,approved_by)
   values(version_id,(ctx->>'scheduleId')::uuid,gid,(plan#>>'{finaleChange,portalId}')::uuid,
    (plan#>>'{finaleChange,previousReservedAt}')::timestamptz,(plan#>>'{finaleChange,proposedReservedAt}')::timestamptz,app_private.start_group_composition_hash(gid),auth.uid());
   update app_private.group_schedule_revisions set expected_finale_arrival_at=(plan->>'finaleArrivalAt')::timestamptz where id=(ctx->>'scheduleId')::uuid;
   update app_private.portal_reservations reservation set reserved_from=(plan->>'finaleArrivalAt')::timestamptz,
    reserved_until=(plan->>'finaleArrivalAt')::timestamptz+make_interval(secs=>(v->>'visitSeconds')::integer+(v->>'bufferSeconds')::integer),version=reservation.version+1
   from jsonb_array_elements(plan->'visits') v where reservation.group_id=gid and reservation.kind='finale' and reservation.status='held' and v->>'kind'='finale';
  end if;
 end loop;
 approved_source:=app_private.joint_route_source_hash(e.id);
 insert into app_private.joint_route_plan_versions(id,event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,metrics,reason)
 select version_id,e.id,coalesce(max(revision),0)+1,approved_source,digest,input->>'boardHash',input->>'policyVersion',auth.uid(),_proposal->'groups',coalesce(_proposal->'metrics','{}'),trim(_reason)
 from app_private.joint_route_plan_versions where event_id=e.id returning * into version;
 for plan in select * from jsonb_array_elements(_proposal->'groups') order by value->>'groupId' loop
  gid:=(plan->>'groupId')::uuid;ctx:=app_private.route_group_start_context(gid);offset_seq:=0;group_count:=group_count+1;
  -- A newly accepted calendar must be the route that run_start/worker dispatch
  -- actually use. Historical modes never select a different legacy route.
  update app_private.walking_groups set route_mode='dynamic',version=walking_groups.version+1 where id=gid and route_mode<>'dynamic';
  insert into app_private.live_route_plans(group_id,event_id,schedule_id,accepted_version_id,source_hash,plan_hash)
   values(gid,e.id,(ctx->>'scheduleId')::uuid,version.id,version.source_hash,version.plan_hash)
  on conflict(group_id) do update set schedule_id=excluded.schedule_id,accepted_version_id=excluded.accepted_version_id,source_hash=excluded.source_hash,plan_hash=excluded.plan_hash,version=live_route_plans.version+1;
  if ctx#>>'{pointSnapshot,linked_portal_id}' is not null and not coalesce((ctx#>>'{pointSnapshot,counts_as_first_portal_visit}')::boolean,false) then
   offset_seq:=1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
   values(e.id,gid,1,(ctx#>>'{pointSnapshot,linked_portal_id}')::uuid,(plan->>'startsAt')::timestamptz,30,0,'start','manual')
   on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=30,buffer_seconds=0,kind='start',source='manual',retired_at=null,version=live_route_visits.version+1,updated_at=clock_timestamp();
  end if;
  for visit in select * from jsonb_array_elements(plan->'visits') order by(value->>'sequence')::integer loop
   seq:=(visit->>'sequence')::integer+offset_seq;visit_count:=visit_count+1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
   values(e.id,gid,seq,(visit->>'portalId')::uuid,(visit->>'startsAt')::timestamptz,(visit->>'visitSeconds')::integer,(visit->>'bufferSeconds')::integer,visit->>'kind','manual')
   on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,kind=excluded.kind,source='manual',retired_at=null,version=live_route_visits.version+1,updated_at=clock_timestamp();
  end loop;
  update app_private.live_route_visits set retired_at=clock_timestamp(),version=live_route_visits.version+1 where group_id=gid and retired_at is null and sequence>jsonb_array_length(plan->'visits')+offset_seq;
 end loop;
 result:=jsonb_build_object('acceptedVersionId',version.id,'revision',version.revision,'sourceHash',version.source_hash,'proposalHash',version.plan_hash,
  'boardHash',app_private.live_planboard_hash(e.id),'groupCount',group_count,'visitCount',visit_count,'changed',true);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(e.id,auth.uid(),'route.joint_proposal.accepted','event',e.id,jsonb_build_object('acceptedVersionId',version.id,'proposalHash',digest,'groups',group_count,'visits',visit_count,'reason',trim(_reason)));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'joint_route.apply',_idempotency_key,hashed,result,now()+interval '30 days');
 perform realtime.send(jsonb_build_object('resource','route_intent'),'snapshot_changed','admin-event:'||e.id,true);
 return result;
end $$;

do $migration$
declare definition text;old_fragment text;
begin
 definition:=pg_get_functiondef('app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid)'::regprocedure);
 old_fragment:=$old$requested:=g.desired_ordinary_visits;if requested is not null and visited>=requested then force_finale:=true;end if;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'CANONICAL_DISPATCH_CAP_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,old_fragment,$new$requested:=g.desired_ordinary_visits;
 if requested is not null and visited>=requested and exists(select 1 from app_private.joint_route_plan_versions accepted where accepted.id=r.accepted_route_version_id and accepted.policy_version<>'joint-reception-v2') then force_finale:=true;end if;$new$);
 old_fragment:=$old$ if _preferred_portal_id is not null and _preferred_portal_id<>intent.portal_id then raise exception 'CANONICAL_ROUTE_INTENT_CONFLICT'using errcode='23514';end if;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'CANONICAL_DISPATCH_HISTORY_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,old_fragment,old_fragment||$new$
 if intent.kind='ordinary' and app_private.group_has_visited_portal(g.event_id,g.id,intent.portal_id) then
  insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
   select g.event_id,g.id,r.id,intent.portal_id,'warning','PHYSICAL_VISIT_ALREADY_RECORDED','Dit fysieke huis is al bezocht door deze groep of een huidig kind. Beoordeel een expliciete herplanning.'
   where not exists(select 1 from app_private.route_alerts where run_id=r.id and portal_id=intent.portal_id and code='PHYSICAL_VISIT_ALREADY_RECORDED' and status='open');
  return jsonb_build_object('decision','wait','retryAfterSeconds',120,'requiresReplanning',true,'reason','PHYSICAL_VISIT_ALREADY_RECORDED','portalId',intent.portal_id,'acceptedVersionId',r.accepted_route_version_id);
 end if;$new$);
 execute definition;
end $migration$;

-- Remove theme scoring from the compatibility fallback. Reception, history,
-- real travel, end preferences and capacity checks remain authoritative.
do $migration$
declare definition text;old_fragment text;
begin
 definition:=pg_get_functiondef('app_private.dispatch_next_stop_before_visit_preference(uuid,timestamptz,boolean,uuid)'::regprocedure);
 old_fragment:=$old$          + case when portal.world_id = (
              select previous_portal.world_id from app_private.run_stops previous_stop
              join app_private.portals previous_portal on previous_portal.id = previous_stop.portal_id
              where previous_stop.run_id = _run_id and previous_stop.state = 'completed'
              order by previous_stop.sequence desc limit 1
            ) then 120 else 0 end$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'FALLBACK_WORLD_SCORE_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,old_fragment,'');
 definition:=replace(definition,$old$and nullif(trim(child.accessibility_note), '') is not null$old$,$new$and app_private.child_step_free_requirement(child.id) is distinct from false$new$);
 definition:=replace(definition,$old$participant.attendance = 'present'$old$,$new$participant.attendance = 'present' and participant.departed_at is null$new$);
 definition:=replace(definition,$old$(not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')$old$,$new$(not needs_step_free or app_private.portal_accessibility_status(portal.id)='step_free')$new$);
 definition:=replace(definition,$old$and portal.approval_status='approved' and portal.lifecycle_status='active'$old$,$new$and portal.approval_status='approved' and portal.lifecycle_status='active'
      and (not needs_step_free or app_private.portal_accessibility_status(portal.id)='step_free')$new$);
 definition:=replace(definition,$old$and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)$old$,$new$and (not needs_step_free or app_private.portal_accessibility_status(portal.id)='step_free')
      and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)$new$);
 execute definition;

 definition:=pg_get_functiondef('app_private.start_ops_route_preview_before_joint_routes(uuid)'::regprocedure);
 old_fragment:=$old$    order by case when needs_anders and not exists(select 1 from unnest(chosen) c(id)
      join app_private.portals cp on cp.id=c.id join app_private.worlds cw on cw.id=cp.world_id where cw.slug='anders')
      then case when q.world_slug='anders' then 0 else 1 end else 0 end,q.walk_s,q.walk_m,q.id limit 1;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'FALLBACK_ANDERS_SCORE_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,old_fragment,$new$    order by q.walk_s,q.walk_m,q.id limit 1;$new$);
 old_fragment:=$old$  if needs_anders and not exists(select 1 from jsonb_array_elements(stops) stop
    join app_private.portals p on p.id=(stop->>'portalId')::uuid join app_private.worlds w on w.id=p.world_id
    where stop->>'kind'='ordinary' and w.slug='anders') then
    warnings:=warnings||jsonb_build_array('Geen haalbare gewone Anders-poort in deze route. Plan waar mogelijk een passend bezoek voor de ontbrekende wereldzegels; dit blokkeert startafspraken niet.');
  end if;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'FALLBACK_ANDERS_ADVICE_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,old_fragment,'');
 definition:=replace(definition,$old$and not(p.id=any(chosen))$old$,$new$and not exists(select 1 from unnest(chosen) earlier(id) where app_private.portal_physical_identity(earlier.id)=app_private.portal_physical_identity(p.id))
        and (p.id=preserved_portal or not app_private.group_has_visited_portal(g.event_id,g.id,p.id))$new$);
 definition:=replace(definition,'  needs_anders:=cardinality(app_private.world_coverage_missing(g.event_id))>0;','');
 definition:=replace(definition,'  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;',
  '  remaining:=case when r.id is not null and g.desired_ordinary_visits is not null then greatest(0,g.desired_ordinary_visits-visited) else 10000 end;');
 -- Explicit declarations also protect manual portals that have no application.
 definition:=replace(definition,$old$and nullif(trim(c.accessibility_note),'') is not null$old$,$new$and app_private.child_step_free_requirement(c.id) is distinct from false$new$);
 definition:=replace(definition,$old$exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free')$old$,$new$app_private.portal_accessibility_status(p.id)='step_free'$new$);
 definition:=replace(definition,'De gekoppelde eerste poort past niet veilig in dit tijdvenster. Controleer de afspraak.',
  'De gekoppelde eerste poort is niet haalbaar binnen de gecontroleerde opening, bezoekduur, groepsgrens en werkelijke wandeling naar P-38. Controleer de afzonderlijke ontvangstgegevens.');
 execute definition;
end $migration$;

-- World coverage remains a profile/passport concern; it cannot instruct the
-- organizer to insert or prioritize a physical Anders visit.
do $migration$
declare definition text;
begin
 definition:=pg_get_functiondef('api.admin_live_planboard_snapshot(text)'::regprocedure);
 definition:=replace(definition,' return result||jsonb_build_object(''routeSourceHash'',source,',
  ' result:=jsonb_set(result,''{warnings}'',coalesce((select jsonb_agg(w) from jsonb_array_elements(result->''warnings'') w where w->>''code''<>''MISSING_WORLD_CANDY_ROUTE''),''[]''::jsonb)); return result||jsonb_build_object(''routeSourceHash'',source,');
 execute definition;
 definition:=pg_get_functiondef('app_private.accept_manual_route_intention(uuid,uuid,text)'::regprocedure);
 execute replace(definition,'''joint-reception-v1''','''joint-reception-v2''');
end $migration$;
insert into app_private.joint_route_policy_releases(policy_version) values('joint-reception-v2');
revoke all on function app_private.assert_group_schedule_timing(uuid,uuid,timestamptz,timestamptz),app_private.joint_route_source_hash(uuid),app_private.validate_joint_route_proposal(jsonb,jsonb) from public,anon,authenticated;
revoke all on function api.admin_joint_route_planning_input(text),api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text) from public,anon;
grant execute on function api.admin_joint_route_planning_input(text),api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text) to authenticated;
