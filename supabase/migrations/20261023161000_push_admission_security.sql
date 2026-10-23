-- SEC-01: shared admission policy, serialized account quota, durable rate permits.
create or replace function app_private.valid_push_endpoint(_endpoint text)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(length(_endpoint) between 1 and 4096
    and _endpoint ~ '^https://(fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com|web[.]push[.]apple[.]com)(:443)?/[^[:space:]?#\\]+$'
    and _endpoint !~ '[[:cntrl:]]' and _endpoint !~* '%(0[0-9a-f]|1[0-9a-f]|20|5c|7f)',false)
$$;

create or replace function app_private.valid_push_keys(_p256dh text,_auth text)
returns boolean language plpgsql immutable set search_path='' as $$
declare key_bytes bytea; auth_bytes bytea; x numeric:=0; y numeric:=0; i integer;
  prime constant numeric:=115792089210356248762697446949407573530086143415290314195533631308867097853951;
  b constant numeric:=41058363725152142129326129780047268409114441015993725554835256314039467401291;
begin
  if _p256dh is null or _auth is null or _p256dh !~ '^[A-Za-z0-9_-]{87}$' or _auth !~ '^[A-Za-z0-9_-]{22}$' then return false; end if;
  key_bytes:=decode(translate(_p256dh,'-_','+/')||'=','base64');
  auth_bytes:=decode(translate(_auth,'-_','+/')||'==','base64');
  if octet_length(key_bytes)<>65 or get_byte(key_bytes,0)<>4 or octet_length(auth_bytes)<>16
    or rtrim(translate(replace(encode(key_bytes,'base64'),E'\n',''),'+/','-_'),'=')<>_p256dh
    or rtrim(translate(encode(auth_bytes,'base64'),'+/','-_'),'=')<>_auth then return false; end if;
  for i in 1..32 loop x:=x*256+get_byte(key_bytes,i); y:=y*256+get_byte(key_bytes,i+32); end loop;
  return x<prime and y<prime and mod(y*y,prime)=mod(x*x*x-3*x+b,prime);
exception when others then return false;
end;
$$;

create table if not exists app_private.push_write_permits(
  id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),used_at timestamptz
);
create index if not exists push_write_permits_account_time_idx on app_private.push_write_permits(user_id,created_at);
alter table app_private.push_write_permits enable row level security;
revoke all on app_private.push_write_permits from public,anon,authenticated;

alter table app_private.push_subscriptions drop constraint if exists push_subscriptions_endpoint_length;
alter table app_private.push_subscriptions add constraint push_subscriptions_endpoint_length
  check(length(endpoint) between 1 and 4096) not valid;

create or replace function app_private.guard_push_subscription()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text||':push-write',0));
  if tg_op='UPDATE' then
    if old.user_id<>new.user_id then raise exception 'ENDPOINT_OWNERSHIP_CONFLICT' using errcode='23514'; end if;
  end if;
  if new.active and (not app_private.valid_push_endpoint(new.endpoint) or not app_private.valid_push_keys(new.p256dh,new.auth_secret)) then
    raise exception 'INVALID_SUBSCRIPTION' using errcode='22023'; end if;
  if new.active and not exists(select 1 from app_private.push_subscriptions where user_id=new.user_id and endpoint=new.endpoint and active)
    and (select count(*) from app_private.push_subscriptions where user_id=new.user_id and active and id<>new.id)>=5 then
    raise exception 'DEVICE_LIMIT_REACHED' using errcode='23514'; end if;
  return new;
end;
$$;
drop trigger if exists guard_push_subscription on app_private.push_subscriptions;
create trigger guard_push_subscription before insert or update of endpoint,p256dh,auth_secret,active,user_id
on app_private.push_subscriptions for each row execute function app_private.guard_push_subscription();

