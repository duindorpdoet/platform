import {appendFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {mailTestPolicy} from './mail-test-policy.mjs';

const targets={staging:{ref:'nocteiuvohesvqbowchw',origin:'https://staging-halloween.duindorpdoet.nl'},production:{ref:'dtubngvxfbupgvgfrjko',origin:'https://halloween.duindorpdoet.nl'}};
const events=['email.sent','email.delivered','email.delivery_delayed','email.bounced','email.complained','email.failed','email.suppressed'];
const literal=value=>`'${String(value).replaceAll("'","''")}'`;
export function activationPolicy(env,now=Date.now()){
 if(!env.RESEND_DEFAULT_RELEASE_SHA||env.RESEND_DEFAULT_RELEASE_SHA!==env.GITHUB_SHA)return false;
 const target=targets[env.APP_ENVIRONMENT];
 if(!target||env.SUPABASE_PROJECT_REF!==target.ref||env.GITHUB_REF!==`refs/heads/${env.APP_ENVIRONMENT}`||env.APP_URL!==target.origin||env.GITHUB_REPOSITORY!=='duindorpdoet/platform')throw new Error('RESEND_RELEASE_BOUNDARY');
 if(env.MAIL_TEST_WAIVER_SHA!==env.GITHUB_SHA||env.SKIP_MAIL_TESTS!=='true'||!mailTestPolicy({...env,GITHUB_EVENT_NAME:'push'},now).skip)throw new Error('RESEND_RELEASE_WAIVER_REQUIRED');
 for(const name of ['SUPABASE_ACCESS_TOKEN','RESEND_API_KEY','RESEND_ADMIN_API_KEY','RESEND_WEBHOOK_SECRET','RESEND_WEBHOOK_ID'])if(!env[name])throw new Error(`RESEND_RELEASE_MISSING_${name}`);
 return true;
}
export function adminIds(value){
 const ids=[...new Set((value??'').split(',').map(v=>v.trim()).filter(Boolean))];
 if(!ids.length||ids.some(v=>!(/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(v))))throw new Error('MAIL_ADMIN_ALLOWLIST_REQUIRED');
 return ids;
}
export function inspectionQuery(env){
 const ids=adminIds(env.MAIL_ADMIN_USER_IDS).map(literal).join(',');
 return `select h.revision,h.active_id,c.provider,c.from_email,
 h.suppressions_imported_at is not null and h.suppression_import_hash ~ '^[a-f0-9]{64}$' as imported,
 (select count(*)::integer from auth.users u join app_private.events e on e.slug='duindorp-halloween-2026' where u.id in (${ids}) and u.email_confirmed_at is not null and app_private.has_capability(e.id,'event_admin',u.id)) as authorized_admins
 from app_private.mail_config_heads h join app_private.mail_config_versions c on c.id=h.active_id where h.environment=${literal(env.APP_ENVIRONMENT)}`;
}
export function activationQuery(env,before){
 if(!Number.isInteger(before.revision)||!(/^[a-f0-9-]{36}$/.test(before.active_id)))throw new Error('RESEND_RELEASE_INVALID_SNAPSHOT');
 const audit=JSON.stringify({environment:env.APP_ENVIRONMENT,release:env.GITHUB_SHA,reason:env.MAIL_TEST_WAIVER_REASON,expiresAt:env.MAIL_TEST_WAIVER_EXPIRES_AT,mailTestsSkipped:true,deliveryValidated:false});
 return `do $release$
 declare h app_private.mail_config_heads; old app_private.mail_config_versions; fresh uuid; next_version integer;
 begin
 select * into h from app_private.mail_config_heads where environment=${literal(env.APP_ENVIRONMENT)} for update;
 if h.active_id is distinct from ${literal(before.active_id)}::uuid or h.revision<>${before.revision} then raise exception 'CONFIG_VERSION_CONFLICT' using errcode='P0001';end if;
 if h.suppressions_imported_at is null or h.suppression_import_hash is null or h.suppression_import_hash !~ '^[a-f0-9]{64}$' or h.suppressions_imported_at<clock_timestamp()-interval '2 hours' then raise exception 'COMPLETE_RECENT_SUPPRESSION_IMPORT_REQUIRED';end if;
 select * into strict old from app_private.mail_config_versions where id=h.active_id and environment=h.environment;
 if old.provider='resend' then return;end if;
 if old.provider<>'sendgrid' then raise exception 'UNEXPECTED_ACTIVE_PROVIDER';end if;
 select coalesce(max(version),0)+1 into next_version from app_private.mail_config_versions where environment=h.environment;
 insert into app_private.mail_config_versions(environment,version,provider,from_email,from_name,reply_to,config_hash)
 values(h.environment,next_version,'resend',old.from_email,old.from_name,old.reply_to,encode(extensions.digest(jsonb_build_object('provider','resend','fromEmail',old.from_email,'fromName',old.from_name,'replyTo',old.reply_to)::text,'sha256'),'hex')) returning id into fresh;
 -- Preserve drafts, suppressions, consent and every old envelope/attempt. No fabricated check or delivery record.
 update app_private.mail_config_heads set active_id=fresh,revision=revision+1 where environment=h.environment;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
 select id,null,'mail.config.release_activate','mail_config',${literal(audit)}::jsonb||jsonb_build_object('previousConfigId',old.id,'configId',fresh,'version',next_version) from app_private.events where slug='duindorp-halloween-2026';
 end $release$;
 select c.provider,c.from_email,c.from_name,c.reply_to,h.revision from app_private.mail_config_heads h join app_private.mail_config_versions c on c.id=h.active_id where h.environment=${literal(env.APP_ENVIRONMENT)};`;
}
export async function verifyResendConfiguration(env,fromEmail,request=fetch){
 async function get(path){
  // Configuration GETs only: no sending, gateway/hook probes or event replay.
  for(let attempt=0;attempt<4;attempt++){
   const r=await request(`https://api.resend.com${path}`,{headers:{Authorization:`Bearer ${env.RESEND_ADMIN_API_KEY}`},signal:AbortSignal.timeout(10000)});
   if(r.status===429&&attempt<3){await new Promise(resolve=>setTimeout(resolve,1250*(attempt+1)));continue;}
   if(!r.ok)throw new Error(`RESEND_CONFIGURATION_HTTP_${r.status}`);return r.json();
  }
 }
 const name=fromEmail.split('@')[1].toLowerCase();let domain,after='';
 for(let page=0;page<10;page++){
  const list=await get(`/domains?limit=100${after?`&after=${encodeURIComponent(after)}`:''}`);domain=list.data?.find(v=>v.name.toLowerCase()===name);
  if(domain||!list.has_more)break;if(!list.data?.length)throw new Error('RESEND_DOMAIN_PAGINATION_INVALID');after=list.data.at(-1).id;
 }
 if(!domain)throw new Error('RESEND_SENDER_DOMAIN_NOT_FOUND');
 const detail=await get(`/domains/${encodeURIComponent(domain.id)}`);
 if(detail.name.toLowerCase()!==name||detail.status!=='verified'||detail.open_tracking!==false||detail.click_tracking!==false)throw new Error('RESEND_DOMAIN_CONFIGURATION_REQUIRED');
 const hook=await get(`/webhooks/${encodeURIComponent(env.RESEND_WEBHOOK_ID)}`);
 if(hook.endpoint!==`${env.APP_URL}/api/webhooks/resend`||hook.status!=='enabled'||hook.signing_secret!==env.RESEND_WEBHOOK_SECRET||!events.every(e=>hook.events?.includes(e)))throw new Error('RESEND_OWN_SIGNED_WEBHOOK_REQUIRED');
 return {domainVerified:true,trackingDisabled:true,ownSignedWebhookConfigured:true,deliveryValidated:false};
}
export async function activateResendRelease(env=process.env,request=fetch){
 if(!activationPolicy(env)){console.log('Resend default activation not requested for this exact commit; existing provider retained.');return;}
 // Use the existing deployment admin connection for protected Auth metadata;
 // enforce the inspection transaction as READ ONLY inside Postgres itself.
 async function query(sql,readOnly){
  const r=await request(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({query:readOnly?`begin read only;${sql};commit;`:sql}),signal:AbortSignal.timeout(30000)});
  if(!r.ok){
   const body=await r.json().catch(()=>null);const code=/^[0-9A-Z]{5}$/.test(body?.code??'')?body.code:(typeof body?.message==='string'?body.message.match(/ERROR:\s*([0-9A-Z]{5}):/)?.[1]:null);
   throw new Error(`RESEND_RELEASE_DATABASE_${readOnly?'INSPECTION':'ACTIVATION'}_HTTP_${r.status}_${code??'UNKNOWN'}`);
  }return r.json();
 }
 const before=(await query(inspectionQuery(env),true))[0];
 if(!before?.imported)throw new Error('COMPLETE_SUPPRESSION_IMPORT_REQUIRED');
 if(!before.authorized_admins)throw new Error('MAIL_ADMIN_ALLOWLIST_HAS_NO_VERIFIED_EVENT_ADMIN');
 const checks=await verifyResendConfiguration(env,before.from_email,request);
 const after=await query(activationQuery(env,before),false);
 if(after.at(-1)?.provider!=='resend')throw new Error('RESEND_DEFAULT_NOT_CONFIRMED');
 console.log(JSON.stringify({environment:env.APP_ENVIRONMENT,release:env.GITHUB_SHA,activeProvider:'resend',authorizedMailAdmins:before.authorized_admins,...checks}));
 if(env.GITHUB_ENV)await appendFile(env.GITHUB_ENV,'MAIL_ACTIVE_PROVIDER=resend\n');
 if(env.GITHUB_STEP_SUMMARY)await appendFile(env.GITHUB_STEP_SUMMARY,`### Resend default activated\n\nEnvironment: ${env.APP_ENVIRONMENT}; commit: ${env.GITHUB_SHA}. Sender preserved, complete suppressions retained, verified domain with tracking disabled and own signed webhook configured. Exact release exception is audited in the database. Mail tests and delivery validation intentionally skipped; no test receipt was fabricated. Existing SendGrid attempts remain pinned.\n`);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await activateResendRelease();
