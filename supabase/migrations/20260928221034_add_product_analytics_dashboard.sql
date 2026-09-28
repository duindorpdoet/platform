begin;

create table app_private.product_analytics_events (
  id bigint generated always as identity primary key,
  event_id uuid not null references app_private.events(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in (
    'login_completed',
    'environment_opened',
    'pwa_install_prompt_accepted',
    'pwa_install_completed',
    'pwa_install_manual_confirmed',
    'pwa_standalone_opened'
  )),
  surface text not null check (surface in (
    'participant',
    'group',
    'homeowner',
    'child',
    'admin',
    'editorial',
    'share_studio',
    'unknown'
  )),
  session_id uuid not null,
  metadata jsonb not null default '{}'::jsonb check (
    jsonb_typeof(metadata) = 'object'
    and metadata - array['platform', 'displayMode'] = '{}'::jsonb
    and (metadata->>'platform' is null or metadata->>'platform' in ('ios', 'android', 'desktop', 'other'))
    and (metadata->>'displayMode' is null or metadata->>'displayMode' in ('browser', 'standalone'))
  ),
  created_at timestamptz not null default now(),
  unique nulls not distinct (event_id, actor_id, event_type, surface, session_id)
);

create index product_analytics_event_time
  on app_private.product_analytics_events(event_id, event_type, created_at desc);
create index product_analytics_actor_time
  on app_private.product_analytics_events(actor_id, created_at desc);

alter table app_private.product_analytics_events enable row level security;
revoke all on table app_private.product_analytics_events from public, anon, authenticated;
revoke all on sequence app_private.product_analytics_events_id_seq from public, anon, authenticated;

