begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
-- R-07: the same physical house may be represented by an old plan FK or a
-- dynamic destination. An issued system skip is excluded from future choices,
-- while only an accepted scan is a position, visit or passport seal.
create temp table identity_cases(group_id uuid,run_id uuid,stop_id uuid,version integer,history_first boolean,plan_ids uuid[],first_stop uuid,redirected_stop uuid,reply jsonb,receipt_key text);
insert into identity_cases(group_id,history_first,receipt_key) values
 ('23000000-0000-0000-0000-000000000001',false,'r07-unvisited-redirect-arrival'),
 ('23000000-0000-0000-0000-000000000002',true,'r07-visited-redirect-arrival');
grant all on identity_cases to authenticated;
create function pg_temp.identity_start(gid uuid) returns uuid language sql security invoker as $$
 select (api.run_start(gid,array(select (p->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(gid)) p),(api.group_snapshot(gid)#>>'{group,version}')::integer,'r07-start-'||gid,'r07-start-'||gid)->>'runId')::uuid
$$;
create function pg_temp.identity_arrive(rid uuid,sid uuid,ver integer,code text,gid uuid,key text) returns jsonb language sql security invoker as $$
 select api.run_arrive_and_advance(rid,sid,ver,code,(select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(gid)#>'{run,participants}') p),key)
$$;
grant execute on function pg_temp.identity_start(uuid),pg_temp.identity_arrive(uuid,uuid,integer,text,uuid,text) to authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update identity_cases set run_id=pg_temp.identity_start(group_id);
select is(api.group_snapshot(group_id)#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000001','both scenarios begin at the same physical P-01') from identity_cases order by history_first;
update identity_cases set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
set local role postgres;
update identity_cases t set first_stop=stop_id,plan_ids=(select array_agg(s.plan_stop_id order by s.plan_stop_id) from app_private.run_stops s where s.run_id=t.run_id);
set local role authenticated;
select lives_ok($$select pg_temp.identity_arrive(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',group_id,'r07-existing-real-history') from identity_cases where history_first$$,'second scenario records the actual outside arrival at P-01');
select is(api.group_snapshot((select group_id from identity_cases where history_first))#>>'{run,currentStop,portal,id}','12000000-0000-0000-0000-000000000002','actual first arrival releases P-02');
update identity_cases set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_redirect_group(run_id,'ordinary','12000000-0000-0000-0000-000000000002',version,'Organisatie leidt de nog niet aangekomen groep van P-01 naar P-02') from identity_cases where not history_first$$,'first scenario redirects unvisited P-01 to physical P-02');
select lives_ok($$select api.admin_redirect_group(run_id,'ordinary','12000000-0000-0000-0000-000000000003',version,'Organisatie leidt de volgende nog niet bezochte P-02 om naar P-03') from identity_cases where history_first$$,'second scenario redirects unvisited P-02 to physical P-03');
set local role postgres;
select is(app_private.evening_route_context(group_id)->>'completedOrdinaryVisits',case when history_first then '1' else '0' end,'system skip never counts as an actual ordinary visit') from identity_cases order by history_first;
select is(app_private.evening_route_context(group_id)->>'lastConfirmedPortalId',case when history_first then '12000000-0000-0000-0000-000000000001' else null end,'redirected destination never becomes a fabricated actual position') from identity_cases order by history_first;
select ok((app_private.evening_route_context(group_id)->'seenPortalIds') ? case when history_first then '12000000-0000-0000-0000-000000000002' else '12000000-0000-0000-0000-000000000001' end,'the issued system-skipped physical house remains excluded from future choices') from identity_cases order by history_first;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
update identity_cases set stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer;
update identity_cases set redirected_stop=stop_id,reply=pg_temp.identity_arrive(run_id,stop_id,version,case when history_first then 'TEST-PORTAL-03-TOKEN' else 'TEST-PORTAL-02-TOKEN' end,group_id,receipt_key);
select is(api.group_snapshot(group_id)#>>'{run,currentStop,portal,id}',case when history_first then '12000000-0000-0000-0000-000000000004' else '12000000-0000-0000-0000-000000000003' end,'actual redirected arrival continues forward without repeating either physical representation') from identity_cases order by history_first;
select is(pg_temp.identity_arrive(run_id,stop_id,version,case when history_first then 'TEST-PORTAL-03-TOKEN' else 'TEST-PORTAL-02-TOKEN' end,group_id,receipt_key),reply,'exact lost-response arrival retry returns the original result') from identity_cases order by history_first;
set local role postgres;
select is((select array_agg(s.plan_stop_id order by s.plan_stop_id) from app_private.run_stops s where s.run_id=t.run_id),t.plan_ids,'redirect and continuation retain every original old plan FK') from identity_cases t order by history_first;
select ok((select s.plan_stop_id is not null and s.portal_id is null from app_private.run_stops s where s.id=t.redirected_stop),'redirect reuses the physical old plan record without rewriting historical identity') from identity_cases t order by history_first;
select is((select count(*)::integer from app_private.run_stop_arrivals a where a.run_id=t.run_id),case when history_first then 10 else 1 end,'only genuinely reached outside arrivals are recorded once') from identity_cases t order by history_first;
select is((select count(*)::integer from app_private.poortenboek_passport_seals a where a.run_id=t.run_id),case when history_first then 10 else 1 end,'each present outside child receives exactly one seal per real house') from identity_cases t order by history_first;
select is((select count(distinct coalesce(s.portal_id,ps.portal_id))::integer from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where s.run_id=t.run_id and s.state in ('active','completed')),(select count(*)::integer from app_private.run_stops s where s.run_id=t.run_id and s.state in ('active','completed')),'issued/history rows contain no duplicate physical house') from identity_cases t order by history_first;
select * from finish();
rollback;
