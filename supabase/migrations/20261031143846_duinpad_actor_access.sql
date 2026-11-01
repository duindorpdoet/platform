set lock_timeout = '5s';

-- Actor access is independent of registrations, children, household and route roles.
create table app_private.duinpad_actor_access (
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null references app_private.events(id),
 user_id uuid references auth.users(id),
 email text not null check(email=lower(trim(email)) and char_length(email) between 3 and 254),
 display_name text not null check(char_length(display_name) between 1 and 100),
 status text not null default 'pending' check(status in ('pending','active','revoked')),
 permissions text[] not null default '{}',
 permissions_revision integer not null default 1 check(permissions_revision>0),
 last_seen_at timestamptz,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(event_id,email), unique(event_id,user_id),
 check(permissions <@ array['heks.ready','heks.go','zone1.trigger','zone2.trigger','zone3.trigger','finale.ready','finale.go','zone1.stop','zone2.stop','zone3.stop','stop-all']::text[]),
 check(status <> 'active' or user_id is not null)
);
create table app_private.duinpad_actor_invitations (
 id uuid primary key,
 access_id uuid not null references app_private.duinpad_actor_access(id),
 event_id uuid not null references app_private.events(id),
 email text not null,
 token_hash bytea not null unique check(octet_length(token_hash)=32),
 expires_at timestamptz not null,
 claimed_at timestamptz,
 claimed_by uuid references auth.users(id),
 revoked_at timestamptz,
 created_at timestamptz not null default now(),
 check(expires_at>created_at),
 check((claimed_at is null)=(claimed_by is null))
);
create unique index duinpad_actor_one_invitation on app_private.duinpad_actor_invitations(access_id) where revoked_at is null and claimed_at is null;
create table app_private.duinpad_actor_commands (
 command_id uuid primary key,
 event_id uuid not null references app_private.events(id),
 access_id uuid not null references app_private.duinpad_actor_access(id),
 actor_id uuid not null references auth.users(id),
 action text not null,
 permissions_revision integer not null,
 group_id text,
 payload_text text not null,
 payload_hash text not null check(payload_hash ~ '^[a-f0-9]{64}$'),
 status text not null default 'requested' check(status in ('requested','started','blocked','not_dispatched','unknown','interrupted','recovery_required')),
 result jsonb not null default '{}',
 issued_at timestamptz not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index duinpad_actor_commands_owner on app_private.duinpad_actor_commands(actor_id,event_id,created_at desc);
create unique index duinpad_actor_one_pending on app_private.duinpad_actor_commands(access_id,action) where status in ('requested','unknown','interrupted','recovery_required');
alter table app_private.duinpad_actor_access enable row level security;
alter table app_private.duinpad_actor_invitations enable row level security;
alter table app_private.duinpad_actor_commands enable row level security;
revoke all on app_private.duinpad_actor_access,app_private.duinpad_actor_invitations,app_private.duinpad_actor_commands from public,anon,authenticated,service_role;

create function app_private.duinpad_actor_can(_event_id uuid,_actor uuid,_permission text) returns boolean
language sql stable security definer set search_path='' as $$
 select _actor is not null and exists(select 1 from app_private.duinpad_actor_access a join auth.users u on u.id=a.user_id
 where a.event_id=_event_id and a.user_id=_actor and a.status='active' and _permission=any(a.permissions)
 and u.email_confirmed_at is not null and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and lower(trim(u.email))=a.email)
$$;

create function app_private.duinpad_actor_rate(_event uuid,_scope text,_max integer) returns void
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 insert into app_private.rate_limit_buckets(scope,opaque_subject_hash,window_start,count,expires_at)
 values('duinpad_actor:'||_scope,auth.uid()::text||':'||_event::text,date_trunc('minute',now()),1,now()+interval '2 minutes')
 on conflict(scope,opaque_subject_hash,window_start) do update set count=app_private.rate_limit_buckets.count+1 returning count into n;
 if n>_max then raise exception 'RATE_LIMITED' using errcode='P0001';end if;
end $$;

create function api.duinpad_actor_admin_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid:=app_private.current_event_id(_event_slug);
begin
 if not app_private.has_capability(eid,'event_admin') then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return jsonb_build_object('eventId',eid,'actors',coalesce((select jsonb_agg(jsonb_build_object(
 'id',a.id,'name',a.display_name,'email',a.email,'userId',a.user_id,'status',case when a.status='pending' and i.expires_at<=now() then 'expired' else a.status end,
 'permissions',a.permissions,'revision',a.permissions_revision,'lastSeenAt',a.last_seen_at,'expiresAt',i.expires_at,'activatedAt',i.claimed_at,
 'mailStatus',(select status::text from app_private.email_outbox o where o.message_type='actor_invitation' and o.payload->>'invitationId'=i.id::text order by created_at desc limit 1)) order by a.display_name,a.id)
 from app_private.duinpad_actor_access a left join lateral(select * from app_private.duinpad_actor_invitations t where t.access_id=a.id order by created_at desc limit 1)i on true where a.event_id=eid),'[]'::jsonb));
end $$;

-- An invitation always gets a new random UUID; plaintext claim material never enters an outbox.
create function api.duinpad_actor_admin_command(_event_slug text,_action text,_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid:=app_private.current_event_id(_event_slug); a app_private.duinpad_actor_access; iid uuid; p text[]; recipient text; t_hash bytea;
begin
 if not app_private.has_capability(eid,'event_admin') then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform app_private.duinpad_actor_rate(eid,'admin',30);
 if _action in ('invite','reinvite') then
  iid:=(_payload->>'invitationId')::uuid; recipient:=lower(trim(_payload->>'email')); t_hash:=decode(_payload->>'tokenHash','hex');
  if octet_length(t_hash)<>32 or recipient !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'INVALID_INPUT' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(eid::text||':actor:'||recipient,0));
  select * into a from app_private.duinpad_actor_access where event_id=eid and email=recipient for update;
  if _action='invite' and a.id is not null then raise exception 'ALREADY_INVITED' using errcode='22023';end if;
  if _action='reinvite' and (a.id is null or a.id is distinct from (_payload->>'id')::uuid) then raise exception 'INVALID_INPUT' using errcode='22023';end if;
  if a.id is null then
   insert into app_private.duinpad_actor_access(event_id,email,display_name,created_by) values(eid,recipient,trim(_payload->>'name'),auth.uid()) returning * into a;
  else
   update app_private.duinpad_actor_access set status='pending',permissions_revision=permissions_revision+1,updated_at=now() where id=a.id returning * into a;
  end if;
  update app_private.duinpad_actor_invitations set revoked_at=now() where access_id=a.id and revoked_at is null;
  update app_private.email_outbox set status='suppressed',last_error_code='ACTOR_INVITATION_SUPERSEDED',updated_at=now()
   where message_type='actor_invitation' and payload->>'accessId'=a.id::text and status in ('pending','deferred','processing');
  insert into app_private.duinpad_actor_invitations(id,access_id,event_id,email,token_hash,expires_at)
  values(iid,a.id,eid,recipient,t_hash,now()+interval '7 days');
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  values('actor-invitation:'||iid,'actor_invitation',a.id::text,recipient,jsonb_build_object('invitationId',iid,'accessId',a.id));
 elsif _action in ('permissions','revoke') then
  select * into a from app_private.duinpad_actor_access where id=(_payload->>'id')::uuid and event_id=eid for update;
  if a.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if a.permissions_revision is distinct from (_payload->>'revision')::integer then raise exception 'STALE_REVISION' using errcode='40001';end if;
  if _action='permissions' then
   if jsonb_typeof(_payload->'permissions')<>'array' then raise exception 'INVALID_INPUT' using errcode='22023';end if;
   select coalesce(array_agg(distinct v),'{}'::text[]) into p from jsonb_array_elements_text(_payload->'permissions') v;
   update app_private.duinpad_actor_access set permissions=p,permissions_revision=permissions_revision+1,updated_at=now() where id=a.id returning * into a;
  else
   update app_private.duinpad_actor_access set status='revoked',permissions='{}',permissions_revision=permissions_revision+1,updated_at=now() where id=a.id returning * into a;
   update app_private.duinpad_actor_invitations set revoked_at=now() where access_id=a.id and revoked_at is null;
   update app_private.email_outbox set status='suppressed',last_error_code='ACTOR_INVITATION_REVOKED',updated_at=now()
    where message_type='actor_invitation' and payload->>'accessId'=a.id::text and status in ('pending','deferred','processing');
  end if;
 else raise exception 'INVALID_INPUT' using errcode='22023';end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,auth.uid(),'duinpad.actor.'||_action,'actor_access',a.id,jsonb_build_object('revision',a.permissions_revision,'permissions',a.permissions,'status',a.status));
 return jsonb_build_object('id',a.id,'eventId',eid,'actorId',a.user_id,'active',a.status='active','permissions',a.permissions,'revision',a.permissions_revision);
