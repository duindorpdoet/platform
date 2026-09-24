-- Durable participant messenger for walkers, portal owners and viewers.
-- Conversation data remains outside the Data API; browser access is only
-- available through role-scoped RPCs and private Realtime broadcasts.

create table app_private.messenger_conversations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  participant_user_id uuid not null references auth.users(id) on delete restrict,
  subject_kind text not null check (subject_kind in ('group', 'portal', 'viewer', 'user')),
  subject_id uuid not null,
  topic text not null default 'support' check (char_length(topic) between 3 and 80),
  status text not null default 'queued'
    check (status in ('queued', 'live', 'awaiting_organization', 'awaiting_participant', 'closed')),
  created_by uuid not null references auth.users(id) on delete restrict,
  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  close_reason text check (close_reason is null or char_length(close_reason) between 5 and 500),
  legacy_ticket_id uuid unique references app_private.group_support_tickets(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  check ((claimed_by is null and claimed_at is null) or (claimed_by is not null and claimed_at is not null)),
  check (
    (status = 'closed' and closed_at is not null and closed_by is not null and close_reason is not null)
    or (status <> 'closed' and closed_at is null and closed_by is null and close_reason is null)
  )
);

create table app_private.messenger_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references app_private.messenger_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete restrict,
  sender_side text not null check (sender_side in ('participant', 'organization')),
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  read_by uuid references auth.users(id) on delete set null,
  legacy_message_id uuid unique references app_private.group_support_ticket_messages(id) on delete set null,
  check ((read_at is null and read_by is null) or (read_at is not null and read_by is not null))
);

create table app_private.messenger_admin_presence (
  event_id uuid not null references app_private.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_seen_at timestamptz not null default now(),
  available_until timestamptz not null,
  version integer not null default 1 check (version > 0),
  primary key (event_id, user_id),
  check (available_until >= last_seen_at)
);

create index messenger_conversations_participant_idx
  on app_private.messenger_conversations(participant_user_id, event_id, last_message_at desc);
create index messenger_conversations_admin_queue_idx
  on app_private.messenger_conversations(event_id, status, last_message_at desc)
  where status <> 'closed';
create index messenger_conversations_subject_idx
  on app_private.messenger_conversations(event_id, subject_kind, subject_id, last_message_at desc);
create unique index messenger_conversations_one_active_subject_idx
  on app_private.messenger_conversations(event_id, participant_user_id, subject_kind, subject_id, topic)
  where status <> 'closed' and legacy_ticket_id is null;
create index messenger_messages_thread_idx
  on app_private.messenger_messages(conversation_id, created_at, id);
create index messenger_messages_unread_idx
  on app_private.messenger_messages(conversation_id, sender_side, created_at)
  where read_at is null;
create index messenger_admin_presence_available_idx
  on app_private.messenger_admin_presence(event_id, available_until desc);

alter table app_private.messenger_conversations enable row level security;
alter table app_private.messenger_messages enable row level security;
alter table app_private.messenger_admin_presence enable row level security;

revoke all on table app_private.messenger_conversations from public, anon, authenticated;
revoke all on table app_private.messenger_messages from public, anon, authenticated;
revoke all on table app_private.messenger_admin_presence from public, anon, authenticated;

