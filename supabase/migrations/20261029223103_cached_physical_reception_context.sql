-- A snapshot captures one statement-consistent physical context per portal.
-- Both the public-facing private validator and the snapshot use this ONE exact
-- interval predicate. No candidate can obtain extra headway, time or capacity.
set lock_timeout='5s';

create function app_private.portal_interval_available_with_context(
 _group uuid,_from timestamptz,_until timestamptz,_children integer,
 _occupancy jsonb,_windows jsonb,_headway integer,_finale_available boolean
) returns boolean language sql stable security definer set search_path='' as $$
 with occupied as materialized (
  select * from jsonb_to_recordset(coalesce(_occupancy,'[]')) as q(group_id uuid,starts_at timestamptz,ends_at timestamptz,child_count integer)
 ), windows as materialized (
  select * from jsonb_to_recordset(coalesce(_windows,'[]')) as w(
   opens_at timestamptz,arrival_closes_at timestamptz,closes_at timestamptz,
   visit_seconds integer,buffer_seconds integer,max_groups integer,max_children integer,
   max_total_children integer,headway_seconds integer,is_finale boolean,max_concurrent_children integer)
 )
 select coalesce(_from<_until and _children>=0 and exists(
  select 1 from windows w
  where _from>=w.opens_at and case when w.is_finale then _from<=w.arrival_closes_at else _from<w.arrival_closes_at end
   and _until<=w.closes_at and _until>=_from+make_interval(secs=>w.visit_seconds+w.buffer_seconds)
   and _children<=w.max_children and(not w.is_finale or _finale_available)
   and _children+coalesce((select sum(q.children) from(
    select r.group_id,max(r.child_count) children from occupied r where r.group_id<>_group group by r.group_id
   )q),0)<=w.max_total_children
   and not exists(select 1 from occupied r where r.group_id<>_group
    and abs(extract(epoch from r.starts_at-_from))<greatest(w.headway_seconds,_headway))
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
revoke all on function app_private.portal_interval_available_with_context(uuid,timestamptz,timestamptz,integer,jsonb,jsonb,integer,boolean) from public,anon,authenticated;

-- Existing API/server callers still get current trusted database policy. Keep
-- the original function identity, signature and private execution rights.
create or replace function app_private.portal_interval_available_from_occupancy(
 _portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_occupancy jsonb
) returns boolean language sql stable security definer set search_path='' as $$
 with context as materialized (
  select coalesce((select jsonb_agg(to_jsonb(w)) from app_private.portal_effective_windows(_portal)w),'[]') windows,
   (select greatest(300,max(p.arrival_headway_seconds)) from app_private.portals p
    where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(_portal)) headway,
   (select settings.finale_available from app_private.portals p
    left join app_private.event_route_settings settings on settings.event_id=p.event_id where p.id=_portal) finale_available
 )
 select app_private.portal_interval_available_with_context(_group,_from,_until,_children,_occupancy,context.windows,context.headway,context.finale_available)
 from context
$$;
revoke all on function app_private.portal_interval_available_from_occupancy(uuid,uuid,timestamptz,timestamptz,integer,jsonb) from public,anon,authenticated;

create or replace function app_private.live_planboard_warnings_before_canonical_routes(_event uuid,_changes jsonb,_visits jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 with physical_headways as materialized (
  -- This is the same all-alias MAX as before: inactive records and aliases in
  -- another event are not silently excluded. Identity is coalesce(application_id,id).
  select coalesce(p.application_id,p.id) physical_id,max(p.arrival_headway_seconds) headway_seconds
  from app_private.portals p group by coalesce(p.application_id,p.id)
 ), start_context as materialized (
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
 ), assigned_children as materialized (
  select distinct rc.child_id from group_sizes size
  join app_private.group_registrations a on a.group_id=size.group_id and a.superseded_at is null
  join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
 ), child_requirements as materialized (
  select child_id,app_private.child_step_free_requirement(child_id) requirement from assigned_children
 ), group_requirements as materialized (
  select a.group_id,bool_or(child.requirement is true) step_free_required,bool_or(child.requirement is null) review_required
  from group_sizes size join app_private.group_registrations a on a.group_id=size.group_id and a.superseded_at is null
  join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
  join child_requirements child on child.child_id=rc.child_id group by a.group_id
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
  select portal_id,app_private.portal_physical_identity(portal_id) physical_id,app_private.portal_location(portal_id) position,app_private.portal_accessibility_status(portal_id) accessibility_status from(select distinct portal_id from v)p
 ), effective_windows as materialized (
  select location.portal_id,w.* from locations location
  cross join lateral app_private.portal_effective_windows(location.portal_id)w
 ), reception_context as materialized (
  select location.portal_id,
   coalesce((select jsonb_agg(to_jsonb(w)) from effective_windows w where w.portal_id=location.portal_id),'[]') windows,
   greatest(300,(select policy.headway_seconds from physical_headways policy where policy.physical_id=location.physical_id)) headway,
   (select settings.finale_available from app_private.portals p
    left join app_private.event_route_settings settings on settings.event_id=p.event_id where p.id=location.portal_id) finale_available
  from locations location
 ), availability_data as materialized (
  select p.portal_id,coalesce((select jsonb_agg(to_jsonb(q)) from(
   select o.group_id,o.starts_at,o.ends_at,o.child_count from occupancy o
    where o.physical_id=p.physical_id
   union all select history.group_id,null::timestamptz,null::timestamptz,
    (select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=history.first_stop_id and a.arrived)
   from app_private.group_portal_visits history
    where app_private.portal_physical_identity(history.portal_id)=p.physical_id
  )q),'[]') occupied from locations p
 ), sequence_edges as materialized (
 select group_id,sequence,lead(sequence) over(partition by group_id order by sequence) next_sequence
 from (select distinct group_id,sequence from v) seq
 ), adjacent_visits as materialized (
  -- Freeze the actual adjacent pairs before location/travel joins. This keeps
  -- all matching entries for duplicate sequence numbers without a huge nested
  -- loop over every route visit, sequence edge and destination location.
  select a.id from_visit_id,b.id to_visit_id,a.group_id,a.kind from_kind,
   a.portal_id from_portal_id,b.portal_id to_portal_id,a.starts_at from_starts_at,
   a.service_ends_at,b.starts_at to_starts_at,b.status to_status
  from v a join sequence_edges seq on seq.group_id=a.group_id and seq.sequence=a.sequence
  join v b on b.group_id=a.group_id and b.sequence=seq.next_sequence
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
  where v.status='planned' and v.kind<>'start' and not exists(select 1 from effective_windows w
   where w.portal_id=v.portal_id and v.starts_at>=w.opens_at and case when w.is_finale then v.starts_at<=w.arrival_closes_at else v.starts_at<w.arrival_closes_at end
    and v.ends_at<=w.closes_at and v.duration>=w.visit_seconds and v.buffer>=w.buffer_seconds and w.max_children>=v.children)
  union all
  select 'ACCESSIBILITY_REQUIREMENT','block','Deze fysieke poort is niet aantoonbaar drempelvrij voor een kind met een expliciete route-eis.',array[v.id],array[v.group_id]
  from v join locations location on location.portal_id=v.portal_id join group_requirements requirement on requirement.group_id=v.group_id
  where v.status='planned' and v.kind<>'start' and location.accessibility_status<>'step_free' and requirement.step_free_required
  union all
  select 'ACCESSIBILITY_REVIEW_REQUIRED','block','Beoordeel de toegankelijkheidswens of verifieer deze poort; de voorlopige route gebruikt uitsluitend aantoonbaar drempelvrije fysieke poorten.',array[v.id],array[v.group_id]
  from v join locations location on location.portal_id=v.portal_id join group_requirements requirement on requirement.group_id=v.group_id
  where v.status='planned' and v.kind<>'start' and location.accessibility_status<>'step_free' and requirement.review_required
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
  select 'TRAVEL_TIME','block','Onvoldoende reistijd tussen het einde van het bezoek en de volgende poort (schatting van de route-engine).',array[edge.from_visit_id,edge.to_visit_id],array[edge.group_id]
  from adjacent_visits edge
  join locations la on la.portal_id=edge.from_portal_id join locations lb on lb.portal_id=edge.to_portal_id
  left join start_context start on start.group_id=edge.group_id
  left join lateral app_private.destination_estimate((case when edge.from_kind='start' then start.position else la.position end->>'latitude')::numeric,(case when edge.from_kind='start' then start.position else la.position end->>'longitude')::numeric,(lb.position->>'latitude')::numeric,(lb.position->>'longitude')::numeric) travel on true
  where edge.to_status='planned' and (travel.duration_seconds is null or edge.to_starts_at<(case when edge.from_kind='start' then edge.from_starts_at else edge.service_ends_at end)+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'ARRIVAL_HEADWAY','block','Groepsaankomsten bij dezelfde fysieke poort liggen onder de ingestelde minimumafstand.',array[a.id,b.id],array[a.group_id,b.group_id]
  from v a join v b on a.physical_id=b.physical_id and a.group_id<>b.group_id and a.id<b.id
  join physical_headways policy on policy.physical_id=a.physical_id
  where a.kind<>'start' and b.kind<>'start' and a.status not in('completed','skipped') and b.status not in('completed','skipped')
   and abs(extract(epoch from a.starts_at-b.starts_at))<policy.headway_seconds
  union all
  select 'RECEPTION_POLICY','block','Aankomstinterval, fysieke bezetting of groeps-/kindercapaciteit conflicteert met andere bezoeken of reserveringen.',array[v.id],array[v.group_id]
  from v join availability_data availability on availability.portal_id=v.portal_id
  join reception_context context on context.portal_id=v.portal_id where v.status='planned' and v.kind<>'start'
   and not app_private.portal_interval_available_with_context(v.group_id,v.starts_at,v.ends_at,v.children,availability.occupied,context.windows,context.headway,context.finale_available)
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
   and exists(select 1 from effective_windows w where w.portal_id=v.portal_id and w.is_finale
    and start.expected_finale_arrival_at>=w.opens_at and start.expected_finale_arrival_at<=w.arrival_closes_at)
  union all
  select 'EVENING_OVERFLOW','warning','Dit bezoek loopt door na de ingestelde definitieve finalesluiting.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings settings on settings.event_id=_event where v.ends_at>settings.finale_closes_at
 )
 select coalesce(jsonb_agg(jsonb_build_object('code',code,'severity',severity,'message',message,'visitIds',visits,'groupIds',groups)),'[]'::jsonb) from (select distinct code,severity,message,visits,groups from notices) dedup
$$;
revoke all on function app_private.live_planboard_warnings_before_canonical_routes(uuid,jsonb,jsonb) from public,anon,authenticated;
