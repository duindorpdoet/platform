-- Unified participant environment: role discovery, read-only viewer links,
-- role-scoped updates and private preferences. All operational data remains
-- outside the Data API and is exposed only through narrow security-definer RPCs.

create table app_private.group_viewer_invites (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  group_id uuid not null references app_private.walking_groups(id) on delete cascade,
  recipient_email text not null check (char_length(recipient_email) between 3 and 254),
  token_hash bytea not null unique,
  invited_by uuid not null references auth.users(id) on delete restrict,
  invite_expires_at timestamptz not null,
  access_expires_at timestamptz,
  consumed_at timestamptz,
  accepted_user_id uuid references auth.users(id) on delete restrict,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (access_expires_at is null or access_expires_at > created_at)
);

create unique index group_viewer_invites_one_open_recipient
  on app_private.group_viewer_invites(group_id, lower(recipient_email))
  where consumed_at is null and revoked_at is null;
create index group_viewer_invites_group_active_idx
  on app_private.group_viewer_invites(group_id, created_at desc)
  where revoked_at is null;

create table app_private.group_viewer_access (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  group_id uuid not null references app_private.walking_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  invite_id uuid not null references app_private.group_viewer_invites(id) on delete restrict,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create unique index group_viewer_access_one_active
  on app_private.group_viewer_access(group_id, user_id)
  where revoked_at is null;
create index group_viewer_access_user_active_idx
  on app_private.group_viewer_access(user_id, event_id, group_id)
  where revoked_at is null;

create table app_private.participant_preferences (
  event_id uuid not null references app_private.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email_updates boolean not null default true,
  reduced_motion boolean not null default false,
  readable_mode boolean not null default false,
  optional_updates_consent boolean not null default false,
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  primary key (event_id, user_id)
);

create index participant_preferences_email_idx
  on app_private.participant_preferences(event_id, user_id)
  where email_updates;

create table app_private.participant_updates (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  audience_role text not null check (audience_role in ('all', 'walker', 'viewer', 'homeowner')),
  group_id uuid references app_private.walking_groups(id) on delete cascade,
  portal_id uuid references app_private.portals(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 3 and 1200),
  priority text not null default 'normal' check (priority in ('normal', 'important', 'urgent')),
  published_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (group_id is null or portal_id is null),
  check (expires_at is null or expires_at > published_at)
);

create index participant_updates_event_role_idx
  on app_private.participant_updates(event_id, audience_role, published_at desc);
create index participant_updates_group_idx
  on app_private.participant_updates(group_id, published_at desc)
  where group_id is not null;
create index participant_updates_portal_idx
  on app_private.participant_updates(portal_id, published_at desc)
  where portal_id is not null;

create table app_private.participant_update_reads (
  update_id uuid not null references app_private.participant_updates(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (update_id, user_id)
);

create index participant_update_reads_user_idx
  on app_private.participant_update_reads(user_id, read_at desc);

alter table app_private.group_viewer_invites enable row level security;
alter table app_private.group_viewer_access enable row level security;
alter table app_private.participant_preferences enable row level security;
alter table app_private.participant_updates enable row level security;
alter table app_private.participant_update_reads enable row level security;

revoke all on table app_private.group_viewer_invites from public, anon, authenticated;
revoke all on table app_private.group_viewer_access from public, anon, authenticated;
revoke all on table app_private.participant_preferences from public, anon, authenticated;
revoke all on table app_private.participant_updates from public, anon, authenticated;
revoke all on table app_private.participant_update_reads from public, anon, authenticated;

create or replace function app_private.has_active_viewer_access(
  _group_id uuid,
  _actor uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and exists (
    select 1
    from app_private.group_viewer_access access
    where access.group_id = _group_id
      and access.user_id = _actor
      and access.revoked_at is null
      and (access.expires_at is null or access.expires_at > now())
  )
$$;

create or replace function api.participant_context(_event_slug text)
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
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then return null; end if;

  return jsonb_build_object(
    'event', jsonb_build_object(
      'id', event_record.id,
      'title', event_record.title,
      'localDate', event_record.local_date,
      'phase', event_record.phase,
      'startsAt', ((event_record.local_date::timestamp + time '18:30') at time zone event_record.timezone),
      'paymentDeadline', (event_record.local_date - 1),
      'supportEmail', coalesce(nullif(event_record.settings ->> 'supportEmail', ''), 'organisatie@duindorpdoet.nl'),
      'supportPhone', nullif(event_record.settings ->> 'supportPhone', '')
    ),
    'roles', coalesce((
      select jsonb_agg(role_record.payload order by role_record.sort_order)
      from (
        select 1 as sort_order, jsonb_build_object(
          'key', 'walker',
          'label', 'Meeloper',
          'groupId', (
            select membership.group_id
            from (
              select leader.group_id, 0 as priority
              from app_private.group_leaders leader
              join app_private.walking_groups walking_group on walking_group.id = leader.group_id
              where walking_group.event_id = event_record.id and leader.user_id = actor
                and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
              union all
              select assignment.group_id, 1
              from app_private.household_members member
              join app_private.registrations registration on registration.household_id = member.household_id
                and registration.event_id = event_record.id and registration.status <> 'cancelled'
              join app_private.group_registrations assignment on assignment.registration_id = registration.id
                and assignment.superseded_at is null
              where member.user_id = actor and member.revoked_at is null
            ) membership
            order by membership.priority limit 1
          )
        ) as payload
        where exists (
          select 1
          from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          where member.user_id = actor and member.revoked_at is null
            and registration.event_id = event_record.id and registration.status <> 'cancelled'
        ) or exists (
          select 1 from app_private.group_leaders leader
          join app_private.walking_groups walking_group on walking_group.id = leader.group_id
          where walking_group.event_id = event_record.id and leader.user_id = actor
            and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
        )
        union all
        select 2, jsonb_build_object(
          'key', 'viewer',
          'label', 'Meekijker',
          'accessId', access.id,
          'groupId', access.group_id,
          'expiresAt', access.expires_at
        )
        from (
          select candidate.*
          from app_private.group_viewer_access candidate
          where candidate.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
            and (candidate.expires_at is null or candidate.expires_at > now())
          order by candidate.created_at
          limit 1
        ) access
        union all
        select 3, jsonb_build_object(
          'key', 'homeowner',
          'label', 'Huiseigenaar',
          'portalId', portal.id
        )
        from (
          select candidate.*
          from app_private.portal_owners candidate
          join app_private.portals owned_portal on owned_portal.id = candidate.portal_id
          where owned_portal.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
          order by candidate.accepted_at
          limit 1
        ) owner
        join app_private.portals portal on portal.id = owner.portal_id
      ) role_record
    ), '[]'::jsonb),
    'preferences', coalesce((
      select jsonb_build_object(
        'reducedMotion', preference.reduced_motion,
        'readableMode', preference.readable_mode
      )
      from app_private.participant_preferences preference
      where preference.event_id = event_record.id and preference.user_id = actor
    ), jsonb_build_object('reducedMotion', false, 'readableMode', false))
  );
end;
$$;

create or replace function api.group_viewer_invite_create(
  _group_id uuid,
  _recipient_email text,
  _access_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  normalized_email text := lower(trim(_recipient_email));
  group_record app_private.walking_groups;
  invite_record app_private.group_viewer_invites;
  invite_token text;
  v_count integer;
begin
  if actor is null or not app_private.is_current_leader(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or char_length(normalized_email) > 254 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _access_expires_at is not null and (_access_expires_at <= now() + interval '15 minutes' or _access_expires_at > now() + interval '40 days') then
    raise exception 'INVALID_EXPIRY' using errcode = '22023';
  end if;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, expires_at)
  values (
    'group_viewer_invite_actor',
    encode(extensions.digest(convert_to(actor::text, 'utf8'), 'sha256'), 'hex'),
    date_trunc('hour', now()),
    date_trunc('hour', now()) + interval '2 hours'
  )
  on conflict (scope, opaque_subject_hash, window_start)
  do update set count = app_private.rate_limit_buckets.count + 1
  returning count into v_count;
  if v_count > 10 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;

  update app_private.group_viewer_invites
  set revoked_at = now(), revoked_by = actor
  where group_id = _group_id and lower(recipient_email) = normalized_email
    and consumed_at is null and revoked_at is null;

  invite_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into app_private.group_viewer_invites(
    event_id, group_id, recipient_email, token_hash, invited_by,
    invite_expires_at, access_expires_at
  ) values (
    group_record.event_id, group_record.id, normalized_email,
    extensions.digest(convert_to(invite_token, 'utf8'), 'sha256'), actor,
    now() + interval '48 hours', _access_expires_at
  ) returning * into invite_record;

  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'group-viewer-invite:' || invite_record.id::text,
    'group_viewer_invite',
    'group_viewer_invite:' || invite_record.id::text,
    normalized_email,
    jsonb_build_object(
      'groupCode', group_record.code,
      'inviteToken', invite_token,
      'expiresAt', invite_record.invite_expires_at,
      'accessExpiresAt', invite_record.access_expires_at,
      'actionPath', '/omgeving?meekijkuitnodiging=' || invite_token
    )
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.viewer_invited', 'group_viewer_invite', invite_record.id,
    jsonb_build_object('accessExpiresAt', invite_record.access_expires_at));
  return jsonb_build_object('id', invite_record.id, 'inviteExpiresAt', invite_record.invite_expires_at, 'accessExpiresAt', invite_record.access_expires_at);
end;
$$;

create or replace function api.group_viewer_invite_accept(_invite_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  actor_email text;
  invite_record app_private.group_viewer_invites;
  access_record app_private.group_viewer_access;
begin
  if actor is null or char_length(trim(coalesce(_invite_token, ''))) <> 64 then
    raise exception 'INVITE_NOT_AVAILABLE' using errcode = '22023';
  end if;
  select lower(email) into actor_email from auth.users where id = actor and email_confirmed_at is not null;
  if actor_email is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into invite_record
  from app_private.group_viewer_invites
  where token_hash = extensions.digest(convert_to(trim(_invite_token), 'utf8'), 'sha256')
  for update;
  if invite_record.id is null or invite_record.revoked_at is not null or invite_record.consumed_at is not null
     or invite_record.invite_expires_at <= now() then
    raise exception 'INVITE_NOT_AVAILABLE' using errcode = '23514';
  end if;
  if lower(invite_record.recipient_email) <> actor_email then
    raise exception 'RECIPIENT_MISMATCH' using errcode = '42501';
  end if;

  update app_private.group_viewer_access
  set revoked_at = now(), revoked_by = actor
  where group_id = invite_record.group_id and user_id = actor and revoked_at is null;
  insert into app_private.group_viewer_access(event_id, group_id, user_id, invite_id, expires_at)
  values (invite_record.event_id, invite_record.group_id, actor, invite_record.id, invite_record.access_expires_at)
  returning * into access_record;
  update app_private.group_viewer_invites
  set consumed_at = now(), accepted_user_id = actor
  where id = invite_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (invite_record.event_id, actor, 'group.viewer_access_accepted', 'group_viewer_access', access_record.id);
  return jsonb_build_object('accessId', access_record.id, 'groupId', access_record.group_id, 'expiresAt', access_record.expires_at);
end;
$$;

create or replace function api.group_viewer_access_snapshot(_group_id uuid)
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
  return jsonb_build_object(
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', invite.id,
        'email', lower(invite.recipient_email),
        'inviteExpiresAt', invite.invite_expires_at,
        'accessExpiresAt', invite.access_expires_at
      ) order by invite.created_at desc)
      from app_private.group_viewer_invites invite
      where invite.group_id = _group_id and invite.consumed_at is null
        and invite.revoked_at is null and invite.invite_expires_at > now()
    ), '[]'::jsonb),
    'active', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', access.id,
        'email', lower(users.email),
        'expiresAt', access.expires_at,
        'createdAt', access.created_at
      ) order by access.created_at desc)
      from app_private.group_viewer_access access
      join auth.users users on users.id = access.user_id
      where access.group_id = _group_id and access.revoked_at is null
        and (access.expires_at is null or access.expires_at > now())
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.group_viewer_access_revoke(_access_id uuid, _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  access_record app_private.group_viewer_access;
begin
  if actor is null or char_length(trim(coalesce(_reason, ''))) < 5 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into access_record from app_private.group_viewer_access where id = _access_id for update;
  if access_record.id is null or access_record.revoked_at is not null
     or not (access_record.user_id = actor or app_private.is_current_leader(access_record.group_id, actor)) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  update app_private.group_viewer_access set revoked_at = now(), revoked_by = actor where id = access_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (access_record.event_id, actor, 'group.viewer_access_revoked', 'group_viewer_access', access_record.id,
    jsonb_build_object('reason', left(trim(_reason), 300)));
  return jsonb_build_object('revoked', true);
end;
$$;

create or replace function api.group_viewer_invite_revoke(_invite_id uuid, _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  invite_record app_private.group_viewer_invites;
begin
  if actor is null or char_length(trim(coalesce(_reason, ''))) < 5 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into invite_record from app_private.group_viewer_invites where id = _invite_id for update;
  if invite_record.id is null or invite_record.revoked_at is not null or invite_record.consumed_at is not null
     or not app_private.is_current_leader(invite_record.group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  update app_private.group_viewer_invites set revoked_at = now(), revoked_by = actor where id = invite_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (invite_record.event_id, actor, 'group.viewer_invite_revoked', 'group_viewer_invite', invite_record.id,
    jsonb_build_object('reason', left(trim(_reason), 300)));
  return jsonb_build_object('revoked', true);
end;
$$;

create or replace function api.group_viewer_snapshot(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  run_record app_private.group_runs;
  v_total integer := 0;
  v_completed integer := 0;
begin
  if actor is null or not app_private.has_active_viewer_access(_group_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where group_id = _group_id order by created_at desc limit 1;
  if run_record.id is not null then
    select count(*), count(*) filter (where state = 'completed') into v_total, v_completed
    from app_private.run_stops where run_id = run_record.id;
  elsif group_record.current_plan_version_id is not null then
    select count(*) into v_total from app_private.route_plan_stops where plan_version_id = group_record.current_plan_version_id;
  end if;
  return jsonb_build_object(
    'group', jsonb_build_object(
      'code', group_record.code,
      'status', group_record.status,
      'start', (
        select jsonb_build_object('name', slot.name, 'startsAt', slot.starts_at)
        from app_private.start_slots slot where slot.id = group_record.start_slot_id
      )
    ),
    'progress', jsonb_build_object(
      'status', coalesce(run_record.status::text, 'waiting'),
      'completed', v_completed,
      'total', v_total,
      'lastUpdatedAt', coalesce(run_record.updated_at, group_record.updated_at)
    ),
    'history', case when run_record.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'sequence', stop.sequence,
        'world', world.name,
        'outcome', stop.outcome,
        'completedAt', stop.completed_at
      ) order by stop.sequence)
      from app_private.run_stops stop
      join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal on portal.id = plan_stop.portal_id
      join app_private.worlds world on world.id = portal.world_id
      where stop.run_id = run_record.id and stop.state = 'completed'
    ), '[]'::jsonb) end
  );
end;
$$;

create or replace function api.participant_updates_snapshot(_event_slug text, _role text)
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
  if actor is null or _role not in ('walker', 'viewer', 'homeowner') then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then return '[]'::jsonb; end if;

  if _role = 'walker' and not (
    exists (
      select 1 from app_private.household_members member
      join app_private.registrations registration on registration.household_id = member.household_id
      where member.user_id = actor and member.revoked_at is null
        and registration.event_id = v_event_id and registration.status <> 'cancelled'
    ) or exists (
      select 1 from app_private.group_leaders leader
      join app_private.walking_groups walking_group on walking_group.id = leader.group_id
      where walking_group.event_id = v_event_id and leader.user_id = actor
        and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
    )
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _role = 'viewer' and not exists (
    select 1 from app_private.group_viewer_access access
    where access.event_id = v_event_id and access.user_id = actor and access.revoked_at is null
      and (access.expires_at is null or access.expires_at > now())
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _role = 'homeowner' and not exists (
    select 1 from app_private.portal_owners owner
    join app_private.portals portal on portal.id = owner.portal_id
    where portal.event_id = v_event_id and owner.user_id = actor and owner.revoked_at is null
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', update.id,
      'title', update.title,
      'body', update.body,
      'priority', update.priority,
      'publishedAt', update.published_at,
      'readAt', read_state.read_at
    ) order by update.published_at desc)
    from app_private.participant_updates update
    left join app_private.participant_update_reads read_state on read_state.update_id = update.id and read_state.user_id = actor
    where update.event_id = v_event_id
      and update.audience_role in ('all', _role)
      and (update.expires_at is null or update.expires_at > now())
      and (
        update.group_id is null or
        (_role = 'walker' and (
          app_private.is_current_leader(update.group_id, actor) or exists (
            select 1 from app_private.household_members member
            join app_private.registrations registration on registration.household_id = member.household_id
            join app_private.group_registrations assignment on assignment.registration_id = registration.id
            where member.user_id = actor and member.revoked_at is null
              and assignment.group_id = update.group_id and assignment.superseded_at is null
          )
        )) or
        (_role = 'viewer' and app_private.has_active_viewer_access(update.group_id, actor))
      )
      and (
        update.portal_id is null or
        (_role = 'homeowner' and exists (
          select 1 from app_private.portal_owners owner
          where owner.portal_id = update.portal_id and owner.user_id = actor and owner.revoked_at is null
        ))
      )
  ), '[]'::jsonb);
