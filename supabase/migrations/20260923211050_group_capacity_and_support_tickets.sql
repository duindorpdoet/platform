-- A single, audited child limit now governs both code-based together parties
-- and the route planner. Existing events keep the planner's former default.
update app_private.events
set settings = settings || jsonb_build_object(
      'maxGroupSize',
      greatest(10, coalesce((
        select count(child.id)::integer
        from app_private.together_parties party
        join app_private.together_memberships membership
          on membership.party_id = party.id and membership.left_at is null
        join app_private.registrations registration
          on registration.id = membership.registration_id and registration.status = 'submitted'
        join app_private.registration_children child
          on child.registration_id = registration.id and child.participation_status = 'active'
        where party.event_id = app_private.events.id and party.locked_at is null
        group by party.id
        order by count(child.id) desc
        limit 1
      ), 0))
    ),
    settings_version = settings_version + 1
where not (settings ? 'maxGroupSize');

alter table app_private.together_parties
  add column capacity_override_at timestamptz,
  add column capacity_override_by uuid references auth.users(id) on delete set null,
  add column capacity_override_reason text,
  add constraint together_parties_capacity_override_complete check (
    (capacity_override_at is null and capacity_override_by is null and capacity_override_reason is null)
    or (capacity_override_at is not null and capacity_override_by is not null
        and char_length(capacity_override_reason) between 10 and 500)
  );

create table app_private.together_join_requests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  source_party_id uuid not null references app_private.together_parties(id) on delete restrict,
  target_party_id uuid not null references app_private.together_parties(id) on delete restrict,
  requested_by_registration_id uuid not null references app_private.registrations(id) on delete restrict,
  requested_code text not null check (requested_code ~ '^[A-HJ-NP-Z2-9]{4}$'),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  child_count_at_request integer not null check (child_count_at_request > 0),
  group_limit_at_request integer not null check (group_limit_at_request between 2 and 50),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_reason text,
  limit_overridden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  check (source_party_id <> target_party_id),
  check (
    (status = 'pending' and decided_by is null and decided_at is null and decision_reason is null and not limit_overridden)
    or (status in ('accepted', 'rejected') and decided_by is not null and decided_at is not null
        and char_length(decision_reason) between 10 and 500)
  )
);

create unique index together_join_requests_one_pending_source
  on app_private.together_join_requests(source_party_id)
  where status = 'pending';
create index together_join_requests_event_status
  on app_private.together_join_requests(event_id, status, created_at desc);
alter table app_private.together_join_requests enable row level security;
revoke all on table app_private.together_join_requests from public, anon, authenticated;

