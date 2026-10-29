begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.event_route_settings set first_start_at='2026-10-31T17:00:00+01',global_ordinary_stop_at='2026-10-31T20:30:00+01',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T19:00:00+01',finale_last_arrival_at='2026-10-31T21:25:00+01',
 finale_closes_at='2026-10-31T21:32:00+01',finale_show_seconds=600,finale_turnover_seconds=120,finale_planning_transfer_seconds=900,
 finale_max_concurrent_groups=2,finale_max_concurrent_children=20,finale_available=true,planner_mode='dynamic'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
create temp table completion_fixtures(label text primary key,gid uuid,rid uuid,child uuid,point uuid,slot uuid,schedule uuid,run uuid,reservation uuid);
create function pg_temp.completion_fixture(_label text,_end timestamptz default '2026-10-31T21:00:00+01') returns void
language plpgsql as $$
declare e uuid:=(select id from app_private.events where slug='duindorp-halloween-2026');h uuid;g uuid;r uuid;c uuid;p uuid;s uuid;
begin
 insert into app_private.households(label,primary_contact_user_id) values('Synthetic completion fixture','f0000000-0000-0000-0000-000000000001') returning id into h;
 insert into app_private.household_members(household_id,user_id,relation_role) values(h,'f0000000-0000-0000-0000-000000000001','owner');
 insert into app_private.registrations(event_id,household_id,reference,status,preferred_start_at,desired_end_at)
 values(e,h,'COMPLETION-'||gen_random_uuid(),'submitted','2026-10-31T18:30:00+01',_end) returning id into r;
 insert into app_private.children(household_id,first_name,age_at_event) values(h,'Synthetic',8) returning id into c;
 insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(e,r,c,250);
 insert into app_private.walking_groups(event_id,code,status,route_mode) values(e,'COMP-'||_label,'draft','dynamic') returning id into g;
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(g,r,1);
 insert into app_private.start_points(event_id,name,private_address,latitude,longitude,max_gathering_groups,max_gathering_children,active)
 values(e,'Synthetic '||_label,'FICTIEF TESTADRES',52.1,4.27,1,20,true) returning id into p;
 insert into app_private.start_slots(event_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,start_point_id)
 values(e,'Synthetic','Synthetic','FICTIEF TESTADRES',52.1,4.27,now(),'2026-10-31T18:30:00+01',1,20,p) returning id into s;
 insert into completion_fixtures(label,gid,rid,child,point,slot) values(_label,g,r,c,p,s);
end $$;
select pg_temp.completion_fixture('late'),pg_temp.completion_fixture('early','2026-10-31T20:30:00+01'),pg_temp.completion_fixture('other'),pg_temp.completion_fixture('bulk');
grant select,update on completion_fixtures to authenticated;
select is(app_private.group_end_overrun_seconds(),1800,'one server policy defaults to thirty minutes');
select is((api.admin_startregie_snapshot('duindorp-halloween-2026')#>>'{settings,maxGroupOverrunSeconds}')::integer,
 app_private.group_end_overrun_seconds(),'browser receives exactly the server policy');
select ok(not has_function_privilege('anon','app_private.assert_group_schedule_timing(uuid,uuid,timestamptz,timestamptz)','execute'),'timing helper is not an anonymous endpoint');
set local role authenticated;
select lives_ok($$update completion_fixtures set schedule=(api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:20:00+01',null,'good','Synthetische grens precies dertig minuten uitloop')->>'id')::uuid where label='late'$$,
 'direct authenticated API accepts completion exactly at 21:30');
select throws_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:20:01+01',null,'good','Synthetische seconde voorbij de groepsgrens') from completion_fixtures where label='late'$$,
 '23514','GROUP_END_TIME_INFEASIBLE','direct API rejects completion at 21:30:01');
select throws_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:25:00+01',null,'good','Aankomst alleen is onvoldoende voor de groepsdeadline') from completion_fixtures where label='late'$$,
 '23514','GROUP_END_TIME_INFEASIBLE','arrival 21:25 does not fit a ten-minute show before 21:30');
