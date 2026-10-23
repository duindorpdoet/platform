-- Explicit reviewed contract replacements; no catalog rewriting at deploy time.

CREATE OR REPLACE FUNCTION api.admin_save_group_schedule(_group_id uuid, _start_slot_id uuid, _effective_stop_at timestamp with time zone, _expected_finale_arrival_at timestamp with time zone, _queue_number integer, _preference_match text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  settings app_private.event_route_settings;
  current_schedule app_private.group_schedule_revisions;
  next_schedule app_private.group_schedule_revisions;
  next_revision integer;
begin
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if exists(select 1 from app_private.group_runs where group_id=group_record.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  if _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if not exists (
    select 1 from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
    where slot.id = _start_slot_id and slot.event_id = group_record.event_id and slot.active
      and app_private.start_point_ready_at(point.id,slot.starts_at)
  ) or _effective_stop_at > settings.global_ordinary_stop_at
     or _expected_finale_arrival_at < settings.finale_opens_at
     or _expected_finale_arrival_at > settings.finale_last_arrival_at then
    raise exception 'SCHEDULE_CONFLICT' using errcode = '23514';
  end if;
  select * into current_schedule from app_private.group_schedule_revisions where id = group_record.current_schedule_revision_id;
  select coalesce(max(revision), 0) + 1 into next_revision from app_private.group_schedule_revisions where group_id = group_record.id;
  insert into app_private.group_schedule_revisions(
    group_id, revision, start_slot_id, effective_ordinary_stop_at, expected_finale_arrival_at,
    queue_number, preference_match, input_snapshot, created_by, supersedes_id
  ) values (
    group_record.id, next_revision, _start_slot_id, _effective_stop_at, _expected_finale_arrival_at,
    _queue_number, _preference_match,
    jsonb_build_object('reason', left(trim(_reason), 500), 'previousRevision', current_schedule.revision),
    actor, current_schedule.id
  ) returning * into next_schedule;
  -- Keep the last published start active until this correction is explicitly
  -- confirmed. The draft pointer is for the admin board only.
  update app_private.walking_groups
  set current_schedule_revision_id = next_schedule.id, version = version + 1
  where id = group_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group_schedule.revision_created', 'group_schedule', next_schedule.id,
    jsonb_build_object('groupId', group_record.id, 'revision', next_revision, 'reason', left(trim(_reason), 500)));
  perform app_private.validate_start_schedule_capacity(group_record.event_id,array[next_schedule.id]);
  return jsonb_build_object('id', next_schedule.id, 'revision', next_schedule.revision, 'state', next_schedule.state);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_startregie_move_group(_group_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _expected_group_version integer, _preference_match text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); group_record app_private.walking_groups; point_record app_private.start_points;
  settings app_private.event_route_settings; portal_record app_private.portals; slot_record app_private.start_slots;
  schedule_record app_private.group_schedule_revisions; result jsonb; group_children integer; occupied_groups integer; occupied_children integer;
begin
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if actor is null or group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if exists(select 1 from app_private.group_runs where group_id=group_record.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  if _expected_group_version is distinct from group_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  select * into point_record from app_private.start_points
    where id = _start_point_id and event_id = group_record.event_id and active for update;
  if point_record.id is null then raise exception 'START_POINT_NOT_AVAILABLE' using errcode = '23514'; end if;
  if not app_private.start_point_safe_connection(point_record.id) then raise exception 'START_POINT_NOT_VERIFIED' using errcode='23514'; end if;
  if point_record.walking_node_id is null or coalesce(point_record.marker_latitude, point_record.geocoded_latitude, point_record.latitude) is null then
    raise exception 'START_POINT_MARKER_INVALID' using errcode = '23514';
  end if;
  if settings.first_start_at is null or settings.global_ordinary_stop_at is null
    or _starts_at < settings.first_start_at or _starts_at > settings.global_ordinary_stop_at then
    raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514';
  end if;
  if (point_record.available_from is not null and _starts_at < point_record.available_from)
    or (point_record.available_until is not null and _starts_at > point_record.available_until) then
    raise exception 'START_POINT_CLOSED' using errcode = '23514';
  end if;
  if point_record.linked_portal_id is not null then
    select * into portal_record from app_private.portals where id = point_record.linked_portal_id;
    if portal_record.lifecycle_status <> 'active' or portal_record.approval_status <> 'approved'
      or not exists (select 1 from app_private.portal_windows portal_window where portal_window.portal_id = portal_record.id
        and _starts_at >= portal_window.opens_at and _starts_at < portal_window.closes_at) then
      raise exception 'LINKED_PORTAL_NOT_OPEN' using errcode = '23514';
    end if;
  end if;

  select * into slot_record from app_private.start_slots
    where start_point_id = point_record.id and starts_at = _starts_at and active for update;
  if slot_record.id is null then
    insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
      location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
    values (group_record.event_id, point_record.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point_record.name, point_record.private_address,
      coalesce(point_record.marker_latitude, point_record.geocoded_latitude, point_record.latitude),
      coalesce(point_record.marker_longitude, point_record.geocoded_longitude, point_record.longitude),
      point_record.verified_at, _starts_at, point_record.max_gathering_groups,
      point_record.max_gathering_children, true, point_record.id)
    returning * into slot_record;
  end if;

  select count(*)::integer,
    coalesce(sum((select count(*) from app_private.group_registrations assignment
      join app_private.registration_children child on child.registration_id = assignment.registration_id
        and child.participation_status = 'active'
      where assignment.group_id = other_group.id and assignment.superseded_at is null)), 0)::integer
  into occupied_groups, occupied_children
  from app_private.walking_groups other_group
  join app_private.group_schedule_revisions other_schedule on other_schedule.id = other_group.current_schedule_revision_id
  join app_private.start_slots other_slot on other_slot.id = other_schedule.start_slot_id
  where other_group.event_id = group_record.event_id and other_group.id <> group_record.id
    and other_slot.start_point_id = point_record.id and other_slot.starts_at = _starts_at;
  select count(*)::integer into group_children from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id
      and child.participation_status = 'active'
    where assignment.group_id = group_record.id and assignment.superseded_at is null;
  if occupied_groups + 1 > least(slot_record.max_groups, point_record.max_gathering_groups)
    or occupied_children + group_children > least(slot_record.max_children, point_record.max_gathering_children) then
    raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode = '23514';
  end if;

  select * into schedule_record from app_private.group_schedule_revisions where id = group_record.current_schedule_revision_id;
  result := api.admin_save_group_schedule(
    group_record.id, slot_record.id,
    coalesce(schedule_record.effective_ordinary_stop_at, settings.global_ordinary_stop_at),
    coalesce(schedule_record.expected_finale_arrival_at,
      greatest(settings.finale_opens_at, settings.global_ordinary_stop_at + make_interval(secs => settings.finale_planning_transfer_seconds))),
    schedule_record.queue_number, _preference_match, _reason
  );
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'groupId', group_record.id),
    'snapshot_changed', 'admin-event:' || group_record.event_id::text, true);
  return result || jsonb_build_object('previousStartSlotId', schedule_record.start_slot_id,
    'startPointId', point_record.id, 'startsAt', slot_record.starts_at);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_publish_group_schedules(_event_slug text, _schedule_ids uuid[], _reason text)
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
  service_interval interval;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_schedule_ids), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id for update;
  if settings.planner_mode <> 'dynamic' or not settings.finale_available or settings.final_portal_id is null then
    raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514';
  end if;
  service_interval := make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds);

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
  publication app_private.group_start_publications;
  result jsonb;
