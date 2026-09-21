create or replace function app_private.require_complete_stop_status_set()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  present_count integer;
begin
  if new.state = 'completed' and old.state is distinct from 'completed' then
    select count(*) into present_count from app_private.run_participants
    where run_id = new.run_id and attendance = 'present';
    if present_count = 0 or exists (
      select 1 from app_private.run_participants participant
      where participant.run_id = new.run_id and participant.attendance = 'present'
        and not exists (
          select 1 from app_private.stop_participant_statuses status
          where status.run_stop_id = new.id and status.run_participant_id = participant.id
        )
    ) then
      raise exception 'INCOMPLETE_STATUS_SET' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger run_stops_complete_status_set
before update of state on app_private.run_stops
for each row execute function app_private.require_complete_stop_status_set();

create or replace function api.run_bulk_skip_pending(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _reason text,
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
  run_record app_private.group_runs;
  receipt app_private.command_receipts;
  changed_count integer;
  result jsonb;
begin
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
$$;

create or replace function api.admin_assign_group_leader(
  _group_id uuid,
  _new_leader_user_id uuid,
  _expected_group_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  next_revision integer;
begin
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
$$;

revoke execute on function app_private.require_complete_stop_status_set() from public, anon, authenticated;
revoke execute on function api.run_bulk_skip_pending(uuid, uuid, integer, text, text, text) from public, anon;
revoke execute on function api.admin_assign_group_leader(uuid, uuid, integer, text) from public, anon;

grant execute on function api.run_bulk_skip_pending(uuid, uuid, integer, text, text, text) to authenticated;
grant execute on function api.admin_assign_group_leader(uuid, uuid, integer, text) to authenticated;

-- Public forms may notify only the event's fixed support mailbox. The supplied
-- sender address remains message data and can never become an outbox target.
update app_private.events
set settings = settings || jsonb_build_object('supportEmail', 'halloween@duindorpdoet.nl'),
    settings_version = settings_version + 1
where slug = 'duindorp-halloween-2026'
  and settings ->> 'supportEmail' is distinct from 'halloween@duindorpdoet.nl';

create or replace function api.submit_public_contact(
  _event_slug text,
  _sender_name text,
  _sender_email text,
  _subject text,
  _body text,
  _opaque_subject_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_record app_private.events;
  bucket_count integer;
  message_id uuid;
  support_email text;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if char_length(trim(_sender_name)) not between 1 and 120
     or char_length(trim(_sender_email)) not between 3 and 320
     or char_length(trim(_subject)) not between 3 and 160
     or char_length(trim(_body)) not between 3 and 4000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  support_email := lower(trim(event_record.settings ->> 'supportEmail'));
  if support_email is null or support_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'SUPPORT_EMAIL_NOT_CONFIGURED' using errcode = '55000';
  end if;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, count, expires_at)
  values ('contact', _opaque_subject_hash, date_trunc('hour', now()), 1, date_trunc('hour', now()) + interval '2 hours')
  on conflict (scope, opaque_subject_hash, window_start) do update set count = app_private.rate_limit_buckets.count + 1
  returning count into bucket_count;
  if bucket_count > 5 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;
  insert into app_private.contact_messages(event_id, sender_name, sender_email, subject, body)
  values (event_record.id, trim(_sender_name), lower(trim(_sender_email)), trim(_subject), trim(_body)) returning id into message_id;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'contact:' || message_id::text || ':notify', 'contact_notification', message_id::text, support_email,
    jsonb_build_object(
      'ticketReference', message_id,
      'contactName', trim(_sender_name),
      'contactEmail', lower(trim(_sender_email)),
      'subject', trim(_subject),
      'message', trim(_body)
    )
  );
  return jsonb_build_object('reference', message_id, 'stored', true);
end;
$$;

create or replace function api.submit_public_sponsor(
  _event_slug text,
  _contact_name text,
  _contact_email text,
  _contribution_type text,
  _proposed_amount_cents integer,
  _message text,
  _opaque_subject_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_record app_private.events;
  bucket_count integer;
  application_id uuid;
  support_email text;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if char_length(trim(_contact_name)) not between 1 and 120
     or char_length(trim(_contact_email)) not between 3 and 320
     or char_length(trim(_contribution_type)) not between 1 and 80
     or _proposed_amount_cents < 0
     or char_length(coalesce(_message, '')) > 4000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  support_email := lower(trim(event_record.settings ->> 'supportEmail'));
  if support_email is null or support_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'SUPPORT_EMAIL_NOT_CONFIGURED' using errcode = '55000';
  end if;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, count, expires_at)
  values ('sponsor', _opaque_subject_hash, date_trunc('day', now()), 1, date_trunc('day', now()) + interval '2 days')
  on conflict (scope, opaque_subject_hash, window_start) do update set count = app_private.rate_limit_buckets.count + 1
  returning count into bucket_count;
  if bucket_count > 3 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;
  insert into app_private.sponsor_applications(event_id, contact_name, contact_email, contribution_type, proposed_amount_cents, message)
  values (event_record.id, trim(_contact_name), lower(trim(_contact_email)), trim(_contribution_type), _proposed_amount_cents, nullif(trim(_message), '')) returning id into application_id;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'sponsor:' || application_id::text || ':notify', 'sponsor_notification', application_id::text, support_email,
    jsonb_build_object(
      'applicationReference', application_id,
      'contactName', trim(_contact_name),
      'contactEmail', lower(trim(_contact_email)),
      'contributionType', trim(_contribution_type),
      'proposedAmountCents', _proposed_amount_cents,
      'message', nullif(trim(_message), '')
    )
  );
  return jsonb_build_object('reference', application_id, 'stored', true);
