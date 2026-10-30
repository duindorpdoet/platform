import { isDeepStrictEqual } from 'node:util';

export const JOINT_ROUTE_POLICY_MIGRATION='20261030065514';
export const JOINT_ROUTE_POLICY_V3_MIGRATION='20261030131348';
const table='app_private.joint_route_policy_releases';
const reviewedPolicies=new Map([[JOINT_ROUTE_POLICY_MIGRATION,'joint-reception-v2'],[JOINT_ROUTE_POLICY_V3_MIGRATION,'joint-reception-v3']]);

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
    'appliedMigrations',coalesce((select jsonb_agg(version::text order by version) from supabase_migrations.schema_migrations),'[]'::jsonb),
    'tableExists',to_regclass('${table}') is not null,
    'rows',${exists?`coalesce((select jsonb_agg(to_jsonb(p) order by p.policy_version) from ${table} p),'[]'::jsonb)`:`'[]'::jsonb`}) as joint_route_policy_release`;
}

/** Allow only pending reviewed metadata appends, retaining every complete old row. */
export function reconcileJointRoutePolicyRelease(before,after,expectedVersions) {
  const failure=()=>({failures:[table],reconciledTables:[],addedPolicyReleases:0});
  if(!before||!after||before.tableExists!==true||after.tableExists!==true
    ||typeof before.migrationApplied!=='boolean'||!Array.isArray(before.rows)||!Array.isArray(after.rows)
    ||!Array.isArray(expectedVersions))return failure();
  const applied=before.appliedMigrations;
  if(applied!==undefined&&(!Array.isArray(applied)||applied.some(version=>typeof version!=='string')
    ||new Set(applied).size!==applied.length||before.migrationApplied!==applied.includes(JOINT_ROUTE_POLICY_MIGRATION)))return failure();
  // Legacy v2 proofs did not capture the complete history. They may retain
  // their original v2 behavior, but cannot authorize the newly reviewed v3.
  if(applied===undefined&&expectedVersions.includes(JOINT_ROUTE_POLICY_V3_MIGRATION))return failure();
  const installed=applied??(before.migrationApplied?[JOINT_ROUTE_POLICY_MIGRATION]:[]);
  const wanted=[...reviewedPolicies].filter(([version])=>expectedVersions.includes(version)&&!installed.includes(version)).map(([,policy])=>policy);
  const old=new Map(before.rows.map(row=>[row.policy_version,row]));
  const current=new Map(after.rows.map(row=>[row.policy_version,row]));
  if(old.size!==before.rows.length||current.size!==after.rows.length)return failure();
  for(const [version,row] of old)if(!isDeepStrictEqual(row,current.get(version)))return failure();
  const added=after.rows.filter(row=>!old.has(row.policy_version));
  if(!wanted.length)return added.length?failure():{failures:[],reconciledTables:[],addedPolicyReleases:0};
  if(wanted.some(policy=>old.has(policy))||added.length!==wanted.length)return failure();
  const earliest=timestampMicros(before.capturedAt),latest=timestampMicros(after.capturedAt);
  if(earliest===null||latest===null||latest<earliest)return failure();
  for(const row of added) {
    const at=timestampMicros(row.activated_at);
    if(Object.keys(row).length!==2||!wanted.includes(row.policy_version)||at===null||at<earliest||at>latest)return failure();
  }
  return {failures:[],reconciledTables:[table],addedPolicyReleases:added.length};
}
