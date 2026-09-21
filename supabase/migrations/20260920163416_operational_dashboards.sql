-- Explicit operational read models and admin commands. Private tables remain
-- outside the Data API; every function derives the actor from auth.uid().

create or replace function api.portal_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  return (
    select jsonb_build_object(
      'application', jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'draft', application.private_draft_data),
      'portal', case when portal.id is null then null else jsonb_build_object(
        'id', portal.id, 'name', portal.name, 'description', portal.description, 'intensity', portal.intensity,
        'approvalStatus', portal.approval_status, 'operationStatus', portal.operation_status, 'version', portal.version,
        'world', world.name,
        'nextArrival', (
          select min(plan_stop.planned_arrival_at)
          from app_private.route_plan_stops plan_stop
          join app_private.route_plan_versions plan on plan.id = plan_stop.plan_version_id and plan.state = 'published'
          join app_private.group_runs run on run.active_plan_version_id = plan.id and run.status in ('ready', 'live', 'paused')
          where plan_stop.portal_id = portal.id and plan_stop.planned_arrival_at >= now()
        )
      ) end
    )
    from app_private.portal_applications application
    left join app_private.portals portal on portal.application_id = application.id
    left join app_private.worlds world on world.id = portal.world_id
    where application.event_id = v_event_id and application.applicant_user_id = actor
    order by application.created_at desc limit 1
  );
end;
$$;

create or replace function api.admin_dashboard(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'registration_manage', actor)
    or app_private.has_capability(v_event_id, 'portals_manage', actor)
    or app_private.has_capability(v_event_id, 'groups_manage', actor)
    or app_private.has_capability(v_event_id, 'live_support', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'event', (select jsonb_build_object('id', id, 'title', title, 'phase', phase, 'date', local_date, 'settingsVersion', settings_version) from app_private.events where id = v_event_id),
    'counts', jsonb_build_object(
      'registrations', (select count(*) from app_private.registrations where event_id = v_event_id and status = 'submitted'),
      'children', (select count(*) from app_private.registration_children where event_id = v_event_id and participation_status = 'active'),
      'portalApplications', (select count(*) from app_private.portal_applications where event_id = v_event_id and review_status = 'submitted'),
      'approvedPortals', (select count(*) from app_private.portals where event_id = v_event_id and approval_status = 'approved'),
      'groups', (select count(*) from app_private.walking_groups where event_id = v_event_id),
      'liveGroups', (select count(*) from app_private.walking_groups where event_id = v_event_id and status = 'live'),
      'openSupportCases', (select count(*) from app_private.support_cases where event_id = v_event_id and status in ('open', 'acknowledged')),
      'unconfirmedPayments', (select count(*) from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.event_id = v_event_id and payment.status not in ('confirmed', 'waived', 'refunded'))
    ),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('id', batch.id, 'kind', batch.kind, 'dryRun', batch.dry_run, 'status', batch.status, 'createdAt', batch.created_at) order by batch.created_at desc) from (select * from app_private.import_batches where event_id = v_event_id order by created_at desc limit 10) batch), '[]'::jsonb),
    'recentActivity', coalesce((select jsonb_agg(jsonb_build_object('action', audit.action, 'resourceType', audit.resource_type, 'createdAt', audit.created_at) order by audit.created_at desc) from (select * from app_private.audit_events where event_id = v_event_id order by created_at desc limit 20) audit), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_planning_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'parties', coalesce((select jsonb_agg(jsonb_build_object(
      'id', registration.id,
      'childCount', (select count(*) from app_private.registration_children child where child.registration_id = registration.id and child.participation_status = 'active'),
      'requestedStartId', registration.start_preference_id,
      'togetherKey', membership.party_id
    ) order by registration.id)
    from app_private.registrations registration
    left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
    where registration.event_id = v_event_id and registration.status = 'submitted'
      and not exists (select 1 from app_private.group_registrations assignment where assignment.registration_id = registration.id and assignment.superseded_at is null)), '[]'::jsonb),
    'starts', coalesce((select jsonb_agg(jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups, 'maxChildren', slot.max_children) order by slot.starts_at, slot.id) from app_private.start_slots slot where slot.event_id = v_event_id and slot.active and slot.location_verified_at is not null), '[]'::jsonb),
    'portals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', portal.id, 'worldId', portal.world_id, 'opensAt', portal_window.opens_at, 'closesAt', portal_window.closes_at,
      'visitMinutes', portal_window.visit_minutes, 'maxConcurrentGroups', portal_window.max_concurrent_groups, 'maxChildren', portal_window.max_children_per_visit
    ) order by portal.id)
    from app_private.portals portal
    join lateral (select * from app_private.portal_windows candidate where candidate.portal_id = portal.id order by candidate.opens_at limit 1) portal_window on true
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    where portal.event_id = v_event_id and portal.approval_status = 'approved'), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_record_import(
  _event_slug text,
  _kind text,
  _source_hash text,
  _errors jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  batch app_private.import_batches;
  item jsonb;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or (_kind = 'portals' and app_private.has_capability(v_event_id, 'portals_manage', actor))
    or (_kind in ('registrations', 'payments') and app_private.has_capability(v_event_id, 'registration_manage', actor))
    or (_kind in ('graph', 'starts') and app_private.has_capability(v_event_id, 'groups_manage', actor))
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _kind not in ('portals', 'registrations', 'payments', 'graph', 'starts') or jsonb_typeof(_errors) <> 'array' then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  insert into app_private.import_batches(event_id, kind, dry_run, source_hash, status, created_by)
  values (v_event_id, _kind, true, _source_hash, case when jsonb_array_length(_errors) = 0 then 'ready' else 'invalid' end, actor)
  returning * into batch;
  for item in select value from jsonb_array_elements(_errors) loop
    insert into app_private.import_errors(batch_id, row_number, field_name, error_code, message)
    values (batch.id, greatest(coalesce((item ->> 'row')::integer, 1), 1), nullif(item ->> 'field', ''), coalesce(nullif(item ->> 'code', ''), 'INVALID_ROW'), left(coalesce(item ->> 'message', 'Ongeldige rij'), 500));
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'import.dry_run_recorded', 'import_batch', batch.id, jsonb_build_object('kind', _kind, 'errorCount', jsonb_array_length(_errors)));
  return jsonb_build_object('id', batch.id, 'status', batch.status, 'errorCount', jsonb_array_length(_errors));
