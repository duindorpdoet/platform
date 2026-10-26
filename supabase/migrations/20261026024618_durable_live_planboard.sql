-- Expected routes are durable intentions, not operational reservations or scans.
create table app_private.live_route_plans (
 group_id uuid primary key references app_private.walking_groups(id),
 event_id uuid not null references app_private.events(id),
 schedule_id uuid references app_private.group_schedule_revisions(id),
 version integer not null default 1, created_at timestamptz not null default now()
);
create table app_private.live_route_visits (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
 group_id uuid not null references app_private.live_route_plans(group_id),
 sequence integer not null check(sequence>0), portal_id uuid not null references app_private.portals(id),
 starts_at timestamptz not null, duration_seconds integer not null check(duration_seconds between 30 and 7200),
 buffer_seconds integer not null default 0 check(buffer_seconds between 0 and 3600),
 kind text not null check(kind in ('ordinary','finale','start')),
 source text not null default 'expected' check(source in ('expected','manual')),
 version integer not null default 1, run_stop_id uuid unique references app_private.run_stops(id),
 retired_at timestamptz, updated_at timestamptz not null default now(), unique(group_id,sequence)
);
create index live_route_visits_portal_time on app_private.live_route_visits(event_id,portal_id,starts_at) where retired_at is null;
create index live_route_visits_group on app_private.live_route_visits(group_id,sequence) where retired_at is null;
alter table app_private.live_route_plans enable row level security;
alter table app_private.live_route_visits enable row level security;
revoke all on app_private.live_route_plans,app_private.live_route_visits from public,anon,authenticated;

