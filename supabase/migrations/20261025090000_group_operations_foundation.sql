-- Preserve identities/history; retired is an explicit preparation lifecycle.
set lock_timeout='5s';
alter table app_private.walking_groups drop constraint if exists walking_groups_status_check;
alter table app_private.walking_groups add constraint walking_groups_status_check check(status in ('draft','ready','live','completed','stopped','retired'));
alter table app_private.walking_groups add column if not exists retired_at timestamptz,
 add column if not exists composition_confirmed_hash text, add column if not exists composition_confirmed_at timestamptz,
 add column if not exists composition_confirmed_by uuid references auth.users(id), add column if not exists composition_revision integer not null default 0;
create table if not exists app_private.group_start_withdrawals (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
 group_id uuid not null references app_private.walking_groups(id), through_publication_order bigint not null,
 actor_id uuid not null references auth.users(id), reason text not null, created_at timestamptz not null default clock_timestamp());
create index if not exists group_start_withdrawals_current on app_private.group_start_withdrawals(group_id,through_publication_order desc);
alter table app_private.group_start_withdrawals enable row level security;
revoke all on app_private.group_start_withdrawals from public,anon,authenticated;
create table if not exists app_private.start_composition_hash_compatibility (
 schedule_id uuid primary key references app_private.group_schedule_revisions(id),group_id uuid not null references app_private.walking_groups(id),legacy_hash text not null,structural_hash text not null);
alter table app_private.start_composition_hash_compatibility enable row level security;
revoke all on app_private.start_composition_hash_compatibility from public,anon,authenticated;
create temp table group_hash_upgrade on commit drop as select s.id,s.group_id,s.confirmed_composition_hash as legacy_hash, s.confirmed_composition_hash=app_private.start_group_composition_hash(s.group_id) as was_current from app_private.group_schedule_revisions s where s.confirmed_at is not null;


CREATE OR REPLACE FUNCTION app_private.start_group_composition_hash(_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select encode(extensions.digest(convert_to(coalesce(jsonb_agg(jsonb_build_object(
    'assignment',jsonb_build_array(a.id,a.registration_id,a.assignment_revision),'registrationStatus',r.status,
    'party',(select jsonb_agg(m.party_id order by m.party_id) from app_private.together_memberships m where m.registration_id=r.id and m.left_at is null),
    'children',(select jsonb_agg(jsonb_build_array(c.id,c.child_id,c.participation_status) order by c.id)
      from app_private.registration_children c where c.registration_id=r.id)) order by a.id),'[]'::jsonb)::text,'UTF8'),'sha256'),'hex')
  from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id
  where a.group_id=_group_id and a.superseded_at is null
$function$
;


CREATE OR REPLACE FUNCTION app_private.start_planning_input_hash(_event_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select encode(extensions.digest(convert_to(jsonb_build_object(
    'event',(select jsonb_build_object('settings',e.settings,'version',e.settings_version) from app_private.events e where e.id=_event_id),
    'routeSettings',(select to_jsonb(s) from app_private.event_route_settings s where s.event_id=_event_id),
    'points',(select jsonb_agg(to_jsonb(p) order by p.id) from app_private.start_points p where p.event_id=_event_id),
    'slots',(select jsonb_agg(to_jsonb(s) order by s.id) from app_private.start_slots s where s.event_id=_event_id),
    'groups',(select jsonb_agg(to_jsonb(g) order by g.id) from app_private.walking_groups g where g.event_id=_event_id),
    'registrations',(select jsonb_agg(jsonb_build_object('registration',jsonb_build_array(r.id,r.household_id,r.status,r.preferred_start_at,r.desired_end_at,r.requested_ordinary_stop_at,r.start_time_preference),
      'children',(select jsonb_agg(jsonb_build_array(c.id,c.child_id,c.participation_status) order by c.id) from app_private.registration_children c where c.registration_id=r.id),
      'assignments',(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.registration_id=r.id)) order by r.id)
      from app_private.registrations r where r.event_id=_event_id),
    'together',(select jsonb_agg(to_jsonb(m) order by m.party_id,m.registration_id) from app_private.together_memberships m join app_private.registrations r on r.id=m.registration_id where r.event_id=_event_id),
    'withdrawals',(select jsonb_agg(to_jsonb(w) order by w.id) from app_private.group_start_withdrawals w where w.event_id=_event_id),
    'publications',(select jsonb_agg(to_jsonb(p) order by p.publication_order) from app_private.group_start_publications p where p.event_id=_event_id)
    )::text,'UTF8'),'sha256'),'hex')
$function$
;


insert into app_private.start_composition_hash_compatibility(schedule_id,group_id,legacy_hash,structural_hash)
select u.id,u.group_id,u.legacy_hash,app_private.start_group_composition_hash(u.group_id) from group_hash_upgrade u where u.was_current on conflict do nothing;
create or replace function app_private.start_composition_hash_current(_schedule uuid,_group uuid,_hash text)
returns boolean language sql stable security definer set search_path='' as $$
 select _hash=app_private.start_group_composition_hash(_group) or exists(select 1 from app_private.start_composition_hash_compatibility c where c.schedule_id=_schedule and c.group_id=_group and c.legacy_hash=_hash and c.structural_hash=app_private.start_group_composition_hash(_group))
$$;
revoke all on function app_private.start_composition_hash_current(uuid,uuid,text) from public,anon,authenticated;

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


CREATE OR REPLACE FUNCTION api.admin_startregie_confirm_start(_event_slug text, _group_id uuid, _expected_revision integer, _expected_settings_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; g app_private.walking_groups; s app_private.group_schedule_revisions; p app_private.start_points;
begin
  select * into e from app_private.events where slug=_event_slug for update;
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
  -- Unpaid is an operational warning; financial status is preserved.

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
  -- Unpaid is an operational warning; financial status is preserved.


  -- The confirmation must still describe the current event and checked point.
  if exists(select 1 from app_private.group_schedule_revisions s
    join app_private.start_slots slot on slot.id=s.start_slot_id
    join app_private.start_points p on p.id=slot.start_point_id
    join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id
    where s.id=any(_schedule_ids) and (s.confirmed_at is null
      or s.confirmed_settings_version is distinct from e.settings_version
      or not app_private.start_composition_hash_current(s.id,g.id,s.confirmed_composition_hash)
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


CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
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
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.group_start_publications p1 where p1.group_id=g.id order by p1.publication_order desc limit 1) pub on true
    where g.event_id=e.id;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;


CREATE OR REPLACE FUNCTION app_private.group_size_policy_impact(_event uuid, _maximum integer, _target integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e app_private.events; groups jsonb; parties jsonb; fingerprint text;
begin
 if _maximum is null or _maximum<1 or (_target is not null and (_target<1 or _target>_maximum)) then
  raise exception 'INVALID_GROUP_LIMIT' using errcode='22023';
 end if;
 select * into e from app_private.events where id=_event;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'code',coalesce(g.system_code,g.code),
  'childCount',(select count(distinct c.id) from app_private.group_registrations a
   join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
   where a.group_id=g.id and a.superseded_at is null),'status',g.status,'version',g.version,
  'published',exists(select 1 from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null and a.published_at is not null)) order by g.id),'[]')
 into groups from app_private.walking_groups g where g.event_id=_event;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.cluster_reference,
  'childCount',app_private.together_party_child_count(p.id),'locked',p.locked_at is not null,
  'members',coalesce((select jsonb_agg(m.registration_id order by m.registration_id) from app_private.together_memberships m where m.party_id=p.id and m.left_at is null),'[]')) order by p.id),'[]')
 into parties from app_private.together_parties p where p.event_id=_event;
 fingerprint:=encode(extensions.digest(jsonb_build_object('event',e.id,'version',e.settings_version,
  'maximum',_maximum,'target',_target,'groups',groups,'parties',parties)::text,'sha256'),'hex');
 return jsonb_build_object('settingsVersion',e.settings_version,'maxGroupSize',app_private.event_group_size_limit(e.id),
  'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
  'followsMaximum',not(e.settings?'targetGroupSize'),'requestedMaximum',_maximum,'requestedTarget',coalesce(_target,least(15,_maximum)),
  'impactHash',fingerprint,'groups',coalesce((select jsonb_agg(item) from jsonb_array_elements(groups) item where (item->>'childCount')::integer>_maximum),'[]'),
  'parties',coalesce((select jsonb_agg(item-'members') from jsonb_array_elements(parties) item where (item->>'childCount')::integer>_maximum),'[]'));
