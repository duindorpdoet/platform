begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
select pg_temp.joint_canonical_fixture();
create function pg_temp.objective_preserved()returns jsonb language sql as $$
 select jsonb_build_object(
 'settings',(select jsonb_agg(to_jsonb(s)order by event_id)from app_private.event_route_settings s),
 'schedules',(select jsonb_agg(to_jsonb(s)order by id)from app_private.group_schedule_revisions s),
 'publications',(select jsonb_agg(to_jsonb(p)order by id)from app_private.group_start_publications p),
 'participants',(select coalesce(jsonb_agg(to_jsonb(p)order by id),'[]')from app_private.run_participants p),
 'arrivals',(select coalesce(jsonb_agg(to_jsonb(a)order by to_jsonb(a)::text),'[]')from app_private.run_stop_arrivals a),
 'mail',(select coalesce(jsonb_agg(to_jsonb(m)order by id),'[]')from app_private.email_outbox m),
 'policyReleases',(select jsonb_agg(to_jsonb(p)order by policy_version)from app_private.joint_route_policy_releases p));
$$;
create temp table objective_test(input jsonb,proposal jsonb,old_proposal jsonb,checkpoint jsonb,result jsonb,old_hash text,accepted uuid,run_id uuid);
insert into objective_test(input,proposal,checkpoint,old_hash)
 select api.admin_joint_route_planning_input('duindorp-halloween-2026'),pg_temp.joint_proposal(),pg_temp.objective_preserved(),
 encode(extensions.digest(jsonb_build_object('policyVersion',3,'source',app_private.joint_route_source_hash_before_v3(e.id))::text,'sha256'),'hex')
 from app_private.events e where e.slug='duindorp-halloween-2026';
update objective_test set old_proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{sourceHash}',to_jsonb(old_hash)));
select isnt(input->>'sourceHash',old_hash,'the old v3 source hash is stale solely because the route objective changed')from objective_test;
select is(input->>'sourceHash',encode(extensions.digest(jsonb_build_object('policyVersion',3,'routeObjective','all-active-coverage-v1','source',app_private.joint_route_source_hash_before_v3((input->>'eventId')::uuid))::text,'sha256'),'hex'),'objective salt preserves the same authoritative v3 source provenance')from objective_test;
select is(input->>'policyVersion','joint-reception-v3','objective revision keeps the exact existing hard policy version')from objective_test;
select is((input->>'maxTotalWalkingSeconds')::integer,3900,'actual65-minute walking budget remains unchanged')from objective_test;
select ok(not has_function_privilege('anon','app_private.joint_route_source_hash(uuid)','execute'),'anonymous users gain no private source-hash access');
select ok(not has_function_privilege('authenticated','app_private.joint_route_source_hash(uuid)','execute'),'authenticated browsers still cannot manufacture trusted hashes');
select lives_ok($$select app_private.validate_joint_route_proposal(input,old_proposal->'groups')from objective_test$$,'unchanged old route geometry still passes hard constraints; source freshness is a separate gate');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',old_proposal,true,'Synthetisch oud voorstel mag na doelwijziging niet worden toegepast',gen_random_uuid()::text)from objective_test$$,'40001','JOINT_ROUTE_PROPOSAL_STALE','a stale client cannot apply an old v3 proposal after the objective deployment');
select is(pg_temp.objective_preserved(),checkpoint,'rejecting an old objective hash preserves settings, all stored appointments, history, participants, policy releases and mail')from objective_test;
select is((select count(*)::integer from app_private.joint_route_plan_versions),0,'rejecting stale input accepts no route version');
select lives_ok($$update objective_test set result=api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Synthetisch vers berekend voorstel expliciet beoordelen',gen_random_uuid()::text)$$,'a fresh source hash accepts the same independently validated hard-feasible route');
select is(pg_temp.objective_preserved(),checkpoint,'fresh acceptance without a finale change preserves every stored start/finale appointment and sends no mail')from objective_test;
select is((select policy_version from app_private.joint_route_plan_versions),'joint-reception-v3','newly accepted versions retain the existing hard policy');
select is((select(metrics#>>'{routePolicy,maxTotalWalkingSeconds}')::integer from app_private.joint_route_plan_versions),3900,'accepted runs keep a trusted immutable walking-policy snapshot');
-- Model a run already bound to v3 before the deployment. Only its source hash
-- is old; its immutable route and approved hard-policy snapshot stay usable.
with accepted as(insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,metrics,reason)
 select(input->>'eventId')::uuid,2,old_hash,old_proposal->>'proposalHash',input->>'boardHash','joint-reception-v3',auth.uid(),proposal->'groups',
 jsonb_build_object('routePolicy',app_private.joint_route_policy_snapshot((input->>'eventId')::uuid)),'Synthetisch eerder beoordeeld v3 beleid met oude bronhash'from objective_test returning id),
 started as(insert into app_private.group_runs(group_id,schedule_revision_id,accepted_route_version_id,status,started_at)
 select(input#>>'{groups,0,id}')::uuid,(app_private.route_group_start_context((input#>>'{groups,0,id}')::uuid)->>'scheduleId')::uuid,accepted.id,'live','2026-10-31T16:00:00Z'from objective_test,accepted returning id,accepted_route_version_id)
 update objective_test set run_id=started.id,accepted=started.accepted_route_version_id from started;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3900,0,'2026-10-31T18:24:00Z',360),null::text,'a begun v3 run keeps its approved65-minute snapshot despite the newly salted source hash')from objective_test;
select is((select source_hash from app_private.joint_route_plan_versions where id=t.accepted),t.old_hash,'objective deployment never rewrites immutable acceptance evidence')from objective_test t;
select *from finish();
rollback;
