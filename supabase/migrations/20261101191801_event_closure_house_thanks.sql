-- Explicit post-event thanks are separate from historical reached-gate reactions.
-- Applying this migration closes nothing and creates no messages or mail.
set lock_timeout='5s';
create table app_private.event_house_thanks (
 id uuid primary key default gen_random_uuid(),event_id uuid not null references app_private.event_closures(event_id),
 household_id uuid not null references app_private.households(id),kind text not null check(kind in('all','personal')),
 portal_id uuid references app_private.portals(id),choice text check(choice in('beautiful','welcome','treats')),
 message text not null default '' check(char_length(message)<=500),created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 check((kind='all' and portal_id is null and choice is null) or(kind='personal' and portal_id is not null and choice is not null)),
 unique nulls not distinct(event_id,household_id,kind,portal_id)
);
create table app_private.event_house_thanks_requests(
 event_id uuid not null,household_id uuid not null,request_key uuid not null,payload_hash bytea not null,
 submission_id uuid not null references app_private.event_house_thanks(id),primary key(event_id,household_id,request_key)
);
-- These immutable target rows are the durable fan-out queue, atomically inserted
-- with a new submission. A rollback cannot acknowledge a partially queued thanks.
create table app_private.event_house_thanks_targets(
 submission_id uuid not null references app_private.event_house_thanks(id),portal_id uuid not null references app_private.portals(id),
 processed_at timestamptz,primary key(submission_id,portal_id)
);
create index event_house_thanks_targets_pending on app_private.event_house_thanks_targets(submission_id,portal_id) where processed_at is null;
create table app_private.event_house_thanks_receipts(
 id uuid primary key default gen_random_uuid(),submission_id uuid not null references app_private.event_house_thanks(id),
 event_id uuid not null references app_private.events(id),portal_id uuid not null references app_private.portals(id),
 received_at timestamptz not null default now(),missing_contacts integer not null default 0,
 contacts_checked_at timestamptz,unique(submission_id,portal_id)
);
create index event_house_thanks_receipts_portal on app_private.event_house_thanks_receipts(event_id,portal_id,received_at desc,id desc);
create index event_house_thanks_contact_repair on app_private.event_house_thanks_receipts(contacts_checked_at) where missing_contacts>0;
create table app_private.event_house_thanks_reads(
 receipt_id uuid not null references app_private.event_house_thanks_receipts(id),account_id uuid not null references auth.users(id),
 read_at timestamptz not null default now(),primary key(receipt_id,account_id)
);
create table app_private.event_house_thanks_mail_recipients(
 receipt_id uuid not null references app_private.event_house_thanks_receipts(id),recipient_email text not null,
 outbox_id uuid not null references app_private.email_outbox(id),created_at timestamptz not null default now(),
 primary key(receipt_id,recipient_email),check(recipient_email=lower(trim(recipient_email)))
);
do $$declare t text;begin foreach t in array array['event_house_thanks','event_house_thanks_requests','event_house_thanks_targets','event_house_thanks_receipts','event_house_thanks_reads','event_house_thanks_mail_recipients'] loop
 execute format('alter table app_private.%I enable row level security',t);
 execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',t);
end loop;end $$;

create function api.portal_thanks_closed_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;homeid uuid;begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or not app_private.event_closure_exists(eid) then return jsonb_build_object('closed',false);end if;
 homeid:=app_private.event_closure_household(eid,auth.uid());
 if homeid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return jsonb_build_object('closed',true,'finished',true,
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.portal_id,'name',p.portal_name,'world',p.world_name) order by p.portal_name,p.portal_id) from app_private.event_closure_portals p where p.event_id=eid),'[]'::jsonb),
 'submissions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'kind',s.kind,'portalId',s.portal_id,'choice',s.choice,'message',s.message,'createdAt',s.created_at,'updatedAt',s.updated_at,
 'targetCount',(select count(*)from app_private.event_house_thanks_targets t where t.submission_id=s.id),'processedCount',(select count(*)from app_private.event_house_thanks_targets t where t.submission_id=s.id and t.processed_at is not null)) order by s.created_at,s.id) from app_private.event_house_thanks s where s.event_id=eid and s.household_id=homeid),'[]'::jsonb),
 'saved',coalesce((select jsonb_agg(jsonb_build_object('portalId',t.portal_id,'choice',t.choice)) from app_private.portal_thanks t where t.event_id=eid and t.household_id=homeid),'[]'::jsonb));