create or replace function api.push_write_attempt()
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); token uuid; first_at timestamptz; count_now integer;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':push-write',0));
  delete from app_private.push_write_permits where user_id=actor and created_at<=clock_timestamp()-interval '1 minute';
  select count(*),min(created_at) into count_now,first_at from app_private.push_write_permits where user_id=actor;
  if count_now>=10 then return jsonb_build_object('allowed',false,'code','PUSH_RATE_LIMIT',
    'retryAfterSeconds',greatest(1,ceil(extract(epoch from first_at+interval '1 minute'-clock_timestamp())))); end if;
  insert into app_private.push_write_permits(user_id) values(actor) returning id into token;
  return jsonb_build_object('allowed',true,'permit',token);
end;
$$;

create or replace function api.push_subscription_state()
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  return jsonb_build_object('enabled',coalesce((select enabled from app_private.push_preferences where user_id=actor),false),
    'activeSubscriptionCount',(select count(*) from app_private.push_subscriptions s where user_id=actor and active
      and app_private.valid_push_endpoint(s.endpoint) and app_private.valid_push_keys(s.p256dh,s.auth_secret)),
    'devices',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'label',coalesce(s.device_label,'Mijn apparaat'),
      'provider',case when s.endpoint like 'https://fcm.googleapis.com/%' then 'google'
        when s.endpoint like 'https://updates.push.services.mozilla.com/%' then 'mozilla'
        when s.endpoint like 'https://web.push.apple.com/%' then 'apple' else 'unknown' end,
      'createdAt',s.created_at,'updatedAt',s.updated_at) order by s.created_at)
      from app_private.push_subscriptions s where s.user_id=actor and s.active),'[]'::jsonb),
    'policy',jsonb_build_object('maxDevicesPerAccount',5,'writesPerMinute',10,'maxBatchTargets',20,
      'concurrency',3,'attemptTimeoutMs',2000,'batchTimeoutMs',8000,'maxEndpointLength',4096));
end;
$$;

