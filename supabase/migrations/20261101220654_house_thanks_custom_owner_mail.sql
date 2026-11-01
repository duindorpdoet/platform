-- Standard reactions remain durable counts. Only an original, genuinely written
-- message may notify the current active working portal team. This migration dispatches
-- no mail and rewrites no receipts, payloads, provider outcomes or historical text.
set lock_timeout='5s';
alter table app_private.event_house_thanks add column initial_message text;

create function app_private.event_house_thanks_normalize(_message text) returns text
language sql immutable set search_path='' as $$
 select btrim(regexp_replace(coalesce(_message,''),U&'[\0009-\000D\0020\00A0\1680\2000-\200A\2028\2029\202F\205F\3000\FEFF]+',' ','g'))
$$;
create function app_private.event_house_thanks_custom(_kind text,_message text) returns boolean
language sql immutable set search_path='' as $$
 select _kind in('all','personal') and app_private.event_house_thanks_normalize(_message)<>''
 and(_kind='personal' or app_private.event_house_thanks_normalize(_message)<>app_private.event_house_thanks_normalize('Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃'))
$$;
-- Historical rows are deliberately not backfilled. Capture their pre-edit text
-- only when it actually changes; default -> custom edits never create a mail.
create function app_private.event_house_thanks_preserve_initial() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then new.initial_message:=new.message;
 elsif old.initial_message is null and new.message is distinct from old.message then new.initial_message:=old.message;
 else new.initial_message:=old.initial_message;end if;
 return new;
end $$;
create trigger event_house_thanks_preserve_initial before insert or update on app_private.event_house_thanks
for each row execute function app_private.event_house_thanks_preserve_initial();

create function app_private.event_house_thanks_active_portal(_portal uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from app_private.portals p where p.id=_portal and p.approval_status='approved' and p.lifecycle_status='active'
 and not exists(select 1 from app_private.portal_flags f where f.portal_id=p.id and f.flag_key='fixture' and f.value))
 -- operation_status='closed' is normal after the evening and remains eligible.
$$;
-- Shared with the separately confirmed organization certificate campaign.
-- Reading a room (viewer) alone does not make an account a mail recipient.
create function app_private.event_portal_mail_recipient(_portal uuid,_account uuid,_email text default null) returns boolean
language sql stable security invoker set search_path='' as $$
 select app_private.event_house_thanks_active_portal(_portal)and exists(
 select 1 from app_private.portal_owners o join auth.users u on u.id=o.user_id
 where o.portal_id=_portal and o.user_id=_account and o.role in('owner','portal_manager','coadmin','crew','actor','reception','tech')
 and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null
 and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null
 and coalesce(u.email,'')~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
 and(_email is null or lower(trim(u.email))=lower(trim(_email))))
