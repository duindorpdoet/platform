begin;

-- Retain retired shared channels for audit/history, but make them unavailable
-- through every guarded chat entrypoint.
alter table app_private.portal_room_channels
  add column if not exists archived_at timestamptz;

create or replace function app_private.poortkamer_channel_access(_channel uuid)
returns app_private.portal_room_channels
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  channel app_private.portal_room_channels;
begin
  select * into channel
  from app_private.portal_room_channels
  where id = _channel
    and archived_at is null;

  if channel.id is null or auth.uid() is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  if channel.kind = 'team' then
    perform app_private.poortkamer_require(channel.portal_id);
  elsif not app_private.poortkamer_community(channel.event_id) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return channel;
end
$$;

-- Algemeen and Hulp gevraagd are event-wide. The preparation rooms are
-- created separately for every portal and can only be opened by that team.
create or replace function app_private.poortkamer_channels(
  _event uuid,
  _portal uuid default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app_private.portal_room_channels
  set name = 'Mededelingen'
  where event_id = _event
    and kind = 'announcements'
    and name = 'De Omroeper'
    and not exists (
      select 1
      from app_private.portal_room_channels existing
      where existing.event_id = _event
        and existing.kind = 'announcements'
        and existing.name = 'Mededelingen'
    );

  update app_private.portal_room_channels
  set name = 'Hulp gevraagd'
  where event_id = _event
    and kind = 'community'
    and name = 'Hulp & materialen'
    and archived_at is null
    and not exists (
      select 1
      from app_private.portal_room_channels existing
      where existing.event_id = _event
        and existing.kind = 'community'
        and existing.name = 'Hulp gevraagd'
    );

  update app_private.portal_room_channels
  set archived_at = coalesce(archived_at, now())
  where event_id = _event
    and kind = 'community'
    and name in (
      'Hulp & materialen',
      'Snoep & voorraad',
      'Voorbereiding',
      'Decor & techniek',
      'Decor en techniek',
      'Tijdens de avond'
    );

  update app_private.portal_room_channels
  set archived_at = coalesce(archived_at, now())
  where event_id = _event
    and kind = 'announcements'
    and name = 'De Omroeper';

  insert into app_private.portal_room_channels(event_id, kind, name, archived_at)
  values
    (_event, 'community', 'Algemeen', null),
    (_event, 'community', 'Hulp gevraagd', null),
    (_event, 'announcements', 'Mededelingen', null)
  on conflict (event_id, portal_id, name)
  do update set archived_at = null;

  if _portal is not null then
    insert into app_private.portal_room_channels(event_id, portal_id, kind, name, archived_at)
    values
      (_event, _portal, 'team', 'Achter de Poort', null),
      (_event, _portal, 'team', 'Voorbereiding', null),
      (_event, _portal, 'team', 'Decor en techniek', null),
      (_event, _portal, 'team', 'Tijdens de avond', null)
    on conflict (event_id, portal_id, name)
    do update set archived_at = null;
  end if;
end
$$;

-- The legacy help command still targets the retired stock room internally.
-- Preserve its authorization/idempotency contract, then route its message to
-- the active public help room (also on installations without a legacy room).
create or replace function api.portal_room_update(
  _portal_id uuid,
  _operation text,
  _payload jsonb,
  _key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  portal app_private.portals;
  help_channel uuid;
begin
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
$$;

do $$
declare
  event_record record;
  portal record;
begin
  for event_record in select id from app_private.events loop
    perform app_private.poortkamer_channels(event_record.id);
  end loop;

  for portal in select id, event_id from app_private.portals loop
    perform app_private.poortkamer_channels(portal.event_id, portal.id);
  end loop;
end
$$;

-- Project only active rooms and return them in the product's fixed order.
create or replace function api.portal_room_snapshot(
  _event_slug text,
  _portal_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base jsonb;
  pid uuid;
begin
  base := api.portal_room_snapshot_v1(_event_slug, _portal_id);
  if base is null then
    return null;
  end if;

  pid := (base #>> '{portal,id}')::uuid;
  base := jsonb_set(
    base,
    '{channels}',
    coalesce((
      select jsonb_agg(channel order by
        case channel->>'kind'
          when 'team' then 0
          when 'community' then 1
          else 2
        end,
        case
          when channel->>'kind' = 'team' and channel->>'name' = 'Achter de Poort' then 0
          when channel->>'kind' = 'team' and channel->>'name' = 'Voorbereiding' then 1
          when channel->>'kind' = 'team' and channel->>'name' = 'Decor en techniek' then 2
          when channel->>'kind' = 'team' and channel->>'name' = 'Tijdens de avond' then 3
          when channel->>'kind' = 'community' and channel->>'name' = 'Algemeen' then 0
          when channel->>'kind' = 'community' and channel->>'name' = 'Hulp gevraagd' then 1
          else 9
        end,
        channel->>'name'
      )
      from jsonb_array_elements(base->'channels') channel
      where channel->>'kind' = 'team'
        or (channel->>'kind' = 'community' and channel->>'name' in ('Algemeen', 'Hulp gevraagd'))
        or (channel->>'kind' = 'announcements' and channel->>'name' = 'Mededelingen')
    ), '[]'::jsonb)
  );
  base := jsonb_set(
    base,
    '{team}',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', membership.user_id,
        'name', coalesce(nullif(concat_ws(' ', membership.first_name, membership.last_name), ''), profile.display_name, 'Poortwachter'),
        'role', membership.role,
        'task', membership.task_label,
        'lastSeenAt', membership.last_seen_at,
        'accessLevel', membership.access_level,
        'suspendedAt', membership.suspended_at,
        'chatModerator', membership.chat_moderator
      ) order by (membership.role = 'owner') desc, membership.accepted_at)
      from app_private.portal_owners membership
      left join app_private.profiles profile on profile.user_id = membership.user_id
      where membership.portal_id = pid
        and membership.revoked_at is null
    ), '[]'::jsonb)
  );

  return base || jsonb_build_object(
    'v2', app_private.poortkamer_v2_snapshot(pid),
    'announcements', coalesce((
      select jsonb_agg(item order by message_id desc)
      from (
        select
          message.id message_id,
          jsonb_build_object(
            'id', message.id,
            'body', message.body,
            'urgent', message.urgent,
            'createdAt', message.created_at
          ) item
        from app_private.portal_room_messages message
        join app_private.portal_room_channels channel on channel.id = message.channel_id
        where channel.event_id = (base->>'eventId')::uuid
          and channel.kind = 'announcements'
          and message.hidden_at is null
        order by message.id desc
        limit 5
      ) updates
    ), '[]'::jsonb)
  );