create or replace function app_private.together_party_child_count(_party_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from app_private.together_memberships membership
  join app_private.registrations registration
    on registration.id = membership.registration_id and registration.status = 'submitted'
  join app_private.registration_children child
    on child.registration_id = registration.id and child.participation_status = 'active'
  where membership.party_id = _party_id and membership.left_at is null
$$;

revoke execute on function app_private.together_party_child_count(uuid) from public, anon, authenticated;

-- Registrations that fit are linked immediately. If the requested party would
-- exceed the configured child limit, the new registration remains in its own
-- party and an organizer decision is created instead of silently overfilling.
create or replace function app_private.attach_registration_to_together_party(
  _registration_id uuid,
  _requested_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration_record app_private.registrations;
  normalized_code text := nullif(upper(trim(coalesce(_requested_code, ''))), '');
  party_record app_private.together_parties;
  own_party_id uuid;
  incoming_children integer;
  projected_children integer;
  max_group_size integer;
begin
  select * into registration_record
  from app_private.registrations
  where id = _registration_id
  for update;

  if registration_record.id is null then
    raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from app_private.together_memberships
    where registration_id = registration_record.id and left_at is null
  ) then
    raise exception 'ALREADY_IN_PARTY' using errcode = '23505';
  end if;

  if normalized_code is not null and normalized_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;

  select coalesce((settings ->> 'maxGroupSize')::integer, 10)
  into max_group_size
  from app_private.events
  where id = registration_record.event_id;
  if max_group_size not between 2 and 50 then
    raise exception 'INVALID_GROUP_SIZE_LIMIT' using errcode = '23514';
  end if;

  select count(*)::integer into incoming_children
  from app_private.registration_children child
  where child.registration_id = registration_record.id and child.participation_status = 'active';
  if incoming_children < 1 then raise exception 'EMPTY_REGISTRATION' using errcode = '23514'; end if;

  if normalized_code is not null then
    select party.* into party_record
    from app_private.registrations target
    join app_private.together_memberships membership
      on membership.registration_id = target.id and membership.left_at is null
    join app_private.together_parties party
      on party.id = membership.party_id and party.locked_at is null
    where target.event_id = registration_record.event_id
      and target.status = 'submitted'
      and target.together_code = normalized_code
      and target.id <> registration_record.id
    for update of party;

    if party_record.id is null then
      raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
    end if;

    projected_children := app_private.together_party_child_count(party_record.id) + incoming_children;
    if projected_children <= max_group_size then
      insert into app_private.together_memberships(party_id, registration_id)
      values (party_record.id, registration_record.id);
      return party_record.id;
    end if;
  end if;

  insert into app_private.together_parties(
    event_id, public_label, creator_household_id, invite_token_hash, expires_at
  ) values (
    registration_record.event_id,
    'Samenloopcode ' || registration_record.together_code,
    registration_record.household_id,
    extensions.digest(convert_to('registration:' || registration_record.id::text, 'utf8'), 'sha256'),
    now() + interval '10 years'
  ) returning id into own_party_id;

  insert into app_private.together_memberships(party_id, registration_id)
  values (own_party_id, registration_record.id);

  if normalized_code is not null then
    insert into app_private.together_join_requests(
      event_id, source_party_id, target_party_id, requested_by_registration_id,
      requested_code, child_count_at_request, group_limit_at_request
    ) values (
      registration_record.event_id, own_party_id, party_record.id, registration_record.id,
      normalized_code, projected_children, max_group_size
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration_record.event_id, actor, 'together.capacity_review_requested',
      'registration', registration_record.id,
      jsonb_build_object('projectedChildren', projected_children, 'groupLimit', max_group_size)
    );
  end if;
  return own_party_id;
end;
$$;

revoke execute on function app_private.attach_registration_to_together_party(uuid, text) from public, anon, authenticated;

create or replace function api.admin_set_group_size_limit(
  _event_slug text,
  _max_group_size integer,
  _expected_settings_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  previous_limit integer;
  largest_existing_party integer;
begin
  if _max_group_size is null or _max_group_size not between 2 and 50
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.settings_version <> _expected_settings_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select coalesce(max(party_size.child_count), 0)
  into largest_existing_party
  from (
    select app_private.together_party_child_count(party.id) as child_count
    from app_private.together_parties party
    where party.event_id = event_record.id and party.locked_at is null
      and party.capacity_override_at is null
  ) party_size;
  if largest_existing_party > _max_group_size then
    raise exception 'GROUP_SIZE_LIMIT_BELOW_ACTIVE_PARTY' using errcode = '23514',
      detail = jsonb_build_object(
        'largestExistingParty', largest_existing_party,
        'requestedLimit', _max_group_size
      )::text;
  end if;
  previous_limit := coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10);
  update app_private.events
  set settings = settings || jsonb_build_object('maxGroupSize', _max_group_size),
      settings_version = settings_version + 1,
      updated_at = now()
  where id = event_record.id
  returning * into event_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    event_record.id, actor, 'group_size_limit.updated', 'event', event_record.id,
    jsonb_build_object('from', previous_limit, 'to', _max_group_size, 'reason', left(trim(_reason), 500))
  );
  return jsonb_build_object(
    'settingsVersion', event_record.settings_version,
    'maxGroupSize', _max_group_size
  );
end;
$$;

