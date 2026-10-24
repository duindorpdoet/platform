begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table finale_test(event_id uuid,g1 uuid,g2 uuid,g3 uuid,g4 uuid,slot_id uuid,pub1 uuid,pub2 uuid,pub3 uuid,pub4 uuid,run1 uuid,run2 uuid,run3 uuid,res1 uuid,res2 uuid,res3 uuid);
insert into finale_test(event_id,g1,g2,g3,g4) select id,'23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002','23000000-0000-0000-0000-000000000003','23000000-0000-0000-0000-000000000004' from app_private.events where slug='duindorp-halloween-2026';
grant all on finale_test to authenticated;
update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours';
update app_private.start_slots set starts_at=now()-interval '1 minute';
update app_private.event_route_settings set first_start_at=now()-interval '2 hours',global_ordinary_stop_at=now()+interval '2 hours',
 allowed_personal_stop_times=array[now()+interval '1 hour'],ordinary_visit_seconds=60,route_buffer_seconds=0,
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=now()-interval '1 hour',finale_last_arrival_at=now()+interval '4 hours',
 finale_closes_at=now()+interval '5 hours',finale_show_seconds=60,finale_turnover_seconds=120,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic',
 finale_waiting_area='',finale_safe_approach='' where event_id=(select event_id from finale_test);
create function pg_temp.publish_finale(gid uuid,target timestamptz,slot uuid default null) returns uuid language plpgsql as $$
declare sid uuid; pub uuid;
begin
 update app_private.group_schedule_revisions set state='superseded' where group_id=gid and state='published';
 insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
  select g.id,coalesce((select max(revision) from app_private.group_schedule_revisions where group_id=g.id),0)+1,'published',coalesce(slot,g.start_slot_id),now()+interval '2 hours',target,'neutral',clock_timestamp()
  from app_private.walking_groups g where g.id=gid returning id into sid;
 update app_private.walking_groups set route_mode='dynamic',current_schedule_revision_id=sid,start_slot_id=coalesce(slot,start_slot_id),version=version+1 where id=gid;
 select id into pub from app_private.group_start_publications where schedule_id=sid;
 return pub;
