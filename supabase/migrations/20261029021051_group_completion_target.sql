-- Desired end is a majority completion TARGET. The policy is owned by the
-- server and projected into the browser snapshot, never accepted from a proposal.
-- No existing registration, schedule, publication, run or reservation is rewritten.
create or replace function app_private.group_end_overrun_seconds()
returns integer language sql immutable set search_path='' as $$ select 1800 $$;
revoke all on function app_private.group_end_overrun_seconds() from public,anon,authenticated;

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
    or _arrival<greatest(settings.finale_opens_at,_stop+make_interval(secs=>settings.finale_planning_transfer_seconds))
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
revoke all on function app_private.assert_group_schedule_timing(uuid,uuid,timestamptz,timestamptz) from public,anon,authenticated;

-- A published schedule freezes its majority end. Legacy runs keep their existing
-- ordinary cutoff. Historical snapshots also obey the group overrun ceiling
-- on future reservations, without rewriting their published times or runs.
create or replace function app_private.schedule_latest_finale_arrival(_schedule uuid)
returns timestamptz language sql stable security definer set search_path='' as $$
 select least(settings.finale_last_arrival_at,settings.finale_closes_at-make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds),
   (case when s.input_snapshot ? 'dominantEndAt' then (s.input_snapshot->>'dominantEndAt')::timestamptz
      else app_private.dominant_end_preference(array(select distinct a.registration_id from app_private.group_registrations a
        where a.group_id=s.group_id and a.superseded_at is null)) end)
     +make_interval(secs=>app_private.group_end_overrun_seconds()-settings.finale_show_seconds))
 from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
 join app_private.event_route_settings settings on settings.event_id=g.event_id where s.id=_schedule
$$;
revoke all on function app_private.schedule_latest_finale_arrival(uuid) from public,anon,authenticated;


create or replace function app_private.validate_group_schedule_exact_preferences()
returns trigger language plpgsql security definer set search_path = '' as $$
declare starts_at timestamptz; dominant_end timestamptz; dominant_start timestamptz;
  registration_ids uuid[]; settings app_private.event_route_settings; ordinary_limit timestamptz;
begin
  if new.state not in ('draft','published') then return new;end if;
  select slot.starts_at into starts_at from app_private.start_slots slot where slot.id = new.start_slot_id;
  select route_settings.* into settings from app_private.event_route_settings route_settings
    join app_private.start_slots slot on slot.event_id = route_settings.event_id where slot.id = new.start_slot_id;
  select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
    coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at), settings.global_ordinary_stop_at))
    into registration_ids, ordinary_limit
    from app_private.group_registrations a join app_private.registrations r on r.id = a.registration_id
    where a.group_id = new.group_id and a.superseded_at is null and r.status = 'submitted';
  dominant_end := app_private.dominant_end_preference(registration_ids);
  dominant_start := app_private.dominant_start_preference(registration_ids);
  if dominant_end is not null then
    if starts_at >= dominant_end + make_interval(secs=>app_private.group_end_overrun_seconds()) then raise exception 'GROUP_START_NOT_BEFORE_DESIRED_END' using errcode = '23514'; end if;

  end if;
  new.effective_ordinary_stop_at := least(new.effective_ordinary_stop_at, ordinary_limit);
  if new.effective_ordinary_stop_at < starts_at then
    raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode = '23514';
  end if;
  perform app_private.assert_group_schedule_timing(new.group_id,new.start_slot_id,new.effective_ordinary_stop_at,new.expected_finale_arrival_at);
  new.input_snapshot := new.input_snapshot || jsonb_build_object('dominantStartAt',dominant_start,'dominantEndAt',dominant_end,
    'maxGroupOverrunSeconds',app_private.group_end_overrun_seconds(),
    'finaleShowSeconds',settings.finale_show_seconds,'finaleTurnoverSeconds',settings.finale_turnover_seconds,
    'expectedCompletionAt',new.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds),
    'physicalFinaleEndsAt',new.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds),
    'endDeviationMinutes',extract(epoch from new.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds)-dominant_end)/60);
  return new;
end;
$$;

drop trigger group_schedule_exact_preferences_guard on app_private.group_schedule_revisions;
create trigger group_schedule_exact_preferences_guard before insert or update of start_slot_id,group_id,effective_ordinary_stop_at,expected_finale_arrival_at,state,input_snapshot
on app_private.group_schedule_revisions for each row execute function app_private.validate_group_schedule_exact_preferences();