create or replace function api.admin_together_requests_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', request.id,
      'version', request.version,
      'status', request.status,
      'requestedCode', request.requested_code,
      'registrationReference', registration.reference,
      'sourceChildren', app_private.together_party_child_count(request.source_party_id),
      'targetChildren', app_private.together_party_child_count(request.target_party_id),
      'projectedChildren', app_private.together_party_child_count(request.source_party_id)
        + app_private.together_party_child_count(request.target_party_id),
      'maxGroupSize', coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10),
      'limitOverridden', request.limit_overridden,
      'createdAt', request.created_at,
      'decidedAt', request.decided_at
    ) order by (request.status = 'pending') desc, request.created_at desc)
    from app_private.together_join_requests request
    join app_private.registrations registration on registration.id = request.requested_by_registration_id
    where request.event_id = event_record.id
  ), '[]'::jsonb);
end;
$$;

create or replace function api.admin_decide_together_request(
  _request_id uuid,
  _expected_version integer,
  _decision text,
  _override_limit boolean,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_record app_private.together_join_requests;
  event_record app_private.events;
  source_children integer;
  target_children integer;
  projected_children integer;
  max_group_size integer;
  membership_record record;
begin
  if _decision is null or _decision not in ('accept', 'reject')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into request_record
  from app_private.together_join_requests
  where id = _request_id
  for update;
  if request_record.id is null then raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into event_record from app_private.events where id = request_record.event_id for update;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if request_record.status <> 'pending' or request_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  -- Lock both parties in deterministic order before recalculating capacity.
  perform id from app_private.together_parties
  where id in (request_record.source_party_id, request_record.target_party_id)
  order by id
  for update;
  if exists (
    select 1 from app_private.together_parties
    where id in (request_record.source_party_id, request_record.target_party_id) and locked_at is not null
  ) then raise exception 'STALE_VERSION' using errcode = '40001'; end if;

  source_children := app_private.together_party_child_count(request_record.source_party_id);
  target_children := app_private.together_party_child_count(request_record.target_party_id);
  projected_children := source_children + target_children;
  max_group_size := coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10);

  if _decision = 'accept' then
    if projected_children > max_group_size and not _override_limit then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514',
        detail = jsonb_build_object('projectedChildren', projected_children, 'maxGroupSize', max_group_size)::text;
    end if;

    for membership_record in
      select * from app_private.together_memberships
      where party_id = request_record.source_party_id and left_at is null
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
    set capacity_override_at = case when projected_children > max_group_size then now() else capacity_override_at end,
        capacity_override_by = case when projected_children > max_group_size then actor else capacity_override_by end,
        capacity_override_reason = case when projected_children > max_group_size then left(trim(_reason), 500) else capacity_override_reason end
    where id = request_record.target_party_id;
    update app_private.together_parties set locked_at = now() where id = request_record.source_party_id;
  end if;

  update app_private.together_join_requests
  set status = case when _decision = 'accept' then 'accepted' else 'rejected' end,
      decided_by = actor,
      decided_at = now(),
      decision_reason = left(trim(_reason), 500),
      limit_overridden = _decision = 'accept' and projected_children > max_group_size,
      updated_at = now(),
      version = version + 1
  where id = request_record.id
  returning * into request_record;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    event_record.id, actor,
    case when _decision = 'accept' then 'together.capacity_request_accepted' else 'together.capacity_request_rejected' end,
    'together_join_request', request_record.id,
    jsonb_build_object(
      'sourceChildren', source_children, 'targetChildren', target_children,
      'projectedChildren', projected_children, 'groupLimit', max_group_size,
      'limitOverridden', request_record.limit_overridden, 'reason', left(trim(_reason), 500)
    )
  );

  return jsonb_build_object(
    'id', request_record.id,
    'status', request_record.status,
    'version', request_record.version,
    'projectedChildren', projected_children,
    'maxGroupSize', max_group_size,
    'limitOverridden', request_record.limit_overridden
  );
end;
$$;

