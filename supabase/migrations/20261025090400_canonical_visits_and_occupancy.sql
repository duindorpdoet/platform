-- Canonical identity complements, rather than rewrites, historical arrivals.
create table if not exists app_private.group_portal_visits (
 event_id uuid not null references app_private.events(id),group_id uuid not null references app_private.walking_groups(id),
 portal_id uuid not null references app_private.portals(id),first_stop_id uuid not null references app_private.run_stops(id),
 arrived_at timestamptz not null,primary key(event_id,group_id,portal_id));
alter table app_private.group_portal_visits enable row level security;
revoke all on app_private.group_portal_visits from public,anon,authenticated;
insert into app_private.group_portal_visits(event_id,group_id,portal_id,first_stop_id,arrived_at)
select distinct on(g.event_id,g.id,coalesce(s.portal_id,ps.portal_id)) g.event_id,g.id,coalesce(s.portal_id,ps.portal_id),s.id,coalesce(s.completed_at,s.opened_at,r.created_at)
from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id
left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
where coalesce(s.portal_id,ps.portal_id) is not null and (exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=s.id and a.arrived) or (s.state='completed' and s.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=s.id)))
order by g.event_id,g.id,coalesce(s.portal_id,ps.portal_id),coalesce(s.completed_at,s.opened_at,r.created_at),s.id on conflict do nothing;
create or replace function app_private.group_has_visited_portal(_event uuid,_group uuid,_portal uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.group_portal_visits v where v.event_id=_event and v.group_id=_group and v.portal_id=_portal)
 or exists(select 1 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id and r.group_id=_group
 join app_private.walking_groups g on g.id=r.group_id and g.event_id=_event left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 where coalesce(s.portal_id,ps.portal_id)=_portal and (exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=s.id and a.arrived)
 or (s.state='completed' and s.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=s.id))))
$$;
create or replace function app_private.record_canonical_portal_visit()
returns trigger language plpgsql security definer set search_path='' as $$
declare gid uuid; pid uuid; original uuid;
begin
 if not new.arrived then return new;end if;
 select r.group_id,coalesce(s.portal_id,ps.portal_id) into gid,pid from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where s.id=new.run_stop_id;
 if pid is null then raise exception 'PORTAL_IDENTITY_MISSING' using errcode='23514';end if;
 insert into app_private.group_portal_visits(event_id,group_id,portal_id,first_stop_id,arrived_at) values(new.event_id,gid,pid,new.run_stop_id,new.arrived_at) on conflict do nothing;
 select first_stop_id into original from app_private.group_portal_visits where event_id=new.event_id and group_id=gid and portal_id=pid;
 if original is distinct from new.run_stop_id then raise exception 'PORTAL_ALREADY_VISITED' using errcode='23514';end if;
 return new;
end $$;
drop trigger if exists record_canonical_portal_visit on app_private.run_stop_arrivals;
create trigger record_canonical_portal_visit before insert on app_private.run_stop_arrivals for each row execute function app_private.record_canonical_portal_visit();
create or replace function app_private.portal_service_seconds(_portal uuid,_at timestamptz)
returns integer language sql stable security definer set search_path='' as $$
 select (w.visit_minutes+w.buffer_minutes)*60 from app_private.portal_windows w where w.portal_id=_portal and _at>=w.opens_at and _at<w.closes_at order by w.opens_at,w.id limit 1
$$;
create or replace function app_private.portal_occupancy_intervals(_portal uuid,_at timestamptz)
returns table(group_id uuid,starts_at timestamptz,ends_at timestamptz,child_count integer) language sql stable security definer set search_path='' as $$
 select r.group_id,r.reserved_from,r.reserved_until,r.child_count from app_private.portal_reservations r
 where r.portal_id=_portal and (r.status in ('active','completed') or (r.status='held' and (r.expires_at is null or r.expires_at>_at)))
 union all
 select p.group_id,p.starts_at,p.starts_at+make_interval(secs=>app_private.portal_service_seconds(_portal,p.starts_at)),
 (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=p.group_id and a.superseded_at is null)
 from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) p
 where p.point_snapshot->>'linked_portal_id'=_portal::text
 and not exists(select 1 from app_private.portal_reservations r where r.group_id=g.id and r.portal_id=_portal and r.status in ('held','active','completed'))
 and not app_private.group_has_visited_portal(g.event_id,g.id,_portal)
 union all
 select r.group_id,r.starts_at,r.starts_at+make_interval(secs=>app_private.portal_service_seconds(_portal,r.starts_at)),r.child_count
 from app_private.portals portal cross join lateral app_private.start_schedule_reservations(portal.event_id) r
 join app_private.start_points point on point.id=r.start_point_id and point.linked_portal_id=_portal
 where portal.id=_portal and not app_private.group_has_visited_portal(portal.event_id,r.group_id,_portal)
 and not exists(select 1 from app_private.portal_reservations b where b.portal_id=_portal and b.group_id=r.group_id and b.status in ('active','completed'))
