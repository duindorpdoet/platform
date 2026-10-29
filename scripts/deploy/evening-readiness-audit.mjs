// Restricted release audit: direct SELECTs only. Never calls snapshot RPCs, seeds
// routes, publishes starts or exposes names, addresses, contact or participant IDs.
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const AUDIT_QUERY = `with
 e as materialized(select * from app_private.events where slug='duindorp-halloween-2026'),
 settings as materialized(select s.* from app_private.event_route_settings s join e on e.id=s.event_id),
 groups as materialized(select g.* from app_private.walking_groups g join e on e.id=g.event_id where g.retired_at is null),
 votes as materialized(select distinct a.group_id,r.id,r.desired_end_at from app_private.group_registrations a
  join groups g on g.id=a.group_id join app_private.registrations r on r.id=a.registration_id
  where a.superseded_at is null and r.status='submitted' and r.desired_end_at is not null),
 dominant as materialized(select distinct on(group_id) group_id,desired_end_at from votes v
  group by group_id,desired_end_at order by group_id,count(*) desc,
  (select sum(abs(extract(epoch from (other.desired_end_at-v.desired_end_at)))) from votes other where other.group_id=v.group_id),desired_end_at),
 publications as materialized(select distinct on(p.group_id) p.* from app_private.group_start_publications p join groups g on g.id=p.group_id
  where not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order)
  order by p.group_id,p.publication_order desc),
 portals as materialized(select p.*,w.slug world_slug,l.street,l.house_number,l.addition,l.postal_code,l.city,
  nullif(trim(coalesce(to_jsonb(p)->>'public_entrance_instructions',
   (select a.private_draft_data->>'entrance' from app_private.portal_applications a where a.id=p.application_id),'')),'') is not null entrance_present,
  case when l.marker_latitude is not null or l.marker_longitude is not null then l.marker_latitude
   when l.geocoded_latitude is not null or l.geocoded_longitude is not null then l.geocoded_latitude else l.latitude end lat,
  case when l.marker_latitude is not null or l.marker_longitude is not null then l.marker_longitude
   when l.geocoded_latitude is not null or l.geocoded_longitude is not null then l.geocoded_longitude else l.longitude end lon
  from app_private.portals p join e on e.id=p.event_id join app_private.worlds w on w.id=p.world_id
  left join app_private.portal_private_locations l on l.portal_id=p.id),
 point_locations as materialized(select p.*,'START-'||row_number() over(order by p.id) audit_point_code,
  case when p.marker_latitude is not null or p.marker_longitude is not null then p.marker_latitude
   when p.geocoded_latitude is not null or p.geocoded_longitude is not null then p.geocoded_latitude else p.latitude end lat,
  case when p.marker_latitude is not null or p.marker_longitude is not null then p.marker_longitude
   when p.geocoded_latitude is not null or p.geocoded_longitude is not null then p.geocoded_longitude else p.longitude end lon
  from app_private.start_points p join e on e.id=p.event_id),
 stored_visits as materialized(
  select v.group_id,v.portal_id,v.kind,v.run_stop_id,v.sequence,v.starts_at,v.duration_seconds,v.buffer_seconds,v.source
  from app_private.live_route_visits v join groups g on g.id=v.group_id where v.retired_at is null
   and (v.run_stop_id is not null or (v.kind='start' and exists(select 1 from app_private.group_runs r where r.group_id=v.group_id))
    or not exists(select 1 from app_private.group_runs r where r.group_id=v.group_id and r.status in ('completed','stopped')))
  union all
  select r.group_id,coalesce(s.portal_id,ps.portal_id),coalesce(s.stop_kind::text,'ordinary'),s.id,s.sequence,
   coalesce(pr.reserved_from,s.opened_at),greatest(30,coalesce(extract(epoch from pr.reserved_until-pr.reserved_from)::integer,300)),0,'actual'
  from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join groups g on g.id=r.group_id
  left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id left join app_private.portal_reservations pr on pr.id=s.reservation_id
  where not exists(select 1 from app_private.live_route_visits v where v.run_stop_id=s.id)),
 arrivals as materialized(select r.group_id,coalesce(s.portal_id,ps.portal_id) portal_id,count(distinct s.id) stops
  from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join groups g on g.id=r.group_id
  left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
  where exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=s.id and a.arrived)
   or(s.state='completed' and s.outcome in('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence scan where scan.run_stop_id=s.id))
  group by r.group_id,coalesce(s.portal_id,ps.portal_id)),
 schedule_rows as materialized(select s.group_id,s.id,s.expected_finale_arrival_at,slot.starts_at,slot.start_point_id
  from groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
  join app_private.start_slots slot on slot.id=s.start_slot_id where s.state in('draft','published')
  union select p.group_id,p.schedule_id,s.expected_finale_arrival_at,p.starts_at,(p.slot_snapshot->>'start_point_id')::uuid
  from publications p left join app_private.group_schedule_revisions s on s.id=p.schedule_id),
 finale_occupancy as materialized(select group_id,expected_finale_arrival_at starts_at,
  expected_finale_arrival_at+make_interval(secs=>s.finale_show_seconds+s.finale_turnover_seconds) ends_at
  from schedule_rows cross join settings s where expected_finale_arrival_at is not null
  union all select r.group_id,r.reserved_from,r.reserved_until from app_private.portal_reservations r cross join settings s
  where r.portal_id=s.final_portal_id and r.status in('held','active','completed')),
 coverage as materialized(select p.* from app_private.world_coverage_policies p join e on e.id=p.event_id),
 report as(select jsonb_build_object(
  'readOnly',true,'eventDate',e.local_date,'settingsVersion',e.settings_version,
  'registrationChannels',jsonb_build_object('housesOpen',coalesce((e.settings->>'portalRegistrationOpen')::boolean,true),'participantsOpen',coalesce((e.settings->>'groupRegistrationOpen')::boolean,false)),
  'counts',jsonb_build_object('groups',(select count(*) from groups),'approvedActiveHouses',(select count(*) from portals where approval_status='approved' and lifecycle_status='active'),
   'storedBoardVisits',(select count(*) from stored_visits),'begunRuns',(select count(*) from app_private.group_runs r join groups g on g.id=r.group_id)),
  'finale',coalesce((select jsonb_build_object('portalCode',p.system_code,'plannerMode',s.planner_mode,'available',s.finale_available,
   'portalApprovedActive',p.approval_status='approved' and p.lifecycle_status='active','markerValid',coalesce(p.lat between -90 and 90 and p.lon between -180 and 180,false),
   'opensAt',s.finale_opens_at,'lastArrivalAt',s.finale_last_arrival_at,'closesAt',s.finale_closes_at,
   'ordinaryStopAt',s.global_ordinary_stop_at,'showSeconds',s.finale_show_seconds,'turnoverSeconds',s.finale_turnover_seconds,
   'maxGroups',s.finale_max_concurrent_groups,'maxChildren',s.finale_max_concurrent_children,
   'windows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',w.opens_at,'closesAt',w.closes_at,'maxGroups',w.max_concurrent_groups,'maxChildren',w.max_children_per_visit,'maxTotalChildren',w.max_children_total)) from app_private.portal_windows w where w.portal_id=s.final_portal_id),'[]'::jsonb),
   'readinessCodes',to_jsonb(array_remove(array[
    case when s.planner_mode<>'dynamic' then 'PLANNER_MODE_NOT_DYNAMIC' end,
    case when not s.finale_available then 'FINALE_NOT_CONFIRMED_AVAILABLE' end,
    case when p.id is null then 'FINALE_PORTAL_MISSING' end,
    case when p.id is not null and (p.approval_status<>'approved' or p.lifecycle_status<>'active') then 'FINALE_PORTAL_NOT_ACTIVE' end,
    case when not coalesce(p.lat between -90 and 90 and p.lon between -180 and 180,false) then 'FINALE_MARKER_INVALID' end,
    case when s.finale_opens_at is null or s.finale_last_arrival_at is null or s.finale_closes_at is null then 'FINALE_TIMES_MISSING' end,
    case when s.finale_opens_at>s.finale_last_arrival_at or s.finale_last_arrival_at>s.finale_closes_at
     or s.finale_opens_at+make_interval(secs=>s.finale_show_seconds+s.finale_turnover_seconds)>s.finale_closes_at then 'FINALE_WINDOW_TOO_SHORT' end,
    case when not exists(select 1 from app_private.portal_windows win where win.portal_id=s.final_portal_id
     and greatest(win.opens_at,s.finale_opens_at)+make_interval(secs=>s.finale_show_seconds+s.finale_turnover_seconds)<=least(win.closes_at,s.finale_closes_at)
     and win.max_concurrent_groups>0 and win.max_children_per_visit>0) then 'FINALE_PHYSICAL_WINDOW_MISSING' end
   ],null))) from settings s left join portals p on p.id=s.final_portal_id),'{}'::jsonb),
  'worldCoverage',jsonb_build_object('active',(select jsonb_build_object('version',version,'missingWorlds',missing_worlds) from coverage where to_jsonb(coverage)->>'policy_status'='active' order by version desc limit 1),
   'pending',(select jsonb_build_object('version',version,'missingWorlds',missing_worlds) from coverage where to_jsonb(coverage)->>'policy_status'='pending' order by version desc limit 1),
   'latest',(select jsonb_build_object('version',version,'missingWorlds',missing_worlds,'status',coalesce(to_jsonb(coverage)->>'policy_status','legacy_dynamic')) from coverage order by version desc limit 1)),
  'groups',coalesce((select jsonb_agg(jsonb_build_object(
   'code',g.system_code,'status',g.status,'routeMode',g.route_mode,'scheduleRevision',s.revision,'scheduleState',s.state,
   'publicationRevision',pub.revision,'publishedStartsAt',pub.starts_at,'startPointCode',point.audit_point_code,'startPortalCode',linked.system_code,'startsAt',slot.starts_at,
   'desiredEndAt',d.desired_end_at,'ordinaryStopAt',s.effective_ordinary_stop_at,'finaleArrivalAt',s.expected_finale_arrival_at,
   'expectedCompletionAt',s.expected_finale_arrival_at+make_interval(secs=>rs.finale_show_seconds),
   'endDeviationMinutes',round(extract(epoch from(s.expected_finale_arrival_at+make_interval(secs=>rs.finale_show_seconds)-d.desired_end_at))/60.0,2),
   'overrunAllowed',d.desired_end_at is null or s.expected_finale_arrival_at+make_interval(secs=>rs.finale_show_seconds)<=d.desired_end_at+interval '30 minutes',
   'routeRevision',lp.version,'routeSource',case when lp.group_id is null then 'not_stored_check_route' else 'stored_live_board' end,
   'routeMatchesCurrentSchedule',lp.schedule_id is not distinct from g.current_schedule_revision_id,
   'ordinaryHouses',case when lp.group_id is null and not exists(select 1 from app_private.group_runs r where r.group_id=g.id) then null else (select count(distinct coalesce(p.application_id,p.id)) from stored_visits v join portals p on p.id=v.portal_id where v.group_id=g.id and v.kind='ordinary') end,
   'finales',case when lp.group_id is null and not exists(select 1 from app_private.group_runs r where r.group_id=g.id) then null else (select count(*) from stored_visits v where v.group_id=g.id and v.kind='finale') end,
   'linkedFirstVisit',point.counts_as_first_portal_visit and point.linked_portal_id is not null,
   'linkedFirstVisitCount',(select count(*) from stored_visits v where v.group_id=g.id and v.portal_id=point.linked_portal_id and v.kind<>'start'),
   'duplicatePlannedPortals',coalesce((select jsonb_agg(jsonb_build_object('portalCode',q.system_code,'visits',q.n)) from(
    select p.system_code,count(*) n from stored_visits v join portals p on p.id=v.portal_id where v.group_id=g.id and v.kind<>'start' group by p.system_code having count(*)>1) q),'[]'::jsonb),
   'finaleUsedAsOrdinary',exists(select 1 from stored_visits v where v.group_id=g.id and v.portal_id=rs.final_portal_id and v.kind='ordinary'),
   'provenPhysicalVisits',(select count(*) from arrivals a where a.group_id=g.id),
   'duplicateProvenPortals',coalesce((select jsonb_agg(jsonb_build_object('portalCode',p.system_code,'stops',a.stops)) from arrivals a join portals p on p.id=a.portal_id where a.group_id=g.id and a.stops>1),'[]'::jsonb),
   'canonicalVisits',(select count(*) from app_private.group_portal_visits c where c.group_id=g.id),
   'runCount',(select count(*) from app_private.group_runs r where r.group_id=g.id),
   'startMarkerValid',coalesce(point.lat between -90 and 90 and point.lon between -180 and 180,false),
   'startEntrancePresent',nullif(trim(point.safe_approach),'') is not null,
   'invalidDestinationCodes',coalesce((select jsonb_agg(distinct p.system_code) from stored_visits v join portals p on p.id=v.portal_id where v.group_id=g.id and not coalesce(p.lat between -90 and 90 and p.lon between -180 and 180,false)),'[]'::jsonb),
   'missingEntranceInstructionCodes',coalesce((select jsonb_agg(distinct p.system_code) from stored_visits v join portals p on p.id=v.portal_id where v.group_id=g.id and not p.entrance_present),'[]'::jsonb),
   'ordinaryAndersPlanned',exists(select 1 from stored_visits v join portals p on p.id=v.portal_id where v.group_id=g.id and v.kind='ordinary' and p.world_slug='anders'),
   'scheduleWarnings',coalesce((select jsonb_agg(item.value) from jsonb_array_elements_text(coalesce(s.warnings,'[]'::jsonb)) item(value) where item.value~'^[A-Z0-9_]+$'),'[]'::jsonb),
   'finaleConcurrentGroups',(select count(distinct f.group_id) from finale_occupancy f where f.starts_at<=s.expected_finale_arrival_at and f.ends_at>s.expected_finale_arrival_at),
   'departureConcurrentGroups',(select count(distinct other.group_id) from schedule_rows other join point_locations op on op.id=other.start_point_id
    where coalesce(op.linked_portal_id,op.id)=coalesce(point.linked_portal_id,point.id) and other.starts_at=slot.starts_at)
   ) order by g.system_code) from groups g left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
   left join publications pub on pub.group_id=g.id
   left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id) left join point_locations point on point.id=coalesce(slot.start_point_id,(pub.slot_snapshot->>'start_point_id')::uuid)
   left join portals linked on linked.id=point.linked_portal_id
   left join dominant d on d.group_id=g.id left join app_private.live_route_plans lp on lp.group_id=g.id cross join settings rs),'[]'::jsonb),
  'possiblePhysicalAliases',coalesce((select jsonb_agg(jsonb_build_object('portalCodes',codes,'basis',basis)) from(
   select array_agg(system_code order by system_code) codes,'same_application' basis from portals
    where approval_status='approved' and lifecycle_status='active' and application_id is not null group by application_id having count(*)>1
   union all select array_agg(system_code order by system_code),'same_address_requires_review' from portals
    where approval_status='approved' and lifecycle_status='active' and postal_code is not null and street is not null
    group by lower(regexp_replace(postal_code,'\\s','','g')),lower(trim(street)),lower(trim(house_number)),lower(trim(coalesce(addition,''))) having count(*)>1
   union all select array_agg(system_code order by system_code),'same_exact_pin_requires_review' from portals
    where approval_status='approved' and lifecycle_status='active' and lat is not null and lon is not null group by lat,lon having count(*)>1
   ) aliases),'[]'::jsonb),
  'checkpoint',jsonb_build_object(
   'settings',md5(coalesce((select jsonb_agg(to_jsonb(s) order by s.event_id)::text from settings s),'null')||e.settings::text),
   'appointments',md5(coalesce((select jsonb_agg(to_jsonb(s) order by s.id)::text from app_private.group_schedule_revisions s join groups g on g.id=s.group_id),'null')
    ||coalesce((select jsonb_agg(to_jsonb(p) order by p.publication_order)::text from app_private.group_start_publications p join e on e.id=p.event_id),'null')),
   'routesAndRuns',md5(coalesce((select jsonb_agg(to_jsonb(lp) order by lp.group_id)::text from app_private.live_route_plans lp join e on e.id=lp.event_id),'null')
    ||coalesce((select jsonb_agg(to_jsonb(v) order by v.id)::text from app_private.live_route_visits v join e on e.id=v.event_id),'null')
    ||coalesce((select jsonb_agg(to_jsonb(r) order by r.id)::text from app_private.group_runs r join groups g on g.id=r.group_id),'null')
    ||coalesce((select jsonb_agg(to_jsonb(s) order by s.id)::text from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join groups g on g.id=r.group_id),'null')))
 ) audit from e)
select audit from report`;