create or replace function api.admin_apply_dynamic_plan(_event_slug text, _proposal jsonb, _input_hash text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  settings app_private.event_route_settings;
  group_item jsonb;
  registration_value jsonb;
  v_group_id uuid;
  v_schedule_id uuid;
  v_start_id uuid;
  v_effective_stop timestamptz;
  v_expected_finale timestamptz;
  v_group_number integer; v_dominant_end timestamptz; v_proposed_stop timestamptz;
  receipt app_private.command_receipts;
  schedule_ids uuid[] := '{}'::uuid[]; canonical_request_hash text; actual_children integer;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id;
  if settings.planner_mode not in ('shadow', 'dynamic') or settings.global_ordinary_stop_at is null or settings.final_portal_id is null then
    raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514';
  end if;
  if length(coalesce(_idempotency_key,'')) not between 8 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode='22023'; end if;
  canonical_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object('proposal',_proposal,'inputHash',_input_hash)::text,'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':admin.applyDynamicPlan:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'admin.applyDynamicPlan' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> canonical_request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if _input_hash is distinct from app_private.start_planning_input_hash(v_event_id) then raise exception 'STALE_PLANNING_INPUT' using errcode='40001'; end if;
  if jsonb_typeof(_proposal -> 'groups') <> 'array' or jsonb_array_length(_proposal -> 'groups') = 0 then
    raise exception 'EMPTY_PLAN' using errcode = '23514';
  end if;
  select coalesce(max(nullif(regexp_replace(code, '[^0-9]', '', 'g'), '')::integer), 0)
  into v_group_number from app_private.walking_groups where event_id = v_event_id;

  for group_item in select value from jsonb_array_elements(_proposal -> 'groups') loop
    v_group_number := v_group_number + 1;
    v_start_id := (group_item ->> 'startId')::uuid;
    if not exists (
      select 1 from app_private.start_slots slot
      join app_private.start_points point on point.id = slot.start_point_id
      where slot.id = v_start_id and slot.event_id = v_event_id and slot.active
        and app_private.start_point_ready_at(point.id,slot.starts_at)
    ) then raise exception 'INVALID_START' using errcode = '23514'; end if;
    if jsonb_typeof(group_item -> 'partyIds') <> 'array' or jsonb_array_length(group_item -> 'partyIds') = 0 then
      raise exception 'INVALID_GROUP' using errcode = '23514';
    end if;
    select least(
      settings.global_ordinary_stop_at,
      coalesce(min(registration.requested_ordinary_stop_at) filter(where registration.requested_ordinary_stop_at is distinct from registration.desired_end_at), settings.global_ordinary_stop_at)
    ) into v_effective_stop
    from app_private.registrations registration
    where registration.id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'));
    v_dominant_end := app_private.dominant_end_preference(array(select value::uuid from jsonb_array_elements_text(group_item->'partyIds')));
    if v_dominant_end is not null then v_effective_stop := least(v_effective_stop,
      v_dominant_end+make_interval(secs=>app_private.group_end_overrun_seconds()-settings.finale_show_seconds-settings.finale_planning_transfer_seconds)); end if;
    v_proposed_stop := nullif(group_item->>'effectiveStopAt','')::timestamptz;
    if v_proposed_stop > v_effective_stop then raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode='23514'; end if;
    v_effective_stop := coalesce(v_proposed_stop,least(v_effective_stop,v_dominant_end-make_interval(secs=>settings.finale_show_seconds+settings.finale_planning_transfer_seconds)));
    v_expected_finale := coalesce(nullif(group_item ->> 'expectedFinaleArrivalAt', '')::timestamptz,
      greatest(settings.finale_opens_at,v_effective_stop+make_interval(secs=>settings.finale_planning_transfer_seconds)));
    if v_effective_stop is null or v_expected_finale < settings.finale_opens_at or v_expected_finale > settings.finale_last_arrival_at then
      raise exception 'FINALE_WINDOW_CONFLICT' using errcode = '23514';
    end if;

    select count(*) into actual_children from app_private.registration_children c
      where c.registration_id in(select value::uuid from jsonb_array_elements_text(group_item->'partyIds')) and c.participation_status='active';
    if actual_children<1 or actual_children is distinct from (group_item->>'childCount')::integer
      or actual_children>app_private.event_group_size_limit(v_event_id) then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514'; end if;
    -- Unpaid is an operational warning; financial status is preserved.

    insert into app_private.walking_groups(event_id, code, status, start_slot_id, route_mode)
    values (v_event_id, 'D-' || to_char(v_group_number, 'FM000'), 'draft', v_start_id, 'dynamic')
    returning id into v_group_id;
    for registration_value in select value from jsonb_array_elements(group_item -> 'partyIds') loop
      if not exists (
        select 1 from app_private.registrations registration
        where registration.id = (registration_value #>> '{}')::uuid and registration.event_id = v_event_id and registration.status = 'submitted'
      ) or exists (
        select 1 from app_private.group_registrations assignment
        where assignment.registration_id = (registration_value #>> '{}')::uuid and assignment.superseded_at is null
      ) then raise exception 'INVALID_REGISTRATION' using errcode = '23514'; end if;
      insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
      values (v_group_id, (registration_value #>> '{}')::uuid, 1);
    end loop;

    if exists (
      select 1 from app_private.together_memberships selected_membership
      where selected_membership.registration_id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'))
        and selected_membership.left_at is null
        and exists (
          select 1 from app_private.together_memberships sibling
          join app_private.registrations sibling_registration on sibling_registration.id = sibling.registration_id
          where sibling.party_id = selected_membership.party_id and sibling.left_at is null
            and sibling_registration.event_id = v_event_id and sibling_registration.status = 'submitted'
            and not (sibling.registration_id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds')))
            and not exists (
              select 1 from app_private.group_registrations assigned
              where assigned.registration_id = sibling.registration_id and assigned.superseded_at is null
            )
        )
    ) then raise exception 'TOGETHER_PARTY_SPLIT' using errcode = '23514'; end if;

    insert into app_private.group_schedule_revisions(
      group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
      expected_finale_arrival_at, preference_match, input_snapshot, warnings, created_by
    ) values (
      v_group_id, 1, 'draft', v_start_id, v_effective_stop, v_expected_finale,
      coalesce(group_item ->> 'preferenceMatch', 'neutral'), group_item,
      coalesce(group_item -> 'warnings', '[]'::jsonb), actor
    ) returning id into v_schedule_id;
    update app_private.walking_groups set current_schedule_revision_id = v_schedule_id, version = version + 1 where id = v_group_id;
    schedule_ids := array_append(schedule_ids, v_schedule_id);
  end loop;
  perform app_private.validate_start_schedule_capacity(v_event_id,schedule_ids);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.proposal_saved', 'group_schedule_batch',
    jsonb_build_object('inputHash', _input_hash, 'groupCount', cardinality(schedule_ids)));
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'admin.applyDynamicPlan', _idempotency_key, canonical_request_hash,
    jsonb_build_object('scheduleIds', schedule_ids, 'groupCount', cardinality(schedule_ids), 'published', false),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$
;

create or replace function api.admin_group_operations_apply(_event_slug text,_action text,_input_hash text,_payload jsonb,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e app_private.events; g app_private.walking_groups; settings app_private.event_route_settings;
  item jsonb; slot app_private.start_slots; registration_ids uuid[]; seen uuid[] := '{}'::uuid[];
  schedule_ids uuid[] := '{}'::uuid[]; receipt app_private.command_receipts; request_hash text; result jsonb;
  created jsonb; dominant_start timestamptz; dominant_end timestamptz;
  ordinary_limit timestamptz; effective_stop timestamptz; finale_arrival timestamptz; child_count integer;
  previous_schedules jsonb := '{}'::jsonb; previous_schedule app_private.group_schedule_revisions;
begin
  if _action is distinct from 'distribute' then
    return app_private.group_operations_apply_before_departure_slots(_event_slug,_action,_input_hash,_payload,_idempotency_key);
  end if;
  select * into e from app_private.events where slug = _event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text || ':route-dispatch',0));
  if length(coalesce(_idempotency_key,'')) not between 16 and 200
    or jsonb_typeof(_payload->'groups') is distinct from 'array'
    or jsonb_array_length(_payload->'groups') not between 1 and 500 then
    raise exception 'INVALID_PLAN' using errcode = '22023'; end if;
  request_hash := encode(extensions.digest(jsonb_build_object('event',e.id,'action',_action,'inputHash',_input_hash,'payload',_payload)::text,'sha256'),'hex');
  select * into receipt from app_private.command_receipts
    where actor_id = auth.uid() and command_type = 'groups.distribute' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if _input_hash is distinct from app_private.group_operations_hash(e.id) then
    raise exception 'STALE_GROUP_INPUT' using errcode = '40001'; end if;
  select * into settings from app_private.event_route_settings where event_id = e.id;
  perform 1 from app_private.walking_groups where event_id = e.id order by id for update;
  -- Validate the entire movable cohort before releasing its old draft-only
  -- reservations. This permits atomic swaps/cycles; publications never leave
  -- the occupancy set and rollback restores every old pointer on any conflict.
  for item in select * from jsonb_array_elements(_payload->'groups') loop
    select * into g from app_private.walking_groups where id = (item->>'key')::uuid and event_id = e.id and retired_at is null;
    if g.id is null or g.id = any(seen) or g.status not in ('draft','ready')
      or exists(select 1 from app_private.group_runs r where r.group_id = g.id)
      or exists(select 1 from app_private.group_schedule_revisions current_schedule
        where current_schedule.id = g.current_schedule_revision_id
          and (current_schedule.confirmed_at is not null or current_schedule.state = 'published'))
      or exists(select 1 from app_private.current_start_publication(g.id)) then
      raise exception 'START_APPOINTMENT_PROTECTED' using errcode = '23514'; end if;
    select * into previous_schedule from app_private.group_schedule_revisions where id = g.current_schedule_revision_id;
    previous_schedules := previous_schedules || jsonb_build_object(g.id::text,
      jsonb_build_object('id',previous_schedule.id,'revision',previous_schedule.revision));
    seen := array_append(seen,g.id);
  end loop;
  update app_private.walking_groups set current_schedule_revision_id = null where id = any(seen);
  seen := '{}';
  for item in select * from jsonb_array_elements(_payload->'groups') loop
    select * into g from app_private.walking_groups where id = (item->>'key')::uuid and event_id = e.id and retired_at is null;
    if g.id is null or g.id = any(seen) or g.status not in ('draft','ready')
      or exists(select 1 from app_private.group_runs r where r.group_id = g.id)
      or exists(select 1 from app_private.group_schedule_revisions s where s.id = g.current_schedule_revision_id
        and (s.confirmed_at is not null or s.state = 'published'))
      or exists(select 1 from app_private.current_start_publication(g.id)) then
      raise exception 'START_APPOINTMENT_PROTECTED' using errcode = '23514'; end if;
    select * into slot from app_private.start_slots where id = (item->>'startId')::uuid and event_id = e.id and active;
    if slot.id is null or not app_private.departure_time_in_window(e.id,slot.starts_at)
      or not app_private.start_point_ready_at(slot.start_point_id,slot.starts_at) then
      raise exception 'INVALID_START' using errcode = '23514'; end if;
    select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
      coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at),settings.global_ordinary_stop_at))
      into registration_ids, ordinary_limit
      from app_private.group_registrations a join app_private.registrations r on r.id = a.registration_id and r.status = 'submitted'
      where a.group_id = g.id and a.superseded_at is null;
    select count(*) into child_count from app_private.registration_children c
      where c.registration_id = any(registration_ids) and c.participation_status = 'active';
    if child_count < 1 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
    dominant_start := app_private.dominant_start_preference(registration_ids);
    dominant_end := app_private.dominant_end_preference(registration_ids);
    if dominant_end is not null then ordinary_limit := least(ordinary_limit,
      dominant_end + make_interval(secs => app_private.group_end_overrun_seconds()-settings.finale_show_seconds-settings.finale_planning_transfer_seconds)); end if;
    effective_stop := coalesce(nullif(item->>'effectiveStopAt','')::timestamptz,least(ordinary_limit,dominant_end-make_interval(secs=>settings.finale_show_seconds+settings.finale_planning_transfer_seconds)));
    finale_arrival := nullif(item->>'expectedFinaleArrivalAt','')::timestamptz;
    if effective_stop > ordinary_limit or effective_stop < slot.starts_at then
      raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode = '23514'; end if;
    created := api.admin_save_group_schedule(g.id,slot.id,effective_stop,finale_arrival,null,
      coalesce(item->>'preferenceMatch','neutral'),'Automatische slotverdeling na actuele preview');
    update app_private.group_schedule_revisions set supersedes_id = (previous_schedules->g.id::text->>'id')::uuid,
      input_snapshot = input_snapshot || item
      || jsonb_build_object('previousRevision',previous_schedules->g.id::text->'revision',
        'dominantStartAt',dominant_start,'dominantEndAt',dominant_end,
        'effectiveStopAt',effective_stop,'expectedFinaleArrivalAt',finale_arrival)
      where id = (created->>'id')::uuid;
    schedule_ids := array_append(schedule_ids,(created->>'id')::uuid);
    seen := array_append(seen,g.id);
  end loop;
  perform app_private.validate_start_schedule_capacity(e.id,schedule_ids);
  result := jsonb_build_object('plannedGroups',cardinality(schedule_ids),'scheduleIds',schedule_ids);
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
    values(e.id,auth.uid(),'groups.distribute','group_operations',jsonb_build_object('inputHash',_input_hash,'result',result));
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'groups.distribute',_idempotency_key,request_hash,result,now() + interval '7 days');
  perform realtime.send(jsonb_build_object('resource','group_composition'),'snapshot_changed','admin-event:' || e.id,true);
  return result;
