import { appendFile } from 'node:fs/promises';
import { activeMailConfig } from './mail-service.mjs';
const config=await activeMailConfig();
const target=process.env.APP_ENVIRONMENT;
if(!['staging','production'].includes(target))throw new Error('Webhook provisioning is release-only');
const origins={staging:'https://staging-halloween.duindorpdoet.nl',production:'https://halloween.duindorpdoet.nl'};
if(new URL(process.env.APP_URL).origin!==origins[target])throw new Error('RESEND_ENDPOINT_ENVIRONMENT_MISMATCH');
if(!process.env.RESEND_ADMIN_API_KEY) {
 if(config.provider==='resend')throw new Error('RESEND_ADMIN_API_KEY_MISSING');
 console.log('Resend webhook setup pending: configure separate management credentials before activation.');
} else {
 const events=['email.sent','email.delivered','email.delivery_delayed','email.bounced','email.complained','email.failed','email.suppressed'];
 const endpoint=`${origins[target]}/api/webhooks/resend`;
 async function api(path,method='GET',body) {
  const response=await fetch(`https://api.resend.com${path}`,{method,headers:{Authorization:`Bearer ${process.env.RESEND_ADMIN_API_KEY}`,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(10000)});
  if(!response.ok)throw new Error(`RESEND_WEBHOOK_SETUP_HTTP_${response.status}`);
  return response.json();
 }
 let own,after='';
 const matches=[];
 for(let page=0;page<10;page++) {
  const list=await api(`/webhooks?limit=100${after?`&after=${encodeURIComponent(after)}`:''}`);
  matches.push(...(list.data??[]).filter(h=>h.endpoint===endpoint));
  if(matches.length>1)throw new Error('DUPLICATE_OWN_RESEND_ENDPOINTS');
  if(!list.has_more||!list.data?.length)break;
  after=list.data.at(-1).id;
  if(page===9)throw new Error('RESEND_WEBHOOK_PAGINATION_LIMIT');
 }
 own=matches[0];
 if(own) {
  // Only this application's exact environment endpoint may be changed.
  if(own.status!=='enabled'||JSON.stringify([...own.events].sort())!==JSON.stringify([...events].sort()))await api(`/webhooks/${own.id}`,'PATCH',{endpoint,events,status:'enabled'});
  own=await api(`/webhooks/${own.id}`);
 } else own=await api('/webhooks','POST',{endpoint,events});
 const secret=own.signing_secret;
 if(typeof secret!=='string'||!/^whsec_[A-Za-z0-9+/=]+$/.test(secret))throw new Error('RESEND_SIGNING_SECRET_MISSING');
 if(!process.env.GITHUB_ENV)throw new Error('GITHUB_ENV_REQUIRED_FOR_SECURE_PROVISIONING');
 // Write only to the protected environment handoff. Never print the value.
 await appendFile(process.env.GITHUB_ENV,`RESEND_WEBHOOK_SECRET=${secret}\nRESEND_WEBHOOK_ID=${own.id}\n`);
 console.log('Own Resend webhook configured; signing secret provisioned through deployment runtime.');
}
