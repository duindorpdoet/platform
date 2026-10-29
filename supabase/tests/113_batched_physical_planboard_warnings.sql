begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local jit=off;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- Independent pre-batching oracle from 20261029171520. It exists only in this
-- rolled-back test session; no slow compatibility function ships in production.
create function pg_temp.reference_physical_warnings(_event uuid,_changes jsonb,_visits jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 with start_context as materialized (
 select g.id group_id,coalesce(pub.starts_at,slot.starts_at) starts_at,
  coalesce(pub.point_snapshot,to_jsonb(point)) point,
  point.active,point.available_from,point.available_until,
  coalesce(case when pub.id is not null then app_private.routing_position(
   (pub.point_snapshot->>'marker_latitude')::numeric,(pub.point_snapshot->>'marker_longitude')::numeric,
   (pub.point_snapshot->>'geocoded_latitude')::numeric,(pub.point_snapshot->>'geocoded_longitude')::numeric,
   (pub.point_snapshot->>'latitude')::numeric,(pub.point_snapshot->>'longitude')::numeric)
   else app_private.start_point_location(point.id) end,'{}') position,
  schedule.expected_finale_arrival_at,schedule.id schedule_id
 from app_private.walking_groups g
 left join lateral app_private.current_start_publication(g.id)pub on true
 left join app_private.group_schedule_revisions schedule on schedule.id=coalesce(pub.schedule_id,g.current_schedule_revision_id)
 left join app_private.start_slots slot on slot.id=schedule.start_slot_id
 left join app_private.start_points point on point.id=coalesce((pub.slot_snapshot->>'start_point_id')::uuid,slot.start_point_id)
 where g.event_id=_event and g.retired_at is null
 ), group_sizes as materialized (
 select g.id group_id,
 (case when exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused')) then (select count(*) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id where r.group_id=g.id and r.status in ('live','paused') and rp.attendance='present' and rp.departed_at is null) else (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) end)::integer children
 from app_private.walking_groups g where g.event_id=_event and g.retired_at is null
 ), data as materialized (
  select item||coalesce((select(select jsonb_object_agg(entry.key,entry.value)from jsonb_each(change)entry
   where entry.key in('portalId','startsAt','durationSeconds','bufferSeconds','source'))
   from jsonb_array_elements(_changes)change where change->>'id'=item->>'id'),'{}'::jsonb)item
  from jsonb_array_elements(_visits) item
 ), v as materialized (
  select (item->>'id')::uuid id,(item->>'groupId')::uuid group_id,(item->>'portalId')::uuid portal_id,(item->>'sequence')::integer sequence,
  (item->>'startsAt')::timestamptz starts_at,(item->>'durationSeconds')::integer duration,(item->>'bufferSeconds')::integer buffer,
  (item->>'startsAt')::timestamptz+make_interval(secs=>(item->>'durationSeconds')::integer) service_ends_at,
  (item->>'startsAt')::timestamptz+make_interval(secs=>(item->>'durationSeconds')::integer+(item->>'bufferSeconds')::integer) ends_at,
  app_private.portal_physical_identity((item->>'portalId')::uuid) physical_id,
  item->>'kind' kind,item->>'status' status,
  size.children
  from data join group_sizes size on size.group_id=(item->>'groupId')::uuid
  where size.children>0 or item->>'status'<>'planned'
 ), occupancy as materialized (
  select physical_id,portal_id,group_id,starts_at,ends_at,children child_count from v where kind<>'start' and status not in ('completed','skipped')
  union all select app_private.portal_physical_identity(r.portal_id),r.portal_id,r.group_id,r.reserved_from,r.reserved_until,r.child_count
   from app_private.portal_reservations r where r.event_id=_event
    and(r.status in('active','completed') or(r.status='held' and(r.expires_at is null or r.expires_at>statement_timestamp())))
 ), locations as materialized (
  select portal_id,app_private.portal_location(portal_id) position from(select distinct portal_id from v)p
 ), availability_data as materialized (
  select p.portal_id,coalesce((select jsonb_agg(to_jsonb(q)) from(
   select o.group_id,o.starts_at,o.ends_at,o.child_count from occupancy o
    where o.physical_id=app_private.portal_physical_identity(p.portal_id)
   union all select history.group_id,null::timestamptz,null::timestamptz,
    (select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=history.first_stop_id and a.arrived)
   from app_private.group_portal_visits history
    where app_private.portal_physical_identity(history.portal_id)=app_private.portal_physical_identity(p.portal_id)
  )q),'[]') occupied from locations p
 ), sequence_edges as materialized (
 select group_id,sequence,lead(sequence) over(partition by group_id order by sequence) next_sequence
 from (select distinct group_id,sequence from v) seq
 ), notices as (
  select 'PORTAL_UNAVAILABLE' code,'block' severity,'Poort is niet actief, goedgekeurd of operationeel beschikbaar.' message,array[v.id] visits,array[v.group_id] groups
  from v join app_private.portals p on p.id=v.portal_id where v.status='planned' and v.kind<>'start' and (p.lifecycle_status<>'active' or p.approval_status<>'approved' or p.operation_status in ('paused','closed'))
  union all
  select 'ROUTE_SOURCE_CHANGED','warning','Dit bestaande routevoorstel hoort bij een eerdere startrevisie. Controleer de poortvolgorde en tijden tegen de nieuwe conceptafspraak; er is niets automatisch herschreven.',array[]::uuid[],array[g.id]
  from app_private.walking_groups g join app_private.live_route_plans source on source.group_id=g.id
  left join lateral(select r.* from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc,r.id desc limit 1) run on true
  where g.event_id=_event and g.retired_at is null and source.schedule_id is distinct from case when run.id is not null then run.schedule_revision_id else g.current_schedule_revision_id end
  union all
  select 'OPENING_WINDOW','block','Aankomst, bezoek en buffer passen niet binnen de effectieve poortopening en toegestane einduitloop.',array[v.id],array[v.group_id] from v
  where v.status='planned' and v.kind<>'start' and not exists(select 1 from app_private.portal_effective_windows(v.portal_id)w
   where v.starts_at>=w.opens_at and case when w.is_finale then v.starts_at<=w.arrival_closes_at else v.starts_at<w.arrival_closes_at end
    and v.ends_at<=w.closes_at and v.duration>=w.visit_seconds and v.buffer>=w.buffer_seconds and w.max_children>=v.children)
  union all
  select 'ACCESSIBILITY_REQUIREMENT','block','Deze fysieke poort is niet aantoonbaar drempelvrij voor een kind met een expliciete route-eis.',array[v.id],array[v.group_id]
  from v where v.status='planned' and v.kind<>'start' and app_private.portal_accessibility_status(v.portal_id)<>'step_free'
   and exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
    where a.group_id=v.group_id and a.superseded_at is null and app_private.child_step_free_requirement(rc.child_id)is true)
  union all
  select 'ACCESSIBILITY_REVIEW_REQUIRED','block','Beoordeel de toegankelijkheidswens of verifieer deze poort; de voorlopige route gebruikt uitsluitend aantoonbaar drempelvrije fysieke poorten.',array[v.id],array[v.group_id]
  from v where v.status='planned' and v.kind<>'start' and app_private.portal_accessibility_status(v.portal_id)<>'step_free'
   and exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
    where a.group_id=v.group_id and a.superseded_at is null and app_private.child_step_free_requirement(rc.child_id)is null)
  union all
  select 'LOCATION_MISSING','block','Poort heeft geen bruikbare locatie voor de route-engine.',array[v.id],array[v.group_id] from v where v.status='planned' and v.kind<>'start' and not app_private.portal_location_ready(v.portal_id)
  union all
  select 'ORDINARY_STOP_LIMIT','block','Gewone poort valt na de afgesproken stoptijd.',array[v.id],array[v.group_id]
  from v where v.status='planned' and v.kind='ordinary' and v.service_ends_at>app_private.group_ordinary_deadline(v.group_id)
  union all
  select 'HOUSEHOLD_STOP_LIMIT','block','Bezoek valt na de stoptijd van inschrijving '||r.reference||'.',array[v.id],array[v.group_id]
  from v join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.kind='ordinary' and r.requested_ordinary_stop_at is not null and r.requested_ordinary_stop_at is distinct from r.desired_end_at and v.service_ends_at>r.requested_ordinary_stop_at
  union all
  select 'START_PREFERENCE','warning','Afwijking van de gewenste starttijd van '||r.reference||'.',array[v.id],array[v.group_id]
  from v join start_context start on start.group_id=v.group_id join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.sequence=1 and r.preferred_start_at is not null and abs(extract(epoch from start.starts_at-r.preferred_start_at))>600
  union all
  select 'GROUP_OVERLAP','block','Twee bezoeken van dezelfde groep overlappen.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.id<b.id and a.kind<>'start' and b.kind<>'start' and a.starts_at<b.service_ends_at and b.starts_at<a.service_ends_at
  union all
  select 'DUPLICATE_PORTAL','block','Dezelfde poort staat meermaals in deze groepsroute.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.physical_id=b.physical_id and a.id<b.id and a.kind<>'start' and b.kind<>'start'
  union all
  select 'TRAVEL_TIME','block','Onvoldoende reistijd tussen het einde van het bezoek en de volgende poort (schatting van de route-engine).',array[a.id,b.id],array[a.group_id]
  from v a join sequence_edges seq on seq.group_id=a.group_id and seq.sequence=a.sequence
  join v b on b.group_id=a.group_id and b.sequence=seq.next_sequence
  join locations la on la.portal_id=a.portal_id join locations lb on lb.portal_id=b.portal_id
  left join start_context start on start.group_id=a.group_id
  left join lateral app_private.destination_estimate((case when a.kind='start' then start.position else la.position end->>'latitude')::numeric,(case when a.kind='start' then start.position else la.position end->>'longitude')::numeric,(lb.position->>'latitude')::numeric,(lb.position->>'longitude')::numeric) travel on true
  where b.status='planned' and (travel.duration_seconds is null or b.starts_at<(case when a.kind='start' then a.starts_at else a.service_ends_at end)+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'ARRIVAL_HEADWAY','block','Groepsaankomsten bij dezelfde fysieke poort liggen onder de ingestelde minimumafstand.',array[a.id,b.id],array[a.group_id,b.group_id]
  from v a join v b on a.physical_id=b.physical_id and a.group_id<>b.group_id and a.id<b.id
  where a.kind<>'start' and b.kind<>'start' and a.status not in('completed','skipped') and b.status not in('completed','skipped')
   and abs(extract(epoch from a.starts_at-b.starts_at))<(select max(p.arrival_headway_seconds)from app_private.portals p where app_private.portal_physical_identity(p.id)=a.physical_id)
  union all
  select 'RECEPTION_POLICY','block','Aankomstinterval, fysieke bezetting of groeps-/kindercapaciteit conflicteert met andere bezoeken of reserveringen.',array[v.id],array[v.group_id]
  from v join availability_data availability on availability.portal_id=v.portal_id where v.status='planned' and v.kind<>'start'
   and not app_private.portal_interval_available_from_occupancy(v.portal_id,v.group_id,v.starts_at,v.ends_at,v.children,availability.occupied)
  union all
  select 'GROUP_END_TIME_INFEASIBLE','block','De finale is niet binnen de maximale groepsuitloop afgerond.',array[v.id],array[v.group_id]
  from v join app_private.walking_groups g on g.id=v.group_id
  join app_private.group_schedule_revisions s on s.id=coalesce((select r.schedule_revision_id from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc limit 1),(select pub.schedule_id from app_private.current_start_publication(g.id)pub),g.current_schedule_revision_id)
  where v.kind='finale' and v.status='planned' and v.starts_at>app_private.schedule_latest_finale_arrival(s.id)
  union all
  select 'FINALE_WINDOW','block','De finale valt buiten het eigen finalevenster.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings s on s.event_id=_event where v.kind='finale' and v.status='planned' and (v.portal_id<>s.final_portal_id or not s.finale_available or v.starts_at<s.finale_opens_at or v.starts_at>s.finale_last_arrival_at or v.ends_at>s.finale_closes_at)
  union all
  select 'START_POINT_WINDOW','block','Het opgeslagen verzamelpunt is niet beschikbaar op het afgesproken startmoment.',array[v.id],array[v.group_id]
  from v join start_context start on start.group_id=v.group_id where v.status='planned' and v.kind='start'
   and(start.active is not true or(start.available_from is not null and v.starts_at<start.available_from)
    or(start.available_until is not null and v.starts_at>start.available_until))
  union all
  select 'START_APPOINTMENT_CHANGED','block','De administratieve start wijkt af van de opgeslagen startafspraak. Gebruik de bestaande startwijzigingsflow.',array[v.id],array[v.group_id]
  from v join start_context start on start.group_id=v.group_id where v.kind='start' and v.status='planned'
   and(v.starts_at is distinct from start.starts_at or v.portal_id is distinct from(start.point->>'linked_portal_id')::uuid)
  union all
  select 'START_TRAVEL_TIME','block','De eerste fysieke poort is niet bereikbaar vanaf het afgesproken startpunt en startmoment.',array[v.id],array[v.group_id]
  from v join start_context start on start.group_id=v.group_id join locations location on location.portal_id=v.portal_id
  left join lateral app_private.destination_estimate((start.position->>'latitude')::numeric,(start.position->>'longitude')::numeric,
    (location.position->>'latitude')::numeric,(location.position->>'longitude')::numeric)travel on true
  where v.status='planned' and v.kind<>'start' and not exists(select 1 from v earlier where earlier.group_id=v.group_id and earlier.kind<>'start' and earlier.sequence<v.sequence)
   and(start.starts_at is null or travel.duration_seconds is null or v.starts_at<start.starts_at+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'FINALE_APPOINTMENT_CHANGED','block','De fysieke finale wijkt af van de geldige gereserveerde finale-afspraak. Herverdeling vraagt een apart te beoordelen wijziging.',array[v.id],array[v.group_id]
  from v join start_context start on start.group_id=v.group_id where v.kind='finale' and v.status='planned'
   and v.starts_at is distinct from start.expected_finale_arrival_at
   and start.expected_finale_arrival_at<=app_private.schedule_latest_finale_arrival(start.schedule_id)
   and exists(select 1 from app_private.portal_effective_windows(v.portal_id)w where w.is_finale
    and start.expected_finale_arrival_at>=w.opens_at and start.expected_finale_arrival_at<=w.arrival_closes_at)
  union all
  select 'EVENING_OVERFLOW','warning','Dit bezoek loopt door na de ingestelde definitieve finalesluiting.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings settings on settings.event_id=_event where v.ends_at>settings.finale_closes_at
 )
 select coalesce(jsonb_agg(jsonb_build_object('code',code,'severity',severity,'message',message,'visitIds',visits,'groupIds',groups)),'[]'::jsonb) from (select distinct code,severity,message,visits,groups from notices) dedup
$$;

-- Compare complete warning objects as a set: the legacy jsonb_agg never
-- specified ordering, but message text and each ordered group/visit array count.
create function pg_temp.sorted_notices(_value jsonb) returns jsonb language sql as $$
 select coalesce(jsonb_agg(item order by item::text),'[]') from jsonb_array_elements(_value)item
$$;
create temp table headway_test as
 select p.event_id,p.id portal_id,p.application_id alias_id,
  '23000000-0000-0000-0000-000000000001'::uuid first_group,
  '23000000-0000-0000-0000-000000000002'::uuid second_group
 from app_private.portals p where p.id='12000000-0000-0000-0000-000000000001';
select ok((select count(*)=1 and bool_and(alias_id is not null) from headway_test),'synthetic seed contains the proven physical alias identity');
select ok((select count(distinct a.group_id)=2 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' cross join headway_test t where a.superseded_at is null and a.group_id in(t.first_group,t.second_group)),'both compared routes have actual participating children');
insert into app_private.portals
 select(jsonb_populate_record(null::app_private.portals,to_jsonb(p)||jsonb_build_object('id',t.alias_id,'application_id',null,'system_number',9997,'system_code','BATCH-ALIAS','name','Synthetic physical alias'))).*
 from app_private.portals p join headway_test t on t.portal_id=p.id;
insert into app_private.portal_windows
 select(jsonb_populate_record(null::app_private.portal_windows,to_jsonb(w)||jsonb_build_object('id',gen_random_uuid(),'portal_id',t.alias_id))).*
 from app_private.portal_windows w join headway_test t on t.portal_id=w.portal_id;
insert into app_private.portal_private_locations
 select(jsonb_populate_record(null::app_private.portal_private_locations,to_jsonb(location)||jsonb_build_object('portal_id',t.alias_id))).*
 from app_private.portal_private_locations location join headway_test t on t.portal_id=location.portal_id;
update app_private.portals set lifecycle_status='active',approval_status='approved',operation_status='open',accessibility_status='step_free',ordinary_hard_close=true
 where id in(select portal_id from headway_test union all select alias_id from headway_test);
update app_private.portals set arrival_headway_seconds=case when id=(select alias_id from headway_test) then 600 else 300 end
 where id in(select portal_id from headway_test union all select alias_id from headway_test);
update app_private.portal_windows set opens_at='2026-10-31T15:00:00Z',closes_at='2026-10-31T21:00:00Z',visit_minutes=5,buffer_minutes=0,max_concurrent_groups=1,max_children_per_visit=20,max_children_total=1000
 where portal_id in(select portal_id from headway_test union all select alias_id from headway_test);
create function pg_temp.pair_visits(_second timestamptz,_same_portal boolean default false)returns jsonb language sql as $$
 select jsonb_build_array(
 jsonb_build_object('id','d1130000-0000-0000-0000-000000000001','groupId',first_group,'portalId',portal_id,'sequence',1,'startsAt','2026-10-31T16:00:00Z','durationSeconds',300,'bufferSeconds',0,'kind','ordinary','status','planned'),
 jsonb_build_object('id','d1130000-0000-0000-0000-000000000002','groupId',second_group,'portalId',case when _same_portal then portal_id else alias_id end,'sequence',1,'startsAt',_second,'durationSeconds',300,'bufferSeconds',0,'kind','ordinary','status','planned')) from headway_test
$$;
create function pg_temp.reference_equal(_visits jsonb,_changes jsonb default '[]')returns boolean language sql as $$
 select pg_temp.sorted_notices(app_private.live_planboard_warnings_before_canonical_routes(event_id,_changes,_visits))=
  pg_temp.sorted_notices(pg_temp.reference_physical_warnings(event_id,_changes,_visits)) from headway_test
$$;
create function pg_temp.warning_count(_code text,_visits jsonb,_changes jsonb default '[]') returns bigint language sql as $$
 select count(*) from headway_test t cross join lateral jsonb_array_elements(app_private.live_planboard_warnings_before_canonical_routes(t.event_id,_changes,_visits)) n where n->>'code'=_code
$$;
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:09:59.999999Z')),'batched warnings exactly match all original warning objects for nonempty aliases');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',pg_temp.pair_visits('2026-10-31T16:09:59.999999Z')),1::bigint,'ten-minute physical alias headway rejects one microsecond early');
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:10:00Z')),'exact headway boundary retains complete original warning semantics');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',pg_temp.pair_visits('2026-10-31T16:10:00Z')),0::bigint,'exact ten-minute alias headway is accepted');
select is(pg_temp.warning_count('RECEPTION_POLICY',pg_temp.pair_visits('2026-10-31T16:10:00Z')),0::bigint,'valid distinct physical groups fit without extra capacity');
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:10:00.000001Z')),'one microsecond after the boundary remains equivalent');
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T15:59:59.999999Z')),'negative arrival separation preserves absolute-headway behavior');
create temp table draft_change as select jsonb_build_array(jsonb_build_object('id','d1130000-0000-0000-0000-000000000002','startsAt','2026-10-31T16:09:59.999999Z')) value;
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:10:00Z'),(select value from draft_change)),'manual preview changes are evaluated before the cached headway comparison');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',pg_temp.pair_visits('2026-10-31T16:10:00Z'),(select value from draft_change)),1::bigint,'preview cannot evade a physical alias conflict');

