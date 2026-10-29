begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local jit=off;
-- Exact pre-context physical validator, test-local only.
create function pg_temp.reference_reception(
 _portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_occupancy jsonb
) returns boolean language sql stable security definer set search_path='' as $$
 with occupied as materialized (
  select * from jsonb_to_recordset(coalesce(_occupancy,'[]')) as q(group_id uuid,starts_at timestamptz,ends_at timestamptz,child_count integer)
 ), policy as materialized (
  select greatest(300,max(p.arrival_headway_seconds)) headway from app_private.portals p
  where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(_portal)
 )
 select coalesce(_from<_until and _children>=0 and exists(
  select 1 from app_private.portal_effective_windows(_portal) w cross join policy
  join app_private.portals p on p.id=_portal left join app_private.event_route_settings settings on settings.event_id=p.event_id
  where _from>=w.opens_at and case when w.is_finale then _from<=w.arrival_closes_at else _from<w.arrival_closes_at end
   and _until<=w.closes_at and _until>=_from+make_interval(secs=>w.visit_seconds+w.buffer_seconds)
   and _children<=w.max_children and(not w.is_finale or settings.finale_available)
   and _children+coalesce((select sum(q.children) from(
    select r.group_id,max(r.child_count) children from occupied r where r.group_id<>_group group by r.group_id
   )q),0)<=w.max_total_children
   and not exists(select 1 from occupied r where r.group_id<>_group
    and abs(extract(epoch from r.starts_at-_from))<greatest(w.headway_seconds,policy.headway))
   and not exists(select 1 from(
    select _from tick union select r.starts_at from occupied r where r.starts_at>=_from and r.starts_at<_until
   )boundary where
    (select count(distinct r.group_id) from occupied r where r.group_id<>_group and r.starts_at<=boundary.tick and r.ends_at>boundary.tick)>=w.max_groups
    or(w.max_concurrent_children is not null and _children+coalesce((select sum(q.children) from(
     select r.group_id,max(r.child_count) children from occupied r where r.group_id<>_group
      and r.starts_at<=boundary.tick and r.ends_at>boundary.tick group by r.group_id
    )q),0)>w.max_concurrent_children))
 ),false)
$$;

insert into app_private.events(id,slug,title,local_date,price_cents) values
 ('d1140000-0000-0000-0000-000000000001','synthetic-cached-reception','Synthetic cached reception','2026-10-31',250);
insert into app_private.portals(id,event_id,world_id,name,intensity,approval_status,lifecycle_status,operation_status,accessibility_status,arrival_headway_seconds)
 select fixture.id,'d1140000-0000-0000-0000-000000000001',p.world_id,fixture.label,p.intensity,'approved','active','open','step_free',fixture.headway
 from app_private.portals p cross join(values
 ('d1140000-0000-0000-0000-000000000011'::uuid,'Synthetic ordinary cached reception',600),
 ('d1140000-0000-0000-0000-000000000030'::uuid,'Synthetic finale cached reception',300))fixture(id,label,headway)
 where p.id='12000000-0000-0000-0000-000000000001';
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
 select id,'2026-10-31T16:00:00Z',case when id='d1140000-0000-0000-0000-000000000030' then '2026-10-31T20:30:00Z' else '2026-10-31T18:00:00Z' end::timestamptz,
 5,2,2,10,case when id='d1140000-0000-0000-0000-000000000030' then 1000 else 8 end
 from app_private.portals where event_id='d1140000-0000-0000-0000-000000000001';
insert into app_private.event_route_settings(event_id,first_start_at,global_ordinary_stop_at,final_portal_id,finale_opens_at,finale_last_arrival_at,finale_closes_at,finale_available,finale_show_seconds,finale_turnover_seconds,finale_max_concurrent_groups,finale_max_concurrent_children)
 values('d1140000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T19:30:00Z','d1140000-0000-0000-0000-000000000030','2026-10-31T18:00:00Z','2026-10-31T20:30:00Z','2026-10-31T21:00:00Z',true,360,120,2,5);
