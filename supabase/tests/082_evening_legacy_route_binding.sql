begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table legacy_test(event_id uuid,group_id uuid,run_id uuid,stop_id uuid,version integer,first_id uuid,second_id uuid,booking jsonb,proof jsonb,publication_id uuid,finale_booking jsonb,plan_stops uuid[],portal_version integer,safe_departure jsonb);
insert into legacy_test(event_id,group_id) select event_id,id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001';
grant all on legacy_test to authenticated;
create function pg_temp.legacy_start(gid uuid,key text) returns uuid language sql security invoker as $$
 select (api.run_start(gid,array(select (p->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(gid)) p),(api.group_snapshot(gid)#>>'{group,version}')::integer,key,key)->>'runId')::uuid
$$;
grant execute on function pg_temp.legacy_start(uuid,text) to authenticated;
-- An old publication without an actual finale appointment cannot start a new run.
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
 select p.event_id,p.group_id,'legacy-without-finale:'||p.id,p.revision,clock_timestamp()-interval '1 minute',clock_timestamp(),p.point_snapshot,p.slot_snapshot from app_private.group_start_publications p where p.group_id='23000000-0000-0000-0000-000000000003' order by publication_order desc limit 1;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select pg_temp.legacy_start('23000000-0000-0000-0000-000000000003','legacy-missing-appointment')$$,'23514','FINAL_RESERVATION_REQUIRED','old departure without finale commitment requests an explicit valid publication');
update legacy_test set run_id=pg_temp.legacy_start(group_id,'legacy-bound-start');
update legacy_test set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select is(api.group_snapshot((select group_id from legacy_test))#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000001','legacy run releases a currently feasible physical house');
set local role postgres;
select is((select count(*)::integer from app_private.group_runs where group_id='23000000-0000-0000-0000-000000000003'),0,'rejected start creates no half-started run');
update legacy_test t set first_id=stop_id,publication_id=(select start_publication_id from app_private.group_runs where id=t.run_id),plan_stops=(select array_agg(plan_stop_id order by plan_stop_id) from app_private.run_stops where run_id=t.run_id);
update legacy_test t set finale_booking=(select to_jsonb(b) from app_private.portal_reservations b where b.start_publication_id=t.publication_id);
select is((select count(*)::integer from app_private.portal_reservations where bound_stop_id=(select stop_id from legacy_test) and kind='ordinary' and status='active'),1,'legacy instruction has one automatic actual capacity binding');
select ok((select plan_stop_id is not null and portal_id is null and reservation_id is null and stop_kind='ordinary' from app_private.run_stops where id=(select stop_id from legacy_test)),'binding preserves the original legacy representation and plan FK');
select ok((select reserved_from<clock_timestamp()+interval '5 minutes' from app_private.portal_reservations where bound_stop_id=(select stop_id from legacy_test)),'bound legacy ETA uses actual now instead of the old October 31 plan time');
update app_private.portals set operation_status='closed' where id='12000000-0000-0000-0000-000000000002';
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'legacy-first-real-arrival') from legacy_test$$,'real old-ID arrival continues through the shared actual route assessment');
select is(api.group_snapshot((select group_id from legacy_test))#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000003','new continuation excludes a house closed since the old plan');
update legacy_test set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
set local role postgres;
update legacy_test set second_id=stop_id;
select is((select ps.portal_id from app_private.run_stops rs join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=(select stop_id from legacy_test)),'12000000-0000-0000-0000-000000000003'::uuid,'replacement reuses the same physical legacy stop rather than replacing its FK');
select is((select array_agg(plan_stop_id order by plan_stop_id) from app_private.run_stops where run_id=(select run_id from legacy_test)),(select plan_stops from legacy_test),'future release preserves every original legacy plan-stop ID');
update app_private.portal_reservations set created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 minute' where bound_stop_id=(select stop_id from legacy_test);
update legacy_test t set booking=(select to_jsonb(b) from app_private.portal_reservations b where b.bound_stop_id=t.stop_id);
set local role service_role;
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'worker evaluates old bound reservations');
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'repeated evaluation remains stable');
set local role authenticated;
select is(api.group_snapshot((select group_id from legacy_test))#>>'{run,currentStop,id}',(select stop_id::text from legacy_test),'expiry preserves the pending stop ID');
select is((api.group_snapshot((select group_id from legacy_test))#>>'{run,version}')::integer,(select version from legacy_test),'timer does not stale the pending arrival version');
select ok((api.group_snapshot((select group_id from legacy_test))#>>'{run,currentDestinationNeedsReview}')::boolean,'parent receives explicit organization-review status');
set local role postgres;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.bound_stop_id=(select stop_id from legacy_test)),(select booking from legacy_test),'timer leaves exact current capacity claim intact');
select is((select count(*)::integer from app_private.route_alerts where run_id=(select run_id from legacy_test) and code='CURRENT_DESTINATION_REVIEW_REQUIRED' and status='open'),1,'repeat worker creates one actionable review alert');
set local role authenticated;
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-03-TOKEN','qr') from legacy_test$$,'pending arrival can still validate at the unchanged released house');
set local role postgres;
update legacy_test t set proof=(select to_jsonb(e) from app_private.scan_evidence e where e.run_stop_id=t.stop_id);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_rotate_credential('12000000-0000-0000-0000-000000000003',1,'Postercode wijzigen nadat de echte aankomst al geldig is bevestigd')$$,'real managing owner rotates the code after valid admission');
set local role postgres;
update legacy_test set portal_version=(select version from app_private.portals where id='12000000-0000-0000-0000-000000000003');
set local role authenticated;
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000003','closed',portal_version,'Poort sluit nadat deze groep al geldig is aangekomen') from legacy_test$$,'owner can close the house to new groups after this accepted arrival');
set local role postgres;
select ok((app_private.start_ops_route_preview((select group_id from legacy_test))->>'feasible')::boolean,'closed already-accepted house does not falsely block a valid remaining route');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-03-TOKEN','qr') from legacy_test$$,'accepted original scan remains valid after later closure and rotation');
select throws_ok($$select api.run_system_skip(run_id,stop_id,version,'Een echte aankomst mag geen systeemoverslag worden','legacy-do-not-erase-arrival','legacy-do-not-erase-arrival') from legacy_test$$,'23514','VISIT_ALREADY_RECORDED','outside choices cannot erase an already accepted arrival');
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-03-TOKEN',(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'legacy-accepted-arrival-after-close') from legacy_test$$,'accepted original command completes all outside children after closure and rotation');
select ok(not (api.group_snapshot((select group_id from legacy_test))#>>'{run,currentDestinationNeedsReview}')::boolean,'resolved earlier instruction does not leave a false alert on the next house');
set local role postgres;
select is((select to_jsonb(e) from app_private.scan_evidence e where e.run_stop_id=(select second_id from legacy_test)),(select proof from legacy_test),'original scan ID, credential revision and acceptance time remain exact');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from legacy_test)),2,'both genuine outside arrivals are preserved');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from legacy_test)),2,'both genuine outside arrivals retain their inclusive seals');
set local role authenticated;
update legacy_test set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_redirect_group(run_id,'ordinary','12000000-0000-0000-0000-000000000005',version,'Organisatie kiest een actuele vervanger voor de oudere route') from legacy_test$$,'authorized actual redirect also supports the legacy route');
set local role postgres;
select is((select ps.portal_id from app_private.group_runs r join app_private.run_stops s on s.id=r.current_stop_id join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where r.id=(select run_id from legacy_test)),'12000000-0000-0000-0000-000000000005'::uuid,'manual old-route replacement preserves physical identity and original plan FK');
set local role authenticated;
update legacy_test set version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select lives_ok($$select api.admin_redirect_group(run_id,'finale',null,version,'Organisatie kiest bewust de bestaande vaste finale-afspraak') from legacy_test$$,'legacy route can wait for its own unchanged fixed finale');
select is(api.group_snapshot((select group_id from legacy_test))#>>'{run,waitingReason}','finale_window','legacy wait uses the same fixed appointment contract');
set local role postgres;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.start_publication_id=(select publication_id from legacy_test)),(select finale_booking from legacy_test),'legacy replan and manual choices retain exact fixed finale identity and instant');
select ok(not has_table_privilege('authenticated','app_private.evening_isolated_rehearsals','insert'),'participants cannot forge the isolated rehearsal scope');
set local role authenticated;
update legacy_test set version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
update legacy_test set safe_departure=api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000001',version,'Organisatie spreekt de geregistreerde ouder en meldt de groep veilig af');
select is((select api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000001',version,'Organisatie spreekt de geregistreerde ouder en meldt de groep veilig af') from legacy_test),(select safe_departure from legacy_test),'lost-response safe-withdrawal retry returns its committed original result');
set local role postgres;
select is((select count(*)::integer from app_private.group_safe_departures where run_id=(select run_id from legacy_test)),1,'safe-withdrawal retry records one actual responsible adult');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from legacy_test)),2,'idempotent departure preserves both true historical arrivals');