end $$;
create function pg_temp.start_finale_group(gid uuid,key text) returns uuid language sql security invoker as $$
 select (api.run_start(gid,array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(gid)) v),
 (api.group_snapshot(gid)#>>'{group,version}')::integer,key,key)->>'runId')::uuid
$$;
grant execute on function pg_temp.start_finale_group(uuid,text) to authenticated;
create function pg_temp.token(sid uuid) returns text language sql security definer set search_path='' as $$
 select 'TEST-PORTAL-'||right(coalesce(s.portal_id,p.portal_id)::text,2)||'-TOKEN' from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=sid
$$;
grant execute on function pg_temp.token(uuid) to authenticated;
update app_private.walking_groups set desired_ordinary_visits=1 where id=(select g1 from finale_test);
update finale_test set pub1=pg_temp.publish_finale(g1,clock_timestamp()+interval '1 hour');
select is((select count(*)::integer from app_private.finale_publication_commitments c join finale_test t on t.pub1=c.publication_id),1,'publication creates one immutable finale commitment');
update finale_test set res1=(select id from app_private.portal_reservations where start_publication_id=pub1);
select is((select status::text from app_private.portal_reservations where id=(select res1 from finale_test)),'held','publication reserves actual reception capacity before departure');
select is((select safe_waiting_instruction from app_private.finale_publication_commitments where publication_id=(select pub1 from finale_test)),
 'Blijf bij jullie groep en vraag de organisatie waar jullie veilig kunnen wachten.','missing configured waiting place produces generic help, no invented place or address');
select throws_ok($$update app_private.finale_publication_commitments set reserved_arrival_at=reserved_arrival_at+interval '1 minute' where publication_id=(select pub1 from finale_test)$$,
 '55000','PUBLISHED_FINALE_IMMUTABLE','a published finale instant cannot be moved in place');
select throws_ok($$update app_private.portal_reservations set reserved_from=reserved_from+interval '1 minute' where id=(select res1 from finale_test)$$,
 '23514','FINAL_RESERVATION_SCOPE_CONFLICT','the reservation boundary also rejects silent rebooking');
select throws_ok($$update app_private.portal_reservations set start_publication_id=null where id=(select res1 from finale_test)$$,'23514','FINAL_RESERVATION_SCOPE_CONFLICT','a frozen reservation cannot lose its publication link');
select throws_ok($$insert into app_private.group_runs(group_id,start_publication_id,status) select g4,pub1,'ready' from finale_test$$,'23514','RUN_START_PUBLICATION_SCOPE_CONFLICT','run cannot bind another group publication');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update finale_test set run1=pg_temp.start_finale_group(g1,'finale-ordinary-start');
select is(api.group_snapshot((select g1 from finale_test))#>>'{run,currentStop,kind}','ordinary','a normal live route can still release a feasible ordinary house');
set local role postgres;
select is((select start_publication_id from app_private.group_runs where id=(select run1 from finale_test)),(select pub1 from finale_test),'run is bound to the exact frozen publication');
select is((select run_id from app_private.portal_reservations where id=(select res1 from finale_test)),(select run1 from finale_test),'runtime adopts the already-published reservation ID');
select throws_ok($$update app_private.group_runs set start_publication_id=null where id=(select run1 from finale_test)$$,'55000','RUN_START_PUBLICATION_IMMUTABLE','live run cannot silently release its frozen publication binding');
create temp table unchanged_finale as select to_jsonb(b) snapshot from app_private.portal_reservations b where id=(select res1 from finale_test);
grant select on unchanged_finale to authenticated;
select is(app_private.try_reserve_finale((select run1 from finale_test),clock_timestamp()+interval '10 minutes',clock_timestamp()),(select res1 from finale_test),'another feasible forecast retains the same finale ID');
select is(app_private.try_reserve_finale((select run1 from finale_test),clock_timestamp()+interval '20 minutes',clock_timestamp()),(select res1 from finale_test),'a second forecast does not rebook to another minute');
select is((select to_jsonb(b) from app_private.portal_reservations b where id=(select res1 from finale_test)),(select snapshot from unchanged_finale),'unchanged forecasts retain exact reservation content and revision');
select is(app_private.try_reserve_finale((select run1 from finale_test),clock_timestamp()+interval '2 hours',clock_timestamp()),null::uuid,'infeasible later ETA does not silently create a replacement appointment');
select is((select to_jsonb(b) from app_private.portal_reservations b where id=(select res1 from finale_test)),(select snapshot from unchanged_finale),'failed forecast preserves the original appointment');
create temp table arrival_command as select r.id run_id,r.current_stop_id stop_id,r.version,
 (select jsonb_object_agg(p.id::text,'skipped') from app_private.run_participants p where p.run_id=r.id and p.attendance='present') choices
 from app_private.group_runs r where r.id=(select run1 from finale_test);
grant all on arrival_command to authenticated;
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,pg_temp.token(stop_id),choices,'finale-ordinary-arrival') from arrival_command$$,'one actual inclusive ordinary arrival reaches the chosen visit limit');
select is(api.group_snapshot((select g1 from finale_test))#>>'{run,waitingReason}','finale_window','group waits for its own reserved finale departure time');
select is(api.group_snapshot((select g1 from finale_test))#>'{run,currentStop}','null'::jsonb,'no finale address is released during the wait');
select is(api.group_snapshot((select g1 from finale_test))#>>'{run,finaleReservation,id}',(select res1::text from finale_test),'participant projection uses the same reservation ID');
select is(api.group_snapshot((select g1 from finale_test))#>>'{run,reservedArrivalAt}',api.group_snapshot((select g1 from finale_test))#>>'{group,expectedFinaleArrivalAt}','route and group show the same fixed appointment');
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,pg_temp.token(stop_id),choices,'finale-ordinary-arrival') from arrival_command$$,'retry after completion returns the prior logical arrival');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run1 from finale_test)),1,'wait and receipt retry do not invent another arrival');
select ok((select (d.input_snapshot->>'waitingUntil')::timestamptz<c.reserved_arrival_at from app_private.dispatch_decisions d join app_private.finale_publication_commitments c on c.publication_id=(select pub1 from finale_test) where d.run_id=(select run1 from finale_test) order by sequence desc limit 1),'departure time uses the actual verified walk instead of a fixed offset');
create temp table waiting_count as select count(*) n from app_private.dispatch_decisions where run_id=(select run1 from finale_test);
select lives_ok($$select app_private.dispatch_next_stop((select run1 from finale_test),clock_timestamp(),true,null)$$,'timer can recheck an unchanged safe wait');
select is((select count(*) from app_private.dispatch_decisions where run_id=(select run1 from finale_test)),(select n from waiting_count),'unchanged wait does not append duplicate decisions on every tick');
select throws_ok($$select pg_temp.publish_finale((select g1 from finale_test),clock_timestamp()+interval '90 minutes')$$,
 '23514','JOURNEY_ALREADY_STARTED','a new publication cannot replace the appointment of an already-live run');