create function app_private.messenger_is_organizer(
  _event_id uuid,
  _actor uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and (
    app_private.has_capability(_event_id, 'event_admin', _actor)
    or app_private.has_capability(_event_id, 'live_support', _actor)
  )
$$;

create function app_private.messenger_actor_can_use_subject(
  _event_id uuid,
  _actor uuid,
  _subject_kind text,
  _subject_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and _subject_id is not null and case _subject_kind
    when 'group' then exists (
      select 1
      from app_private.walking_groups walking_group
      where walking_group.id = _subject_id
        and walking_group.event_id = _event_id
        and (
          app_private.is_current_leader(walking_group.id, _actor)
          or exists (
            select 1
            from app_private.household_members member
            join app_private.registrations registration
              on registration.household_id = member.household_id
              and registration.event_id = walking_group.event_id
              and registration.status <> 'cancelled'
            join app_private.group_registrations assignment
              on assignment.registration_id = registration.id
              and assignment.group_id = walking_group.id
              and assignment.superseded_at is null
            where member.user_id = _actor and member.revoked_at is null
          )
        )
    )
    when 'portal' then exists (
      select 1
      from app_private.portals portal
      join app_private.portal_owners owner
        on owner.portal_id = portal.id and owner.revoked_at is null
      where portal.id = _subject_id and portal.event_id = _event_id and owner.user_id = _actor
    )
    when 'viewer' then exists (
      select 1
      from app_private.group_viewer_access viewer
      where viewer.id = _subject_id and viewer.event_id = _event_id and viewer.user_id = _actor
        and viewer.revoked_at is null and (viewer.expires_at is null or viewer.expires_at > now())
    )
    when 'user' then _subject_id = _actor and (
      exists (
        select 1
        from app_private.household_members member
        join app_private.registrations registration
          on registration.household_id = member.household_id and registration.event_id = _event_id
        where member.user_id = _actor and member.revoked_at is null and registration.status <> 'cancelled'
      )
      or exists (
        select 1 from app_private.portal_owners owner
        join app_private.portals portal on portal.id = owner.portal_id and portal.event_id = _event_id
        where owner.user_id = _actor and owner.revoked_at is null
      )
      or exists (
        select 1 from app_private.group_viewer_access viewer
        where viewer.event_id = _event_id and viewer.user_id = _actor and viewer.revoked_at is null
          and (viewer.expires_at is null or viewer.expires_at > now())
      )
      or exists (
        select 1 from app_private.group_leaders leader
        join app_private.walking_groups walking_group on walking_group.id = leader.group_id and walking_group.event_id = _event_id
        where leader.user_id = _actor and leader.active_from <= now()
          and (leader.active_until is null or leader.active_until > now())
      )
    )
    else false
  end
$$;

create function app_private.consume_messenger_message_budget(_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  message_count integer;
begin
  if _actor is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, expires_at)
  values (
    'messenger_message_actor',
    encode(extensions.digest(convert_to(_actor::text, 'utf8'), 'sha256'), 'hex'),
    date_trunc('hour', now()),
    date_trunc('hour', now()) + interval '2 hours'
  )
  on conflict (scope, opaque_subject_hash, window_start)
  do update set count = app_private.rate_limit_buckets.count + 1
  returning count into message_count;
  if message_count > 30 then
    raise exception 'RATE_LIMITED' using errcode = 'P0001';
  end if;
end;
$$;

create function app_private.messenger_resolve_participant(
  _event_id uuid,
  _subject_kind text,
  _subject_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  participant uuid;
begin
  case _subject_kind
    when 'group' then
      select leader.user_id into participant
      from app_private.group_leaders leader
      join app_private.walking_groups walking_group
        on walking_group.id = leader.group_id and walking_group.event_id = _event_id
      where leader.group_id = _subject_id and leader.active_from <= now()
        and (leader.active_until is null or leader.active_until > now())
      order by leader.revision desc limit 1;
      if participant is null then
        select household.primary_contact_user_id into participant
        from app_private.walking_groups walking_group
        join app_private.group_registrations assignment
          on assignment.group_id = walking_group.id and assignment.superseded_at is null
        join app_private.registrations registration on registration.id = assignment.registration_id
        join app_private.households household on household.id = registration.household_id
        where walking_group.id = _subject_id and walking_group.event_id = _event_id
          and registration.status <> 'cancelled'
        order by assignment.assigned_at, assignment.id limit 1;
      end if;
    when 'portal' then
      select owner.user_id into participant
      from app_private.portals portal
      join app_private.portal_owners owner on owner.portal_id = portal.id and owner.revoked_at is null
      where portal.id = _subject_id and portal.event_id = _event_id
      order by owner.accepted_at, owner.user_id limit 1;
    when 'viewer' then
      select viewer.user_id into participant
      from app_private.group_viewer_access viewer
      where viewer.id = _subject_id and viewer.event_id = _event_id and viewer.revoked_at is null
        and (viewer.expires_at is null or viewer.expires_at > now());
    when 'user' then
      if exists (select 1 from auth.users where id = _subject_id) then participant := _subject_id; end if;
    else null;
  end case;
  return participant;
end;
$$;

create function app_private.messenger_subject_metadata(
  _event_id uuid,
  _subject_kind text,
  _subject_id uuid,
  _participant_user_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  case _subject_kind
    when 'group' then
      select jsonb_build_object(
        'subjectLabel', concat_ws(' · ', walking_group.system_code, coalesce(walking_group.display_name, walking_group.code)),
        'systemCode', walking_group.system_code,
        'displayName', coalesce(walking_group.display_name, walking_group.code)
      ) into result
      from app_private.walking_groups walking_group
      where walking_group.id = _subject_id and walking_group.event_id = _event_id;
    when 'portal' then
      select jsonb_build_object(
        'subjectLabel', concat_ws(' · ', portal.system_code, portal.name),
        'systemCode', portal.system_code,
        'displayName', portal.name
      ) into result
      from app_private.portals portal
      where portal.id = _subject_id and portal.event_id = _event_id;
    when 'viewer' then
      select jsonb_build_object(
        'subjectLabel', concat_ws(' · ', walking_group.system_code, coalesce(walking_group.display_name, walking_group.code), 'meekijker'),
        'systemCode', walking_group.system_code,
        'displayName', coalesce(walking_group.display_name, walking_group.code)
      ) into result
      from app_private.group_viewer_access viewer
      join app_private.walking_groups walking_group on walking_group.id = viewer.group_id
      where viewer.id = _subject_id and viewer.event_id = _event_id;
    when 'user' then
      select jsonb_build_object(
        'subjectLabel', 'Persoonlijk gesprek',
        'systemCode', null,
        'displayName', coalesce(profile.display_name, 'Deelnemer')
      ) into result
      from auth.users users
      left join app_private.profiles profile on profile.user_id = users.id
      where users.id = _participant_user_id;
    else null;
  end case;
  return coalesce(result, jsonb_build_object(
    'subjectLabel', 'Hulp van de organisatie', 'systemCode', null, 'displayName', 'Deelnemer'
  ));
end;
$$;

create function app_private.messenger_conversation_payload(
  _conversation_id uuid,
  _organization_view boolean,
  _actor uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conversation app_private.messenger_conversations;
  metadata jsonb;
begin
  select * into conversation from app_private.messenger_conversations where id = _conversation_id;
  if conversation.id is null then return null; end if;
  if (_organization_view and not app_private.messenger_is_organizer(conversation.event_id, _actor))
     or (not _organization_view and (
       conversation.participant_user_id <> _actor
       or not app_private.messenger_actor_can_use_subject(
         conversation.event_id, _actor, conversation.subject_kind, conversation.subject_id
       )
     )) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  metadata := app_private.messenger_subject_metadata(
    conversation.event_id, conversation.subject_kind, conversation.subject_id, conversation.participant_user_id
  );
  return jsonb_build_object(
    'id', conversation.id,
    'subjectKind', conversation.subject_kind,
    'subjectId', conversation.subject_id,
    'subjectLabel', metadata ->> 'subjectLabel',
    'systemCode', metadata -> 'systemCode',
    'displayName', metadata ->> 'displayName',
    'status', conversation.status,
    'version', conversation.version,
    'claimedBy', case when _organization_view then to_jsonb(conversation.claimed_by) else null end,
    'updatedAt', conversation.updated_at,
    'unreadCount', (
      select count(*) from app_private.messenger_messages message
      where message.conversation_id = conversation.id and message.read_at is null
        and message.sender_side = case when _organization_view then 'participant' else 'organization' end
    ),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', message.id,
        'senderSide', message.sender_side,
        'body', message.body,
        'createdAt', message.created_at,
        'isMine', message.sender_side = case when _organization_view then 'organization' else 'participant' end,
        'readAt', message.read_at,
        'mailStatus', (
          select outbox.status::text from app_private.email_outbox outbox
          where outbox.dedupe_key = case
            when message.sender_side = 'organization' then 'messenger-admin-reply:' || message.id::text
            else 'messenger-incoming-admin:' || conversation.id::text || ':' || to_char(message.created_at at time zone 'UTC', 'YYYYMMDDHH24')
          end limit 1
        )
      ) order by message.created_at, message.id)
      from (
        select recent.*
        from app_private.messenger_messages recent
        where recent.conversation_id = conversation.id
        order by recent.created_at desc, recent.id desc
        limit 100
      ) message
    ), '[]'::jsonb)
  );
end;
$$;

create function app_private.enqueue_messenger_notification(
  _conversation_id uuid,
  _message_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  event_record app_private.events;
  recipient_email text;
begin
  select * into conversation from app_private.messenger_conversations where id = _conversation_id;
  select * into message from app_private.messenger_messages where id = _message_id and conversation_id = _conversation_id;
  select * into event_record from app_private.events where id = conversation.event_id;
  if conversation.id is null or message.id is null then raise exception 'MESSENGER_MESSAGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if message.sender_side = 'participant' then
    recipient_email := lower(trim(event_record.settings ->> 'supportEmail'));
    if recipient_email is not null and recipient_email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'messenger-incoming-admin:' || conversation.id::text || ':' || to_char(message.created_at at time zone 'UTC', 'YYYYMMDDHH24'),
        'messenger_incoming_admin', conversation.id::text, recipient_email,
        jsonb_build_object('conversationId', conversation.id, 'actionPath', '/admin?section=messenger')
      ) on conflict (dedupe_key) do nothing;
    end if;
  else
    select lower(users.email) into recipient_email from auth.users users
    where users.id = conversation.participant_user_id and users.email_confirmed_at is not null;
    if recipient_email is not null then
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'messenger-admin-reply:' || message.id::text,
        'messenger_admin_reply', conversation.id::text, recipient_email,
        jsonb_build_object('conversationId', conversation.id, 'actionPath', '/omgeving')
      ) on conflict (dedupe_key) do nothing;
    end if;
  end if;
