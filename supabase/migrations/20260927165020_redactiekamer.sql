-- Additive editorial contracts. All content, recipients and delivery targets remain private.
begin;
alter table app_private.event_capabilities
  drop constraint event_capabilities_capability_check;
alter table app_private.event_capabilities
  add constraint event_capabilities_capability_check check (capability in ('event_admin', 'registration_manage', 'payments_manage', 'portals_manage', 'groups_manage', 'live_support', 'content_manage', 'content_publish', 'communications_manage', 'communications_send'));
create function app_private.editorial_can (_event uuid, _cap text, _actor uuid default auth.uid ())
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    app_private.has_capability (_event, 'event_admin', _actor)
    or app_private.has_capability (_event, _cap, _actor)
$$;
create table app_private.news_categories (
  id uuid primary key default gen_random_uuid (),
  event_id uuid not null references app_private.events (id),
  name text not null check (char_length(trim(name)) between 1 and 60),
  sort_order int not null default 0,
  active boolean not null default true,
  unique (event_id, name)
);
insert into app_private.news_categories (event_id, name, sort_order)
select
  e.id,
  n.name,
  n.ord
from
  app_private.events e
  cross join (
    values ('Organisatie', 1),
      ('Voor ouders', 2),
      ('Voor huizen', 3),
      ('Route en avond', 4),
      ('Achter de schermen', 5),
      ('Belangrijk', 6)) n (name, ord);
