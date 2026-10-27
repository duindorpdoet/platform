import { Webhook } from 'standardwebhooks';
import { randomUUID } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import { activeMailConfig } from './mail-service.mjs';
const config = await activeMailConfig();
if(process.env.GITHUB_ENV)await appendFile(process.env.GITHUB_ENV,`MAIL_ACTIVE_PROVIDER=${config.provider}\n`);
if(config.provider==='sendgrid' && process.env.APP_ENVIRONMENT==='staging') {
  await import('./verify-sendgrid-provider.mjs');
} else {
  for(const name of ['SEND_EMAIL_HOOK_SECRET',...(config.provider==='resend'?['RESEND_API_KEY','RESEND_WEBHOOK_SECRET']:['SENDGRID_API'])])if(!process.env[name])throw new Error(`Missing mail validation variable: ${name}`);
  const recipient=process.env.TEST_EMAIL_1||process.env.ORGANIZATION_SUPPORT_EMAIL;
  if(!recipient)throw new Error('MAIL_VALIDATION_RECIPIENT_MISSING');
  const body=JSON.stringify({kind:'transactional',message:{to:recipient,subject:'Configuratiecontrole zonder verzending',text:'Controle',html:'<p>Controle</p>',providerProbe:true,checkConfigId:config.id}});
  const id=`msg_${randomUUID()}`,date=new Date();
  const signature=new Webhook(process.env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/, '')).sign(id,date,body);
  const response=await fetch(`${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).origin}/functions/v1/send-email-hook`,{method:'POST',headers:{'content-type':'application/json','webhook-id':id,'webhook-timestamp':String(Math.floor(date.getTime()/1000)),'webhook-signature':signature},body,signal:AbortSignal.timeout(5000)});
  if(!response.ok||response.headers.get('x-mail-provider')!==config.provider||response.headers.get('x-mail-status')!=='validated')throw new Error('MAIL_GATEWAY_VALIDATION_FAILED');
  console.log(`Signed ${config.provider} gateway configuration validated without sending. Provider acceptance/delivery and real Auth mailbox receipt remain separate release gates.`);
}
