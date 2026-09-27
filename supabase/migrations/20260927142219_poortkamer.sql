-- De Poortkamer: additive membership roles, bounded private room contracts.
begin;
alter table app_private.portals add column room_generation integer not null default 1;
alter table app_private.events add column community_generation integer not null default 1;
create function app_private.poortkamer_portal_topic(_id uuid) returns text language sql stable security definer set search_path='' as $$ select 'portal-room:'||id||':'||room_generation from app_private.portals where id=_id $$;
create function app_private.poortkamer_community_topic(_id uuid) returns text language sql stable security definer set search_path='' as $$ select 'poortplein:'||id||':'||community_generation from app_private.events where id=_id $$;
alter table app_private.portal_owners
  add column role text not null default 'coadmin' check (role in ('owner','coadmin','crew','viewer')),
  add column invited_by uuid references auth.users(id),
  add column first_name text check (char_length(first_name) between 1 and 80),
  add column last_name text check (char_length(last_name) between 1 and 100),
  add column task_label text check (task_label in ('ontvangst','snoep','acteur','rij/veiligheid','techniek')),
  add column last_seen_at timestamptz;
-- Recover the existing applicant when an approved portal lacks an owner.
insert into app_private.portal_owners(portal_id,user_id)
select p.id,a.applicant_user_id from app_private.portals p join app_private.portal_applications a on a.id=p.application_id
where p.approval_status='approved' and not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.revoked_at is null);
with ranked as (
 select o.ctid, row_number() over(partition by o.portal_id order by (o.user_id=a.applicant_user_id) desc,o.accepted_at,o.user_id) n
 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id
 left join app_private.portal_applications a on a.id=p.application_id where o.revoked_at is null
) update app_private.portal_owners o set role='owner' from ranked r where o.ctid=r.ctid and r.n=1;
do $$ begin
 if exists(select 1 from app_private.portals p where p.approval_status='approved' and not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.role='owner' and o.revoked_at is null)) then
  raise exception 'APPROVED_PORTAL_OWNER_MISSING: assign a verified existing owner before applying this migration';
 end if;
end $$;
create unique index portal_one_primary_owner on app_private.portal_owners(portal_id) where revoked_at is null and role='owner';
create function app_private.poortkamer_initial_owner() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.portals where id=new.portal_id for update;
 if new.revoked_at is null and not exists(select 1 from app_private.portal_owners where portal_id=new.portal_id and revoked_at is null) then new.role:='owner'; end if;
 return new;
end $$;
create trigger poortkamer_initial_owner before insert on app_private.portal_owners for each row execute function app_private.poortkamer_initial_owner();
create function app_private.poortkamer_primary_constraint() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 if tg_table_name='portals' then pid:=coalesce(new.id,old.id); else pid:=coalesce(new.portal_id,old.portal_id); end if;
 perform 1 from app_private.portals where id=pid for update;
 if exists(select 1 from app_private.portals where id=pid and approval_status='approved')
 and (select count(*) from app_private.portal_owners where portal_id=pid and role='owner' and revoked_at is null)<>1
 then raise exception 'EXACTLY_ONE_PRIMARY_OWNER' using errcode='23514'; end if;
 return null;
end $$;
create constraint trigger portal_primary_membership after insert or update or delete on app_private.portal_owners deferrable initially deferred for each row execute function app_private.poortkamer_primary_constraint();
create constraint trigger portal_primary_required after insert or update on app_private.portals deferrable initially deferred for each row execute function app_private.poortkamer_primary_constraint();

alter table app_private.portals add column pause_until timestamptz,
 add column stock_status text not null default 'sufficient' check(stock_status in ('plenty','sufficient','low','empty')),
 add column stock_help_requested_at timestamptz,
 add column room_updated_at timestamptz not null default now();
create table app_private.portal_team_invites (
 id uuid primary key default gen_random_uuid(),portal_id uuid not null references app_private.portals(id),
 email text not null check(email=lower(trim(email)) and char_length(email)<=254 and email like '%@%'),
 first_name text not null check(char_length(trim(first_name)) between 1 and 80),last_name text not null check(char_length(trim(last_name)) between 1 and 100),
 role text not null default 'viewer' check(role in ('coadmin','crew','viewer')),
 token_hash bytea not null unique,invited_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',accepted_at timestamptz,accepted_by uuid references auth.users(id),revoked_at timestamptz
);
create unique index portal_pending_invite on app_private.portal_team_invites(portal_id,email) where accepted_at is null and revoked_at is null;
create table app_private.portal_readiness (
 portal_id uuid not null references app_private.portals(id),item text not null check(item in ('access','lighting','candy','crew','phone','push','qr','warnings','opening')),
 done boolean not null,changed_by uuid not null references auth.users(id),changed_at timestamptz not null default now(),primary key(portal_id,item)
);
create table app_private.portal_status_history (
 id uuid primary key default gen_random_uuid(),portal_id uuid not null references app_private.portals(id),actor_id uuid references auth.users(id),
 state app_private.portal_operation_status not null,reason text,resume_at timestamptz,created_at timestamptz not null default now()
);
create index portal_status_history_portal on app_private.portal_status_history(portal_id,created_at);
create table app_private.portal_room_channels (
 id uuid primary key default gen_random_uuid(),event_id uuid not null references app_private.events(id),portal_id uuid references app_private.portals(id),
 kind text not null check(kind in ('team','community','announcements')),name text not null,
 check((kind='team')=(portal_id is not null)),unique nulls not distinct(event_id,portal_id,name)
);
create table app_private.portal_room_messages (
 id bigint generated always as identity primary key,channel_id uuid not null references app_private.portal_room_channels(id) on delete cascade,
 actor_id uuid references auth.users(id),sender_portal_id uuid references app_private.portals(id),body text not null check(char_length(trim(body)) between 1 and 1000),
 system boolean not null default false,urgent boolean not null default false,pinned boolean not null default false,hidden_at timestamptz,
 created_at timestamptz not null default now(),dedupe_key uuid not null default gen_random_uuid(),unique(actor_id,dedupe_key)
);
create index portal_messages_history on app_private.portal_room_messages(channel_id,id desc);
create table app_private.portal_room_reads (
 channel_id uuid not null references app_private.portal_room_channels(id) on delete cascade,user_id uuid not null references auth.users(id),
 last_read_id bigint not null default 0,muted boolean not null default false,primary key(channel_id,user_id)
);
create table app_private.portal_room_reactions (
 message_id bigint not null references app_private.portal_room_messages(id) on delete cascade,user_id uuid not null references auth.users(id),
 reaction text not null check(reaction in ('👍','❤️','🎃')),primary key(message_id,user_id,reaction)
);
create table app_private.portal_room_reports (
 id uuid primary key default gen_random_uuid(),message_id bigint not null references app_private.portal_room_messages(id) on delete cascade,
 reported_by uuid not null references auth.users(id),reason text not null check(char_length(trim(reason)) between 5 and 500),
 created_at timestamptz not null default now(),resolved_at timestamptz,unique(message_id,reported_by)
);
create table app_private.portal_community_mutes (
 event_id uuid not null references app_private.events(id),user_id uuid not null references auth.users(id),until_at timestamptz not null,
 reason text not null,primary key(event_id,user_id)
);
create table app_private.portal_notification_preferences (
 user_id uuid primary key references auth.users(id),next_10 boolean not null default true,next_3 boolean not null default true,
 arrived boolean not null default true,pause_1 boolean not null default true,urgent boolean not null default true,
 mention boolean not null default true,access boolean not null default true
);
create table app_private.portal_push_outbox (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),portal_id uuid references app_private.portals(id),
 kind text not null,dedupe_key text not null,created_at timestamptz not null default now(),available_at timestamptz not null default now(),
 lease_until timestamptz,attempts integer not null default 0,completed_at timestamptz,unique(user_id,dedupe_key)
);
create index portal_push_pending on app_private.portal_push_outbox(available_at) where completed_at is null;
create table app_private.portal_push_deliveries (
 notification_id uuid not null references app_private.portal_push_outbox(id) on delete cascade,subscription_id uuid not null references app_private.push_subscriptions(id) on delete cascade,
 delivered_at timestamptz not null default now(),primary key(notification_id,subscription_id)
);
create table app_private.portal_room_budgets(user_id uuid not null references auth.users(id),kind text not null,window_at timestamptz not null,used integer not null,primary key(user_id,kind));
-- Each environment owns its key. No bearer link is persisted in the outbox.
select vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'poortkamer_invitation_v1','HMAC key: rotate only after expiring pending Poortkamer invitations')
where not exists(select 1 from vault.secrets where name='poortkamer_invitation_v1');
create function app_private.poortkamer_invite_token(_id uuid) returns text language sql stable security definer set search_path='' as $$
 select encode(extensions.hmac(convert_to('poortkamer:v1:'||_id::text,'UTF8'),decode(decrypted_secret,'hex'),'sha256'),'hex') from vault.decrypted_secrets where name='poortkamer_invitation_v1'