end;
$$;

create or replace function api.admin_apply_plan(
  _event_slug text,
  _proposal jsonb,
  _input_hash text,
  _idempotency_key text,
  _request_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  select id into v_event_id from app_private.events where slug = _event_slug for update;
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
$$;

create or replace function api.admin_publish_plans(_event_slug text, _plan_ids uuid[], _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  affected integer;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(array_length(_plan_ids, 1), 0) = 0 or nullif(trim(_reason), '') is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if (select count(distinct plan.id) from app_private.route_plan_versions plan join app_private.walking_groups walking_group on walking_group.id = plan.group_id where plan.id = any(_plan_ids) and walking_group.event_id = v_event_id and plan.state = 'valid') <> (select count(distinct id) from unnest(_plan_ids) wanted(id)) then raise exception 'INVALID_PLAN' using errcode = '23514'; end if;
  update app_private.route_plan_versions set state = 'published', published_at = now() where id = any(_plan_ids) and state = 'valid';
  get diagnostics affected = row_count;
  update app_private.walking_groups walking_group set status = 'ready', version = version + 1 where walking_group.current_plan_version_id = any(_plan_ids);
  update app_private.group_registrations assignment set published_at = now() where assignment.group_id in (select plan.group_id from app_private.route_plan_versions plan where plan.id = any(_plan_ids));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.published', 'route_plan_batch', jsonb_build_object('planCount', affected, 'reason', left(_reason, 300)));
  return jsonb_build_object('published', affected);
end;
$$;

revoke execute on function api.portal_snapshot(text) from public, anon;
revoke execute on function api.admin_dashboard(text) from public, anon;
revoke execute on function api.admin_planning_snapshot(text) from public, anon;
revoke execute on function api.admin_record_import(text, text, text, jsonb) from public, anon;
revoke execute on function api.admin_apply_plan(text, jsonb, text, text, text) from public, anon;
revoke execute on function api.admin_publish_plans(text, uuid[], text) from public, anon;

grant execute on function api.portal_snapshot(text) to authenticated;
grant execute on function api.admin_dashboard(text) to authenticated;
grant execute on function api.admin_planning_snapshot(text) to authenticated;
grant execute on function api.admin_record_import(text, text, text, jsonb) to authenticated;
grant execute on function api.admin_apply_plan(text, jsonb, text, text, text) to authenticated;
grant execute on function api.admin_publish_plans(text, uuid[], text) to authenticated;

create or replace function api.group_roster(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  leader boolean;
  support boolean;
begin
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  leader := app_private.is_current_leader(_group_id, actor);
  support := app_private.has_capability(group_record.event_id, 'live_support', actor) or app_private.has_capability(group_record.event_id, 'groups_manage', actor);
  if not (leader or support) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('registrationChildId', registration_child.id, 'firstName', child.first_name, 'householdLabel', household.label) order by household.label, child.first_name)
    from app_private.group_registrations assignment
    join app_private.registrations registration on registration.id = assignment.registration_id
    join app_private.households household on household.id = registration.household_id
    join app_private.registration_children registration_child on registration_child.registration_id = registration.id and registration_child.participation_status = 'active'
    join app_private.children child on child.id = registration_child.child_id
    where assignment.group_id = _group_id and assignment.superseded_at is null
  ), '[]'::jsonb);