$$;
create or replace function app_private.event_house_thanks_queue_mail(_receipt uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare r app_private.event_house_thanks_receipts;s app_private.event_house_thanks;recipient record;oid uuid;queued integer:=0;payload jsonb;begin
 select *into r from app_private.event_house_thanks_receipts where id=_receipt for update;
 if r.id is null then return 0;end if;
 select *into s from app_private.event_house_thanks where id=r.submission_id;
 if not app_private.event_house_thanks_active_portal(r.portal_id)
 or not app_private.event_house_thanks_custom(s.kind,coalesce(s.initial_message,s.message))
 or not app_private.event_house_thanks_custom(s.kind,s.message)then
  update app_private.event_house_thanks_receipts set contacts_checked_at=clock_timestamp(),missing_contacts=0 where id=r.id;
  return 0;
 end if;
 payload:=jsonb_build_object('receiptId',r.id,'eventId',r.event_id,'portalId',r.portal_id,'portalName',(select portal_name from app_private.event_closure_portals where event_id=r.event_id and portal_id=r.portal_id),
 'kind',s.kind,'choice',s.choice,'message',coalesce(s.initial_message,s.message),'senderLabel','Een gezin uit Duindorp','portalRoomPath','/mijn-huis');
 for recipient in select distinct lower(trim(u.email))email from app_private.portal_owners o join auth.users u on u.id=o.user_id
 where o.portal_id=r.portal_id and app_private.event_portal_mail_recipient(r.portal_id,o.user_id)loop
  if not exists(select 1 from app_private.event_house_thanks_mail_recipients m where m.receipt_id=r.id and m.recipient_email=recipient.email)then
   oid:=null;
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('house-thanks:'||r.id||':'||encode(extensions.digest(recipient.email,'sha256'),'hex'),'house_thanks_received',r.id::text,recipient.email,payload)
   on conflict(dedupe_key)do nothing returning id into oid;
   if oid is null then select id into oid from app_private.email_outbox where dedupe_key='house-thanks:'||r.id||':'||encode(extensions.digest(recipient.email,'sha256'),'hex');end if;
   insert into app_private.event_house_thanks_mail_recipients(receipt_id,recipient_email,outbox_id)values(r.id,recipient.email,oid)on conflict do nothing;
   queued:=queued+1;
  end if;
 end loop;
 update app_private.event_house_thanks_receipts set contacts_checked_at=clock_timestamp(),missing_contacts=(select case when count(*)=0 then 1 else count(*)filter(where not app_private.event_portal_mail_recipient(r.portal_id,o.user_id))end
 from app_private.portal_owners o where o.portal_id=r.portal_id and o.role in('owner','portal_manager','coadmin','crew','actor','reception','tech')
 and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null)where id=r.id;
 return queued;
end $$;

-- Both the Node worker and the signed gateway call this exact material check.
-- Frozen payloads remain unchanged, including already delivered/uncertain mail.
create or replace function api.worker_house_thanks_mail(_outbox_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select o.payload from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id
 join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.event_house_thanks s on s.id=r.submission_id
 where o.id=_outbox_id and o.message_type='house_thanks_received' and lower(trim(o.recipient_email))=m.recipient_email
 and app_private.event_house_thanks_active_portal(r.portal_id)
 and app_private.event_house_thanks_custom(s.kind,coalesce(s.initial_message,s.message))
 and app_private.event_house_thanks_custom(s.kind,s.message)
 and o.payload->>'kind'=s.kind and app_private.event_house_thanks_custom(o.payload->>'kind',o.payload->>'message')
 and exists(select 1 from app_private.portal_owners p where p.portal_id=r.portal_id and app_private.event_portal_mail_recipient(r.portal_id,p.user_id,m.recipient_email))
$$;

create or replace function api.portal_thanks_inbox(_event_slug text,_portal_id uuid default null,_before uuid default null,_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;pid uuid:=_portal_id;anchor app_private.event_house_thanks_receipts;result jsonb;begin
 select id into eid from app_private.events where slug=_event_slug;
 if pid is null then select p.id into pid from app_private.portals p join app_private.portal_owners o on o.portal_id=p.id where p.event_id=eid and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null order by p.system_code limit 1;end if;
 if not app_private.event_house_thanks_can_read(eid,pid) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _limit is null or _limit<1 or _limit>25 then raise exception 'INVALID_INPUT' using errcode='22023';end if;
 if _before is not null then select *into anchor from app_private.event_house_thanks_receipts where id=_before and event_id=eid and portal_id=pid;
  if anchor.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 end if;
 with own as(select r.*,s.kind,s.choice,s.message,app_private.event_house_thanks_custom(s.kind,s.message)custom
 from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id where r.event_id=eid and r.portal_id=pid),
 page as(select *from own where custom and(_before is null or(received_at,id)<(anchor.received_at,anchor.id))order by received_at desc,id desc limit _limit+1),
 visible as(select *from page order by received_at desc,id desc limit _limit)
 select jsonb_build_object('portalId',pid,'portalName',(select name from app_private.portals where id=pid),'total',(select count(*)from own),
 'aggregateOnlyCount',(select count(*)from own where not custom),'customMessageCount',(select count(*)from own where custom),
 'counters',(select jsonb_build_object('general',count(*)filter(where kind='all'),'personal',count(*)filter(where kind='personal'),
 'beautiful',count(*)filter(where choice='beautiful'),'welcome',count(*)filter(where choice='welcome'),'treats',count(*)filter(where choice='treats'))from own),
 'unread',(select count(*)from own r where custom and not exists(select 1 from app_private.event_house_thanks_reads d where d.receipt_id=r.id and d.account_id=auth.uid())),
 'messages',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'kind',v.kind,'choice',v.choice,'message',v.message,'senderLabel','Een gezin uit Duindorp','receivedAt',v.received_at,
 'read',exists(select 1 from app_private.event_house_thanks_reads d where d.receipt_id=v.id and d.account_id=auth.uid()),
 'missingContacts',v.missing_contacts,'mailCounts',coalesce((select jsonb_object_agg(x.status,x.n)from(select o.status::text status,count(*)n from app_private.event_house_thanks_mail_recipients m join app_private.email_outbox o on o.id=m.outbox_id where m.receipt_id=v.id group by o.status)x),'{}'::jsonb),
 'mailStatus',case when v.missing_contacts>0 then 'missing_contact' when exists(select 1 from app_private.event_house_thanks_mail_recipients m join app_private.email_outbox o on o.id=m.outbox_id where m.receipt_id=v.id and o.status in('failed','suppressed','unknown'))then 'attention'else 'queued_or_processed'end)order by v.received_at desc,v.id desc)from visible v),'[]'::jsonb),
 'nextCursor',case when(select count(*)from page)>_limit then(select id from visible order by received_at,id limit 1)else null end)into result;
 return result;
