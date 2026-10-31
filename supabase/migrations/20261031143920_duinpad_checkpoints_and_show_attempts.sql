-- Additive, seedless: never changes routes, existing tokens, opening times or data.
create table app_private.duinpad_checkpoints (
 id uuid primary key default gen_random_uuid(), event_id uuid not null unique references app_private.events(id),
 portal_id uuid references app_private.portals(id), label text not null check(length(label) between 1 and 70),
 location_instruction text not null check(length(location_instruction) between 1 and 500),
 ciphertext text, token_hash bytea, short_code_hash bytea, version integer not null default 1,
 created_by uuid not null references auth.users(id), updated_at timestamptz not null default now(),
 check ((portal_id is null and ciphertext is not null and octet_length(token_hash)=32 and octet_length(short_code_hash)=32)
     or (portal_id is not null and ciphertext is null and token_hash is null and short_code_hash is null))
);
alter table app_private.duinpad_checkpoints enable row level security;
revoke all on app_private.duinpad_checkpoints from public,anon,authenticated;
create function api.duinpad_checkpoint_admin(_event_slug text,_actor uuid,_action text default 'read',_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare e uuid:=app_private.current_event_id(_event_slug); c app_private.duinpad_checkpoints; f uuid; p app_private.portals;
begin
 if not(app_private.has_capability(e,'event_admin',_actor) or app_private.has_capability(e,'portals_manage',_actor))then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select final_portal_id into f from app_private.event_route_settings where event_id=e;
 if _action not in('read','create','link','rotate')then raise exception 'INVALID_INPUT';end if;
 if _action<>'read'then
  perform 1 from app_private.events where id=e for no key update;
  select *into c from app_private.duinpad_checkpoints where event_id=e for update;
  if _action in('create','link')and c.id is not null then raise exception 'ALREADY_CONFIGURED';end if;
  if _action='rotate'and(c.id is null or c.portal_id is not null or c.version is distinct from (_data->>'version')::integer or _data->>'confirmRotation'<>'true')then raise exception 'STALE_VERSION';end if;
  if _action='link'then
   select *into p from app_private.portals where id=(_data->>'portalId')::uuid and event_id=e and approval_status='approved' and lifecycle_status<>'archived';
   if p.id is null or p.id=f then raise exception 'INVALID_CHECKPOINT';end if;
  end if;
  if _action in('create','link')then
   insert into app_private.duinpad_checkpoints(event_id,portal_id,label,location_instruction,ciphertext,token_hash,short_code_hash,created_by)
   values(e,p.id,_data->>'label',_data->>'instruction',case when p.id is null then _data->>'ciphertext'end,
    case when p.id is null then decode(_data->>'tokenHash','hex')end,case when p.id is null then decode(_data->>'shortHash','hex')end,_actor);
  else
   update app_private.duinpad_checkpoints set ciphertext=_data->>'ciphertext',token_hash=decode(_data->>'tokenHash','hex'),short_code_hash=decode(_data->>'shortHash','hex'),version=version+1,updated_at=now()where id=c.id;
  end if;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)values(e,_actor,'duinpad.checkpoint.'||_action,'duinpad',jsonb_build_object('stage','qr1'));
 end if;
 select *into c from app_private.duinpad_checkpoints where event_id=e;
 select *into p from app_private.portals where id=f and event_id=e;
 return jsonb_build_object('eventId',e,'eventDate',(select local_date from app_private.events where id=e),'qr1',case when c.id is null then null else jsonb_build_object('id',coalesce(c.portal_id,c.id),'checkpointId',c.id,'portalId',c.portal_id,'label',c.label,'instruction',c.location_instruction,'version',c.version,'ciphertext',c.ciphertext)end,
  'qr2',case when p.id is null then null else jsonb_build_object('id',p.id,'portalId',p.id,'label',p.name,'instruction','Scan bij de finalepoort en volg de aanwijzingen van de acteurs.','version',p.version)end,
  'portals',(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'label',q.name)order by q.name),'[]')from app_private.portals q where q.event_id=e and q.id<>f and q.approval_status='approved'and q.lifecycle_status<>'archived'));