end $$;

create function api.duinpad_actor_claim(_event_slug text,_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid:=app_private.current_event_id(_event_slug); i app_private.duinpad_actor_invitations; a app_private.duinpad_actor_access; verified_email text;
begin
 select lower(trim(email)) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null and deleted_at is null and (banned_until is null or banned_until<=now());
 if verified_email is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform app_private.duinpad_actor_rate(eid,'claim',12);
 select * into i from app_private.duinpad_actor_invitations where event_id=eid and token_hash=decode(_token_hash,'hex') for update;
 if i.id is null or i.revoked_at is not null then raise exception 'INVITATION_UNAVAILABLE' using errcode='22023';end if;
 if i.email<>verified_email then raise exception 'INVITATION_WRONG_ACCOUNT' using errcode='42501';end if;
 select * into a from app_private.duinpad_actor_access where id=i.access_id for update;
 if i.claimed_by=auth.uid() and a.status='active' and a.user_id=auth.uid() then return jsonb_build_object('active',true,'duplicate',true);end if;
 if i.expires_at<=now() or i.claimed_at is not null then raise exception 'INVITATION_UNAVAILABLE' using errcode='22023';end if;
 if a.user_id is not null and a.user_id<>auth.uid() then raise exception 'INVITATION_IDENTITY_CONFLICT' using errcode='42501';end if;
 update app_private.duinpad_actor_invitations set claimed_at=now(),claimed_by=auth.uid() where id=i.id;
 update app_private.duinpad_actor_access set status='active',user_id=auth.uid(),permissions_revision=permissions_revision+1,updated_at=now() where id=a.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id) values(eid,auth.uid(),'duinpad.actor.claim','actor_access',a.id);
 return jsonb_build_object('active',true,'duplicate',false);