$$;
create function app_private.poortkamer_role(_portal uuid,_actor uuid default auth.uid()) returns text language sql stable security definer set search_path='' as $$
 select case when app_private.has_capability(p.event_id,'event_admin',_actor) or app_private.has_capability(p.event_id,'portals_manage',_actor) or app_private.has_capability(p.event_id,'live_support',_actor) then 'admin'
 else (select role from app_private.portal_owners where portal_id=p.id and user_id=_actor and revoked_at is null) end
 from app_private.portals p where p.id=_portal and p.approval_status='approved' and _actor is not null
$$;
create function app_private.poortkamer_require(_portal uuid,_level text default 'read') returns text language plpgsql stable security definer set search_path='' as $$
declare r text:=app_private.poortkamer_role(_portal);
begin
 if r is null or (_level='live' and r='viewer') or (_level='details' and r not in ('owner','coadmin','admin'))
 or (_level='team' and r not in ('owner','admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return r;
end $$;
create function app_private.poortkamer_community(_event uuid,_actor uuid default auth.uid()) returns boolean language sql stable security definer set search_path='' as $$
 select _actor is not null and (app_private.has_capability(_event,'event_admin',_actor) or app_private.has_capability(_event,'portals_manage',_actor) or app_private.has_capability(_event,'live_support',_actor)
 or exists(select 1 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id where p.event_id=_event and p.approval_status='approved' and o.user_id=_actor and o.revoked_at is null))
$$;
create function app_private.poortkamer_budget(_kind text,_limit integer) returns void language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 insert into app_private.portal_room_budgets values(auth.uid(),_kind,now(),1)
 on conflict(user_id,kind) do update set window_at=case when portal_room_budgets.window_at<now()-interval '1 minute' then now() else portal_room_budgets.window_at end,
 used=case when portal_room_budgets.window_at<now()-interval '1 minute' then 1 else portal_room_budgets.used+1 end returning used into n;
 if n>_limit then raise exception 'RATE_LIMITED' using errcode='P0001'; end if;
end $$;
create function app_private.poortkamer_channels(_event uuid,_portal uuid default null) returns void language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.portal_room_channels(event_id,kind,name) values(_event,'community','Algemeen'),(_event,'community','Hulp & materialen'),(_event,'community','Snoep & voorraad'),(_event,'community','Decor & techniek'),(_event,'announcements','De Omroeper') on conflict do nothing;
 if _portal is not null then insert into app_private.portal_room_channels(event_id,portal_id,kind,name) values(_event,_portal,'team','Achter de Poort') on conflict do nothing; end if;
end $$;
create function app_private.poortkamer_signal(_portal uuid,_action text,_change jsonb default '{}'::jsonb,_line text default null) returns void language plpgsql security definer set search_path='' as $$
declare eid uuid; cid uuid;
begin
 update app_private.portals set room_updated_at=now() where id=_portal returning event_id into eid;
 if eid is null then return; end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(eid,auth.uid(),_action,'portal',_portal,_change);
 if _line is not null then
 perform app_private.poortkamer_channels(eid,_portal);
 select id into cid from app_private.portal_room_channels where portal_id=_portal;
 insert into app_private.portal_room_messages(channel_id,body,system) values(cid,_line,true);
 end if;
 perform realtime.send(jsonb_build_object('id',_portal),'snapshot_changed',app_private.poortkamer_portal_topic(_portal),true);
 perform realtime.send(jsonb_build_object('id',_portal),'snapshot_changed','admin-event:'||eid,true);
end $$;
create function app_private.poortkamer_email(_event uuid,_user uuid,_kind text,_key text,_payload jsonb default '{}'::jsonb) returns void language sql security definer set search_path='' as $$
 insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 select _key,_kind,'user:'||id,email,_payload from auth.users where id=_user and email_confirmed_at is not null on conflict(dedupe_key) do nothing
$$;
create function app_private.poortkamer_push(_portal uuid,_kind text,_key text,_user uuid default null) returns void language sql security definer set search_path='' as $$
 insert into app_private.portal_push_outbox(user_id,portal_id,kind,dedupe_key)
 select user_id,_portal,_kind,_key from app_private.portal_owners where portal_id=_portal and revoked_at is null and (_user is null or user_id=_user) on conflict do nothing
$$;
create function api.portal_team_command(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; inv app_private.portal_team_invites; target uuid; r text; email_value text; result jsonb; receipt app_private.command_receipts; request_hash text; member app_private.portal_owners;
begin
 select * into p from app_private.portals where id=_portal_id for update;
 perform app_private.poortkamer_require(p.id,'team');
 request_hash:=encode(extensions.digest(convert_to(jsonb_build_array(_portal_id,_operation,_payload)::text,'UTF8'),'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.team' and idempotency_key=_key::text;
 if found then if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 perform app_private.poortkamer_budget('team',10);
 if _operation='invite' then
  email_value:=lower(trim(_payload->>'email')); r:=coalesce(_payload->>'role','viewer');
  if (select count(*) from app_private.portal_owners where portal_id=p.id and revoked_at is null)+(select count(*) from app_private.portal_team_invites where portal_id=p.id and accepted_at is null and revoked_at is null and expires_at>now())>=100 then raise exception 'TEAM_FULL'; end if;
  if r not in ('viewer','crew','coadmin') then raise exception 'INVALID_ROLE'; end if;
  if exists(select 1 from app_private.portal_owners o join auth.users u on u.id=o.user_id where o.portal_id=p.id and o.revoked_at is null and lower(u.email)=email_value) then raise exception 'ALREADY_MEMBER'; end if;
  update app_private.portal_team_invites set revoked_at=now() where portal_id=p.id and email=email_value and accepted_at is null and revoked_at is null and expires_at<=now();
  inv.id:=gen_random_uuid();
  insert into app_private.portal_team_invites(id,portal_id,email,first_name,last_name,role,token_hash,invited_by)
  values(inv.id,p.id,email_value,trim(_payload->>'firstName'),trim(_payload->>'lastName'),r,extensions.digest(app_private.poortkamer_invite_token(inv.id),'sha256'),auth.uid()) returning * into inv;
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  values('portal-invite:'||inv.id,'portal_team_invite','portal-invite:'||inv.id,inv.email,jsonb_build_object('inviteId',inv.id));
  result:=jsonb_build_object('id',inv.id);
 elsif _operation in ('resend','revoke_invite') then
  select * into inv from app_private.portal_team_invites where id=(_payload->>'inviteId')::uuid and portal_id=p.id for update;
  if inv.id is null or inv.accepted_at is not null or inv.revoked_at is not null then raise exception 'INVITATION_UNAVAILABLE'; end if;
  update app_private.portal_team_invites set revoked_at=now() where id=inv.id;
  if _operation='resend' then
   inv.id:=gen_random_uuid();
   insert into app_private.portal_team_invites(id,portal_id,email,first_name,last_name,role,token_hash,invited_by)
   values(inv.id,p.id,inv.email,inv.first_name,inv.last_name,inv.role,extensions.digest(app_private.poortkamer_invite_token(inv.id),'sha256'),auth.uid());
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('portal-invite:'||inv.id,'portal_team_invite','portal-invite:'||inv.id,inv.email,jsonb_build_object('inviteId',inv.id));
  end if;
  result:=jsonb_build_object('id',inv.id);
 elsif _operation in ('role','revoke','transfer','task') then
  target:=(_payload->>'userId')::uuid;
  select * into member from app_private.portal_owners where portal_id=p.id and user_id=target and revoked_at is null for update;
  if member.user_id is null then raise exception 'MEMBER_NOT_FOUND'; end if;
  if _operation<>'task' and member.role='owner' then raise exception 'TRANSFER_OWNER_FIRST'; end if;
  if _operation='transfer' then
   update app_private.portal_owners set role='coadmin' where portal_id=p.id and role='owner' and revoked_at is null;
   update app_private.portal_owners set role='owner' where portal_id=p.id and user_id=target and revoked_at is null;
  elsif _operation='revoke' then update app_private.portal_owners set revoked_at=now() where portal_id=p.id and user_id=target and revoked_at is null;
  elsif _operation='task' then update app_private.portal_owners set task_label=nullif(_payload->>'task','') where portal_id=p.id and user_id=target and revoked_at is null;
  else
   r:=_payload->>'role'; if r not in ('coadmin','crew','viewer') then raise exception 'INVALID_ROLE'; end if;
   update app_private.portal_owners set role=r where portal_id=p.id and user_id=target and revoked_at is null;
  end if;
  result:=jsonb_build_object('userId',target);
  if _operation<>'task' then
   perform app_private.poortkamer_email(p.event_id,target,case when _operation='revoke' then 'portal_team_revoked' else 'portal_team_role_changed' end,'portal-access:'||_key,jsonb_build_object('portalCode',p.system_code));
   insert into app_private.portal_push_outbox(user_id,portal_id,kind,dedupe_key) values(target,p.id,'access','access:'||_key) on conflict do nothing;
  end if;
 else raise exception 'INVALID_OPERATION'; end if;
 perform app_private.poortkamer_signal(p.id,'portal.team.'||_operation,result,
 case _operation when 'invite' then 'Een sleutel is gedeeld. De uitnodiging wacht op bevestiging.' when 'resend' then 'Een nieuwe uitnodiging is verstuurd; de vorige sleutel is ingetrokken.' when 'revoke_invite' then 'Een openstaande uitnodiging is ingetrokken.' when 'transfer' then 'Het hoofdpoortwachterschap is overgedragen.' when 'revoke' then 'Een teamlid heeft geen toegang meer.' when 'task' then 'Een teamtaak is aangepast.' else 'Een teamrol is gewijzigd.' end);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.team',_key::text,request_hash,result,now()+interval '30 days');
 return result;
end $$;
create function api.portal_invitation_check(_token text,_email text) returns boolean language sql stable security definer set search_path='' as $$
 select length(_token)=64 and exists(select 1 from app_private.portal_team_invites i join app_private.portals p on p.id=i.portal_id where i.token_hash=extensions.digest(_token,'sha256') and i.email=lower(trim(_email)) and i.revoked_at is null and i.accepted_at is null and i.expires_at>now() and p.approval_status='approved')
$$;
create function api.portal_invitation_mail_payload(_invite_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('actionPath','/uitnodiging/poort/'||app_private.poortkamer_invite_token(i.id),'portalCode',p.system_code)
 from app_private.portal_team_invites i join app_private.portals p on p.id=i.portal_id where i.id=_invite_id and i.revoked_at is null and i.accepted_at is null and i.expires_at>now() and p.approval_status='approved'
$$;
create function api.portal_invitation_accept(_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare inv app_private.portal_team_invites; p app_private.portals; uid uuid:=auth.uid(); eid text; owner_id uuid;
begin
 select lower(email) into eid from auth.users where id=uid and email_confirmed_at is not null;
 if eid is null then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501'; end if;
 select * into inv from app_private.portal_team_invites where token_hash=extensions.digest(_token,'sha256');
 select * into p from app_private.portals where id=inv.portal_id for update;
 select * into inv from app_private.portal_team_invites where id=inv.id for update;
 if p.id is null or p.approval_status<>'approved' or inv.email<>eid or inv.revoked_at is not null or inv.accepted_at is not null or inv.expires_at<=now() then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501'; end if;
 if exists(select 1 from app_private.portal_owners where portal_id=p.id and user_id=uid and revoked_at is null) then raise exception 'ALREADY_MEMBER'; end if;
 insert into app_private.portal_owners(portal_id,user_id,role,invited_by,first_name,last_name) values(p.id,uid,inv.role,inv.invited_by,inv.first_name,inv.last_name);
 update app_private.portal_team_invites set accepted_at=now(),accepted_by=uid where id=inv.id;
 select user_id into owner_id from app_private.portal_owners where portal_id=p.id and role='owner' and revoked_at is null;
 perform app_private.poortkamer_email(p.event_id,owner_id,'portal_team_accepted','portal-accepted:'||inv.id,jsonb_build_object('portalCode',p.system_code));
 perform app_private.poortkamer_signal(p.id,'portal.team.accepted',jsonb_build_object('inviteId',inv.id,'userId',uid),'Een nieuwe Poortwachter heeft de sleutel aangenomen.');
 return jsonb_build_object('portalId',p.id);
end $$;
-- Strengthen existing write APIs without replacing the route planner.
CREATE OR REPLACE FUNCTION api.portal_set_operational_state(_portal_id uuid, _state app_private.portal_operation_status, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  affected record;
begin
  perform app_private.poortkamer_require(_portal_id,'live');
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null or portal.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (
    select 1 from app_private.portal_owners owner
    where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null
  ) and not app_private.has_capability(portal.event_id, 'event_admin', actor)
    and not app_private.has_capability(portal.event_id, 'portals_manage', actor)
    and not app_private.has_capability(portal.event_id, 'live_support', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _state in ('paused', 'closed') and char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  update app_private.portals
  set pause_until = null, operation_status = _state, pause_after_current = _state = 'paused', version = version + 1
  where id = _portal_id returning * into portal;

  if exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    if _state = 'open' then
      update app_private.event_route_settings set finale_available = true, version = version + 1
      where event_id = portal.event_id;
    elsif _state = 'paused' then
      update app_private.event_route_settings set finale_available = false, version = version + 1
      where event_id = portal.event_id;
      update app_private.portal_reservations set status = 'cancelled',
        cancelled_reason = 'Laatste poort pauzeert', version = version + 1
      where portal_id = portal.id and kind = 'finale' and status = 'held';
    end if;
  end if;

  if _state in ('paused', 'closed') then
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = case when _state = 'closed' then 'Poort direct gesloten' else 'Poort pauzeert na huidige groep' end,
      version = version + 1
    where portal_id = _portal_id and status = 'held' and kind = 'ordinary';
  end if;
  if _state = 'closed' and exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    update app_private.event_route_settings set finale_available = false, version = version + 1 where event_id = portal.event_id;
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = 'Laatste poort direct gesloten', version = version + 1
    where portal_id = portal.id and kind = 'finale' and status in ('held', 'active');
    for affected in
      select run.id as run_id, run.group_id
      from app_private.group_runs run
      join app_private.walking_groups walking_group on walking_group.id = run.group_id
      where walking_group.event_id = portal.event_id and walking_group.route_mode = 'dynamic'
        and run.status in ('live', 'paused')
    loop
      update app_private.group_runs set status = 'paused', version = version + 1 where id = affected.run_id;
      insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
      select portal.event_id, affected.group_id, affected.run_id, portal.id, 'urgent', 'FINALE_UNAVAILABLE',
        'De eindpoort is gesloten. Gebruik uitsluitend de goedgekeurde noodafsluiting.'
      where not exists (select 1 from app_private.route_alerts where run_id = affected.run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    end loop;
  elsif _state = 'closed' then
    for affected in
      select stop.id as stop_id, stop.run_id, reservation.id as reservation_id
      from app_private.run_stops stop
      join app_private.group_runs run on run.id = stop.run_id and run.current_stop_id = stop.id and run.status = 'live'
      join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
      left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
      where stop.portal_id = portal.id and stop.state = 'active'
        and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
      for update of stop, run
    loop
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
      where id = affected.stop_id;
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Poort direct gesloten',
        reason = left(trim(_reason), 500), changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.stop_id and required_for_completion;
      update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Poort direct gesloten', version = version + 1
      where id = affected.reservation_id;
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      values (affected.run_id, affected.stop_id, portal.world_id, 'system_skipped')
      on conflict (run_stop_id) do nothing;
      update app_private.group_runs set current_stop_id = null, version = version + 1
      where id = affected.run_id;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.stop_id, 'stop.system_skipped', actor,
        jsonb_build_object('portalId', portal.id, 'reason', left(trim(_reason), 500)));
      perform app_private.dispatch_next_stop(affected.run_id, clock_timestamp());
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.operation_state_changed', 'portal', portal.id,
    jsonb_build_object('state', _state, 'reason', left(coalesce(trim(_reason), ''), 500)));
  insert into app_private.portal_status_history(portal_id,actor_id,state,reason) values(portal.id,actor,_state,left(trim(_reason),500));
  perform app_private.poortkamer_signal(portal.id,'portal.room.status',jsonb_build_object('state',_state),'De poortstatus is gewijzigd.');
  return jsonb_build_object('id', portal.id, 'state', portal.operation_status, 'version', portal.version, 'pauseAfterCurrent', portal.pause_after_current);
end;
$function$;
CREATE OR REPLACE FUNCTION api.portal_rotate_credential(_portal_id uuid, _expected_portal_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  credential app_private.portal_credentials;
  credential_token text;
  short_code text;
  next_version integer;
begin
  perform app_private.poortkamer_require(_portal_id,'details');
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = actor and owner.revoked_at is null)
     and not app_private.has_capability(portal.event_id, 'event_admin', actor)
    and not app_private.has_capability(portal.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if portal.version <> _expected_portal_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if portal.approval_status <> 'approved' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;

  select coalesce(max(version), 0) + 1 into next_version from app_private.portal_credentials where portal_id = portal.id;
  credential_token := encode(extensions.gen_random_bytes(32), 'hex');
  short_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  update app_private.portal_credentials set revoked_at = now() where portal_id = portal.id and revoked_at is null;
  insert into app_private.portal_credentials(portal_id, token_hash, short_code_hash, version, valid_from)
  values (
    portal.id,
    extensions.digest(convert_to(credential_token, 'utf8'), 'sha256'),
    extensions.digest(convert_to(short_code, 'utf8'), 'sha256'),
    next_version,
    now()
  ) returning * into credential;
  update app_private.portals set version = version + 1 where id = portal.id returning * into portal;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.credential_rotated', 'portal', portal.id, jsonb_build_object('credentialVersion', credential.version, 'reason', left(_reason, 300)));
  return jsonb_build_object(
    'portalId', portal.id,
    'portalVersion', portal.version,
    'credentialVersion', credential.version,
    'credential', credential_token,
    'shortCode', short_code
  );
end;
$function$;
create function api.portal_room_update(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; result jsonb; request_hash text; receipt app_private.command_receipts; minutes integer; newstate app_private.portal_operation_status;
begin
 select * into p from app_private.portals where id=_portal_id for update;
 perform app_private.poortkamer_require(_portal_id,case when _operation='details' then 'details' else 'live' end);
 request_hash:=encode(extensions.digest(jsonb_build_array(_portal_id,_operation,_payload)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.room' and idempotency_key=_key::text;
 if found then if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 perform app_private.poortkamer_budget('room',30);
 if _operation='status' then
  if (_payload->>'version') is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  minutes:=(_payload->>'minutes')::integer; newstate:=(_payload->>'state')::app_private.portal_operation_status;
  if newstate not in ('open','paused','closed') or (minutes is not null and (newstate<>'paused' or minutes not in (5,10,15,20,30))) then raise exception 'INVALID_STATE'; end if;
  result:=api.portal_set_operational_state(p.id,newstate,(_payload->>'version')::integer,_payload->>'reason');
  if newstate='paused' and minutes is not null then
   update app_private.portals set pause_until=now()+make_interval(mins=>minutes) where id=p.id;
   update app_private.portal_status_history set resume_at=now()+make_interval(mins=>minutes) where id=(select id from app_private.portal_status_history where portal_id=p.id order by created_at desc,id desc limit 1);
  end if;
 elsif _operation='checklist' then
  insert into app_private.portal_readiness(portal_id,item,done,changed_by) values(p.id,_payload->>'item',(_payload->>'done')::boolean,auth.uid())
  on conflict(portal_id,item) do update set done=excluded.done,changed_by=excluded.changed_by,changed_at=now();
  result:=jsonb_build_object('item',_payload->>'item');
  perform app_private.poortkamer_signal(p.id,'portal.readiness.updated',result,'De gedeelde gereedcheck is bijgewerkt.');
 elsif _operation='stock' then
  update app_private.portals set stock_status=_payload->>'stock',stock_help_requested_at=case when _payload->>'stock' in ('plenty','sufficient') then null else stock_help_requested_at end where id=p.id;
  result:=jsonb_build_object('stock',_payload->>'stock');
  perform app_private.poortkamer_signal(p.id,'portal.stock.updated',result,'De snoepvoorraad is bijgewerkt.');
 elsif _operation='help' then
  perform app_private.poortkamer_budget('stock_help',2);
  if exists(select 1 from app_private.portal_community_mutes where event_id=p.event_id and user_id=auth.uid() and until_at>now()) then raise exception 'COMMUNITY_MUTED' using errcode='42501'; end if;
  if (_payload->>'shareCommunity')::boolean is distinct from true then raise exception 'EXPLICIT_CONFIRMATION_REQUIRED'; end if;
  perform app_private.poortkamer_channels(p.event_id,p.id);
  insert into app_private.portal_room_messages(channel_id,actor_id,sender_portal_id,body,dedupe_key)
  select id,auth.uid(),p.id,p.system_code||' vraagt hulp met de snoepvoorraad. Neem contact op via deze poort in het Poortplein.',_key from app_private.portal_room_channels where event_id=p.event_id and name='Snoep & voorraad' and kind='community';
  update app_private.portals set stock_help_requested_at=now() where id=p.id;
  result:=jsonb_build_object('shared',true);
  perform app_private.poortkamer_signal(p.id,'portal.stock.help',result,'Er is hulp voor snoepvoorraad gevraagd op het Poortplein.');
 elsif _operation='details' then
  if p.version is distinct from (_payload->>'version')::integer then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if char_length(trim(_payload->>'name')) not between 2 and 160 or char_length(coalesce(_payload->>'description',''))>2000 then raise exception 'INVALID_DETAILS'; end if;
  update app_private.portals set name=trim(_payload->>'name'),description=_payload->>'description',version=version+1 where id=p.id;
  result:=jsonb_build_object('updated',true);
  perform app_private.poortkamer_signal(p.id,'portal.details.updated','{}','De poortgegevens zijn bijgewerkt.');
 else raise exception 'INVALID_OPERATION'; end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.room',_key::text,request_hash,result,now()+interval '30 days');
 return result;
end $$;
create function app_private.poortkamer_channel_access(_channel uuid) returns app_private.portal_room_channels language plpgsql stable security definer set search_path='' as $$
declare c app_private.portal_room_channels;
begin
 select * into c from app_private.portal_room_channels where id=_channel;
 if c.id is null or auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if c.kind='team' then perform app_private.poortkamer_require(c.portal_id); elsif not app_private.poortkamer_community(c.event_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return c;
end $$;
create function app_private.poortkamer_message_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare c app_private.portal_room_channels;
begin
 select * into c from app_private.portal_room_channels where id=new.channel_id;
 perform realtime.send(jsonb_build_object('id',c.id),'snapshot_changed',case when c.kind='team' then app_private.poortkamer_portal_topic(c.portal_id) else app_private.poortkamer_community_topic(c.event_id) end,true);
 return new;
end $$;
create trigger poortkamer_message_changed after insert or update on app_private.portal_room_messages for each row execute function app_private.poortkamer_message_signal();
create function api.portal_chat_snapshot(_channel_id uuid,_before bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c app_private.portal_room_channels;
begin
 c:=app_private.poortkamer_channel_access(_channel_id);
 return jsonb_build_object('channelId',c.id,'retainedUntil',(select local_date+interval '1 month' from app_private.events where id=c.event_id),
 'messages',coalesce((select jsonb_agg(item order by mid) from (
  select m.id mid,jsonb_build_object('id',m.id,'body',case when m.hidden_at is null then m.body else 'Dit bericht is verborgen door de organisatie.' end,
  'system',m.system,'urgent',m.urgent,'pinned',m.pinned,'hidden',m.hidden_at is not null,'createdAt',m.created_at,
  'sender',case when m.system then 'De Poortkamer' when c.kind='announcements' then 'De organisatie'
    when c.kind='team' then coalesce(nullif(concat_ws(' ',o.first_name,o.last_name),''),pr.display_name,'Poortwachter')
    else coalesce(o.first_name,split_part(pr.display_name,' ',1),'Poortwachter') end,
  'role',case when c.kind='team' then coalesce(o.role,'admin') else null end,
  'portalCode',case when c.kind='community' then p.system_code else null end,'portalName',case when c.kind='community' then p.name else null end,
  'mentionUserId',case when c.kind='community' and m.hidden_at is null and o.user_id is not null and p.approval_status='approved' then m.actor_id else null end,
  'own',m.actor_id=auth.uid(),'reactions',coalesce((select jsonb_agg(jsonb_build_object('emoji',r.reaction,'count',r.n,'own',r.own)) from
    (select reaction,count(*) n,bool_or(user_id=auth.uid()) own from app_private.portal_room_reactions where message_id=m.id group by reaction) r),'[]'::jsonb)) item
  from app_private.portal_room_messages m
  left join app_private.portals p on p.id=m.sender_portal_id
  left join app_private.portal_owners o on o.portal_id=coalesce(c.portal_id,m.sender_portal_id) and o.user_id=m.actor_id and o.revoked_at is null
  left join app_private.profiles pr on pr.user_id=m.actor_id
  where m.channel_id=c.id and (_before is null or m.id<_before) order by m.id desc limit 60
 ) bounded),'[]'::jsonb),
 'pins',coalesce((select jsonb_agg(jsonb_build_object('id',id,'body',body)) from(select id,body from app_private.portal_room_messages where channel_id=c.id and pinned and hidden_at is null order by id desc limit 5) pins),'[]'::jsonb));
end $$;
create function api.portal_chat_send(_channel_id uuid,_body text,_key uuid,_portal_id uuid default null,_mentions uuid[] default '{}',_urgent boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare c app_private.portal_room_channels; mid bigint; old app_private.portal_room_messages; target uuid; target_portal uuid; isadmin boolean;
begin
 c:=app_private.poortkamer_channel_access(_channel_id);
 isadmin:=app_private.has_capability(c.event_id,'event_admin') or app_private.has_capability(c.event_id,'portals_manage') or app_private.has_capability(c.event_id,'live_support');
 if c.kind='announcements' and not isadmin then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if c.kind='community' and exists(select 1 from app_private.portal_community_mutes where event_id=c.event_id and user_id=auth.uid() and until_at>now()) then raise exception 'COMMUNITY_MUTED' using errcode='42501'; end if;
 if _portal_id is not null then
  perform app_private.poortkamer_require(_portal_id);
  if not exists(select 1 from app_private.portals where id=_portal_id and event_id=c.event_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 end if;
 if c.kind='team' and _portal_id is distinct from c.portal_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _urgent and c.kind<>'announcements' then raise exception 'INVALID_URGENCY'; end if;
 if char_length(trim(_body)) not between 1 and 1000 or coalesce(cardinality(_mentions),0)>20 then raise exception 'INVALID_MESSAGE'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||_key::text,0));
 select * into old from app_private.portal_room_messages where actor_id=auth.uid() and dedupe_key=_key;
 if found then
  if old.channel_id<>c.id or old.body<>trim(_body) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return jsonb_build_object('id',old.id);
 end if;
 perform app_private.poortkamer_budget('chat',15);
 insert into app_private.portal_room_messages(channel_id,actor_id,sender_portal_id,body,dedupe_key,urgent)
 values(c.id,auth.uid(),_portal_id,trim(_body),_key,_urgent) returning id into mid;
 if c.kind in ('team','community') then
  foreach target in array coalesce(_mentions,'{}'::uuid[]) loop
   select o.portal_id into target_portal from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id
   where o.user_id=target and o.revoked_at is null and p.approval_status='approved' and p.event_id=c.event_id
   and (c.kind='community' or o.portal_id=c.portal_id) order by p.system_code limit 1;
   if target_portal is null then raise exception 'INVALID_MENTION'; end if;
   if not exists(select 1 from app_private.portal_room_reads where channel_id=c.id and user_id=target and muted) then
    perform app_private.poortkamer_push(target_portal,'mention','mention:'||mid,target);
   end if;
  end loop;
 end if;
 if _urgent then
  insert into app_private.portal_push_outbox(user_id,kind,dedupe_key)
  select distinct o.user_id,'urgent','announcement:'||mid from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id where p.event_id=c.event_id and p.approval_status='approved' and o.revoked_at is null on conflict do nothing;
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  select 'announcement-fallback:'||mid||':'||u.id,'portal_urgent_announcement','user:'||u.id,u.email,'{}'::jsonb
  from auth.users u where u.email_confirmed_at is not null and exists(select 1 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id where o.user_id=u.id and o.revoked_at is null and p.event_id=c.event_id and p.approval_status='approved')
  and not exists(select 1 from app_private.push_subscriptions s join app_private.push_preferences pref on pref.user_id=s.user_id and pref.enabled where s.user_id=u.id and s.active) on conflict do nothing;
 end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(c.event_id,auth.uid(),'portal.chat.sent','portal_channel',c.id,jsonb_build_object('messageId',mid,'urgent',_urgent));
 return jsonb_build_object('id',mid);
end $$;
create function api.portal_chat_action(_channel_id uuid,_operation text,_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c app_private.portal_room_channels; mid bigint:=(_payload->>'messageId')::bigint; m app_private.portal_room_messages; allowed boolean;
begin
 c:=app_private.poortkamer_channel_access(_channel_id);
 if _operation in ('read','mute') then
  if _operation='read' then
   insert into app_private.portal_room_reads(channel_id,user_id,last_read_id) values(c.id,auth.uid(),least(coalesce(mid,0),coalesce((select max(id) from app_private.portal_room_messages where channel_id=c.id),0)))
   on conflict(channel_id,user_id) do update set last_read_id=greatest(portal_room_reads.last_read_id,excluded.last_read_id);
  else insert into app_private.portal_room_reads(channel_id,user_id,muted) values(c.id,auth.uid(),(_payload->>'muted')::boolean)
   on conflict(channel_id,user_id) do update set muted=excluded.muted;
  end if;
 else
  select * into m from app_private.portal_room_messages where id=mid and channel_id=c.id for update;
  if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
  perform app_private.poortkamer_budget('chat_action',30);
  if _operation='react' then
   if m.hidden_at is not null or c.kind='announcements' then raise exception 'REACTION_UNAVAILABLE'; end if;
   if (_payload->>'active')::boolean then insert into app_private.portal_room_reactions values(mid,auth.uid(),_payload->>'emoji') on conflict do nothing;
   else delete from app_private.portal_room_reactions where message_id=mid and user_id=auth.uid() and reaction=_payload->>'emoji'; end if;
  elsif _operation='report' then
   insert into app_private.portal_room_reports(message_id,reported_by,reason) values(mid,auth.uid(),trim(_payload->>'reason')) on conflict(message_id,reported_by) do nothing;
  elsif _operation in ('hide','pin','mute_author','resolve') then
   allowed:=app_private.has_capability(c.event_id,'event_admin') or app_private.has_capability(c.event_id,'portals_manage') or app_private.has_capability(c.event_id,'live_support');
   if _operation='pin' and c.kind='team' then allowed:=allowed or app_private.poortkamer_role(c.portal_id) in ('owner','coadmin'); end if;
   if not allowed then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if _operation='pin' then update app_private.portal_room_messages set pinned=(_payload->>'pinned')::boolean where id=mid;
   elsif _operation='hide' then update app_private.portal_room_messages set hidden_at=coalesce(hidden_at,now()) where id=mid;
   elsif _operation='mute_author' then
    if c.kind<>'community' or m.actor_id is null or char_length(trim(_payload->>'reason')) not between 5 and 500 then raise exception 'INVALID_MODERATION'; end if;
    insert into app_private.portal_community_mutes(event_id,user_id,until_at,reason) values(c.event_id,m.actor_id,now()+interval '24 hours',trim(_payload->>'reason'))
    on conflict(event_id,user_id) do update set until_at=excluded.until_at,reason=excluded.reason;
   end if;
   update app_private.portal_room_reports set resolved_at=now() where message_id=mid and _operation in ('hide','resolve','mute_author');
   insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(c.event_id,auth.uid(),'portal.chat.'||_operation,'portal_channel',c.id,jsonb_build_object('messageId',mid));
  else raise exception 'INVALID_OPERATION'; end if;
  perform realtime.send(jsonb_build_object('id',c.id),'snapshot_changed',case when c.kind='team' then app_private.poortkamer_portal_topic(c.portal_id) else app_private.poortkamer_community_topic(c.event_id) end,true);
  perform realtime.send(jsonb_build_object('id',c.id),'snapshot_changed','admin-event:'||c.event_id,true);
 end if;
 return jsonb_build_object('ok',true);
end $$;
create function api.portal_visits_snapshot(_portal_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare arrivals jsonb; visits jsonb; recap jsonb;
begin
 perform app_private.poortkamer_require(_portal_id);
 arrivals:=api.portal_arrivals_snapshot(_portal_id);
 with confirmed as (
 select s.id, g.system_code, e.scanned_at,
 (select count(*) from app_private.stop_participant_statuses ps where ps.run_stop_id=s.id and ps.status='visited') child_count
 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id
 join app_private.scan_evidence e on e.run_stop_id=s.id left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 where coalesce(s.portal_id,plan.portal_id)=_portal_id
 ), gaps as (select scanned_at-lag(scanned_at) over(order by scanned_at) gap from confirmed),
 pause_history as(select state,created_at,lead(created_at,1,now()) over(order by created_at,id) ended from app_private.portal_status_history where portal_id=_portal_id)
 select coalesce((select jsonb_agg(jsonb_build_object('groupCode',system_code,'visitedAt',scanned_at,'children',child_count) order by scanned_at desc) from(select * from confirmed order by scanned_at desc limit 200) bounded),'[]'::jsonb),
 jsonb_build_object('groups',(select count(*) from confirmed),'children',(select coalesce(sum(child_count),0) from confirmed),'firstVisit',(select min(scanned_at) from confirmed),'lastVisit',(select max(scanned_at) from confirmed),
 'averageGapMinutes',(select round(extract(epoch from avg(gap))/60,1) from gaps),
 'busiestHalfHour',(select date_bin('30 minutes',scanned_at,'2026-01-01'::timestamptz) from confirmed group by 1 order by count(*) desc,1 limit 1),
 'pauses',(select count(*) from pause_history where state='paused'),'pauseMinutes',(select round(coalesce(sum(extract(epoch from ended-created_at))/60,0),1) from pause_history where state='paused')) into visits,recap;
 return jsonb_build_object('arrivals',coalesce((select jsonb_agg(x) from jsonb_array_elements(arrivals->'arrivals') x where x->>'state'<>'completed' and not exists(select 1 from jsonb_array_elements(visits) v where v->>'groupCode'=x->>'groupCode')),'[]'::jsonb),'visits',visits,'recap',recap,'updatedAt',now());
end $$;
create function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; pid uuid; p app_private.portals; r text; channels jsonb;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select id into eid from app_private.events where slug=_event_slug;
 pid:=_portal_id;
 if pid is null then select o.portal_id into pid from app_private.portal_owners o join app_private.portals pp on pp.id=o.portal_id where o.user_id=auth.uid() and o.revoked_at is null and pp.event_id=eid and pp.approval_status='approved' order by pp.system_code limit 1; end if;
 if pid is null then return null; end if;
 select * into p from app_private.portals where id=pid and event_id=eid for update;
 r:=app_private.poortkamer_require(p.id);
 update app_private.portal_owners set last_seen_at=now() where portal_id=pid and user_id=auth.uid() and revoked_at is null;
 perform app_private.poortkamer_channels(eid,pid);
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'kind',c.kind,'name',c.name,'muted',coalesce(rd.muted,false),
 'unread',(select count(*) from app_private.portal_room_messages m where m.channel_id=c.id and m.id>coalesce(rd.last_read_id,0) and m.actor_id is distinct from auth.uid() and m.hidden_at is null)) order by c.kind,c.name),'[]'::jsonb)
 into channels from app_private.portal_room_channels c left join app_private.portal_room_reads rd on rd.channel_id=c.id and rd.user_id=auth.uid() where c.event_id=eid and (c.portal_id=pid or c.portal_id is null);
 return jsonb_build_object('userId',auth.uid(),'eventId',eid,'eventDate',(select local_date from app_private.events where id=eid),'updatedAt',now(),'role',r,'portalTopic',app_private.poortkamer_portal_topic(pid),'communityTopic',app_private.poortkamer_community_topic(eid),
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',pp.id,'code',pp.system_code,'name',pp.name) order by pp.system_code) from app_private.portal_owners o join app_private.portals pp on pp.id=o.portal_id where o.user_id=auth.uid() and o.revoked_at is null and pp.event_id=eid and pp.approval_status='approved'),'[]'::jsonb),
 'portal',jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'description',p.description,'world',(select name from app_private.worlds where id=p.world_id),'worldSlug',(select slug from app_private.worlds where id=p.world_id),
 'state',p.operation_status,'version',p.version,'pauseUntil',p.pause_until,'stock',p.stock_status,'helpRequestedAt',p.stock_help_requested_at,'lastActivity',p.room_updated_at,
 'locationVerified',coalesce((select verified_at is not null from app_private.portal_private_locations where portal_id=pid),false),
 'opensAt',(select min(opens_at) from app_private.portal_windows where portal_id=pid),'closesAt',(select max(closes_at) from app_private.portal_windows where portal_id=pid)),
 'team',coalesce((select jsonb_agg(jsonb_build_object('userId',o.user_id,'name',coalesce(nullif(concat_ws(' ',o.first_name,o.last_name),''),pr.display_name,'Poortwachter'),'role',o.role,'task',o.task_label,'lastSeenAt',o.last_seen_at) order by (o.role='owner') desc,o.accepted_at) from app_private.portal_owners o left join app_private.profiles pr on pr.user_id=o.user_id where o.portal_id=pid and o.revoked_at is null),'[]'::jsonb),
 'invites',case when r in ('owner','admin') then coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'name',concat_ws(' ',i.first_name,i.last_name),'email',i.email,'role',i.role,'expiresAt',i.expires_at,'status',case when i.revoked_at is not null then 'revoked' when i.accepted_at is not null then 'accepted' when i.expires_at<=now() then 'expired' else 'pending' end) order by i.created_at desc) from(select * from app_private.portal_team_invites where portal_id=pid order by created_at desc limit 100) i),'[]'::jsonb) else '[]'::jsonb end,
 'checklist',coalesce((select jsonb_agg(jsonb_build_object('item',c.item,'done',c.done,'changedAt',c.changed_at,'changedBy',coalesce(nullif(concat_ws(' ',o.first_name,o.last_name),''),pr.display_name,'Poortwachter'))) from app_private.portal_readiness c left join app_private.portal_owners o on o.portal_id=pid and o.user_id=c.changed_by and o.revoked_at is null left join app_private.profiles pr on pr.user_id=c.changed_by where c.portal_id=pid),'[]'::jsonb),
 'channels',channels,'visits',api.portal_visits_snapshot(pid),
 'urgentAnnouncement',(select jsonb_build_object('id',m.id,'body',m.body,'createdAt',m.created_at) from app_private.portal_room_messages m join app_private.portal_room_channels c on c.id=m.channel_id where c.event_id=eid and c.kind='announcements' and m.urgent and m.hidden_at is null order by m.id desc limit 1),
 'preferences',coalesce((select to_jsonb(pref)-'user_id' from app_private.portal_notification_preferences pref where user_id=auth.uid()),'{"next_10":true,"next_3":true,"arrived":true,"pause_1":true,"urgent":true,"mention":true,"access":true}'::jsonb));
end $$;
create function api.portal_notification_preferences_set(_preferences jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 insert into app_private.portal_notification_preferences(user_id,next_10,next_3,arrived,pause_1,urgent,mention,access)
 values(auth.uid(),coalesce((_preferences->>'next_10')::boolean,true),coalesce((_preferences->>'next_3')::boolean,true),coalesce((_preferences->>'arrived')::boolean,true),coalesce((_preferences->>'pause_1')::boolean,true),coalesce((_preferences->>'urgent')::boolean,true),coalesce((_preferences->>'mention')::boolean,true),coalesce((_preferences->>'access')::boolean,true))
 on conflict(user_id) do update set next_10=excluded.next_10,next_3=excluded.next_3,arrived=excluded.arrived,pause_1=excluded.pause_1,urgent=excluded.urgent,mention=excluded.mention,access=excluded.access;
 return _preferences;
end $$;
create function api.admin_portal_room_snapshot(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if auth.uid() is null or not (app_private.has_capability(eid,'event_admin') or app_private.has_capability(eid,'portals_manage') or app_private.has_capability(eid,'live_support')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform app_private.poortkamer_channels(eid);
 return jsonb_build_object('realtimeTopic','admin-event:'||eid,'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'stock',p.stock_status,'helpRequestedAt',p.stock_help_requested_at,'lastActivity',p.room_updated_at,
 'ready',(select count(*) from app_private.portal_readiness where portal_id=p.id and done),'online',(select count(*) from app_private.portal_owners where portal_id=p.id and revoked_at is null and last_seen_at>now()-interval '45 seconds'),
 'pending',(select count(*) from app_private.portal_team_invites where portal_id=p.id and revoked_at is null and accepted_at is null and expires_at>now()))) from(select * from app_private.portals where event_id=eid and approval_status='approved' order by system_code limit 500) p),'[]'::jsonb),
 'channels',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'kind',kind)) from app_private.portal_room_channels where event_id=eid and portal_id is null),'[]'::jsonb),
 'reports',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'messageId',r.message_id,'channelId',m.channel_id,'body',m.body,'reason',r.reason,'createdAt',r.created_at)) from(select rr.* from app_private.portal_room_reports rr join app_private.portal_room_messages mm on mm.id=rr.message_id join app_private.portal_room_channels cc on cc.id=mm.channel_id where cc.event_id=eid and rr.resolved_at is null order by rr.created_at limit 100) r join app_private.portal_room_messages m on m.id=r.message_id),'[]'::jsonb));
