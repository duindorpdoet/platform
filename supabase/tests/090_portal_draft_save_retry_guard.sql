begin;
create extension if not exists pgtap with schema extensions;
select extensions.no_plan();
create temp table portal_save_regression_results(check_name text) on commit drop;
do $test$
declare
 event_slug text := 'duindorp-halloween-2026';
 eid uuid; actor uuid; gid uuid; pid uuid; rid uuid;
 command_payload jsonb; stored_payload jsonb; first_result jsonb; result jsonb; impact jsonb;
 current_version integer; protected_payload jsonb;
begin
 select id into strict eid from app_private.events where slug=event_slug;
 select user_id into strict actor from app_private.event_capabilities
  where event_id=eid and capability='portals_manage' order by user_id limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 command_payload:=jsonb_build_object('name','Portal save regression '||gen_random_uuid()::text,
  'worldSlug','anders','lifecycleStatus','concept','approvalStatus','draft',
  'impactHash','obsolete-saved-confirmation','impactConfirmed',true,'commandKey',gen_random_uuid()::text);
 first_result:=api.admin_manual_portal_save(event_slug,null,command_payload,null,'Transactional portal-save regression test');
 pid:=(first_result->>'id')::uuid;
 select payload into strict stored_payload from app_private.portal_maintenance_drafts where portal_id=pid;
 if stored_payload ?| array['impactHash','impactConfirmed','commandKey'] then
  raise exception using errcode='XX000',message='Draft insert retained transient command metadata';
 end if;
 if stored_payload->>'name' is distinct from command_payload->>'name' then
  raise exception using errcode='XX000',message='Draft cleanup changed editable fields';
 end if;
 insert into portal_save_regression_results values('draft insert strips control metadata and preserves editable fields');

 result:=api.admin_manual_portal_save(event_slug,null,command_payload,null,'Transactional portal-save regression test');
 if result is distinct from first_result then
  raise exception using errcode='XX000',message='Idempotent replay did not return the original receipt';
 end if;
 insert into portal_save_regression_results values('idempotent creation replay is unchanged');

 begin
  perform api.admin_manual_portal_save(event_slug,null,command_payload||'{"name":"Conflicting request"}',null,'Transactional portal-save regression test');
  raise exception using errcode='XX000',message='Changed content reused an idempotency key';
 exception when sqlstate 'P0001' then
  if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if;
 end;
 insert into portal_save_regression_results values('idempotency conflict remains enforced');

 update app_private.portal_maintenance_drafts
 set payload=payload||'{"impactHash":"stale","impactConfirmed":true,"commandKey":"stale-command-key"}'
 where portal_id=pid;
 select payload into stored_payload from app_private.portal_maintenance_drafts where portal_id=pid;
 if stored_payload ?| array['impactHash','impactConfirmed','commandKey'] then
  raise exception using errcode='XX000',message='Draft update retained transient command metadata';
 end if;
 insert into portal_save_regression_results values('draft update also strips control metadata');

 -- Reopening uses the stored payload, exactly where the old hash used to survive.
 command_payload:=stored_payload||jsonb_build_object('approvalStatus','submitted','saveMode','activate','commandKey',gen_random_uuid()::text);
 select version into current_version from app_private.portals where id=pid;
 result:=api.admin_manual_portal_save(event_slug,pid,command_payload,current_version,'Reopened portal draft saves after a sensitive field change');
 if (result->>'version')::integer<=current_version then
  raise exception using errcode='XX000',message='Reopened portal draft was not saved';
 end if;
 insert into portal_save_regression_results values('reopened draft with a sensitive change saves successfully');

 select version into current_version from app_private.portals where id=pid;
 begin
  perform api.admin_manual_portal_save(event_slug,pid,command_payload-'commandKey',current_version-1,'Reject an outdated portal record without retrying forever');
  raise exception using errcode='XX000',message='Outdated portal version was accepted';
 exception when sqlstate 'P0001' then
  if sqlerrm<>'STALE_VERSION' then raise; end if;
 end;
 insert into portal_save_regression_results values('nested stale record version returns final P0001');

 begin
  perform api.admin_manual_portal_save(event_slug,pid,(command_payload||'{"operationStatus":"paused","impactHash":"outdated"}')-'commandKey',current_version,'Reject an outdated confirmation hash without retrying forever');
  raise exception using errcode='XX000',message='Outdated impact hash was accepted';
 exception when sqlstate 'P0001' then
  if sqlerrm<>'STALE_VERSION' then raise; end if;
 end;
 insert into portal_save_regression_results values('stale confirmation hash returns final P0001');

 insert into app_private.walking_groups(event_id,code,system_number,system_code)
 select eid,'REGRESSION-'||pid::text,n,'G-'||lpad(n::text,2,'0')
 from (select coalesce(max(system_number),0)+1 as n from app_private.walking_groups where event_id=eid) next_number
 returning id into gid;
 insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
 values(eid,pid,gid,'finale','held','2026-10-31T17:00:00Z','2026-10-31T17:10:00Z',1)
 returning id into rid;
 protected_payload:=(command_payload-'commandKey')||'{"operationStatus":"paused"}';
 begin
  perform api.admin_manual_portal_save(event_slug,pid,protected_payload,current_version,'Protected portal requires a reviewed confirmation');
  raise exception using errcode='XX000',message='Protected portal changed without confirmation';
 exception when sqlstate '23514' then
  if sqlerrm<>'CONFIRMATION_REQUIRED' then raise; end if;
 end;
 insert into portal_save_regression_results values('protected portal still requires explicit confirmation');

 impact:=api.admin_portal_change_impact(pid);
 begin
  perform api.admin_manual_portal_save(event_slug,pid,protected_payload||jsonb_build_object('impactHash',impact->>'inputHash','impactConfirmed',true),current_version,'An active reservation still blocks a confirmed portal change');
  raise exception using errcode='XX000',message='Active reservation was bypassed';
 exception when sqlstate '23514' then
  if sqlerrm<>'RESOLVE_ACTIVE_VISITS_FIRST' then raise; end if;
 end;
 insert into portal_save_regression_results values('active reservations remain protected after confirmation');

 perform set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
 begin
  perform api.admin_manual_portal_save(event_slug,pid,command_payload-'commandKey',current_version,'An account without portal rights must remain blocked');
  raise exception using errcode='XX000',message='Unauthorized actor edited a portal';
 exception when sqlstate '42501' then
  if sqlerrm<>'NOT_AUTHORIZED' then raise; end if;
 end;
 insert into portal_save_regression_results values('authorization remains enforced');
 if has_function_privilege('anon','api.admin_manual_portal_save(text,uuid,jsonb,integer,text)','execute')
  or has_function_privilege('authenticated','app_private.strip_portal_draft_command_metadata()','execute') then
  raise exception using errcode='XX000',message='Hotfix exposed a privileged function';
 end if;
 insert into portal_save_regression_results values('private trigger and API permissions remain restricted');
end
$test$;
select extensions.ok(true,check_name) from portal_save_regression_results order by check_name;
select * from extensions.finish();
rollback;
