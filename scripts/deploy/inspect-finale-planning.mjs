// Read-only release diagnosis. Only aggregate timing facts leave memory. No
// addresses, contacts, registration/group/slot IDs or participant rows are saved.
import { execFileSync } from "node:child_process";
import { readFile, mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";
const response = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`, {
  method: "POST", headers: { Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`, "Content-Type": "application/json" },
  body: JSON.stringify({ read_only: true, query: `with e as(select id,settings from app_private.events where slug='duindorp-halloween-2026'),
  focus as(select g.* from app_private.walking_groups g join e on e.id=g.event_id where g.system_number=48 and g.retired_at is null),
  points as(select p.*,row_number() over(order by p.id)::text anonymous_id from app_private.start_points p join e on e.id=p.event_id),
  slots as(select s.*,row_number() over(order by s.id)::text anonymous_id from app_private.start_slots s join e on e.id=s.event_id),
  physical as(select p.id,coalesce(linked_portal_id,p.id) physical_id,dense_rank() over(order by coalesce(linked_portal_id,p.id))::text anonymous_id from points p),
  reservations as(
   select g.id group_id,s.id schedule_id,s.start_slot_id,slot.starts_at,slot.start_point_id,s.expected_finale_arrival_at,
    (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) children
   from app_private.walking_groups g join e on e.id=g.event_id join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id and s.state='draft'
   join app_private.start_slots slot on slot.id=s.start_slot_id where g.retired_at is null and g.status not in ('finished','completed','stopped','cancelled') and not exists(select 1 from app_private.group_runs run where run.group_id=g.id and run.status in ('stopped','completed')) and g.id not in(select id from focus)
   union
   select p.group_id,p.schedule_id,(p.slot_snapshot->>'id')::uuid,p.starts_at,(p.slot_snapshot->>'start_point_id')::uuid,s.expected_finale_arrival_at,
    (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=p.group_id and a.superseded_at is null)
   from app_private.group_start_publications p join e on e.id=p.event_id join app_private.walking_groups g on g.id=p.group_id and g.retired_at is null
   left join app_private.group_schedule_revisions s on s.id=p.schedule_id
   where g.status not in ('finished','completed','stopped','cancelled') and not exists(select 1 from app_private.group_runs run where run.group_id=g.id and run.status in ('stopped','completed')) and p.group_id not in(select id from focus) and not exists(select 1 from app_private.group_start_publications later where later.group_id=p.group_id and later.publication_order>p.publication_order)
   and not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order)
  ) select jsonb_build_object(
   'settings',(select jsonb_build_object('targetGroupSize',least(coalesce((e.settings->>'targetGroupSize')::integer,15),coalesce((e.settings->>'maxGroupSize')::integer,20)),'maxGroupSize',coalesce((e.settings->>'maxGroupSize')::integer,20),'globalOrdinaryStopAt',s.global_ordinary_stop_at,
    'finaleOpensAt',s.finale_opens_at,'finaleLastArrivalAt',s.finale_last_arrival_at,'finaleClosesAt',s.finale_closes_at,
    'finaleShowSeconds',s.finale_show_seconds,'finaleTurnoverSeconds',s.finale_turnover_seconds,'finalePlanningTransferSeconds',s.finale_planning_transfer_seconds,
    'finaleMaxGroups',s.finale_max_concurrent_groups,'finaleMaxChildren',s.finale_max_concurrent_children,
    'finaleWindows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',w.opens_at,'closesAt',w.closes_at,'maxGroups',w.max_concurrent_groups,'maxChildren',w.max_children_per_visit,'maxTotalChildren',w.max_children_total)) from app_private.portal_windows w where w.portal_id=s.final_portal_id),'[]'::jsonb))
    from app_private.event_route_settings s join e on e.id=s.event_id),
   'parties',coalesce((select jsonb_agg(jsonb_build_object('id','family-'||n,'fixedGroupId','focus','childCount',children,'preferredStartAt',preferred_start_at,'desiredEndAt',desired_end_at,'requestedStopAt',requested_ordinary_stop_at))
    from(select row_number() over(order by r.id) n,r.preferred_start_at,r.desired_end_at,r.requested_ordinary_stop_at,
     (select count(*) from app_private.registration_children c where c.registration_id=r.id and c.participation_status='active') children
     from focus g join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null join app_private.registrations r on r.id=a.registration_id and r.status='submitted') q),'[]'::jsonb),
   'starts',coalesce((select jsonb_agg(jsonb_build_object('id','slot-'||slot.anonymous_id,'startPointId','point-'||physical.anonymous_id,'startsAt',slot.starts_at,
    'maxGroups',1,'maxChildren',least(slot.max_children,p.max_gathering_children),'availableFrom',p.available_from,'availableUntil',p.available_until,
    'markerValid',coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude) is not null and coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude) is not null))
    from slots slot join points p on p.id=slot.start_point_id join physical on physical.id=p.id where slot.active and p.active),'[]'::jsonb),
   'existingSchedules',coalesce((select jsonb_agg(jsonb_build_object('id','reservation-'||n,'groupId','group-'||gn,'startId','old-'||n,'startPointId','point-'||p.anonymous_id,'startsAt',r.starts_at,'childCount',r.children,'expectedFinaleArrivalAt',coalesce(r.expected_finale_arrival_at,(select finale_last_arrival_at from app_private.event_route_settings where event_id=(select id from e)))))
    from(select r.*,row_number() over(order by r.schedule_id,r.group_id,r.starts_at) n,dense_rank() over(order by r.group_id) gn from reservations r) r join physical p on p.id=r.start_point_id),'[]'::jsonb),
   'stored',(select jsonb_build_object('ordinaryStop',s.effective_ordinary_stop_at,'arrival',s.expected_finale_arrival_at,'state',s.state)
    from focus g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id),
   'started',(select exists(select 1 from app_private.group_runs r join focus g on g.id=r.group_id))
  ) diagnostic` }), signal: AbortSignal.timeout(60_000),
});
if (!response.ok) throw new Error(`READ_ONLY_FINALE_DIAGNOSTIC_${response.status}`);
const [{ diagnostic }] = await response.json();
const directory = await mkdtemp(join(tmpdir(), "finale-planner-source-"));
try {
  for (const name of ["start-preference", "route-planner"]) {
    const source = (await readFile(`lib/domain/${name}.ts`, "utf8")).replace('"./start-preference"', '"./start-preference.mjs"');
    await writeFile(join(directory, `${name}.mjs`), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText);
  }
  const baselineCommit = "d4b54ff23c0c928e21019c6631ba7b937781e130";
  let baselineSource;
  try { baselineSource = execFileSync("git", ["show", `${baselineCommit}:lib/domain/route-planner.ts`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); }
  catch {
    const baselineResponse = await fetch(`https://api.github.com/repos/duindorpdoet/platform/contents/lib/domain/route-planner.ts?ref=${baselineCommit}`, {
      headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" }, signal: AbortSignal.timeout(30_000),
    });
    if (!baselineResponse.ok) throw new Error(`BASELINE_PLANNER_READ_${baselineResponse.status}`);
    const blob = await baselineResponse.json(); baselineSource = Buffer.from(blob.content, "base64").toString("utf8");
  }
  await writeFile(join(directory, "previous-planner.mjs"), ts.transpileModule(baselineSource.replace('"./start-preference"', '"./start-preference.mjs"'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText);
  const { proposePlan: previousPlanner } = await import(pathToFileURL(join(directory, "previous-planner.mjs")));
  const { proposePlan } = await import(pathToFileURL(join(directory, "route-planner.mjs")));
  // Fetch policy from its reviewed definition; the release may not have migrated yet.
  const policySource = await readFile("supabase/migrations/20261029021051_group_completion_target.sql", "utf8");
  const maxGroupOverrunSeconds = Number(policySource.match(/returns integer language sql immutable set search_path='' as \$\$ select (\d+) \$\$/)?.[1]);
  if (!Number.isSafeInteger(maxGroupOverrunSeconds)) throw new Error("REVIEWED_GROUP_POLICY_MISSING");
  const input = { ...diagnostic.settings, parties: diagnostic.parties, starts: diagnostic.starts, existingSchedules: diagnostic.existingSchedules, maxGroupOverrunSeconds };
  const proposed = diagnostic.parties.length ? proposePlan(input) : null;
  const strict = diagnostic.parties.length ? previousPlanner(input) : null;
  const summarize = result => result && ({ conflicts: result.conflicts.map(c => c.code), ...result.groups[0] && {
    ordinaryStop: result.groups[0].effectiveStopAt, arrival: result.groups[0].expectedFinaleArrivalAt,
    completion: result.groups[0].expectedCompletionAt ?? new Date(Date.parse(result.groups[0].expectedFinaleArrivalAt) + input.finaleShowSeconds * 1000).toISOString(), endDeviationMinutes: result.groups[0].endDeviationMinutes,
    routeLostMinutes: result.groups[0].ordinaryRouteLostMinutes,
  } });
  console.log(JSON.stringify({ code: "READ_ONLY_FINALE_PLANNING", readOnly: true, started: diagnostic.started,
    baselineCommit, settings: diagnostic.settings, storedTiming: diagnostic.stored, previousPlanner: summarize(strict), proposedPolicy: summarize(proposed),
    changedRows: 0, messagesSent: 0 }));
} finally { await rm(directory, { recursive: true, force: true }); }
