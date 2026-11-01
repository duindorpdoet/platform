-- A separate, intentional organization campaign. Applying this migration sends
-- nothing and does not alter existing thanks, visits, mail or provider outcomes.
set lock_timeout='5s';

create table app_private.portal_certificate_campaigns(
 id uuid primary key default gen_random_uuid(),event_id uuid not null unique references app_private.event_closures(event_id),
 created_at timestamptz not null default clock_timestamp(),created_by uuid not null references auth.users(id),command_id uuid not null,
 subject text not null check(app_private.event_evening_text_valid(subject,200)and position(chr(10)in subject)=0 and position(chr(13)in subject)=0),
 body text not null check(app_private.event_evening_text_valid(body,20000)),recipient_counts jsonb not null
);
create table app_private.portal_certificate_accounts(
 campaign_id uuid not null references app_private.portal_certificate_campaigns(id),account_id uuid not null references auth.users(id),
 normalized_email text not null check(normalized_email=lower(trim(normalized_email))),portal_ids uuid[] not null check(cardinality(portal_ids)>0),
 primary key(campaign_id,account_id)
);
create table app_private.portal_certificate_recipients(
 campaign_id uuid not null references app_private.portal_certificate_campaigns(id),normalized_email text not null check(normalized_email=lower(trim(normalized_email))),
 created_at timestamptz not null default clock_timestamp(),outbox_id uuid unique references app_private.email_outbox(id),queued_at timestamptz,suppressed_at timestamptz,
 primary key(campaign_id,normalized_email)
);
create index portal_certificate_pending on app_private.portal_certificate_recipients(created_at,campaign_id)where outbox_id is null and suppressed_at is null;
create function app_private.portal_certificate_immutable()returns trigger language plpgsql set search_path=''as $$
begin raise exception 'CERTIFICATE_CAMPAIGN_IMMUTABLE'using errcode='23514';end $$;
create trigger portal_certificate_immutable before update or delete on app_private.portal_certificate_campaigns for each row execute function app_private.portal_certificate_immutable();
create trigger portal_certificate_immutable before update or delete on app_private.portal_certificate_accounts for each row execute function app_private.portal_certificate_immutable();
do $$declare t text;begin
 foreach t in array array['portal_certificate_campaigns','portal_certificate_accounts','portal_certificate_recipients']loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function app_private.portal_certificate_candidates(_event uuid)
returns table(account_id uuid,portal_id uuid,normalized_email text,eligible boolean)
language sql stable security invoker set search_path=''as $$
 select o.user_id,o.portal_id,lower(trim(u.email)),app_private.event_portal_mail_recipient(o.portal_id,o.user_id)
 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id and p.event_id=_event
 join auth.users u on u.id=o.user_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())
 where app_private.event_house_thanks_active_portal(p.id)and o.role in('owner','portal_manager','coadmin','crew','actor','reception','tech')
 and o.accepted_at is not null and o.revoked_at is null and o.suspended_at is null
$$;
create function app_private.portal_certificate_counts(_event uuid)returns jsonb
language sql stable security invoker set search_path=''as $$
 with candidates as materialized(select *from app_private.portal_certificate_candidates(_event))
 select jsonb_build_object('participatingHouses',(select count(*)from app_private.portals p where p.event_id=_event and app_private.event_house_thanks_active_portal(p.id)),
 'teamAccounts',(select count(distinct account_id)from candidates),'uniqueEmailRecipients',(select count(distinct normalized_email)from candidates where eligible),
 'missingContactAccounts',(select count(*)from(select account_id from candidates group by account_id having not bool_or(eligible))missing))
$$;
create function app_private.portal_certificate_recipient_available(_campaign uuid,_email text)returns boolean
language sql stable security invoker set search_path=''as $$
 select exists(select 1 from app_private.portal_certificate_accounts a join app_private.portal_certificate_campaigns c on c.id=a.campaign_id
 cross join lateral unnest(a.portal_ids)pid join app_private.portals p on p.id=pid and p.event_id=c.event_id
 where a.campaign_id=_campaign and a.normalized_email=_email and app_private.event_portal_mail_recipient(p.id,a.account_id,_email))