end;
$$;

create or replace function api.admin_startregie_move_group(_group_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _expected_group_version integer, _preference_match text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); group_record app_private.walking_groups; point_record app_private.start_points;
  settings app_private.event_route_settings; portal_record app_private.portals; slot_record app_private.start_slots;
  schedule_record app_private.group_schedule_revisions; result jsonb; group_children integer; occupied_groups integer; occupied_children integer; registration_ids uuid[]; dominant_end timestamptz; effective_stop timestamptz; finale_arrival timestamptz;
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
  if not (app_private.start_point_location(point_record.id)->>'valid')::boolean then
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
  select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
    coalesce(schedule_record.effective_ordinary_stop_at,settings.global_ordinary_stop_at),
    coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at),settings.global_ordinary_stop_at))
    into registration_ids,effective_stop from app_private.group_registrations a
    join app_private.registrations r on r.id=a.registration_id and r.status='submitted'
    where a.group_id=group_record.id and a.superseded_at is null;
  dominant_end := app_private.dominant_end_preference(registration_ids);
  if dominant_end is not null and schedule_record.id is null then effective_stop := least(effective_stop,
    dominant_end-make_interval(secs=>settings.finale_show_seconds+settings.finale_planning_transfer_seconds)); end if;
  finale_arrival := coalesce(schedule_record.expected_finale_arrival_at,
    greatest(settings.finale_opens_at,effective_stop+make_interval(secs=>settings.finale_planning_transfer_seconds)));
  result := api.admin_save_group_schedule(
    group_record.id, slot_record.id, effective_stop, finale_arrival,
    schedule_record.queue_number, _preference_match, _reason
  );
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'groupId', group_record.id),
    'snapshot_changed', 'admin-event:' || group_record.event_id::text, true);
  return result || jsonb_build_object('previousStartSlotId', schedule_record.start_slot_id,
    'startPointId', point_record.id, 'startsAt', slot_record.starts_at);
