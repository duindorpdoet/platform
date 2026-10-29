-- An organizer creates the real registration/children, without inventing an Auth identity.
alter table app_private.households alter column primary_contact_user_id drop not null;
create table app_private.registration_activations(
 registration_id uuid primary key references app_private.registrations(id) on delete restrict,
 event_id uuid not null references app_private.events(id),
 normalized_email text not null check(normalized_email=lower(trim(normalized_email)) and length(normalized_email)<=254),
 parent_name text not null check(length(parent_name) between 2 and 120),
 invitation_id uuid not null default gen_random_uuid(),
 invite_token_hash bytea unique,
 invitation_version integer not null default 1 check(invitation_version>0),
 issued_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '7 days',
 activated_at timestamptz,activated_user_id uuid references auth.users(id),
 created_by uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 unique(event_id,normalized_email),check(expires_at>issued_at),
 check((activated_at is null)=(activated_user_id is null))
);
alter table app_private.registration_activations enable row level security;
revoke all on app_private.registration_activations from public,anon,authenticated;

create function app_private.require_pending_household_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from app_private.households h where h.id=new.id and h.primary_contact_user_id is null
  and not exists(select 1 from app_private.registrations r join app_private.registration_activations a on a.registration_id=r.id
   where r.household_id=h.id and a.activated_at is null)) then raise exception 'PENDING_HOUSEHOLD_REQUIRES_INVITATION' using errcode='23514';end if;
 return null;
end $$;
create constraint trigger households_pending_identity after insert or update on app_private.households
 deferrable initially deferred for each row execute function app_private.require_pending_household_identity();
revoke all on function app_private.require_pending_household_identity() from public,anon,authenticated;

-- Reuse the existing environment-owned invitation key with a separate domain.
-- No bearer reference is stored in an outbox, admin response, audit or snapshot.
create function app_private.registration_activation_token(_registration uuid) returns text
language sql stable security definer set search_path='' as $$
 select encode(extensions.hmac(convert_to('registration-activation:v1:'||a.registration_id::text||':'||a.invitation_id::text||':'||a.invitation_version::text,'UTF8'),
  decode(k.decrypted_secret,'hex'),'sha256'),'hex')
 from app_private.registration_activations a cross join vault.decrypted_secrets k
 where a.registration_id=_registration and k.name='poortkamer_invitation_v1';
$$;
create function app_private.registration_activation_action_path(_registration uuid) returns text
language sql stable security definer set search_path='' as $$
 select '/uitnodiging/inschrijving/'||app_private.registration_activation_token(a.registration_id)
 from app_private.registration_activations a join app_private.registrations r on r.id=a.registration_id
 where a.registration_id=_registration and a.activated_at is null and a.expires_at>statement_timestamp() and r.status='submitted';
$$;
revoke all on function app_private.registration_activation_token(uuid),app_private.registration_activation_action_path(uuid) from public,anon,authenticated;

create function app_private.registration_activation_issue(_registration uuid,_actor uuid,_command uuid) returns void
language plpgsql security definer set search_path='' as $$
declare a app_private.registration_activations;
begin
 update app_private.registration_activations set invite_token_hash=extensions.digest(app_private.registration_activation_token(registration_id),'sha256')
 where registration_id=_registration returning * into a;
 if a.invite_token_hash is null then raise exception 'INVITATION_KEY_UNAVAILABLE' using errcode='55000';end if;
 update app_private.email_outbox set status='suppressed',last_error_code='REGISTRATION_INVITATION_SUPERSEDED',updated_at=clock_timestamp()
 where message_type='registration_activation' and payload->>'registrationId'=_registration::text and status in('pending','deferred');
 insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 values('registration:'||_registration||':activation:'||a.invitation_version,'registration_activation','registration:'||_registration,a.normalized_email,
  jsonb_build_object('registrationId',_registration,'invitationVersion',a.invitation_version,'commandId',_command));
end $$;
revoke all on function app_private.registration_activation_issue(uuid,uuid,uuid) from public,anon,authenticated;

create function app_private.registration_activation_identity() returns text
language plpgsql stable security definer set search_path='' as $$
declare verified_email text; sid uuid;
begin
 begin sid:=nullif(auth.jwt()->>'session_id','')::uuid;exception when others then sid:=null;end;
 select lower(trim(u.email)) into verified_email from auth.users u
 where u.id=auth.uid() and u.email_confirmed_at is not null and u.deleted_at is null
  and (u.banned_until is null or u.banned_until<=statement_timestamp());
 if verified_email is null or not exists(select 1 from auth.sessions s where s.id=sid and s.user_id=auth.uid() and (s.not_after is null or s.not_after>statement_timestamp())) then raise exception 'VERIFIED_IDENTITY_REQUIRED' using errcode='42501';end if;
 return verified_email;