end $$;
create function app_private.poortkamer_tick() returns void language plpgsql security definer set search_path='' as $$
declare p app_private.portals; row record;
begin
 -- Lock the same portal row used by manual status changes. A later Stop clears pause_until.
 for p in select * from app_private.portals where operation_status='paused' and pause_until<=now() and approval_status='approved' order by id for update skip locked loop
  update app_private.portals set operation_status='open',pause_until=null,pause_after_current=false,version=version+1 where id=p.id;
  update app_private.event_route_settings set finale_available=true,version=version+1 where event_id=p.event_id and final_portal_id=p.id;
  insert into app_private.portal_status_history(portal_id,state,reason) values(p.id,'open','Getimede pauze verstreken');
  perform app_private.poortkamer_signal(p.id,'portal.pause.auto_resumed','{}','De getimede pauze is voorbij. De poort is weer open.');
 end loop;
 for p in select * from app_private.portals where operation_status='paused' and pause_until>now() and pause_until<=now()+interval '1 minute' loop
  perform app_private.poortkamer_push(p.id,'pause_1','pause:'||p.id||':'||p.pause_until);
 end loop;
 for row in
  with upcoming as(
   select id::text key,portal_id,reserved_from arrival from app_private.portal_reservations where status in ('held','active')
   union all
   select s.id::text,s.portal_id,s.planned_arrival_at from app_private.route_plan_stops s join app_private.route_plan_versions v on v.id=s.plan_version_id and v.state='published'
   join app_private.walking_groups g on g.id=v.group_id and g.route_mode<>'dynamic'
  ) select *,case when arrival<=now()+interval '3 minutes' then 'next_3' else 'next_10' end kind from upcoming where arrival>now() and arrival<=now()+interval '10 minutes'
 loop perform app_private.poortkamer_push(row.portal_id,row.kind,row.kind||':'||row.key); end loop;
 for row in select e.id,coalesce(s.portal_id,plan.portal_id) portal_id from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id where e.scanned_at>now()-interval '5 minutes'
 loop if row.portal_id is not null then perform app_private.poortkamer_push(row.portal_id,'arrived','arrived:'||row.id); end if; end loop;
 -- Delete messages and cascaded reactions/reports; retain membership/audit history.
 delete from app_private.portal_room_messages m using app_private.portal_room_channels c,app_private.events e where m.channel_id=c.id and c.event_id=e.id and now()>=((e.local_date+interval '1 month') at time zone e.timezone);
 delete from app_private.portal_push_outbox where completed_at<now()-interval '30 days';
