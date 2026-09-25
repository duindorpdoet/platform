begin;

create table app_private.push_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app_private.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_secret text not null,
  user_agent text,
  device_label text,
  active boolean not null default true,
  last_success_at timestamptz,
  last_error_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_subscriptions_endpoint_length check (char_length(endpoint) between 20 and 2048),
  constraint push_subscriptions_p256dh_length check (char_length(p256dh) between 16 and 512),
  constraint push_subscriptions_auth_length check (char_length(auth_secret) between 8 and 256)
);

create index push_subscriptions_user_active_idx
  on app_private.push_subscriptions(user_id, active);

alter table app_private.push_preferences enable row level security;
alter table app_private.push_subscriptions enable row level security;

create policy push_preferences_owner_select
  on app_private.push_preferences
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy push_subscriptions_owner_select
  on app_private.push_subscriptions
  for select to authenticated
  using ((select auth.uid()) = user_id);

revoke all on table app_private.push_preferences from public, anon, authenticated;
revoke all on table app_private.push_subscriptions from public, anon, authenticated;

create or replace function api.push_subscription_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'enabled', coalesce((select p.enabled from app_private.push_preferences p where p.user_id = actor), false),
    'activeSubscriptionCount', (
      select count(*) from app_private.push_subscriptions s where s.user_id = actor and s.active
    )
  );
end;
$$;

create or replace function api.push_preference_set(_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  insert into app_private.push_preferences(user_id, enabled)
  values (actor, _enabled)
  on conflict (user_id) do update
    set enabled = excluded.enabled, updated_at = now();

  if not _enabled then
    update app_private.push_subscriptions
    set active = false, updated_at = now()
    where user_id = actor and active;
  end if;

  return api.push_subscription_state();
end;
$$;

create or replace function api.push_subscription_upsert(
  _endpoint text,
  _p256dh text,
  _auth_secret text,
  _user_agent text default null,
  _device_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if char_length(_endpoint) not between 20 and 2048
     or char_length(_p256dh) not between 16 and 512
     or char_length(_auth_secret) not between 8 and 256 then
    raise exception 'INVALID_SUBSCRIPTION' using errcode = '22023';
  end if;

  insert into app_private.push_subscriptions(
    user_id, endpoint, p256dh, auth_secret, user_agent, device_label, active
  )
  values (
    actor, _endpoint, _p256dh, _auth_secret,
    left(nullif(trim(_user_agent), ''), 500),
    left(nullif(trim(_device_label), ''), 120),
    true
  )
  on conflict (endpoint) do update
    set user_id = actor,
        p256dh = excluded.p256dh,
        auth_secret = excluded.auth_secret,
        user_agent = excluded.user_agent,
        device_label = excluded.device_label,
        active = true,
        last_error_at = null,
        last_error_code = null,
        updated_at = now();

  insert into app_private.push_preferences(user_id, enabled)
  values (actor, true)
  on conflict (user_id) do update set enabled = true, updated_at = now();

  return api.push_subscription_state();
end;
$$;

create or replace function api.push_subscription_delete(_endpoint text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  update app_private.push_subscriptions
  set active = false, updated_at = now()
  where user_id = actor and endpoint = _endpoint;

  if not exists (
    select 1 from app_private.push_subscriptions where user_id = actor and active
  ) then
    insert into app_private.push_preferences(user_id, enabled)
    values (actor, false)
    on conflict (user_id) do update set enabled = false, updated_at = now();
  end if;

  return api.push_subscription_state();
end;
$$;

create or replace function api.push_test_targets_for_user(_user_id uuid)
returns table(endpoint text, p256dh text, auth_secret text)
language sql
security definer
set search_path = ''
as $$
  select s.endpoint, s.p256dh, s.auth_secret
  from app_private.push_subscriptions s
  join app_private.push_preferences p on p.user_id = s.user_id and p.enabled
  where s.user_id = _user_id and s.active;
$$;

create or replace function api.push_subscription_delivery_record(
  _endpoint text,
  _success boolean,
  _error_code text default null,
  _deactivate boolean default false
)
returns void
language sql
security definer
set search_path = ''
as $$
  update app_private.push_subscriptions
  set active = case when _deactivate then false else active end,
      last_success_at = case when _success then now() else last_success_at end,
      last_error_at = case when _success then null else now() end,
      last_error_code = case when _success then null else left(_error_code, 100) end,
      updated_at = now()
  where endpoint = _endpoint;
$$;

revoke execute on function api.push_subscription_state() from public, anon;
revoke execute on function api.push_preference_set(boolean) from public, anon;
revoke execute on function api.push_subscription_upsert(text, text, text, text, text) from public, anon;
revoke execute on function api.push_subscription_delete(text) from public, anon;
revoke execute on function api.push_test_targets_for_user(uuid) from public, anon, authenticated;
revoke execute on function api.push_subscription_delivery_record(text, boolean, text, boolean) from public, anon, authenticated;

grant execute on function api.push_subscription_state() to authenticated;
grant execute on function api.push_preference_set(boolean) to authenticated;
grant execute on function api.push_subscription_upsert(text, text, text, text, text) to authenticated;
grant execute on function api.push_subscription_delete(text) to authenticated;
grant execute on function api.push_test_targets_for_user(uuid) to service_role;
grant execute on function api.push_subscription_delivery_record(text, boolean, text, boolean) to service_role;

commit;