select lives_ok($$update completion_fixtures set schedule=(api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T20:50:00+01',null,'good','Andere groep heeft een eigen vroegere uitloopgrens')->>'id')::uuid where label='early'$$,
 '20:30 desired end permits completion exactly at 21:00');
select throws_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T20:50:01+01',null,'good','Geen globale deadline gebruiken voor een vroegere groep') from completion_fixtures where label='early'$$,
 '23514','GROUP_END_TIME_INFEASIBLE','20:30 desired end rejects completion at 21:00:01');
set local role postgres;
select is((select (s.input_snapshot->>'expectedCompletionAt')::timestamptz from app_private.group_schedule_revisions s join completion_fixtures f on f.schedule=s.id where label='late'),
 '2026-10-31T21:30:00+01'::timestamptz,'snapshot completion includes the entire show');
select is((select (s.input_snapshot->>'physicalFinaleEndsAt')::timestamptz from app_private.group_schedule_revisions s join completion_fixtures f on f.schedule=s.id where label='late'),
 '2026-10-31T21:32:00+01'::timestamptz,'physical occupancy includes turnover independently');
select throws_ok($$update app_private.event_route_settings set finale_show_seconds=601 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')$$,
 '23514','GROUP_END_TIME_INFEASIBLE','an extra show second cannot cross the group boundary');
select throws_ok($$update app_private.event_route_settings set finale_turnover_seconds=121 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')$$,
 '23514','GROUP_END_TIME_INFEASIBLE','an extra turnover second cannot cross definitive physical closure');
select lives_ok($$update app_private.event_route_settings set finale_closes_at='2026-10-31T21:33:00+01',finale_turnover_seconds=121 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')$$,
 'turnover may extend past group completion if separate physical closure allows it');
update app_private.event_route_settings set finale_turnover_seconds=120,finale_closes_at='2026-10-31T21:32:00+01' where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
-- Publication is an explicit local fixture operation; no mail worker is called.
create function pg_temp.completion_publish(_label text) returns jsonb language plpgsql security definer set search_path='' as $$
declare f record;expected jsonb;version integer;
begin
 select * into f from completion_fixtures where label=_label;
 select settings_version into version from app_private.events where slug='duindorp-halloween-2026';
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026',f.gid,(select revision from app_private.group_schedule_revisions where id=f.schedule),version);
 select jsonb_build_array(jsonb_build_object('id',id,'revision',revision)) into expected from app_private.group_schedule_revisions where id=f.schedule;
 return api.admin_startregie_publish_times('duindorp-halloween-2026',array[f.schedule],expected,version,gen_random_uuid()::text,'Synthetische expliciete publicatie van geldige uitloop');