-- A legacy finale stop keeps its original plan FK and uses a real due instant.
create temp table legacy_finale(group_id uuid,point_id uuid,slot_id uuid,plan_id uuid,plan_stop_id uuid,target timestamptz,run_id uuid,stop_id uuid,reservation_id uuid);
insert into legacy_finale(group_id,point_id,slot_id,plan_id,plan_stop_id,target) values('23000000-0000-0000-0000-000000000002',extensions.gen_random_uuid(),extensions.gen_random_uuid(),extensions.gen_random_uuid(),extensions.gen_random_uuid(),clock_timestamp()+interval '6 seconds');
grant all on legacy_finale to authenticated;
insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,walking_node_id,verified_at,verified_by,max_gathering_groups,max_gathering_children,active)
 select f.point_id,t.event_id,'Expliciet fictief finale-startpunt','Fictief finaleplein',n.coordinate[1]::numeric,n.coordinate[0]::numeric,n.id,clock_timestamp(),'f0000000-0000-0000-0000-000000000001',10,40,true from legacy_finale f cross join legacy_test t join app_private.walking_nodes n on n.portal_id='12000000-0000-0000-0000-000000000030';
insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,active,start_point_id)
 select f.slot_id,t.event_id,'legacy-final-only:'||f.slot_id,'Fictieve finale-afspraak','Fictief finaleplein',p.private_address,p.latitude,p.longitude,clock_timestamp(),clock_timestamp()-interval '1 minute',10,40,true,f.point_id from legacy_finale f cross join legacy_test t join app_private.start_points p on p.id=f.point_id;