end $$;
revoke all on function app_private.registration_activation_identity() from public,anon,authenticated;

create function api.admin_registration_create(_event_slug text,_payload jsonb,_expected_event_version integer,_command_id uuid,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; actor uuid:=auth.uid(); h uuid; rid uuid:=gen_random_uuid(); reg app_private.registrations;
 v_email text:=lower(trim(_payload->>'email')); parent text:=trim(_payload->>'parentName'); child jsonb; count_children integer;
 payment_total integer; gid uuid:=nullif(_payload->>'groupId','')::uuid; pid uuid:=nullif(_payload->>'partyId','')::uuid; party_groups uuid[];
 digest text; receipt app_private.command_receipts; result jsonb; cid uuid; start_at timestamptz; end_at timestamptz;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if actor is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',actor) or app_private.has_capability(e.id,'registration_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if (gid is not null or pid is not null) and not(app_private.has_capability(e.id,'event_admin',actor) or app_private.has_capability(e.id,'groups_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _command_id is null or length(trim(coalesce(_reason,''))) not between 10 and 500 or jsonb_typeof(_payload)<>'object' then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 digest:=encode(extensions.digest(jsonb_build_array(e.id,_payload,_expected_event_version,trim(_reason))::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='registration.admin.create' and idempotency_key=_command_id::text;
 if receipt.id is not null then
  if receipt.request_hash<>digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;
  return receipt.safe_result;
 end if;
 if e.settings_version is distinct from _expected_event_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
 if length(coalesce(parent,'')) not between 2 and 120 or length(coalesce(v_email,''))>254 or coalesce(v_email,'')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  or (nullif(trim(_payload->>'phone'),'') is not null and length(trim(_payload->>'phone')) not between 6 and 32)
  or jsonb_typeof(_payload->'children')<>'array' then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 -- Event lock serializes duplicate checks with other organizer create/move commands.
 select r.* into reg from app_private.registrations r
 where r.event_id=e.id and r.status<>'cancelled' and (
  exists(select 1 from app_private.registration_activations a where a.registration_id=r.id and a.normalized_email=v_email)
  or exists(select 1 from app_private.household_members m join auth.users u on u.id=m.user_id
   where m.household_id=r.household_id and m.revoked_at is null and u.email_confirmed_at is not null and lower(trim(u.email))=v_email))
 order by r.created_at,r.id limit 1;
 if reg.id is not null then
  return jsonb_build_object('existing',true,'existingRegistrationId',reg.id,'registrationId',reg.id,'reference',reg.reference,'version',reg.version);
 end if;
 count_children:=jsonb_array_length(_payload->'children');
 if count_children<1 or count_children>app_private.event_group_size_limit(e.id) then raise exception 'INVALID_CHILD_COUNT' using errcode='22023';end if;
 if (select count(*) from app_private.registration_children c where c.event_id=e.id and c.participation_status='active')+count_children>coalesce((e.settings->>'maxChildren')::integer,300) then raise exception 'EVENT_CAPACITY_REACHED' using errcode='23514';end if;
 for child in select value from jsonb_array_elements(_payload->'children') loop
  if length(trim(coalesce(child->>'name',''))) not between 1 and 80 or coalesce(child->>'age','')!~'^[0-9]{1,2}$' or (child->>'age')::integer not between 0 and 20
   or length(coalesce(child->>'accessibilityNote',''))>500 then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 end loop;
 begin start_at:=nullif(_payload->>'preferredStartAt','')::timestamptz;end_at:=nullif(_payload->>'desiredEndAt','')::timestamptz;
 exception when others then raise exception 'INVALID_EXACT_PREFERENCES' using errcode='22023';end;
 perform app_private.validate_exact_preferences(e.id,start_at,end_at);
 if pid is not null then
  perform 1 from app_private.together_parties where id=pid and event_id=e.id for update;
  if not found then raise exception 'PARTY_NOT_FOUND' using errcode='22023';end if;
  select array_agg(distinct a.group_id) into party_groups from app_private.together_memberships m join app_private.group_registrations a on a.registration_id=m.registration_id and a.superseded_at is null where m.party_id=pid and m.left_at is null;
  if cardinality(party_groups)>1 or (gid is not null and cardinality(party_groups)>0 and not(gid=any(party_groups))) then raise exception 'PARTY_GROUP_MISMATCH' using errcode='23514';end if;
  if gid is null and cardinality(party_groups)=1 then gid:=party_groups[1];end if;
  if app_private.together_party_child_count(pid)+count_children>app_private.event_group_size_limit(e.id) then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514';end if;
 end if;
 if gid is not null then
  perform 1 from app_private.walking_groups where id=gid and event_id=e.id and retired_at is null for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='22023';end if;
 end if;
 -- The invited identity acquires ownership only in the verified claim transaction.
 insert into app_private.households(label,phone) values(parent,nullif(trim(_payload->>'phone'),'')) returning id into h;
 insert into app_private.registration_drafts(event_id,household_id,payload)
 values(e.id,h,_payload||jsonb_build_object('adult',jsonb_build_object('name',parent,'householdLabel',parent,'phone',_payload->>'phone')))
 on conflict(event_id,household_id) do update set payload=excluded.payload,version=app_private.registration_drafts.version+1;
 payment_total:=count_children*e.price_cents;
 insert into app_private.registrations(id,event_id,household_id,status,reference,submitted_at,price_snapshot_cents)
 values(rid,e.id,h,'submitted',upper('DPH-'||extract(year from e.local_date)::text||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,8)),clock_timestamp(),payment_total) returning * into reg;
 for child in select value from jsonb_array_elements(_payload->'children') loop
  insert into app_private.children(household_id,first_name,age_at_event,accessibility_note) values(h,trim(child->>'name'),(child->>'age')::smallint,nullif(trim(child->>'accessibilityNote'),'')) returning id into cid;
  insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(e.id,rid,cid,e.price_cents);
 end loop;
 insert into app_private.payment_requests(registration_id,purpose,amount_cents,reference,status) values(rid,'event_registration',payment_total,reg.reference,'awaiting_link');
 insert into app_private.registration_activations(registration_id,event_id,normalized_email,parent_name,created_by) values(rid,e.id,v_email,parent,actor);
 if pid is not null then insert into app_private.together_memberships(party_id,registration_id) values(pid,rid);end if;
 if gid is not null then
  perform app_private.admin_registration_scope_begin(e.id,rid,array[gid],_command_id);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at)
  values(gid,rid,1,case when app_private.published_start_projection(gid) is not null then clock_timestamp() end);
  perform app_private.admin_registration_assert_group_capacity(gid);
  perform app_private.admin_registration_refresh_group(gid,actor);
  perform app_private.admin_registration_scope_end(_command_id);
 end if;
 perform app_private.registration_activation_issue(rid,actor,_command_id);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(e.id,actor,'registration.created_by_organization','registration',rid,jsonb_build_object('reason',trim(_reason),'commandId',_command_id,'childCount',count_children,'groupId',gid,'partyId',pid,'activationStatus','pending'));
 result:=jsonb_build_object('existing',false,'registrationId',rid,'reference',reg.reference,'version',reg.version,'activationStatus','pending','invitationVersion',1,'mailQueued',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'registration.admin.create',_command_id::text,digest,result,now()+interval '30 days');
 perform realtime.send(jsonb_build_object('resource','registrations'),'snapshot_changed','admin-event:'||e.id,true);
 return result;
end $$;

create function api.admin_registration_invite(_event_slug text,_registration_id uuid,_expected_registration_version integer,_email text,_command_id uuid,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; r app_private.registrations; a app_private.registration_activations; actor uuid:=auth.uid(); v_email text;
 digest text; saved app_private.command_receipts; result jsonb; corrected boolean;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if actor is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',actor) or app_private.has_capability(e.id,'registration_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _command_id is null or length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 digest:=encode(extensions.digest(jsonb_build_array(e.id,_registration_id,_expected_registration_version,lower(trim(_email)),trim(_reason))::text,'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=actor and command_type='registration.admin.invite' and idempotency_key=_command_id::text;
 if saved.id is not null then if saved.request_hash<>digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return saved.safe_result;end if;
 select * into r from app_private.registrations where id=_registration_id and event_id=e.id for update;
 select * into a from app_private.registration_activations where registration_id=r.id for update;
 if r.id is null or a.registration_id is null or r.status<>'submitted' or a.activated_at is not null then raise exception 'PENDING_ACTIVATION_REQUIRED' using errcode='23514';end if;
 if r.version is distinct from _expected_registration_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
 v_email:=coalesce(nullif(lower(trim(_email)),''),a.normalized_email);
 if length(v_email)>254 or v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 if exists(select 1 from app_private.registration_activations other where other.event_id=e.id and other.registration_id<>r.id and other.normalized_email=v_email)
 or exists(select 1 from app_private.registrations other join app_private.household_members m on m.household_id=other.household_id and m.revoked_at is null join auth.users u on u.id=m.user_id and u.email_confirmed_at is not null
  where other.event_id=e.id and other.status<>'cancelled' and other.id<>r.id and lower(trim(u.email))=v_email) then raise exception 'REGISTRATION_ALREADY_EXISTS' using errcode='23505';end if;
 corrected:=v_email is distinct from a.normalized_email;
 update app_private.registration_activations set normalized_email=v_email,invitation_id=gen_random_uuid(),invitation_version=invitation_version+1,issued_at=clock_timestamp(),expires_at=clock_timestamp()+interval '7 days' where registration_id=r.id returning * into a;
 update app_private.registrations set version=version+1 where id=r.id returning * into r;
 update app_private.registration_drafts set payload=jsonb_set(payload,'{email}',to_jsonb(v_email)),version=version+1 where event_id=e.id and household_id=r.household_id;
 perform app_private.registration_activation_issue(r.id,actor,_command_id);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(e.id,actor,'registration.invitation_reissued','registration',r.id,jsonb_build_object('commandId',_command_id,'reason',trim(_reason),'emailCorrected',corrected,'invitationVersion',a.invitation_version));
 result:=jsonb_build_object('registrationId',r.id,'version',r.version,'invitationVersion',a.invitation_version,'mailQueued',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'registration.admin.invite',_command_id::text,digest,result,now()+interval '30 days');
 perform realtime.send(jsonb_build_object('resource','registrations'),'snapshot_changed','admin-event:'||e.id,true);
 return result;
end $$;

create function api.registration_activation_claim(_token text,_command_id uuid,_mode text default 'fresh') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); v_email text:=app_private.registration_activation_identity(); a app_private.registration_activations;
 r app_private.registrations; h app_private.households; eid uuid; gid uuid; session_id uuid; saved app_private.command_receipts; digest text; result jsonb;
begin
 if _command_id is null or _mode is null or _mode not in('fresh','explicit') or coalesce(_token,'')!~'^[a-f0-9]{64}$' then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 select event_id into eid from app_private.registration_activations where invite_token_hash=extensions.digest(_token,'sha256');
 perform 1 from app_private.events where id=eid for update;
 select * into a from app_private.registration_activations where invite_token_hash=extensions.digest(_token,'sha256') for update;
 if a.registration_id is null or a.normalized_email<>v_email then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 select * into r from app_private.registrations where id=a.registration_id for update;
 if r.status<>'submitted' then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 digest:=encode(extensions.digest(jsonb_build_array(a.registration_id,a.invitation_version,_mode)::text,'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=actor and command_type='registration.activation.claim' and idempotency_key=_command_id::text;
 if saved.id is not null then if saved.request_hash<>digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return saved.safe_result;end if;
 if a.activated_at is not null then
  if a.activated_user_id<>actor then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
  return jsonb_build_object('registrationId',r.id,'activated',true,'alreadyActivated',true);
 end if;
 if a.expires_at<=clock_timestamp() then raise exception 'INVITATION_EXPIRED' using errcode='23514';end if;
 if _mode='fresh' then
  begin session_id:=nullif(auth.jwt()->>'session_id','')::uuid;exception when others then session_id:=null;end;
  if not exists(select 1 from auth.sessions s where s.id=session_id and s.user_id=actor and s.created_at>=a.issued_at and (s.not_after is null or s.not_after>clock_timestamp())) then
   raise exception 'FRESH_LOGIN_OR_EXPLICIT_CLAIM_REQUIRED' using errcode='42501';
  end if;
 end if;
 if exists(select 1 from app_private.registrations other join app_private.household_members m on m.household_id=other.household_id and m.user_id=actor and m.revoked_at is null
  where other.event_id=a.event_id and other.id<>r.id and other.status<>'cancelled') then raise exception 'REGISTRATION_ALREADY_EXISTS' using errcode='23505';end if;
 select assignment.group_id into gid from app_private.group_registrations assignment where assignment.registration_id=r.id and assignment.superseded_at is null;
 if gid is not null and not app_private.admin_registration_group_started(gid) then
  perform app_private.admin_registration_assert_group_capacity(gid);
 end if;
 select * into h from app_private.households where id=r.household_id for update;
 if h.primary_contact_user_id is not null and h.primary_contact_user_id<>actor then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 -- Capacity was reserved when active children were created. Claim changes no count,
 -- assignment, publication, payment or live visit; existing ownership roles survive.
 update app_private.households set primary_contact_user_id=actor,version=version+1 where id=h.id and primary_contact_user_id is null;
 if not exists(select 1 from app_private.household_members where household_id=h.id and user_id=actor and revoked_at is null) then
  insert into app_private.household_members(household_id,user_id,relation_role) values(h.id,actor,'owner');
 end if;
 update app_private.registration_activations set activated_at=clock_timestamp(),activated_user_id=actor where registration_id=r.id;
 update app_private.registrations set version=version+1 where id=r.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(a.event_id,actor,'registration.activated','registration',r.id,jsonb_build_object('commandId',_command_id,'mode',_mode,'invitationVersion',a.invitation_version));
 perform realtime.send(jsonb_build_object('resource','registrations'),'snapshot_changed','admin-event:'||a.event_id,true);
 result:=jsonb_build_object('registrationId',r.id,'activated',true,'alreadyActivated',false);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'registration.activation.claim',_command_id::text,digest,result,now()+interval '30 days');
 return result;
end $$;

create function api.registration_activation_renew(_token text,_command_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); v_email text:=app_private.registration_activation_identity(); a app_private.registration_activations; eid uuid; saved app_private.command_receipts; digest text; result jsonb;
begin
 if _command_id is null or coalesce(_token,'')!~'^[a-f0-9]{64}$' then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':registration.activation.renew:'||_command_id,0));
 digest:=encode(extensions.digest(_token,'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=actor and command_type='registration.activation.renew' and idempotency_key=_command_id::text;
 if saved.id is not null then if saved.request_hash<>digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return saved.safe_result;end if;
 select event_id into eid from app_private.registration_activations where invite_token_hash=extensions.digest(_token,'sha256');
 perform 1 from app_private.events where id=eid for update;
 select * into a from app_private.registration_activations where invite_token_hash=extensions.digest(_token,'sha256') for update;
 if a.registration_id is null or a.normalized_email<>v_email or a.activated_at is not null then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 if not exists(select 1 from app_private.registrations where id=a.registration_id and status='submitted') then raise exception 'INVITATION_UNAVAILABLE' using errcode='42501';end if;
 update app_private.registration_activations set invitation_id=gen_random_uuid(),invitation_version=invitation_version+1,issued_at=clock_timestamp(),expires_at=clock_timestamp()+interval '7 days' where registration_id=a.registration_id;
 update app_private.registrations set version=version+1 where id=a.registration_id;
 perform app_private.registration_activation_issue(a.registration_id,actor,_command_id);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(eid,actor,'registration.invitation_renewed','registration',a.registration_id,jsonb_build_object('commandId',_command_id));
 result:=jsonb_build_object('queued',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(actor,'registration.activation.renew',_command_id::text,digest,result,now()+interval '30 days');
 return result;
end $$;

create function api.worker_registration_activation_mail_payload(_outbox_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o app_private.email_outbox; a app_private.registration_activations; r app_private.registrations; g app_private.walking_groups; names jsonb; appointment jsonb;
begin
 select * into o from app_private.email_outbox where id=_outbox_id;
 if o.message_type<>'registration_activation' or o.status not in('pending','processing','deferred') then return null;end if;
 select * into a from app_private.registration_activations where registration_id::text=o.payload->>'registrationId';
 select * into r from app_private.registrations where id=a.registration_id;
 if a.registration_id is null or a.activated_at is not null or a.expires_at<=statement_timestamp() or r.status<>'submitted'
  or a.invitation_version::text is distinct from o.payload->>'invitationVersion' or a.normalized_email is distinct from lower(trim(o.recipient_email)) then return null;end if;
 select coalesce(jsonb_agg(c.first_name order by c.created_at,c.id),'[]') into names from app_private.registration_children rc join app_private.children c on c.id=rc.child_id where rc.registration_id=r.id and rc.participation_status='active';
 select wg.* into g from app_private.group_registrations assignment join app_private.walking_groups wg on wg.id=assignment.group_id where assignment.registration_id=r.id and assignment.superseded_at is null;
 appointment:=app_private.published_start_projection(g.id);
 return jsonb_build_object('personName',a.parent_name,'registrationReference',r.reference,'children',names,'childCount',jsonb_array_length(names),'activationPending',true,
  'groupName',g.display_name,'groupCode',g.system_code,'startsAt',appointment->'startsAt','groupConfirmed',appointment is not null,
  'actionPath',app_private.registration_activation_action_path(r.id),'expiresAt',a.expires_at);
end $$;
revoke all on function api.admin_registration_create(text,jsonb,integer,uuid,text),api.admin_registration_invite(text,uuid,integer,text,uuid,text),api.registration_activation_claim(text,uuid,text),api.registration_activation_renew(text,uuid),api.worker_registration_activation_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.admin_registration_create(text,jsonb,integer,uuid,text),api.admin_registration_invite(text,uuid,integer,text,uuid,text),api.registration_activation_claim(text,uuid,text),api.registration_activation_renew(text,uuid) to authenticated;
grant execute on function api.worker_registration_activation_mail_payload(uuid) to service_role;

create function app_private.event_registration_household(_event uuid,_actor uuid default auth.uid()) returns uuid
language sql stable security definer set search_path='' as $$
 select h.id from app_private.household_members m join app_private.households h on h.id=m.household_id
 left join lateral(select rr.id,rr.status from app_private.registrations rr where rr.household_id=h.id and rr.event_id=_event and rr.status<>'cancelled'
  order by (rr.status='submitted') desc,rr.created_at desc,rr.id limit 1) r on true
 left join app_private.registration_drafts d on d.household_id=h.id and d.event_id=_event
 where m.user_id=_actor and m.revoked_at is null and m.accepted_at<=statement_timestamp()
 order by case when r.status='submitted' then 0 when r.id is not null then 1 when d.id is not null then 2 else 3 end,
  (h.primary_contact_user_id=_actor) desc,(m.relation_role='owner') desc,m.accepted_at,h.id limit 1;
$$;
revoke all on function app_private.event_registration_household(uuid,uuid) from public,anon,authenticated;

create function api.admin_registration_creation_options(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e app_private.events;
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'registration_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return coalesce(app_private.exact_preference_options(e.id),'{}'::jsonb)||jsonb_build_object('eventVersion',e.settings_version,'priceCents',e.price_cents,'maxGroupSize',app_private.event_group_size_limit(e.id),
 'canManageGroups',app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid()),
 'groups',coalesce((select jsonb_agg(app_private.admin_registration_group_choice(g.id) order by g.system_number,g.id) from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null),'[]'::jsonb),
 'parties',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'reference',coalesce(p.cluster_reference,p.public_label),
  'groupId',(select a.group_id from app_private.together_memberships m join app_private.group_registrations a on a.registration_id=m.registration_id and a.superseded_at is null where m.party_id=p.id and m.left_at is null order by a.group_id limit 1),
  'children',app_private.together_party_child_count(p.id),'households',(select count(*) from app_private.together_memberships m join app_private.registrations r on r.id=m.registration_id and r.status='submitted' where m.party_id=p.id and m.left_at is null)) order by p.cluster_reference,p.id)
  from app_private.together_parties p where p.event_id=e.id and exists(select 1 from app_private.together_memberships m join app_private.registrations r on r.id=m.registration_id and r.status='submitted' where m.party_id=p.id and m.left_at is null)),'[]'::jsonb));
end $$;
revoke all on function api.admin_registration_creation_options(text) from public,anon;
grant execute on function api.admin_registration_creation_options(text) to authenticated;


-- Preserve the latest person/group naming contract, including unclaimed registrations.
create or replace function api.admin_registrations_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record
  from app_private.events
  where slug = _event_slug;

  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'version',registration.version,
        'activation',coalesce((select jsonb_build_object('status',case when a.activated_at is null then 'pending' else 'activated' end,'email',a.normalized_email,'invitationVersion',a.invitation_version,'expiresAt',a.expires_at,'activatedAt',a.activated_at) from app_private.registration_activations a where a.registration_id=registration.id),jsonb_build_object('status','activated')),
        'mailStatus',(select o.status::text from app_private.email_outbox o where o.payload->>'registrationId'=registration.id::text and o.message_type='registration_activation'
          and o.payload->>'invitationVersion'=(select a.invitation_version::text from app_private.registration_activations a where a.registration_id=registration.id) order by o.created_at desc,o.id desc limit 1),
        'reservedChildCount',case when exists(select 1 from app_private.registration_activations a where a.registration_id=registration.id and a.activated_at is null) then registration.child_count else 0 end,
        'activatedChildCount',case when exists(select 1 from app_private.registration_activations a where a.registration_id=registration.id and a.activated_at is null) then 0 else registration.child_count end,
        'paidChildCount',(select count(*) from app_private.registration_children rc where rc.registration_id=registration.id and rc.participation_status='active' and app_private.child_payment_payload(rc.id)->>'status' in('confirmed','waived')),
        'presentChildCount',case when exists(select 1 from app_private.group_runs run where run.group_id=registration.group_id and run.started_at is not null)
          then (select count(*) from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
            where rc.registration_id=registration.id and rc.participation_status='active' and rp.attendance='present' and rp.departed_at is null
             and rp.run_id=(select run.id from app_private.group_runs run where run.group_id=registration.group_id and run.started_at is not null order by run.started_at desc,run.created_at desc,run.id limit 1)) else null end,
        'submittedAt', registration.submitted_at,
        'updatedAt', registration.updated_at,
        'parentName', registration.parent_name,
        'personName',app_private.registration_person_name(registration.id),
        'householdLabel',registration.household_label,
        'parentEmail', registration.parent_email,
        'phone', registration.phone,
        'groupId', registration.group_id,
        'groupCode', registration.group_code,
        'groupName', coalesce(
          registration.group_name,
          case when registration.group_code is not null
            then 'Groep ' || registration.group_code
            else 'Nog niet ingedeeld'
          end
        ),
        'togetherCode', registration.together_code,
        'partyId', registration.party_id,
        'clusterReference', registration.cluster_reference,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'childCount', registration.child_count,
        'children', registration.children,
        'priceCents', registration.price_snapshot_cents
      )
      order by registration.submitted_at desc nulls last, registration.created_at desc, registration.id
    )
    from (
      select
        submitted.*,
        coalesce((
          select count(*)::integer
          from app_private.registration_children registration_child
          where registration_child.registration_id = submitted.id
            and registration_child.participation_status = 'active'
        ), 0) as child_count,
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', registration_child.id,
            'childId',child.id,
            'name', child.first_name,
            'age', child.age_at_event,
            'accessibilityNote', child.accessibility_note,
            'status', registration_child.participation_status
          ) order by child.first_name, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child on child.id = registration_child.child_id
          where registration_child.registration_id = submitted.id
        ), '[]'::jsonb) as children
      from (
        select
          registration.id,
          registration.reference,
          registration.version,
          registration.status,
          registration.submitted_at,
          registration.created_at,
          registration.updated_at,
          registration.together_code,
          membership.party_id,
          party.cluster_reference,
          registration.preferred_start_at,
          registration.desired_end_at,
          registration.price_snapshot_cents,
          coalesce(app_private.registration_person_name(registration.id),'Deelnemer') as parent_name,
          coalesce(activation.normalized_email,lower(users.email)) as parent_email,
          household.phone,
          household.label as household_label,
          assigned_group.id as group_id,
          assigned_group.system_code as group_code,
          assigned_group.display_name as group_name
        from app_private.registrations registration
        join app_private.households household on household.id = registration.household_id
        left join auth.users users on users.id = household.primary_contact_user_id
        left join app_private.registration_activations activation on activation.registration_id=registration.id
        left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
        left join app_private.together_parties party on party.id = membership.party_id
        left join app_private.profiles profile on profile.user_id = household.primary_contact_user_id
        left join app_private.registration_drafts draft
          on draft.event_id = registration.event_id and draft.household_id = registration.household_id
        left join lateral (
          select walking_group.id, walking_group.system_code, walking_group.display_name
          from app_private.group_registrations assignment
          join app_private.walking_groups walking_group on walking_group.id = assignment.group_id
          where assignment.registration_id = registration.id and assignment.superseded_at is null
          order by assignment.assigned_at desc, assignment.id desc
          limit 1
        ) assigned_group on true
        where registration.event_id = event_record.id
          and registration.status <> 'draft'
      ) submitted
    ) registration
  ), '[]'::jsonb);