create or replace function api.push_subscription_write(_permit uuid,_operation text,_payload jsonb,_user_agent text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); permit app_private.push_write_permits; v_endpoint text; existing app_private.push_subscriptions;
  enabled boolean; error_code text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':push-write',0));
  select * into permit from app_private.push_write_permits where id=_permit and user_id=actor and used_at is null
    and created_at>clock_timestamp()-interval '30 seconds' for update;
  if permit.id is null then return jsonb_build_object('error',jsonb_build_object('code','PUSH_PERMIT_REQUIRED')); end if;
  update app_private.push_write_permits set used_at=clock_timestamp() where id=permit.id;
  -- Failed writes return a safe result instead of rolling back their rate debit.
  begin
    if jsonb_typeof(_payload) is distinct from 'object' then raise exception 'INVALID_SUBSCRIPTION' using errcode='22023'; end if;
    if _operation='POST' then
      v_endpoint:=_payload->>'endpoint';
      if not app_private.valid_push_endpoint(v_endpoint) or not app_private.valid_push_keys(_payload#>>'{keys,p256dh}',_payload#>>'{keys,auth}') then
        raise exception 'INVALID_SUBSCRIPTION' using errcode='22023'; end if;
      -- Canonical explicit HTTPS port so the same endpoint cannot occupy two devices.
      v_endpoint:=regexp_replace(v_endpoint,':443/','/');
      select * into existing from app_private.push_subscriptions where push_subscriptions.endpoint=v_endpoint for update;
      if existing.id is not null and existing.user_id<>actor then raise exception 'ENDPOINT_OWNERSHIP_CONFLICT' using errcode='23514'; end if;
      insert into app_private.push_subscriptions(user_id,endpoint,p256dh,auth_secret,user_agent,device_label,active)
        values(actor,v_endpoint,_payload#>>'{keys,p256dh}',_payload#>>'{keys,auth}',left(_user_agent,500),
          left(coalesce(nullif(trim(_payload->>'deviceLabel'),''),'Mijn apparaat'),80),true)
        on conflict(endpoint) do update set p256dh=excluded.p256dh,auth_secret=excluded.auth_secret,
          device_label=excluded.device_label,user_agent=excluded.user_agent,active=true,updated_at=clock_timestamp(),last_error_code=null,last_error_at=null;
      insert into app_private.push_preferences(user_id,enabled) values(actor,true)
        on conflict(user_id) do update set enabled=true,updated_at=clock_timestamp();
    elsif _operation='PATCH' then
      if jsonb_typeof(_payload->'enabled') is distinct from 'boolean' then raise exception 'INVALID_PREFERENCE' using errcode='22023'; end if;
      enabled:=(_payload->>'enabled')::boolean;
      insert into app_private.push_preferences(user_id,enabled) values(actor,enabled)
        on conflict(user_id) do update set enabled=excluded.enabled,updated_at=clock_timestamp();
      if not enabled then update app_private.push_subscriptions set active=false,updated_at=clock_timestamp() where user_id=actor and active; end if;
    elsif _operation='DELETE' then
      if coalesce(_payload->>'id',_payload->>'endpoint','')='' then raise exception 'DEVICE_REQUIRED' using errcode='22023'; end if;
      update app_private.push_subscriptions set active=false,updated_at=clock_timestamp()
        where user_id=actor and (id::text=_payload->>'id' or push_subscriptions.endpoint=regexp_replace(_payload->>'endpoint',':443/','/'));
    else raise exception 'INVALID_OPERATION' using errcode='22023'; end if;
  exception when others then
    error_code:=case when sqlerrm in ('INVALID_SUBSCRIPTION','INVALID_PREFERENCE','DEVICE_REQUIRED','DEVICE_LIMIT_REACHED','ENDPOINT_OWNERSHIP_CONFLICT')
      then sqlerrm else 'INVALID_SUBSCRIPTION' end;
    return jsonb_build_object('error',jsonb_build_object('code',error_code));
  end;
  return api.push_subscription_state();
end;
$$;

-- Keep old clients functional through the same admission gate; they cannot
-- bypass rate accounting by sending a malformed direct RPC payload.
create or replace function app_private.push_legacy_write(_operation text,_payload jsonb,_user_agent text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare attempt jsonb;
begin
  attempt:=api.push_write_attempt();
  if (attempt->>'allowed')::boolean is distinct from true then return jsonb_build_object('error',attempt); end if;
  return api.push_subscription_write((attempt->>'permit')::uuid,_operation,_payload,_user_agent);
end;
$$;
create or replace function api.push_subscription_upsert(_endpoint text,_p256dh text,_auth_secret text,_user_agent text default null,_device_label text default null)
returns jsonb language sql security definer set search_path='' as $$
  select app_private.push_legacy_write('POST',jsonb_build_object('endpoint',_endpoint,'keys',jsonb_build_object('p256dh',_p256dh,'auth',_auth_secret),'deviceLabel',_device_label),_user_agent)
$$;
create or replace function api.push_preference_set(_enabled boolean)
returns jsonb language sql security definer set search_path='' as $$
  select app_private.push_legacy_write('PATCH',jsonb_build_object('enabled',_enabled))
$$;
create or replace function api.push_subscription_delete(_endpoint text)
returns jsonb language sql security definer set search_path='' as $$
  select app_private.push_legacy_write('DELETE',jsonb_build_object('endpoint',_endpoint))
$$;
revoke all on function app_private.valid_push_endpoint(text),app_private.valid_push_keys(text,text),
  app_private.guard_push_subscription(),app_private.push_legacy_write(text,jsonb,text) from public,anon,authenticated;
revoke all on function api.push_write_attempt(),api.push_subscription_write(uuid,text,jsonb,text) from public,anon;
grant execute on function api.push_write_attempt(),api.push_subscription_write(uuid,text,jsonb,text) to authenticated;