end;
$$;

create or replace function api.participant_update_mark_read(_update_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  update_record app_private.participant_updates;
  allowed boolean := false;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into update_record from app_private.participant_updates where id = _update_id;
  if update_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if update_record.audience_role in ('all', 'walker') then
    allowed := exists (
      select 1 from app_private.household_members member
      join app_private.registrations registration on registration.household_id = member.household_id
      left join app_private.group_registrations assignment on assignment.registration_id = registration.id and assignment.superseded_at is null
      where member.user_id = actor and member.revoked_at is null
        and registration.event_id = update_record.event_id and registration.status <> 'cancelled'
        and (update_record.group_id is null or assignment.group_id = update_record.group_id)
    ) or (update_record.group_id is not null and app_private.is_current_leader(update_record.group_id, actor));
  end if;
  if not allowed and update_record.audience_role in ('all', 'viewer') then
    allowed := exists (
      select 1 from app_private.group_viewer_access access
      where access.event_id = update_record.event_id and access.user_id = actor and access.revoked_at is null
        and (access.expires_at is null or access.expires_at > now())
        and (update_record.group_id is null or access.group_id = update_record.group_id)
    );
  end if;
  if not allowed and update_record.audience_role in ('all', 'homeowner') then
    allowed := exists (
      select 1 from app_private.portal_owners owner
      join app_private.portals portal on portal.id = owner.portal_id
      where portal.event_id = update_record.event_id and owner.user_id = actor and owner.revoked_at is null
        and (update_record.portal_id is null or owner.portal_id = update_record.portal_id)
    );
  end if;
  if not allowed then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  insert into app_private.participant_update_reads(update_id, user_id)
  values (update_record.id, actor)
  on conflict (update_id, user_id) do update set read_at = excluded.read_at;
  return jsonb_build_object('read', true);
end;
$$;

create or replace function api.participant_profile_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  context jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then return null; end if;
  context := api.participant_context(_event_slug);
  insert into app_private.participant_preferences(event_id, user_id)
  values (v_event_id, actor) on conflict (event_id, user_id) do nothing;
  return jsonb_build_object(
    'displayName', (select display_name from app_private.profiles where user_id = actor),
    'email', (select lower(email) from auth.users where id = actor),
    'roles', context -> 'roles',
    'preferences', (
      select jsonb_build_object(
        'emailUpdates', preference.email_updates,
        'reducedMotion', preference.reduced_motion,
        'readableMode', preference.readable_mode,
        'optionalUpdatesConsent', preference.optional_updates_consent,
        'version', preference.version
      ) from app_private.participant_preferences preference
      where preference.event_id = v_event_id and preference.user_id = actor
    )
  );
end;
$$;

create or replace function api.participant_profile_update(
  _event_slug text,
  _display_name text,
  _email_updates boolean,
  _reduced_motion boolean,
  _readable_mode boolean,
  _optional_updates_consent boolean,
  _expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  preference app_private.participant_preferences;
  normalized_name text := nullif(trim(_display_name), '');
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if normalized_name is not null and char_length(normalized_name) > 120 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into app_private.participant_preferences(event_id, user_id)
  values (v_event_id, actor) on conflict (event_id, user_id) do nothing;
  select * into preference from app_private.participant_preferences
  where event_id = v_event_id and user_id = actor for update;
  if preference.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  insert into app_private.profiles(user_id, display_name)
  values (actor, normalized_name)
  on conflict (user_id) do update set display_name = excluded.display_name, updated_at = now(), version = app_private.profiles.version + 1;
  update app_private.participant_preferences set
    email_updates = _email_updates,
    reduced_motion = _reduced_motion,
    readable_mode = _readable_mode,
    optional_updates_consent = _optional_updates_consent,
    updated_at = now(),
    version = version + 1
  where event_id = v_event_id and user_id = actor
  returning * into preference;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'participant.preferences_updated', 'profile', actor,
    jsonb_build_object('emailUpdates', _email_updates, 'optionalUpdatesConsent', _optional_updates_consent));
  return jsonb_build_object('version', preference.version);
end;
$$;

create or replace function api.portal_arrivals_snapshot(_portal_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal_record app_private.portals;
begin
  select * into portal_record from app_private.portals where id = _portal_id;
  if actor is null or portal_record.id is null or not (
    exists (select 1 from app_private.portal_owners owner where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null)
    or app_private.has_capability(portal_record.event_id, 'portals_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'portalId', portal_record.id,
    'arrivals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'groupCode', walking_group.code,
        'plannedArrivalAt', stop.planned_arrival_at,
        'plannedDepartureAt', stop.planned_departure_at,
        'expectedChildren', (
          select count(*)
          from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null and child.participation_status = 'active'
        ),
        'state', coalesce(run_stop.state::text, 'planned')
      ) order by stop.planned_arrival_at)
      from app_private.route_plan_stops stop
      join app_private.route_plan_versions plan on plan.id = stop.plan_version_id and plan.state = 'published'
      join app_private.walking_groups walking_group on walking_group.id = plan.group_id
      left join app_private.group_runs run on run.active_plan_version_id = plan.id
      left join app_private.run_stops run_stop on run_stop.run_id = run.id and run_stop.plan_stop_id = stop.id
      where stop.portal_id = portal_record.id
    ), '[]'::jsonb),
    'expectedTotal', coalesce((
      select sum(group_size)
      from (
        select distinct walking_group.id, (
          select count(*)
          from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null and child.participation_status = 'active'
        ) as group_size
        from app_private.route_plan_stops stop
        join app_private.route_plan_versions plan on plan.id = stop.plan_version_id and plan.state = 'published'
        join app_private.walking_groups walking_group on walking_group.id = plan.group_id
        where stop.portal_id = portal_record.id
      ) expected
    ), 0)
  );
