begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
select ok(not has_function_privilege('anon','api.admin_evening_cockpit(text)','execute'),'anonymous cockpit remains private');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.admin_evening_cockpit('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','ordinary parent cannot read aggregate contacts');
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','ordinary parent cannot read portal operations');
set local role postgres;
insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
select id,'a0000000-0000-0000-0000-000000000001','live_support','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';
create function pg_temp.aggregate_group() returns jsonb language sql as $$
 select item from jsonb_array_elements(api.admin_evening_cockpit('duindorp-halloween-2026')->'groups') item
 where item->>'groupId'='23000000-0000-0000-0000-000000000002'
$$;
create function pg_temp.aggregate_portal() returns jsonb language sql as $$
 select item from jsonb_array_elements(api.admin_evening_cockpit('duindorp-halloween-2026')->'portals') item
 where item->>'id'='12000000-0000-0000-0000-000000000001'
$$;
create function pg_temp.aggregate_operations() returns jsonb language sql as $$
 select item from jsonb_array_elements(api.admin_portal_operations_snapshot('duindorp-halloween-2026')->'portals') item
 where item->>'portalId'='12000000-0000-0000-0000-000000000001'
$$;
set local role authenticated;
select is(pg_temp.aggregate_group()->>'childCount','5','support sees five enrolled children in the selected group');
select is(pg_temp.aggregate_group()->>'groupCode','G-02','canonical group code is retained without a JSON rewrite');
select is(pg_temp.aggregate_group()#>>'{responsibleAdults,0,userId}','a0000000-0000-0000-0000-000000000005','responsible adults belong to the selected group');
select is(pg_temp.aggregate_portal()->>'activeReservations','0','an unassigned ordinary house has no active booking');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table aggregate_run as select (api.run_start('23000000-0000-0000-0000-000000000002',
 array(select(p->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster('23000000-0000-0000-0000-000000000002'))p),
 (api.group_snapshot('23000000-0000-0000-0000-000000000002')#>>'{group,version}')::integer,'aggregate-actual-start','aggregate-actual-start')->>'runId')::uuid id;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(pg_temp.aggregate_group()->>'runStatus','live','an actual started run remains live in the aggregate');
select is(pg_temp.aggregate_portal()->>'activeReservations','1','one real current ordinary claim is counted once');
select is(pg_temp.aggregate_portal()->>'expectedChildren','5','current ordinary claim reserves five children');
select is(pg_temp.aggregate_operations()->>'activeReservations','1','operations and cockpit count the same claim');
select is(pg_temp.aggregate_operations()->>'expectedChildren','5','operations and cockpit count the same children');
select is(pg_temp.aggregate_operations()->>'code','P-01','operations keeps the recognizable physical portal code');
select throws_ok($$select api.admin_evening_cockpit('an-event-that-does-not-exist')$$,'42501','NOT_AUTHORIZED','an unrelated event cannot reuse the support scope');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select id from aggregate_run)),0,'snapshot reads do not fabricate an arrival');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select id from aggregate_run)),0,'snapshot reads do not fabricate seals');
update app_private.event_capabilities set revoked_at=now() where user_id='a0000000-0000-0000-0000-000000000001' and capability='live_support';
set local role authenticated;
select throws_ok($$select api.admin_evening_cockpit('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','revoked support cannot reuse a prior aggregate response');
select throws_ok($$select api.admin_portal_operations_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','revoked support cannot read portal private fields');
select * from finish();
rollback;
