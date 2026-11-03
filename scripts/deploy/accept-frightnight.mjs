// Real hosted browser gate; does not log in, impersonate historical actors,
// request OTP or exercise writes. Authenticated multi-account acceptance is
// separately reported and never inferred from these public screenshots.
import { chromium } from '@playwright/test';
import { mkdir, writeFile, appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { management } from './redesign-preflight.mjs';
import { assertFrightnightRelease, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from './frightnight-release.mjs';

const target = assertFrightnightRelease(process.env);
const rows = await management('/database/query', {read_only:true,query:FRIGHTNIGHT_SAFETY_SQL});
assertFrightnightSafety(rows[0]?.frightnight_safety);
const directory = join(process.env.RUNNER_TEMP ?? '/tmp', 'frightnight-acceptance');
await mkdir(directory, {recursive:true});
const browser = await chromium.launch();
const report = {revision:process.env.GITHUB_SHA,origin:target.origin,eventSlug:target.slug,scope:'public-no-send',screenshots:[],checks:[],authenticatedRoleAcceptance:'not performed by this gate',otpOrProviderDelivery:'not performed by this gate'};
try {
  for (const width of [1440,390]) {
    const context = await browser.newContext({viewport:{width,height:900},reducedMotion:'reduce'});
    let forbiddenRequests = 0;
    await context.route('**/*', async route => {
      const request = route.request(), path = new URL(request.url()).pathname;
      if (/\/auth\/v1\/(otp|magiclink|recover|signup|invite)|\/api\/push\/test|\/api\/mail\//.test(path)
          || (request.method() !== 'GET' && request.method() !== 'HEAD' && /^\/api\/frightnight\//.test(path))) {
        forbiddenRequests++; await route.abort(); return;
      }
      await route.continue();
    });
    const page = await context.newPage();
    for (const [path,name] of [['/','festival'],['/inloggen','login'],['/nachtpas','nachtpas-entry'],['/mijn-zone','zone-entry'],['/avondregie','regie-entry'],['/testcentrum','test-entry']]) {
      const response = await page.goto(`${target.origin}${path}`, {waitUntil:'networkidle'});
      if (!response?.ok()) throw new Error(`FRIGHTNIGHT_BROWSER_PAGE_${path}`);
      await page.locator('main').waitFor();
      if (path === '/inloggen') await page.getByLabel('E-mailadres', {exact:true}).waitFor();
      if (path !== '/' && path !== '/inloggen') await page.getByRole('link', {name:/Inloggen met e-mailcode/}).waitFor();
      if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth+1)) throw new Error(`FRIGHTNIGHT_HORIZONTAL_OVERFLOW_${name}_${width}`);
      const filename = `${name}-${width}.png`;
      await page.screenshot({path:join(directory,filename),fullPage:true});
      report.screenshots.push(filename);
    }
    const snapshot = await context.request.get(`${target.origin}/api/frightnight/snapshot`);
    if (snapshot.status() !== 401 || !snapshot.headers()['cache-control']?.includes('no-store')) throw new Error('FRIGHTNIGHT_BROWSER_PRIVATE_API_FAILED');
    await page.goto(`${target.origin}/`);
    await page.evaluate(async () => {
      if (!('serviceWorker' in navigator)) throw new Error('SERVICE_WORKER_UNAVAILABLE');
      let installationTimer;
      try {
        await Promise.race([
          navigator.serviceWorker.register('/sw.js').then(() => navigator.serviceWorker.ready),
          new Promise((_,reject) => { installationTimer=setTimeout(()=>reject(new Error('SW_INSTALLATION_FAILED')),15000); }),
        ]);
      } catch { throw new Error('SW_INSTALLATION_FAILED'); }
      finally { clearTimeout(installationTimer); }
      if (!navigator.serviceWorker.controller) await new Promise((resolve,reject) => {
        const timer=setTimeout(()=>reject(new Error('SERVICE_WORKER_NOT_CONTROLLING')),10000);
        navigator.serviceWorker.addEventListener('controllerchange',()=>{clearTimeout(timer);resolve(true);},{once:true});
      });
    });
    const privateCache = await page.evaluate(async () => {
      for (const name of await caches.keys()) for (const request of await (await caches.open(name)).keys()) {
        if (/^\/(api|auth|nachtpas|mijn-zone|avondregie|testcentrum|inloggen)(?:\/|$)/.test(new URL(request.url).pathname)) return true;
      }
      return false;
    });
    if (privateCache || forbiddenRequests) throw new Error('FRIGHTNIGHT_NO_SEND_OR_PRIVATE_CACHE_FAILED');
    await context.setOffline(true);
    await page.goto(`${target.origin}/offline.html`);
    if (!(await page.locator('body').innerText()).includes('Duinpad')) throw new Error('FRIGHTNIGHT_PREAVAILABLE_HELP_FAILED');
    const offlineLogo = await page.evaluate(async () => {
      const logo = document.querySelector('img[src="/frightnight/logo.png"]');
      if (!(logo instanceof HTMLImageElement)) return false;
      let imageTimer;
      try {
        await Promise.race([
          logo.decode(),
          new Promise((_,reject) => { imageTimer=setTimeout(()=>reject(new Error('OFFLINE_LOGO_DECODE_TIMEOUT')),5000); }),
        ]);
        return logo.complete && logo.naturalWidth > 0 && logo.naturalHeight > 0;
      } catch { return false; }
      finally { clearTimeout(imageTimer); }
    });
    if (!offlineLogo) throw new Error('FRIGHTNIGHT_PREAVAILABLE_LOGO_FAILED');
    report.checks.push({width,publicScreens:true,loginForm:true,privateApiDenied:true,privateCacheEmpty:true,noSend:true,preavailableHelp:true,offlineLogo:true,reducedMotion:true});
    await context.close();
  }
} finally { await browser.close(); }
await writeFile(join(directory,'report.json'),JSON.stringify(report,null,2)+'\n');
if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY,'### FrightNight no-send browser acceptance\n\nDesktop and 390px mobile: festival, OTP form, four authenticated-entry shells, no horizontal overflow, denied private API, private-cache boundary and preavailable Duinpad help checked. No OTP, mail, push or payment requested. These public screenshots do not establish authenticated role, camera, load, PSP or whole-walk acceptance.\n');
console.log('FrightNight public mobile/desktop and no-send privacy checks passed; scope recorded in report.json.');
