-- One order for route-affecting mutations: event row, dispatch mutex, actor/receipt,
-- run/group and then portal/settings. NO KEY UPDATE remains compatible with the
-- FK checks of stock, print and other independent portal actions.
-- Existing command bodies, roles, payments and mail behavior are retained below.
set lock_timeout='5s';
create or replace function app_private.lock_evening_event(_event_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if _event_id is null then return; end if;
 perform 1 from app_private.events where id=_event_id for no key update;
 if not found then return; end if;
 perform pg_advisory_xact_lock(hashtextextended(_event_id::text||':route-dispatch',0));
end $$;
revoke all on function app_private.lock_evening_event(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION api.admin_activate_emergency_closure(_event_slug text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  settings app_private.event_route_settings;
  affected record;
  affected_count integer := 0;
  instruction text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'live_support', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  select * into settings from app_private.event_route_settings where event_id = event_record.id for update;
  if nullif(trim(settings.emergency_destination_name), '') is null
     or nullif(trim(settings.emergency_instructions), '') is null then
    raise exception 'EMERGENCY_PLAN_NOT_CONFIGURED' using errcode = '23514';
  end if;
  instruction := 'Noodafsluiting: ga samen naar ' || settings.emergency_destination_name || '. ' || settings.emergency_instructions;
  update app_private.event_route_settings set finale_available = false, version = version + 1
  where event_id = event_record.id;
  update app_private.portals set operation_status = 'closed', version = version + 1
  where id = settings.final_portal_id and operation_status <> 'closed';

  for affected in
    select run.id as run_id, run.group_id, run.current_stop_id
    from app_private.group_runs run
    join app_private.walking_groups walking_group on walking_group.id = run.group_id
    where walking_group.event_id = event_record.id and walking_group.route_mode = 'dynamic'
      and run.status in ('ready', 'live', 'paused')
    for update of run
  loop
    if affected.current_stop_id is not null then
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Noodafsluiting geactiveerd',
        reason = instruction, changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.current_stop_id and required_for_completion;
      update app_private.run_stops
      set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = instruction, version = version + 1
      where id = affected.current_stop_id and state = 'active';
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      select affected.run_id, stop.id, portal_for_stop.world_id, 'system_skipped'
      from app_private.run_stops stop
      left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal_for_stop on portal_for_stop.id = coalesce(stop.portal_id, plan_stop.portal_id)
      where stop.id = affected.current_stop_id
      on conflict (run_stop_id) do nothing;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.current_stop_id, 'stop.emergency_interrupted', actor,
        jsonb_build_object('reason', instruction));
    end if;
    update app_private.portal_reservations
    set status = 'cancelled', cancelled_reason = 'Noodafsluiting geactiveerd', version = version + 1
    where run_id = affected.run_id and status in ('held', 'active');
    update app_private.group_runs
    set status = 'stopped', current_stop_id = null, stopped_reason = instruction,
      finished_at = clock_timestamp(), version = version + 1
    where id = affected.run_id;
    update app_private.walking_groups set status = 'stopped', version = version + 1 where id = affected.group_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    values (event_record.id, affected.group_id, affected.run_id, settings.final_portal_id,
      'urgent', 'EMERGENCY_CLOSURE', instruction);
    affected_count := affected_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'event.emergency_closure_activated', 'event', event_record.id,
    jsonb_build_object('affectedGroups', affected_count, 'reason', left(trim(_reason), 500),
      'destination', settings.emergency_destination_name));
  return jsonb_build_object('activated', true, 'affectedGroups', affected_count, 'instruction', instruction);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_apply_dynamic_plan(_event_slug text, _proposal jsonb, _input_hash text, _idempotency_key text, _request_hash text)
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
  v_group_number integer;
  receipt app_private.command_receipts;
  schedule_ids uuid[] := '{}'::uuid[]; canonical_request_hash text; actual_children integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
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
      coalesce(min(registration.requested_ordinary_stop_at), settings.global_ordinary_stop_at)
    ) into v_effective_stop
    from app_private.registrations registration
    where registration.id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'));
    v_expected_finale := coalesce(nullif(group_item ->> 'expectedFinaleArrivalAt', '')::timestamptz, v_effective_stop + interval '15 minutes');
    if v_effective_stop is null or v_expected_finale < settings.finale_opens_at or v_expected_finale > settings.finale_last_arrival_at then
      raise exception 'FINALE_WINDOW_CONFLICT' using errcode = '23514';
    end if;

    select count(*) into actual_children from app_private.registration_children c
      where c.registration_id in(select value::uuid from jsonb_array_elements_text(group_item->'partyIds')) and c.participation_status='active';
    if actual_children<1 or actual_children is distinct from (group_item->>'childCount')::integer
      or actual_children>app_private.event_group_size_limit(v_event_id) then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514'; end if;
    if exists(select 1 from app_private.registrations r left join app_private.payment_requests p on p.registration_id=r.id
      where r.id in(select value::uuid from jsonb_array_elements_text(group_item->'partyIds'))
        and coalesce(p.status::text,'') not in ('confirmed','waived')) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode='23514'; end if;
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
$function$;