-- The previous all-alias MAX included inactive portal records. Do not narrow
-- its scope when materializing it, or introduce a different minimum policy.
update app_private.portals set lifecycle_status='concept',approval_status='draft',arrival_headway_seconds=900 where id=(select alias_id from headway_test);
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:10:00Z',true)),'inactive physical aliases retain the exact original maximum-headway policy');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',pg_temp.pair_visits('2026-10-31T16:10:00Z',true)),1::bigint,'inactive alias stricter policy still controls the shared physical door');
update app_private.portals set lifecycle_status='active',approval_status='approved',arrival_headway_seconds=600 where id=(select alias_id from headway_test);
create temp table duplicate_route as select jsonb_set(pg_temp.pair_visits('2026-10-31T16:10:00Z'),'{1,groupId}',to_jsonb(first_group)) value from headway_test;
select ok(pg_temp.reference_equal((select value from duplicate_route)),'duplicate aliases in one group retain all original duplicate-route warnings');
select is(pg_temp.warning_count('DUPLICATE_PORTAL',(select value from duplicate_route)),1::bigint,'physical aliases remain a duplicate visit for one family group');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',(select value from duplicate_route)),0::bigint,'alternative entries of the same physical group do not count as two arrivals');

-- Accessibility is cached from every assigned active child, never inferred
-- from free text and never restricted to just currently present run members.
update app_private.portals set accessibility_status='unknown' where id in(select portal_id from headway_test union all select alias_id from headway_test);
update app_private.children set step_free_required=null,accessibility_note='Synthetische toegankelijkheidsvraag ter beoordeling'
 where id=(select rc.child_id from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' cross join headway_test t where a.group_id=t.first_group and a.superseded_at is null order by rc.child_id limit 1);
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),'cached unresolved accessibility retains complete original notices');
select is(pg_temp.warning_count('ACCESSIBILITY_REVIEW_REQUIRED',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),1::bigint,'legacy free text remains a review flag for an unverified physical gate');
update app_private.children set step_free_required=true where accessibility_note='Synthetische toegankelijkheidsvraag ter beoordeling';
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),'cached explicit accessibility retains complete original notices');
select is(pg_temp.warning_count('ACCESSIBILITY_REQUIREMENT',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),1::bigint,'explicit drempelvrij requirement continues to block an unverified gate');
-- One group can legitimately contain both an explicit need and an unresolved
-- separate child's note. Both independent warning branches must survive.
with selected as(select rc.child_id,row_number()over(order by rc.child_id)n from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' cross join headway_test t where a.group_id=t.second_group and a.superseded_at is null)
 update app_private.children c set step_free_required=case when selected.n=1 then true else null end,accessibility_note='Synthetische gemengde toegankelijkheidsvraag'
 from selected where selected.child_id=c.id and selected.n<=2;
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),'mixed explicit and unresolved assigned needs retain both original warnings');
select is(pg_temp.warning_count('ACCESSIBILITY_REQUIREMENT',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),1::bigint,'mixed group keeps explicit need warning');
select is(pg_temp.warning_count('ACCESSIBILITY_REVIEW_REQUIRED',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),1::bigint,'mixed group separately keeps unresolved note warning');
update app_private.children set step_free_required=false where accessibility_note='Synthetische gemengde toegankelijkheidsvraag';
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),'explicit false wins over old free text exactly as in the original checker');
select is(pg_temp.warning_count('ACCESSIBILITY_REVIEW_REQUIRED',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),0::bigint,'explicit false clears unresolved status without interpreting the note');
update app_private.children set step_free_required=null,accessibility_note=null where accessibility_note='Synthetische gemengde toegankelijkheidsvraag';
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)),'undeclared empty notes remain effective false');
update app_private.portals set accessibility_status='step_free' where id in(select portal_id from headway_test union all select alias_id from headway_test);
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),'verified physical accessibility suppresses the same notices as before');
select is(pg_temp.warning_count('ACCESSIBILITY_REQUIREMENT',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),0::bigint,'verified step-free physical visit meets the declared need');