end;
$$;

create or replace function api.together_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); v_event_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  return (
    select jsonb_build_object(
      'registrationId', registration.id,
      'party', case when party.id is null then null else jsonb_build_object('id', party.id, 'label', party.public_label, 'memberCount', (select count(*) from app_private.together_memberships member where member.party_id = party.id and member.left_at is null), 'locked', party.locked_at is not null) end
    )
    from app_private.household_members household_member
    join app_private.registrations registration on registration.household_id = household_member.household_id and registration.event_id = v_event_id and registration.status = 'submitted'
    left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
    left join app_private.together_parties party on party.id = membership.party_id
    where household_member.user_id = actor and household_member.revoked_at is null
    order by household_member.accepted_at limit 1
  );
end;
$$;

create or replace function api.together_create(_registration_id uuid, _label text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); registration app_private.registrations; party app_private.together_parties; invite_code text;
begin
  select * into registration from app_private.registrations where id = _registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if exists (select 1 from app_private.together_memberships where registration_id = registration.id and left_at is null) then raise exception 'ALREADY_IN_PARTY' using errcode = '23505'; end if;
  if char_length(trim(_label)) not between 2 and 80 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  invite_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  insert into app_private.together_parties(event_id, public_label, creator_household_id, invite_token_hash, expires_at)
  values (registration.event_id, trim(_label), registration.household_id, extensions.digest(convert_to(invite_code, 'utf8'), 'sha256'), now() + interval '35 days') returning * into party;
  insert into app_private.together_memberships(party_id, registration_id) values (party.id, registration.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id) values (registration.event_id, actor, 'together_party.created', 'together_party', party.id);
  return jsonb_build_object('id', party.id, 'label', party.public_label, 'inviteCode', invite_code);
end;
$$;

create or replace function api.together_join(_registration_id uuid, _invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); registration app_private.registrations; party app_private.together_parties;
begin
  select * into registration from app_private.registrations where id = _registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if exists (select 1 from app_private.together_memberships where registration_id = registration.id and left_at is null) then raise exception 'ALREADY_IN_PARTY' using errcode = '23505'; end if;
  select * into party from app_private.together_parties where event_id = registration.event_id and invite_token_hash = extensions.digest(convert_to(upper(trim(_invite_code)), 'utf8'), 'sha256') and expires_at > now() and locked_at is null for update;
  if party.id is null then raise exception 'INVALID_INVITE' using errcode = '22023'; end if;
  insert into app_private.together_memberships(party_id, registration_id) values (party.id, registration.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id) values (registration.event_id, actor, 'together_party.joined', 'together_party', party.id);
  return jsonb_build_object('id', party.id, 'label', party.public_label);
end;
$$;

