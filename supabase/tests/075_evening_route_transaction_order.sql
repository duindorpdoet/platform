begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table route_probe(run_id uuid,stop_id uuid,version integer);
grant all on route_probe to authenticated;
set local role authenticated;
select throws_ok($$select api.run_start('23000000-0000-0000-0000-000000000002',array[]::uuid[],null,'null-version-start','null-version-start')$$,'40001','STALE_VERSION','missing expected group version is never a CAS bypass');
insert into route_probe(run_id) select (api.run_start('23000000-0000-0000-0000-000000000002',
 array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster('23000000-0000-0000-0000-000000000002')) v),
 (api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{group,version}')::integer,'route-order-start','route-order-start')->>'runId')::uuid;
update route_probe set stop_id=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
select throws_ok($$select api.run_scan(run_id,stop_id,null,'TEST-PORTAL-01-TOKEN','qr') from route_probe$$,'40001','STALE_VERSION','scan requires an actual expected run version');
select throws_ok($$select api.run_set_state(run_id,'paused',null,'Pauze met ontbrekende versie') from route_probe$$,'40001','STALE_VERSION','pause requires an actual expected run version');
select throws_ok($$select api.run_set_state(run_id,'paused',version-1,'Pauze met een oude versie') from route_probe$$,'40001','STALE_VERSION','stale pause cannot overwrite a newer run');
-- Confirm an actual scan/completion before the organization records safe departure.
select lives_ok($$select api.run_arrive_and_advance(p.run_id,p.stop_id,p.version,'TEST-PORTAL-01-TOKEN',
 (select jsonb_object_agg(v->>'id','visited') from jsonb_array_elements(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>'{run,participants}') v),
 'route-order-arrival') from route_probe p$$,'ordinary real arrival keeps its existing scan, seal and next-stop behavior');
update route_probe set stop_id=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
select lives_ok($$select api.run_set_state(run_id,'paused',version,'Groep wacht veilig op de organisatie') from route_probe$$,'own leader can still pause a live route');
update route_probe set version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
set local role postgres;
create temp table retained as
 select 'arrivals' kind,md5(coalesce(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id),'[]')::text) hash from app_private.run_stop_arrivals a
 union all select 'seals',md5(coalesce(jsonb_agg(to_jsonb(s) order by s.run_stop_id,s.child_id),'[]')::text) from app_private.poortenboek_passport_seals s
 union all select 'payments',md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.payment_requests p
 union all select 'credentials',md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]')::text) from app_private.portal_credentials c;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000005',null,'Afmelding met ontbrekende actuele versie') from route_probe$$,'40001','STALE_VERSION','safe withdrawal cannot omit expected run version');
select throws_ok($$select api.admin_safe_withdraw_group(run_id,'b0000000-0000-0000-0000-000000000001',version,'Verantwoordelijke hoort niet bij deze groep') from route_probe$$,'23514','RESPONSIBLE_ADULT_NOT_IN_GROUP','safe withdrawal accepts only a currently registered adult of this group');
select lives_ok($$select api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000005',version,'Organisatie spreekt de eigen verantwoordelijke en meldt veilig af') from route_probe$$,'organization can safely withdraw the current paused run');
update route_probe set version=(api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{run,version}')::integer;
select throws_ok($$select api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000005',version,'Een gestopte tocht nogmaals proberen af te melden') from route_probe$$,'23514','RUN_NOT_ACTIVE','a stopped run cannot be withdrawn again');
set local role postgres;
select is((select status::text from app_private.group_runs where id=(select run_id from route_probe)),'stopped','safe departure stops the current run');
select is((select responsible_adult_user_id from app_private.group_safe_departures where run_id=(select run_id from route_probe)),'a0000000-0000-0000-0000-000000000005'::uuid,'actual selected adult is retained');
select is((select md5(coalesce(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id),'[]')::text) from app_private.run_stop_arrivals a),(select hash from retained where kind='arrivals'),'safe departure preserves exact existing arrivals');
select is((select md5(coalesce(jsonb_agg(to_jsonb(s) order by s.run_stop_id,s.child_id),'[]')::text) from app_private.poortenboek_passport_seals s),(select hash from retained where kind='seals'),'safe departure preserves exact existing child seals');
select is((select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.payment_requests p),(select hash from retained where kind='payments'),'safe departure does not rewrite payments');
select is((select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]')::text) from app_private.portal_credentials c),(select hash from retained where kind='credentials'),'safe departure does not rotate QR credentials');
-- A completed historic route is not a substitute for the group's current action.
update app_private.group_runs set status='completed' where id=(select run_id from route_probe);
set local role authenticated;
select throws_ok($$select api.admin_safe_withdraw_group(run_id,'a0000000-0000-0000-0000-000000000005',version,'Een afgeronde tocht mag niet terug naar gestopt') from route_probe$$,'23514','RUN_NOT_ACTIVE','completed run cannot be changed to stopped');
set local role postgres;
select ok(not has_function_privilege('authenticated','app_private.lock_evening_event(uuid)','execute'),'private event lock is not a public command');
select ok(has_function_privilege('authenticated','api.run_start(uuid,uuid[],integer,text,text)','execute'),'existing authorized start signature remains executable');
select ok(not has_function_privilege('anon','api.run_start(uuid,uuid[],integer,text,text)','execute'),'anonymous callers still cannot start routes');
select ok(not has_function_privilege('authenticated','api.worker_dispatch_due_groups(text,integer)','execute'),'worker remains unavailable to participant sessions');
select ok(has_function_privilege('service_role','api.worker_dispatch_due_groups(text,integer)','execute'),'trusted worker retains its existing role grant');
select * from finish();
rollback;