end;
$function$;

create or replace function app_private.validate_start_schedule_capacity(_event_id uuid, _schedule_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; settings app_private.event_route_settings; tick timestamptz; service_interval interval;
  load_groups integer; load_children bigint;
begin
  perform 1 from app_private.events where id=_event_id for update;
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
    perform app_private.assert_group_schedule_timing(candidate.group_id,candidate.start_slot_id,candidate.effective_ordinary_stop_at,candidate.expected_finale_arrival_at);
    if not app_private.valid_departure_time(candidate.starts_at) then
      raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode='23514'; end if;
    if not app_private.departure_time_in_window(_event_id,candidate.starts_at) then
      raise exception 'START_TIME_OUTSIDE_EVENT' using errcode='23514'; end if;
    if not app_private.start_point_ready_at(candidate.start_point_id,candidate.starts_at) then
      raise exception 'START_POINT_CLOSED' using errcode='23514'; end if;
    -- Coalesce aliases linked to the same real portal. Different slot IDs and
    -- start-point IDs never create a second departure at the same instant.
    select count(*) into load_groups from (
      select distinct r.group_id from app_private.start_schedule_reservations(_event_id) r
      where app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id)=app_private.reserved_departure_key(candidate.group_id,candidate.id,candidate.start_point_id)
        and r.starts_at=candidate.starts_at
      union select candidate.group_id
    ) physical_departures;
    if load_groups>1 then raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
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
    for tick in select distinct r.starts_at from app_private.finale_occupancy_intervals(_event_id,statement_timestamp()) r
      where r.starts_at<candidate.expected_finale_arrival_at+service_interval and r.ends_at>candidate.expected_finale_arrival_at
      union select candidate.expected_finale_arrival_at
    loop
      select count(*),coalesce(sum(n),0) into load_groups,load_children from (
        select r.group_id,max(r.children) n from app_private.finale_occupancy_intervals(_event_id,statement_timestamp()) r
        where r.starts_at<=tick and r.ends_at>tick group by r.group_id) q;
      if load_groups>settings.finale_max_concurrent_groups or load_children>settings.finale_max_concurrent_children
        or not exists(select 1 from app_private.portal_windows w where w.portal_id=settings.final_portal_id
          and candidate.expected_finale_arrival_at>=w.opens_at and candidate.expected_finale_arrival_at+service_interval<=w.closes_at
          and load_groups<=w.max_concurrent_groups and load_children<=w.max_children_total
          and (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null)<=w.max_children_per_visit) then
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

create or replace function app_private.copy_registration_exact_preferences_from_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft jsonb;
  preferred_start timestamptz;
  desired_end timestamptz;
begin
  select payload into draft from app_private.registration_drafts
  where event_id = new.event_id and household_id = new.household_id;
  if nullif(trim(coalesce(draft ->> 'desiredEndAt', '')), '') is null then return new; end if;
  begin
    desired_end := (draft ->> 'desiredEndAt')::timestamptz;
    preferred_start := case when nullif(trim(coalesce(draft ->> 'preferredStartAt', '')), '') is null
      then null else (draft ->> 'preferredStartAt')::timestamptz end;
  exception when others then
    raise exception 'INVALID_EXACT_PREFERENCES' using errcode = '22023';
  end;
  perform app_private.validate_exact_preferences(new.event_id, preferred_start, desired_end);
  new.preferred_start_at := preferred_start;
  new.desired_end_at := desired_end;
  -- An explicit ordinary-stop draft is handled by its separate existing trigger.
  -- Do not derive a hard cutoff from a desired completion.
  return new;
end;
$$;

