import { readFile, writeFile } from 'node:fs/promises';
import { backupKey, openBackup, readReleaseState, sealBackup } from './redesign-preflight.mjs';
import { compareFingerprints } from './redesign-backup.mjs';
import { reconcileReleaseMetadata } from './redesign-reconciliation.mjs';
import { reconcileWorldPolicyInitialization } from './world-policy-reconciliation.mjs';
import { reconcileJointRoutePolicyRelease } from './joint-route-policy-reconciliation.mjs';
import { reconcileJointRouteSettingsInitialization } from './joint-route-settings-reconciliation.mjs';
import { reconcileP12RoutePolicy,jointRouteSettingsBeforeP12Policy } from './p12-route-policy-reconciliation.mjs';

try {
  const key=backupKey(process.env.CHILD_CODE_ENCRYPTION_KEY);
  const context=`duindorp-release:${process.env.APP_ENVIRONMENT}:${process.env.GITHUB_SHA}:${process.env.GITHUB_RUN_ID}`;
  if(!process.env.RELEASE_PRIVATE_BASELINE_FILE)throw new Error('PRE_MIGRATION_BASELINE_REQUIRED');
  const before=JSON.parse(openBackup(await readFile(process.env.RELEASE_PRIVATE_BASELINE_FILE),key,context+':migration-baseline').toString());
  const {preservation:response,metadata}=await readReleaseState(before.catalog,before);
  const after={rows:response[0].preservation.rows,...metadata[0].metadata},reconciliation=reconcileReleaseMetadata(before,after,before.expectedMigrationVersions);
  const coverageReconciliation=reconcileWorldPolicyInitialization(before.worldPolicyInitialization,response[0].preservation.worldPolicyInitialization,before.expectedMigrationVersions);
  const jointRoutePolicyReconciliation=reconcileJointRoutePolicyRelease(before.jointRoutePolicyRelease,response[0].preservation.jointRoutePolicyRelease,before.expectedMigrationVersions);
  const p12RoutePolicyReconciliation=reconcileP12RoutePolicy(before.p12RoutePolicy,response[0].preservation.p12RoutePolicy,before.expectedMigrationVersions);
  const settingsBeforeP12Policy=jointRouteSettingsBeforeP12Policy(before.p12RoutePolicy,response[0].preservation.p12RoutePolicy,before.expectedMigrationVersions,response[0].preservation.jointRouteSettingsInitialization);
  const jointRouteSettingsReconciliation=reconcileJointRouteSettingsInitialization(before.jointRouteSettingsInitialization,settingsBeforeP12Policy,before.expectedMigrationVersions);
  const metadataTables=new Set([...coverageReconciliation.reconciledTables,...jointRoutePolicyReconciliation.reconciledTables,...jointRouteSettingsReconciliation.reconciledTables,...p12RoutePolicyReconciliation.reconciledTables,'supabase_migrations.schema_migrations','cron.job_run_details','app_private.email_events']);
  const changed=[...new Set([...compareFingerprints(before.rows,after.rows).filter(table=>!metadataTables.has(table)),...reconciliation.failures,...coverageReconciliation.failures,...jointRoutePolicyReconciliation.failures,...jointRouteSettingsReconciliation.failures,...p12RoutePolicyReconciliation.failures])];
  await writeFile(process.env.RELEASE_PRIVATE_BASELINE_FILE+'.after',sealBackup(Buffer.from(JSON.stringify({after,changed,reconciliation,worldPolicyInitialization:response[0].preservation.worldPolicyInitialization,coverageReconciliation,jointRoutePolicyRelease:response[0].preservation.jointRoutePolicyRelease,jointRoutePolicyReconciliation,jointRouteSettingsInitialization:response[0].preservation.jointRouteSettingsInitialization,jointRouteSettingsReconciliation,p12RoutePolicy:response[0].preservation.p12RoutePolicy,p12RoutePolicyReconciliation})),key,context+':post-migration'),{flag:'wx',mode:0o600});
  if(changed.length)throw new Error('EXISTING_DATA_CHANGED_REQUIRES_RECONCILIATION: '+changed.join(','));
  console.log(JSON.stringify({environment:process.env.APP_ENVIRONMENT,revision:process.env.GITHUB_SHA,existingDataPreserved:true,tablesCompared:before.catalog.length,reconciliation,coverageReconciliation,jointRoutePolicyReconciliation,jointRouteSettingsReconciliation,p12RoutePolicyReconciliation}));
} catch(error) {console.error(error.message);process.exitCode=1;}