select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','participant cannot enumerate other groups through the finale-team projection');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select row->>'publicationId' from jsonb_array_elements(api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000030')->'arrivals') row where row->>'reservationId'=(select res1::text from finale_test)),(select pub1::text from finale_test),'finale team sees the same immutable publication and reservation as the participant');
select is((select (row->>'plannedArrivalAt')::timestamptz from jsonb_array_elements(api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000030')->'arrivals') row where row->>'reservationId'=(select res1::text from finale_test)),(select (snapshot->>'reserved_from')::timestamptz from unchanged_finale),'finale team sees the exact fixed arrival instant');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role postgres;

-- Dedicated synthetic short walking connection: real server time is used.
-- This is a database/API scenario and makes no physical route/camera claim.
create temp table short_walk(point_id uuid,node_id uuid,slot_id uuid);
insert into short_walk select gen_random_uuid(),gen_random_uuid(),gen_random_uuid();
insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at)
 select w.node_id,t.event_id,'finale-short-walk','start',point(4.27001,52.10),now() from short_walk w cross join finale_test t;
insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by,wheelchair_accessible)
 select t.event_id,w.node_id,n.id,20,20,now(),'f0000000-0000-0000-0000-000000000001',true from short_walk w cross join finale_test t join app_private.walking_nodes n on n.portal_id='12000000-0000-0000-0000-000000000030' and n.event_id=t.event_id;
insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,walking_node_id,accessible,max_gathering_groups,max_gathering_children,verified_at,verified_by)
 select w.point_id,t.event_id,'Synthetisch kort startpunt','ALLEEN TESTLOCATIE',52.10,4.27001,w.node_id,true,10,40,now(),'f0000000-0000-0000-0000-000000000001' from short_walk w cross join finale_test t;
insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,start_point_id)
 select w.slot_id,t.event_id,'finale-short-slot','Synthetische finaleproef','ALLEEN TESTLOCATIE','ALLEEN TESTLOCATIE',52.10,4.27001,now(),now()-interval '1 minute',10,40,w.point_id from short_walk w cross join finale_test t;