end $$;
select lives_ok($$select pg_temp.completion_publish('late')$$,'valid overrun survives explicit server publication');
select is((select state::text from app_private.group_schedule_revisions s join completion_fixtures f on f.schedule=s.id where label='late'),'published','valid overrun is published');
select is((api.group_snapshot((select gid from completion_fixtures where label='late'))#>>'{group,timing,expectedCompletionAt}')::timestamptz,
 '2026-10-31T21:30:00+01'::timestamptz,'participant snapshot exposes published completion consistently');
-- Caller metadata can never replace server-derived target, policy or completion.
update app_private.group_schedule_revisions set input_snapshot=input_snapshot||jsonb_build_object('maxGroupOverrunSeconds',999999,
 'dominantEndAt','2026-11-01T21:00:00+01','expectedCompletionAt','2026-10-31T19:00:00+01') where id=(select schedule from completion_fixtures where label='late');
select is((select (input_snapshot->>'maxGroupOverrunSeconds')::integer from app_private.group_schedule_revisions where id=(select schedule from completion_fixtures where label='late')),
 app_private.group_end_overrun_seconds(),'metadata cannot override the server overrun allowance');
select is((select (input_snapshot->>'expectedCompletionAt')::timestamptz from app_private.group_schedule_revisions where id=(select schedule from completion_fixtures where label='late')),
 '2026-10-31T21:30:00+01'::timestamptz,'metadata cannot forge expected show completion');
-- Direct trigger bypass attempts still fail, including state-only publication.
select throws_ok($$update app_private.group_schedule_revisions set expected_finale_arrival_at='2026-10-31T21:20:01+01' where id=(select schedule from completion_fixtures where label='late')$$,
 '23514','GROUP_END_TIME_INFEASIBLE','direct schedule writes cannot bypass the temporal guard');
-- Real live reservation and idempotence under the same policy.
with inserted as(insert into app_private.group_runs(group_id,status,schedule_revision_id) select gid,'live',schedule from completion_fixtures where label='late' returning id)
 update completion_fixtures set run=inserted.id from inserted where label='late';
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select f.run,c.id,'present' from completion_fixtures f join app_private.registration_children c on c.registration_id=f.rid where label='late';
create temp table completion_preserved as select md5(to_jsonb(r)::text) run_hash from app_private.group_runs r join completion_fixtures f on f.run=r.id where label='late';
select is(app_private.schedule_latest_finale_arrival(schedule),'2026-10-31T21:20:00+01'::timestamptz,'live policy uses published target plus thirty minutes minus show') from completion_fixtures where label='late';
select is(app_private.try_reserve_finale(run,'2026-10-31T21:20:01+01','2026-10-31T21:00:00+01'),null::uuid,'live dispatch refuses one second beyond published group deadline') from completion_fixtures where label='late';
-- Reproduce a historical snapshot lacking the new policy metadata. Only this
-- synthetic fixture bypasses the write trigger; ordinary API callers cannot.
set local session_replication_role=replica;
update app_private.group_schedule_revisions set input_snapshot=input_snapshot-'maxGroupOverrunSeconds'-'dominantEndAt' where id=(select schedule from completion_fixtures where label='late');
set local session_replication_role=origin;
select is(app_private.schedule_latest_finale_arrival(schedule),'2026-10-31T21:20:00+01'::timestamptz,
 'historical metadata cannot bypass the same majority-based group ceiling') from completion_fixtures where label='late';
select is(app_private.try_reserve_finale(run,'2026-10-31T21:20:01+01','2026-10-31T21:00:00+01'),null::uuid,
 'live reservation also rejects excess overrun for a historical published snapshot') from completion_fixtures where label='late';
update app_private.group_schedule_revisions set input_snapshot=input_snapshot where id=(select schedule from completion_fixtures where label='late');
update completion_fixtures set reservation=app_private.try_reserve_finale(run,'2026-10-31T21:20:00+01','2026-10-31T21:00:00+01') where label='late';
select ok(reservation is not null,'live reservation at exact boundary succeeds after old strict target') from completion_fixtures where label='late';
select is(app_private.try_reserve_finale(run,'2026-10-31T21:20:00+01','2026-10-31T21:00:00+01'),reservation,'repeated live reservation returns the same reservation') from completion_fixtures where label='late';
select is((select count(*)::integer from app_private.portal_reservations r join completion_fixtures f on f.run=r.run_id where f.label='late' and r.kind='finale' and r.status in ('held','active')),1,'live retries keep exactly one physical reservation');
select is((select md5(to_jsonb(r)::text) from app_private.group_runs r join completion_fixtures f on f.run=r.id where label='late'),(select run_hash from completion_preserved),'reservation checking does not rewrite a started route');
select throws_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:10:00+01',null,'good','Begonnen route niet wijzigen via een nieuw concept') from completion_fixtures where label='late'$$,
 '23514','GROUP_ALREADY_STARTED','started group cannot be rewritten by a new schedule');
-- Both bulk entry points accept real overrun, retaining their existing receipts.
select pg_temp.completion_fixture('bulk-valid'),pg_temp.completion_fixture('new-valid');
create temp table completion_bulk_command as select gen_random_uuid()::text key,
 app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')) hash,
 jsonb_build_object('groups',jsonb_build_array(jsonb_build_object('key',gid,'startId',slot,'effectiveStopAt','2026-10-31T20:30:00+01','expectedFinaleArrivalAt','2026-10-31T21:05:00+01','preferenceMatch','good'))) payload,
 null::jsonb result from completion_fixtures where label='bulk-valid';
select lives_ok($$update completion_bulk_command set result=api.admin_group_operations_apply('duindorp-halloween-2026','distribute',hash,payload,key)$$,
 'bulk redistribution persists a valid fifteen-minute overrun');
