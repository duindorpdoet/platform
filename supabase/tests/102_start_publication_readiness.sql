begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table readiness_fixture as select id eid,'23000000-0000-0000-0000-000000000001'::uuid gid,
 null::uuid point,null::uuid schedule,null::integer revision,null::jsonb checked,null::jsonb checkpoint
 from app_private.events where slug='duindorp-halloween-2026';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',finale_last_arrival_at='2026-10-31T20:30:00Z',
 finale_closes_at='2026-10-31T21:00:00Z',finale_available=false,planner_mode='dynamic'
 where event_id=(select eid from readiness_fixture);
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINALE_NOT_CONFIRMED_AVAILABLE","field":"finaleAvailable","action":"settings"}]'::jsonb,
 'filled finale times do not confirm actual availability and identify the exact checkbox') from readiness_fixture;
select is((api.admin_startregie_snapshot('duindorp-halloween-2026')#>>'{publicationReadiness,ready}')::boolean,false,
 'snapshot shares the same stored server readiness');
select is((select finale_available from app_private.event_route_settings where event_id=eid),false,
 'readiness never automatically enables finale availability') from readiness_fixture;
select is((select finale_opens_at from app_private.event_route_settings where event_id=eid),'2026-10-31T18:00:00Z'::timestamptz,
 'checking readiness preserves already stored finale times') from readiness_fixture;
update app_private.event_route_settings set planner_mode='shadow' where event_id=(select eid from readiness_fixture);
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"PLANNER_MODE_NOT_DYNAMIC","field":"plannerMode"}]'::jsonb,
 'planner mode is a separate concrete readiness cause') from readiness_fixture;
update app_private.event_route_settings set planner_mode='dynamic',finale_available=true,final_portal_id=null where event_id=(select eid from readiness_fixture);
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINAL_PORTAL_MISSING"}]'::jsonb,
 'a missing finale is distinct from unconfirmed availability') from readiness_fixture;
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=null where event_id=(select eid from readiness_fixture);
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINALE_TIMES_MISSING"}]'::jsonb,
 'missing saved times have a separate readiness cause') from readiness_fixture;
update app_private.event_route_settings set finale_opens_at='2026-10-31T18:00:00Z' where event_id=(select eid from readiness_fixture);
update app_private.portals set approval_status='submitted' where id='12000000-0000-0000-0000-000000000030';
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINAL_PORTAL_NOT_ELIGIBLE","action":"portals"}]'::jsonb,
 'a finale must actually be approved and active') from readiness_fixture;
update app_private.portals set approval_status='approved' where id='12000000-0000-0000-0000-000000000030';
create temp table saved_final_operation as select operation_status from app_private.portals where id='12000000-0000-0000-0000-000000000030';
update app_private.portals set operation_status='closed' where id='12000000-0000-0000-0000-000000000030';
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINALE_OPERATION_UNAVAILABLE","action":"portals"}]'::jsonb,
 'safe availability checkbox cannot override an explicitly closed physical finale') from readiness_fixture;
update app_private.portals set operation_status='paused' where id='12000000-0000-0000-0000-000000000030';
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINALE_OPERATION_UNAVAILABLE"}]'::jsonb,
 'a paused finale has the same concrete operational availability blocker') from readiness_fixture;
update app_private.portals set operation_status=(select operation_status from saved_final_operation) where id='12000000-0000-0000-0000-000000000030';
create temp table saved_final_position as select * from app_private.portal_private_locations where portal_id='12000000-0000-0000-0000-000000000030';
update app_private.portal_private_locations set marker_latitude=null,marker_longitude=null,geocoded_latitude=null,geocoded_longitude=null,latitude=null,longitude=null
 where portal_id='12000000-0000-0000-0000-000000000030';
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINAL_PORTAL_POSITION_INVALID"}]'::jsonb,
 'an unusable physical finale position is named before publication') from readiness_fixture;
update app_private.portal_private_locations l set marker_latitude=p.marker_latitude,marker_longitude=p.marker_longitude,
 geocoded_latitude=p.geocoded_latitude,geocoded_longitude=p.geocoded_longitude,latitude=p.latitude,longitude=p.longitude from saved_final_position p where l.portal_id=p.portal_id;
create temp table saved_final_windows as select * from app_private.portal_windows where portal_id='12000000-0000-0000-0000-000000000030';
delete from app_private.portal_windows where portal_id='12000000-0000-0000-0000-000000000030';
select ok(app_private.start_publication_readiness(eid)->'reasons' @> '[{"code":"FINALE_PHYSICAL_WINDOW_CONFLICT"}]'::jsonb,
 'configured finale times cannot replace a real physical opening') from readiness_fixture;
