begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table coverage(eid uuid,version integer,fingerprint text,run_id uuid,stop_id uuid,run_version integer,participants uuid[],children uuid[],
 route_revision_before integer,board_hash_before text,route_revision_after integer,board_hash_after text,event_settings_before integer);
insert into coverage(eid) select id from app_private.events where slug='duindorp-halloween-2026';

-- Synthetic house coverage: the three named worlds are absent. The group channel is independent.
update app_private.events set settings=settings||'{"portalRegistrationOpen":true,"groupRegistrationOpen":true}'::jsonb where id=(select eid from coverage);
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='circuswereld')
 where p.event_id=(select eid from coverage) and p.world_id in(select id from app_private.worlds where slug in('vampierrijk','geestenwereld','besmette-zone'));
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='anders') where p.id='12000000-0000-0000-0000-000000000001';
select is((app_private.world_coverage_projection((select eid from coverage))->>'status'),'provisional','open house channel has provisional coverage');
select ok(app_private.world_coverage_missing((select eid from coverage)) @> array['vampierrijk','geestenwereld','besmette-zone'],'canonical world identities include Geestenrijk as geestenwereld');
select is((select count(*) from app_private.world_coverage_policies where event_id=(select eid from coverage) and policy_status='active'),0::bigint,'open houses do not activate compensation');
update app_private.events set settings=settings||'{"groupRegistrationOpen":false}'::jsonb where id=(select eid from coverage);
select is((app_private.world_coverage_projection((select eid from coverage))->>'status'),'provisional','closing participant channel does not finalize house coverage');

-- Real arrival while houses remain open gives no provisional compensation.
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update coverage set run_id=(api.run_start('23000000-0000-0000-0000-000000000002',array(select rc.id from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id='23000000-0000-0000-0000-000000000002' and a.superseded_at is null),1,'closure-start-01','closure-start-01')->>'runId')::uuid;
update coverage c set stop_id=r.current_stop_id,run_version=r.version from app_private.group_runs r where r.id=c.run_id;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,run_version,'TEST-PORTAL-01-TOKEN',(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=coverage.run_id and attendance='present'),'closure-arrival-01') from coverage$$,'a real Anders arrival remains usable while compensation is provisional');
update coverage c set participants=array(select id from app_private.run_participants where run_id=c.run_id and attendance='present'),children=array(select rc.child_id from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=c.run_id and rp.attendance='present');
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),0::bigint,'no missing-world draw before house closure');

-- Finalization is a true setting transition and is idempotent for the same state.
update app_private.events set settings=settings||'{"portalRegistrationOpen":false}'::jsonb where id=(select eid from coverage);
update coverage set version=app_private.world_coverage_current_version(eid);
select is((app_private.world_coverage_projection((select eid from coverage))->>'status'),'active','house closure activates exactly one final policy');
select ok((select missing_worlds=array['besmette-zone','geestenwereld','vampierrijk'] from app_private.world_coverage_policies where event_id=(select eid from coverage) and policy_status='active'),'closure freezes the precise missing-world set');
update app_private.events set settings=settings||'{"portalRegistrationOpen":false}'::jsonb where id=(select eid from coverage);
select app_private.refresh_world_coverage((select eid from coverage));
select is(app_private.world_coverage_current_version((select eid from coverage)),(select version from coverage),'repeated close and refresh preserve one active version');
create temp table original_finale as select final_portal_id from app_private.event_route_settings where event_id=(select eid from coverage);
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000001' where event_id=(select eid from coverage);
select app_private.award_missing_worlds(eid,a.child_id,stop_id,a.run_participant_id,true,'own_departure') from coverage c join app_private.run_stop_arrivals a on a.run_stop_id=c.stop_id and a.arrived;
select app_private.settle_child_worlds(id,'own_departure') from app_private.run_participants where id=any((select participants from coverage)::uuid[]);
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),0::bigint,'configured Anders finale is never an ordinary compensation source, including settlement');
update app_private.event_route_settings set final_portal_id=(select final_portal_id from original_finale) where event_id=(select eid from coverage);
update app_private.run_participants set attendance='absent' where id=(select participants[1] from coverage);
select app_private.award_missing_worlds(eid,a.child_id,stop_id,a.run_participant_id,false,'arrival') from coverage c join app_private.run_stop_arrivals a on a.run_stop_id=c.stop_id and a.arrived;
select is((select count(*) from app_private.child_world_awards where run_participant_id=(select participants[1] from coverage) and origin='compensation'),0::bigint,'a child who is absent cannot receive a compensation award');
update app_private.run_participants set attendance='present' where id=(select participants[1] from coverage);
select app_private.award_missing_worlds(eid,a.child_id,stop_id,a.run_participant_id,false,'arrival') from coverage c join app_private.run_stop_arrivals a on a.run_stop_id=c.stop_id and a.arrived;
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),(select cardinality(children)::bigint from coverage),'one permanent random missing world for each present child at proven ordinary arrival');
create temp table first_draw as select child_id,world_slug,run_stop_id,awarded_at from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation';
select app_private.award_missing_worlds(eid,a.child_id,stop_id,a.run_participant_id,false,'arrival') from coverage c join app_private.run_stop_arrivals a on a.run_stop_id=c.stop_id and a.arrived;
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),(select count(*) from first_draw),'same arrival never draws again');
select ok(not exists(select * from first_draw except select child_id,world_slug,run_stop_id,awarded_at from app_private.child_world_awards),'refresh and replay preserve the actual random result');
select app_private.settle_child_worlds(id,'own_departure') from app_private.run_participants where id=any((select participants from coverage)::uuid[]);
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),(select 3*cardinality(children)::bigint from coverage),'one real Anders arrival suffices to settle all three worlds at legitimate own end');
select is((select count(distinct run_stop_id) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),1::bigint,'bonus worlds use the one actual physical arrival');
select ok(not exists(select 1 from app_private.child_world_awards a join app_private.run_participants rp on rp.id=a.run_participant_id where a.event_id=(select eid from coverage) and rp.attendance<>'present'),'absent children get no awards');

