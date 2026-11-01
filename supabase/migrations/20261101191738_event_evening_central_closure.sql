-- Explicit organization action only: applying this migration closes/sends nothing.
set lock_timeout='5s';

-- Match the existing JS validation exactly: UTF-16 units and ECMAScript trim
-- whitespace. Validation never normalizes or rewrites the confirmed text.
create function app_private.event_evening_text_valid(_value text,_maximum integer)returns boolean
language sql immutable parallel safe set search_path=''as $$
 select coalesce(_value is not null and _maximum>=1
  and char_length(_value)+regexp_count(_value,U&'[\+010000-\+10FFFF]')<=_maximum
  and _value~U&'[^\0009-\000D\0020\00A0\1680\2000-\200A\2028\2029\202F\205F\3000\FEFF]',false)
$$;

create table app_private.event_closures(
 event_id uuid primary key references app_private.events(id),id uuid not null unique default gen_random_uuid(),
 closed_at timestamptz not null default clock_timestamp(),closed_by uuid not null references auth.users(id),
 subject text not null check(app_private.event_evening_text_valid(subject,200)and subject !~ E'[\\r\\n]'),
 body text not null check(app_private.event_evening_text_valid(body,20000)),message_version integer not null default 1 check(message_version=1),
 command_id uuid not null
);
create table app_private.event_closure_registrations(
 event_id uuid not null references app_private.event_closures(event_id),registration_id uuid not null references app_private.registrations(id),
 household_id uuid not null references app_private.households(id),primary key(event_id,registration_id)
);
create index event_closure_registration_household on app_private.event_closure_registrations(event_id,household_id);
create table app_private.event_closure_children(
 event_id uuid not null references app_private.event_closures(event_id),registration_child_id uuid not null references app_private.registration_children(id),
 child_id uuid not null references app_private.children(id),household_id uuid not null references app_private.households(id),
 primary key(event_id,registration_child_id),unique(event_id,child_id)
);
create table app_private.event_closure_portals(
 event_id uuid not null references app_private.event_closures(event_id),portal_id uuid not null references app_private.portals(id),
 portal_name text not null,world_id uuid not null references app_private.worlds(id),world_slug text not null,world_name text not null,
 finale boolean not null,presentation jsonb not null,primary key(event_id,portal_id)
);
-- Existing adult identities and pending, genuine invitations are frozen separately
-- from current authorization. A new unrelated household member gains no campaign.
create table app_private.event_closure_identity_claims(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references app_private.event_closures(event_id),
 household_id uuid not null references app_private.households(id),account_id uuid references auth.users(id),
 normalized_email text,kind text not null check(kind in('adult','activation','household_invite')),
 binding_id uuid,check(account_id is not null or normalized_email is not null),
 unique nulls not distinct(event_id,household_id,account_id,normalized_email,kind,binding_id)
);
create index event_closure_identity_actor on app_private.event_closure_identity_claims(event_id,account_id);
create table app_private.event_closure_accounts(
 event_id uuid not null references app_private.event_closures(event_id),account_id uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),read_at timestamptz,normalized_email text,
 primary key(event_id,account_id)
);
create table app_private.event_closure_mail_recipients(
 event_id uuid not null references app_private.event_closures(event_id),normalized_email text not null,
 created_at timestamptz not null default clock_timestamp(),outbox_id uuid references app_private.email_outbox(id),
 queued_at timestamptz,primary key(event_id,normalized_email),check(normalized_email=lower(trim(normalized_email)))
);
create index event_closure_mail_pending on app_private.event_closure_mail_recipients(created_at,event_id) where outbox_id is null;
do $$declare t text;begin
 foreach t in array array['event_closures','event_closure_registrations','event_closure_children','event_closure_portals','event_closure_identity_claims','event_closure_accounts','event_closure_mail_recipients']loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;
create function app_private.event_closure_immutable()returns trigger language plpgsql set search_path=''as $$
begin raise exception 'EVENT_CLOSURE_IMMUTABLE'using errcode='23514';end $$;
do $$declare t text;begin
 foreach t in array array['event_closures','event_closure_registrations','event_closure_children','event_closure_portals','event_closure_identity_claims']loop
  execute format('create trigger event_closure_immutable before update or delete on app_private.%I for each row execute function app_private.event_closure_immutable()',t);
 end loop;
end $$;
create function app_private.event_closure_exists(_event uuid)returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from app_private.event_closures where event_id=_event)
$$;
create function app_private.event_closure_household(_event uuid,_actor uuid default auth.uid())returns uuid
language sql stable security definer set search_path=''as $$
 select snapshot.household_id from app_private.event_closure_registrations snapshot
 join app_private.registrations reg on reg.id=snapshot.registration_id and reg.event_id=_event and reg.status='submitted'
 join app_private.household_members member on member.household_id=snapshot.household_id and member.user_id=_actor and member.revoked_at is null and member.accepted_at is not null
 join auth.users u on u.id=_actor and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null
 where snapshot.event_id=_event and exists(
  select 1 from app_private.event_closure_identity_claims claim where claim.event_id=_event and claim.household_id=snapshot.household_id and(
   claim.account_id=_actor or(claim.account_id is null and claim.normalized_email=lower(trim(u.email))and(
    (claim.kind='activation'and exists(select 1 from app_private.registration_activations a where a.registration_id=claim.binding_id and a.activated_user_id=_actor and a.activated_at is not null))
    or(claim.kind='household_invite'and exists(select 1 from app_private.household_invites i where i.id=claim.binding_id and i.consumed_at is not null and i.revoked_at is null))
   ))))order by snapshot.registration_id limit 1
