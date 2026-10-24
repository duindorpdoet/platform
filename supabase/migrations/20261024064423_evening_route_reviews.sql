-- Private evidence is additive. Existing plans, credentials and arrivals remain intact.
create table app_private.evening_route_calculations (
 id uuid primary key default extensions.gen_random_uuid(),
 event_id uuid not null references app_private.events(id),
 group_id uuid not null references app_private.walking_groups(id),
 input_hash text not null check(input_hash ~ '^[0-9a-f]{64}$'),
 fingerprint text not null check(fingerprint ~ '^[0-9a-f]{64}$'),
 input_snapshot jsonb not null,result_snapshot jsonb not null,canonical_result jsonb not null,
 calculated_at timestamptz not null default clock_timestamp(),
 unique(group_id,fingerprint)
);
create index evening_route_calculations_event on app_private.evening_route_calculations(event_id);
create index evening_route_calculations_input on app_private.evening_route_calculations(group_id,input_hash,calculated_at desc);
alter table app_private.evening_route_calculations enable row level security;
revoke all on app_private.evening_route_calculations from public,anon,authenticated;
create table app_private.evening_route_reviews (
 id uuid primary key default extensions.gen_random_uuid(),
 event_id uuid not null references app_private.events(id),group_id uuid not null references app_private.walking_groups(id),
 calculation_id uuid not null references app_private.evening_route_calculations(id),
 fingerprint text not null,route_revision integer not null,actor_id uuid not null,actor_label text not null,
 reviewed_at timestamptz not null default clock_timestamp(),unique(calculation_id,actor_id)
);
create index evening_route_reviews_event on app_private.evening_route_reviews(event_id);
create index evening_route_reviews_group on app_private.evening_route_reviews(group_id,reviewed_at desc);
alter table app_private.evening_route_reviews enable row level security;
revoke all on app_private.evening_route_reviews from public,anon,authenticated;
create or replace function app_private.reject_evening_route_evidence_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_relid='app_private.evening_route_calculations'::regclass and tg_op='DELETE' and not exists(select 1 from app_private.evening_route_reviews r where r.calculation_id=old.id) then return old;end if;
 raise exception 'ROUTE_EVIDENCE_IMMUTABLE' using errcode='55000';end $$;
create trigger immutable_evening_route_calculation before update or delete on app_private.evening_route_calculations for each row execute function app_private.reject_evening_route_evidence_change();
create trigger immutable_evening_route_review before update or delete on app_private.evening_route_reviews for each row execute function app_private.reject_evening_route_evidence_change();
revoke all on function app_private.reject_evening_route_evidence_change() from public,anon,authenticated;