create temp table probe_context as
 select portal.id portal,coalesce((select jsonb_agg(to_jsonb(w)) from app_private.portal_effective_windows(portal.id)w),'[]') windows,
  (select greatest(300,max(p.arrival_headway_seconds)) from app_private.portals p where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(portal.id)) headway,
  (select s.finale_available from app_private.event_route_settings s where s.event_id=portal.event_id) finale_available
 from app_private.portals portal where portal.event_id='d1140000-0000-0000-0000-000000000001';
create temp table occupied_cases(value jsonb);
insert into occupied_cases values
 ('[]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T16:00:00Z","ends_at":"2026-10-31T16:07:00Z","child_count":4}]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T16:00:00Z","ends_at":"2026-10-31T16:07:00Z","child_count":4},{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T16:00:00Z","ends_at":"2026-10-31T16:07:00Z","child_count":4},{"group_id":"23000000-0000-0000-0000-000000000001","starts_at":"2026-10-31T16:00:00Z","ends_at":"2026-10-31T18:00:00Z","child_count":99}]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":null,"ends_at":null,"child_count":6}]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:08:00Z","child_count":3}]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:08:00Z","child_count":1},{"group_id":"23000000-0000-0000-0000-000000000003","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:08:00Z","child_count":1}]'),
 ('[{"group_id":"23000000-0000-0000-0000-000000000002","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:08:00Z","child_count":1},{"group_id":"23000000-0000-0000-0000-000000000003","starts_at":"2026-10-31T18:00:00Z","ends_at":"2026-10-31T18:05:00Z","child_count":1}]');
create temp table reception_probes as
 select context.portal,'23000000-0000-0000-0000-000000000001'::uuid own_group,times.at_time,
  times.at_time+make_interval(secs=>duration.seconds) until_time,children.count_children,occupied.value
 from probe_context context cross join(values
 ('2026-10-31T15:59:59.999999Z'::timestamptz),('2026-10-31T16:00:00Z'::timestamptz),
 ('2026-10-31T16:05:00Z'::timestamptz),('2026-10-31T16:10:00Z'::timestamptz),
 ('2026-10-31T17:57:00Z'::timestamptz),('2026-10-31T18:00:00Z'::timestamptz),
 ('2026-10-31T18:05:00Z'::timestamptz),('2026-10-31T20:22:00Z'::timestamptz),('2026-10-31T20:22:00.000001Z'::timestamptz))times(at_time)
 cross join(values(420),(480))duration(seconds) cross join(values(0),(2),(3),(11))children(count_children) cross join occupied_cases occupied;
