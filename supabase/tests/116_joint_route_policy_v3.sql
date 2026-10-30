begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
select pg_temp.joint_canonical_fixture();
update app_private.event_route_settings set max_early_finish_seconds=1800 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
create temp table v3_test(input jsonb,proposal jsonb,baseline jsonb,settings jsonb,saved jsonb,key text default gen_random_uuid()::text);
insert into v3_test(input,proposal,settings)select api.admin_joint_route_planning_input('duindorp-halloween-2026'),pg_temp.joint_proposal(),
 (select to_jsonb(s)from app_private.event_route_settings s where event_id=(select id from app_private.events where slug='duindorp-halloween-2026'));
-- Isolate one real group; duration, pin-based travel, reception and identity
-- remain server-owned. Other groups do not cause unrelated headway conflicts.
update v3_test set input=jsonb_set(input,'{groups}',jsonb_build_array(input->'groups'->0)),proposal=jsonb_set(proposal,'{groups}',jsonb_build_array(proposal->'groups'->0));
create function pg_temp.v3_finish(_at timestamptz)returns void language plpgsql as $$
declare t v3_test;p jsonb;arrival timestamptz;
begin
 select *into t from v3_test;p:=t.proposal->'groups'->0;arrival:=_at-make_interval(secs=>(p#>>'{visits,1,visitSeconds}')::integer);
 p:=jsonb_set(p,'{visits,1,startsAt}',to_jsonb(arrival))||jsonb_build_object('finaleArrivalAt',arrival,'expectedCompletionAt',_at,
 'finaleChange',jsonb_build_object('portalId',p#>'{visits,1,portalId}','previousReservedAt',t.input#>'{groups,0,finale,reservedAt}','proposedReservedAt',arrival));
 update v3_test set proposal=pg_temp.joint_rehash(jsonb_set(t.proposal,'{groups,0}',p));
end $$;
select pg_temp.v3_finish('2026-10-31T18:30:00Z');
update v3_test set baseline=proposal;
select is((select input->>'policyVersion'from v3_test),'joint-reception-v3','server exposes v3');
select is((select(input->>'maxTotalWalkingSeconds')::integer from v3_test),3900,'default budget is65 minutes including finale');
select is((select(input->>'maxEarlyFinishSeconds')::integer from v3_test),1800,'proposed early tolerance is30 minutes');
select is((select(input->>'maxLegWalkingSeconds')::integer from v3_test),900,'ordinary leg limit remains separate');
select is((select(input#>>'{groups,0,earliestCompletionAt}')::timestamptz from v3_test),'2026-10-31T18:30:00Z'::timestamptz,'server derives earliest show completion from desired end');
select is((select(input#>>'{groups,0,latestCompletionAt}')::timestamptz from v3_test),'2026-10-31T19:30:00Z'::timestamptz,'existing overrun remains separately30 minutes');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'show END exactly at desired minus30 minutes is valid');
select pg_temp.v3_finish('2026-10-31T18:29:59Z');
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'23514','GROUP_COMPLETION_TOO_EARLY','one second too early is a hard show-end violation');
savepoint upper_boundary;
update v3_test set input=jsonb_set(input,'{groups,0}',input#>'{groups,0}'||jsonb_build_object('desiredEndAt','2026-10-31T18:00:00Z','earliestCompletionAt','2026-10-31T17:30:00Z','latestCompletionAt','2026-10-31T18:30:00Z'));
select pg_temp.v3_finish('2026-10-31T18:30:00Z');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'show END exactly at existing upper tolerance is valid');
select pg_temp.v3_finish('2026-10-31T18:30:01Z');
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'23514','GROUP_COMPLETION_LIMIT','show end beyond existing overrun stays invalid');
rollback to upper_boundary;
update v3_test set proposal=baseline;
savepoint no_desired;
update v3_test set input=jsonb_set(input,'{groups,0}',input#>'{groups,0}'||jsonb_build_object('desiredEndAt',null,'earliestCompletionAt',null,'latestCompletionAt',null));
select pg_temp.v3_finish('2026-10-31T18:00:00Z');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'without desired end no artificial lower completion bound is invented');
rollback to no_desired;
savepoint long_finale;
-- Only trusted test data changes the matrix. Both route and server duration
-- match, and the actual last leg now consumes the whole remaining budget.
create function pg_temp.v3_walk(_total integer)returns void language plpgsql as $$
declare t v3_test;p jsonb;seconds integer;
begin
 select *into t from v3_test;p:=t.proposal->'groups'->0;seconds:=_total-(p#>>'{visits,0,walkSeconds}')::integer;
 update v3_test set input=jsonb_set(input,'{legs}',(select jsonb_agg(case when l->>'from'='portal:'||(p#>>'{visits,0,portalId}')and l->>'to'='portal:'||(p#>>'{visits,1,portalId}')then l||jsonb_build_object('seconds',seconds)else l end)from jsonb_array_elements(input->'legs')l)),
 proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{groups,0,visits,1,walkSeconds}',to_jsonb(seconds)));
end $$;
select pg_temp.v3_walk(3900);
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'exact3900-second actual total including longfinale is valid');
select pg_temp.v3_walk(3901);
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'23514','ROUTE_TOTAL_WALKING_BUDGET','3901 seconds fails total budget rather than a final-leg cap');
rollback to long_finale;
create function pg_temp.v3_manual_notices()returns jsonb language sql as $$
 select app_private.live_planboard_warnings_from_visits((input->>'eventId')::uuid,'[]',
 (select jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'groupId',proposal#>'{groups,0,groupId}','portalId',v->'portalId','kind',v->'kind','sequence',v->'sequence','startsAt',v->'startsAt','durationSeconds',v->'visitSeconds','bufferSeconds',v->'bufferSeconds','status','planned',
 'runStopId',(select stop.id from app_private.run_stops stop join app_private.group_runs run on run.id=stop.run_id where run.group_id=(proposal#>>'{groups,0,groupId}')::uuid and stop.portal_id=(v->>'portalId')::uuid order by stop.sequence desc limit 1)))from jsonb_array_elements(proposal#>'{groups,0,visits}')v))from v3_test
$$;
savepoint manual_completion;
select pg_temp.v3_finish('2026-10-31T18:29:59Z');
select ok(exists(select 1 from jsonb_array_elements(pg_temp.v3_manual_notices())notice where notice->>'code'='GROUP_COMPLETION_TOO_EARLY'and notice->>'severity'='block'),'manual planboard preview exposes the same hard early-completion constraint');
rollback to manual_completion;
savepoint invalid_config;
update v3_test set input=input-'routePolicySettingsVersion';
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from v3_test$$,'23514','INVALID_ROUTE_POLICY_CONFIG','missing v3 settings version cannot silently use old policy');
rollback to invalid_config;
select ok(not has_function_privilege('anon','api.admin_joint_route_policy_get(text)','execute'),'anonymous users cannot inspect private policy');
select ok(not has_function_privilege('authenticated','app_private.joint_runtime_policy_violation(uuid,text,integer,integer,timestamptz,integer)','execute'),'clients cannot bypass trusted runtime policy');
select is((api.admin_joint_route_policy_get('duindorp-halloween-2026')->>'version')::integer,1,'policy has separate initial counter');
select ok(jsonb_array_length(api.admin_joint_route_policy_get('duindorp-halloween-2026')->'portals')>0,'policy UI receives physical portal choices');
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,0,1800,'{}','Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'22023','INVALID_ROUTE_POLICY_CONFIG','walking budget must be positive');
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,3900,-1,'{}','Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'22023','INVALID_ROUTE_POLICY_CONFIG','early tolerance cannot be negative');
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,3900,86401,'{}','Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'22023','INVALID_ROUTE_POLICY_CONFIG','early tolerance is bounded');
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,3900,1800,array['12000000-0000-0000-0000-000000000030'::uuid],'Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'23514','INVALID_ORGANIZER_COVERAGE_PORTAL','finale cannot become ordinary coverage goal');
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,3900,1800,array['12000000-0000-0000-0000-000000000001'::uuid,'12000000-0000-0000-0000-000000000001'::uuid],'Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'22023','INVALID_ROUTE_POLICY_CONFIG','duplicate organizer goals are rejected');
savepoint runtime_policy;
create temp table v3_run(run_id uuid,accepted uuid);
with accepted as(insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,metrics,reason)
 select(input->>'eventId')::uuid,1,input->>'sourceHash',proposal->>'proposalHash',input->>'boardHash','joint-reception-v3',auth.uid(),proposal->'groups',jsonb_build_object('routePolicy',app_private.joint_route_policy_snapshot((input->>'eventId')::uuid)),'Synthetisch onveranderlijk runtimebeleid'from v3_test returning id),
 started as(insert into app_private.group_runs(group_id,schedule_revision_id,accepted_route_version_id,status,started_at)
 select(input#>>'{groups,0,id}')::uuid,(app_private.route_group_start_context((input#>>'{groups,0,id}')::uuid)->>'scheduleId')::uuid,accepted.id,'live','2026-10-31T16:00:00Z'from v3_test,accepted returning id,accepted_route_version_id)
 insert into v3_run select id,accepted_route_version_id from started;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3900,0,'2026-10-31T18:24:00Z',360),null::text,'runtime permits a long finale leg at exactly the real total budget')from v3_run;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3901,0,'2026-10-31T18:24:00Z',360),'ROUTE_TOTAL_WALKING_BUDGET','runtime counts the actual finale walk in total')from v3_run;
select is(app_private.joint_runtime_policy_violation(run_id,'ordinary',901,0,'2026-10-31T17:00:00Z',300),'ORDINARY_LEG_WALKING_LIMIT','runtime independently protects ordinary900-second limit')from v3_run;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',1200,0,'2026-10-31T18:23:59Z',360),'GROUP_COMPLETION_TOO_EARLY','runtime checks actual show end rather than arrival alone')from v3_run;
select pg_temp.v3_finish('2026-10-31T18:29:59Z');
select ok(exists(select 1 from jsonb_array_elements(pg_temp.v3_manual_notices())n where n->>'code'='GROUP_COMPLETION_TOO_EARLY'),'manual future edits of a begun v3 route also enforce its approved show-end limit');
update v3_test set proposal=baseline;
update app_private.event_route_settings set max_total_walking_seconds=1,max_early_finish_seconds=0 where event_id=(select(input->>'eventId')::uuid from v3_test);
select ok(not exists(select 1 from jsonb_array_elements(pg_temp.v3_manual_notices())n where n->>'code'in('GROUP_COMPLETION_TOO_EARLY','ROUTE_TOTAL_WALKING_BUDGET')),'begun v3 manual checks retain approved limits rather than newly changed event settings');
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3900,0,'2026-10-31T18:24:00Z',360),null::text,'a begun run retains its approved limits after policy settings change')from v3_run;
with reservation as(insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
 select(input->>'eventId')::uuid,(proposal#>>'{groups,0,visits,0,portalId}')::uuid,(input#>>'{groups,0,id}')::uuid,run_id,'ordinary','completed','2026-10-31T17:00:00Z','2026-10-31T17:07:00Z',1 from v3_test,v3_run returning id,run_id),
 stop as(insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,outcome,opened_at,completed_at)
 select reservation.run_id,(proposal#>>'{groups,0,visits,0,portalId}')::uuid,reservation.id,'ordinary',1,'completed','visited','2026-10-31T17:00:00Z','2026-10-31T17:05:00Z'from reservation,v3_test returning run_id)
 insert into app_private.dispatch_decisions(event_id,run_id,sequence,selected_portal_id,selected_kind,decision,input_snapshot,reason)
 select(input->>'eventId')::uuid,stop.run_id,1,(proposal#>>'{groups,0,visits,0,portalId}')::uuid,'ordinary','ordinary','{"walkSeconds":1000}'::jsonb,'Synthetic actual dispatched travel'from stop,v3_test;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',2900,0,'2026-10-31T18:24:00Z',360),null::text,'actual prior dispatch walking plus finale exactly3900 is allowed')from v3_run;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',2901,0,'2026-10-31T18:24:00Z',360),'ROUTE_TOTAL_WALKING_BUDGET','recorded prior walking is included in the runtime budget')from v3_run;
update app_private.dispatch_decisions set input_snapshot='{"walkSeconds":3900}'where run_id=(select run_id from v3_run);
select ok(exists(select 1 from jsonb_array_elements(pg_temp.v3_manual_notices())n where n->>'code'='ROUTE_TOTAL_WALKING_BUDGET'),'manual future edits include recorded actual walking of a begun v3 run');
with old as(insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,reason)
 select(input->>'eventId')::uuid,2,input->>'sourceHash',proposal->>'proposalHash',input->>'boardHash','joint-reception-v2',auth.uid(),proposal->'groups','Protected earlier accepted runtime policy'from v3_test returning id)
 update app_private.group_runs set accepted_route_version_id=old.id from old where group_runs.id=(select run_id from v3_run);
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3901,0,'2026-10-31T18:00:00Z',360),null::text,'an already begun earlier policy run does not inherit new v3 restrictions')from v3_run;
select ok(not exists(select 1 from jsonb_array_elements(pg_temp.v3_manual_notices())n where n->>'code'in('GROUP_COMPLETION_TOO_EARLY','ROUTE_TOTAL_WALKING_BUDGET')),'begun v2 manual edits retain their existing reviewed policy');
rollback to runtime_policy;

create temp table v3_preserved as select
 (select jsonb_agg(jsonb_build_array(s.id,app_private.is_start_confirmation_current(s.id))order by s.id)from app_private.group_schedule_revisions s)confirmed,
 app_private.start_publication_readiness((select id from app_private.events where slug='duindorp-halloween-2026'))readiness,
 (select jsonb_agg(to_jsonb(s)order by id)from app_private.group_schedule_revisions s)schedules,
 (select jsonb_agg(to_jsonb(p)order by id)from app_private.group_start_publications p)publications,
 (select coalesce(jsonb_agg(to_jsonb(m)order by id),'[]')from app_private.email_outbox m)mail;
update v3_test set saved=api.admin_joint_route_policy_save('duindorp-halloween-2026',1,4200,1200,array['12000000-0000-0000-0000-000000000002'::uuid,'12000000-0000-0000-0000-000000000001'::uuid],'Expliciete synthetische beleidskeuze zonder routewijziging',key);
select is((select(saved->>'version')::integer from v3_test),2,'changed policy increments only policy counter');
select is((select saved->'organizerCoveragePortalIds'from v3_test),'["12000000-0000-0000-0000-000000000002","12000000-0000-0000-0000-000000000001"]'::jsonb,'physical organizer goals retain explicit priority order');
select isnt((select saved->>'sourceHash'from v3_test),(select input->>'sourceHash'from v3_test),'policy changes invalidate existing source hashes');
select is((select to_jsonb(s)-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version']from app_private.event_route_settings s where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),
 (select settings-array['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version']from v3_test),'all previous settings fields including start version and timestamp remain unchanged');
select is(api.admin_joint_route_policy_save('duindorp-halloween-2026',1,4200,1200,array['12000000-0000-0000-0000-000000000002'::uuid,'12000000-0000-0000-0000-000000000001'::uuid],'Expliciete synthetische beleidskeuze zonder routewijziging',key),saved,'idempotent retry returns original receipt after version changed')from v3_test;
select throws_ok($$select api.admin_joint_route_policy_save('duindorp-halloween-2026',1,3900,1800,'{}','Synthetisch geldig beleidsmotief',gen_random_uuid()::text)$$,'40001','STALE_VERSION','stale edit cannot overwrite policy');
select is((select jsonb_agg(to_jsonb(s)order by id)from app_private.group_schedule_revisions s),(select schedules from v3_preserved),'policy save never changes agreed starts or finale reservations');
select is((select jsonb_agg(to_jsonb(p)order by id)from app_private.group_start_publications p),(select publications from v3_preserved),'policy save does not republish confirmed starts');
select is((select coalesce(jsonb_agg(to_jsonb(m)order by id),'[]')from app_private.email_outbox m),(select mail from v3_preserved),'policy save queues no participant mail');
select is((select count(*)::integer from app_private.joint_route_plan_versions),0,'policy save does not apply any route');
select is((select jsonb_agg(jsonb_build_array(s.id,app_private.is_start_confirmation_current(s.id))order by s.id)from app_private.group_schedule_revisions s),(select confirmed from v3_preserved),'policy save preserves existing current start confirmations');
select is(app_private.start_publication_readiness((select id from app_private.events where slug='duindorp-halloween-2026')),(select readiness from v3_preserved),'start publication readiness and its source versions remain current after a route policy edit');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een verouderd voorstel mag geen geldige route wijzigen',gen_random_uuid()::text)from v3_test$$,'40001','JOINT_ROUTE_PROPOSAL_STALE','old proposals are stale after changing policy');
select *from finish();
rollback;
