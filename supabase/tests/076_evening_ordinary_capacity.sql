begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table capacity_fixture as select
 (select id from app_private.events where slug='duindorp-halloween-2026') event_id,
 '12000000-0000-0000-0000-000000000028'::uuid portal_id,
 '23000000-0000-0000-0000-000000000002'::uuid group_id,
 '2026-10-31T17:30:00Z'::timestamptz arrival_at;
create function pg_temp.assess(_children integer,_arrival timestamptz default null) returns jsonb
language sql as $$ select app_private.assess_ordinary_portal(event_id,group_id,portal_id,coalesce(_arrival,arrival_at),_children,statement_timestamp()) from capacity_fixture $$;
update app_private.portal_windows set max_children_per_visit=20,max_concurrent_groups=2,max_children_total=5000 where portal_id=(select portal_id from capacity_fixture);
select is(pg_temp.assess(26)->>'eligible','false','event maximum does not enlarge a house with space for twenty children');
select is(pg_temp.assess(26)#>>'{reasons,0}','26 kinderen; deze poort kan maximaal 20 kinderen ontvangen.','capacity exclusion explains the actual group and house counts');
select is(pg_temp.assess(20)->>'eligible','true','a physically fitting group can use the house');
select is(pg_temp.assess(0)#>>'{blockingCodes,0}','EMPTY_GROUP','empty group cannot reserve a house');
select ok(pg_temp.assess(1,'2026-10-31T20:59:00Z')->'blockingCodes' ? 'PORTAL_WINDOW_CONFLICT','the whole visit must fit, not merely its arrival');
select ok(pg_temp.assess(1,'2026-10-31T16:59:00Z')->'blockingCodes' ? 'PORTAL_WINDOW_CONFLICT','arrival before opening is rejected');
update app_private.portals set operation_status='paused' where id=(select portal_id from capacity_fixture);
select ok(pg_temp.assess(1)->'blockingCodes' ? 'PORTAL_NOT_OPEN','paused portal does not receive new groups');
update app_private.portals set operation_status='closed' where id=(select portal_id from capacity_fixture);
select ok(pg_temp.assess(1)->'blockingCodes' ? 'PORTAL_NOT_OPEN','closed portal does not receive new groups');
update app_private.portals set operation_status='open' where id=(select portal_id from capacity_fixture);
update app_private.portal_private_locations set verified_at=null where portal_id=(select portal_id from capacity_fixture);
select ok(pg_temp.assess(1)->'blockingCodes' ? 'PORTAL_NOT_VERIFIED','unverified private location cannot receive an assignment');
update app_private.portal_private_locations set verified_at=now() where portal_id=(select portal_id from capacity_fixture);
update app_private.portal_windows set max_children_per_visit=12 where portal_id=(select portal_id from capacity_fixture);
create temp table capacity_bookings(id uuid,label text);
with a as (insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,service_until,reserved_until,child_count)
 select event_id,portal_id,'23000000-0000-0000-0000-000000000001','ordinary','held',arrival_at,arrival_at+interval '5 minutes',arrival_at+interval '7 minutes',5 from capacity_fixture returning id)
 insert into capacity_bookings select id,'first' from a;
with a as (insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,service_until,reserved_until,child_count)
 select event_id,portal_id,'23000000-0000-0000-0000-000000000003','ordinary','held',arrival_at+interval '7 minutes',arrival_at+interval '12 minutes',arrival_at+interval '14 minutes',5 from capacity_fixture returning id)
 insert into capacity_bookings select id,'second' from a;
