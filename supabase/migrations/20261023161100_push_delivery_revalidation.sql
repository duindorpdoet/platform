create or replace function app_private.push_target_fingerprint(_endpoint text,_p256dh text,_auth text)
returns text language sql immutable set search_path='' as $$
  select encode(extensions.digest(convert_to(_endpoint||E'\n'||_p256dh||E'\n'||_auth,'UTF8'),'sha256'),'hex')
$$;

create or replace function api.worker_push_target(
  _notification uuid,_subscription uuid,_fingerprint text,_token uuid default null,_test_user_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s app_private.push_subscriptions; n app_private.portal_push_outbox; permitted boolean:=false;
begin
  select * into s from app_private.push_subscriptions where id=_subscription for update;
  if s.id is null or not s.active or not exists(select 1 from app_private.push_preferences where user_id=s.user_id and enabled) then return null; end if;
  if _notification is null then
    permitted:=s.user_id=_test_user_id;
  else
    select * into n from app_private.portal_push_outbox where id=_notification and user_id=s.user_id
      and claim_token=_token and lease_until>clock_timestamp() and completed_at is null;
    if n.id is null then return null; end if;
    if n.kind='news' then
      select exists(select 1 from app_private.content_versions v
        join app_private.news_articles a on a.id=v.article_id
        join app_private.news_placements p on p.version_id=v.id and p.state='live'
          and p.starts_at<=clock_timestamp() and (p.ends_at is null or p.ends_at>clock_timestamp())
        join app_private.participant_preferences cp on cp.event_id=a.event_id and cp.user_id=s.user_id
        where v.id=n.news_version_id and app_private.editorial_access(a.event_id,p.channel,s.user_id)
          and case p.channel when 'parents' then cp.editorial_push_parents when 'houses' then cp.editorial_push_houses else false end)
        into permitted;
    else
      permitted:=coalesce((select (to_jsonb(pref)->>n.kind)::boolean from app_private.portal_notification_preferences pref where pref.user_id=s.user_id),true)
        and (n.kind='access'
          or (n.portal_id is not null and app_private.poortkamer_role(n.portal_id,s.user_id) is not null)
          or (n.kind='incident' and exists(select 1 from app_private.portals p join app_private.event_capabilities ec
            on ec.event_id=p.event_id and ec.user_id=s.user_id and ec.revoked_at is null
              and ec.capability in ('event_admin','portals_manage','live_support') where p.id=n.portal_id))
          or (n.kind='urgent' and exists(select 1 from app_private.portal_room_messages m join app_private.portal_room_channels c
            on c.id=m.channel_id where 'announcement:'||m.id=n.dedupe_key and app_private.poortkamer_community(c.event_id,s.user_id))));
    end if;
  end if;
  if permitted is distinct from true then return null; end if;
  if not app_private.valid_push_endpoint(s.endpoint) or not app_private.valid_push_keys(s.p256dh,s.auth_secret) then
    update app_private.push_subscriptions set active=false,last_error_at=clock_timestamp(),last_error_code='UNSAFE_SUBSCRIPTION',updated_at=clock_timestamp() where id=s.id;
    return jsonb_build_object('blocked',true);
  end if;
  if app_private.push_target_fingerprint(s.endpoint,s.p256dh,s.auth_secret) is distinct from _fingerprint then return null; end if;
  if (select count(*) from app_private.push_subscriptions other where other.user_id=s.user_id and other.active
    and (other.created_at,other.id)<=(s.created_at,s.id))>5 then return null; end if;
  return jsonb_build_object('subscriptionId',s.id,'endpoint',s.endpoint,'p256dh',s.p256dh,'auth',s.auth_secret,'fingerprint',_fingerprint);
end;
$$;

create or replace function api.worker_defer_push(_id uuid,_token uuid,_attempted boolean default false)
returns void language plpgsql security definer set search_path='' as $$
begin
  update app_private.portal_push_outbox set lease_until=null,claim_token=null,
    available_at=clock_timestamp()+interval '1 second',attempts=greatest(0,attempts-case when _attempted then 0 else 1 end)
    where id=_id and claim_token=_token and completed_at is null;
end;
$$;

create or replace function api.worker_record_portal_push(_id uuid,_delivered uuid[],_failed boolean,_token uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform 1 from app_private.portal_push_outbox where id=_id and claim_token=_token
    and lease_until>clock_timestamp() and kind<>'news' for update;
  if not found then raise exception 'STALE_LEASE' using errcode='40001'; end if;
  perform api.worker_record_portal_push(_id,_delivered,_failed);
end;
$$;
revoke all on function app_private.push_target_fingerprint(text,text,text) from public,anon,authenticated;
revoke all on function api.worker_push_target(uuid,uuid,text,uuid,uuid),api.worker_defer_push(uuid,uuid,boolean),
  api.worker_record_portal_push(uuid,uuid[],boolean,uuid) from public,anon,authenticated;
grant execute on function api.worker_push_target(uuid,uuid,text,uuid,uuid),api.worker_defer_push(uuid,uuid,boolean),
  api.worker_record_portal_push(uuid,uuid[],boolean,uuid) to service_role;