end
$$;

create or replace function api.admin_portal_room_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base jsonb;
  eid uuid;
begin
  base := api.admin_portal_room_snapshot_v1(_event_slug);
  select id into eid
  from app_private.events
  where slug = _event_slug;

  base := jsonb_set(
    base,
    '{channels}',
    coalesce((
      select jsonb_agg(channel order by
        case channel->>'kind'
          when 'community' then 0
          when 'announcements' then 1
          else 2
        end,
        case
          when channel->>'name' = 'Algemeen' then 0
          when channel->>'name' = 'Hulp gevraagd' then 1
          else 2
        end,
        channel->>'name'
      )
      from jsonb_array_elements(base->'channels') channel
      where (channel->>'kind' = 'community' and channel->>'name' in ('Algemeen', 'Hulp gevraagd'))
        or (channel->>'kind' = 'announcements' and channel->>'name' = 'Mededelingen')
    ), '[]'::jsonb)
  );

  return base || jsonb_build_object(
    'userId', auth.uid(),
    'eventId', eid,
    'communityTopic', app_private.poortkamer_community_topic(eid),
    'incidents', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', incident.id,
        'portalId', incident.portal_id,
        'portalCode', portal.system_code,
        'portalName', portal.name,
        'category', incident.category,
        'urgency', incident.urgency,
        'status', incident.status,
        'description', incident.description,
        'callbackRequested', incident.callback_requested,
        'assignedTo', incident.assigned_to,
        'createdAt', incident.created_at
      ) order by (incident.urgency = 'high') desc, incident.created_at desc)
      from app_private.portal_incidents incident
      join app_private.portals portal on portal.id = incident.portal_id
      where incident.event_id = eid
        and incident.status not in ('resolved', 'closed')
    ), '[]'::jsonb),
    'presentations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', presentation.id,
        'portalId', presentation.portal_id,
        'portalCode', portal.system_code,
        'version', presentation.version,
        'status', presentation.status,
        'publicName', presentation.public_name,
        'submittedAt', presentation.submitted_at
      ) order by presentation.submitted_at)
      from app_private.portal_presentations presentation
      join app_private.portals portal on portal.id = presentation.portal_id
      where portal.event_id = eid
        and presentation.status in ('submitted', 'changes_requested')
    ), '[]'::jsonb)
  );
end
$$;

commit;
