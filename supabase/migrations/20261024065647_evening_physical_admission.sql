-- New proof uses the actual acceptance instant after any event-lock wait.
alter table app_private.scan_evidence alter column scanned_at set default clock_timestamp();

-- All representations of one physical house consume the same reception pool.
create or replace function app_private.ordinary_portal_bookings(_event_id uuid,_portal_id uuid,_decision_at timestamptz)
returns table(group_id uuid,booking_id uuid,starts_at timestamptz,ends_at timestamptz,children integer,historical boolean,source text)
language sql stable security definer set search_path='' as $function$
with latest_runs as materialized (
 select distinct on(r.group_id) r.* from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
 where g.event_id=_event_id order by r.group_id,r.created_at desc,r.id desc
),latest_publications as materialized (
 select distinct on(p.group_id) p.* from app_private.group_start_publications p where p.event_id=_event_id order by p.group_id,p.publication_order desc
),live_bookings as (
 select b.group_id,b.id,least(b.reserved_from,scan.scanned_at),
  case when current_stop.id is not null and b.status='active' then greatest(b.reserved_until,_decision_at+make_interval(secs=>
   case when b.kind='finale' then greatest(coalesce(cfg.finale_show_seconds,60),60)+coalesce(cfg.finale_turnover_seconds,120)
   else greatest(coalesce(extract(epoch from b.service_until-b.reserved_from)::integer,cfg.ordinary_visit_seconds,60),60)+coalesce(cfg.route_buffer_seconds,0) end)) else b.reserved_until end,
  b.child_count,false,'reservation'::text
 from app_private.portal_reservations b left join latest_runs r on r.group_id=b.group_id
 left join latest_publications p on p.group_id=b.group_id
 left join app_private.event_route_settings cfg on cfg.event_id=b.event_id
 left join app_private.run_stops current_stop on current_stop.id=r.current_stop_id and current_stop.state='active' and (current_stop.reservation_id=b.id or b.bound_stop_id=current_stop.id)
 left join app_private.scan_evidence scan on scan.run_stop_id=current_stop.id
 where b.event_id=_event_id and b.portal_id=_portal_id and b.status in ('held','active')
  and ((b.run_id is not null and b.run_id=r.id and r.status in ('ready','live','paused'))
   or (b.run_id is null and (b.start_publication_id is null or b.start_publication_id=p.id)
    and (r.id is null or r.status not in ('completed','stopped') or b.created_at>coalesce(r.finished_at,r.created_at))))
  and (b.expires_at is null or b.expires_at>_decision_at or (b.status='active' and current_stop.id is not null))
),legacy_current as (
 select r.group_id,s.id,coalesce(scan.scanned_at,s.opened_at,r.started_at,_decision_at),
  greatest(coalesce(ps.planned_departure_at,_decision_at),_decision_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,60)+coalesce(cfg.route_buffer_seconds,0))),
  (select count(*)::integer from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null),false,'legacy_current'::text
 from latest_runs r join app_private.walking_groups g on g.id=r.group_id
 left join app_private.event_route_settings cfg on cfg.event_id=g.event_id
 join app_private.run_stops s on s.id=r.current_stop_id and s.state='active'
 left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 left join app_private.scan_evidence scan on scan.run_stop_id=s.id
 where r.status in ('live','paused') and s.reservation_id is null and coalesce(s.portal_id,ps.portal_id)=_portal_id
  and not exists(select 1 from app_private.portal_reservations b where b.bound_stop_id=s.id and b.status in ('held','active'))
),planned as (
 select p.group_id,s.id,s.planned_arrival_at,s.planned_departure_at+make_interval(mins=>w.buffer_minutes),
  (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=p.group_id and a.superseded_at is null),false,'legacy_plan'::text
 from app_private.route_plan_stops s join app_private.route_plan_versions p on p.id=s.plan_version_id and p.state in ('valid','published')
 join app_private.walking_groups g on g.id=p.group_id and g.event_id=_event_id
 join lateral(select pw.buffer_minutes from app_private.portal_windows pw where pw.portal_id=s.portal_id and s.planned_arrival_at>=pw.opens_at and s.planned_departure_at<=pw.closes_at order by pw.opens_at,pw.id limit 1) w on true
 left join latest_runs r on r.group_id=p.group_id
 left join latest_publications pub on pub.group_id=p.group_id
 where s.portal_id=_portal_id
  and p.id in(select candidate.id from app_private.route_plan_versions candidate where candidate.group_id=p.group_id and candidate.state=p.state order by candidate.revision desc,candidate.created_at desc,candidate.id desc limit 1)
  and not (pub.schedule_id is not null and pub.published_at>=p.created_at)
  and not(coalesce(r.status in ('live','paused'),false) or (coalesce(r.status in ('completed','stopped'),false) and (r.active_plan_version_id=p.id or r.created_at>=coalesce(p.published_at,p.created_at))))
),actual as (
 select r.group_id,(array_agg(s.id order by s.id))[1],min(a.arrived_at),max(a.arrived_at)+interval '1 microsecond',count(distinct a.child_id)::integer,true,'arrival'::text
 from app_private.run_stop_arrivals a join app_private.group_runs r on r.id=a.run_id join app_private.run_stops s on s.id=a.run_stop_id
 left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 where a.event_id=_event_id and a.arrived and coalesce(s.portal_id,ps.portal_id)=_portal_id group by r.group_id
)
select * from live_bookings union all select * from legacy_current union all select * from planned union all select * from actual
$function$;