insert into reception_probes(portal,own_group,at_time,until_time,count_children,value) values
 (null,'23000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2,'[]'),
 ('d1140000-0000-0000-0000-000000000099','23000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2,'[]'),
 ('d1140000-0000-0000-0000-000000000011',null,'2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2,'[]'),
 ('d1140000-0000-0000-0000-000000000011','23000000-0000-0000-0000-000000000001',null,'2026-10-31T16:07:00Z',2,'[]'),
 ('d1140000-0000-0000-0000-000000000011','23000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z',null,2,'[]'),
 ('d1140000-0000-0000-0000-000000000011','23000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',null,'[]'),
 ('d1140000-0000-0000-0000-000000000011','23000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2,null);
create temp table reception_results as
 select probes.*,pg_temp.reference_reception(portal,own_group,at_time,until_time,count_children,value) before_value,
 app_private.portal_interval_available_from_occupancy(portal,own_group,at_time,until_time,count_children,value) after_value
 from reception_probes probes;
select is((select count(*) from reception_results),1015::bigint,'independent original validator is exercised across a nonempty boundary/history/duplicate/null grid');
select is((select count(*) from reception_results where before_value is distinct from after_value),0::bigint,'fresh-policy wrapper exactly matches the complete original validator for every probe');
select ok((select bool_or(after_value) and bool_or(not after_value) from reception_results),'equivalence grid contains both genuinely available and rejected intervals');
select is((select count(*) from reception_results result join probe_context context on context.portal=result.portal
 where result.before_value is distinct from app_private.portal_interval_available_with_context(result.own_group,result.at_time,result.until_time,result.count_children,result.value,context.windows,context.headway,context.finale_available)),0::bigint,'cached statement context exactly matches the original physical predicate');
create function pg_temp.available(_portal uuid,_from text,_until text,_children integer,_occupied jsonb default '[]') returns boolean language sql as $$
 select app_private.portal_interval_available_from_occupancy(_portal,'23000000-0000-0000-0000-000000000001',_from::timestamptz,_until::timestamptz,_children,_occupied)
$$;
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2),'ordinary arrival exactly at opening fits full service plus buffer');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T15:59:59.999999Z','2026-10-31T16:07:00Z',2),'one microsecond early remains invalid');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T16:00:00Z','2026-10-31T16:05:00Z',2),'physical changeover cannot be omitted');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T17:57:00Z','2026-10-31T18:04:00Z',2),'ordinary full physical visit may use explicit five-minute grace');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T17:58:00.000001Z','2026-10-31T18:05:00.000001Z',2),'one microsecond beyond physical grace remains invalid');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T18:00:00Z','2026-10-31T18:07:00Z',2),'ordinary arrival at receiving close is invalid');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T20:22:00Z','2026-10-31T20:30:00Z',3),'finale show plus turnover ends exactly at its physical close');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T20:22:00.000001Z','2026-10-31T20:30:00.000001Z',3),'finale physical closure retains microsecond precision');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T20:22:00Z','2026-10-31T20:28:00Z',3),'finale turnover remains separate from show completion');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',3,(select value from occupied_cases where value::text like '%18:08%' and jsonb_array_length(value)=1)),'simultaneous finale-child maximum is retained');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',2,(select value from occupied_cases where value::text like '%18:08%' and jsonb_array_length(value)=1)),'overlapping finale fits only when both distinct-group and child caps fit');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T16:10:00Z','2026-10-31T16:17:00Z',2,(select value from occupied_cases where value::text like '%null%')),'null-time historical children count toward the exact cumulative maximum');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T16:10:00Z','2026-10-31T16:17:00Z',3,(select value from occupied_cases where value::text like '%null%')),'historical children cannot be erased by no current overlap');
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',2,(select value from occupied_cases where value::text like '%000000000003%' and value::text not like '%18:05%')),'two other distinct groups exceed the group maximum even while child and headway limits fit');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T18:05:00Z','2026-10-31T18:13:00Z',2,(select value from occupied_cases where value::text like '%000000000003%' and value::text like '%18:05%')),'the second group ending exactly at arrival no longer occupies a lane');
select ok(not app_private.portal_interval_available_with_context('23000000-0000-0000-0000-000000000001','2026-10-31T18:00:00Z','2026-10-31T18:08:00Z',2,'[]',windows,headway,null),'NULL finale authority cannot be treated as approval') from probe_context where portal='d1140000-0000-0000-0000-000000000030';
update app_private.event_route_settings set finale_available=false where event_id='d1140000-0000-0000-0000-000000000001';
select ok(not pg_temp.available('d1140000-0000-0000-0000-000000000030','2026-10-31T18:00:00Z','2026-10-31T18:08:00Z',2),'each server call captures the actual disabled-finale policy');
select is(app_private.portal_interval_available_from_occupancy('d1140000-0000-0000-0000-000000000030','23000000-0000-0000-0000-000000000001','2026-10-31T18:00:00Z','2026-10-31T18:08:00Z',2,'[]'),pg_temp.reference_reception('d1140000-0000-0000-0000-000000000030','23000000-0000-0000-0000-000000000001','2026-10-31T18:00:00Z','2026-10-31T18:08:00Z',2,'[]'),'disabled-finale behavior matches the original authority exactly');
select ok(pg_temp.available('d1140000-0000-0000-0000-000000000011','2026-10-31T16:00:00Z','2026-10-31T16:07:00Z',2),'disabled finale does not incorrectly close ordinary houses');
select ok(not has_function_privilege('authenticated','app_private.portal_interval_available_with_context(uuid,timestamptz,timestamptz,integer,jsonb,jsonb,integer,boolean)','execute'),'clients cannot forge a permissive reception context');
select ok(not has_function_privilege('anon','app_private.portal_interval_available_with_context(uuid,timestamptz,timestamptz,integer,jsonb,jsonb,integer,boolean)','execute'),'anonymous clients cannot invoke cached physical authority');
select ok(not has_function_privilege('authenticated','app_private.portal_interval_available_from_occupancy(uuid,uuid,timestamptz,timestamptz,integer,jsonb)','execute'),'the existing fresh-policy server validator remains private');
select * from finish();
rollback;