end $$;
create function api.worker_claim_portal_push() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 with candidates as(
  select n.id from app_private.portal_push_outbox n where completed_at is null and available_at<=now() and (lease_until is null or lease_until<now()) order by available_at limit 10 for update skip locked
 ), claimed as(
  update app_private.portal_push_outbox n set lease_until=now()+interval '2 minutes',attempts=attempts+1 from candidates c where n.id=c.id returning n.*
 ) select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'kind',n.kind,'attempts',n.attempts,
 'targets',coalesce((select jsonb_agg(jsonb_build_object('subscriptionId',s.id,'endpoint',s.endpoint,'p256dh',s.p256dh,'auth',s.auth_secret))
 from app_private.push_subscriptions s join app_private.push_preferences pr on pr.user_id=s.user_id and pr.enabled
 left join app_private.portal_notification_preferences pref on pref.user_id=s.user_id
 where s.user_id=n.user_id and s.active and coalesce((to_jsonb(pref)->>n.kind)::boolean,true)
 and (n.kind='access' or (n.portal_id is not null and app_private.poortkamer_role(n.portal_id,n.user_id) is not null) or (n.kind='urgent' and exists(select 1 from app_private.portal_room_messages m join app_private.portal_room_channels c on c.id=m.channel_id where 'announcement:'||m.id=n.dedupe_key and app_private.poortkamer_community(c.event_id,n.user_id))))
 and not exists(select 1 from app_private.portal_push_deliveries d where d.notification_id=n.id and d.subscription_id=s.id)),'[]'::jsonb))),'[]'::jsonb) into result from claimed n;
 return result;