end $$;

create function api.duinpad_actor_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.duinpad_actor_access; eid uuid:=app_private.current_event_id(_event_slug);
begin
 select x.* into a from app_private.duinpad_actor_access x join auth.users u on u.id=x.user_id
 where x.event_id=eid and x.user_id=auth.uid() and x.status='active' and u.email_confirmed_at is not null and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and x.email=lower(trim(u.email));
 if a.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 update app_private.duinpad_actor_access set last_seen_at=now() where id=a.id;
 return jsonb_build_object('id',a.id,'eventId',eid,'actorId',a.user_id,'name',a.display_name,'permissions',a.permissions,'revision',a.permissions_revision,'active',true,
 'receipts',coalesce((select jsonb_agg(r) from(select command_id as "commandId",action,status,result,created_at as "createdAt" from app_private.duinpad_actor_commands where actor_id=auth.uid() and event_id=eid order by created_at desc limit 10)r),'[]'::jsonb));
end $$;

create function api.duinpad_actor_reserve(_event_slug text,_command_id uuid,_payload_text text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid:=app_private.current_event_id(_event_slug); a app_private.duinpad_actor_access; p jsonb:=_payload_text::jsonb; c app_private.duinpad_actor_commands; h text;
begin
 select * into a from app_private.duinpad_actor_access where event_id=eid and user_id=auth.uid() for update;
 if not app_private.duinpad_actor_can(eid,auth.uid(),p->>'action') then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 h:=encode(extensions.digest(convert_to(_payload_text,'UTF8'),'sha256'),'hex');
 select * into c from app_private.duinpad_actor_commands where command_id=_command_id;
 if c.command_id is not null then
  if c.actor_id<>auth.uid() or c.payload_hash<>h then raise exception 'COMMAND_CONFLICT' using errcode='22023';end if;
  return jsonb_build_object('dispatch',false,'status',c.status,'commandId',c.command_id,'result',c.result);
 end if;
 perform app_private.duinpad_actor_rate(eid,'command',30);
 if char_length(_payload_text)>4096 or p->>'version'<>'duinpad.actor.v1' or p->>'command_id'<>_command_id::text
  or p->>'event_scope_id'<>eid::text or p->>'actor_subject'<>auth.uid()::text or (p->>'permissions_revision')::integer<>a.permissions_revision
  or (p->>'issued_at')::numeric<extract(epoch from now())-5 or (p->>'issued_at')::numeric>extract(epoch from now())+2
  or (p->>'expires_at')::numeric>(p->>'issued_at')::numeric+8 or (p->>'expires_at')::numeric<=extract(epoch from now()) then
  raise exception 'INVALID_COMMAND' using errcode='22023';end if;
 insert into app_private.duinpad_actor_commands(command_id,event_id,access_id,actor_id,action,permissions_revision,group_id,payload_text,payload_hash,issued_at)
 values(_command_id,eid,a.id,auth.uid(),p->>'action',a.permissions_revision,p->>'group_id',_payload_text,h,to_timestamp((p->>'issued_at')::numeric));
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,auth.uid(),'duinpad.actor.command','actor_command',_command_id,jsonb_build_object('action',p->>'action','revision',a.permissions_revision));
 return jsonb_build_object('dispatch',true,'commandId',_command_id,'status','requested');