create function app_private.live_planboard_hash(_event uuid) returns text language sql stable security definer set search_path='' as $$
 select md5(jsonb_build_array(app_private.start_ops_route_revision(_event),(select settings_version from app_private.events where id=_event),
 (select jsonb_agg(to_jsonb(point) order by point.id) from app_private.start_points point where point.event_id=_event),
 (select jsonb_agg(to_jsonb(slot) order by slot.id) from app_private.start_slots slot where slot.event_id=_event),
 (select jsonb_agg(to_jsonb(p)||jsonb_build_object('windows',(select jsonb_agg(to_jsonb(w) order by w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id) from app_private.portals p where p.event_id=_event),
 (select jsonb_agg(to_jsonb(s) order by s.id) from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id where g.event_id=_event),
 (select jsonb_agg(jsonb_build_array(r.id,r.version,m.user_id,m.revoked_at,m.accepted_at) order by r.id,m.user_id) from app_private.registrations r join app_private.household_members m on m.household_id=r.household_id where r.event_id=_event),
 (select jsonb_agg(jsonb_build_array(v.id,v.version,v.run_stop_id,v.retired_at) order by v.id) from app_private.live_route_visits v where v.event_id=_event),
 (select jsonb_agg(jsonb_build_array(r.id,r.version,r.status,r.reserved_from,r.reserved_until) order by r.id) from app_private.portal_reservations r where r.event_id=_event),
 (select jsonb_agg(jsonb_build_array(g.id,g.version,g.current_schedule_revision_id) order by g.id) from app_private.walking_groups g where g.event_id=_event),
 (select max(publication_order) from app_private.group_start_publications where event_id=_event),
 (select count(*) from app_private.group_start_withdrawals where event_id=_event))::text)
$$;
revoke all on function app_private.live_planboard_hash(uuid) from public,anon,authenticated;

create function app_private.live_planboard_seed(_event uuid) returns void language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups; route jsonb; stop jsonb; timing record; arrival timestamptz; settings app_private.event_route_settings; start_slot app_private.start_slots; start_point app_private.start_points; offset_sequence integer;
begin
 select * into settings from app_private.event_route_settings where event_id=_event;
 for g in select * from app_private.walking_groups where event_id=_event and retired_at is null and (current_schedule_revision_id is not null or current_plan_version_id is not null) and (not exists(select 1 from app_private.live_route_plans p where p.group_id=walking_groups.id) or (not exists(select 1 from app_private.live_route_visits v where v.group_id=walking_groups.id and v.retired_at is null) and not exists(select 1 from app_private.group_runs r where r.group_id=walking_groups.id))) order by id loop
  if g.route_mode='legacy' and g.current_schedule_revision_id is null then
   select jsonb_build_object('stops',coalesce(jsonb_agg(jsonb_build_object('portalId',s.portal_id,'sequence',s.position,'plannedArrivalAt',s.planned_arrival_at,'legacyDuration',extract(epoch from s.planned_departure_at-s.planned_arrival_at)::integer,'kind',case when s.position=(select max(position) from app_private.route_plan_stops where plan_version_id=g.current_plan_version_id) then 'finale' else 'ordinary' end) order by s.position),'[]')) into route from app_private.route_plan_stops s where s.plan_version_id=g.current_plan_version_id;
  else route:=app_private.start_ops_route_preview(g.id); end if;
  insert into app_private.live_route_plans(group_id,event_id,schedule_id) values(g.id,_event,g.current_schedule_revision_id) on conflict(group_id) do update set schedule_id=excluded.schedule_id,version=live_route_plans.version+1;
  offset_sequence:=0;
  select slot.* into start_slot from app_private.group_schedule_revisions schedule join app_private.start_slots slot on slot.id=schedule.start_slot_id where schedule.id=g.current_schedule_revision_id;
  select * into start_point from app_private.start_points where id=start_slot.start_point_id;
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
    case when g.route_mode='legacy' and g.current_schedule_revision_id is null then 0 when stop->>'kind'='finale' then settings.finale_turnover_seconds else coalesce(timing.buffer_seconds,settings.route_buffer_seconds) end,stop->>'kind')
    on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,source='expected',kind=excluded.kind,retired_at=null,version=live_route_visits.version+1 where live_route_visits.run_stop_id is null;
  end loop;
 end loop;
 -- Match only authoritative stop identities, never create a scan or arrival.
 update app_private.live_route_visits v set run_stop_id=s.id,version=v.version+1
 from app_private.group_runs r join app_private.run_stops s on s.run_id=r.id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 where v.kind<>'start' and v.group_id=r.group_id and v.event_id=_event and v.portal_id=coalesce(s.portal_id,ps.portal_id) and v.run_stop_id is null
 and not exists(select 1 from app_private.live_route_visits other where other.run_stop_id=s.id);
end $$;
revoke all on function app_private.live_planboard_seed(uuid) from public,anon,authenticated;

create function app_private.live_planboard_visits(_event uuid) returns jsonb language sql stable security definer set search_path='' as $$
 with visits as (
 select v.id,v.group_id,v.portal_id,v.sequence,v.kind,v.source,v.version,v.starts_at,v.duration_seconds,v.buffer_seconds,v.run_stop_id from app_private.live_route_visits v
 join app_private.walking_groups g on g.id=v.group_id and g.retired_at is null
 where v.event_id=_event and v.retired_at is null and (v.run_stop_id is not null or (v.kind='start' and exists(select 1 from app_private.group_runs r where r.group_id=v.group_id)) or not exists(select 1 from app_private.group_runs r where r.group_id=v.group_id and r.status in ('completed','stopped')))
 union all
 select s.id,r.group_id,coalesce(s.portal_id,ps.portal_id),s.sequence,coalesce(s.stop_kind::text,'ordinary'),'actual',s.version,
 coalesce(pr.reserved_from,s.opened_at),greatest(30,coalesce(extract(epoch from pr.reserved_until-pr.reserved_from)::integer,300)),0,s.id
 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id
 left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id left join app_private.portal_reservations pr on pr.id=s.reservation_id
 where g.event_id=_event and not exists(select 1 from app_private.live_route_visits v where v.run_stop_id=s.id)
 )
 select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'groupId',v.group_id,'portalId',v.portal_id,'sequence',v.sequence,'kind',v.kind,
 'source',case when s.id is not null or (v.kind='start' and started.id is not null) then 'actual' else v.source end,'version',v.version,'runStopId',s.id,
 'startsAt',coalesce(a.arrived_at,pr.reserved_from,v.starts_at),'plannedStartsAt',v.starts_at,
 'endsAt',coalesce(s.completed_at,case when a.arrived_at is not null then greatest(a.arrived_at+make_interval(secs=>v.duration_seconds),statement_timestamp()) else pr.reserved_until-make_interval(secs=>v.buffer_seconds) end,v.starts_at+make_interval(secs=>v.duration_seconds)),
 'durationSeconds',v.duration_seconds,'bufferSeconds',v.buffer_seconds,'actualArrivalAt',a.arrived_at,'actualDepartureAt',s.completed_at,
 'status',case when v.kind='start' and started.id is not null then 'completed' when s.state='completed' then case when s.outcome in ('visited','mixed','all_skipped') and a.arrived_at is not null then 'completed' else 'skipped' end when a.arrived_at is not null then 'present' when s.id is not null then 'underway' else 'planned' end,
 'editable',s.id is null and v.kind<>'finale' and not (v.kind='start' and started.id is not null) and (g.route_mode='dynamic' or (g.current_schedule_revision_id is not null and not exists(select 1 from app_private.group_runs legacy where legacy.group_id=g.id and legacy.active_plan_version_id is not null))),
 'confirmed',s.id is not null or (v.sequence=1 and (app_private.is_start_confirmation_current(g.current_schedule_revision_id) or exists(select 1 from app_private.current_start_publication(g.id))))) order by v.group_id,v.sequence),'[]'::jsonb)
 from visits v join app_private.walking_groups g on g.id=v.group_id
 left join lateral (select r.id,r.started_at from app_private.group_runs r where r.group_id=g.id order by r.created_at desc limit 1) started on true
 left join app_private.run_stops s on s.id=v.run_stop_id left join app_private.portal_reservations pr on pr.id=s.reservation_id
 left join lateral (select min(arrived_at) arrived_at from app_private.run_stop_arrivals where run_stop_id=s.id and arrived) a on true
