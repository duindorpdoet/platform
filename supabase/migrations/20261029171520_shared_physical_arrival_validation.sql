-- Shared physical reception rules for every caller. Administrative gathering
-- remains subject to start-slot capacity, and never consumes a house visit.
set lock_timeout='5s';

create or replace function app_private.portal_physical_identity(_portal uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce(p.application_id,p.id) from app_private.portals p where p.id=_portal
$$;

-- Linked portal records are aliases, not separate physical departure doors.
-- A published appointment keeps its frozen portal/point choice.
create or replace function app_private.start_departure_key(_point uuid)
returns uuid language sql stable security definer set search_path=''as $$
 select coalesce(app_private.portal_physical_identity(point.linked_portal_id),point.linked_portal_id,point.id)
 from app_private.start_points point where point.id=_point
$$;
create or replace function app_private.reserved_departure_key(_group uuid,_schedule uuid,_point uuid)
returns uuid language sql stable security definer set search_path=''as $$
 select coalesce((select coalesce(app_private.portal_physical_identity((publication.point_snapshot->>'linked_portal_id')::uuid),
   (publication.point_snapshot->>'linked_portal_id')::uuid,(publication.slot_snapshot->>'start_point_id')::uuid)
  from app_private.group_start_publications publication where publication.group_id=_group and publication.schedule_id is not distinct from _schedule
  order by publication.publication_order desc limit 1),app_private.start_departure_key(_point))
$$;
revoke all on function app_private.start_departure_key(uuid),app_private.reserved_departure_key(uuid,uuid,uuid)from public,anon,authenticated;

create or replace function app_private.portal_service_seconds(_portal uuid,_at timestamptz)
returns integer language sql stable security definer set search_path='' as $$
 select w.visit_seconds+w.buffer_seconds from app_private.portal_effective_windows(_portal) w
 where _at>=w.opens_at and case when w.is_finale then _at<=w.arrival_closes_at else _at<w.arrival_closes_at end
 order by w.opens_at,w.closes_at limit 1
$$;

-- Empty or retired future groups have no physical departure or gathering
-- demand. Their immutable publication/history remains available separately.
alter function app_private.start_schedule_reservations(uuid)rename to start_schedule_reservations_before_nonempty_groups;
revoke all on function app_private.start_schedule_reservations_before_nonempty_groups(uuid)from public,anon,authenticated;
create function app_private.start_schedule_reservations(_event_id uuid)
returns table(group_id uuid,schedule_id uuid,start_slot_id uuid,start_point_id uuid,starts_at timestamptz,child_count integer,finale_at timestamptz)
language sql stable security definer set search_path=''as $$
 select reservation.*from app_private.start_schedule_reservations_before_nonempty_groups(_event_id)reservation
 join app_private.walking_groups logical_group on logical_group.id=reservation.group_id
 where(reservation.child_count>0 and logical_group.retired_at is null)
  or exists(select 1 from app_private.group_runs begun where begun.group_id=reservation.group_id and begun.started_at is not null)
$$;
revoke all on function app_private.start_schedule_reservations(uuid)from public,anon,authenticated;

create or replace function app_private.portal_occupancy_intervals(_portal uuid,_at timestamptz)
returns table(group_id uuid,starts_at timestamptz,ends_at timestamptz,child_count integer)
language sql stable security definer set search_path='' as $$
 with aliases as materialized (
  select p.id from app_private.portals p where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(_portal)
 ), reserved as materialized (
  select r.group_id,r.reserved_from,r.reserved_until,r.child_count from app_private.portal_reservations r
  where r.portal_id in(select id from aliases) and (r.status in('active','completed')
   or(r.status='held' and(r.expires_at is null or r.expires_at>_at)))
 ), intended(group_id,starts_at,ends_at,child_count)as materialized (
  select v.group_id,v.starts_at,v.starts_at+make_interval(secs=>v.duration_seconds+v.buffer_seconds),
   case when latest.status in('live','paused') then
    (select count(*)::integer from app_private.run_participants participant where participant.run_id=latest.id
     and participant.attendance='present' and participant.departed_at is null)
   else (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=v.group_id and a.superseded_at is null)end
  from app_private.live_route_visits v join app_private.walking_groups logical_group on logical_group.id=v.group_id and logical_group.retired_at is null
  left join lateral(select r.id,r.status from app_private.group_runs r where r.group_id=v.group_id
   order by r.created_at desc,r.id desc limit 1)latest on true
  where v.portal_id in(select id from aliases) and v.kind<>'start' and v.retired_at is null
   and(v.run_stop_id is null or exists(select 1 from app_private.run_stops stop
    where stop.id=v.run_stop_id and stop.state='locked' and stop.opened_at is null))
   and coalesce(latest.status not in('completed','stopped'),true)
   and not exists(select 1 from reserved r where r.group_id=v.group_id)
 )
 select * from reserved
 union all select * from intended where child_count>0
 union all
 select pub.group_id,pub.starts_at,pub.starts_at+make_interval(secs=>app_private.portal_service_seconds((pub.point_snapshot->>'linked_portal_id')::uuid,pub.starts_at)),
  (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
   on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=pub.group_id and a.superseded_at is null)
 from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub
 where g.retired_at is null and exists(select 1 from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'where a.group_id=g.id and a.superseded_at is null)
  and (pub.point_snapshot->>'linked_portal_id')::uuid in(select id from aliases)
  and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)
  and not exists(select 1 from reserved r where r.group_id=g.id)
  and not exists(select 1 from app_private.live_route_visits v where v.group_id=g.id and v.retired_at is null)
  and not app_private.group_has_visited_portal(g.event_id,g.id,_portal)
 union all
 select r.group_id,r.starts_at,r.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,r.starts_at)),r.child_count
 from app_private.portals portal cross join lateral app_private.start_schedule_reservations(portal.event_id) r
 join app_private.start_points point on point.id=r.start_point_id and point.linked_portal_id in(select id from aliases)
 where portal.id=_portal and point.counts_as_first_portal_visit
  and not exists(select 1 from app_private.current_start_publication(r.group_id))
  and not exists(select 1 from reserved b where b.group_id=r.group_id)
  and not exists(select 1 from app_private.live_route_visits v where v.group_id=r.group_id and v.retired_at is null)
  and not app_private.group_has_visited_portal(portal.event_id,r.group_id,_portal)
