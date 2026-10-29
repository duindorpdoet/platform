-- Pure input/proposal support only: no route, publication, invitation or live row
-- is recalculated by applying this migration. Reception columns exist in 170035.
set lock_timeout='5s';

-- Extend the new organizer commands after the structured column exists. Assert
-- the exact old fragments so a future override cannot be changed accidentally.
do $migration$
declare definition text; old_fragment text;
begin
 definition:=pg_get_functiondef('api.admin_registration_create(text,jsonb,integer,uuid,text)'::regprocedure);
 old_fragment:=$old$or length(coalesce(child->>'accessibilityNote',''))>500 then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'ADMIN_CREATE_ACCESSIBILITY_VALIDATION_CHANGED';end if;
 definition:=replace(definition,old_fragment,$new$or length(coalesce(child->>'accessibilityNote',''))>500
   or (child?'stepFreeRequired' and child->'stepFreeRequired'<>'null'::jsonb and jsonb_typeof(child->'stepFreeRequired')<>'boolean') then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;$new$);
 old_fragment:=$old$insert into app_private.children(household_id,first_name,age_at_event,accessibility_note) values(h,trim(child->>'name'),(child->>'age')::smallint,nullif(trim(child->>'accessibilityNote'),'')) returning id into cid;$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'ADMIN_CREATE_ACCESSIBILITY_INSERT_CHANGED';end if;
 definition:=replace(definition,old_fragment,$new$insert into app_private.children(household_id,first_name,age_at_event,accessibility_note,step_free_required) values(h,trim(child->>'name'),(child->>'age')::smallint,nullif(trim(child->>'accessibilityNote'),''),(child->>'stepFreeRequired')::boolean) returning id into cid;$new$);
 execute definition;
 definition:=pg_get_functiondef('api.admin_registrations_snapshot(text)'::regprocedure);
 old_fragment:=$old$'accessibilityNote', child.accessibility_note,$old$;
 if strpos(definition,old_fragment)=0 then raise exception 'ADMIN_ROSTER_ACCESSIBILITY_PROJECTION_CHANGED';end if;
 execute replace(definition,old_fragment,$new$'accessibilityNote', child.accessibility_note,
            'stepFreeRequired',child.step_free_required,
            'requiresAccessibilityReview',child.step_free_required is null and nullif(trim(child.accessibility_note),'') is not null,$new$);
end $migration$;

-- One stable statement snapshot supplies all groups, physical windows, stored
-- entrance-pin travel estimates and existing occupancy. No per-group greedy
-- preview or seeding function is called by this read-only endpoint.
create function api.admin_joint_route_planning_input(_event_slug text) returns jsonb
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
  'ordinaryStopAt',app_private.group_ordinary_deadline(g.id),'desiredEndAt',g.desired_end,'maxOrdinaryVisits',g.desired_ordinary_visits,
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

 return jsonb_build_object('eventId',e.id,'sourceHash',app_private.joint_route_source_hash(e.id),'boardHash',app_private.live_planboard_hash(e.id),
  'policyVersion','joint-reception-v1','maxGroupOverrunSeconds',app_private.group_end_overrun_seconds(),
  'maxLegWalkingSeconds',900,'maxTotalWalkingSeconds',3600,'needsAnders',cardinality(app_private.world_coverage_missing(e.id))>0,
  'groups',coalesce((select jsonb_agg(item-array['_latitude','_longitude','_pointId','_pointActive','_pointAccessible','_availableFrom','_availableUntil','_maxGatheringGroups','_maxGatheringChildren','_slotMaxChildren'] order by item->>'id') from jsonb_array_elements(groups_json) item),'[]'),
  'portals',coalesce((select jsonb_agg(item-'_latitude'-'_longitude' order by item->>'id') from jsonb_array_elements(portals_json) item),'[]'),
  'legs',legs_json,'fixedVisits',fixed_json,'before',before_json,'diagnostics',diagnostics);
end $$;
revoke all on function api.admin_joint_route_planning_input(text) from public,anon;
grant execute on function api.admin_joint_route_planning_input(text) to authenticated;
