import { chromium } from '/home/codex/repos/duindorphalloween-frightnight-2027/node_modules/@playwright/test/index.mjs';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const root='/home/codex/repos/duindorphalloween-frightnight-2027';
const origin='http://127.0.0.1:3137';
const output='/tmp/frightnight-login-invalid-evidence';
await mkdir(output,{recursive:true});
const report={scope:'local real public OTP form invalid-input validation only; no authentication request authorized',origin,buildId:(await readFile(root+'/.next/BUILD_ID','utf8')).trim(),revision:'0ddd9558f3fd70ce479fd1d02d2d5168586ca167',startedAt:new Date().toISOString(),checks:[],blockedWrites:[],pageErrors:[],otpRequests:0,sourceSha256:{}};
for(const name of ['components/frightnight/login.tsx','components/auth/email-otp-form.tsx','app/inloggen/page.tsx']) report.sourceSha256[name]=createHash('sha256').update(await readFile(root+'/'+name)).digest('hex');
const browser=await chromium.launch({headless:true,args:['--disable-dev-shm-usage','--no-sandbox']});
try {
 for(const width of [390,1440]) {
  const context=await browser.newContext({viewport:{width,height:900},locale:'nl-NL',reducedMotion:'reduce',serviceWorkers:'block'});
  await context.route('**/*',async route=>{
   const request=route.request(), url=new URL(request.url());
   if(!['GET','HEAD'].includes(request.method())){ report.blockedWrites.push({method:request.method(),path:url.pathname}); if(/otp|verify|token|authorize/i.test(url.pathname)) report.otpRequests++; return route.abort('blockedbyclient'); }
   if(url.origin!==origin) return route.abort('blockedbyclient');
   return route.continue();
  });
  const page=await context.newPage();page.on('pageerror',error=>report.pageErrors.push(error.message));
  await page.goto(origin+'/inloggen',{waitUntil:'networkidle'});
  const email=page.getByLabel('E-mailadres',{exact:true});
  const button=page.getByRole('button',{name:'Stuur eenmalige code',exact:true});
  await email.waitFor({state:'visible'});
  await page.waitForFunction(()=>document.querySelector('input[type="email"]')?.disabled===false);
  assert.equal(await button.isDisabled(),true);
  report.checks.push({width,label:'empty email prevents code request',status:'passed'});
  for(const value of ['geen-adres','ongeldig@','dubbel@@voorbeeld.invalid']) {
   await email.fill(value);
   const before=report.blockedWrites.length;
   if(await button.isEnabled()) await button.click();
   else await email.press('Enter');
   const validity=await email.evaluate(input=>({valid:input.validity.valid,typeMismatch:input.validity.typeMismatch,valueMissing:input.validity.valueMissing,message:input.validationMessage}));
   assert.equal(validity.valid,false);assert.equal(validity.typeMismatch,true);assert.ok(validity.message.length>0);
   assert.equal(report.blockedWrites.length,before);
   assert.ok(await email.isVisible());
   report.checks.push({width,label:'malformed email rejected before Auth',value,validity,status:'passed'});
  }
  await page.screenshot({path:output+`/invalid-email-${width}.png`,fullPage:true});
  await context.close();
 }
 assert.equal(report.blockedWrites.length,0);assert.equal(report.otpRequests,0);assert.equal(report.pageErrors.length,0);
 report.status='passed';
} finally { await browser.close();report.completedAt=new Date().toISOString();await writeFile(output+'/report.json',JSON.stringify(report,null,2)+'\n',{mode:0o600}); }
console.log(JSON.stringify({status:report.status,checks:report.checks.length,otpRequests:report.otpRequests,blockedWrites:report.blockedWrites.length,output}));