$$;
-- Shared before existing domain locks; close takes the matching exclusive slot.
create function app_private.event_closure_assert_open(_event uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('event-closure:'||_event::text,0));
 if app_private.event_closure_exists(_event)then raise exception 'EVENING_ENDED'using errcode='23514';end if;
end $$;
create function app_private.event_closure_account_enroll(_event uuid,_actor uuid)returns void language plpgsql security definer set search_path=''as $$
declare email text;home uuid;
begin
 home:=app_private.event_closure_household(_event,_actor);
 if home is null then return;end if;
 -- Bind a genuinely activated frozen invitation to the stable account once.
 insert into app_private.event_closure_identity_claims(event_id,household_id,account_id,kind)values(_event,home,_actor,'adult')on conflict do nothing;
 insert into app_private.event_closure_accounts(event_id,account_id)values(_event,_actor)on conflict do nothing;
 select lower(trim(u.email))into email from auth.users u where u.id=_actor and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp());
 if email is not null and email~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'then
  update app_private.event_closure_accounts set normalized_email=email where event_id=_event and account_id=_actor and normalized_email is null;
  insert into app_private.event_closure_mail_recipients(event_id,normalized_email)select _event,normalized_email from app_private.event_closure_accounts where event_id=_event and account_id=_actor and normalized_email is not null on conflict do nothing;
 end if;
end $$;
create function app_private.event_closure_portals_json(_event uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',portal_id,'name',portal_name,'worldId',world_id,'worldSlug',world_slug,'worldName',world_name,'finale',finale,'presentation',presentation,'visited',true,'source','event_closure')order by finale,portal_name,portal_id),'[]')from app_private.event_closure_portals where event_id=_event
$$;
create function app_private.event_closure_for_actor(_event uuid,_actor uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select jsonb_build_object('id',c.id,'closedAt',c.closed_at,'subject',c.subject,'body',c.body,'messageVersion',c.message_version,
  'readAt',(select read_at from app_private.event_closure_accounts where event_id=_event and account_id=_actor),'portalCount',(select count(*)from app_private.event_closure_portals where event_id=_event))
 from app_private.event_closures c where c.event_id=_event and app_private.event_closure_household(_event,_actor)is not null
$$;
-- Participation derives from the operational portal model, not current open status.
-- Historic physical evidence includes withdrawn/archived portals that DID take part.
create function app_private.event_closure_participating_portals(_event uuid)returns setof app_private.portals
language sql stable security definer set search_path=''as $$
 select p.*from app_private.portals p where p.event_id=_event
 and not exists(select 1 from app_private.portal_flags flag where flag.portal_id=p.id and flag.flag_key='fixture'and flag.value)and(
  (p.lifecycle_status='active'and p.approval_status='approved')
  or exists(select 1 from app_private.group_portal_visits v where v.event_id=_event and v.portal_id=p.id)
  or exists(select 1 from app_private.portal_status_history h where h.portal_id=p.id and h.state='open')
 )
$$;
create function api.event_closure_admin_snapshot(_event_slug text)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare e app_private.events;c app_private.event_closures;counts jsonb;mail jsonb;
begin
 select *into e from app_private.events where slug=_event_slug;
 if auth.uid()is null or e.id is null or not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into c from app_private.event_closures where event_id=e.id;
 if c.id is null then
  with households as(select distinct r.household_id from app_private.registrations r where r.event_id=e.id and r.status='submitted'and exists(select 1 from app_private.registration_children rc where rc.registration_id=r.id and rc.participation_status='active')),
  adults as(select distinct u.id,case when u.email_confirmed_at is not null then nullif(lower(trim(u.email)),'')end email from households h join app_private.household_members m on m.household_id=h.household_id and m.revoked_at is null and m.accepted_at is not null join auth.users u on u.id=m.user_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp()))
  select jsonb_build_object('participantAccounts',(select count(*)from adults),'children',(select count(*)from app_private.registration_children rc join app_private.registrations r on r.id=rc.registration_id where r.event_id=e.id and r.status='submitted'and rc.participation_status='active'),'participatingHouses',(select count(*)from app_private.event_closure_participating_portals(e.id)),'uniqueEmailRecipients',(select count(distinct email)from adults where email~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'),'missingContactAccounts',(select count(*)from adults where email is null or email!~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'),'pendingActivations',(select count(*)from app_private.registration_activations a join app_private.registrations r on r.id=a.registration_id join households h on h.household_id=r.household_id where a.event_id=e.id and a.activated_at is null))into counts;
 else
  select jsonb_build_object('participantAccounts',(select count(*)from app_private.event_closure_accounts where event_id=e.id),'children',(select count(*)from app_private.event_closure_children where event_id=e.id),'participatingHouses',(select count(*)from app_private.event_closure_portals where event_id=e.id),'uniqueEmailRecipients',(select count(*)from app_private.event_closure_mail_recipients where event_id=e.id),'missingContactAccounts',(select count(*)from app_private.event_closure_accounts a join auth.users u on u.id=a.account_id where a.event_id=e.id and(u.email_confirmed_at is null or nullif(trim(u.email),'')is null)),'pendingActivations',(select count(*)from app_private.event_closure_identity_claims i where i.event_id=e.id and i.kind='activation'and not exists(select 1 from app_private.registration_activations a where a.registration_id=i.binding_id and a.activated_at is not null)))into counts;
 end if;
 select jsonb_build_object('queued',count(*)filter(where r.outbox_id is null or o.status in('pending','deferred','processing')),'processed',count(*)filter(where o.status in('accepted','delivered','failed','suppressed','unknown','validated')),'providerAccepted',count(*)filter(where o.accepted_at is not null or o.status in('accepted','delivered')),'delivered',count(*)filter(where o.status='delivered'),'failed',count(*)filter(where o.status='failed'),'unknown',count(*)filter(where o.status='unknown' or exists(select 1 from app_private.mail_envelopes env where env.outbox_id=o.id and env.status in('unknown','reconcile'))),'suppressed',count(*)filter(where o.status='suppressed'))into mail
 from app_private.event_closure_mail_recipients r left join app_private.email_outbox o on o.id=r.outbox_id where r.event_id=e.id;
 return jsonb_build_object('event',jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title),'closed',c.id is not null,'closure',case when c.id is null then null else jsonb_build_object('id',c.id,'closedAt',c.closed_at,'closedBy',c.closed_by,'subject',c.subject,'body',c.body,'messageVersion',c.message_version)end,'counts',counts,'mail',mail);
