-- Additive provider migration. No activation, mail, consent or publication occurs here.
alter table app_private.email_outbox add column provider text check(provider in ('sendgrid','resend'));
alter table app_private.email_outbox add column accepted_at timestamptz;
-- Preserve all existing columns/fingerprints during additive metadata backfill.
alter table app_private.email_outbox disable trigger email_outbox_touch;
update app_private.email_outbox set provider='sendgrid' where attempts>0 or provider_id is not null or status in ('accepted','delivered','unknown');
update app_private.email_outbox set accepted_at=created_at where status in ('accepted','delivered') or provider_id is not null;
alter table app_private.email_outbox enable trigger email_outbox_touch;
alter table app_private.email_events drop constraint email_events_provider_check;
alter table app_private.email_events add constraint email_events_provider_check check(provider in ('sendgrid','resend'));
alter table app_private.email_events add column provider_message_id text;
alter table app_private.email_events add column environment text;
alter table app_private.email_events add column recipient_hash bytea;
alter table app_private.email_events add column safe_code text;
alter table app_private.email_events add column verification_key_hash text;
create index email_events_provider_message on app_private.email_events(provider,environment,provider_message_id,recipient_hash);
create index email_events_unlinked_provider on app_private.email_events(provider,environment,provider_message_id) where outbox_id is null;

