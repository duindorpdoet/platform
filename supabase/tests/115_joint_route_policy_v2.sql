begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
create temp table route_policy_test(input jsonb,proposal jsonb,result jsonb,checkpoint jsonb,key text default gen_random_uuid()::text);
select pg_temp.joint_canonical_fixture();
insert into route_policy_test(input,proposal) select api.admin_joint_route_planning_input('duindorp-halloween-2026'),pg_temp.joint_proposal();

-- These are server-owned fixture travel matrices. Direct API tests below also
-- ensure a browser cannot replace the freshly loaded authoritative durations.
create function pg_temp.policy_walk(_seconds integer,_ordinary boolean default false,_late boolean default false) returns void language plpgsql as $$
declare data route_policy_test;plans jsonb:='[]';plan jsonb;visits jsonb;target jsonb;leg jsonb;arrival timestamptz;
begin
 select * into data from route_policy_test;
 target:=data.proposal->'groups'->0->'visits'->case when _ordinary then 0 else 1 end;
 select * into leg from jsonb_array_elements(data.input->'legs') l
 where l->>'to'='portal:'||(target->>'portalId')
  and l->>'from'=case when _ordinary then 'start:'||(data.proposal->'groups'->0->>'groupId') else 'portal:'||(data.proposal->'groups'->0->'visits'->0->>'portalId') end;
 update route_policy_test set input=jsonb_set(input,'{legs}',(select jsonb_agg(case when l=leg then l||jsonb_build_object('seconds',_seconds) else l end) from jsonb_array_elements(input->'legs') l));
 for plan in select * from jsonb_array_elements(data.proposal->'groups') loop
  visits:=(select jsonb_agg(case when (v->>'kind'='ordinary')=_ordinary and (not _ordinary or plan->>'groupId'=data.proposal->'groups'->0->>'groupId') then v||jsonb_build_object('walkSeconds',_seconds) else v end order by (v->>'sequence')::integer) from jsonb_array_elements(plan->'visits')v);
  if _late then
   arrival:=(plan->'visits'->1->>'startsAt')::timestamptz-interval '5 minutes'-make_interval(secs=>(plan->'visits'->0->>'visitSeconds')::integer);
   visits:=jsonb_set(visits,'{0,startsAt}',to_jsonb(arrival));
  end if;
  plans:=plans||jsonb_build_array(plan||jsonb_build_object('visits',visits));
 end loop;
 update route_policy_test set proposal=pg_temp.joint_rehash(proposal||jsonb_build_object('groups',plans));
end $$;
create function pg_temp.policy_finale_change(_at timestamptz,_mark boolean default true) returns void language plpgsql as $$
declare proposed jsonb;plan jsonb;original timestamptz;
begin
 select t.proposal into proposed from route_policy_test t;plan:=proposed->'groups'->0;
 original:=(plan->>'finaleArrivalAt')::timestamptz;
 plan:=jsonb_set(plan,'{visits,1,startsAt}',to_jsonb(_at))||jsonb_build_object('finaleArrivalAt',_at,
  'expectedCompletionAt',_at+make_interval(secs=>(plan->'visits'->1->>'visitSeconds')::integer));
 if _mark then plan:=plan||jsonb_build_object('finaleChange',jsonb_build_object('portalId',plan->'visits'->1->'portalId','previousReservedAt',original,'proposedReservedAt',_at));end if;
 update route_policy_test t set proposal=pg_temp.joint_rehash(jsonb_set(proposed,'{groups,0}',plan));
end $$;

select is((select input->>'policyVersion' from route_policy_test),'joint-reception-v2','server projects the explicit 30 October route policy');
select is((select input->'needsAnders' from route_policy_test),'false'::jsonb,'world coverage does not request an Anders visit');
select ok(not has_table_privilege('authenticated','app_private.joint_route_finale_approvals','insert'),'a browser cannot manufacture finale approval evidence');
select ok(not has_function_privilege('authenticated','app_private.validate_joint_route_proposal(jsonb,jsonb)','execute'),'browser cannot supply trusted validator inputs');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'ordinary baseline and physical P-38 finale remain valid');

