// Guarded local proof against the real official postgres-meta HTTP service.
// It exercises multi-statement response handling, not a hand-written PG mock.
import assert from 'node:assert/strict';
import { requireLocalTogetherDatabase, sql } from './together-fixtures.mjs';
import { fingerprintManagementRequest, preservationManagementRequest, preservationQuery } from '../deploy/redesign-backup.mjs';

requireLocalTogetherDatabase();
const base=new URL(process.env.PRESERVATION_META_URL??'http://127.0.0.1:65428');
assert.ok(['127.0.0.1','localhost','[::1]'].includes(base.hostname)&&base.protocol==='http:','Official meta HTTP proof only permits a local endpoint');
const catalog=JSON.parse(sql(`select jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,
 'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)) order by c.relname)
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in('app_private','auth','storage','supabase_migrations','vault','cron','supabase_functions','public') and c.relkind in('r','p')`));
async function request(body) {
 const response=await fetch(new URL('/query',base),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30_000)});
 const data=await response.json();
 return {status:response.status,data};
}
const baseline=JSON.parse(sql('begin read only;'+preservationQuery(catalog)+';commit;'));
const body=preservationManagementRequest(catalog);
assert.equal(body.read_only,false,'management owner selection must match the fixed read-only transaction');
const result=await request(body);
assert.equal(result.status,200,`Whole preservation request returned HTTP ${result.status}`);
assert.ok(Array.isArray(result.data)&&result.data.length===1&&result.data[0].preservation,'last SELECT rows must survive trailing COMMIT');
const preserved=result.data[0].preservation;
assert.deepEqual(preserved.rows,baseline.rows,'all existing row fingerprints survive the actual HTTP path');
for(const field of ['policyRows','expected','auditBoundary','auditOriginal','addedAuditRows'])assert.deepEqual(preserved.worldPolicyInitialization[field],baseline.worldPolicyInitialization[field],`private policy derivation field ${field} remains exact`);
const fingerprints=await request(fingerprintManagementRequest(catalog));
assert.equal(fingerprints.status,200);
const ordered=rows=>[...rows].sort((a,b)=>a.table.localeCompare(b.table));
assert.deepEqual(ordered(fingerprints.data.map(row=>row.fingerprint)),ordered(preserved.rows),'fingerprint-only endpoint returns every original SELECT row after COMMIT');

const write=await request({read_only:false,query:"begin read only;update app_private.events set settings=settings where false;commit;"});
assert.equal(write.status,400,'the database must reject a write even though management selects its owner connection');
assert.equal(write.data.code,'25006','PostgreSQL READ ONLY is enforced independently of the management flag');
const denied=await request({read_only:false,query:"begin read only;set local role authenticated;select app_private.portal_location_ready('12000000-0000-0000-0000-000000000001');commit;"});
assert.equal(denied.status,400);
assert.equal(denied.data.code,'42501','private helper execution is not opened to clients');
const scope=await request({read_only:false,query:"select current_setting('transaction_read_only') read_only,current_user role"});
assert.equal(scope.status,200);
assert.deepEqual(scope.data,[{read_only:'off',role:'postgres'}],'transaction settings and client role changes do not leak into another HTTP request');
const after=JSON.parse(sql('begin read only;'+preservationQuery(catalog)+';commit;'));
assert.deepEqual(after.rows,baseline.rows,'successful and rejected HTTP requests leave every existing table unchanged');
console.log(JSON.stringify({code:'PRESERVATION_POSTGRES_META_HTTP_VERIFIED',officialService:true,catalogTables:catalog.length,
 lastSelectSurvivesCommit:true,allFingerprintsMatch:true,wholePrivatePolicyDerivation:true,fingerprintOnlyRowsMatch:true,
 databaseReadOnlyRejectsWrite:'25006',privateClientDenied:'42501',transactionScopeRestored:true,changedRows:0}));