select is(api.admin_group_operations_apply('duindorp-halloween-2026','distribute',hash,payload,key),result,'bulk overrun retry returns its existing receipt') from completion_bulk_command;
update app_private.group_registrations set superseded_at=clock_timestamp() where group_id=(select gid from completion_fixtures where label='new-valid');
create temp table completion_new_command as select gen_random_uuid()::text key,
 app_private.start_planning_input_hash((select id from app_private.events where slug='duindorp-halloween-2026')) hash,
 jsonb_build_object('groups',jsonb_build_array(jsonb_build_object('partyIds',jsonb_build_array(rid),'childCount',1,'startId',slot,
 'effectiveStopAt','2026-10-31T20:30:00+01','expectedFinaleArrivalAt','2026-10-31T20:54:00+01','preferenceMatch','good'))) payload,
 null::jsonb result from completion_fixtures where label='new-valid';
select lives_ok($$update completion_new_command set result=api.admin_apply_dynamic_plan('duindorp-halloween-2026',payload,hash,key,'server computes request hash')$$,
 'new-group bulk proposal persists a valid four-minute overrun');
select is(api.admin_apply_dynamic_plan('duindorp-halloween-2026',payload,hash,key,'server computes request hash'),result,'new-group overrun retry returns its receipt') from completion_new_command;
-- Same group draft/published/live alternatives count once; other groups count.
select lives_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:20:00+01',null,'good','Tweede fysieke groep naast gepubliceerde en live revisie') from completion_fixtures where label='other'$$,
 'published and live reservation of one group do not consume two places');
select throws_ok($$select api.admin_save_group_schedule(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:20:00+01',null,'good','Derde groep past niet in de echte finale capaciteit') from completion_fixtures where label='bulk'$$,
 '23514','FINALE_CAPACITY_EXCEEDED','another physical group still consumes finale capacity');
-- Explicit ordinary bounds stay hard despite the finale allowance.
select is((select effective_ordinary_stop_at from app_private.group_schedule_revisions s join completion_fixtures f on f.schedule=s.id where label='late'),
 '2026-10-31T20:30:00+01'::timestamptz,'finale allowance never extends ordinary closure');
select throws_ok($$select app_private.assert_group_schedule_timing(gid,slot,'2026-10-31T20:30:01+01','2026-10-31T21:10:00+01') from completion_fixtures where label='bulk'$$,
 '23514','GROUP_END_TIME_INFEASIBLE','ordinary visit beyond closure is rejected even during allowed overrun');
-- A newly published extended ordinary route is not cut off at the old wish.
update app_private.event_route_settings set global_ordinary_stop_at='2026-10-31T20:45:00+01',finale_planning_transfer_seconds=300,
 finale_max_concurrent_groups=4 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
select pg_temp.completion_fixture('live-soft','2026-10-31T20:30:00+01');
update completion_fixtures set schedule=(api.admin_save_group_schedule(gid,slot,'2026-10-31T20:40:00+01','2026-10-31T20:50:00+01',null,'good','Nieuwe gepubliceerde route mag na de oude eindwens gewone poorten bezoeken')->>'id')::uuid where label='live-soft';
select lives_ok($$select pg_temp.completion_publish('live-soft')$$,'new ordinary extension is explicitly published');
with inserted as(insert into app_private.group_runs(group_id,status,schedule_revision_id) select gid,'live',schedule from completion_fixtures where label='live-soft' returning id)
 update completion_fixtures set run=inserted.id from inserted where label='live-soft';
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select f.run,c.id,'present' from completion_fixtures f join app_private.registration_children c on c.registration_id=f.rid where label='live-soft';
select is(app_private.dispatch_next_stop(run,'2026-10-31T20:31:00+01')->>'decision','ordinary',
 'live dispatch after desired 20:30 still visits an ordinary gate under the published 20:40 cutoff') from completion_fixtures where label='live-soft';
select is((select effective_ordinary_stop_at from app_private.group_schedule_revisions s join completion_fixtures f on f.schedule=s.id where label='live-soft'),
 '2026-10-31T20:40:00+01'::timestamptz,'live dispatch retains the reviewed published ordinary cutoff');
-- No silently enlarged physical window, regardless of configured final window.
update app_private.portal_windows set closes_at='2026-10-31T21:19:59+01' where portal_id='12000000-0000-0000-0000-000000000030';
select throws_ok($$select app_private.assert_group_schedule_timing(gid,slot,'2026-10-31T20:30:00+01','2026-10-31T21:20:00+01') from completion_fixtures where label='bulk'$$,
 '23514','FINALE_PHYSICAL_WINDOW_CONFLICT','a shorter physical finale window is an explicit conflict');
select * from finish();
rollback;