end;
$$;

create or replace function api.admin_publish_participant_update(
  _event_slug text,
  _audience_role text,
  _title text,
  _body text,
  _priority text default 'normal',
  _send_email boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  update_record app_private.participant_updates;
  recipient record;
  v_count integer := 0;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if actor is null or v_event_id is null or not (
    app_private.has_capability(v_event_id, 'live_support', actor) or app_private.has_capability(v_event_id, 'content_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _audience_role not in ('all', 'walker', 'viewer', 'homeowner')
     or _priority not in ('normal', 'important', 'urgent')
     or char_length(trim(coalesce(_title, ''))) not between 3 and 120
     or char_length(trim(coalesce(_body, ''))) not between 3 and 1200 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  insert into app_private.participant_updates(event_id, audience_role, title, body, priority, created_by)
  values (v_event_id, _audience_role, trim(_title), trim(_body), _priority, actor)
  returning * into update_record;
  if _send_email then
    for recipient in
      select distinct on (recipient_user_id) recipient_user_id, recipient_email, recipient_role from (
        select member.user_id as recipient_user_id, lower(users.email) as recipient_email, 'walker'::text as recipient_role
        from app_private.household_members member
        join auth.users users on users.id = member.user_id
        join app_private.registrations registration on registration.household_id = member.household_id
        where registration.event_id = v_event_id and registration.status <> 'cancelled' and member.revoked_at is null
          and _audience_role in ('all', 'walker')
        union all
        select access.user_id, lower(users.email), 'viewer'::text
        from app_private.group_viewer_access access
        join auth.users users on users.id = access.user_id
        where access.event_id = v_event_id and access.revoked_at is null
          and (access.expires_at is null or access.expires_at > now()) and _audience_role in ('all', 'viewer')
        union all
        select owner.user_id, lower(users.email), 'homeowner'::text
        from app_private.portal_owners owner
        join app_private.portals portal on portal.id = owner.portal_id
        join auth.users users on users.id = owner.user_id
        where portal.event_id = v_event_id and owner.revoked_at is null and _audience_role in ('all', 'homeowner')
      ) recipients
      where coalesce((
        select preference.email_updates
        from app_private.participant_preferences preference
        where preference.event_id = v_event_id and preference.user_id = recipients.recipient_user_id
      ), true)
      order by recipient_user_id,
        case recipient_role when 'walker' then 1 when 'viewer' then 2 else 3 end
    loop
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'participant-update:' || update_record.id::text || ':' || recipient.recipient_user_id::text,
        'participant_update',
        'participant_update:' || update_record.id::text || ':' || recipient.recipient_user_id::text,
        recipient.recipient_email,
        jsonb_build_object(
          'title', update_record.title,
          'message', update_record.body,
          'actionPath', '/omgeving/' || case recipient.recipient_role when 'walker' then 'meeloper' when 'viewer' then 'meekijker' else 'huiseigenaar' end || '/updates'
        )
      ) on conflict (dedupe_key) do nothing;
      v_count := v_count + 1;
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'participant.update_published', 'participant_update', update_record.id,
    jsonb_build_object('audienceRole', _audience_role, 'emailCount', v_count));
  return jsonb_build_object('id', update_record.id, 'emailCount', v_count);
end;
$$;

-- Keep Hulp & contact notifications inside the unified participant app.
create or replace function app_private.enqueue_group_ticket_notifications(_ticket_id uuid, _message_id uuid)
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
      'actionPath', '/omgeving/meeloper/groep'
    )
  ) on conflict (dedupe_key) do nothing;