-- Distinct sequence edges skip a numeric hole, while every duplicate row at
-- the preceding sequence still produces its own actual adjacency/travel check.
create temp table adjacent_cases as select jsonb_build_array(
 (pg_temp.pair_visits('2026-10-31T16:10:00Z')->0),
 (pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)||jsonb_build_object('id','d1130000-0000-0000-0000-000000000003','portalId','12000000-0000-0000-0000-000000000002','startsAt','2026-10-31T16:01:00Z'),
 (pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)||jsonb_build_object('id','d1130000-0000-0000-0000-000000000004','portalId','12000000-0000-0000-0000-000000000003','sequence',4,'startsAt','2026-10-31T16:02:00Z')) value;
select ok(pg_temp.reference_equal((select value from adjacent_cases)),'cached adjacency keeps duplicate sequence combinations and numeric holes');
select is(pg_temp.warning_count('TRAVEL_TIME',(select value from adjacent_cases)),2::bigint,'each duplicate preceding row retains its own insufficient-travel warning');
update adjacent_cases set value=jsonb_set(value,'{0,kind}','"start"');
select ok(pg_temp.reference_equal((select value from adjacent_cases)),'administrative start still measures from the frozen start position and start moment');

-- Cached ordinary windows preserve the strict receiving close, physical end
-- and service+buffer distinctions, including a single microsecond at the edge.
update app_private.portal_windows set closes_at='2026-10-31T16:05:00Z' where portal_id in(select portal_id from headway_test union all select alias_id from headway_test);
select ok(pg_temp.reference_equal(jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),'ordinary physical end at exact hard close retains original windows');
select is(pg_temp.warning_count('OPENING_WINDOW',jsonb_build_array(pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)),0::bigint,'complete ordinary visit may end exactly at its hard close');
create temp table late_window as select jsonb_build_array((pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)||jsonb_build_object('startsAt','2026-10-31T16:00:00.000001Z')) value;
select ok(pg_temp.reference_equal((select value from late_window)),'cached ordinary physical close keeps microsecond precision');
select is(pg_temp.warning_count('OPENING_WINDOW',(select value from late_window)),1::bigint,'one microsecond past physical hard close remains invalid');
update app_private.portal_windows set closes_at='2026-10-31T21:00:00Z' where portal_id in(select portal_id from headway_test union all select alias_id from headway_test);
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T16:00:00Z',finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',finale_show_seconds=360,finale_turnover_seconds=120,finale_available=true where event_id=(select event_id from headway_test);
update app_private.portal_windows set opens_at='2026-10-31T16:00:00Z',closes_at='2026-10-31T20:30:00Z',max_children_per_visit=20 where portal_id='12000000-0000-0000-0000-000000000030';
create temp table finale_window as select jsonb_build_array((pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)||jsonb_build_object('portalId','12000000-0000-0000-0000-000000000030','kind','finale','startsAt','2026-10-31T20:22:00Z','durationSeconds',360,'bufferSeconds',120)) value;
select ok(pg_temp.reference_equal((select value from finale_window)),'cached finale window keeps the exact physical/configured intersection');
select is(pg_temp.warning_count('OPENING_WINDOW',(select value from finale_window)),0::bigint,'show and turnover can finish exactly at physical finale close');
update finale_window set value=jsonb_set(value,'{0,startsAt}','"2026-10-31T20:22:00.000001Z"');
select ok(pg_temp.reference_equal((select value from finale_window)),'cached finale window keeps microsecond physical-close rejection');
select is(pg_temp.warning_count('OPENING_WINDOW',(select value from finale_window)),1::bigint,'finale receives no extra ordinary grace for one microsecond');