create function api.analytics_track(
  _event_slug text,
  _event_type text,
  _surface text,
  _session_id uuid,
  _metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_id uuid;
  actor uuid := auth.uid();
begin
  select id into event_id
  from app_private.events
  where slug = _event_slug;

  if actor is null or event_id is null or _session_id is null
    or _event_type not in (
      'login_completed',
      'environment_opened',
      'pwa_install_prompt_accepted',
      'pwa_install_completed',
      'pwa_install_manual_confirmed',
      'pwa_standalone_opened'
    )
    or _surface not in ('participant', 'group', 'homeowner', 'child', 'admin', 'editorial', 'share_studio', 'unknown')
    or jsonb_typeof(coalesce(_metadata, '{}'::jsonb)) <> 'object'
    or coalesce(_metadata, '{}'::jsonb) - array['platform', 'displayMode'] <> '{}'::jsonb
    or (_metadata->>'platform' is not null and _metadata->>'platform' not in ('ios', 'android', 'desktop', 'other'))
    or (_metadata->>'displayMode' is not null and _metadata->>'displayMode' not in ('browser', 'standalone')) then
    raise exception 'INVALID_INPUT';
  end if;

  if (select count(*) from app_private.product_analytics_events item
      where item.actor_id = actor and item.created_at >= now() - interval '1 hour') >= 120 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into app_private.product_analytics_events(
    event_id,
    actor_id,
    event_type,
    surface,
    session_id,
    metadata
  ) values (
    event_id,
    actor,
    _event_type,
    _surface,
    _session_id,
    coalesce(_metadata, '{}'::jsonb)
  ) on conflict do nothing;
end
$$;

alter table app_private.social_share_events
  drop constraint social_share_events_event_type_check;
alter table app_private.social_share_events
  add constraint social_share_events_event_type_check check (event_type in (
    'studio_opened','template_selected','preview_generated','image_downloaded',
    'caption_copied','link_copied','native_share_opened','native_share_completed',
    'platform_fallback_opened','public_page_viewed','house_registration_started',
    'house_registration_completed','participant_registration_started',
    'participant_registration_completed'
  ));

create or replace function api.social_share_track(
  _event_slug text,
  _public_share_id text,
  _template_key text,
  _event_type text,
  _platform text,
  _session_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_event_id uuid;
  page_id uuid;
  template_id uuid;
begin
  if _event_type not in (
      'studio_opened','template_selected','preview_generated','image_downloaded',
      'caption_copied','link_copied','native_share_opened','native_share_completed',
      'platform_fallback_opened','public_page_viewed','house_registration_started',
      'house_registration_completed','participant_registration_started',
      'participant_registration_completed'
    )
    or (_platform is not null and _platform not in ('native','facebook','instagram','snapchat','whatsapp','x')) then
    raise exception 'INVALID_INPUT';
  end if;

  select event.id into target_event_id
  from app_private.events event
  where event.slug = _event_slug;
  if target_event_id is null or _session_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  if _public_share_id is not null then
    select page.id, generation.template_id into page_id, template_id
    from app_private.social_share_pages page
    join app_private.social_share_generations generation on generation.id = page.generation_id
    where page.public_share_id = _public_share_id
      and page.active
      and page.expires_at > now();
  elsif _template_key is not null then
    select template.id into template_id
    from app_private.social_share_templates template
    where template.event_id = target_event_id
      and template.template_key = _template_key
      and template.status = 'live';
  end if;

  insert into app_private.social_share_events(
    event_id,
    share_page_id,
    template_id,
    actor_id,
    anonymous_session_id,
    event_type,
    platform
  ) values (
    target_event_id,
    page_id,
    template_id,
    auth.uid(),
    _session_id,
    _event_type,
    _platform
  );
end
$$;

create function app_private.analytics_actor(_event_id uuid, _actor uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', account.id,
    'name', coalesce(
      profile.display_name,
      (select nullif(concat_ws(' ', owner.first_name, owner.last_name), '')
       from app_private.portal_owners owner
       join app_private.portals portal on portal.id = owner.portal_id
       where owner.user_id = account.id
         and owner.revoked_at is null
         and portal.event_id = _event_id
       order by (owner.role = 'owner') desc, owner.accepted_at
       limit 1),
      split_part(account.email, '@', 1),
      'Gebruiker'
    ),
    'email', account.email,
    'role', case
      when exists (
        select 1 from app_private.event_capabilities capability
        where capability.event_id = _event_id
          and capability.user_id = account.id
          and capability.revoked_at is null
      ) then 'Organisatie'
      when exists (
        select 1 from app_private.portal_owners owner
        join app_private.portals portal on portal.id = owner.portal_id
        where owner.user_id = account.id
          and owner.revoked_at is null
          and portal.event_id = _event_id
      ) then 'Huisteam'
      when exists (
        select 1 from app_private.household_members member
        join app_private.registrations registration on registration.household_id = member.household_id
        where member.user_id = account.id
          and member.revoked_at is null
          and registration.event_id = _event_id
      ) then 'Deelnemer'
      else 'Gebruiker'
    end
  )
  from auth.users account
  left join app_private.profiles profile on profile.user_id = account.id
  where account.id = _actor
$$;

create function app_private.analytics_actor_in_event(_event_id uuid, _actor uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and (
    exists (
      select 1 from app_private.product_analytics_events entry
      where entry.event_id = _event_id and entry.actor_id = _actor
    )
    or exists (
      select 1 from app_private.event_capabilities capability
      where capability.event_id = _event_id
        and capability.user_id = _actor
        and capability.revoked_at is null
    )
    or exists (
      select 1 from app_private.portal_owners owner
      join app_private.portals portal on portal.id = owner.portal_id
      where portal.event_id = _event_id
        and owner.user_id = _actor
        and owner.revoked_at is null
    )
    or exists (
      select 1 from app_private.household_members member
      join app_private.registrations registration on registration.household_id = member.household_id
      where registration.event_id = _event_id
        and member.user_id = _actor
        and member.revoked_at is null
    )
  )
$$;

create function api.admin_product_analytics_snapshot(
  _event_slug text,
  _days integer default 30
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  event_record app_private.events;
  from_at timestamptz;
begin
  select * into event_record
  from app_private.events
  where slug = _event_slug;

  if event_record.id is null
    or auth.uid() is null
    or not app_private.has_capability(event_record.id, 'event_admin') then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _days not in (0, 7, 30, 90) then
    raise exception 'INVALID_INPUT';
  end if;

  from_at := case when _days = 0 then event_record.created_at else now() - make_interval(days => _days) end;

  return jsonb_build_object(
    'from', from_at,
    'to', now(),
    'summary', jsonb_build_object(
      'adultLogins', (select count(*) from auth.audit_log_entries entry
        where entry.created_at >= from_at and entry.payload->>'action' = 'login'
          and entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$'
          and app_private.analytics_actor_in_event(event_record.id, (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid)),
      'uniqueAdultUsers', (select count(distinct entry.payload->>'actor_id') from auth.audit_log_entries entry
        where entry.created_at >= from_at and entry.payload->>'action' = 'login'
          and entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$'
          and app_private.analytics_actor_in_event(event_record.id, (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid)),
      'childLogins', (select count(*) from app_private.audit_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.action = 'poortenboek.login'),
      'uniqueChildAccounts', (select count(distinct entry.resource_id) from app_private.audit_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.action = 'poortenboek.login'),
      'pwaInstalled', (select count(*) from app_private.product_analytics_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'pwa_install_completed'),
      'pwaManualConfirmed', (select count(*) from app_private.product_analytics_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'pwa_install_manual_confirmed'),
      'pwaUniqueUsers', (select count(distinct entry.actor_id) from app_private.product_analytics_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type in ('pwa_install_completed', 'pwa_install_manual_confirmed')),
      'pwaStandaloneOpens', (select count(*) from app_private.product_analytics_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'pwa_standalone_opened'),
      'socialGenerated', (select count(*) from app_private.social_share_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'preview_generated'),
      'socialDownloaded', (select count(*) from app_private.social_share_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'image_downloaded'),
      'socialShareCompleted', (select count(*) from app_private.social_share_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type = 'native_share_completed'),
      'socialShareIntents', (select count(*) from app_private.social_share_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type in ('native_share_opened', 'platform_fallback_opened')),
      'uniqueSocialActors', (select count(distinct coalesce(entry.actor_id::text, entry.anonymous_session_id::text))
        from app_private.social_share_events entry
        where entry.event_id = event_record.id and entry.created_at >= from_at
          and entry.event_type in ('preview_generated', 'image_downloaded', 'native_share_completed', 'platform_fallback_opened'))
    ),
    'loginDestinations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'surface', metric.surface,
        'count', metric.total,
        'uniqueActors', metric.unique_actors
      ) order by metric.total desc, metric.surface)
      from (
        select entry.surface, count(*) total, count(distinct entry.actor_id) unique_actors
        from app_private.product_analytics_events entry
        where entry.event_id = event_record.id
          and entry.created_at >= from_at
          and entry.event_type = 'login_completed'
        group by entry.surface
        union all
        select 'child', count(*), count(distinct entry.resource_id)
        from app_private.audit_events entry
        where entry.event_id = event_record.id
          and entry.created_at >= from_at
          and entry.action = 'poortenboek.login'
        having count(*) > 0
      ) metric
    ), '[]'::jsonb),
    'environmentOpens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'surface', metric.surface,
        'count', metric.total,
        'uniqueActors', metric.unique_actors
      ) order by metric.total desc, metric.surface)
      from (
        select entry.surface, count(*) total, count(distinct entry.actor_id) unique_actors
        from app_private.product_analytics_events entry
        where entry.event_id = event_record.id
          and entry.created_at >= from_at
          and entry.event_type = 'environment_opened'
        group by entry.surface
      ) metric
    ), '[]'::jsonb),
    'pwa', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventType', metric.event_type,
        'count', metric.total,
        'uniqueActors', metric.unique_actors
      ) order by metric.event_type)
      from (
        select entry.event_type, count(*) total, count(distinct entry.actor_id) unique_actors
        from app_private.product_analytics_events entry
        where entry.event_id = event_record.id
          and entry.created_at >= from_at
          and entry.event_type like 'pwa_%'
        group by entry.event_type
      ) metric
    ), '[]'::jsonb),
    'social', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventType', metric.event_type,
        'platform', metric.platform,
        'count', metric.total,
        'uniqueActors', metric.unique_actors
      ) order by metric.event_type, metric.platform nulls first)
      from (
        select entry.event_type, entry.platform, count(*) total,
          count(distinct coalesce(entry.actor_id::text, entry.anonymous_session_id::text)) unique_actors
        from app_private.social_share_events entry
        where entry.event_id = event_record.id
          and entry.created_at >= from_at
        group by entry.event_type, entry.platform
      ) metric
    ), '[]'::jsonb),
    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'templateKey', metric.template_key,
        'templateName', metric.template_name,
        'generated', metric.generated,
        'downloaded', metric.downloaded,
        'shared', metric.shared
      ) order by metric.generated desc, metric.template_name)
      from (
        select template.template_key, template.name template_name,
          count(*) filter (where entry.event_type = 'preview_generated') generated,
          count(*) filter (where entry.event_type = 'image_downloaded') downloaded,
          count(*) filter (where entry.event_type = 'native_share_completed') shared
        from app_private.social_share_templates template
        left join app_private.social_share_events entry on entry.template_id = template.id
          and entry.created_at >= from_at
        where template.event_id = event_record.id
        group by template.template_key, template.name
      ) metric
    ), '[]'::jsonb),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', day::date,
        'adultLogins', (select count(*) from auth.audit_log_entries entry
          where entry.payload->>'action' = 'login'
            and entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$'
            and app_private.analytics_actor_in_event(event_record.id, (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid)
            and entry.created_at >= day::date::timestamp at time zone event_record.timezone
            and entry.created_at < (day::date + 1)::timestamp at time zone event_record.timezone),
        'childLogins', (select count(*) from app_private.audit_events entry
          where entry.event_id = event_record.id and entry.action = 'poortenboek.login'
            and entry.created_at >= day::date::timestamp at time zone event_record.timezone
            and entry.created_at < (day::date + 1)::timestamp at time zone event_record.timezone),
        'pwaInstalled', (select count(*) from app_private.product_analytics_events entry
          where entry.event_id = event_record.id and entry.event_type = 'pwa_install_completed'
            and entry.created_at >= day::date::timestamp at time zone event_record.timezone
            and entry.created_at < (day::date + 1)::timestamp at time zone event_record.timezone),
        'socialShared', (select count(*) from app_private.social_share_events entry
          where entry.event_id = event_record.id and entry.event_type = 'native_share_completed'
            and entry.created_at >= day::date::timestamp at time zone event_record.timezone
            and entry.created_at < (day::date + 1)::timestamp at time zone event_record.timezone)
      ) order by day)
      from generate_series(
        (from_at at time zone event_record.timezone)::date,
        (now() at time zone event_record.timezone)::date,
        interval '1 day'
      ) day
    ), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
        'kind', activity.kind,
        'eventType', activity.event_type,
        'surface', activity.surface,
        'actor', case
          when activity.kind = 'child' then jsonb_build_object(
            'id', null,
            'name', 'Kinderaccount',
            'email', null,
            'role', 'Kindomgeving',
            'groupCode', activity.group_code
          )
          when activity.actor_id is not null then coalesce(
            app_private.analytics_actor(event_record.id, activity.actor_id),
            jsonb_build_object('id', activity.actor_id, 'name', 'Verwijderde gebruiker', 'email', null, 'role', 'Gebruiker')
          )
          else jsonb_build_object(
            'id', null,
            'name', 'Anonieme bezoeker',
            'email', null,
            'role', 'Publiek',
            'session', left(activity.session_id::text, 8)
          )
        end,
        'detail', activity.detail,
        'occurredAt', activity.occurred_at
      ) order by activity.occurred_at desc)
      from (
        select * from (
          select 'auth'::text kind, 'auth_login'::text event_type,
            coalesce((
              select tracked.surface
              from app_private.product_analytics_events tracked
              where tracked.actor_id = (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid
                and tracked.event_type = 'login_completed'
                and abs(extract(epoch from tracked.created_at - entry.created_at)) <= 120
              order by abs(extract(epoch from tracked.created_at - entry.created_at))
              limit 1
            ), 'unknown') surface,
            (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid actor_id,
            null::uuid session_id,
            null::text group_code,
            jsonb_build_object('provider', entry.payload #>> '{traits,provider}') detail,
            entry.created_at occurred_at
          from auth.audit_log_entries entry
          where entry.created_at >= from_at and entry.payload->>'action' = 'login'
            and entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$'
            and app_private.analytics_actor_in_event(event_record.id, (case when entry.payload->>'actor_id' ~* '^[0-9a-f-]{36}$' then entry.payload->>'actor_id' end)::uuid)

          union all

          select 'product', entry.event_type, entry.surface, entry.actor_id,
            entry.session_id, null, entry.metadata, entry.created_at
          from app_private.product_analytics_events entry
          where entry.event_id = event_record.id
            and entry.created_at >= from_at
            and entry.event_type <> 'login_completed'

          union all

          select 'child', 'login_completed', 'child', null, null,
            (select walking_group.code
             from app_private.registration_children registration_child
             join app_private.group_registrations group_registration
               on group_registration.registration_id = registration_child.registration_id
               and group_registration.superseded_at is null
             join app_private.walking_groups walking_group on walking_group.id = group_registration.group_id
             where registration_child.child_id = entry.resource_id
               and registration_child.event_id = event_record.id
             order by group_registration.assigned_at desc
             limit 1),
            '{}'::jsonb, entry.created_at
          from app_private.audit_events entry
          where entry.event_id = event_record.id
            and entry.created_at >= from_at
            and entry.action = 'poortenboek.login'

          union all

          select 'social', entry.event_type, 'share_studio', entry.actor_id,
            entry.anonymous_session_id, null,
            jsonb_build_object(
              'platform', entry.platform,
              'templateKey', template.template_key,
              'templateName', template.name
            ), entry.created_at
          from app_private.social_share_events entry
          left join app_private.social_share_templates template on template.id = entry.template_id
          where entry.event_id = event_record.id
            and entry.created_at >= from_at
            and entry.event_type in (
              'preview_generated', 'image_downloaded', 'native_share_opened',
              'native_share_completed', 'platform_fallback_opened'
            )
        ) combined
        order by occurred_at desc
        limit 200
      ) activity
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function api.analytics_track(text,text,text,uuid,jsonb) from public, anon;
revoke all on function api.admin_product_analytics_snapshot(text,integer) from public, anon;
revoke all on function app_private.analytics_actor(uuid,uuid) from public, anon, authenticated;
revoke all on function app_private.analytics_actor_in_event(uuid,uuid) from public, anon, authenticated;
revoke all on function api.social_share_track(text,text,text,text,text,uuid) from public;
grant execute on function api.analytics_track(text,text,text,uuid,jsonb) to authenticated;
grant execute on function api.admin_product_analytics_snapshot(text,integer) to authenticated;
grant execute on function api.social_share_track(text,text,text,text,text,uuid) to anon, authenticated;

commit;