insert into app_private.portal_windows select * from saved_final_windows;
update readiness_fixture set point=(api.admin_startregie_start_point_save('duindorp-halloween-2026',null,
 '{"name":"Synthetic readiness start","publicLabel":"Synthetic readiness start","pointType":"gathering","privateAddress":"FICTIEF TESTADRES","geocodedLatitude":52.1,"geocodedLongitude":4.27,"active":true,"maxGroups":1,"maxChildren":30}'::jsonb,
 null,'Synthetische readinessregressie zonder echte deelnemers')->>'id')::uuid;
select api.admin_startregie_confirm_point('duindorp-halloween-2026',point,(select version from app_private.start_points where id=point)) from readiness_fixture;
update readiness_fixture set schedule=(api.admin_startregie_move_group(gid,point,'2026-10-31T16:00:00Z',
 (select version from app_private.walking_groups where id=gid),'neutral','Synthetisch opgeslagen concept voor readinesscontrole')->>'id')::uuid;
update readiness_fixture set revision=(select s.revision from app_private.group_schedule_revisions s where s.id=readiness_fixture.schedule);
update readiness_fixture set checkpoint=jsonb_build_object('group',(select to_jsonb(g) from app_private.walking_groups g where g.id=gid),
 'schedule',(select to_jsonb(s) from app_private.group_schedule_revisions s where s.id=schedule),
 'mailCount',(select count(*) from app_private.email_outbox),'runCount',(select count(*) from app_private.group_runs));
update readiness_fixture set checked=api.admin_startregie_publication_readiness('duindorp-halloween-2026',
 jsonb_build_array(jsonb_build_object('id',schedule,'revision',revision)),(select settings_version from app_private.events where id=eid));
select is((checked->>'ready')::boolean,true,'the saved exact appointment passes the shared timing and capacity rules') from readiness_fixture;
select ok(api.admin_startregie_publication_readiness('duindorp-halloween-2026',
 jsonb_build_array(jsonb_build_object('id',schedule,'revision',revision+1)),(select settings_version from app_private.events where id=eid))->'reasons' @> '[{"code":"STALE_REVISION"}]'::jsonb,
 'the shown revision must still be the saved revision') from readiness_fixture;
select ok(api.admin_startregie_publication_readiness('duindorp-halloween-2026',
 jsonb_build_array(jsonb_build_object('id',schedule,'revision',revision)),(select settings_version-1 from app_private.events where id=eid))->'reasons' @> '[{"code":"STALE_VERSION"}]'::jsonb,
 'a stale settings confirmation is distinct from missing finale times') from readiness_fixture;
select is(jsonb_build_object('group',(select to_jsonb(g) from app_private.walking_groups g where g.id=gid),
 'schedule',(select to_jsonb(s) from app_private.group_schedule_revisions s where s.id=schedule),
 'mailCount',(select count(*) from app_private.email_outbox),'runCount',(select count(*) from app_private.group_runs)),checkpoint,
 'readiness checks preserve groups, concepts, runs and communication') from readiness_fixture;
update app_private.event_route_settings set finale_available=false where event_id=(select eid from readiness_fixture);
select throws_ok($$select api.admin_startregie_confirm_and_send('duindorp-halloween-2026',
 jsonb_build_array(jsonb_build_object('id',schedule,'revision',revision)),(select settings_version from app_private.events where id=eid),gen_random_uuid()::text) from readiness_fixture$$,
 '23514','FINALE_NOT_CONFIRMED_AVAILABLE','direct API publication names the same exact unavailable-finale reason');
select is((select count(*) from app_private.email_outbox),(checkpoint->>'mailCount')::bigint,
 'a blocked direct publication queues no participant message') from readiness_fixture;
select is((select finale_max_concurrent_groups from app_private.event_route_settings where event_id=eid),1,
 'readiness does not increase the configured one-group finale capacity') from readiness_fixture;
select ok(not has_function_privilege('anon','api.admin_startregie_publication_readiness(text,jsonb,integer)','execute'),
 'publication preflight is not an anonymous endpoint');
select ok(not has_function_privilege('authenticated','app_private.assert_start_schedule_capacity_readonly(uuid,uuid[])','execute'),
 'the read-only internal assertion is not a direct authenticated API');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_publication_readiness('duindorp-halloween-2026','[{"id":"00000000-0000-0000-0000-000000000001","revision":1}]',1)$$,
 '42501','NOT_AUTHORIZED','a participant cannot inspect admin publication readiness');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local transaction_read_only=on;
select lives_ok($$select api.admin_startregie_publication_readiness('duindorp-halloween-2026',
 jsonb_build_array(jsonb_build_object('id',schedule,'revision',revision)),(select settings_version from app_private.events where id=eid)) from readiness_fixture$$,
 'readiness preflight takes no write locks and works in a read-only transaction');
select * from finish();
rollback;
