-- Forward-only completion of general thanks and paused -> closed recovery.
-- No deployed migration, historical row or existing policy is rewritten.
create table app_private.fn_organization_thanks (
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null, run_id uuid not null, registration_id uuid not null,
 actor_id uuid not null references auth.users(id),
 message text not null check(length(message) between 1 and 500),
 created_at timestamptz not null default now(),
 unique(event_id,registration_id),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id),
 foreign key(event_id) references app_private.fn_events(event_id)
);
alter table app_private.fn_organization_thanks enable row level security;
revoke all on app_private.fn_organization_thanks from public,anon,authenticated,service_role;

-- Preserve the reviewed provider projection and admission wrapper exactly.
alter function api.frightnight_snapshot(text) set schema app_private;
alter function app_private.frightnight_snapshot(text) rename to fn_snapshot_policy_impl;
revoke all on function app_private.fn_snapshot_policy_impl(text) from public,anon,authenticated,service_role;
alter function api.frightnight_command(text,text,jsonb,uuid) set schema app_private;
alter function app_private.frightnight_command(text,text,jsonb,uuid) rename to fn_command_access_impl;
revoke all on function app_private.fn_command_access_impl(text,text,jsonb,uuid) from public,anon,authenticated,service_role;

create function api.frightnight_snapshot(p_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; rid uuid; result jsonb;
begin
 result:=app_private.fn_snapshot_policy_impl(p_slug);
 eid:=(result#>>'{event,id}')::uuid;rid:=(result#>>'{registration,id}')::uuid;
 result:=result||jsonb_build_object('organizationThanksSent',exists(select 1 from app_private.fn_organization_thanks t where t.event_id=eid and t.registration_id=rid));
 if app_private.fn_can(eid,'content_manage',actor) then
  result:=result||jsonb_build_object('feedback',jsonb_build_object(
   'organizationThanks',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'registrationId',t.registration_id,'label',r.label,'message',t.message,'createdAt',t.created_at)order by t.created_at desc,t.id)from(select *from app_private.fn_organization_thanks where event_id=eid order by created_at desc,id limit 100)t join app_private.fn_registrations r on r.event_id=t.event_id and r.id=t.registration_id),'[]'::jsonb),
   'evaluations',coalesce((select jsonb_agg(jsonb_build_object('registrationId',t.registration_id,'label',r.label,'rating',t.rating,'message',t.message,'createdAt',t.created_at)order by t.created_at desc,t.registration_id)from(select *from app_private.fn_evaluations where event_id=eid order by created_at desc,registration_id limit 100)t join app_private.fn_registrations r on r.event_id=t.event_id and r.id=t.registration_id),'[]'::jsonb)));
 end if;
 return result;
end $$;
revoke all on function api.frightnight_snapshot(text) from public,anon,service_role;
grant execute on function api.frightnight_snapshot(text) to authenticated;

create function app_private.fn_general_thanks(p_slug text,p_payload jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; rid uuid; r app_private.fn_registrations; previous app_private.fn_receipts; request_digest bytea; thanks app_private.fn_organization_thanks; message text; result jsonb;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_key is null or p_payload is null or jsonb_typeof(p_payload)<>'object' or (p_payload-'text')<>'{}'::jsonb or jsonb_typeof(p_payload->'text') is distinct from 'string' then raise exception 'INVALID_GENERAL_THANKS' using errcode='22023'; end if;
 perform app_private.fn_require_context(p_slug,actor);
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
 rid:=app_private.fn_registration(eid,actor);
 select *into r from app_private.fn_registrations where event_id=eid and id=rid;
 if r.id is null or r.status='archived' then raise exception 'REGISTRATION_REQUIRED' using errcode='42501'; end if;
 message:=trim(p_payload->>'text');
 if length(message) not between 1 and 500 then raise exception 'INVALID_GENERAL_THANKS' using errcode='22023'; end if;
 request_digest:=extensions.digest('thanks.general:'||p_payload::text,'sha256');
 select *into previous from app_private.fn_receipts where event_id=eid and actor_id=actor and command_key=p_key;
 if found then
  if previous.result#>>'{snapshot,registration,id}' is distinct from rid::text then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if previous.request_hash<>request_digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='40001'; end if;
  return jsonb_build_object('ok',true,'result',previous.result->'result','snapshot',api.frightnight_snapshot(p_slug));
 end if;
 select *into thanks from app_private.fn_organization_thanks where event_id=eid and registration_id=rid;
 if found and thanks.message<>message then raise exception 'GENERAL_THANKS_ALREADY_SENT' using errcode='40001'; end if;
 if thanks.id is null then
  insert into app_private.fn_organization_thanks(event_id,run_id,registration_id,actor_id,message)values(eid,r.run_id,rid,actor,message)returning *into thanks;
  insert into app_private.fn_audit(event_id,actor_id,action,details)values(eid,actor,'thanks.general',jsonb_build_object('thanksId',thanks.id,'registrationId',rid,'commandId',p_key,'delivery','in-app'));
 end if;
 result:=jsonb_build_object('thanksId',thanks.id,'saved',true,'delivery','in-app','mailSent',false);
 insert into app_private.fn_receipts(event_id,actor_id,command_key,request_hash,result)values(eid,actor,p_key,request_digest,jsonb_build_object('result',result,'snapshot',jsonb_build_object('registration',jsonb_build_object('id',rid))));
 return jsonb_build_object('ok',true,'result',result,'snapshot',api.frightnight_snapshot(p_slug));
end $$;
revoke all on function app_private.fn_general_thanks(text,jsonb,uuid) from public,anon,authenticated,service_role;

create function api.frightnight_command(p_slug text,p_command text,p_payload jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; was_closed boolean; replay boolean; response jsonb;
begin
 if p_command='thanks.general' then return app_private.fn_general_thanks(p_slug,p_payload,p_key); end if;
 if p_command='admin.settings' and p_payload->'closed'='true'::jsonb then
  -- Keep the original payload/hash. A receipt replay must never clear a later
  -- legitimate pause, and an already closed edition is not a new transition.
  perform app_private.fn_require_context(p_slug,actor);
  select e.id,f.closed into eid,was_closed from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
  select exists(select 1 from app_private.fn_receipts where event_id=eid and actor_id=actor and command_key=p_key)into replay;
  response:=app_private.fn_command_access_impl(p_slug,p_command,p_payload,p_key);
  if not replay and not was_closed and response#>>'{snapshot,event,closed}'='true' then
   update app_private.fn_events set paused=false where event_id=eid and paused;
   response:=jsonb_set(response,'{snapshot}',api.frightnight_snapshot(p_slug));
  end if;
  return response;
 end if;
 return app_private.fn_command_access_impl(p_slug,p_command,p_payload,p_key);
end $$;
revoke all on function api.frightnight_command(text,text,jsonb,uuid) from public,anon,service_role;
grant execute on function api.frightnight_command(text,text,jsonb,uuid) to authenticated;