end;
$$;

-- Keep every existing financial/privacy wrapper; only the active base selection changes.
create or replace function app_private.registration_snapshot_before_group_capacity(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event app_private.events;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into v_event from app_private.events where slug = _event_slug;
  if v_event.id is null then return null; end if;
  return (
    select jsonb_build_object(
      'event', jsonb_build_object(
        'changeDeadline', v_event.change_deadline,
        'changesOpen', v_event.change_deadline is null or v_event.change_deadline > now()
      ),
      'household', jsonb_build_object('id', household.id, 'label', household.label, 'phone', household.phone, 'version', household.version),
      'draft', case when draft.id is null then null else jsonb_build_object('payload', draft.payload, 'version', draft.version, 'updatedAt', draft.updated_at) end,
      'registration', case when registration.id is null then null else jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'activationStatus',case when exists(select 1 from app_private.registration_activations a where a.registration_id=registration.id and a.activated_at is null) then 'pending' else 'activated' end,
        'priceCents', registration.price_snapshot_cents,
        'version', registration.version,
        'togetherCode', registration.together_code,
        'togetherCount', coalesce((
          select count(*)
          from app_private.together_memberships own_membership
          join app_private.together_memberships party_member
            on party_member.party_id = own_membership.party_id and party_member.left_at is null
          join app_private.registrations party_registration
            on party_registration.id = party_member.registration_id and party_registration.status = 'submitted'
          where own_membership.registration_id = registration.id and own_membership.left_at is null
        ), 1),
        'children', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', registration_child.id,
            'firstName', child.first_name,
            'ageAtEvent', child.age_at_event,
            'status', registration_child.participation_status,
            'unitPriceCents', registration_child.unit_price_cents
          ) order by registration_child.created_at, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child on child.id = registration_child.child_id
          where registration_child.registration_id = registration.id
        ), '[]'::jsonb),
        'changeRequests', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', change_request.id,
            'kind', replace(change_request.category, 'registration_', ''),
            'status', change_request.status,
            'description', change_request.safe_description,
            'createdAt', change_request.created_at,
            'updatedAt', change_request.updated_at
          ) order by change_request.created_at desc)
          from app_private.support_cases change_request
          where change_request.registration_id = registration.id
            and change_request.reporter = actor
        ), '[]'::jsonb),
        'payment', (
          select jsonb_build_object('status', payment.status, 'amountCents', payment.amount_cents, 'externalUrl', payment.external_url, 'version', payment.version)
          from app_private.payment_requests payment
          where payment.registration_id = registration.id
          order by payment.created_at desc
          limit 1
        )
      ) end
    )
    from app_private.household_members member
    join app_private.households household on household.id = member.household_id
    left join app_private.registration_drafts draft on draft.household_id = household.id and draft.event_id = v_event.id
    left join lateral (
      select candidate.*
      from app_private.registrations candidate
      where candidate.household_id = household.id and candidate.event_id = v_event.id
      order by (candidate.status <> 'cancelled') desc, candidate.created_at desc
      limit 1
    ) registration on true
    where member.user_id = actor and member.revoked_at is null
      and household.id=app_private.event_registration_household(v_event.id,actor)
    order by member.accepted_at
    limit 1
  );
