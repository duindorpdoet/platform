import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { requireLocalTogetherDatabase, sql } from './together-fixtures.mjs';
import { compareFingerprints, preservationQuery } from '../deploy/redesign-backup.mjs';
import { reconcileWorldPolicyInitialization, WORLD_POLICY_MIGRATION } from '../deploy/world-policy-reconciliation.mjs';

const container=requireLocalTogetherDatabase();
const catalog=JSON.parse(sql(`select jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,
 'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)) order by c.relname)
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private' and c.relkind in('r','p')`));
// Compare the original pre-expand policy columns. New lifecycle metadata is
// checked explicitly by the reconciler, rather than hidden in a table exception.
catalog.find(table=>table.name==='world_coverage_policies').columns=['event_id','version','missing_worlds','fingerprint','created_at'];
const oldColumns=['event_id','version','missing_worlds','fingerprint','created_at'];

function session() {
  const child=spawn('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']);
  let buffer='',waiting,serial=0,error='';
  child.stdout.on('data',chunk=>{buffer+=chunk;flush();});
  child.stderr.on('data',chunk=>{error+=chunk;});
  const done=new Promise((resolve,reject)=>{
    child.on('error',reject);
    child.on('exit',code=>{if(code===0)resolve();else { const failure=new Error('POLICY_PRESERVATION_SQL_FAILED: '+error.slice(0,300));waiting?.reject(failure);reject(failure); }});
  });
  function flush() {
    if(!waiting)return;
    const marker=waiting.marker+'\n',index=buffer.indexOf(marker);
    if(index<0)return;
    const result=buffer.slice(0,index).trim();buffer=buffer.slice(index+marker.length);
    const pending=waiting;waiting=null;pending.resolve(result);
  }
  return {
    async query(statement) {
      const marker='POLICY_PRESERVATION_BOUNDARY_'+(++serial);
      return new Promise((resolve,reject)=>{waiting={marker,resolve,reject};child.stdin.write(statement+`;select '${marker}';\n`);flush();});
    },
    async close() {child.stdin.end();await done;},
  };
}

let checked=0;
for(const housesOpen of [true,false]) {
  const connection=session();
  try {
    const baseline=JSON.parse(await connection.query(`begin;
      alter table app_private.events disable trigger world_coverage_registration_changed;
      update app_private.events set settings=jsonb_set(settings,'{portalRegistrationOpen}','${housesOpen}'::jsonb,true);
      alter table app_private.events enable trigger world_coverage_registration_changed;
      update app_private.world_coverage_policies set policy_status='retired',source_fingerprint=null,activated_at=null,activated_by=null,activation_reason=null;
      ${preservationQuery(catalog).replace("\'capturedAt\',statement_timestamp()", "\'capturedAt\',transaction_timestamp()")}`));
    const before=baseline.worldPolicyInitialization;
    // The installed local schema includes the additive columns. Model exactly
    // the pre-expand baseline while executing the real migration initializer.
    before.migrationApplied=false;
    before.policyRows=before.policyRows.map(row=>Object.fromEntries(oldColumns.map(column=>[column,row[column]])));
    const currentQuery=preservationQuery(catalog,before);
    const after=JSON.parse(await connection.query(`do $$declare eid uuid;begin for eid in select id from app_private.events order by id loop perform app_private.refresh_world_coverage(eid);end loop;end $$;${currentQuery}`));
    const result=reconcileWorldPolicyInitialization(before,after.worldPolicyInitialization,[WORLD_POLICY_MIGRATION]);
    assert.deepEqual(result.failures,[],'real initializer must match the exact derived append contract');
    assert.equal(result.addedPolicies,before.expected.length);
    assert.equal(result.addedCoverageAuditEvents,housesOpen?0:before.expected.length);
    assert.deepEqual(compareFingerprints(baseline.rows,after.rows).filter(table=>!result.reconciledTables.includes(table)),[],'all other existing tables remain exact');

    const negative=async(change,expectedTable)=>{
      const changed=JSON.parse(await connection.query('savepoint tamper;'+change+';'+currentQuery));
      const reconciliation=reconcileWorldPolicyInitialization(before,changed.worldPolicyInitialization,[WORLD_POLICY_MIGRATION]);
      const failures=[...compareFingerprints(baseline.rows,changed.rows).filter(table=>!reconciliation.reconciledTables.includes(table)),...reconciliation.failures];
      assert.ok(failures.includes(expectedTable),`must reject ${expectedTable} tampering`);
      await connection.query('rollback to savepoint tamper;release savepoint tamper');
    };
    await negative("update app_private.world_coverage_policies set fingerprint='tampered-old-policy' where (event_id,version)=(select event_id,min(version) from app_private.world_coverage_policies group by event_id order by event_id limit 1)",'app_private.world_coverage_policies');
    await negative("insert into app_private.audit_events(action,resource_type,minimal_change) values('unrelated.release.change','fixture','{}')",'app_private.audit_events');
    if(before.auditOriginal.rows>0)await negative("update app_private.audit_events set minimal_change=minimal_change||'{\"tampered\":true}'::jsonb where id=(select min(id) from app_private.audit_events)",'app_private.audit_events');
    await negative("update app_private.walking_groups set version=version+1 where id=(select id from app_private.walking_groups order by id limit 1)",'app_private.walking_groups');
    checked++;
    await connection.query('rollback');
  } finally {await connection.close();}
}
console.log(JSON.stringify({code:'WORLD_POLICY_PRESERVATION_VERIFIED',houseChannelCases:checked,actualInitializer:true,allOriginalPolicyFieldsPreserved:true,oldAuditMutationBlocked:true,unrelatedAppendBlocked:true,groupMutationBlocked:true,rolledBack:true}));