savepoint sole_physical_finale;
-- Give the synthetic fixture the real event's identity, without changing any
-- live setting or using a production identifier. Only this fixture bypasses
-- immutable identity triggers, and the savepoint restores it immediately.
set local session_replication_role=replica;
update app_private.portals set system_code='P-38',system_number=38 where id='12000000-0000-0000-0000-000000000030';
set local session_replication_role=origin;
select throws_ok($$update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000002' where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')$$,'23514','P38_ONLY_FINAL_PORTAL','the configured physical finale cannot move away from P-38');
select is((select final_portal_id from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),'12000000-0000-0000-0000-000000000030'::uuid,'rejected location replacement preserves the real P-38 finale');
rollback to sole_physical_finale;

savepoint longer_finale;
select pg_temp.policy_walk(925);
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'a real last walk of 925 seconds passes server policy without an intermediate house');
rollback to longer_finale;
savepoint longer_finale;
select pg_temp.policy_walk(1114);
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'a real last walk of 1114 seconds is also allowed');
rollback to longer_finale;
savepoint longer_finale;
select pg_temp.policy_walk(1200);
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'there is no replacement 20-minute maximum to P-38');
rollback to longer_finale;
savepoint long_ordinary;
select pg_temp.policy_walk(925,true);
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'23514','ORDINARY_LEG_WALKING_LIMIT','the separate ordinary leg limit remains independently enforced');
rollback to long_ordinary;
savepoint total_budget;
select pg_temp.policy_walk(1200);
update route_policy_test set input=jsonb_set(input,'{maxTotalWalkingSeconds}','1199');
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'23514','ROUTE_TOTAL_WALKING_BUDGET','the total walking budget is explicit and separate from the removed finale leg limit');
rollback to total_budget;
savepoint insufficient_time;
select pg_temp.policy_walk(1200,false,true);
update route_policy_test set input=jsonb_set(input,'{groups}',(select jsonb_agg(g||jsonb_build_object('ordinaryStopAt','2026-10-31T20:00:00Z')) from jsonb_array_elements(input->'groups')g));
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'23514','ROUTE_TRAVEL_TIME_INVALID','twenty minutes of actual travel cannot fit five minutes before the booked finale');
rollback to insufficient_time;
savepoint forged_duration;
update route_policy_test set proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{groups,0,visits,1,walkSeconds}','0'));
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een gefingeerde korte finale-wandeling weigeren',key) from route_policy_test$$,'23514','ROUTE_TRAVEL_TIME_INVALID','direct apply reloads real travel and refuses a fabricated zero-minute walk');
rollback to forged_duration;