end $$;
create function api.worker_record_portal_push(_id uuid,_delivered uuid[],_failed boolean) returns void language plpgsql security definer set search_path='' as $$
declare n app_private.portal_push_outbox;
begin
 select * into n from app_private.portal_push_outbox where id=_id for update;
 insert into app_private.portal_push_deliveries(notification_id,subscription_id) select n.id,s.id from app_private.push_subscriptions s where s.id=any(_delivered) and s.user_id=n.user_id on conflict do nothing;
 update app_private.portal_push_outbox set completed_at=case when not _failed or attempts>=5 then now() end,lease_until=null,available_at=now()+make_interval(mins=>least(attempts,10)) where id=n.id;
 if _failed and n.attempts>=5 and n.kind='urgent' then
  perform app_private.poortkamer_email(null,n.user_id,'portal_urgent_announcement','push-fallback:'||n.id);
 end if;
end $$;
CREATE OR REPLACE FUNCTION app_private.can_access_realtime_topic(_topic text, _actor uuid DEFAULT auth.uid())
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select _actor is not null and case
    when _topic like 'registration:%' then exists (select 1 from app_private.registrations r
      where r.id::text = split_part(_topic, ':', 2) and app_private.is_household_member(r.household_id, _actor))
    when _topic like 'group:%' then exists (
      select 1 from app_private.walking_groups walking_group
      where walking_group.id::text = split_part(_topic, ':', 2) and (
        app_private.is_current_leader(walking_group.id, _actor)
        or app_private.has_capability(walking_group.event_id, 'live_support', _actor)
        or exists (
          select 1 from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          join app_private.group_registrations assignment on assignment.registration_id = registration.id
          where member.user_id = _actor and member.revoked_at is null
            and assignment.group_id = walking_group.id and assignment.superseded_at is null
        )
      )
    )
    when _topic like 'portal-room:%' then exists (select 1 from app_private.portals p where _topic=app_private.poortkamer_portal_topic(p.id) and app_private.poortkamer_role(p.id,_actor) is not null)
    when _topic like 'poortplein:%' then exists (select 1 from app_private.events e where _topic=app_private.poortkamer_community_topic(e.id) and app_private.poortkamer_community(e.id,_actor))
    when _topic like 'portal:%' then exists (
      select 1 from app_private.portals portal where portal.id::text = split_part(_topic, ':', 2) and portal.approval_status='approved' and (
        exists (select 1 from app_private.portal_owners owner
          where owner.portal_id = portal.id and owner.user_id = _actor and owner.revoked_at is null)
        or app_private.has_capability(portal.event_id, 'portals_manage', _actor)
      )
    )
    when _topic like 'messenger:%' then exists (
      select 1 from app_private.messenger_conversations conversation
      where conversation.id::text = split_part(_topic, ':', 2) and (
        app_private.messenger_is_organizer(conversation.event_id, _actor)
        or (conversation.participant_user_id = _actor and app_private.messenger_actor_can_use_subject(
          conversation.event_id, _actor, conversation.subject_kind, conversation.subject_id
        ))
      )
    )
    when _topic like 'messenger-admin:%' then app_private.messenger_is_organizer(
      nullif(split_part(_topic, ':', 2), '')::uuid, _actor
    )
    when _topic like 'admin-event:%' then exists (
      select 1 from app_private.events event_record
      where event_record.id::text = split_part(_topic, ':', 2) and (
        app_private.has_capability(event_record.id, 'event_admin', _actor)
        or app_private.has_capability(event_record.id, 'groups_manage', _actor)
        or app_private.has_capability(event_record.id, 'registration_manage', _actor)
        or app_private.has_capability(event_record.id, 'portals_manage', _actor)
        or app_private.has_capability(event_record.id, 'live_support', _actor)
      )
    )
    else false end
