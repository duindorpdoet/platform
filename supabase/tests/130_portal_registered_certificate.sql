begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
-- The historical seed's four old published routes are kept intact but retired
-- for this isolated cohort. A savepoint below tests their legacy fallback.
update app_private.walking_groups set retired_at=now()where id::text like'23000000-%';
update app_private.portal_flags set value=false where flag_key='fixture';
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
insert into app_private.walking_groups(id,event_id,code,status,route_mode)
select 'e7000000-0000-0000-0000-000000000002',id,'REGISTERED-SECOND','ready','dynamic'from app_private.events where slug='duindorp-halloween-2026';
update app_private.group_registrations set superseded_at=now()where registration_id='d3000000-0000-0000-0000-000000000003'and superseded_at is null;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at)
values('e7000000-0000-0000-0000-000000000002','d3000000-0000-0000-0000-000000000003',2,now());
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_by,point_snapshot,slot_snapshot)
select e.id,g.id,'synthetic-registered:'||g.id,1,t.starts_at,'f0000000-0000-0000-0000-000000000001',
 jsonb_build_object('linked_portal_id',case when g.id='d7000000-0000-0000-0000-000000000001'then '12000000-0000-0000-0000-000000000001'else '12000000-0000-0000-0000-000000000002'end),'{}'
from app_private.events e join app_private.walking_groups g on g.event_id=e.id
cross join lateral(select timestamptz'2026-10-31T17:00Z'+case when g.id='e7000000-0000-0000-0000-000000000002'then interval'10 minutes'else interval'0'end starts_at)t
where g.id in('d7000000-0000-0000-0000-000000000001','e7000000-0000-0000-0000-000000000002');

-- Two accepted revisions retain history, but only the current pointer owns the
-- intended calendar. Old portal3 and unreviewed portal4 rows cannot count.
insert into app_private.joint_route_plan_versions(id,event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,reason)
select ('e6000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,e.id,n,'synthetic-source-'||n,'synthetic-plan-'||n,'synthetic-board','synthetic-projection',
 'f0000000-0000-0000-0000-000000000001',
 (select jsonb_agg(jsonb_build_object('groupId',pub.group_id,'startsAt',pub.starts_at,'visits',jsonb_build_array(
  jsonb_build_object('portalId',case when n=1 then '12000000-0000-0000-0000-000000000003'else '12000000-0000-0000-0000-000000000001'end,
   'kind','ordinary','sequence',1,'startsAt',pub.starts_at+interval'5 minutes','visitSeconds',180,'bufferSeconds',60),
  jsonb_build_object('portalId','12000000-0000-0000-0000-000000000030','kind','finale','sequence',2,'startsAt',pub.starts_at+interval'15 minutes','visitSeconds',240,'bufferSeconds',30))))
 from app_private.group_start_publications pub where pub.group_id in('d7000000-0000-0000-0000-000000000001','e7000000-0000-0000-0000-000000000002')),
 'Synthetic immutable registered route projection fixture'
from app_private.events e,generate_series(1,2)n where e.slug='duindorp-halloween-2026';
insert into app_private.live_route_plans(group_id,event_id,accepted_version_id,source_hash,plan_hash)
select pub.group_id,pub.event_id,'e6000000-0000-0000-0000-000000000002','synthetic-source-2','synthetic-plan-2'
from app_private.group_start_publications pub where pub.group_id in('d7000000-0000-0000-0000-000000000001','e7000000-0000-0000-0000-000000000002');
insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source,retired_at)
select pub.event_id,pub.group_id,n,
 case n when 1 then(pub.point_snapshot->>'linked_portal_id')::uuid when 2 then'12000000-0000-0000-0000-000000000001'::uuid
 when 3 then'12000000-0000-0000-0000-000000000030'::uuid when 4 then'12000000-0000-0000-0000-000000000003'::uuid else'12000000-0000-0000-0000-000000000004'::uuid end,
 pub.starts_at+make_interval(mins=>case n when 1 then 0 when 2 then 5 when 3 then 15 else 25 end),
 case n when 1 then 30 when 3 then 240 else 180 end,case n when 1 then 0 when 3 then 30 else 60 end,
 case n when 1 then'start'when 3 then'finale'else'ordinary'end,'manual',case when n=4 then now()end
from app_private.group_start_publications pub,generate_series(1,5)n where pub.group_id in('d7000000-0000-0000-0000-000000000001','e7000000-0000-0000-0000-000000000002');