$$;
revoke all on function app_private.live_planboard_visits(uuid) from public,anon,authenticated;

-- The same validator feeds display, preview and the locked apply transaction.
create function app_private.live_planboard_warnings(_event uuid,_changes jsonb default '[]') returns jsonb
language sql stable security definer set search_path='' as $$
 with data as (
  select item||coalesce((select change from jsonb_array_elements(_changes) change where change->>'id'=item->>'id'),'{}'::jsonb) item
  from jsonb_array_elements(app_private.live_planboard_visits(_event)) item
 ), v as (
  select (item->>'id')::uuid id,(item->>'groupId')::uuid group_id,(item->>'portalId')::uuid portal_id,(item->>'sequence')::integer sequence,
  (item->>'startsAt')::timestamptz starts_at,(item->>'durationSeconds')::integer duration,(item->>'bufferSeconds')::integer buffer,
  (item->>'startsAt')::timestamptz+make_interval(secs=>(item->>'durationSeconds')::integer+(item->>'bufferSeconds')::integer) ends_at,
  item->>'kind' kind,item->>'status' status,
  (case when exists(select 1 from app_private.group_runs r where r.group_id=(item->>'groupId')::uuid and r.status in ('live','paused')) then (select count(*) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id where r.group_id=(item->>'groupId')::uuid and r.status in ('live','paused') and rp.attendance='present' and rp.departed_at is null) else (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=(item->>'groupId')::uuid and a.superseded_at is null) end)::integer children
  from data
 ), occupancy as (
  select portal_id,group_id,starts_at,ends_at,children from v where status not in ('completed','skipped')
  union all select portal_id,group_id,reserved_from,reserved_until,child_count from app_private.portal_reservations where event_id=_event and status in ('active','held','completed')
  union all select (pub.point_snapshot->>'linked_portal_id')::uuid,pub.group_id,pub.starts_at,pub.starts_at+make_interval(secs=>coalesce(app_private.portal_service_seconds((pub.point_snapshot->>'linked_portal_id')::uuid,pub.starts_at),300)),
   (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=pub.group_id and a.superseded_at is null)::integer
  from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) pub where g.event_id=_event and pub.point_snapshot->>'linked_portal_id' is not null
 ), notices as (
  select 'PORTAL_UNAVAILABLE' code,'block' severity,'Poort is niet actief, goedgekeurd of operationeel beschikbaar.' message,array[v.id] visits,array[v.group_id] groups
  from v join app_private.portals p on p.id=v.portal_id where v.status='planned' and (p.lifecycle_status<>'active' or p.approval_status<>'approved' or p.operation_status in ('paused','closed'))
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
  where v.status='planned' and v.kind<>'finale' and r.requested_ordinary_stop_at is not null and v.ends_at>r.requested_ordinary_stop_at
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
  from v a join v b on b.group_id=a.group_id and b.sequence=(select min(c.sequence) from v c where c.group_id=a.group_id and c.sequence>a.sequence)
  left join lateral app_private.destination_estimate((app_private.portal_location(a.portal_id)->>'latitude')::numeric,(app_private.portal_location(a.portal_id)->>'longitude')::numeric,(app_private.portal_location(b.portal_id)->>'latitude')::numeric,(app_private.portal_location(b.portal_id)->>'longitude')::numeric) travel on true
  where b.status='planned' and (travel.duration_seconds is null or b.starts_at<(case when a.kind='start' then a.starts_at else a.ends_at end)+make_interval(secs=>travel.duration_seconds::integer))
  union all
  select 'PORTAL_CAPACITY','block','Gelijktijdige groepscapaciteit is overschreden.',
   array(select x.id from v x where x.portal_id=v.portal_id and x.starts_at< v.ends_at and x.ends_at>v.starts_at),
   array(select distinct x.group_id from occupancy x where x.portal_id=v.portal_id and x.starts_at<v.ends_at and x.ends_at>v.starts_at)
  from v where v.status='planned' and exists(
   select 1 from occupancy edge join app_private.portal_windows w on w.portal_id=v.portal_id and edge.starts_at>=w.opens_at and edge.starts_at<w.closes_at
   where edge.portal_id=v.portal_id and edge.starts_at>=v.starts_at and edge.starts_at<v.ends_at
   and (select count(distinct o.group_id) from occupancy o where o.portal_id=v.portal_id and o.starts_at<=edge.starts_at and o.ends_at>edge.starts_at)>w.max_concurrent_groups)
  union all
  select 'RECEPTION_POLICY','block','De ontvangst past niet binnen de actuele reserveringen of totale kindlimiet.',array[v.id],array[v.group_id]
  from v where v.status='planned' and not app_private.portal_interval_available(v.portal_id,v.group_id,v.starts_at,v.ends_at,v.children,statement_timestamp())
  union all
  select 'FINALE_WINDOW','block','De finale valt buiten het eigen finalevenster.',array[v.id],array[v.group_id]
  from v join app_private.event_route_settings s on s.event_id=_event where v.kind='finale' and v.status='planned' and (v.portal_id<>s.final_portal_id or not s.finale_available or v.starts_at<s.finale_opens_at or v.starts_at>s.finale_last_arrival_at or v.ends_at>s.finale_closes_at)
  union all
  select 'EVENING_OVERFLOW','warning','Dit bezoek loopt door buiten de standaardtijdlijn van 21:30.',array[v.id],array[v.group_id]
  from v join app_private.events e on e.id=_event where v.ends_at>(e.local_date+time '21:30') at time zone 'Europe/Amsterdam'
 )
 select coalesce(jsonb_agg(jsonb_build_object('code',code,'severity',severity,'message',message,'visitIds',visits,'groupIds',groups)),'[]'::jsonb) from (select distinct code,severity,message,visits,groups from notices) dedup
