// Bounded read-only diagnostic for the existing release environment. No Auth
// impersonation, coordinates, addresses, account data or credentials in output.
import { writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const startLocationInventoryQuery = `select jsonb_build_object(
  'eventId',e.id,'eventSlug',e.slug,
  'latestMigration',(select max(version) from supabase_migrations.schema_migrations),
  'walkingNodeCount',(select count(*) from app_private.walking_nodes where event_id=e.id),
  'approvedEdgeCount',(select count(*) from app_private.walking_edges where event_id=e.id and approved_at is not null and closed_at is null),
  'unassignedGroups',(select count(*) from app_private.walking_groups where event_id=e.id and current_schedule_revision_id is null),
  'startPoints',coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'name',p.name,'publicLabel',p.public_label,'linkedPortalId',p.linked_portal_id,
    'version',p.version,'active',p.active,'countsAsFirstPortalVisit',p.counts_as_first_portal_visit,
    'storedSource',p.location_source,'hasManualPair',p.marker_latitude is not null and p.marker_longitude is not null,
    'hasAddressPair',p.geocoded_latitude is not null and p.geocoded_longitude is not null,
    'hasLegacyPair',p.latitude is not null and p.longitude is not null,
    'effectivePositionHash',encode(sha256(convert_to(jsonb_build_array(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude))::text,'UTF8')),'hex'),
    'walkingNodeId',p.walking_node_id,'verifiedAt',p.verified_at,'markerUpdatedAt',p.marker_updated_at,
    'routeReady',app_private.start_point_safe_connection(p.id),
    'readiness',app_private.start_point_readiness(p.id)-'location',
    'confirmationAudit',(select jsonb_build_object('createdAt',a.created_at,'version',a.minimal_change->'version','hasLocationHash',a.minimal_change ? 'locationHash')
      from app_private.audit_events a where a.event_id=e.id and a.resource_type='start_point' and a.resource_id=p.id and a.action='start_point.confirmed' order by a.created_at desc,a.id desc limit 1),
    'groupLinks',(select count(*) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id join app_private.start_slots slot on slot.id=s.start_slot_id where g.event_id=e.id and slot.start_point_id=p.id)) order by p.id)
    from app_private.start_points p where p.event_id=e.id),'[]'::jsonb),
  'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'systemCode',p.system_code,'version',p.version,
    'lifecycleStatus',p.lifecycle_status,'storedSource',l.location_source,
    'hasPosition',coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude) is not null and coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude) is not null,
    'effectivePositionHash',encode(sha256(convert_to(jsonb_build_array(coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude),coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude))::text,'UTF8')),'hex')) order by p.id)
    from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id where p.event_id=e.id),'[]'::jsonb)) inventory
  from app_private.events e where e.slug='duindorp-halloween-2026'`;

async function run() {
  const project = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!project || !token) throw new Error("EXISTING_AUTHORIZED_DATABASE_ACCESS_REQUIRED");
  const response = await fetch(`https://api.supabase.com/v1/projects/${encodeURIComponent(project)}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: startLocationInventoryQuery, read_only: true }), signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) throw new Error(`READ_ONLY_INVENTORY_${response.status}`);
  const data = await response.json();
  if (data.length !== 1 || !data[0].inventory?.eventId) throw new Error("EVENT_NOT_FOUND");
  const output = resolve(process.argv[2] ?? "private-exports/start-location-inventory.json");
  await mkdir(dirname(output), { recursive: true, mode: 0o700 });
  await writeFile(output, JSON.stringify({ capturedAt: new Date().toISOString(), ...data[0].inventory }, null, 2), { mode: 0o600 });
  console.log(JSON.stringify({ readOnly: true, startPoints: data[0].inventory.startPoints.length, reportWritten: true }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await run();