end;
$$;

-- Import every existing ticket and message with their original identifiers.
insert into app_private.messenger_conversations(
  id, event_id, participant_user_id, subject_kind, subject_id, topic, status,
  created_by, closed_at, closed_by, close_reason, legacy_ticket_id,
  created_at, updated_at, last_message_at, version
)
select
  ticket.id, ticket.event_id, ticket.opened_by, 'group', ticket.group_id,
  left('legacy:' || ticket.category || ':' || ticket.subject, 80),
  case ticket.status when 'awaiting_organization' then 'awaiting_organization'
    when 'awaiting_leader' then 'awaiting_participant' when 'resolved' then 'closed'
    when 'closed' then 'closed' else 'queued' end,
  ticket.opened_by,
  case when ticket.status in ('resolved', 'closed') then ticket.updated_at else null end,
  case when ticket.status in ('resolved', 'closed') then ticket.opened_by else null end,
  case when ticket.status in ('resolved', 'closed') then 'Geïmporteerd afgesloten supportgesprek' else null end,
  ticket.id, ticket.created_at, ticket.updated_at, ticket.last_message_at, ticket.version
from app_private.group_support_tickets ticket on conflict (id) do nothing;

insert into app_private.messenger_messages(
  id, conversation_id, sender_id, sender_side, body, created_at, read_at, read_by, legacy_message_id
)
select message.id, message.ticket_id, message.sender_id,
  case message.sender_side when 'organization' then 'organization' else 'participant' end,
  message.body, message.created_at, message.read_at, message.read_by, message.id
from app_private.group_support_ticket_messages message
where exists (select 1 from app_private.messenger_conversations conversation where conversation.id = message.ticket_id)
on conflict (id) do nothing;