revoke execute on function api.group_roster(uuid) from public, anon;
revoke execute on function api.together_snapshot(text) from public, anon;
revoke execute on function api.together_create(uuid, text) from public, anon;
revoke execute on function api.together_join(uuid, text) from public, anon;
grant execute on function api.group_roster(uuid) to authenticated;
grant execute on function api.together_snapshot(text) to authenticated;
grant execute on function api.together_create(uuid, text) to authenticated;
grant execute on function api.together_join(uuid, text) to authenticated;

create or replace function api.run_set_state(
  _run_id uuid,
  _state app_private.run_status,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); run_record app_private.group_runs; event_id uuid; leader boolean; support boolean;
begin
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
$$;

create or replace function api.run_support_override(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); run_record app_private.group_runs; event_id uuid; credential_id uuid;
begin
  select run.* into run_record from app_private.group_runs run where run.id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select walking_group.event_id into event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
  if run_record.status <> 'live' or not app_private.has_capability(event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select credential.id into credential_id
  from app_private.run_stops stop
  join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portal_credentials credential on credential.portal_id = plan_stop.portal_id and credential.revoked_at is null
  where stop.id = _stop_id order by credential.version desc limit 1;
  if credential_id is null then raise exception 'NO_ACTIVE_CREDENTIAL' using errcode = '23514'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  select _stop_id, credential.id, credential.version, actor, 'support_override' from app_private.portal_credentials credential where credential.id = credential_id
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata) values (_run_id, _stop_id, 'stop.support_override', actor, jsonb_build_object('reason', left(_reason, 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change) values (event_id, actor, 'stop.support_override', 'group_run', _run_id, jsonb_build_object('stopId', _stop_id, 'reason', left(_reason, 500)));
  return jsonb_build_object('accepted', true, 'stopId', _stop_id, 'override', true);
end;
$$;

create or replace function api.admin_live_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'groupId', walking_group.id, 'groupCode', walking_group.code, 'runId', run.id, 'runStatus', run.status, 'runVersion', run.version,
    'stopId', run.current_stop_id,
    'portalName', (select portal.name from app_private.run_stops stop join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id join app_private.portals portal on portal.id = plan_stop.portal_id where stop.id = run.current_stop_id)
  ) order by walking_group.code)
  from app_private.walking_groups walking_group
  join app_private.group_runs run on run.group_id = walking_group.id and run.status in ('live', 'paused')
  where walking_group.event_id = v_event_id), '[]'::jsonb);
end;
$$;

revoke execute on function api.run_set_state(uuid, app_private.run_status, integer, text) from public, anon;
revoke execute on function api.run_support_override(uuid, uuid, integer, text) from public, anon;
revoke execute on function api.admin_live_snapshot(text) from public, anon;
grant execute on function api.run_set_state(uuid, app_private.run_status, integer, text) to authenticated;
grant execute on function api.run_support_override(uuid, uuid, integer, text) to authenticated;
grant execute on function api.admin_live_snapshot(text) to authenticated;

create or replace function api.bootstrap_first_admin(_event_slug text, _email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_event_id uuid; v_user_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if exists (select 1 from app_private.event_capabilities where event_id = v_event_id and capability = 'event_admin' and revoked_at is null) then raise exception 'ADMIN_ALREADY_EXISTS' using errcode = '23505'; end if;
  select id into v_user_id from auth.users where lower(email) = lower(trim(_email)) and email_confirmed_at is not null order by created_at limit 1;
  if v_user_id is null then raise exception 'CONFIRMED_USER_REQUIRED' using errcode = '23514'; end if;
  insert into app_private.event_capabilities(event_id, user_id, capability, granted_by)
  select v_event_id, v_user_id, capability, v_user_id
  from unnest(array['event_admin','registration_manage','payments_manage','portals_manage','groups_manage','live_support','content_manage']) capability;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, v_user_id, 'event.first_admin_bootstrapped', 'profile', v_user_id, jsonb_build_object('capabilityCount', 7));
  return jsonb_build_object('userId', v_user_id, 'capabilityCount', 7);
end;
$$;

revoke execute on function api.bootstrap_first_admin(text, text) from public, anon, authenticated;
grant execute on function api.bootstrap_first_admin(text, text) to service_role;
