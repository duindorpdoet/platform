-- Preserve every accepted intention and running route. Initial generation remains idempotent; normal reads no longer rebuild empty routes.
set lock_timeout='5s';

create or replace function app_private.live_planboard_seed(_event uuid) returns void language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups; route jsonb; stop jsonb; timing record; arrival timestamptz; settings app_private.event_route_settings; start_slot app_private.start_slots; start_point app_private.start_points; offset_sequence integer; active_schedule uuid; source_plan uuid; origin app_private.group_start_publications; current_run app_private.group_runs;
begin
 select * into settings from app_private.event_route_settings where event_id=_event;
 for g in select * from app_private.walking_groups where event_id=_event and retired_at is null and (current_schedule_revision_id is not null or current_plan_version_id is not null) and not exists(select 1 from app_private.live_route_plans p where p.group_id=walking_groups.id) order by id limit 2 loop
  select * into current_run from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc,r.id desc limit 1;
  active_schedule:=case when current_run.id is not null then current_run.schedule_revision_id else g.current_schedule_revision_id end;
  source_plan:=case when current_run.id is not null then current_run.active_plan_version_id else g.current_plan_version_id end;
  select * into origin from app_private.group_start_publications pub where pub.group_id=g.id and pub.schedule_id is not distinct from active_schedule order by pub.publication_order desc limit 1;
  if active_schedule is null and source_plan is not null then
   select jsonb_build_object('stops',coalesce(jsonb_agg(jsonb_build_object('portalId',s.portal_id,'sequence',s.position,'plannedArrivalAt',s.planned_arrival_at,'legacyDuration',extract(epoch from s.planned_departure_at-s.planned_arrival_at)::integer,'kind',case when s.position=(select max(position) from app_private.route_plan_stops where plan_version_id=source_plan) then 'finale' else 'ordinary' end) order by s.position),'[]')) into route from app_private.route_plan_stops s where s.plan_version_id=source_plan;
  else route:=app_private.start_ops_route_preview(g.id); end if;
  insert into app_private.live_route_plans(group_id,event_id,schedule_id) values(g.id,_event,active_schedule) on conflict(group_id) do update set schedule_id=excluded.schedule_id,version=live_route_plans.version+1;
  offset_sequence:=0;
  select slot.* into start_slot from app_private.group_schedule_revisions schedule join app_private.start_slots slot on slot.id=schedule.start_slot_id where schedule.id=active_schedule;
  select * into start_point from app_private.start_points where id=start_slot.start_point_id;
  if origin.id is not null then start_point:=jsonb_populate_record(null::app_private.start_points,origin.point_snapshot); start_slot.starts_at:=origin.starts_at; end if;
  if start_point.linked_portal_id is not null and not start_point.counts_as_first_portal_visit then
   select win.visit_minutes*60 visit_seconds,win.buffer_minutes*60 buffer_seconds into timing from app_private.portal_windows win where win.portal_id=start_point.linked_portal_id and start_slot.starts_at>=win.opens_at and start_slot.starts_at<win.closes_at order by win.opens_at limit 1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind)
   values(_event,g.id,1,start_point.linked_portal_id,start_slot.starts_at,coalesce(timing.visit_seconds,settings.ordinary_visit_seconds),coalesce(timing.buffer_seconds,settings.route_buffer_seconds),'start')
   on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,kind='start',source='expected',retired_at=null,version=live_route_visits.version+1 where live_route_visits.run_stop_id is null;
   offset_sequence:=1;
  end if;
  for stop in select * from jsonb_array_elements(route->'stops') loop
   arrival:=(stop->>'plannedArrivalAt')::timestamptz;
   select w.visit_minutes*60 visit_seconds,w.buffer_minutes*60 buffer_seconds into timing from app_private.portal_windows w where w.portal_id=(stop->>'portalId')::uuid and arrival>=w.opens_at and arrival<w.closes_at order by w.opens_at,w.id limit 1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind)
   values(_event,g.id,(stop->>'sequence')::integer+offset_sequence,(stop->>'portalId')::uuid,arrival,
    coalesce((stop->>'legacyDuration')::integer,case when stop->>'kind'='finale' then settings.finale_show_seconds else coalesce(timing.visit_seconds,settings.ordinary_visit_seconds) end),
    case when active_schedule is null and source_plan is not null then 0 when stop->>'kind'='finale' then settings.finale_turnover_seconds else coalesce(timing.buffer_seconds,settings.route_buffer_seconds) end,stop->>'kind')
    on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,source='expected',kind=excluded.kind,retired_at=null,version=live_route_visits.version+1 where live_route_visits.run_stop_id is null;
  end loop;
 end loop;
 -- Match only authoritative stop identities, never create a scan or arrival.
 update app_private.live_route_visits v set run_stop_id=s.id,version=v.version+1
 from (select distinct on(group_id) * from app_private.group_runs order by group_id,case when status in ('live','paused') then 0 else 1 end,created_at desc,id desc) r
 join app_private.run_stops s on s.run_id=r.id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 where v.kind<>'start' and v.group_id=r.group_id and v.event_id=_event and v.portal_id=coalesce(s.portal_id,ps.portal_id) and v.run_stop_id is null
 and not exists(select 1 from app_private.run_stops newer left join app_private.route_plan_stops newer_plan on newer_plan.id=newer.plan_stop_id
   where newer.run_id=r.id and coalesce(newer.portal_id,newer_plan.portal_id)=coalesce(s.portal_id,ps.portal_id)
   and (newer.sequence,newer.opened_at,newer.id)>(s.sequence,s.opened_at,s.id))
 and not exists(select 1 from app_private.live_route_visits other where other.run_stop_id=s.id);