end;
$$;
create or replace function app_private.registration_preferences_snapshot_before_codes(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  registration app_private.registrations;
  schedule_published boolean := false;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  select registration_record.* into registration
  from app_private.registrations registration_record
  where registration_record.event_id = event_record.id
    and registration_record.status <> 'cancelled'
    and registration_record.household_id=app_private.event_registration_household(event_record.id,actor)
  order by registration_record.created_at desc limit 1;
  if registration.id is not null then
    select exists (
      select 1 from app_private.group_registrations assignment
      join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
      where assignment.registration_id = registration.id and assignment.superseded_at is null
    ) into schedule_published;
  end if;
  return jsonb_build_object(
    'registrationId', registration.id,
    'version', registration.version,
    'startPreference', coalesce(registration.start_time_preference::text, 'indifferent'),
    'ordinaryStopAt', registration.requested_ordinary_stop_at,
    'editable', registration.id is not null and not schedule_published and registration.preference_change_status = 'editable',
    'changeStatus', registration.preference_change_status,
    'confirmedSchedule', case when not schedule_published then null else (
      select jsonb_build_object(
        'startsAt', slot.starts_at, 'startPoint', point.name,
        'startAddress', point.private_address,
        'effectiveOrdinaryStopAt', schedule.effective_ordinary_stop_at,
        'expectedFinaleArrivalAt', schedule.expected_finale_arrival_at,
        'revision', schedule.revision
      )
      from app_private.group_registrations assignment
      join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
      join app_private.start_slots slot on slot.id = schedule.start_slot_id
      join app_private.start_points point on point.id = slot.start_point_id
      where assignment.registration_id = registration.id and assignment.superseded_at is null
      limit 1
    ) end,
    'event', jsonb_build_object(
      'firstStartAt', (select first_start_at from app_private.event_route_settings where event_id = event_record.id),
      'globalOrdinaryStopAt', (select global_ordinary_stop_at from app_private.event_route_settings where event_id = event_record.id),
      'allowedStopTimes', coalesce((select to_jsonb(allowed_personal_stop_times) from app_private.event_route_settings where event_id = event_record.id), '[]'::jsonb)
    )
  );
end;
$$;
