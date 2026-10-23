import { readFile, writeFile } from 'node:fs/promises';
import { backupKey, management, openBackup, sealBackup } from './redesign-preflight.mjs';
import { compareFingerprints, fingerprintQuery } from './redesign-backup.mjs';

try {
  const key=backupKey(process.env.CHILD_CODE_ENCRYPTION_KEY);
  const context=`duindorp-release:${process.env.APP_ENVIRONMENT}:${process.env.GITHUB_SHA}:${process.env.GITHUB_RUN_ID}`;
  if(!process.env.RELEASE_PRIVATE_BASELINE_FILE)throw new Error('PRE_MIGRATION_BASELINE_REQUIRED');
  const before=JSON.parse(openBackup(await readFile(process.env.RELEASE_PRIVATE_BASELINE_FILE),key,context+':migration-baseline').toString());
  const response=await management('/database/query',{read_only:true,query:fingerprintQuery(before.catalog)});
  const after=response.map(row=>row.fingerprint),changed=compareFingerprints(before.rows,after);
  await writeFile(process.env.RELEASE_PRIVATE_BASELINE_FILE+'.after',sealBackup(Buffer.from(JSON.stringify({after,changed})),key,context+':post-migration'),{flag:'wx',mode:0o600});
  if(changed.length)throw new Error('EXISTING_DATA_CHANGED_REQUIRES_RECONCILIATION: '+changed.join(','));
  console.log(JSON.stringify({environment:process.env.APP_ENVIRONMENT,revision:process.env.GITHUB_SHA,existingDataPreserved:true,tablesCompared:before.catalog.length}));
} catch(error) {console.error(error.message);process.exitCode=1;}