update app_private.walking_groups set start_slot_id=(select slot_id from legacy_finale) where id=(select group_id from legacy_finale);
insert into app_private.route_plan_versions(id,group_id,revision,state,generated_by,input_hash)
 select plan_id,group_id,coalesce((select max(revision) from app_private.route_plan_versions where group_id=f.group_id),0)+1,'draft','f0000000-0000-0000-0000-000000000001','explicit-legacy-finale-fixture' from legacy_finale f;
insert into app_private.route_plan_stops(id,plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at)
 select f.plan_stop_id,f.plan_id,1,'12000000-0000-0000-0000-000000000030',f.target,f.target+make_interval(mins=>(select visit_minutes from app_private.portal_windows where portal_id='12000000-0000-0000-0000-000000000030' and f.target>=opens_at and f.target<closes_at order by opens_at limit 1)) from legacy_finale f;
update app_private.route_plan_versions set state='published',published_at=clock_timestamp() where id=(select plan_id from legacy_finale);
update app_private.group_schedule_revisions set state='superseded' where group_id=(select group_id from legacy_finale) and state='published';
with published as(insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
 select group_id,coalesce((select max(revision) from app_private.group_schedule_revisions where group_id=f.group_id),0)+1,'published',slot_id,clock_timestamp()+interval '3 hours',target,'neutral',clock_timestamp() from legacy_finale f returning id,group_id)
 update app_private.walking_groups g set current_schedule_revision_id=p.id from published p where g.id=p.group_id;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update legacy_finale set run_id=pg_temp.legacy_start(group_id,'legacy-real-clock-finale');