create function pg_temp.registered_checkpoint()returns jsonb language sql stable as $$
 select jsonb_build_object(
 'plans',(select jsonb_agg(to_jsonb(p)order by group_id)from app_private.live_route_plans p),
 'visits',(select jsonb_agg(to_jsonb(v)order by id)from app_private.live_route_visits v),
 'versions',(select jsonb_agg(to_jsonb(v)order by id)from app_private.joint_route_plan_versions v),
 'assignments',(select jsonb_agg(to_jsonb(a)order by id)from app_private.group_registrations a),
 'publications',(select jsonb_agg(to_jsonb(p)order by id)from app_private.group_start_publications p),
 'runs',(select jsonb_agg(to_jsonb(r)order by id)from app_private.group_runs r),
 'arrivals',(select jsonb_agg(to_jsonb(a)order by run_stop_id,run_participant_id)from app_private.run_stop_arrivals a),
 'seals',(select count(*)from app_private.poortenboek_passport_seals),
 'outbox',(select jsonb_agg(to_jsonb(o)order by id)from app_private.email_outbox o))
$$;
create temp table registered_before as select pg_temp.registered_checkpoint()state;
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),' {"registeredGroups":2,"registeredChildren":3}'::jsonb,'registered groups and kids count without any real arrival');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000002'),' {"registeredGroups":1,"registeredChildren":1}'::jsonb,'published house gathering is registered planning even without an ordinary stop');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000030'),' {"registeredGroups":2,"registeredChildren":3}'::jsonb,'registered finale is included independently of actual scans');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000003'),' {"registeredGroups":0,"registeredChildren":0}'::jsonb,'older accepted version and retired intent are excluded');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000004'),' {"registeredGroups":0,"registeredChildren":0}'::jsonb,'an unreviewed extra live-board row is not an accepted registration');
select is(app_private.portal_registered_impact(gen_random_uuid()),'{"registeredGroups":0,"registeredChildren":0}'::jsonb,'unknown portal returns no invented registered cohort');
select ok(not has_function_privilege('authenticated','app_private.portal_registered_impact(uuid)','execute'),'new planning projection remains private');
select ok(not has_function_privilege('service_role','app_private.portal_registered_impact(uuid)','execute'),'no service-role shortcut is added');
select is((select prosecdef from pg_proc where oid='app_private.portal_registered_impact(uuid)'::regprocedure),false,'new helper is security invoker');
select is((select provolatile::text from pg_proc where oid='app_private.portal_registered_impact(uuid)'::regprocedure),'s','complete registered projection is read only stable');

savepoint unpublished_binding;
update app_private.group_registrations set published_at=null where group_id='e7000000-0000-0000-0000-000000000002'and superseded_at is null;
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'unpublished composition does not inflate registered counts');
rollback to unpublished_binding;
savepoint cancelled_registration;
update app_private.registrations set status='cancelled'where id='d3000000-0000-0000-0000-000000000003';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'cancelled household registration is excluded');
rollback to cancelled_registration;
savepoint cancelled_child;
update app_private.registration_children set participation_status='cancelled'where id='d5000000-0000-0000-0000-000000000003';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'cancelled child does not keep an empty group registered');
rollback to cancelled_child;
savepoint reassigned_family;
update app_private.group_registrations set superseded_at=now()where group_id='e7000000-0000-0000-0000-000000000002'and superseded_at is null;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at)values('d7000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000003',3,now());
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":3}'::jsonb,'reassigned family counts once in the current published group');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000002'),'{"registeredGroups":0,"registeredChildren":0}'::jsonb,'superseded assignment no longer credits the former start house');
rollback to reassigned_family;
savepoint retired_group;
update app_private.walking_groups set retired_at=now()where id='e7000000-0000-0000-0000-000000000002';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'retired old group is not a current registered group');
rollback to retired_group;
savepoint withdrawn_start;
insert into app_private.group_start_withdrawals(event_id,group_id,through_publication_order,actor_id,reason)
select event_id,group_id,publication_order,'f0000000-0000-0000-0000-000000000001','Synthetic withdrawn published appointment'from app_private.group_start_publications where group_id='e7000000-0000-0000-0000-000000000002';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'withdrawn start publication excludes its old accepted calendar');
rollback to withdrawn_start;
savepoint unaccepted_proposal;
update app_private.live_route_plans set accepted_version_id=null where group_id='e7000000-0000-0000-0000-000000000002';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'unaccepted draft board never becomes a registered route');
rollback to unaccepted_proposal;
savepoint wrong_accepted_hash;
update app_private.live_route_plans set plan_hash='stale-unaccepted-value'where group_id='e7000000-0000-0000-0000-000000000002';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'accepted pointer must retain its matching accepted plan identity');
rollback to wrong_accepted_hash;
savepoint changed_live_row;
update app_private.live_route_visits set starts_at=starts_at+interval'1 minute'where group_id='e7000000-0000-0000-0000-000000000002'and kind='ordinary'and portal_id='12000000-0000-0000-0000-000000000001';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'unaccepted changed live row does not impersonate immutable approved intent');
rollback to changed_live_row;
savepoint retired_visit;
update app_private.live_route_visits set retired_at=now()where group_id='e7000000-0000-0000-0000-000000000002'and kind='ordinary'and portal_id='12000000-0000-0000-0000-000000000001';
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":1,"registeredChildren":2}'::jsonb,'retired obsolete route position is excluded');
rollback to retired_visit;

