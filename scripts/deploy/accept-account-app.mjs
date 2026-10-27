// Release acceptance never requests OTP, sends mail or subscribes/sends push.
import {chromium} from '@playwright/test';
import {mkdir,appendFile} from 'node:fs/promises';
import {join} from 'node:path';
const app=process.env.APP_URL;
if(process.env.APP_ENVIRONMENT!=='staging'||app!=='https://staging-halloween.duindorpdoet.nl'||process.env.SUPABASE_PROJECT_REF!=='nocteiuvohesvqbowchw')throw new Error('STAGING_ACCEPTANCE_BOUNDARY');
const proof=await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({query:`begin;
 do $checks$
 declare actor uuid; account jsonb; child_id text; child_count integer;
 begin
  if has_function_privilege('anon','api.account_app_snapshot(text)','execute') or has_table_privilege('authenticated','app_private.account_app_preferences','select') then raise exception 'ACCOUNT_PRIVILEGES_UNSAFE';end if;
  if not exists(select 1 from supabase_migrations.schema_migrations where version='20261027033940') or exists(select 1 from supabase_migrations.schema_migrations where version='20261027032725') then raise exception 'HOTFIX_HISTORY_NOT_CANONICAL';end if;
  if exists(select 1 from app_private.portal_maintenance_drafts where payload ?|array['impactHash','impactConfirmed','commandKey']) then raise exception 'STALE_DRAFT_METADATA';end if;
  select hm.user_id into actor from app_private.household_members hm join auth.users u on u.id=hm.user_id join app_private.registrations r on r.household_id=hm.household_id join app_private.events e on e.id=r.event_id where hm.revoked_at is null and hm.relation_role='owner' and r.status='submitted' and e.slug='duindorp-halloween-2026' and u.email_confirmed_at is not null order by hm.user_id limit 1;
  if actor is not null then
   perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
   account:=api.account_app_snapshot('duindorp-halloween-2026');
   if account->>'userId'<>actor::text or account->'children' is distinct from api.poortenboek_parent(actor,'duindorp-halloween-2026','list') then raise exception 'ACCOUNT_LINKS_DIFFER';end if;
   perform api.account_app_command('duindorp-halloween-2026','welcome','{"version":1}');
   if api.participant_guidance('duindorp-halloween-2026')->>'welcomeVersion'<>'1' then raise exception 'WELCOME_NOT_PERSISTED';end if;
   if jsonb_array_length(account->'children')>0 then
    child_id:=account->'children'->0->>'id';
    perform api.account_app_command('duindorp-halloween-2026','remember',jsonb_build_object('kind','child','id',child_id));
    if api.account_app_snapshot('duindorp-halloween-2026')->'resume'->>'id'<>child_id then raise exception 'RESUME_NOT_REVALIDATED';end if;
   end if;
   begin
    perform api.account_app_command('duindorp-halloween-2026','remember',jsonb_build_object('kind','child','id',gen_random_uuid()));
    raise exception 'FOREIGN_CHILD_ACCEPTED';
   exception when insufficient_privilege then null;end;
  end if;
  perform set_config('request.jwt.claims','{}',true);
  begin perform api.account_app_snapshot('duindorp-halloween-2026');raise exception 'ANONYMOUS_ACCOUNT_ACCEPTED';exception when insufficient_privilege then null;end;
 end $checks$;
 rollback;
 select true as rolled_back_contracts_passed;`}),signal:AbortSignal.timeout(60000)});
if(!proof.ok)throw new Error(`STAGING_RPC_CONTRACT_${proof.status}`);
const result=await proof.json();
if(result.at(-1)?.rolled_back_contracts_passed!==true)throw new Error('STAGING_CONTRACT_PROOF_MISSING');
console.log('Live account authorization, existing child links, once-only welcome, denied foreign child and canonical hotfix contracts passed with rollback.');
const browser=await chromium.launch();
const directory=join(process.env.RUNNER_TEMP??'/tmp','account-app-acceptance');await mkdir(directory,{recursive:true});
try{
 for(const width of [1440,360]){
  const context=await browser.newContext({viewport:{width,height:900}});const page=await context.newPage();
  let mailRequests=0,pushWrites=0;
  await page.route('**/*',async route=>{
   const request=route.request(),path=new URL(request.url()).pathname;
   if(/\/auth\/v1\/(otp|magiclink|recover|signup)|\/api\/push\/test|\/api\/mail\//.test(path)){mailRequests++;await route.abort();return;}
   if(path==='/api/push/subscription'&&request.method()!=='GET'){pushWrites++;await route.abort();return;}
   await route.continue();
  });
  await page.goto(`${app}/app`);if(!page.url().startsWith(`${app}/inloggen`))throw new Error('APP_ENTRY_NOT_LOGIN');
  await page.getByRole('button',{name:'Doorgaan met Google',exact:true}).waitFor();await page.getByLabel('E-mailadres',{exact:true}).waitFor();
  if(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1))throw new Error(`LOGIN_HORIZONTAL_OVERFLOW_${width}`);
  await page.screenshot({path:join(directory,`login-${width}.png`),fullPage:true});
  const privateApi=await context.request.get(`${app}/api/account`);if(privateApi.status()!==401||!privateApi.headers()['cache-control']?.includes('no-store'))throw new Error('ACCOUNT_API_PRIVACY_FAILED');
  await page.goto(`${app}/auth/callback?error=access_denied`);await page.locator('.entry-error').filter({hasText:'geannuleerd'}).waitFor();
  await page.goto(`${app}/app/hulp`);await page.getByRole('button',{name:'Installeer de app',exact:true}).waitFor();
  await page.evaluate(()=>navigator.serviceWorker.ready.then(()=>true));
  const privateCache=await page.evaluate(async()=>{for(const name of await caches.keys())for(const request of await(await caches.open(name)).keys())if(/^\/(app(?:\/|$)|auth|api|omgeving|mijn-|admin|inloggen|poortenboek)/.test(new URL(request.url).pathname))return true;return false;});
  if(privateCache||mailRequests||pushWrites)throw new Error('ACCEPTANCE_PRIVACY_OR_NO_SEND_BOUNDARY');
  await context.close();
 }
}finally{await browser.close();}
console.log(`Live desktop/mobile app-entry, complete login, cancellation, help, service worker and private-cache checks passed for ${process.env.GITHUB_SHA}. No mail or push delivery attempted.`);
if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,`### Account/app staging acceptance\n\nDesktop and 360px mobile: live app entry, complete Google/OTP screen, cancellation, private account API, installation help and worker cache privacy passed. Account/RPC/welcome/child-link checks ran with rollback. No OTP request, testmail or push send. Google credentials and actual device push delivery remain separate external validation.\n`);