end $$;

-- The caller captures occupancy once. This private primitive preserves the
-- reception policy used by both a locked dispatcher and the board validator.
create or replace function app_private.portal_interval_available_from_occupancy(
 _portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_occupancy jsonb
) returns boolean language sql stable security definer set search_path='' as $$
 with occupied as materialized (
  select * from jsonb_to_recordset(coalesce(_occupancy,'[]')) as q(group_id uuid,starts_at timestamptz,ends_at timestamptz,child_count integer)
 )
 select _from<_until and exists(select 1 from app_private.portal_windows w where w.portal_id=_portal and _from>=w.opens_at and _until<=w.closes_at and _children<=w.max_children_per_visit
 and _children+coalesce((select sum(loaded.children) from (select q.group_id,max(q.child_count) children from occupied q where q.group_id<>_group group by q.group_id) loaded),0)<=w.max_children_total
 and not exists(select 1 from (
  select _from tick union select r.starts_at from occupied r where r.starts_at>=_from and r.starts_at<_until
 ) boundary where (select count(distinct r.group_id) from occupied r where r.group_id<>_group and r.starts_at<=boundary.tick and r.ends_at>boundary.tick)>=w.max_concurrent_groups))
$$;
create or replace function app_private.portal_interval_available(_portal uuid,_group uuid,_from timestamptz,_until timestamptz,_children integer,_at timestamptz)
returns boolean language sql stable security definer set search_path='' as $$
 with occupancy as materialized (
  select b.group_id,b.starts_at,b.ends_at,b.child_count from app_private.portal_occupancy_intervals(_portal,_at) b
  union all select v.group_id,null::timestamptz,null::timestamptz,(select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=v.first_stop_id and a.arrived)
  from app_private.group_portal_visits v where v.portal_id=_portal
 )
 select app_private.portal_interval_available_from_occupancy(_portal,_group,_from,_until,_children,
   coalesce((select jsonb_agg(to_jsonb(occupancy)) from occupancy),'[]'))
$$;
revoke all on function app_private.portal_interval_available_from_occupancy(uuid,uuid,timestamptz,timestamptz,integer,jsonb),app_private.portal_interval_available(uuid,uuid,timestamptz,timestamptz,integer,timestamptz) from public,anon,authenticated;