end;
$$;

create or replace function api.admin_assign_group_leader_by_email(
  _group_id uuid,
  _new_leader_email text,
  _expected_group_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_event_id uuid;
  leader_user_id uuid;
begin
  select walking_group.event_id into group_event_id
  from app_private.walking_groups walking_group
  where walking_group.id = _group_id;
  if group_event_id is null or not app_private.has_capability(group_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select users.id into leader_user_id
  from auth.users users
  where lower(users.email) = lower(trim(_new_leader_email))
    and users.email_confirmed_at is not null
  order by users.created_at
  limit 1;
  if leader_user_id is null then raise exception 'LEADER_NOT_AVAILABLE' using errcode = '23514'; end if;
  return api.admin_assign_group_leader(_group_id, leader_user_id, _expected_group_version, _reason);
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
    'groupId', walking_group.id,
    'groupCode', walking_group.code,
    'groupVersion', walking_group.version,
    'leaderEmail', (
      select lower(users.email)
      from app_private.group_leaders leader
      join auth.users users on users.id = leader.user_id
      where leader.group_id = walking_group.id and leader.active_until is null
      order by leader.revision desc limit 1
    ),
    'runId', run.id,
    'runStatus', run.status,
    'runVersion', run.version,
    'stopId', run.current_stop_id,
    'portalName', (
      select portal.name
      from app_private.run_stops stop
      join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal on portal.id = plan_stop.portal_id
      where stop.id = run.current_stop_id
    )
  ) order by walking_group.code)
  from app_private.walking_groups walking_group
  join app_private.group_runs run on run.group_id = walking_group.id and run.status in ('live', 'paused')
  where walking_group.event_id = v_event_id), '[]'::jsonb);
end;
$$;

revoke execute on function api.admin_assign_group_leader_by_email(uuid, text, integer, text) from public, anon;
grant execute on function api.admin_assign_group_leader_by_email(uuid, text, integer, text) to authenticated;

