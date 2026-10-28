import { execFileSync } from 'node:child_process';
import { releaseMetadataQuery, reconcileReleaseMetadata } from '../deploy/redesign-reconciliation.mjs';

const container=process.env.BACKUP_FINGERPRINT_DB_CONTAINER;
if(!/^supabase_db_duindorp[a-zA-Z0-9_-]*$/.test(container??''))throw new Error('ISOLATED_MAIL_PRESERVATION_DATABASE_REQUIRED');
function query(sql) {
  try {
    return JSON.parse(execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],{input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim());
  } catch { throw new Error('MAIL_EVENT_PRESERVATION_SQL_FAILED'); }
}
// Recreate the identical fixture in rollback transactions. Fixed timestamps
// ensure the original record has exactly the same full-row hash each time.
const fixture=`insert into app_private.email_events(id,provider,provider_event_id,provider_message_id,kind,occurred_at,received_at,verification_key_hash)
values('94000000-0000-0000-0000-000000000001','resend','preservation-original','local-original','email.sent','2026-10-28T00:00:00Z','2026-10-28T00:00:00Z',repeat('a',64));`;
const before=query('begin;'+fixture+releaseMetadataQuery()+';rollback;');
const afterQuery=releaseMetadataQuery(before),versions=before.migrationHistory.map(row=>row.version);
const append="insert into app_private.email_events(provider,provider_event_id,kind,occurred_at,verification_key_hash) values('resend','preservation-added','email.delivered',now(),repeat('b',64));";
const positive=query('begin;'+fixture+append+afterQuery+';rollback;');
const passed=reconcileReleaseMetadata(before,positive,versions);
if(passed.failures.length||passed.addedMailEvents!==1)throw new Error('VERIFIED_MAIL_APPEND_NOT_PRESERVED');
for(const change of [
  "delete from app_private.email_events where id='94000000-0000-0000-0000-000000000001';",
  "update app_private.email_events set safe_code='CHANGED' where id='94000000-0000-0000-0000-000000000001';",
  "insert into app_private.email_events(provider,provider_event_id,kind,occurred_at) values('resend','unverified','email.sent',now());",
  "insert into app_private.email_events(provider,provider_event_id,kind,occurred_at,verification_key_hash) values('resend','invalid-hash','email.sent',now(),'invalid');",
  "insert into app_private.email_events(provider,provider_event_id,kind,occurred_at,verification_key_hash) values('sendgrid','wrong-provider','delivered',now(),repeat('b',64));",
]) {
  const after=query('begin;'+fixture+change+afterQuery+';rollback;');
  if(!reconcileReleaseMetadata(before,after,versions).failures.includes('app_private.email_events'))throw new Error('MAIL_EVENT_CHANGE_NOT_BLOCKED');
}
console.log(JSON.stringify({code:'MAIL_EVENT_PRESERVATION_VERIFIED',verifiedAppendAccepted:true,originalDeletionBlocked:true,originalMutationBlocked:true,unverifiedAdditionBlocked:true,invalidHashBlocked:true,otherProviderBlocked:true,rolledBack:true}));