-- A genuinely begun group with nobody currently present still owns its actual
-- completed physical reservation/buffer. Planned zero-child rows are omitted.
insert into app_private.group_runs(id,group_id,active_plan_version_id,status,started_at)
 select 'd1130000-0000-0000-0000-000000000010',g.id,g.current_plan_version_id,'live',clock_timestamp()-interval '1 hour'
 from app_private.walking_groups g join headway_test t on t.second_group=g.id;
insert into app_private.portal_reservations(id,event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
 select 'd1130000-0000-0000-0000-000000000011',event_id,alias_id,second_group,'d1130000-0000-0000-0000-000000000010','ordinary','completed','2026-10-31T16:00:00Z','2026-10-31T16:12:00Z',3 from headway_test;
create temp table actual_buffer as select jsonb_build_array(
 (pg_temp.pair_visits('2026-10-31T16:10:00Z')->0)||jsonb_build_object('startsAt','2026-10-31T16:10:00Z'),
 (pg_temp.pair_visits('2026-10-31T16:10:00Z')->1)||jsonb_build_object('startsAt','2026-10-31T16:00:00Z','status','completed','durationSeconds',360,'bufferSeconds',360)) value;
select is((select count(*) from app_private.run_participants where run_id='d1130000-0000-0000-0000-000000000010'),0::bigint,'begun fixture has zero actual present children rather than an empty unbegun route');
select ok(pg_temp.reference_equal((select value from actual_buffer)),'actual zero-child completed occupancy preserves all original warning objects');
select is(pg_temp.warning_count('RECEPTION_POLICY',(select value from actual_buffer)),1::bigint,'completed reservation buffer still blocks another group until its physical end');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',(select value from actual_buffer)),0::bigint,'completed visits are excluded from planned arrival-pair warnings');
select is(pg_temp.warning_count('ARRIVAL_HEADWAY',pg_temp.pair_visits('2026-10-31T16:09:59.999999Z')),0::bigint,'zero-child future rows do not introduce fictitious arrival demand');
select ok(pg_temp.reference_equal(pg_temp.pair_visits('2026-10-31T16:09:59.999999Z')),'zero-child planned filtering stays equivalent');
-- An alternate held revision of the same physical group counts once.
insert into app_private.portal_reservations(id,event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
 select 'd1130000-0000-0000-0000-000000000012',event_id,portal_id,second_group,'ordinary','held','2026-10-31T16:00:00Z','2026-10-31T16:12:00Z',3 from headway_test;
update app_private.portal_windows set max_concurrent_groups=2 where portal_id in(select portal_id from headway_test union all select alias_id from headway_test);
select ok(pg_temp.reference_equal((select value from actual_buffer)),'duplicate reservation revisions preserve distinct physical-group capacity semantics');
select is(pg_temp.warning_count('RECEPTION_POLICY',(select value from actual_buffer)),0::bigint,'two revisions of the same physical group do not consume two capacity slots');
select ok(not has_function_privilege('authenticated','app_private.live_planboard_warnings_before_canonical_routes(uuid,jsonb,jsonb)','execute'),'optimized authority remains private to the canonical wrapper');
select ok(not has_function_privilege('anon','app_private.live_planboard_warnings_before_canonical_routes(uuid,jsonb,jsonb)','execute'),'anonymous clients cannot invoke the private cached snapshot checks');
select * from finish();
rollback;
