-- Bound Startregie reads without weakening authorization, source freshness,
-- publication preconditions or physical-capacity assertions.
--
-- Per-request context is passed explicitly. Nothing is cached across requests
-- or within a transaction after writes. Existing read/write entry points retain
-- their original authorization and ACLs.

create or replace function app_private.assert_group_schedule_timing_with_source(
  _group uuid,_slot uuid,_stop timestamptz,_arrival timestamptz,_current_source_hash text
) returns void language plpgsql stable security definer set search_path='' as $$
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
        or (app_private.canonical_route_group_current(_group,_current_source_hash) and exists(
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


create or replace function app_private.start_ops_route_preview_with_context(_group_id uuid,_current_source_hash text,_route_revision integer,_publication_readiness jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g app_private.walking_groups;ctx jsonb;point jsonb;origin jsonb;stops jsonb;warnings jsonb:='[]'::jsonb;accepted jsonb;version_id uuid;source_hash text;stale boolean;
begin
 select * into g from app_private.walking_groups where id=_group_id;
 if g.id is null then return null;end if;
 -- Preserve the existing journey's destination and history projection.
 if app_private.admin_registration_group_started(g.id) and not exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.accepted_route_version_id is not null) then
  return app_private.start_ops_route_preview_before_joint_routes(g.id);end if;
 ctx:=app_private.route_group_start_context(g.id);point:=ctx->'pointSnapshot';
 origin:=app_private.routing_position((point->>'marker_latitude')::numeric,(point->>'marker_longitude')::numeric,(point->>'geocoded_latitude')::numeric,(point->>'geocoded_longitude')::numeric,(point->>'latitude')::numeric,(point->>'longitude')::numeric);
 select p.accepted_version_id,p.source_hash into version_id,source_hash from app_private.live_route_plans p where p.group_id=g.id;
 accepted:=app_private.canonical_route_group_plan(g.id);
 stale:=version_id is not null and not app_private.canonical_route_group_current(g.id,_current_source_hash);
 select coalesce(jsonb_agg(reason->>'message'),'[]'::jsonb) into warnings
 from jsonb_array_elements(_publication_readiness->'reasons') reason;
 if version_id is null then warnings:=warnings||jsonb_build_array('Bereken, beoordeel en sla eerst een gezamenlijk routevoorstel op. Deze opgeslagen intentie is niet opnieuw berekend.');
 elsif stale then warnings:=warnings||jsonb_build_array('De route-invoer of opgeslagen intentie is gewijzigd. Bereken en beoordeel een nieuw gezamenlijk voorstel; de bestaande tijden zijn behouden.');end if;
 with stored as(
  select v.portal_id,row_number()over(order by v.sequence)::integer sequence,v.starts_at,v.duration_seconds,v.buffer_seconds,v.kind,v.run_stop_id,
   (select (x->>'walkMeters')::integer from jsonb_array_elements(coalesce(accepted->'visits','[]')) x where x->>'portalId'=v.portal_id::text) walk_meters,
   (select (x->>'walkSeconds')::integer from jsonb_array_elements(coalesce(accepted->'visits','[]')) x where x->>'portalId'=v.portal_id::text) walk_seconds
  from app_private.live_route_visits v where v.group_id=g.id and v.retired_at is null and v.kind<>'start'
 ),fallback as(
  select ps.portal_id,ps.position,ps.planned_arrival_at,extract(epoch from ps.planned_departure_at-ps.planned_arrival_at)::integer,0,
   case when ps.position=(select max(position)from app_private.route_plan_stops where plan_version_id=g.current_plan_version_id)then 'finale' else 'ordinary'end,null::uuid,null::integer,null::integer
  from app_private.route_plan_stops ps where ps.plan_version_id=g.current_plan_version_id and g.route_mode='legacy' and not exists(select 1 from stored)
 ),actual as(select * from stored union all select * from fallback),positioned as(
  select a.*,lag(a.portal_id)over(order by a.sequence) previous_portal from actual a
 )
 select coalesce(jsonb_agg(jsonb_build_object('portalId',p.id,'code',p.system_code,'name',p.name,'address',concat_ws(' ',l.street,l.house_number,l.addition),
  'coordinate',app_private.routing_coordinate(app_private.portal_location(p.id)),'publicEntranceInstructions',app_private.portal_public_entrance(p.id),
  'world',case when a.kind='finale' then 'Finale' else world.name end,'kind',a.kind,'sequence',a.sequence,'walkMeters',coalesce(a.walk_meters,travel.distance_m),'walkMinutes',ceil(coalesce(a.walk_seconds,travel.duration_seconds)/60.0),
  'plannedArrivalAt',a.starts_at,'visitSeconds',a.duration_seconds,'bufferSeconds',a.buffer_seconds,
  'expectedCompletionAt',case when a.kind='finale'then a.starts_at+make_interval(secs=>a.duration_seconds)end,
  'physicalEndsAt',a.starts_at+make_interval(secs=>a.duration_seconds+a.buffer_seconds),
  'status',case when a.run_stop_id is not null then 'current' else 'expected'end)order by a.sequence),'[]')into stops
 from positioned a join app_private.portals p on p.id=a.portal_id join app_private.worlds world on world.id=p.world_id left join app_private.portal_private_locations l on l.portal_id=p.id
 left join lateral(select case when a.previous_portal is null then origin else app_private.portal_location(a.previous_portal)end value) previous on true
 left join lateral app_private.destination_estimate((previous.value->>'latitude')::numeric,(previous.value->>'longitude')::numeric,
  (app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric) travel on a.walk_seconds is null;
 return jsonb_build_object('groupId',g.id,'revision',_route_revision,'generatedAt',statement_timestamp(),
  'acceptedVersionId',version_id,'sourceHash',source_hash,'sourceChanged',stale,'requiresJointReview',version_id is null or stale,
  'start',jsonb_build_object('pointId',point->'id','name',point->>'name','address',point->>'private_address','coordinate',app_private.routing_coordinate(origin),'arrivalInstructions',point->>'public_arrival_instructions','startsAt',ctx->'startsAt'),
  'stops',stops,'totalMeters',coalesce((select sum((x->>'walkMeters')::integer)from jsonb_array_elements(stops)x),0),
  'totalMinutes',coalesce((select ceil(sum((x->>'visitSeconds')::integer+coalesce((x->>'walkMinutes')::integer,0)*60)/60.0)from jsonb_array_elements(stops)x),0),
  'eligiblePortalCount',(select count(distinct app_private.portal_physical_identity(p.id))from app_private.portals p where p.event_id=g.event_id and p.approval_status='approved'and p.lifecycle_status='active'),
  'warnings',warnings,'provisional',true,'distanceMethod','straight_line','travelTimeEstimated',true,
  'hasConfirmedStart',coalesce((ctx->>'hasPublishedStart')::boolean,false)or app_private.is_start_confirmation_current((ctx->>'scheduleId')::uuid));
end $$;



revoke all on function app_private.start_ops_route_preview_with_context(uuid,text,integer,jsonb),
 app_private.assert_group_schedule_timing_with_source(uuid,uuid,timestamptz,timestamptz,text)
 from public,anon,authenticated;

-- Keep the current snapshot implementation and every accumulated projection.
-- Guard each source shape so a different upstream implementation fails safely.
do $patch_snapshot$
declare definition text; previous text; anchor text;
begin
 definition:=pg_get_functiondef('app_private.admin_startregie_snapshot_before_publication_readiness(text)'::regprocedure);
 if position('hotfix_shared_source_hash' in definition)>0 then return; end if;
 anchor:=E'\nbegin\n';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_SNAPSHOT_BODY_CHANGED';end if;
 definition:=replace(definition,anchor,E'\n  hotfix_shared_source_hash text; hotfix_shared_route_revision integer; hotfix_shared_readiness jsonb;\nbegin\n');
 anchor:='select * into e from app_private.events where slug=_event_slug;';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_SNAPSHOT_EVENT_LOOKUP_CHANGED';end if;
 definition:=replace(definition,anchor,anchor||E'\n  hotfix_shared_source_hash:=app_private.joint_route_source_hash(e.id);\n  hotfix_shared_route_revision:=(\'x\'||substr(hotfix_shared_source_hash,1,7))::bit(28)::integer;\n  hotfix_shared_readiness:=app_private.start_publication_readiness(e.id);');
 anchor:='app_private.start_ops_route_revision(e.id)';
 if cardinality(string_to_array(definition,anchor))<>3 then raise exception 'STARTREGIE_SNAPSHOT_REVISION_CALLS_CHANGED';end if;
 definition:=replace(definition,anchor,'hotfix_shared_route_revision');
 anchor:='app_private.start_ops_route_preview(g.id)';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_SNAPSHOT_PREVIEW_CALL_CHANGED';end if;
 definition:=replace(definition,anchor,'app_private.start_ops_route_preview_with_context(g.id,hotfix_shared_source_hash,hotfix_shared_route_revision,hotfix_shared_readiness)');
 execute definition;
end $patch_snapshot$;

-- The publication preflight and locked publication command use the SAME
-- physical/timing assertions. Reuse this statement's reservations and current
-- source hash instead of recalculating the complete event per selected group.
do $patch_readiness$
declare definition text;anchor text;replacement text;
begin
 definition:=pg_get_functiondef('app_private.assert_start_schedule_capacity_readonly(uuid,uuid[])'::regprocedure);
 if position('hotfix_shared_source_hash' in definition)>0 then return;end if;
 anchor:='declare candidate record;';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_CAPACITY_DECLARATION_CHANGED';end if;
 definition:=replace(definition,anchor,'declare hotfix_shared_source_hash text; hotfix_start_reservations jsonb; candidate record;');
 anchor:='select * into settings from app_private.event_route_settings where event_id=_event_id;';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_CAPACITY_SETTINGS_LOOKUP_CHANGED';end if;
 definition:=replace(definition,anchor,anchor||E'\n  hotfix_shared_source_hash:=app_private.joint_route_source_hash(_event_id);\n  select coalesce(jsonb_agg(to_jsonb(reservation)),\'[]\'::jsonb) into hotfix_start_reservations from app_private.start_schedule_reservations(_event_id) reservation;');
 anchor:='app_private.assert_group_schedule_timing(candidate.group_id,candidate.start_slot_id,candidate.effective_ordinary_stop_at,candidate.expected_finale_arrival_at)';
 if cardinality(string_to_array(definition,anchor))<>2 then raise exception 'STARTREGIE_CAPACITY_TIMING_CALL_CHANGED';end if;
 definition:=replace(definition,anchor,'app_private.assert_group_schedule_timing_with_source(candidate.group_id,candidate.start_slot_id,candidate.effective_ordinary_stop_at,candidate.expected_finale_arrival_at,hotfix_shared_source_hash)');
 anchor:='app_private.start_schedule_reservations(_event_id) r';
 if cardinality(string_to_array(definition,anchor))<>4 then raise exception 'STARTREGIE_CAPACITY_RESERVATION_CALLS_CHANGED';end if;
 replacement:='jsonb_to_recordset(hotfix_start_reservations) as r(group_id uuid,schedule_id uuid,start_slot_id uuid,start_point_id uuid,starts_at timestamptz,child_count integer,finale_at timestamptz)';
 definition:=replace(definition,anchor,replacement);
 execute definition;
end $patch_readiness$;