create or replace function app_private.live_planboard_warnings_from_visits(_event uuid,_changes jsonb,_visits jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 with group_sizes as materialized (
 select g.id group_id,
 (case when exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused')) then (select count(*) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id where r.group_id=g.id and r.status in ('live','paused') and rp.attendance='present' and rp.departed_at is null) else (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) end)::integer children
 from app_private.walking_groups g where g.event_id=_event and g.retired_at is null
 ), data as materialized (
  select item||coalesce((select change from jsonb_array_elements(_changes) change where change->>'id'=item->>'id'),'{}'::jsonb) item
  from jsonb_array_elements(_visits) item
 ), v as materialized (
  select (item->>'id')::uuid id,(item->>'groupId')::uuid group_id,(item->>'portalId')::uuid portal_id,(item->>'sequence')::integer sequence,
  (item->>'startsAt')::timestamptz starts_at,(item->>'durationSeconds')::integer duration,(item->>'bufferSeconds')::integer buffer,
  (item->>'startsAt')::timestamptz+make_interval(secs=>(item->>'durationSeconds')::integer+(item->>'bufferSeconds')::integer) ends_at,
  item->>'kind' kind,item->>'status' status,
  size.children
  from data join group_sizes size on size.group_id=(item->>'groupId')::uuid
 ), occupancy as materialized (
  select portal_id,group_id,starts_at,ends_at,children from v where status not in ('completed','skipped')
  union all select portal_id,group_id,reserved_from,reserved_until,child_count from app_private.portal_reservations where event_id=_event and status in ('active','held','completed')
  union all select (pub.point_snapshot->>'linked_portal_id')::uuid,pub.group_id,pub.starts_at,pub.starts_at+make_interval(secs=>coalesce(app_private.portal_service_seconds((pub.point_snapshot->>'linked_portal_id')::uuid,pub.starts_at),300)),
   (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=pub.group_id and a.superseded_at is null)::integer
  from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub where g.event_id=_event and pub.point_snapshot->>'linked_portal_id' is not null
 ), locations as materialized (
 select portal_id,app_private.portal_location(portal_id) position from (select distinct portal_id from v) p
 ), physical_occupancy as materialized (
 select p.portal_id,o.* from locations p cross join lateral app_private.portal_occupancy_intervals(p.portal_id,statement_timestamp()) o
 ), availability_data as materialized (
 select p.portal_id,coalesce((select jsonb_agg(to_jsonb(occupied)) from (
  select o.group_id,o.starts_at,o.ends_at,o.child_count from physical_occupancy o where o.portal_id=p.portal_id
  union all select v.group_id,null::timestamptz,null::timestamptz,(select count(distinct a.child_id)::integer from app_private.run_stop_arrivals a where a.run_stop_id=v.first_stop_id and a.arrived)
  from app_private.group_portal_visits v where v.portal_id=p.portal_id
 ) occupied),'[]') occupied from locations p
 ), sequence_edges as materialized (
 select group_id,sequence,lead(sequence) over(partition by group_id order by sequence) next_sequence
 from (select distinct group_id,sequence from v) seq
 ), loads as materialized (
 select edge.portal_id,edge.at,count(distinct o.group_id) groups,array_agg(distinct o.group_id) group_ids
 from (select distinct portal_id,starts_at at from occupancy) edge join occupancy o on o.portal_id=edge.portal_id and o.starts_at<=edge.at and o.ends_at>edge.at
 group by edge.portal_id,edge.at
 ), notices as (
  select 'PORTAL_UNAVAILABLE' code,'block' severity,'Poort is niet actief, goedgekeurd of operationeel beschikbaar.' message,array[v.id] visits,array[v.group_id] groups
  from v join app_private.portals p on p.id=v.portal_id where v.status='planned' and (p.lifecycle_status<>'active' or p.approval_status<>'approved' or p.operation_status in ('paused','closed'))
  union all
  select 'ROUTE_SOURCE_CHANGED','warning','Dit bestaande routevoorstel hoort bij een eerdere startrevisie. Controleer de poortvolgorde en tijden tegen de nieuwe conceptafspraak; er is niets automatisch herschreven.',array[]::uuid[],array[g.id]
  from app_private.walking_groups g join app_private.live_route_plans source on source.group_id=g.id
  left join lateral(select r.* from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc,r.id desc limit 1) run on true
  where g.event_id=_event and g.retired_at is null and source.schedule_id is distinct from case when run.id is not null then run.schedule_revision_id else g.current_schedule_revision_id end
  union all
  select 'OPENING_WINDOW','block','Bezoek en buffer passen niet binnen één openingsvenster.',array[v.id],array[v.group_id] from v where v.status='planned' and not exists(select 1 from app_private.portal_windows w where w.portal_id=v.portal_id and v.starts_at>=w.opens_at and v.ends_at<=w.closes_at and (v.kind='finale' or (v.duration>=w.visit_minutes*60 and v.buffer>=w.buffer_minutes*60)) and w.max_children_per_visit>=v.children)
  union all
  select 'LOCATION_MISSING','block','Poort heeft geen bruikbare locatie voor de route-engine.',array[v.id],array[v.group_id] from v where v.status='planned' and not app_private.portal_location_ready(v.portal_id)
  union all
  select 'ORDINARY_STOP_LIMIT','block','Gewone poort valt na de afgesproken stoptijd.',array[v.id],array[v.group_id]
  from v join app_private.walking_groups g on g.id=v.group_id join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
  where v.status='planned' and v.kind<>'finale' and v.ends_at>s.effective_ordinary_stop_at
  union all
  select 'HOUSEHOLD_STOP_LIMIT','block','Bezoek valt na de stoptijd van inschrijving '||r.reference||'.',array[v.id],array[v.group_id]
  from v join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.kind<>'finale' and r.requested_ordinary_stop_at is not null and r.requested_ordinary_stop_at is distinct from r.desired_end_at and v.ends_at>r.requested_ordinary_stop_at
  union all
  select 'START_PREFERENCE','warning','Afwijking van de gewenste starttijd van '||r.reference||'.',array[v.id],array[v.group_id]
  from v join app_private.group_registrations a on a.group_id=v.group_id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id
  where v.status='planned' and v.sequence=1 and r.preferred_start_at is not null and abs(extract(epoch from v.starts_at-r.preferred_start_at))>600
  union all
  select 'GROUP_OVERLAP','block','Twee bezoeken van dezelfde groep overlappen.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.id<b.id and a.kind<>'start' and b.kind<>'start' and a.starts_at<b.ends_at and b.starts_at<a.ends_at
  union all
  select 'DUPLICATE_PORTAL','block','Dezelfde poort staat meermaals in deze groepsroute.',array[a.id,b.id],array[a.group_id]
  from v a join v b on a.group_id=b.group_id and a.portal_id=b.portal_id and a.id<b.id
  union all
  select 'TRAVEL_TIME','block','Onvoldoende reistijd en buffer tussen opeenvolgende poorten (schatting van de route-engine).',array[a.id,b.id],array[a.group_id]
  from v a join sequence_edges seq on seq.group_id=a.group_id and seq.sequence=a.sequence
  join v b on b.group_id=a.group_id and b.sequence=seq.next_sequence
  join locations la on la.portal_id=a.portal_id join locations lb on lb.portal_id=b.portal_id
  left join lateral app_private.destination_estimate((la.position->>'latitude')::numeric,(la.position->>'longitude')::numeric,(lb.position->>'latitude')::numeric,(lb.position->>'longitude')::numeric) travel on true
  where b.status='planned' and (travel.duration_seconds is null or b.starts_at<(case when a.kind='start' then a.starts_at else a.ends_at end)+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'PORTAL_CAPACITY','block','Gelijktijdige groepscapaciteit is overschreden.',
   array(select x.id from v x where x.portal_id=v.portal_id and x.starts_at< v.ends_at and x.ends_at>v.starts_at),
   array(select distinct x.group_id from occupancy x where x.portal_id=v.portal_id and x.starts_at<v.ends_at and x.ends_at>v.starts_at)
  from v where v.status='planned' and exists(
   select 1 from loads edge join app_private.portal_windows w on w.portal_id=v.portal_id and edge.at>=w.opens_at and edge.at<w.closes_at
   where edge.portal_id=v.portal_id and edge.at>=v.starts_at and edge.at<v.ends_at and edge.groups>w.max_concurrent_groups)
  union all
  select 'RECEPTION_POLICY','block','De ontvangst past niet binnen de actuele reserveringen of totale kindlimiet.',array[v.id],array[v.group_id]
  from v join availability_data availability on availability.portal_id=v.portal_id where v.status='planned' and not app_private.portal_interval_available_from_occupancy(v.portal_id,v.group_id,v.starts_at,v.ends_at,v.children,availability.occupied)
  union all
  select 'GROUP_END_TIME_INFEASIBLE','block','De finale is niet binnen de maximale groepsuitloop afgerond.',array[v.id],array[v.group_id]
  from v join app_private.walking_groups g on g.id=v.group_id
  join app_private.group_schedule_revisions s on s.id=coalesce((select r.schedule_revision_id from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused') order by r.created_at desc limit 1),g.current_schedule_revision_id)
  where v.kind='finale' and v.status='planned' and v.starts_at>app_private.schedule_latest_finale_arrival(s.id)
  union all
  select 'FINALE_WINDOW','block','De finale valt buiten het eigen finalevenster.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings s on s.event_id=_event where v.kind='finale' and v.status='planned' and (v.portal_id<>s.final_portal_id or not s.finale_available or v.starts_at<s.finale_opens_at or v.starts_at>s.finale_last_arrival_at or v.ends_at>s.finale_closes_at)
  union all
  select 'EVENING_OVERFLOW','warning','Dit bezoek loopt door na de ingestelde definitieve finalesluiting.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings settings on settings.event_id=_event where v.ends_at>settings.finale_closes_at
 )
 select coalesce(jsonb_agg(jsonb_build_object('code',code,'severity',severity,'message',message,'visitIds',visits,'groupIds',groups)),'[]'::jsonb) from (select distinct code,severity,message,visits,groups from notices) dedup
$$;

create or replace function app_private.live_planboard_warnings(_event uuid,_changes jsonb default '[]') returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.live_planboard_warnings_from_visits(_event,_changes,app_private.live_planboard_visits(_event))
$$;
revoke all on function app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb),app_private.live_planboard_warnings(uuid,jsonb) from public,anon,authenticated;


create or replace function app_private.live_planboard_initialization_pending(_event uuid)
returns integer language sql stable security definer set search_path='' as $$
 select count(*)::integer from app_private.walking_groups g where g.event_id=_event and g.retired_at is null
 and (g.current_schedule_revision_id is not null or g.current_plan_version_id is not null)
 and not exists(select 1 from app_private.live_route_plans p where p.group_id=g.id)
$$;
revoke all on function app_private.live_planboard_initialization_pending(uuid) from public,anon,authenticated;

create or replace function api.admin_live_planboard_snapshot_before_worlds(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; result jsonb; visits jsonb;
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 -- Ordinary refreshes do not take the global event writer lock or rebuild routes.
 if exists(select 1 from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null
   and (g.current_schedule_revision_id is not null or g.current_plan_version_id is not null)
   and not exists(select 1 from app_private.live_route_plans p where p.group_id=g.id))
 or exists(select 1 from (select distinct on(group_id) * from app_private.group_runs order by group_id,case when status in ('live','paused') then 0 else 1 end,created_at desc,id desc) r join app_private.run_stops s on s.run_id=r.id
   left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
   join app_private.live_route_visits v on v.group_id=r.group_id and v.portal_id=coalesce(s.portal_id,ps.portal_id)
   where v.event_id=e.id and v.kind<>'start' and v.run_stop_id is null
   and not exists(select 1 from app_private.live_route_visits linked where linked.run_stop_id=s.id)) then
   perform 1 from app_private.events where id=e.id for no key update;
   perform app_private.live_planboard_seed(e.id);
 end if;
 visits:=app_private.live_planboard_visits(e.id);
 result:=jsonb_build_object('eventId',e.id,'eventDate',e.local_date,'generatedAt',clock_timestamp(),'inputHash',app_private.live_planboard_hash(e.id),'realtimeTopic','admin-event:'||e.id,
 'initializationPending',app_private.live_planboard_initialization_pending(e.id),'visits',visits,'warnings',app_private.live_planboard_warnings_from_visits(e.id,'[]',visits),
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'code',p.system_code,'world',w.name,'worldSlug',w.slug,'operationStatus',p.operation_status,'lifecycleStatus',p.lifecycle_status,'approvalStatus',p.approval_status,'finale',s.final_portal_id=p.id,
 'windows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',win.opens_at,'closesAt',win.closes_at,'maxGroups',win.max_concurrent_groups,'maxChildren',win.max_children_per_visit,'durationSeconds',win.visit_minutes*60,'bufferSeconds',win.buffer_minutes*60) order by win.opens_at) from app_private.portal_windows win where win.portal_id=p.id),'[]')) order by p.system_number)
 from app_private.portals p join app_private.worlds w on w.id=p.world_id left join app_private.event_route_settings s on s.event_id=p.event_id
 where p.event_id=e.id and ((p.lifecycle_status='active' and p.approval_status='approved') or exists(select 1 from app_private.live_route_visits pending join app_private.walking_groups current_group on current_group.id=pending.group_id and current_group.retired_at is null where pending.portal_id=p.id and pending.retired_at is null) or exists(select 1 from app_private.run_stops rs join app_private.group_runs r on r.id=rs.run_id join app_private.walking_groups g on g.id=r.group_id where g.event_id=e.id and rs.portal_id=p.id))),'[]'),
 'groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'code',g.system_code,'name',coalesce(g.display_name,g.system_code),'version',g.version,
 'draftStartsAt',(select starts_at from app_private.start_slots where id=schedule.start_slot_id),'recipients',(select count(*) from app_private.group_adult_recipients(g.id)),'runId',r.id,'runVersion',r.version,'status',g.status,'publishedStartsAt',pub.starts_at,'scheduleId',g.current_schedule_revision_id,
 'activeChildren',case when r.id is not null then (select count(*) from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null) else null end,'scheduleRevision',schedule.revision,'routeSourceScheduleId',(select source.schedule_id from app_private.live_route_plans source where source.group_id=g.id),'routeSourceChanged',exists(select 1 from app_private.live_route_plans source where source.group_id=g.id and source.schedule_id is distinct from case when r.status in ('live','paused') then r.schedule_revision_id else g.current_schedule_revision_id end),'confirmed',app_private.is_start_confirmation_current(schedule.id),'settingsVersion',e.settings_version,
 'households',coalesce((select jsonb_agg(jsonb_build_object('reference',reg.reference,'preferredStartAt',reg.preferred_start_at,'ordinaryStopAt',reg.requested_ordinary_stop_at,'desiredEndAt',reg.desired_end_at,'childCount',(select count(*) from app_private.registration_children c where c.registration_id=reg.id and c.participation_status='active'))) from app_private.group_registrations a join app_private.registrations reg on reg.id=a.registration_id where a.group_id=g.id and a.superseded_at is null),'[]')) order by g.system_code)
 from app_private.walking_groups g left join lateral (select run.* from app_private.group_runs run where run.group_id=g.id order by case when run.status in ('live','paused') then 0 else 1 end,run.created_at desc,run.id desc limit 1) r on true left join app_private.group_schedule_revisions schedule on schedule.id=g.current_schedule_revision_id left join lateral app_private.current_start_publication(g.id) pub on true where g.event_id=e.id and g.retired_at is null),'[]'));
 return result;
