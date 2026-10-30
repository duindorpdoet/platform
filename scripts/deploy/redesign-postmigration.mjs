import { readFile, writeFile } from 'node:fs/promises';
import { backupKey, management, openBackup, sealBackup } from './redesign-preflight.mjs';
import { compareFingerprints, preservationManagementRequest } from './redesign-backup.mjs';
import { reconcileReleaseMetadata, releaseMetadataQuery } from './redesign-reconciliation.mjs';
import { reconcileWorldPolicyInitialization } from './world-policy-reconciliation.mjs';
import { reconcileJointRoutePolicyRelease } from './joint-route-policy-reconciliation.mjs';

try {
  const key=backupKey(process.env.CHILD_CODE_ENCRYPTION_KEY);
  const context=`duindorp-release:${process.env.APP_ENVIRONMENT}:${process.env.GITHUB_SHA}:${process.env.GITHUB_RUN_ID}`;
  if(!process.env.RELEASE_PRIVATE_BASELINE_FILE)throw new Error('PRE_MIGRATION_BASELINE_REQUIRED');
  const before=JSON.parse(openBackup(await readFile(process.env.RELEASE_PRIVATE_BASELINE_FILE),key,context+':migration-baseline').toString());
  const [response,metadata]=await Promise.all([
    management('/database/query',preservationManagementRequest(before.catalog,before.worldPolicyInitialization)),
    management('/database/query',{read_only:true,query:releaseMetadataQuery(before)}),
  ]);
  const after={rows:response[0].preservation.rows,...metadata[0].metadata},reconciliation=reconcileReleaseMetadata(before,after,before.expectedMigrationVersions);
  const coverageReconciliation=reconcileWorldPolicyInitialization(before.worldPolicyInitialization,response[0].preservation.worldPolicyInitialization,before.expectedMigrationVersions);
  const jointRoutePolicyReconciliation=reconcileJointRoutePolicyRelease(before.jointRoutePolicyRelease,response[0].preservation.jointRoutePolicyRelease,before.expectedMigrationVersions);
  const metadataTables=new Set([...coverageReconciliation.reconciledTables,...jointRoutePolicyReconciliation.reconciledTables,'supabase_migrations.schema_migrations','cron.job_run_details','app_private.email_events']);
  const changed=[...new Set([...compareFingerprints(before.rows,after.rows).filter(table=>!metadataTables.has(table)),...reconciliation.failures,...coverageReconciliation.failures,...jointRoutePolicyReconciliation.failures])];
  await writeFile(process.env.RELEASE_PRIVATE_BASELINE_FILE+'.after',sealBackup(Buffer.from(JSON.stringify({after,changed,reconciliation,worldPolicyInitialization:response[0].preservation.worldPolicyInitialization,coverageReconciliation,jointRoutePolicyRelease:response[0].preservation.jointRoutePolicyRelease,jointRoutePolicyReconciliation})),key,context+':post-migration'),{flag:'wx',mode:0o600});
  if(changed.length)throw new Error('EXISTING_DATA_CHANGED_REQUIRES_RECONCILIATION: '+changed.join(','));
  console.log(JSON.stringify({environment:process.env.APP_ENVIRONMENT,revision:process.env.GITHUB_SHA,existingDataPreserved:true,tablesCompared:before.catalog.length,reconciliation,coverageReconciliation,jointRoutePolicyReconciliation}));
} catch(error) {console.error(error.message);process.exitCode=1;}