update finale_test set slot_id=(select slot_id from short_walk);
update finale_test set pub2=pg_temp.publish_finale(g2,clock_timestamp()+interval '10 seconds',slot_id);
update finale_test set res2=(select id from app_private.portal_reservations where start_publication_id=pub2);
set local role authenticated;
update finale_test set run2=pg_temp.start_finale_group(g2,'finale-short-start');
select is(api.group_snapshot((select g2 from finale_test))#>>'{run,currentStop,kind}','finale','verified walk releases the finale only when its departure is due');
select lives_ok($$select api.run_bulk_skip_pending((api.group_snapshot(g2)#>>'{run,id}')::uuid,(api.group_snapshot(g2)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g2)#>>'{run,version}')::integer,'Kinderen blijven voor deze finale buiten','finale-unscanned-skip','finale-unscanned-skip') from finale_test$$,'outside choices can be prepared without inventing an arrival');
select throws_ok($$select api.run_complete_stop((api.group_snapshot(g2)#>>'{run,id}')::uuid,(api.group_snapshot(g2)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g2)#>>'{run,version}')::integer,true,'finale-without-scan','finale-without-scan') from finale_test$$,'23514','SCAN_REQUIRED','even an all-outside finale cannot finish without an accepted real scan');

select throws_ok($$select api.run_scan((api.group_snapshot(g2)#>>'{run,id}')::uuid,(api.group_snapshot(g2)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g2)#>>'{run,version}')::integer,'TEST-30','short_code') from finale_test$$,
 '23514','FINAL_ARRIVAL_TOO_EARLY','direct scan cannot admit the group before its reserved instant');
select throws_ok($$select api.run_arrive_and_advance((api.group_snapshot(g2)#>>'{run,id}')::uuid,(api.group_snapshot(g2)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g2)#>>'{run,version}')::integer,'TEST-PORTAL-30-TOKEN',
 (select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(g2)#>'{run,participants}') p),'finale-too-early-compound') from finale_test$$,
 '23514','FINAL_ARRIVAL_TOO_EARLY','compound arrival uses the same early-admission boundary');
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id where s.run_id=(select run2 from finale_test)),0,'early attempts leave no scan evidence');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run2 from finale_test)),0,'early attempts leave no fictional arrivals or seals');
select pg_sleep(greatest(0,extract(epoch from ((select reserved_arrival_at from app_private.finale_publication_commitments where publication_id=(select pub2 from finale_test))+interval '100 milliseconds'-clock_timestamp()))));
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance((api.group_snapshot(g2)#>>'{run,id}')::uuid,(api.group_snapshot(g2)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g2)#>>'{run,version}')::integer,'TEST-PORTAL-30-TOKEN',
 (select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(g2)#>'{run,participants}') p),'finale-valid-compound') from finale_test$$,
 'real server time admits a genuine arrival at the reserved instant');
select is(api.group_snapshot((select g2 from finale_test))#>>'{run,status}','completed','inclusive final arrival completes the journey');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run2 from finale_test)),5,'all five present children receive their actual finale arrival including outside children');
select is((select id from app_private.portal_reservations where run_id=(select run2 from finale_test) and kind='finale'),(select res2 from finale_test),'release, scan and completion keep one reservation ID');

-- Reconstruct a previously released delayed group, without changing server time
-- or the immutable appointment, then call the real public admission commands.
update finale_test set pub3=pg_temp.publish_finale(g3,clock_timestamp()-interval '3 minutes',slot_id);
update finale_test set res3=(select id from app_private.portal_reservations where start_publication_id=pub3);
with inserted as (insert into app_private.group_runs(group_id,schedule_revision_id,start_publication_id,status,started_at)
 select t.g3,p.schedule_id,p.id,'live',now()-interval '5 minutes' from finale_test t join app_private.group_start_publications p on p.id=t.pub3 returning id)
 update finale_test set run3=inserted.id from inserted;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select t.run3,rc.id,'present' from finale_test t join app_private.group_registrations a on a.group_id=t.g3 and a.superseded_at is null join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active';
update app_private.portal_reservations b set run_id=t.run3,status='active' from finale_test t where b.id=t.res3;
with inserted as (insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
 select t.run3,'12000000-0000-0000-0000-000000000030',t.res3,'finale',1,'active',c.reserved_arrival_at-interval '20 seconds' from finale_test t join app_private.finale_publication_commitments c on c.publication_id=t.pub3 returning id,run_id)
 update app_private.group_runs r set current_stop_id=inserted.id from inserted where r.id=inserted.run_id;
insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id)
 select r.current_stop_id,p.id from finale_test t join app_private.group_runs r on r.id=t.run3 join app_private.run_participants p on p.run_id=r.id;
set local role authenticated;
select throws_ok($$select api.run_scan((api.group_snapshot(g3)#>>'{run,id}')::uuid,(api.group_snapshot(g3)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g3)#>>'{run,version}')::integer,'TEST-30','short_code') from finale_test$$,
 '23514','FINAL_RESERVATION_MISSED','direct late scan requires organization review instead of rebooking');
select throws_ok($$select api.run_arrive_and_advance((api.group_snapshot(g3)#>>'{run,id}')::uuid,(api.group_snapshot(g3)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g3)#>>'{run,version}')::integer,'TEST-PORTAL-30-TOKEN',
 (select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(g3)#>'{run,participants}') p),'finale-too-late-compound') from finale_test$$,
 '23514','FINAL_RESERVATION_MISSED','compound late arrival uses the same fixed grace boundary');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run3 from finale_test)),0,'missed appointment awards no fictional arrivals');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.admin_redirect_group(run3,'finale',null,(api.group_snapshot(g3)#>>'{run,version}')::integer,'Organisatie controleert de gemiste finale-afspraak') from finale_test$$,
 '23514','FINAL_RESERVATION_MISSED','manual redirection cannot bypass the same missed-reservation boundary');
set local role postgres;
select is((select count(*)::integer from app_private.portal_reservations where run_id=(select run3 from finale_test) and kind='finale'),1,'late attempts do not silently create a second reservation');
select is((select current_stop_id is not null from app_private.group_runs where id=(select run3 from finale_test)),true,'failed manual command preserves the already-released destination');
-- Prior server-accepted scan evidence remains valid for a delayed completion.
insert into app_private.scan_evidence(run_stop_id,credential_id,credential_version,actor_id,validation_method,scanned_at)
 select r.current_stop_id,cr.id,cr.version,'c0000000-0000-0000-0000-000000000001','qr',c.reserved_arrival_at+interval '10 seconds'
 from finale_test t join app_private.group_runs r on r.id=t.run3 join app_private.finale_publication_commitments c on c.publication_id=t.pub3
 join app_private.portal_credentials cr on cr.portal_id=c.portal_id and cr.revoked_at is null;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.run_scan((api.group_snapshot(g3)#>>'{run,id}')::uuid,(api.group_snapshot(g3)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g3)#>>'{run,version}')::integer,'TEST-30','short_code') from finale_test$$,
 'a prior accepted scan remains valid when its response/completion is delayed');
select lives_ok($$select api.run_arrive_and_advance((api.group_snapshot(g3)#>>'{run,id}')::uuid,(api.group_snapshot(g3)#>>'{run,currentStop,id}')::uuid,(api.group_snapshot(g3)#>>'{run,version}')::integer,'TEST-PORTAL-30-TOKEN',
 (select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(g3)#>'{run,participants}') p),'finale-delayed-finish') from finale_test$$,
 'delayed completion preserves valid admission and inclusive participant accounting');
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id where s.run_id=(select run3 from finale_test)),1,'retry of prior scan remains one logical scan');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run3 from finale_test)),7,'delayed valid completion retains all seven actual arrivals');
select is((select count(*)::integer from app_private.portal_reservations where run_id=(select run3 from finale_test) and status in ('held','active')),0,'completed finale releases its reception claim');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.admin_safe_withdraw_group(run1,'a0000000-0000-0000-0000-000000000001',(api.group_snapshot(g1)#>>'{run,version}')::integer,'Organisatie meldt de wachtende groep met de eigen ouder veilig af') from finale_test$$,'safe departure releases the held fixed appointment');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000030')->>'forecastGroups','0','stopped/completed commitments do not reappear as phantom forecasts');
select is(api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000030')->>'assignedGroups','0','no active house-team appointment remains after controlled departures and completions');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run1 from finale_test)),1,'departure retains the earlier actual ordinary arrival');

update finale_test set pub4=pg_temp.publish_finale(g4,clock_timestamp()+interval '2 hours');
create temp table old_finale_revision as select c.*,b.id reservation_id from app_private.finale_publication_commitments c join app_private.portal_reservations b on b.start_publication_id=c.publication_id where c.publication_id=(select pub4 from finale_test);
update finale_test set pub4=pg_temp.publish_finale(g4,clock_timestamp()+interval '150 minutes');
select is((select status::text from app_private.portal_reservations where id=(select reservation_id from old_finale_revision)),'cancelled','explicit new publication supersedes only the unused old booking');
select is((select reserved_arrival_at from app_private.finale_publication_commitments where publication_id=(select publication_id from old_finale_revision)),(select reserved_arrival_at from old_finale_revision),'previous published finale instant remains in immutable history');
select is((select count(*)::integer from app_private.portal_reservations b join finale_test t on b.group_id=t.g4 where b.status in ('held','active')),1,'new publication leaves one current unused appointment');
select ok(not has_table_privilege('authenticated','app_private.finale_publication_commitments','select'),'participant cannot enumerate private future commitments');
select ok(not has_function_privilege('authenticated','app_private.ensure_finale_commitment(uuid)','execute'),'private publisher helper is not a public bypass');
select ok(not has_function_privilege('anon','app_private.run_finale_details(uuid,timestamptz)','execute'),'anonymous caller cannot enumerate a future finale destination');
select * from finish();
rollback;
