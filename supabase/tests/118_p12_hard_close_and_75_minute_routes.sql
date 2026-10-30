begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
select pg_temp.joint_canonical_fixture();
-- Reproduce the previous organization policy using synthetic seed data only.
update app_private.event_route_settings set max_total_walking_seconds=3900,route_policy_version=1,
 finale_last_arrival_at='2026-10-31T19:30:00Z'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update app_private.portals set ordinary_hard_close=false,ordinary_end_grace_seconds=300 where system_code='P-12';
update app_private.portal_windows set closes_at='2026-10-31T18:10:00Z',visit_minutes=5,buffer_minutes=2
 where portal_id=(select id from app_private.portals where system_code='P-12');
create function pg_temp.p12_preserved()returns jsonb language sql as $$
 select jsonb_build_object(
 'starts',(select jsonb_agg(to_jsonb(p)order by id)from app_private.group_start_publications p),
 'schedules',(select jsonb_agg(to_jsonb(p)order by id)from app_private.group_schedule_revisions p),
 'history',(select coalesce(jsonb_agg(to_jsonb(p)order by to_jsonb(p)::text),'[]')from app_private.run_stop_arrivals p),
 'participants',(select coalesce(jsonb_agg(to_jsonb(p)order by id),'[]')from app_private.run_participants p),
 'mail',(select coalesce(jsonb_agg(to_jsonb(p)order by id),'[]')from app_private.email_outbox p),
 'versions',(select coalesce(jsonb_agg(to_jsonb(p)order by id),'[]')from app_private.joint_route_plan_versions p),
 'ledger',(select jsonb_agg(to_jsonb(p)order by policy_version)from app_private.joint_route_policy_releases p),
 'otherPortals',(select jsonb_agg(to_jsonb(p)order by id)from app_private.portals p where system_code<>'P-12'),
 'otherWindows',(select jsonb_agg(to_jsonb(w)order by id)from app_private.portal_windows w where portal_id not in(select id from app_private.portals where system_code='P-12')));
$$;
create temp table p12_test(input jsonb,proposal jsonb,old_input jsonb,checkpoint jsonb,portal jsonb,settings jsonb,functions jsonb,accepted uuid,run_id uuid);
insert into p12_test(old_input,proposal,portal,settings,functions)
 select api.admin_joint_route_planning_input('duindorp-halloween-2026'),pg_temp.joint_proposal(),
 (select to_jsonb(p)from app_private.portals p where system_code='P-12'),
 (select to_jsonb(s)from app_private.event_route_settings s where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),
 (select jsonb_agg(jsonb_build_array(p.oid::regprocedure::text,p.proowner,p.proacl)order by p.oid)
  from pg_proc p where p.oid in('app_private.apply_portal_planning_policy(uuid,jsonb)'::regprocedure,'app_private.validate_route_plan_stop()'::regprocedure,
   'app_private.dispatch_next_stop_before_joint_routes(uuid,timestamptz,boolean,uuid)'::regprocedure));
-- Preserve an already begun v3 route and its immutable older walking budget.
with accepted as(insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,metrics,reason)
 select(old_input->>'eventId')::uuid,1,old_input->>'sourceHash',proposal->>'proposalHash',old_input->>'boardHash','joint-reception-v3',auth.uid(),proposal->'groups',
 jsonb_build_object('routePolicy',app_private.joint_route_policy_snapshot((old_input->>'eventId')::uuid)),'Synthetisch eerder goedgekeurd beleid behouden'from p12_test returning id)
 update p12_test set accepted=accepted.id from accepted;
