import {pathToFileURL} from 'node:url';
import {mailRpc,activeMailConfig} from './mail-service.mjs';
import {SuppressionSyncError,syncSendGridSuppressions} from './sendgrid-suppressions.mjs';

export function canRetainLegacyProvider(error,provider) {
 return provider==='sendgrid' && error instanceof SuppressionSyncError && ['SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED','SENDGRID_SUPPRESSIONS_CREDENTIAL_MISSING'].includes(error.message);
}
export async function importMailSuppressions(){
 try {
  const counts=await syncSendGridSuppressions({environment:process.env.APP_ENVIRONMENT,apiKey:process.env.SENDGRID_SUPPRESSIONS_API_KEY||process.env.SENDGRID_API,apiBaseUrl:process.env.SENDGRID_API_BASE_URL,rpc:mailRpc});
  console.log(`SendGrid suppressions automatically imported: ${JSON.stringify(counts)}. No consent was restored.`);
 }catch(error){
  const code=error instanceof SuppressionSyncError?error.message:'SUPPRESSION_IMPORT_STORAGE_FAILED';
  const config=await activeMailConfig();
  if(canRetainLegacyProvider(error,config.provider)){
   // The approved gateway is shipped while the effective SendGrid provider stays
   // active. Never certify a missing import as complete or activate Resend here.
   console.log(`${code}: existing SendGrid delivery is retained. Resend activation still requires the complete automatic import; no empty list was certified. Configure a same-account read-only SENDGRID_SUPPRESSIONS_API_KEY if the existing key cannot read suppressions. No export file is needed.`);
   return;
  }
  console.error(`${code}: automatic suppression import could not be confirmed; activation requires a confirmed complete import.`);
  process.exitCode=1;
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await importMailSuppressions();