CREATE OR REPLACE FUNCTION api.admin_apply_plan(_event_slug text, _proposal jsonb, _input_hash text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  group_item jsonb;
  registration_value jsonb;
  portal_value jsonb;
  v_group_id uuid;
  v_plan_id uuid;
  v_start_id uuid;
  group_number integer := 0;
  stop_number integer;
  start_time timestamptz;
  receipt app_private.command_receipts;
  plan_ids uuid[] := '{}'::uuid[];
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'admin.applyPlan' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if jsonb_typeof(_proposal -> 'groups') <> 'array' or jsonb_array_length(_proposal -> 'groups') = 0 then raise exception 'EMPTY_PLAN' using errcode = '23514'; end if;
  for group_item in select value from jsonb_array_elements(_proposal -> 'groups') loop
    group_number := group_number + 1;
    v_start_id := (group_item ->> 'startId')::uuid;
    if not exists (select 1 from app_private.start_slots where id = v_start_id and event_id = v_event_id and active and location_verified_at is not null) then raise exception 'INVALID_START' using errcode = '23514'; end if;
    if jsonb_array_length(group_item -> 'partyIds') = 0 or jsonb_array_length(group_item -> 'portalIds') = 0 then raise exception 'INVALID_GROUP' using errcode = '23514'; end if;
    insert into app_private.walking_groups(event_id, code, status, start_slot_id)
    values (v_event_id, 'G-' || to_char(group_number, 'FM000'), 'draft', v_start_id) returning id into v_group_id;
    for registration_value in select value from jsonb_array_elements(group_item -> 'partyIds') loop
      if not exists (select 1 from app_private.registrations registration where registration.id = (registration_value #>> '{}')::uuid and registration.event_id = v_event_id and registration.status = 'submitted')
         or exists (select 1 from app_private.group_registrations assignment where assignment.registration_id = (registration_value #>> '{}')::uuid and assignment.superseded_at is null) then raise exception 'INVALID_REGISTRATION' using errcode = '23514'; end if;
      insert into app_private.group_registrations(group_id, registration_id, assignment_revision) values (v_group_id, (registration_value #>> '{}')::uuid, 1);
    end loop;
    insert into app_private.route_plan_versions(group_id, revision, state, generated_by, input_hash, score)
    values (v_group_id, 1, 'valid', actor, _input_hash || ':' || group_number, coalesce(group_item -> 'score', '{}'::jsonb)) returning id into v_plan_id;
    plan_ids := array_append(plan_ids, v_plan_id);
    select starts_at into start_time from app_private.start_slots where id = v_start_id;
    stop_number := 0;
    for portal_value in select value from jsonb_array_elements(group_item -> 'portalIds') loop
      stop_number := stop_number + 1;
      if not exists (select 1 from app_private.portals portal join app_private.portal_private_locations location on location.portal_id = portal.id where portal.id = (portal_value #>> '{}')::uuid and portal.event_id = v_event_id and portal.approval_status = 'approved' and location.verified_at is not null) then raise exception 'INVALID_PORTAL' using errcode = '23514'; end if;
      insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
      values (v_plan_id, stop_number, (portal_value #>> '{}')::uuid, start_time + make_interval(mins => (stop_number - 1) * 8), start_time + make_interval(mins => (stop_number - 1) * 8 + 5));
    end loop;
    update app_private.walking_groups set current_plan_version_id = v_plan_id, version = version + 1 where id = v_group_id;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.proposal_saved', 'route_plan_batch', jsonb_build_object('inputHash', _input_hash, 'groupCount', group_number));
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'admin.applyPlan', _idempotency_key, _request_hash, jsonb_build_object('planIds', plan_ids, 'groupCount', group_number, 'published', false), now() + interval '30 days') returning * into receipt;
  return receipt.safe_result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_assign_group_leader(_group_id uuid, _new_leader_user_id uuid, _expected_group_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  next_revision integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (select 1 from auth.users where id = _new_leader_user_id and email_confirmed_at is not null) then raise exception 'LEADER_NOT_AVAILABLE' using errcode = '23514'; end if;
  if exists (select 1 from app_private.group_leaders where group_id = _group_id and user_id = _new_leader_user_id and active_until is null) then
    raise exception 'ALREADY_CURRENT_LEADER' using errcode = '23514';
  end if;
  select coalesce(max(revision), 0) + 1 into next_revision from app_private.group_leaders where group_id = _group_id;
  update app_private.group_leaders set active_until = now() where group_id = _group_id and active_until is null;
  insert into app_private.group_leaders(group_id, user_id, active_from, revision, assigned_by)
  values (_group_id, _new_leader_user_id, now(), next_revision, actor);
  update app_private.walking_groups set version = version + 1 where id = _group_id returning * into group_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.leader_reassigned', 'walking_group', group_record.id, jsonb_build_object('revision', next_revision, 'reason', left(_reason, 500)));
  return jsonb_build_object('groupId', group_record.id, 'groupVersion', group_record.version, 'leaderRevision', next_revision);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_create_plan_revision(_group_id uuid, _portal_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  v_revision integer;
  v_plan_id uuid;
  v_start_time timestamptz;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if coalesce(array_length(_portal_ids, 1), 0) not between 1 and 50
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if group_record.start_slot_id is null then raise exception 'INVALID_START' using errcode = '23514'; end if;

  select coalesce(max(revision), 0) + 1 into v_revision
  from app_private.route_plan_versions where group_id = group_record.id;
  select starts_at into v_start_time from app_private.start_slots where id = group_record.start_slot_id;

  insert into app_private.route_plan_versions(group_id, revision, state, generated_by, supersedes_id, input_hash)
  values (
    group_record.id,
    v_revision,
    'valid',
    actor,
    group_record.current_plan_version_id,
    md5(group_record.id::text || ':' || v_revision::text || ':' || array_to_string(_portal_ids, ','))
  ) returning id into v_plan_id;

  update app_private.walking_groups
  set current_plan_version_id = v_plan_id, version = version + 1
  where id = group_record.id;

  insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
  select v_plan_id, portal.position::integer, portal.id,
    v_start_time + make_interval(mins => (portal.position::integer - 1) * 8),
    v_start_time + make_interval(mins => (portal.position::integer - 1) * 8 + 5)
  from unnest(_portal_ids) with ordinality as portal(id, position)
  order by portal.position;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'route_plan.revision_created', 'route_plan_version', v_plan_id,
    jsonb_build_object('groupId', group_record.id, 'revision', v_revision, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('planId', v_plan_id, 'groupId', group_record.id, 'revision', v_revision, 'published', false);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_decide_registration_change(_case_id uuid, _expected_case_version integer, _decision text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare eid uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_case.event_id from app_private.support_cases evening_case where evening_case.id=_case_id));

 select event_id into eid from app_private.support_cases where id=_case_id;
 if app_private.has_capability(eid,'event_admin') or app_private.has_capability(eid,'registration_manage') then
   perform pg_advisory_xact_lock(hashtextextended('payment-batch:'||eid,0));
 end if;
 return app_private.admin_decide_registration_change_before_child_payments(_case_id,_expected_case_version,_decision,_reason);
end $function$;

CREATE OR REPLACE FUNCTION api.admin_decide_together_request(_request_id uuid, _expected_version integer, _decision text, _override_limit boolean, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  request_record app_private.together_join_requests;
  event_record app_private.events;
  source_children integer;
  target_children integer;
  projected_children integer;
  max_group_size integer;
  membership_record record;
  recorded_change jsonb;
  expected_status text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_request.event_id from app_private.together_join_requests evening_request where evening_request.id=_request_id));

  if _expected_version is null or _expected_version < 1
     or _override_limit is null
     or _decision is null or _decision not in ('accept', 'reject')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  expected_status := case when _decision = 'accept' then 'accepted' else 'rejected' end;

  select * into request_record
  from app_private.together_join_requests
  where id = _request_id;
  if request_record.id is null then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into event_record
  from app_private.events
  where id = request_record.event_id
  for no key update;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  -- Re-read under the event lock; all party-moving commands lock the event first.
  select * into request_record from app_private.together_join_requests where id = _request_id for update;

  -- A retry is idempotent only for the same terminal decision and the version
  -- used by the original call (or the returned terminal version). An opposite
  -- decision and unrelated stale versions keep the optimistic-lock failure.
  if request_record.status in ('accepted', 'rejected') then
    if request_record.status <> expected_status
       or _expected_version not in (request_record.version - 1, request_record.version) then
      raise exception 'STALE_VERSION' using errcode = '40001';
    end if;

    select audit.minimal_change
    into recorded_change
    from app_private.audit_events audit
    where audit.resource_type = 'together_join_request'
      and audit.resource_id = request_record.id
      and audit.action = case
        when request_record.status = 'accepted' then 'together.capacity_request_accepted'
        else 'together.capacity_request_rejected'
      end
    order by audit.created_at desc, audit.id desc
    limit 1;

    projected_children := coalesce(
      (recorded_change ->> 'projectedChildren')::integer,
      case
        when request_record.status = 'accepted'
          then app_private.together_party_child_count(request_record.target_party_id)
        else request_record.child_count_at_request
          + app_private.together_party_child_count(request_record.target_party_id)
      end
    );
    max_group_size := coalesce(
      (recorded_change ->> 'groupLimit')::integer,
      request_record.group_limit_at_request,
      (event_record.settings ->> 'maxGroupSize')::integer,
      10
    );

    return jsonb_build_object(
      'id', request_record.id,
      'status', request_record.status,
      'version', request_record.version,
      'projectedChildren', projected_children,
      'maxGroupSize', max_group_size,
      'limitOverridden', request_record.limit_overridden
    );
  end if;

  if request_record.status <> 'pending' or request_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  -- Lock both parties in deterministic order before recalculating capacity.
  perform id
  from app_private.together_parties
  where id in (request_record.source_party_id, request_record.target_party_id)
  order by id
  for update;
  if exists (
    select 1
    from app_private.together_parties
    where id in (request_record.source_party_id, request_record.target_party_id)
      and locked_at is not null
  ) then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  source_children := app_private.together_party_child_count(request_record.source_party_id);
  target_children := app_private.together_party_child_count(request_record.target_party_id);
  projected_children := source_children + target_children;
  max_group_size := app_private.event_group_size_limit(event_record.id);

  if _decision = 'accept' then
    if projected_children > max_group_size and not _override_limit then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514',
        detail = jsonb_build_object(
          'projectedChildren', projected_children,
          'maxGroupSize', max_group_size
        )::text;
    end if;

    if projected_children>max_group_size then
      insert into app_private.group_size_override_commands(event_id,party_id,actor_id,approved_registration_ids,approved_children,settings_version,reason)
      select event_record.id,request_record.target_party_id,actor,
       array_agg(distinct m.registration_id order by m.registration_id),projected_children,event_record.settings_version,trim(_reason)
      from app_private.together_memberships m where m.party_id in(request_record.source_party_id,request_record.target_party_id) and m.left_at is null;
    end if;

    for membership_record in
      select *
      from app_private.together_memberships
      where party_id = request_record.source_party_id
        and left_at is null
      order by joined_at, id
      for update
    loop
      update app_private.together_memberships
      set left_at = now()
      where id = membership_record.id;

      insert into app_private.together_memberships(party_id, registration_id)
      values (request_record.target_party_id, membership_record.registration_id);
    end loop;

    update app_private.together_join_requests
    set target_party_id = request_record.target_party_id,
        updated_at = now(),
        version = version + 1
    where target_party_id = request_record.source_party_id
      and id <> request_record.id
      and status = 'pending';

    update app_private.together_parties
    set capacity_override_at = case
          when projected_children > max_group_size then now()
          else capacity_override_at
        end,
        capacity_override_by = case
          when projected_children > max_group_size then actor
          else capacity_override_by
        end,
        capacity_override_reason = case
          when projected_children > max_group_size then left(trim(_reason), 500)
          else capacity_override_reason
        end
    where id = request_record.target_party_id;

    update app_private.together_parties
    set locked_at = now()
    where id = request_record.source_party_id;

    perform app_private.ensure_together_party_cluster_reference(request_record.target_party_id);
  end if;

  update app_private.together_join_requests
  set status = expected_status,
      decided_by = actor,
      decided_at = now(),
      decision_reason = left(trim(_reason), 500),
      limit_overridden = _decision = 'accept' and projected_children > max_group_size,
      updated_at = now(),
      version = version + 1
  where id = request_record.id
  returning * into request_record;

  insert into app_private.audit_events(
    event_id,
    actor_id,
    action,
    resource_type,
    resource_id,
    minimal_change
  )
  values (
    event_record.id,
    actor,
    case
      when _decision = 'accept' then 'together.capacity_request_accepted'
      else 'together.capacity_request_rejected'
    end,
    'together_join_request',
    request_record.id,
    jsonb_build_object(
      'sourceChildren', source_children,
      'targetChildren', target_children,
      'projectedChildren', projected_children,
      'groupLimit', max_group_size,
      'limitOverridden', request_record.limit_overridden,
      'reason', left(trim(_reason), 500)
    )
  );

  perform realtime.send(jsonb_build_object('requestId', request_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);

  return jsonb_build_object(
    'id', request_record.id,
    'status', request_record.status,
    'version', request_record.version,
    'projectedChildren', projected_children,
    'maxGroupSize', max_group_size,
    'limitOverridden', request_record.limit_overridden
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_group_create(_event_slug text, _display_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); event_record app_private.events; created_group app_private.walking_groups; normalized_name text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;
  normalized_name := nullif(regexp_replace(trim(coalesce(_display_name, '')), '[[:space:]]+', ' ', 'g'), '');
  if normalized_name is not null and (char_length(normalized_name) not between 2 and 80 or normalized_name ~ '[[:cntrl:]]') then
    raise exception 'INVALID_GROUP_NAME' using errcode = '22023';
  end if;
  insert into app_private.walking_groups(event_id, code, status, display_name, route_mode)
  values (event_record.id, 'pending', 'draft', normalized_name, 'dynamic') returning * into created_group;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'group.created', 'walking_group', created_group.id,
    jsonb_build_object('systemCode', created_group.system_code, 'displayName', created_group.display_name));
  perform realtime.send(jsonb_build_object('resource', 'group_composition', 'id', created_group.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', created_group.id, 'systemCode', created_group.system_code,
    'displayName', created_group.display_name, 'version', created_group.version);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_group_move_registration(_event_slug text, _registration_id uuid, _target_group_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  selected_registration app_private.registrations;
  target_group app_private.walking_groups;
  selected_party_id uuid;
  bundle_ids uuid[];
  bundle_children integer;
  target_children integer;
  max_group_size integer;
  member_id uuid;
  active_assignment app_private.group_registrations;
  next_revision integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;
  select * into selected_registration from app_private.registrations
  where id = _registration_id and event_id = event_record.id and status = 'submitted' for update;
  if selected_registration.id is null then raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002'; end if;
  select party_id into selected_party_id from app_private.together_memberships
  where registration_id = selected_registration.id and left_at is null;
  select coalesce(array_agg(registration.id order by registration.id), array[selected_registration.id]) into bundle_ids
  from app_private.registrations registration
  where registration.event_id = event_record.id and registration.status = 'submitted' and (
    (selected_party_id is null and registration.id = selected_registration.id)
    or (selected_party_id is not null and exists (select 1 from app_private.together_memberships membership
      where membership.party_id = selected_party_id and membership.registration_id = registration.id and membership.left_at is null))
  );
  perform 1 from app_private.registrations where id = any(bundle_ids) order by id for update;

  if _target_group_id is not null then
    select * into target_group from app_private.walking_groups
    where id = _target_group_id and event_id = event_record.id for update;
    if target_group.id is null then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
    if target_group.status <> 'draft' or exists (select 1 from app_private.group_schedule_revisions schedule
      where schedule.group_id = target_group.id and schedule.state = 'published') then
      raise exception 'GROUPS_FINALIZED' using errcode = '23514';
    end if;
  end if;

  if exists (
    select 1 from app_private.group_registrations assignment
    join app_private.walking_groups source_group on source_group.id = assignment.group_id
    where assignment.registration_id = any(bundle_ids) and assignment.superseded_at is null
      and (assignment.published_at is not null or source_group.status <> 'draft'
        or exists (select 1 from app_private.group_schedule_revisions schedule
          where schedule.group_id = source_group.id and schedule.state = 'published'))
  ) then raise exception 'GROUPS_FINALIZED' using errcode = '23514'; end if;

  select count(*)::integer into bundle_children from app_private.registration_children child
  where child.registration_id = any(bundle_ids) and child.participation_status = 'active';
  max_group_size := app_private.event_group_size_limit(event_record.id);
  if _target_group_id is not null then
    select count(*)::integer into target_children
    from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id
      and child.participation_status = 'active'
    where assignment.group_id = _target_group_id and assignment.superseded_at is null
      and not (assignment.registration_id = any(bundle_ids));
    if target_children + bundle_children > max_group_size then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514';
    end if;
  end if;

  foreach member_id in array bundle_ids loop
    select * into active_assignment from app_private.group_registrations assignment
    where assignment.registration_id = member_id and assignment.superseded_at is null for update;
    if active_assignment.group_id is not distinct from _target_group_id then continue; end if;
    if active_assignment.id is not null then
      update app_private.group_registrations set superseded_at = now() where id = active_assignment.id;
      update app_private.walking_groups set version = version + 1, updated_at = now()
      where id = active_assignment.group_id;
    end if;
    if _target_group_id is not null then
      select coalesce(max(assignment_revision), 0) + 1 into next_revision
      from app_private.group_registrations where registration_id = member_id;
      insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
      values (_target_group_id, member_id, next_revision);
    end if;
    active_assignment := null;
  end loop;
  if _target_group_id is not null then
    update app_private.walking_groups set version = version + 1, updated_at = now() where id = _target_group_id;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'group.registration_moved', 'registration', selected_registration.id,
    jsonb_build_object('targetGroupId', _target_group_id, 'registrationIds', to_jsonb(bundle_ids),
      'childCount', bundle_children));
  perform realtime.send(jsonb_build_object('resource', 'group_composition', 'registrationId', selected_registration.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('movedRegistrations', cardinality(bundle_ids), 'childCount', bundle_children,
    'targetGroupId', _target_group_id);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_group_repair_split_party(_event_slug text, _party_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  party_record app_private.together_parties;
  bundle_ids uuid[];
  active_member_count integer;
  location_count integer;
  target_group app_private.walking_groups;
  move_result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record
  from app_private.events
  where slug = _event_slug
  for no key update;

  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;

  select * into party_record
  from app_private.together_parties
  where id = _party_id and event_id = event_record.id
  for update;
  if party_record.id is null then
    raise exception 'PARTY_NOT_FOUND' using errcode = 'P0002';
  end if;

  select count(*)::integer into active_member_count
  from app_private.together_memberships membership
  where membership.party_id = _party_id and membership.left_at is null;

  select coalesce(array_agg(registration.id order by registration.id), '{}'::uuid[])
  into bundle_ids
  from app_private.together_memberships membership
  join app_private.registrations registration
    on registration.id = membership.registration_id
  where membership.party_id = _party_id
    and membership.left_at is null
    and registration.event_id = event_record.id
    and registration.status = 'submitted';

  if cardinality(bundle_ids) < 2 or active_member_count <> cardinality(bundle_ids) then
    raise exception 'PARTY_NOT_REPAIRABLE' using errcode = '23514';
  end if;
  perform 1
  from app_private.registrations registration
  where registration.id = any(bundle_ids)
  order by registration.id
  for update;

  select count(distinct coalesce(assignment.group_id::text, 'unassigned'))::integer
  into location_count
  from unnest(bundle_ids) member_id
  left join app_private.group_registrations assignment
    on assignment.registration_id = member_id
   and assignment.superseded_at is null;
  if location_count < 2 then
    raise exception 'PARTY_NOT_SPLIT' using errcode = '23514';
  end if;

  -- Prefer the group containing the most registrations. Child count breaks a
  -- member-count tie; the immutable system order is the final deterministic
  -- tie-breaker so the correction never leaves the administrator stuck.
  select walking_group.* into target_group
  from app_private.walking_groups walking_group
  join (
    select
      assignment.group_id,
      count(*)::integer as member_count,
      sum((
        select count(*)
        from app_private.registration_children child
        where child.registration_id = assignment.registration_id
          and child.participation_status = 'active'
      ))::integer as child_count
    from app_private.group_registrations assignment
    where assignment.registration_id = any(bundle_ids)
      and assignment.superseded_at is null
    group by assignment.group_id
  ) ranked on ranked.group_id = walking_group.id
  where walking_group.event_id = event_record.id
  order by ranked.member_count desc, ranked.child_count desc, walking_group.system_number asc
  limit 1;
  if target_group.id is null then
    raise exception 'PARTY_REPAIR_TARGET_NOT_FOUND' using errcode = 'P0002';
  end if;

  move_result := api.admin_group_move_registration(
    _event_slug,
    bundle_ids[1],
    target_group.id
  );

  return move_result || jsonb_build_object(
    'partyId', _party_id,
    'targetSystemCode', target_group.system_code,
    'targetDisplayName', target_group.display_name
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_group_size_policy_save(_event_slug text, _max_group_size integer, _target_group_size integer, _expected_settings_version integer, _expected_impact_hash text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; impact jsonb; old_limit integer; old_target integer; result_version integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if _expected_settings_version is distinct from e.settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 impact:=app_private.group_size_policy_impact(e.id,_max_group_size,_target_group_size);
 if _expected_impact_hash is distinct from impact->>'impactHash' then raise exception 'GROUP_SIZE_IMPACT_CHANGED' using errcode='40001'; end if;
 old_limit:=app_private.event_group_size_limit(e.id); old_target:=(e.settings->>'targetGroupSize')::integer;
 if old_limit=_max_group_size and old_target is not distinct from _target_group_size then return impact; end if;
 update app_private.events set settings=(settings-'targetGroupSize')||jsonb_build_object('maxGroupSize',_max_group_size)
  ||case when _target_group_size is null then '{}'::jsonb else jsonb_build_object('targetGroupSize',_target_group_size) end,
  settings_version=settings_version+1,updated_at=now() where id=e.id returning settings_version into result_version;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(e.id,auth.uid(),'group_size_limit.updated','event',e.id,jsonb_build_object('from',old_limit,'to',_max_group_size,
  'previousTarget',old_target,'target',_target_group_size,'settingsVersion',result_version,'reason',trim(_reason),
  'existingGroups',impact->'groups','existingParties',impact->'parties','reviewedImpactHash',_expected_impact_hash));
 perform realtime.send(jsonb_build_object('resource','event_settings','version',result_version),'snapshot_changed','admin-event:'||e.id::text,true);
 return jsonb_build_object('settingsVersion',result_version,'maxGroupSize',_max_group_size,
  'targetGroupSize',coalesce(_target_group_size,_max_group_size),'followsMaximum',_target_group_size is null,
  'groups',impact->'groups','parties',impact->'parties');
end $function$;

CREATE OR REPLACE FUNCTION api.admin_location_marker_save(_event_slug text, _resource_type text, _resource_id uuid, _latitude numeric, _longitude numeric, _reason text, _restore_from_address boolean, _expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; location_record app_private.portal_private_locations;
  effective_latitude numeric; effective_longitude numeric; node_id uuid; next_version integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or _resource_type not in ('start_point', 'portal', 'final_portal')
    or char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _latitude not between -90 and 90 or _longitude not between -180 and 180 then
    raise exception 'INVALID_COORDINATE' using errcode = '22023';
  end if;

  if _resource_type = 'start_point' then
    if not (app_private.has_capability(event_record.id, 'groups_manage', actor)
      or app_private.has_capability(event_record.id, 'event_admin', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    select * into point_record from app_private.start_points
      where id = _resource_id and event_id = event_record.id for update;
    if point_record.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    effective_latitude := case when _restore_from_address then point_record.geocoded_latitude else _latitude end;
    effective_longitude := case when _restore_from_address then point_record.geocoded_longitude else _longitude end;
    if effective_latitude is null then raise exception 'ADDRESS_LOCATION_MISSING' using errcode = '23514'; end if;
    node_id := app_private.nearest_walking_node(event_record.id, effective_latitude, effective_longitude);
    update app_private.start_points set
      marker_latitude = case when _restore_from_address then null else effective_latitude end,
      marker_longitude = case when _restore_from_address then null else effective_longitude end,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when _restore_from_address then 'address' else 'manual' end,
      marker_reason = case when _restore_from_address then null else trim(_reason) end,
      marker_updated_by = actor, marker_updated_at = now(), walking_node_id = node_id,
      walking_node_updated_at = case when node_id is not null then now() end,
      verified_at = case when node_id is not null then now() end,
      verified_by = case when node_id is not null then actor end,
      updated_at = now(), version = version + 1
    where id = point_record.id returning version into next_version;
    update app_private.start_slots set latitude = effective_latitude, longitude = effective_longitude,
      location_verified_at = case when node_id is not null then now() end, updated_at = now()
    where start_point_id = point_record.id;
  else
    if not (app_private.has_capability(event_record.id, 'portals_manage', actor)
      or app_private.has_capability(event_record.id, 'event_admin', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    select * into portal_record from app_private.portals
      where id = _resource_id and event_id = event_record.id for update;
    select * into location_record from app_private.portal_private_locations where portal_id = _resource_id;
    if portal_record.id is null or location_record.portal_id is null then raise exception 'PORTAL_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from portal_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    effective_latitude := case when _restore_from_address then location_record.geocoded_latitude else _latitude end;
    effective_longitude := case when _restore_from_address then location_record.geocoded_longitude else _longitude end;
    if effective_latitude is null then raise exception 'ADDRESS_LOCATION_MISSING' using errcode = '23514'; end if;
    select id into node_id from app_private.walking_nodes where portal_id = portal_record.id limit 1;
    if node_id is null then
      insert into app_private.walking_nodes(event_id, kind, portal_id, coordinate, verified_at, verified_by)
      values (event_record.id, 'portal', portal_record.id, point(effective_longitude, effective_latitude), null, null)
      returning id into node_id;
    else
      update app_private.walking_nodes set coordinate = point(effective_longitude, effective_latitude) where id = node_id;
    end if;
    update app_private.portal_private_locations set
      marker_latitude = case when _restore_from_address then null else effective_latitude end,
      marker_longitude = case when _restore_from_address then null else effective_longitude end,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when _restore_from_address then 'address' else 'manual' end,
      marker_reason = case when _restore_from_address then null else trim(_reason) end,
      marker_updated_by = actor, marker_updated_at = now(), walking_node_updated_at = now(),
      verified_at = now(), verified_by = actor, updated_at = now()
    where portal_id = portal_record.id;
    update app_private.portals set updated_at = now(), version = version + 1
      where id = portal_record.id returning version into next_version;
  end if;

  insert into app_private.location_change_history(event_id, resource_type, resource_id,
    address_latitude, address_longitude, marker_latitude, marker_longitude, location_source, reason, changed_by)
  values (event_record.id, _resource_type, _resource_id,
    case when _resource_type = 'start_point' then point_record.geocoded_latitude else location_record.geocoded_latitude end,
    case when _resource_type = 'start_point' then point_record.geocoded_longitude else location_record.geocoded_longitude end,
    effective_latitude, effective_longitude, case when _restore_from_address then 'address' else 'manual' end, trim(_reason), actor);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'location.marker_moved', _resource_type, _resource_id,
    jsonb_build_object('source', case when _restore_from_address then 'address' else 'manual' end,
      'walkingNodeRecalculated', node_id is not null, 'routeCacheInvalidated', true, 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', _resource_type, 'id', _resource_id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', _resource_id, 'version', next_version,
    'latitude', effective_latitude, 'longitude', effective_longitude,
    'walkingNodeId', node_id, 'routeCacheInvalidated', true);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_merge_together_parties(_event_slug text, _source_party_id uuid, _target_party_id uuid, _expected_source_state text, _expected_target_state text, _reason text, _idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_record app_private.events; preview jsonb; result jsonb; request_hash text; receipt app_private.command_receipts;
  moved_ids uuid[]; member record; reference text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  event_record := app_private.require_together_manager(_event_slug);
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500
      or char_length(coalesce(_idempotency_key, '')) not between 10 and 100
      or _expected_source_state is null or _expected_target_state is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  -- Same event-first lock order as registration submission, group moves and decisions.
  perform id from app_private.events where id = event_record.id for no key update;
  request_hash := encode(extensions.digest(jsonb_build_array(event_record.id, _source_party_id, _target_party_id,
    _expected_source_state, _expected_target_state, trim(_reason))::text, 'sha256'), 'hex');
  select * into receipt from app_private.command_receipts where actor_id = auth.uid()
    and command_type = 'together.adminMerge' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '22023'; end if;
    return receipt.safe_result;
  end if;
  -- Child/cancellation commands lock registrations before their party; follow that
  -- order and freeze the rows represented in the preview before recomputing it.
  perform r.id from app_private.registrations r
    where r.event_id = event_record.id and exists (select 1 from app_private.together_memberships m
      where m.registration_id = r.id and m.party_id in (_source_party_id, _target_party_id) and m.left_at is null)
    order by r.id for update;
  perform id from app_private.together_parties where event_id = event_record.id and id in (_source_party_id, _target_party_id) order by id for update;
  perform g.id from app_private.walking_groups g where g.event_id = event_record.id and exists (
    select 1 from app_private.group_registrations a join app_private.together_memberships m on m.registration_id = a.registration_id
    where a.group_id = g.id and a.superseded_at is null and m.left_at is null and m.party_id in (_source_party_id, _target_party_id)
  ) order by g.id for update;
  preview := app_private.together_merge_preview(event_record.id, _source_party_id, _target_party_id);
  if preview #>> '{source,stateToken}' <> _expected_source_state or preview #>> '{target,stateToken}' <> _expected_target_state then
    raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not (preview ->> 'canMerge')::boolean then raise exception 'MERGE_BLOCKED' using errcode = '23514', detail = (preview -> 'blockers')::text; end if;
  for member in select id, registration_id from app_private.together_memberships
      where party_id = _source_party_id and left_at is null order by id for update
  loop
    update app_private.together_memberships set left_at = now() where id = member.id;
    insert into app_private.together_memberships(party_id, registration_id) values (_target_party_id, member.registration_id);
  end loop;
  update app_private.together_join_requests set target_party_id = _target_party_id, version = version + 1, updated_at = now()
    where target_party_id = _source_party_id and status = 'pending';
  update app_private.together_parties set locked_at = now() where id = _source_party_id;
  reference := app_private.ensure_together_party_cluster_reference(_target_party_id);
  select array_agg(registration_id order by registration_id) into moved_ids from app_private.together_memberships
    where party_id = _target_party_id and left_at is null;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, auth.uid(), 'together.admin_merged', 'together_party', _target_party_id,
      jsonb_build_object('sourcePartyId', _source_party_id, 'targetPartyId', _target_party_id,
        'sourceClusterReference', preview #>> '{source,clusterReference}', 'targetClusterReference', reference,
        'registrationIds', to_jsonb(moved_ids), 'childCount', preview -> 'projectedChildren', 'reason', trim(_reason)));
  result := jsonb_build_object('partyId', _target_party_id, 'clusterReference', reference, 'childCount', preview -> 'projectedChildren');
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
    values (auth.uid(), 'together.adminMerge', _idempotency_key, request_hash, result, now() + interval '10 years');
  perform realtime.send(jsonb_build_object('partyId', _target_party_id), 'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_publish_plans(_event_slug text, _plan_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  affected integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(array_length(_plan_ids, 1), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if (select count(distinct plan.id) from app_private.route_plan_versions plan join app_private.walking_groups walking_group on walking_group.id = plan.group_id where plan.id = any(_plan_ids) and walking_group.event_id = v_event_id and plan.state = 'valid') <> (select count(distinct id) from unnest(_plan_ids) wanted(id)) then raise exception 'INVALID_PLAN' using errcode = '23514'; end if;

  if exists(select 1 from app_private.route_plan_versions plan where plan.id=any(_plan_ids)
    and not exists(select 1 from app_private.group_start_publications p where p.group_id=plan.group_id)) then
    raise exception 'START_TIME_PUBLICATION_REQUIRED' using errcode='23514'; end if;

  update app_private.route_plan_stops
  set planned_arrival_at = planned_arrival_at
  where plan_version_id = any(_plan_ids);

  update app_private.route_plan_versions set state = 'published', published_at = now() where id = any(_plan_ids) and state = 'valid';
  get diagnostics affected = row_count;
  update app_private.walking_groups walking_group
  set status = case when walking_group.status = 'draft' then 'ready' else walking_group.status end,
      version = version + 1
  where walking_group.current_plan_version_id = any(_plan_ids);
  update app_private.group_registrations assignment set published_at = now() where assignment.group_id in (select plan.group_id from app_private.route_plan_versions plan where plan.id = any(_plan_ids));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.published', 'route_plan_batch', jsonb_build_object('planCount', affected, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', affected);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_redirect_group(_run_id uuid, _target text, _preferred_portal_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  stop_record app_private.run_stops;
  dispatch_result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' or run_record.status <> 'live' then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  if not (
    app_private.has_capability(group_record.event_id, 'live_support', actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _target not in ('ordinary', 'finale')
     or (_target = 'ordinary' and _preferred_portal_id is null)
     or (_target = 'finale' and _preferred_portal_id is not null) then
    raise exception 'INVALID_REDIRECT_TARGET' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  if run_record.current_stop_id is not null then
    select * into stop_record from app_private.run_stops where id = run_record.current_stop_id for update;
    if stop_record.stop_kind = 'finale' then
      raise exception 'FINAL_DESTINATION_ALREADY_PUBLISHED' using errcode = '23514';
    end if;
    if exists (select 1 from app_private.scan_evidence where run_stop_id = stop_record.id) then
      raise exception 'VISIT_IN_PROGRESS' using errcode = '23514';
    end if;
    update app_private.run_stops
    set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
      completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
    where id = stop_record.id;
    update app_private.stop_participant_statuses
    set status = 'skipped', required_for_completion = false,
      exclusion_reason = 'Bestemming door organisatie gewijzigd',
      reason = 'Bestemming door organisatie gewijzigd', changed_by = actor,
      decided_at = clock_timestamp(), version = version + 1
    where run_stop_id = stop_record.id and status = 'pending';
    update app_private.portal_reservations
    set status = 'cancelled', cancelled_reason = 'Bestemming door organisatie gewijzigd', version = version + 1
    where id = stop_record.reservation_id and status in ('held', 'active');
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, stop_record.id, 'stop.admin_redirected', actor,
      jsonb_build_object('target', _target, 'reason', left(trim(_reason), 500)));
    update app_private.group_runs set current_stop_id = null, version = version + 1 where id = _run_id;
  end if;

  dispatch_result := app_private.dispatch_next_stop(
    _run_id,
    clock_timestamp(),
    _target = 'finale',
    case when _target = 'ordinary' then _preferred_portal_id else null end
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.destination_redirected', 'group_run', _run_id,
    jsonb_build_object('target', _target, 'preferredPortalId', _preferred_portal_id, 'reason', left(trim(_reason), 500)));
  return dispatch_result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_safe_withdraw_group(_run_id uuid, _responsible_adult_user_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if run_record.id is null or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.has_capability(group_record.event_id, 'live_support', actor) or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if run_record.status not in ('live','paused') or run_record.id is distinct from (
    select r.id from app_private.group_runs r where r.group_id=group_record.id order by r.created_at desc,r.id desc limit 1
  ) then raise exception 'RUN_NOT_ACTIVE' using errcode='23514'; end if;
  if not exists (select 1 from app_private.readiness_group_adults(group_record.id) a where a.user_id=_responsible_adult_user_id) then raise exception 'RESPONSIBLE_ADULT_NOT_IN_GROUP' using errcode = '23514'; end if;
  insert into app_private.group_safe_departures(group_id, run_id, responsible_adult_user_id, recorded_by, reason)
  values (group_record.id, run_record.id, _responsible_adult_user_id, actor, trim(_reason));
  update app_private.group_runs set status = 'stopped', current_stop_id = null, stopped_reason = trim(_reason),
    finished_at = clock_timestamp(), version = version + 1 where id = run_record.id returning * into run_record;
  update app_private.walking_groups set status = 'stopped', version = version + 1 where id = group_record.id;
  update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Veilige afmelding', version = version + 1
  where run_id = run_record.id and status in ('held', 'active');
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.safe_departure_recorded', 'group_run', run_record.id,
    jsonb_build_object('responsibleAdultUserId', _responsible_adult_user_id, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('runId', run_record.id, 'status', run_record.status, 'version', run_record.version);
end;
$function$;

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
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for no key update;
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
$function$;

CREATE OR REPLACE FUNCTION api.admin_save_route_settings(_event_slug text, _settings jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  current_settings app_private.event_route_settings;
  next_mode text;
  next_final_portal uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_settings) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into current_settings from app_private.event_route_settings where event_id = v_event_id for update;
  if current_settings.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  next_mode := coalesce(_settings ->> 'plannerMode', current_settings.planner_mode);
  next_final_portal := coalesce(nullif(_settings ->> 'finalPortalId', '')::uuid, current_settings.final_portal_id);
  if next_mode not in ('disabled', 'shadow', 'dynamic') then raise exception 'INVALID_PLANNER_MODE' using errcode = '22023'; end if;
  if next_final_portal is not null and not exists (
    select 1 from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes node on node.portal_id = portal.id and node.verified_at is not null
    where portal.id = next_final_portal and portal.event_id = v_event_id and portal.approval_status = 'approved'
  ) then raise exception 'FINAL_PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  update app_private.event_route_settings set
    first_start_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'firstStartAt'), first_start_at),
    early_preference_latest_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'earlyPreferenceLatestAt'), early_preference_latest_at),
    later_preference_earliest_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'laterPreferenceEarliestAt'), later_preference_earliest_at),
    global_ordinary_stop_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'globalOrdinaryStopAt'), global_ordinary_stop_at),
    allowed_personal_stop_times = case when _settings ? 'allowedStopTimes'
      then array(select value::timestamptz from jsonb_array_elements_text(_settings -> 'allowedStopTimes') value order by value::timestamptz)
      else allowed_personal_stop_times end,
    ordinary_visit_seconds = coalesce((_settings ->> 'ordinaryVisitSeconds')::integer, ordinary_visit_seconds),
    route_buffer_seconds = coalesce((_settings ->> 'bufferSeconds')::integer, route_buffer_seconds),
    final_portal_id = next_final_portal,
    finale_opens_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleOpensAt'), finale_opens_at),
    finale_last_arrival_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleLastArrivalAt'), finale_last_arrival_at),
    finale_closes_at = coalesce(app_private.parse_amsterdam_instant(_settings->>'finaleClosesAt'), finale_closes_at),
    finale_show_seconds = coalesce((_settings ->> 'finaleShowSeconds')::integer, finale_show_seconds),
    finale_turnover_seconds = coalesce((_settings ->> 'finaleTurnoverSeconds')::integer, finale_turnover_seconds),
    finale_planning_transfer_seconds = coalesce((_settings ->> 'finalePlanningTransferSeconds')::integer, finale_planning_transfer_seconds),
    finale_max_concurrent_groups = coalesce((_settings ->> 'finaleMaxGroups')::integer, finale_max_concurrent_groups),
    finale_max_concurrent_children = coalesce((_settings ->> 'finaleMaxChildren')::integer, finale_max_concurrent_children),
    finale_safe_approach = case when _settings ? 'finaleSafeApproach' then nullif(trim(_settings ->> 'finaleSafeApproach'), '') else finale_safe_approach end,
    finale_waiting_area = case when _settings ? 'finaleWaitingArea' then nullif(trim(_settings ->> 'finaleWaitingArea'), '') else finale_waiting_area end,
    finale_exit_route = case when _settings ? 'finaleExitRoute' then nullif(trim(_settings ->> 'finaleExitRoute'), '') else finale_exit_route end,
    finale_accessible_entrance = case when _settings ? 'finaleAccessibleEntrance' then nullif(trim(_settings ->> 'finaleAccessibleEntrance'), '') else finale_accessible_entrance end,
    finale_contact = case when _settings ? 'finaleContact' then nullif(trim(_settings ->> 'finaleContact'), '') else finale_contact end,
    emergency_destination_name = case when _settings ? 'emergencyDestinationName' then nullif(trim(_settings ->> 'emergencyDestinationName'), '') else emergency_destination_name end,
    emergency_instructions = case when _settings ? 'emergencyInstructions' then nullif(trim(_settings ->> 'emergencyInstructions'), '') else emergency_instructions end,
    finale_available = coalesce((_settings ->> 'finaleAvailable')::boolean, finale_available),
    planner_mode = next_mode,
    updated_by = actor,
    version = version + 1
  where event_id = v_event_id returning * into current_settings;

  if current_settings.planner_mode in ('shadow', 'dynamic') and (
    current_settings.first_start_at is null or current_settings.global_ordinary_stop_at is null
    or current_settings.final_portal_id is null or current_settings.finale_opens_at is null
    or current_settings.finale_last_arrival_at is null or current_settings.finale_closes_at is null
  ) then raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514'; end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'route_settings.updated', 'event', v_event_id,
    jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_set_group_size_limit(_event_slug text, _max_group_size integer, _expected_settings_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; target integer; impact jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if _max_group_size is null or _max_group_size<1 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if _expected_settings_version is distinct from e.settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 target:=(e.settings->>'targetGroupSize')::integer;
 impact:=app_private.group_size_policy_impact(e.id,_max_group_size,target);
 if _max_group_size<app_private.event_group_size_limit(e.id) and (jsonb_array_length(impact->'groups')>0 or jsonb_array_length(impact->'parties')>0) then
  raise exception 'GROUP_SIZE_IMPACT_REVIEW_REQUIRED' using errcode='23514';
 end if;
 return api.admin_group_size_policy_save(_event_slug,_max_group_size,target,_expected_settings_version,impact->>'impactHash',_reason);
end $function$;

CREATE OR REPLACE FUNCTION api.admin_start_point_save(_event_slug text, _point_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  node_event_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_payload) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if nullif(_payload ->> 'walkingNodeId', '') is not null then
    select event_id into node_event_id from app_private.walking_nodes
    where id = (_payload ->> 'walkingNodeId')::uuid and kind in ('start', 'junction') and verified_at is not null;
    if node_event_id is distinct from v_event_id then raise exception 'START_NODE_NOT_VERIFIED' using errcode = '23514'; end if;
  end if;
  if coalesce((_payload ->> 'verified')::boolean, false) and (
    nullif(_payload ->> 'walkingNodeId', '') is null
    or nullif(_payload ->> 'latitude', '') is null
    or nullif(_payload ->> 'longitude', '') is null
  ) then raise exception 'START_POINT_NOT_ROUTE_READY' using errcode = '23514'; end if;
  if _point_id is null then
    insert into app_private.start_points(
      event_id, name, private_address, latitude, longitude, walking_node_id, accessible,
      accessibility_notes, max_gathering_groups, max_gathering_children, verified_at, verified_by
    ) values (
      v_event_id, trim(_payload ->> 'name'), trim(_payload ->> 'privateAddress'),
      nullif(_payload ->> 'latitude', '')::numeric, nullif(_payload ->> 'longitude', '')::numeric,
      nullif(_payload ->> 'walkingNodeId', '')::uuid, nullif(_payload ->> 'accessible', '')::boolean,
      nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      coalesce((_payload ->> 'maxGroups')::integer, 1), coalesce((_payload ->> 'maxChildren')::integer, 20),
      case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end
    ) returning * into point;
  else
    select * into point from app_private.start_points where id = _point_id and event_id = v_event_id for update;
    if point.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if point.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.start_points set
      name = trim(_payload ->> 'name'), private_address = trim(_payload ->> 'privateAddress'),
      latitude = nullif(_payload ->> 'latitude', '')::numeric, longitude = nullif(_payload ->> 'longitude', '')::numeric,
      walking_node_id = nullif(_payload ->> 'walkingNodeId', '')::uuid,
      accessible = nullif(_payload ->> 'accessible', '')::boolean,
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      max_gathering_groups = coalesce((_payload ->> 'maxGroups')::integer, max_gathering_groups),
      max_gathering_children = coalesce((_payload ->> 'maxChildren')::integer, max_gathering_children),
      verified_at = case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      verified_by = case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end,
      version = version + 1
    where id = point.id returning * into point;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_point.saved', 'start_point', point.id,
    jsonb_build_object('version', point.version, 'verified', point.verified_at is not null, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', point.id, 'version', point.version, 'verified', point.verified_at is not null);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_start_slot_save(_event_slug text, _slot_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _max_groups integer, _max_children integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  slot app_private.start_slots;
  route_settings app_private.event_route_settings;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into point from app_private.start_points where id = _start_point_id and event_id = v_event_id and active;
  select * into route_settings from app_private.event_route_settings where event_id = v_event_id;
  if point.id is null or point.verified_at is null or point.walking_node_id is null
     or point.latitude is null or point.longitude is null or _max_groups < 1 or _max_children < 1
     or (route_settings.first_start_at is not null and _starts_at < route_settings.first_start_at)
     or (route_settings.global_ordinary_stop_at is not null and _starts_at >= route_settings.global_ordinary_stop_at)
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _slot_id is null then
    insert into app_private.start_slots(
      event_id, name, location_name, private_address, latitude, longitude, location_verified_at,
      starts_at, max_groups, max_children, start_point_id
    ) values (
      v_event_id, point.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point.name, point.private_address, point.latitude, point.longitude, point.verified_at,
      _starts_at, _max_groups, _max_children, point.id
    ) returning * into slot;
  else
    update app_private.start_slots set starts_at = _starts_at, max_groups = _max_groups,
      max_children = _max_children, start_point_id = point.id, location_name = point.name,
      private_address = point.private_address, latitude = point.latitude, longitude = point.longitude,
      location_verified_at = point.verified_at
    where id = _slot_id and event_id = v_event_id returning * into slot;
    if slot.id is null then raise exception 'START_SLOT_NOT_FOUND' using errcode = 'P0002'; end if;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_slot.saved', 'start_slot', slot.id, jsonb_build_object('startsAt', slot.starts_at, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_confirm_start(_event_slug text, _group_id uuid, _expected_revision integer, _expected_settings_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; g app_private.walking_groups; s app_private.group_schedule_revisions; p app_private.start_points;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into e from app_private.events where slug=_event_slug for no key update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  select * into g from app_private.walking_groups where id=_group_id and event_id=e.id for update;
  if g.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if exists(select 1 from app_private.group_runs where group_id=g.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id for update;
  if s.id is null or s.revision is distinct from _expected_revision or s.state<>'draft' then raise exception 'STALE_REVISION' using errcode='40001'; end if;
  select p1.* into p from app_private.start_points p1 join app_private.start_slots slot on slot.start_point_id=p1.id where slot.id=s.start_slot_id;
  if not app_private.start_point_safe_connection(p.id) then raise exception 'START_POINT_NOT_VERIFIED' using errcode='23514'; end if;
  if not app_private.start_point_ready_at(p.id,(select starts_at from app_private.start_slots where id=s.start_slot_id)) then raise exception 'START_POINT_NOT_AVAILABLE' using errcode='23514'; end if;
  if not exists(select 1 from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) then
    raise exception 'EMPTY_GROUP' using errcode='23514'; end if;
  if exists(select 1 from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id
    left join app_private.payment_requests p1 on p1.registration_id=r.id where a.group_id=g.id and a.superseded_at is null
      and r.status='submitted' and coalesce(p1.status::text,'') not in ('confirmed','waived')) then
    raise exception 'PAYMENT_NOT_CONFIRMED' using errcode='23514'; end if;
  perform app_private.validate_start_schedule_capacity(e.id,array[s.id]);
  update app_private.group_schedule_revisions set confirmed_at=clock_timestamp(),confirmed_by=auth.uid(),
    confirmed_settings_version=e.settings_version,confirmed_point_version=p.version,
    confirmed_route_settings_version=(select version from app_private.event_route_settings where event_id=e.id),
    confirmed_starts_at=(select starts_at from app_private.start_slots where id=s.start_slot_id),
    confirmed_start_point_id=p.id,confirmed_composition_hash=app_private.start_group_composition_hash(g.id) where id=s.id returning * into s;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'group_start.confirmed','group_schedule',s.id,jsonb_build_object('revision',s.revision,'settingsVersion',e.settings_version));
  perform realtime.send(jsonb_build_object('resource','start_planning','groupId',g.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',s.id,'revision',s.revision,'state','confirmed','confirmedAt',s.confirmed_at);
end;
$function$;

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
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for no key update;
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
$function$;

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
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_settings_save(_event_slug text, _settings jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); event_record app_private.events; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce((_settings ->> 'preferenceGreenMinutes')::integer, 15)
    >= coalesce((_settings ->> 'preferenceAmberMinutes')::integer, 30) then
    raise exception 'INVALID_PREFERENCE_THRESHOLDS' using errcode = '22023';
  end if;
  result := api.admin_save_route_settings(_event_slug, _settings, _expected_version, _reason);
  update app_private.event_route_settings set
    start_interval_minutes = coalesce((_settings ->> 'startIntervalMinutes')::integer, start_interval_minutes),
    preference_green_minutes = coalesce((_settings ->> 'preferenceGreenMinutes')::integer, preference_green_minutes),
    preference_amber_minutes = coalesce((_settings ->> 'preferenceAmberMinutes')::integer, preference_amber_minutes)
  where event_id = event_record.id;
  perform realtime.send(jsonb_build_object('resource', 'start_planning_settings', 'eventId', event_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_slots_prepare(_event_slug text, _starts_at timestamp with time zone[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); event_record app_private.events; settings app_private.event_route_settings;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_starts_at), 0) = 0 or cardinality(_starts_at) > 100 then
    raise exception 'INVALID_START_TIMES' using errcode = '22023';
  end if;
  select * into settings from app_private.event_route_settings where event_id = event_record.id;
  if exists (select 1 from unnest(_starts_at) as requested(starts_at)
    where requested.starts_at < settings.first_start_at or requested.starts_at > settings.global_ordinary_stop_at) then
    raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514';
  end if;
  insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
    location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
  select event_record.id, point.name || ' ' || to_char(requested.starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
    point.name, point.private_address,
    coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude),
    coalesce(point.marker_longitude, point.geocoded_longitude, point.longitude),
    point.verified_at, requested.starts_at, point.max_gathering_groups, point.max_gathering_children, true, point.id
  from app_private.start_points point cross join unnest(_starts_at) as requested(starts_at)
  where point.event_id = event_record.id and point.active and point.walking_node_id is not null
    and not exists (select 1 from app_private.start_slots existing
      where existing.start_point_id = point.id and existing.starts_at = requested.starts_at)
  on conflict do nothing;
  return jsonb_build_object('starts', coalesce((select jsonb_agg(jsonb_build_object(
    'id', slot.id, 'startPointId', slot.start_point_id, 'startsAt', slot.starts_at,
    'maxGroups', slot.max_groups, 'maxChildren', slot.max_children
  ) order by slot.starts_at, slot.start_point_id)
  from app_private.start_slots slot
  where slot.event_id = event_record.id and slot.active and slot.starts_at = any(_starts_at)), '[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_start_point_archive(_point_id uuid, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); point_record app_private.start_points; linked_groups integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_point.event_id from app_private.start_points evening_point where evening_point.id=_point_id));

  select * into point_record from app_private.start_points where id = _point_id for update;
  if actor is null or point_record.id is null or not app_private.has_capability(point_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select count(*) into linked_groups from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    where slot.start_point_id = point_record.id;
  if linked_groups > 0 then raise exception 'MOVE_GROUPS_FIRST:%', linked_groups using errcode = '23514'; end if;
  update app_private.start_points set active = false, updated_at = now(), version = version + 1
    where id = point_record.id returning * into point_record;
  update app_private.start_slots set active = false, updated_at = now() where start_point_id = point_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (point_record.event_id, actor, 'start_point.archived', 'start_point', point_record.id,
    jsonb_build_object('reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'start_point', 'id', point_record.id),
    'snapshot_changed', 'admin-event:' || point_record.event_id::text, true);
  return jsonb_build_object('id', point_record.id, 'archived', true, 'version', point_record.version);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_start_point_from_portal(_event_slug text, _portal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; p app_private.portals; l app_private.portal_private_locations; existing app_private.start_points;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into e from app_private.events where slug=_event_slug for no key update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.portals where id=_portal_id and event_id=e.id and approval_status='approved' and lifecycle_status='active';
  select * into l from app_private.portal_private_locations where portal_id=p.id and verified_at is not null;
  if p.id is null or l.portal_id is null then raise exception 'LINKED_PORTAL_NOT_AVAILABLE' using errcode='23514'; end if;
  select * into existing from app_private.start_points where event_id=e.id and linked_portal_id=p.id and active order by id limit 1;
  if existing.id is not null then return jsonb_build_object('id',existing.id,'version',existing.version,'reused',true); end if;
  return api.admin_startregie_start_point_save(_event_slug,null,jsonb_build_object(
    'pointType','portal','linkedPortalId',p.id,'countsAsFirstPortalVisit',true,'name',p.name,'publicLabel',p.name,
    'privateAddress',concat_ws(' ',l.street,l.house_number,l.addition),'geocodedLatitude',coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),
    'geocodedLongitude',coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),'active',true,
    'maxGroups',1,'maxChildren',coalesce((select max(max_children_per_visit) from app_private.portal_windows where portal_id=p.id),app_private.event_group_size_limit(e.id))),
    null,'Goedgekeurde poort overnemen als te controleren startpunt');
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_startregie_start_point_save(_event_slug text, _point_id uuid, _payload jsonb, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); event_record app_private.events; point_record app_private.start_points;
  portal_record app_private.portals; effective_latitude numeric; effective_longitude numeric; node_id uuid;
  point_kind text := coalesce(nullif(_payload ->> 'pointType', ''), 'gathering');
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if jsonb_typeof(_payload) <> 'object' or char_length(trim(coalesce(_payload ->> 'name', ''))) not between 2 and 120
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500
    or point_kind not in ('gathering', 'portal') then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if point_kind = 'portal' then
    select * into portal_record from app_private.portals
    where id = nullif(_payload ->> 'linkedPortalId', '')::uuid and event_id = event_record.id;
    if portal_record.id is null or portal_record.lifecycle_status not in ('approved', 'active') then
      raise exception 'LINKED_PORTAL_NOT_AVAILABLE' using errcode = '23514';
    end if;
  end if;
  effective_latitude := coalesce(nullif(_payload ->> 'markerLatitude', '')::numeric,
    nullif(_payload ->> 'geocodedLatitude', '')::numeric);
  effective_longitude := coalesce(nullif(_payload ->> 'markerLongitude', '')::numeric,
    nullif(_payload ->> 'geocodedLongitude', '')::numeric);
  if nullif(_payload ->> 'markerLatitude', '') is not null
    and char_length(trim(coalesce(_payload ->> 'markerReason', ''))) < 5 then
    raise exception 'MARKER_REASON_REQUIRED' using errcode = '22023';
  end if;
  if effective_latitude is not null then
    node_id := app_private.nearest_walking_node(event_record.id, effective_latitude, effective_longitude);
  end if;

  if _point_id is null then
    insert into app_private.start_points(
      event_id, name, public_label, point_type, linked_portal_id, private_address,
      public_arrival_instructions, internal_notes, available_from, available_until,
      max_gathering_groups, max_gathering_children, accessible, accessibility_notes,
      safe_approach, counts_as_first_portal_visit, contact_name, contact_phone,
      geocoded_latitude, geocoded_longitude, marker_latitude, marker_longitude,
      latitude, longitude, location_source, marker_reason, marker_updated_by,
      marker_updated_at, walking_node_id, walking_node_updated_at, verified_at, verified_by, active
    ) values (
      event_record.id, trim(_payload ->> 'name'),
      coalesce(nullif(trim(_payload ->> 'publicLabel'), ''), trim(_payload ->> 'name')),
      point_kind, case when point_kind = 'portal' then portal_record.id end,
      nullif(trim(_payload ->> 'privateAddress'), ''), nullif(trim(_payload ->> 'publicArrivalInstructions'), ''),
      nullif(trim(_payload ->> 'internalNotes'), ''), app_private.parse_amsterdam_instant(_payload->>'availableFrom'),
      app_private.parse_amsterdam_instant(_payload->>'availableUntil'),
      coalesce((_payload ->> 'maxGroups')::integer, 1), coalesce((_payload ->> 'maxChildren')::integer, 20),
      nullif(_payload ->> 'accessible', '')::boolean, nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      nullif(trim(_payload ->> 'safeApproach'), ''), coalesce((_payload ->> 'countsAsFirstPortalVisit')::boolean, false),
      nullif(trim(_payload ->> 'contactName'), ''), nullif(trim(_payload ->> 'contactPhone'), ''),
      nullif(_payload ->> 'geocodedLatitude', '')::numeric, nullif(_payload ->> 'geocodedLongitude', '')::numeric,
      nullif(_payload ->> 'markerLatitude', '')::numeric, nullif(_payload ->> 'markerLongitude', '')::numeric,
      effective_latitude, effective_longitude,
      case when nullif(_payload ->> 'markerLatitude', '') is null then 'address' else 'manual' end,
      nullif(trim(_payload ->> 'markerReason'), ''), actor,
      case when effective_latitude is not null then now() end, node_id, case when node_id is not null then now() end,
      case when node_id is not null then now() end, case when node_id is not null then actor end,
      coalesce((_payload ->> 'active')::boolean, true)
    ) returning * into point_record;
  else
    select * into point_record from app_private.start_points where id = _point_id and event_id = event_record.id for update;
    if point_record.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if _expected_version is distinct from point_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.start_points set
      name = trim(_payload ->> 'name'), public_label = coalesce(nullif(trim(_payload ->> 'publicLabel'), ''), trim(_payload ->> 'name')),
      point_type = point_kind, linked_portal_id = case when point_kind = 'portal' then portal_record.id end,
      private_address = nullif(trim(_payload ->> 'privateAddress'), ''),
      public_arrival_instructions = nullif(trim(_payload ->> 'publicArrivalInstructions'), ''),
      internal_notes = nullif(trim(_payload ->> 'internalNotes'), ''),
      available_from = app_private.parse_amsterdam_instant(_payload->>'availableFrom'),
      available_until = app_private.parse_amsterdam_instant(_payload->>'availableUntil'),
      max_gathering_groups = coalesce((_payload ->> 'maxGroups')::integer, max_gathering_groups),
      max_gathering_children = coalesce((_payload ->> 'maxChildren')::integer, max_gathering_children),
      accessible = nullif(_payload ->> 'accessible', '')::boolean,
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      safe_approach = nullif(trim(_payload ->> 'safeApproach'), ''),
      counts_as_first_portal_visit = coalesce((_payload ->> 'countsAsFirstPortalVisit')::boolean, false),
      contact_name = nullif(trim(_payload ->> 'contactName'), ''), contact_phone = nullif(trim(_payload ->> 'contactPhone'), ''),
      geocoded_latitude = nullif(_payload ->> 'geocodedLatitude', '')::numeric,
      geocoded_longitude = nullif(_payload ->> 'geocodedLongitude', '')::numeric,
      marker_latitude = nullif(_payload ->> 'markerLatitude', '')::numeric,
      marker_longitude = nullif(_payload ->> 'markerLongitude', '')::numeric,
      latitude = effective_latitude, longitude = effective_longitude,
      location_source = case when nullif(_payload ->> 'markerLatitude', '') is null then 'address' else 'manual' end,
      marker_reason = nullif(trim(_payload ->> 'markerReason'), ''), marker_updated_by = actor,
      marker_updated_at = case when effective_latitude is not null then now() end,
      walking_node_id = node_id, walking_node_updated_at = case when node_id is not null then now() end,
      verified_at = case when node_id is not null then now() end, verified_by = case when node_id is not null then actor end,
      active = coalesce((_payload ->> 'active')::boolean, active), updated_at = now(), version = version + 1
    where id = point_record.id returning * into point_record;
  end if;

  update app_private.start_slots set location_name = point_record.name, private_address = point_record.private_address,
    latitude = point_record.latitude, longitude = point_record.longitude,
    location_verified_at = point_record.verified_at, max_groups = point_record.max_gathering_groups,
    max_children = point_record.max_gathering_children, updated_at = now()
  where start_point_id = point_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, case when _point_id is null then 'start_point.created' else 'start_point.updated' end,
    'start_point', point_record.id, jsonb_build_object('version', point_record.version, 'type', point_record.point_type,
      'routeReady', point_record.walking_node_id is not null, 'reason', left(trim(_reason), 500)));
  if effective_latitude is not null then
    insert into app_private.location_change_history(event_id, resource_type, resource_id,
      address_latitude, address_longitude, marker_latitude, marker_longitude, location_source, reason, changed_by)
    values (event_record.id, 'start_point', point_record.id, point_record.geocoded_latitude, point_record.geocoded_longitude,
      effective_latitude, effective_longitude, point_record.location_source, point_record.marker_reason, actor);
  end if;
  perform realtime.send(jsonb_build_object('resource', 'start_point', 'id', point_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', point_record.id, 'version', point_record.version,
    'routeReady', point_record.walking_node_id is not null, 'walkingNodeId', point_record.walking_node_id);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_verify_portal_location(_portal_id uuid, _expected_portal_version integer, _latitude numeric, _longitude numeric, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal_record app_private.portals;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_portal.event_id from app_private.portals evening_portal where evening_portal.id=_portal_id));

  if _latitude not between -90 and 90 or _longitude not between -180 and 180 then raise exception 'INVALID_COORDINATE' using errcode = '22023'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into portal_record from app_private.portals where id = _portal_id for update;
  if portal_record.id is null or not app_private.has_capability(portal_record.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if portal_record.version <> _expected_portal_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  update app_private.portal_private_locations
  set latitude = _latitude, longitude = _longitude, verified_at = now(), verified_by = actor
  where portal_id = portal_record.id;
  update app_private.portals set version = version + 1 where id = portal_record.id returning * into portal_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal_record.event_id, actor, 'portal.location_verified', 'portal', portal_record.id, jsonb_build_object('reason', left(trim(_reason), 500)));
  return jsonb_build_object('portalId', portal_record.id, 'portalVersion', portal_record.version, 'locationVerified', true);
end;
$function$;

CREATE OR REPLACE FUNCTION api.admin_verify_portal_walking_connection(_event_slug text, _portal_id uuid, _expected_version integer, _safe_connection_checked boolean, _safe_approach text, _step_free_checked boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; p app_private.portals; l app_private.portal_private_locations;
  anchor app_private.walking_nodes; own_node app_private.walking_nodes; distance numeric; lat numeric; lon numeric;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into e from app_private.events where slug=_event_slug for no key update;
  if e.id is null or not (app_private.has_capability(e.id,'portals_manage',auth.uid())
    or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.portals where id=_portal_id and event_id=e.id for update;
  if p.id is null or p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if _safe_connection_checked is distinct from true or length(trim(coalesce(_safe_approach,''))) not between 1 and 1000 then
    raise exception 'SAFE_CONNECTION_REQUIRED' using errcode='23514'; end if;
  if p.approval_status<>'approved' or p.lifecycle_status not in ('approved','active') then raise exception 'PORTAL_NOT_APPROVED' using errcode='23514'; end if;
  select * into l from app_private.portal_private_locations where portal_id=p.id for update;
  lat:=coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude);lon:=coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude);
  if lat is null or lon is null then raise exception 'LOCATION_REQUIRED' using errcode='23514'; end if;
  select n.* into anchor from app_private.walking_nodes n where n.event_id=e.id and n.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=e.id and edge.approved_at is not null and edge.closed_at is null
      and (edge.from_node_id=n.id or edge.to_node_id=n.id))
    order by app_private.location_distance_m(lat,lon,n.coordinate[1]::numeric,n.coordinate[0]::numeric),n.id limit 1;
  distance:=app_private.location_distance_m(lat,lon,anchor.coordinate[1]::numeric,anchor.coordinate[0]::numeric);
  if anchor.id is null or distance is null or distance>75 then raise exception 'CONNECTION_TOO_FAR' using errcode='23514'; end if;
  select * into own_node from app_private.walking_nodes where portal_id=p.id and event_id=e.id order by id limit 1 for update;
  if own_node.id is null then
    insert into app_private.walking_nodes(event_id,kind,portal_id,coordinate,verified_at,verified_by)
      values(e.id,'portal',p.id,point(lon,lat),clock_timestamp(),auth.uid()) returning * into own_node;
  else
    update app_private.walking_nodes set coordinate=point(lon,lat) where id=own_node.id;
    update app_private.walking_nodes set verified_at=clock_timestamp(),verified_by=auth.uid() where id=own_node.id returning * into own_node;
  end if;
  if own_node.id<>anchor.id then
    insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,
      wheelchair_accessible,approved_at,approved_by,geometry_geojson)
    values(e.id,own_node.id,anchor.id,greatest(1,ceil(distance)::integer),greatest(1,ceil(distance/1.1)::integer),
      _step_free_checked is true,clock_timestamp(),auth.uid(),jsonb_build_object('type','LineString','coordinates',
        jsonb_build_array(jsonb_build_array(lon,lat),jsonb_build_array(anchor.coordinate[0],anchor.coordinate[1]))));
  end if;
  update app_private.portal_private_locations set walking_connection_verified_at=clock_timestamp(),walking_connection_verified_by=auth.uid(),
    safe_walking_approach=trim(_safe_approach),verified_at=clock_timestamp(),verified_by=auth.uid() where portal_id=p.id;
  update app_private.portals set version=version+1 where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'portal.walking_connection_verified','portal',p.id,jsonb_build_object('version',p.version,
      'walkingNodeId',own_node.id,'anchorNodeId',anchor.id,'estimatedMeters',ceil(distance),'stepFreeChecked',_step_free_checked));
  perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',p.id,'version',p.version,'walkingConnectionVerified',true);
end;
$function$;

CREATE OR REPLACE FUNCTION api.group_journey_preference_save(_group_id uuid, _expected_version integer, _desired_ordinary_visits integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; actor uuid := auth.uid();
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  select * into g from app_private.walking_groups where id = _group_id for update;
  if actor is null or g.id is null or not app_private.is_current_leader(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if g.route_mode <> 'dynamic' then raise exception 'DYNAMIC_JOURNEY_REQUIRED' using errcode = '23514'; end if;
  if _expected_version is distinct from g.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if exists(select 1 from app_private.group_runs where group_id = _group_id) then
    raise exception 'JOURNEY_ALREADY_STARTED' using errcode = '23514';
  end if;
  if _desired_ordinary_visits is not null and _desired_ordinary_visits not between 1 and 1000 then
    raise exception 'INVALID_VISIT_PREFERENCE' using errcode = '22023';
  end if;
  update app_private.walking_groups set desired_ordinary_visits = _desired_ordinary_visits,
    version = version + 1, updated_at = now() where id = _group_id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values(g.event_id, actor, 'group.journey_preference_updated', 'walking_group', g.id,
    jsonb_build_object('desiredOrdinaryVisits', _desired_ordinary_visits));
  perform realtime.send(jsonb_build_object('resource', 'walking_group', 'id', g.id),
    'snapshot_changed', 'group:' || g.id::text, true);
  return api.group_journey_preference(_group_id);
end;
$function$;

CREATE OR REPLACE FUNCTION api.portal_room_update(_portal_id uuid, _operation text, _payload jsonb, _key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result jsonb;
  portal app_private.portals;
  help_channel uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _operation in ('status','details') then perform app_private.lock_evening_event((select evening_portal.event_id from app_private.portals evening_portal where evening_portal.id=_portal_id)); end if;

  if _operation in (
    'incident_create',
    'incident_status',
    'presentation_save',
    'presentation_submit',
    'presentation_activate',
    'simulation_start',
    'simulation_step',
    'simulation_reset'
  ) then
    return api.portal_v2_command(_portal_id, _operation, _payload, _key);
  end if;

  result := api.portal_room_update_v1(_portal_id, _operation, _payload, _key);
  if _operation <> 'help' then
    return result;
  end if;

  select * into portal
  from app_private.portals
  where id = _portal_id;
  perform app_private.poortkamer_channels(portal.event_id, portal.id);

  select id into help_channel
  from app_private.portal_room_channels
  where event_id = portal.event_id
    and portal_id is null
    and kind = 'community'
    and name = 'Hulp gevraagd'
    and archived_at is null;

  update app_private.portal_room_messages message
  set channel_id = help_channel
  where message.actor_id = auth.uid()
    and message.dedupe_key = _key
    and exists (
      select 1
      from app_private.portal_room_channels retired
      where retired.id = message.channel_id
        and retired.kind = 'community'
        and retired.name = 'Snoep & voorraad'
        and retired.archived_at is not null
    );

  if not found then
    insert into app_private.portal_room_messages(
      channel_id,
      actor_id,
      sender_portal_id,
      body,
      dedupe_key
    ) values (
      help_channel,
      auth.uid(),
      portal.id,
      portal.system_code || ' vraagt hulp met de snoepvoorraad. Neem contact op via deze poort in het Poortplein.',
      _key
    ) on conflict (actor_id, dedupe_key) do nothing;
  end if;

  return result;
end
$function$;

CREATE OR REPLACE FUNCTION api.portal_room_update_v1(_portal_id uuid, _operation text, _payload jsonb, _key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; result jsonb; request_hash text; receipt app_private.command_receipts; minutes integer; newstate app_private.portal_operation_status;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _operation in ('status','details') then perform app_private.lock_evening_event((select evening_portal.event_id from app_private.portals evening_portal where evening_portal.id=_portal_id)); end if;

 select * into p from app_private.portals where id=_portal_id for update;
 perform app_private.poortkamer_require(_portal_id,case when _operation='details' then 'details' else 'live' end);
 request_hash:=encode(extensions.digest(jsonb_build_array(_portal_id,_operation,_payload)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.room' and idempotency_key=_key::text;
 if found then if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 perform app_private.poortkamer_budget('room',30);
 if _operation='status' then
  if (_payload->>'version') is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  minutes:=(_payload->>'minutes')::integer; newstate:=(_payload->>'state')::app_private.portal_operation_status;
  if newstate not in ('open','paused','closed') or (minutes is not null and (newstate<>'paused' or minutes not in (5,10,15,20,30))) then raise exception 'INVALID_STATE'; end if;
  result:=api.portal_set_operational_state(p.id,newstate,(_payload->>'version')::integer,_payload->>'reason');
  if newstate='paused' and minutes is not null then
   update app_private.portals set pause_until=now()+make_interval(mins=>minutes) where id=p.id;
   update app_private.portal_status_history set resume_at=now()+make_interval(mins=>minutes) where id=(select id from app_private.portal_status_history where portal_id=p.id order by created_at desc,id desc limit 1);
  end if;
 elsif _operation='checklist' then
  insert into app_private.portal_readiness(portal_id,item,done,changed_by) values(p.id,_payload->>'item',(_payload->>'done')::boolean,auth.uid())
  on conflict(portal_id,item) do update set done=excluded.done,changed_by=excluded.changed_by,changed_at=now();
  result:=jsonb_build_object('item',_payload->>'item');
  perform app_private.poortkamer_signal(p.id,'portal.readiness.updated',result,'De gedeelde gereedcheck is bijgewerkt.');
 elsif _operation='stock' then
  update app_private.portals set stock_status=_payload->>'stock',stock_help_requested_at=case when _payload->>'stock' in ('plenty','sufficient') then null else stock_help_requested_at end where id=p.id;
  result:=jsonb_build_object('stock',_payload->>'stock');
  perform app_private.poortkamer_signal(p.id,'portal.stock.updated',result,'De snoepvoorraad is bijgewerkt.');
 elsif _operation='help' then
  perform app_private.poortkamer_budget('stock_help',2);
  if exists(select 1 from app_private.portal_community_mutes where event_id=p.event_id and user_id=auth.uid() and until_at>now()) then raise exception 'COMMUNITY_MUTED' using errcode='42501'; end if;
  if (_payload->>'shareCommunity')::boolean is distinct from true then raise exception 'EXPLICIT_CONFIRMATION_REQUIRED'; end if;
  perform app_private.poortkamer_channels(p.event_id,p.id);
  insert into app_private.portal_room_messages(channel_id,actor_id,sender_portal_id,body,dedupe_key)
  select id,auth.uid(),p.id,p.system_code||' vraagt hulp met de snoepvoorraad. Neem contact op via deze poort in het Poortplein.',_key from app_private.portal_room_channels where event_id=p.event_id and name='Snoep & voorraad' and kind='community';
  update app_private.portals set stock_help_requested_at=now() where id=p.id;
  result:=jsonb_build_object('shared',true);
  perform app_private.poortkamer_signal(p.id,'portal.stock.help',result,'Er is hulp voor snoepvoorraad gevraagd op het Poortplein.');
 elsif _operation='details' then
  if p.version is distinct from (_payload->>'version')::integer then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if char_length(trim(_payload->>'name')) not between 2 and 160 or char_length(coalesce(_payload->>'description',''))>2000 then raise exception 'INVALID_DETAILS'; end if;
  update app_private.portals set name=trim(_payload->>'name'),description=_payload->>'description',version=version+1 where id=p.id;
  result:=jsonb_build_object('updated',true);
  perform app_private.poortkamer_signal(p.id,'portal.details.updated','{}','De poortgegevens zijn bijgewerkt.');
 else raise exception 'INVALID_OPERATION'; end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.room',_key::text,request_hash,result,now()+interval '30 days');
 return result;
end $function$;

CREATE OR REPLACE FUNCTION api.portal_set_operational_state(_portal_id uuid, _state app_private.portal_operation_status, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  affected record;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_portal.event_id from app_private.portals evening_portal where evening_portal.id=_portal_id));

  perform app_private.poortkamer_require(_portal_id,'live');
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null or portal.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (
    select 1 from app_private.portal_owners owner
    where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null
  ) and not app_private.has_capability(portal.event_id, 'event_admin', actor)
    and not app_private.has_capability(portal.event_id, 'portals_manage', actor)
    and not app_private.has_capability(portal.event_id, 'live_support', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _state in ('paused', 'closed') and char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  update app_private.portals
  set pause_until = null, operation_status = _state, pause_after_current = _state = 'paused', version = version + 1
  where id = _portal_id returning * into portal;

  if exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    if _state = 'open' then
      update app_private.event_route_settings set finale_available = true, version = version + 1
      where event_id = portal.event_id;
    elsif _state = 'paused' then
      update app_private.event_route_settings set finale_available = false, version = version + 1
      where event_id = portal.event_id;
      update app_private.portal_reservations set status = 'cancelled',
        cancelled_reason = 'Laatste poort pauzeert', version = version + 1
      where portal_id = portal.id and kind = 'finale' and status = 'held';
    end if;
  end if;

  if _state in ('paused', 'closed') then
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = case when _state = 'closed' then 'Poort direct gesloten' else 'Poort pauzeert na huidige groep' end,
      version = version + 1
    where portal_id = _portal_id and status = 'held' and kind = 'ordinary';
  end if;
  if _state = 'closed' and exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    update app_private.event_route_settings set finale_available = false, version = version + 1 where event_id = portal.event_id;
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = 'Laatste poort direct gesloten', version = version + 1
    where portal_id = portal.id and kind = 'finale' and status in ('held', 'active');
    for affected in
      select run.id as run_id, run.group_id
      from app_private.group_runs run
      join app_private.walking_groups walking_group on walking_group.id = run.group_id
      where walking_group.event_id = portal.event_id and walking_group.route_mode = 'dynamic'
        and run.status in ('live', 'paused')
    loop
      update app_private.group_runs set status = 'paused', version = version + 1 where id = affected.run_id;
      insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
      select portal.event_id, affected.group_id, affected.run_id, portal.id, 'urgent', 'FINALE_UNAVAILABLE',
        'De eindpoort is gesloten. Gebruik uitsluitend de goedgekeurde noodafsluiting.'
      where not exists (select 1 from app_private.route_alerts where run_id = affected.run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    end loop;
  elsif _state = 'closed' then
    for affected in
      select stop.id as stop_id, stop.run_id, reservation.id as reservation_id
      from app_private.run_stops stop
      join app_private.group_runs run on run.id = stop.run_id and run.current_stop_id = stop.id and run.status = 'live'
      join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
      left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
      where stop.portal_id = portal.id and stop.state = 'active'
        and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
      for update of stop, run
    loop
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
      where id = affected.stop_id;
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Poort direct gesloten',
        reason = left(trim(_reason), 500), changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.stop_id and required_for_completion;
      update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Poort direct gesloten', version = version + 1
      where id = affected.reservation_id;
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      values (affected.run_id, affected.stop_id, portal.world_id, 'system_skipped')
      on conflict (run_stop_id) do nothing;
      update app_private.group_runs set current_stop_id = null, version = version + 1
      where id = affected.run_id;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.stop_id, 'stop.system_skipped', actor,
        jsonb_build_object('portalId', portal.id, 'reason', left(trim(_reason), 500)));
      perform app_private.dispatch_next_stop(affected.run_id, clock_timestamp());
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.operation_state_changed', 'portal', portal.id,
    jsonb_build_object('state', _state, 'reason', left(coalesce(trim(_reason), ''), 500)));
  insert into app_private.portal_status_history(portal_id,actor_id,state,reason) values(portal.id,actor,_state,left(trim(_reason),500));
  perform app_private.poortkamer_signal(portal.id,'portal.room.status',jsonb_build_object('state',_state),'De poortstatus is gewijzigd.');
  return jsonb_build_object('id', portal.id, 'state', portal.operation_status, 'version', portal.version, 'pauseAfterCurrent', portal.pause_after_current);
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_child_add(_registration_id uuid, _expected_registration_version integer, _first_name text, _age_at_event integer, _accessibility_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  event_record app_private.events;
  payment app_private.payment_requests;
  legacy_batch app_private.payment_link_batches;
  child_record app_private.children;
  registration_child app_private.registration_children;
  party_id uuid;
  party_children integer;
  event_children integer;
  active_before integer;
  amount_before integer;
  active_after integer;
  amount_after integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_registration.event_id from app_private.registrations evening_registration where evening_registration.id=_registration_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if nullif(trim(coalesce(_first_name, '')), '') is null
     or char_length(trim(_first_name)) > 80
     or _age_at_event not between 0 and 20
     or char_length(coalesce(_accessibility_note, '')) > 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select candidate.* into registration
  from app_private.registrations candidate
  where candidate.id = _registration_id
    and app_private.is_household_member(candidate.household_id, actor);
  if registration.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-batch:' || registration.event_id, 0));
  select * into event_record from app_private.events where id = registration.event_id for no key update;
  perform assignment.id
  from app_private.group_registrations assignment
  where assignment.registration_id = registration.id and assignment.superseded_at is null
  order by assignment.id
  for update;
  select * into registration from app_private.registrations where id = _registration_id for update;

  if registration.version is distinct from _expected_registration_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if not app_private.registration_children_editable(registration.id) then
    raise exception 'CHILDREN_LOCKED' using errcode = '23514';
  end if;

  select membership.party_id into party_id
  from app_private.together_memberships membership
  where membership.registration_id = registration.id and membership.left_at is null
  limit 1;
  if party_id is null then
    select count(*)::integer into party_children
    from app_private.registration_children child
    where child.registration_id = registration.id and child.participation_status = 'active';
  else
    perform party.id from app_private.together_parties party where party.id = party_id for update;
    party_children := app_private.together_party_child_count(party_id);
  end if;

  if party_children + 1 > coalesce((event_record.settings ->> 'maxGroupSize')::integer, 20) then
    raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514';
  end if;
  select count(*)::integer into event_children
  from app_private.registration_children child
  where child.event_id = registration.event_id and child.participation_status = 'active';
  if event_children + 1 > coalesce((event_record.settings ->> 'maxChildren')::integer, 300) then
    raise exception 'EVENT_CAPACITY_REACHED' using errcode = '23514';
  end if;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_before, amount_before
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  select * into payment
  from app_private.payment_requests
  where registration_id = registration.id
  order by created_at desc limit 1
  for update;

  if payment.id is not null and not payment.child_payment_mode then
    if payment.status in ('reported', 'partial', 'confirmed', 'refund_due')
       or exists (
         select 1 from app_private.payment_entries entry
         where entry.request_id = payment.id
           and entry.entry_type <> 'reported'
           and entry.amount_cents <> 0
       ) then
      raise exception 'LEGACY_PAYMENT_REQUIRES_ORGANIZER' using errcode = '23514';
    end if;

    if payment.payment_batch_id is not null then
      perform request.id
      from app_private.payment_requests request
      where request.payment_batch_id = payment.payment_batch_id
      order by request.id
      for update;
      select * into legacy_batch
      from app_private.payment_link_batches
      where id = payment.payment_batch_id
      for update;
      if legacy_batch.status <> 'awaiting_payment' then
        raise exception 'PAYMENT_REPORTED' using errcode = '23514';
      end if;
      update app_private.payment_requests
      set external_url = null, payment_batch_id = null,
          status = 'awaiting_link', version = version + 1
      where payment_batch_id = legacy_batch.id;
      update app_private.payment_link_batches
      set status = 'cancelled', version = version + 1, updated_at = now()
      where id = legacy_batch.id;
      insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
      values (registration.event_id, actor, 'payment.batch_cancelled_for_child_change',
        'payment_batch', legacy_batch.id, jsonb_build_object('registrationId', registration.id));
    elsif payment.external_url is not null then
      update app_private.payment_requests
      set external_url = null, status = 'awaiting_link', version = version + 1
      where id = payment.id;
    end if;
  end if;

  insert into app_private.children(household_id, first_name, age_at_event, accessibility_note)
  values (
    registration.household_id,
    trim(_first_name),
    _age_at_event::smallint,
    nullif(trim(coalesce(_accessibility_note, '')), '')
  ) returning * into child_record;

  insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
  values (registration.event_id, registration.id, child_record.id, event_record.price_cents)
  returning * into registration_child;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_after, amount_after
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  update app_private.registrations
  set price_snapshot_cents = amount_after, updated_at = now(), version = version + 1
  where id = registration.id
  returning * into registration;
  perform app_private.reconcile_registration_payment(registration.id);

  insert into app_private.registration_revisions(registration_id, version, changed_by, change_type, totals_before, totals_after)
  values (
    registration.id, registration.version, actor, 'parent_add_child',
    jsonb_build_object('childCount', active_before, 'amountCents', amount_before),
    jsonb_build_object('childCount', active_after, 'amountCents', amount_after)
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    registration.event_id, actor, 'registration.child_added_by_parent',
    'registration_child', registration_child.id,
    jsonb_build_object('registrationId', registration.id, 'childCount', active_after, 'amountCents', amount_after)
  );

  return jsonb_build_object(
    'registrationId', registration.id,
    'registrationChildId', registration_child.id,
    'version', registration.version,
    'priceCents', amount_after
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_child_remove(_registration_child_id uuid, _expected_registration_version integer, _expected_payment_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  registration_child app_private.registration_children;
  payment app_private.payment_requests;
  child_batch app_private.child_payment_batches;
  legacy_batch app_private.payment_link_batches;
  active_before integer;
  amount_before integer;
  active_after integer;
  amount_after integer;
  affected_registrations uuid[] := '{}'::uuid[];
  affected_registration_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_registration.event_id from app_private.registration_children evening_child join app_private.registrations evening_registration on evening_registration.id=evening_child.registration_id where evening_child.id=_registration_child_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select candidate.* into registration
  from app_private.registration_children child
  join app_private.registrations candidate on candidate.id = child.registration_id
  where child.id = _registration_child_id
    and app_private.is_household_member(candidate.household_id, actor);
  if registration.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-batch:' || registration.event_id, 0));
  perform assignment.id
  from app_private.group_registrations assignment
  where assignment.registration_id = registration.id and assignment.superseded_at is null
  order by assignment.id
  for update;
  select * into registration
  from app_private.registrations
  where id = registration.id
  for update;
  select * into registration_child
  from app_private.registration_children
  where id = _registration_child_id
  for update;

  if registration.version is distinct from _expected_registration_version
     or registration_child.payment_version is distinct from _expected_payment_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if not app_private.registration_children_editable(registration.id) then
    raise exception 'CHILDREN_LOCKED' using errcode = '23514';
  end if;
  if registration_child.participation_status <> 'active' then
    raise exception 'INVALID_TRANSITION' using errcode = '23514';
  end if;
  if not app_private.registration_child_unpaid(registration_child.id) then
    raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
  end if;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_before, amount_before
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  select * into payment
  from app_private.payment_requests
  where registration_id = registration.id
  order by created_at desc limit 1
  for update;

  if registration_child.child_payment_batch_id is not null then
    perform request.id
    from app_private.child_payment_members member
    join app_private.payment_requests request on request.id = member.payment_request_id
    where member.batch_id = registration_child.child_payment_batch_id
    order by request.id
    for update;
    perform child.id
    from app_private.child_payment_members member
    join app_private.registration_children child on child.id = member.registration_child_id
    where member.batch_id = registration_child.child_payment_batch_id
    order by child.id
    for update;

    select * into child_batch
    from app_private.child_payment_batches
    where id = registration_child.child_payment_batch_id
    for update;
    if child_batch.status <> 'awaiting_payment'
       or app_private.child_payment_batch_payload(child_batch.id) ->> 'status' <> 'awaiting_payment' then
      raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
    end if;

    select coalesce(array_agg(distinct request.registration_id order by request.registration_id), '{}'::uuid[])
    into affected_registrations
    from app_private.child_payment_members member
    join app_private.payment_requests request on request.id = member.payment_request_id
    where member.batch_id = child_batch.id;

    update app_private.child_payment_batches
    set status = 'cancelled', version = version + 1
    where id = child_batch.id;
    update app_private.registration_children child
    set child_payment_batch_id = null, payment_version = payment_version + 1
    where child.id in (
      select member.registration_child_id
      from app_private.child_payment_members member
      where member.batch_id = child_batch.id
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration.event_id, actor, 'payment.child_batch_cancelled_for_child_removal',
      'child_payment_batch', child_batch.id,
      jsonb_build_object('registrationId', registration.id, 'registrationChildId', registration_child.id)
    );
  elsif payment.id is not null and not payment.child_payment_mode and payment.payment_batch_id is not null then
    perform request.id
    from app_private.payment_requests request
    where request.payment_batch_id = payment.payment_batch_id
    order by request.id
    for update;
    select * into legacy_batch
    from app_private.payment_link_batches
    where id = payment.payment_batch_id
    for update;
    if legacy_batch.status <> 'awaiting_payment'
       or app_private.payment_batch_payload(legacy_batch.id) ->> 'status' <> 'awaiting_payment' then
      raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
    end if;

    select coalesce(array_agg(distinct request.registration_id order by request.registration_id), '{}'::uuid[])
    into affected_registrations
    from app_private.payment_requests request
    where request.payment_batch_id = legacy_batch.id;

    update app_private.payment_requests
    set external_url = null, payment_batch_id = null,
        status = 'awaiting_link', version = version + 1
    where payment_batch_id = legacy_batch.id;
    update app_private.payment_link_batches
    set status = 'cancelled', version = version + 1, updated_at = now()
    where id = legacy_batch.id;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration.event_id, actor, 'payment.batch_cancelled_for_child_removal',
      'payment_batch', legacy_batch.id,
      jsonb_build_object('registrationId', registration.id, 'registrationChildId', registration_child.id)
    );
  elsif payment.id is not null and not payment.child_payment_mode and payment.external_url is not null then
    update app_private.payment_requests
    set external_url = null, status = 'awaiting_link', version = version + 1
    where id = payment.id;
  end if;

  update app_private.registration_children
  set participation_status = 'cancelled',
      child_payment_batch_id = null,
      payment_version = payment_version + 1
  where id = registration_child.id;
  update app_private.children
  set archived_at = now(), updated_at = now(), version = version + 1
  where id = registration_child.child_id;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_after, amount_after
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  update app_private.registrations
  set price_snapshot_cents = amount_after, updated_at = now(), version = version + 1
  where id = registration.id
  returning * into registration;

  perform app_private.reconcile_registration_payment(registration.id);
  foreach affected_registration_id in array affected_registrations loop
    if affected_registration_id is distinct from registration.id then
      perform app_private.reconcile_registration_payment(affected_registration_id);
    end if;
  end loop;

  insert into app_private.registration_revisions(registration_id, version, changed_by, change_type, totals_before, totals_after)
  values (
    registration.id, registration.version, actor, 'parent_remove_child',
    jsonb_build_object('childCount', active_before, 'amountCents', amount_before),
    jsonb_build_object('childCount', active_after, 'amountCents', amount_after)
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    registration.event_id, actor, 'registration.child_removed_by_parent',
    'registration_child', registration_child.id,
    jsonb_build_object('registrationId', registration.id, 'childCount', active_after, 'amountCents', amount_after)
  );

  return jsonb_build_object(
    'registrationId', registration.id,
    'registrationChildId', registration_child.id,
    'version', registration.version,
    'priceCents', amount_after
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_exact_preferences_save(_registration_id uuid, _preferred_start_at timestamp with time zone, _desired_end_at timestamp with time zone, _expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  settings app_private.event_route_settings;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_registration.event_id from app_private.registrations evening_registration where evening_registration.id=_registration_id));

  select * into registration from app_private.registrations where id = _registration_id for update;
  if actor is null or registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if registration.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if registration.preference_change_status <> 'editable' or exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
    where assignment.registration_id = registration.id and assignment.superseded_at is null
  ) then raise exception 'PREFERENCES_LOCKED' using errcode = '23514'; end if;
  perform app_private.validate_exact_preferences(registration.event_id, _preferred_start_at, _desired_end_at);
  select * into settings from app_private.event_route_settings where event_id = registration.event_id;
  update app_private.registrations
  set preferred_start_at = _preferred_start_at,
      desired_end_at = _desired_end_at,
      requested_ordinary_stop_at = least(_desired_end_at, settings.global_ordinary_stop_at),
      version = version + 1,
      updated_at = now()
  where id = registration.id returning * into registration;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.exact_preferences_updated', 'registration', registration.id,
    jsonb_build_object('preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at));
  return jsonb_build_object(
    'registrationId', registration.id, 'preferredStartAt', registration.preferred_start_at,
    'desiredEndAt', registration.desired_end_at, 'ordinaryStopAt', registration.requested_ordinary_stop_at,
    'version', registration.version, 'editable', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_preferences_save(_registration_id uuid, _start_preference app_private.start_time_preference, _ordinary_stop_at timestamp with time zone, _expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  settings app_private.event_route_settings;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_registration.event_id from app_private.registrations evening_registration where evening_registration.id=_registration_id));

  select * into registration from app_private.registrations where id = _registration_id for update;
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if registration.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if registration.preference_change_status <> 'editable' or exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
    where assignment.registration_id = registration.id and assignment.superseded_at is null
  ) then raise exception 'PREFERENCES_LOCKED' using errcode = '23514'; end if;
  select * into settings from app_private.event_route_settings where event_id = registration.event_id;
  if _ordinary_stop_at is not null
     and (_ordinary_stop_at > settings.global_ordinary_stop_at
       or not (_ordinary_stop_at = any(settings.allowed_personal_stop_times))) then
    raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
  end if;
  update app_private.registrations
  set start_time_preference = _start_preference,
      requested_ordinary_stop_at = _ordinary_stop_at,
      version = version + 1
  where id = registration.id returning * into registration;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.preferences_updated', 'registration', registration.id,
    jsonb_build_object('startPreference', _start_preference, 'ordinaryStopAt', _ordinary_stop_at));
  return jsonb_build_object(
    'registrationId', registration.id, 'startPreference', registration.start_time_preference,
    'ordinaryStopAt', registration.requested_ordinary_stop_at, 'version', registration.version,
    'editable', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_save_draft(_event_slug text, _payload jsonb, _expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  adult_name text := nullif(trim(_payload #>> '{adult,name}'), '');
  requested_together_code text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or jsonb_typeof(_payload -> 'adult') <> 'object' or adult_name is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  requested_together_code := upper(regexp_replace(trim(coalesce(_payload ->> 'togetherCode', '')), '[^A-Za-z0-9]', '', 'g'));
  if requested_together_code <> '' and requested_together_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;
  _payload := jsonb_set(
      _payload - 'togetherPreference' - 'togetherCode',
      '{adult}',
      (_payload -> 'adult') - 'householdLabel',
      true
    ) || jsonb_build_object('togetherCode', requested_together_code);

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();
    insert into app_private.households(id, label, primary_contact_user_id, phone)
    values (
      v_household_id,
      'Gezelschap ' || upper(substr(replace(v_household_id::text, '-', ''), 1, 6)),
      actor,
      nullif(trim(_payload #>> '{adult,phone}'), '')
    );
    insert into app_private.household_members(household_id, user_id, relation_role)
    values (v_household_id, actor, 'owner');
  else
    update app_private.households
    set phone = nullif(trim(_payload #>> '{adult,phone}'), ''),
        version = version + 1
    where id = v_household_id;
  end if;

  update app_private.profiles
  set display_name = adult_name, version = version + 1
  where user_id = actor;

  insert into app_private.registration_drafts(event_id, household_id, payload)
  values (v_event_id, v_household_id, _payload)
  on conflict (event_id, household_id) do update
    set payload = excluded.payload,
        version = app_private.registration_drafts.version + 1
    where _expected_version is null or app_private.registration_drafts.version = _expected_version
  returning * into draft_record;

  if draft_record.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  return jsonb_build_object('id', draft_record.id, 'version', draft_record.version, 'savedAt', draft_record.updated_at);
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_submit(_event_slug text, _terms_version text, _privacy_version text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  registration_record app_private.registrations;
  child jsonb;
  child_count integer;
  total integer;
  receipt app_private.command_receipts;
  actor_email text;
  requested_together_code text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false)
     or (event_record.registration_open_at is not null and event_record.registration_open_at > now())
     or (event_record.registration_close_at is not null and event_record.registration_close_at <= now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;

  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'registration.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;
  if v_household_id is null then raise exception 'HOUSEHOLD_REQUIRED' using errcode = '23514'; end if;

  select * into draft_record from app_private.registration_drafts
  where app_private.registration_drafts.event_id = event_record.id
    and app_private.registration_drafts.household_id = v_household_id
  for update;
  if draft_record.id is null then raise exception 'DRAFT_REQUIRED' using errcode = '23514'; end if;
  if jsonb_typeof(draft_record.payload -> 'children') <> 'array' then raise exception 'CHILDREN_REQUIRED' using errcode = '23514'; end if;
  child_count := jsonb_array_length(draft_record.payload -> 'children');
  if child_count < 1 then raise exception 'EMPTY_REGISTRATION' using errcode = '23514'; end if;
  if (select count(*) from app_private.registration_children where event_id = event_record.id and participation_status = 'active') + child_count > coalesce((event_record.settings ->> 'maxChildren')::integer, 300) then
    raise exception 'EVENT_CAPACITY_REACHED' using errcode = '23514';
  end if;

  requested_together_code := nullif(upper(trim(coalesce(draft_record.payload ->> 'togetherCode', ''))), '');
  if requested_together_code is not null and requested_together_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;
  total := child_count * event_record.price_cents;

  select * into registration_record from app_private.registrations
  where app_private.registrations.event_id = event_record.id
    and app_private.registrations.household_id = v_household_id
    and status <> 'cancelled'
  for update;
  if registration_record.id is null then
    insert into app_private.registrations(
      event_id, household_id, status, reference, submitted_at, terms_version, terms_accepted_at,
      privacy_version, marketing_consent, price_snapshot_cents
    ) values (
      event_record.id, v_household_id, 'submitted',
      upper('DPH-' || extract(year from event_record.local_date)::text || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
      now(), _terms_version, now(), _privacy_version,
      coalesce((draft_record.payload ->> 'marketingConsent')::boolean, false), total
    ) returning * into registration_record;

    for child in select value from jsonb_array_elements(draft_record.payload -> 'children') loop
      if nullif(trim(child ->> 'name'), '') is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
      with inserted_child as (
        insert into app_private.children(household_id, first_name, age_at_event, age_band, accessibility_note)
        values (
          v_household_id,
          trim(child ->> 'name'),
          case when child ->> 'age' ~ '^[0-9]{1,2}$' then (child ->> 'age')::smallint else null end,
          nullif(trim(child ->> 'ageBand'), ''),
          nullif(trim(child ->> 'accessibilityNote'), '')
        ) returning id
      )
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
      select event_record.id, registration_record.id, id, event_record.price_cents from inserted_child;
    end loop;

    perform app_private.attach_registration_to_together_party(registration_record.id, requested_together_code);

    insert into app_private.payment_requests(registration_id, purpose, amount_cents, reference, status)
    values (registration_record.id, 'event_registration', total, registration_record.reference, 'awaiting_link');

    select email into actor_email from auth.users where id = actor;
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'registration:' || registration_record.id::text || ':received:' || actor::text,
      'registration_received', actor::text, actor_email,
      jsonb_build_object(
        'reference', registration_record.reference,
        'childCount', child_count,
        'amountCents', total,
        'paymentStatus', 'awaiting_link',
        'togetherCode', registration_record.together_code
      )
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, actor, 'registration.submitted', 'registration', registration_record.id, jsonb_build_object('childCount', child_count, 'amountCents', total));

    update app_private.registration_drafts
    set payload = payload - 'togetherCode' - 'togetherPreference', version = version + 1
    where id = draft_record.id;
  end if;

  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'registration.submit', _idempotency_key, _request_hash,
    jsonb_build_object(
      'id', registration_record.id,
      'reference', registration_record.reference,
      'status', registration_record.status,
      'priceCents', registration_record.price_snapshot_cents,
      'togetherCode', registration_record.together_code
    ),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.registration_together_request(_registration_id uuid, _together_code text, _idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare registration app_private.registrations; event_record app_private.events; source_id uuid; target_id uuid;
  code text:=upper(trim(_together_code)); request app_private.together_join_requests; preview jsonb;
  receipt app_private.command_receipts; request_hash text; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event((select evening_registration.event_id from app_private.registrations evening_registration where evening_registration.id=_registration_id));

  select * into registration from app_private.registrations where id=_registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if code is null or code !~ '^[A-HJ-NP-Z2-9]{4}$' then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  if char_length(coalesce(_idempotency_key,'')) not between 10 and 100 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  select * into event_record from app_private.events where id=registration.event_id for no key update;
  select * into registration from app_private.registrations where id=_registration_id for update;
  request_hash:=encode(extensions.digest(jsonb_build_array(registration.id,code)::text,'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='together.participantRequest' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023'; end if;
    return receipt.safe_result;
  end if;
  if registration.status<>'submitted' or event_record.phase not in('draft','registration_open','registration_closed','planning') then
    raise exception 'TOGETHER_LOCKED' using errcode='23514'; end if;
  select party_id into source_id from app_private.together_memberships where registration_id=registration.id and left_at is null;
  select m.party_id into target_id from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null
    where r.event_id=registration.event_id and r.together_code=code and r.status='submitted';
  if source_id is null or target_id is null or source_id=target_id then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  perform id from app_private.together_parties where id in(source_id,target_id) order by id for update;
  select * into request from app_private.together_join_requests where source_party_id=source_id and status='pending';
  if request.id is not null then
    if request.requested_by_registration_id<>registration.id or request.requested_code<>code then
      raise exception 'OPEN_TOGETHER_REQUEST' using errcode='23514'; end if;
  else
    preview:=app_private.together_merge_preview(event_record.id,source_id,target_id);
    -- Capacity above the configured limit remains an explicit organizer decision;
    -- locked/publication/group conflicts cannot be introduced through this new entrypoint.
    if jsonb_array_length((preview->'blockers') - 'over_capacity')>0 or (preview->>'projectedChildren')::integer>app_private.event_group_size_limit(event_record.id) then
      raise exception 'TOGETHER_REQUEST_BLOCKED' using errcode='23514'; end if;
    insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,
      requested_code,child_count_at_request,group_limit_at_request)
    values(event_record.id,source_id,target_id,registration.id,code,(preview#>>'{source,childCount}')::integer,
      (preview->>'maxGroupSize')::integer) returning * into request;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(event_record.id,auth.uid(),'together.join_requested','registration',registration.id,
        jsonb_build_object('requestId',request.id,'requiresApproval',true));
  end if;
  result:=jsonb_build_object('id',request.id,'status',request.status,'version',request.version);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'together.participantRequest',_idempotency_key,request_hash,result,now()+interval '10 years');
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.run_arrive_and_advance(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _participant_choices jsonb, _idempotency_key text, _portal_id uuid DEFAULT NULL::uuid, _method text DEFAULT 'qr'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; saved app_private.command_receipts; hashed text; result jsonb; entry record; statusrow app_private.stop_participant_statuses;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

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
end $function$;

CREATE OR REPLACE FUNCTION api.run_bulk_skip_pending(_run_id uuid, _stop_id uuid, _expected_run_version integer, _reason text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  receipt app_private.command_receipts;
  changed_count integer;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.bulkSkipPending' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    if run_record.id is null or not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.stop_participant_statuses
  set status = 'skipped', version = version + 1, changed_by = actor,
      reason = left(_reason, 500), decided_at = now()
  where run_stop_id = _stop_id and required_for_completion and status = 'pending';
  get diagnostics changed_count = row_count;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participants.bulk_skipped', actor, jsonb_build_object('count', changed_count, 'reason', left(_reason, 500)));
  result := jsonb_build_object('runId', _run_id, 'stopId', _stop_id, 'changedCount', changed_count, 'runVersion', run_record.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.bulkSkipPending', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$function$;

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
$function$;

CREATE OR REPLACE FUNCTION api.run_confirm_arrival(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _participant_choices jsonb, _idempotency_key text, _portal_id uuid DEFAULT NULL::uuid, _method text DEFAULT 'qr'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; saved app_private.command_receipts; hashed text; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null or char_length(coalesce(_idempotency_key,'')) not between 8 and 100 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=encode(extensions.digest(convert_to(jsonb_build_array(_run_id,_expected_stop_id,_expected_run_version,_credential,_portal_id,_method)::text,'utf8'),'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.confirmArrival' and idempotency_key=_idempotency_key;
 if saved.id is not null then
  if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return saved.safe_result;
 end if;
 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 result:=api.run_scan(_run_id,_expected_stop_id,_expected_run_version,_credential,_method);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.confirmArrival',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $function$;

CREATE OR REPLACE FUNCTION api.run_end_early(_run_id uuid, _expected_run_version integer, _participant_ids uuid[], _reason text, _idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; eventid uuid; item uuid; remaining integer; hashed text; saved app_private.command_receipts; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if cardinality(_participant_ids) is null or cardinality(_participant_ids)=0 or cardinality(_participant_ids)<>(select count(distinct i) from unnest(_participant_ids) i) then raise exception 'INVALID_ATTENDANCE'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 select event_id into eventid from app_private.walking_groups where id=r.group_id;
 -- Check household authority before returning any existing receipt.
 if r.id is null or exists(select 1 from unnest(_participant_ids) i where not exists(select 1 from app_private.run_participants p
 join app_private.registration_children rc on rc.id=p.registration_child_id join app_private.registrations reg on reg.id=rc.registration_id
 where p.id=i and p.run_id=_run_id and app_private.is_household_member(reg.household_id,auth.uid()))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=md5(jsonb_build_array(_run_id,_expected_run_version,_participant_ids,_reason)::text);
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.endEarly' and idempotency_key=_idempotency_key;
 if saved.id is not null then if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return saved.safe_result; end if;
 if r.version<>_expected_run_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status not in ('live','paused') then raise exception 'RUN_NOT_LIVE'; end if;
 if exists(select 1 from app_private.run_participants where id=any(_participant_ids) and (attendance<>'present' or departed_at is not null)) then raise exception 'INVALID_ATTENDANCE'; end if;
 select count(*) into remaining from app_private.run_participants where run_id=_run_id and attendance='present' and not(id=any(_participant_ids));
 if remaining>0 and app_private.is_current_leader(r.group_id,auth.uid()) then
  -- The leader's household cannot leave the remaining children without a handover.
  if not exists(select 1 from app_private.run_participants p join app_private.registration_children rc on rc.id=p.registration_child_id
   join app_private.registrations reg on reg.id=rc.registration_id where p.run_id=_run_id and p.attendance='present' and not(p.id=any(_participant_ids)) and app_private.is_household_member(reg.household_id,auth.uid()))
  then raise exception 'LEADERSHIP_HANDOVER_REQUIRED'; end if;
 end if;
 update app_private.run_participants set attendance='departed',departed_at=clock_timestamp(),departure_reason='early',roster_version=roster_version+1 where id=any(_participant_ids) and run_id=_run_id;
 update app_private.stop_participant_statuses set required_for_completion=false,exclusion_reason='departed',version=version+1,changed_by=auth.uid()
 where run_stop_id=r.current_stop_id and run_participant_id=any(_participant_ids);
 update app_private.group_runs set version=version+1,
 status=case when remaining=0 then 'stopped'::app_private.run_status else status end,
 current_stop_id=case when remaining=0 then null else current_stop_id end,
 stopped_reason=case when remaining=0 then 'all_participants_departed' else stopped_reason end,
 finished_at=case when remaining=0 then clock_timestamp() else finished_at end where id=_run_id;
 if remaining=0 then update app_private.walking_groups set status='stopped',version=version+1 where id=r.group_id; end if;
 insert into app_private.journey_events(run_id,stop_id,event_type,actor_id,safe_metadata) values(_run_id,r.current_stop_id,'household.departed',auth.uid(),jsonb_build_object('participants',_participant_ids,'reason','early'));
 result:=jsonb_build_object('ok',true,'remainingParticipants',remaining);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.endEarly',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $function$;

CREATE OR REPLACE FUNCTION api.run_mark_departed(_run_id uuid, _stop_id uuid, _run_participant_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  remaining integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if nullif(trim(_reason), '') is null then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) and not app_private.has_capability((select event_id from app_private.walking_groups where id = run_record.group_id), 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.run_participants set attendance = 'departed', departed_at = now(), roster_version = roster_version + 1
  where id = _run_participant_id and run_id = _run_id and attendance = 'present';
  if not found then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;
  update app_private.stop_participant_statuses set required_for_completion = false, exclusion_reason = 'departed', reason = _reason, version = version + 1, changed_by = actor
  where run_stop_id = _stop_id and run_participant_id = _run_participant_id;
  update app_private.group_runs set version = version + 1 where id = _run_id returning * into run_record;
  select count(*) into remaining from app_private.run_participants where run_id = _run_id and attendance = 'present';
  if remaining = 0 then
    update app_private.group_runs set status = 'stopped', stopped_reason = 'all_participants_departed', finished_at = now(), current_stop_id = null, version = version + 1 where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'stopped', version = version + 1 where id = run_record.group_id;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participant.departed', actor, jsonb_build_object('runParticipantId', _run_participant_id, 'reason', left(_reason, 200)));
  return jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'remainingParticipants', remaining);
end;
$function$;

CREATE OR REPLACE FUNCTION api.run_scan(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select credential.* into credential_record
  from app_private.run_stops run_stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    -- A pause means "no new groups". A group already inside may still scan and
    -- finish safely; a direct close remains blocked.
    and portal.operation_status in ('open', 'paused')
    and credential.revoked_at is null and credential.valid_from <= now()
    and (credential.valid_until is null or credential.valid_until > now())
    and (
      (_method = 'qr' and credential.token_hash = extensions.digest(convert_to(_credential, 'utf8'), 'sha256'))
      or (_method = 'short_code' and credential.short_code_hash = extensions.digest(convert_to(upper(trim(_credential)), 'utf8'), 'sha256'))
    )
  order by credential.version desc limit 1;
  if credential_record.id is null then raise exception 'WRONG_PORTAL' using errcode = '22023'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
end;
$function$;

CREATE OR REPLACE FUNCTION api.run_scan_validate(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _portal_id uuid DEFAULT NULL::uuid, _method text DEFAULT 'qr'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 return jsonb_build_object('valid',true);
end $function$;

CREATE OR REPLACE FUNCTION api.run_set_state(_run_id uuid, _state app_private.run_status, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); run_record app_private.group_runs; event_id uuid; leader boolean; support boolean;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select run.* into run_record from app_private.group_runs run where run.id = _run_id for update;
  if run_record.id is null or run_record.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select walking_group.event_id into event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
  leader := app_private.is_current_leader(run_record.group_id, actor);
  support := app_private.has_capability(event_id, 'live_support', actor);
  if not (leader or support) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _state not in ('live', 'paused', 'stopped') or (_state in ('paused', 'stopped') and nullif(trim(_reason), '') is null) then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if _state = 'stopped' and not support then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if run_record.status = 'completed' or run_record.status = 'stopped' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  if _state = 'live' and run_record.status <> 'paused' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.group_runs set status = _state, stopped_reason = case when _state = 'stopped' then _reason else stopped_reason end, version = version + 1 where id = _run_id returning * into run_record;
  if _state = 'stopped' then update app_private.walking_groups set status = 'stopped', version = version + 1 where id = run_record.group_id; end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata) values (_run_id, run_record.current_stop_id, 'run.' || _state::text, actor, jsonb_build_object('reason', left(coalesce(_reason, ''), 300)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change) values (event_id, actor, 'run.' || _state::text, 'group_run', _run_id, jsonb_build_object('reason', left(coalesce(_reason, ''), 300)));
  return jsonb_build_object('id', run_record.id, 'status', run_record.status, 'version', run_record.version);
end;
$function$;

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
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_group_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for no key update;
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
$function$;

CREATE OR REPLACE FUNCTION api.run_support_override(_run_id uuid, _stop_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  v_event_id uuid;
  credential_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select event_id into v_event_id from app_private.walking_groups where id = run_record.group_id;
  if run_record.status <> 'live' or not app_private.has_capability(v_event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select credential.id into credential_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portal_credentials credential on credential.portal_id = coalesce(stop.portal_id, plan_stop.portal_id) and credential.revoked_at is null
  where stop.id = _stop_id order by credential.version desc limit 1;
  if credential_id is null then raise exception 'NO_ACTIVE_CREDENTIAL' using errcode = '23514'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  select _stop_id, credential.id, credential.version, actor, 'support_override'
  from app_private.portal_credentials credential where credential.id = credential_id
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.support_override', actor, jsonb_build_object('reason', left(trim(_reason), 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.support_override', 'group_run', _run_id,
    jsonb_build_object('stopId', _stop_id, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('accepted', true, 'stopId', _stop_id, 'override', true);
end;
$function$;

CREATE OR REPLACE FUNCTION api.run_system_skip(_run_id uuid, _stop_id uuid, _expected_run_version integer, _reason text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  next_stop app_private.run_stops;
  receipt app_private.command_receipts;
  portal_state app_private.portal_operation_status;
  portal_id uuid;
  world_id uuid;
  v_event_id uuid;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.systemSkip' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
    if run_record.id is null or not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    return receipt.safe_result;
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select portal.id, portal.world_id, portal.operation_status into portal_id, world_id, portal_state
  from app_private.route_plan_stops plan_stop
  join app_private.portals portal on portal.id = plan_stop.portal_id
  where plan_stop.id = stop_record.plan_stop_id;
  if portal_state <> 'closed' then raise exception 'PORTAL_NOT_CLOSED' using errcode = '23514'; end if;
  if exists (select 1 from app_private.stop_participant_statuses where run_stop_id = _stop_id and status = 'visited') then
    raise exception 'VISIT_ALREADY_RECORDED' using errcode = '23514';
  end if;

  update app_private.stop_participant_statuses
  set required_for_completion = false, exclusion_reason = 'system_portal_closed', reason = left(_reason, 500), version = version + 1, changed_by = actor
  where run_stop_id = _stop_id and required_for_completion;
  update app_private.run_stops
  set state = 'completed', outcome = 'system_skipped', completed_at = now(), completion_actor = actor,
      completion_reason = left(_reason, 500), version = version + 1
  where id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, world_id, 'system_skipped');

  select * into next_stop from app_private.run_stops where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
  if next_stop.id is null then
    update app_private.group_runs set status = 'completed', current_stop_id = null, finished_at = now(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
  else
    update app_private.run_stops set state = 'active', opened_at = now(), version = version + 1 where id = next_stop.id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select next_stop.id, participant.id from app_private.run_participants participant
    where participant.run_id = _run_id and participant.attendance = 'present';
    update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
    where id = _run_id returning * into run_record;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.system_skipped', actor, jsonb_build_object('portalId', portal_id, 'reason', left(_reason, 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.system_skipped', 'group_run', _run_id, jsonb_build_object('stopId', _stop_id, 'portalId', portal_id, 'reason', left(_reason, 500)));
  result := jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'completedStopId', _stop_id, 'outcome', 'system_skipped', 'hasNextStop', next_stop.id is not null);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.systemSkip', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION api.run_update_participant(_run_id uuid, _stop_id uuid, _run_participant_id uuid, _new_status app_private.participant_stop_status, _expected_run_version integer, _expected_status_version integer, _reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  status_record app_private.stop_participant_statuses;
  participant_household uuid;
  leader boolean;
  own_child boolean;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if _expected_status_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.run_participants where id=_run_participant_id and run_id=_run_id and attendance='present' and departed_at is null) then raise exception 'INVALID_ATTENDANCE' using errcode='23514'; end if;
  select status.* into status_record
  from app_private.stop_participant_statuses status
  where status.run_stop_id = _stop_id and status.run_participant_id = _run_participant_id for update;
  if status_record.id is null or status_record.version <> _expected_status_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select child.household_id into participant_household
  from app_private.run_participants participant
  join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
  join app_private.children child on child.id = registration_child.child_id
  where participant.id = _run_participant_id;
  leader := app_private.is_current_leader(run_record.group_id, actor);
  own_child := app_private.is_household_member(participant_household, actor);
  if not leader and not own_child then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _new_status = 'visited' then
    if not leader then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'skipped' then
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if leader and nullif(trim(_reason), '') is null then raise exception 'PARENT_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'pending' then
    if not own_child or status_record.status <> 'skipped' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  end if;
  update app_private.stop_participant_statuses
  set status = _new_status, version = version + 1, changed_by = actor, reason = _reason,
      decided_at = case when _new_status = 'pending' then null else now() end
  where id = status_record.id returning * into status_record;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participant.' || _new_status::text, actor, jsonb_build_object('runParticipantId', _run_participant_id));
  return jsonb_build_object('id', status_record.id, 'status', status_record.status, 'version', status_record.version);
end;
$function$;

CREATE OR REPLACE FUNCTION api.worker_dispatch_due_groups(_event_slug text, _batch_size integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid;
  candidate record;
  dispatched integer := 0;
  alerted integer := 0;
begin
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  for candidate in
    select run.id, run.group_id, run.current_stop_id, run.updated_at, schedule.effective_ordinary_stop_at,
      stop.stop_kind, stop.opened_at, stop.reservation_id, reservation.expires_at as reservation_expires_at
    from app_private.group_runs run
    join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
    join app_private.group_schedule_revisions schedule on schedule.id = run.schedule_revision_id
    left join app_private.run_stops stop on stop.id = run.current_stop_id
    left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
    where walking_group.event_id = v_event_id and run.status = 'live'
    order by run.updated_at
    for update of run skip locked
    limit least(greatest(_batch_size, 1), 200)
  loop
    if candidate.current_stop_id is null then
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    elsif candidate.stop_kind = 'ordinary' and candidate.effective_ordinary_stop_at <= clock_timestamp() then
      if exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
        insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
        select v_event_id, candidate.group_id, candidate.id, 'warning', 'ACTIVE_VISIT_AFTER_STOP',
          'De stopgrens is bereikt tijdens een lopend bezoek; rond veilig af en ga daarna naar de eindpoort.'
        where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'ACTIVE_VISIT_AFTER_STOP');
        alerted := alerted + 1;
      else
        update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
          completed_at = clock_timestamp(), completion_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.current_stop_id and state = 'active';
        update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
          exclusion_reason = 'Stopgrens bereikt zonder bevestigde scan', reason = 'Automatische overgang naar laatste poort',
          decided_at = clock_timestamp(), version = version + 1
        where run_stop_id = candidate.current_stop_id and status = 'pending';
        update app_private.portal_reservations set status = 'cancelled',
          cancelled_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.reservation_id and status in ('held', 'active');
        update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
        insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
        values (candidate.id, candidate.current_stop_id, 'stop.cutoff_redirected', jsonb_build_object('reason', 'Stopgrens bereikt zonder bevestigde scan'));
        perform app_private.dispatch_next_stop(candidate.id, clock_timestamp(), true, null);
        dispatched := dispatched + 1;
      end if;
    elsif candidate.stop_kind = 'ordinary'
      and candidate.reservation_expires_at <= clock_timestamp()
      and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
        completed_at = clock_timestamp(), completion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', version = version + 1
      where id = candidate.current_stop_id and state = 'active';
      update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
        exclusion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', reason = 'Automatische herplanning naar een veilige actuele bestemming',
        decided_at = clock_timestamp(), version = version + 1
      where run_stop_id = candidate.current_stop_id and status = 'pending';
      update app_private.portal_reservations set status = 'expired', version = version + 1
      where id = candidate.reservation_id and status in ('held', 'active');
      update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (candidate.id, candidate.current_stop_id, 'stop.reservation_expired',
        jsonb_build_object('reason', 'Aankomstvenster verlopen zonder bevestigde scan'));
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      values (v_event_id, candidate.group_id, candidate.id, 'warning', 'DESTINATION_EXPIRED_REPLANNED',
        'De vorige aankomstreservering verliep zonder scan; de groep kreeg een nieuwe veilige serverbestemming.');
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    end if;
    if candidate.updated_at < clock_timestamp() - interval '10 minutes' then
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select v_event_id, candidate.group_id, candidate.id, 'warning', 'STALE_GROUP_CONNECTION',
        'De groep heeft langer dan tien minuten geen serverbevestiging gegeven.'
      where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'STALE_GROUP_CONNECTION');
      alerted := alerted + 1;
    end if;
  end loop;
  return jsonb_build_object('dispatched', dispatched, 'alerts', alerted);
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.assert_arrival_credential(_run_id uuid, _stop_id uuid, _version integer, _credential text, _method text, _portal_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; p app_private.portals; credentialid uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if r.version<>_version or r.current_stop_id is distinct from _stop_id then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status<>'live' then raise exception 'RUN_NOT_LIVE'; end if;
 select portal.* into p from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 join app_private.portals portal on portal.id=coalesce(s.portal_id,plan.portal_id) where s.id=_stop_id and s.run_id=_run_id and s.state='active' for share of portal;
 if p.id is null or (_portal_id is not null and p.id<>_portal_id) then raise exception 'WRONG_PORTAL'; end if;
 if p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 if _method not in ('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160 then raise exception 'WRONG_PORTAL'; end if;
 select c.id into credentialid from app_private.portal_credentials c where c.portal_id=p.id and c.revoked_at is null
 and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
 and ((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
 or (_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
 order by c.version desc limit 1;
 if credentialid is null then raise exception 'WRONG_PORTAL'; end if;
 return credentialid;
end $function$;

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
  return app_private.dispatch_next_stop_before_visit_preference(
    _run_id, _decision_at, _force_finale or reached, case when reached then null else coalesce(first_portal,_preferred_portal_id) end);
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
  join app_private.walking_nodes node on node.portal_id = stop.portal_id and node.event_id = group_record.event_id and node.verified_at is not null
  where stop.run_id = _run_id and stop.plan_stop_id is null and stop.state = 'completed'
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
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) as departure_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) as earliest_finale_at,
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
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
        and exists (
          select 1 from app_private.portal_windows portal_window
          where portal_window.portal_id = portal.id
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) >= portal_window.opens_at
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) < portal_window.closes_at
            and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer) <= portal_window.closes_at
            and portal_window.max_children_per_visit>=v_child_count
        )
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at
        and not exists (
          select 1 from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')
            and (reservation.expires_at is null or reservation.expires_at > _decision_at)
            and reservation.reserved_from < _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer)
            and reservation.reserved_until > _decision_at + make_interval(secs => source_path.duration_seconds::integer)
        )
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
      and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
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
$function$;

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
$function$;

CREATE OR REPLACE FUNCTION app_private.publish_startregie_ops(_event_slug text, _schedule_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); event_record app_private.events; result jsonb; next_version integer; version_id uuid;
begin
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select * into event_record from app_private.events where slug = _event_slug for no key update;
  if actor is null or event_record.id is null or not app_private.has_capability(event_record.id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  result := app_private.publish_group_schedules_ops(_event_slug, _schedule_ids, _reason);
  update app_private.start_planning_versions set state = 'superseded'
    where event_id = event_record.id and state = 'published';
  select coalesce(max(version), 0) + 1 into next_version
    from app_private.start_planning_versions where event_id = event_record.id;
  insert into app_private.start_planning_versions(event_id, version, schedule_ids, snapshot, published_by, reason)
  values (event_record.id, next_version, _schedule_ids,
    jsonb_build_object('scheduleIds', _schedule_ids, 'publishedCount', cardinality(_schedule_ids)), actor, trim(_reason))
  returning id into version_id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'start_planning.published', 'start_planning', version_id,
    jsonb_build_object('version', next_version, 'changedSchedules', cardinality(_schedule_ids), 'reason', left(trim(_reason), 500)));
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'id', version_id, 'version', next_version),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result || jsonb_build_object('planningVersionId', version_id, 'planningVersion', next_version);
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.try_reserve_finale(_run_id uuid, _earliest_arrival timestamp with time zone, _decision_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  settings app_private.event_route_settings;
  v_child_count integer;
  candidate_time timestamptz;
  candidate_end timestamptz;
  active_groups integer;
  active_children integer;
  reservation_id uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if settings.final_portal_id is null or not settings.finale_available then return null; end if;
  select count(*) into v_child_count from app_private.run_participants
  where run_id = _run_id and attendance = 'present';
  if v_child_count = 0 or v_child_count > settings.finale_max_concurrent_children then return null; end if;

  update app_private.portal_reservations
  set status = 'cancelled', cancelled_reason = 'Vervangen door actuele finaleprognose', version = version + 1
  where run_id = _run_id and kind = 'finale' and status in ('held', 'active');
  candidate_time := greatest(
    settings.finale_opens_at,
    date_trunc('minute', _earliest_arrival) + case when date_trunc('minute', _earliest_arrival) < _earliest_arrival then interval '1 minute' else interval '0' end
  );
  while candidate_time <= settings.finale_last_arrival_at loop
    candidate_end := candidate_time + make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds);
    exit when candidate_end > settings.finale_closes_at;
    select count(*), coalesce(sum(reservation.child_count), 0)::integer
      into active_groups, active_children
    from app_private.portal_reservations reservation
    where reservation.portal_id = settings.final_portal_id
      and reservation.kind = 'finale' and reservation.status in ('held', 'active')
      and (reservation.expires_at is null or reservation.expires_at > _decision_at)
      and reservation.reserved_from < candidate_end and reservation.reserved_until > candidate_time;
    if active_groups < settings.finale_max_concurrent_groups
       and active_children + v_child_count <= settings.finale_max_concurrent_children then
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at
      ) values (
        group_record.event_id, settings.final_portal_id, group_record.id, _run_id, 'finale', 'held',
        candidate_time, candidate_end, v_child_count, settings.finale_closes_at
      ) returning id into reservation_id;
      return reservation_id;
    end if;
    candidate_time := candidate_time + interval '1 minute';
  end loop;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.enforce_twenty_child_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare total integer; before_count integer; maximum integer; eventid uuid; target uuid; old_active boolean:=false; ids uuid[];
begin
 -- Keep the trigger identity for compatibility, replace its former fixed policy.
 if tg_table_name='together_memberships' then
  if new.left_at is not null then return new; end if;
  select event_id into eventid from app_private.together_parties where id=new.party_id;
  perform 1 from app_private.events where id=eventid for no key update;
  perform 1 from app_private.together_parties where id=new.party_id for update;
  if not exists(select 1 from app_private.registrations r where r.id=new.registration_id and r.event_id=eventid) then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  select array_agg(distinct registration_id) into ids from app_private.together_memberships where party_id=new.party_id and left_at is null;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=any(coalesce(ids,'{}')) and participation_status='active';
  select count(*)::integer into total from app_private.registration_children c where c.participation_status='active' and (c.registration_id=new.registration_id or c.registration_id in(select m.registration_id from app_private.together_memberships m where m.party_id=new.party_id and m.left_at is null and m.id<>new.id));
 elsif tg_table_name='group_registrations' then
  if new.superseded_at is not null then return new; end if;
  select event_id into eventid from app_private.walking_groups where id=new.group_id;
  perform 1 from app_private.events where id=eventid for no key update;
  perform 1 from app_private.walking_groups where id=new.group_id for update;
  if not exists(select 1 from app_private.registrations r where r.id=new.registration_id and r.event_id=eventid) then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  select array_agg(distinct registration_id) into ids from app_private.group_registrations where group_id=new.group_id and superseded_at is null;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=any(coalesce(ids,'{}')) and participation_status='active';
  select count(*)::integer into total from app_private.registration_children c where c.participation_status='active' and (c.registration_id=new.registration_id or c.registration_id in(select a.registration_id from app_private.group_registrations a where a.group_id=new.group_id and a.superseded_at is null and a.id<>new.id));
 else
  if new.participation_status<>'active' then return new; end if;
  if tg_op='UPDATE' then old_active:=old.participation_status='active' and old.registration_id=new.registration_id; end if;
  if old_active then return new; end if;
  select event_id into eventid from app_private.registrations where id=new.registration_id;
  if new.event_id is distinct from eventid then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  perform 1 from app_private.events where id=eventid for no key update;
  maximum:=app_private.event_group_size_limit(eventid);
  perform 1 from app_private.registrations where id=new.registration_id for update;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=new.registration_id and participation_status='active' and id<>new.id;
  if before_count+1>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',before_count+1)::text; end if;
  for target in select party_id from app_private.together_memberships where registration_id=new.registration_id and left_at is null order by party_id loop
   perform 1 from app_private.together_parties where id=target for update;
   select count(distinct c.id)::integer+1 into total from app_private.registration_children c join app_private.together_memberships m on m.registration_id=c.registration_id
    where m.party_id=target and m.left_at is null and c.participation_status='active' and c.id<>new.id;
   if total>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
  end loop;
  for target in select group_id from app_private.group_registrations where registration_id=new.registration_id and superseded_at is null order by group_id loop
   perform 1 from app_private.walking_groups where id=target for update;
   select count(distinct c.id)::integer+1 into total from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id
    where a.group_id=target and a.superseded_at is null and c.participation_status='active' and c.id<>new.id;
   if total>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
  end loop;
  return new;
 end if;
 maximum:=app_private.event_group_size_limit(eventid);
 if tg_table_name='together_memberships' then
 if total>maximum and exists(
  select 1 from app_private.group_size_override_commands review join app_private.events e on e.id=review.event_id
  where review.event_id=eventid and review.party_id=new.party_id and review.transaction_id=txid_current()
   and review.actor_id=auth.uid() and review.settings_version=e.settings_version and total<=review.approved_children
   and new.registration_id=any(review.approved_registration_ids)
   and not exists(select 1 from app_private.together_memberships m where m.party_id=new.party_id and m.left_at is null
     and not(m.registration_id=any(review.approved_registration_ids)))
 ) then return new; end if;
 end if;
 if total>maximum and total>before_count then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.guard_registration_draft_child_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare maximum integer; current_count integer:=0; proposed integer;
begin
 perform 1 from app_private.events where id=new.event_id for no key update;
 maximum:=app_private.event_group_size_limit(new.event_id);
 if jsonb_typeof(new.payload->'children')='array' then
  proposed:=jsonb_array_length(new.payload->'children');
  if tg_op='UPDATE' and old.event_id=new.event_id and jsonb_typeof(old.payload->'children')='array' then current_count:=jsonb_array_length(old.payload->'children'); end if;
  if proposed>maximum and proposed>current_count then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',proposed)::text; end if;
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.dispatch_all_due_routes()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_slug text;
begin
  for event_slug in
    select event.slug from app_private.events event
    join app_private.event_route_settings settings on settings.event_id = event.id and settings.planner_mode = 'dynamic'
    where event.phase in ('ready', 'live', 'paused') order by event.id
  loop
    perform api.worker_dispatch_due_groups(event_slug, 100);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.poortkamer_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; row record; eventid uuid;
begin
 -- Discover candidates without holding portal locks. Serialize each event first,
 -- then recheck its due portals in the same order as manual status changes.
 for eventid in select distinct event_id from app_private.portals
  where operation_status='paused' and pause_until<=now() and approval_status='approved' order by event_id loop
  perform app_private.lock_evening_event(eventid);
  for p in select * from app_private.portals where event_id=eventid and operation_status='paused'
   and pause_until<=now() and approval_status='approved' order by id for update skip locked loop
   update app_private.portals set operation_status='open',pause_until=null,pause_after_current=false,version=version+1 where id=p.id;
   update app_private.event_route_settings set finale_available=true,version=version+1 where event_id=p.event_id and final_portal_id=p.id;
   insert into app_private.portal_status_history(portal_id,state,reason) values(p.id,'open','Getimede pauze verstreken');
   perform app_private.poortkamer_signal(p.id,'portal.pause.auto_resumed','{}','De getimede pauze is voorbij. De poort is weer open.');
  end loop;
 end loop;
 for p in select * from app_private.portals where operation_status='paused' and pause_until>now() and pause_until<=now()+interval '1 minute' loop
  perform app_private.poortkamer_push(p.id,'pause_1','pause:'||p.id||':'||p.pause_until);
 end loop;
 for row in
  with upcoming as(
   select id::text key,portal_id,reserved_from arrival from app_private.portal_reservations where status in ('held','active')
   union all
   select s.id::text,s.portal_id,s.planned_arrival_at from app_private.route_plan_stops s join app_private.route_plan_versions v on v.id=s.plan_version_id and v.state='published'
   join app_private.walking_groups g on g.id=v.group_id and g.route_mode<>'dynamic'
  ) select *,case when arrival<=now()+interval '3 minutes' then 'next_3' else 'next_10' end kind from upcoming where arrival>now() and arrival<=now()+interval '10 minutes'
 loop perform app_private.poortkamer_push(row.portal_id,row.kind,row.kind||':'||row.key); end loop;
 for row in select e.id,coalesce(s.portal_id,plan.portal_id) portal_id from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id where e.scanned_at>now()-interval '5 minutes'
 loop if row.portal_id is not null then perform app_private.poortkamer_push(row.portal_id,'arrived','arrived:'||row.id); end if; end loop;
 -- Delete messages and cascaded reactions/reports; retain membership/audit history.
 delete from app_private.portal_room_messages m using app_private.portal_room_channels c,app_private.events e where m.channel_id=c.id and c.event_id=e.id and now()>=((e.local_date+interval '1 month') at time zone e.timezone);
 delete from app_private.portal_push_outbox where completed_at<now()-interval '30 days';
end $function$;

notify pgrst,'reload schema';