savepoint historical_caps;
update app_private.walking_groups set desired_ordinary_visits=1 where id='23000000-0000-0000-0000-000000000001';
update route_policy_test set input=api.admin_joint_route_planning_input('duindorp-halloween-2026');
select ok((select bool_and(g->'maxOrdinaryVisits'='null'::jsonb) from route_policy_test,jsonb_array_elements(input->'groups')g),'historic desired visit caps do not become joint route limits');
update route_policy_test set input=jsonb_set(input,'{groups,0,maxOrdinaryVisits}','0');
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'a historical zero input cap cannot reject a genuine feasible visit');
rollback to historical_caps;
savepoint historical_route_mode;
update app_private.walking_groups set route_mode='legacy' where id='23000000-0000-0000-0000-000000000001';
select is((select route_mode from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'legacy','reading a proposal does not change a historical route mode');
select lives_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Historische route-mode pas na expliciete gezamenlijke beoordeling vervangen',key) from route_policy_test$$,'an explicitly accepted joint calendar also owns a previously legacy route');
select is((select route_mode from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'dynamic','run_start and the worker will use the newly approved joint calendar');
rollback to historical_route_mode;
savepoint world_label;
update route_policy_test set checkpoint=jsonb_build_object('sourceHash',app_private.joint_route_source_hash((input->>'eventId')::uuid));
update app_private.portals set world_id=(select w.id from app_private.worlds w where w.event_id=portals.event_id and w.id<>portals.world_id order by w.id limit 1) where id='12000000-0000-0000-0000-000000000001';
select is(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','changing only a theme label does not invalidate route policy') from route_policy_test;
select lives_ok($$select app_private.validate_joint_route_proposal(api.admin_joint_route_planning_input('duindorp-halloween-2026'),proposal->'groups') from route_policy_test$$,'a different world label cannot exclude an otherwise suitable physical visit');
rollback to world_label;

savepoint first_house;
-- The physical linked house would fit first, even if a client claims otherwise.
update route_policy_test set input=jsonb_set(input,'{groups,0,fixedFirstPortalId}','"12000000-0000-0000-0000-000000000002"');
update route_policy_test set proposal=jsonb_set(proposal,'{groups,0,diagnostics}','[{"code":"FIRST_PORTAL_ALTERNATIVE","severity":"warning","message":"Een clientvoorkeur mag geen veiligheidsbewijs zijn"}]');
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'23514','FEASIBLE_FIRST_PORTAL_MUST_BE_PRESERVED','a client diagnostic cannot override an independently feasible linked first house');
-- Reordering the JSON array cannot pretend that sequence two is first.
do $$
declare data route_policy_test;plan jsonb;second jsonb;portal jsonb;leg jsonb;exit_leg jsonb;
begin
 select * into data from route_policy_test;plan:=data.proposal->'groups'->0;
 select * into portal from jsonb_array_elements(data.input->'portals') p where p->>'id'='12000000-0000-0000-0000-000000000002';
 select * into leg from jsonb_array_elements(data.input->'legs') l where l->>'from'='portal:12000000-0000-0000-0000-000000000001' and l->>'to'=portal->>'nodeId';
 select * into exit_leg from jsonb_array_elements(data.input->'legs') l where l->>'from'=portal->>'nodeId' and l->>'to'='portal:'||(plan->'visits'->1->>'portalId');
 second:=jsonb_build_object('portalId',portal->'id','sequence',2,'kind','ordinary','startsAt','2026-10-31T17:15:00Z','visitSeconds',portal#>'{windows,0,visitSeconds}','bufferSeconds',portal#>'{windows,0,bufferSeconds}','walkSeconds',leg->'seconds','walkMeters',leg->'meters');
 plan:=jsonb_set(plan,'{visits}',jsonb_build_array(second,plan->'visits'->0,(plan->'visits'->1)||jsonb_build_object('sequence',3,'walkSeconds',exit_leg->'seconds','walkMeters',exit_leg->'meters')));
 update route_policy_test set proposal=pg_temp.joint_rehash(jsonb_set(data.proposal,'{groups,0}',plan));
end $$;
select throws_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from route_policy_test$$,'23514','FEASIBLE_FIRST_PORTAL_MUST_BE_PRESERVED','the first physical visit is sequence one even when the JSON array is permuted');
rollback to first_house;

savepoint unreviewed_finale;
select pg_temp.policy_finale_change('2026-10-31T17:30:00Z',false);
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Zonder expliciete afspraakwijziging geen ander finaletijdslot',key) from route_policy_test$$,'23514','FINALE_APPOINTMENT_REVIEW_REQUIRED','a changed P-38 time must carry the exact before/after appointment for review');
rollback to unreviewed_finale;
savepoint reviewed_capacity_conflict;
select pg_temp.policy_finale_change((select (proposal->'groups'->1->>'finaleArrivalAt')::timestamptz from route_policy_test));
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Ook een expliciet voorgesteld tijdslot moet ontvangstafstand respecteren',key) from route_policy_test$$,'23514','JOINT_ROUTE_ARRIVAL_OR_CAPACITY_CONFLICT','review flags cannot override actual finale reception headway');
select is((select count(*)::integer from app_private.joint_route_finale_approvals),0,'failed calendar validation creates no approval or schedule change');
rollback to reviewed_capacity_conflict;

-- This earlier finale is before the historical ordinary-cutoff plus a generic
-- planning-transfer allowance, but the complete actual route reaches it safely.
select pg_temp.policy_finale_change('2026-10-31T17:30:00Z');
update route_policy_test set checkpoint=jsonb_build_object(
 'publications',(select jsonb_agg(to_jsonb(p) order by p.id) from app_private.group_start_publications p),
 'outbox',(select jsonb_agg(to_jsonb(o) order by o.id) from app_private.email_outbox o),
 'starts',(select jsonb_agg(jsonb_build_array(g.id,s.start_slot_id,s.state,s.effective_ordinary_stop_at,slot.starts_at,slot.start_point_id) order by g.id) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=(app_private.route_group_start_context(g.id)->>'scheduleId')::uuid join app_private.start_slots slot on slot.id=s.start_slot_id));
select lives_ok($$update route_policy_test set result=api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een gezamenlijk beter P-38 tijdslot expliciet beoordelen',key)$$,'an approved real finale change atomically stores the schedule and physical calendar');
select is((select expected_finale_arrival_at from app_private.group_schedule_revisions where id=(app_private.route_group_start_context('23000000-0000-0000-0000-000000000001')->>'scheduleId')::uuid),'2026-10-31T17:30:00Z'::timestamptz,'the reserved schedule now has precisely the approved P-38 time');
select is((select starts_at from app_private.live_route_visits where group_id='23000000-0000-0000-0000-000000000001' and kind='finale' and retired_at is null),'2026-10-31T17:30:00Z'::timestamptz,'the planboard and approved reservation have the same finale arrival');
select is((select count(*)::integer from app_private.joint_route_finale_approvals),1,'one immutable server approval records the exact changed appointment');
select ok((select bool_and(app_private.canonical_route_group_current((g->>'groupId')::uuid)) from route_policy_test,jsonb_array_elements(proposal->'groups')g),'new semantic hashes keep every accepted route current immediately after the atomic change');
select is((select jsonb_agg(to_jsonb(p) order by p.id) from app_private.group_start_publications p),(select checkpoint->'publications' from route_policy_test),'finale approval never republishes or edits confirmed start publications');
select is((select coalesce(jsonb_agg(to_jsonb(o) order by o.id),'null'::jsonb) from app_private.email_outbox o),(select checkpoint->'outbox' from route_policy_test),'finale approval never sends or queues participant mail');
select is((select jsonb_agg(jsonb_build_array(g.id,s.start_slot_id,s.state,s.effective_ordinary_stop_at,slot.starts_at,slot.start_point_id) order by g.id) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=(app_private.route_group_start_context(g.id)->>'scheduleId')::uuid join app_private.start_slots slot on slot.id=s.start_slot_id),(select checkpoint->'starts' from route_policy_test),'start locations, times, states and ordinary time limits remain unchanged');
select is(api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een gezamenlijk beter P-38 tijdslot expliciet beoordelen',key),result,'retrying the approved joint change returns the same durable result') from route_policy_test;
select is((select count(*)::integer from app_private.joint_route_finale_approvals),1,'idempotent retry does not create duplicate approvals');
-- Real confirmed child arrivals survive both household reassignment and a safe
-- present-participant transfer after a run has already bound its accepted plan.
savepoint physical_and_child_history;
create temp table policy_history(run_id uuid,recipient_run uuid,stop_id uuid,participant uuid,child_id uuid,registration_child uuid,alias_id uuid);
select ok(not app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001'),'a planned house or administrative gathering is not an actual physical visit')from route_policy_test;
do $$
declare eid uuid;historical uuid;recipient uuid;stop uuid;participant uuid;rc uuid;child uuid;reservation uuid;evidence uuid;alias uuid;parent jsonb;
begin
 select event_id into eid from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001';
 select registration_child.id,registration_child.child_id into rc,child from app_private.group_registrations a join app_private.registration_children registration_child on registration_child.registration_id=a.registration_id and registration_child.participation_status='active' where a.group_id='23000000-0000-0000-0000-000000000001' and a.superseded_at is null order by registration_child.id limit 1;
 select application_id,to_jsonb(p) into alias,parent from app_private.portals p where p.id='12000000-0000-0000-0000-000000000001';
 -- A manual record whose physical identity is the original application is a
 -- second portal alias for the same actual house, not an extra visit.
 insert into app_private.portals select p.* from jsonb_populate_record(null::app_private.portals,parent||jsonb_build_object('id',alias,'application_id',null,'system_number',99,'system_code','P-99','name','Synthetic alias of one physical house'))p;
 insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
 select alias,w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total from app_private.portal_windows w where w.portal_id='12000000-0000-0000-0000-000000000001';
 insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at,finished_at)
 values('23000000-0000-0000-0000-000000000001',(app_private.route_group_start_context('23000000-0000-0000-0000-000000000001')->>'scheduleId')::uuid,'completed','2026-10-31T16:00:00Z','2026-10-31T17:05:00Z')returning id into historical;
 insert into app_private.run_participants(run_id,registration_child_id,attendance)values(historical,rc,'present')returning id into participant;
 insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
 values(eid,'12000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000001',historical,'ordinary','completed','2026-10-31T17:00:00Z','2026-10-31T17:07:00Z',1)returning id into reservation;
 insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,outcome,opened_at,completed_at)
 values(historical,'12000000-0000-0000-0000-000000000001',reservation,'ordinary',1,'completed','visited','2026-10-31T17:00:00Z','2026-10-31T17:05:00Z')returning id into stop;
 insert into app_private.scan_evidence(run_stop_id,credential_id,credential_version,actor_id,validation_method,scanned_at)
 select stop,c.id,c.version,'f0000000-0000-0000-0000-000000000001','short_code','2026-10-31T17:00:00Z'from app_private.portal_credentials c where c.portal_id='12000000-0000-0000-0000-000000000001' order by c.version desc limit 1 returning id into evidence;
 insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id)
 values(eid,historical,stop,participant,child,evidence,true,'2026-10-31T17:00:00Z','f0000000-0000-0000-0000-000000000001');
 insert into app_private.group_runs(group_id,schedule_revision_id,accepted_route_version_id,status,started_at)
 select '23000000-0000-0000-0000-000000000002',(app_private.route_group_start_context('23000000-0000-0000-0000-000000000002')->>'scheduleId')::uuid,(result->>'acceptedVersionId')::uuid,'live','2026-10-31T16:10:00Z' from route_policy_test returning id into recipient;
 insert into policy_history values(historical,recipient,stop,participant,child,rc,alias);
end $$;
select ok(app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000001',h.alias_id),'a confirmed visit to one portal is also history for its physical alias')from route_policy_test,policy_history h;
select ok(not app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000002',h.alias_id),'an unrelated group does not inherit another child history')from route_policy_test,policy_history h;
select ok(not app_private.group_has_visited_portal(gen_random_uuid(),'23000000-0000-0000-0000-000000000001',h.alias_id),'arrival history never crosses event boundaries')from policy_history h;
savepoint assigned_family_transfer;
-- Model the result of an already reviewed composition correction. Ordinary
-- callers retain the existing composition-reopen guard.
set local session_replication_role=replica;
update app_private.group_registrations set group_id='23000000-0000-0000-0000-000000000002'where group_id='23000000-0000-0000-0000-000000000001' and superseded_at is null;
set local session_replication_role=origin;
select ok(app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000002',h.alias_id),'reassigning a household preserves its actual child arrivals across physical aliases')from route_policy_test,policy_history h;
rollback to assigned_family_transfer;
-- Present runtime membership can change safely without rewriting historical
-- group assignments. It is independently included in the history protection.
insert into app_private.run_participants(run_id,registration_child_id,attendance)select recipient_run,registration_child,'present'from policy_history;
select ok(app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000002',h.alias_id),'a present non-departed transferred child protects its history even without changing the assignment')from route_policy_test,policy_history h;
update app_private.run_participants set departed_at='2026-10-31T17:01:00Z'where run_id=(select recipient_run from policy_history);
select ok(not app_private.group_has_visited_portal((input->>'eventId')::uuid,'23000000-0000-0000-0000-000000000002',h.alias_id),'a departed child outside the current assignments no longer restricts another group')from route_policy_test,policy_history h;
update app_private.run_participants set departed_at=null where run_id=(select recipient_run from policy_history);
create temp table history_calendar as select jsonb_agg(to_jsonb(v)order by v.id) visits from app_private.live_route_visits v;
select is(app_private.dispatch_next_stop(recipient_run,'2026-10-31T17:00:00Z')->>'reason','PHYSICAL_VISIT_ALREADY_RECORDED','an already bound run rechecks the transferred child physical history before dispatch')from policy_history;
select is((select count(*)::integer from app_private.run_stops s join policy_history h on h.recipient_run=s.run_id),0,'history protection creates no duplicate physical stop');
select is((select count(*)::integer from app_private.portal_reservations r join policy_history h on h.recipient_run=r.run_id),0,'history protection does not reserve a duplicate ordinary or finale stop');
select is((select jsonb_agg(to_jsonb(v)order by v.id)from app_private.live_route_visits v),(select visits from history_calendar),'history protection asks for explicit replanning and preserves the accepted intentions');
select is(app_private.dispatch_next_stop(recipient_run,'2026-10-31T17:00:00Z')->>'reason','PHYSICAL_VISIT_ALREADY_RECORDED','retrying still cannot dispatch the already visited house')from policy_history;
select is((select count(*)::integer from app_private.route_alerts a join policy_history h on h.recipient_run=a.run_id where a.code='PHYSICAL_VISIT_ALREADY_RECORDED'and a.status='open'),1,'repeated runtime checks show one concrete history advisory');
rollback to physical_and_child_history;

-- The runtime also uses the actual long final walk, including for a group
-- whose ordinary visit is complete. No extra physical stop is invented.
savepoint long_finale_runtime;
create temp table policy_runtime(run_id uuid,walk_seconds integer,result jsonb);
with run as(insert into app_private.group_runs(group_id,schedule_revision_id,accepted_route_version_id,status,started_at)
 select '23000000-0000-0000-0000-000000000001',(app_private.route_group_start_context('23000000-0000-0000-0000-000000000001')->>'scheduleId')::uuid,(result->>'acceptedVersionId')::uuid,'live','2026-10-31T16:00:00Z' from route_policy_test returning id)
 insert into policy_runtime(run_id)select id from run;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select runtime.run_id,rc.id,'present' from policy_runtime runtime cross join app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id='23000000-0000-0000-0000-000000000001' and a.superseded_at is null;
with reservation as(insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
 select (select event_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'12000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000001',run_id,'ordinary','completed','2026-10-31T17:00:00Z','2026-10-31T17:07:00Z',1 from policy_runtime returning id,run_id),
 stop as(insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at,completed_at,outcome)
 select run_id,'12000000-0000-0000-0000-000000000001',id,'ordinary',1,'completed','2026-10-31T17:00:00Z','2026-10-31T17:05:00Z','visited' from reservation returning id)
 update app_private.live_route_visits set run_stop_id=stop.id from stop where group_id='23000000-0000-0000-0000-000000000001' and kind='ordinary' and retired_at is null;
update app_private.portal_private_locations set marker_latitude=52.10,marker_longitude=4.259 where portal_id='12000000-0000-0000-0000-000000000001';
update policy_runtime set walk_seconds=travel.duration_seconds from app_private.destination_estimate(52.10,4.259,
 (app_private.portal_location('12000000-0000-0000-0000-000000000030')->>'latitude')::numeric,
 (app_private.portal_location('12000000-0000-0000-0000-000000000030')->>'longitude')::numeric)travel;
select ok(walk_seconds>900 and walk_seconds<=1500,'runtime fixture has a genuine stored entrance-pin walk longer than fifteen minutes')from policy_runtime;
select lives_ok($$update policy_runtime set result=app_private.dispatch_next_stop(run_id,'2026-10-31T17:30:00Z'::timestamptz-make_interval(secs=>walk_seconds))$$,'live dispatch accepts the actual long last walk when it reaches the approved P-38 slot');
select is(result->>'decision','finale','the actual long last walk dispatches P-38 directly without an extra ordinary stop')from policy_runtime;
select is((select (d.input_snapshot->>'walkSeconds')::integer from app_private.dispatch_decisions d where d.run_id=runtime.run_id order by sequence desc limit 1),walk_seconds,'dispatch records the full actual final walking duration')from policy_runtime runtime;
rollback to long_finale_runtime;
savepoint no_previous_appointment;
select lives_ok($$insert into app_private.joint_route_finale_approvals(accepted_version_id,schedule_id,group_id,portal_id,previous_reserved_at,proposed_reserved_at,composition_hash,approved_by)
 select gen_random_uuid(),schedule_id,group_id,portal_id,null,proposed_reserved_at,composition_hash,approved_by from app_private.joint_route_finale_approvals limit 1$$,'approval evidence can explicitly represent an initially missing finale reservation');
rollback to no_previous_appointment;
select throws_ok($$update app_private.joint_route_finale_approvals set proposed_reserved_at=proposed_reserved_at+interval '5 minutes'$$,'23514','ACCEPTED_ROUTE_VERSION_IMMUTABLE','the record of explicit finale approval cannot be overwritten');
select * from finish();
rollback;