-- Private, two-way ticket conversations for current group leaders and the
-- organizing team. Read receipts are per message; notifications are durable.
create table app_private.group_support_tickets (
  id uuid primary key default gen_random_uuid(),
  ticket_number bigint generated always as identity unique,
  event_id uuid not null references app_private.events(id) on delete cascade,
  group_id uuid not null references app_private.walking_groups(id) on delete cascade,
  opened_by uuid not null references auth.users(id) on delete restrict,
  subject text not null check (char_length(subject) between 3 and 160),
  category text not null check (category in ('question', 'planning', 'accessibility', 'incident', 'other')),
  status text not null default 'awaiting_organization'
    check (status in ('awaiting_organization', 'awaiting_leader', 'resolved', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, id)
);

create table app_private.group_support_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references app_private.group_support_tickets(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete restrict,
  sender_side text not null check (sender_side in ('leader', 'organization')),
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  read_by uuid references auth.users(id) on delete set null,
  check ((read_at is null and read_by is null) or (read_at is not null and read_by is not null))
);

create index group_support_tickets_event_status
  on app_private.group_support_tickets(event_id, status, last_message_at desc);
create index group_support_tickets_group
  on app_private.group_support_tickets(group_id, last_message_at desc);
create index group_support_ticket_messages_thread
  on app_private.group_support_ticket_messages(ticket_id, created_at, id);
create index group_support_ticket_messages_unread
  on app_private.group_support_ticket_messages(ticket_id, sender_side)
  where read_at is null;

alter table app_private.group_support_tickets enable row level security;
alter table app_private.group_support_ticket_messages enable row level security;
revoke all on table app_private.group_support_tickets from public, anon, authenticated;
revoke all on table app_private.group_support_ticket_messages from public, anon, authenticated;
revoke all on sequence app_private.group_support_tickets_ticket_number_seq from public, anon, authenticated;

-- Keep the previous read models private and wrap them with the additional
-- capacity state. This preserves all existing privacy-filtered fields.
alter function api.registration_snapshot(text) set schema app_private;
alter function app_private.registration_snapshot(text) rename to registration_snapshot_before_group_capacity;
revoke execute on function app_private.registration_snapshot_before_group_capacity(text) from public, anon, authenticated;

create function api.registration_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  snapshot jsonb;
  v_registration_id uuid;
  event_record app_private.events;
  together_request jsonb;
begin
  snapshot := app_private.registration_snapshot_before_group_capacity(_event_slug);
  if snapshot is null then return null; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  snapshot := jsonb_set(
    snapshot,
    '{event}',
    coalesce(snapshot -> 'event', '{}'::jsonb) || jsonb_build_object(
      'maxGroupSize', coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10)
    ),
    true
  );
  v_registration_id := nullif(snapshot #>> '{registration,id}', '')::uuid;
  if v_registration_id is null then return snapshot; end if;

  select jsonb_build_object(
    'id', request.id,
    'status', request.status,
    'requestedCode', request.requested_code,
    'projectedChildren', case when request.status = 'pending'
      then app_private.together_party_child_count(request.source_party_id)
        + app_private.together_party_child_count(request.target_party_id)
      else request.child_count_at_request end,
    'maxGroupSize', case when request.status = 'pending'
      then coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10)
      else request.group_limit_at_request end,
    'limitOverridden', request.limit_overridden,
    'updatedAt', request.updated_at
  ) into together_request
  from app_private.together_join_requests request
  where request.requested_by_registration_id = v_registration_id
     or (
       request.status in ('pending', 'rejected')
       and exists (
         select 1 from app_private.together_memberships membership
         where membership.registration_id = v_registration_id
           and membership.party_id = request.source_party_id
           and membership.left_at is null
       )
     )
  order by request.created_at desc
  limit 1;

  return jsonb_set(
    snapshot,
    '{registration}',
    (snapshot -> 'registration') || jsonb_build_object('togetherRequest', together_request),
    true
  );
end;
$$;

alter function api.admin_dashboard(text) set schema app_private;
alter function app_private.admin_dashboard(text) rename to admin_dashboard_before_group_capacity;
revoke execute on function app_private.admin_dashboard_before_group_capacity(text) from public, anon, authenticated;