end;
$$;

revoke execute on function app_private.has_active_viewer_access(uuid, uuid) from public, anon;
grant execute on function app_private.has_active_viewer_access(uuid, uuid) to authenticated;

revoke execute on function api.participant_context(text) from public, anon;
revoke execute on function api.group_viewer_invite_create(uuid, text, timestamptz) from public, anon;
revoke execute on function api.group_viewer_invite_accept(text) from public, anon;
revoke execute on function api.group_viewer_access_snapshot(uuid) from public, anon;
revoke execute on function api.group_viewer_access_revoke(uuid, text) from public, anon;
revoke execute on function api.group_viewer_invite_revoke(uuid, text) from public, anon;
revoke execute on function api.group_viewer_snapshot(uuid) from public, anon;
revoke execute on function api.participant_updates_snapshot(text, text) from public, anon;
revoke execute on function api.participant_update_mark_read(uuid) from public, anon;
revoke execute on function api.participant_profile_snapshot(text) from public, anon;
revoke execute on function api.participant_profile_update(text, text, boolean, boolean, boolean, boolean, integer) from public, anon;
revoke execute on function api.portal_arrivals_snapshot(uuid) from public, anon;
revoke execute on function api.admin_publish_participant_update(text, text, text, text, text, boolean) from public, anon;

grant execute on function api.participant_context(text) to authenticated;
grant execute on function api.group_viewer_invite_create(uuid, text, timestamptz) to authenticated;
grant execute on function api.group_viewer_invite_accept(text) to authenticated;
grant execute on function api.group_viewer_access_snapshot(uuid) to authenticated;
grant execute on function api.group_viewer_access_revoke(uuid, text) to authenticated;
grant execute on function api.group_viewer_invite_revoke(uuid, text) to authenticated;
grant execute on function api.group_viewer_snapshot(uuid) to authenticated;
grant execute on function api.participant_updates_snapshot(text, text) to authenticated;
grant execute on function api.participant_update_mark_read(uuid) to authenticated;
grant execute on function api.participant_profile_snapshot(text) to authenticated;
grant execute on function api.participant_profile_update(text, text, boolean, boolean, boolean, boolean, integer) to authenticated;
grant execute on function api.portal_arrivals_snapshot(uuid) to authenticated;
grant execute on function api.admin_publish_participant_update(text, text, text, text, text, boolean) to authenticated;

-- A role-specific viewer topic is intentionally not added to Realtime. Viewer
-- progress is pulled from the redacted snapshot, so no raw group broadcast can
-- cross the read-only privacy boundary.