begin
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
    if exists (
      select 1 from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where assignment.group_id = _group_id and assignment.superseded_at is null
        and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
    ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;
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

    select * into publication from app_private.group_start_publications where group_id=_group_id order by publication_order desc limit 1;
    if publication.point_snapshot->>'walking_node_id' is not null and not exists(
      select 1 from app_private.route_plan_stops stop join app_private.walking_nodes node on node.portal_id=stop.portal_id and node.event_id=group_record.event_id and node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id,(publication.point_snapshot->>'walking_node_id')::uuid,node.id,false) safe_path
      where stop.plan_version_id=plan_id and stop.position=1) then raise exception 'NO_SAFE_WALKING_PATH' using errcode='23514'; end if;
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
    select v_run_id, stop.id, stop.position,
      case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when stop.position = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
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

do $$ begin
  if to_regprocedure('app_private.group_snapshot_before_start_ops(uuid)') is null then
    alter function api.group_snapshot(uuid) set schema app_private;
    alter function app_private.group_snapshot(uuid) rename to group_snapshot_before_start_ops;
  end if;
end $$;
revoke all on function app_private.group_snapshot_before_start_ops(uuid) from public,anon,authenticated;

create or replace function api.group_snapshot(_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; 
begin
  result:=app_private.group_snapshot_before_start_ops(_group_id);
  return jsonb_set(result,'{group,start}',coalesce(app_private.published_start_projection(_group_id),'null'::jsonb),true);
end;
$$;
revoke all on function api.group_snapshot(uuid) from public,anon;
grant execute on function api.group_snapshot(uuid) to authenticated;

do $$ begin
  if to_regprocedure('app_private.group_viewer_snapshot_before_start_ops(uuid)') is null then
    alter function api.group_viewer_snapshot(uuid) set schema app_private;
    alter function app_private.group_viewer_snapshot(uuid) rename to group_viewer_snapshot_before_start_ops;
  end if;
end $$;
revoke all on function app_private.group_viewer_snapshot_before_start_ops(uuid) from public,anon,authenticated;

create or replace function api.group_viewer_snapshot(_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; 
begin
  result:=app_private.group_viewer_snapshot_before_start_ops(_group_id);
  return jsonb_set(result,'{group,start}',coalesce(app_private.published_start_projection(_group_id),'null'::jsonb),true);
end;
$$;
revoke all on function api.group_viewer_snapshot(uuid) from public,anon;
grant execute on function api.group_viewer_snapshot(uuid) to authenticated;

do $$ begin
  if to_regprocedure('app_private.registration_preferences_snapshot_before_start_ops(text)') is null then
    alter function api.registration_preferences_snapshot(text) set schema app_private;
    alter function app_private.registration_preferences_snapshot(text) rename to registration_preferences_snapshot_before_start_ops;
  end if;
end $$;
revoke all on function app_private.registration_preferences_snapshot_before_start_ops(text) from public,anon,authenticated;

create or replace function api.registration_preferences_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; g uuid; appointment jsonb;
begin
  result:=app_private.registration_preferences_snapshot_before_start_ops(_event_slug);
  select a.group_id into g from app_private.group_registrations a
    where a.registration_id=(result->>'registrationId')::uuid and a.superseded_at is null;
  appointment:=app_private.published_start_projection(g);
  result:=jsonb_set(result,'{confirmedSchedule}',(case when jsonb_typeof(result->'confirmedSchedule')='object'
    then (result->'confirmedSchedule')-'startPoint'-'startAddress' else '{}'::jsonb end)
    ||coalesce(appointment,'{}'::jsonb),true);
  if appointment is null then result:=jsonb_set(result,'{confirmedSchedule}','null'::jsonb,true); end if;
  return result;
end;
$$;
revoke all on function api.registration_preferences_snapshot(text) from public,anon;
grant execute on function api.registration_preferences_snapshot(text) to authenticated;

do $$ begin
  if to_regprocedure('app_private.participant_context_before_start_ops(text)') is null then
    alter function api.participant_context(text) set schema app_private;
    alter function app_private.participant_context(text) rename to participant_context_before_start_ops;
  end if;
end $$;
revoke all on function app_private.participant_context_before_start_ops(text) from public,anon,authenticated;

create or replace function api.participant_context(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; g uuid; appointment jsonb;
begin
  result:=app_private.participant_context_before_start_ops(_event_slug);
  select (r->>'groupId')::uuid into g from jsonb_array_elements(result->'roles') r
    where r->>'key' in ('walker','viewer') and r->>'groupId' is not null order by case when r->>'key'='walker' then 0 else 1 end limit 1;
  appointment:=app_private.published_start_projection(g);
  if appointment is not null then result:=jsonb_set(result,'{event,startsAt}',appointment->'startsAt',true); end if;
  return result;
end;
$$;
revoke all on function api.participant_context(text) from public,anon;
grant execute on function api.participant_context(text) to authenticated;