$$;
revoke all on function app_private.live_planboard_warnings(uuid,jsonb) from public,anon,authenticated;

create function api.admin_live_planboard_snapshot(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; result jsonb;
begin
 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform app_private.live_planboard_seed(e.id);
 result:=jsonb_build_object('eventId',e.id,'eventDate',e.local_date,'generatedAt',clock_timestamp(),'inputHash',app_private.live_planboard_hash(e.id),'realtimeTopic','admin-event:'||e.id,
 'visits',app_private.live_planboard_visits(e.id),'warnings',app_private.live_planboard_warnings(e.id),
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'code',p.system_code,'world',w.name,'worldSlug',w.slug,'operationStatus',p.operation_status,'finale',s.final_portal_id=p.id,
 'windows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',win.opens_at,'closesAt',win.closes_at,'maxGroups',win.max_concurrent_groups,'maxChildren',win.max_children_per_visit,'durationSeconds',win.visit_minutes*60,'bufferSeconds',win.buffer_minutes*60) order by win.opens_at) from app_private.portal_windows win where win.portal_id=p.id),'[]')) order by p.system_number)
 from app_private.portals p join app_private.worlds w on w.id=p.world_id left join app_private.event_route_settings s on s.event_id=p.event_id
 where p.event_id=e.id and ((p.lifecycle_status='active' and p.approval_status='approved') or exists(select 1 from app_private.run_stops rs join app_private.group_runs r on r.id=rs.run_id join app_private.walking_groups g on g.id=r.group_id where g.event_id=e.id and rs.portal_id=p.id))),'[]'),
 'groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'code',g.system_code,'name',coalesce(g.display_name,g.system_code),'version',g.version,
 'draftStartsAt',(select starts_at from app_private.start_slots where id=schedule.start_slot_id),'recipients',(select count(*) from app_private.group_adult_recipients(g.id)),'runId',r.id,'runVersion',r.version,'status',g.status,'publishedStartsAt',pub.starts_at,'scheduleId',g.current_schedule_revision_id,
 'activeChildren',case when r.id is not null then (select count(*) from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null) else null end,'scheduleRevision',schedule.revision,'confirmed',app_private.is_start_confirmation_current(schedule.id),'settingsVersion',e.settings_version,
 'households',coalesce((select jsonb_agg(jsonb_build_object('reference',reg.reference,'preferredStartAt',reg.preferred_start_at,'ordinaryStopAt',reg.requested_ordinary_stop_at,'desiredEndAt',reg.desired_end_at,'childCount',(select count(*) from app_private.registration_children c where c.registration_id=reg.id and c.participation_status='active'))) from app_private.group_registrations a join app_private.registrations reg on reg.id=a.registration_id where a.group_id=g.id and a.superseded_at is null),'[]')) order by g.system_code)
 from app_private.walking_groups g left join app_private.group_runs r on r.group_id=g.id left join app_private.group_schedule_revisions schedule on schedule.id=g.current_schedule_revision_id left join lateral app_private.current_start_publication(g.id) pub on true where g.event_id=e.id and g.retired_at is null),'[]'));
 return result;
end $$;
revoke all on function api.admin_live_planboard_snapshot(text) from public,anon;
grant execute on function api.admin_live_planboard_snapshot(text) to authenticated;