export const SNAPSHOT_STATS_QUERY = `select calls,round(mean_exec_time::numeric,2) mean_ms,round(max_exec_time::numeric,2) max_ms,rows,
 case when query ilike '%admin_live_planboard_snapshot%' then 'admin_live_planboard_snapshot' else 'other' end rpc
 from extensions.pg_stat_statements where query ilike '%admin_live_planboard_snapshot%' and query not ilike '%pg_stat_statements%' order by calls desc limit 10`;

export async function runAudit(env = process.env) {
  if (!/^[a-z0-9]{15,30}$/.test(env.SUPABASE_PROJECT_REF ?? "") || !env.SUPABASE_ACCESS_TOKEN) throw new Error("READ_ONLY_AUDIT_CONFIGURATION_REQUIRED");
  async function query(sql) {
    const response = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`, {
      method: "POST", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ read_only: true, query: sql }), signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) throw new Error(`READ_ONLY_AUDIT_${response.status}`);
    return response.json();
  }
  const [{ audit }] = await query(AUDIT_QUERY);
  if (!audit || !Array.isArray(audit.groups)) throw new Error("READ_ONLY_AUDIT_EVENT_MISSING");
  let statementStats;
  try { statementStats = { readable: true, statements: await query(SNAPSHOT_STATS_QUERY) }; }
  catch { statementStats = { readable: false, reason: "Statement statistics unavailable to the read-only management role" }; }
  const result = { code: "READ_ONLY_EVENING_READINESS_AUDIT", generatedAt: new Date().toISOString(), revision: env.GITHUB_SHA ?? null,
    ...audit, statementStats, changedRows: 0, messagesSent: 0 };
  const directory = join(env.RUNNER_TEMP ?? "/tmp", "duindorp-evening-baseline");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const output = join(directory, "audit.json");
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  console.log(JSON.stringify(result));
  return output;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await runAudit();