create or replace function app_private.physical_portal_usage(_event_id uuid,_portal_id uuid,_group_id uuid,_arrival timestamptz,_until timestamptz,_children integer,_decision_at timestamptz)
returns jsonb language sql stable security definer set search_path='' as $function$
with bookings as materialized(select * from app_private.ordinary_portal_bookings(_event_id,_portal_id,_decision_at)),
 overlapping as materialized(select * from bookings where not historical and group_id<>_group_id and starts_at<_until and ends_at>_arrival),
 ticks as(select _arrival at_time union select starts_at from overlapping where starts_at>_arrival and starts_at<_until),
 per_group as(select t.at_time,b.group_id,max(b.children) children from ticks t join overlapping b on b.starts_at<=t.at_time and b.ends_at>t.at_time group by t.at_time,b.group_id),
 totals as(select at_time,count(*)::integer groups,sum(children)::integer children from per_group group by at_time),
 history as(select group_id,max(children)::integer children from bookings where historical group by group_id),
 future as(select b.group_id,max(b.children)::integer children from bookings b where not historical and ends_at>_decision_at and b.group_id<>_group_id and not exists(select 1 from history h where h.group_id=b.group_id) group by b.group_id)
select jsonb_build_object('peakGroups',coalesce((select max(groups) from totals),0)+1,'peakChildren',coalesce((select max(children) from totals),0)+_children,
 'totalChildren',coalesce((select sum(children) from history where group_id<>_group_id),0)+coalesce((select sum(children) from future),0)+greatest(_children,coalesce((select children from history where group_id=_group_id),0)))
$function$;
revoke all on function app_private.physical_portal_usage(uuid,uuid,uuid,timestamptz,timestamptz,integer,timestamptz) from public,anon,authenticated;