create function app_private.sync_legacy_ticket_to_messenger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into app_private.messenger_conversations(
    id, event_id, participant_user_id, subject_kind, subject_id, topic, status,
    created_by, closed_at, closed_by, close_reason, legacy_ticket_id,
    created_at, updated_at, last_message_at, version
  ) values (
    new.id, new.event_id, new.opened_by, 'group', new.group_id,
    left('legacy:' || new.category || ':' || new.subject, 80),
    case new.status when 'awaiting_organization' then 'awaiting_organization'
      when 'awaiting_leader' then 'awaiting_participant' when 'resolved' then 'closed'
      when 'closed' then 'closed' else 'queued' end,
    new.opened_by,
    case when new.status in ('resolved', 'closed') then new.updated_at else null end,
    case when new.status in ('resolved', 'closed') then new.opened_by else null end,
    case when new.status in ('resolved', 'closed') then 'Afgesloten via bestaande supportinbox' else null end,
    new.id, new.created_at, new.updated_at, new.last_message_at, new.version
  ) on conflict (id) do update set
    status = excluded.status, closed_at = excluded.closed_at, closed_by = excluded.closed_by,
    close_reason = excluded.close_reason, updated_at = excluded.updated_at,
    last_message_at = excluded.last_message_at,
    version = greatest(app_private.messenger_conversations.version, excluded.version);
  return new;
end;
$$;

create function app_private.sync_legacy_ticket_message_to_messenger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into app_private.messenger_messages(
    id, conversation_id, sender_id, sender_side, body, created_at, read_at, read_by, legacy_message_id
  ) values (
    new.id, new.ticket_id, new.sender_id,
    case new.sender_side when 'organization' then 'organization' else 'participant' end,
    new.body, new.created_at, new.read_at, new.read_by, new.id
  ) on conflict (id) do update set read_at = excluded.read_at, read_by = excluded.read_by;
  return new;
end;
$$;

create trigger messenger_sync_legacy_ticket after insert or update on app_private.group_support_tickets
for each row execute function app_private.sync_legacy_ticket_to_messenger();
create trigger messenger_sync_legacy_ticket_message after insert or update of read_at, read_by on app_private.group_support_ticket_messages
for each row execute function app_private.sync_legacy_ticket_message_to_messenger();

create or replace function app_private.can_access_realtime_topic(_topic text, _actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select _actor is not null and case
    when _topic like 'group:%' then exists (
      select 1 from app_private.walking_groups walking_group
      where walking_group.id::text = split_part(_topic, ':', 2) and (
        app_private.is_current_leader(walking_group.id, _actor)
        or app_private.has_capability(walking_group.event_id, 'live_support', _actor)
        or exists (
          select 1 from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          join app_private.group_registrations assignment on assignment.registration_id = registration.id
          where member.user_id = _actor and member.revoked_at is null
            and assignment.group_id = walking_group.id and assignment.superseded_at is null
        )
      )
    )
    when _topic like 'portal:%' then exists (
      select 1 from app_private.portals portal where portal.id::text = split_part(_topic, ':', 2) and (
        exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = _actor and owner.revoked_at is null)
        or app_private.has_capability(portal.event_id, 'portals_manage', _actor)
      )
    )
    when _topic like 'messenger:%' then exists (
      select 1 from app_private.messenger_conversations conversation
      where conversation.id::text = split_part(_topic, ':', 2)
        and (
          app_private.messenger_is_organizer(conversation.event_id, _actor)
          or (
            conversation.participant_user_id = _actor
            and app_private.messenger_actor_can_use_subject(
              conversation.event_id, _actor, conversation.subject_kind, conversation.subject_id
            )
          )
        )
    )
    when _topic like 'messenger-admin:%' then app_private.messenger_is_organizer(
      nullif(split_part(_topic, ':', 2), '')::uuid, _actor
    )
    else false end
$$;

create function app_private.notify_messenger_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare conversation app_private.messenger_conversations;
begin
  select * into conversation from app_private.messenger_conversations where id = coalesce(new.conversation_id, new.id);
  if conversation.id is not null then
    perform realtime.send(
      jsonb_build_object('resource', 'messenger_conversation', 'conversationId', conversation.id, 'version', conversation.version),
      'snapshot_changed', 'messenger:' || conversation.id::text, true
    );
    perform realtime.send(
      jsonb_build_object('resource', 'messenger_conversation', 'conversationId', conversation.id, 'version', conversation.version),
      'snapshot_changed', 'messenger-admin:' || conversation.event_id::text, true
    );
  end if;
  return new;
end;
$$;

create trigger messenger_message_broadcast after insert or update of read_at on app_private.messenger_messages
for each row execute function app_private.notify_messenger_change();