create table app_private.mail_config_versions(
 id uuid primary key default gen_random_uuid(), environment text not null check(environment in ('development','test','staging','production')),
 version integer not null, provider text not null check(provider in ('sendgrid','resend')),
 from_email text not null check(from_email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'),
 from_name text not null check(length(from_name) between 1 and 120 and from_name !~ '[\r\n<>]'),
 reply_to text not null check(reply_to ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'),
 config_hash text not null, created_at timestamptz not null default now(), unique(environment,version));
create table app_private.mail_config_heads(
 environment text primary key, active_id uuid references app_private.mail_config_versions(id), draft_id uuid references app_private.mail_config_versions(id),
 revision integer not null default 0, suppressions_imported_at timestamptz, suppression_import_hash text,
 checked_id uuid references app_private.mail_config_versions(id), checked_at timestamptz, check_result jsonb);
-- Effective legacy configuration is bootstrapped explicitly from runtime before deployment.
-- An unbootstrapped environment fails closed instead of silently switching Auth.
create table app_private.mail_envelopes(
 id uuid primary key default gen_random_uuid(), environment text not null, logical_key text not null,
 config_id uuid not null references app_private.mail_config_versions(id), provider text not null check(provider in ('resend','sendgrid')),
 outbox_id uuid unique references app_private.email_outbox(id) on delete restrict,
 channel text not null check(channel in ('auth','transactional','nachtpost','test')), message_type text not null,
 recipient_hash bytea not null, payload jsonb, payload_hash text not null, credential_hash text not null,
 status text not null check(status in ('processing','unknown','deferred','failed','accepted','reconcile')),
 claim_token uuid, lease_until timestamptz, first_attempt_at timestamptz not null default clock_timestamp(),
 accepted_at timestamptz, provider_id text, error_code text, retry_after_seconds integer,
 delivery_status text not null default 'pending', delivered_at timestamptz, complained_at timestamptz,
 bounced_at timestamptz, suppressed_at timestamptz, failed_at timestamptz,
 unique(environment,logical_key), unique(provider,environment,provider_id),
 check(channel <> 'auth' or payload is null));
create table app_private.mail_suppressions(
 environment text not null, recipient_hash bytea not null, reason text not null, transactional_blocked boolean not null default true,
 provider text not null, created_at timestamptz not null default now(), primary key(environment,recipient_hash));
create index mail_envelopes_recent on app_private.mail_envelopes(environment,first_attempt_at desc);
create index mail_envelopes_config on app_private.mail_envelopes(config_id);
create index mail_envelopes_reconcile on app_private.mail_envelopes(environment,status,first_attempt_at) where status in ('unknown','reconcile');
alter table app_private.mail_config_versions enable row level security;
alter table app_private.mail_config_heads enable row level security;
alter table app_private.mail_envelopes enable row level security;
alter table app_private.mail_suppressions enable row level security;
revoke all on app_private.mail_config_versions,app_private.mail_config_heads,app_private.mail_envelopes,app_private.mail_suppressions from public,anon,authenticated,service_role;

create function api.worker_mail_config(_environment text,_key text default null,_config_id uuid default null) returns jsonb
language sql security definer set search_path='' as $$
 select to_jsonb(c) from app_private.mail_config_versions c where c.environment=_environment and c.id=coalesce(
 (select config_id from app_private.mail_envelopes where environment=_environment and logical_key=_key),_config_id,
 (select active_id from app_private.mail_config_heads where environment=_environment))
$$;

create function api.worker_mail_prepare(_environment text,_key text,_config_id uuid,_outbox_id uuid,_channel text,_message_type text,_recipient text,_payload jsonb,_payload_hash text,_credential_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.mail_envelopes; o app_private.email_outbox; c app_private.mail_config_versions; token uuid:=gen_random_uuid();
begin
 perform pg_advisory_xact_lock(hashtextextended(_environment||':'||_key,0));
 select * into e from app_private.mail_envelopes where environment=_environment and logical_key=_key for update;
 if e.id is not null then
  if e.recipient_hash<>extensions.digest(lower(trim(_recipient)),'sha256') or e.channel<>_channel or e.outbox_id is distinct from _outbox_id then raise exception 'ENVELOPE_CONFLICT';end if;
  if _channel='auth' and e.payload_hash<>_payload_hash then raise exception 'AUTH_ENVELOPE_CONFLICT';end if;
  if e.status<>'accepted' and e.credential_hash<>_credential_hash then
   update app_private.mail_envelopes set status='reconcile',error_code='PROVIDER_CREDENTIAL_CHANGED' where id=e.id returning * into e;
   return to_jsonb(e)||jsonb_build_object('dispatch',false);
  end if;
  if e.status in ('accepted','failed','reconcile') then return to_jsonb(e)||jsonb_build_object('dispatch',false);end if;
  if e.lease_until>clock_timestamp() then return to_jsonb(e)||jsonb_build_object('dispatch',false,'busy',true);end if;
  if e.first_attempt_at<clock_timestamp()-interval '23 hours 55 minutes' then
   update app_private.mail_envelopes set status='reconcile',error_code='IDEMPOTENCY_WINDOW_EXPIRED' where id=e.id returning * into e;
   return to_jsonb(e)||jsonb_build_object('dispatch',false);
  end if;
 else
  select * into c from app_private.mail_config_versions where id=_config_id and environment=_environment;
  if c.id is null or (c.id is distinct from (select active_id from app_private.mail_config_heads where environment=_environment) and not (_channel='test' and c.id=(select draft_id from app_private.mail_config_heads where environment=_environment))) then raise exception 'CONFIG_CHANGED';end if;
  if _outbox_id is not null then
   select * into o from app_private.email_outbox where id=_outbox_id for update;
   if o.id is null or o.status<>'processing' or lower(trim(o.recipient_email))<>lower(trim(_recipient)) then raise exception 'OUTBOX_NOT_AUTHORIZED';end if;
   if o.provider is not null and o.provider<>c.provider then raise exception 'LEGACY_ATTEMPT_REQUIRES_RECONCILIATION';end if;
   if _channel='test' and o.payload->>'configId' is distinct from c.id::text then raise exception 'TEST_CONFIG_CONFLICT';end if;
   if o.provider_id is not null or o.accepted_at is not null then raise exception 'ALREADY_ACCEPTED';end if;
   update app_private.email_outbox set provider=c.provider where id=o.id;
  elsif _channel not in ('auth','test') then raise exception 'OUTBOX_REQUIRED';end if;
  if not (_channel='test' and lower(_recipient) in ('delivered@resend.dev','bounced@resend.dev','complained@resend.dev','suppressed@resend.dev')) and exists(select 1 from app_private.mail_suppressions where environment=_environment and recipient_hash=extensions.digest(lower(trim(_recipient)),'sha256') and (transactional_blocked or _channel='nachtpost')) then raise exception 'RECIPIENT_SUPPRESSED';end if;
  insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload,payload_hash,credential_hash,status)
  values(_environment,_key,c.id,c.provider,_outbox_id,_channel,case when _outbox_id is not null then o.message_type else _message_type end,extensions.digest(lower(trim(_recipient)),'sha256'),case when _channel='auth' then null else _payload end,_payload_hash,_credential_hash,'processing') returning * into e;
 end if;
 -- Legacy SendGrid has no provider idempotency guarantee. An uncertain legacy
 -- attempt is never retried through either provider automatically.
 if e.provider='sendgrid' and e.status in ('unknown','deferred') then
  update app_private.mail_envelopes set status='reconcile',error_code='LEGACY_RECONCILIATION_REQUIRED' where id=e.id returning * into e;
  return to_jsonb(e)||jsonb_build_object('dispatch',false);
 end if;
 update app_private.mail_envelopes set status='processing',claim_token=token,lease_until=clock_timestamp()+interval '8 seconds' where id=e.id returning * into e;
 return to_jsonb(e)||jsonb_build_object('dispatch',true);
end $$;

create function app_private.project_resend_events(_envelope uuid) returns void
language plpgsql security definer set search_path='' as $$
declare e app_private.mail_envelopes; delivered timestamptz; complained timestamptz; bounced timestamptz; suppressed timestamptz; failed timestamptz; delayed boolean; seen boolean;
begin
 select * into e from app_private.mail_envelopes where id=_envelope for update;
 if e.provider<>'resend' or e.provider_id is null then return;end if;
 -- Tags are diagnostics only. The authoritative link is provider+environment+
 -- provider message ID returned for this envelope, plus the recipient hash.
 update app_private.email_events set outbox_id=e.outbox_id where provider='resend' and environment=e.environment and provider_message_id=e.provider_id and recipient_hash=e.recipient_hash and outbox_id is null;
 select min(occurred_at) filter(where kind='email.delivered'),min(occurred_at) filter(where kind='email.complained'),
 min(occurred_at) filter(where kind='email.bounced'),min(occurred_at) filter(where kind='email.suppressed'),
 min(occurred_at) filter(where kind='email.failed'),bool_or(kind='email.delivery_delayed'),bool_or(kind in ('email.sent','email.delivered','email.complained','email.bounced','email.delivery_delayed','email.failed','email.suppressed'))
 into delivered,complained,bounced,suppressed,failed,delayed,seen from app_private.email_events
 where provider='resend' and environment=e.environment and provider_message_id=e.provider_id and recipient_hash=e.recipient_hash;
 if seen is not true then return;end if;
 update app_private.mail_envelopes set status='accepted',accepted_at=coalesce(accepted_at,clock_timestamp()),
 delivered_at=delivered,complained_at=complained,bounced_at=bounced,suppressed_at=suppressed,failed_at=failed,
 delivery_status=case when complained is not null then 'complained' when suppressed is not null then 'suppressed' when bounced is not null then 'bounced' when failed is not null then 'failed' when delivered is not null then 'delivered' when delayed then 'delayed' else 'accepted' end,
 lease_until=null where id=e.id;
 if complained is not null or bounced is not null or suppressed is not null then
  insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider)
  values(e.environment,e.recipient_hash,case when complained is not null then 'complained' when bounced is not null then 'bounced' else 'suppressed' end,'resend')
  on conflict(environment,recipient_hash) do update set reason=case when app_private.mail_suppressions.transactional_blocked and not excluded.transactional_blocked then app_private.mail_suppressions.reason else excluded.reason end,transactional_blocked=app_private.mail_suppressions.transactional_blocked or excluded.transactional_blocked;
  if e.channel='nachtpost' then
   insert into app_private.editorial_suppressions(email_hash,reason) values(e.recipient_hash,case when complained is not null then 'spamreport' else 'bounce' end)
   on conflict(email_hash) do update set reason=excluded.reason;
  end if;
 end if;
 if e.outbox_id is not null then
  update app_private.email_outbox set provider_id=e.provider_id,accepted_at=coalesce(accepted_at,e.accepted_at,clock_timestamp()),lease_until=null,
  status=case when status='delivered' or delivered is not null then 'delivered'::app_private.outbox_status
   when bounced is not null or complained is not null or suppressed is not null or failed is not null then 'failed'::app_private.outbox_status else 'accepted'::app_private.outbox_status end
  where id=e.outbox_id;
 end if;
end $$;

create function api.worker_mail_finish(_id uuid,_token uuid,_status text,_provider_id text default null,_code text default null,_retry_after integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e app_private.mail_envelopes;
begin
 select * into e from app_private.mail_envelopes where id=_id for update;
 if e.id is null or e.claim_token is distinct from _token then raise exception 'STALE_MAIL_CLAIM';end if;
 if _status not in ('accepted','unknown','deferred','failed') or (_status='accepted' and nullif(_provider_id,'') is null) then raise exception 'INVALID_MAIL_RESULT';end if;
 if e.status<>'accepted' then
  update app_private.mail_envelopes set status=_status,provider_id=coalesce(_provider_id,provider_id),error_code=_code,retry_after_seconds=_retry_after,
  accepted_at=case when _status='accepted' then coalesce(accepted_at,clock_timestamp()) else accepted_at end,lease_until=null where id=e.id returning * into e;
 end if;
 if e.outbox_id is not null then
  update app_private.email_outbox set provider=e.provider,provider_id=coalesce(e.provider_id,provider_id),accepted_at=coalesce(accepted_at,e.accepted_at),
  status=case when status in ('accepted','delivered','failed','suppressed') then status else e.status::app_private.outbox_status end,
  last_error_code=e.error_code,lease_until=null,next_attempt_at=clock_timestamp()+make_interval(secs=>coalesce(_retry_after,30)) where id=e.outbox_id;
 end if;
 perform app_private.project_resend_events(e.id);
 return (select to_jsonb(m) from app_private.mail_envelopes m where id=e.id);
end $$;

create function api.worker_store_resend_event(_environment text,_event_id text,_provider_id text,_kind text,_occurred_at timestamptz,_recipient text default null,_safe_code text default null,_verification_key_hash text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare inserted boolean; envelope uuid;
begin
 insert into app_private.email_events(provider,environment,provider_event_id,provider_message_id,kind,occurred_at,recipient_hash,safe_code,verification_key_hash)
 values('resend',_environment,_event_id,_provider_id,_kind,_occurred_at,case when _recipient is not null then extensions.digest(lower(trim(_recipient)),'sha256') end,_safe_code,_verification_key_hash)
 on conflict(provider,provider_event_id) do nothing;
 get diagnostics inserted=row_count;
 if not inserted then return false;end if;
 select id into envelope from app_private.mail_envelopes where provider='resend' and environment=_environment and provider_id=_provider_id;
 if envelope is not null then perform app_private.project_resend_events(envelope);end if;
 return true;
end $$;

-- Preserve all existing domain cleanup wrappers, claim/lease and SKIP LOCKED.
alter function api.worker_claim_outbox(integer,integer) rename to worker_claim_outbox_before_resend;
revoke all on function api.worker_claim_outbox_before_resend(integer,integer) from public,anon,authenticated,service_role;
create function api.worker_claim_outbox(_batch_size integer,_lease_seconds integer,_environment text) returns setof app_private.email_outbox
language plpgsql security definer set search_path='' as $$
begin
 if _environment is not null and _environment not in ('development','test','staging','production') then raise exception 'INVALID_ENVIRONMENT';end if;
 -- Restore acknowledged envelopes after a crash; never re-claim provider delays.
 update app_private.email_outbox o set status=case when e.delivered_at is not null then 'delivered'::app_private.outbox_status else 'accepted'::app_private.outbox_status end,
 provider_id=e.provider_id,accepted_at=coalesce(o.accepted_at,e.accepted_at),lease_until=null
 from app_private.mail_envelopes e where e.outbox_id=o.id and e.status='accepted' and o.status in ('processing','unknown','deferred');
 update app_private.mail_envelopes set status='unknown',error_code='EDGE_LEASE_EXPIRED',lease_until=null where status='processing' and lease_until<clock_timestamp();
 update app_private.mail_envelopes set status='reconcile',error_code='IDEMPOTENCY_WINDOW_EXPIRED' where status in ('unknown','deferred') and first_attempt_at<clock_timestamp()-interval '23 hours 55 minutes';
 update app_private.email_outbox o set status='unknown',lease_until=null,last_error_code=e.error_code from app_private.mail_envelopes e where e.outbox_id=o.id and e.status='reconcile' and o.status in ('pending','deferred','processing','unknown');
 update app_private.email_outbox o set status='deferred',lease_until=null,next_attempt_at=least(o.next_attempt_at,clock_timestamp())
 from app_private.mail_envelopes e where e.outbox_id=o.id and e.provider='resend' and e.status in ('unknown','deferred')
 and (o.status='unknown' or (o.status='processing' and o.lease_until<clock_timestamp()));
 return query select * from api.worker_claim_outbox_before_resend(_batch_size,_lease_seconds);
end $$;

-- Preserve the two-argument RPC for workers already running during rollout.
-- Those workers used SendGrid without durable envelopes. Label their claims
-- explicitly so a later deployment cannot replay an uncertain legacy call as Resend.
create function api.worker_claim_outbox(_batch_size integer,_lease_seconds integer) returns setof app_private.email_outbox
language plpgsql security definer set search_path='' as $$
declare item app_private.email_outbox;
begin
 for item in select * from api.worker_claim_outbox(_batch_size,_lease_seconds,null) loop
  if item.provider='resend' or exists(select 1 from app_private.mail_envelopes e where e.outbox_id=item.id and e.provider='resend') then
   -- An old caller does not understand Resend keys. It may not receive a
   -- recovered Resend row and route it through its old SendGrid transport.
   update app_private.email_outbox set status='unknown',lease_until=null,last_error_code='ENVELOPE_WORKER_REQUIRED' where id=item.id;
   continue;
  end if;
  if item.provider is null then
   update app_private.email_outbox set provider='sendgrid' where id=item.id and provider is null returning * into item;
  end if;
  return next item;
 end loop;
end $$;

create or replace function api.worker_update_outbox(_id uuid,_status app_private.outbox_status,_provider_id text default null,_error_code text default null,_next_attempt_at timestamptz default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 update app_private.email_outbox set status=case when status in ('accepted','delivered','failed','suppressed') then status
 when exists(select 1 from app_private.mail_envelopes e where e.outbox_id=_id and e.status='accepted') then 'accepted'::app_private.outbox_status else _status end,
 provider=coalesce(provider,(select e.provider from app_private.mail_envelopes e where e.outbox_id=_id),case when _provider_id is not null then 'sendgrid' end),provider_id=coalesce(provider_id,_provider_id),accepted_at=case when _status in ('accepted','delivered') then coalesce(accepted_at,clock_timestamp()) else accepted_at end,
 last_error_code=case when status in ('accepted','delivered') then last_error_code else _error_code end,
 next_attempt_at=coalesce(_next_attempt_at,next_attempt_at),lease_until=null where id=_id;
 if not found then raise exception 'OUTBOX_NOT_FOUND';end if;
end $$;

-- A legacy callback can only affect a legacy message; a provider deferral does
-- not relinquish transport acceptance. Existing SendGrid records remain intact.
create or replace function api.worker_store_email_event(_provider_event_id text,_outbox_id uuid,_kind text,_occurred_at timestamptz)
returns boolean language plpgsql security definer set search_path='' as $$
declare inserted boolean;
begin
 if exists(select 1 from app_private.email_outbox where id=_outbox_id and provider='resend') then return false;end if;
 insert into app_private.email_events(provider,provider_event_id,outbox_id,kind,occurred_at) values('sendgrid',_provider_event_id,_outbox_id,_kind,_occurred_at) on conflict(provider,provider_event_id) do nothing;
 get diagnostics inserted=row_count;
 if inserted and _outbox_id is not null then
 update app_private.email_outbox set provider='sendgrid',accepted_at=coalesce(accepted_at,clock_timestamp()),status=case
 when status in ('delivered','failed','suppressed') then status when _kind='delivered' then 'delivered'::app_private.outbox_status
 when _kind in ('bounce','dropped','spamreport') then 'failed'::app_private.outbox_status
 else 'accepted'::app_private.outbox_status end where id=_outbox_id;
 if _kind in ('bounce','dropped','spamreport') then
 insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider)
 select h.environment,extensions.digest(lower(trim(o.recipient_email)),'sha256'),_kind,'sendgrid' from app_private.email_outbox o cross join app_private.mail_config_heads h where o.id=_outbox_id
 on conflict(environment,recipient_hash) do update set reason=case when app_private.mail_suppressions.transactional_blocked and not excluded.transactional_blocked then app_private.mail_suppressions.reason else excluded.reason end,transactional_blocked=app_private.mail_suppressions.transactional_blocked or excluded.transactional_blocked;
 end if;end if;
 return inserted;
end $$;

-- Guard against accepted rows made retryable by a late worker or legacy domain
-- wrapper. Delivery projections remain independently visible in mail_envelopes.
create function app_private.mail_acceptance_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if old.accepted_at is not null and new.status in ('pending','processing','deferred','unknown','validated') then new.status:=old.status;end if;
 new.accepted_at:=coalesce(old.accepted_at,new.accepted_at);
 return new;
end $$;
create trigger mail_acceptance_guard before update on app_private.email_outbox for each row execute function app_private.mail_acceptance_guard();

-- Stable semantic history: callbacks may update updated_at, never this order.
create or replace function api.worker_group_schedule_mail_payload(_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare message app_private.email_outbox; publication app_private.group_start_publications; previous app_private.email_outbox; result jsonb; kind text;
begin
 select * into message from app_private.email_outbox where id=_outbox_id and message_type in ('group_schedule_published','group_schedule_corrected','group_composition_confirmed','group_assignment_withdrawn') for update;
 if message.id is null or message.status in ('suppressed','delivered','failed') then return null;end if;
 if message.message_type='group_assignment_withdrawn' then
  if not exists(select 1 from app_private.registrations r join app_private.household_members m on m.household_id=r.household_id and m.user_id::text=message.recipient_ref and m.revoked_at is null and m.accepted_at is not null where r.event_id=(message.payload->>'eventId')::uuid and r.status='submitted') then return null;end if;
  return message.payload;
 end if;
 if not exists(select 1 from app_private.group_adult_recipients((message.payload->>'groupId')::uuid) r where r.user_id::text=message.recipient_ref and r.email=lower(message.recipient_email)) then return null;end if;
 if message.message_type='group_composition_confirmed' then
  if not exists(select 1 from app_private.walking_groups g where g.id=(message.payload->>'groupId')::uuid and g.retired_at is null and g.composition_revision=(message.payload->>'compositionRevision')::integer and g.composition_confirmed_hash=app_private.start_group_composition_hash(g.id) and g.composition_confirmed_hash=message.payload->>'compositionHash') then return null;end if;
  return message.payload;
 end if;
 select * into publication from app_private.current_start_publication((message.payload->>'groupId')::uuid);
 if publication.id is null or publication.starts_at is distinct from (message.payload->>'startsAt')::timestamptz then return null;end if;
 -- Only evidence of actual provider acceptance is treated as a previously communicated time.
 select * into previous from app_private.email_outbox o where o.id<>message.id and o.recipient_ref=message.recipient_ref
  and o.payload->>'groupId'=message.payload->>'groupId' and o.message_type in ('group_schedule_published','group_schedule_corrected')
  and (o.status in ('accepted','delivered') or o.provider_id is not null) order by coalesce((select t.publication_order from app_private.start_time_communications t where t.id=coalesce(nullif(o.payload->>'timeEventId','')::uuid,case when o.dedupe_key~'^start-time:[0-9a-f-]{36}:' then split_part(o.dedupe_key,':',2)::uuid end)),(select max(p.publication_order) from app_private.group_start_publications p where p.group_id=(o.payload->>'groupId')::uuid and p.revision=case when o.dedupe_key~'^group-schedule:[0-9a-f-]{36}:[0-9]+:' then split_part(o.dedupe_key,':',3)::integer when coalesce(o.payload->>'revision','')~'^[0-9]+$' then (o.payload->>'revision')::integer end),(select max(p.publication_order) from app_private.group_start_publications p where p.group_id=(o.payload->>'groupId')::uuid and p.starts_at=(o.payload->>'startsAt')::timestamptz and p.published_at<=o.created_at),0) desc,o.accepted_at desc nulls last,o.created_at desc,o.id desc limit 1;
 if previous.id is not null and (previous.payload->>'startsAt')::timestamptz=publication.starts_at then return null;end if;
 kind:=case when previous.id is null then 'group_schedule_published' else 'group_schedule_corrected' end;
 result:=jsonb_build_object('groupId',publication.group_id,'groupName',message.payload->>'groupName','groupCode',message.payload->>'groupCode','messageType',kind,
  'timeEventId',message.payload->'timeEventId','startsAt',publication.starts_at,'oldStartsAt',previous.payload->'startsAt','addressReleaseAt',publication.starts_at-interval '1 hour',
  'addressReleased',clock_timestamp()>=publication.starts_at-interval '1 hour','actionPath','/omgeving/meeloper/groep');
 -- Persist exactly the safe content rendered by the worker for subsequent corrections/audit.
 update app_private.email_outbox set payload=result,message_type=kind where id=message.id;
 return result;
end $$;

-- Only the server's service credential may enter these commands. The route also
-- requires a runtime allowlisted verified user ID; event_admin alone is not enough.
create function app_private.assert_mail_admin(_actor uuid,_event_slug text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if _actor is null or not exists(select 1 from app_private.events e where e.slug=_event_slug and app_private.has_capability(e.id,'event_admin',_actor)) then
 raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
end $$;

create function app_private.mail_config_test_verified(_environment text,_config uuid,_credential_hash text,_webhook_hash text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.mail_envelopes e where e.environment=_environment and e.config_id=_config and e.channel='test' and e.status='accepted' and e.delivery_status='delivered' and e.delivered_at is not null and e.accepted_at>=now()-interval '30 minutes' and e.credential_hash=_credential_hash
 and exists(select 1 from app_private.email_events ev where ev.provider='resend' and ev.environment=e.environment and ev.provider_message_id=e.provider_id and ev.recipient_hash=e.recipient_hash and ev.kind='email.delivered' and ev.verification_key_hash=_webhook_hash))
$$;

create function api.mail_admin_snapshot(_environment text,_actor uuid,_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.assert_mail_admin(_actor,_event_slug);
 select jsonb_build_object('revision',h.revision,'active',(select to_jsonb(c) from app_private.mail_config_versions c where c.id=h.active_id),
 'draft',(select to_jsonb(c) from app_private.mail_config_versions c where c.id=h.draft_id),'draftTestVerified',app_private.mail_config_test_verified(_environment,h.draft_id,h.check_result->>'credentialHash',h.check_result->>'webhookKeyHash'),
 'checkedAt',h.checked_at,'checkedId',h.checked_id,'checkResult',h.check_result,'suppressionsImportedAt',h.suppressions_imported_at,
 'lastWebhookAt',(select max(received_at) from app_private.email_events where provider='resend' and environment=_environment),
 'lastTest',(select jsonb_build_object('status',status,'deliveryStatus',delivery_status,'code',error_code,'at',first_attempt_at,'providerId',provider_id,'configId',config_id,'simulated',coalesce(payload->'to'->>0 like '%@resend.dev',false)) from app_private.mail_envelopes where environment=_environment and channel='test' order by first_attempt_at desc limit 1),
 'attempts',coalesce((select jsonb_agg(v) from (select id,channel,message_type,provider,provider_id,config_id,status,delivery_status,error_code,first_attempt_at,accepted_at,delivered_at,complained_at from app_private.mail_envelopes where environment=_environment order by first_attempt_at desc limit 50) v),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(v) from (select ev.provider,ev.provider_event_id,ev.provider_message_id,ev.outbox_id,ev.kind,ev.occurred_at,ev.received_at,ev.safe_code,m.channel,m.message_type from app_private.email_events ev left join app_private.mail_envelopes m on m.provider=ev.provider and m.environment=ev.environment and m.provider_id=ev.provider_message_id and m.recipient_hash=ev.recipient_hash where ev.environment=_environment or (ev.provider='sendgrid' and ev.environment is null) order by ev.received_at desc limit 50) v),'[]'::jsonb),
 'legacyReconciliation',(select count(*) from app_private.email_outbox where provider='sendgrid' and status in ('processing','unknown','deferred')))
 into result from app_private.mail_config_heads h where environment=_environment;
 return result;
end $$;

create function api.mail_admin_command(_environment text,_actor uuid,_event_slug text,_command text,_expected_revision integer,_config_id uuid default null,_draft jsonb default null,_check jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare h app_private.mail_config_heads; c app_private.mail_config_versions; next_version integer; hash text;
begin
 perform app_private.assert_mail_admin(_actor,_event_slug);
 select * into h from app_private.mail_config_heads where environment=_environment for update;
 if h.environment is null then raise exception 'MAIL_CONFIG_NOT_BOOTSTRAPPED';end if;
 if h.revision<>_expected_revision then raise exception 'CONFIG_VERSION_CONFLICT' using errcode='40001';end if;
 if _command='save' then
  if _draft->>'provider'<>'resend' or length(coalesce(_draft->>'fromName','')) not between 1 and 120 then raise exception 'INVALID_CONFIG';end if;
  select coalesce(max(version),0)+1 into next_version from app_private.mail_config_versions where environment=_environment;
  hash:=encode(extensions.digest(_draft::text,'sha256'),'hex');
  insert into app_private.mail_config_versions(environment,version,provider,from_email,from_name,reply_to,config_hash)
  values(_environment,next_version,'resend',lower(trim(_draft->>'fromEmail')),trim(_draft->>'fromName'),lower(trim(_draft->>'replyTo')),hash) returning * into c;
  update app_private.mail_config_heads set draft_id=c.id,revision=revision+1,checked_id=null,checked_at=null,check_result=null where environment=_environment;
 elsif _command='check' then
  if _config_id is distinct from coalesce(h.draft_id,h.active_id) then raise exception 'CONFIG_VERSION_CONFLICT' using errcode='40001';end if;
  update app_private.mail_config_heads set checked_id=_config_id,checked_at=clock_timestamp(),check_result=_check where environment=_environment;
 elsif _command='activate' then
  if _config_id is distinct from h.draft_id or h.checked_id is distinct from h.draft_id or h.checked_at<clock_timestamp()-interval '10 minutes' or (_check->>'confirmed') is distinct from 'true' then raise exception 'CONFIG_CHECK_REQUIRED';end if;
  select * into c from app_private.mail_config_versions where id=h.draft_id;
  if h.check_result->>'configHash' is distinct from c.config_hash or h.check_result->>'ready' is distinct from 'true' then raise exception 'CONFIG_CHECK_REQUIRED';end if;
  if h.suppressions_imported_at is null then raise exception 'SUPPRESSION_IMPORT_REQUIRED';end if;
  if not app_private.mail_config_test_verified(_environment,c.id,h.check_result->>'credentialHash',h.check_result->>'webhookKeyHash') then raise exception 'VERIFIED_DRAFT_TEST_REQUIRED';end if;
  -- Existing unknown SendGrid attempts remain pinned, visible and unclaimable.
  update app_private.mail_config_heads set active_id=draft_id,draft_id=null,revision=revision+1 where environment=_environment;
 else raise exception 'UNKNOWN_MAIL_COMMAND';end if;
 if _command in ('save','activate') then
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
 select id,_actor,'mail.config.'||_command,'mail_config',jsonb_build_object('environment',_environment,'configId',c.id,'version',c.version) from app_private.events where slug=_event_slug;
 end if;
 return api.mail_admin_snapshot(_environment,_actor,_event_slug);
end $$;

create function api.worker_mail_bootstrap(_environment text,_from_email text,_from_name text,_reply_to text) returns void
language plpgsql security definer set search_path='' as $$
declare c uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('mail-bootstrap:'||_environment,0));
 if exists(select 1 from app_private.mail_config_heads where environment=_environment) then return;end if;
 insert into app_private.mail_config_versions(environment,version,provider,from_email,from_name,reply_to,config_hash)
 values(_environment,1,'sendgrid',_from_email,_from_name,_reply_to,encode(extensions.digest(jsonb_build_array(_from_email,_from_name,_reply_to,'sendgrid')::text,'sha256'),'hex')) returning id into c;
 insert into app_private.mail_config_heads(environment,active_id) values(_environment,c);
 -- Existing local editorial suppressions remain effective for all new mail.
 insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider,transactional_blocked)
 select _environment,email_hash,reason,'sendgrid',reason not in ('unsubscribe','group_unsubscribe') from app_private.editorial_suppressions on conflict do nothing;
 insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider)
 select distinct _environment,extensions.digest(lower(trim(o.recipient_email)),'sha256'),case when bool_or(ev.kind='spamreport') then 'spamreport' else 'bounce' end,'sendgrid' from app_private.email_events ev join app_private.email_outbox o on o.id=ev.outbox_id where ev.provider='sendgrid' and ev.kind in ('bounce','spamreport') group by lower(trim(o.recipient_email)) on conflict(environment,recipient_hash) do update set reason=case when app_private.mail_suppressions.transactional_blocked and not excluded.transactional_blocked then app_private.mail_suppressions.reason else excluded.reason end,transactional_blocked=app_private.mail_suppressions.transactional_blocked or excluded.transactional_blocked;
end $$;

create function api.worker_import_mail_suppressions(_environment text,_entries jsonb,_source_hash text,_complete boolean default false) returns integer
language plpgsql security definer set search_path='' as $$
declare count integer;
begin
 if _source_hash!~'^[a-f0-9]{64}$' or jsonb_array_length(_entries)>1000 then raise exception 'INVALID_IMPORT';end if;
 insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider,transactional_blocked)
 select _environment,decode(entry->>'emailHash','hex'),entry->>'reason','sendgrid',(entry->>'reason')<>'unsubscribe' from jsonb_array_elements(_entries) entry
 where entry->>'emailHash' ~ '^[a-f0-9]{64}$' and entry->>'reason' in ('bounce','spamreport','unsubscribe','invalid')
 on conflict(environment,recipient_hash) do update set reason=case when app_private.mail_suppressions.transactional_blocked and not excluded.transactional_blocked then app_private.mail_suppressions.reason else excluded.reason end,transactional_blocked=app_private.mail_suppressions.transactional_blocked or excluded.transactional_blocked;
 get diagnostics count=row_count;
 if _complete then update app_private.mail_config_heads set suppressions_imported_at=clock_timestamp(),suppression_import_hash=_source_hash where environment=_environment;end if;
 return count;
end $$;

-- Explicit grants for only the functions introduced here; private helpers remain
-- inaccessible even to service_role except through the controlled entry points.
do $$ declare f record;
begin
 for f in select p.oid::regprocedure as signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where
 (n.nspname='api' and p.proname in ('worker_mail_config','worker_mail_prepare','worker_mail_finish','worker_store_resend_event','worker_claim_outbox','worker_update_outbox','worker_store_email_event','mail_admin_snapshot','mail_admin_command','worker_mail_bootstrap','worker_import_mail_suppressions')) or
 (n.nspname='app_private' and p.proname in ('project_resend_events','mail_acceptance_guard','assert_mail_admin','mail_config_test_verified')) loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
 if f.nspname='api' then execute format('grant execute on function %s to service_role',f.signature);end if;
 end loop;
end $$;

create function api.mail_admin_test(_environment text,_actor uuid,_event_slug text,_expected_revision integer,_recipient text,_command_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare h app_private.mail_config_heads; existing uuid; receipt app_private.command_receipts; request_hash text;
begin
 perform app_private.assert_mail_admin(_actor,_event_slug);
 perform pg_advisory_xact_lock(hashtextextended('mail-test:'||_environment||':'||lower(_recipient),0));
 select * into h from app_private.mail_config_heads where environment=_environment for update;
 if h.revision<>_expected_revision or (select provider from app_private.mail_config_versions where id=coalesce(h.draft_id,h.active_id))<>'resend' then raise exception 'CONFIG_VERSION_CONFLICT';end if;
 if h.draft_id is not null and (h.checked_id is distinct from h.draft_id or h.check_result->>'ready' is distinct from 'true') then raise exception 'DRAFT_CHECK_REQUIRED';end if;
 request_hash:=encode(extensions.digest(jsonb_build_array(_environment,coalesce(h.draft_id,h.active_id),lower(_recipient))::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=_actor and command_type='mail.test' and idempotency_key=_command_key;
 if receipt.id is not null then
  if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  return (receipt.safe_result->>'outboxId')::uuid;
 end if;
 -- Coalesce simultaneous tabs/double clicks for the same configuration and
 -- recipient. A later intentional test after ten minutes is a new command.
 select id into existing from app_private.email_outbox where message_type='mail_provider_test' and recipient_email=lower(_recipient)
 and payload->>'configId'=coalesce(h.draft_id,h.active_id)::text and created_at>clock_timestamp()-interval '10 minutes' order by created_at desc limit 1;
 if existing is null then
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  values('mail-test:'||gen_random_uuid(),'mail_provider_test',_actor::text,lower(_recipient),jsonb_build_object('configId',coalesce(h.draft_id,h.active_id),'environment',_environment,'simulated',lower(_recipient) like '%@resend.dev')) returning id into existing;
 end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(_actor,'mail.test',_command_key,request_hash,jsonb_build_object('outboxId',existing),clock_timestamp()+interval '30 days');
 return existing;
end $$;
revoke all on function api.mail_admin_test(text,uuid,text,integer,text,text) from public,anon,authenticated;
grant execute on function api.mail_admin_test(text,uuid,text,integer,text,text) to service_role;

create function api.worker_mail_diagnostics(_environment text,_event_id text default null) returns jsonb
language sql security definer set search_path='' as $$
 select jsonb_build_object('eventLinked',exists(select 1 from app_private.email_events ev join app_private.mail_envelopes e on e.provider=ev.provider and e.environment=ev.environment and e.provider_id=ev.provider_message_id and e.recipient_hash=ev.recipient_hash where ev.provider='resend' and ev.environment=_environment and ev.provider_event_id=_event_id),'lastWebhookAt',(select max(received_at) from app_private.email_events where provider='resend' and environment=_environment),
 'unknownCount',(select count(*) from app_private.mail_envelopes where environment=_environment and status in ('unknown','reconcile')),
 'deliveryCounts',(select coalesce(jsonb_object_agg(delivery_status,n),'{}') from (select delivery_status,count(*) n from app_private.mail_envelopes where environment=_environment group by delivery_status) x))
$$;
revoke all on function api.worker_mail_diagnostics(text,text) from public,anon,authenticated;
grant execute on function api.worker_mail_diagnostics(text,text) to service_role;

-- Explicit incident rollback changes only the provider for future envelopes.
-- In-flight Resend/SendGrid attempts retain their original provider and key.
create function api.mail_admin_rollback(_environment text,_actor uuid,_event_slug text,_expected_revision integer,_confirmed boolean,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare h app_private.mail_config_heads; legacy uuid;
begin
 perform app_private.assert_mail_admin(_actor,_event_slug);
 if _confirmed is not true or length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'CONFIRMATION_REQUIRED';end if;
 select * into h from app_private.mail_config_heads where environment=_environment for update;
 if h.revision is distinct from _expected_revision then raise exception 'CONFIG_VERSION_CONFLICT' using errcode='40001';end if;
 select id into legacy from app_private.mail_config_versions where environment=_environment and provider='sendgrid' order by version desc limit 1;
 if legacy is null then raise exception 'LEGACY_CONFIG_MISSING';end if;
 update app_private.mail_config_heads set active_id=legacy,revision=revision+1,checked_id=null,checked_at=null,check_result=null where environment=_environment;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
 select id,_actor,'mail.config.rollback','mail_config',jsonb_build_object('environment',_environment,'configId',legacy,'reason',trim(_reason)) from app_private.events where slug=_event_slug;
 return api.mail_admin_snapshot(_environment,_actor,_event_slug);
end $$;
revoke all on function api.mail_admin_rollback(text,uuid,text,integer,boolean,text) from public,anon,authenticated;
grant execute on function api.mail_admin_rollback(text,uuid,text,integer,boolean,text) to service_role;
