begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
-- This event owns no schedules, publications or participants; capacity changes
-- cannot invalidate another synthetic fixture's deliberately frozen starts.
insert into app_private.events(id,slug,title,local_date,price_cents) values
 ('d1080000-0000-0000-0000-000000000001','synthetic-reception-policy','Synthetic reception policy','2026-10-31',250);
insert into app_private.portals(id,event_id,world_id,name,intensity,approval_status,lifecycle_status)
 select fixture.id,'d1080000-0000-0000-0000-000000000001',p.world_id,fixture.label,p.intensity,'approved','active'
 from app_private.portals p cross join(values
  ('d1080000-0000-0000-0000-000000000011'::uuid,'Synthetic ordinary reception'),
  ('d1080000-0000-0000-0000-000000000030'::uuid,'Synthetic finale reception'))fixture(id,label)
 where p.id='12000000-0000-0000-0000-000000000001';
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
 select id,'2026-10-31T16:00:00Z','2026-10-31T21:00:00Z',6,2,2,10,1000 from app_private.portals where event_id='d1080000-0000-0000-0000-000000000001';
insert into app_private.event_route_settings(event_id,first_start_at,global_ordinary_stop_at,final_portal_id,finale_opens_at,finale_last_arrival_at,finale_closes_at,finale_available,finale_show_seconds,finale_turnover_seconds,finale_max_concurrent_groups,finale_max_concurrent_children)
 values('d1080000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T19:30:00Z','d1080000-0000-0000-0000-000000000030','2026-10-31T17:30:00Z','2026-10-31T20:30:00Z','2026-10-31T21:00:00Z',true,360,120,1,5);
select is((select arrival_headway_seconds from app_private.portals where id='d1080000-0000-0000-0000-000000000011'),300,'shared default is five minutes');
select throws_ok($$update app_private.portals set arrival_headway_seconds=299 where id='d1080000-0000-0000-0000-000000000011'$$,'23514',null,'headway below five minutes is invalid');
select throws_ok($$update app_private.portals set arrival_headway_seconds=301 where id='d1080000-0000-0000-0000-000000000011'$$,'23514',null,'headway must use whole minutes');
select throws_ok($$update app_private.portals set ordinary_end_grace_seconds=301 where id='d1080000-0000-0000-0000-000000000011'$$,'23514',null,'ordinary grace cannot exceed five minutes');
update app_private.portal_windows set opens_at='2026-10-31T16:00:00Z',closes_at='2026-10-31T18:00:00Z',visit_minutes=6,buffer_minutes=2,max_concurrent_groups=2,max_children_per_visit=10,max_children_total=1000 where portal_id='d1080000-0000-0000-0000-000000000011';
create function pg_temp.reception(_from text,_until text,_occupied jsonb default '[]') returns boolean language sql as $$
 select app_private.portal_interval_available_from_occupancy('d1080000-0000-0000-0000-000000000011','23000000-0000-0000-0000-000000000001',_from::timestamptz,_until::timestamptz,3,_occupied)
$$;
create temp table reception_occupancy as select '[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T16:00:00Z","ends_at":"2026-10-31T16:08:00Z","child_count":3}]'::jsonb value;
select is(pg_temp.reception('2026-10-31T16:04:59Z','2026-10-31T16:12:59Z',(select value from reception_occupancy)),false,'4:59 fails even with overlap capacity');
select is(pg_temp.reception('2026-10-31T16:05:00Z','2026-10-31T16:13:00Z',(select value from reception_occupancy)),true,'5:00 allows overlapping service when two groups fit');
update app_private.portal_windows set max_concurrent_groups=1 where portal_id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T16:05:00Z','2026-10-31T16:13:00Z',(select value from reception_occupancy)),false,'headway does not increase concurrent group capacity');
select is(pg_temp.reception('2026-10-31T16:08:00Z','2026-10-31T16:16:00Z',(select value from reception_occupancy)),true,'next arrival can use the exact end of physical occupancy');
update app_private.portal_windows set max_concurrent_groups=2,max_children_total=5 where portal_id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T16:08:00Z','2026-10-31T16:16:00Z',(select value from reception_occupancy)),false,'cumulative child limit remains distinct from simultaneous capacity');
update app_private.portal_windows set max_children_total=1000 where portal_id='d1080000-0000-0000-0000-000000000011';
update app_private.portals set arrival_headway_seconds=600 where id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T16:09:59Z','2026-10-31T16:17:59Z',(select value from reception_occupancy)),false,'per-house ten-minute override rejects 9:59');
select is(pg_temp.reception('2026-10-31T16:10:00Z','2026-10-31T16:18:00Z',(select value from reception_occupancy)),true,'per-house ten-minute override permits 10:00');
update app_private.portals set arrival_headway_seconds=300 where id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T15:59:59Z','2026-10-31T16:07:59Z'),false,'zero early-arrival tolerance');
select is(pg_temp.reception('2026-10-31T16:00:00Z','2026-10-31T16:08:00Z'),true,'arrival at opening fits');
select is(pg_temp.reception('2026-10-31T16:00:00Z','2026-10-31T16:06:00Z'),false,'required changeover cannot be omitted');
update app_private.portal_windows set closes_at='2026-10-31T17:00:00Z' where portal_id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T16:57:00Z','2026-10-31T17:05:00Z'),true,'full service and buffer may use exactly five minutes ordinary grace');
select is(pg_temp.reception('2026-10-31T16:57:01Z','2026-10-31T17:05:01Z'),false,'physical occupancy one second past grace fails');
update app_private.portal_windows set visit_minutes=2,buffer_minutes=0 where portal_id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T17:00:01Z','2026-10-31T17:02:01Z'),false,'grace never permits a new arrival after receiving closes');
update app_private.portals set ordinary_hard_close=true where id='d1080000-0000-0000-0000-000000000011';
select is(pg_temp.reception('2026-10-31T16:59:00Z','2026-10-31T17:01:00Z'),false,'explicit hard closing has zero grace');
select is(pg_temp.reception('2026-10-31T16:58:00Z','2026-10-31T17:00:00Z'),true,'physical occupancy may end exactly at a hard close');