create or replace function api.worker_update_outbox(
  _id uuid,
  _status app_private.outbox_status,
  _provider_id text default null,
  _error_code text default null,
  _next_attempt_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app_private.email_outbox
  set status = case
        when status in ('delivered', 'failed', 'suppressed') then status
        else _status
      end,
      provider_id = coalesce(_provider_id, provider_id),
      last_error_code = _error_code,
      next_attempt_at = coalesce(_next_attempt_at, next_attempt_at),
      lease_until = null
  where id = _id;
end;
$$;

create or replace function api.worker_store_email_event(
  _provider_event_id text,
  _outbox_id uuid,
  _kind text,
  _occurred_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted boolean;
begin
  insert into app_private.email_events(provider, provider_event_id, outbox_id, kind, occurred_at)
  values ('sendgrid', _provider_event_id, _outbox_id, _kind, _occurred_at)
  on conflict (provider, provider_event_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted and _outbox_id is not null then
    update app_private.email_outbox
    set status = case
      when status in ('delivered', 'failed', 'suppressed') then status
      when _kind = 'delivered' then 'delivered'::app_private.outbox_status
      when _kind in ('bounce', 'dropped', 'spamreport') then 'failed'::app_private.outbox_status
      when _kind = 'deferred' then 'deferred'::app_private.outbox_status
      else status
    end
    where id = _outbox_id;
  end if;
  return inserted;
end;
$$;

create or replace function app_private.has_approved_walking_path(
  _event_id uuid,
  _from_node_id uuid,
  _to_node_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with recursive reachable(node_id) as (
    select _from_node_id
    union
    select case when edge.from_node_id = reachable.node_id then edge.to_node_id else edge.from_node_id end
    from reachable
    join app_private.walking_edges edge
      on edge.event_id = _event_id
      and edge.approved_at is not null
      and edge.closed_at is null
      and (edge.from_node_id = reachable.node_id or edge.to_node_id = reachable.node_id)
  )
  select _from_node_id is not null and _to_node_id is not null
    and exists (select 1 from reachable where node_id = _to_node_id)
$$;

create or replace function app_private.validate_route_plan_stop()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  plan_record record;
  window_record app_private.portal_windows;
  portal_world_id uuid;
  source_node_id uuid;
  target_node_id uuid;
  active_children integer;
  overlapping_groups integer;
begin
  select plan.id as plan_id, plan.state, walking_group.id as group_id, walking_group.event_id,
         slot.external_id as start_external_id
    into plan_record
  from app_private.route_plan_versions plan
  join app_private.walking_groups walking_group on walking_group.id = plan.group_id
  join app_private.start_slots slot on slot.id = walking_group.start_slot_id
  where plan.id = new.plan_version_id;
  if plan_record.plan_id is null then raise exception 'INVALID_ROUTE_PLAN' using errcode = '23514'; end if;
  if new.position < 1 or new.planned_departure_at <= new.planned_arrival_at then
    raise exception 'INVALID_ROUTE_TIMING' using errcode = '23514';
  end if;

  select portal.world_id into portal_world_id
  from app_private.portals portal
  join app_private.portal_private_locations location
    on location.portal_id = portal.id and location.verified_at is not null
  where portal.id = new.portal_id and portal.event_id = plan_record.event_id
    and portal.approval_status = 'approved';
  if portal_world_id is null then raise exception 'PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  select candidate.* into window_record
  from app_private.portal_windows candidate
  where candidate.portal_id = new.portal_id
    and new.planned_arrival_at >= candidate.opens_at
    and new.planned_departure_at <= candidate.closes_at
    and new.planned_departure_at = new.planned_arrival_at + make_interval(mins => candidate.visit_minutes)
  order by candidate.opens_at
  limit 1;
  if window_record.id is null then raise exception 'PORTAL_WINDOW_CONFLICT' using errcode = '23514'; end if;

  select count(*) into active_children
  from app_private.group_registrations assignment
  join app_private.registration_children child on child.registration_id = assignment.registration_id
    and child.participation_status = 'active'
  where assignment.group_id = plan_record.group_id and assignment.superseded_at is null;
  if active_children = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if active_children > window_record.max_children_per_visit then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  if exists (
    select 1 from app_private.route_plan_stops existing
    join app_private.portals portal on portal.id = existing.portal_id
    where existing.plan_version_id = new.plan_version_id
      and existing.id is distinct from new.id
      and (existing.portal_id = new.portal_id or portal.world_id = portal_world_id)
  ) then raise exception 'DUPLICATE_PORTAL_OR_WORLD' using errcode = '23514'; end if;

  select count(*) into overlapping_groups
  from app_private.route_plan_stops existing
  join app_private.route_plan_versions existing_plan on existing_plan.id = existing.plan_version_id
  where existing.portal_id = new.portal_id
    and existing.id is distinct from new.id
    and existing_plan.state in ('valid', 'published')
    and existing.planned_arrival_at < new.planned_departure_at
    and existing.planned_departure_at > new.planned_arrival_at;
  if overlapping_groups >= window_record.max_concurrent_groups then
    raise exception 'PORTAL_CAPACITY_EXCEEDED' using errcode = '23514';
  end if;

  select node.id into target_node_id
  from app_private.walking_nodes node
  where node.event_id = plan_record.event_id and node.kind = 'portal'
    and node.portal_id = new.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if new.position = 1 then
    select node.id into source_node_id
    from app_private.walking_nodes node
    where node.event_id = plan_record.event_id and node.kind = 'start'
      and node.external_id = plan_record.start_external_id and node.verified_at is not null
    order by node.id limit 1;
  else
    select node.id into source_node_id
    from app_private.route_plan_stops previous_stop
    join app_private.walking_nodes node on node.portal_id = previous_stop.portal_id
      and node.event_id = plan_record.event_id and node.kind = 'portal' and node.verified_at is not null
    where previous_stop.plan_version_id = new.plan_version_id and previous_stop.position = new.position - 1
    order by node.id limit 1;
  end if;
  if not app_private.has_approved_walking_path(plan_record.event_id, source_node_id, target_node_id) then
    raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger route_plan_stops_validate
before insert or update of plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at
on app_private.route_plan_stops
for each row execute function app_private.validate_route_plan_stop();

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
  if coalesce(array_length(_plan_ids, 1), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if (select count(distinct plan.id) from app_private.route_plan_versions plan join app_private.walking_groups walking_group on walking_group.id = plan.group_id where plan.id = any(_plan_ids) and walking_group.event_id = v_event_id and plan.state = 'valid') <> (select count(distinct id) from unnest(_plan_ids) wanted(id)) then raise exception 'INVALID_PLAN' using errcode = '23514'; end if;

  -- Touching every stop invokes the same capacity, window and graph checks used
  -- during creation while the event lock prevents a concurrent publication race.
  update app_private.route_plan_stops
  set planned_arrival_at = planned_arrival_at
  where plan_version_id = any(_plan_ids);

  update app_private.route_plan_versions set state = 'published', published_at = now() where id = any(_plan_ids) and state = 'valid';
  get diagnostics affected = row_count;
  update app_private.walking_groups walking_group set status = 'ready', version = version + 1 where walking_group.current_plan_version_id = any(_plan_ids);
  update app_private.group_registrations assignment set published_at = now() where assignment.group_id in (select plan.group_id from app_private.route_plan_versions plan where plan.id = any(_plan_ids));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.published', 'route_plan_batch', jsonb_build_object('planCount', affected, 'reason', left(_reason, 500)));
  return jsonb_build_object('published', affected);
end;
$$;

revoke execute on function app_private.has_approved_walking_path(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function app_private.validate_route_plan_stop() from public, anon, authenticated;