-- Explicit route inputs, with no generated-at or audit update timestamps.
-- An active evening uses thirty-second clock buckets; the result retains its
-- exact real calculation instant. Preparation without live occupancy is stable.
create or replace function app_private.evening_route_input(_group_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $function$
declare context jsonb:=app_private.evening_route_context(_group_id); eventid uuid:=(context->>'eventId')::uuid; decision_at timestamptz:=(context->>'serverNowAt')::timestamptz;
 result jsonb;
begin
 if eventid is null then return null;end if;
 select jsonb_build_object('contract','evening-route-v1','group',jsonb_build_object('id',g.id,'ordinaryLimit',g.desired_ordinary_visits),
  'startPolicy',jsonb_build_array(context->'gatheringPortalId',context->'startCountsAsVisit'),'origin',context->'start','positionNode',context->'sourceNodeId','remainingNode',context->'remainingSourceNodeId','mode',context->'mode',
  'clockBucket',case when context->>'mode'='live' or exists(select 1 from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid and r.status in ('live','paused')) then floor(extract(epoch from decision_at)/30) end,
  'confirmed',context->'hasConfirmedStart','children',context->'childCount','stepFree',context->'requiresStepFree','terminal',coalesce((context->>'terminal')::boolean,false),
  'schedule',jsonb_build_object('revision',s.revision,'slot',s.start_slot_id,'cutoff',context->'ordinaryStopAt','finale',context->'finalePortalId','finaleAt',context->'finaleArrivalAt',
   'serviceUntil',coalesce((context->>'finaleServiceUntil')::timestamptz,(context->>'finaleArrivalAt')::timestamptz+make_interval(secs=>cfg.finale_show_seconds)),
   'occupiedUntil',coalesce((context->>'finaleOccupiedUntil')::timestamptz,(context->>'finaleArrivalAt')::timestamptz+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds)),
   'grace',context->'finaleGraceSeconds','waiting',coalesce(context->>'safeWaitingInstruction',
    case when nullif(trim(cfg.finale_waiting_area),'') is not null or nullif(trim(cfg.finale_safe_approach),'') is not null then concat_ws(' ',case when nullif(trim(cfg.finale_waiting_area),'') is not null then 'Wacht samen op de afgesproken plek: '||trim(cfg.finale_waiting_area)||'.' end,case when nullif(trim(cfg.finale_safe_approach),'') is not null then 'Volg deze afgesproken aanloop: '||trim(cfg.finale_safe_approach)||'.' end) else 'Blijf bij jullie groep en vraag de organisatie waar jullie veilig kunnen wachten.' end)),
  'settings',to_jsonb(cfg)-array['event_id','updated_at','updated_by','version'],
  'roster',coalesce((select jsonb_agg(jsonb_build_array(a.id,rc.id,rc.participation_status,ch.accessibility_note) order by a.id,rc.id)
   from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id join app_private.children ch on ch.id=rc.child_id where a.group_id=g.id and a.superseded_at is null),'[]'),
  'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'world',p.world_id,'approval',p.approval_status,'lifecycle',p.lifecycle_status,'operation',p.operation_status,
    'address',jsonb_build_array(l.street,l.house_number,l.addition),'coordinate',jsonb_build_array(coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)),
    'verified',l.verified_at is not null,'practical',info.information,'legacyAccessibility',a.private_draft_data->>'accessibility') order by p.id)
    from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id left join app_private.portal_visit_information info on info.portal_id=p.id left join app_private.portal_applications a on a.id=p.application_id where p.event_id=eventid),'[]'),
  'windows',coalesce((select jsonb_agg(to_jsonb(w)-array['created_at','updated_at'] order by w.id) from app_private.portal_windows w join app_private.portals p on p.id=w.portal_id where p.event_id=eventid),'[]'),
  'nodes',coalesce((select jsonb_agg(jsonb_build_array(n.id,n.portal_id,n.coordinate::text,n.verified_at is not null) order by n.id) from app_private.walking_nodes n where n.event_id=eventid),'[]'),
  'edges',coalesce((select jsonb_agg(jsonb_build_array(edge.id,edge.from_node_id,edge.to_node_id,edge.distance_m,edge.duration_seconds,edge.wheelchair_accessible,edge.geometry_geojson,edge.approved_at is not null,edge.closed_at is not null) order by edge.id) from app_private.walking_edges edge where edge.event_id=eventid),'[]'),
  'bookings',coalesce((select jsonb_agg(jsonb_build_array(b.group_id,b.portal_id,b.kind,b.status,b.reserved_from,b.service_until,b.reserved_until,b.child_count,b.expires_at,b.expires_at is null or b.expires_at>decision_at,b.reserved_until>decision_at) order by b.id)
    from app_private.portal_reservations b where b.event_id=eventid and b.group_id<>g.id and b.status in ('held','active')),'[]'),
  'runs',coalesce((select jsonb_agg(jsonb_build_array(r.id,r.group_id,r.status,r.current_stop_id,r.finale_only,r.version) order by r.id) from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'presence',coalesce((select jsonb_agg(jsonb_build_array(rp.id,rp.run_id,rp.attendance,rp.departed_at) order by rp.id) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'stops',coalesce((select jsonb_agg(jsonb_build_array(rs.id,rs.run_id,coalesce(rs.portal_id,ps.portal_id),rs.state,rs.stop_kind,rs.outcome,rs.sequence,rs.opened_at,rs.completed_at) order by rs.id) from app_private.run_stops rs join app_private.group_runs r on r.id=rs.run_id join app_private.walking_groups wg on wg.id=r.group_id left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where wg.event_id=eventid),'[]'),
  'scans',coalesce((select jsonb_agg(jsonb_build_array(scan.run_stop_id,scan.scanned_at) order by scan.id) from app_private.scan_evidence scan join app_private.run_stops scan_stop on scan_stop.id=scan.run_stop_id join app_private.group_runs r on r.id=scan_stop.run_id join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'historyArrivals',coalesce((select jsonb_agg(jsonb_build_array(a.run_stop_id,a.child_id,a.arrived_at,a.arrived) order by a.run_stop_id,a.child_id) from app_private.run_stop_arrivals a where a.event_id=eventid),'[]'),
  'legacyPlans',coalesce((select jsonb_agg(jsonb_build_array(p.group_id,p.id,p.state,rs.id,rs.portal_id,rs.planned_arrival_at,rs.planned_departure_at,rs.planned_departure_at>decision_at) order by p.id,rs.id) from app_private.route_plan_versions p join app_private.walking_groups wg on wg.id=p.group_id join app_private.route_plan_stops rs on rs.plan_version_id=p.id where wg.event_id=eventid and p.group_id<>g.id and p.state in ('valid','published')),'[]'))
 into result from app_private.walking_groups g left join app_private.group_schedule_revisions s on s.id=(context->>'scheduleId')::uuid left join app_private.event_route_settings cfg on cfg.event_id=g.event_id where g.id=_group_id;
 return result;
end;
$function$;

create or replace function app_private.evening_route_result_signature(_route jsonb,_input jsonb) returns jsonb
language sql immutable security definer set search_path='' as $function$
 select jsonb_build_object('mode',_route->'mode','start',_route->'start','feasible',_route->'feasible','blockers',_route->'blockers',
  'history',_route->'history','meters',_route->'totalMeters','minutes',_route->'totalMinutes',
  'stops',coalesce((select jsonb_agg((s-array['id','reservationId','reservedArrivalAt'])||case when s->>'kind'='finale' then jsonb_build_object('reservedArrivalAt',_input#>'{schedule,finaleAt}') else '{}'::jsonb end order by ordinal)
   from jsonb_array_elements(_route->'stops') with ordinality item(s,ordinal)),'[]'),
  'checklist',coalesce((select jsonb_agg(jsonb_build_object('code',c->'code','status',c->'status') order by c->>'code') from jsonb_array_elements(_route->'checklist') c),'[]'))
$function$;

create or replace function app_private.evening_route_with_review(_group_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $function$
declare g app_private.walking_groups; inputs jsonb; input_digest text; output jsonb; canonical jsonb; route_digest text;
 fresh_context jsonb; calculation app_private.evening_route_calculations; previous app_private.evening_route_calculations; review app_private.evening_route_reviews; difference jsonb;
begin
 select * into g from app_private.walking_groups where id=_group_id;
 if g.id is null then return null;end if;
 perform 1 from app_private.events where id=g.event_id for share;
 inputs:=app_private.evening_route_input(g.id);
 input_digest:=encode(extensions.digest(convert_to(inputs::text,'UTF8'),'sha256'),'hex');
 select * into calculation from app_private.evening_route_calculations where group_id=g.id and input_hash=input_digest order by calculated_at desc,id desc limit 1;
 if calculation.id is null then
  output:=app_private.compute_evening_route_preview(g.id,null);
  canonical:=app_private.evening_route_result_signature(output,inputs);
  route_digest:=encode(extensions.digest(convert_to(jsonb_build_object('input',inputs,'result',canonical)::text,'UTF8'),'sha256'),'hex');
  insert into app_private.evening_route_calculations(event_id,group_id,input_hash,fingerprint,input_snapshot,result_snapshot,canonical_result)
   values(g.event_id,g.id,input_digest,route_digest,inputs,output,canonical) on conflict(group_id,fingerprint) do nothing returning * into calculation;
  if calculation.id is null then select * into calculation from app_private.evening_route_calculations where group_id=g.id and fingerprint=route_digest;end if;
  -- Keep reviewed snapshots forever; bound the disposable preview cache.
  delete from app_private.evening_route_calculations c where c.group_id=g.id
   and c.id not in(select id from app_private.evening_route_calculations where group_id=g.id order by calculated_at desc,id desc limit 2)
   and not exists(select 1 from app_private.evening_route_reviews r where r.calculation_id=c.id);
 end if;
 select * into review from app_private.evening_route_reviews where group_id=g.id order by reviewed_at desc,id desc limit 1;
 if review.id is not null then select * into previous from app_private.evening_route_calculations where id=review.calculation_id;
 else select * into previous from app_private.evening_route_calculations where group_id=g.id and id<>calculation.id order by calculated_at desc,id desc limit 1;end if;
 if previous.id is not null and previous.fingerprint<>calculation.fingerprint then
  select jsonb_build_object('added',coalesce((select jsonb_agg(jsonb_build_object('code',s->'code','name',s->'name') order by s->>'code') from jsonb_array_elements(calculation.result_snapshot->'stops') s where not exists(select 1 from jsonb_array_elements(previous.result_snapshot->'stops') old where old->>'portalId'=s->>'portalId')),'[]'),
   'removed',coalesce((select jsonb_agg(jsonb_build_object('code',s->'code','name',s->'name') order by s->>'code') from jsonb_array_elements(previous.result_snapshot->'stops') s where not exists(select 1 from jsonb_array_elements(calculation.result_snapshot->'stops') newest where newest->>'portalId'=s->>'portalId')),'[]'),
   'distanceDeltaMeters',coalesce((calculation.result_snapshot->>'totalMeters')::numeric,0)-coalesce((previous.result_snapshot->>'totalMeters')::numeric,0),
   'durationDeltaMinutes',coalesce((calculation.result_snapshot->>'totalMinutes')::numeric,0)-coalesce((previous.result_snapshot->>'totalMinutes')::numeric,0)) into difference;
 end if;
 fresh_context:=app_private.evening_route_context(g.id);
 output:=calculation.result_snapshot||jsonb_build_object('publicationId',fresh_context->'publicationId','finaleReservationId',fresh_context->'finaleReservationId','safeWaitingInstruction',fresh_context->'safeWaitingInstruction',
  'checklist',coalesce((select jsonb_agg(case when check_item->>'code'='finale' and coalesce((fresh_context->>'finaleReserved')::boolean,false) then check_item||jsonb_build_object('detail','De route behoudt de gepubliceerde reservering en revisie.') else check_item end order by ordinal) from jsonb_array_elements(calculation.result_snapshot->'checklist') with ordinality rows(check_item,ordinal)),'[]'),
  'stops',coalesce((select jsonb_agg(case when s->>'kind'='finale' then s||jsonb_build_object('reservationId',fresh_context->'finaleReservationId','reservedArrivalAt',case when (fresh_context->>'finaleReserved')::boolean then fresh_context->'finaleArrivalAt' else 'null'::jsonb end) else s end order by ordinal) from jsonb_array_elements(calculation.result_snapshot->'stops') with ordinality rows(s,ordinal)),'[]'));
 return output||jsonb_build_object('fingerprint',calculation.fingerprint,'revision',app_private.start_ops_route_revision(g.event_id),
  'review',jsonb_build_object('isCurrent',coalesce(review.fingerprint=calculation.fingerprint,false),'reviewedAt',review.reviewed_at,'reviewedBy',review.actor_label),'diff',difference);
end;
$function$;
revoke all on function app_private.evening_route_input(uuid),app_private.evening_route_result_signature(jsonb,jsonb),app_private.evening_route_with_review(uuid) from public,anon,authenticated;

create or replace function api.admin_startregie_route_preview(_event_slug text,_group_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $function$
declare eventid uuid:=app_private.current_event_id(_event_slug); actor uuid:=auth.uid();result jsonb;
begin
 if actor is null or not app_private.has_capability(eventid,'groups_manage',actor) or not exists(select 1 from app_private.walking_groups where id=_group_id and event_id=eventid) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 result:=app_private.evening_route_with_review(_group_id);
 if not app_private.has_capability(eventid,'groups_manage',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return result;
end;
$function$;
create or replace function api.admin_startregie_review_route(_event_slug text,_group_id uuid,_expected_revision integer,_expected_fingerprint text) returns jsonb
language plpgsql security definer set search_path='' as $function$
declare eventid uuid:=app_private.current_event_id(_event_slug); actor uuid:=auth.uid(); route jsonb; calculation uuid; result app_private.evening_route_reviews;
begin
 if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform app_private.lock_evening_event(eventid);
 if not app_private.has_capability(eventid,'groups_manage',actor) or not exists(select 1 from app_private.walking_groups where id=_group_id and event_id=eventid) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 route:=app_private.evening_route_with_review(_group_id);
 if _expected_revision is distinct from (route->>'revision')::integer or _expected_fingerprint is distinct from route->>'fingerprint' then raise exception 'STALE_ROUTE' using errcode='40001';end if;
 select id into calculation from app_private.evening_route_calculations where group_id=_group_id and fingerprint=_expected_fingerprint;
 insert into app_private.evening_route_reviews(event_id,group_id,calculation_id,fingerprint,route_revision,actor_id,actor_label)
  values(eventid,_group_id,calculation,_expected_fingerprint,_expected_revision,actor,app_private.readiness_actor_label('group',_group_id,actor))
  on conflict(calculation_id,actor_id) do nothing returning * into result;
 if result.id is null then select * into result from app_private.evening_route_reviews where calculation_id=calculation and actor_id=actor;end if;
 return jsonb_build_object('id',result.id,'fingerprint',result.fingerprint,'reviewedAt',result.reviewed_at,'reviewedBy',result.actor_label);
end;
$function$;
revoke all on function api.admin_startregie_route_preview(text,uuid),api.admin_startregie_review_route(text,uuid,integer,text) from public,anon;
grant execute on function api.admin_startregie_route_preview(text,uuid),api.admin_startregie_review_route(text,uuid,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb; cached_route_revision integer;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  cached_route_revision:=app_private.start_ops_route_revision(e.id);
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item),'[]'::jsonb),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',cached_route_revision) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.group_start_publications p1 where p1.group_id=g.id order by p1.publication_order desc limit 1) pub on true
    where g.event_id=e.id;
  routes:='{}'::jsonb; -- Heavy private routes are fetched individually on demand.
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',cached_route_revision,'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.publish_group_schedules_ops(_event_slug text, _schedule_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  settings app_private.event_route_settings;
  schedule app_private.group_schedule_revisions;
  recipient record;
  child_count integer;
  published_count integer := 0;
  preview_group record; preview_data jsonb; route_stop jsonb; capacity_data jsonb; present_children integer;
begin
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_schedule_ids), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id for update;
  if settings.planner_mode <> 'dynamic' or not settings.finale_available or settings.final_portal_id is null then
    raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514';
  end if;

  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.walking_groups walking_group on walking_group.id = candidate.group_id
    where candidate.id = any(_schedule_ids)
      and (walking_group.event_id <> v_event_id or candidate.state <> 'draft'
        or walking_group.current_schedule_revision_id <> candidate.id)
  ) or (select count(*) from app_private.group_schedule_revisions where id = any(_schedule_ids)) <> cardinality(_schedule_ids) then
    raise exception 'INVALID_SCHEDULE' using errcode = '23514';
  end if;

  -- Payment is a hard publication and start condition.
  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.group_registrations assignment on assignment.group_id = candidate.group_id and assignment.superseded_at is null
    join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
    left join app_private.payment_requests payment on payment.registration_id = registration.id
    where candidate.id = any(_schedule_ids) and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
  ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;

  -- The confirmation must still describe the current event and checked point.
  if exists(select 1 from app_private.group_schedule_revisions s
    join app_private.start_slots slot on slot.id=s.start_slot_id
    join app_private.start_points p on p.id=slot.start_point_id
    join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id
    where s.id=any(_schedule_ids) and (s.confirmed_at is null
      or s.confirmed_settings_version is distinct from e.settings_version
      or s.confirmed_composition_hash is distinct from app_private.start_group_composition_hash(g.id)
      or s.confirmed_point_version is distinct from p.version
      or s.confirmed_route_settings_version is distinct from settings.version
      or s.confirmed_starts_at is distinct from slot.starts_at or s.confirmed_start_point_id is distinct from p.id
      or not slot.active
      or not app_private.start_point_ready_at(p.id,slot.starts_at))) then
    raise exception 'START_NOT_CONFIRMED' using errcode='23514'; end if;
  if exists(select 1 from app_private.group_runs r join app_private.group_schedule_revisions s on s.group_id=r.group_id
    where s.id=any(_schedule_ids)) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  perform app_private.validate_start_schedule_capacity(v_event_id,_schedule_ids);
  for preview_group in select candidate.group_id from app_private.group_schedule_revisions candidate where candidate.id=any(_schedule_ids) loop
    preview_data:=app_private.evening_route_with_review(preview_group.group_id);
    if not coalesce((preview_data->>'feasible')::boolean,false) then raise exception 'ROUTE_NOT_FEASIBLE' using errcode='23514',detail=(preview_data->'blockers')::text;end if;
    select count(*) into present_children from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=preview_group.group_id and a.superseded_at is null;
    for route_stop in select value from jsonb_array_elements(preview_data->'stops') where value->>'kind'='ordinary' loop
      capacity_data:=app_private.assess_ordinary_portal(v_event_id,preview_group.group_id,(route_stop->>'portalId')::uuid,(route_stop->>'plannedArrivalAt')::timestamptz,present_children,clock_timestamp());
      if not coalesce((capacity_data->>'eligible')::boolean,false) then raise exception 'ROUTE_NOT_FEASIBLE' using errcode='23514',detail=(capacity_data->'reasons')::text;end if;
    end loop;
  end loop;

  for schedule in
    select candidate.* from app_private.group_schedule_revisions candidate
    where candidate.id = any(_schedule_ids) order by candidate.group_id, candidate.revision
    for update
  loop
    update app_private.group_schedule_revisions
    set state = 'superseded'
    where group_id = schedule.group_id and state = 'published' and id <> schedule.id;
    update app_private.group_schedule_revisions
    set state = 'published', published_at = clock_timestamp()
    where id = schedule.id;
    update app_private.walking_groups
    set status = 'ready', start_slot_id = schedule.start_slot_id,
        current_schedule_revision_id = schedule.id, route_mode = 'dynamic', version = version + 1
    where id = schedule.group_id;
    update app_private.group_registrations set published_at = now()
    where group_id = schedule.group_id and superseded_at is null;
    update app_private.registrations set preference_change_status = 'locked', version = version + 1
    where id in (select registration_id from app_private.group_registrations where group_id = schedule.group_id and superseded_at is null);
    select count(*) into child_count from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
    where assignment.group_id = schedule.group_id and assignment.superseded_at is null;
    for recipient in
      select distinct users.id as user_id, lower(users.email) as email
      from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id
      join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
      join auth.users users on users.id = member.user_id and users.email_confirmed_at is not null
      where assignment.group_id = schedule.group_id and assignment.superseded_at is null
    loop
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      select
        'group-schedule:' || schedule.group_id::text || ':' || schedule.revision::text || ':' || recipient.user_id::text,
        case when schedule.revision = 1 then 'group_schedule_published' else 'group_schedule_corrected' end,
        recipient.user_id::text,
        recipient.email,
        jsonb_build_object(
          'groupId', schedule.group_id, 'revision', schedule.revision, 'childCount', child_count,
          'startsAt', slot.starts_at, 'addressReleaseAt', slot.starts_at-interval '1 hour',
          'ordinaryStopAt', schedule.effective_ordinary_stop_at,
          'actionPath', '/omgeving/meeloper/groep'
        )
      from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
      where slot.id = schedule.start_slot_id
      on conflict (dedupe_key) do nothing;
    end loop;
    published_count := published_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.published', 'group_schedule_batch',
    jsonb_build_object('count', published_count, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', published_count);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_startregie_publish_times(_event_slug text, _schedule_ids uuid[], _expected_revisions jsonb, _expected_settings_version integer, _idempotency_key text, _reason text DEFAULT 'Geselecteerde starttijden en gecontroleerde routes publiceren'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; receipt app_private.command_receipts; fingerprint text; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into e from app_private.events where slug=_event_slug for no key update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if length(trim(coalesce(_idempotency_key,''))) not between 16 and 200
    or coalesce(cardinality(_schedule_ids),0) not between 1 and 500
    or jsonb_typeof(_expected_revisions) is distinct from 'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('event',e.id,'ids',_schedule_ids,
    'revisions',_expected_revisions,'settingsVersion',_expected_settings_version,'reason',_reason)::text,'UTF8'),'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='start_times.publish' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
    return receipt.safe_result;
  end if;
  raise exception 'EXPECTED_ROUTE_FINGERPRINT_REQUIRED' using errcode='40001';
  if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if jsonb_array_length(_expected_revisions)<>cardinality(_schedule_ids)
    or exists(select 1 from unnest(_schedule_ids) candidate(id) where not exists(
      select 1 from jsonb_array_elements(_expected_revisions) expected
      join app_private.group_schedule_revisions s on s.id=candidate.id
      where expected->>'id'=s.id::text and (expected->>'revision')::integer=s.revision
        and exists(select 1 from app_private.walking_groups g where g.id=s.group_id and g.current_schedule_revision_id=s.id))) then
    raise exception 'STALE_REVISION' using errcode='40001'; end if;
  result:=app_private.publish_startregie_ops(_event_slug,_schedule_ids,_reason);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'start_times.publish',_idempotency_key,fingerprint,result,now()+interval '2 days');
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_startregie_publish_times(_event_slug text, _schedule_ids uuid[], _expected_revisions jsonb, _expected_settings_version integer, _idempotency_key text, _expected_route_fingerprints jsonb, _reason text DEFAULT 'Geselecteerde starttijden en gecontroleerde routes publiceren'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; receipt app_private.command_receipts; fingerprint text; result jsonb; route_group record; route_data jsonb; expected_fingerprint text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into e from app_private.events where slug=_event_slug for no key update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if length(trim(coalesce(_idempotency_key,''))) not between 16 and 200
    or coalesce(cardinality(_schedule_ids),0) not between 1 and 500
    or jsonb_typeof(_expected_revisions) is distinct from 'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('event',e.id,'ids',_schedule_ids,
    'revisions',_expected_revisions,'settingsVersion',_expected_settings_version,'reason',_reason,'routeFingerprints',_expected_route_fingerprints)::text,'UTF8'),'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='start_times.publish' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
    return receipt.safe_result;
  end if;
  if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if jsonb_array_length(_expected_revisions)<>cardinality(_schedule_ids)
    or exists(select 1 from unnest(_schedule_ids) candidate(id) where not exists(
      select 1 from jsonb_array_elements(_expected_revisions) expected
      join app_private.group_schedule_revisions s on s.id=candidate.id
      where expected->>'id'=s.id::text and (expected->>'revision')::integer=s.revision
        and exists(select 1 from app_private.walking_groups g where g.id=s.group_id and g.current_schedule_revision_id=s.id))) then
    raise exception 'STALE_REVISION' using errcode='40001'; end if;
  if jsonb_typeof(_expected_route_fingerprints) is distinct from 'array'
    or jsonb_array_length(_expected_route_fingerprints)<>cardinality(_schedule_ids)
    or (select count(distinct item->>'groupId') from jsonb_array_elements(_expected_route_fingerprints) item)<>cardinality(_schedule_ids)
    or exists(select 1 from jsonb_array_elements(_expected_route_fingerprints) item where coalesce(item->>'fingerprint','') !~ '^[0-9a-f]{64}$') then
    raise exception 'EXPECTED_ROUTE_FINGERPRINT_REQUIRED' using errcode='40001';end if;
  for route_group in select group_id from app_private.group_schedule_revisions where id=any(_schedule_ids) loop
    select item->>'fingerprint' into expected_fingerprint from jsonb_array_elements(_expected_route_fingerprints) item where item->>'groupId'=route_group.group_id::text;
    route_data:=app_private.evening_route_with_review(route_group.group_id);
    if expected_fingerprint is distinct from route_data->>'fingerprint' then raise exception 'STALE_ROUTE' using errcode='40001';end if;
  end loop;
  result:=app_private.publish_startregie_ops(_event_slug,_schedule_ids,_reason);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'start_times.publish',_idempotency_key,fingerprint,result,now()+interval '2 days');
  return result;
end;
$function$
;

revoke all on function api.admin_startregie_publish_times(text,uuid[],jsonb,integer,text,jsonb,text) from public,anon;
grant execute on function api.admin_startregie_publish_times(text,uuid[],jsonb,integer,text,jsonb,text) to authenticated;