$$;

create or replace function app_private.portal_interval_available_from_occupancy(
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

create or replace function app_private.portal_interval_available(
 _portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_at timestamptz
) returns boolean language sql stable security definer set search_path='' as $$
 with occupancy as materialized (
  select b.group_id,b.starts_at,b.ends_at,b.child_count from app_private.portal_occupancy_intervals(_portal,_at)b
  union all select v.group_id,null::timestamptz,null::timestamptz,
   (select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=v.first_stop_id and a.arrived)
  from app_private.group_portal_visits v where app_private.portal_physical_identity(v.portal_id)=app_private.portal_physical_identity(_portal)
 )
 select app_private.portal_interval_available_from_occupancy(_portal,_group,_from,_until,_children,
  coalesce((select jsonb_agg(to_jsonb(occupancy))from occupancy),'[]'))
$$;
revoke all on function app_private.portal_physical_identity(uuid) from public,anon,authenticated;

create or replace function app_private.live_planboard_warnings_from_visits(_event uuid,_changes jsonb,_visits jsonb) returns jsonb
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

-- Gathering availability belongs to the start point. A later physical house
-- visit is checked at its own arrival, including an explicitly reviewed first-
-- house alternative; its receiving window is not a gathering window.
create or replace function app_private.start_point_ready_at(_point_id uuid,_starts_at timestamptz)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select (app_private.start_point_safe_connection(p.id)
  or(p.active and nullif(trim(p.private_address),'')is not null
   and(app_private.start_point_location(p.id)->>'valid')::boolean
   and(p.linked_portal_id is null or exists(select 1 from app_private.portals linked
    where linked.id=p.linked_portal_id and linked.event_id=p.event_id and linked.lifecycle_status<>'archived'))
   and exists(select 1 from app_private.walking_groups g
    cross join lateral(select app_private.route_group_start_context(g.id)ctx)context
    cross join lateral(select v.portal_id from app_private.live_route_visits v where v.group_id=g.id
     and v.kind<>'start'and v.retired_at is null order by v.sequence limit 1)first_visit
    where g.event_id=p.event_id and context.ctx#>>'{pointSnapshot,id}'=p.id::text
     and(context.ctx->>'startsAt')::timestamptz=_starts_at
     and first_visit.portal_id is distinct from p.linked_portal_id)))
  and(p.available_from is null or _starts_at>=p.available_from)
  and(p.available_until is null or _starts_at<p.available_until)
  from app_private.start_points p where p.id=_point_id),false)