$$;
create or replace function app_private.portal_interval_available(_portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_at timestamptz)
returns boolean language sql stable security definer set search_path='' as $$
 select _from<_until and exists(select 1 from app_private.portal_windows w where w.portal_id=_portal and _from>=w.opens_at and _until<=w.closes_at and _children<=w.max_children_per_visit
 and _children+coalesce((select sum(occupied.children) from (select q.group_id,max(q.child_count) children from (
  select b.group_id,b.child_count from app_private.portal_occupancy_intervals(_portal,_at) b
  union all select v.group_id,(select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=v.first_stop_id and a.arrived) from app_private.group_portal_visits v where v.portal_id=_portal
 ) q where q.group_id<>_group group by q.group_id) occupied),0)<=w.max_children_total
 and not exists(select 1 from (
  select _from tick union select r.starts_at from app_private.portal_occupancy_intervals(_portal,_at) r where r.starts_at>=_from and r.starts_at<_until
 ) boundary where (select count(distinct r.group_id) from app_private.portal_occupancy_intervals(_portal,_at) r where r.group_id<>_group and r.starts_at<=boundary.tick and r.ends_at>boundary.tick)>=w.max_concurrent_groups))
$$;
revoke all on function app_private.group_has_visited_portal(uuid,uuid,uuid),app_private.record_canonical_portal_visit(),app_private.portal_service_seconds(uuid,timestamptz),app_private.portal_occupancy_intervals(uuid,timestamptz),app_private.portal_interval_available(uuid,uuid,timestamptz,timestamptz,integer,timestamptz) from public,anon,authenticated;

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
  perform 1 from app_private.events where id=(select lock_group.event_id from app_private.group_runs lock_run join app_private.walking_groups lock_group on lock_group.id=lock_run.group_id where lock_run.id=_run_id) for update;
  perform pg_advisory_xact_lock(hashtextextended((select lock_group.event_id::text||':route-dispatch' from app_private.group_runs lock_run join app_private.walking_groups lock_group on lock_group.id=lock_run.group_id where lock_run.id=_run_id),0));
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
  -- Completing the app step is not evidence of physical departure.
  update app_private.portal_reservations set status='completed',reserved_from=clock_timestamp(),
    reserved_until=clock_timestamp()+make_interval(secs=>coalesce(app_private.portal_service_seconds(portal_id,clock_timestamp()),480)),version=version+1
  where id=stop_record.reservation_id;
  perform realtime.send(jsonb_build_object('resource','arrivals'),'snapshot_changed','portal:'||coalesce(stop_record.portal_id,(select portal_id from app_private.route_plan_stops where id=stop_record.plan_stop_id)),true);
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
    dispatch_result := app_private.dispatch_next_stop(_run_id, clock_timestamp());
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
  source_lat numeric; source_lon numeric; final_lat numeric; final_lon numeric; frozen_position jsonb;
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

  select (app_private.portal_location(stop.portal_id)->>'latitude')::numeric,
    (app_private.portal_location(stop.portal_id)->>'longitude')::numeric into source_lat,source_lon
  from app_private.run_stops stop where stop.run_id=_run_id and stop.plan_stop_id is null and stop.state='completed'
  order by stop.sequence desc limit 1;
  if source_lat is null or source_lon is null then
    select app_private.routing_position((p.point_snapshot->>'marker_latitude')::numeric,(p.point_snapshot->>'marker_longitude')::numeric,
      (p.point_snapshot->>'geocoded_latitude')::numeric,(p.point_snapshot->>'geocoded_longitude')::numeric,
      (p.point_snapshot->>'latitude')::numeric,(p.point_snapshot->>'longitude')::numeric) into frozen_position
    from app_private.group_start_publications p where p.group_id=group_record.id and p.schedule_id=run_record.schedule_revision_id
    order by p.publication_order desc limit 1;
    source_lat:=(frozen_position->>'latitude')::numeric; source_lon:=(frozen_position->>'longitude')::numeric;
  end if;
  if source_lat is null or source_lon is null then raise exception 'SOURCE_POSITION_INVALID' using errcode='23514'; end if;
  select (app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,
    (app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric into final_lat,final_lon;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.event_id=group_record.event_id
      and portal.approval_status='approved' and portal.lifecycle_status='active'
      and app_private.portal_location_ready(portal.id) and portal.operation_status in ('open', 'scheduled')
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

  if app_private.group_has_visited_portal(group_record.event_id,group_record.id,settings.final_portal_id) then
    update app_private.group_runs set status='completed',current_stop_id=null,finished_at=clock_timestamp(),version=version+1 where id=_run_id;
    update app_private.walking_groups set status='completed',version=version+1 where id=group_record.id;
    return jsonb_build_object('decision','completed');
  end if;
  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      select portal.id as portal_id, portal.world_id, portal.name,
        source_path.distance_m as incoming_distance_m, source_path.duration_seconds as incoming_seconds,
        source_path.edge_ids as incoming_edge_ids,
        final_path.duration_seconds as finale_seconds,
        _decision_at + make_interval(secs => source_path.duration_seconds::integer) as arrival_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) as departure_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) as earliest_finale_at,
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
      join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
      cross join lateral app_private.destination_estimate(source_lat,source_lon,coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude)) source_path
      cross join lateral app_private.destination_estimate(coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude),final_lat,final_lon) final_path
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)
        and exists (
          select 1 from app_private.portal_windows portal_window
          where portal_window.portal_id = portal.id
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) >= portal_window.opens_at
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) < portal_window.closes_at
            and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer) <= portal_window.closes_at
            and portal_window.max_children_per_visit>=v_child_count
        )
        and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) <= schedule.effective_ordinary_stop_at
        and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at
        and app_private.portal_interval_available(portal.id,group_record.id,
          _decision_at+make_interval(secs=>source_path.duration_seconds::integer),
          _decision_at+make_interval(secs=>(source_path.duration_seconds+app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer),v_child_count,_decision_at)
      order by score, incoming_distance_m, portal.id
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds)
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
          'decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op geschatte reistijd, beschikbaarheid en finalehaalbaarheid'
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
    join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
    cross join lateral app_private.destination_estimate(source_lat,source_lon,coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude)) source_path
    cross join lateral app_private.destination_estimate(coalesce(location.marker_latitude,location.geocoded_latitude,location.latitude),coalesce(location.marker_longitude,location.geocoded_longitude,location.longitude),final_lat,final_lon) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)
      and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at;
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

  select * into finale_path from app_private.destination_estimate(source_lat,source_lon,final_lat,final_lon);
  if finale_path.duration_seconds is null then raise exception 'FINAL_PORTAL_POSITION_INVALID' using errcode = '23514'; end if;
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
    jsonb_build_object('decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'walkSeconds', finale_path.duration_seconds),
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
  select * into r from app_private.group_runs where id = _run_id for update;
  select desired_ordinary_visits into requested from app_private.walking_groups where id = r.group_id;
  if requested is not null then
    select count(*) into visited from app_private.run_stops stop where stop.run_id = _run_id
      and stop.stop_kind = 'ordinary' and stop.state = 'completed' and stop.outcome in ('visited', 'mixed', 'all_skipped')
      and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=stop.id);
    reached := visited >= requested;
  end if;
  if not reached and not exists(select 1 from app_private.run_stops where run_id=_run_id) then
    select (p.point_snapshot->>'linked_portal_id')::uuid into first_portal
      from app_private.group_start_publications p where p.schedule_id=r.schedule_revision_id
      and (p.point_snapshot->>'counts_as_first_portal_visit')::boolean=true
      order by p.publication_order desc limit 1;
  end if;
  if first_portal is not null and app_private.group_has_visited_portal((select event_id from app_private.walking_groups where id=r.group_id),r.group_id,first_portal) then first_portal:=null;end if;
  return app_private.dispatch_next_stop_before_visit_preference(
    _run_id, _decision_at, _force_finale or reached, case when reached then null else coalesce(first_portal,_preferred_portal_id) end);
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
  last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; chosen uuid[]:='{}'::uuid[]; candidate record;
  meters bigint:=0; seconds bigint:=0; walk_m bigint; walk_s bigint; provisional boolean:=false;
  remaining integer; visited integer:=0; child_count integer; fixed_portal uuid;
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
  last_lon:=(app_private.start_point_location(point.id)->>'longitude')::numeric;
  last_lat:=(app_private.start_point_location(point.id)->>'latitude')::numeric;
  start_time:=slot.starts_at; at_time:=slot.starts_at;
  if r.id is not null then
    at_time:=greatest(at_time,statement_timestamp());
    select coalesce(array_agg(coalesce(rs.portal_id,ps.portal_id)),array[]::uuid[]),
      count(*) filter(where coalesce(rs.stop_kind::text,'ordinary')='ordinary' and rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=rs.id))
    into chosen,visited from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
    where rs.run_id=r.id and rs.state='completed' and (exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=rs.id and a.arrived) or (rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=rs.id)));
    select coalesce(rs.portal_id,ps.portal_id) into preserved_portal from app_private.run_stops rs
      left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=r.current_stop_id;
    select (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'longitude')::numeric,
      (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'latitude')::numeric into last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    last_lon:=coalesce(last_lon,(app_private.start_point_location(point.id)->>'longitude')::numeric);
    last_lat:=coalesce(last_lat,(app_private.start_point_location(point.id)->>'latitude')::numeric);
  end if;
  select count(*) into visited from app_private.portals p where p.event_id=g.event_id and p.id<>settings.final_portal_id and app_private.group_has_visited_portal(g.event_id,g.id,p.id);
  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;
  if not point.counts_as_first_portal_visit and point.linked_portal_id is not null and point.linked_portal_id is distinct from preserved_portal then
    chosen:=array_append(chosen,point.linked_portal_id);
  elsif point.counts_as_first_portal_visit and r.id is null then fixed_portal:=point.linked_portal_id; end if;
  select count(*) into eligible from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
    where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')
      and p.id<>settings.final_portal_id;

  loop
    exit when remaining<=0 and preserved_portal is null;
    select q.* into candidate from (
      select p.id,p.name,p.system_code,p.world_id,w.name world,l.*,
        coalesce(m.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
          coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))))::bigint walk_m,
        m.duration_seconds::bigint walk_s,
        true geographic,
        final_path.duration_seconds final_seconds
      from app_private.portals p join app_private.worlds w on w.id=p.world_id
      join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
      left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true
      left join lateral app_private.destination_estimate(coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) final_path on true
      where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen)) and not app_private.group_has_visited_portal(g.event_id,g.id,p.id)
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
        and (p.id=preserved_portal or not step_free or exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free'))
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
        and win.max_children_per_visit>=child_count)
      and app_private.portal_interval_available(q.id,g.id,at_time+make_interval(secs=>q.walk_s::integer),at_time+make_interval(secs=>q.walk_s::integer+app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer))),child_count,statement_timestamp())))
    order by q.walk_s,q.walk_m,q.id limit 1;
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
    last_lon:=coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude);
    last_lat:=coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude);
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null and not app_private.group_has_visited_portal(g.event_id,g.id,candidate.id) and app_private.portal_location_ready(candidate.id) and candidate.duration_seconds is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude),coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude))))::bigint;
    walk_s:=candidate.duration_seconds;
    provisional:=true;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','finale',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>settings.finale_last_arrival_at or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('De eindpoort heeft geen geldig opgeslagen adres of marker — controleer de eindpoort.'); end if;
  if provisional then warnings:=warnings||jsonb_build_array('Afstanden zijn hemelsbreed; reistijden zijn schattingen. Kies zelf hoe je naar de volgende poort gaat.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      (app_private.start_point_location(point.id)->>'longitude')::numeric,(app_private.start_point_location(point.id)->>'latitude')::numeric),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'distanceMethod','straight_line','travelTimeEstimated',true,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$
;


CREATE OR REPLACE FUNCTION api.run_arrive_and_advance(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _participant_choices jsonb, _idempotency_key text, _portal_id uuid DEFAULT NULL::uuid, _method text DEFAULT 'qr'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; saved app_private.command_receipts; hashed text; result jsonb; entry record; statusrow app_private.stop_participant_statuses;
begin
  perform 1 from app_private.events where id=(select lock_group.event_id from app_private.group_runs lock_run join app_private.walking_groups lock_group on lock_group.id=lock_run.group_id where lock_run.id=_run_id) for update;
  perform pg_advisory_xact_lock(hashtextextended((select lock_group.event_id::text||':route-dispatch' from app_private.group_runs lock_run join app_private.walking_groups lock_group on lock_group.id=lock_run.group_id where lock_run.id=_run_id),0));
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(coalesce(_idempotency_key,'')) not between 8 and 100 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=encode(extensions.digest(convert_to(jsonb_build_array(_run_id,_expected_stop_id,_expected_run_version,_credential,_participant_choices,_portal_id,_method)::text,'utf8'),'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.arriveAndAdvance' and idempotency_key=_idempotency_key;
 if saved.id is not null then
  if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return saved.safe_result;
 end if;
 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 if jsonb_typeof(_participant_choices) is distinct from 'object' or (select count(*) from jsonb_object_keys(_participant_choices))=0 then raise exception 'INVALID_ATTENDANCE'; end if;
 if exists(select 1 from jsonb_each_text(_participant_choices) c where c.value not in ('visited','skipped') or not exists(select 1 from app_private.run_participants p where p.id::text=c.key and p.run_id=_run_id and p.attendance='present' and p.departed_at is null))
 or exists(select 1 from app_private.run_participants p join app_private.stop_participant_statuses st on st.run_participant_id=p.id and st.run_stop_id=_expected_stop_id where p.run_id=_run_id and p.attendance='present' and st.required_for_completion and not (_participant_choices ? p.id::text))
 then raise exception 'INVALID_ATTENDANCE'; end if;
 perform api.run_scan(_run_id,_expected_stop_id,_expected_run_version,_credential,_method);
 for entry in select * from jsonb_each_text(_participant_choices) loop
  select * into statusrow from app_private.stop_participant_statuses where run_stop_id=_expected_stop_id and run_participant_id=entry.key::uuid for update;
  if statusrow.id is null then raise exception 'INVALID_ATTENDANCE'; end if;
  if statusrow.status::text<>entry.value then
   if statusrow.status='skipped' then perform api.run_update_participant(_run_id,_expected_stop_id,entry.key::uuid,'pending',_expected_run_version,statusrow.version,'Keuze bevestigd met eigen ouder');
    select * into statusrow from app_private.stop_participant_statuses where id=statusrow.id; end if;
   perform api.run_update_participant(_run_id,_expected_stop_id,entry.key::uuid,entry.value::app_private.participant_stop_status,_expected_run_version,statusrow.version,'Keuze bevestigd met ouder bij aankomst');
  end if;
 end loop;
 result:=api.run_complete_stop(_run_id,_expected_stop_id,_expected_run_version,true,_idempotency_key||':complete',hashed)||jsonb_build_object('accepted',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.arriveAndAdvance',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $function$
;


CREATE OR REPLACE FUNCTION api.run_start(_group_id uuid, _present_registration_child_ids uuid[], _expected_group_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
  dispatch_result jsonb;
  result jsonb;
begin
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  perform pg_advisory_xact_lock(hashtextextended((select event_id::text||':route-dispatch' from app_private.walking_groups where id=_group_id),0));
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_present_registration_child_ids), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id
        and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  if group_record.route_mode = 'dynamic' then
    select * into schedule from app_private.group_schedule_revisions
    where group_id = group_record.id and state = 'published'
    order by revision desc limit 1;
    if schedule.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode = '23514'; end if;
    if clock_timestamp() < (select starts_at from app_private.group_start_publications where schedule_id=schedule.id order by publication_order desc limit 1) then
      raise exception 'START_TIME_NOT_REACHED' using errcode = '23514';
    end if;
    -- Unpaid is an operational warning; financial status is preserved.

    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at)
    values (_group_id, null, schedule.id, 'live', clock_timestamp()) returning id into v_run_id;
  else
    select id into plan_id from app_private.route_plan_versions
    where group_id = _group_id and state = 'published' order by revision desc limit 1;
    if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.group_start_publications where group_id=_group_id) then
    raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514'; end if;
  if clock_timestamp() < (select starts_at from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1) then raise exception 'START_TIME_NOT_REACHED' using errcode='23514'; end if;

    if exists(select 1 from app_private.route_plan_stops stop
      where stop.plan_version_id=plan_id and stop.position=1
        and not app_private.portal_location_ready(stop.portal_id)) then
      raise exception 'PORTAL_NOT_ROUTE_READY' using errcode='23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, status, started_at)
    values (_group_id, plan_id, 'live', clock_timestamp()) returning id into v_run_id;
  end if;

  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids)
      then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null
    and registration_child.participation_status = 'active';

  if group_record.route_mode = 'dynamic' then
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := app_private.dispatch_next_stop(v_run_id, clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id = v_run_id;
  else
    insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
    select v_run_id, stop.id, row_number() over(order by stop.position),
      case when row_number() over(order by stop.position) = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when row_number() over(order by stop.position) = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id=plan_id and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,stop.portal_id) order by stop.position;
    select id into first_stop_id from app_private.run_stops where run_id = v_run_id and sequence = 1;
    if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
    update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select first_stop_id, participant.id from app_private.run_participants participant
    where participant.run_id = v_run_id and participant.attendance = 'present';
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := jsonb_build_object('decision', 'legacy', 'stopId', first_stop_id);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (v_run_id, first_stop_id, 'run.started', actor, jsonb_build_object('routeMode', group_record.route_mode));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id, jsonb_build_object('routeMode', group_record.route_mode));
  result := jsonb_build_object('runId', v_run_id, 'dispatch', dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, result, now() + interval '2 days') returning * into receipt;
  return receipt.safe_result;
end;
$function$
;
CREATE OR REPLACE FUNCTION app_private.validate_start_schedule_capacity(_event_id uuid, _schedule_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; settings app_private.event_route_settings; tick timestamptz; service_interval interval;
  load_groups integer; load_children bigint;
begin
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_slot_id=candidate.start_slot_id group by r.group_id) q;
    if load_groups>candidate.max_groups or load_children>candidate.max_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_point_id=candidate.start_point_id and r.starts_at=candidate.starts_at group by r.group_id) q;
    if load_groups>candidate.max_gathering_groups or load_children>candidate.max_gathering_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    if candidate.expected_finale_arrival_at is null or candidate.expected_finale_arrival_at<settings.finale_opens_at
      or candidate.expected_finale_arrival_at>settings.finale_last_arrival_at then
      raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    -- Half-open intervals, evaluated at every occupancy change. A group's
    -- overlapping old and new reservation contributes its children once.
    for tick in select distinct r.finale_at from app_private.start_schedule_reservations(_event_id) r
      where r.finale_at<candidate.expected_finale_arrival_at+service_interval
        and r.finale_at+service_interval>candidate.expected_finale_arrival_at
      union select candidate.expected_finale_arrival_at
    loop
      select count(*),coalesce(sum(n),0) into load_groups,load_children from (
        select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
        where r.finale_at<=tick and r.finale_at+service_interval>tick group by r.group_id) q;
      if load_groups>settings.finale_max_concurrent_groups or load_children>settings.finale_max_concurrent_children then
        raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    end loop;
    if exists(select 1 from app_private.start_points point where point.id=candidate.start_point_id and point.linked_portal_id is not null and
      not app_private.portal_interval_available(point.linked_portal_id,candidate.group_id,candidate.starts_at,
        candidate.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,candidate.starts_at)),
        (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null),statement_timestamp())) then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514';
    end if;
  end loop;
end;
$function$
;