-- Existing genuinely published legacy route remains readable, without creating
-- a new route or promoting any draft. Its seed children are distinct identities.
savepoint legacy_route;
create temp table legacy_registered as select g.id,stop.portal_id,
 (app_private.portal_registered_impact(stop.portal_id)->>'registeredGroups')::bigint groups_before,
 (app_private.portal_registered_impact(stop.portal_id)->>'registeredChildren')::bigint children_before,
 (select count(distinct rc.child_id)from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id and r.status='submitted'
 join app_private.registration_children rc on rc.registration_id=r.id and rc.participation_status='active'where a.group_id=g.id and a.superseded_at is null and a.published_at is not null)child_count
from app_private.walking_groups g join app_private.route_plan_versions v on v.id=g.current_plan_version_id and v.state='published'
join app_private.route_plan_stops stop on stop.plan_version_id=v.id where g.id='23000000-0000-0000-0000-000000000001'order by stop.position limit 1;
update app_private.walking_groups set retired_at=null where id=(select id from legacy_registered);
select is((app_private.portal_registered_impact(portal_id)->>'registeredGroups')::bigint,groups_before+1,'current published legacy route adds exactly its one current group')from legacy_registered;
select is((app_private.portal_registered_impact(portal_id)->>'registeredChildren')::bigint,children_before+child_count,'legacy fallback counts registered child identities rather than attendance')from legacy_registered;
rollback to legacy_route;

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->'registeredImpact','{"registeredGroups":2,"registeredChildren":3}'::jsonb,'room exposes separate registered projection for the certificate');
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->'impact','{"actualGroups":0,"actualChildren":0}'::jsonb,'actual arrival contract stays factual and unchanged');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000001')#>>'{recap,children}','0','actual recap does not fall back to registered kids');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','registered counts do not grant participant access to another private house');
set local role postgres;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select user_id from app_private.portal_owners where portal_id='12000000-0000-0000-0000-000000000001'and revoked_at is null and role='owner'),'role','authenticated')::text,true);
set local role authenticated;
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->'registeredImpact','{"registeredGroups":2,"registeredChildren":3}'::jsonb,'existing actual house owner retains private registered counts');
select throws_ok($$select api.portal_room_snapshot('other-event','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','event boundary remains enforced');
set local role postgres;
select is(pg_temp.registered_checkpoint(),(select state from registered_before),'all projection reads preserve plans, published bindings, history and mail');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic close','Synthetic closure body',gen_random_uuid());
select is((select status from app_private.walking_groups where id='d7000000-0000-0000-0000-000000000001'),'stopped','real central closure stops the group business execution');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000001'),'{"registeredGroups":2,"registeredChildren":3}'::jsonb,'stopped nonretired groups retain registered planning after closure');
select is(app_private.portal_registered_impact('12000000-0000-0000-0000-000000000029'),'{"registeredGroups":0,"registeredChildren":0}'::jsonb,'a closure gift without a registered route never inflates the certificate');
select is((select count(*)from app_private.run_stop_arrivals),0::bigint,'registered projection never invents child arrivals');
select is((select count(*)from app_private.duinpad_show_attempts),0::bigint,'registered projection never starts a physical finale');
select is((select count(*)from app_private.portal_certificate_campaigns),0::bigint,'reading the revised certificate never confirms its mail campaign');
select *from finish();
rollback;