create function api.admin_dashboard(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  snapshot jsonb;
  event_record app_private.events;
begin
  snapshot := app_private.admin_dashboard_before_group_capacity(_event_slug);
  select * into event_record from app_private.events where slug = _event_slug;
  return snapshot
    || jsonb_build_object(
      'event', (snapshot -> 'event') || jsonb_build_object(
        'maxGroupSize', coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10)
      ),
      'counts', (snapshot -> 'counts') || jsonb_build_object(
        'pendingTogetherRequests', (
          select count(*) from app_private.together_join_requests
          where event_id = event_record.id and status = 'pending'
        ),
        'openTickets', (
          select count(*) from app_private.group_support_tickets
          where event_id = event_record.id and status not in ('resolved', 'closed')
        )
      )
    );
end;
$$;

alter function api.admin_planning_snapshot(text) set schema app_private;
alter function app_private.admin_planning_snapshot(text) rename to admin_planning_snapshot_before_group_capacity;
revoke execute on function app_private.admin_planning_snapshot_before_group_capacity(text) from public, anon, authenticated;

create function api.admin_planning_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  snapshot jsonb;
  enriched_parties jsonb;
begin
  snapshot := app_private.admin_planning_snapshot_before_group_capacity(_event_slug);
  select coalesce(jsonb_agg(
    party.value || jsonb_build_object(
      'togetherOverride', coalesce(together_party.capacity_override_at is not null, false)
    ) order by party.ordinality
  ), '[]'::jsonb)
  into enriched_parties
  from jsonb_array_elements(snapshot -> 'parties') with ordinality party(value, ordinality)
  left join app_private.together_memberships membership
    on membership.registration_id = (party.value ->> 'id')::uuid and membership.left_at is null
  left join app_private.together_parties together_party on together_party.id = membership.party_id;
  return jsonb_set(snapshot, '{parties}', enriched_parties, true);
end;
$$;

create function app_private.group_ticket_reference(_ticket_number bigint)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$ select 'TCK-' || lpad(_ticket_number::text, 6, '0') $$;

create function app_private.is_ticket_organizer(_event_id uuid, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and (
    app_private.has_capability(_event_id, 'event_admin', _actor)
    or app_private.has_capability(_event_id, 'groups_manage', _actor)
    or app_private.has_capability(_event_id, 'live_support', _actor)
  )
$$;

create function app_private.enqueue_group_ticket_notifications(_ticket_id uuid, _message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ticket_record app_private.group_support_tickets;
  message_record app_private.group_support_ticket_messages;
  event_record app_private.events;
  leader_email text;
  support_email text;
  reference text;
begin
  select * into ticket_record from app_private.group_support_tickets where id = _ticket_id;
  select * into message_record from app_private.group_support_ticket_messages
  where id = _message_id and ticket_id = _ticket_id;
  select * into event_record from app_private.events where id = ticket_record.event_id;
  if ticket_record.id is null or message_record.id is null then
    raise exception 'TICKET_MESSAGE_NOT_FOUND' using errcode = 'P0002';
  end if;
  support_email := lower(trim(event_record.settings ->> 'supportEmail'));
  select lower(users.email) into leader_email
  from app_private.group_leaders leader
  join auth.users users on users.id = leader.user_id and users.email_confirmed_at is not null
  where leader.group_id = ticket_record.group_id
    and leader.active_from <= now()
    and (leader.active_until is null or leader.active_until > now())
  order by leader.revision desc
  limit 1;
  if support_email is null or support_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'SUPPORT_EMAIL_NOT_CONFIGURED' using errcode = '55000';
  end if;
  if leader_email is null then raise exception 'ACTIVE_LEADER_EMAIL_REQUIRED' using errcode = '23514'; end if;
  reference := app_private.group_ticket_reference(ticket_record.ticket_number);

  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'group-ticket:' || _message_id::text || ':organization',
    'group_ticket_message_organization', ticket_record.id::text, support_email,
    jsonb_build_object(
      'ticketReference', reference, 'subject', ticket_record.subject,
      'message', message_record.body,
      'senderLabel', case when message_record.sender_side = 'leader' then 'Groepsleider' else 'Organisatie' end,
      'actionPath', '/admin'
    )
  ) on conflict (dedupe_key) do nothing;

  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'group-ticket:' || _message_id::text || ':leader',
    'group_ticket_message_leader', ticket_record.id::text, leader_email,
    jsonb_build_object(
      'ticketReference', reference, 'subject', ticket_record.subject,
      'message', message_record.body,
      'senderLabel', case when message_record.sender_side = 'leader' then 'Jij' else 'Organisatie' end,
      'actionPath', '/mijn-groep'
    )
  ) on conflict (dedupe_key) do nothing;
