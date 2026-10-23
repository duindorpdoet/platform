-- Bounded claims; final ownership/consent/key validation happens before sending.

CREATE OR REPLACE FUNCTION api.worker_claim_editorial_push(_allowed_emails text[] DEFAULT '{}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        limit 4
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
                  jsonb_agg(jsonb_build_object('subscriptionId', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth_secret,'fingerprint',app_private.push_target_fingerprint(s.endpoint,s.p256dh,s.auth_secret)))
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
                and (select count(*) from app_private.push_subscriptions other where other.user_id=s.user_id and other.active and (other.created_at,other.id)<=(s.created_at,s.id))<=5
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
$function$
;

CREATE OR REPLACE FUNCTION api.worker_claim_portal_push(_allowed_emails text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  with candidates as (
    select n.id from app_private.portal_push_outbox n
    where n.kind<>'news'
      and (_allowed_emails is null or exists(select 1 from auth.users u where u.id=n.user_id and lower(trim(u.email))=any(_allowed_emails)))
      and n.completed_at is null and n.available_at<=now() and (n.lease_until is null or n.lease_until<now())
    order by n.available_at limit 4 for update skip locked
  ), claimed as (
    update app_private.portal_push_outbox n set lease_until=now()+interval '2 minutes',claim_token=gen_random_uuid(),attempts=attempts+1
      from candidates c where n.id=c.id returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'claimToken',n.claim_token,'kind',n.kind,'attempts',n.attempts,
    'targets',coalesce((select jsonb_agg(jsonb_build_object('subscriptionId',s.id,'endpoint',s.endpoint,'p256dh',s.p256dh,'auth',s.auth_secret,'fingerprint',app_private.push_target_fingerprint(s.endpoint,s.p256dh,s.auth_secret)))
      from app_private.push_subscriptions s join app_private.push_preferences pr on pr.user_id=s.user_id and pr.enabled
      left join app_private.portal_notification_preferences pref on pref.user_id=s.user_id
      where s.user_id=n.user_id and s.active and (select count(*) from app_private.push_subscriptions other where other.user_id=s.user_id and other.active and (other.created_at,other.id)<=(s.created_at,s.id))<=5 and coalesce((to_jsonb(pref)->>n.kind)::boolean,true)
        and (n.kind='access'
          or (n.portal_id is not null and app_private.poortkamer_role(n.portal_id,n.user_id) is not null)
          or (n.kind='incident' and exists(select 1 from app_private.portals p join app_private.event_capabilities ec on ec.event_id=p.event_id and ec.user_id=n.user_id and ec.revoked_at is null and ec.capability in ('event_admin','portals_manage','live_support') where p.id=n.portal_id))
          or (n.kind='urgent' and exists(select 1 from app_private.portal_room_messages m join app_private.portal_room_channels c on c.id=m.channel_id where 'announcement:'||m.id=n.dedupe_key and app_private.poortkamer_community(c.event_id,n.user_id))))
        and not exists(select 1 from app_private.portal_push_deliveries d where d.notification_id=n.id and d.subscription_id=s.id)),'[]'::jsonb))),'[]'::jsonb)
    into result from claimed n;
  return result;
end $function$
;

do $$ begin
  if to_regprocedure('app_private.push_test_targets_before_security(uuid)') is null then
    alter function api.push_test_targets_for_user(uuid) set schema app_private;
    alter function app_private.push_test_targets_for_user(uuid) rename to push_test_targets_before_security;
  end if;
end $$;
revoke all on function app_private.push_test_targets_before_security(uuid) from public,anon,authenticated,service_role;
create or replace function api.push_test_targets_for_user(_user_id uuid)
returns table("subscriptionId" uuid,endpoint text,p256dh text,auth_secret text,fingerprint text)
language sql security definer set search_path='' as $$
  select s.id,s.endpoint,s.p256dh,s.auth_secret,app_private.push_target_fingerprint(s.endpoint,s.p256dh,s.auth_secret)
  from app_private.push_subscriptions s join app_private.push_preferences p on p.user_id=s.user_id and p.enabled
  where s.user_id=_user_id and s.active order by s.created_at,s.id limit 5
$$;
revoke all on function api.push_test_targets_for_user(uuid) from public,anon,authenticated;
grant execute on function api.push_test_targets_for_user(uuid) to service_role;
