create or replace function app_private.start_planning_input_hash(_event_id uuid)
returns text language sql stable security definer set search_path='' as $$
  select encode(extensions.digest(convert_to(jsonb_build_object(
    'event',(select jsonb_build_object('settings',e.settings,'version',e.settings_version) from app_private.events e where e.id=_event_id),
    'routeSettings',(select to_jsonb(s) from app_private.event_route_settings s where s.event_id=_event_id),
    'points',(select jsonb_agg(to_jsonb(p) order by p.id) from app_private.start_points p where p.event_id=_event_id),
    'slots',(select jsonb_agg(to_jsonb(s) order by s.id) from app_private.start_slots s where s.event_id=_event_id),
    'groups',(select jsonb_agg(to_jsonb(g) order by g.id) from app_private.walking_groups g where g.event_id=_event_id),
    'registrations',(select jsonb_agg(jsonb_build_object('registration',to_jsonb(r),'payment',to_jsonb(p),
      'children',(select jsonb_agg(to_jsonb(c) order by c.id) from app_private.registration_children c where c.registration_id=r.id),
      'assignments',(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.registration_id=r.id)) order by r.id)
      from app_private.registrations r left join app_private.payment_requests p on p.registration_id=r.id where r.event_id=_event_id),
    'publications',(select jsonb_agg(to_jsonb(p) order by p.publication_order) from app_private.group_start_publications p where p.event_id=_event_id)
    )::text,'UTF8'),'sha256'),'hex')
$$;
revoke all on function app_private.start_planning_input_hash(uuid) from public,anon,authenticated;

-- Legacy publication names cannot bypass the required revision-bearing command.
-- The current simple UI and advanced board confirm separately from publication.
create or replace function api.admin_startregie_publish(_event_slug text,_schedule_ids uuid[],_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from app_private.events e where e.slug=_event_slug
    and app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  raise exception 'EXPECTED_REVISION_REQUIRED' using errcode='40001';
end;
$$;

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
  select id into v_event_id from app_private.events where slug = _event_slug for update;
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
  select * into event_record from app_private.events where slug = _event_slug for update;
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
$function$
;
create or replace function api.admin_publish_group_schedules(_event_slug text,_schedule_ids uuid[],_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return api.admin_startregie_publish(_event_slug,_schedule_ids,_reason);
end;
$$;
revoke all on function app_private.publish_group_schedules_ops(text,uuid[],text),app_private.publish_startregie_ops(text,uuid[],text) from public,anon,authenticated;

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
$function$
;

-- Existing static route revisions retain their frozen departure; first-time
-- departures use the explicit Startregie confirmation/publication commands.
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
  select id into v_event_id from app_private.events where slug = _event_slug for update;
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
$function$

;