end;
$$;

create function api.group_ticket_create(
  _group_id uuid,
  _category text,
  _subject text,
  _body text,
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
  group_record app_private.walking_groups;
  ticket_record app_private.group_support_tickets;
  message_record app_private.group_support_ticket_messages;
  receipt app_private.command_receipts;
  result jsonb;
begin
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'groupTicket.create' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if actor is null or group_record.id is null or not app_private.is_current_leader(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _category is null or _category not in ('question', 'planning', 'accessibility', 'incident', 'other')
     or char_length(trim(coalesce(_subject, ''))) not between 3 and 160
     or char_length(trim(coalesce(_body, ''))) not between 1 and 4000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if (select count(*) from app_private.group_support_tickets
      where group_id = _group_id and status not in ('resolved', 'closed')) >= 10 then
    raise exception 'TOO_MANY_OPEN_TICKETS' using errcode = '23514';
  end if;
  insert into app_private.group_support_tickets(event_id, group_id, opened_by, subject, category)
  values (group_record.event_id, _group_id, actor, trim(_subject), _category)
  returning * into ticket_record;
  insert into app_private.group_support_ticket_messages(ticket_id, sender_id, sender_side, body)
  values (ticket_record.id, actor, 'leader', trim(_body))
  returning * into message_record;
  perform app_private.enqueue_group_ticket_notifications(ticket_record.id, message_record.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group_ticket.created', 'group_support_ticket', ticket_record.id,
    jsonb_build_object('category', ticket_record.category));
  result := jsonb_build_object(
    'id', ticket_record.id,
    'reference', app_private.group_ticket_reference(ticket_record.ticket_number),
    'status', ticket_record.status,
    'version', ticket_record.version
  );
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'groupTicket.create', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create function api.group_ticket_reply(
  _ticket_id uuid,
  _expected_version integer,
  _body text,
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
  ticket_record app_private.group_support_tickets;
  message_record app_private.group_support_ticket_messages;
  receipt app_private.command_receipts;
  actor_side text;
  result jsonb;
begin
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'groupTicket.reply' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into ticket_record from app_private.group_support_tickets where id = _ticket_id for update;
  if ticket_record.id is null or actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  actor_side := case
    when app_private.is_current_leader(ticket_record.group_id, actor) then 'leader'
    when app_private.is_ticket_organizer(ticket_record.event_id, actor) then 'organization'
    else null
  end;
  if actor_side is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if ticket_record.status = 'closed' or ticket_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if char_length(trim(coalesce(_body, ''))) not between 1 and 4000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  insert into app_private.group_support_ticket_messages(ticket_id, sender_id, sender_side, body)
  values (ticket_record.id, actor, actor_side, trim(_body))
  returning * into message_record;
  update app_private.group_support_tickets
  set status = case when actor_side = 'leader' then 'awaiting_organization' else 'awaiting_leader' end,
      updated_at = now(), last_message_at = now(), version = version + 1
  where id = ticket_record.id
  returning * into ticket_record;
  perform app_private.enqueue_group_ticket_notifications(ticket_record.id, message_record.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (ticket_record.event_id, actor, 'group_ticket.replied', 'group_support_ticket', ticket_record.id,
    jsonb_build_object('senderSide', actor_side));
  result := jsonb_build_object(
    'id', ticket_record.id,
    'messageId', message_record.id,
    'status', ticket_record.status,
    'version', ticket_record.version
  );
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'groupTicket.reply', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create function api.group_ticket_mark_read(_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  ticket_record app_private.group_support_tickets;
  actor_side text;
  changed_count integer;
begin
  select * into ticket_record from app_private.group_support_tickets where id = _ticket_id;
  if ticket_record.id is null or actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  actor_side := case
    when app_private.is_current_leader(ticket_record.group_id, actor) then 'leader'
    when app_private.is_ticket_organizer(ticket_record.event_id, actor) then 'organization'
    else null
  end;
  if actor_side is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.group_support_ticket_messages
  set read_at = now(), read_by = actor
  where ticket_id = ticket_record.id and sender_side <> actor_side and read_at is null;
  get diagnostics changed_count = row_count;
  return jsonb_build_object('ticketId', ticket_record.id, 'markedRead', changed_count);
end;
$$;

create function api.group_ticket_set_status(
  _ticket_id uuid,
  _expected_version integer,
  _status text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  ticket_record app_private.group_support_tickets;
  leader boolean;
  organizer boolean;
  next_status text;
begin
  select * into ticket_record from app_private.group_support_tickets where id = _ticket_id for update;
  if ticket_record.id is null or actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  leader := app_private.is_current_leader(ticket_record.group_id, actor);
  organizer := app_private.is_ticket_organizer(ticket_record.event_id, actor);
  if not (leader or organizer) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if ticket_record.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _status is null or _status not in ('open', 'resolved', 'closed')
     or char_length(trim(coalesce(_reason, ''))) not between 5 and 500
     or (leader and not organizer and _status not in ('open', 'closed')) then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  next_status := case
    when _status = 'open' and leader then 'awaiting_organization'
    when _status = 'open' then 'awaiting_leader'
    else _status
  end;
  update app_private.group_support_tickets
  set status = next_status, updated_at = now(), version = version + 1
  where id = ticket_record.id
  returning * into ticket_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (ticket_record.event_id, actor, 'group_ticket.status_changed', 'group_support_ticket', ticket_record.id,
    jsonb_build_object('status', next_status, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', ticket_record.id, 'status', ticket_record.status, 'version', ticket_record.version);
end;
$$;

create function api.group_ticket_snapshot(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not app_private.is_current_leader(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ticket.id,
      'reference', app_private.group_ticket_reference(ticket.ticket_number),
      'subject', ticket.subject,
      'category', ticket.category,
      'status', ticket.status,
      'version', ticket.version,
      'createdAt', ticket.created_at,
      'updatedAt', ticket.updated_at,
      'unreadCount', (select count(*) from app_private.group_support_ticket_messages unread
        where unread.ticket_id = ticket.id and unread.sender_side = 'organization' and unread.read_at is null),
      'messages', coalesce((select jsonb_agg(jsonb_build_object(
        'id', message.id,
        'senderSide', message.sender_side,
        'body', message.body,
        'createdAt', message.created_at,
        'readAt', message.read_at,
        'isMine', message.sender_side = 'leader'
      ) order by message.created_at, message.id)
      from app_private.group_support_ticket_messages message where message.ticket_id = ticket.id), '[]'::jsonb)
    ) order by ticket.last_message_at desc, ticket.id)
    from app_private.group_support_tickets ticket
    where ticket.group_id = _group_id
  ), '[]'::jsonb);
end;
$$;

create function api.admin_group_ticket_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not app_private.is_ticket_organizer(event_record.id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ticket.id,
      'reference', app_private.group_ticket_reference(ticket.ticket_number),
      'groupCode', walking_group.code,
      'leaderEmail', leader_user.email,
      'subject', ticket.subject,
      'category', ticket.category,
      'status', ticket.status,
      'version', ticket.version,
      'createdAt', ticket.created_at,
      'updatedAt', ticket.updated_at,
      'unreadCount', (select count(*) from app_private.group_support_ticket_messages unread
        where unread.ticket_id = ticket.id and unread.sender_side = 'leader' and unread.read_at is null),
      'messages', coalesce((select jsonb_agg(jsonb_build_object(
        'id', message.id,
        'senderSide', message.sender_side,
        'body', message.body,
        'createdAt', message.created_at,
        'readAt', message.read_at,
        'isMine', message.sender_side = 'organization'
      ) order by message.created_at, message.id)
      from app_private.group_support_ticket_messages message where message.ticket_id = ticket.id), '[]'::jsonb)
    ) order by (ticket.status not in ('resolved', 'closed')) desc, ticket.last_message_at desc, ticket.id)
    from app_private.group_support_tickets ticket
    join app_private.walking_groups walking_group on walking_group.id = ticket.group_id
    left join lateral (
      select users.email
      from app_private.group_leaders leader
      join auth.users users on users.id = leader.user_id
      where leader.group_id = ticket.group_id
        and leader.active_from <= now()
        and (leader.active_until is null or leader.active_until > now())
      order by leader.revision desc limit 1
    ) leader_user on true
    where ticket.event_id = event_record.id
  ), '[]'::jsonb);
end;
$$;

create function app_private.notify_group_ticket_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare ticket_group_id uuid;
begin
  select group_id into ticket_group_id
  from app_private.group_support_tickets
  where id = new.ticket_id;
  perform realtime.send(
    jsonb_build_object('resource', 'group_support_ticket', 'ticketId', new.ticket_id),
    'snapshot_changed',
    'group:' || ticket_group_id::text,
    true
  );
  return new;
end;
$$;

create trigger group_support_ticket_message_broadcast
after insert or update of read_at on app_private.group_support_ticket_messages
for each row execute function app_private.notify_group_ticket_change();

revoke execute on function app_private.group_ticket_reference(bigint) from public, anon, authenticated;
revoke execute on function app_private.is_ticket_organizer(uuid, uuid) from public, anon, authenticated;
revoke execute on function app_private.enqueue_group_ticket_notifications(uuid, uuid) from public, anon, authenticated;
revoke execute on function app_private.notify_group_ticket_change() from public, anon, authenticated;

revoke execute on function api.admin_set_group_size_limit(text, integer, integer, text) from public, anon;
revoke execute on function api.admin_together_requests_snapshot(text) from public, anon;
revoke execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text) from public, anon;
revoke execute on function api.registration_snapshot(text) from public, anon;
revoke execute on function api.admin_dashboard(text) from public, anon;
revoke execute on function api.admin_planning_snapshot(text) from public, anon;
revoke execute on function api.group_ticket_create(uuid, text, text, text, text, text) from public, anon;
revoke execute on function api.group_ticket_reply(uuid, integer, text, text, text) from public, anon;
revoke execute on function api.group_ticket_mark_read(uuid) from public, anon;
revoke execute on function api.group_ticket_set_status(uuid, integer, text, text) from public, anon;
revoke execute on function api.group_ticket_snapshot(uuid) from public, anon;
revoke execute on function api.admin_group_ticket_snapshot(text) from public, anon;

grant execute on function api.admin_set_group_size_limit(text, integer, integer, text) to authenticated;
grant execute on function api.admin_together_requests_snapshot(text) to authenticated;
grant execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text) to authenticated;
grant execute on function api.registration_snapshot(text) to authenticated;
grant execute on function api.admin_dashboard(text) to authenticated;
grant execute on function api.admin_planning_snapshot(text) to authenticated;
grant execute on function api.group_ticket_create(uuid, text, text, text, text, text) to authenticated;
grant execute on function api.group_ticket_reply(uuid, integer, text, text, text) to authenticated;
grant execute on function api.group_ticket_mark_read(uuid) to authenticated;
grant execute on function api.group_ticket_set_status(uuid, integer, text, text) to authenticated;
grant execute on function api.group_ticket_snapshot(uuid) to authenticated;
grant execute on function api.admin_group_ticket_snapshot(text) to authenticated;

notify pgrst, 'reload schema';