$function$;
create policy "poortkamer members receive presence" on realtime.messages for select to authenticated using (
 extension='presence' and (realtime.topic() like 'portal-room:%') and app_private.can_access_realtime_topic((select realtime.topic()),(select auth.uid()))
);
create policy "poortkamer members share presence" on realtime.messages for insert to authenticated with check (
 extension='presence' and (realtime.topic() like 'portal-room:%') and app_private.can_access_realtime_topic((select realtime.topic()),(select auth.uid()))
);
create function app_private.poortkamer_membership_epoch() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid:=coalesce(new.portal_id,old.portal_id); eid uuid; old_topic text; old_community text;
begin
 if tg_op='UPDATE' and new.role is not distinct from old.role and new.revoked_at is not distinct from old.revoked_at then return new; end if;
 select event_id into eid from app_private.portals where id=pid for update;
 old_topic:=app_private.poortkamer_portal_topic(pid); old_community:=app_private.poortkamer_community_topic(eid);
 update app_private.portals set room_generation=room_generation+1 where id=pid;
 update app_private.events set community_generation=community_generation+1 where id=eid;
 -- Only this final invalidation reaches the old channels. Future data/signals use a new authorized topic.
 perform realtime.send(jsonb_build_object('id',pid),'snapshot_changed',old_topic,true);
 perform realtime.send(jsonb_build_object('id',eid),'snapshot_changed',old_community,true);
 return coalesce(new,old);
