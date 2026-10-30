import { isDeepStrictEqual } from 'node:util';

export const JOINT_ROUTE_POLICY_MIGRATION='20261030065514';
const table='app_private.joint_route_policy_releases';
const policy='joint-reception-v2';

// PostgreSQL timestamps retain six fractional digits. Date.parse alone rounds
// them to milliseconds and would admit an append outside a one-microsecond edge.
function timestampMicros(value) {
  if(typeof value!=='string')return null;
  const match=value.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/);
  if(!match)return null;
  const whole=Date.parse(match[1]+match[3]);
  return Number.isFinite(whole)?BigInt(whole)*1000n+BigInt((match[2]??'').padEnd(6,'0')):null;
}

// This fixed, read-only projection shares the physical-row fingerprint's SQL
// snapshot. A missing prerequisite remains explicit and fails reconciliation.
export function jointRoutePolicyReleaseQuery(catalog) {
  const exists=catalog.some(entry=>entry.schema==='app_private'&&entry.name==='joint_route_policy_releases');
  return `select jsonb_build_object('capturedAt',statement_timestamp(),
    'migrationApplied',exists(select 1 from supabase_migrations.schema_migrations where version='${JOINT_ROUTE_POLICY_MIGRATION}'),
    'tableExists',to_regclass('${table}') is not null,
    'rows',${exists?`coalesce((select jsonb_agg(to_jsonb(p) order by p.policy_version) from ${table} p),'[]'::jsonb)`:`'[]'::jsonb`}) as joint_route_policy_release`;
}

/** Allow exactly one reviewed metadata append, while retaining every old row. */
export function reconcileJointRoutePolicyRelease(before,after,expectedVersions) {
  const failure=()=>({failures:[table],reconciledTables:[],addedPolicyReleases:0});
  if(!before||!after||before.tableExists!==true||after.tableExists!==true
    ||typeof before.migrationApplied!=='boolean'||!Array.isArray(before.rows)||!Array.isArray(after.rows)
    ||!Array.isArray(expectedVersions))return failure();
  const initializing=!before.migrationApplied&&expectedVersions.includes(JOINT_ROUTE_POLICY_MIGRATION);
  const old=new Map(before.rows.map(row=>[row.policy_version,row]));
  const current=new Map(after.rows.map(row=>[row.policy_version,row]));
  if(old.size!==before.rows.length||current.size!==after.rows.length)return failure();
  for(const [version,row] of old)if(!isDeepStrictEqual(row,current.get(version)))return failure();
  const added=after.rows.filter(row=>!old.has(row.policy_version));
  if(!initializing)return added.length?failure():{failures:[],reconciledTables:[],addedPolicyReleases:0};
  if(old.has(policy)||added.length!==1)return failure();
  const row=added[0],earliest=timestampMicros(before.capturedAt),latest=timestampMicros(after.capturedAt),at=timestampMicros(row.activated_at);
  if(Object.keys(row).length!==2||row.policy_version!==policy||typeof row.activated_at!=='string'
    ||earliest===null||latest===null||at===null||latest<earliest||at<earliest||at>latest)return failure();
  return {failures:[],reconciledTables:[table],addedPolicyReleases:1};
}