select is(pg_temp.assess(7)->>'eligible','true','two groups and twelve concurrent children fit exactly');
select is(pg_temp.assess(8)->>'eligible','false','aggregate concurrent child capacity applies independently of group slots');
select is((pg_temp.assess(8)#>>'{capacity,peakChildren}')::integer,13,'existing group plus proposed group counts all children');
select is((pg_temp.assess(7,'2026-10-31T17:34:00Z')#>>'{capacity,peakGroups}')::integer,2,'back-to-back bookings are not summed as if simultaneous');
select is(pg_temp.assess(7,'2026-10-31T17:34:00Z')->>'eligible','true','half-open capacity changes are evaluated throughout the proposed visit');
-- The same physical group may be represented in an old plan and a reservation.
-- Even duplicate fixture representations cannot inflate the projected occupancy.
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,service_until,reserved_until,child_count)
 select event_id,portal_id,'23000000-0000-0000-0000-000000000001','ordinary','held',arrival_at,arrival_at+interval '5 minutes',arrival_at+interval '7 minutes',5 from capacity_fixture;
select is((pg_temp.assess(7)#>>'{capacity,peakGroups}')::integer,2,'one physical group is counted once across overlapping booking representations');
select is((pg_temp.assess(7)#>>'{capacity,peakChildren}')::integer,12,'duplicate representation does not count a group roster twice');
update app_private.portal_windows set max_concurrent_groups=1 where portal_id=(select portal_id from capacity_fixture);
select ok(pg_temp.assess(1)->'blockingCodes' ? 'PORTAL_CAPACITY_EXCEEDED','independent simultaneous-group limit is enforced');
select throws_ok($$insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,service_until,reserved_until,child_count)
 select event_id,portal_id,group_id,'ordinary','active',arrival_at,arrival_at+interval '5 minutes',arrival_at+interval '7 minutes',1 from capacity_fixture$$,
 '23514','PORTAL_CAPACITY_EXCEEDED','reservation boundary rejects physical overbooking atomically');
select is((select count(*)::integer from app_private.portal_reservations b join capacity_fixture f on f.group_id=b.group_id and f.portal_id=b.portal_id),0,'failed reservation leaves no partial booking');
update app_private.portal_reservations set status='completed' where portal_id=(select portal_id from capacity_fixture) and group_id='23000000-0000-0000-0000-000000000001';
select is(pg_temp.assess(7)->>'eligible','true','completed booking releases its interval');
update app_private.portal_reservations set status='expired' where portal_id=(select portal_id from capacity_fixture);
select is(pg_temp.assess(12)->>'eligible','true','expired booking releases future capacity');

-- Exercise a real participant arrival, then a real departure and organization stop.
update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours',max_children_per_visit=40,max_concurrent_groups=10 where portal_id in ('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002');
create temp table live_capacity(run_id uuid,stop_id uuid,version integer,reservation_id uuid);
grant all on live_capacity to authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
insert into live_capacity(run_id) select (api.run_start('23000000-0000-0000-0000-000000000002',
 array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster('23000000-0000-0000-0000-000000000002')) v),
 (api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{group,version}')::integer,'capacity-real-start','capacity-real-start')->>'runId')::uuid;
update live_capacity set stop_id=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
set local role postgres;
update live_capacity l set reservation_id=(select id from app_private.portal_reservations where bound_stop_id=l.stop_id);
select throws_ok($$update app_private.portal_reservations b set group_id='23000000-0000-0000-0000-000000000001',bound_stop_id=l.stop_id from live_capacity l where b.id=l.reservation_id$$,
 '23514','INVALID_RESERVATION_SCOPE','legacy binding cannot attach a reservation to another physical group');
update app_private.portal_reservations b set bound_stop_id=l.stop_id from live_capacity l where b.id=l.reservation_id;
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance(l.run_id,l.stop_id,l.version,'TEST-PORTAL-01-TOKEN',
 (select jsonb_object_agg(v->>'id','skipped') from jsonb_array_elements(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>'{run,participants}') v),'capacity-real-arrival') from live_capacity l$$,'real inclusive arrival completes the assigned visit');
update live_capacity set stop_id=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
set local role postgres;
select is((select status::text from app_private.portal_reservations where id=(select reservation_id from live_capacity)),'completed','real arrival completion frees its reservation');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from live_capacity)),5,'all five present children have retained actual arrival facts');
select is((select sum(children)::integer from app_private.ordinary_portal_bookings((select event_id from capacity_fixture),'12000000-0000-0000-0000-000000000001',now()) where historical),5,'historical capacity counts actual frozen arrivals');
update app_private.portal_windows set max_children_total=5 where portal_id='12000000-0000-0000-0000-000000000001';
select ok(app_private.assess_ordinary_portal((select event_id from capacity_fixture),'23000000-0000-0000-0000-000000000003','12000000-0000-0000-0000-000000000001',now(),1)->'blockingCodes' ? 'PORTAL_TOTAL_CAPACITY_EXCEEDED','completed arrivals remain in the finite total-reception limit');
update app_private.portal_windows set opens_at=now()+interval '1 hour' where portal_id='12000000-0000-0000-0000-000000000001';
select ok(app_private.assess_ordinary_portal((select event_id from capacity_fixture),'23000000-0000-0000-0000-000000000003','12000000-0000-0000-0000-000000000001',now()+interval '2 hours',1)->'blockingCodes' ? 'PORTAL_TOTAL_CAPACITY_EXCEEDED','changing a future opening window does not erase the physical total already received');
update live_capacity l set reservation_id=(select id from app_private.portal_reservations where bound_stop_id=l.stop_id and kind='ordinary');
create temp table preserved_capacity as
 select 'arrivals' kind,md5(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id)::text) hash from app_private.run_stop_arrivals a
 union all select 'seals',md5(jsonb_agg(to_jsonb(s) order by s.run_stop_id,s.child_id)::text) from app_private.poortenboek_passport_seals s
 union all select 'payments',md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p
 union all select 'credentials',md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c;
update app_private.portals set operation_status='closed' where id='12000000-0000-0000-0000-000000000002';
set local role authenticated;
select lives_ok($$select api.run_mark_departed(l.run_id,l.stop_id,(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,participants,0,id}')::uuid,l.version,'Ouder neemt het kind mee naar huis') from live_capacity l$$,'departure from a released destination still works after it closes to new groups');
update live_capacity set version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
set local role postgres;
select is((select child_count from app_private.portal_reservations where id=(select reservation_id from live_capacity)),4,'departed child releases current ordinary capacity');
select is((select child_count from app_private.portal_reservations where run_id=(select run_id from live_capacity) and kind='finale'),4,'departure also shrinks the held finale claim');
select is((select sum(children)::integer from app_private.ordinary_portal_bookings((select event_id from capacity_fixture),'12000000-0000-0000-0000-000000000001',now()) where historical),5,'departure cannot rewrite the prior actual arrival count');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.run_set_state(run_id,'stopped',version,'Organisatie meldt de hele groep veilig af') from live_capacity$$,'authorized stop releases both ordinary and held finale capacity');
set local role postgres;
select is((select count(*)::integer from app_private.portal_reservations where run_id=(select run_id from live_capacity) and status in ('held','active')),0,'terminal run retains no active booking');
select is((select md5(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id)::text) from app_private.run_stop_arrivals a),(select hash from preserved_capacity where kind='arrivals'),'capacity release preserves exact actual arrival history');
select is((select md5(jsonb_agg(to_jsonb(s) order by s.run_stop_id,s.child_id)::text) from app_private.poortenboek_passport_seals s),(select hash from preserved_capacity where kind='seals'),'capacity release preserves inclusive child seals');
select is((select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p),(select hash from preserved_capacity where kind='payments'),'capacity changes do not touch payment data');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c),(select hash from preserved_capacity where kind='credentials'),'capacity changes do not rotate credentials');
select ok(not has_function_privilege('authenticated','app_private.assess_ordinary_portal(uuid,uuid,uuid,timestamptz,integer,timestamptz,timestamptz,timestamptz)','execute'),'private house-capacity projection cannot enumerate future addresses through REST');
select ok(not has_table_privilege('authenticated','app_private.portal_reservations','insert'),'participant cannot forge a capacity reservation');
select * from finish();
rollback;