select is(api.group_snapshot((select group_id from legacy_finale))#>>'{run,waitingReason}','finale_window','legacy finale does not reveal an early destination');
set local role postgres;
update legacy_finale f set stop_id=(select id from app_private.run_stops where run_id=f.run_id and plan_stop_id=f.plan_stop_id),reservation_id=(select id from app_private.portal_reservations where run_id=f.run_id and kind='finale');
select pg_sleep(7);
set local role service_role;
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'trusted worker releases a truly due legacy finale');
set local role authenticated;
select is(api.group_snapshot((select group_id from legacy_finale))#>>'{run,currentStop,id}',(select stop_id::text from legacy_finale),'due finale retains the existing legacy stop ID');
select is(api.group_snapshot((select group_id from legacy_finale))#>>'{run,currentStop,kind}','finale','legacy-bound finale is identified consistently to the parent');
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,(api.group_snapshot(group_id)#>>'{run,version}')::integer,'TEST-PORTAL-30-TOKEN',(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'legacy-real-finale-arrival') from legacy_finale$$,'real-clock legacy-bound finale admits and completes outside children');
select is(api.group_snapshot((select group_id from legacy_finale))#>>'{run,status}','completed','actual legacy finale completion ends the run');
set local role postgres;
select is((select plan_stop_id from app_private.run_stops where id=(select stop_id from legacy_finale)),(select plan_stop_id from legacy_finale),'finale completion retains its original plan-stop FK');
select is((select status::text from app_private.portal_reservations where id=(select reservation_id from legacy_finale)),'completed','completion releases the bound fixed finale claim');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from legacy_finale) and finale),5,'all five present outside children receive exactly one legacy finale seal');
-- Simulate a genuinely pre-existing active legacy instruction lacking a finale.
-- New run_start rejects this state above, but valid old progress must survive.
create temp table old_progress(group_id uuid,publication_id uuid,run_id uuid,stop_id uuid,participant_id uuid);
insert into old_progress values('23000000-0000-0000-0000-000000000004',null,extensions.gen_random_uuid(),extensions.gen_random_uuid(),extensions.gen_random_uuid());
grant all on old_progress to authenticated;
with old_publication as(insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
 select p.event_id,p.group_id,'known-old-active:'||p.id,p.revision,clock_timestamp()-interval '1 hour',clock_timestamp()-interval '20 minutes',p.point_snapshot,p.slot_snapshot from app_private.group_start_publications p where p.group_id=(select group_id from old_progress) order by p.publication_order desc limit 1 returning id)
 update old_progress set publication_id=old_publication.id from old_publication;
insert into app_private.group_runs(id,group_id,active_plan_version_id,status,started_at,start_publication_id)
 select f.run_id,f.group_id,(select id from app_private.route_plan_versions where group_id=f.group_id and state='published' order by revision desc limit 1),'live',clock_timestamp()-interval '10 minutes',f.publication_id from old_progress f;
insert into app_private.run_participants(id,run_id,registration_child_id,attendance)
 select f.participant_id,f.run_id,(select rc.id from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id and a.superseded_at is null where a.group_id=f.group_id and rc.participation_status='active' order by rc.id limit 1),'present' from old_progress f;
insert into app_private.run_stops(id,run_id,plan_stop_id,sequence,state,opened_at)
 select f.stop_id,f.run_id,(select ps.id from app_private.route_plan_stops ps join app_private.group_runs r on r.active_plan_version_id=ps.plan_version_id where r.id=f.run_id and ps.position=1),1,'active',clock_timestamp()-interval '5 minutes' from old_progress f;
insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id) select stop_id,participant_id from old_progress;
update app_private.group_runs set current_stop_id=(select stop_id from old_progress),version=version+1 where id=(select run_id from old_progress);
update app_private.walking_groups set status='live' where id=(select group_id from old_progress);
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,(api.group_snapshot(group_id)#>>'{run,version}')::integer,'TEST-PORTAL-01-TOKEN',jsonb_build_object(participant_id::text,'skipped'),'legacy-old-progress-retained') from old_progress$$,'already active old instruction can record its actual arrival without inventing a finale');
select is(api.group_snapshot((select group_id from old_progress))#>>'{run,status}','paused','missing old finale pauses only further assignment');
select is(api.group_snapshot((select group_id from old_progress))#>>'{run,planningConflict}','FINAL_RESERVATION_REQUIRED','old missing commitment has a specific controlled help state');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from old_progress)),1,'original pending old arrival survives the blocked continuation');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from old_progress)),1,'original present outside child retains its real seal');

select * from finish();
rollback;
