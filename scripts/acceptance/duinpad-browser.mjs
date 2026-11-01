/** Component-browser acceptance only. Synthetic endpoints; no auth, relay, mail or hardware.
 * Run: node scripts/acceptance/duinpad-browser.mjs
 * Artifacts: test-results/duinpad-browser/{report.json,*.jpg}. No production routes are created.
 */
import { createRequire } from 'node:module';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { chromium } from '@playwright/test';
const repo = process.cwd(), output = resolve(repo, 'test-results/duinpad-browser');
await mkdir(output, { recursive: true });
const temp = await mkdtemp(join(tmpdir(), 'duinpad-components-'));
const require = createRequire(import.meta.url);
const cssRequire = createRequire(require.resolve('@tailwindcss/postcss'));
const postcss = cssRequire('postcss');
const tailwind = require('@tailwindcss/postcss');
const globals = await readFile(join(repo, 'app/globals.css'), 'utf8');
await writeFile(join(temp, 'globals.css'), (await postcss([tailwind({ base: repo })]).process(globals, { from: join(repo, 'app/globals.css') })).css);
await writeFile(join(temp, 'link.tsx'), `import * as React from '${repo}/node_modules/react'; export default function Link({href,children,...props}){return <a href={typeof href==='string'?href:href.pathname} {...props}>{children}</a>}`);
await writeFile(join(temp, 'supabase-mock.ts'), `
const callbacks=new Set();let subject='synthetic-account-A';
window.__duinpadAuth={emit(event,next){subject=next;for(const callback of callbacks)callback(event,next?{user:{id:next}}:null)},subscribers(){return callbacks.size}};
const client={auth:{onAuthStateChange(callback){callbacks.add(callback);queueMicrotask(()=>{if(callbacks.has(callback))callback('INITIAL_SESSION',subject?{user:{id:subject}}:null)});return{data:{subscription:{unsubscribe(){callbacks.delete(callback)}}}}}}};
export function createClient(){return client;}
`);
await writeFile(join(temp, 'main.tsx'), `import * as React from '${repo}/node_modules/react';import{createRoot}from '${repo}/node_modules/react-dom/client';
import{ActorRoom}from '${repo}/components/actors/actor-room';import{ActorManagement}from '${repo}/components/admin/actor-management';import{DuinpadExperience}from '${repo}/components/duinpad/experience';import{DuinpadAdmin}from '${repo}/components/duinpad/admin';
const permissions=['heks.ready','heks.go','zone1.trigger','zone1.stop','finale.go'];const initial={name:'Synthetische Acteur',revision:1,permissions,connected:true,compatible:true,observedAt:Date.now()/1000,controls:permissions.map(action=>({action,enabled:true,blocked_reason:null,group_id:['heks.go','finale.go'].includes(action)?'synthetic-run':null,effect:null})),receipts:[]};
const screen=new URLSearchParams(location.search).get('screen');createRoot(document.getElementById('root')).render(screen==='actor'?<ActorRoom initial={initial}/>:<main style={{maxWidth:900,margin:'auto',padding:16}}>{screen==='actors-admin'?<ActorManagement/>:screen==='posters'?<DuinpadAdmin/>:<DuinpadExperience/>}</main>);`);
execFileSync(join(repo, 'node_modules/.bin/esbuild'), [join(temp, 'main.tsx'), '--bundle', '--format=esm', '--jsx=automatic', `--tsconfig=${repo}/tsconfig.json`, `--alias:next/link=${temp}/link.tsx`, `--alias:@/lib/supabase/client=${temp}/supabase-mock.ts`, `--outdir=${temp}`, '--log-level=error', '--define:process.env.NEXT_PUBLIC_SUPABASE_URL=undefined', '--define:process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=undefined', '--define:process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY=undefined'], { cwd: repo, env: { ...process.env, NODE_PATH: join(repo, 'node_modules') } });
await writeFile(join(temp, 'index.html'), '<!doctype html><html lang="nl"><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/globals.css"><link rel="stylesheet" href="/main.css"></head><body><div id="root"></div><script type="module" src="/main.js"></script></body></html>');
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://localhost').pathname;
  const file = pathname.startsWith('/images/') || pathname.startsWith('/duinpad/') ? join(repo, 'public', pathname) : join(temp, ['/', '/index.html'].includes(pathname) ? 'index.html' : pathname);
  try { const bytes = await readFile(file); response.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : file.endsWith('.svg') ? 'image/svg+xml' : file.endsWith('.webp') ? 'image/webp' : 'text/html'); response.end(bytes); }
  catch { response.statusCode = 404; response.end('missing'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port, origin = `http://127.0.0.1:${port}`;
const browser = await chromium.launch({ headless: true });
const checks = [], failures = [];
function check(name, pass, evidence) { checks.push({ name, pass, evidence }); if (!pass) failures.push(name); }
const permissions = ['heks.ready', 'heks.go', 'zone1.trigger', 'zone1.stop', 'finale.go'];
let actorDenied = false, actorUnknown = false, actorStale = false, actorFinaleBlocked = false, ended = false;
const calls = [];
const snapshot = () => ({ eligible: true, recorded: false, eveningEnded: ended, children: [{ id: 'synthetic-child', name: 'Synthetisch Kind' }], location: { name: 'Synthetische Finalepoort', address: 'ALLEEN LOKALE FIXTURE', instruction: 'Volg de synthetische ingangsinstructie.' } });
try {
 for (const width of [320, 390]) {
  const context = await browser.newContext({ viewport: { width, height: 844 }, reducedMotion: 'reduce' });
  const page = await context.newPage();
  page.on('pageerror', error => failures.push(`browser ${width}: ${error.message}`));
  let authFixture = null, receiptHold = null, retryHold = null, snapshotHold = null;
  function deferredResponse(payload, status = 200) {
    let release, markRequested;
    const gate = new Promise(resolve => { release = resolve; });
    const requested = new Promise(resolve => { markRequested = resolve; });
    return { payload, status, gate, requested, release, markRequested };
  }
  async function waitForHeldRequest(hold) {
    let timer;
    try { await Promise.race([hold.requested, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Synthetic deferred request was not observed')), 10000); })]); }
    finally { clearTimeout(timer); }
  }
  async function switchAccount(owner) {
    authFixture.owner = owner;
    authFixture.show = { status: 'blocked', message: `Actuele eigen groep ${owner}: wacht op de begeleider.` };
    await page.evaluate(subject => { window.__duinpadAuth.emit('SIGNED_IN', subject); }, `synthetic-account-${owner}`);
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await page.getByText(`Synthetische Finalepoort account ${owner}`, { exact: true }).waitFor();
    await page.getByText(`Actuele eigen groep ${owner}: wacht op de begeleider.`, { exact: true }).waitFor();
  }
  async function settleOldResponse(hold, path) {
    const received = page.waitForResponse(response => new URL(response.url()).pathname === path);
    hold.release();
    await received;
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  }
  await page.route('**/api/**', async route => {
    const url = new URL(route.request().url()); const body = route.request().postDataJSON(); calls.push({ path: url.pathname, search: url.search, method: route.request().method(), body });
    let held = null;
    if (url.pathname === '/api/duinpad/receipt' && receiptHold) { held = receiptHold; receiptHold = null; }
    if (url.pathname === '/api/duinpad/retry' && retryHold) { held = retryHold; retryHold = null; }
    if (url.pathname === '/api/duinpad/snapshot' && snapshotHold) { held = snapshotHold; snapshotHold = null; }
    if (held) {
      held.markRequested(); await held.gate;
      await route.fulfill({ status: held.status, contentType: 'application/json', body: JSON.stringify(held.payload) });
      return;
    }
    let payload, status = 200;
    if (url.pathname === '/api/actors') {
      status = actorDenied ? 403 : 200;
      payload = actorDenied ? { error: { message: 'Je toegang is ingetrokken.' } } : { data: { name: 'Synthetische Acteur', revision: 1, permissions, connected: true, compatible: true, observedAt: Date.now()/1000 - (actorStale ? 9 : 0), controls: permissions.map(action => ({ action, enabled: !(actorFinaleBlocked && action === 'finale.go'), blocked_reason: actorFinaleBlocked && action === 'finale.go' ? 'Finale-uitkomst onbekend; controleer de regie' : null, group_id: ['heks.go', 'finale.go'].includes(action) ? 'synthetic-run' : null, effect: null })), receipts: actorUnknown ? [{ commandId: '0c470ea3-3e9a-4b36-8d84-0f59dc4ee8c3', action: 'heks.go', status: 'unknown', result: { message: 'Geen startbevestiging ontvangen.' } }] : [] } };
    } else if (url.pathname === '/api/actors/command') { actorUnknown = true; payload = { data: { status: 'unknown', message: 'Geen startbevestiging ontvangen. Vraag de regie.' } }; }
    else if (url.pathname === '/api/actors/finale-recovery') payload = { data: { status: 'blocked', message: 'Gedeelde finale: de regie heeft niet-uitvoering bevestigd.' } };
    else if (url.pathname.startsWith('/api/actors/receipts/')) payload = { data: { status: 'unknown', result: { message: 'Nog geen betrouwbare uitvoeringsuitslag.' } } };
    else if (url.pathname === '/api/actors/admin') payload = { data: { actors: [{ id: 'synthetic-actor', name: 'Synthetische Acteur', email: 'acteur@example.invalid', status: 'pending', permissions: [], revision: 1, lastSeenAt: null, activatedAt: null, expiresAt: '2026-11-07T20:00:00Z', mailStatus: 'accepted' }] } };
    else if (url.pathname === '/api/duinpad/snapshot') payload = authFixture ? { ...snapshot(), runId: `synthetic-run-${authFixture.owner}`, recorded: true, eveningEnded: false, children: [], location: { name: `Synthetische Finalepoort account ${authFixture.owner}`, address: 'ALLEEN LOKALE AUTH-STATE FIXTURE' }, show: authFixture.show } : snapshot();
    else if (url.pathname === '/api/duinpad/validate') payload = { ...snapshot(), stage: 'qr2' };
    else if (url.pathname === '/api/duinpad/confirm') payload = { stage: 'qr2', duplicate: false, show: { status: 'unknown', message: 'Geen startbevestiging ontvangen. Vraag de begeleider om de regie te controleren.' } };
    else if (url.pathname === '/api/duinpad/admin') payload = { qr1: { id: 'synthetic-qr1', label: 'Synthetische ingang', instruction: 'Vóór de heks', version: 1 }, qr2: { id: 'synthetic-qr2', label: 'Synthetische finale', instruction: 'Echte finale in fixture', version: 1 }, portals: [], show: { configured: true, connected: false } };
    else if (url.pathname === '/api/duinpad/poster') payload = { id: url.searchParams.get('stage') === 'qr1' ? 'synthetic-qr1' : 'synthetic-qr2', credential: 'synthetic-only-not-production-credential', shortCode: url.searchParams.get('stage') === 'qr1' ? '111111' : '222222', origin: `http://localhost:${port}` };
    else if (url.pathname === '/api/redesign/thanks') payload = { finished: true, portals: [], saved: [] };
    else payload = {};
    await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(payload) });
  });
  actorDenied = false; actorUnknown = false; actorStale = false; actorFinaleBlocked = false; ended = false;
  await page.goto(`${origin}/?screen=actor`);
  await page.getByRole('heading', { name: 'Acteurskamer', exact: true }).waitFor();
  check(`actor ${width}px no horizontal overflow`, await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'document.scrollWidth <= viewport');
  check(`actor ${width}px only assigned buttons`, await page.getByRole('button', { name: 'Zone 2 starten', exact: true }).count() === 0 && await page.getByRole('button', { name: 'ALLES STOPPEN', exact: true }).count() === 0, 'unassigned controls absent');
  check(`actor ${width}px large touch targets`, await page.locator('.actor-card button').evaluateAll(buttons => buttons.every(button => button.getBoundingClientRect().height >= 48)), 'buttons >=48 CSS px');
  await page.keyboard.press('Tab'); await page.keyboard.press('Tab'); await page.keyboard.press('Tab');
  check(`actor ${width}px keyboard focus`, await page.evaluate(() => document.activeElement?.tagName === 'BUTTON'), 'keyboard reaches assigned action');
  await page.screenshot({ path: join(output, `actor-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });
  await page.getByRole('button', { name: 'Heks GO', exact: true }).click();
  await page.getByText('Controle bij de regie nodig', { exact: true }).waitFor();
  check(`actor ${width}px unknown blocks retry`, await page.getByRole('button', { name: 'Heks GO', exact: true }).isDisabled(), 'unknown requires read-only receipt');
  const commandsBefore = calls.filter(c => c.path === '/api/actors/command').length;
  await page.getByRole('button', { name: 'Ontvangst controleren', exact: true }).click();
  await page.getByText('Nog geen betrouwbare uitvoeringsuitslag.', { exact: true }).waitFor();
  check(`actor ${width}px receipt never retries`, calls.filter(c => c.path === '/api/actors/command').length === commandsBefore, 'GET receipt emits no POST command');
  actorUnknown = false; actorFinaleBlocked = true;
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.waitForFunction(() => [...document.querySelectorAll('.actor-controls button')].some(button => button.textContent === 'Finale GO' && button.disabled));
  check(`actor ${width}px shared finale receipt readable while GO blocked`, await page.getByRole('button', { name: 'Gedeelde finale-ontvangst controleren', exact: true }).isEnabled() && await page.locator('.actor-receipt').count() === 0, 'separate read-only recovery does not require an enabled execution control or original actor receipt');
  const beforeSharedRead = calls.filter(call => call.path === '/api/actors/command').length;
  await page.getByRole('button', { name: 'Gedeelde finale-ontvangst controleren', exact: true }).click();
  await page.getByText('Gedeelde finale: de regie heeft niet-uitvoering bevestigd.', { exact: true }).waitFor();
  const sharedRead = calls.findLast(call => call.path === '/api/actors/finale-recovery');
  check(`actor ${width}px shared finale recovery is GET without browser group`, sharedRead.method === 'GET' && sharedRead.search === '' && calls.filter(call => call.path === '/api/actors/command').length === beforeSharedRead, 'group derived by authenticated backend; no execution POST from recovery');
  actorDenied = true; await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.getByText('Toegang gewijzigd', { exact: true }).waitFor();
  check(`actor ${width}px revocation removes controls`, await page.locator('.actor-controls button').count() === 0, '403 focus refresh removes controls');
  actorDenied = false; actorUnknown = false; actorStale = true; actorFinaleBlocked = false;
  await page.goto(`${origin}/?screen=actor`); await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.getByText('Geen actuele verbinding met de showcomputer', { exact: true }).waitFor();
  check(`actor ${width}px stale blocks all actions`, await page.locator('.actor-controls button').evaluateAll(buttons => buttons.every(button => button.disabled)), '9s old local status rejected');
  await page.goto(`${origin}/?screen=actors-admin`); await page.getByRole('heading', { name: 'Acteurs & showbediening', exact: true }).waitFor();
  await page.getByText('Provider heeft geaccepteerd; aflevering onbekend', { exact: true }).waitFor();
  check(`actor management ${width}px starts without rights`, await page.locator('.actor-permissions input:checked').count() === 0, 'new invite rights none');
  await page.getByRole('button', { name: 'Heks', exact: true }).click();
  check(`actor management ${width}px preset excludes global stop`, await page.getByRole('checkbox', { name: 'ALLES STOPPEN' }).isChecked() === false, 'global stop separate');
  check(`actor management ${width}px no horizontal overflow`, await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'document.scrollWidth <= viewport');
  await page.screenshot({ path: join(output, `actor-admin-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });
  await page.goto(`${origin}/?screen=finale`); await page.getByRole('heading', { name: /Er wacht nog één poort/ }).waitFor();
  check(`finale ${width}px server location`, await page.getByText('Synthetische Finalepoort', { exact: true }).isVisible(), 'server snapshot location');
  check(`finale ${width}px reduced motion`, await page.locator('.duinpad-gate-art img').evaluate(image => getComputedStyle(image).animationName === 'none'), 'prefers-reduced-motion disables gate animation');
  check(`finale ${width}px no horizontal overflow`, await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'document.scrollWidth <= viewport');
  await page.screenshot({ path: join(output, `finale-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });
  await page.getByRole('button', { name: 'Scan de finale-QR of QR1', exact: true }).click();
  await page.getByLabel('Korte code').fill('111111');
  const confirmBefore = calls.filter(c => c.path === '/api/duinpad/confirm').length;
  await page.getByRole('button', { name: 'Code controleren', exact: true }).click();
  await page.getByRole('button', { name: 'Ja, bevestig onze aankomst', exact: true }).waitFor();
  check(`finale ${width}px validation does not confirm`, confirmBefore === calls.filter(c => c.path === '/api/duinpad/confirm').length, 'validation only opens participation confirmation');
  await page.getByLabel('Slaat de beleving over, krijgt wel een zegel').check();
  await page.getByRole('button', { name: 'Ja, bevestig onze aankomst', exact: true }).click();
  await page.getByText('Jullie finalescan is geregistreerd.', { exact: true }).waitFor();
  check(`finale ${width}px skip child preserved`, calls.findLast(c => c.path === '/api/duinpad/confirm').body.choices['synthetic-child'] === 'skipped', 'explicit skipped child sent to business confirmation');
  ended = true; await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.getByRole('heading', { name: 'Bedankt voor het samen griezelen!', exact: true }).waitFor();
  check(`finale ${width}px server ended removes starts`, await page.getByRole('button', { name: 'Scan de finale-QR of QR1', exact: true }).count() === 0, 'server eveningEnded hides scan action');
  await page.screenshot({ path: join(output, `evening-ended-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });
  await page.goto(`${origin}/?screen=posters`); await page.getByRole('heading', { name: 'Duinpad: QR1 & QR2', exact: true }).waitFor();
  await page.getByText('Appcode ingesteld', { exact: true }).first().waitFor();
  check(`posters ${width}px distinct codes`, await page.getByText('111111', { exact: true }).count() === 1 && await page.getByText('222222', { exact: true }).count() === 1, 'separate QR1/QR2 preview and short code');
  check(`posters ${width}px show offline separate`, await page.getByText(/Showverbinding: geen actuele verbinding/).isVisible(), 'valid app posters do not claim connected show');
  check(`posters ${width}px no horizontal overflow`, await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'document.scrollWidth <= viewport');
  await page.screenshot({ path: join(output, `posters-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });

  // Real component lifecycle, synthetic Supabase events. These tests assert that
  // old HTTP results cannot cross an account generation; no provider is contacted.
  authFixture = { owner: 'A', show: { status: 'unknown', message: 'Account A wacht op de bestaande ontvangst.' } };
  await page.goto(`${origin}/?screen=finale`);
  await page.getByText('Synthetische Finalepoort account A', { exact: true }).waitFor();
  check(`auth generation ${width}px mocked subscription active`, await page.evaluate(() => window.__duinpadAuth.subscribers() > 0), 'actual component onAuthStateChange callback subscribed to synthetic emitter');
  const oldReceipt = deferredResponse({ status: 'started', message: 'OUDE ACCOUNT A: FINALSHOW GESTART' });
  receiptHold = oldReceipt;
  await page.getByRole('button', { name: 'Bestaande ontvangst controleren', exact: true }).click();
  await waitForHeldRequest(oldReceipt);
  check(`finale receipt ${width}px scopes recorded receipt to QR2`, new URLSearchParams(calls.findLast(call => call.path === '/api/duinpad/receipt').search).get('stage') === 'qr2', 'recorded account does not recover a QR1 registration as finale receipt');
  await switchAccount('B');
  await settleOldResponse(oldReceipt, '/api/duinpad/receipt');
  check(`auth generation ${width}px late receipt A cannot mark B started`, await page.getByText('OUDE ACCOUNT A: FINALSHOW GESTART', { exact: true }).count() === 0 && await page.getByText('Actuele eigen groep B: wacht op de begeleider.', { exact: true }).isVisible(), 'hold receipt A, emit SIGNED_IN B, load B, release started receipt A');

  await switchAccount('A');
  const oldRetry = deferredResponse({ status: 'started', message: 'OUDE RETRY A: FINALSHOW GESTART' });
  retryHold = oldRetry;
  await page.getByRole('button', { name: 'Bewust opnieuw finale aanvragen', exact: true }).click();
  await waitForHeldRequest(oldRetry);
  await switchAccount('B');
  await settleOldResponse(oldRetry, '/api/duinpad/retry');
  check(`auth generation ${width}px late retry A cannot mark B started`, await page.getByText('OUDE RETRY A: FINALSHOW GESTART', { exact: true }).count() === 0 && await page.getByText('Actuele eigen groep B: wacht op de begeleider.', { exact: true }).isVisible(), 'hold retry A, switch B, release successful old retry after B snapshot');

  await switchAccount('A');
  const oldForbidden = deferredResponse({ error: { message: 'Synthetic old A forbidden snapshot' } }, 403);
  snapshotHold = oldForbidden;
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await waitForHeldRequest(oldForbidden);
  await switchAccount('B');
  await settleOldResponse(oldForbidden, '/api/duinpad/snapshot');
  check(`auth generation ${width}px late A403 cannot erase B snapshot`, await page.getByText('Synthetische Finalepoort account B', { exact: true }).isVisible() && await page.getByText('Actuele eigen groep B: wacht op de begeleider.', { exact: true }).isVisible(), 'hold A403, load B after auth event, release stale authorization error');
  await page.screenshot({ path: join(output, `auth-switch-${width}.jpg`), type: 'jpeg', quality: 80, fullPage: true });
  await context.close();
 }
} catch (error) { failures.push(error.stack); }
finally {
 await browser.close(); await new Promise(resolve => server.close(resolve)); await rm(temp, { recursive: true, force: true });
 const revision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
 await writeFile(join(output, 'report.json'), JSON.stringify({ testedAt: new Date().toISOString(), revision, environment: 'local component browser with synthetic HTTP mocks; working tree changes', hardware: 'not tested', auth: 'synthetic Supabase auth-state callbacks only; provider/OTP/Google authentication not tested', mail: 'not sent', checks, failures }, null, 2));
 console.log(JSON.stringify({ passed: checks.filter(c => c.pass).length, checks: checks.length, failures, output }, null, 2));
 if (failures.length) process.exitCode = 1;
}
