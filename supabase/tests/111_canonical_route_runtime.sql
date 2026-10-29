begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
create temp table runtime_test(fixture jsonb,starts_at timestamptz,proposal jsonb,result jsonb,run_id uuid,departure timestamptz,old_snapshot jsonb);
insert into runtime_test(starts_at)select to_timestamp(floor(extract(epoch from statement_timestamp()-interval '1 hour')/600)*600);
update runtime_test set fixture=pg_temp.joint_canonical_fixture(starts_at);
-- The old stored cutoff is genuinely derived, not a household's hard stop.
update app_private.group_schedule_revisions set effective_ordinary_stop_at=(select starts_at+interval '30 minutes'from runtime_test)
 where id=(select(fixture#>>'{third,scheduleId}')::uuid from runtime_test);
update app_private.portal_windows set opens_at=(select starts_at+interval '40 minutes'from runtime_test)where portal_id='12000000-0000-0000-0000-000000000001';
update runtime_test set proposal=pg_temp.joint_proposal(starts_at+interval '50 minutes');
-- A second accepted ordinary appointment proves future visits of a begun group
-- remain physical calendar commitments before dispatch creates a reservation.
do $$
declare input jsonb:=api.admin_joint_route_planning_input('duindorp-halloween-2026');third uuid;groups jsonb;second jsonb;walk jsonb;exit_leg jsonb;win jsonb;
begin
 select(fixture#>>'{third,groupId}')::uuid into third from runtime_test;
 select p->'windows'->0 into win from jsonb_array_elements(input->'portals')p where p->>'id'='12000000-0000-0000-0000-000000000002';
 select *into walk from jsonb_array_elements(input->'legs')l where l->>'from'='portal:12000000-0000-0000-0000-000000000001'and l->>'to'='portal:12000000-0000-0000-0000-000000000002';
 select *into exit_leg from jsonb_array_elements(input->'legs')l where l->>'from'='portal:12000000-0000-0000-0000-000000000002'and l->>'to'='portal:12000000-0000-0000-0000-000000000030';
 second:=jsonb_build_object('portalId','12000000-0000-0000-0000-000000000002','kind','ordinary','sequence',2,'startsAt',(select starts_at+interval '90 minutes'from runtime_test),
  'visitSeconds',win->'visitSeconds','bufferSeconds',win->'bufferSeconds','walkSeconds',walk->'seconds','walkMeters',walk->'meters');
 select jsonb_agg(case when p->>'groupId'=third::text then jsonb_set(p,'{visits}',jsonb_build_array(p->'visits'->0,second,
  (p->'visits'->1)||jsonb_build_object('sequence',3,'walkSeconds',exit_leg->'seconds','walkMeters',exit_leg->'meters')))else p end order by p->>'groupId')into groups
  from runtime_test t cross join lateral jsonb_array_elements(t.proposal->'groups')p;
 update runtime_test set proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{groups}',groups));
end $$;

select lives_ok($$update runtime_test set result=api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Synthetische beoordeelde route voor live-controle',gen_random_uuid()::text)$$,'runtime fixture accepts the same complete physical calendar');
select ok(not has_function_privilege('authenticated','api.worker_dispatch_due_groups(text,integer)','execute'),'background dispatch remains service-only');
select is((select count(*)::integer from app_private.group_runs),0,'accepting a route does not start a journey');
select is(app_private.start_ops_route_preview((fixture#>>'{third,groupId}')::uuid)->'stops'->0->>'portalId','12000000-0000-0000-0000-000000000001','expected preview uses the accepted first ordinary door')from runtime_test;
select is((select(stop->>'plannedArrivalAt')::timestamptz from jsonb_array_elements(app_private.start_ops_route_preview((fixture#>>'{third,groupId}')::uuid)->'stops')stop where stop->>'kind'='finale'),
 (select starts_at from app_private.live_route_visits where group_id=(fixture#>>'{third,groupId}')::uuid and kind='finale'and retired_at is null),'expected preview uses exactly the accepted reserved finale time')from runtime_test;
select ok((select min(starts_at)from app_private.live_route_visits where group_id=(fixture#>>'{third,groupId}')::uuid and kind='ordinary')>
 (select effective_ordinary_stop_at from app_private.group_schedule_revisions where id=(fixture#>>'{third,scheduleId}')::uuid),'accepted ordinary visit may follow the former derived cutoff')from runtime_test;

-- A newly started journey binds to the accepted version, including an exact held
-- finale. No unrelated route is recreated or silently shortened.
insert into app_private.group_runs(id,group_id,schedule_revision_id,status,started_at)
 select 'd1110000-0000-0000-0000-000000000001',(fixture#>>'{third,groupId}')::uuid,(fixture#>>'{third,scheduleId}')::uuid,'live',clock_timestamp()from runtime_test;
update runtime_test set run_id='d1110000-0000-0000-0000-000000000001';
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select t.run_id,rc.id,case when row_number()over(order by rc.id)=1 then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end from runtime_test t join app_private.group_registrations a on a.group_id=(t.fixture#>>'{third,groupId}')::uuid and a.superseded_at is null
 join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active';
update runtime_test t set departure=(select(visit->>'startsAt')::timestamptz-make_interval(secs=>(visit->>'walkSeconds')::integer)
 from jsonb_array_elements(t.proposal->'groups')g cross join lateral jsonb_array_elements(g->'visits')visit where g->>'groupId'=t.fixture#>>'{third,groupId}'and visit->>'kind'='ordinary'order by(visit->>'sequence')::integer limit 1);
select lives_ok($$update runtime_test set result=app_private.dispatch_next_stop(run_id,departure)$$,'new live dispatch follows its accepted first visit after the old cutoff');
select is(result->>'decision','ordinary','the old derived ordinary cutoff does not force an early finale')from runtime_test;
select is((select accepted_route_version_id from app_private.group_runs r where r.id=t.run_id),(select accepted_version_id from app_private.live_route_plans p where p.group_id=(t.fixture#>>'{third,groupId}')::uuid),'run and board bind the same immutable accepted version')from runtime_test t;
select is((select count(*)::integer from app_private.portal_reservations r where r.run_id=t.run_id and r.kind='finale'and r.status='held'),1,'first dispatch holds exactly one finale reservation')from runtime_test t;
select is((select r.reserved_from from app_private.portal_reservations r where r.run_id=t.run_id and r.kind='finale'and r.status='held'),
 (select v.starts_at from app_private.live_route_visits v where v.group_id=(t.fixture#>>'{third,groupId}')::uuid and v.kind='finale'and v.retired_at is null),'held finale is not pulled forward to an independently greedy arrival')from runtime_test t;
select is((select r.reserved_until-r.reserved_from from app_private.portal_reservations r where r.run_id=t.run_id and r.kind='finale'and r.status='held'),interval '8 minutes','finale physical reservation includes six-minute show and two-minute changeover')from runtime_test t;
select is((api.group_snapshot((fixture#>>'{third,groupId}')::uuid)#>>'{group,timing,ordinaryStopAt}')::timestamptz,
 app_private.group_ordinary_deadline((fixture#>>'{third,groupId}')::uuid),'authorized live timing uses the actual hard ordinary boundary')from runtime_test;
select is((api.group_snapshot((fixture#>>'{third,groupId}')::uuid)#>>'{group,timing,expectedFinaleArrivalAt}')::timestamptz,
 (select reserved_from from app_private.portal_reservations where run_id=t.run_id and kind='finale'and status='held'),'live timing and held finale use the same arrival')from runtime_test t;

create function pg_temp.live_facts(_run uuid)returns jsonb language sql as $$
 select jsonb_build_object('run',(select to_jsonb(r)from app_private.group_runs r where id=_run),
  'stops',(select jsonb_agg(to_jsonb(s)order by s.id)from app_private.run_stops s where run_id=_run),
  'reservations',(select jsonb_agg(to_jsonb(r)order by r.id)from app_private.portal_reservations r where run_id=_run))
$$;
update runtime_test set old_snapshot=pg_temp.live_facts(run_id);
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',1)$$,'background pulse accepts the bound route after its former cutoff');
select is((select state::text from app_private.run_stops where run_id=t.run_id and stop_kind='ordinary'),'active','background pulse does not skip the real ordinary visit at the obsolete cutoff')from runtime_test t;
select is((select count(*)::integer from app_private.journey_events where run_id=t.run_id and event_type='stop.cutoff_redirected'),0,'no obsolete cutoff redirection is recorded')from runtime_test t;
select ok(not exists(select 1 from app_private.route_alerts where run_id=t.run_id and code='ACTIVE_VISIT_AFTER_STOP'),'obsolete derived cutoff does not create a misleading hard-stop alert')from runtime_test t;

-- Once begun, every still unprotected accepted future appointment remains fixed
-- occupancy for all other groups, even before that individual stop is dispatched.
savepoint fixed_future;
update app_private.run_stops set state='completed',outcome='visited',completed_at=clock_timestamp()where run_id=(select run_id from runtime_test)and stop_kind='ordinary';
update app_private.group_runs set current_stop_id=null where id=(select run_id from runtime_test);
update app_private.portal_reservations set status='completed'where run_id=(select run_id from runtime_test)and kind='ordinary';
select ok(exists(select 1 from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'fixedVisits')v
 where v->>'groupId'=t.fixture#>>'{third,groupId}'and v->>'portalId'='12000000-0000-0000-0000-000000000002'), 'begun group remaining ordinary appointment stays fixed for a new proposal')from runtime_test t;
select ok(not app_private.portal_interval_available('12000000-0000-0000-0000-000000000002',(fixture#>>'{source,groupId}')::uuid,
 starts_at+interval '90 minutes',starts_at+interval '97 minutes',1,clock_timestamp()),'another group cannot book over the begun group remaining ordinary arrival')from runtime_test;
select ok(exists(select 1 from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'fixedVisits')v
 where v->>'groupId'=t.fixture#>>'{third,groupId}'and v->>'kind'='finale'), 'begun group future finale remains fixed occupancy for a new proposal')from runtime_test t;
select is((select(v->>'children')::integer from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'fixedVisits')v
 where v->>'groupId'=t.fixture#>>'{third,groupId}'and v->>'kind'='finale'limit 1),1,'begun future finale counts the one actually present child rather than the full assigned family')from runtime_test t;
rollback to fixed_future;

-- Model a journey that was already underway at deployment. Read-only refreshes
-- and cheap seeding retain its current destination, reservations and timestamps.
savepoint begun_legacy;
update app_private.live_route_plans set accepted_version_id=null,source_hash=null,plan_hash=null where group_id=(select(fixture#>>'{fourth,groupId}')::uuid from runtime_test);
insert into app_private.group_runs(id,group_id,schedule_revision_id,status,started_at)
 select 'd1110000-0000-0000-0000-000000000002',(fixture#>>'{fourth,groupId}')::uuid,(fixture#>>'{fourth,scheduleId}')::uuid,'live',
 (select activated_at-interval '1 second'from app_private.joint_route_policy_releases where policy_version='joint-reception-v1')from runtime_test;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select 'd1110000-0000-0000-0000-000000000002',rc.id,'present'from runtime_test t join app_private.group_registrations a on a.group_id=(t.fixture#>>'{fourth,groupId}')::uuid and a.superseded_at is null
 join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active';
insert into app_private.portal_reservations(id,event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
 select 'd1110000-0000-0000-0000-000000000003',(select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000002',(fixture#>>'{fourth,groupId}')::uuid,'d1110000-0000-0000-0000-000000000002','ordinary','active',clock_timestamp(),clock_timestamp()+interval '7 minutes',1,clock_timestamp()+interval '20 minutes'from runtime_test;
insert into app_private.run_stops(id,run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
 values('d1110000-0000-0000-0000-000000000004','d1110000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000002','d1110000-0000-0000-0000-000000000003','ordinary',1,'active',clock_timestamp());
update app_private.group_runs set current_stop_id='d1110000-0000-0000-0000-000000000004'where id='d1110000-0000-0000-0000-000000000002';
update runtime_test set old_snapshot=pg_temp.live_facts('d1110000-0000-0000-0000-000000000002');
select lives_ok($$select app_private.live_planboard_seed((select id from app_private.events where slug='duindorp-halloween-2026'));select api.admin_live_planboard_snapshot('duindorp-halloween-2026')$$,'refreshing the board never replans an already begun legacy journey');
select is(pg_temp.live_facts('d1110000-0000-0000-0000-000000000002'),old_snapshot,'existing begun run, current destination and reservation remain byte-for-byte unchanged')from runtime_test;
select is((select accepted_route_version_id from app_private.group_runs where id='d1110000-0000-0000-0000-000000000002'),null::uuid,'old begun journey is not silently bound to a new plan version');
rollback to begun_legacy;

savepoint unaccepted;
insert into app_private.group_runs(id,group_id,schedule_revision_id,status,started_at)
 select 'd1110000-0000-0000-0000-000000000005',(fixture#>>'{fourth,groupId}')::uuid,(fixture#>>'{fourth,scheduleId}')::uuid,'live',clock_timestamp()from runtime_test;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select 'd1110000-0000-0000-0000-000000000005',rc.id,'present'from runtime_test t join app_private.group_registrations a on a.group_id=(t.fixture#>>'{fourth,groupId}')::uuid and a.superseded_at is null join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active';
update app_private.live_route_plans set accepted_version_id=null,source_hash=null,plan_hash=null where group_id=(select(fixture#>>'{fourth,groupId}')::uuid from runtime_test);
select throws_ok($$select app_private.dispatch_next_stop('d1110000-0000-0000-0000-000000000005',clock_timestamp())$$,'23514','JOINT_ROUTE_REVIEW_REQUIRED','new route cannot start from an unaccepted durable intention');
select is((select count(*)::integer from app_private.portal_reservations where run_id='d1110000-0000-0000-0000-000000000005'),0,'blocked new start creates no operational reservation');
update app_private.live_route_visits set retired_at=clock_timestamp()where group_id=(select(fixture#>>'{fourth,groupId}')::uuid from runtime_test)and retired_at is null;
select throws_ok($$select app_private.dispatch_next_stop('d1110000-0000-0000-0000-000000000005',clock_timestamp())$$,'23514','JOINT_ROUTE_REVIEW_REQUIRED','a cold empty dynamic board cannot bypass explicit route acceptance');
select is((select count(*)::integer from app_private.portal_reservations where run_id='d1110000-0000-0000-0000-000000000005'),0,'empty unaccepted dynamic route also creates no reservation');
rollback to unaccepted;
select is((select count(*)::integer from app_private.group_runs where id in('d1110000-0000-0000-0000-000000000002','d1110000-0000-0000-0000-000000000005')),0,'rolled-back legacy and blocked-start probes leave no extra journey');
-- Logical future appointments are not physical occupation when their last
-- family has left. Neither this projection nor a retirement deletes history.
savepoint empty_future;
savepoint retired_future;
update app_private.walking_groups set retired_at=clock_timestamp()where id=(select(fixture#>>'{fourth,groupId}')::uuid from runtime_test);
select ok(not exists(select 1 from app_private.portal_occupancy_intervals('12000000-0000-0000-0000-000000000001',clock_timestamp())occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid)
 and not exists(select 1 from app_private.start_schedule_reservations((select id from app_private.events where slug='duindorp-halloween-2026'))occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid),'retired nonempty future group reserves neither a door nor a departure')from runtime_test t;
rollback to retired_future;
do $$
declare gid uuid;rid uuid;eid uuid;command_id uuid:=gen_random_uuid();
begin
 select(fixture#>>'{fourth,groupId}')::uuid into gid from runtime_test;
 select registration_id into rid from app_private.group_registrations where group_id=gid and superseded_at is null limit 1;
 select event_id into eid from app_private.walking_groups where id=gid;
 perform app_private.admin_registration_scope_begin(eid,rid,array[gid],command_id);
 update app_private.group_registrations set superseded_at=clock_timestamp()where group_id=gid and registration_id=rid and superseded_at is null;
 perform app_private.admin_registration_refresh_group(gid,auth.uid());
 perform app_private.admin_registration_scope_end(command_id);
end $$;
-- Deliberately put the now-empty historical intention over a populated group's
-- actual plan: it must create no fictitious headway or concurrent-group claim.
update app_private.live_route_visits set starts_at=(select min(starts_at)from app_private.live_route_visits where group_id=(select(fixture#>>'{source,groupId}')::uuid from runtime_test)and kind='ordinary'and retired_at is null)
 where group_id=(select(fixture#>>'{fourth,groupId}')::uuid from runtime_test)and kind='ordinary'and retired_at is null;
select ok(not exists(select 1 from app_private.portal_occupancy_intervals('12000000-0000-0000-0000-000000000001',clock_timestamp())occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid),'empty unbegun source reserves no future ordinary door')from runtime_test t;
select ok(not exists(select 1 from app_private.finale_occupancy_intervals((select id from app_private.events where slug='duindorp-halloween-2026'),clock_timestamp())occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid),'empty unbegun source reserves no future finale')from runtime_test t;
select ok(not exists(select 1 from app_private.start_schedule_reservations((select id from app_private.events where slug='duindorp-halloween-2026'))occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid),'empty source keeps historical appointment without consuming departure/gathering capacity')from runtime_test t;
select ok(not exists(select 1 from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'fixedVisits')occupied where occupied->>'groupId'=t.fixture#>>'{fourth,groupId}'),'empty source creates no false fixed calendar visit')from runtime_test t;
select ok(not exists(select 1 from jsonb_array_elements(app_private.live_planboard_warnings((select id from app_private.events where slug='duindorp-halloween-2026'),'[]'))warning
 where warning->>'code' in('ARRIVAL_HEADWAY','RECEPTION_POLICY')and warning->'groupIds'@>jsonb_build_array(t.fixture#>>'{source,groupId}')),'empty source intention creates no false headway/capacity block for the populated group')from runtime_test t;
select ok(exists(select 1 from app_private.live_route_visits where group_id=(t.fixture#>>'{fourth,groupId}')::uuid and retired_at is null),'capacity projection preserves empty group historical intention rows')from runtime_test t;
-- An actual completed reservation remains physical truth even if its family
-- is no longer assigned. Its remaining buffer still blocks another arrival.
insert into app_private.group_runs(id,group_id,schedule_revision_id,status,started_at,finished_at)
 select 'd1110000-0000-0000-0000-000000000006',(fixture#>>'{fourth,groupId}')::uuid,(fixture#>>'{fourth,scheduleId}')::uuid,'live',clock_timestamp()-interval '10 minutes',null from runtime_test;
select ok(exists(select 1 from app_private.start_schedule_reservations((select id from app_private.events where slug='duindorp-halloween-2026'))departure where departure.group_id=(t.fixture#>>'{fourth,groupId}')::uuid and departure.child_count=0),'an actual begun departure remains reserved even after logical assigned membership becomes empty')from runtime_test t;
update app_private.group_runs set status='completed',finished_at=clock_timestamp()where id='d1110000-0000-0000-0000-000000000006';
insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
 select g.event_id,'12000000-0000-0000-0000-000000000002',g.id,'d1110000-0000-0000-0000-000000000006','ordinary','completed',t.starts_at+interval '58 minutes',t.starts_at+interval '66 minutes',1,clock_timestamp()+interval '1 hour'
 from runtime_test t join app_private.walking_groups g on g.id=(t.fixture#>>'{fourth,groupId}')::uuid;
select ok(exists(select 1 from app_private.portal_occupancy_intervals('12000000-0000-0000-0000-000000000002',clock_timestamp())occupied where occupied.group_id=(t.fixture#>>'{fourth,groupId}')::uuid and occupied.child_count=1),'empty membership never discards a real completed physical reservation')from runtime_test t;
select ok(not app_private.portal_interval_available('12000000-0000-0000-0000-000000000002',(fixture#>>'{source,groupId}')::uuid,starts_at+interval '60 minutes',starts_at+interval '67 minutes',1,clock_timestamp()),'real completed buffer still blocks another group after logical membership becomes empty')from runtime_test;
rollback to empty_future;
update app_private.portals set arrival_headway_seconds=600 where id='12000000-0000-0000-0000-000000000030';
select is((api.admin_startregie_snapshot('duindorp-halloween-2026')#>>'{settings,finaleHeadwaySeconds}')::integer,600,'legacy start-slot proposal receives the configurable physical finale headway');
select is((api.admin_startregie_snapshot('duindorp-halloween-2026')#>>'{settings,finaleOpensAt}')::timestamptz,
 (select finale_opens_at from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),'effective finale metadata preserves the configured editable opening');
select *from finish();
rollback;