-- A late theme addition is visible and requires an explicit, authorized revision.
update app_private.portals p set world_id=(select id from app_private.worlds w where w.event_id=p.event_id and w.slug='vampierrijk') where p.id='12000000-0000-0000-0000-000000000004';
select is(app_private.world_coverage_current_version((select eid from coverage)),(select version from coverage),'late house change cannot silently replace active policy');
select ok((app_private.world_coverage_projection((select eid from coverage))->'pendingRevision')<>'null'::jsonb,'late change exposes a pending policy revision');
update coverage c set fingerprint=p.source_fingerprint from app_private.world_coverage_policies p where p.event_id=c.eid and p.policy_status='pending';
update app_private.portals set operation_status='paused' where id='12000000-0000-0000-0000-000000000004';
select app_private.refresh_world_coverage((select eid from coverage));
select is((select source_fingerprint from app_private.world_coverage_policies where event_id=(select eid from coverage) and policy_status='pending'),(select fingerprint from coverage),'temporary pause does not alter coverage or create another candidate');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.admin_accept_world_coverage_revision('duindorp-halloween-2026',1,'fake','Ik controleer deze wereldregeling')$$,'42501','NOT_AUTHORIZED','a parent cannot change compensation policy');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_accept_world_coverage_revision('duindorp-halloween-2026',1,'00000000000000000000000000000000','Ik controleer deze wereldregeling')$$,'40001','STALE_WORLD_COVERAGE','outdated revision or fingerprint cannot be applied');
select throws_ok($$select api.admin_accept_world_coverage_revision('duindorp-halloween-2026',null,null,'Ik controleer deze wereldregeling')$$,'22023','VALIDATION_ERROR','null revision cannot retire the active policy');
update coverage c set version=p.version from app_private.world_coverage_policies p where p.event_id=c.eid and p.policy_status='pending';
update coverage c set route_revision_before=app_private.start_ops_route_revision(eid),board_hash_before=app_private.live_planboard_hash(eid),
 event_settings_before=(select settings_version from app_private.events e where e.id=c.eid);
select lives_ok($$select api.admin_accept_world_coverage_revision('duindorp-halloween-2026',version,fingerprint,'Late goedgekeurde themapoort gecontroleerd') from coverage$$,'authorized review activates the exact visible candidate');
select ok(not(app_private.world_coverage_missing((select eid from coverage)) @> array['vampierrijk']),'reviewed policy now reflects the late themed house');
select isnt(app_private.start_ops_route_revision((select eid from coverage)),(select route_revision_before from coverage),'accepting coverage invalidates route revision even after portal change was already observed');
select isnt(app_private.live_planboard_hash((select eid from coverage)),(select board_hash_before from coverage),'accepted coverage invalidates stale planboard commands through the shared route revision');
select is((select settings_version from app_private.events where id=(select eid from coverage)),(select event_settings_before from coverage),'coverage review preserves unrelated event settings and start confirmations');
update coverage set route_revision_after=app_private.start_ops_route_revision(eid),board_hash_after=app_private.live_planboard_hash(eid);
select lives_ok($$select api.admin_accept_world_coverage_revision('duindorp-halloween-2026',version,fingerprint,'Late goedgekeurde themapoort gecontroleerd') from coverage$$,'identical acceptance retry is idempotent');
select is(app_private.start_ops_route_revision((select eid from coverage)),(select route_revision_after from coverage),'exact repeated acceptance preserves the route revision');
select is(app_private.live_planboard_hash((select eid from coverage)),(select board_hash_after from coverage),'exact repeated acceptance preserves the planboard input hash');
select is((select count(*) from app_private.child_world_awards where child_id=any((select children from coverage)::uuid[]) and origin='compensation'),(select 3*cardinality(children)::bigint from coverage),'all previously earned awards survive a changed policy');
select ok(not has_function_privilege('authenticated','app_private.award_missing_worlds(uuid,uuid,uuid,uuid,boolean,text)','execute'),'direct API clients cannot forge compensation');
select ok(not has_table_privilege('authenticated','app_private.world_coverage_policies','update'),'clients cannot bypass policy review');
select ok(not has_function_privilege('authenticated','app_private.start_ops_route_revision_before_closure_policy(uuid)','execute'),'clients cannot bypass policy-aware route revision');

-- Same initialization path used for events already closed at migration time, without a fake close.
update app_private.world_coverage_policies set policy_status='retired' where event_id=(select eid from coverage) and policy_status='active';
select app_private.refresh_world_coverage((select eid from coverage));
select is((select count(*) from app_private.world_coverage_policies where event_id=(select eid from coverage) and policy_status='active'),1::bigint,'already-closed event is initialized without toggling registration');
select is((select (settings->>'portalRegistrationOpen')::boolean from app_private.events where id=(select eid from coverage)),false,'initialization preserves closed house setting');
update app_private.portal_windows set opens_at='2026-10-31T21:00:00+01',closes_at='2026-10-31T21:30:00+01'
 where portal_id='12000000-0000-0000-0000-000000000004';
select ok(app_private.world_coverage_missing_now((select eid from coverage)) @> array['vampierrijk'],'a themed house opening after actual ordinary closing cannot cover that ordinary world');
select * from finish();
rollback;