create table app_private.news_articles (
  id uuid primary key default gen_random_uuid (),
  event_id uuid not null references app_private.events (id),
  slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) <= 100),
  revision int not null default 0,
  created_by uuid not null references auth.users (id),
  updated_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, slug)
);
create table app_private.newsletter_campaigns (
  id uuid primary key default gen_random_uuid (),
  event_id uuid not null references app_private.events (id),
  revision int not null default 0,
  status text not null default 'draft' check (status in ('draft', 'ready', 'scheduled', 'preparing', 'sending', 'sent', 'partial_failed', 'cancelled')),
  audience jsonb not null default '{"roles":["parents"]}',
  scheduled_at timestamptz,
  counts jsonb,
  created_by uuid not null references auth.users (id),
  updated_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table app_private.content_versions
  add column editorial_planning jsonb not null default '{}' check (jsonb_typeof(editorial_planning) = 'object'
    and octet_length(editorial_planning::text) < 6000),
    add column content_kind text not null default 'page' check (content_kind in ('page', 'news', 'newsletter')),
    add column article_id uuid references app_private.news_articles (id),
    add column campaign_id uuid references app_private.newsletter_campaigns (id);
alter table app_private.content_versions
  add constraint content_kind_owner check ((content_kind = 'page' and article_id is null and campaign_id is null) or (content_kind = 'news' and article_id is not null and campaign_id is null) or (content_kind = 'newsletter' and campaign_id is not null and article_id is null));
drop index app_private.content_versions_one_published;
create unique index content_versions_one_published on app_private.content_versions (event_id, page_key, locale)
where
  status = 'published' and content_kind = 'page';
create index content_article_versions on app_private.content_versions (article_id, version desc)
where
  article_id is not null;
create index content_campaign_versions on app_private.content_versions (campaign_id, version desc)
where
  campaign_id is not null;
create table app_private.news_placements (
  id uuid primary key default gen_random_uuid (),
  article_id uuid not null references app_private.news_articles (id),
  version_id uuid not null references app_private.content_versions (id),
  channel text not null check (channel in ('website', 'parents', 'houses')),
  listed boolean not null default true,
  featured boolean not null default false,
  starts_at timestamptz not null,
  ends_at timestamptz,
  push_at timestamptz,
  cta jsonb,
  state text not null default 'scheduled' check (state in ('scheduled', 'live', 'archived')),
  published_at timestamptz,
  archived_at timestamptz,
  push_queued_at timestamptz,
  check (ends_at is null or ends_at > starts_at),
  check (push_at is null or (push_at >= starts_at and (ends_at is null or push_at < ends_at))),
  check (channel <> 'website' or push_at is null),
  unique (version_id, channel)
);
create unique index news_one_live on app_private.news_placements (article_id, channel)
where
  state = 'live';
create index news_due on app_private.news_placements (starts_at)
where
  state = 'scheduled';
create index news_channel_live on app_private.news_placements (channel, published_at desc)
where
  state = 'live';
create index news_push_due on app_private.news_placements (push_at)
where
  push_queued_at is null and push_at is not null;
create table app_private.news_reads (
  user_id uuid not null references auth.users (id) on delete cascade,
  version_id uuid not null references app_private.content_versions (id),
  channel text not null check (channel in ('parents', 'houses')),
  read_at timestamptz not null default now(),
  primary key (user_id, version_id, channel)
);
create table app_private.news_metrics (
  version_id uuid not null references app_private.content_versions (id),
  channel text not null check (channel in ('website', 'parents', 'houses')),
  day date not null default current_date,
  views bigint not null default 0,
  clicks bigint not null default 0,
  primary key (version_id, channel, day)
);
create table app_private.editorial_media (
  id uuid primary key default gen_random_uuid (),
  event_id uuid not null references app_private.events (id),
  alt text not null check (char_length(trim(alt)) between 1 and 300),
  caption text not null default '' check (length(caption) <= 500),
  width int not null check (width between 320 and 12000),
  height int not null check (height between 180 and 12000),
  focal_x numeric not null default 50 check (focal_x between 0 and 100),
  focal_y numeric not null default 50 check (focal_y between 0 and 100),
  byte_size int not null check (byte_size between 1 and 12582912),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create table app_private.editorial_media_usage (
  media_id uuid not null references app_private.editorial_media (id),
  version_id uuid not null references app_private.content_versions (id),
  primary key (media_id, version_id)
);
create index editorial_media_event on app_private.editorial_media (event_id, created_at desc);
create index editorial_usage_version on app_private.editorial_media_usage (version_id);
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('editorial-media', 'editorial-media', false, 12582912, array['image/webp']);
-- No browser Storage policy: original bytes and variants are supplied only by checked server routes.
alter table app_private.participant_preferences
  add column editorial_push_parents boolean not null default false,
  add column editorial_push_houses boolean not null default false,
  add column editorial_consented_at timestamptz,
  add column editorial_consent_source text,
  add column editorial_unsubscribed_at timestamptz;
update
  app_private.participant_preferences
set
  editorial_consented_at = updated_at,
  editorial_consent_source = 'legacy_preferences'
where
  optional_updates_consent;
create function app_private.editorial_consent_history ()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
begin
  if new.optional_updates_consent and (tg_op = 'INSERT' or not old.optional_updates_consent) then
    new.editorial_consented_at := now();
    new.editorial_consent_source := coalesce(nullif (new.editorial_consent_source, ''), 'account_preferences');
    new.editorial_unsubscribed_at := null;
  elsif not new.optional_updates_consent
      and tg_op = 'UPDATE'
      and old.optional_updates_consent then
      new.editorial_unsubscribed_at := now();
  end if;
  return new;
end
$$;
create trigger editorial_consent_history
  before insert or update on app_private.participant_preferences for each row
  execute function app_private.editorial_consent_history ();
create table app_private.newsletter_recipients (
  id uuid primary key default gen_random_uuid (),
  campaign_id uuid not null references app_private.newsletter_campaigns (id),
  version_id uuid not null references app_private.content_versions (id),
  user_id uuid not null references auth.users (id),
  email text not null check (email = lower(trim(email))),
  reasons text[] not null,
  outbox_id uuid unique references app_private.email_outbox (id) on delete set null,
  created_at timestamptz not null default now(),
  unsubscribed_at timestamptz,
  unique (campaign_id, email)
);
create index newsletter_recipient_user on app_private.newsletter_recipients (user_id);
create table app_private.editorial_suppressions (
  email_hash bytea primary key,
  reason text not null check (reason in ('bounce', 'dropped', 'spamreport', 'unsubscribe', 'group_unsubscribe')),
  created_at timestamptz not null default now()
);
alter table app_private.portal_push_outbox
  add column news_version_id uuid references app_private.content_versions (id),
  add column news_channel text check (news_channel in ('parents', 'houses')),
  add column failed_at timestamptz;
alter table app_private.portal_push_deliveries
  add column status text not null default 'sent_to_pushservice' check (status in ('queued', 'sent_to_pushservice', 'invalid', 'failed', 'clicked', 'suppressed')),
  add column attempts int not null default 0,
  add column last_error_code text,
  add column clicked_at timestamptz;
create function app_private.editorial_url (_value text)
  returns boolean
  language sql
  immutable
  set search_path = ''
  as $$
  select
    coalesce(length(_value) between 1 and 2000
      and _value !~ '[[:space:]\\]'
      and ((_value like '/%'
        and _value not like '//%')
      or _value ~ '^https://[A-Za-z0-9.-]+(:443)?([/?#][^@]*)?$'), false)
$$;
create function app_private.editorial_rich_valid (_node jsonb, _depth int default 0)
  returns boolean
  language plpgsql
  stable
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  n jsonb;
  t text;
  attrs jsonb;
begin
  if _depth > 10 or jsonb_typeof(_node) <> 'object' or pg_column_size(_node) > 60000 or (_node - array['type', 'text', 'attrs', 'marks', 'content']) <> '{}' then
    return false;
  end if;
  t := _node ->> 'type';
  attrs := coalesce(_node -> 'attrs', '{}');
  if t is null or t not in ('doc', 'text', 'paragraph', 'heading', 'bulletList', 'orderedList', 'listItem', 'blockquote', 'callout', 'hardBreak', 'horizontalRule', 'image') then
    return false;
  end if;
  if jsonb_typeof(attrs) <> 'object' then
    return false;
  end if;
  if t = 'text' then
    if jsonb_typeof(_node -> 'text') is distinct from 'string' or length(_node ->> 'text')
      not between 1 and 20000 then
      return false;
    end if;
  elsif _node ? 'text' then
    return false;
  end if;
  if t = 'image' then
    if attrs - array['mediaId', 'alt', 'caption', 'width'] <> '{}' or coalesce(attrs ->> 'mediaId', '') !~ '^[0-9a-f-]{36}$' or coalesce(length(trim(attrs->>'alt')),0) not between 1 and 300 or coalesce(length(attrs->>'caption'),501)>500 or coalesce(attrs->>'width','')
      not in ('50', '75', '100') then
      return false;
    end if;
  elsif t = 'heading' then
    if attrs - array['level', 'textAlign'] <> '{}' or coalesce(attrs ->> 'level', '')
      not in ('2', '3') then
      return false;
    end if;
  elsif t = 'paragraph' then
    if attrs - 'textAlign' <> '{}' then
      return false;
    end if;
  elsif t = 'orderedList' then
    if attrs - array['start', 'type'] <> '{}' or coalesce(attrs ->> 'start', '1') !~ '^[0-9]{1,4}$' or (attrs ->> 'start')::int not between 1 and 1000 or attrs ->> 'type' is not null then
      return false;
    end if;
  elsif attrs <> '{}' then
    return false;
  end if;
  if attrs ->> 'textAlign' is not null and attrs ->> 'textAlign' not in ('left', 'center', 'right') then
    return false;
  end if;
  if _node ? 'marks' then
    if t <> 'text' or jsonb_typeof(_node -> 'marks') <> 'array' or jsonb_array_length(_node -> 'marks') > 4 then
      return false;
    end if;
    for n in
    select
      value
    from
      jsonb_array_elements(_node -> 'marks')
      loop
        if n ->> 'type' = 'link' then
          if n - array['type', 'attrs'] <> '{}' or (n -> 'attrs') - 'href' <> '{}' or not app_private.editorial_url ((n -> 'attrs') ->> 'href') then
            return false;
          end if;
        elsif coalesce(n ->> 'type', '')
          not in ('bold', 'italic', 'underline')
            or n - 'type' <> '{}' then
            return false;
        end if;
      end loop;
  end if;
  if _node ? 'content' then
    if t in ('text', 'image', 'hardBreak', 'horizontalRule') or jsonb_typeof(_node -> 'content') <> 'array' or jsonb_array_length(_node -> 'content') > 500 then
      return false;
    end if;
    for n in
    select
      value
    from
      jsonb_array_elements(_node -> 'content')
      loop
        if not app_private.editorial_rich_valid (n, _depth + 1) then
          return false;
        end if;
      end loop;
  end if;
  return true;
exception
  when others then
    return false;
end
$$;
create function app_private.editorial_validate (_event uuid, _content jsonb)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  mid uuid;
begin
  if jsonb_typeof(_content) <> 'object' or pg_column_size(_content) > 70000 or _content - array['title', 'intro', 'heroId', 'heroAlt', 'heroCaption', 'author', 'categoryId', 'body', 'cta'] <> '{}' or coalesce(length(trim(_content ->> 'title')), 0)
    not between 3 and 160 or coalesce(length(_content ->> 'intro'), 221) > 220 or coalesce(length(_content ->> 'author'), 101) > 100 or coalesce(length(_content ->> 'heroCaption'), 501) > 500 or coalesce((_content -> 'body') ->> 'type', '') <> 'doc' or not app_private.editorial_rich_valid (_content -> 'body') then
    raise exception 'INVALID_CONTENT'
      using errcode = '22023';
  end if;
  if _content ->> 'categoryId' is not null and not exists (
    select
      1
    from
      app_private.news_categories
    where
      id = (_content ->> 'categoryId')::uuid
      and event_id = _event) then
    raise exception 'INVALID_CATEGORY';
  end if;
  if _content ->> 'heroId' is not null and coalesce(length(trim(_content ->> 'heroAlt')), 0)
    not between 1 and 300 then
    raise exception 'ALT_REQUIRED';
  end if;
  if _content ->> 'cta' is not null and (jsonb_typeof(_content -> 'cta') <> 'object' or (_content -> 'cta') - array['label', 'url'] <> '{}' or coalesce(length(trim((_content -> 'cta') ->> 'label')), 0)
  not between 1 and 60 or not app_private.editorial_url ((_content -> 'cta') ->> 'url')) then
    raise exception 'INVALID_CTA';
  end if;
  for mid in
  select
    (_content ->> 'heroId')::uuid
  where
    _content ->> 'heroId' is not null
  union
  select
    ((x -> 'attrs') ->> 'mediaId')::uuid
  from
    jsonb_path_query(_content -> 'body', '$ .** ? (@.type == "image")') x loop
    perform
      1
    from
      app_private.editorial_media
    where
      id = mid
      and event_id = _event
      and deleted_at is null for share;
      if not found then
        raise exception 'MEDIA_NOT_AVAILABLE';
      end if;
  end loop;
end
$$;
create function app_private.editorial_use_media (_version uuid, _content jsonb)
  returns void
  language sql
  security definer
  set search_path = ''
  as $$
  insert into app_private.editorial_media_usage (media_id, version_id)
  select
    mid,
    _version
  from (
    select
      (_content ->> 'heroId')::uuid mid
    where
      _content ->> 'heroId' is not null
    union
    select
      ((x -> 'attrs') ->> 'mediaId')::uuid
    from
      jsonb_path_query(_content -> 'body', '$ .** ? (@.type == "image")') x) ids
on conflict
  do nothing;
$$;
create function app_private.editorial_immutable ()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
begin
  if old.content_kind <> 'page' and old.status <> 'draft' and (tg_op = 'DELETE' or new.editorial_planning is distinct from old.editorial_planning or new.structured_content is distinct from old.structured_content or new.event_id <> old.event_id or new.content_kind <> old.content_kind or new.article_id is distinct from old.article_id or new.campaign_id is distinct from old.campaign_id or new.version <> old.version or new.status = 'draft') then
    raise exception 'IMMUTABLE_VERSION';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;
create trigger editorial_version_immutable
  before update or delete on app_private.content_versions for each row
  execute function app_private.editorial_immutable ();
create function app_private.editorial_access (_event uuid, _channel text, _actor uuid default auth.uid ())
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    case when _channel = 'website' then
      true
    when _actor is null then
      false
    when _channel = 'parents' then
      exists (
        select
          1
        from
          app_private.registrations r
          join app_private.household_members m on m.household_id = r.household_id
        where
          r.event_id = _event
          and r.status = 'submitted'
          and m.user_id = _actor
          and m.revoked_at is null)
      or exists (
        select
          1
        from
          app_private.group_leaders l
          join app_private.walking_groups g on g.id = l.group_id
        where
          g.event_id = _event
          and l.user_id = _actor
          and l.active_from <= now()
          and (l.active_until is null
            or l.active_until > now()))
      or exists (
        select
          1
        from
          app_private.group_viewer_access v
        where
          v.event_id = _event
          and v.user_id = _actor
          and v.revoked_at is null
          and v.expires_at > now())
    when _channel = 'houses' then
      exists (
        select
          1
        from
          app_private.portal_applications a
        where
          a.event_id = _event
          and a.applicant_user_id = _actor
          and a.review_status not in ('withdrawn', 'rejected'))
      or exists (
        select
          1
        from
          app_private.portal_owners o
          join app_private.portals p on p.id = o.portal_id
        where
          p.event_id = _event
          and p.approval_status = 'approved'
          and o.user_id = _actor
          and o.revoked_at is null)
    else
      false
    end;
$$;
create function api.editorial_preferences (_event_slug text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  if auth.uid () is null then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  select
    id
  into
    strict eid
  from
    app_private.events
  where
    slug = _event_slug;
    return jsonb_build_object('email', coalesce((
        select
          optional_updates_consent
        from app_private.participant_preferences
        where
          event_id = eid
          and user_id = auth.uid ()), false), 'parentsPush', coalesce((
    select
      editorial_push_parents
    from app_private.participant_preferences
    where
      event_id = eid
      and user_id = auth.uid ()), false), 'housesPush', coalesce((
  select
    editorial_push_houses
  from app_private.participant_preferences
  where
    event_id = eid
    and user_id = auth.uid ()), false), 'consentedAt', (
  select
    editorial_consented_at
  from app_private.participant_preferences
  where
    event_id = eid
    and user_id = auth.uid ()), 'source', (
  select
    editorial_consent_source
  from app_private.participant_preferences
  where
    event_id = eid
    and user_id = auth.uid ()), 'unsubscribedAt', (
  select
    editorial_unsubscribed_at
  from app_private.participant_preferences
  where
    event_id = eid
    and user_id = auth.uid ()), 'devices', coalesce((
  select
    jsonb_agg(jsonb_build_object('id', id, 'label', coalesce(device_label, 'Browser'), 'active', active, 'lastUsed', last_success_at))
  from app_private.push_subscriptions
  where
    user_id = auth.uid ()), '[]'::jsonb));
end
$$;
create function api.editorial_preferences_set (_event_slug text, _email boolean, _parents_push boolean, _houses_push boolean)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  if auth.uid () is null then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  select
    id
  into
    strict eid
  from
    app_private.events
  where
    slug = _event_slug;
  insert into app_private.participant_preferences (event_id, user_id, optional_updates_consent, editorial_push_parents, editorial_push_houses, editorial_consent_source)
    values (eid, auth.uid (), _email, _parents_push, _houses_push, 'communication_preferences')
  on conflict (event_id, user_id)
    do update set
      optional_updates_consent = excluded.optional_updates_consent,
      editorial_push_parents = excluded.editorial_push_parents,
      editorial_push_houses = excluded.editorial_push_houses,
      editorial_consent_source = excluded.editorial_consent_source,
      updated_at = now(),
      version = app_private.participant_preferences.version + 1;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (eid, auth.uid (), 'editorial.preferences_changed', 'profile', auth.uid (), jsonb_build_object('email', _email, 'parentsPush', _parents_push, 'housesPush', _houses_push));
    return api.editorial_preferences (_event_slug);
end
$$;
create function api.admin_news_save (_event_slug text, _id uuid, _expected_revision int, _slug text, _content jsonb, _planning jsonb default '{}')
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
  a app_private.news_articles;
  v app_private.content_versions;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not app_private.editorial_can (eid, 'content_manage') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    perform
      app_private.editorial_validate (eid, _content);
      if _id is null then
        insert into app_private.news_articles (event_id, slug, created_by, updated_by)
          values (eid, _slug, auth.uid (), auth.uid ())
        returning
          *
        into
          a;
        else
          select
            *
          into
            a
          from
            app_private.news_articles
          where
            id = _id
            and event_id = eid
          for update;
      end if;
      if a.id is null then
        raise exception 'NOT_FOUND';
      end if;
      if a.revision <> _expected_revision then
        raise exception 'STALE_VERSION'
          using errcode = '40001';
      end if;
      if a.slug <> _slug and exists (
        select
          1
        from
          app_private.news_placements
        where
          article_id = a.id) then
        raise exception 'PUBLISHED_SLUG_IMMUTABLE';
      end if;
      update
        app_private.news_articles
      set
        revision = revision + 1,
        slug = _slug,
        updated_by = auth.uid (),
        updated_at = now()
      where
        id = a.id
      returning
        *
      into
        a;
  insert into app_private.content_versions (event_id, page_key, structured_content, created_by, version, content_kind, article_id, editorial_planning)
    values (eid, 'news-' || a.id, _content, auth.uid (), a.revision, 'news', a.id, _planning)
  returning
    *
  into
    v;
    perform
      app_private.editorial_use_media (v.id, _content);
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (eid, auth.uid (), 'news.draft_saved', 'news', a.id, jsonb_build_object('version', v.version));
    return jsonb_build_object('id', a.id, 'revision', a.revision, 'versionId', v.id);
end
$$;
-- Channel archive transitions include replacements and automatic end dates.
create function app_private.editorial_placement_archived() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.state='archived' and old.state<>new.state then
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    select event_id,auth.uid(),'news.placement_archived','news',id,jsonb_build_object('versionId',new.version_id,'channel',new.channel,'previousState',old.state) from app_private.news_articles where id=new.article_id;
  end if;
  return new;
end $$;
create trigger editorial_placement_archived after update on app_private.news_placements for each row execute function app_private.editorial_placement_archived();
revoke all on function app_private.editorial_placement_archived() from public,anon,authenticated;

create function app_private.editorial_publish_due (_event uuid default null)
  returns int
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  a record;
  p record;
  amount int := 0;
begin
  -- Same article lock order in interactive commands and workers. SKIP LOCKED
  -- permits concurrent workers without skipping a replacement's old publication.
  for a in
  select
    n.id,
    n.event_id
  from
    app_private.news_articles n
  where (_event is null
    or n.event_id = _event)
    and exists (
      select
        1
      from
        app_private.news_placements due
      where
        due.article_id = n.id
        and ((due.state = 'scheduled'
            and due.starts_at <= now())
          or (due.state = 'live'
            and (due.ends_at <= now()
              or (due.push_at is not null
                and due.push_queued_at is null)))))
  order by
    n.id
  limit 100
  for update
    skip locked loop
      update
        app_private.news_placements
      set
        state = 'archived',
        archived_at = now()
      where
        article_id = a.id
        and state = 'live'
        and ends_at <= now();
        for p in
        select
          *
        from
          app_private.news_placements
        where
          article_id = a.id
          and state = 'scheduled'
          and starts_at <= now()
        order by
          starts_at,
          version_id loop
            update
              app_private.news_placements
            set
              state = 'archived',
              archived_at = now()
            where
              article_id = a.id
              and channel = p.channel
              and state = 'live';
              update
                app_private.news_placements
              set
                state = case when ends_at <= now() then
                  'archived'
                else
                  'live'
                end,
                published_at = now(),
                archived_at = case when ends_at <= now() then
                  now()
                end
              where
                id = p.id;
            insert into app_private.audit_events (event_id, action, resource_type, resource_id, minimal_change)
              values (a.event_id, case when p.ends_at<=now() then 'news.schedule_expired' else 'news.published' end, 'news', a.id, jsonb_build_object('versionId', p.version_id, 'channel', p.channel));
              amount := amount + 1;
          end loop;
          for p in
          select
            *
          from
            app_private.news_placements
          where
            article_id = a.id
            and state = 'live'
            and push_at is not null
            and push_queued_at is null
            and (ends_at is null
              or ends_at > now())
          order by
            push_at,
            channel loop
              insert into app_private.portal_push_outbox (user_id, kind, dedupe_key, news_version_id, news_channel, available_at)
              select
                pr.user_id,
                'news',
                'news:' || p.version_id,
                p.version_id,
                p.channel,
                p.push_at
              from
                app_private.participant_preferences pr
              where
                pr.event_id = a.event_id
                and case p.channel
                when 'parents' then
                  pr.editorial_push_parents
                when 'houses' then
                  pr.editorial_push_houses
                else
                  false
                end
                and app_private.editorial_access (a.event_id, p.channel, pr.user_id)
                and exists (
                  select
                    1
                  from
                    app_private.push_subscriptions s
                    join app_private.push_preferences pp on pp.user_id = s.user_id
                      and pp.enabled
                  where
                    s.user_id = pr.user_id
                    and s.active)
                on conflict (user_id,
                  dedupe_key)
                do nothing;
              insert into app_private.portal_push_deliveries (notification_id, subscription_id, status)
              select
                n.id,
                s.id,
                'queued'
              from
                app_private.portal_push_outbox n
                join app_private.push_subscriptions s on s.user_id = n.user_id
                  and s.active
              where
                n.news_version_id = p.version_id
                and n.created_at = now()
              on conflict
                do nothing;
                update
                  app_private.news_placements
                set
                  push_queued_at = now()
                where
                  id = p.id;
              insert into app_private.audit_events (event_id, action, resource_type, resource_id, minimal_change)
                values (a.event_id, 'news.push_queued', 'news', a.id, jsonb_build_object('versionId', p.version_id));
            end loop;
    end loop;
    return amount;
end
$$;
create function api.admin_news_publish (_version_id uuid, _placements jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  a app_private.news_articles;
  v app_private.content_versions;
  p jsonb;
  start_time timestamptz;
begin
  select
    n.*
  into
    a
  from
    app_private.news_articles n
    join app_private.content_versions c on c.article_id = n.id
  where
    c.id = _version_id
  for update
    of n;
    if a.id is null or not app_private.editorial_can (a.event_id, 'content_publish') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    select
      *
    into
      v
    from
      app_private.content_versions
    where
      id = _version_id;
      if v.status = 'published' then
        return jsonb_build_object('id', a.id, 'versionId', v.id, 'alreadyPublished', true);
      end if;
      if v.status <> 'draft' or v.version <> a.revision then
        raise exception 'STALE_VERSION'
          using errcode = '40001';
      end if;
      if jsonb_typeof(_placements) <> 'array' or jsonb_array_length(_placements)
        not between 1 and 3 or exists (
        select
          1
        from
          jsonb_array_elements(_placements) entry
        group by
          entry ->> 'channel'
        having
          count(*) > 1) then
        raise exception 'INVALID_PLACEMENTS';
      end if;
      perform
        app_private.editorial_validate (a.event_id, v.structured_content);
        if v.structured_content ->> 'heroId' is null then
          raise exception 'HERO_REQUIRED';
        end if;
        for p in
        select
          value
        from
          jsonb_array_elements(_placements)
          loop
            if p - array['channel', 'listed', 'featured', 'startsAt', 'endsAt', 'pushAt', 'cta'] <> '{}' then
              raise exception 'INVALID_PLACEMENTS';
            end if;
            if p ->> 'pushAt' is not null and not app_private.editorial_can (a.event_id, 'communications_send') then
              raise exception 'PUSH_NOT_AUTHORIZED'
                using errcode = '42501';
            end if;
            if p ->> 'cta' is not null and ((p -> 'cta') - array['label', 'url'] <> '{}' or coalesce(length(trim((p -> 'cta') ->> 'label')), 0)
            not between 1 and 60 or not app_private.editorial_url ((p -> 'cta') ->> 'url')) then
              raise exception 'INVALID_CTA';
            end if;
            start_time := coalesce((p ->> 'startsAt')::timestamptz, now());
            if start_time > now() + interval '2 years' then
              raise exception 'INVALID_SCHEDULE';
            end if;
            -- A new schedule supersedes previous pending replacements in this channel.
            update
              app_private.news_placements
            set
              state = 'archived',
              archived_at = now()
            where
              article_id = a.id
              and channel = p ->> 'channel'
              and state = 'scheduled';
            insert into app_private.news_placements (article_id, version_id, channel, listed, featured, starts_at, ends_at, push_at, cta)
              values (a.id, v.id, p ->> 'channel', coalesce((p ->> 'listed')::boolean, true), coalesce((p ->> 'featured')::boolean, false), start_time, (p ->> 'endsAt')::timestamptz, (p ->> 'pushAt')::timestamptz, nullif (p -> 'cta', 'null'::jsonb));
          end loop;
          update
            app_private.news_placements
          set
            state = 'archived',
            archived_at = now()
          where
            article_id = a.id
            and state <> 'archived'
            and channel not in (
              select
                item ->> 'channel'
              from
                jsonb_array_elements(_placements) item);
            update
              app_private.content_versions
            set
              status = 'published',
              published_at = now()
            where
              id = v.id;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (a.event_id, auth.uid (), 'news.publication_scheduled', 'news', a.id, jsonb_build_object('versionId', v.id, 'channels', (
          select
            jsonb_agg(entry ->> 'channel')
          from jsonb_array_elements(_placements) entry)));
    perform
      app_private.editorial_publish_due (a.event_id);
      return jsonb_build_object('id', a.id, 'versionId', v.id);
end
$$;
create function api.admin_news_archive (_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  a app_private.news_articles;
begin
  select
    *
  into
    a
  from
    app_private.news_articles
  where
    id = _id
  for update;
  if a.id is null or not app_private.editorial_can (a.event_id, 'content_publish') then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  update
    app_private.news_placements
  set
    state = 'archived',
    archived_at = now()
  where
    article_id = a.id
    and state <> 'archived';
    update
      app_private.content_versions
    set
      status = 'archived'
    where
      article_id = a.id
      and status = 'published';
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id)
    values (a.event_id, auth.uid (), 'news.archived', 'news', a.id);
end
$$;
create function api.news_feed (_event_slug text, _channel text default 'website', _slug text default null, _offset int default 0)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if eid is null or not app_private.editorial_access (eid, _channel) then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    return coalesce((
      select
        jsonb_agg(item order by published desc)
      from (
        select
          p.published_at published, jsonb_build_object('id', a.id, 'slug', a.slug, 'versionId', v.id, 'version', v.version, 'content', v.structured_content, 'channel', p.channel, 'publishedAt', p.published_at, 'featured', p.featured, 'cta', coalesce(p.cta, v.structured_content -> 'cta'), 'category', c.name, 'read', exists (
              select
                1
              from app_private.news_reads r
            where
              r.version_id = v.id
              and r.channel = _channel
              and r.user_id = auth.uid ())) item
      from app_private.news_placements p
      join app_private.news_articles a on a.id = p.article_id
      join app_private.content_versions v on v.id = p.version_id
      left join app_private.news_categories c on c.id = (v.structured_content ->> 'categoryId')::uuid
    where
      a.event_id = eid
      and p.channel = _channel
      and p.state = 'live'
      and p.starts_at <= now()
    and (p.ends_at is null
      or p.ends_at > now())
    and (_slug is not null
      or p.listed)
    and (_slug is null
      or a.slug = _slug)
  order by p.published_at desc, a.id limit 24 offset greatest (0, least (_offset, 10000)))
rows), '[]'::jsonb);
end
$$;
create function api.news_record (_version uuid, _channel text, _action text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    a.event_id
  into
    eid
  from
    app_private.news_placements p
    join app_private.news_articles a on a.id = p.article_id
  where
    p.version_id = _version
    and p.channel = _channel
    and p.state = 'live'
    and p.starts_at <= now()
    and (p.ends_at is null
      or p.ends_at > now());
    if eid is null or not app_private.editorial_access (eid, _channel) or _action not in ('view', 'click') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    if _channel <> 'website' and auth.uid () is not null and _action = 'view' then
      insert into app_private.news_reads (user_id, version_id, channel)
        values (auth.uid (), _version, _channel)
      on conflict
        do nothing;
    end if;
  insert into app_private.news_metrics (version_id, channel, views, clicks)
    values (_version, _channel, case when _action = 'view' then
        1
      else
        0
      end, case when _action = 'click' then
        1
      else
        0
      end)
  on conflict (version_id, channel, day)
    do update set
      views = app_private.news_metrics.views + excluded.views,
      clicks = app_private.news_metrics.clicks + excluded.clicks;
end
$$;
create function api.admin_news_push_preview (_event_slug text, _channels text[])
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not app_private.editorial_can (eid, 'content_publish') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    return ( with people as (
        select
          u.id,
          bool_or(
            case c
            when 'parents' then
              coalesce(p.editorial_push_parents, false)
            when 'houses' then
              coalesce(p.editorial_push_houses, false)
            else
              false
            end) consent
        from
          auth.users u
        cross join unnest(_channels) c
        left join app_private.participant_preferences p on p.user_id = u.id
          and p.event_id = eid
      where
        c in ('parents', 'houses')
        and app_private.editorial_access (eid, c, u.id)
      group by
        u.id
      )
      select
        jsonb_build_object('users', count(*) filter (where consent), 'withoutConsent', count(*) filter (where not consent), 'devices', (
            select
              count(*)
            from app_private.push_subscriptions s
            join people on people.id = s.user_id
              and people.consent
            join app_private.push_preferences pp on pp.user_id = s.user_id
              and pp.enabled
            where
              s.active))
      from
        people);
end
$$;
create function api.admin_editorial_category (_event_slug text, _id uuid, _name text, _active boolean, _sort int)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not app_private.editorial_can (eid, 'content_manage') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    if _id is null then
      insert into app_private.news_categories (event_id, name, active, sort_order)
        values (eid, _name, _active, _sort);
      else
        update
          app_private.news_categories
        set
          name = _name,
          active = _active,
          sort_order = _sort
        where
          id = _id
          and event_id = eid;
    end if;
end
$$;
create function api.admin_editorial_media_register (_event_slug text, _id uuid, _alt text, _caption text, _width int, _height int, _bytes int, _focal_x numeric, _focal_y numeric)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not (app_private.editorial_can (eid, 'content_manage') or app_private.editorial_can (eid, 'communications_manage')) then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
  insert into app_private.editorial_media (id, event_id, alt, caption, width, height, byte_size, focal_x, focal_y, created_by)
    values (_id, eid, _alt, _caption, _width, _height, _bytes, _focal_x, _focal_y, auth.uid ());
    return _id;
end
$$;
create function api.editorial_media_access (_id uuid)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  m app_private.editorial_media;
  is_public boolean;
  allowed boolean;
begin
  select
    *
  into
    m
  from
    app_private.editorial_media
  where
    id = _id
    and deleted_at is null;
    if m.id is null then
      return null;
    end if;
    select
      exists (
        select
          1
        from
          app_private.editorial_media_usage u
          join app_private.news_placements p on p.version_id = u.version_id
        where
          u.media_id = m.id
          and p.channel = 'website'
          and p.state = 'live'
          and p.starts_at <= now()
          and (p.ends_at is null
            or p.ends_at > now()))
    into
      is_public;
      allowed := is_public
      or app_private.editorial_can (m.event_id, 'content_manage')
      or app_private.editorial_can (m.event_id, 'content_publish')
      or app_private.editorial_can (m.event_id, 'communications_manage')
      or app_private.editorial_can (m.event_id, 'communications_send')
      or exists (
        select
          1
        from
          app_private.editorial_media_usage u
          join app_private.news_placements p on p.version_id = u.version_id
        where
          u.media_id = m.id
          and p.state = 'live'
          and p.starts_at <= now()
          and (p.ends_at is null
            or p.ends_at > now())
          and app_private.editorial_access (m.event_id, p.channel));
      if not allowed then
        return null;
      end if;
      return jsonb_build_object('id', m.id, 'eventId', m.event_id, 'public', is_public, 'alt', m.alt, 'focalX', m.focal_x, 'focalY', m.focal_y);
end
$$;
create function api.admin_editorial_media_delete (_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  m app_private.editorial_media;
begin
  select
    *
  into
    m
  from
    app_private.editorial_media
  where
    id = _id
  for update;
  if m.id is null or not (app_private.editorial_can (m.event_id, 'content_manage') or app_private.editorial_can (m.event_id, 'communications_manage')) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  if exists (
    select
      1
    from
      app_private.editorial_media_usage
    where
      media_id = m.id) then
    raise exception 'MEDIA_IN_USE';
  end if;
  update
    app_private.editorial_media
  set
    deleted_at = now()
  where
    id = m.id;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id)
    values (m.event_id, auth.uid (), 'editorial.media_deleted', 'media', m.id);
    return jsonb_build_object('id', m.id, 'eventId', m.event_id);
end
$$;
create function app_private.editorial_audience (_event uuid, _definition jsonb)
  returns table (
    user_id uuid,
    email text,
    reasons text[],
    eligible boolean,
    exclusion text,
    profile_count int)
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
begin
  if jsonb_typeof(_definition) <> 'object' or _definition - array['roles',
    'registrationStatus',
    'paid',
    'assigned',
    'startSlotId',
    'startsAfter',
    'startsBefore',
    'portalComplete',
    'portalApproved',
    'portalActive',
    'worldId'] <> '{}' or jsonb_typeof(_definition -> 'roles') <> 'array' or jsonb_array_length(_definition -> 'roles')
    not between 1 and 12 or exists (
    select
      1
    from
      jsonb_array_elements_text(_definition -> 'roles') r
    where
      r not in ('parents', 'primary_contacts', 'leaders', 'viewers', 'applicants', 'portals', 'portal_owners', 'portal_members', 'portal_editors', 'invited', 'organization', 'subscribers')) then
    raise exception 'INVALID_AUDIENCE';
  end if;
  if _definition ->> 'registrationStatus' is not null and _definition ->> 'registrationStatus' not in ('submitted', 'draft', 'cancelled') then
    raise exception 'INVALID_AUDIENCE';
  end if;
  return query with role_matches as (
    select
      m.user_id,
      'parents' role
    from
      app_private.household_members m
      join app_private.registrations r on r.household_id = m.household_id
    where
      m.revoked_at is null
      and r.event_id = _event
      and r.status::text = coalesce(_definition ->> 'registrationStatus', 'submitted')
  union all
  select
    h.primary_contact_user_id,
    'primary_contacts'
  from
    app_private.households h
    join app_private.registrations r on r.household_id = h.id
  where
    r.event_id = _event
    and r.status::text = coalesce(_definition ->> 'registrationStatus', 'submitted')
  union all
  select
    l.user_id,
    'leaders'
  from
    app_private.group_leaders l
    join app_private.walking_groups g on g.id = l.group_id
  where
    g.event_id = _event
    and l.active_from <= now()
    and (l.active_until is null
      or l.active_until > now())
  union all
  select
    v.user_id,
    'viewers'
  from
    app_private.group_viewer_access v
  where
    v.event_id = _event
    and v.revoked_at is null
    and v.expires_at > now()
  union all
  select
    a.applicant_user_id,
    'applicants'
  from
    app_private.portal_applications a
  where
    a.event_id = _event
    and a.review_status not in ('withdrawn', 'rejected')
  union all
  select
    o.user_id,
    roles.value
  from
    app_private.portal_owners o
    join app_private.portals p on p.id = o.portal_id
    cross join lateral unnest(array['portal_members', case when p.approval_status = 'approved' then
        'portals'
      end, case when o.role = 'owner' then
        'portal_owners'
      end, case when o.role in ('owner', 'coadmin') then
        'portal_editors'
      end]) roles (value)
  where
    p.event_id = _event
    and o.revoked_at is null
    and roles.value is not null
  union all
  select
    u.id,
    'invited'
  from
    app_private.portal_team_invites i
    join app_private.portals p on p.id = i.portal_id
    join auth.users u on lower(trim(u.email)) = i.email
  where
    p.event_id = _event
    and i.revoked_at is null
    and i.accepted_at is null
    and i.expires_at > now()
  union all
  select
    c.user_id,
    'organization'
  from
    app_private.event_capabilities c
  where
    c.event_id = _event
    and c.revoked_at is null
  union all
  select
    p.user_id,
    'subscribers'
  from
    app_private.participant_preferences p
  where
    p.event_id = _event
    and p.optional_updates_consent
  ),
  filtered as (
    select distinct
      r.user_id,
      r.role,
      lower(trim(u.email)) email
    from
      role_matches r
      join auth.users u on u.id = r.user_id
    where
      _definition -> 'roles' ? r.role
      and (not (_definition ?| array['registrationStatus',
          'paid',
          'assigned',
          'startSlotId',
          'startsAfter',
          'startsBefore'])
        or exists (
          select
            1
          from
            app_private.registrations reg
            join app_private.household_members hm on hm.household_id = reg.household_id
              and hm.user_id = r.user_id
              and hm.revoked_at is null
          left join app_private.group_registrations gr on gr.registration_id = reg.id
            and gr.superseded_at is null
        left join app_private.walking_groups g on g.id = gr.group_id
        left join app_private.start_slots ss on ss.id = g.start_slot_id
      where
        reg.event_id = _event
        and (_definition ->> 'registrationStatus' is null
          or reg.status::text = _definition ->> 'registrationStatus')
        and (_definition ->> 'assigned' is null
          or (gr.id is not null) = (_definition ->> 'assigned')::boolean)
        and (_definition ->> 'startSlotId' is null
          or ss.id = (_definition ->> 'startSlotId')::uuid)
        and (_definition ->> 'startsAfter' is null
          or ss.starts_at >= (_definition ->> 'startsAfter')::timestamptz)
        and (_definition ->> 'startsBefore' is null
          or ss.starts_at <= (_definition ->> 'startsBefore')::timestamptz)
        and (_definition ->> 'paid' is null
          or (not exists (
              select
                1
              from
                app_private.registration_children rc
              where
                rc.registration_id = reg.id
                and rc.participation_status = 'active'
                and app_private.child_payment_payload (rc.id) ->> 'status' not in ('confirmed', 'waived'))) = (_definition ->> 'paid')::boolean)))
      and (not (_definition ?| array['portalComplete',
          'portalApproved',
          'portalActive',
          'worldId'])
        or exists (
          select
            1
          from
            app_private.portal_applications a
          left join app_private.portals p on p.application_id = a.id
        where
          a.event_id = _event
          and (a.applicant_user_id = r.user_id
            or exists (
              select
                1
              from
                app_private.portal_owners o
              where
                o.portal_id = p.id
                and o.user_id = r.user_id
                and o.revoked_at is null))
            and (_definition ->> 'portalComplete' is null
              or (a.submitted_at is not null) = (_definition ->> 'portalComplete')::boolean)
            and (_definition ->> 'portalApproved' is null
              or coalesce(p.approval_status = 'approved', false) = (_definition ->> 'portalApproved')::boolean)
            and (_definition ->> 'portalActive' is null
              or coalesce(p.approval_status = 'approved'
                and p.operation_status not in ('closed'), false) = (_definition ->> 'portalActive')::boolean)
            and (_definition ->> 'worldId' is null
              or coalesce(p.world_id, a.requested_world_id) = (_definition ->> 'worldId')::uuid)))
  ),
  deduped as (
    select
      (array_agg(f.user_id order by f.user_id))[1] uid,
      f.email,
      array_agg(distinct f.role order by f.role) reasons,
      count(*)::int profiles
    from
      filtered f
    group by
      f.email
  ),
  checked as (
    select
      d.*,
      case when d.email is null
        or d.email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
        'invalid'
      when not exists (
        select
          1
        from
          app_private.participant_preferences p
        where
          p.event_id = _event
          and p.user_id = d.uid
          and p.optional_updates_consent
          and p.editorial_consented_at is not null) then
        'unsubscribed'
      when exists (
        select
          1
        from
          app_private.editorial_suppressions s
        where
          s.email_hash = extensions.digest(d.email, 'sha256')) then
        'suppressed'
      when exists (
        select
          1
        from
          app_private.email_outbox o
          join app_private.email_events e on e.outbox_id = o.id
        where
          lower(trim(o.recipient_email)) = d.email
          and e.kind in ('bounce', 'dropped', 'spamreport')) then
        'bounced'
      end blocked
    from
      deduped d
  )
  select
    c.uid,
    c.email,
    c.reasons,
    c.blocked is null,
    c.blocked,
    c.profiles
  from
    checked c;
end
$$;
create function app_private.editorial_audience_counts (_event uuid, _definition jsonb)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    jsonb_build_object('profiles', coalesce(sum(profile_count), 0), 'uniqueEmails', count(*) filter (where exclusion is distinct from 'invalid'), 'duplicates', coalesce(sum(profile_count), 0) - count(*), 'unsubscribed', count(*) filter (where exclusion = 'unsubscribed'), 'suppressed', count(*) filter (where exclusion = 'suppressed'), 'bounced', count(*) filter (where exclusion = 'bounced'), 'invalid', count(*) filter (where exclusion = 'invalid'), 'recipients', count(*) filter (where eligible))
  from
    app_private.editorial_audience (_event, _definition);
$$;
create function api.admin_newsletter_audience (_event_slug text, _definition jsonb)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not (app_private.editorial_can (eid, 'communications_manage') or app_private.editorial_can (eid, 'communications_send')) then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    return app_private.editorial_audience_counts (eid, _definition);
end
$$;
create function app_private.editorial_campaign_cards (_version uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    coalesce(jsonb_agg(jsonb_build_object('versionId', n.id, 'slug', a.slug, 'content', n.structured_content, 'channels', (
            select
              jsonb_agg(distinct p.channel)
            from app_private.news_placements p
            where
              p.version_id = n.id
              and p.state = 'live'
              and p.starts_at <= now()
            and (p.ends_at is null
              or p.ends_at > now())))
    order by x.ord), '[]'::jsonb)
  from
    app_private.content_versions v
  cross join lateral jsonb_array_elements_text(v.structured_content -> 'newsVersionIds')
  with ordinality x (id, ord)
  join app_private.content_versions n on n.id = x.id::uuid
    and n.event_id = v.event_id
    and n.status = 'published'
  join app_private.news_articles a on a.id = n.article_id
where
  v.id = _version;
$$;
create function api.admin_newsletter_save (_event_slug text, _id uuid, _expected_revision int, _content jsonb, _audience jsonb, _ready boolean default false)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
  c app_private.newsletter_campaigns;
  v app_private.content_versions;
  nid text;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    if not app_private.editorial_can (eid, 'communications_manage') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    if jsonb_typeof(_content) <> 'object' or pg_column_size(_content) > 90000 or _content - array['internalName', 'subject', 'preheader', 'eyebrow', 'article', 'newsVersionIds', 'closing', 'senderName'] <> '{}' or coalesce(length(trim(_content ->> 'internalName')), 0)
      not between 3 and 120 or coalesce(length(trim(_content ->> 'subject')), 0)
      not between 3 and 200 or _content ->> 'subject' ~ '[\r\n]' or coalesce(length(_content ->> 'preheader'), 0)
      not between 1 and 180 or coalesce(length(_content ->> 'eyebrow'), 0)
      not between 1 and 100 or coalesce(length(_content ->> 'senderName'), 0)
      not between 1 and 120 or coalesce(length(_content ->> 'closing'), 2001) > 2000 or jsonb_typeof(_content -> 'newsVersionIds') <> 'array' or jsonb_array_length(_content -> 'newsVersionIds') > 8 then
      raise exception 'INVALID_CAMPAIGN';
    end if;
    perform
      app_private.editorial_validate (eid, _content -> 'article');
      perform
        app_private.editorial_audience_counts (eid, _audience);
        for nid in
        select
          value
        from
          jsonb_array_elements_text(_content -> 'newsVersionIds')
          loop
            if not exists (
              select
                1
              from
                app_private.content_versions v
                join app_private.news_placements p on p.version_id = v.id
              where
                v.id = nid::uuid
                and v.event_id = eid
                and p.state = 'live'
                and p.starts_at <= now()
                and (p.ends_at is null
                or p.ends_at > now())) then
              raise exception 'NEWS_NOT_PUBLISHED';
            end if;
          end loop;
          if _id is null then
            insert into app_private.newsletter_campaigns (event_id, created_by)
              values (eid, auth.uid ())
            returning
              *
            into
              c;
            else
              select
                *
              into
                c
              from
                app_private.newsletter_campaigns
              where
                id = _id
                and event_id = eid
              for update;
          end if;
          if c.id is null or c.status not in ('draft', 'ready') then
            raise exception 'CAMPAIGN_FROZEN';
          end if;
          if c.revision <> _expected_revision then
            raise exception 'STALE_VERSION'
              using errcode = '40001';
          end if;
          update
            app_private.newsletter_campaigns
          set
            revision = revision + 1,
            audience = _audience,
            status = case when _ready then
              'ready'
            else
              'draft'
            end,
            updated_by = auth.uid (),
            updated_at = now()
          where
            id = c.id
          returning
            *
          into
            c;
  insert into app_private.content_versions (event_id, page_key, structured_content, version, created_by, content_kind, campaign_id)
    values (eid, 'newsletter-' || c.id, _content, c.revision, auth.uid (), 'newsletter', c.id)
  returning
    *
  into
    v;
    perform
      app_private.editorial_use_media (v.id, _content -> 'article');
  insert into app_private.editorial_media_usage (media_id, version_id)
  select
    u.media_id,
    v.id
  from
    app_private.editorial_media_usage u
  where
    u.version_id in (
      select
        value::uuid
      from
        jsonb_array_elements_text(_content -> 'newsVersionIds'))
  on conflict
    do nothing;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (eid, auth.uid (), 'newsletter.draft_saved', 'newsletter', c.id, jsonb_build_object('version', v.version));
    return jsonb_build_object('id', c.id, 'revision', c.revision, 'versionId', v.id);
end
$$;
create function api.admin_newsletter_test (_version uuid, _key uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  v app_private.content_versions;
  oid uuid;
begin
  select
    *
  into
    v
  from
    app_private.content_versions
  where
    id = _version
    and content_kind = 'newsletter';
    if v.id is null or not app_private.editorial_can (v.event_id, 'communications_send') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
  insert into app_private.email_outbox (dedupe_key, message_type, recipient_ref, recipient_email, payload)
  select
    'nachtpost-test:' || v.id || ':' || _key,
    'nachtpost',
    auth.uid ()::text,
    lower(trim(email)),
    jsonb_build_object('versionId', v.id, 'test', true, 'actorId', auth.uid ())
  from
    auth.users
  where
    id = auth.uid ()
  on conflict (dedupe_key)
    do nothing
  returning
    id
  into
    oid;
    if oid is null then
      select
        id
      into
        oid
      from
        app_private.email_outbox
      where
        dedupe_key = 'nachtpost-test:' || v.id || ':' || _key
        and recipient_ref = auth.uid ()::text;
    end if;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (v.event_id, auth.uid (), 'newsletter.test_requested', 'newsletter', v.campaign_id, jsonb_build_object('versionId', v.id, 'outboxId', oid));
    return oid;
end
$$;
create function api.admin_newsletter_schedule (_version uuid, _at timestamptz, _expected_count int)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  c app_private.newsletter_campaigns;
  v app_private.content_versions;
  cards jsonb;
  v_counts jsonb;
  total int;
begin
  select
    n.*
  into
    c
  from
    app_private.newsletter_campaigns n
    join app_private.content_versions v on v.campaign_id = n.id
  where
    v.id = _version
  for update
    of n;
    if c.id is null or not app_private.editorial_can (c.event_id, 'communications_send') then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    select
      *
    into
      v
    from
      app_private.content_versions
    where
      id = _version;
      if v.status = 'published' and c.status <> 'cancelled' then
        return c.counts;
      end if;
      if c.status not in ('draft', 'ready') or v.version <> c.revision then
        raise exception 'STALE_VERSION'
          using errcode = '40001';
      end if;
      if _at is null or _at > now() + interval '1 year' then
        raise exception 'INVALID_SCHEDULE';
      end if;
      if not exists (
        select
          1
        from
          app_private.email_outbox o
        where
          o.message_type = 'nachtpost'
          and o.payload ->> 'versionId' = v.id::text
          and o.payload ->> 'test' = 'true'
          and o.status in ('accepted', 'delivered')) then
        raise exception 'TEST_MAIL_REQUIRED';
      end if;
      cards := app_private.editorial_campaign_cards (v.id);
      if jsonb_array_length(cards) <> jsonb_array_length(v.structured_content -> 'newsVersionIds') or exists (
        select
          1
        from
          jsonb_array_elements(cards) item
        where
          item ->> 'channels' is null) then
        raise exception 'NEWS_NOT_PUBLISHED';
      end if;
      v_counts := app_private.editorial_audience_counts (c.event_id, c.audience);
      -- Portal-only news must never be mailed to an account without that channel.
      insert into app_private.newsletter_recipients (campaign_id, version_id, user_id, email, reasons)
      select
        c.id,
        v.id,
        a.user_id,
        a.email,
        a.reasons
      from
        app_private.editorial_audience (c.event_id, c.audience) a
            where
              a.eligible
              and not exists (
                select
                  1
                from
                  jsonb_array_elements(cards) card
                where
                  not exists (
                    select
                      1
                    from
                      jsonb_array_elements_text(card -> 'channels') ch
                    where
                      app_private.editorial_access (c.event_id, ch, a.user_id)));
                get diagnostics total = row_count;
                if total <> _expected_count then
                  raise exception 'AUDIENCE_CHANGED'
                    using errcode = '40001';
                end if;
                v_counts := v_counts || jsonb_build_object('recipients', total, 'channelExcluded', (v_counts ->> 'recipients')::int - total);
                update
                  app_private.content_versions
                set
                  structured_content = structured_content || jsonb_build_object('newsCards', cards),
                  status = 'published',
                  published_at = now()
                where
                  id = v.id;
  insert into app_private.editorial_media_usage (media_id, version_id)
  select
    u.media_id,
    v.id
  from
    app_private.editorial_media_usage u
  where
    u.version_id in (
      select
        (card ->> 'versionId')::uuid
      from
        jsonb_array_elements(cards) card)
  on conflict
    do nothing;
    update
      app_private.newsletter_campaigns
    set
      status = 'scheduled',
      scheduled_at = greatest (_at, now()),
      counts = v_counts,
      updated_by = auth.uid (),
      updated_at = now()
    where
      id = c.id;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (c.event_id, auth.uid (), 'newsletter.scheduled', 'newsletter', c.id, jsonb_build_object('versionId', v.id, 'recipients', total, 'scheduledAt', _at));
    return v_counts;
end
$$;
create function api.admin_newsletter_cancel (_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  c app_private.newsletter_campaigns;
begin
  select
    *
  into
    c
  from
    app_private.newsletter_campaigns
  where
    id = _id
  for update;
  if c.id is null or not app_private.editorial_can (c.event_id, 'communications_send') then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  if c.status not in ('draft', 'ready', 'scheduled', 'cancelled') then
    raise exception 'CAMPAIGN_STARTED';
  end if;
  update
    app_private.newsletter_campaigns
  set
    status = 'cancelled',
    updated_at = now()
  where
    id = c.id;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id)
    values (c.event_id, auth.uid (), 'newsletter.cancelled', 'newsletter', c.id);
end
$$;
-- Preserve delivery totals while removing per-person evidence on the existing
-- event retention boundary. Push cleanup also runs in the existing Poortkamer job.
alter table app_private.newsletter_campaigns
  add column retained_delivery jsonb not null default '{}',
  add column retained_events jsonb not null default '{}',
  add column retained_at timestamptz;
alter table app_private.news_metrics
  add column push_users bigint not null default 0,
  add column push_devices bigint not null default 0,
  add column push_sent bigint not null default 0,
  add column push_invalid bigint not null default 0,
  add column push_failed bigint not null default 0,
  add column push_clicked bigint not null default 0;
create function app_private.editorial_push_retained ()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $$
begin
  if old.kind = 'news' then
    insert into app_private.news_metrics (version_id, channel, day, push_users, push_devices, push_sent, push_invalid, push_failed, push_clicked)
    select
      old.news_version_id,
      old.news_channel,
      old.created_at::date,
      1,
      count(*),
      count(*) filter (where status in ('sent_to_pushservice', 'clicked')),
      count(*) filter (where status = 'invalid'),
      count(*) filter (where status = 'failed'),
      count(*) filter (where status = 'clicked')
    from
      app_private.portal_push_deliveries
    where
      notification_id = old.id
    on conflict (version_id,
      channel,
      day)
      do update set
        push_users = app_private.news_metrics.push_users + excluded.push_users,
        push_devices = app_private.news_metrics.push_devices + excluded.push_devices,
        push_sent = app_private.news_metrics.push_sent + excluded.push_sent,
        push_invalid = app_private.news_metrics.push_invalid + excluded.push_invalid,
        push_failed = app_private.news_metrics.push_failed + excluded.push_failed,
        push_clicked = app_private.news_metrics.push_clicked + excluded.push_clicked;
  end if;
  return old;
end
$$;
create trigger editorial_push_retained
  before delete on app_private.portal_push_outbox for each row
  execute function app_private.editorial_push_retained ();
create function app_private.editorial_retention ()
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
declare
  c record;
begin
  for c in
  select
    n.id
  from
    app_private.newsletter_campaigns n
    join app_private.events e on e.id = n.event_id
  where
    n.retained_at is null
    and n.status in ('sent', 'partial_failed', 'cancelled')
    and n.updated_at < now() - interval '30 days'
    and now() > ((e.local_date + coalesce((e.settings ->> 'operationalDataRetentionDays')::int, 30))::timestamp at time zone e.timezone)
  for update
    of n skip locked loop
      update
        app_private.newsletter_campaigns n
      set
        retained_at = now(),
        retained_delivery = coalesce((
          select
            jsonb_object_agg(t.status, t.amount)
          from (
            select
              o.status, count(*) amount from app_private.newsletter_recipients r
            join app_private.email_outbox o on o.id = r.outbox_id
            where
              r.campaign_id = c.id group by o.status) t), '{}'),
        retained_events = coalesce((
          select
            jsonb_object_agg(t.kind, t.amount)
          from (
            select
              e.kind, count(*) amount from app_private.newsletter_recipients r
            join app_private.email_events e on e.outbox_id = r.outbox_id
          where
            r.campaign_id = c.id group by e.kind) t), '{}')
      where
        n.id = c.id;
      delete from app_private.email_events e using app_private.email_outbox o, app_private.content_versions v
      where e.outbox_id = o.id
        and o.message_type = 'nachtpost'
        and o.payload ->> 'versionId' = v.id::text
        and v.campaign_id = c.id;
  delete from app_private.email_outbox o using app_private.content_versions v
  where o.message_type = 'nachtpost'
    and o.payload ->> 'versionId' = v.id::text
    and v.campaign_id = c.id;
  delete from app_private.newsletter_recipients
  where campaign_id = c.id;
end loop;
  delete from app_private.portal_push_outbox
  where kind = 'news'
    and coalesce(completed_at, failed_at) < now() - interval '30 days';
end
$$;
revoke all on function app_private.editorial_retention () from public, anon, authenticated;
revoke all on function app_private.editorial_push_retained () from public, anon, authenticated;
create function api.worker_editorial_tick (_mail_enabled boolean default false)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  n int;
  c app_private.newsletter_campaigns;
begin
  n := app_private.editorial_publish_due ();
  if _mail_enabled then
    for c in
    select
      *
    from
      app_private.newsletter_campaigns
    where
      status = 'scheduled'
      and scheduled_at <= now()
    order by
      scheduled_at
    limit 10
    for update
      skip locked loop
        update
          app_private.newsletter_campaigns
        set
          status = 'preparing',
          updated_at = now()
        where
          id = c.id;
        insert into app_private.email_outbox (dedupe_key, message_type, recipient_ref, recipient_email, payload)
        select
          'nachtpost:' || r.version_id || ':' || encode(extensions.digest(r.email, 'sha256'), 'hex'),
          'nachtpost',
          r.user_id::text,
          r.email,
          jsonb_build_object('versionId', r.version_id, 'recipientId', r.id)
        from
          app_private.newsletter_recipients r
        where
          r.campaign_id = c.id
        on conflict (dedupe_key)
          do nothing;
          update
            app_private.newsletter_recipients r
          set
            outbox_id = o.id
          from
            app_private.email_outbox o
          where
            r.campaign_id = c.id
            and o.payload ->> 'recipientId' = r.id::text
            and o.message_type = 'nachtpost';
            update
              app_private.newsletter_campaigns
            set
              status = case when exists (
                select
                  1
                from
                  app_private.newsletter_recipients
                where
                  campaign_id = c.id) then
                'sending'
              else
                'sent'
              end
            where
              id = c.id;
        insert into app_private.audit_events (event_id, action, resource_type, resource_id)
          values (c.event_id, 'newsletter.started', 'newsletter', c.id);
      end loop;
  end if;
  update
    app_private.newsletter_campaigns c
  set
    status = case when exists (
      select
        1
      from
        app_private.newsletter_recipients r
        join app_private.email_outbox o on o.id = r.outbox_id
      where
        r.campaign_id = c.id
        and o.status in ('failed', 'unknown')) then
      'partial_failed'
    else
      'sent'
    end,
    updated_at = now()
  where
    c.status = 'sending'
    and not exists (
      select
        1
      from
        app_private.newsletter_recipients r
        join app_private.email_outbox o on o.id = r.outbox_id
      where
        r.campaign_id = c.id
        and o.status in ('pending', 'processing', 'deferred'));
    -- Individual reads expire after 30 days; aggregate totals remain. No tracking IPs.
    delete from app_private.news_reads
    where read_at < now() - interval '30 days';
      perform
        app_private.editorial_retention ();
        return jsonb_build_object('published', n);
end
$$;
create function api.worker_newsletter_material (_outbox uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  o app_private.email_outbox;
  v app_private.content_versions;
  r app_private.newsletter_recipients;
  u uuid;
  cards jsonb;
begin
  select
    *
  into
    o
  from
    app_private.email_outbox
  where
    id = _outbox
    and message_type = 'nachtpost';
    if o.id is null then
      return null;
    end if;
    select
      *
    into
      v
    from
      app_private.content_versions
    where
      id = (o.payload ->> 'versionId')::uuid
      and content_kind = 'newsletter';
      if v.id is null then
        return null;
      end if;
      if o.payload ->> 'test' = 'true' then
        u := (o.payload ->> 'actorId')::uuid;
        if not app_private.editorial_can (v.event_id, 'communications_send', u) then
          return null;
        end if;
      else
        select
          *
        into
          r
        from
          app_private.newsletter_recipients
        where
          id = (o.payload ->> 'recipientId')::uuid
          and outbox_id = o.id;
          u := r.user_id;
          if r.id is null or r.unsubscribed_at is not null or not exists (
            select
              1
            from
              app_private.participant_preferences p
            where
              p.event_id = v.event_id
              and p.user_id = u
              and p.optional_updates_consent) or exists (
          select
            1
          from
            app_private.editorial_suppressions s
          where
            s.email_hash = extensions.digest(r.email, 'sha256')) then
            return null;
          end if;
          if not exists (
            select
              1
            from
              app_private.editorial_audience (v.event_id, (
              select
                audience
              from app_private.newsletter_campaigns
              where
                id = v.campaign_id)) a
            where
              a.user_id = u
              and a.eligible
              and a.email = r.email) then
            return null;
          end if;
      end if;
      cards := coalesce(v.structured_content -> 'newsCards', app_private.editorial_campaign_cards (v.id));
      if o.payload ->> 'test' is distinct from 'true' and exists (
        select
          1
        from
          jsonb_array_elements(cards) card
        where
          not exists (
          select
            1
          from
            jsonb_array_elements_text(card -> 'channels') ch
          where
            app_private.editorial_access (v.event_id, ch, u))) then
        return null;
      end if;
      return jsonb_build_object('content', v.structured_content || jsonb_build_object('newsCards', cards), 'recipientId', r.id, 'eventId', v.event_id, 'versionId', v.id, 'test', o.payload ->> 'test' = 'true');
end
$$;
create function api.worker_newsletter_unsubscribe (_recipient uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  r app_private.newsletter_recipients;
  eid uuid;
begin
  select
    *
  into
    r
  from
    app_private.newsletter_recipients
  where
    id = _recipient;
    if r.id is null then
      return;
    end if;
    select
      event_id
    into
      eid
    from
      app_private.newsletter_campaigns
    where
      id = r.campaign_id;
      update
        app_private.participant_preferences
      set
        optional_updates_consent = false,
        updated_at = now(),
        version = version + 1
      where
        event_id = eid
        and user_id = r.user_id;
        update
          app_private.newsletter_recipients
        set
          unsubscribed_at = coalesce(unsubscribed_at, now())
        where
          user_id = r.user_id
          and campaign_id in (
            select
              id
            from
              app_private.newsletter_campaigns
            where
              event_id = eid);
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id)
    values (eid, r.user_id, 'newsletter.unsubscribed', 'profile', r.user_id);
end
$$;
create function api.admin_newsletter_preview (_version uuid)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  c app_private.newsletter_campaigns;
  cards jsonb;
  counts jsonb;
  total int;
begin
  select
    n.*
  into
    c
  from
    app_private.newsletter_campaigns n
    join app_private.content_versions v on v.campaign_id = n.id
  where
    v.id = _version;
    if c.id is null or not (app_private.editorial_can (c.event_id, 'communications_manage') or app_private.editorial_can (c.event_id, 'communications_send')) then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    cards := app_private.editorial_campaign_cards (_version);
    counts := app_private.editorial_audience_counts (c.event_id, c.audience);
    select
      count(*)
    into
      total
    from
      app_private.editorial_audience (c.event_id, c.audience) a
where
  a.eligible
    and not exists (
      select
        1
      from
        jsonb_array_elements(cards) card
      where
        not exists (
          select
            1
          from
            jsonb_array_elements_text(card -> 'channels') ch
          where
            app_private.editorial_access (c.event_id, ch, a.user_id)));
      return counts || jsonb_build_object('recipients', total, 'channelExcluded', (counts ->> 'recipients')::int - total, 'cards', cards);
end
$$;
alter table app_private.portal_push_outbox
  add column claim_token uuid;
create function api.worker_claim_editorial_push (_allowed_emails text[] default '{}')
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  result jsonb;
begin
  update
    app_private.portal_push_deliveries d
  set
    status = 'failed',
    attempts = 5,
    last_error_code = 'ACCEPTANCE_UNCERTAIN'
  from
    app_private.portal_push_outbox n
  where
    d.notification_id = n.id
    and n.kind = 'news'
    and n.lease_until < now()
    and d.status = 'queued';
    update
      app_private.portal_push_outbox
    set
      failed_at = now(),
      lease_until = null
    where
      kind = 'news'
      and completed_at is null
      and lease_until < now();
      -- Staging passes a non-null allowlist even if empty. Production may pass null.
      with candidate as (
        select
          n.id
        from
          app_private.portal_push_outbox n
          join auth.users u on u.id = n.user_id
        where
          n.kind = 'news'
          and n.completed_at is null
          and n.failed_at is null
          and n.available_at <= now()
          and (n.lease_until is null
            or n.lease_until < now())
          and (_allowed_emails is null
            or lower(trim(u.email)) = any (_allowed_emails))
        order by
          n.available_at
        limit 10
        for update
          of n skip locked
      ),
      claimed as (
        update
          app_private.portal_push_outbox n
        set
          lease_until = now() + interval '5 minutes',
          claim_token = gen_random_uuid (),
          attempts = attempts + 1
        from
          candidate c
        where
          n.id = c.id
        returning
          n.*
      )
      select
        coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'claimToken', n.claim_token, 'url', '/omgeving/nieuws/' || a.slug, 'versionId', v.id, 'targets', coalesce((
                select
                  jsonb_agg(jsonb_build_object('subscriptionId', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth_secret))
                from app_private.portal_push_deliveries d
                join app_private.push_subscriptions s on s.id = d.subscription_id
                join app_private.push_preferences pp on pp.user_id = s.user_id
                  and pp.enabled
                join app_private.participant_preferences cp on cp.user_id = s.user_id
                  and cp.event_id = a.event_id
              where
                d.notification_id = n.id
                and d.status in ('queued', 'failed')
                and d.attempts < 5
                and s.active
                and s.user_id = n.user_id
                and exists (
                  select
                    1
                  from app_private.news_placements p
                where
                  p.version_id = v.id
                  and p.state = 'live'
                  and p.starts_at <= now()
              and (p.ends_at is null
                or p.ends_at > now())
            and app_private.editorial_access (a.event_id, p.channel, n.user_id)
            and case p.channel
            when 'parents' then
              cp.editorial_push_parents
            when 'houses' then
              cp.editorial_push_houses
            else
              false
            end)), '[]'::jsonb))), '[]'::jsonb)
      into
        result
      from
        claimed n
        join app_private.content_versions v on v.id = n.news_version_id
        join app_private.news_articles a on a.id = v.article_id;
        return result;
end
$$;
create function api.worker_record_editorial_push (_id uuid, _token uuid, _subscription uuid, _status text, _error text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  n app_private.portal_push_outbox;
begin
  select
    *
  into
    n
  from
    app_private.portal_push_outbox
  where
    id = _id
    and claim_token = _token
    and lease_until > now()
    and kind = 'news'
  for update;
  if n.id is null then
    raise exception 'STALE_LEASE';
  end if;
  if _status not in ('sent_to_pushservice', 'invalid', 'failed') then
    raise exception 'INVALID_STATUS';
  end if;
  update
    app_private.portal_push_deliveries
  set
    status = _status,
    delivered_at = now(),
    attempts = case when _error = 'ACCEPTANCE_UNCERTAIN' then
      5
    else
      attempts + 1
    end,
    last_error_code =
    left (_error,
      80)
  where
    notification_id = n.id
    and subscription_id = _subscription
    and status in ('queued', 'failed');
    if _status = 'invalid' then
      update
        app_private.push_subscriptions
      set
        active = false,
        updated_at = now(),
        last_error_at = now(),
        last_error_code =
        left (_error,
          80)
      where
        id = _subscription
        and user_id = n.user_id;
    end if;
end
$$;
create function api.worker_finish_editorial_push (_id uuid, _token uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  n app_private.portal_push_outbox;
begin
  select
    *
  into
    n
  from
    app_private.portal_push_outbox
  where
    id = _id
    and claim_token = _token
    and kind = 'news'
  for update;
  if n.id is null then
    raise exception 'STALE_LEASE';
  end if;
  -- Queued targets omitted by the claim lost permission, consent or subscription.
  update
    app_private.portal_push_deliveries
  set
    status = 'suppressed'
  where
    notification_id = n.id
    and status = 'queued';
    update
      app_private.portal_push_outbox
    set
      lease_until = null,
      claim_token = null,
      available_at = now() + make_interval(mins => least (60, (2 ^ least (n.attempts, 6))::int)),
      failed_at = case when exists (
        select
          1
        from
          app_private.portal_push_deliveries
        where
          notification_id = n.id
          and status = 'failed'
          and (n.attempts >= 5
            or attempts >= 5)) then
        now()
      end,
      completed_at = case when not exists (
        select
          1
        from
          app_private.portal_push_deliveries
        where
          notification_id = n.id
          and status = 'failed') then
        now()
      end
    where
      id = n.id;
end
$$;
create function api.news_push_clicked (_notification uuid, _subscription uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
begin
  if auth.uid () is null then
    return;
  end if;
  update
    app_private.portal_push_deliveries d
  set
    status = 'clicked',
    clicked_at = coalesce(clicked_at, now())
  from
    app_private.portal_push_outbox n
  where
    d.notification_id = n.id
    and n.id = _notification
    and d.subscription_id = _subscription
    and n.user_id = auth.uid ()
    and n.kind = 'news'
    and d.status in ('sent_to_pushservice', 'clicked');
end
$$;
create function api.admin_editorial_retry (_id uuid, _kind text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
begin
  if _kind = 'push' then
    select
      v.event_id
    into
      eid
    from
      app_private.portal_push_outbox n
      join app_private.content_versions v on v.id = n.news_version_id
    where
      n.id = _id
    for update
      of n;
      if eid is null or not app_private.editorial_can (eid, 'communications_send') then
        raise exception 'NOT_AUTHORIZED'
          using errcode = '42501';
      end if;
      if exists (
        select
          1
        from
          app_private.portal_push_deliveries
        where
          notification_id = _id
          and last_error_code = 'ACCEPTANCE_UNCERTAIN') then
        raise exception 'RETRY_NOT_SAFE';
      end if;
      update
        app_private.portal_push_outbox
      set
        failed_at = null,
        attempts = 0,
        available_at = now()
      where
        id = _id
        and failed_at is not null;
        update
          app_private.portal_push_deliveries
        set
          attempts = 0
        where
          notification_id = _id
          and status = 'failed'
          and last_error_code is distinct from 'ACCEPTANCE_UNCERTAIN';
        elsif _kind = 'mail' then
          select
            v.event_id
          into
            eid
          from
            app_private.email_outbox o
            join app_private.content_versions v on v.id = (o.payload ->> 'versionId')::uuid
          where
            o.id = _id
            and o.message_type = 'nachtpost'
          for update
            of o;
            if eid is null or not app_private.editorial_can (eid, 'communications_send') then
              raise exception 'NOT_AUTHORIZED'
                using errcode = '42501';
            end if;
            update
              app_private.email_outbox
            set
              status = 'pending',
              next_attempt_at = now(),
              attempts = 0
            where
              id = _id
              and status = 'failed'
              and provider_id is null
              and last_error_code in ('MAIL_GATEWAY_502', 'MAIL_NOT_CONFIGURED', 'MAIL_DISABLED', 'RECIPIENT_NOT_ALLOWED')
              and not exists (
                select
                  1
                from
                  app_private.email_events e
                where
                  e.outbox_id = _id);
              if not found then
                raise exception 'RETRY_NOT_SAFE';
              end if;
            else
              raise exception 'INVALID_KIND';
  end if;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (eid, auth.uid (), 'editorial.retry_requested', 'delivery', _id, jsonb_build_object('kind', _kind));
end
$$;
create function api.worker_editorial_mail_media (_version uuid, _media uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    jsonb_build_object('id', m.id, 'eventId', m.event_id)
  from
    app_private.editorial_media m
    join app_private.editorial_media_usage u on u.media_id = m.id
    join app_private.content_versions v on v.id = u.version_id
    join app_private.newsletter_campaigns c on c.id = v.campaign_id
  where
    v.id = _version
    and m.id = _media
    and m.deleted_at is null
    and ((v.status = 'published'
        and c.status in ('preparing', 'sending', 'sent', 'partial_failed'))
      or exists (
        select
          1
        from
          app_private.email_outbox o
        where
          o.message_type = 'nachtpost'
          and o.payload ->> 'versionId' = v.id::text
          and o.payload ->> 'test' = 'true'
          and o.status in ('accepted', 'delivered')));
$$;
create function api.admin_editorial_snapshot (_event_slug text)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  eid uuid;
  can_news boolean;
  can_mail boolean;
  readership jsonb;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
    can_news := app_private.editorial_can (eid, 'content_manage')
    or app_private.editorial_can (eid, 'content_publish');
    can_mail := app_private.editorial_can (eid, 'communications_manage')
    or app_private.editorial_can (eid, 'communications_send');
    if eid is null or not (can_news or can_mail) then
      raise exception 'NOT_AUTHORIZED'
        using errcode = '42501';
    end if;
    select
      jsonb_object_agg(channel, total)
    into
      readership
    from (
      select
        channel,
        count(*) total
      from
        unnest(array['parents', 'houses']) channel
      cross join auth.users u
    where
      app_private.editorial_access (eid, channel, u.id)
    group by
      channel) counts;
  return jsonb_build_object('eventId', eid, 'categories', coalesce((
      select
        jsonb_agg(to_jsonb (c) - 'event_id' order by sort_order, name)
      from app_private.news_categories c
      where
        event_id = eid), '[]'::jsonb), 'slots', coalesce((
      select
        jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'startsAt', s.starts_at))
      from app_private.start_slots s
      where
        s.event_id = eid
        and s.active), '[]'::jsonb), 'worlds', coalesce((
      select
        jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name))
      from app_private.worlds w
    where
      w.event_id = eid), '[]'::jsonb), 'news', case when can_news
    or can_mail then
    coalesce((
      select
        jsonb_agg(jsonb_build_object('id', a.id, 'slug', a.slug, 'revision', a.revision, 'versionId', v.id, 'version', v.version, 'content', v.structured_content, 'planning', v.editorial_planning, 'status', v.status, 'updatedAt', a.updated_at, 'placements', coalesce((
              select
                jsonb_agg(jsonb_build_object('id', p.id, 'versionId', p.version_id, 'channel', p.channel, 'state', p.state, 'listed', p.listed, 'featured', p.featured, 'startsAt', p.starts_at, 'endsAt', p.ends_at, 'pushAt', p.push_at, 'cta', p.cta))
            from app_private.news_placements p
          where
            p.article_id = a.id
            and p.state <> 'archived'), '[]'::jsonb), 'metrics', coalesce((
          select
            jsonb_agg(jsonb_build_object('channel', m.channel, 'views', m.views, 'clicks', m.clicks, 'retainedPush', m.push, 'audience', coalesce((readership ->> m.channel)::int, 0), 'readers', (
                select
                  count(distinct r.user_id)
              from app_private.news_reads r
            where
              r.version_id in (
                select
                  p.version_id
                from app_private.news_placements p
              where
                p.article_id = a.id
                and p.channel = m.channel
                and p.state = 'live')
              and r.channel = m.channel)))
    from (
      select
        channel, sum(views) views, sum(clicks) clicks, jsonb_build_object('users', sum(push_users), 'devices', sum(push_devices), 'sent', sum(push_sent), 'invalid', sum(push_invalid), 'failed', sum(push_failed), 'clicked', sum(push_clicked)) push
      from app_private.news_metrics
    where
      version_id in (
        select
          id
        from app_private.content_versions
      where
        article_id = a.id)
  group by channel) m), '[]'::jsonb))
order by a.updated_at desc)
from (
  select
    *
  from app_private.news_articles
where
  event_id = eid order by updated_at desc limit 200) a
join app_private.content_versions v on v.article_id = a.id
    and v.version = a.revision), '[]'::jsonb)
  else
    '[]'::jsonb
  end, 'campaigns', case when can_mail then
    coalesce((
      select
        jsonb_agg(jsonb_build_object('id', c.id, 'revision', c.revision, 'status', c.status, 'versionId', v.id, 'content', v.structured_content, 'audience', c.audience, 'scheduledAt', c.scheduled_at, 'counts', c.counts, 'testAccepted', exists (
              select
                1
              from app_private.email_outbox o
          where
            o.message_type = 'nachtpost'
            and o.payload ->> 'versionId' = v.id::text
            and o.payload ->> 'test' = 'true'
            and o.status in ('accepted', 'delivered')), 'delivery', c.retained_delivery || coalesce((
        select
          jsonb_object_agg(t.status, t.total)
        from (
          select
            o.status, count(*) total from app_private.newsletter_recipients r
          join app_private.email_outbox o on o.id = r.outbox_id
        where
          r.campaign_id = c.id group by o.status) t), '{}'::jsonb), 'events', c.retained_events || coalesce((
      select
        jsonb_object_agg(t.kind, t.total)
      from (
        select
          e.kind, count(*) total from app_private.newsletter_recipients r
        join app_private.email_events e on e.outbox_id = r.outbox_id
      where
        r.campaign_id = c.id group by e.kind) t), '{}'::jsonb))
order by c.updated_at desc)
from (
  select
    *
  from app_private.newsletter_campaigns
where
  event_id = eid order by updated_at desc limit 100) c
join app_private.content_versions v on v.campaign_id = c.id
    and v.version = c.revision), '[]'::jsonb)
  else
    '[]'::jsonb
  end, 'media', coalesce((
    select
      jsonb_agg(jsonb_build_object('id', m.id, 'alt', m.alt, 'caption', m.caption, 'width', m.width, 'height', m.height, 'focalX', m.focal_x, 'focalY', m.focal_y, 'uses', coalesce((
            select
              jsonb_agg(jsonb_build_object('versionId', v.id, 'title', coalesce(v.structured_content ->> 'title', v.structured_content ->> 'internalName'), 'kind', v.content_kind))
          from app_private.editorial_media_usage u
        join app_private.content_versions v on v.id = u.version_id
      where
        u.media_id = m.id), '[]'::jsonb))
order by m.created_at desc)
from (
  select
    *
  from app_private.editorial_media
where
  event_id = eid
    and deleted_at is null order by created_at desc limit 200) m), '[]'::jsonb), 'push', case when can_mail
  or can_news then
  coalesce((
    select
      jsonb_agg(jsonb_build_object('id', n.id, 'versionId', n.news_version_id, 'createdAt', n.created_at, 'completedAt', n.completed_at, 'failedAt', n.failed_at, 'statuses', coalesce((
            select
              jsonb_object_agg(t.status, t.total)
          from (
            select
              status, count(*) total
          from app_private.portal_push_deliveries d
        where
          d.notification_id = n.id group by status) t), '{}'::jsonb)))
from (
  select
    n.*
  from app_private.portal_push_outbox n
  join app_private.content_versions v on v.id = n.news_version_id
where
  v.event_id = eid order by n.created_at desc limit 100) n), '[]'::jsonb)
else
  '[]'::jsonb
end, 'mailHistory', case when can_mail then
  coalesce((
    select
      jsonb_agg(jsonb_build_object('id', o.id, 'versionId', o.payload ->> 'versionId', 'test', o.payload ->> 'test' = 'true', 'status', o.status, 'attempts', o.attempts, 'error', o.last_error_code, 'createdAt', o.created_at))
    from (
      select
        o.*
      from app_private.email_outbox o
      join app_private.content_versions v on v.id = (o.payload ->> 'versionId')::uuid
  where
    o.message_type = 'nachtpost'
    and v.event_id = eid order by o.created_at desc limit 100) o), '[]'::jsonb)
else
  '[]'::jsonb
end, 'activeSubscriptions', (
  select
    count(*)
  from app_private.push_subscriptions s
  join app_private.participant_preferences p on p.user_id = s.user_id
    and p.event_id = eid
where
  s.active
    and (p.editorial_push_parents
      or p.editorial_push_houses)));
end
$$;
-- Compatibility boundaries for existing page and operational delivery contracts.
create or replace function api.event_public_snapshot (_event_slug text)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    jsonb_build_object('slug', event.slug, 'title', event.title, 'date', event.local_date, 'timezone', event.timezone, 'phase', event.phase, 'priceCents', event.price_cents, 'currency', event.currency, 'registrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
    and (event.registration_open_at is null
      or event.registration_open_at <= now())
  and (event.registration_close_at is null
    or event.registration_close_at > now()), 'groupRegistrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
and (event.registration_open_at is null
  or event.registration_open_at <= now())
and (event.registration_close_at is null
  or event.registration_close_at > now()), 'portalRegistrationOpen', coalesce((event.settings ->> 'portalRegistrationOpen')::boolean, true), 'worlds', coalesce((
  select
    jsonb_agg(jsonb_build_object('slug', world.slug, 'name', world.name, 'story', world.story, 'artworkPath', world.artwork_path)
  order by world.sort_order)
  from app_private.worlds world
  where
    world.event_id = event.id), '[]'::jsonb), 'sponsors', coalesce((
  select
    jsonb_agg(jsonb_build_object('name', publication.approved_name, 'logoPath', publication.logo_path, 'url', publication.website_url)
    order by publication.sort_order, publication.approved_name)
  from app_private.sponsor_publications publication
  join app_private.sponsor_applications application on application.id = publication.sponsor_application_id
  where
    application.event_id = event.id), '[]'::jsonb), 'content', coalesce((
  select
    jsonb_object_agg(content.page_key, content.structured_content order by content.page_key)
  from app_private.content_versions content
where
  content.event_id = event.id
  and content.locale = 'nl-NL'
  and content.status = 'published'
  and content.content_kind = 'page'), '{}'::jsonb))
  from
    app_private.events event
  where
    event.slug = _event_slug
$$;
create or replace function api.admin_content_snapshot (_event_slug text)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
declare
  actor uuid := auth.uid ();
  v_event_id uuid;
begin
  select
    id
  into
    v_event_id
  from
    app_private.events
  where
    slug = _event_slug;
  if v_event_id is null or not (app_private.has_capability (v_event_id, 'content_manage', actor) or app_private.has_capability (v_event_id, 'event_admin', actor)) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  return jsonb_build_object('versions', coalesce((
      select
        jsonb_agg(jsonb_build_object('id', content.id, 'pageKey', content.page_key, 'locale', content.locale, 'content', content.structured_content, 'status', content.status, 'version', content.version, 'publishedAt', content.published_at, 'createdAt', content.created_at)
      order by content.page_key, content.locale, content.version desc)
      from app_private.content_versions content
      where
        content.event_id = v_event_id
        and content.content_kind = 'page'), '[]'::jsonb), 'sponsors', coalesce((
      select
        jsonb_agg(jsonb_build_object('id', application.id, 'contactName', application.contact_name, 'contactEmail', application.contact_email, 'contributionType', application.contribution_type, 'proposedAmountCents', application.proposed_amount_cents, 'message', application.message, 'status', application.review_status, 'version', application.version, 'publication', case when publication.sponsor_application_id is null then
              null
            else
              jsonb_build_object('approvedName', publication.approved_name, 'websiteUrl', publication.website_url, 'sortOrder', publication.sort_order, 'publishedAt', publication.published_at)
            end)
        order by application.created_at desc)
      from app_private.sponsor_applications application
    left join app_private.sponsor_publications publication on publication.sponsor_application_id = application.id
    where
      application.event_id = v_event_id), '[]'::jsonb));
end;
$$;
create or replace function api.admin_save_content_draft (_event_slug text, _page_key text, _locale text, _content jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
declare
  actor uuid := auth.uid ();
  v_event_id uuid;
  next_version integer;
  created app_private.content_versions;
begin
  select
    id
  into
    v_event_id
  from
    app_private.events
  where
    slug = _event_slug
  for update;
  if v_event_id is null or not (app_private.has_capability (v_event_id, 'content_manage', actor) or app_private.has_capability (v_event_id, 'event_admin', actor)) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  if _page_key like 'news-%' or _page_key like 'newsletter-%' or trim(coalesce(_page_key, '')) !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' or trim(coalesce(_locale, '')) !~ '^[a-z]{2}-[A-Z]{2}$' or jsonb_typeof(_content) <> 'object' or octet_length(_content::text) > 50000 then
    raise exception 'VALIDATION_ERROR'
      using errcode = '22023';
  end if;
  select
    coalesce(max(version), 0) + 1
  into
    next_version
  from
    app_private.content_versions
  where
    event_id = v_event_id
    and page_key = trim(_page_key)
    and locale = trim(_locale);
  insert into app_private.content_versions (event_id, page_key, locale, structured_content, status, created_by, version)
    values (v_event_id, trim(_page_key), trim(_locale), _content, 'draft', actor, next_version)
  returning
    *
  into
    created;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (v_event_id, actor, 'content.draft_created', 'content_version', created.id, jsonb_build_object('pageKey', created.page_key, 'locale', created.locale, 'version', created.version));
  return jsonb_build_object('id', created.id, 'pageKey', created.page_key, 'locale', created.locale, 'status', created.status, 'version', created.version);
end;
$$;
create or replace function api.admin_publish_content (_content_version_id uuid, _expected_version integer, _reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
declare
  actor uuid := auth.uid ();
  content app_private.content_versions;
begin
  select
    *
  into
    content
  from
    app_private.content_versions
  where
    id = _content_version_id
  for update;
  if content.id is null or content.content_kind <> 'page' or not (app_private.has_capability (content.event_id, 'content_manage', actor) or app_private.has_capability (content.event_id, 'event_admin', actor)) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  if content.version <> _expected_version then
    raise exception 'STALE_VERSION'
      using errcode = '40001';
  end if;
  if content.status <> 'draft' or char_length(trim(coalesce(_reason, '')))
    not between 10 and 500 then
    raise exception 'INVALID_TRANSITION'
      using errcode = '23514';
  end if;
  update
    app_private.content_versions
  set
    status = 'archived'
  where
    event_id = content.event_id
    and page_key = content.page_key
    and locale = content.locale
    and status = 'published';
  update
    app_private.content_versions
  set
    status = 'published',
    published_at = now()
  where
    id = content.id
  returning
    *
  into
    content;
  insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (content.event_id, actor, 'content.published', 'content_version', content.id, jsonb_build_object('pageKey', content.page_key, 'locale', content.locale, 'version', content.version, 'reason',
      left (trim(_reason), 500)));
  return jsonb_build_object('id', content.id, 'status', content.status, 'version', content.version, 'publishedAt', content.published_at);
end;
$$;
create or replace function api.admin_set_user_capabilities (_event_slug text, _email text, _capabilities text[], _expected_capabilities text[], _reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
declare
  actor uuid := auth.uid ();
  v_event_id uuid;
  target_user_id uuid;
  normalized_email text := lower(trim(coalesce(_email, '')));
  allowed_capabilities constant text[] := array['content_manage', 'content_publish', 'communications_manage', 'communications_send', 'event_admin', 'groups_manage', 'live_support', 'payments_manage', 'portals_manage', 'registration_manage'];
  desired_capabilities text[];
  expected_capabilities text[];
  current_capabilities text[];
  added_capabilities text[];
  removed_capabilities text[];
begin
  if char_length(normalized_email)
    not between 3 and 254 or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or char_length(trim(coalesce(_reason, '')))
    not between 10 and 500 then
    raise exception 'VALIDATION_ERROR'
      using errcode = '22023';
  end if;
  if exists (
    select
      1
    from
      unnest(coalesce(_capabilities, '{}'::text[])) requested (capability)
    where
      requested.capability is null
      or not (requested.capability = any (allowed_capabilities))) or exists (
select
  1
from
  unnest(coalesce(_expected_capabilities, '{}'::text[])) requested (capability)
where
  requested.capability is null
  or not (requested.capability = any (allowed_capabilities))) then
    raise exception 'VALIDATION_ERROR'
      using errcode = '22023';
  end if;
  select
    coalesce(array_agg(distinct requested.capability order by requested.capability), '{}'::text[])
  into
    desired_capabilities
  from
    unnest(coalesce(_capabilities, '{}'::text[])) requested (capability);
  select
    coalesce(array_agg(distinct requested.capability order by requested.capability), '{}'::text[])
  into
    expected_capabilities
  from
    unnest(coalesce(_expected_capabilities, '{}'::text[])) requested (capability);
  if cardinality(desired_capabilities) <> cardinality(coalesce(_capabilities, '{}'::text[])) or cardinality(expected_capabilities) <> cardinality(coalesce(_expected_capabilities, '{}'::text[])) then
    raise exception 'VALIDATION_ERROR'
      using errcode = '22023';
  end if;
  -- Lock the event row so two administration screens cannot both pass the
  -- last-admin check or overwrite each other's capability set.
  select
    id
  into
    v_event_id
  from
    app_private.events
  where
    slug = _event_slug
  for update;
  if v_event_id is null then
    raise exception 'EVENT_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if not app_private.has_capability (v_event_id, 'event_admin', actor) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  select
    id
  into
    target_user_id
  from
    auth.users
  where
    lower(email) = normalized_email
    and email_confirmed_at is not null
  order by
    created_at
  limit 1;
  if target_user_id is null then
    raise exception 'CONFIRMED_USER_REQUIRED'
      using errcode = '23514';
  end if;
  select
    coalesce(array_agg(capability order by capability), '{}'::text[])
  into
    current_capabilities
  from
    app_private.event_capabilities
  where
    event_id = v_event_id
    and user_id = target_user_id
    and revoked_at is null;
  if current_capabilities is distinct from expected_capabilities then
    raise exception 'STALE_VERSION'
      using errcode = '40001';
  end if;
  if 'event_admin' = any (current_capabilities) and not ('event_admin' = any (desired_capabilities)) and (
select
  count(distinct user_id)
from
  app_private.event_capabilities
where
  event_id = v_event_id
  and capability = 'event_admin'
  and revoked_at is null) <= 1 then
    raise exception 'LAST_EVENT_ADMIN'
      using errcode = '23514';
  end if;
  select
    coalesce(array_agg(capability order by capability), '{}'::text[])
  into
    added_capabilities
  from
    unnest(desired_capabilities) requested (capability)
where
  not (requested.capability = any (current_capabilities));
  select
    coalesce(array_agg(capability order by capability), '{}'::text[])
  into
    removed_capabilities
  from
    unnest(current_capabilities) existing (capability)
where
  not (existing.capability = any (desired_capabilities));
  update
    app_private.event_capabilities
  set
    revoked_at = clock_timestamp(),
    revoke_reason =
    left (trim(_reason),
      500)
  where
    event_id = v_event_id
    and user_id = target_user_id
    and revoked_at is null
    and capability = any (removed_capabilities);
  insert into app_private.event_capabilities (event_id, user_id, capability, granted_by)
  select
    v_event_id,
    target_user_id,
    capability,
    actor
  from
    unnest(added_capabilities) added (capability);
  if cardinality(added_capabilities) > 0 or cardinality(removed_capabilities) > 0 then
    insert into app_private.audit_events (event_id, actor_id, action, resource_type, resource_id, minimal_change)
      values (v_event_id, actor, 'event.capabilities_changed', 'profile', target_user_id, jsonb_build_object('added', to_jsonb (added_capabilities), 'removed', to_jsonb (removed_capabilities), 'reason',
        left (trim(_reason), 500)));
  end if;
  return jsonb_build_object('userId', target_user_id, 'email', normalized_email, 'capabilities', to_jsonb (desired_capabilities), 'added', to_jsonb (added_capabilities), 'removed', to_jsonb (removed_capabilities), 'changed', cardinality(added_capabilities) > 0
    or cardinality(removed_capabilities) > 0);
end;
$$;
drop function api.worker_claim_portal_push ();
create function api.worker_claim_portal_push (_allowed_emails text[] default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
  as $$
declare
  result jsonb;
begin
  with candidates as (
    select
      n.id
    from
      app_private.portal_push_outbox n
    where
      n.kind <> 'news'
      and (_allowed_emails is null
        or exists (
          select
            1
          from
            auth.users u
          where
            u.id = n.user_id
            and lower(trim(u.email)) = any (_allowed_emails)))
        and completed_at is null
        and available_at <= now()
        and (lease_until is null
          or lease_until < now())
      order by
        available_at
      limit 10
      for update
        skip locked
  ),
  claimed as (
    update
      app_private.portal_push_outbox n
    set
      lease_until = now() + interval '2 minutes',
      attempts = attempts + 1
    from
      candidates c
    where
      n.id = c.id
    returning
      n.*
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'attempts', n.attempts, 'targets', coalesce((
            select
              jsonb_agg(jsonb_build_object('subscriptionId', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth_secret))
            from app_private.push_subscriptions s
            join app_private.push_preferences pr on pr.user_id = s.user_id
              and pr.enabled
          left join app_private.portal_notification_preferences pref on pref.user_id = s.user_id
        where
          s.user_id = n.user_id
          and s.active
          and coalesce((to_jsonb (pref) ->> n.kind)::boolean, true)
        and (n.kind = 'access'
          or (n.portal_id is not null
            and app_private.poortkamer_role (n.portal_id, n.user_id) is not null)
          or (n.kind = 'urgent'
            and exists (
              select
                1
              from app_private.portal_room_messages m
              join app_private.portal_room_channels c on c.id = m.channel_id
            where
              'announcement:' || m.id = n.dedupe_key
              and app_private.poortkamer_community (c.event_id, n.user_id))))
      and not exists (
        select
          1
        from app_private.portal_push_deliveries d
      where
        d.notification_id = n.id
        and d.subscription_id = s.id)), '[]'::jsonb))), '[]'::jsonb)
  into
    result
  from
    claimed n;
  return result;
end
$$;
-- Reuse the existing webhook. Only editorial events set editorial suppressions;
-- provider deferrals after acceptance are not a request to send a second mail.
create function app_private.editorial_email_event ()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
declare
  o app_private.email_outbox;
begin
  select
    *
  into
    o
  from
    app_private.email_outbox
  where
    id = new.outbox_id;
    if o.message_type = 'nachtpost' then
      if new.kind in ('bounce', 'dropped', 'spamreport', 'unsubscribe', 'group_unsubscribe') then
        insert into app_private.editorial_suppressions (email_hash, reason)
          values (extensions.digest(lower(trim(o.recipient_email)), 'sha256'), new.kind)
        on conflict (email_hash)
          do update set
            reason = excluded.reason;
          if new.kind in ('unsubscribe', 'group_unsubscribe') and o.payload ->> 'recipientId' is not null then
            perform
              api.worker_newsletter_unsubscribe ((o.payload ->> 'recipientId')::uuid);
          end if;
      end if;
    end if;
    return new;
end
$$;
create trigger editorial_email_event
  after insert on app_private.email_events for each row
  execute function app_private.editorial_email_event ();
create function app_private.editorial_outbox_guard ()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $$
  # variable_conflict use_column
begin
  if old.message_type = 'nachtpost' and old.provider_id is not null and new.status = 'deferred' then
    new.status := old.status;
  end if;
  return new;
end
$$;
create trigger editorial_outbox_guard
  before update on app_private.email_outbox for each row
  execute function app_private.editorial_outbox_guard ();
-- Never replay an editorial provider call when its worker died after dispatch.
-- The existing queue and all earlier payment/portal guards remain in force.
alter function api.worker_claim_outbox (integer, integer) set schema app_private;
alter function app_private.worker_claim_outbox (integer, integer) rename to worker_claim_outbox_before_editorial;
revoke all on function app_private.worker_claim_outbox_before_editorial (integer, integer) from public, anon, authenticated, service_role;
create function api.worker_claim_outbox (_batch_size integer, _lease_seconds integer)
  returns setof app_private.email_outbox
  language plpgsql
  security definer
  set search_path = ''
  as $$
begin
  update
    app_private.email_outbox
  set
    status = 'unknown',
    last_error_code = 'ACCEPTANCE_UNCERTAIN',
    lease_until = null
  where
    message_type = 'nachtpost'
    and status = 'processing'
    and lease_until < now();
  return query
  select
    *
  from
    app_private.worker_claim_outbox_before_editorial (_batch_size, _lease_seconds);
end
$$;
revoke all on function api.worker_claim_outbox (integer, integer) from public, anon, authenticated;
grant execute on function api.worker_claim_outbox (integer, integer) to service_role;
-- No new direct-table grants. SECURITY DEFINER RPCs are the only entry points.
alter table app_private.news_categories enable row level security;
revoke all on app_private.news_categories from public, anon, authenticated;
revoke all on function api.worker_claim_portal_push (text[]) from public, anon, authenticated;
grant execute on function api.worker_claim_portal_push (text[]) to service_role;
alter table app_private.news_articles enable row level security;
revoke all on app_private.news_articles from public, anon, authenticated;
alter table app_private.newsletter_campaigns enable row level security;
revoke all on app_private.newsletter_campaigns from public, anon, authenticated;
alter table app_private.news_placements enable row level security;
revoke all on app_private.news_placements from public, anon, authenticated;
alter table app_private.news_reads enable row level security;
revoke all on app_private.news_reads from public, anon, authenticated;
alter table app_private.news_metrics enable row level security;
revoke all on app_private.news_metrics from public, anon, authenticated;
alter table app_private.editorial_media enable row level security;
revoke all on app_private.editorial_media from public, anon, authenticated;
alter table app_private.editorial_media_usage enable row level security;
revoke all on app_private.editorial_media_usage from public, anon, authenticated;
alter table app_private.newsletter_recipients enable row level security;
revoke all on app_private.newsletter_recipients from public, anon, authenticated;
alter table app_private.editorial_suppressions enable row level security;
revoke all on app_private.editorial_suppressions from public, anon, authenticated;
revoke all on function app_private.editorial_can (uuid, text, uuid) from public, anon, authenticated;
revoke all on function app_private.editorial_consent_history () from public, anon, authenticated;
revoke all on function app_private.editorial_url (text) from public, anon, authenticated;
revoke all on function app_private.editorial_rich_valid (jsonb, int) from public, anon, authenticated;
revoke all on function app_private.editorial_validate (uuid, jsonb) from public, anon, authenticated;
revoke all on function app_private.editorial_use_media (uuid, jsonb) from public, anon, authenticated;
revoke all on function app_private.editorial_immutable () from public, anon, authenticated;
revoke all on function app_private.editorial_access (uuid, text, uuid) from public, anon, authenticated;
revoke all on function api.editorial_preferences (text) from public, anon, authenticated;
grant execute on function api.editorial_preferences (text) to authenticated;
revoke all on function api.editorial_preferences_set (text, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function api.editorial_preferences_set (text, boolean, boolean, boolean) to authenticated;
revoke all on function api.admin_news_save (text, uuid, int, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function api.admin_news_save (text, uuid, int, text, jsonb, jsonb) to authenticated;
revoke all on function app_private.editorial_publish_due (uuid) from public, anon, authenticated;
revoke all on function api.admin_news_publish (uuid, jsonb) from public, anon, authenticated;
grant execute on function api.admin_news_publish (uuid, jsonb) to authenticated;
revoke all on function api.admin_news_archive (uuid) from public, anon, authenticated;
grant execute on function api.admin_news_archive (uuid) to authenticated;
revoke all on function api.news_feed (text, text, text, int) from public, anon, authenticated;
grant execute on function api.news_feed (text, text, text, int) to anon, authenticated;
revoke all on function api.news_record (uuid, text, text) from public, anon, authenticated;
grant execute on function api.news_record (uuid, text, text) to anon, authenticated;
revoke all on function api.admin_news_push_preview (text, text[]) from public, anon, authenticated;
grant execute on function api.admin_news_push_preview (text, text[]) to authenticated;
revoke all on function api.admin_editorial_category (text, uuid, text, boolean, int) from public, anon, authenticated;
grant execute on function api.admin_editorial_category (text, uuid, text, boolean, int) to authenticated;
revoke all on function api.admin_editorial_media_register (text, uuid, text, text, int, int, int, numeric, numeric) from public, anon, authenticated;
grant execute on function api.admin_editorial_media_register (text, uuid, text, text, int, int, int, numeric, numeric) to authenticated;
revoke all on function api.editorial_media_access (uuid) from public, anon, authenticated;
grant execute on function api.editorial_media_access (uuid) to anon, authenticated;
revoke all on function api.admin_editorial_media_delete (uuid) from public, anon, authenticated;
grant execute on function api.admin_editorial_media_delete (uuid) to authenticated;
revoke all on function app_private.editorial_audience (uuid, jsonb) from public, anon, authenticated;
revoke all on function app_private.editorial_audience_counts (uuid, jsonb) from public, anon, authenticated;
revoke all on function api.admin_newsletter_audience (text, jsonb) from public, anon, authenticated;
grant execute on function api.admin_newsletter_audience (text, jsonb) to authenticated;
revoke all on function app_private.editorial_campaign_cards (uuid) from public, anon, authenticated;
revoke all on function api.admin_newsletter_save (text, uuid, int, jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function api.admin_newsletter_save (text, uuid, int, jsonb, jsonb, boolean) to authenticated;
revoke all on function api.admin_newsletter_test (uuid, uuid) from public, anon, authenticated;
grant execute on function api.admin_newsletter_test (uuid, uuid) to authenticated;
revoke all on function api.admin_newsletter_schedule (uuid, timestamptz, int) from public, anon, authenticated;
grant execute on function api.admin_newsletter_schedule (uuid, timestamptz, int) to authenticated;
revoke all on function api.admin_newsletter_cancel (uuid) from public, anon, authenticated;
grant execute on function api.admin_newsletter_cancel (uuid) to authenticated;
revoke all on function api.worker_editorial_tick (boolean) from public, anon, authenticated;
grant execute on function api.worker_editorial_tick (boolean) to service_role;
revoke all on function api.worker_newsletter_material (uuid) from public, anon, authenticated;
grant execute on function api.worker_newsletter_material (uuid) to service_role;
revoke all on function api.worker_newsletter_unsubscribe (uuid) from public, anon, authenticated;
grant execute on function api.worker_newsletter_unsubscribe (uuid) to service_role;
revoke all on function api.admin_newsletter_preview (uuid) from public, anon, authenticated;
grant execute on function api.admin_newsletter_preview (uuid) to authenticated;
revoke all on function api.worker_claim_editorial_push (text[]) from public, anon, authenticated;
grant execute on function api.worker_claim_editorial_push (text[]) to service_role;
revoke all on function api.worker_record_editorial_push (uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function api.worker_record_editorial_push (uuid, uuid, uuid, text, text) to service_role;
revoke all on function api.worker_finish_editorial_push (uuid, uuid) from public, anon, authenticated;
grant execute on function api.worker_finish_editorial_push (uuid, uuid) to service_role;
revoke all on function api.news_push_clicked (uuid, uuid) from public, anon, authenticated;
grant execute on function api.news_push_clicked (uuid, uuid) to authenticated;
revoke all on function api.admin_editorial_retry (uuid, text) from public, anon, authenticated;
grant execute on function api.admin_editorial_retry (uuid, text) to authenticated;
revoke all on function api.worker_editorial_mail_media (uuid, uuid) from public, anon, authenticated;
grant execute on function api.worker_editorial_mail_media (uuid, uuid) to service_role;
revoke all on function api.admin_editorial_snapshot (text) from public, anon, authenticated;
grant execute on function api.admin_editorial_snapshot (text) to authenticated;
revoke all on function app_private.editorial_email_event () from public, anon, authenticated;
revoke all on function app_private.editorial_outbox_guard () from public, anon, authenticated;
alter function api.admin_dashboard (text) set schema app_private;
alter function app_private.admin_dashboard (text) rename to admin_dashboard_before_editorial;
revoke all on function app_private.admin_dashboard_before_editorial (text) from public, anon, authenticated;
create function api.admin_dashboard (_event_slug text)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
  as $$
declare
  eid uuid;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
  if exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('event_admin', 'registration_manage', 'portals_manage', 'groups_manage', 'live_support')) then
    return app_private.admin_dashboard_before_editorial (_event_slug);
  end if;
  if not exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('content_manage', 'content_publish', 'communications_manage', 'communications_send')) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  return jsonb_build_object('event', (
      select
        jsonb_build_object('id', e.id, 'title', e.title, 'phase', e.phase, 'date', e.local_date, 'settingsVersion', e.settings_version, 'maxGroupSize', coalesce((e.settings ->> 'maxGroupSize')::int, 15))
    from app_private.events e
    where
      e.id = eid), 'counts', '{}'::jsonb, 'imports', '[]'::jsonb, 'recentActivity', '[]'::jsonb);
end
$$;
revoke all on function api.admin_dashboard (text) from public, anon;
grant execute on function api.admin_dashboard (text) to authenticated;
commit;