create function api.participant_messenger_context(
  _event_slug text,
  _role text,
  _group_id uuid default null,
  _portal_id uuid default null,
  _viewer_access_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  subject_kind text;
  subject_id uuid;
  metadata jsonb;
  conversation_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  case _role
    when 'walker' then subject_kind := 'group'; subject_id := _group_id;
    when 'group' then subject_kind := 'group'; subject_id := _group_id;
    when 'homeowner' then subject_kind := 'portal'; subject_id := _portal_id;
    when 'portal' then subject_kind := 'portal'; subject_id := _portal_id;
    when 'viewer' then subject_kind := 'viewer'; subject_id := _viewer_access_id;
    when 'user' then subject_kind := 'user'; subject_id := actor;
    else raise exception 'INVALID_MESSENGER_ROLE' using errcode = '22023';
  end case;
  if not app_private.messenger_actor_can_use_subject(event_record.id, actor, subject_kind, subject_id) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  metadata := app_private.messenger_subject_metadata(event_record.id, subject_kind, subject_id, actor);
  select conversation.id into conversation_id
  from app_private.messenger_conversations conversation
  where conversation.event_id = event_record.id
    and conversation.participant_user_id = actor
    and conversation.subject_kind = subject_kind and conversation.subject_id = subject_id
  order by (conversation.status <> 'closed') desc, conversation.last_message_at desc limit 1;
  return jsonb_build_object(
    'available', exists (
      select 1 from app_private.messenger_admin_presence presence
      where presence.event_id = event_record.id and presence.available_until > now()
    ),
    'subjectKind', subject_kind,
    'subjectId', subject_id,
    'subjectLabel', metadata ->> 'subjectLabel',
    'systemCode', metadata -> 'systemCode',
    'displayName', metadata ->> 'displayName',
    'conversation', case when conversation_id is null then null
      else app_private.messenger_conversation_payload(conversation_id, false, actor) end
  );
end;
$$;

create function api.participant_messenger_snapshot(_event_slug text)
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
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'available', exists (
      select 1 from app_private.messenger_admin_presence presence
      where presence.event_id = event_record.id and presence.available_until > now()
    ),
    'conversations', coalesce((
      select jsonb_agg(
        app_private.messenger_conversation_payload(conversation.id, false, actor)
        order by (conversation.status <> 'closed') desc, conversation.last_message_at desc
      )
      from (
        select candidate.*
        from app_private.messenger_conversations candidate
        where candidate.event_id = event_record.id
          and candidate.participant_user_id = actor
          and app_private.messenger_actor_can_use_subject(
            candidate.event_id, actor, candidate.subject_kind, candidate.subject_id
          )
        order by (candidate.status <> 'closed') desc, candidate.last_message_at desc
        limit 20
      ) conversation
    ), '[]'::jsonb)
  );
end;
$$;

create function api.admin_messenger_snapshot(_event_slug text)
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
  if event_record.id is null or not app_private.messenger_is_organizer(event_record.id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'realtimeTopic', 'messenger-admin:' || event_record.id::text,
    'availableAdmins', coalesce((
      select count(*) from app_private.messenger_admin_presence presence
      where presence.event_id = event_record.id and presence.available_until > now()
    ), 0),
    'conversations', coalesce((
      select jsonb_agg(
        app_private.messenger_conversation_payload(conversation.id, true, actor)
        order by (conversation.status <> 'closed') desc,
          case conversation.status when 'queued' then 0 when 'awaiting_organization' then 1 else 2 end,
          conversation.last_message_at desc
      )
      from (
        select candidate.*
        from app_private.messenger_conversations candidate
        where candidate.event_id = event_record.id
        order by (candidate.status <> 'closed') desc,
          case candidate.status when 'queued' then 0 when 'awaiting_organization' then 1 else 2 end,
          candidate.last_message_at desc
        limit 100
      ) conversation
    ), '[]'::jsonb)
  );
end;
$$;