create function api.admin_live_planboard_preview(_event_slug text,_command jsonb,_input_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; v app_private.live_route_visits; changes jsonb; before_rows jsonb; warnings jsonb; delta interval; at_time timestamptz; target uuid; duration integer; saved app_private.command_receipts;
 changes_start boolean:=false; protected boolean:=false; point uuid; g app_private.walking_groups; publication app_private.group_start_publications; affected uuid[];
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
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

create function api.admin_live_planboard_apply(_event_slug text,_command jsonb,_input_hash text,_confirmed boolean,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e app_private.events; preview jsonb; hashed text; receipt app_private.command_receipts; item jsonb; result jsonb; g app_private.walking_groups;
begin
 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if length(trim(coalesce(_reason,''))) not between 10 and 500 or length(coalesce(_idempotency_key,'')) not between 16 and 200 then raise exception 'REASON_AND_KEY_REQUIRED'; end if;
 hashed:=md5(jsonb_build_array(e.id,_command,_input_hash,_confirmed,_reason)::text);
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='planboard.apply' and idempotency_key=_idempotency_key;
 if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
 preview:=api.admin_live_planboard_preview(_event_slug,_command,_input_hash);
 if (preview->>'requiresConfirmation')::boolean and not coalesce(_confirmed,false) then raise exception 'CONFIRMATION_REQUIRED'; end if;
 if exists(select 1 from jsonb_array_elements(preview->'warnings') w where w->>'severity'='block') then raise exception 'PLANBOARD_DOMAIN_BLOCKED:%',(preview->'warnings')::text using errcode='23514'; end if;
 select * into g from app_private.walking_groups where id=(preview->>'groupId')::uuid;
 if (preview->>'changesStart')::boolean then
  perform api.admin_startregie_move_group(g.id,(preview->>'startPointId')::uuid,(preview->'changes'->0->>'startsAt')::timestamptz,g.version,'neutral',_reason);
 end if;
 for item in select * from jsonb_array_elements(preview->'changes') loop
  update app_private.live_route_visits set portal_id=(item->>'portalId')::uuid,starts_at=(item->>'startsAt')::timestamptz,duration_seconds=(item->>'durationSeconds')::integer,buffer_seconds=(item->>'bufferSeconds')::integer,source=item->>'source',version=version+1,updated_at=clock_timestamp()
  where id=(item->>'id')::uuid and event_id=e.id and run_stop_id is null and retired_at is null;
  if not found then raise exception 'VISIT_PROTECTED' using errcode='23514'; end if;
 end loop;
 update app_private.live_route_plans set version=version+1,schedule_id=(select current_schedule_revision_id from app_private.walking_groups where id=g.id) where group_id=g.id;
 result:=jsonb_build_object('eventId',e.id,'before',preview->'before','after',preview->'changes','inputHash',app_private.live_planboard_hash(e.id),'communication',preview->'communication');
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(e.id,auth.uid(),'planboard.'||(_command->>'action'),'group',g.id,jsonb_build_object('reason',_reason,'before',preview->'before','after',preview->'changes'));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'planboard.apply',_idempotency_key,hashed,result,now()+interval '7 days');
 for item in select distinct jsonb_build_object('portalId',v->>'portalId') from jsonb_array_elements((preview->'before')||(preview->'changes')) v loop
  perform realtime.send(jsonb_build_object('resource','route_intent'),'snapshot_changed','portal:'||(item->>'portalId'),true);
 end loop;
 perform realtime.send(jsonb_build_object('resource','live_route','groupId',g.id),'snapshot_changed','admin-event:'||e.id,true);
 perform realtime.send(jsonb_build_object('resource','live_route'),'snapshot_changed','group:'||g.id,true);
 return result;
end $$;
revoke all on function api.admin_live_planboard_apply(text,jsonb,text,boolean,text,text) from public,anon;
grant execute on function api.admin_live_planboard_apply(text,jsonb,text,boolean,text,text) to authenticated;

-- Bind newly dispatched canonical stops to the corresponding durable identity.
create function app_private.live_route_bind_stop() returns trigger language plpgsql security definer set search_path='' as $$
declare gid uuid; candidate uuid; pid uuid;
begin
 select group_id into gid from app_private.group_runs where id=new.run_id;
 pid:=coalesce(new.portal_id,(select portal_id from app_private.route_plan_stops where id=new.plan_stop_id));
 select id into candidate from app_private.live_route_visits where group_id=gid and kind<>'start' and portal_id=pid and retired_at is null and run_stop_id is null order by sequence limit 1 for update;
 if candidate is not null then update app_private.live_route_visits set run_stop_id=new.id,version=version+1 where id=candidate; end if;
 return new;
end $$;
revoke all on function app_private.live_route_bind_stop() from public,anon,authenticated;
create trigger live_route_bind_stop after insert on app_private.run_stops for each row execute function app_private.live_route_bind_stop();

alter function app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid) rename to dispatch_next_stop_before_live_planboard;
revoke all on function app_private.dispatch_next_stop_before_live_planboard(uuid,timestamptz,boolean,uuid) from public,anon,authenticated;
create function app_private.dispatch_next_stop(_run_id uuid,_decision_at timestamptz default clock_timestamp(),_force_finale boolean default false,_preferred_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; intent app_private.live_route_visits; result jsonb; source jsonb; travel record; earliest_departure timestamptz; child_count integer; stopid uuid; reservationid uuid; finale_id uuid; final_travel record; ordinary_end timestamptz;
begin
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or r.status<>'live' or r.current_stop_id is not null then raise exception 'RUN_NOT_DISPATCHABLE' using errcode='23514'; end if;
 perform pg_advisory_xact_lock(hashtextextended((select event_id from app_private.walking_groups where id=r.group_id)::text||':route-dispatch',0));
 if not _force_finale and exists(select 1 from app_private.live_route_visits manual where manual.group_id=r.group_id and manual.retired_at is null and manual.source='manual') then
  select * into intent from app_private.live_route_visits v where v.group_id=r.group_id and v.kind<>'start' and v.retired_at is null and v.run_stop_id is null
   and not app_private.group_has_visited_portal(v.event_id,v.group_id,v.portal_id) order by v.sequence limit 1 for update;
 end if;
 if intent.id is null then return app_private.dispatch_next_stop_before_live_planboard(_run_id,_decision_at,_force_finale,_preferred_portal_id); end if;
 if _preferred_portal_id is not null and _preferred_portal_id<>intent.portal_id then raise exception 'MANUAL_ROUTE_INTENT_CONFLICT' using errcode='23514'; end if;
 if intent.kind='ordinary' then
  select app_private.portal_location(coalesce(s.portal_id,ps.portal_id)) into source from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id where s.run_id=r.id and s.state='completed' order by s.sequence desc limit 1;
  if source is null then select app_private.routing_position((pub.point_snapshot->>'marker_latitude')::numeric,(pub.point_snapshot->>'marker_longitude')::numeric,(pub.point_snapshot->>'geocoded_latitude')::numeric,(pub.point_snapshot->>'geocoded_longitude')::numeric,(pub.point_snapshot->>'latitude')::numeric,(pub.point_snapshot->>'longitude')::numeric) into source from app_private.group_start_publications pub where pub.schedule_id=r.schedule_revision_id order by pub.publication_order desc limit 1; end if;
  select * into travel from app_private.destination_estimate((source->>'latitude')::numeric,(source->>'longitude')::numeric,(app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric);
  if travel.duration_seconds is null then raise exception 'MANUAL_ROUTE_LOCATION_UNAVAILABLE'; end if;
  earliest_departure:=intent.starts_at-make_interval(secs=>travel.duration_seconds::integer);
  if _decision_at<earliest_departure then return jsonb_build_object('decision','wait','retryAfterSeconds',greatest(1,ceil(extract(epoch from earliest_departure-_decision_at)))::integer,'plannedPortalId',intent.portal_id); end if;
 end if;
 begin
  if intent.kind='ordinary' and not exists(select 1 from app_private.portal_windows w where w.portal_id=intent.portal_id and _decision_at+make_interval(secs=>travel.duration_seconds::integer)>=w.opens_at and _decision_at+make_interval(secs=>travel.duration_seconds::integer)<w.closes_at and intent.duration_seconds>=w.visit_minutes*60 and intent.buffer_seconds>=w.buffer_minutes*60) then raise exception 'MANUAL_ROUTE_SERVICE_POLICY_CHANGED'; end if;
  result:=app_private.dispatch_next_stop_before_live_planboard(_run_id,_decision_at,intent.kind='finale',case when intent.kind='finale' then null else intent.portal_id end);
  stopid:=(result->>'stopId')::uuid;
  if stopid is not null and intent.kind='ordinary' then
   select reservation_id into reservationid from app_private.run_stops where id=stopid;
   select count(*) into child_count from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
   if not app_private.portal_interval_available(intent.portal_id,r.group_id,
    _decision_at+make_interval(secs=>travel.duration_seconds::integer),_decision_at+make_interval(secs=>travel.duration_seconds::integer+intent.duration_seconds+intent.buffer_seconds),child_count,_decision_at) then raise exception 'MANUAL_ROUTE_CAPACITY_CHANGED'; end if;
   ordinary_end:=_decision_at+make_interval(secs=>travel.duration_seconds::integer+intent.duration_seconds+intent.buffer_seconds);
   if ordinary_end>(select effective_ordinary_stop_at from app_private.group_schedule_revisions where id=r.schedule_revision_id) then raise exception 'MANUAL_ROUTE_STOP_LIMIT'; end if;
   select journey.* into final_travel from app_private.event_route_settings settings cross join lateral app_private.destination_estimate((app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) journey where settings.event_id=intent.event_id;
   if final_travel.duration_seconds is null then raise exception 'MANUAL_ROUTE_FINALE_UNAVAILABLE';end if;
   finale_id:=app_private.try_reserve_finale(r.id,ordinary_end+make_interval(secs=>final_travel.duration_seconds::integer),_decision_at);
   if finale_id is null then raise exception 'MANUAL_ROUTE_FINALE_UNAVAILABLE';end if;
   update app_private.portal_reservations set reserved_until=ordinary_end,expires_at=greatest(expires_at,ordinary_end+make_interval(secs=>(select reservation_ttl_seconds from app_private.event_route_settings where event_id=intent.event_id))),version=version+1 where id=reservationid;
  end if;
 exception when check_violation or raise_exception then
  insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
  select intent.event_id,r.group_id,r.id,intent.portal_id,'warning','MANUAL_ROUTE_RECHECK','Handmatige route-intentie is niet meer uitvoerbaar. Controleer beschikbaarheid en capaciteit in het live planbord.'
  where not exists(select 1 from app_private.route_alerts where run_id=r.id and code='MANUAL_ROUTE_RECHECK' and status='open');
  return jsonb_build_object('decision','wait','manualIntentBlocked',true,'retryAfterSeconds',120);
 end;
 return result;
end $$;
revoke all on function app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid) from public,anon,authenticated;

-- Reopening one published composition uses the same withdrawal transaction/outbox.
alter function app_private.withdraw_group_appointment(uuid,text) rename to withdraw_group_appointment_before_live_planboard;
revoke all on function app_private.withdraw_group_appointment_before_live_planboard(uuid,text) from public,anon,authenticated;
create function app_private.withdraw_group_appointment(_group uuid,_reason text) returns void language plpgsql security definer set search_path='' as $$
declare publication app_private.group_start_publications; recipient record;
begin
 select * into publication from app_private.current_start_publication(_group);
 if publication.id is not null and _reason<>'Alle groepen teruggezet na actuele impactcontrole' then
  for recipient in select * from app_private.group_adult_recipients(_group) loop
   if exists(select 1 from app_private.email_outbox o where o.recipient_ref=recipient.user_id::text and o.payload->>'groupId'=_group::text and o.message_type in ('group_schedule_published','group_schedule_corrected') and (o.status in ('accepted','delivered') or o.provider_id is not null)) then
    insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
    values('group-withdrawal:'||publication.id||':'||recipient.user_id,'group_assignment_withdrawn',recipient.user_id::text,recipient.email,jsonb_build_object('eventId',publication.event_id,'groupId',_group,'groupCode',(select system_code from app_private.walking_groups where id=_group),'reason',_reason,'actionPath','/omgeving/meeloper/groep')) on conflict(dedupe_key) do nothing;
   end if;
  end loop;
 end if;
 perform app_private.withdraw_group_appointment_before_live_planboard(_group,_reason);
 update app_private.live_route_visits set retired_at=clock_timestamp(),version=version+1 where group_id=_group and run_stop_id is null and retired_at is null;
end $$;
revoke all on function app_private.withdraw_group_appointment(uuid,text) from public,anon,authenticated;

create function api.admin_live_planboard_publish(_event_slug text,_group_id uuid,_input_hash text,_expected_schedule_id uuid,_expected_revision integer,_expected_settings_version integer,_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; revisions jsonb;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not app_private.has_capability(eid,'groups_manage',auth.uid()) or not exists(select 1 from app_private.walking_groups where id=_group_id and event_id=eid and retired_at is null) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 revisions:=jsonb_build_array(jsonb_build_object('id',_expected_schedule_id,'revision',_expected_revision));
 if not exists(select 1 from app_private.command_receipts where actor_id=auth.uid() and command_type='starts.confirm_and_send' and idempotency_key=_key) then
  if _input_hash is distinct from app_private.live_planboard_hash(eid) then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if not exists(select 1 from app_private.walking_groups where id=_group_id and current_schedule_revision_id=_expected_schedule_id) then raise exception 'STALE_REVISION' using errcode='40001'; end if;
 end if;
 return api.admin_startregie_confirm_and_send(_event_slug,revisions,_expected_settings_version,_key);
end $$;
revoke all on function api.admin_live_planboard_publish(text,uuid,text,uuid,integer,integer,text) from public,anon;
grant execute on function api.admin_live_planboard_publish(text,uuid,text,uuid,integer,integer,text) to authenticated;

-- Expected timing uses the same per-portal service duration and buffer as dispatch.
CREATE OR REPLACE FUNCTION app_private.start_ops_route_preview(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; point app_private.start_points;
  slot app_private.start_slots; settings app_private.event_route_settings; r app_private.group_runs;
  last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; chosen uuid[]:='{}'::uuid[]; candidate record;
  meters bigint:=0; seconds bigint:=0; walk_m bigint; walk_s bigint; provisional boolean:=false;
  remaining integer; visited integer:=0; child_count integer; fixed_portal uuid;
  preserved_portal uuid; eligible integer; step_free boolean;
begin
  select * into g from app_private.walking_groups where id=_group_id;
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id;
  select * into slot from app_private.start_slots where id=coalesce(s.start_slot_id,g.start_slot_id);
  select * into point from app_private.start_points where id=slot.start_point_id;
  select * into settings from app_private.event_route_settings where event_id=g.event_id;
  if point.id is null or slot.id is null then return jsonb_build_object('groupId',g.id,'hasConfirmedStart',false,'stops','[]'::jsonb,'warnings',jsonb_build_array('Kies en bevestig eerst een startpunt en tijd.')); end if;
  select * into r from app_private.group_runs where group_id=g.id order by created_at desc limit 1;
  select count(*) into child_count from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
  select exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id
    join app_private.children c on c.id=rc.child_id where a.group_id=g.id and a.superseded_at is null
      and rc.participation_status='active' and nullif(trim(c.accessibility_note),'') is not null) into step_free;
  last_lon:=(app_private.start_point_location(point.id)->>'longitude')::numeric;
  last_lat:=(app_private.start_point_location(point.id)->>'latitude')::numeric;
  start_time:=slot.starts_at; at_time:=slot.starts_at;
  if r.id is not null then
    at_time:=greatest(at_time,statement_timestamp());
    select coalesce(array_agg(coalesce(rs.portal_id,ps.portal_id)),array[]::uuid[]),
      count(*) filter(where coalesce(rs.stop_kind::text,'ordinary')='ordinary' and rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=rs.id))
    into chosen,visited from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
    where rs.run_id=r.id and rs.state='completed';
    select coalesce(rs.portal_id,ps.portal_id) into preserved_portal from app_private.run_stops rs
      left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=r.current_stop_id;
    select (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'longitude')::numeric,
      (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'latitude')::numeric into last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    last_lon:=coalesce(last_lon,(app_private.start_point_location(point.id)->>'longitude')::numeric);
    last_lat:=coalesce(last_lat,(app_private.start_point_location(point.id)->>'latitude')::numeric);
  end if;
  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;
  if not point.counts_as_first_portal_visit and point.linked_portal_id is not null and point.linked_portal_id is distinct from preserved_portal then
    chosen:=array_append(chosen,point.linked_portal_id);
  elsif point.counts_as_first_portal_visit and r.id is null then fixed_portal:=point.linked_portal_id; end if;
  select count(*) into eligible from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
    where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')
      and p.id<>settings.final_portal_id;

  loop
    exit when remaining<=0 and preserved_portal is null;
    select q.* into candidate from (
      select p.id,p.name,p.system_code,p.world_id,w.name world,l.*,
        coalesce(m.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
          coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))))::bigint walk_m,
        m.duration_seconds::bigint walk_s,
        true geographic,
        final_path.duration_seconds final_seconds
      from app_private.portals p join app_private.worlds w on w.id=p.world_id
      join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
      left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true
      left join lateral app_private.destination_estimate(coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) final_path on true
      where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen))
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
        and (p.id=preserved_portal or not step_free or exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free'))
        and (preserved_portal is null or p.id=preserved_portal)
        and (preserved_portal is not null or fixed_portal is null or p.id=fixed_portal)
    ) q where q.walk_s is not null and (q.id=preserved_portal or (
      at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds))::integer)<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and q.final_seconds is not null
      and at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds)+q.final_seconds)::integer)<=settings.finale_last_arrival_at
      and exists(select 1 from app_private.portal_windows win where win.portal_id=q.id
        and at_time+make_interval(secs=>q.walk_s::integer)>=win.opens_at
        and at_time+make_interval(secs=>q.walk_s::integer)<win.closes_at
        and at_time+make_interval(secs=>(q.walk_s+win.visit_minutes*60+win.buffer_minutes*60)::integer)<=win.closes_at
        and win.max_children_per_visit>=child_count)))
    order by q.walk_s,q.walk_m,q.id limit 1;
    if candidate.id is null then
      if fixed_portal is not null then warnings:=warnings||jsonb_build_array('De gekoppelde eerste poort past niet veilig in dit tijdvenster. Controleer de afspraak.'); end if;
      exit;
    end if;
    walk_m:=candidate.walk_m; walk_s:=candidate.walk_s;
    provisional:=provisional or candidate.geographic;
    at_time:=at_time+make_interval(secs=>walk_s::integer);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world',candidate.world,'kind','ordinary',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,
      'status',case when candidate.id=preserved_portal then 'current' else 'expected' end));
    meters:=meters+walk_m; seconds:=seconds+walk_s+coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds);
    at_time:=at_time+make_interval(secs=>coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds));
    last_lon:=coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude);
    last_lat:=coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude);
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join lateral app_private.destination_estimate(last_lat,last_lon,coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null and app_private.portal_location_ready(candidate.id) and candidate.duration_seconds is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude),coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude))))::bigint;
    walk_s:=candidate.duration_seconds;
    provisional:=true;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','finale',
      'coordinate',jsonb_build_array(coalesce(candidate.marker_longitude,candidate.geocoded_longitude,candidate.longitude),coalesce(candidate.marker_latitude,candidate.geocoded_latitude,candidate.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>settings.finale_last_arrival_at or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('De eindpoort heeft geen geldig opgeslagen adres of marker — controleer de eindpoort.'); end if;
  if provisional then warnings:=warnings||jsonb_build_array('Afstanden zijn hemelsbreed; reistijden zijn schattingen. Kies zelf hoe je naar de volgende poort gaat.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',point.name,'address',point.private_address,'coordinate',jsonb_build_array(
      (app_private.start_point_location(point.id)->>'longitude')::numeric,(app_private.start_point_location(point.id)->>'latitude')::numeric),'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'distanceMethod','straight_line','travelTimeEstimated',true,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$;