$$;
create function api.worker_portal_certificate_mail(_outbox_id uuid)returns jsonb
language sql stable security definer set search_path=''as $$
 select jsonb_build_object('eventId',c.event_id,'campaignId',c.id,'subject',c.subject,'body',c.body,'actionPath','/mijn-huis')
 from app_private.portal_certificate_campaigns c join app_private.portal_certificate_recipients r on r.campaign_id=c.id
 join app_private.email_outbox o on o.id=r.outbox_id where o.id=_outbox_id and o.message_type='portal_certificate_ready'
 and lower(trim(o.recipient_email))=r.normalized_email and o.recipient_ref='portal-certificate:'||c.id
 and app_private.portal_certificate_recipient_available(c.id,r.normalized_email)
$$;
create function app_private.portal_certificate_retryable(_outbox uuid)returns boolean
language sql stable security invoker set search_path=''as $$
 select exists(select 1 from app_private.email_outbox o left join app_private.mail_envelopes env on env.outbox_id=o.id
 where o.id=_outbox and o.message_type='portal_certificate_ready'and o.status='failed'and o.accepted_at is null and o.provider_id is null and o.attempts<8
 and api.worker_portal_certificate_mail(o.id)is not null
 and(env.id is null or(env.provider='resend'and env.status='failed'and env.accepted_at is null and env.provider_id is null
 and env.first_attempt_at>statement_timestamp()-interval '23 hours 55 minutes')))
$$;

create function api.portal_certificate_admin_snapshot(_event_slug text)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare e app_private.events;c app_private.portal_certificate_campaigns;counts jsonb;mail jsonb;
begin
 select *into e from app_private.events where slug=_event_slug;
 if auth.uid()is null or e.id is null or not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into c from app_private.portal_certificate_campaigns where event_id=e.id;
 counts:=coalesce(c.recipient_counts,app_private.portal_certificate_counts(e.id));
 select jsonb_build_object('pending',count(*)filter(where r.outbox_id is null and r.suppressed_at is null),
 'queued',count(*)filter(where o.status in('pending','processing','deferred')),
 'processed',count(*)filter(where r.suppressed_at is not null or o.status in('accepted','delivered','failed','suppressed','unknown','validated')),
 'providerAccepted',count(*)filter(where o.accepted_at is not null or env.accepted_at is not null or env.status='accepted'),
 'delivered',count(*)filter(where env.delivered_at is not null or env.delivery_status='delivered' or o.status='delivered'),
 'failed',count(*)filter(where o.status='failed'),'unknown',count(*)filter(where o.status='unknown' or env.status in('unknown','reconcile')),
 'suppressed',count(*)filter(where r.suppressed_at is not null or o.status='suppressed'),
 'retryableFailed',count(*)filter(where app_private.portal_certificate_retryable(o.id)))into mail
 from app_private.portal_certificate_recipients r left join app_private.email_outbox o on o.id=r.outbox_id
 left join app_private.mail_envelopes env on env.outbox_id=o.id where r.campaign_id=c.id;
 return jsonb_build_object('event',jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title),
 'ready',e.phase='completed'and app_private.event_closure_exists(e.id),'confirmed',c.id is not null,
 'campaign',case when c.id is not null then jsonb_build_object('id',c.id,'createdAt',c.created_at,'createdBy',c.created_by,'subject',c.subject,'body',c.body)end,
 'message',case when c.id is not null then jsonb_build_object('subject',c.subject,'body',c.body)end,'counts',counts,'mail',mail);
end $$;