end $$;

create or replace function api.admin_live_planboard_snapshot(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; missing text[]; notices jsonb;
begin
 result:=api.admin_live_planboard_snapshot_before_worlds(_event_slug);
 missing:=app_private.world_coverage_missing((result->>'eventId')::uuid);
 if cardinality(missing)>0 then
  select coalesce(jsonb_agg(jsonb_build_object('code','MISSING_WORLD_CANDY_ROUTE','severity','warning','message','Ontbrekende werelden: '||array_to_string(missing,', ')||'. Plan een echte gewone stop bij Anders; zonder geschikte aankomst zijn geen bonuszegels mogelijk.','visitIds','[]'::jsonb,'groupIds',jsonb_build_array(g->>'id'))),'[]') into notices
  from jsonb_array_elements(result->'groups') g where not exists(select 1 from jsonb_array_elements(result->'visits') v join app_private.portals p on p.id=(v->>'portalId')::uuid join app_private.worlds w on w.id=p.world_id and w.slug='anders' where v->>'groupId'=g->>'id' and v->>'kind'='ordinary' and v->>'status'<>'skipped');
  result:=result||jsonb_build_object('warnings',(result->'warnings')||notices);
 end if;
 return result||jsonb_build_object('missingWorlds',to_jsonb(missing),'worldCoverage',app_private.world_coverage_projection((result->>'eventId')::uuid));
end $$;
revoke all on function api.admin_live_planboard_snapshot_before_worlds(text),app_private.live_planboard_seed(uuid) from public,anon,authenticated;
revoke all on function api.admin_live_planboard_snapshot(text) from public,anon;
grant execute on function api.admin_live_planboard_snapshot(text) to authenticated;

create or replace function api.admin_live_planboard_preview(_event_slug text,_command jsonb,_input_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; v app_private.live_route_visits; changes jsonb; before_rows jsonb; warnings jsonb; delta interval; at_time timestamptz; target uuid; duration integer; saved app_private.command_receipts;
 changes_start boolean:=false; protected boolean:=false; point uuid; g app_private.walking_groups; publication app_private.group_start_publications; affected uuid[];
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if app_private.live_planboard_initialization_pending(e.id)>0 then raise exception 'LIVE_PLANBOARD_INITIALIZING' using errcode='55000'; end if;
 if _input_hash is distinct from app_private.live_planboard_hash(e.id) then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if _command->>'action' in ('undo','redo') then
  select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='planboard.apply' and idempotency_key=_command->>'restoreKey';
  if saved.id is null or saved.safe_result->>'eventId'<>e.id::text then raise exception 'INVALID_UNDO'; end if;
  changes:=case when _command->>'action'='undo' then saved.safe_result->'before' else saved.safe_result->'after' end;
  before_rows:=case when _command->>'action'='undo' then saved.safe_result->'after' else saved.safe_result->'before' end;
  if exists(select 1 from jsonb_array_elements(before_rows) old left join app_private.live_route_visits current on current.id=(old->>'id')::uuid
   where current.id is null or current.run_stop_id is not null or current.retired_at is not null or current.portal_id is distinct from (old->>'portalId')::uuid or current.starts_at is distinct from (old->>'startsAt')::timestamptz or current.duration_seconds is distinct from (old->>'durationSeconds')::integer) then raise exception 'STALE_REVISION' using errcode='40001'; end if;
  select * into v from app_private.live_route_visits where id=(changes->0->>'id')::uuid;
 elsif _command->>'action'='move' then
  select * into v from app_private.live_route_visits where id=(_command->>'visitId')::uuid and event_id=e.id;
  if v.id is null or v.run_stop_id is not null or v.retired_at is not null or v.kind='finale' then raise exception 'VISIT_PROTECTED' using errcode='23514'; end if;
  at_time:=app_private.parse_amsterdam_instant(_command->>'startsAt');target:=(_command->>'portalId')::uuid;duration:=coalesce((_command->>'durationSeconds')::integer,v.duration_seconds);
  if at_time is null or extract(minute from at_time at time zone 'Europe/Amsterdam')::integer%10<>0 or extract(second from at_time)<>0 or duration not between 30 and 7200 then raise exception 'INVALID_SNAP_OR_DURATION' using errcode='22023'; end if;
  delta:=at_time-v.starts_at;
  select jsonb_agg(jsonb_build_object('id',other.id,'groupId',other.group_id,'portalId',case when other.id=v.id then target else other.portal_id end,
   'startsAt',other.starts_at+delta,'durationSeconds',case when other.id=v.id then duration else other.duration_seconds end,
   'bufferSeconds',case when other.id=v.id then greatest(other.buffer_seconds,coalesce((select min(w.buffer_minutes)*60 from app_private.portal_windows w where w.portal_id=target and at_time>=w.opens_at and at_time<w.closes_at),other.buffer_seconds)) else other.buffer_seconds end,'source','manual') order by other.sequence) into changes
  from app_private.live_route_visits other where other.group_id=v.group_id and other.run_stop_id is null and other.retired_at is null
   and (other.id=v.id or (coalesce((_command->>'shiftFollowing')::boolean,false) and other.sequence>v.sequence));
 else raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 if changes is null or jsonb_array_length(changes)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into g from app_private.walking_groups where id=v.group_id and retired_at is null;
 if g.route_mode='legacy' and (g.current_schedule_revision_id is null or exists(select 1 from app_private.group_runs legacy where legacy.group_id=g.id and legacy.active_plan_version_id is not null)) then raise exception 'USE_LEGACY_EVENING_REGIE' using errcode='23514'; end if;
 if g.id is null or exists(select 1 from app_private.group_runs where group_id=g.id and status in ('completed','stopped')) then raise exception 'GROUP_FINISHED' using errcode='23514'; end if;
 select * into publication from app_private.current_start_publication(g.id);
 changes_start:=v.sequence=1 and not exists(select 1 from app_private.group_runs where group_id=g.id)
 and exists(select 1 from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id where s.id=g.current_schedule_revision_id and (v.kind='start' or p.counts_as_first_portal_visit) and p.linked_portal_id=v.portal_id);
 if changes_start then
  select id into point from app_private.start_points where event_id=e.id and active and linked_portal_id=(changes->0->>'portalId')::uuid and counts_as_first_portal_visit=(v.kind<>'start') order by id limit 1;
  if point is null then raise exception 'CHOOSE_A_CONFIRMED_LINKED_START_POINT' using errcode='23514'; end if;
  protected:=publication.id is not null or app_private.is_start_confirmation_current(g.current_schedule_revision_id);
 end if;
 select array_agg((c->>'id')::uuid) into affected from jsonb_array_elements(changes) c;
 warnings:=coalesce((select jsonb_agg(w) from jsonb_array_elements(app_private.live_planboard_warnings(e.id,changes)) w where exists(select 1 from jsonb_array_elements_text(w->'visitIds') vid where vid::uuid=any(affected))),'[]'::jsonb);
 select jsonb_agg(jsonb_build_object('id',x.id,'groupId',x.group_id,'portalId',x.portal_id,'startsAt',x.starts_at,'durationSeconds',x.duration_seconds,'bufferSeconds',x.buffer_seconds,'source',x.source) order by x.sequence) into before_rows
 from app_private.live_route_visits x where x.id=any(affected);
 return jsonb_build_object('eventId',e.id,'inputHash',_input_hash,'groupId',g.id,'groupCode',g.system_code,'before',before_rows,'changes',changes,'warnings',warnings,
  'changesStart',changes_start,'startPointId',point,'requiresConfirmation',protected,'publishedStartsAt',publication.starts_at,
  'recipients',(select count(*) from app_private.group_adult_recipients(g.id)),
  'communication',case when changes_start then 'Nieuw concept; bestaande publicatie blijft geldig. Er wordt nog geen starttijdmail klaargezet.' else 'Route-intentie voor de avondregie; geen starttijdmail.' end);
end $$;
revoke all on function api.admin_live_planboard_preview(text,jsonb,text) from public,anon;
grant execute on function api.admin_live_planboard_preview(text,jsonb,text) to authenticated;