end $$;
create trigger poortkamer_membership_changed after insert or update or delete on app_private.portal_owners for each row execute function app_private.poortkamer_membership_epoch();
create function api.portal_push_test_authorize(_portal_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin perform app_private.poortkamer_require(_portal_id); perform app_private.poortkamer_budget('push_test',2); return true; end $$;
CREATE OR REPLACE FUNCTION api.portal_application_save(_event_slug text, _payload jsonb, _expected_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  verified_email text;
  application app_private.portal_applications;
  next_status app_private.review_status;
  world_slug text;
  contact_name text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select lower(trim(email)) into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or pg_column_size(_payload) > 65536 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  world_slug := lower(coalesce(nullif(trim(_payload ->> 'requestedWorldSlug'), ''), 'anders'));
  contact_name := coalesce(nullif(trim(_payload ->> 'contactName'), ''), 'bewoner');
  _payload := _payload || jsonb_build_object(
    'email', verified_email,
    'address', case when jsonb_typeof(_payload -> 'address') = 'object' then _payload -> 'address' else '{}'::jsonb end,
    'requestedWorldSlug', world_slug,
    'portalName', case
      when world_slug = 'anders' and nullif(trim(_payload ->> 'portalName'), '') is null
        then left('Snoeppunt van ' || contact_name, 120)
      else coalesce(_payload ->> 'portalName', '')
    end,
    'description', case
      when world_slug = 'anders' and nullif(trim(_payload ->> 'description'), '') is null
        then 'Hier delen we tijdens de avond graag een snoepje uit.'
      else coalesce(_payload ->> 'description', '')
    end,
    'intensity', case
      when coalesce(_payload ->> 'intensity', '') ~ '^[1-4]$' then _payload ->> 'intensity'
      when world_slug = 'anders' then '1'
      else '2'
    end,
    'warnings', case
      when jsonb_typeof(_payload -> 'warnings') = 'object' then _payload -> 'warnings'
      else jsonb_build_object('smoke', false, 'flashes', false, 'sound', false, 'actors', false, 'allergens', false)
    end,
    'availableFrom', coalesce(nullif(trim(_payload ->> 'availableFrom'), ''), '17:00'),
    'availableUntil', coalesce(nullif(trim(_payload ->> 'availableUntil'), ''), '21:00'),
    'accessibility', coalesce(_payload ->> 'accessibility', ''),
    'entrance', coalesce(_payload ->> 'entrance', ''),
    'availability', case when jsonb_typeof(_payload -> 'availability') = 'boolean' then _payload -> 'availability' else 'true'::jsonb end,
    'locationConsent', case when jsonb_typeof(_payload -> 'locationConsent') = 'boolean' then _payload -> 'locationConsent' else 'false'::jsonb end
  );

  perform pg_advisory_xact_lock(hashtextextended(event_record.id::text || ':portal-account:' || actor::text, 0));
  select * into application from app_private.portal_applications
  where event_id = event_record.id and applicant_user_id = actor
  order by (review_status not in ('withdrawn', 'rejected')) desc, created_at desc
  limit 1 for update;
  perform app_private.poortkamer_require(p.id,'details') from app_private.portals p where p.application_id=application.id;
  if application.id is null and not coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, false) then
    raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;

  if application.id is null then
    insert into app_private.portal_applications(event_id, applicant_user_id, private_draft_data)
    values (event_record.id, actor, _payload) returning * into application;
  else
    if application.review_status in ('withdrawn', 'rejected') then raise exception 'APPLICATION_NOT_EDITABLE' using errcode = '23514'; end if;
    if _expected_version is not null and application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    next_status := case
      when application.review_status in ('submitted', 'approved') then 'changes_requested'::app_private.review_status
      else application.review_status
    end;
    update app_private.portal_applications
    set private_draft_data = _payload,
        review_status = next_status,
        review_feedback = case when next_status = 'changes_requested' then 'Gegevens door eigenaar gewijzigd; opnieuw beoordelen.' else review_feedback end,
        reviewed_by = case when next_status = 'changes_requested' then null else reviewed_by end,
        reviewed_at = case when next_status = 'changes_requested' then null else reviewed_at end,
        version = version + 1
    where id = application.id returning * into application;
  end if;
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'savedAt', application.updated_at);
end;
$function$;
CREATE OR REPLACE FUNCTION api.portal_application_submit(_application_id uuid, _expected_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  application app_private.portal_applications;
  actor_email text;
  receipt app_private.command_receipts;
  v_world_id uuid;
  draft jsonb;
  postal_code text;
begin
  perform app_private.poortkamer_require(p.id,'details') from app_private.portals p where p.application_id=_application_id;
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':portal.submit:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'portal.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into application from app_private.portal_applications
  where id = _application_id and applicant_user_id = actor for update;
  if application.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if application.version <> _expected_version or application.review_status not in ('draft', 'changes_requested') then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  select lower(trim(email)) into actor_email from auth.users where id = actor and email_confirmed_at is not null;
  draft := application.private_draft_data;
  postal_code := upper(replace(trim(coalesce(draft #>> '{address,postalCode}', '')), ' ', ''));
  select world.id into v_world_id from app_private.worlds world
  where world.event_id = application.event_id and world.slug = lower(trim(draft ->> 'requestedWorldSlug'));
  if actor_email is null
     or lower(trim(coalesce(draft ->> 'email', ''))) <> actor_email
     or char_length(trim(coalesce(draft ->> 'contactName', ''))) not between 2 and 120
     or char_length(trim(coalesce(draft ->> 'phone', ''))) not between 6 and 32
     or (nullif(trim(coalesce(draft #>> '{address,street}', '')), '') is not null
       and char_length(trim(draft #>> '{address,street}')) not between 2 and 120)
     or (nullif(trim(coalesce(draft #>> '{address,houseNumber}', '')), '') is not null
       and char_length(trim(draft #>> '{address,houseNumber}')) not between 1 and 12)
     or char_length(trim(coalesce(draft #>> '{address,addition}', ''))) > 12
     or (postal_code <> '' and postal_code !~ '^[0-9]{4}[A-Z]{2}$')
     or char_length(trim(coalesce(draft ->> 'entrance', ''))) > 500
     or (nullif(trim(coalesce(draft ->> 'portalName', '')), '') is not null
       and char_length(trim(draft ->> 'portalName')) not between 2 and 120)
     or char_length(trim(coalesce(draft ->> 'description', ''))) > 1000
     or coalesce(draft ->> 'intensity', '') !~ '^[1-4]$'
     or v_world_id is null
     or coalesce(draft ->> 'availableFrom', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'availableUntil', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'accessibility', '') not in ('', 'step_free', 'steps', 'mixed', 'unknown')
     or coalesce(jsonb_typeof(draft -> 'warnings'), '') <> 'object'
     or (draft ->> 'availableUntil')::time <= (draft ->> 'availableFrom')::time then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  update app_private.portal_applications
  set review_status = 'submitted', requested_world_id = v_world_id, review_feedback = null,
      submitted_at = now(), reviewed_by = null, reviewed_at = null, version = version + 1
  where id = application.id returning * into application;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'portal:' || application.id::text || ':received:' || application.version::text,
    'portal_received', actor::text, actor_email,
    jsonb_build_object('applicationId', application.id, 'applicationVersion', application.version)
  ) on conflict (dedupe_key) do nothing;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (application.event_id, actor, 'portal_application.submitted', 'portal_application', application.id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'portal.submit', _idempotency_key, _request_hash,
    jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$;
CREATE OR REPLACE FUNCTION api.portal_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; application app_private.portal_applications; portal app_private.portals;
begin
  result := app_private.portal_snapshot_before_codes(_event_slug);
  if result is null then return null; end if;
  if result #>> '{application,id}' is not null then
    select * into application from app_private.portal_applications where id = (result #>> '{application,id}')::uuid;
  end if;
  result := jsonb_set(result, '{application}', coalesce(result -> 'application', '{}'::jsonb) || jsonb_build_object(
    'code', application.system_code, 'systemCode', application.system_code
  ), true);
  if result #>> '{portal,id}' is not null then
    select * into portal from app_private.portals where id = (result #>> '{portal,id}')::uuid;
    perform app_private.poortkamer_require(portal.id);
    result := jsonb_set(result, '{portal}', coalesce(result -> 'portal', '{}'::jsonb) || jsonb_build_object(
      'code', portal.system_code, 'systemCode', portal.system_code
    ), true);
  end if;
  return result;
end;
$function$;
create function app_private.poortkamer_visit_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid; sid uuid;
begin
 if tg_table_name='portal_reservations' then pid:=coalesce(new.portal_id,old.portal_id);
 elsif tg_table_name='scan_evidence' then
  sid:=coalesce(new.run_stop_id,old.run_stop_id);
  select coalesce(s.portal_id,plan.portal_id) into pid from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id where s.id=sid;
 else
  select coalesce(new.portal_id,plan.portal_id) into pid from app_private.route_plan_stops plan where plan.id=new.plan_stop_id;
  pid:=coalesce(new.portal_id,pid);
 end if;
 if pid is not null then perform realtime.send(jsonb_build_object('id',pid),'snapshot_changed',app_private.poortkamer_portal_topic(pid),true); end if;
 return coalesce(new,old);
end $$;
create trigger poortkamer_reservation_changed after insert or update or delete on app_private.portal_reservations for each row execute function app_private.poortkamer_visit_signal();
create trigger poortkamer_scan_changed after insert on app_private.scan_evidence for each row execute function app_private.poortkamer_visit_signal();
create trigger poortkamer_stop_changed after update on app_private.run_stops for each row execute function app_private.poortkamer_visit_signal();
-- All new tables remain inaccessible through PostgREST, even with schema usage.
do $$ declare t text; fn record; begin
 foreach t in array array['portal_team_invites','portal_readiness','portal_status_history','portal_room_channels','portal_room_messages','portal_room_reads','portal_room_reactions','portal_room_reports','portal_community_mutes','portal_notification_preferences','portal_push_outbox','portal_push_deliveries','portal_room_budgets'] loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated',t);
 end loop;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname like 'poortkamer_%' loop
  execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
 end loop;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.proname in ('portal_team_command','portal_invitation_accept','portal_room_update','portal_chat_snapshot','portal_chat_send','portal_chat_action','portal_visits_snapshot','portal_room_snapshot','portal_notification_preferences_set','admin_portal_room_snapshot','portal_push_test_authorize') loop
  execute format('revoke all on function %s from public,anon',fn.signature);
  execute format('grant execute on function %s to authenticated',fn.signature);
 end loop;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.proname in ('portal_invitation_check','portal_invitation_mail_payload','worker_claim_portal_push','worker_record_portal_push') loop
  execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
  execute format('grant execute on function %s to service_role',fn.signature);
 end loop;
end $$;
revoke all on sequence app_private.portal_room_messages_id_seq from public,anon,authenticated;
select cron.schedule('duindorp-poortkamer-maintenance','* * * * *','select app_private.poortkamer_tick()');
commit;