create function api.portal_certificate_confirm(_event_slug text,_subject text,_body text,_command_id uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare e app_private.events;existing uuid;
begin
 select *into e from app_private.events where slug=_event_slug;
 if auth.uid()is null or e.id is null or not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('portal-certificate:'||e.id,0));
 if not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select id into existing from app_private.portal_certificate_campaigns where event_id=e.id;
 if existing is not null then return api.portal_certificate_admin_snapshot(_event_slug)||jsonb_build_object('existing',true);end if;
 select *into e from app_private.events where id=e.id;
 if e.phase<>'completed' or not app_private.event_closure_exists(e.id)then raise exception 'CERTIFICATES_NOT_READY'using errcode='23514';end if;
 if _command_id is null or not app_private.event_evening_text_valid(_subject,200)or position(chr(10)in _subject)>0 or position(chr(13)in _subject)>0
 or not app_private.event_evening_text_valid(_body,20000)then raise exception 'VALIDATION_ERROR'using errcode='22023';end if;
 perform app_private.poortkamer_budget('portal_certificate_confirm',3);
 -- One MVCC source for counts, accounts and deduplicated addresses. Confirm
 -- captures durable targets; it does not enqueue or contact the mail provider.
 with candidates as materialized(select *from app_private.portal_certificate_candidates(e.id)),
 eligible as materialized(select *from candidates where eligible),
 campaign as(insert into app_private.portal_certificate_campaigns(event_id,created_by,command_id,subject,body,recipient_counts)
 select e.id,auth.uid(),_command_id,_subject,_body,jsonb_build_object(
  'participatingHouses',(select count(*)from app_private.portals p where p.event_id=e.id and app_private.event_house_thanks_active_portal(p.id)),
  'teamAccounts',(select count(distinct account_id)from candidates),'uniqueEmailRecipients',(select count(distinct normalized_email)from eligible),
  'missingContactAccounts',(select count(*)from(select account_id from candidates group by account_id having not bool_or(eligible))missing))returning id),
 accounts as(insert into app_private.portal_certificate_accounts(campaign_id,account_id,normalized_email,portal_ids)
 select campaign.id,eligible.account_id,eligible.normalized_email,array_agg(distinct eligible.portal_id order by eligible.portal_id)
 from campaign cross join eligible group by campaign.id,eligible.account_id,eligible.normalized_email returning campaign_id)
 insert into app_private.portal_certificate_recipients(campaign_id,normalized_email)
 select distinct campaign.id,eligible.normalized_email from campaign cross join eligible;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
 values(e.id,auth.uid(),'portal_certificate.confirm','portal_certificate_campaign',jsonb_build_object('messageVersion',1));
 return api.portal_certificate_admin_snapshot(_event_slug)||jsonb_build_object('existing',false);
end $$;

create function api.worker_portal_certificates(_limit integer default 25)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r app_private.portal_certificate_recipients;c app_private.portal_certificate_campaigns;oid uuid;processed integer:=0;suppressed integer:=0;
begin
 if _limit is null or _limit<1 or _limit>25 then raise exception 'INVALID_INPUT'using errcode='22023';end if;
 for r in select *from app_private.portal_certificate_recipients where outbox_id is null and suppressed_at is null order by created_at,campaign_id,normalized_email limit _limit for update skip locked loop
  if not app_private.portal_certificate_recipient_available(r.campaign_id,r.normalized_email)then
   update app_private.portal_certificate_recipients set suppressed_at=clock_timestamp()where campaign_id=r.campaign_id and normalized_email=r.normalized_email;
   suppressed:=suppressed+1;
  else
   select *into c from app_private.portal_certificate_campaigns where id=r.campaign_id;oid:=null;
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('portal-certificate:'||c.id||':'||encode(extensions.digest(r.normalized_email,'sha256'),'hex'),'portal_certificate_ready',
    'portal-certificate:'||c.id,r.normalized_email,jsonb_build_object('eventId',c.event_id,'campaignId',c.id,'subject',c.subject,'body',c.body,'actionPath','/mijn-huis'))
   on conflict(dedupe_key)do nothing returning id into oid;
   if oid is null then select id into oid from app_private.email_outbox where dedupe_key='portal-certificate:'||c.id||':'||encode(extensions.digest(r.normalized_email,'sha256'),'hex');end if;
   update app_private.portal_certificate_recipients set outbox_id=oid,queued_at=clock_timestamp()where campaign_id=r.campaign_id and normalized_email=r.normalized_email;
  end if;
  processed:=processed+1;
 end loop;
 return jsonb_build_object('processed',processed,'suppressed',suppressed,'remaining',(select count(*)from app_private.portal_certificate_recipients where outbox_id is null and suppressed_at is null));