end $$;

-- No execution API: only the trusted server records an authenticated relay receipt.
create function api.duinpad_actor_finish(_command_id uuid,_status text,_result jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c app_private.duinpad_actor_commands;
begin
 if _status not in ('started','blocked','not_dispatched','unknown','interrupted','recovery_required') or pg_column_size(_result)>2048 then raise exception 'INVALID_INPUT' using errcode='22023';end if;
 select * into c from app_private.duinpad_actor_commands where command_id=_command_id for update;
 if c.command_id is null then raise exception 'COMMAND_NOT_FOUND' using errcode='22023';end if;
 if c.status='started' then return jsonb_build_object('status',c.status,'result',c.result);end if;
 if c.status not in ('requested','unknown','interrupted','recovery_required') then return jsonb_build_object('status',c.status,'result',c.result);end if;
 update app_private.duinpad_actor_commands set status=_status,result=_result,updated_at=now() where command_id=_command_id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(c.event_id,c.actor_id,'duinpad.actor.receipt','actor_command',_command_id,jsonb_build_object('status',_status));
 return jsonb_build_object('status',_status,'result',_result);
end $$;
create function api.duinpad_actor_receipt(_event_slug text,_command_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c app_private.duinpad_actor_commands;
begin
 select * into c from app_private.duinpad_actor_commands where command_id=_command_id and actor_id=auth.uid() and event_id=app_private.current_event_id(_event_slug);
 if c.command_id is null or not app_private.duinpad_actor_can(c.event_id,auth.uid(),c.action) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return jsonb_build_object('commandId',c.command_id,'eventId',c.event_id,'groupId',c.group_id,'action',c.action,'payloadHash',c.payload_hash,'status',c.status,'result',c.result);
end $$;

create function api.worker_duinpad_actor_invitation(_outbox_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.duinpad_actor_invitations; a app_private.duinpad_actor_access; o app_private.email_outbox; material jsonb;
begin
 select * into o from app_private.email_outbox where id=_outbox_id and message_type='actor_invitation' and status='processing' for update;
 if o.id is null then return null;end if;
 select * into i from app_private.duinpad_actor_invitations where id=(o.payload->>'invitationId')::uuid and claimed_at is null and revoked_at is null and expires_at>now();
 if i.id is null then return null;end if;
 select * into a from app_private.duinpad_actor_access where id=i.access_id and status='pending' and email=i.email;
 if a.id is null or o.recipient_email<>i.email then return null;end if;
 material:=o.payload->'material';
 if material is null then
  material:=jsonb_build_object('invitationId',i.id,'eventId',i.event_id,'name',a.display_name,'invitedEmail',i.email,'permissions',a.permissions,'expiresAt',i.expires_at);
  update app_private.email_outbox set payload=payload||jsonb_build_object('material',material) where id=o.id;
 end if;
 return material||jsonb_build_object('tokenHash',encode(i.token_hash,'hex'));
end $$;

-- Extend the existing chooser and its existing remember command, preserving every other role.
alter function api.account_app_snapshot(text) rename to account_app_snapshot_before_duinpad_actor;
revoke all on function api.account_app_snapshot_before_duinpad_actor(text) from public,anon,authenticated,service_role;
create function api.account_app_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb:=api.account_app_snapshot_before_duinpad_actor(_event_slug); eid uuid:=(result->>'eventId')::uuid;
begin
 if exists(select 1 from app_private.duinpad_actor_access a join auth.users u on u.id=a.user_id where a.event_id=eid and a.user_id=auth.uid() and a.status='active' and u.email_confirmed_at is not null and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()) and a.email=lower(trim(u.email))) then
  result:=jsonb_set(result,'{environments}',(result->'environments')||jsonb_build_array(jsonb_build_object('id','actor','kind','actor','label','Acteurskamer','description','Alleen jouw toegewezen showknoppen en hun actuele beschikbaarheid.','path','/omgeving/acteur')));
  if exists(select 1 from app_private.account_app_preferences p where p.event_id=eid and p.user_id=auth.uid() and p.last_target='{"kind":"adult","id":"actor"}'::jsonb) then result:=jsonb_set(result,'{resume}','{"kind":"adult","id":"actor"}'::jsonb);end if;
 end if;
 return result;
end $$;
revoke all on function app_private.duinpad_actor_can(uuid,uuid,text),app_private.duinpad_actor_rate(uuid,text,integer) from public,anon,authenticated,service_role;
revoke all on function api.duinpad_actor_admin_snapshot(text),api.duinpad_actor_admin_command(text,text,jsonb),api.duinpad_actor_claim(text,text),api.duinpad_actor_snapshot(text),api.duinpad_actor_reserve(text,uuid,text),api.duinpad_actor_receipt(text,uuid),api.account_app_snapshot(text),api.duinpad_actor_finish(uuid,text,jsonb),api.worker_duinpad_actor_invitation(uuid) from public,anon,authenticated,service_role;
grant execute on function api.duinpad_actor_admin_snapshot(text),api.duinpad_actor_admin_command(text,text,jsonb),api.duinpad_actor_claim(text,text),api.duinpad_actor_snapshot(text),api.duinpad_actor_reserve(text,uuid,text),api.duinpad_actor_receipt(text,uuid),api.account_app_snapshot(text) to authenticated;
grant execute on function api.duinpad_actor_finish(uuid,text,jsonb),api.worker_duinpad_actor_invitation(uuid) to service_role;

-- Recovered mail envelopes must not bypass a superseded/revoked actor invitation.
alter function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) set schema app_private;
alter function app_private.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) rename to worker_mail_prepare_before_duinpad_actor;
revoke all on function app_private.worker_mail_prepare_before_duinpad_actor(text,text,uuid,uuid,text,text,text,jsonb,text,text) from public,anon,authenticated,service_role;
create function api.worker_mail_prepare(_environment text,_key text,_config_id uuid,_outbox_id uuid,_channel text,
 _message_type text,_recipient text,_payload jsonb,_payload_hash text,_credential_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.email_outbox; envelope app_private.mail_envelopes; material jsonb;
begin
 if _message_type='actor_invitation' then
  perform pg_advisory_xact_lock(hashtextextended(_environment||':'||_key,0));
  select * into envelope from app_private.mail_envelopes where environment=_environment and logical_key=_key for update;
  if envelope.status is distinct from 'accepted' then
   select * into o from app_private.email_outbox where id=_outbox_id for update;
   material:=api.worker_duinpad_actor_invitation(_outbox_id);
   if material is null or lower(trim(o.recipient_email)) is distinct from lower(trim(_recipient)) then
    if envelope.id is not null then update app_private.mail_envelopes set status='reconcile',error_code='ACTOR_INVITATION_SUPERSEDED',lease_until=null where id=envelope.id;end if;
    return jsonb_build_object('dispatch',false,'status','failed','error_code','ACTOR_INVITATION_SUPERSEDED');
   end if;
   if envelope.id is not null and envelope.payload_hash is distinct from _payload_hash then
    update app_private.mail_envelopes set status='reconcile',error_code='ACTOR_MAIL_MATERIAL_CHANGED',lease_until=null where id=envelope.id;
    return jsonb_build_object('dispatch',false,'status','reconcile','error_code','ACTOR_MAIL_MATERIAL_CHANGED');
   end if;
  end if;
 end if;
 return app_private.worker_mail_prepare_before_duinpad_actor(_environment,_key,_config_id,_outbox_id,_channel,_message_type,_recipient,case when _message_type='actor_invitation' then null else _payload end,_payload_hash,_credential_hash);
end $$;
revoke all on function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) from public,anon,authenticated;
grant execute on function api.worker_mail_prepare(text,text,uuid,uuid,text,text,text,jsonb,text,text) to service_role;
notify pgrst,'reload schema';
