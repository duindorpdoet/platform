begin;

-- A test mail proves the exact mail content, not a redundant save operation.
-- Only equivalent versions of the SAME campaign can share that proof. Changed
-- content and other campaigns still require their own successful test. Recipient
-- permissions, consent, expected counts and freezing remain in the send RPC.
create index email_outbox_newsletter_tests_version
  on app_private.email_outbox ((payload->>'versionId'), created_at desc)
  where message_type = 'nachtpost' and payload->>'test' = 'true';

create function app_private.newsletter_test_result(_version uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('status', o.status, 'version', tested.version)
  from app_private.content_versions current_version
  join app_private.content_versions tested
    on tested.campaign_id = current_version.campaign_id
    and tested.event_id = current_version.event_id
    and tested.content_kind = 'newsletter'
    -- newsCards is a derived projection attached only when the version freezes.
    and tested.structured_content - 'newsCards' = current_version.structured_content - 'newsCards'
  join app_private.email_outbox o
    on o.payload->>'versionId' = tested.id::text
    and o.message_type = 'nachtpost' and o.payload->>'test' = 'true'
  where current_version.id = _version and current_version.content_kind = 'newsletter'
  order by (o.status in ('accepted', 'delivered')) desc, o.created_at desc, o.id
  limit 1;
$$;
revoke all on function app_private.newsletter_test_result(uuid) from public, anon, authenticated, service_role;

create or replace function api.admin_newsletter_save (_event_slug text, _id uuid, _expected_revision int, _content jsonb, _audience jsonb, _ready boolean default false)
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
          -- Saving an unchanged draft must keep its version and test-mail proof.
          select * into v from app_private.content_versions
          where campaign_id = c.id and version = c.revision;
          if v.id is not null and v.structured_content = _content
             and c.audience = _audience
             and c.status = (case when _ready then 'ready' else 'draft' end) then
            return jsonb_build_object('id', c.id, 'revision', c.revision, 'versionId', v.id);
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

create or replace function api.admin_newsletter_schedule (_version uuid, _at timestamptz, _expected_count int)
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
      if not coalesce(app_private.newsletter_test_result(v.id)->>'status' in ('accepted', 'delivered'), false) then
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

-- Preserve the bounded, capability-checked organizer projection and use the same
-- test-mail result as the mutation. No address or provider payload is exposed.
alter function api.admin_editorial_snapshot(text) set schema app_private;
alter function app_private.admin_editorial_snapshot(text) rename to admin_editorial_snapshot_before_testmail_fix;
revoke all on function app_private.admin_editorial_snapshot_before_testmail_fix(text) from public, anon, authenticated, service_role;
create function api.admin_editorial_snapshot(_event_slug text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  result := app_private.admin_editorial_snapshot_before_testmail_fix(_event_slug);
  return result || jsonb_build_object('campaigns', (
    select coalesce(jsonb_agg(item || jsonb_build_object(
      'testAccepted', coalesce(proof->>'status' in ('accepted', 'delivered'), false),
      'testStatus', proof->>'status', 'testedVersion', proof->'version'
    ) order by ordinal), '[]'::jsonb)
    from jsonb_array_elements(result->'campaigns') with ordinality campaigns(item, ordinal)
    cross join lateral (select app_private.newsletter_test_result((item->>'versionId')::uuid) proof) tests
  ));
end;
$$;
revoke all on function api.admin_editorial_snapshot(text) from public, anon, authenticated;
grant execute on function api.admin_editorial_snapshot(text) to authenticated;
revoke all on function api.admin_newsletter_save(text, uuid, int, jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function api.admin_newsletter_save(text, uuid, int, jsonb, jsonb, boolean) to authenticated;
revoke all on function api.admin_newsletter_schedule(uuid, timestamptz, int) from public, anon, authenticated;
grant execute on function api.admin_newsletter_schedule(uuid, timestamptz, int) to authenticated;

commit;