end $$;
create function api.portal_certificate_retry_failed(_event_slug text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare e uuid;n integer:=0;candidate uuid;
begin
 select id into e from app_private.events where slug=_event_slug;
 if auth.uid()is null or e is null or not app_private.has_capability(e,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform app_private.poortkamer_budget('portal_certificate_retry_failed',10);
 for candidate in select o.id from app_private.portal_certificate_campaigns c join app_private.portal_certificate_recipients r on r.campaign_id=c.id
 join app_private.email_outbox o on o.id=r.outbox_id where c.event_id=e and app_private.portal_certificate_retryable(o.id)
 order by o.created_at,o.id limit 100 loop
  if app_private.event_evening_retry_outbox(candidate)then n:=n+1;end if;
 end loop;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
 values(e,auth.uid(),'portal_certificate.retry_failed','portal_certificate_campaign',jsonb_build_object('requeued',n));
 return api.portal_certificate_admin_snapshot(_event_slug)||jsonb_build_object('requeued',n);
end $$;

-- Retain the existing gateway lease/idempotency boundary for every mail type.
-- Unavailable recipients never turn an accepted/unknown outcome into a resend.
create or replace function api.worker_mail_prepare(_environment text,_key text,_config_id uuid,_outbox_id uuid,_channel text,_message_type text,_recipient text,_payload jsonb,_payload_hash text,_credential_hash text)returns jsonb
language plpgsql security definer set search_path=''as $$
begin
 if ((_message_type='house_thanks_received'and api.worker_house_thanks_mail(_outbox_id)is null)
  or(_message_type='event_closure_thanks'and api.worker_event_closure_mail(_outbox_id)is null)
  or(_message_type='portal_certificate_ready'and api.worker_portal_certificate_mail(_outbox_id)is null))
  and not exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status='accepted')then
  return jsonb_build_object('dispatch',false,'status',case when exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status in('unknown','reconcile'))then 'reconcile'else 'failed'end,
   'error_code',case _message_type when 'event_closure_thanks'then 'EVENT_CLOSURE_RECIPIENT_UNAVAILABLE'when 'portal_certificate_ready'then 'PORTAL_CERTIFICATE_RECIPIENT_UNAVAILABLE'else 'HOUSE_THANKS_RECIPIENT_UNAVAILABLE'end);
 end if;
 if _message_type='duinpad_evening_thanks'and exists(select 1 from app_private.email_outbox o join app_private.event_closures c on c.event_id=(o.payload->>'eventId')::uuid where o.id=_outbox_id)
  and not exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status='accepted')then
  return jsonb_build_object('dispatch',false,'status',case when exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status in('unknown','reconcile'))then 'reconcile'else 'failed'end,'error_code','EVENT_CENTRALLY_CLOSED');
 end if;
 return api.worker_mail_prepare_before_house_thanks(_environment,_key,_config_id,_outbox_id,_channel,_message_type,_recipient,_payload,_payload_hash,_credential_hash);
end $$;
create or replace function api.worker_update_outbox_v2(_id uuid,_status text,_provider_id text default null,_error_code text default null,_next_attempt_at timestamptz default null)returns void
language plpgsql security definer set search_path=''as $$
declare o app_private.email_outbox;e app_private.mail_envelopes;
begin
 if _status='suppressed'then
  select *into o from app_private.email_outbox where id=_id for update;
  if o.message_type in('event_closure_thanks','house_thanks_received','portal_certificate_ready')then
   select *into e from app_private.mail_envelopes where outbox_id=_id;
   if o.status in('accepted','delivered')or o.accepted_at is not null then return;end if;
   if e.status='accepted'then
    perform api.worker_update_outbox_v2_before_house_thanks(_id,case when e.delivered_at is not null then 'delivered'else 'accepted'end,e.provider_id,null,null);return;
   end if;
   if e.status in('unknown','reconcile')then
    update app_private.email_outbox set status='unknown',last_error_code='EVENING_RECIPIENT_UNAVAILABLE_RECONCILE',lease_until=null where id=_id;return;
   end if;
  end if;
 end if;
 perform api.worker_update_outbox_v2_before_house_thanks(_id,_status,_provider_id,_error_code,_next_attempt_at);
end $$;

revoke all on function app_private.portal_certificate_immutable(),app_private.portal_certificate_candidates(uuid),app_private.portal_certificate_counts(uuid),app_private.portal_certificate_recipient_available(uuid,text),app_private.portal_certificate_retryable(uuid)from public,anon,authenticated,service_role;
revoke all on function api.portal_certificate_admin_snapshot(text),api.portal_certificate_confirm(text,text,text,uuid),api.portal_certificate_retry_failed(text),api.worker_portal_certificates(integer),api.worker_portal_certificate_mail(uuid)from public,anon,authenticated,service_role;
grant execute on function api.portal_certificate_admin_snapshot(text),api.portal_certificate_confirm(text,text,text,uuid),api.portal_certificate_retry_failed(text)to authenticated;
grant execute on function api.worker_portal_certificates(integer),api.worker_portal_certificate_mail(uuid)to service_role;
-- CREATE OR REPLACE preserves the two pre-existing service-only gateway ACLs.
notify pgrst,'reload schema';
