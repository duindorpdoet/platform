-- Event administrators can manage narrowly scoped operational capabilities for
-- confirmed Auth users. Authorization is stored in the private application
-- schema and is evaluated on every command; user-editable Auth metadata is not
-- part of the trust boundary.

create or replace function api.admin_access_snapshot(_event_slug text)
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
  select id into v_event_id
  from app_private.events
  where slug = _event_slug;

  if v_event_id is null then
    raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app_private.has_capability(v_event_id, 'event_admin', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'actorUserId', actor,
    'members', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'userId', member.id,
          'email', lower(member.email),
          'displayName', nullif(trim(profile.display_name), ''),
          'capabilities', coalesce((
            select jsonb_agg(capability.capability order by capability.capability)
            from app_private.event_capabilities capability
            where capability.event_id = v_event_id
              and capability.user_id = member.id
              and capability.revoked_at is null
          ), '[]'::jsonb)
        )
        order by lower(member.email)
      )
      from auth.users member
      left join app_private.profiles profile on profile.user_id = member.id
      where member.email is not null
        and exists (
          select 1
          from app_private.event_capabilities capability
          where capability.event_id = v_event_id
            and capability.user_id = member.id
            and capability.revoked_at is null
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_set_user_capabilities(
  _event_slug text,
  _email text,
  _capabilities text[],
  _expected_capabilities text[],
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  target_user_id uuid;
  normalized_email text := lower(trim(coalesce(_email, '')));
  allowed_capabilities constant text[] := array[
    'content_manage',
    'event_admin',
    'groups_manage',
    'live_support',
    'payments_manage',
    'portals_manage',
    'registration_manage'
  ];
  desired_capabilities text[];
  expected_capabilities text[];
  current_capabilities text[];
  added_capabilities text[];
  removed_capabilities text[];
begin
  if char_length(normalized_email) not between 3 and 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(coalesce(_capabilities, '{}'::text[])) requested(capability)
    where requested.capability is null
       or not (requested.capability = any(allowed_capabilities))
  ) or exists (
    select 1
    from unnest(coalesce(_expected_capabilities, '{}'::text[])) requested(capability)
    where requested.capability is null
       or not (requested.capability = any(allowed_capabilities))
  ) then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct requested.capability order by requested.capability), '{}'::text[])
  into desired_capabilities
  from unnest(coalesce(_capabilities, '{}'::text[])) requested(capability);

  select coalesce(array_agg(distinct requested.capability order by requested.capability), '{}'::text[])
  into expected_capabilities
  from unnest(coalesce(_expected_capabilities, '{}'::text[])) requested(capability);

  if cardinality(desired_capabilities) <> cardinality(coalesce(_capabilities, '{}'::text[]))
     or cardinality(expected_capabilities) <> cardinality(coalesce(_expected_capabilities, '{}'::text[])) then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  -- Lock the event row so two administration screens cannot both pass the
  -- last-admin check or overwrite each other's capability set.
  select id into v_event_id
  from app_private.events
  where slug = _event_slug
  for update;

  if v_event_id is null then
    raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app_private.has_capability(v_event_id, 'event_admin', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  select id into target_user_id
  from auth.users
  where lower(email) = normalized_email
    and email_confirmed_at is not null
  order by created_at
  limit 1;

  if target_user_id is null then
    raise exception 'CONFIRMED_USER_REQUIRED' using errcode = '23514';
  end if;

  select coalesce(array_agg(capability order by capability), '{}'::text[])
  into current_capabilities
  from app_private.event_capabilities
  where event_id = v_event_id
    and user_id = target_user_id
    and revoked_at is null;

  if current_capabilities is distinct from expected_capabilities then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  if 'event_admin' = any(current_capabilities)
     and not ('event_admin' = any(desired_capabilities))
     and (
       select count(distinct user_id)
       from app_private.event_capabilities
       where event_id = v_event_id
         and capability = 'event_admin'
         and revoked_at is null
     ) <= 1 then
    raise exception 'LAST_EVENT_ADMIN' using errcode = '23514';
  end if;

  select coalesce(array_agg(capability order by capability), '{}'::text[])
  into added_capabilities
  from unnest(desired_capabilities) requested(capability)
  where not (requested.capability = any(current_capabilities));

  select coalesce(array_agg(capability order by capability), '{}'::text[])
  into removed_capabilities
  from unnest(current_capabilities) existing(capability)
  where not (existing.capability = any(desired_capabilities));

  update app_private.event_capabilities
  set revoked_at = clock_timestamp(),
      revoke_reason = left(trim(_reason), 500)
  where event_id = v_event_id
    and user_id = target_user_id
    and revoked_at is null
    and capability = any(removed_capabilities);

  insert into app_private.event_capabilities(event_id, user_id, capability, granted_by)
  select v_event_id, target_user_id, capability, actor
  from unnest(added_capabilities) added(capability);

  if cardinality(added_capabilities) > 0 or cardinality(removed_capabilities) > 0 then
    insert into app_private.audit_events(
      event_id,
      actor_id,
      action,
      resource_type,
      resource_id,
      minimal_change
    ) values (
      v_event_id,
      actor,
      'event.capabilities_changed',
      'profile',
      target_user_id,
      jsonb_build_object(
        'added', to_jsonb(added_capabilities),
        'removed', to_jsonb(removed_capabilities),
        'reason', left(trim(_reason), 500)
      )
    );
  end if;

  return jsonb_build_object(
    'userId', target_user_id,
    'email', normalized_email,
    'capabilities', to_jsonb(desired_capabilities),
    'added', to_jsonb(added_capabilities),
    'removed', to_jsonb(removed_capabilities),
    'changed', cardinality(added_capabilities) > 0 or cardinality(removed_capabilities) > 0
  );
end;
$$;

revoke execute on function api.admin_access_snapshot(text) from public, anon;
revoke execute on function api.admin_set_user_capabilities(text, text, text[], text[], text) from public, anon;
grant execute on function api.admin_access_snapshot(text) to authenticated;
grant execute on function api.admin_set_user_capabilities(text, text, text[], text[], text) to authenticated;