end $$;

-- Keep the same single authorized recovery action/budget. Ineligible house mail
-- is neither advertised as retryable nor requeued; campaign mail is untouched.
create or replace function api.event_closure_admin_snapshot(_event_slug text)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb:=api.event_closure_admin_snapshot_before_house_thanks(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;n bigint;begin
 select count(*)into n from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.email_outbox o on o.id=m.outbox_id
 where r.event_id=eid and o.status='failed' and api.worker_house_thanks_mail(o.id)is not null;
 return result||jsonb_build_object('mail',(result->'mail')||jsonb_build_object('houseFailed',n));
end $$;
create or replace function api.event_closure_retry_failed(_event_slug text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare result jsonb:=api.event_closure_retry_failed_before_house_thanks(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;candidate uuid;n integer:=0;begin
 for candidate in select o.id from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.email_outbox o on o.id=m.outbox_id left join app_private.mail_envelopes env on env.outbox_id=o.id
 where r.event_id=eid and o.status='failed'and o.accepted_at is null and o.provider_id is null and o.attempts<8 and api.worker_house_thanks_mail(o.id)is not null
 and(env.id is null or(env.provider='resend'and env.status='failed'and env.accepted_at is null and env.provider_id is null and env.first_attempt_at>clock_timestamp()-interval '23 hours 55 minutes'))
 order by o.created_at,o.id limit 100 loop
  if app_private.event_evening_retry_outbox(candidate)then n:=n+1;end if;
 end loop;
 if n>0 then insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)values(eid,auth.uid(),'event_house_thanks.retry_failed','event_closure',jsonb_build_object('requeued',n));end if;
 return api.event_closure_admin_snapshot(_event_slug)||jsonb_build_object('requeued',coalesce((result->>'requeued')::integer,0)+n,'houseRequeued',n);
end $$;
revoke all on function app_private.event_house_thanks_normalize(text),app_private.event_house_thanks_custom(text,text),app_private.event_house_thanks_preserve_initial(),app_private.event_house_thanks_active_portal(uuid),app_private.event_portal_mail_recipient(uuid,uuid,text)from public,anon,authenticated,service_role;
-- CREATE OR REPLACE retains each existing RPC's exact grants and owner.
notify pgrst,'reload schema';