$$;

-- One effective appointment per physical group. A competing unpublished
-- revision does not reserve a second finale alongside its current publication.
create or replace function app_private.finale_occupancy_intervals(_event uuid,_at timestamptz)
returns table(group_id uuid,starts_at timestamptz,ends_at timestamptz,children integer)
language sql stable security definer set search_path='' as $$
 select schedule.*from(
 select g.id group_id,s.expected_finale_arrival_at starts_at,s.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds)ends_at,
  case when latest.status in('live','paused') then
   (select count(*)::integer from app_private.run_participants participant where participant.run_id=latest.id
    and participant.attendance='present' and participant.departed_at is null)
  else (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
   on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null)end children
 from app_private.walking_groups g left join lateral app_private.current_start_publication(g.id)pub on true
 left join lateral(select run.id,run.status from app_private.group_runs run where run.group_id=g.id
  order by run.created_at desc,run.id desc limit 1)latest on true
 join app_private.group_schedule_revisions s on s.id=coalesce(pub.schedule_id,g.current_schedule_revision_id)
 join app_private.event_route_settings settings on settings.event_id=g.event_id
 where g.event_id=_event and g.retired_at is null and s.state in('draft','published') and s.expected_finale_arrival_at is not null
 )schedule where schedule.children>0
 union all
 select r.group_id,r.reserved_from,r.reserved_until,r.child_count from app_private.portal_reservations r
 join app_private.event_route_settings settings on settings.event_id=r.event_id
  and app_private.portal_physical_identity(settings.final_portal_id)=app_private.portal_physical_identity(r.portal_id)
 where r.event_id=_event and(r.status in('active','completed') or(r.status='held' and(r.expires_at is null or r.expires_at>_at)))
$$;
create or replace function app_private.assert_start_schedule_capacity_readonly(_event_id uuid, _schedule_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; settings app_private.event_route_settings; service_interval interval;
  load_groups integer; load_children bigint; occupied jsonb; selected_groups uuid[];
begin
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  select array_agg(distinct s.group_id) into selected_groups from app_private.group_schedule_revisions s
   join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id where s.id=any(_schedule_ids);
  select coalesce(jsonb_agg(to_jsonb(q)),'[]') into occupied from(
   select r.group_id,r.starts_at,r.ends_at,r.children child_count from app_private.finale_occupancy_intervals(_event_id,statement_timestamp())r
    where not(r.group_id=any(coalesce(selected_groups,'{}'::uuid[])))
   union all
   select s.group_id,s.expected_finale_arrival_at,s.expected_finale_arrival_at+service_interval,
    (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
     on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=s.group_id and a.superseded_at is null)
   from app_private.group_schedule_revisions s where s.id=any(_schedule_ids)
  )q;
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
    perform app_private.assert_group_schedule_timing(candidate.group_id,candidate.start_slot_id,candidate.effective_ordinary_stop_at,candidate.expected_finale_arrival_at);
    if not app_private.valid_departure_time(candidate.starts_at) then
      raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode='23514'; end if;
    if not app_private.departure_time_in_window(_event_id,candidate.starts_at) then
      raise exception 'START_TIME_OUTSIDE_EVENT' using errcode='23514'; end if;
    if not app_private.start_point_ready_at(candidate.start_point_id,candidate.starts_at) then
      raise exception 'START_POINT_CLOSED' using errcode='23514'; end if;
    -- Coalesce aliases linked to the same real portal. Different slot IDs and
    -- start-point IDs never create a second departure at the same instant.
    select count(*) into load_groups from (
      select distinct r.group_id from app_private.start_schedule_reservations(_event_id) r
      where app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id)=app_private.reserved_departure_key(candidate.group_id,candidate.id,candidate.start_point_id)
        and r.starts_at=candidate.starts_at
      union select candidate.group_id
    ) physical_departures;
    if load_groups>1 then raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_slot_id=candidate.start_slot_id group by r.group_id) q;
    if load_groups>candidate.max_groups or load_children>candidate.max_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_point_id=candidate.start_point_id and r.starts_at=candidate.starts_at group by r.group_id) q;
    if load_groups>candidate.max_gathering_groups or load_children>candidate.max_gathering_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    if not app_private.portal_interval_available_from_occupancy(settings.final_portal_id,candidate.group_id,
     candidate.expected_finale_arrival_at,candidate.expected_finale_arrival_at+service_interval,
     (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
      on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null),occupied)then
      if not coalesce(settings.finale_available,false) then
        raise exception 'FINALE_NOT_CONFIRMED_AVAILABLE' using errcode='23514';end if;
      raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514';end if;
    -- Check a real linked first visit, not a gathering marker. A reviewed
    -- alternative is already validated against its actual physical arrival.
    if exists(select 1 from app_private.start_points point where point.id=candidate.start_point_id
     and point.linked_portal_id is not null and point.counts_as_first_portal_visit
     and(not exists(select 1 from app_private.live_route_visits v where v.group_id=candidate.group_id and v.kind<>'start' and v.retired_at is null)
      or exists(select 1 from app_private.live_route_visits v where v.group_id=candidate.group_id and v.portal_id=point.linked_portal_id
       and v.kind<>'start' and v.retired_at is null and v.starts_at=candidate.starts_at))
     and not app_private.portal_interval_available(point.linked_portal_id,candidate.group_id,candidate.starts_at,
      candidate.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,candidate.starts_at)),
      (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
       on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null),statement_timestamp()))then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514';end if;
  end loop;