end $$;
revoke all on function api.duinpad_checkpoint_admin(text,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function api.duinpad_checkpoint_admin(text,uuid,text,jsonb)to service_role;

-- A validated credential determines the stage; callers cannot submit a stage.
create function api.duinpad_checkpoint_validate(_event_slug text,_credential text,_portal_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=auth.uid();e uuid:=app_private.current_event_id(_event_slug);c app_private.duinpad_checkpoints;r uuid;context jsonb;budget integer;
begin
 if a is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 insert into app_private.rate_limit_buckets(scope,opaque_subject_hash,window_start,count,expires_at) values('duinpad.credential',a::text,date_trunc('minute',clock_timestamp()),1,clock_timestamp()+interval '2 minutes') on conflict(scope,opaque_subject_hash,window_start)do update set count=app_private.rate_limit_buckets.count+1 returning count into budget;
 if budget>30 then raise exception 'RATE_LIMITED'using errcode='P0001';end if;
 r:=app_private.duinpad_run_for_actor(e,a);
 if r is null then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into c from app_private.duinpad_checkpoints where event_id=e and(_portal_id is null or coalesce(portal_id,id)=_portal_id);
 if c.id is null then return null;end if;
 if (c.portal_id is null and(c.token_hash=extensions.digest(_credential,'sha256')or c.short_code_hash=extensions.digest(upper(_credential),'sha256')))
  or(c.portal_id is not null and exists(select 1 from app_private.portal_credentials p where p.portal_id=c.portal_id and p.revoked_at is null and p.valid_from<=now()and(p.valid_until is null or p.valid_until>now())and(p.token_hash=extensions.digest(_credential,'sha256')or p.short_code_hash=extensions.digest(upper(_credential),'sha256'))))then
  context:=api.duinpad_finale_snapshot(_event_slug);
  if not exists(select 1 from app_private.duinpad_show_attempts where run_id=r and stage='qr1'and status='registered')and(not coalesce((context->>'eligible')::boolean,false)or coalesce((context->>'eveningEnded')::boolean,true)or not exists(select 1 from app_private.group_runs where id=r and status='live'))then raise exception 'ROUTE_NOT_LIVE';end if;
  return jsonb_build_object('stage','qr1','runId',r,'relayGroupId',r,'eventId',e,'checkpointId',c.id,'label',c.label,'instruction',c.location_instruction);
 end if;
 return null;
end $$;
revoke all on function api.duinpad_checkpoint_validate(text,text,uuid)from public,anon;
grant execute on function api.duinpad_checkpoint_validate(text,text,uuid)to authenticated;

create table app_private.duinpad_show_attempts(
 id uuid primary key, event_id uuid not null references app_private.events(id),run_id uuid not null references app_private.group_runs(id),
 stage text not null check(stage in('qr1','qr2')),actor_id uuid not null references auth.users(id),
 source text not null check(source in('visitor','actor')),payload text not null check(octet_length(payload)<=4096),payload_hash text not null check(payload_hash~'^[a-f0-9]{64}$'),
 status text not null check(status in('requested','started','registered','blocked','not_dispatched','unknown','interrupted','recovery_required')),
 issued_at bigint not null,created_at timestamptz not null default now(),finished_at timestamptz,result jsonb
);
create index duinpad_show_group_history on app_private.duinpad_show_attempts(run_id,stage,created_at desc);
alter table app_private.duinpad_show_attempts enable row level security;
revoke all on app_private.duinpad_show_attempts from public,anon,authenticated;
create function api.duinpad_show_reserve(_actor uuid,_event uuid,_run uuid,_stage text,_id uuid,_source text,_payload text,_hash text,_issued_at bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.duinpad_show_attempts;
begin
 if _stage not in('qr1','qr2')or _source not in('visitor','actor')or _actor is null or abs(extract(epoch from clock_timestamp())-_issued_at)>5
  or encode(extensions.digest(_payload,'sha256'),'hex')is distinct from _hash then raise exception 'INVALID_INPUT';end if;
 if not exists(select 1 from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=_run and g.event_id=_event)then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if _source='actor'then
  if _stage<>'qr2'or not app_private.duinpad_actor_can(_event,_actor,'finale.go')then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 elsif app_private.duinpad_run_for_actor(_event,_actor)is distinct from _run then raise exception 'NOT_AUTHORIZED'using errcode='42501';
 elsif exists(select 1 from app_private.duinpad_evenings where run_id=_run and evening_ends_at<=clock_timestamp())then raise exception 'EVENING_ENDED';
 elsif _stage='qr2'and not exists(select 1 from app_private.duinpad_finale_account_claims c join app_private.duinpad_finale_receipts f on f.id=c.receipt_id where c.event_id=_event and c.account_id=_actor and f.run_id=_run)then raise exception 'SCAN_REQUIRED';
 end if;
 if (_payload::jsonb->>'group_id')is distinct from _run::text or (_payload::jsonb->>'issued_at')::bigint is distinct from _issued_at
  or (_source='visitor'and((_payload::jsonb->>'event_id')is distinct from _id::text or (_payload::jsonb->>'stage')is distinct from _stage))
  or (_source='actor'and((_payload::jsonb->>'command_id')is distinct from _id::text or (_payload::jsonb->>'action')is distinct from 'finale.go' or (_payload::jsonb->>'event_scope_id')is distinct from _event::text or (_payload::jsonb->>'actor_subject')is distinct from _actor::text))then raise exception 'PAYLOAD_MISMATCH';end if;
 -- One shared physical slot covers actor finale.go and all visitor scan units.
 perform pg_advisory_xact_lock(hashtextextended('duinpad:'||_run::text||':'||_stage,0));
 select *into p from app_private.duinpad_show_attempts where run_id=_run and stage=_stage and status in('requested','unknown','started','registered','interrupted','recovery_required')order by created_at desc limit 1;
 if p.id is not null then return jsonb_build_object('dispatch',false,'attemptId',p.id,'status',case when p.status='requested'and p.created_at<clock_timestamp()-interval '15 seconds'then 'unknown'else p.status end);end if;
 if exists(select 1 from app_private.duinpad_show_attempts where id=_id)then raise exception 'ATTEMPT_ALREADY_USED';end if;
 insert into app_private.duinpad_show_attempts(id,event_id,run_id,stage,actor_id,source,payload,payload_hash,status,issued_at)values(_id,_event,_run,_stage,_actor,_source,_payload,_hash,'requested',_issued_at);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)values(_event,_actor,'duinpad.show.requested','duinpad',_id,jsonb_build_object('stage',_stage,'source',_source));
 return jsonb_build_object('dispatch',true,'attemptId',_id,'status','requested');
end $$;
create function api.duinpad_show_finish(_id uuid,_status text,_result jsonb,_reconciled boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare p app_private.duinpad_show_attempts;
begin
 if _status not in('started','registered','blocked','not_dispatched','unknown','interrupted','recovery_required')or octet_length(_result::text)>2048 then raise exception 'INVALID_INPUT';end if;
 select *into p from app_private.duinpad_show_attempts where id=_id for update;
 if p.id is null then raise exception 'NOT_FOUND';end if;
 if p.status in('started','registered')then return;end if;
 if p.status in('unknown','interrupted','recovery_required')and not _reconciled then return;end if;
 update app_private.duinpad_show_attempts set status=_status,result=_result,finished_at=clock_timestamp()where id=_id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)values(p.event_id,p.actor_id,'duinpad.show.'||_status,'duinpad',_id,jsonb_build_object('stage',p.stage,'reconciled',_reconciled));
end $$;
create function api.duinpad_show_receipt(_actor uuid,_event_slug text,_id uuid default null,_stage text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e uuid:=app_private.current_event_id(_event_slug);r uuid;p app_private.duinpad_show_attempts;
begin
 r:=app_private.duinpad_run_for_actor(e,_actor);
 select *into p from app_private.duinpad_show_attempts where event_id=e and(_stage is null or stage=_stage)and(id=_id or(_id is null and run_id=r))order by created_at desc limit 1;
 if p.id is null then return null;end if;
 if not(p.run_id=r or(p.actor_id=_actor and app_private.duinpad_actor_can(e,_actor,'finale.go'))or app_private.has_capability(e,'event_admin',_actor))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 return jsonb_build_object('attemptId',p.id,'eventId',e,'runId',p.run_id,'stage',p.stage,'source',p.source,'status',case when p.status='requested'and p.created_at<clock_timestamp()-interval '15 seconds'then 'unknown'else p.status end,'result',p.result,'payload',p.payload,'payloadHash',p.payload_hash);
end $$;
revoke all on function api.duinpad_show_reserve(uuid,uuid,uuid,text,uuid,text,text,text,bigint)from public,anon,authenticated;
revoke all on function api.duinpad_show_finish(uuid,text,jsonb,boolean)from public,anon,authenticated;
revoke all on function api.duinpad_show_receipt(uuid,text,uuid,text)from public,anon,authenticated;
grant execute on function api.duinpad_show_reserve(uuid,uuid,uuid,text,uuid,text,text,text,bigint),api.duinpad_show_finish(uuid,text,jsonb,boolean),api.duinpad_show_receipt(uuid,text,uuid,text)to service_role;