create or replace function api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'maxGroupOverrunSeconds',app_private.group_end_overrun_seconds(),
    'finaleWindows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',w.opens_at,'closesAt',w.closes_at,
      'maxGroups',w.max_concurrent_groups,'maxChildren',w.max_children_per_visit,'maxTotalChildren',w.max_children_total) order by w.opens_at)
      from app_private.portal_windows w join app_private.event_route_settings s on s.final_portal_id=w.portal_id where s.event_id=e.id),'[]'::jsonb),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'readiness',app_private.start_point_readiness(p.id),
    'confirmed',app_private.start_point_readiness(p.id)->'confirmed',
    'latitude',app_private.start_point_location(p.id)->'latitude','longitude',app_private.start_point_location(p.id)->'longitude',
    'locationSource',app_private.start_point_location(p.id)->'source',
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'location',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude),
    'latitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'latitude',
    'longitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'longitude',
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item left join app_private.portal_private_locations l on l.portal_id=(item->>'id')::uuid),'[]'::jsonb),true);
  -- Replace only the obsolete marker test. Unassigned groups, capacity and
  -- publication checks remain independent and unchanged.
  base:=jsonb_set(base,'{warnings}',coalesce((select jsonb_agg(w) from jsonb_array_elements(base->'warnings') w
    where w->>'code' not in ('MISSING_MARKER','WALKING_ROUTE_MISSING')),'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object(
      'code','MISSING_MARKER','resourceId',p.id,'resourceType','start_point','action','kaart',
      'message',p.public_label||' — '||case r->>'confirmationReason'
        when 'START_POINT_POSITION_MISSING' then 'Geen opgeslagen positie — plaats een marker.'
        when 'START_POINT_POSITION_INVALID' then 'Ongeldige positie — controleer de coördinaten en sla opnieuw op.'
        when 'START_POINT_ADDRESS_MISSING' then 'Adres ontbreekt — vul het adres van deze startlocatie in.'
        when 'LINKED_PORTAL_NOT_AVAILABLE' then 'Gekoppelde poort niet beschikbaar — controleer deze poort.'
        when 'LINKED_START_PORTAL_POSITION_INVALID' then 'De gekoppelde eerste poort '||coalesce(r->>'linkedPortalName','')||' heeft geen geldig adres en positie — controleer deze poort.'
        else 'Controleer het opgeslagen adres en de marker van deze startlocatie.' end) order by p.name)
      from app_private.start_points p cross join lateral(select app_private.start_point_readiness(p.id) r) c
      where p.event_id=e.id and p.active and not (r->>'canConfirm')::boolean), '[]'::jsonb),true);
  base:=jsonb_set(base,'{stats,missingMarkers}',to_jsonb((select count(*) from app_private.start_points p
    where p.event_id=e.id and p.active and not (app_private.start_point_location(p.id)->>'valid')::boolean)),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,
      'appointmentProtected',s.confirmed_at is not null or pub.publication_order is not null,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.current_start_publication(g.id)) pub on true
    where g.event_id=e.id and g.retired_at is null;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and g.retired_at is null and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'startPointId',app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id),
    'startsAt',r.starts_at,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  reservations:=reservations||coalesce((select jsonb_agg(jsonb_build_object(
    'id','live:'||reservation.id,'groupId',reservation.group_id,'startId',schedule.start_slot_id,
    'startPointId',app_private.reserved_departure_key(reservation.group_id,schedule.id,slot.start_point_id),
    'startsAt',coalesce(publication.starts_at,slot.starts_at),'childCount',reservation.child_count,
    'expectedFinaleArrivalAt',reservation.reserved_from,'finaleEndsAt',reservation.reserved_until,
    'partyIds',coalesce((select jsonb_agg(a.registration_id) from app_private.group_registrations a where a.group_id=reservation.group_id and a.superseded_at is null),'[]'::jsonb)))
    from app_private.portal_reservations reservation join app_private.group_runs run on run.id=reservation.run_id
    join app_private.group_schedule_revisions schedule on schedule.id=run.schedule_revision_id
    join app_private.start_slots slot on slot.id=schedule.start_slot_id
    left join lateral(select * from app_private.current_start_publication(reservation.group_id) p where p.schedule_id=schedule.id) publication on true
    where reservation.event_id=e.id and reservation.kind='finale' and reservation.status in ('held','active','completed')
      and reservation.reserved_until>statement_timestamp() and (reservation.expires_at is null or reservation.expires_at>statement_timestamp() or reservation.status='completed')),'[]'::jsonb);
  base:=jsonb_set(base,'{groups}',coalesce((select jsonb_agg(item) from jsonb_array_elements(base->'groups') item join app_private.walking_groups g on g.id=(item->>'id')::uuid where g.retired_at is null),'[]'));
  base:=jsonb_set(base,'{groups}',coalesce((select jsonb_agg(case when item->'schedule' is null or item->'schedule'='null'::jsonb then item else
    jsonb_set(item,'{schedule}',item->'schedule'||jsonb_build_object(
      'expectedCompletionAt',(item#>>'{schedule,expectedFinaleArrivalAt}')::timestamptz+make_interval(secs=>coalesce((s.input_snapshot->>'finaleShowSeconds')::integer,settings.finale_show_seconds)),
      'endDeviationMinutes',extract(epoch from (item#>>'{schedule,expectedFinaleArrivalAt}')::timestamptz+make_interval(secs=>coalesce((s.input_snapshot->>'finaleShowSeconds')::integer,settings.finale_show_seconds))
        -(s.input_snapshot->>'dominantEndAt')::timestamptz)/60)) end)
    from jsonb_array_elements(base->'groups') item left join app_private.group_schedule_revisions s on s.id=(item#>>'{schedule,id}')::uuid
    join app_private.event_route_settings settings on settings.event_id=e.id),'[]'::jsonb));
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;

create or replace function app_private.start_ops_route_preview(_group_id uuid)
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
    select * into s from app_private.group_schedule_revisions where id=r.schedule_revision_id;
    at_time:=greatest(at_time,statement_timestamp());
    select coalesce(array_agg(coalesce(rs.portal_id,ps.portal_id)),array[]::uuid[]),
      count(*) filter(where coalesce(rs.stop_kind::text,'ordinary')='ordinary' and rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=rs.id))
    into chosen,visited from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
    where rs.run_id=r.id and rs.state='completed';
    select coalesce(rs.portal_id,ps.portal_id) into preserved_portal from app_private.run_stops rs
      left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=r.current_stop_id;
    select (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'longitude')::numeric,
      (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'latitude')::numeric into last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    last_lon:=coalesce(last_lon,(app_private.start_point_location(point.id)->>'longitude')::numeric);
    last_lat:=coalesce(last_lat,(app_private.start_point_location(point.id)->>'latitude')::numeric);
  end if;
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
      where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen))
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
        and (p.id=preserved_portal or not step_free or exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free'))
        and (preserved_portal is null or p.id=preserved_portal)
        and (preserved_portal is not null or fixed_portal is null or p.id=fixed_portal)
    ) q where q.walk_s is not null and (q.id=preserved_portal or (
      at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds))::integer)<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and q.final_seconds is not null
      and at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds)+q.final_seconds)::integer)<=app_private.schedule_latest_finale_arrival(s.id)
      and exists(select 1 from app_private.portal_windows win where win.portal_id=q.id
        and at_time+make_interval(secs=>q.walk_s::integer)>=win.opens_at
        and at_time+make_interval(secs=>q.walk_s::integer)<win.closes_at
        and at_time+make_interval(secs=>(q.walk_s+win.visit_minutes*60+win.buffer_minutes*60)::integer)<=win.closes_at
        and win.max_children_per_visit>=child_count)))
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
    meters:=meters+walk_m; seconds:=seconds+walk_s+coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds);
    at_time:=at_time+make_interval(secs=>coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds));
    last_lon:=coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude);
    last_lat:=coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude);
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null and app_private.portal_location_ready(candidate.id) and candidate.duration_seconds is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude),coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude))))::bigint;
    walk_s:=candidate.duration_seconds;
    provisional:=true;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','finale',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'expectedCompletionAt',at_time+make_interval(secs=>settings.finale_show_seconds),'physicalEndsAt',at_time+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds),'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>app_private.schedule_latest_finale_arrival(s.id) or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('De eindpoort heeft geen geldig opgeslagen adres of marker — controleer de eindpoort.'); end if;
  if provisional then warnings:=warnings||jsonb_build_array('Afstanden zijn hemelsbreed; reistijden zijn schattingen. Kies zelf hoe je naar de volgende poort gaat.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      (app_private.start_point_location(point.id)->>'longitude')::numeric,(app_private.start_point_location(point.id)->>'latitude')::numeric),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'distanceMethod','straight_line','travelTimeEstimated',true,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$;

create or replace function app_private.dispatch_next_stop_before_visit_preference(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
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
        and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= app_private.schedule_latest_finale_arrival(schedule.id)
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
      and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= app_private.schedule_latest_finale_arrival(schedule.id);
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

create or replace function app_private.live_planboard_warnings(_event uuid,_changes jsonb default '[]') returns jsonb
language sql stable security definer set search_path='' as $$
 with data as (
  select item||coalesce((select change from jsonb_array_elements(_changes) change where change->>'id'=item->>'id'),'{}'::jsonb) item
  from jsonb_array_elements(app_private.live_planboard_visits(_event)) item
 ), v as (
  select (item->>'id')::uuid id,(item->>'groupId')::uuid group_id,(item->>'portalId')::uuid portal_id,(item->>'sequence')::integer sequence,
  (item->>'startsAt')::timestamptz starts_at,(item->>'durationSeconds')::integer duration,(item->>'bufferSeconds')::integer buffer,
  (item->>'startsAt')::timestamptz+make_interval(secs=>(item->>'durationSeconds')::integer+(item->>'bufferSeconds')::integer) ends_at,
  item->>'kind' kind,item->>'status' status,
  (case when exists(select 1 from app_private.group_runs r where r.group_id=(item->>'groupId')::uuid and r.status in ('live','paused')) then (select count(*) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id where r.group_id=(item->>'groupId')::uuid and r.status in ('live','paused') and rp.attendance='present' and rp.departed_at is null) else (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=(item->>'groupId')::uuid and a.superseded_at is null) end)::integer children
  from data
 ), occupancy as (
  select portal_id,group_id,starts_at,ends_at,children from v where status not in ('completed','skipped')
  union all select portal_id,group_id,reserved_from,reserved_until,child_count from app_private.portal_reservations where event_id=_event and status in ('active','held','completed')
  union all select (pub.point_snapshot->>'linked_portal_id')::uuid,pub.group_id,pub.starts_at,pub.starts_at+make_interval(secs=>coalesce(app_private.portal_service_seconds((pub.point_snapshot->>'linked_portal_id')::uuid,pub.starts_at),300)),
   (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=pub.group_id and a.superseded_at is null)::integer
  from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub where g.event_id=_event and pub.point_snapshot->>'linked_portal_id' is not null
 ), notices as (
  select 'PORTAL_UNAVAILABLE' code,'block' severity,'Poort is niet actief, goedgekeurd of operationeel beschikbaar.' message,array[v.id] visits,array[v.group_id] groups
  from v join app_private.portals p on p.id=v.portal_id where v.status='planned' and (p.lifecycle_status<>'active' or p.approval_status<>'approved' or p.operation_status in ('paused','closed'))
  union all
  select 'OPENING_WINDOW','block','Bezoek en buffer passen niet binnen één openingsvenster.',array[v.id],array[v.group_id] from v where v.status='planned' and not exists(select 1 from app_private.portal_windows w where w.portal_id=v.portal_id and v.starts_at>=w.opens_at and v.ends_at<=w.closes_at and (v.kind='finale' or (v.duration>=w.visit_minutes*60 and v.buffer>=w.buffer_minutes*60)) and w.max_children_per_visit>=v.children)
  union all
  select 'LOCATION_MISSING','block','Poort heeft geen bruikbare locatie voor de route-engine.',array[v.id],array[v.group_id] from v where v.status='planned' and not app_private.portal_location_ready(v.portal_id)
  union all
  select 'ORDINARY_STOP_LIMIT','block','Gewone poort valt na de afgesproken stoptijd.',array[v.id],array[v.group_id]
  from v join app_private.walking_groups g on g.id=v.group_id join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
  where v.status='planned' and v.kind<>'finale' and v.ends_at>s.effective_ordinary_stop_at
  union all
  select 'HOUSEHOLD_STOP_LIMIT','block','Bezoek valt na de stoptijd van inschrijving '||r.reference||'.',array[v.id],array[v.group_id]
  from v join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.kind<>'finale' and r.requested_ordinary_stop_at is not null and r.requested_ordinary_stop_at is distinct from r.desired_end_at and v.ends_at>r.requested_ordinary_stop_at
  union all
  select 'START_PREFERENCE','warning','Afwijking van de gewenste starttijd van '||r.reference||'.',array[v.id],array[v.group_id]
  from v join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.sequence=1 and r.preferred_start_at is not null and abs(extract(epoch from v.starts_at-r.preferred_start_at))>600
  union all
  select 'GROUP_OVERLAP','block','Twee bezoeken van dezelfde groep overlappen.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.id<b.id and a.kind<>'start' and b.kind<>'start' and a.starts_at<b.ends_at and b.starts_at<a.ends_at
  union all
  select 'DUPLICATE_PORTAL','block','Dezelfde poort staat meermaals in deze groepsroute.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.portal_id=b.portal_id and a.id<b.id
  union all
  select 'TRAVEL_TIME','block','Onvoldoende reistijd en buffer tussen opeenvolgende poorten (schatting van de route-engine).',array[a.id,b.id],array[a.group_id]
  from v a join v b on b.group_id=a.group_id and b.sequence=(select min(c.sequence) from v c where c.group_id=a.group_id and c.sequence>a.sequence)
  left join lateral app_private.destination_estimate((app_private.portal_location(a.portal_id)->>'latitude')::numeric,(app_private.portal_location(a.portal_id)->>'longitude')::numeric,(app_private.portal_location(b.portal_id)->>'latitude')::numeric,(app_private.portal_location(b.portal_id)->>'longitude')::numeric) travel on true
  where b.status='planned' and (travel.duration_seconds is null or b.starts_at<(case when a.kind='start' then a.starts_at else a.ends_at end)+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'PORTAL_CAPACITY','block','Gelijktijdige groepscapaciteit is overschreden.',
   array(select x.id from v x where x.portal_id=v.portal_id and x.starts_at< v.ends_at and x.ends_at>v.starts_at),
   array(select distinct x.group_id from occupancy x where x.portal_id=v.portal_id and x.starts_at<v.ends_at and x.ends_at>v.starts_at)
  from v where v.status='planned' and exists(
   select 1 from occupancy edge join app_private.portal_windows w on w.portal_id=v.portal_id and edge.starts_at>=w.opens_at and edge.starts_at<w.closes_at
   where edge.portal_id=v.portal_id and edge.starts_at>=v.starts_at and edge.starts_at<v.ends_at
   and (select count(distinct o.group_id) from occupancy o where o.portal_id=v.portal_id and o.starts_at<=edge.starts_at and o.ends_at>edge.starts_at)>w.max_concurrent_groups)
  union all
  select 'RECEPTION_POLICY','block','De ontvangst past niet binnen de actuele reserveringen of totale kindlimiet.',array[v.id],array[v.group_id]
  from v where v.status='planned' and not app_private.portal_interval_available(v.portal_id,v.group_id,v.starts_at,v.ends_at,v.children,statement_timestamp())
  union all
  select 'GROUP_END_TIME_INFEASIBLE','block','De finale is niet binnen de maximale groepsuitloop afgerond.',array[v.id],array[v.group_id]
  from v join app_private.walking_groups g on g.id=v.group_id
  join app_private.group_schedule_revisions s on s.id=coalesce((select r.schedule_revision_id from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc limit 1),g.current_schedule_revision_id)
  where v.kind='finale' and v.status='planned' and v.starts_at>app_private.schedule_latest_finale_arrival(s.id)
  union all
  select 'FINALE_WINDOW','block','De finale valt buiten het eigen finalevenster.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings s on s.event_id=_event where v.kind='finale' and v.status='planned' and (v.portal_id<>s.final_portal_id or not s.finale_available or v.starts_at<s.finale_opens_at or v.starts_at>s.finale_last_arrival_at or v.ends_at>s.finale_closes_at)
  union all
  select 'EVENING_OVERFLOW','warning','Dit bezoek loopt door na de ingestelde definitieve finalesluiting.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings settings on settings.event_id=_event where v.ends_at>settings.finale_closes_at
 )
 select coalesce(jsonb_agg(jsonb_build_object('code',code,'severity',severity,'message',message,'visitIds',visits,'groupIds',groups)),'[]'::jsonb) from (select distinct code,severity,message,visits,groups from notices) dedup
$$;

create or replace function app_private.finale_occupancy_intervals(_event uuid,_at timestamptz)
returns table(group_id uuid,starts_at timestamptz,ends_at timestamptz,children integer)
language sql stable security definer set search_path='' as $$
 select r.group_id,r.finale_at,r.finale_at+make_interval(secs=>s.finale_show_seconds+s.finale_turnover_seconds),r.child_count
 from app_private.start_schedule_reservations(_event) r join app_private.event_route_settings s on s.event_id=_event
 union all
 select r.group_id,r.reserved_from,r.reserved_until,r.child_count from app_private.portal_reservations r
 join app_private.event_route_settings s on s.event_id=r.event_id and s.final_portal_id=r.portal_id
 where r.event_id=_event and r.kind='finale' and r.status in ('held','active','completed')
   and (r.expires_at is null or r.expires_at>_at or r.status='completed')
$$;
revoke all on function app_private.finale_occupancy_intervals(uuid,timestamptz) from public,anon,authenticated;

create or replace function app_private.try_reserve_finale(_run_id uuid,_earliest_arrival timestamptz,_decision_at timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; g app_private.walking_groups; settings app_private.event_route_settings;
  v_child_count integer; candidate_time timestamptz; candidate_end timestamptz; deadline timestamptz;
  tick timestamptz; groups_at integer; children_at integer; fits boolean; reservation_id uuid; physical app_private.portal_windows;
begin
 select * into r from app_private.group_runs where id=_run_id for update;
 select * into g from app_private.walking_groups where id=r.group_id;
 perform 1 from app_private.events where id=g.event_id for update;
 perform pg_advisory_xact_lock(hashtextextended(g.event_id::text||':route-dispatch',0));
 select * into settings from app_private.event_route_settings where event_id=g.event_id;
 if r.id is null or settings.final_portal_id is null or not settings.finale_available then return null;end if;
 select count(*) into v_child_count from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
 if v_child_count=0 or v_child_count>settings.finale_max_concurrent_children then return null;end if;
 deadline:=app_private.schedule_latest_finale_arrival(r.schedule_revision_id);
 for candidate_time in
  select distinct t from (
   select greatest(settings.finale_opens_at,_earliest_arrival) t
   union all select q.ends_at from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q where q.group_id<>g.id
   union all select w.opens_at from app_private.portal_windows w where w.portal_id=settings.final_portal_id
  ) candidates where t>=greatest(settings.finale_opens_at,_earliest_arrival) and t<=deadline order by t
 loop
  candidate_end:=candidate_time+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  fits:=false;
  for physical in select * from app_private.portal_windows w where w.portal_id=settings.final_portal_id
    and candidate_time>=w.opens_at and candidate_end<=w.closes_at and v_child_count<=w.max_children_per_visit
  loop
   fits:=true;
   for tick in select candidate_time union select q.starts_at from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q
    where q.group_id<>g.id and q.starts_at>candidate_time and q.starts_at<candidate_end
   loop
    select count(*),coalesce(sum(n),0) into groups_at,children_at from (
     select q.group_id,max(q.children) n from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q
     where q.group_id<>g.id and q.starts_at<=tick and q.ends_at>tick group by q.group_id
    ) occupied;
    if groups_at+1>least(settings.finale_max_concurrent_groups,physical.max_concurrent_groups)
      or children_at+v_child_count>least(settings.finale_max_concurrent_children,physical.max_children_total) then fits:=false;exit;end if;
   end loop;
   exit when fits;
  end loop;
  if not fits then continue;end if;
  select id into reservation_id from app_private.portal_reservations where run_id=r.id and kind='finale' and status in ('held','active')
    and reserved_from=candidate_time and reserved_until=candidate_end and portal_id=settings.final_portal_id and portal_reservations.child_count=v_child_count limit 1;
  if reservation_id is not null then return reservation_id;end if;
  update app_private.portal_reservations set status='cancelled',cancelled_reason='Vervangen door actuele finaleprognose',version=version+1
    where run_id=r.id and kind='finale' and status in ('held','active');
  insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
    values(g.event_id,settings.final_portal_id,g.id,r.id,'finale','held',candidate_time,candidate_end,v_child_count,settings.finale_closes_at)
    returning id into reservation_id;
  return reservation_id;
 end loop;
 return null;
end $$;

create or replace function app_private.copy_registration_preferences_from_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft jsonb;
  preference text;
  requested_stop text;
  parsed_stop timestamptz;
  route_settings app_private.event_route_settings;
  has_exact_preferences boolean;
begin
  select payload into draft from app_private.registration_drafts
  where event_id = new.event_id and household_id = new.household_id;
  preference := draft ->> 'startPreference';
  requested_stop := draft ->> 'ordinaryStopAt';
  has_exact_preferences := nullif(trim(coalesce(draft ->> 'desiredEndAt', '')), '') is not null;
  if draft ? 'startPreference' and coalesce(preference, '') not in ('early', 'indifferent', 'later') then
    raise exception 'INVALID_START_PREFERENCE' using errcode = '22023';
  end if;
  if preference in ('early', 'indifferent', 'later') then
    new.start_time_preference := preference::app_private.start_time_preference;
  end if;
  if nullif(trim(requested_stop), '') is not null then
    begin
      parsed_stop := requested_stop::timestamptz;
    exception when others then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end;
    if has_exact_preferences and parsed_stop=(draft->>'desiredEndAt')::timestamptz then return new;end if;
    select * into route_settings from app_private.event_route_settings where event_id = new.event_id;
    if route_settings.global_ordinary_stop_at is null
       or parsed_stop > route_settings.global_ordinary_stop_at
       or not (parsed_stop = any(route_settings.allowed_personal_stop_times)) then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end if;
    new.requested_ordinary_stop_at := parsed_stop;
  end if;
  return new;
end;
$$;

create or replace function api.group_snapshot(_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; schedule app_private.group_schedule_revisions; settings app_private.event_route_settings;
begin
  result:=app_private.group_snapshot_before_start_ops(_group_id);
  select s.* into schedule from app_private.group_schedule_revisions s where s.id=coalesce(
    (select r.schedule_revision_id from app_private.group_runs r where r.group_id=_group_id order by r.created_at desc limit 1),
    (select p.schedule_id from app_private.current_start_publication(_group_id) p)) and s.state='published';
  select rs.* into settings from app_private.event_route_settings rs join app_private.walking_groups g on g.event_id=rs.event_id where g.id=_group_id;
  if schedule.id is not null then result:=jsonb_set(result,'{group,timing}',jsonb_build_object(
    'desiredEndAt',schedule.input_snapshot->'dominantEndAt','ordinaryStopAt',schedule.effective_ordinary_stop_at,
    'expectedFinaleArrivalAt',schedule.expected_finale_arrival_at,
    'expectedCompletionAt',schedule.expected_finale_arrival_at+make_interval(secs=>coalesce((schedule.input_snapshot->>'finaleShowSeconds')::integer,settings.finale_show_seconds)),
    'physicalFinaleEndsAt',schedule.expected_finale_arrival_at+make_interval(secs=>coalesce((schedule.input_snapshot->>'finaleShowSeconds')::integer,settings.finale_show_seconds)+coalesce((schedule.input_snapshot->>'finaleTurnoverSeconds')::integer,settings.finale_turnover_seconds))));end if;
  return jsonb_set(result,'{group,start}',coalesce(app_private.published_start_projection(_group_id),'null'::jsonb),true);
end;
$$;
