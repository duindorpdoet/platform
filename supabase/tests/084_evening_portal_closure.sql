begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table closure_test(group_id uuid,run_id uuid,stop_id uuid,version integer,legacy boolean,original_stop jsonb,original_booking jsonb,finale_booking jsonb,portal_version integer);
insert into closure_test(group_id,legacy) values('23000000-0000-0000-0000-000000000001',false),('23000000-0000-0000-0000-000000000002',true);
grant all on closure_test to authenticated;
update app_private.walking_groups set route_mode=case when id='23000000-0000-0000-0000-000000000001' then 'dynamic' else 'legacy' end,desired_ordinary_visits=2 where id in(select group_id from closure_test);
create function pg_temp.closure_start(gid uuid) returns uuid language sql security invoker as $$
 select (api.run_start(gid,array(select (p->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(gid)) p),(api.group_snapshot(gid)#>>'{group,version}')::integer,'closure-start-'||gid,'closure-start-'||gid)->>'runId')::uuid
$$;
create function pg_temp.closure_arrive(rid uuid,sid uuid,ver integer,code text,gid uuid,key text) returns jsonb language sql security invoker as $$
 select api.run_arrive_and_advance(rid,sid,ver,code,(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(gid)#>'{run,participants}') p),key)
$$;
grant execute on function pg_temp.closure_start(uuid),pg_temp.closure_arrive(uuid,uuid,integer,text,uuid,text) to authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update closure_test set run_id=pg_temp.closure_start(group_id);
update closure_test set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
set local role postgres;
update closure_test t set original_stop=(select to_jsonb(s) from app_private.run_stops s where s.id=t.stop_id),original_booking=(select to_jsonb(b) from app_private.portal_reservations b where b.id=(select reservation_id from app_private.run_stops where id=t.stop_id) or b.bound_stop_id=t.stop_id),finale_booking=(select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='finale');
select is((select count(*)::integer from app_private.group_runs where id in(select run_id from closure_test)),2,'dynamic and legacy routes both have real issued destinations');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','closed',null,'Een ontbrekende verwachte poortversie is geen geldige keuze')$$,'40001','STALE_VERSION','null cannot bypass the actual portal version');
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','closed',1,'Bewoner sluit terwijl twee echte aankomstschermen nog openstaan')$$,'actual managing owner closes the currently issued ordinary house');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.group_snapshot(group_id)#>>'{run,currentStop,id}',stop_id::text,'closure retains the original pending stop ID') from closure_test order by legacy;
select is((api.group_snapshot(group_id)#>>'{run,version}')::integer,version,'closure retains the original pending arrival version') from closure_test order by legacy;
select ok((api.group_snapshot(group_id)#>>'{run,currentDestinationNeedsReview}')::boolean,'parent sees explicit current-instruction review status') from closure_test order by legacy;
set local role postgres;
select is((select to_jsonb(s) from app_private.run_stops s where s.id=t.stop_id),t.original_stop,'closure keeps the entire issued stop and old FK exact') from closure_test t order by legacy;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.id=(select reservation_id from app_private.run_stops where id=t.stop_id) or b.bound_stop_id=t.stop_id),t.original_booking,'closure keeps the exact physical capacity claim') from closure_test t order by legacy;
select is((select count(*)::integer from app_private.route_alerts where code='CURRENT_DESTINATION_REVIEW_REQUIRED' and status='open' and run_id in(select run_id from closure_test)),2,'both representation types receive one scoped actionable alert');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',group_id,'closed-current-'||group_id) from closure_test where not legacy$$,'P0001','PORTAL_UNAVAILABLE','closed unaccepted dynamic arrival is rejected without replacing its command');
select throws_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',group_id,'closed-current-'||group_id) from closure_test where legacy$$,'P0001','PORTAL_UNAVAILABLE','closed unaccepted legacy arrival is rejected without replacing its command');
set local role postgres;
select is((select count(*)::integer from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id where s.run_id in(select run_id from closure_test)),0,'closure creates no scan evidence');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id in(select run_id from closure_test)),0,'rejected pending arrivals create no false arrival');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','open',2,null)$$,'same owner can reopen the actual house');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',group_id,'closed-current-'||group_id) from closure_test$$,'the same original pending commands can complete after reopening');
select is(api.group_snapshot(group_id)#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000002','both route types continue at the actual next house') from closure_test order by legacy;
select ok(not (api.group_snapshot(group_id)#>>'{run,currentDestinationNeedsReview}')::boolean,'completion resolves the old instruction-specific alert') from closure_test order by legacy;
update closure_test set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-02-TOKEN','qr') from closure_test where not legacy$$,'one actual ordinary arrival is accepted before a later finale closure');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000030','closed',1,'Laatste poort sluit terwijl gewone aankomsten nog worden afgerond')$$,'closing the finale raises an event-wide safety status');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((api.group_snapshot(group_id)#>>'{run,version}')::integer,version,'finale closure does not invalidate an issued current ordinary arrival') from closure_test order by legacy;
select is(api.group_snapshot(group_id)#>>'{run,currentStop,id}',stop_id::text,'finale closure retains each current ordinary stop') from closure_test order by legacy;
set local role postgres;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='finale'),t.finale_booking,'venue closure retains the exact bound fixed finale reservation') from closure_test t order by legacy;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-02-TOKEN',group_id,'finale-closed-ordinary-'||group_id) from closure_test$$,'actual ordinary arrivals survive an unavailable future finale');
select is(api.group_snapshot(group_id)#>>'{run,status}','paused','only further assignment pauses after retaining the actual ordinary arrival') from closure_test order by legacy;
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=t.run_id),case when t.legacy then 10 else 2 end,'all real outside arrivals are retained through the future finale conflict') from closure_test t order by legacy;
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=t.run_id),case when t.legacy then 10 else 2 end,'all present outside children keep the corresponding genuine seals') from closure_test t order by legacy;
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000030','open',2,null)$$,'reopening the same venue restores availability without replacing appointments');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.run_set_state(run_id,'live',(api.group_snapshot(group_id)#>>'{run,version}')::integer,'Organisatie heeft de heropende finale bevestigd') from closure_test$$,'leaders resume their actual safely paused runs');
set local role service_role;
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'trusted worker resumes only the original fixed wait');
set local role authenticated;
select is(api.group_snapshot(group_id)#>>'{run,waitingReason}','finale_window','resumed groups wait for their unchanged own appointment') from closure_test order by legacy;
set local role postgres;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='finale'),t.finale_booking,'reopening and resuming keep every reservation field exact') from closure_test t order by legacy;
-- Both final instructions use an actually due server instant. The synthetic
-- start point is the finale's already verified node; no browser clock override.
create temp table due_closure(group_id uuid,run_id uuid,stop_id uuid,version integer,accepted boolean,reservation jsonb,proof jsonb);
insert into due_closure(group_id,accepted) values('23000000-0000-0000-0000-000000000003',true),('23000000-0000-0000-0000-000000000004',false);
grant all on due_closure to authenticated;
create temp table due_place(point_id uuid,slot_id uuid,target timestamptz,portal_version integer);
insert into due_place values(extensions.gen_random_uuid(),extensions.gen_random_uuid(),clock_timestamp()+interval '6 seconds',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000030'));
grant all on due_place to authenticated;
insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,walking_node_id,max_gathering_groups,max_gathering_children,verified_at,verified_by)
 select x.point_id,p.event_id,'FICTIEF STARTPUNT VOOR SLUITINGSPROEF','GEEN ECHT BEZOEKADRES',n.coordinate[1]::numeric,n.coordinate[0]::numeric,n.id,10,40,clock_timestamp(),'f0000000-0000-0000-0000-000000000001'
 from due_place x cross join app_private.portals p join app_private.walking_nodes n on n.portal_id=p.id where p.id='12000000-0000-0000-0000-000000000030';
insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,start_point_id)
 select x.slot_id,p.event_id,'due-closure-'||x.slot_id,'Fictieve sluitingsproef','Fictieve proefplek',p.private_address,p.latitude,p.longitude,clock_timestamp(),clock_timestamp()-interval '1 minute',10,40,p.id from due_place x join app_private.start_points p on p.id=x.point_id;
update app_private.walking_groups set start_slot_id=(select slot_id from due_place),route_mode='dynamic',desired_ordinary_visits=1 where id in(select group_id from due_closure);
update app_private.group_schedule_revisions set state='superseded' where group_id in(select group_id from due_closure) and state='published';
with published as(insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
 select t.group_id,coalesce((select max(revision) from app_private.group_schedule_revisions where group_id=t.group_id),0)+1,'published',x.slot_id,clock_timestamp()+interval '2 hours',x.target,'neutral',clock_timestamp() from due_closure t cross join due_place x returning id,group_id)
 update app_private.walking_groups g set current_schedule_revision_id=p.id from published p where g.id=p.group_id;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update due_closure set run_id=pg_temp.closure_start(group_id);
select is(api.group_snapshot(group_id)#>>'{run,waitingReason}','finale_window','short real-clock fixture waits for its fixed appointment') from due_closure order by accepted;
set local role postgres;
select pg_sleep(7);
set local role service_role;
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'actual server clock makes both short finale appointments due');
set local role authenticated;
update due_closure set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select is(api.group_snapshot(group_id)#>>'{run,currentStop,kind}','finale','actually due instruction is a real reserved finale') from due_closure order by accepted;
select lives_ok($$select api.run_scan(run_id,stop_id,version,'TEST-PORTAL-30-TOKEN','qr') from due_closure where accepted$$,'one finale group is actually admitted before venue closure');
set local role postgres;
update due_closure t set proof=(select to_jsonb(e) from app_private.scan_evidence e where e.run_stop_id=t.stop_id),reservation=(select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='finale');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000030','closed',portal_version,'Laatste poort sluit na een echte toelating en vóór een andere bevestiging') from due_place$$,'owner closes a finale with both admitted and pending groups');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.group_snapshot(group_id)#>>'{run,currentStop,id}',stop_id::text,'venue closure retains both actually issued finale instruction IDs') from due_closure order by accepted;
select ok((api.group_snapshot(group_id)#>>'{run,currentDestinationNeedsReview}')::boolean,'unaccepted current finale has explicit organization-help status') from due_closure where not accepted;
select is((api.group_snapshot(group_id)#>>'{run,version}')::integer,version,'venue closure does not silently stale either pending finale command') from due_closure order by accepted;
set local role postgres;
select is((select to_jsonb(b) from app_private.portal_reservations b where b.run_id=t.run_id and b.kind='finale'),t.reservation,'venue closure preserves the exact bound final capacity claim') from due_closure t order by accepted;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-30-TOKEN',group_id,'closed-unaccepted-finale') from due_closure where not accepted$$,'P0001','PORTAL_UNAVAILABLE','closed unaccepted finale gives no admission or fictitious final seal');
select lives_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-30-TOKEN',group_id,'closed-accepted-finale') from due_closure where accepted$$,'previously accepted real finale arrival can finish after closure');
select lives_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-30-TOKEN',group_id,'closed-accepted-finale') from due_closure where accepted$$,'exact accepted-finale retry still returns its original result after closure');
set local role postgres;
select is((select to_jsonb(e) from app_private.scan_evidence e where e.run_stop_id=t.stop_id),t.proof,'valid original finale proof keeps its original identity and acceptance time') from due_closure t where accepted;
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=t.run_id and finale),case when t.accepted then 7 else 0 end,'only genuinely admitted present outside children receive one finale seal') from due_closure t order by accepted;
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000030','open',portal_version+1,null) from due_place$$,'the venue can reopen while the second original command is still pending');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.closure_arrive(run_id,stop_id,version,'TEST-PORTAL-30-TOKEN',group_id,'closed-unaccepted-finale') from due_closure where not accepted$$,'same unaccepted original command can complete when the venue actually reopens');
set local role postgres;
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=t.run_id and finale),10,'all ten actually admitted outside children receive one final seal') from due_closure t where not accepted;

select * from finish();
rollback;