end $$;

create function api.portal_thanks_closed_save(_event_slug text,_kind text,_portal_id uuid,_choice text,_message text,_request_key uuid,_submission_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid;homeid uuid;s app_private.event_house_thanks;prior app_private.event_house_thanks_requests;fingerprint bytea;body text:=btrim(coalesce(_message,''));begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select id into eid from app_private.events where slug=_event_slug;
 homeid:=app_private.event_closure_household(eid,auth.uid());
 if homeid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _request_key is null or _kind is null or _kind not in('all','personal') or char_length(body)>500
 or (_kind='all' and(_portal_id is not null or _choice is not null))
 or (_kind='personal' and(_portal_id is null or _choice is null or _choice not in('beautiful','welcome','treats')))
 then raise exception 'INVALID_INPUT' using errcode='22023';end if;
 if _kind='personal' and not exists(select 1 from app_private.event_closure_portals where event_id=eid and portal_id=_portal_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 fingerprint:=extensions.digest(jsonb_build_array(_kind,_portal_id,_choice,body,_submission_id)::text,'sha256');
 -- Household-local serialization makes two adults/tabs share the same boundary.
 perform pg_advisory_xact_lock(hashtextextended('event-house-thanks:'||eid||':'||homeid,0));
 select *into prior from app_private.event_house_thanks_requests where event_id=eid and household_id=homeid and request_key=_request_key;
 if prior.submission_id is not null then
  if prior.payload_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23514';end if;
  return jsonb_build_object('ok',true,'id',prior.submission_id,'duplicate',true);
 end if;
 perform app_private.poortkamer_budget('event_house_thanks',15);
 if _submission_id is not null then
  select *into s from app_private.event_house_thanks where id=_submission_id and event_id=eid and household_id=homeid and kind=_kind and portal_id is not distinct from _portal_id for update;
  if s.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  update app_private.event_house_thanks set message=body,choice=_choice,updated_at=now() where id=s.id;
 else
  select *into s from app_private.event_house_thanks where event_id=eid and household_id=homeid and kind=_kind and portal_id is not distinct from _portal_id;
  if s.id is null then
   insert into app_private.event_house_thanks(event_id,household_id,kind,portal_id,choice,message,created_by) values(eid,homeid,_kind,_portal_id,_choice,body,auth.uid()) returning *into s;
   insert into app_private.event_house_thanks_targets(submission_id,portal_id) select s.id,p.portal_id from app_private.event_closure_portals p where p.event_id=eid and(_kind='all' or p.portal_id=_portal_id);
  end if;
 end if;
 insert into app_private.event_house_thanks_requests(event_id,household_id,request_key,payload_hash,submission_id) values(eid,homeid,_request_key,fingerprint,s.id);
 return jsonb_build_object('ok',true,'id',s.id,'edited',_submission_id is not null);
end $$;

-- Legacy reached-gate reactions remain visible and editable while the event is
-- open. Old cached clients cannot silently create a different type after closure.
alter function api.portal_thanks_snapshot(text,text,uuid) rename to portal_thanks_snapshot_before_event_close;
create function api.portal_thanks_snapshot(_event_slug text,_scope text default 'family',_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid;begin
 select id into eid from app_private.events where slug=_event_slug;
 if _scope='family' and app_private.event_closure_exists(eid) then return api.portal_thanks_closed_snapshot(_event_slug);end if;
 return api.portal_thanks_snapshot_before_event_close(_event_slug,_scope,_portal_id);
end $$;
alter function api.portal_thanks_save(text,uuid,text) rename to portal_thanks_save_before_event_close;
create function api.portal_thanks_save(_event_slug text,_portal_id uuid,_choice text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from app_private.events e join app_private.event_closures c on c.event_id=e.id where e.slug=_event_slug) then raise exception 'CLOSED_THANKS_REQUIRED' using errcode='23514';end if;
 return api.portal_thanks_save_before_event_close(_event_slug,_portal_id,_choice);
end $$;

create function app_private.event_house_thanks_can_read(_event uuid,_portal uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id join auth.users u on u.id=o.user_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null
 where p.event_id=_event and p.id=_portal and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null)
$$;
create function api.portal_thanks_inbox(_event_slug text,_portal_id uuid default null,_before uuid default null,_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;pid uuid:=_portal_id;anchor app_private.event_house_thanks_receipts;result jsonb;begin
 select id into eid from app_private.events where slug=_event_slug;
 if pid is null then select p.id into pid from app_private.portals p join app_private.portal_owners o on o.portal_id=p.id where p.event_id=eid and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null order by p.system_code limit 1;end if;
 if not app_private.event_house_thanks_can_read(eid,pid) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _limit is null or _limit<1 or _limit>25 then raise exception 'INVALID_INPUT' using errcode='22023';end if;
 if _before is not null then select *into anchor from app_private.event_house_thanks_receipts where id=_before and event_id=eid and portal_id=pid;
  if anchor.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 end if;
 with page as(select r.*,s.kind,s.choice,s.message from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id
 where r.event_id=eid and r.portal_id=pid and(_before is null or(r.received_at,r.id)<(anchor.received_at,anchor.id)) order by r.received_at desc,r.id desc limit _limit+1),
 visible as(select *from page order by received_at desc,id desc limit _limit)
 select jsonb_build_object('portalId',pid,'portalName',(select name from app_private.portals where id=pid),
 'total',(select count(*)from app_private.event_house_thanks_receipts where event_id=eid and portal_id=pid),
 'unread',(select count(*)from app_private.event_house_thanks_receipts r where r.event_id=eid and r.portal_id=pid and not exists(select 1 from app_private.event_house_thanks_reads d where d.receipt_id=r.id and d.account_id=auth.uid())),
 'messages',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'kind',v.kind,'choice',v.choice,'message',v.message,'senderLabel','Een gezin uit Duindorp','receivedAt',v.received_at,
 'read',exists(select 1 from app_private.event_house_thanks_reads d where d.receipt_id=v.id and d.account_id=auth.uid()),
 'missingContacts',v.missing_contacts,'mailCounts',coalesce((select jsonb_object_agg(x.status,x.n)from(select o.status::text status,count(*)n from app_private.event_house_thanks_mail_recipients m join app_private.email_outbox o on o.id=m.outbox_id where m.receipt_id=v.id group by o.status)x),'{}'::jsonb),
 'mailStatus',case when v.missing_contacts>0 then 'missing_contact' when exists(select 1 from app_private.event_house_thanks_mail_recipients m join app_private.email_outbox o on o.id=m.outbox_id where m.receipt_id=v.id and o.status in('failed','suppressed','unknown')) then 'attention' else 'queued_or_processed' end) order by v.received_at desc,v.id desc)from visible v),'[]'::jsonb),
 'nextCursor',case when(select count(*)from page)>_limit then(select id from visible order by received_at,id limit 1)else null end)into result;
 return result;