-- The already released location is the door being visited. Editing a future
-- walking node cannot erase valid arrival proof at that door. New admission
-- still checks actual physical occupancy, independent of the expected ETA.
create or replace function app_private.assert_physical_portal_admission(_run_id uuid,_stop_id uuid)
returns void language plpgsql security definer set search_path='' as $function$
declare r app_private.group_runs; g app_private.walking_groups; s app_private.run_stops; p app_private.portals;
 cfg app_private.event_route_settings; w app_private.portal_windows; booking app_private.portal_reservations; ps app_private.route_plan_stops;
 decision_at timestamptz:=clock_timestamp(); children integer; usage jsonb; is_finale boolean; until_at timestamptz; max_groups integer;max_children integer;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 select * into s from app_private.run_stops where id=_stop_id and run_id=r.id and state='active';
 if s.id is null or r.current_stop_id is distinct from s.id then raise exception 'STALE_VERSION' using errcode='40001';end if;
 -- A retry or later completion of an accepted scan is never a second admission.
 if exists(select 1 from app_private.scan_evidence where run_stop_id=s.id) then return;end if;
 select * into ps from app_private.route_plan_stops where id=s.plan_stop_id;
 select * into p from app_private.portals where id=coalesce(s.portal_id,ps.portal_id) and event_id=g.event_id;
 select * into cfg from app_private.event_route_settings where event_id=g.event_id;
 select * into booking from app_private.portal_reservations where id=s.reservation_id or bound_stop_id=s.id order by id limit 1;
 if p.id is null or p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE' using errcode='23514';end if;
 select count(*) into children from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
 if children<=0 then raise exception 'EMPTY_GROUP' using errcode='23514';end if;
 is_finale:=s.stop_kind='finale' and cfg.final_portal_id=p.id;
 if is_finale then
  if not cfg.finale_available then raise exception 'FINALE_UNAVAILABLE' using errcode='23514';end if;
  max_groups:=cfg.finale_max_concurrent_groups;max_children:=cfg.finale_max_concurrent_children;
  until_at:=decision_at+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds);
 else
  -- Preserve a valid released instruction when its expected reception interval
  -- differs from the actual arrival; use that window's existing capacity limits.
  select * into w from app_private.portal_windows pw where pw.portal_id=p.id and
   ((decision_at>=pw.opens_at and decision_at<pw.closes_at) or (coalesce(booking.reserved_from,ps.planned_arrival_at)>=pw.opens_at and coalesce(booking.reserved_from,ps.planned_arrival_at)<pw.closes_at))
   order by (decision_at>=pw.opens_at and decision_at<pw.closes_at) desc,pw.opens_at,pw.id limit 1;
  if w.id is null then raise exception 'PORTAL_CAPACITY_UNAVAILABLE' using errcode='23514';end if;
  max_groups:=w.max_concurrent_groups;max_children:=w.max_children_per_visit;
  until_at:=decision_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,w.visit_minutes*60)+greatest(cfg.route_buffer_seconds,w.buffer_minutes*60));
 end if;
 usage:=app_private.physical_portal_usage(g.event_id,p.id,g.id,decision_at,until_at,children,decision_at);
 if (usage->>'peakGroups')::integer>max_groups then raise exception 'PORTAL_CAPACITY_EXCEEDED' using errcode='23514';end if;
 if (usage->>'peakChildren')::integer>max_children then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode='23514';end if;
 if not is_finale and w.max_children_total is not null and (usage->>'totalChildren')::integer>w.max_children_total then raise exception 'PORTAL_TOTAL_CAPACITY_EXCEEDED' using errcode='23514';end if;