end $$;
create function api.event_closure_confirm(_event_slug text,_subject text,_body text,_command_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare e app_private.events;c app_private.event_closures;
begin
 select *into e from app_private.events where slug=_event_slug;
 if auth.uid()is null or e.id is null or not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('event-closure:'||e.id::text,0));
 select *into e from app_private.events where id=e.id for update;
 -- Recheck after waiting for a concurrent organizer/permission change.
 if not app_private.has_capability(e.id,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if app_private.event_closure_exists(e.id)then return api.event_closure_admin_snapshot(_event_slug)||jsonb_build_object('existing',true);end if;
 if _command_id is null or not app_private.event_evening_text_valid(_subject,200)or _subject~E'[\\r\\n]'or not app_private.event_evening_text_valid(_body,20000)then raise exception 'VALIDATION_ERROR'using errcode='22023';end if;
 if e.phase not in('registration_open','registration_closed','planning','ready','live','paused','completed')or e.local_date>(clock_timestamp()at time zone 'Europe/Amsterdam')::date or coalesce((e.settings->>'rehearsal')::boolean,false)then raise exception 'EVENT_NOT_CLOSABLE'using errcode='23514';end if;
 perform app_private.poortkamer_budget('event_closure_confirm',3);
 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
 insert into app_private.event_closures(event_id,closed_by,subject,body,command_id)values(e.id,auth.uid(),_subject,_body,_command_id)returning *into c;
 insert into app_private.event_closure_registrations(event_id,registration_id,household_id)
 select e.id,r.id,r.household_id from app_private.registrations r where r.event_id=e.id and r.status='submitted'and exists(select 1 from app_private.registration_children rc where rc.registration_id=r.id and rc.participation_status='active');
 insert into app_private.event_closure_children(event_id,registration_child_id,child_id,household_id)
 select e.id,rc.id,rc.child_id,r.household_id from app_private.event_closure_registrations r join app_private.registration_children rc on rc.registration_id=r.registration_id and rc.participation_status='active'where r.event_id=e.id;
 insert into app_private.event_closure_portals(event_id,portal_id,portal_name,world_id,world_slug,world_name,finale,presentation)
 select e.id,p.id,coalesce(presentation.public_name,p.name),p.world_id,w.slug,w.name,coalesce(p.id=settings.final_portal_id,false),
  jsonb_build_object('version',coalesce(presentation.version,publication.version,1),'portalCode',p.system_code,'world',w.name,'worldSlug',w.slug,'publicName',coalesce(presentation.public_name,nullif(publication.published_title,''),p.name),'shortDescription',coalesce(presentation.short_description,nullif(publication.teaser,''),'Een poort uit de nacht van Duindorp.'),'story',coalesce(presentation.story_fragment,w.story,''),'symbol',coalesce(presentation.symbol,'gate'),'color',coalesce(presentation.color,'amber'),'imagePath',coalesce(presentation.image_path,publication.image_path),'accessibility',coalesce(presentation.accessibility,'Volg de aanwijzingen van de groepsleider.'),'intensity',coalesce(presentation.intensity,p.intensity))
 from app_private.event_closure_participating_portals(e.id)p join app_private.worlds w on w.id=p.world_id
 left join app_private.event_route_settings settings on settings.event_id=e.id
 left join app_private.portal_presentations presentation on presentation.portal_id=p.id and presentation.status='active'
 left join app_private.portal_publications publication on publication.portal_id=p.id;
 -- One MVCC snapshot captures both sides of an invitation acceptance. If an
 -- acceptance commits concurrently, the adult OR pending invitation is captured.
 insert into app_private.event_closure_identity_claims(event_id,household_id,account_id,normalized_email,kind,binding_id)
 select distinct e.id,r.household_id,m.user_id,null::text,'adult'::text,null::uuid from app_private.event_closure_registrations r join app_private.household_members m on m.household_id=r.household_id and m.revoked_at is null and m.accepted_at is not null
 join auth.users u on u.id=m.user_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())where r.event_id=e.id
 union all
 select e.id,r.household_id,null::uuid,a.normalized_email,'activation',a.registration_id from app_private.event_closure_registrations r join app_private.registration_activations a on a.registration_id=r.registration_id and a.activated_at is null where r.event_id=e.id
 union all
 select distinct e.id,r.household_id,null::uuid,lower(trim(i.recipient_email)),'household_invite',i.id from app_private.event_closure_registrations r join app_private.household_invites i on i.household_id=r.household_id and i.consumed_at is null and i.revoked_at is null and i.expires_at>c.closed_at where r.event_id=e.id;
 insert into app_private.event_closure_accounts(event_id,account_id,normalized_email)select distinct e.id,i.account_id,case when u.email_confirmed_at is not null and u.email~'^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'then lower(trim(u.email))end from app_private.event_closure_identity_claims i join auth.users u on u.id=i.account_id where i.event_id=e.id;
 insert into app_private.event_closure_mail_recipients(event_id,normalized_email)
 select distinct e.id,a.normalized_email from app_private.event_closure_accounts a where a.event_id=e.id and a.normalized_email is not null;
 -- Business stop only. No scan, arrival, participant, seal, show or physical job.
 update app_private.group_runs run set status='stopped',current_stop_id=null,finished_at=c.closed_at,stopped_reason='event_closed_by_organization',version=run.version+1,updated_at=c.closed_at
 from app_private.walking_groups g where g.id=run.group_id and g.event_id=e.id and run.status in('ready','live','paused');
 update app_private.walking_groups set status='stopped',version=version+1 where event_id=e.id and status in('draft','ready','live');
 update app_private.portal_reservations set status='cancelled'where event_id=e.id and status in('held','active');
 update app_private.events set phase='completed',updated_at=c.closed_at where id=e.id;
 -- Never touch accepted/unknown delivery. Old completed group mails stay history.
 update app_private.email_outbox set status='suppressed',last_error_code='CENTRAL_EVENT_CLOSED',updated_at=c.closed_at where message_type='duinpad_evening_thanks'and payload->>'eventId'=e.id::text and status in('pending','deferred')and accepted_at is null and provider_id is null
 and not exists(select 1 from app_private.mail_envelopes env where env.outbox_id=email_outbox.id and env.status in('accepted','processing','unknown','reconcile'));
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)values(e.id,auth.uid(),'event.evening_closed','event_closure',c.id,jsonb_build_object('messageVersion',1,'commandId',_command_id));
 perform realtime.send(jsonb_build_object('resource','event_closure','id',c.id),'snapshot_changed','admin-event:'||e.id,true);
 return api.event_closure_admin_snapshot(_event_slug)||jsonb_build_object('existing',false);