update app_private.event_route_settings set finale_opens_at='2026-10-31T17:30:00Z',finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',finale_show_seconds=360,finale_turnover_seconds=120,finale_max_concurrent_groups=1,finale_max_concurrent_children=5 where event_id=(select id from app_private.events where slug='synthetic-reception-policy');
update app_private.portal_windows set opens_at='2026-10-31T17:59:00Z',closes_at='2026-10-31T20:30:00Z',max_concurrent_groups=100,max_children_per_visit=100,max_children_total=1000 where portal_id='d1080000-0000-0000-0000-000000000030';
create function pg_temp.finale_reception(_from text,_until text,_occupied jsonb default '[]')returns boolean language sql as $$
 select app_private.portal_interval_available_from_occupancy('d1080000-0000-0000-0000-000000000030','23000000-0000-0000-0000-000000000001',_from::timestamptz,_until::timestamptz,3,_occupied)
$$;
select is((select opens_at from app_private.portal_effective_windows('d1080000-0000-0000-0000-000000000030')limit 1),'2026-10-31T17:59:00Z'::timestamptz,'physical 18:59 opening overrides global 18:30 opening');
select is(pg_temp.finale_reception('2026-10-31T17:58:59Z','2026-10-31T18:06:59Z'),false,'physical finale cannot begin before its own opening');
select is(pg_temp.finale_reception('2026-10-31T17:59:00Z','2026-10-31T18:07:00Z'),true,'physical finale begins exactly at effective opening');
select is(pg_temp.finale_reception('2026-10-31T20:22:00Z','2026-10-31T20:30:00Z'),true,'show and turnover finish exactly at definitive physical close');
select is(pg_temp.finale_reception('2026-10-31T20:22:01Z','2026-10-31T20:30:01Z'),false,'finale receives no ordinary-house end grace');
select is(pg_temp.finale_reception('2026-10-31T20:22:00Z','2026-10-31T20:28:00Z'),false,'show completion alone cannot omit physical turnover');
create temp table finale_occupancy as select '[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:08:00Z","child_count":3}]'::jsonb value;
select is(pg_temp.finale_reception('2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',(select value from finale_occupancy)),false,'six-minute show plus two-minute turnover cannot accept five-minute cadence with one group');
select is(pg_temp.finale_reception('2026-10-31T18:08:00Z','2026-10-31T18:16:00Z',(select value from finale_occupancy)),true,'eight-minute physical cadence fits one-group finale');
update app_private.event_route_settings set finale_max_concurrent_groups=2 where event_id=(select id from app_private.events where slug='synthetic-reception-policy');
select is(pg_temp.finale_reception('2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',(select value from finale_occupancy)),false,'separate simultaneous finale-child maximum is preserved');
select is(app_private.portal_interval_available_from_occupancy('d1080000-0000-0000-0000-000000000030','23000000-0000-0000-0000-000000000001','2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',2,(select value from finale_occupancy)),true,'headway overlap is allowed only when both group and child maxima fit');
select ok(not has_function_privilege('authenticated','app_private.portal_interval_available_from_occupancy(uuid,uuid,timestamptz,timestamptz,integer,jsonb)','execute'),'physical authority is private');
select ok(not has_function_privilege('anon','api.portal_planning_policy_save(uuid,integer,jsonb,text)','execute'),'anonymous users cannot change reception policy');
select * from finish();
rollback;