create function api.admin_messenger_presence(
  _event_slug text,
  _available boolean,
  _ttl_seconds integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  presence app_private.messenger_admin_presence;
  ttl integer := coalesce(_ttl_seconds, 90);
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not app_private.messenger_is_organizer(event_record.id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if ttl not between 30 and 300 then raise exception 'INVALID_PRESENCE_TTL' using errcode = '22023'; end if;
  insert into app_private.messenger_admin_presence(event_id, user_id, last_seen_at, available_until)
  values (
    event_record.id, actor, now(),
    case when coalesce(_available, false) then now() + make_interval(secs => ttl) else now() end
  )
  on conflict (event_id, user_id) do update set
    last_seen_at = excluded.last_seen_at,
    available_until = excluded.available_until,
    version = app_private.messenger_admin_presence.version + 1
  returning * into presence;
  return jsonb_build_object(
    'available', presence.available_until > now(),
    'availableUntil', presence.available_until,
    'version', presence.version
  );
end;
$$;

create function api.participant_messenger_create(
  _event_slug text,
  _subject_kind text,
  _subject_id uuid,
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
  event_record app_private.events;
  receipt app_private.command_receipts;
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  next_status text;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if _subject_kind not in ('group', 'portal', 'viewer', 'user')
     or char_length(trim(coalesce(_body, ''))) not between 1 and 4000
     or nullif(trim(coalesce(_idempotency_key, '')), '') is null
     or nullif(trim(coalesce(_request_hash, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if not app_private.messenger_actor_can_use_subject(event_record.id, actor, _subject_kind, _subject_id) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    actor::text || ':messenger:' || _subject_kind || ':' || _subject_id::text, 0
  ));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'messenger.participant.create' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  perform app_private.consume_messenger_message_budget(actor);
  select * into conversation
  from app_private.messenger_conversations candidate
  where candidate.event_id = event_record.id and candidate.participant_user_id = actor
    and candidate.subject_kind = _subject_kind and candidate.subject_id = _subject_id
    and candidate.topic = 'support' and candidate.legacy_ticket_id is null
  order by (candidate.status <> 'closed') desc, candidate.last_message_at desc
  limit 1 for update;
  next_status := case when exists (
    select 1 from app_private.messenger_admin_presence presence
    where presence.event_id = event_record.id and presence.available_until > now()
  ) then 'queued' else 'awaiting_organization' end;
  if conversation.id is null then
    insert into app_private.messenger_conversations(
      event_id, participant_user_id, subject_kind, subject_id, status, created_by
    ) values (event_record.id, actor, _subject_kind, _subject_id, next_status, actor)
    returning * into conversation;
  elsif conversation.status = 'closed' then
    update app_private.messenger_conversations set
      status = next_status, claimed_by = null, claimed_at = null,
      closed_at = null, closed_by = null, close_reason = null,
      updated_at = now(), version = version + 1
    where id = conversation.id returning * into conversation;
  end if;
  insert into app_private.messenger_messages(conversation_id, sender_id, sender_side, body)
  values (conversation.id, actor, 'participant', trim(_body)) returning * into message;
  update app_private.messenger_conversations set
    status = case
      when claimed_by is not null and exists (
        select 1 from app_private.messenger_admin_presence presence
        where presence.event_id = event_record.id and presence.user_id = claimed_by and presence.available_until > now()
      ) then 'live'
      else next_status
    end,
    last_message_at = message.created_at, updated_at = message.created_at, version = version + 1
  where id = conversation.id returning * into conversation;
  perform app_private.enqueue_messenger_notification(conversation.id, message.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'messenger.conversation_started', 'messenger_conversation', conversation.id,
    jsonb_build_object('subjectKind', _subject_kind));
  result := jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'messenger.participant.create', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;


create function api.participant_messenger_reply(
  _conversation_id uuid,
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
  receipt app_private.command_receipts;
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  result jsonb;
begin
  if actor is null
     or char_length(trim(coalesce(_body, ''))) not between 1 and 4000
     or nullif(trim(coalesce(_idempotency_key, '')), '') is null
     or nullif(trim(coalesce(_request_hash, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id and participant_user_id = actor;
  if conversation.id is null or not app_private.messenger_actor_can_use_subject(
    conversation.event_id, actor, conversation.subject_kind, conversation.subject_id
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select * into receipt
  from app_private.command_receipts
  where actor_id = actor
    and command_type = 'messenger.participant.reply'
    and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return receipt.safe_result;
  end if;
  perform app_private.consume_messenger_message_budget(actor);

  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id and participant_user_id = actor
  for update;
  if conversation.id is null or not app_private.messenger_actor_can_use_subject(
    conversation.event_id, actor, conversation.subject_kind, conversation.subject_id
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if conversation.status = 'closed' then raise exception 'CONVERSATION_CLOSED' using errcode = '55000'; end if;
  if conversation.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;

  insert into app_private.messenger_messages(conversation_id, sender_id, sender_side, body)
  values (conversation.id, actor, 'participant', trim(_body))
  returning * into message;

  update app_private.messenger_conversations
  set status = case when claimed_by is not null and exists (
      select 1
      from app_private.messenger_admin_presence presence
      where presence.event_id = conversation.event_id
        and presence.user_id = conversation.claimed_by
        and presence.available_until > now()
    ) then 'live' else 'awaiting_organization' end,
    last_message_at = message.created_at,
    updated_at = message.created_at,
    version = version + 1
  where id = conversation.id
  returning * into conversation;

  perform app_private.enqueue_messenger_notification(conversation.id, message.id);
  result := jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'messenger.participant.reply', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create function api.participant_messenger_mark_read(_conversation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  conversation app_private.messenger_conversations;
  organization_view boolean;
  changed integer;
begin
  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id;

  organization_view := conversation.id is not null
    and app_private.messenger_is_organizer(conversation.event_id, actor);
  if conversation.id is null
     or (
       not organization_view
       and (
         conversation.participant_user_id <> actor
         or not app_private.messenger_actor_can_use_subject(
           conversation.event_id, actor, conversation.subject_kind, conversation.subject_id
         )
       )
     ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  update app_private.messenger_messages
  set read_at = now(), read_by = actor
  where conversation_id = conversation.id
    and read_at is null
    and sender_side = case when organization_view then 'participant' else 'organization' end;
  get diagnostics changed = row_count;
  return jsonb_build_object('conversationId', conversation.id, 'markedRead', changed);
end;
$$;

create function api.admin_messenger_create(
  _event_slug text,
  _subject_kind text,
  _subject_id uuid,
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
  participant uuid;
  event_record app_private.events;
  receipt app_private.command_receipts;
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  result jsonb;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not app_private.messenger_is_organizer(event_record.id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _subject_kind not in ('group', 'portal', 'viewer', 'user')
     or char_length(trim(coalesce(_body, ''))) not between 1 and 4000
     or nullif(trim(coalesce(_idempotency_key, '')), '') is null
     or nullif(trim(coalesce(_request_hash, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  participant := app_private.messenger_resolve_participant(event_record.id, _subject_kind, _subject_id);
  if participant is null
     or not app_private.messenger_actor_can_use_subject(event_record.id, participant, _subject_kind, _subject_id) then
    raise exception 'PARTICIPANT_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    event_record.id::text || ':messenger:' || _subject_kind || ':' || _subject_id::text, 0
  ));
  select * into receipt
  from app_private.command_receipts
  where actor_id = actor and command_type = 'messenger.admin.create' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  select * into conversation
  from app_private.messenger_conversations candidate
  where candidate.event_id = event_record.id
    and candidate.participant_user_id = participant
    and candidate.subject_kind = _subject_kind
    and candidate.subject_id = _subject_id
    and candidate.topic = 'support'
    and candidate.status <> 'closed'
    and candidate.legacy_ticket_id is null
  order by candidate.last_message_at desc
  limit 1 for update;

  if conversation.id is null then
    insert into app_private.messenger_conversations(
      event_id, participant_user_id, subject_kind, subject_id, status,
      created_by, claimed_by, claimed_at
    ) values (
      event_record.id, participant, _subject_kind, _subject_id, 'awaiting_participant',
      actor, actor, now()
    ) returning * into conversation;
  end if;

  insert into app_private.messenger_messages(conversation_id, sender_id, sender_side, body)
  values (conversation.id, actor, 'organization', trim(_body))
  returning * into message;

  update app_private.messenger_conversations
  set status = 'awaiting_participant',
    claimed_by = actor,
    claimed_at = coalesce(claimed_at, now()),
    last_message_at = message.created_at,
    updated_at = message.created_at,
    version = version + 1
  where id = conversation.id
  returning * into conversation;

  perform app_private.enqueue_messenger_notification(conversation.id, message.id);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'messenger.admin_started', 'messenger_conversation', conversation.id,
    jsonb_build_object('subjectKind', _subject_kind));

  result := jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'messenger.admin.create', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create function api.admin_messenger_claim(
  _conversation_id uuid,
  _expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  conversation app_private.messenger_conversations;
  active_other boolean;
begin
  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id
  for update;
  if conversation.id is null
     or not app_private.messenger_is_organizer(conversation.event_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if conversation.status = 'closed' then raise exception 'CONVERSATION_CLOSED' using errcode = '55000'; end if;
  if conversation.claimed_by = actor and conversation.status = 'live' then
    return jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
  end if;
  if conversation.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;

  select exists (
    select 1
    from app_private.messenger_admin_presence presence
    where presence.event_id = conversation.event_id
      and presence.user_id = conversation.claimed_by
      and presence.available_until > now()
      and presence.user_id <> actor
  ) into active_other;
  if active_other then raise exception 'CONVERSATION_ALREADY_CLAIMED' using errcode = '55000'; end if;

  update app_private.messenger_conversations
  set claimed_by = actor, claimed_at = now(), status = 'live',
      updated_at = now(), version = version + 1
  where id = conversation.id
  returning * into conversation;

  update app_private.messenger_messages
  set read_at = now(), read_by = actor
  where conversation_id = conversation.id and sender_side = 'participant' and read_at is null;

  return jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
end;
$$;

create function api.admin_messenger_reply(
  _conversation_id uuid,
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
  receipt app_private.command_receipts;
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  active_other boolean;
  result jsonb;
begin
  if actor is null
     or char_length(trim(coalesce(_body, ''))) not between 1 and 4000
     or nullif(trim(coalesce(_idempotency_key, '')), '') is null
     or nullif(trim(coalesce(_request_hash, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select * into conversation from app_private.messenger_conversations where id = _conversation_id;
  if conversation.id is null
     or not app_private.messenger_is_organizer(conversation.event_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  select * into receipt
  from app_private.command_receipts
  where actor_id = actor and command_type = 'messenger.admin.reply' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id
  for update;
  if conversation.status = 'closed' then raise exception 'CONVERSATION_CLOSED' using errcode = '55000'; end if;
  if conversation.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;

  select exists (
    select 1 from app_private.messenger_admin_presence presence
    where presence.event_id = conversation.event_id
      and presence.user_id = conversation.claimed_by
      and presence.available_until > now()
      and presence.user_id <> actor
  ) into active_other;
  if active_other then raise exception 'CONVERSATION_ALREADY_CLAIMED' using errcode = '55000'; end if;

  insert into app_private.messenger_messages(conversation_id, sender_id, sender_side, body)
  values (conversation.id, actor, 'organization', trim(_body))
  returning * into message;

  update app_private.messenger_messages
  set read_at = now(), read_by = actor
  where conversation_id = conversation.id and sender_side = 'participant' and read_at is null;

  update app_private.messenger_conversations
  set claimed_by = actor,
    claimed_at = case when claimed_by = actor then claimed_at else now() end,
    status = 'awaiting_participant',
    last_message_at = message.created_at,
    updated_at = message.created_at,
    version = version + 1
  where id = conversation.id
  returning * into conversation;

  perform app_private.enqueue_messenger_notification(conversation.id, message.id);
  result := jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'messenger.admin.reply', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create function api.admin_messenger_close(
  _conversation_id uuid,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  conversation app_private.messenger_conversations;
begin
  select * into conversation
  from app_private.messenger_conversations
  where id = _conversation_id
  for update;
  if conversation.id is null
     or not app_private.messenger_is_organizer(conversation.event_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if conversation.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  update app_private.messenger_conversations
  set status = 'closed', closed_at = now(), closed_by = actor,
      close_reason = trim(_reason), updated_at = now(), version = version + 1
  where id = conversation.id
  returning * into conversation;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (conversation.event_id, actor, 'messenger.closed', 'messenger_conversation', conversation.id,
    jsonb_build_object('reason', trim(_reason)));

  return jsonb_build_object('id', conversation.id, 'status', conversation.status, 'version', conversation.version);
end;
$$;

revoke all on function app_private.messenger_is_organizer(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.messenger_actor_can_use_subject(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function app_private.consume_messenger_message_budget(uuid) from public, anon, authenticated;
revoke all on function app_private.messenger_resolve_participant(uuid, text, uuid) from public, anon, authenticated;
revoke all on function app_private.messenger_subject_metadata(uuid, text, uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.messenger_conversation_payload(uuid, boolean, uuid) from public, anon, authenticated;
revoke all on function app_private.enqueue_messenger_notification(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.sync_legacy_ticket_to_messenger() from public, anon, authenticated;
revoke all on function app_private.sync_legacy_ticket_message_to_messenger() from public, anon, authenticated;
revoke all on function app_private.notify_messenger_change() from public, anon, authenticated;

revoke all on function api.participant_messenger_context(text, text, uuid, uuid, uuid) from public, anon;
revoke all on function api.participant_messenger_snapshot(text) from public, anon;
revoke all on function api.participant_messenger_create(text, text, uuid, text, text, text) from public, anon;
revoke all on function api.participant_messenger_reply(uuid, integer, text, text, text) from public, anon;
revoke all on function api.participant_messenger_mark_read(uuid) from public, anon;
revoke all on function api.admin_messenger_snapshot(text) from public, anon;
revoke all on function api.admin_messenger_create(text, text, uuid, text, text, text) from public, anon;
revoke all on function api.admin_messenger_claim(uuid, integer) from public, anon;
revoke all on function api.admin_messenger_reply(uuid, integer, text, text, text) from public, anon;
revoke all on function api.admin_messenger_presence(text, boolean, integer) from public, anon;
revoke all on function api.admin_messenger_close(uuid, integer, text) from public, anon;

grant execute on function api.participant_messenger_context(text, text, uuid, uuid, uuid) to authenticated;
grant execute on function api.participant_messenger_snapshot(text) to authenticated;
grant execute on function api.participant_messenger_create(text, text, uuid, text, text, text) to authenticated;
grant execute on function api.participant_messenger_reply(uuid, integer, text, text, text) to authenticated;
grant execute on function api.participant_messenger_mark_read(uuid) to authenticated;
grant execute on function api.admin_messenger_snapshot(text) to authenticated;
grant execute on function api.admin_messenger_create(text, text, uuid, text, text, text) to authenticated;
grant execute on function api.admin_messenger_claim(uuid, integer) to authenticated;
grant execute on function api.admin_messenger_reply(uuid, integer, text, text, text) to authenticated;
grant execute on function api.admin_messenger_presence(text, boolean, integer) to authenticated;
grant execute on function api.admin_messenger_close(uuid, integer, text) to authenticated;

select pg_notify('pgrst', 'reload schema');

create or replace function app_private.notify_messenger_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  conversation app_private.messenger_conversations;
begin
  if tg_table_name = 'messenger_messages' then
    select * into conversation
    from app_private.messenger_conversations
    where id = new.conversation_id;
  else
    conversation := new;
  end if;
  if conversation.id is not null then
    perform realtime.send(
      jsonb_build_object('resource', 'messenger_conversation', 'conversationId', conversation.id, 'version', conversation.version),
      'snapshot_changed', 'messenger:' || conversation.id::text, true
    );
    perform realtime.send(
      jsonb_build_object('resource', 'messenger_conversation', 'conversationId', conversation.id, 'version', conversation.version),
      'snapshot_changed', 'messenger-admin:' || conversation.event_id::text, true
    );
  end if;
  return new;
end;
$$;

drop trigger if exists messenger_conversation_broadcast on app_private.messenger_conversations;
create trigger messenger_conversation_broadcast
after update of status, claimed_by, updated_at, version on app_private.messenger_conversations
for each row execute function app_private.notify_messenger_change();

select pg_notify('pgrst', 'reload schema');

create or replace function api.participant_messenger_context(
  _event_slug text,
  _role text,
  _group_id uuid default null,
  _portal_id uuid default null,
  _viewer_access_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  context_subject_kind text;
  context_subject_id uuid;
  metadata jsonb;
  conversation_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  case _role
    when 'walker' then context_subject_kind := 'group'; context_subject_id := _group_id;
    when 'group' then context_subject_kind := 'group'; context_subject_id := _group_id;
    when 'homeowner' then context_subject_kind := 'portal'; context_subject_id := _portal_id;
    when 'portal' then context_subject_kind := 'portal'; context_subject_id := _portal_id;
    when 'viewer' then context_subject_kind := 'viewer'; context_subject_id := _viewer_access_id;
    when 'user' then context_subject_kind := 'user'; context_subject_id := actor;
    else raise exception 'INVALID_MESSENGER_ROLE' using errcode = '22023';
  end case;
  if not app_private.messenger_actor_can_use_subject(
    event_record.id, actor, context_subject_kind, context_subject_id
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  metadata := app_private.messenger_subject_metadata(
    event_record.id, context_subject_kind, context_subject_id, actor
  );
  select candidate.id into conversation_id
  from app_private.messenger_conversations candidate
  where candidate.event_id = event_record.id
    and candidate.participant_user_id = actor
    and candidate.subject_kind = context_subject_kind
    and candidate.subject_id = context_subject_id
  order by (candidate.status <> 'closed') desc, candidate.last_message_at desc
  limit 1;
  return jsonb_build_object(
    'available', exists (
      select 1 from app_private.messenger_admin_presence presence
      where presence.event_id = event_record.id and presence.available_until > now()
    ),
    'subjectKind', context_subject_kind,
    'subjectId', context_subject_id,
    'subjectLabel', metadata ->> 'subjectLabel',
    'systemCode', metadata -> 'systemCode',
    'displayName', metadata ->> 'displayName',
    'conversation', case when conversation_id is null then null
      else app_private.messenger_conversation_payload(conversation_id, false, actor) end
  );
end;
$$;

revoke all on function api.participant_messenger_context(text, text, uuid, uuid, uuid) from public, anon;
grant execute on function api.participant_messenger_context(text, text, uuid, uuid, uuid) to authenticated;
select pg_notify('pgrst', 'reload schema');