end $function$
;


CREATE OR REPLACE FUNCTION app_private.published_start_projection(_group_id uuid, _at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.group_start_publications; result jsonb;
begin
  select * into p from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1;
  if p.id is null or exists(select 1 from app_private.walking_groups g where g.id=_group_id and g.retired_at is not null)
    or exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order) then return null; end if;
  result:=jsonb_build_object('startsAt',p.starts_at,'revision',p.revision,
    'publishedAt',p.published_at,'addressReleaseAt',p.starts_at-interval '1 hour',
    'addressReleased',_at>=p.starts_at-interval '1 hour','canStart',_at>=p.starts_at,'timePublished',true,
    'name','Startlocatie volgt','locationName','Startlocatie volgt','startPoint','Startlocatie volgt',
    'address',null,'startAddress',null,'coordinate',null,'linkedPortalId',null);
  if _at>=p.starts_at-interval '1 hour' then
    result:=result||jsonb_build_object('name',p.point_snapshot->>'name',
      'locationName',p.point_snapshot->>'name','startPoint',p.point_snapshot->>'name',
      'address',p.point_snapshot->>'private_address','startAddress',p.point_snapshot->>'private_address',
      'linkedPortalId',p.point_snapshot->>'linked_portal_id',
      'safeApproach',p.point_snapshot->>'safe_approach','arrivalInstructions',p.point_snapshot->>'public_arrival_instructions',
      'coordinate',jsonb_build_array(
        coalesce(p.point_snapshot->>'marker_longitude',p.point_snapshot->>'geocoded_longitude',p.point_snapshot->>'longitude')::numeric,
        coalesce(p.point_snapshot->>'marker_latitude',p.point_snapshot->>'geocoded_latitude',p.point_snapshot->>'latitude')::numeric));
  end if;
  return result;
end;
$function$
;


create or replace function app_private.current_start_publication(_group uuid)
returns setof app_private.group_start_publications language sql stable security definer set search_path='' as $$
 select p.* from app_private.group_start_publications p join app_private.walking_groups g on g.id=p.group_id and g.retired_at is null
 where p.group_id=_group and not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order)
 order by p.publication_order desc limit 1
$$;
revoke all on function app_private.current_start_publication(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.is_start_confirmation_current(_schedule_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select s.confirmed_at is not null and s.confirmed_settings_version=e.settings_version
    and s.confirmed_point_version=p.version and s.confirmed_start_point_id=p.id and s.confirmed_starts_at=slot.starts_at
    and s.confirmed_route_settings_version=settings.version and slot.active
    and app_private.start_composition_hash_current(s.id,g.id,s.confirmed_composition_hash)
    and app_private.start_point_ready_at(p.id,slot.starts_at)
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id join app_private.event_route_settings settings on settings.event_id=e.id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=_schedule_id),false)
$function$
;
