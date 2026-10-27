import {describe,it,expect,vi} from 'vitest';
import {activationPolicy,activationQuery,inspectionQuery,verifyResendConfiguration,activateResendRelease} from './activate-resend-release.mjs';
const now=Date.now(),sha='a'.repeat(40);
const env={GITHUB_SHA:sha,RESEND_DEFAULT_RELEASE_SHA:sha,GITHUB_REPOSITORY:'duindorpdoet/platform',GITHUB_REF:'refs/heads/staging',APP_ENVIRONMENT:'staging',APP_URL:'https://staging-halloween.duindorpdoet.nl',SUPABASE_PROJECT_REF:'nocteiuvohesvqbowchw',SKIP_MAIL_TESTS:'true',MAIL_TEST_WAIVER_SHA:sha,MAIL_TEST_WAIVER_EXPIRES_AT:new Date(now+3600000).toISOString(),MAIL_TEST_WAIVER_REASON:'Explicit owner instruction: Resend default, no mail tests',SUPABASE_ACCESS_TOKEN:'fixture',RESEND_API_KEY:'fixture',RESEND_ADMIN_API_KEY:'fixture',RESEND_WEBHOOK_ID:'own-hook',RESEND_WEBHOOK_SECRET:'whsec_fixture',MAIL_ADMIN_USER_IDS:'f0000000-0000-0000-0000-000000000001'};
const before={revision:0,active_id:'f0000000-0000-0000-0000-000000000002',provider:'sendgrid',from_email:'sender@example.invalid',imported:true,authorized_admins:1};
const hook={endpoint:env.APP_URL+'/api/webhooks/resend',status:'enabled',signing_secret:env.RESEND_WEBHOOK_SECRET,events:['email.sent','email.delivered','email.delivery_delayed','email.bounced','email.complained','email.failed','email.suppressed']};
function configurationResponse(url:string){return url.includes('/domains?')?{data:[{id:'domain',name:'example.invalid'}]}:url.includes('/domains/')?{name:'example.invalid',status:'verified',open_tracking:false,click_tracking:false}:hook;}
describe('bounded Resend default release configuration without mail delivery',()=>{
 it('does nothing for unrelated commits and requires exact unexpired waiver and environment',()=>{
  expect(activationPolicy({...env,GITHUB_SHA:'b'.repeat(40)},now)).toBe(false);
  expect(activationPolicy(env,now)).toBe(true);
  for(const patch of [{SUPABASE_PROJECT_REF:'dtubngvxfbupgvgfrjko'},{GITHUB_REF:'refs/heads/main'},{MAIL_TEST_WAIVER_SHA:'b'.repeat(40)},{SKIP_MAIL_TESTS:'false'},{MAIL_TEST_WAIVER_EXPIRES_AT:new Date(now-1).toISOString()},{RESEND_WEBHOOK_SECRET:''}])expect(()=>activationPolicy({...env,...patch},now)).toThrow();
 });
 it('verifies actual sender-domain details and own signed webhook using GETs only',async()=>{
  const request=vi.fn(async(url:string,options:RequestInit)=>{expect(options.method).toBeUndefined();expect(url).not.toMatch(/\/emails|\/events|\/functions/);return Response.json(configurationResponse(url));});
  expect(await verifyResendConfiguration(env,before.from_email,request)).toMatchObject({domainVerified:true,trackingDisabled:true,deliveryValidated:false});expect(request).toHaveBeenCalledTimes(3);
 });
 it('rejects tracking, unverified domains and another endpoint before switching',async()=>{
  for(const patch of [{status:'pending'},{click_tracking:true}])await expect(verifyResendConfiguration(env,before.from_email,async(url:string)=>Response.json(url.includes('/domains/')?{...configurationResponse(url),...patch}:configurationResponse(url)))).rejects.toThrow('RESEND_DOMAIN_CONFIGURATION_REQUIRED');
  await expect(verifyResendConfiguration(env,before.from_email,async(url:string)=>Response.json(url.includes('/webhooks/')?{...hook,endpoint:'https://other.invalid'}:configurationResponse(url)))).rejects.toThrow('RESEND_OWN_SIGNED_WEBHOOK_REQUIRED');
 });
 it('requires suppression completion and a currently verified allowlisted event administrator',async()=>{
  for(const patch of [{imported:false},{authorized_admins:0}]){
   const request=vi.fn(async()=>Response.json([{...before,...patch}]));await expect(activateResendRelease(env,request)).rejects.toThrow();expect(request).toHaveBeenCalledTimes(1);
  }
  expect(()=>inspectionQuery({...env,MAIL_ADMIN_USER_IDS:"'); select 1;--"})).toThrow();
 });
 it('records a configuration exception without pretending a delivered test exists',async()=>{
  const query=activationQuery(env,before);expect(query).toContain("'mail.config.release_activate'");expect(query).toContain('"deliveryValidated":false');expect(query).toContain('for update');expect(query).toContain('CONFIG_VERSION_CONFLICT');expect(query).not.toMatch(/insert into app_private.(mail_envelopes|email_events)|40001|draft_id=/);
  const request=vi.fn(async(url:string,options:RequestInit)=>{
   if(url.startsWith('https://api.resend.com'))return Response.json(configurationResponse(url));
   const body=JSON.parse(options.body as string);return Response.json(body.read_only?[before]:[{provider:'resend'}]);
  });await activateResendRelease(env,request);expect(request).toHaveBeenCalledTimes(5);
 });
});