end $$;
create function api.portal_thanks_read(_event_slug text,_receipt_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.event_house_thanks_receipts;begin
 select x.*into r from app_private.event_house_thanks_receipts x join app_private.events e on e.id=x.event_id where x.id=_receipt_id and e.slug=_event_slug;
 if r.id is null or not app_private.event_house_thanks_can_read(r.event_id,r.portal_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 insert into app_private.event_house_thanks_reads(receipt_id,account_id)values(r.id,auth.uid())on conflict do nothing;
 return jsonb_build_object('ok',true);
end $$;

create function app_private.event_house_thanks_queue_mail(_receipt uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare r app_private.event_house_thanks_receipts;s app_private.event_house_thanks;recipient record;oid uuid;queued integer:=0;payload jsonb;begin
 select *into r from app_private.event_house_thanks_receipts where id=_receipt for update;
 select *into s from app_private.event_house_thanks where id=r.submission_id;
 payload:=jsonb_build_object('receiptId',r.id,'eventId',r.event_id,'portalId',r.portal_id,'portalName',(select portal_name from app_private.event_closure_portals where event_id=r.event_id and portal_id=r.portal_id),
 'kind',s.kind,'choice',s.choice,'message',s.message,'senderLabel','Een gezin uit Duindorp','portalRoomPath','/mijn-huis');
 for recipient in select distinct lower(trim(u.email))email from app_private.portal_owners o join auth.users u on u.id=o.user_id where o.portal_id=r.portal_id and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null and coalesce(u.email,'')~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$' loop
  if not exists(select 1 from app_private.event_house_thanks_mail_recipients m where m.receipt_id=r.id and m.recipient_email=recipient.email)then
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('house-thanks:'||r.id||':'||encode(extensions.digest(recipient.email,'sha256'),'hex'),'house_thanks_received',r.id::text,recipient.email,payload)
   on conflict(dedupe_key)do nothing returning id into oid;
   if oid is null then select id into oid from app_private.email_outbox where dedupe_key='house-thanks:'||r.id||':'||encode(extensions.digest(recipient.email,'sha256'),'hex');end if;
   insert into app_private.event_house_thanks_mail_recipients(receipt_id,recipient_email,outbox_id)values(r.id,recipient.email,oid)on conflict do nothing;
   queued:=queued+1;
  end if;
 end loop;
 update app_private.event_house_thanks_receipts set contacts_checked_at=clock_timestamp(),missing_contacts=(select case when count(*)=0 then 1 else count(*)filter(where u.email_confirmed_at is null or coalesce(u.email,'')!~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$')end from app_private.portal_owners o left join auth.users u on u.id=o.user_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())where o.portal_id=r.portal_id and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null)where id=r.id;
 return queued;
end $$;
create function api.worker_house_thanks_fanout(_limit integer default 25) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target record;repair record;rid uuid;n integer:=0;m integer:=0;repaired integer:=0;begin
 if _limit is null or _limit<1 or _limit>25 then raise exception 'INVALID_INPUT' using errcode='22023';end if;
 for target in select t.submission_id,t.portal_id,s.event_id from app_private.event_house_thanks_targets t join app_private.event_house_thanks s on s.id=t.submission_id where t.processed_at is null order by s.created_at,t.submission_id,t.portal_id limit _limit for update of t skip locked loop
  insert into app_private.event_house_thanks_receipts(submission_id,event_id,portal_id)values(target.submission_id,target.event_id,target.portal_id)on conflict(submission_id,portal_id)do update set submission_id=excluded.submission_id returning id into rid;
  m:=m+app_private.event_house_thanks_queue_mail(rid);
  update app_private.event_house_thanks_targets set processed_at=clock_timestamp()where submission_id=target.submission_id and portal_id=target.portal_id;n:=n+1;
 end loop;
 -- Missing contact repairs are bounded and delayed; accepted/unknown provider
 -- attempts are never reset. The immutable recipient ledger prevents remailing.
 for repair in select id from app_private.event_house_thanks_receipts where missing_contacts>0 and contacts_checked_at<clock_timestamp()-interval '5 minutes' order by contacts_checked_at limit greatest(0,_limit-n)for update skip locked loop
  m:=m+app_private.event_house_thanks_queue_mail(repair.id);repaired:=repaired+1;
 end loop;
 return jsonb_build_object('processed',n,'pending',(select count(*)from app_private.event_house_thanks_targets where processed_at is null),'receipts',n,'mailsQueued',m,'contactsRechecked',repaired);
end $$;
create function api.worker_house_thanks_mail(_outbox_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select o.payload from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id
 where o.id=_outbox_id and o.message_type='house_thanks_received' and lower(trim(o.recipient_email))=m.recipient_email and exists(select 1 from app_private.portal_owners p join auth.users u on u.id=p.user_id where p.portal_id=r.portal_id and p.revoked_at is null and p.suspended_at is null and p.accepted_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null and lower(trim(u.email))=m.recipient_email)
$$;
-- Recheck access at the durable gateway boundary, including recovered attempts.
alter function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text)rename to worker_mail_prepare_before_house_thanks;
create function api.worker_mail_prepare(_environment text,_key text,_config_id uuid,_outbox_id uuid,_channel text,_message_type text,_recipient text,_payload jsonb,_payload_hash text,_credential_hash text)returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if ((_message_type='house_thanks_received' and api.worker_house_thanks_mail(_outbox_id)is null)or(_message_type='event_closure_thanks' and api.worker_event_closure_mail(_outbox_id)is null)) and not exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status='accepted')then
  return jsonb_build_object('dispatch',false,'status',case when exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status in('unknown','reconcile'))then 'reconcile'else 'failed'end,'error_code',case when _message_type='event_closure_thanks'then 'EVENT_CLOSURE_RECIPIENT_UNAVAILABLE'else 'HOUSE_THANKS_RECIPIENT_UNAVAILABLE'end);
 end if;
 if _message_type='duinpad_evening_thanks' and exists(select 1 from app_private.email_outbox o join app_private.event_closures c on c.event_id=(o.payload->>'eventId')::uuid where o.id=_outbox_id) and not exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status='accepted')then
  return jsonb_build_object('dispatch',false,'status',case when exists(select 1 from app_private.mail_envelopes where environment=_environment and logical_key=_key and status in('unknown','reconcile'))then 'reconcile'else 'failed'end,'error_code','EVENT_CENTRALLY_CLOSED');
 end if;
 return api.worker_mail_prepare_before_house_thanks(_environment,_key,_config_id,_outbox_id,_channel,_message_type,_recipient,_payload,_payload_hash,_credential_hash);
end $$;
-- An access change cannot rewrite an uncertain or accepted provider outcome.
-- Preserve the text-only worker API and every unrelated message type unchanged.
alter function api.worker_update_outbox_v2(uuid,text,text,text,timestamptz)rename to worker_update_outbox_v2_before_house_thanks;
create function api.worker_update_outbox_v2(_id uuid,_status text,_provider_id text default null,_error_code text default null,_next_attempt_at timestamptz default null)returns void
language plpgsql security definer set search_path='' as $$
declare o app_private.email_outbox;e app_private.mail_envelopes;begin
 if _status='suppressed'then
  select *into o from app_private.email_outbox where id=_id for update;
  if o.message_type in('event_closure_thanks','house_thanks_received')then
   select *into e from app_private.mail_envelopes where outbox_id=_id;
   if o.status in('accepted','delivered')or o.accepted_at is not null then return;end if;
   if e.status='accepted'then
    perform api.worker_update_outbox_v2_before_house_thanks(_id,case when e.delivered_at is not null then 'delivered'else 'accepted'end,e.provider_id,null,null);return;
   end if;
   if e.status in('unknown','reconcile')then
    update app_private.email_outbox set status='unknown',last_error_code='EVENING_RECIPIENT_UNAVAILABLE_RECONCILE',lease_until=null where id=_id;
    return;
   end if;
  end if;
 end if;
 perform api.worker_update_outbox_v2_before_house_thanks(_id,_status,_provider_id,_error_code,_next_attempt_at);
end $$;
revoke all on function api.worker_update_outbox_v2_before_house_thanks(uuid,text,text,text,timestamptz),api.worker_update_outbox_v2(uuid,text,text,text,timestamptz)from public,anon,authenticated,service_role;
grant execute on function api.worker_update_outbox_v2(uuid,text,text,text,timestamptz)to service_role;
-- One authorized recovery action covers both independent message purposes.
-- The shared helper preserves provider identity, excludes uncertain/accepted
-- outcomes and permits only conclusive failures within its idempotency window.
alter function api.event_closure_admin_snapshot(text)rename to event_closure_admin_snapshot_before_house_thanks;
create function api.event_closure_admin_snapshot(_event_slug text)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb:=api.event_closure_admin_snapshot_before_house_thanks(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;n bigint;begin
 select count(*)into n from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.email_outbox o on o.id=m.outbox_id where r.event_id=eid and o.status='failed';
 return result||jsonb_build_object('mail',(result->'mail')||jsonb_build_object('houseFailed',n));
end $$;
alter function api.event_closure_retry_failed(text)rename to event_closure_retry_failed_before_house_thanks;
create function api.event_closure_retry_failed(_event_slug text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare result jsonb:=api.event_closure_retry_failed_before_house_thanks(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;candidate uuid;n integer:=0;begin
 for candidate in select o.id from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.email_outbox o on o.id=m.outbox_id left join app_private.mail_envelopes env on env.outbox_id=o.id
 where r.event_id=eid and o.status='failed'and o.accepted_at is null and o.provider_id is null and o.attempts<8
 and(env.id is null or(env.provider='resend'and env.status='failed'and env.accepted_at is null and env.provider_id is null and env.first_attempt_at>clock_timestamp()-interval '23 hours 55 minutes'))
 order by o.created_at,o.id limit 100 loop
  if app_private.event_evening_retry_outbox(candidate)then n:=n+1;end if;
 end loop;
 if n>0 then insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)values(eid,auth.uid(),'event_house_thanks.retry_failed','event_closure',jsonb_build_object('requeued',n));end if;
 return api.event_closure_admin_snapshot(_event_slug)||jsonb_build_object('requeued',coalesce((result->>'requeued')::integer,0)+n,'houseRequeued',n);
end $$;
revoke all on function api.event_closure_admin_snapshot_before_house_thanks(text),api.event_closure_retry_failed_before_house_thanks(text),api.event_closure_admin_snapshot(text),api.event_closure_retry_failed(text)from public,anon,authenticated,service_role;
grant execute on function api.event_closure_admin_snapshot(text),api.event_closure_retry_failed(text)to authenticated;
revoke all on function api.portal_thanks_snapshot_before_event_close(text,text,uuid),api.portal_thanks_save_before_event_close(text,uuid,text),api.worker_mail_prepare_before_house_thanks(text,text,uuid,uuid,text,text,text,jsonb,text,text),app_private.event_house_thanks_can_read(uuid,uuid),app_private.event_house_thanks_queue_mail(uuid)from public,anon,authenticated,service_role;
revoke all on function api.portal_thanks_closed_snapshot(text),api.portal_thanks_closed_save(text,text,uuid,text,text,uuid,uuid),api.portal_thanks_snapshot(text,text,uuid),api.portal_thanks_save(text,uuid,text),api.portal_thanks_inbox(text,uuid,uuid,integer),api.portal_thanks_read(text,uuid),api.worker_house_thanks_fanout(integer),api.worker_house_thanks_mail(uuid),api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text)from public,anon,authenticated,service_role;
grant execute on function api.portal_thanks_closed_snapshot(text),api.portal_thanks_closed_save(text,text,uuid,text,text,uuid,uuid),api.portal_thanks_snapshot(text,text,uuid),api.portal_thanks_save(text,uuid,text),api.portal_thanks_inbox(text,uuid,uuid,integer),api.portal_thanks_read(text,uuid)to authenticated;
grant execute on function api.worker_house_thanks_fanout(integer),api.worker_house_thanks_mail(uuid),api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text)to service_role;
notify pgrst,'reload schema';