end;
$function$;

create or replace function app_private.try_reserve_finale(_run_id uuid,_earliest_arrival timestamptz,_decision_at timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; g app_private.walking_groups; settings app_private.event_route_settings;
  v_child_count integer; candidate_time timestamptz; candidate_end timestamptz; deadline timestamptz;
  tick timestamptz; groups_at integer; children_at integer; fits boolean; reservation_id uuid; physical app_private.portal_windows;
begin
 select * into r from app_private.group_runs where id=_run_id for update;
 select * into g from app_private.walking_groups where id=r.group_id;
 perform 1 from app_private.events where id=g.event_id for update;
 perform pg_advisory_xact_lock(hashtextextended(g.event_id::text||':route-dispatch',0));
 select * into settings from app_private.event_route_settings where event_id=g.event_id;
 if r.id is null or settings.final_portal_id is null or not settings.finale_available then return null;end if;
 select count(*) into v_child_count from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
 if v_child_count=0 or v_child_count>settings.finale_max_concurrent_children then return null;end if;
 deadline:=app_private.schedule_latest_finale_arrival(r.schedule_revision_id);
 for candidate_time in
  select distinct t from (
   select greatest(settings.finale_opens_at,_earliest_arrival) t
   union all select q.ends_at from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q where q.group_id<>g.id
   union all select q.starts_at+make_interval(secs=>(select max(p.arrival_headway_seconds) from app_private.portals p
    where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(settings.final_portal_id)))
    from app_private.finale_occupancy_intervals(g.event_id,_decision_at)q where q.group_id<>g.id
   union all select w.opens_at from app_private.portal_windows w where w.portal_id=settings.final_portal_id
  ) candidates where t>=greatest(settings.finale_opens_at,_earliest_arrival) and t<=deadline order by t
 loop
  candidate_end:=candidate_time+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  fits:=false;
  for physical in select * from app_private.portal_windows w where w.portal_id=settings.final_portal_id
    and candidate_time>=w.opens_at and candidate_end<=w.closes_at and v_child_count<=w.max_children_per_visit
  loop
   fits:=true;
   for tick in select candidate_time union select q.starts_at from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q
    where q.group_id<>g.id and q.starts_at>candidate_time and q.starts_at<candidate_end
   loop
    select count(*),coalesce(sum(n),0) into groups_at,children_at from (
     select q.group_id,max(q.children) n from app_private.finale_occupancy_intervals(g.event_id,_decision_at) q
     where q.group_id<>g.id and q.starts_at<=tick and q.ends_at>tick group by q.group_id
    ) occupied;
    if groups_at+1>least(settings.finale_max_concurrent_groups,physical.max_concurrent_groups)
      or children_at+v_child_count>least(settings.finale_max_concurrent_children,physical.max_children_total) then fits:=false;exit;end if;
   end loop;
   exit when fits;
  end loop;
  if not fits or not app_private.portal_interval_available_from_occupancy(settings.final_portal_id,g.id,candidate_time,candidate_end,v_child_count,
   coalesce((select jsonb_agg(jsonb_build_object('group_id',q.group_id,'starts_at',q.starts_at,'ends_at',q.ends_at,'child_count',q.children))
    from app_private.finale_occupancy_intervals(g.event_id,_decision_at)q),'[]'))then continue;end if;
  select id into reservation_id from app_private.portal_reservations where run_id=r.id and kind='finale' and status in ('held','active')
    and reserved_from=candidate_time and reserved_until=candidate_end and portal_id=settings.final_portal_id and portal_reservations.child_count=v_child_count limit 1;
  if reservation_id is not null then return reservation_id;end if;
  update app_private.portal_reservations set status='cancelled',cancelled_reason='Vervangen door actuele finaleprognose',version=version+1
    where run_id=r.id and kind='finale' and status in ('held','active');
  insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
    values(g.event_id,settings.final_portal_id,g.id,r.id,'finale','held',candidate_time,candidate_end,v_child_count,settings.finale_closes_at)
    returning id into reservation_id;
  return reservation_id;
 end loop;
 return null;
end $$;

-- Collect genuine database writes, including subtransactions. A deferred check
-- sees the complete atomic batch, so a valid swap is never rejected halfway.
-- The private collector cannot be forged through a client session setting.
create table app_private.start_schedule_capacity_checks(
 transaction_id bigint not null,backend_pid integer not null,
 schedule_id uuid not null references app_private.group_schedule_revisions(id) on delete cascade,
 event_id uuid not null references app_private.events(id) on delete cascade,
 primary key(transaction_id,backend_pid,schedule_id)
);
alter table app_private.start_schedule_capacity_checks enable row level security;
revoke all on app_private.start_schedule_capacity_checks from public,anon,authenticated;
create function app_private.collect_start_schedule_capacity_check() returns trigger
language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 if new.state not in('draft','published')then return new;end if;
 select g.event_id into eid from app_private.walking_groups g where g.id=new.group_id;
 if app_private.admin_registration_group_started(new.group_id)then
  raise exception 'GROUP_ALREADY_STARTED' using errcode='23514';end if;
 insert into app_private.start_schedule_capacity_checks(transaction_id,backend_pid,schedule_id,event_id)
 values(txid_current(),pg_backend_pid(),new.id,eid)on conflict do nothing;
 return new;
end $$;
create trigger collect_start_schedule_capacity_check after insert or update of start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,state
 on app_private.group_schedule_revisions for each row execute function app_private.collect_start_schedule_capacity_check();
create function app_private.enforce_start_schedule_capacity_check()returns trigger
language plpgsql security definer set search_path='' as $$
declare eid uuid; ids uuid[];
begin
 select g.event_id into eid from app_private.walking_groups g where g.id=new.group_id;
 if not exists(select 1 from app_private.start_schedule_capacity_checks c where c.transaction_id=txid_current()and c.backend_pid=pg_backend_pid()and c.event_id=eid)then return null;end if;
 perform 1 from app_private.events where id=eid for update;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 select array_agg(q.id)into ids from(
  select distinct on(s.group_id)s.id from app_private.start_schedule_capacity_checks c
  join app_private.group_schedule_revisions s on s.id=c.schedule_id
  join app_private.walking_groups g on g.id=s.group_id
  where c.transaction_id=txid_current()and c.backend_pid=pg_backend_pid()and c.event_id=eid
   and(s.id=g.current_schedule_revision_id or exists(select 1 from app_private.current_start_publication(g.id)pub where pub.schedule_id=s.id))
  order by s.group_id,(s.id=g.current_schedule_revision_id)desc,s.revision desc
 )q;
 perform app_private.validate_start_schedule_capacity(eid,coalesce(ids,'{}'::uuid[]));
 delete from app_private.start_schedule_capacity_checks c where c.transaction_id=txid_current()and c.backend_pid=pg_backend_pid()and c.event_id=eid;
 return null;
end $$;
create constraint trigger enforce_start_schedule_capacity_check after insert or update of start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,state
 on app_private.group_schedule_revisions deferrable initially deferred for each row execute function app_private.enforce_start_schedule_capacity_check();
revoke all on function app_private.collect_start_schedule_capacity_check(),app_private.enforce_start_schedule_capacity_check()from public,anon,authenticated;