end $$;
create function api.event_closure_snapshot(_event_slug text)returns jsonb language plpgsql security definer set search_path=''as $$
declare e app_private.events;ending jsonb;
begin
 if auth.uid()is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into e from app_private.events where slug=_event_slug;
 if e.id is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if not app_private.event_closure_exists(e.id)then return jsonb_build_object('event',jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title),'closed',false,'closure',null,'portals','[]'::jsonb);end if;
 if app_private.event_closure_household(e.id,auth.uid())is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform app_private.event_closure_account_enroll(e.id,auth.uid());ending:=app_private.event_closure_for_actor(e.id,auth.uid());
 return jsonb_build_object('event',jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title),'closed',true,'closure',ending,'portals',app_private.event_closure_portals_json(e.id));
end $$;
create function api.event_closure_acknowledge(_event_slug text,_closure_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare result jsonb:=api.event_closure_snapshot(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;
begin
 if not coalesce((result->>'closed')::boolean,false)or result->'closure'->>'id'is distinct from _closure_id::text then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 update app_private.event_closure_accounts set read_at=coalesce(read_at,clock_timestamp())where event_id=eid and account_id=auth.uid();
 return api.event_closure_snapshot(_event_slug);
end $$;
create function api.worker_event_closure_mail(_outbox_id uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select jsonb_build_object('eventId',c.event_id,'closureId',c.id,'subject',c.subject,'body',c.body,'actionPath','/omgeving/meeloper/nu')
 from app_private.event_closure_mail_recipients r join app_private.event_closures c on c.event_id=r.event_id join app_private.email_outbox o on o.id=r.outbox_id
 where o.id=_outbox_id and o.message_type='event_closure_thanks'and o.status not in('failed','suppressed')and lower(trim(o.recipient_email))=r.normalized_email
 and exists(select 1 from app_private.event_closure_accounts a join auth.users u on u.id=a.account_id and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())where a.event_id=r.event_id and lower(trim(u.email))=r.normalized_email and app_private.event_closure_household(r.event_id,a.account_id)is not null)
$$;
create function api.worker_event_closures(_limit integer default 25)returns jsonb language plpgsql security definer set search_path=''as $$
declare recipient app_private.event_closure_mail_recipients;ending app_private.event_closures;oid uuid;processed integer:=0;
begin
 if _limit is null or _limit<1 or _limit>25 then raise exception 'INVALID_INPUT'using errcode='22023';end if;
 for recipient in select *from app_private.event_closure_mail_recipients where outbox_id is null order by created_at,event_id,normalized_email limit _limit for update skip locked loop
  select *into ending from app_private.event_closures where event_id=recipient.event_id;
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  values('event-closure:'||ending.id||':'||encode(extensions.digest(recipient.normalized_email,'sha256'),'hex'),'event_closure_thanks','event-closure:'||ending.id,recipient.normalized_email,jsonb_build_object('eventId',ending.event_id,'closureId',ending.id,'subject',ending.subject,'body',ending.body,'actionPath','/omgeving/meeloper/nu'))on conflict(dedupe_key)do nothing returning id into oid;
  if oid is null then select id into oid from app_private.email_outbox where dedupe_key='event-closure:'||ending.id||':'||encode(extensions.digest(recipient.normalized_email,'sha256'),'hex');end if;
  update app_private.event_closure_mail_recipients set outbox_id=oid,queued_at=clock_timestamp()where event_id=recipient.event_id and normalized_email=recipient.normalized_email;
  processed:=processed+1;
 end loop;
 return jsonb_build_object('processed',processed,'remaining',(select count(*)from app_private.event_closure_mail_recipients where outbox_id is null));
end $$;
-- Retry only conclusive non-delivery. Unknown/provider-accepted rows require
-- existing provider reconciliation and never become a second send here.
create function app_private.event_evening_retry_outbox(_outbox_id uuid)returns boolean language plpgsql security definer set search_path=''as $$
declare candidate record;envelope app_private.mail_envelopes;message app_private.email_outbox;
begin
 select o.id,env.id envelope_id,env.environment,env.logical_key into candidate from app_private.email_outbox o left join app_private.mail_envelopes env on env.outbox_id=o.id
 where o.id=_outbox_id and o.status='failed'and o.accepted_at is null and o.provider_id is null and o.attempts<8
 and(env.id is null or(env.provider='resend'and env.status='failed'and env.accepted_at is null and env.provider_id is null and env.first_attempt_at>clock_timestamp()-interval '23 hours 55 minutes'));
 if candidate.id is null then return false;end if;
 if candidate.envelope_id is not null then
  -- Match the gateway lock order and retain its provider idempotency key.
  perform pg_advisory_xact_lock(hashtextextended(candidate.environment||':'||candidate.logical_key,0));
  select *into envelope from app_private.mail_envelopes where id=candidate.envelope_id for update;
  if envelope.status<>'failed'or envelope.accepted_at is not null or envelope.provider_id is not null or envelope.first_attempt_at<=clock_timestamp()-interval '23 hours 55 minutes'then return false;end if;
 end if;
 select *into message from app_private.email_outbox where id=candidate.id for update skip locked;
 if message.id is null or message.status<>'failed'or message.accepted_at is not null or message.provider_id is not null or message.attempts>=8 then return false;end if;
 if candidate.envelope_id is null and exists(select 1 from app_private.mail_envelopes where outbox_id=candidate.id)then return false;end if;
 if candidate.envelope_id is not null then
  update app_private.mail_envelopes set status='deferred',lease_until=null,claim_token=null,error_code='OPERATOR_RETRY_REQUESTED'where id=candidate.envelope_id;
 end if;
 update app_private.email_outbox set status='pending',next_attempt_at=clock_timestamp()+interval '30 seconds',lease_until=null,last_error_code=null,updated_at=clock_timestamp()where id=candidate.id;
 return true;
end $$;
create function api.event_closure_retry_failed(_event_slug text)returns jsonb language plpgsql security definer set search_path=''as $$
declare eid uuid:=app_private.current_event_id(_event_slug);n integer:=0;candidate uuid;
begin
 if auth.uid()is null or not app_private.has_capability(eid,'event_admin',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform app_private.poortkamer_budget('event_closure_retry_failed',10);
 for candidate in select o.id from app_private.email_outbox o join app_private.event_closure_mail_recipients r on r.outbox_id=o.id left join app_private.mail_envelopes env on env.outbox_id=o.id where r.event_id=eid and o.status='failed'and o.accepted_at is null and o.provider_id is null and o.attempts<8 and(env.id is null or(env.provider='resend'and env.status='failed'and env.accepted_at is null and env.provider_id is null and env.first_attempt_at>clock_timestamp()-interval '23 hours 55 minutes'))order by o.created_at,o.id limit 100 loop
  if app_private.event_evening_retry_outbox(candidate)then n:=n+1;end if;
 end loop;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)values(eid,auth.uid(),'event_closure.retry_failed','event_closure',jsonb_build_object('requeued',n));
 return api.event_closure_admin_snapshot(_event_slug)||jsonb_build_object('requeued',n);
end $$;

-- Every public route/scanning writer takes the closure gate BEFORE its original
-- domain locks. Existing authorization, transactions and receipts remain inside.
do $$
declare fn record;args text;call_args text;guard text;old_name text;statement text;allow_auth boolean;allow_service boolean;
begin
 for fn in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='api'and p.proname in(
  'run_start','run_scan','run_scan_validate','run_set_state','run_confirm_arrival','run_arrive_and_advance','run_complete_stop',
  'run_update_participant','run_bulk_skip_pending','run_system_skip','run_support_override','run_end_early','run_mark_departed',
  'duinpad_finale_validate','duinpad_finale_confirm','duinpad_checkpoint_validate','duinpad_show_reserve','duinpad_actor_reserve','worker_dispatch_due_groups')
  and p.proname not like '%before%'loop
  args:=pg_get_function_arguments(fn.oid);old_name:=fn.proname||'_before_event_closure';
  select string_agg(format('%I',name),','order by ordinal)into call_args from unnest(fn.proargnames)with ordinality a(name,ordinal)where ordinal<=fn.pronargs;
  allow_auth:=has_function_privilege('authenticated',fn.oid,'EXECUTE');allow_service:=has_function_privilege('service_role',fn.oid,'EXECUTE');
  if fn.proname='run_start'then guard:='(select event_id from app_private.walking_groups where id=_group_id)';
  elsif fn.proname in('duinpad_finale_validate','duinpad_finale_confirm','duinpad_checkpoint_validate','duinpad_actor_reserve','worker_dispatch_due_groups')then guard:='app_private.current_event_id(_event_slug)';
  elsif fn.proname='duinpad_show_reserve'then guard:='_event';
  else guard:='(select g.event_id from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=_run_id)';end if;
  if fn.proname='worker_dispatch_due_groups'then
   statement:=format('perform pg_advisory_xact_lock_shared(hashtextextended(''event-closure:''||%s::text,0));if app_private.event_closure_exists(%s)then return jsonb_build_object(''dispatched'',0,''alerted'',0,''eventClosed'',true);end if;',guard,guard);
  elsif fn.proname='duinpad_actor_reserve'then
   statement:=format('if _payload_text::jsonb->>''action''=''finale.go''then perform app_private.event_closure_assert_open(%s);end if;',guard);
  else statement:=format('perform app_private.event_closure_assert_open(%s);',guard);end if;
  execute format('alter function api.%I(%s)rename to %I',fn.proname,pg_get_function_identity_arguments(fn.oid),old_name);
  execute format('revoke all on function api.%I(%s)from public,anon,authenticated,service_role',old_name,pg_get_function_identity_arguments(fn.oid));
  execute format('create function api.%I(%s)returns jsonb language plpgsql security definer set search_path=''''as $wrapper$begin %s return api.%I(%s);end $wrapper$',fn.proname,args,statement,old_name,call_args);
  execute format('revoke all on function api.%I(%s)from public,anon,authenticated,service_role',fn.proname,pg_get_function_identity_arguments(fn.oid));
  if allow_auth then execute format('grant execute on function api.%I(%s)to authenticated',fn.proname,pg_get_function_identity_arguments(fn.oid));end if;
  if allow_service then execute format('grant execute on function api.%I(%s)to service_role',fn.proname,pg_get_function_identity_arguments(fn.oid));end if;
 end loop;
end $$;
-- Personal two-hour histories remain intact; central closure is authoritative.
alter function app_private.duinpad_evening_closed(uuid,uuid)rename to duinpad_evening_closed_before_event_closure;
create function app_private.duinpad_evening_closed(_event uuid,_actor uuid)returns boolean language sql stable security definer set search_path=''as $$
 select app_private.event_closure_exists(_event)or app_private.duinpad_evening_closed_before_event_closure(_event,_actor)
$$;
-- Lock event slots first, then evening rows/outbox rows. This is the same ordering
-- as the explicit close, so a worker cannot enqueue a generic mail behind it.
create or replace function api.worker_duinpad_evenings(_batch_size integer default 100)returns jsonb
language plpgsql security definer set search_path=''as $$
declare eid uuid;evening app_private.duinpad_evenings;recipient record;processed integer:=0;queued integer:=0;inserted integer;maximum integer:=least(greatest(_batch_size,1),500);
begin
 for eid in select distinct event_id from app_private.duinpad_evenings where processed_at is null and evening_ends_at<=statement_timestamp()order by event_id loop
  perform pg_advisory_xact_lock_shared(hashtextextended('event-closure:'||eid::text,0));
  for evening in select *from app_private.duinpad_evenings where event_id=eid and processed_at is null and evening_ends_at<=statement_timestamp()order by evening_ends_at,run_id limit greatest(maximum-processed,0)for update skip locked loop
   if not app_private.event_closure_exists(eid)then
    for recipient in select m.account_id,lower(trim(u.email))email from app_private.duinpad_evening_members m join auth.users u on u.id=m.account_id and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())where m.run_id=evening.run_id and nullif(trim(u.email),'')is not null loop
     insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload,next_attempt_at)
     values('duinpad-evening:'||evening.event_id||':'||recipient.account_id,'duinpad_evening_thanks',recipient.account_id::text,recipient.email,jsonb_build_object('eventId',evening.event_id,'runId',evening.run_id,'logicalDueAt',evening.evening_ends_at,'actionPath','/omgeving/meeloper'),evening.evening_ends_at)on conflict(dedupe_key)do nothing;
     get diagnostics inserted=row_count;queued:=queued+inserted;
    end loop;
   end if;
   update app_private.duinpad_evenings set processed_at=clock_timestamp()where run_id=evening.run_id;
   insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)values(eid,'duinpad.evening_closed','group_run',evening.run_id,jsonb_build_object('logicalDueAt',evening.evening_ends_at,'centralClosure',app_private.event_closure_exists(eid)));
   processed:=processed+1;
  end loop;
  exit when processed>=maximum;
 end loop;
 return jsonb_build_object('processed',processed,'queued',queued);
end $$;

alter function api.participant_context(text)rename to participant_context_before_event_closure;
create function api.participant_context(_event_slug text)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb:=api.participant_context_before_event_closure(_event_slug);eid uuid:=(result->'event'->>'id')::uuid;
begin return jsonb_set(result,'{event,eveningClosure}',coalesce(app_private.event_closure_for_actor(eid,auth.uid()),'null'::jsonb));end $$;
alter function api.account_app_snapshot(text)rename to account_app_snapshot_before_event_closure;
create function api.account_app_snapshot(_event_slug text)returns jsonb language plpgsql security definer set search_path=''as $$
declare result jsonb:=api.account_app_snapshot_before_event_closure(_event_slug);eid uuid:=(result->>'eventId')::uuid;
begin
 if app_private.event_closure_exists(eid)then perform app_private.event_closure_account_enroll(eid,auth.uid());end if;
 return result||jsonb_build_object('eveningClosure',app_private.event_closure_for_actor(eid,auth.uid()));
end $$;
alter function api.group_snapshot(uuid)rename to group_snapshot_before_event_closure;
create function api.group_snapshot(_group_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb:=api.group_snapshot_before_event_closure(_group_id);ending jsonb;
begin
 ending:=app_private.event_closure_for_actor((result->>'eventId')::uuid,auth.uid());
 if ending is not null then
  result:=result||jsonb_build_object('eveningClosure',ending,'administrativeVisitedPortals',app_private.event_closure_portals_json((result->>'eventId')::uuid));
  if result->'run'is not null and result->'run'<>'null'::jsonb then result:=result||jsonb_build_object('run',(result->'run')||jsonb_build_object('eveningEnded',true,'ownEveningFinished',true,'currentStop',null));end if;
 end if;
 return result;
end $$;
-- Gift seals are a projection; no physical visit, source-stop, arrival or scan is
-- manufactured. Existing physical seals retain their own timestamps and source.
alter function app_private.poortenboek_snapshot(app_private.poortenboek_sessions)rename to poortenboek_snapshot_before_event_closure;
create function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions)returns jsonb language plpgsql set search_path=''as $$
declare result jsonb;code app_private.poortenboek_codes;ending app_private.event_closures;seals jsonb;worlds jsonb;chapters jsonb;
begin
 result:=app_private.poortenboek_snapshot_before_event_closure(_session);
 select *into code from app_private.poortenboek_codes where id=_session.code_id;
 select *into ending from app_private.event_closures where event_id=code.event_id;
 if ending.id is null or not exists(select 1 from app_private.event_closure_children c join app_private.registration_children rc on rc.id=c.registration_child_id and rc.participation_status='active'join app_private.registrations r on r.id=rc.registration_id and r.status='submitted'where c.event_id=code.event_id and c.child_id=code.child_id)then return result;end if;
 select coalesce(jsonb_agg(case when physical.run_stop_id is not null then jsonb_build_object('stopId',physical.run_stop_id,'portalId',p.portal_id,'worldId',p.world_id,'earnedAt',physical.earned_at,'finale',p.finale,'presentation',physical.presentation_snapshot,'source','physical')
  else jsonb_build_object('portalId',p.portal_id,'worldId',p.world_id,'earnedAt',ending.closed_at,'finale',p.finale,'presentation',p.presentation,'source','event_closure','closureId',ending.id)end order by p.finale,p.portal_name,p.portal_id),'[]')into seals
 from app_private.event_closure_portals p left join lateral(select s.*from app_private.poortenboek_passport_seals s where s.event_id=p.event_id and s.child_id=code.child_id and s.portal_id=p.portal_id order by s.earned_at,s.run_stop_id limit 1)physical on true where p.event_id=code.event_id;
 select coalesce(jsonb_agg(item||jsonb_build_object('unlocked',true)),'[]')into worlds from jsonb_array_elements(result->'worlds')item;
 select jsonb_agg(jsonb_build_object('chapter',n,'unlockedAt',coalesce((select unlocked_at from app_private.poortenboek_story_chapters where event_id=code.event_id and child_id=code.child_id and chapter=n),ending.closed_at),'source',case when exists(select 1 from app_private.poortenboek_story_chapters where event_id=code.event_id and child_id=code.child_id and chapter=n)then 'physical'else 'event_closure'end)order by n)into chapters from generate_series(1,6)n;
 result:=result||jsonb_build_object('eventPhase','completed','eveningClosure',jsonb_build_object('id',ending.id,'closedAt',ending.closed_at),'worlds',worlds,'journey',(result->'journey')||jsonb_build_object('visitedCount',jsonb_array_length(seals),'assignedCount',jsonb_array_length(seals),'upgradeLevel',4,'chapters',chapters,'seals',seals,'complete',true));
 return result;
end $$;
-- Reading a gifted chapter is allowed without falsifying chapter/seal history.
alter function api.poortenboek_child_action(text,text,jsonb,uuid)rename to poortenboek_child_action_before_event_closure;
create function api.poortenboek_child_action(_token_hash text,_action text,_payload jsonb default '{}',_request_id uuid default null)returns jsonb language plpgsql security definer set search_path=''as $$
declare session app_private.poortenboek_sessions;code app_private.poortenboek_codes;chapter_number integer;
begin
 if _action='chapter_read'then
  session:=app_private.poortenboek_session(_token_hash);select *into code from app_private.poortenboek_codes where id=session.code_id;
  if app_private.event_closure_exists(code.event_id)and exists(select 1 from app_private.event_closure_children c join app_private.registration_children rc on rc.id=c.registration_child_id and rc.participation_status='active'join app_private.registrations reg on reg.id=rc.registration_id and reg.status='submitted'where c.event_id=code.event_id and c.child_id=code.child_id)then
   chapter_number:=(_payload->>'chapter')::integer;
   if chapter_number is null or chapter_number not between 1 and 6 then raise exception 'CHAPTER_LOCKED';end if;
   insert into app_private.poortenboek_chapter_reads(event_id,child_id,chapter)values(code.event_id,code.child_id,chapter_number)on conflict do nothing;
   return app_private.poortenboek_snapshot(session);
  end if;
 end if;
 return api.poortenboek_child_action_before_event_closure(_token_hash,_action,_payload,_request_id);
end $$;

-- Existing private-schema boundary is retained. No table becomes a Data API.
revoke all on function app_private.event_evening_text_valid(text,integer),app_private.event_evening_retry_outbox(uuid),app_private.event_closure_immutable(),app_private.event_closure_exists(uuid),app_private.event_closure_household(uuid,uuid),app_private.event_closure_assert_open(uuid),app_private.event_closure_account_enroll(uuid,uuid),app_private.event_closure_portals_json(uuid),app_private.event_closure_for_actor(uuid,uuid),app_private.event_closure_participating_portals(uuid),app_private.duinpad_evening_closed_before_event_closure(uuid,uuid),app_private.duinpad_evening_closed(uuid,uuid),app_private.poortenboek_snapshot_before_event_closure(app_private.poortenboek_sessions),app_private.poortenboek_snapshot(app_private.poortenboek_sessions)from public,anon,authenticated,service_role;
revoke all on function api.participant_context_before_event_closure(text),api.account_app_snapshot_before_event_closure(text),api.group_snapshot_before_event_closure(uuid),api.poortenboek_child_action_before_event_closure(text,text,jsonb,uuid)from public,anon,authenticated,service_role;
revoke all on function api.event_closure_admin_snapshot(text),api.event_closure_confirm(text,text,text,uuid),api.event_closure_snapshot(text),api.event_closure_acknowledge(text,uuid),api.event_closure_retry_failed(text),api.participant_context(text),api.account_app_snapshot(text),api.group_snapshot(uuid),api.poortenboek_child_action(text,text,jsonb,uuid),api.worker_event_closures(integer),api.worker_event_closure_mail(uuid)from public,anon,authenticated,service_role;
grant execute on function api.event_closure_admin_snapshot(text),api.event_closure_confirm(text,text,text,uuid),api.event_closure_snapshot(text),api.event_closure_acknowledge(text,uuid),api.event_closure_retry_failed(text),api.participant_context(text),api.account_app_snapshot(text),api.group_snapshot(uuid)to authenticated;
grant execute on function api.poortenboek_child_action(text,text,jsonb,uuid),api.worker_event_closures(integer),api.worker_event_closure_mail(uuid)to service_role;
notify pgrst,'reload schema';