with started as(insert into app_private.group_runs(group_id,schedule_revision_id,accepted_route_version_id,status,started_at)
 select(old_input#>>'{groups,3,id}')::uuid,(app_private.route_group_start_context((old_input#>>'{groups,3,id}')::uuid)->>'scheduleId')::uuid,accepted,'live','2026-10-31T16:30:00Z'from p12_test returning id)
 update p12_test set run_id=started.id from started;
update p12_test set checkpoint=pg_temp.p12_preserved();
\ir ../migrations/20261030182243_p12_hard_close_and_75_minute_routes.sql
update p12_test set input=api.admin_joint_route_planning_input('duindorp-halloween-2026');
select is(pg_temp.p12_preserved(),checkpoint,'migration preserves starts, schedules, history, participants, accepted routes, mail, ledger and other houses')from p12_test;
select is(input->>'policyVersion','joint-reception-v3','hard policy contract remains v3')from p12_test;
select is((input->>'maxTotalWalkingSeconds')::integer,4500,'new plans receive75 minutes of actual walking including P38')from p12_test;
select is((input->>'routePolicySettingsVersion')::integer,2,'only the route-policy settings counter advances')from p12_test;
select isnt(input->>'sourceHash',old_input->>'sourceHash','real settings and P12 changes invalidate old cached proposals')from p12_test;
select is((select to_jsonb(s)-array['max_total_walking_seconds','route_policy_version']from app_private.event_route_settings s where event_id=(input->>'eventId')::uuid),settings-array['max_total_walking_seconds','route_policy_version'],'confirmed-start version, updated_at and every unrelated settings field are preserved')from p12_test;
select is((select to_jsonb(p)-array['ordinary_hard_close','ordinary_end_grace_seconds','version','updated_at']from app_private.portals p where p.id=(portal->>'id')::uuid),portal-array['ordinary_hard_close','ordinary_end_grace_seconds','version','updated_at'],'every unrelated P12 portal field is preserved')from p12_test;
select is((select version from app_private.portals where system_code='P-12'),(portal->>'version')::integer+1,'P12 editor version advances once')from p12_test;
select is((select closes_at from app_private.portal_windows where portal_id=(portal->>'id')::uuid),'2026-10-31T18:00:00Z'::timestamptz,'stored P12 close is exactly19:00 Amsterdam')from p12_test;
select ok((select ordinary_hard_close and ordinary_end_grace_seconds=0 from app_private.portals where system_code='P-12'),'P12 has explicit zero-grace physical closing');
select is((select closes_at from app_private.portal_effective_windows((portal->>'id')::uuid)limit 1),'2026-10-31T18:00:00Z'::timestamptz,'effective close cannot retain19:10 or old grace')from p12_test;
select is((select(p->'windows'->0->>'closesAt')::timestamptz from jsonb_array_elements(input->'portals')p where p->>'code'='P-12'),'2026-10-31T18:00:00Z'::timestamptz,'joint RPC exports the same actual hard end')from p12_test;
select is(functions,(select jsonb_agg(jsonb_build_array(p.oid::regprocedure::text,p.proowner,p.proacl)order by p.oid)
 from pg_proc p where p.oid in('app_private.apply_portal_planning_policy(uuid,jsonb)'::regprocedure,'app_private.validate_route_plan_stop()'::regprocedure,
 'app_private.dispatch_next_stop_before_joint_routes(uuid,timestamptz,boolean,uuid)'::regprocedure)),'function owners and ACLs remain exact')from p12_test;
select is(app_private.joint_runtime_policy_violation(run_id,'finale',3901,0,'2026-10-31T18:24:00Z',360),'ROUTE_TOTAL_WALKING_BUDGET','begun v3 route keeps its earlier65-minute approval')from p12_test;
select is((select(metrics#>>'{routePolicy,maxTotalWalkingSeconds}')::integer from app_private.joint_route_plan_versions v where v.id=t.accepted),3900,'migration never rewrites an accepted policy snapshot')from p12_test t;
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Synthetisch oud voorstel mag niet worden toegepast',gen_random_uuid()::text)from p12_test$$,'40001','JOINT_ROUTE_PROPOSAL_STALE','old cached proposals cannot apply under the new real policy');
create function pg_temp.p12_available(_from timestamptz,_until timestamptz)returns boolean language sql as $$
 select app_private.portal_interval_available_from_occupancy((select id from app_private.portals where system_code='P-12'),'23000000-0000-0000-0000-000000000001',_from,_until,3,'[]')
$$;
select ok(pg_temp.p12_available('2026-10-31T17:53:00Z','2026-10-31T18:00:00Z'),'18:53 plus5-minute visit and2-minute buffer finishes exactly19:00');
select ok(not pg_temp.p12_available('2026-10-31T17:53:01Z','2026-10-31T18:00:01Z'),'18:53:01 cannot use one second of grace');
select ok(not pg_temp.p12_available('2026-10-31T17:54:00Z','2026-10-31T17:59:00Z'),'a five-minute visit cannot omit its actual buffer');
select app_private.apply_portal_planning_policy((select id from app_private.portals where system_code='P-12'),'{"ordinaryHardClose":true,"ordinaryEndGraceSeconds":300}');
select is((select ordinary_end_grace_seconds from app_private.portals where system_code='P-12'),0,'raw server saves cannot restore grace while hard closing is enabled');
savepoint six_minute_service;
update app_private.portal_windows set visit_minutes=6 where portal_id=(select id from app_private.portals where system_code='P-12');
select ok(pg_temp.p12_available('2026-10-31T17:52:00Z','2026-10-31T18:00:00Z'),'a real six-minute visit moves last arrival to18:52 with its two-minute buffer');
select ok(not pg_temp.p12_available('2026-10-31T17:53:00Z','2026-10-31T18:01:00Z'),'the boundary uses actual service rather than assuming every visit takes five minutes');
rollback to six_minute_service;
-- Actual server-owned travel and durations; one group isolates the boundary.
create function pg_temp.p12_route(_arrival timestamptz,_total integer default null)returns void language plpgsql as $$
declare t p12_test;g jsonb;p jsonb;f jsonb;incoming jsonb;outgoing jsonb;final_at timestamptz:='2026-10-31T19:20:00Z';visits jsonb;win jsonb;final_win jsonb;
begin
 select *into t from p12_test;g:=t.input->'groups'->0;
 select *into p from jsonb_array_elements(t.input->'portals')q where q->>'code'='P-12';win:=p->'windows'->0;
 select *into f from jsonb_array_elements(t.input->'portals')q where q->>'id'=g#>>'{finale,portalId}';final_win:=f->'windows'->0;
 select *into incoming from jsonb_array_elements(t.input->'legs')l where l->>'from'=g->>'startNodeId'and l->>'to'=p->>'nodeId';
 select *into outgoing from jsonb_array_elements(t.input->'legs')l where l->>'from'=p->>'nodeId'and l->>'to'=f->>'nodeId';
 if _total is not null then outgoing:=outgoing||jsonb_build_object('seconds',_total-(incoming->>'seconds')::integer);end if;
 visits:=jsonb_build_array(jsonb_build_object('portalId',p->'id','kind','ordinary','sequence',1,'startsAt',_arrival,'visitSeconds',win->'visitSeconds','bufferSeconds',win->'bufferSeconds','walkSeconds',incoming->'seconds','walkMeters',incoming->'meters'),
 jsonb_build_object('portalId',f->'id','kind','finale','sequence',2,'startsAt',final_at,'visitSeconds',final_win->'visitSeconds','bufferSeconds',final_win->'bufferSeconds','walkSeconds',outgoing->'seconds','walkMeters',outgoing->'meters'));
 update p12_test set input=jsonb_set(jsonb_set(input,'{groups}',jsonb_build_array(g)),'{legs}',(select jsonb_agg(case when l->>'from'=outgoing->>'from'and l->>'to'=outgoing->>'to'then outgoing else l end)from jsonb_array_elements(input->'legs')l)),
 proposal=jsonb_build_object('groups',jsonb_build_array(jsonb_build_object('groupId',g->'id','startsAt',g->'startsAt','finaleArrivalAt',final_at,'expectedCompletionAt',final_at+make_interval(secs=>(final_win->>'visitSeconds')::integer),
 'finaleChange',jsonb_build_object('portalId',f->'id','previousReservedAt',g#>'{finale,reservedAt}','proposedReservedAt',final_at),'visits',visits,'diagnostics','[]'::jsonb)));
end $$;
select pg_temp.p12_route('2026-10-31T17:53:00Z');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from p12_test$$,'joint validator accepts exact19:00 physical finish');
create function pg_temp.p12_notices()returns jsonb language sql as $$
 select app_private.live_planboard_warnings_from_visits((input->>'eventId')::uuid,'[]',
 (select jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'groupId',proposal#>'{groups,0,groupId}','portalId',v->'portalId','kind',v->'kind',
 'sequence',v->'sequence','startsAt',v->'startsAt','durationSeconds',v->'visitSeconds','bufferSeconds',v->'bufferSeconds','status','planned'))
 from jsonb_array_elements(proposal#>'{groups,0,visits}')v))from p12_test
$$;
select ok(not exists(select 1 from jsonb_array_elements(pg_temp.p12_notices())n where n->>'code'='OPENING_WINDOW'and n->>'severity'='block'),'manual planboard preview accepts the same exact19:00 physical finish');
select pg_temp.p12_route('2026-10-31T17:53:01Z');
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from p12_test$$,'23514','PORTAL_EFFECTIVE_WINDOW_CONFLICT','joint validator rejects one second beyond hard close');
select ok(exists(select 1 from jsonb_array_elements(pg_temp.p12_notices())n where n->>'code'='OPENING_WINDOW'and n->>'severity'='block'),'manual planboard preview blocks the same one-second overflow');
select pg_temp.p12_route('2026-10-31T17:53:00Z',4500);
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from p12_test$$,'exact4500 including a genuinely long final P38 leg is valid');
select pg_temp.p12_route('2026-10-31T17:53:00Z',4501);
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups')from p12_test$$,'23514','ROUTE_TOTAL_WALKING_BUDGET','4501 seconds fails the actual total walking budget');
create temp table p12_legacy(id uuid);
insert into p12_legacy select gen_random_uuid();
insert into app_private.route_plan_versions(id,group_id,revision,input_hash)
 select id,'23000000-0000-0000-0000-000000000002',100,'synthetic-p12-hardclose'from p12_legacy;
select lives_ok($$insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select id,1,(select id from app_private.portals where system_code='P-12'),'2026-10-31T17:53:00Z','2026-10-31T17:58:00Z'from p12_legacy$$,'legacy stored plan accepts exact service plus buffer finish');
delete from app_private.route_plan_stops where plan_version_id=(select id from p12_legacy);
select throws_ok($$insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select id,1,(select id from app_private.portals where system_code='P-12'),'2026-10-31T17:53:01Z','2026-10-31T17:58:01Z'from p12_legacy$$,'23514','PORTAL_WINDOW_CONFLICT','legacy storage cannot omit the final buffer second');
insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select id,1,(select id from app_private.portals where system_code='P-12'),'2026-10-31T17:53:00Z','2026-10-31T17:58:00Z'from p12_legacy;
update app_private.portals set world_id=(select world_id from app_private.portals where system_code='P-12')
 where id='12000000-0000-0000-0000-000000000002';
select lives_ok($$insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select id,2,'12000000-0000-0000-0000-000000000002','2026-10-31T18:10:00Z','2026-10-31T18:15:00Z'from p12_legacy$$,'two different physical houses with the same world remain eligible in legacy route storage');
select throws_ok($$insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select id,3,(select id from app_private.portals where system_code='P-12'),'2026-10-31T17:50:00Z','2026-10-31T17:55:00Z'from p12_legacy$$,'23514','DUPLICATE_PHYSICAL_VISIT','the same physical house remains forbidden regardless of its world label');
select *from finish();
rollback;