end;
$function$;
revoke all on function app_private.assert_physical_portal_admission(uuid,uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.assess_ordinary_portal(_event_id uuid, _group_id uuid, _portal_id uuid, _arrival_at timestamp with time zone, _children integer, _decision_at timestamp with time zone DEFAULT statement_timestamp(), _visit_end timestamp with time zone DEFAULT NULL::timestamp with time zone, _occupied_until timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; cfg app_private.event_route_settings; w app_private.portal_windows;
  codes jsonb:='[]'; reasons jsonb:='[]'; visit_end timestamptz; occupied_until timestamptz;
  peak_groups integer:=0; peak_children integer:=0; total_children integer:=0;
  visit_seconds integer; buffer_seconds integer; usage jsonb;
begin
  select * into p from app_private.portals where id=_portal_id and event_id=_event_id;
  select * into cfg from app_private.event_route_settings where event_id=_event_id;
  if p.id is null then return jsonb_build_object('eligible',false,'blockingCodes',jsonb_build_array('PORTAL_NOT_ROUTE_READY'),'reasons',jsonb_build_array('Deze poort hoort niet bij dit evenement.')); end if;
  if _children is null or _children<=0 then codes:=codes||'"EMPTY_GROUP"'::jsonb; reasons:=reasons||'"Er zijn geen aanwezige kinderen om toe te wijzen."'::jsonb; end if;
  if p.approval_status<>'approved' or p.lifecycle_status<>'active' then
    codes:=codes||'"PORTAL_NOT_APPROVED"'::jsonb; reasons:=reasons||'"Deze poort is niet goedgekeurd en actief."'::jsonb; end if;
  if p.operation_status not in ('open','scheduled') then
    codes:=codes||'"PORTAL_NOT_OPEN"'::jsonb; reasons:=reasons||jsonb_build_array(case when p.operation_status='paused' then 'Deze poort heeft pauze.' else 'Deze poort ontvangt geen nieuwe groepen.' end); end if;
  if not exists(select 1 from app_private.portal_private_locations l where l.portal_id=p.id and l.verified_at is not null)
    or not app_private.portal_has_verified_walking_connection(p.id) then
    codes:=codes||'"PORTAL_NOT_VERIFIED"'::jsonb; reasons:=reasons||'"Locatie en veilige wandelverbinding zijn nog niet bevestigd."'::jsonb; end if;
  select pw.* into w from app_private.portal_windows pw where pw.portal_id=p.id and _arrival_at>=pw.opens_at and _arrival_at<pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,pw.visit_minutes*60)))<=pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(mins=>pw.visit_minutes))>=_arrival_at+make_interval(mins=>pw.visit_minutes)
    order by pw.opens_at,pw.id limit 1;
  if w.id is null then
    if _arrival_at is null then
      codes:=codes||'"ARRIVAL_TIME_REQUIRED"'::jsonb; reasons:=reasons||'"De verwachte aankomst is nog niet bekend."'::jsonb;
    else
      codes:=codes||'"PORTAL_WINDOW_CONFLICT"'::jsonb; reasons:=reasons||'"De verwachte aankomst en het bezoek passen niet binnen de openingstijd."'::jsonb;
    end if;
  else
    visit_end:=coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,w.visit_minutes*60)));
    occupied_until:=greatest(visit_end,coalesce(_occupied_until,visit_end+make_interval(secs=>greatest(cfg.route_buffer_seconds,w.buffer_minutes*60))));
    visit_seconds:=extract(epoch from visit_end-_arrival_at)::integer;
    buffer_seconds:=extract(epoch from occupied_until-visit_end)::integer;
    if _children>w.max_children_per_visit then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb;
      reasons:=reasons||jsonb_build_array(format('%s kinderen; deze poort kan maximaal %s kinderen ontvangen.',_children,w.max_children_per_visit)); end if;
    usage:=app_private.physical_portal_usage(_event_id,p.id,_group_id,_arrival_at,occupied_until,_children,_decision_at);
    peak_groups:=(usage->>'peakGroups')::integer;peak_children:=(usage->>'peakChildren')::integer;total_children:=(usage->>'totalChildren')::integer;
    if peak_groups>w.max_concurrent_groups then
      codes:=codes||'"PORTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('Dit tijdvak heeft ruimte voor %s gelijktijdige groepen; het is al bezet.',w.max_concurrent_groups)); end if;
    if peak_children>w.max_children_per_visit and not (_children>w.max_children_per_visit) then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('In dit tijdvak zouden %s kinderen tegelijk aankomen; er is ruimte voor %s.',peak_children,w.max_children_per_visit)); end if;
    if w.max_children_total is not null and total_children>w.max_children_total then
      codes:=codes||'"PORTAL_TOTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('De totale ontvangstcapaciteit van %s kinderen bij deze poort is bereikt.',w.max_children_total)); end if;
  end if;
  return jsonb_build_object('eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
    'windowId',w.id,'plannedArrivalAt',_arrival_at,'plannedDepartureAt',visit_end,'occupiedUntil',occupied_until,
    'visitSeconds',visit_seconds,'bufferSeconds',buffer_seconds,'capacity',jsonb_build_object('groupChildren',_children,
      'maxChildren',w.max_children_per_visit,'maxGroups',w.max_concurrent_groups,'peakGroups',peak_groups,
      'peakChildren',peak_children,'totalChildren',total_children,'maxChildrenTotal',w.max_children_total));
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.assess_finale_reservation(_event_id uuid, _group_id uuid, _portal_id uuid, _arrival timestamp with time zone, _until timestamp with time zone, _children integer, _decision_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cfg app_private.event_route_settings; codes jsonb:='[]'; reasons jsonb:='[]'; peak_groups integer:=0; peak_children integer:=0; usage jsonb;
begin
 select * into cfg from app_private.event_route_settings where event_id=_event_id;
 if cfg.event_id is null or not cfg.finale_available or cfg.final_portal_id is distinct from _portal_id
  or not exists(select 1 from app_private.portals p where p.id=_portal_id and p.event_id=_event_id
    and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled'))
  or not app_private.portal_has_verified_walking_connection(_portal_id) then
   codes:=codes||'"FINALE_UNAVAILABLE"'::jsonb;reasons:=reasons||'"De gepubliceerde finale is niet beschikbaar; organisatiecontrole is nodig."'::jsonb;
 end if;
 if _children is null or _children<=0 then codes:=codes||'"EMPTY_GROUP"'::jsonb;reasons:=reasons||'"Er zijn geen aanwezige kinderen."'::jsonb; end if;
 if _arrival is null or _until is null or _arrival<cfg.finale_opens_at or _arrival>cfg.finale_last_arrival_at or _until>cfg.finale_closes_at or _until<=_arrival then
  codes:=codes||'"FINALE_WINDOW_CONFLICT"'::jsonb;reasons:=reasons||'"De gereserveerde finale past niet in het geldige ontvangstvenster."'::jsonb;
 end if;
 usage:=app_private.physical_portal_usage(_event_id,_portal_id,_group_id,_arrival,_until,_children,_decision_at);
 peak_groups:=(usage->>'peakGroups')::integer;peak_children:=(usage->>'peakChildren')::integer;
 if peak_groups>cfg.finale_max_concurrent_groups or peak_children>cfg.finale_max_concurrent_children then
  codes:=codes||'"FINALE_CAPACITY_EXCEEDED"'::jsonb;reasons:=reasons||'"De vaste finale-afspraak heeft onvoldoende beschikbare ontvangstcapaciteit."'::jsonb;
 end if;
 return jsonb_build_object('eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
  'peakGroups',peak_groups,'peakChildren',peak_children,'maxGroups',cfg.finale_max_concurrent_groups,'maxChildren',cfg.finale_max_concurrent_children);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.validate_ordinary_reservation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare assessment jsonb;
begin
  if new.bound_stop_id is not null and not exists(select 1 from app_private.run_stops s
    join app_private.group_runs r on r.id=s.run_id and r.group_id=new.group_id
    join app_private.walking_groups g on g.id=r.group_id and g.event_id=new.event_id
    left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
    where s.id=new.bound_stop_id and s.run_id=new.run_id and coalesce(s.portal_id,ps.portal_id)=new.portal_id)
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  if new.kind<>'ordinary' or new.status not in ('held','active') then return new; end if;
  if tg_op='UPDATE' and row(new.portal_id,new.group_id,new.run_id,new.child_count,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.child_count,old.reserved_from,old.reserved_until,old.service_until)
    then return new; end if;
  perform app_private.lock_evening_event(new.event_id);
  if not exists(select 1 from app_private.walking_groups g where g.id=new.group_id and g.event_id=new.event_id)
    or (new.run_id is not null and not exists(select 1 from app_private.group_runs r where r.id=new.run_id and r.group_id=new.group_id and r.status in ('ready','live','paused')))
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  -- Shrinking an existing current booking never evicts the released destination.
  if tg_op='UPDATE' and new.child_count<=old.child_count and row(new.portal_id,new.group_id,new.run_id,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.reserved_from,old.reserved_until,old.service_until) then return new; end if;
  assessment:=app_private.assess_ordinary_portal(new.event_id,new.group_id,new.portal_id,new.reserved_from,new.child_count,
    clock_timestamp(),coalesce(new.service_until,new.reserved_until),new.reserved_until);
  if not (assessment->>'eligible')::boolean then raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.run_scan(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
  inserted_count integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select credential.* into credential_record
  from app_private.run_stops run_stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    -- A pause means "no new groups". A group already inside may still scan and
    -- finish safely; a direct close remains blocked.
    and portal.operation_status in ('open', 'paused')
    and credential.revoked_at is null and credential.valid_from <= now()
    and (credential.valid_until is null or credential.valid_until > now())
    and (
      (_method = 'qr' and credential.token_hash = extensions.digest(convert_to(_credential, 'utf8'), 'sha256'))
      or (_method = 'short_code' and credential.short_code_hash = extensions.digest(convert_to(upper(trim(_credential)), 'utf8'), 'sha256'))
    )
  order by credential.version desc limit 1;
  if credential_record.id is null then raise exception 'WRONG_PORTAL' using errcode = '22023'; end if;
  perform app_private.assert_finale_arrival_window(_run_id,_expected_stop_id);
 perform app_private.assert_physical_portal_admission(_run_id,_expected_stop_id);
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  get diagnostics inserted_count=row_count;
  if inserted_count>0 then
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  end if;
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.assert_arrival_credential(_run_id uuid, _stop_id uuid, _version integer, _credential text, _method text, _portal_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; p app_private.portals; credentialid uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if r.version<>_version or r.current_stop_id is distinct from _stop_id then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status<>'live' then raise exception 'RUN_NOT_LIVE'; end if;
 select portal.* into p from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 join app_private.portals portal on portal.id=coalesce(s.portal_id,plan.portal_id) where s.id=_stop_id and s.run_id=_run_id and s.state='active' for share of portal;
 if p.id is null or (_portal_id is not null and p.id<>_portal_id) then raise exception 'WRONG_PORTAL'; end if;
 if p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 if _method not in ('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160 then raise exception 'WRONG_PORTAL'; end if;
 select c.id into credentialid from app_private.portal_credentials c where c.portal_id=p.id and c.revoked_at is null
 and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
 and ((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
 or (_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
 order by c.version desc limit 1;
 if credentialid is null then raise exception 'WRONG_PORTAL'; end if;
 perform app_private.assert_finale_arrival_window(_run_id,_stop_id);
 perform app_private.assert_physical_portal_admission(_run_id,_stop_id);
 return credentialid;
end $function$
;
