-- Explicit organization policy:65 minutes actual walking, proposed30-minute
-- early-completion tolerance. Policy changes never apply a route or send mail.
set lock_timeout='5s';
alter table app_private.event_route_settings
 add column max_total_walking_seconds integer not null default 3900 check(max_total_walking_seconds between 1 and 86400),
 add column max_early_finish_seconds integer not null default 1800 check(max_early_finish_seconds between 0 and 86400),
 add column organizer_coverage_portal_ids uuid[] not null default'{}',
 add column route_policy_version integer not null default 1 check(route_policy_version>0);

-- These four fields have a separate version. Neither their initialization nor
-- an authorized later policy edit invalidates an unchanged start confirmation.
create function app_private.touch_route_policy_settings() returns trigger language plpgsql set search_path='' as $$
begin
 if(to_jsonb(new)-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version'])
  is distinct from(to_jsonb(old)-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version']) then new.updated_at:=now();end if;
 return new;
end $$;
drop trigger event_route_settings_touch on app_private.event_route_settings;
create trigger event_route_settings_touch before update on app_private.event_route_settings for each row execute function app_private.touch_route_policy_settings();
drop trigger validate_finale_capacity_edit on app_private.event_route_settings;
create trigger validate_finale_capacity_edit after update on app_private.event_route_settings for each row
 when((to_jsonb(old)-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version'])
 is distinct from(to_jsonb(new)-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version']))
 execute function app_private.validate_finale_capacity_edit();
revoke all on function app_private.touch_route_policy_settings() from public,anon,authenticated;

update app_private.event_route_settings s set organizer_coverage_portal_ids=coalesce((select array_agg(p.id order by array_position(array['P-02','P-12'],p.system_code))
 from app_private.portals p where p.event_id=s.event_id and p.system_code in('P-02','P-12')and p.lifecycle_status='active'and p.approval_status='approved'
 and p.operation_status in('open','scheduled')and p.id is distinct from s.final_portal_id),'{}')
 from app_private.events e where e.id=s.event_id and e.slug='duindorp-halloween-2026';

alter function app_private.joint_route_source_hash(uuid) rename to joint_route_source_hash_before_v3;
create function app_private.joint_route_source_hash(_event uuid) returns text language sql stable security definer set search_path='' as $$
 select encode(extensions.digest(jsonb_build_object('policyVersion',3,'source',app_private.joint_route_source_hash_before_v3(_event))::text,'sha256'),'hex')
$$;
revoke all on function app_private.joint_route_source_hash_before_v3(uuid),app_private.joint_route_source_hash(uuid) from public,anon,authenticated;

alter function api.admin_joint_route_planning_input(text) rename to admin_joint_route_planning_input_before_v3;
alter function api.admin_joint_route_planning_input_before_v3(text) set schema app_private;
create function api.admin_joint_route_planning_input(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare input jsonb;settings app_private.event_route_settings;
begin
 input:=app_private.admin_joint_route_planning_input_before_v3(_event_slug);
 select *into settings from app_private.event_route_settings where event_id=(input->>'eventId')::uuid;
 return input||jsonb_build_object('policyVersion','joint-reception-v3','maxTotalWalkingSeconds',settings.max_total_walking_seconds,
  'maxEarlyFinishSeconds',settings.max_early_finish_seconds,'organizerCoveragePortalIds',settings.organizer_coverage_portal_ids,'routePolicySettingsVersion',settings.route_policy_version,
  'groups',coalesce((select jsonb_agg(g||jsonb_build_object('earliestCompletionAt',case when g->>'desiredEndAt'is not null then(g->>'desiredEndAt')::timestamptz-make_interval(secs=>settings.max_early_finish_seconds)end,
   'latestCompletionAt',case when g->>'desiredEndAt'is not null then(g->>'desiredEndAt')::timestamptz+make_interval(secs=>app_private.group_end_overrun_seconds())end)order by g->>'id')from jsonb_array_elements(input->'groups')g),'[]'));
end $$;
revoke all on function app_private.admin_joint_route_planning_input_before_v3(text),api.admin_joint_route_planning_input(text) from public,anon,authenticated;
grant execute on function api.admin_joint_route_planning_input(text) to authenticated;

create function api.admin_joint_route_policy_get(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eid uuid;s app_private.event_route_settings;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if auth.uid()is null or eid is null or not(app_private.has_capability(eid,'event_admin',auth.uid())or app_private.has_capability(eid,'groups_manage',auth.uid()))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into s from app_private.event_route_settings where event_id=eid;
 return jsonb_build_object('policyVersion','joint-reception-v3','version',s.route_policy_version,'maxTotalWalkingSeconds',s.max_total_walking_seconds,
 'maxEarlyFinishSeconds',s.max_early_finish_seconds,'maxGroupOverrunSeconds',app_private.group_end_overrun_seconds(),'organizerCoveragePortalIds',s.organizer_coverage_portal_ids,'sourceHash',app_private.joint_route_source_hash(eid),
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'active',p.lifecycle_status='active'and p.approval_status='approved'and p.operation_status in('open','scheduled')and app_private.portal_location_ready(p.id)and exists(select 1 from app_private.portal_effective_windows(p.id)),'finale',p.id=s.final_portal_id)order by p.system_code)
 from app_private.portals p where p.event_id=eid),'[]'));
end $$;
create function api.admin_joint_route_policy_save(_event_slug text,_expected_version integer,_max_total_walking_seconds integer,_max_early_finish_seconds integer,
 _organizer_coverage_portal_ids uuid[],_reason text,_idempotency_key text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;s app_private.event_route_settings;old app_private.command_receipts;hashed text;result jsonb;changed boolean;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid()is null or eid is null or not(app_private.has_capability(eid,'event_admin',auth.uid())or app_private.has_capability(eid,'groups_manage',auth.uid()))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 if _expected_version is null or _expected_version<1 or _max_total_walking_seconds is null or _max_total_walking_seconds not between 1 and 86400
 or _max_early_finish_seconds is null or _max_early_finish_seconds not between 0 and 86400 or _organizer_coverage_portal_ids is null
 or coalesce(array_ndims(_organizer_coverage_portal_ids),1)<>1 or cardinality(_organizer_coverage_portal_ids)>120
 or array_position(_organizer_coverage_portal_ids,null)is not null or cardinality(_organizer_coverage_portal_ids)<>(select count(distinct x)from unnest(_organizer_coverage_portal_ids)x)
 or char_length(trim(coalesce(_reason,'')))not between 10 and 500 or coalesce(_idempotency_key,'')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 then raise exception 'INVALID_ROUTE_POLICY_CONFIG'using errcode='22023';end if;
 hashed:=encode(extensions.digest(jsonb_build_array(eid,_expected_version,_max_total_walking_seconds,_max_early_finish_seconds,_organizer_coverage_portal_ids,trim(_reason))::text,'sha256'),'hex');
 select *into old from app_private.command_receipts where actor_id=auth.uid()and command_type='joint_route.policy_save'and idempotency_key=_idempotency_key;
 if old.id is not null then if old.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'using errcode='23505';end if;return old.safe_result;end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 select *into s from app_private.event_route_settings where event_id=eid for update;
 if s.route_policy_version<>_expected_version then raise exception 'STALE_VERSION'using errcode='40001';end if;
 if exists(select 1 from unnest(_organizer_coverage_portal_ids)x where not exists(select 1 from app_private.portals p where p.id=x and p.event_id=eid and p.id is distinct from s.final_portal_id
 and p.lifecycle_status='active'and p.approval_status='approved'and p.operation_status in('open','scheduled')and app_private.portal_location_ready(p.id)
 and exists(select 1 from app_private.portal_effective_windows(p.id))))
 or cardinality(_organizer_coverage_portal_ids)<>(select count(distinct app_private.portal_physical_identity(x))from unnest(_organizer_coverage_portal_ids)x)
 then raise exception 'INVALID_ORGANIZER_COVERAGE_PORTAL'using errcode='23514';end if;
 changed:=row(s.max_total_walking_seconds,s.max_early_finish_seconds,s.organizer_coverage_portal_ids)is distinct from row(_max_total_walking_seconds,_max_early_finish_seconds,_organizer_coverage_portal_ids);
 if changed then
 update app_private.event_route_settings set max_total_walking_seconds=_max_total_walking_seconds,max_early_finish_seconds=_max_early_finish_seconds,
  organizer_coverage_portal_ids=_organizer_coverage_portal_ids,route_policy_version=route_policy_version+1 where event_id=eid;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,auth.uid(),'route.policy_updated','event',eid,jsonb_build_object('maxTotalWalkingSeconds',_max_total_walking_seconds,'maxEarlyFinishSeconds',_max_early_finish_seconds,
  'organizerCoveragePortalIds',_organizer_coverage_portal_ids,'previousVersion',s.route_policy_version,'reason',trim(_reason)));
 end if;
 result:=api.admin_joint_route_policy_get(_event_slug)||jsonb_build_object('changed',changed);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'joint_route.policy_save',_idempotency_key,hashed,result,now()+interval'30 days');
 return result;
end $$;
revoke all on function api.admin_joint_route_policy_get(text),api.admin_joint_route_policy_save(text,integer,integer,integer,uuid[],text,text) from public,anon,authenticated;
grant execute on function api.admin_joint_route_policy_get(text),api.admin_joint_route_policy_save(text,integer,integer,integer,uuid[],text,text) to authenticated;

alter function app_private.validate_joint_route_proposal(jsonb,jsonb) rename to validate_joint_route_proposal_before_v3;
create function app_private.validate_joint_route_proposal(_input jsonb,_plans jsonb) returns void language plpgsql security definer set search_path='' as $$
declare plan jsonb;g jsonb;finish timestamptz;earliest timestamptz;latest timestamptz;
begin
 if _input->>'policyVersion'='joint-reception-v3'and((_input->>'maxEarlyFinishSeconds')is null or(_input->>'maxEarlyFinishSeconds')::integer not between 0 and 86400
 or _input->>'maxTotalWalkingSeconds'is null or(_input->>'maxTotalWalkingSeconds')::integer not between 1 and 86400 or _input->>'routePolicySettingsVersion'is null or(_input->>'routePolicySettingsVersion')::integer<1 or jsonb_typeof(_input->'organizerCoveragePortalIds')is distinct from'array')then raise exception 'INVALID_ROUTE_POLICY_CONFIG'using errcode='23514';end if;
 perform app_private.validate_joint_route_proposal_before_v3(_input,_plans);
 for plan in select *from jsonb_array_elements(_plans)loop
 select *into g from jsonb_array_elements(_input->'groups')x where x->>'id'=plan->>'groupId';
 if _input->>'policyVersion'='joint-reception-v3'and g->>'desiredEndAt'is not null then
  finish:=(plan->>'expectedCompletionAt')::timestamptz;
  earliest:=(g->>'desiredEndAt')::timestamptz-make_interval(secs=>coalesce((_input->>'maxEarlyFinishSeconds')::integer,0));
  latest:=(g->>'desiredEndAt')::timestamptz+make_interval(secs=>(_input->>'maxGroupOverrunSeconds')::integer);
  if g->>'earliestCompletionAt'is not null then earliest:=greatest(earliest,(g->>'earliestCompletionAt')::timestamptz);end if;
  if g->>'latestCompletionAt'is not null then latest:=least(latest,(g->>'latestCompletionAt')::timestamptz);end if;
  if finish<earliest then raise exception 'GROUP_COMPLETION_TOO_EARLY'using errcode='23514',detail=jsonb_build_object('groupId',g->'id','actualCompletionAt',finish,'earliestCompletionAt',earliest)::text;end if;
  if finish>latest then raise exception 'GROUP_COMPLETION_LIMIT'using errcode='23514';end if;
 end if;
 end loop;
end $$;
revoke all on function app_private.validate_joint_route_proposal_before_v3(jsonb,jsonb),app_private.validate_joint_route_proposal(jsonb,jsonb) from public,anon,authenticated;

-- Store authoritative policy limits with the new immutable acceptance evidence,
-- so changing policy later cannot retroactively change a begun run's limits.
do $migration$
declare definition text;fragment text;
begin
 definition:=pg_get_functiondef('api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text)'::regprocedure);
 fragment:=$old$coalesce(_proposal->'metrics','{}'),trim(_reason)$old$;
 if strpos(definition,fragment)=0 then raise exception 'JOINT_POLICY_METRICS_FRAGMENT_CHANGED';end if;
 execute replace(definition,fragment,$new$coalesce(_proposal->'metrics','{}')||jsonb_build_object('routePolicy',jsonb_build_object('maxTotalWalkingSeconds',input->'maxTotalWalkingSeconds','maxEarlyFinishSeconds',input->'maxEarlyFinishSeconds','maxOrdinaryLegSeconds',input->'maxLegWalkingSeconds','completionWindows',(select jsonb_agg(jsonb_build_object('groupId',g->'id','desiredEndAt',g->'desiredEndAt','earliestCompletionAt',g->'earliestCompletionAt','latestCompletionAt',g->'latestCompletionAt'))from jsonb_array_elements(input->'groups')g))),trim(_reason)$new$);
 definition:=pg_get_functiondef('app_private.accept_manual_route_intention(uuid,uuid,text)'::regprocedure);
 execute replace(definition,'''joint-reception-v2''','''joint-reception-v3''');
end $migration$;

create function app_private.group_route_completion_window(_group uuid,_early_seconds integer default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g app_private.walking_groups;s app_private.group_schedule_revisions;target timestamptz;early_seconds integer;
begin
 select *into g from app_private.walking_groups where id=_group;
 select *into s from app_private.group_schedule_revisions where id=(app_private.route_group_start_context(_group)->>'scheduleId')::uuid;
 select coalesce(_early_seconds,max_early_finish_seconds)into early_seconds from app_private.event_route_settings where event_id=g.event_id;
 select approved.dominant_end_at into target from app_private.registration_management_schedule_preferences approved where approved.group_id=g.id and approved.schedule_id=s.id and approved.composition_hash=app_private.start_group_composition_hash(g.id);
 if not found then
  if s.input_snapshot?'dominantEndAt'then target:=(s.input_snapshot->>'dominantEndAt')::timestamptz;
  else target:=app_private.dominant_end_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null));end if;
 end if;
 return jsonb_build_object('groupId',g.id,'desiredEndAt',target,'earliestCompletionAt',case when target is not null then target-make_interval(secs=>early_seconds)end,
 'latestCompletionAt',case when target is not null then target+make_interval(secs=>app_private.group_end_overrun_seconds())end);
end $$;
create function app_private.joint_route_policy_snapshot(_event uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('maxTotalWalkingSeconds',s.max_total_walking_seconds,'maxEarlyFinishSeconds',s.max_early_finish_seconds,'maxOrdinaryLegSeconds',900,
 'completionWindows',(select jsonb_agg(app_private.group_route_completion_window(g.id,s.max_early_finish_seconds)order by g.id)from app_private.walking_groups g where g.event_id=_event))
 from app_private.event_route_settings s where s.event_id=_event
$$;
create function app_private.joint_runtime_policy_violation(_run uuid,_kind text,_walk_seconds integer,_exit_seconds integer,_arrival timestamptz,_show_seconds integer) returns text
language plpgsql stable security definer set search_path='' as $$
declare run app_private.group_runs;accepted app_private.joint_route_plan_versions;policy jsonb;completion jsonb;spent bigint;finish timestamptz;
begin
 select *into run from app_private.group_runs where id=_run;
 select *into accepted from app_private.joint_route_plan_versions where id=run.accepted_route_version_id;
 if accepted.policy_version is distinct from'joint-reception-v3'then return null;end if;
 policy:=accepted.metrics->'routePolicy';
 if policy is null then raise exception 'ACCEPTED_ROUTE_POLICY_MISSING'using errcode='23514';end if;
 select coalesce(sum((d.input_snapshot->>'walkSeconds')::integer),0)into spent from app_private.dispatch_decisions d
 where d.run_id=_run and d.selected_portal_id is not null and d.input_snapshot?'walkSeconds'
 and exists(select 1 from app_private.run_stops stop where stop.run_id=_run and stop.portal_id=d.selected_portal_id and stop.state='completed');
 if _kind='ordinary'and _walk_seconds>(policy->>'maxOrdinaryLegSeconds')::integer then return'ORDINARY_LEG_WALKING_LIMIT';end if;
 if(spent+_walk_seconds+(case when _kind='ordinary'then coalesce(_exit_seconds,0)else 0 end))>(policy->>'maxTotalWalkingSeconds')::integer then return'ROUTE_TOTAL_WALKING_BUDGET';end if;
 if _kind='finale'then
 select *into completion from jsonb_array_elements(policy->'completionWindows')g where g->>'groupId'=run.group_id::text;
 finish:=_arrival+make_interval(secs=>_show_seconds);
 if completion->>'desiredEndAt'is not null and finish<(completion->>'earliestCompletionAt')::timestamptz then return'GROUP_COMPLETION_TOO_EARLY';end if;
 if completion->>'desiredEndAt'is not null and finish>(completion->>'latestCompletionAt')::timestamptz then return'GROUP_COMPLETION_LIMIT';end if;
 end if;
 return null;
end $$;
revoke all on function app_private.group_route_completion_window(uuid,integer),app_private.joint_route_policy_snapshot(uuid),app_private.joint_runtime_policy_violation(uuid,text,integer,integer,timestamptz,integer)from public,anon,authenticated;

do $migration$
declare definition text;fragment text;
begin
 definition:=pg_get_functiondef('app_private.accept_manual_route_intention(uuid,uuid,text)'::regprocedure);
 fragment:='accepted_by,group_plans,reason)';
 if strpos(definition,fragment)=0 then raise exception 'MANUAL_POLICY_SNAPSHOT_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,fragment,'accepted_by,group_plans,metrics,reason)');
 definition:=replace(definition,'auth.uid(),plans,trim(_reason)','auth.uid(),plans,jsonb_build_object(''routePolicy'',app_private.joint_route_policy_snapshot(_event)),trim(_reason)');
 definition:=replace(definition,'''joint-reception-v3'',auth.uid()',
  'coalesce((select accepted.policy_version from app_private.group_runs run join app_private.joint_route_plan_versions accepted on accepted.id=run.accepted_route_version_id where run.group_id=_group and run.status in(''live'',''paused'')limit 1),''joint-reception-v3''),auth.uid()');
 definition:=replace(definition,'jsonb_build_object(''routePolicy'',app_private.joint_route_policy_snapshot(_event))',
  'jsonb_build_object(''routePolicy'',coalesce((select accepted.metrics->''routePolicy'' from app_private.group_runs run join app_private.joint_route_plan_versions accepted on accepted.id=run.accepted_route_version_id where run.group_id=_group and run.status in(''live'',''paused'')limit 1),app_private.joint_route_policy_snapshot(_event)))');
 execute definition;

 definition:=pg_get_functiondef('app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid)'::regprocedure);
 definition:=replace(definition,'force_finale boolean:=_force_finale;','force_finale boolean:=_force_finale;policy_violation text;');
 definition:=replace(definition,'accepted.policy_version<>''joint-reception-v2''','accepted.policy_version not in(''joint-reception-v2'',''joint-reception-v3'')');
 fragment:=$old$ if(intent.kind='ordinary'and(arrival+make_interval(secs=>intent.duration_seconds)>app_private.group_ordinary_deadline(g.id)$old$;
 if strpos(definition,fragment)=0 then raise exception 'RUNTIME_POLICY_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,fragment,$new$ policy_violation:=app_private.joint_runtime_policy_violation(r.id,intent.kind,travel.duration_seconds::integer,exit_leg.duration_seconds::integer,arrival,intent.duration_seconds);
 if policy_violation is not null then
  insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
  select g.event_id,g.id,r.id,intent.portal_id,'warning',policy_violation,'De werkelijke wandeling of afronding past niet binnen het beoordeelde routebeleid. Beoordeel een expliciete herplanning.'
  where not exists(select 1 from app_private.route_alerts where run_id=r.id and code=policy_violation and status='open');
  return jsonb_build_object('decision','wait','retryAfterSeconds',120,'requiresReplanning',true,'reason',policy_violation,'acceptedVersionId',r.accepted_route_version_id);
 end if;
 if(intent.kind='ordinary'and(arrival+make_interval(secs=>intent.duration_seconds)>app_private.group_ordinary_deadline(g.id)$new$);
 execute definition;

 -- Unstarted compatibility previews use the same real walk budget and show-end
 -- lower bound. Existing begun routes retain their original accepted policy.
 definition:=pg_get_functiondef('app_private.start_ops_route_preview_before_joint_routes(uuid)'::regprocedure);
 definition:=replace(definition,'linked_start uuid; counts_as_first boolean;','linked_start uuid; counts_as_first boolean;walk_used bigint:=0;completion_window jsonb;');
 definition:=replace(definition,'  select * into settings from app_private.event_route_settings where event_id=g.event_id;',
 '  select * into settings from app_private.event_route_settings where event_id=g.event_id;completion_window:=app_private.group_route_completion_window(g.id);');
 fragment:='    ) q where q.walk_s is not null and (q.id=preserved_portal or (';
 if strpos(definition,fragment)=0 then raise exception 'PREVIEW_WALKING_POLICY_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,fragment,'    ) q where q.walk_s is not null and (r.id is not null or(q.walk_s<=900 and walk_used+q.walk_s+q.final_seconds<=settings.max_total_walking_seconds)) and (q.id=preserved_portal or (');
 definition:=replace(definition,'    meters:=meters+walk_m; seconds:=seconds+walk_s+', '    walk_used:=walk_used+walk_s;meters:=meters+walk_m; seconds:=seconds+walk_s+');
 fragment:='    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);';
 if strpos(definition,fragment)=0 then raise exception 'PREVIEW_COMPLETION_POLICY_FRAGMENT_CHANGED';end if;
 definition:=replace(definition,fragment,'    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at,case when r.id is null then(completion_window->>''earliestCompletionAt'')::timestamptz-make_interval(secs=>settings.finale_show_seconds)end);
    if r.id is null and walk_used+walk_s>settings.max_total_walking_seconds then warnings:=warnings||jsonb_build_array(''ROUTE_TOTAL_WALKING_BUDGET: de echte wandeling inclusief P-38 overschrijdt het ingestelde totaalbudget.'');end if;
    if r.id is null and not exists(select 1 from app_private.portal_effective_windows(candidate.id)w where at_time>=w.opens_at and at_time<=w.arrival_closes_at and at_time+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds)<=w.closes_at)
     then warnings:=warnings||jsonb_build_array(''GROUP_COMPLETION_WINDOW: de vroegste afronding en echte opening/sluiting van P-38 hebben geen passend tijdslot.'');end if;');
 execute definition;
end $migration$;
-- Manual planboard edits use the same policy before they can create immutable
-- acceptance evidence. Already begun routes keep their accepted policy.
alter function app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb) rename to live_planboard_warnings_before_v3;
create function app_private.live_planboard_warnings_from_visits(_event uuid,_changes jsonb,_visits jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;g app_private.walking_groups;s app_private.event_route_settings;v jsonb;ctx jsonb;position jsonb;travel record;walked bigint;completion_window jsonb;finish timestamptz;code text;ids jsonb;run app_private.group_runs;accepted app_private.joint_route_plan_versions;policy jsonb;total_limit integer;leg_limit integer;
begin
 result:=app_private.live_planboard_warnings_before_v3(_event,_changes,_visits);
 select *into s from app_private.event_route_settings where event_id=_event;
 for g in select *from app_private.walking_groups where event_id=_event and retired_at is null loop
  select *into run from app_private.group_runs where group_id=g.id and status in('live','paused')order by created_at desc limit 1;
  select *into accepted from app_private.joint_route_plan_versions where id=run.accepted_route_version_id;
  if app_private.admin_registration_group_started(g.id)and accepted.policy_version is distinct from'joint-reception-v3'then continue;end if;
  ctx:=app_private.route_group_start_context(g.id);completion_window:=app_private.group_route_completion_window(g.id);walked:=0;total_limit:=s.max_total_walking_seconds;leg_limit:=900;
  if run.id is not null then
   policy:=accepted.metrics->'routePolicy';
   if policy is null or policy='null'::jsonb then raise exception 'ACCEPTED_ROUTE_POLICY_MISSING'using errcode='23514';end if;
   total_limit:=(policy->>'maxTotalWalkingSeconds')::integer;leg_limit:=(policy->>'maxOrdinaryLegSeconds')::integer;
   select *into completion_window from jsonb_array_elements(policy->'completionWindows')w where w->>'groupId'=g.id::text;
   select coalesce(sum((d.input_snapshot->>'walkSeconds')::integer),0)into walked from app_private.dispatch_decisions d where d.run_id=run.id and d.selected_portal_id is not null and d.input_snapshot?'walkSeconds'
    and exists(select 1 from app_private.run_stops stop where stop.run_id=run.id and stop.portal_id=d.selected_portal_id and stop.state in('active','completed'));
  end if;
  position:=app_private.routing_position((ctx#>>'{pointSnapshot,marker_latitude}')::numeric,(ctx#>>'{pointSnapshot,marker_longitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_latitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_longitude}')::numeric,(ctx#>>'{pointSnapshot,latitude}')::numeric,(ctx#>>'{pointSnapshot,longitude}')::numeric);
  if run.id is not null then
   select app_private.portal_location(coalesce(stop.portal_id,planned.portal_id))into position from app_private.run_stops stop left join app_private.route_plan_stops planned on planned.id=stop.plan_stop_id
    where stop.run_id=run.id and stop.state in('active','completed')order by stop.sequence desc limit 1;
   if position is null then position:=app_private.routing_position((ctx#>>'{pointSnapshot,marker_latitude}')::numeric,(ctx#>>'{pointSnapshot,marker_longitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_latitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_longitude}')::numeric,(ctx#>>'{pointSnapshot,latitude}')::numeric,(ctx#>>'{pointSnapshot,longitude}')::numeric);end if;
  end if;
  for v in select *from jsonb_array_elements(_visits)x where x->>'groupId'=g.id::text and x->>'kind'<>'start'and x->>'retired_at'is null and(run.id is null or x->>'runStopId'is null)order by(x->>'sequence')::integer loop
   select *into travel from app_private.destination_estimate((position->>'latitude')::numeric,(position->>'longitude')::numeric,(app_private.portal_location((v->>'portalId')::uuid)->>'latitude')::numeric,(app_private.portal_location((v->>'portalId')::uuid)->>'longitude')::numeric);
   walked:=walked+coalesce(travel.duration_seconds,0);code:=null;
   if v->>'kind'='ordinary'and travel.duration_seconds>leg_limit then code:='ORDINARY_LEG_WALKING_LIMIT';end if;
   if walked>total_limit then code:='ROUTE_TOTAL_WALKING_BUDGET';end if;
   if v->>'kind'='finale'then
    finish:=(v->>'startsAt')::timestamptz+make_interval(secs=>(v->>'durationSeconds')::integer);
    if completion_window->>'desiredEndAt'is not null and finish<(completion_window->>'earliestCompletionAt')::timestamptz then code:='GROUP_COMPLETION_TOO_EARLY';end if;
    if completion_window->>'desiredEndAt'is not null and finish>(completion_window->>'latestCompletionAt')::timestamptz then code:='GROUP_COMPLETION_LIMIT';end if;
   end if;
   if code is not null and not exists(select 1 from jsonb_array_elements(result)n where n->>'code'=code and n->'groupIds'@>jsonb_build_array(g.id))then
    select coalesce(jsonb_agg(x->'id'),'[]')into ids from jsonb_array_elements(_visits)x where x->>'groupId'=g.id::text and x->>'retired_at'is null;
    result:=result||jsonb_build_array(jsonb_build_object('code',code,'severity','block','message','De werkelijke wandeling inclusief P-38 of het einde van de finales­how valt buiten het ingestelde routebeleid.','visitIds',ids,'groupIds',jsonb_build_array(g.id)));
   end if;
   position:=app_private.portal_location((v->>'portalId')::uuid);
  end loop;
 end loop;
 return result;
end $$;
revoke all on function app_private.live_planboard_warnings_before_v3(uuid,jsonb,jsonb),app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb)from public,anon,authenticated;

insert into app_private.joint_route_policy_releases(policy_version)values('joint-reception-v3');
