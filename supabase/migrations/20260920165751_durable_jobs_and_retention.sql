create extension if not exists pg_cron;
create extension if not exists pg_net;

create table app_private.job_configs (
  key text primary key check (key in ('mail_outbox')),
  endpoint text not null check (endpoint ~ '^https://'),
  secret_id uuid not null,
  active boolean not null default false,
  configured_at timestamptz not null default now(),
  configured_by text not null default 'service_role'
);
alter table app_private.job_configs enable row level security;
revoke all on table app_private.job_configs from public, anon, authenticated;

create or replace function app_private.dispatch_mail_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare config app_private.job_configs; bearer text; request_id bigint;
begin
  select * into config from app_private.job_configs where key = 'mail_outbox' and active;
  if config.key is null then return null; end if;
  select decrypted_secret into bearer from vault.decrypted_secrets where id = config.secret_id;
  if bearer is null then raise exception 'MAIL_WORKER_SECRET_MISSING'; end if;
  select net.http_post(
    url := config.endpoint,
    headers := jsonb_build_object('Authorization', 'Bearer ' || bearer, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  ) into request_id;
  return request_id;
end;
$$;

create or replace function api.configure_mail_worker(_endpoint text, _secret text, _active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare config app_private.job_configs; new_secret_id uuid; scheduled_job_id bigint;
begin
  if _endpoint !~ '^https://' or char_length(_secret) < 32 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into config from app_private.job_configs where key = 'mail_outbox' for update;
  if config.key is null then
    select vault.create_secret(_secret, 'duindorp_halloween_mail_worker', 'Bearer token for the one-minute durable outbox poller') into new_secret_id;
    insert into app_private.job_configs(key, endpoint, secret_id, active) values ('mail_outbox', _endpoint, new_secret_id, _active) returning * into config;
  else
    perform vault.update_secret(config.secret_id, _secret);
    update app_private.job_configs set endpoint = _endpoint, active = _active, configured_at = now() where key = 'mail_outbox' returning * into config;
  end if;
  if exists (select 1 from cron.job where jobname = 'duindorp-halloween-mail-outbox') then perform cron.unschedule('duindorp-halloween-mail-outbox'); end if;
  if _active then
    select cron.schedule('duindorp-halloween-mail-outbox', '* * * * *', 'select app_private.dispatch_mail_worker()') into scheduled_job_id;
  end if;
  return jsonb_build_object('active', config.active, 'endpointOrigin', regexp_replace(config.endpoint, '^(https://[^/]+).*$', '\1'), 'scheduleId', scheduled_job_id);
end;
$$;

create or replace function api.retention_preview(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); event_record app_private.events; retention_days integer;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not app_private.has_capability(event_record.id, 'event_admin', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  retention_days := coalesce((event_record.settings ->> 'operationalDataRetentionDays')::integer, 30);
  return jsonb_build_object(
    'retentionDays', retention_days,
    'eligibleAfter', (event_record.local_date + retention_days) :: timestamp at time zone event_record.timezone,
    'groupRuns', (select count(*) from app_private.group_runs run join app_private.walking_groups walking_group on walking_group.id = run.group_id where walking_group.event_id = event_record.id),
    'journeyEvents', (select count(*) from app_private.journey_events journey join app_private.group_runs run on run.id = journey.run_id join app_private.walking_groups walking_group on walking_group.id = run.group_id where walking_group.event_id = event_record.id),
    'action', 'preview_only'
  );
end;
$$;

revoke execute on function app_private.dispatch_mail_worker() from public, anon, authenticated;
revoke execute on function api.configure_mail_worker(text, text, boolean) from public, anon, authenticated;
revoke execute on function api.retention_preview(text) from public, anon;
grant execute on function api.configure_mail_worker(text, text, boolean) to service_role;
grant execute on function api.retention_preview(text) to authenticated;

create or replace function api.configure_release_mode(_event_slug text, _mode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare event_record app_private.events;
begin
  if _mode not in ('staging_test_open', 'production_closed') then raise exception 'INVALID_MODE' using errcode = '22023'; end if;
  update app_private.events
  set phase = case when _mode = 'staging_test_open' then 'registration_open'::app_private.event_phase else 'draft'::app_private.event_phase end,
      registration_open_at = case when _mode = 'staging_test_open' then now() - interval '1 minute' else null end,
      registration_close_at = case when _mode = 'staging_test_open' then make_timestamptz(extract(year from local_date)::integer, 10, 25, 23, 59, 0, timezone) else null end,
      settings = settings || jsonb_build_object('registrationPublished', _mode = 'staging_test_open', 'releaseMode', _mode),
      settings_version = settings_version + 1
  where slug = _event_slug returning * into event_record;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into app_private.audit_events(event_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, 'release.mode_configured', 'event', event_record.id, jsonb_build_object('mode', _mode));
  return jsonb_build_object('phase', event_record.phase, 'registrationPublished', event_record.settings -> 'registrationPublished');
end;
$$;

revoke execute on function api.configure_release_mode(text, text) from public, anon, authenticated;
grant execute on function api.configure_release_mode(text, text) to service_role;
