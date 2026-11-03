// Hosted acceptance creates only fresh .invalid identities and a fresh 2027
// sibling edition. It never signs in an existing actor, requests OTP or sends
// mail. Credentials, sessions and QR secrets stay in process memory.
import { createClient } from '@supabase/supabase-js';
import { createServerClient } from '@supabase/ssr';
import { chromium, expect } from '@playwright/test';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { management } from '../deploy/redesign-preflight.mjs';
import { assertFrightnightRelease, assertFrightnightHostedContract, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from '../deploy/frightnight-release.mjs';
import { runRegieAcceptance } from './frightnight-regie.mjs';

const target = assertFrightnightRelease(process.env);
if (!/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA ?? '') || process.env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA !== process.env.GITHUB_SHA) throw new Error('VERIFIED_BACKUP_PRESERVATION_AND_RELEASE_REQUIRED');
if (process.env.FRIGHTNIGHT_PAYMENT_PROVIDER !== 'contract') throw new Error('ACCEPTANCE_REQUIRES_EXPLICIT_CONTRACT_PROVIDER_NO_EXTERNAL_PAYMENT');
for (const name of ['NEXT_PUBLIC_SUPABASE_ANON_KEY','SUPABASE_SERVICE_ROLE_KEY','SUPABASE_ACCESS_TOKEN']) if (!process.env[name]) throw new Error(`ACCEPTANCE_MISSING_${name}`);
const sbUrl = `https://${target.projectRef}.supabase.co`;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const service = createClient(sbUrl, process.env.SUPABASE_SERVICE_ROLE_KEY, {auth:{persistSession:false,autoRefreshToken:false}});
const run = `${process.env.GITHUB_RUN_ID ?? 'manual'}-${randomUUID().slice(0,8)}`;
const slug = `frightnight-2027-test-acceptance-${run}`;
const directory = join(process.env.RUNNER_TEMP ?? '/tmp','frightnight-acceptance','authenticated');
await mkdir(directory,{recursive:true});
const report = {revision:process.env.GITHUB_SHA,origin:target.origin,projectRef:target.projectRef,edition:slug,scope:'fresh-synthetic-2027-only',checks:[],screenshots:[],externalPsp:'not exercised; deterministic contract adapter',physicalCamera:'not exercised; manual QR alternative used',load:'two concurrent families; no high-volume load claim',credentials:'memory only; no passwords, sessions or QR secrets in artifacts'};
const actors=[];
const contexts=[];
let browser;
let eventId;
let fixtureAdmin;
let preservationBefore;
let bootstrapAttempted=false;
let failed;
const literal = value => `'${String(value).replaceAll("'","''")}'`;
const assert = (condition,code) => {if(!condition)throw new Error(code);};
const checked = (label,detail={}) => {report.checks.push({label,status:'passed',...detail});console.log(`FrightNight acceptance: ${label} passed.`);};
const safeError=error=>{
  const message=String(error?.message??'');
  return /^[A-Za-z0-9_.:-]{1,180}$/.test(message)?message:'BROWSER_OR_RUNTIME_CHECK_FAILED';
};
async function sql(query, write=false) {
  return management('/database/query',{read_only:!write,query:write?`begin;set local lock_timeout='3s';set local statement_timeout='15s';${query};commit;`:query});
}
async function rpc(actor,name,args,allowFailure=false) {
  const response=await fetch(`${sbUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:anonKey,Authorization:`Bearer ${actor?.session.access_token ?? process.env.SUPABASE_SERVICE_ROLE_KEY}`,'Content-Type':'application/json','Content-Profile':'api'},body:JSON.stringify(args),signal:AbortSignal.timeout(20000)});
  const value=await response.json();
  if(!response.ok&&!allowFailure)throw new Error(`RPC_${name}_${response.status}_${String(value.code ?? 'rejected')}`);
  return {status:response.status,value};
}
async function app(actor,operation,payload={},key=randomUUID(),allowFailure=false) {
  const response=await actor.context.request.post(`${target.origin}/api/frightnight/command`,{headers:{Origin:target.origin},data:{commandId:key,operation,payload}});
  const value=await response.json();
  if(!response.ok()&&!allowFailure)throw new Error(`APP_${operation}_${response.status()}_${value.error?.code ?? 'rejected'}`);
  return {status:response.status(),value:value.data,error:value.error};
}
async function snapshot(actor) {
  const response=await actor.context.request.get(`${target.origin}/api/frightnight/snapshot`);
  assert(response.ok(),'SNAPSHOT_FAILED');
  const result=(await response.json()).data;
  assert(result.event.slug===slug,'SIGNED_EDITION_CONTEXT_LOST');
  return result;
}
async function select(actor) {
  const response=await actor.context.request.post(`${target.origin}/api/frightnight/edition`,{headers:{Origin:target.origin},data:{slug}});
  assert(response.ok(),'SERVER_EDITION_SELECTION_FAILED');
  assert((await response.json()).data.selected===slug,'SERVER_EDITION_SELECTION_MISMATCH');
  const cookie=(await actor.context.cookies()).find(x=>x.name==='frightnight-edition');
  assert(cookie?.httpOnly&&cookie.secure,'SIGNED_HTTP_ONLY_EDITION_COOKIE_REQUIRED');
}
async function actor(alias) {
  const email=`fn2027-${run}-${alias}@example.invalid`;
  assert(email.endsWith('@example.invalid'),'SYNTHETIC_EMAIL_REQUIRED');
  const password=randomBytes(36).toString('base64url');
  const created=await service.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{display_name:`Acceptatie ${alias}`,synthetic_frightnight_run:run}});
  if(created.error||!created.data.user)throw new Error('SYNTHETIC_AUTH_CREATE_FAILED');
  const record={id:created.data.user.id,alias,email,session:null,context:null};actors.push(record);
  const jar=new Map();
  const ssr=createServerClient(sbUrl,anonKey,{cookies:{getAll:()=>[...jar].map(([name,value])=>({name,value})),setAll:values=>values.forEach(value=>jar.set(value.name,value.value))}});
  const signed=await ssr.auth.signInWithPassword({email,password});
  if(signed.error||!signed.data.session)throw new Error('SYNTHETIC_PASSWORD_SESSION_FAILED');
  record.session=signed.data.session;
  record.context=await browser.newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'});contexts.push(record.context);
  await record.context.addCookies([...jar].map(([name,value])=>({name,value,domain:new URL(target.origin).hostname,path:'/',secure:true,sameSite:'Lax'})));
  let forbidden=0;
  await record.context.route('**/*',async route=>{
    const url=new URL(route.request().url());
    if (/\/auth\/v1\/(otp|magiclink|recover|signup|invite)|\/api\/push\/test|\/api\/mail\//.test(url.pathname)
        || /(^|\.)mollie\.com$/.test(url.hostname)) {forbidden++;await route.abort();return;}
    await route.continue();
  });
  record.forbidden=()=>forbidden;
  return record;
}
async function markSynthetic(actorId) {
  await sql(`update app_private.fn_registrations set synthetic=true where event_id=${literal(eventId)}::uuid and owner_id=${literal(actorId)}::uuid and exists(select 1 from auth.users u where u.id=owner_id and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})`,true);
}
async function checkCapacity() {
  const result=await sql(`select count(*)::integer violations from(select z.id from app_private.fn_zones z join app_private.fn_destinations d on d.event_id=z.event_id and d.zone_id=z.id and d.state='current' where z.event_id=${literal(eventId)}::uuid group by z.id,z.capacity having sum(d.persons)>z.capacity)x`);
  assert(result[0].violations===0,'CAPACITY_OVERSUBSCRIBED');
}
async function fingerprint2026() {
  const result=await sql(`select jsonb_build_object(
    'event',(select md5(coalesce(jsonb_agg(to_jsonb(e) order by e.id)::text,'')) from app_private.events e where e.slug='duindorp-halloween-2026'),
    'registrations',(select md5(coalesce(jsonb_agg(to_jsonb(r) order by r.id)::text,'')) from app_private.registrations r join app_private.events e on e.id=r.event_id where e.slug='duindorp-halloween-2026'),
    'households2026',(select md5(coalesce(jsonb_agg(to_jsonb(h) order by h.id)::text,'')) from app_private.households h where exists(select 1 from app_private.registrations r join app_private.events e on e.id=r.event_id where e.slug='duindorp-halloween-2026' and r.household_id=h.id)),
    'householdIds',(select coalesce(jsonb_agg(id),'[]'::jsonb) from app_private.households),
    'payments',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id)::text,'')) from app_private.payment_requests p),
    'canonicalTest',(select md5(to_jsonb(f)::text) from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug=${literal(target.slug)}),
    'authCount',(select count(*) from auth.users),
    'authIds',(select jsonb_agg(id) from auth.users),
    'legacyOutboxCount',(select count(*) from app_private.email_outbox)
  ) preservation`);
  return result[0].preservation;
}
async function capture(actor,path,name) {
  const page=await actor.context.newPage();
  for(const width of [1440,390]) {
    await page.setViewportSize({width,height:1000});
    await page.goto(`${target.origin}${path}`,{waitUntil:'networkidle'});
    await page.locator('.fn-environment-nav').waitFor();
    await expect(page.locator('.fn-workspace')).toBeVisible();
    assert(!await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),`AUTHENTICATED_OVERFLOW_${name}_${width}`);
    const file=`${name}-${width}.png`;await page.screenshot({path:join(directory,file),fullPage:true});report.screenshots.push(file);
  }
  await page.close();
}
try {
  const healthResponse=await fetch(`${target.origin}/api/health`,{signal:AbortSignal.timeout(10000)});
  const health=await healthResponse.json();
  assert(healthResponse.ok,'LIVE_RELEASE_HEALTH_UNAVAILABLE');
  assertFrightnightHostedContract(health,process.env.GITHUB_SHA);
  const safety=await sql(FRIGHTNIGHT_SAFETY_SQL);assertFrightnightSafety(safety[0].frightnight_safety);
  const before=await fingerprint2026();preservationBefore=before;
  browser=await chromium.launch();
  const admin=await actor('regie');fixtureAdmin=admin;
  const a=await actor('gezin-a');
  const b=await actor('gezin-b');
  const resident=await actor('bewoner');
  const support=await actor('support');
  // Grant only the new actor one temporary 2027 capability so the real bootstrap
  // can create a sibling. Existing capabilities and real users are never copied.
  await sql(`insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
    select f.event_id,${literal(admin.id)}::uuid,'event_admin',${literal(admin.id)}::uuid from app_private.fn_events f join app_private.events e on e.id=f.event_id
    where e.slug=${literal(target.slug)} and f.environment='staging' and f.is_test and exists(select 1 from auth.users u where u.id=${literal(admin.id)}::uuid and u.email=${literal(admin.email)} and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})`,true);
  bootstrapAttempted=true;
  const boot=await rpc(null,'frightnight_bootstrap',{p_slug:slug,p_actor:admin.id,p_environment:'staging',p_confirmation:`${target.projectRef}:staging:duindorphalloweenstg`});
  eventId=boot.value.eventId;assert(/^[0-9a-f-]{36}$/.test(eventId),'SIBLING_EVENT_ID_REQUIRED');
  await sql(`update app_private.event_capabilities set revoked_at=now() where event_id=(select id from app_private.events where slug=${literal(target.slug)}) and user_id=${literal(admin.id)}::uuid and capability='event_admin';
    insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) values(${literal(eventId)}::uuid,${literal(support.id)}::uuid,'live_support',${literal(admin.id)}::uuid)`,true);
  await select(admin);await select(support);
  const seed=await app(admin,'test.seed');
  const startCode=seed.value.result.startCode;
  const codes=new Map(seed.value.result.zoneCodes.map(z=>[z.zoneId,z.code]));
  await app(admin,'test.walk.fixture');
  const seedAgain=await app(admin,'test.seed',{},randomUUID(),true);assert(seedAgain.status===409,'DUPLICATE_SEED_NOT_REJECTED');
  for(const [person,adults,children,intensity] of [[a,2,2,2],[b,1,2,1]]) {
    await rpc(person,'frightnight_command',{p_slug:slug,p_command:'registration.save',p_payload:{label:`Synthetisch ${person.alias}`,routeType:'lantern',adults,children,consent:true,termsVersion:'2027-test-v1',maxIntensity:intensity,avoidSmoke:true,avoidStrobes:true,stepFree:true,startSlot:'2027-10-30T15:00:00Z'},p_key:randomUUID()});
    await markSynthetic(person.id);await select(person);
    const own=await snapshot(person);assert(own.registration.amountCents===(adults+children)*350,'SERVER_PRICE_MISMATCH');
  }
  await rpc(resident,'frightnight_command',{p_slug:slug,p_command:'zone.apply',p_payload:{name:`Acceptatiezone ${run}`,address:'Duinpad · synthetische acceptatielocatie',type:'candy',intensity:0,capacity:8,opensAt:'2027-10-30T15:00:00Z',closesAt:'2027-10-30T19:00:00Z',stepFree:true,description:'Uitsluitend synthetisch decor voor deze geïsoleerde proef.'},p_key:randomUUID()});
  await select(resident);
  let ownZone=(await snapshot(resident)).ownZones[0];
  assert((await app(admin,'admin.zone.review',{zoneId:ownZone.id,decision:'approved'},randomUUID(),true)).status===409,'UNCONFIRMED_RESIDENT_ZONE_APPROVED');
  await app(resident,'zone.confirm',{zoneId:ownZone.id,expectedVersion:ownZone.version,confirmed:true});
  ownZone=(await snapshot(resident)).ownZones[0];
  await app(resident,'zone.location.confirm',{zoneId:ownZone.id,expectedVersion:ownZone.version,confirmed:true,latitude:52.095,longitude:4.26});
  ownZone=(await snapshot(resident)).ownZones[0];
  await sql(`update app_private.fn_zones set synthetic=true where event_id=${literal(eventId)}::uuid and id=${literal(ownZone.id)}::uuid and owner_id=${literal(resident.id)}::uuid`,true);
  checked('new confirmed synthetic Auth sessions and signed sibling context',{actors:5});
  const forbidden=await app(a,'admin.settings',{expectedVersion:1,paused:true},randomUUID(),true);assert(forbidden.status===403,'FAMILY_ADMIN_AUTHORIZATION_FAILED');
  assert((await app(support,'test.seed',{},randomUUID(),true)).status===403,'LIMITED_ROLE_ESCALATED');
  assert((await app(a,'zone.status',{zoneId:ownZone.id,status:'open',expectedVersion:ownZone.version},randomUUID(),true)).status===403,'FOREIGN_HOUSE_AUTHORIZATION_FAILED');
  const cross=await a.context.request.post(`${target.origin}/api/frightnight/edition`,{headers:{Origin:target.origin},data:{slug:target.slug}});assert(cross.status()===403,'CROSS_EDITION_SELECTION_ALLOWED');
  checked('family, house, limited-role and cross-edition authorization');
  // Real HTTP checkout, failure/retry, cancellation/expiry and idempotent
  // provider confirmation all run through the configured contract adapter.
  for(const person of [a,b]) {
    const checkout=await app(person,'payment.checkout');assert(checkout.value.result.provider==='contract'&&checkout.value.result.simulated===true,'EXTERNAL_CHECKOUT_NOT_ALLOWED');
    const reg=(await snapshot(person)).registration;
    await app(admin,'test.payment',{registrationId:reg.id,status:person===a?'failed':'expired',scenario:'normal'});
    await app(person,'payment.checkout');
    await app(admin,'test.payment',{registrationId:reg.id,status:'paid',scenario:'duplicate'});
    await app(person,'payment.reconcile');
    assert((await snapshot(person)).registration.paymentStatus==='paid','CONFIRMED_PAYMENT_NOT_VISIBLE');
  }
  checked('contract checkout, failed/expired retry, duplicate confirmation and reconciliation');
  const captured=await admin.context.request.get(`${target.origin}/api/frightnight/admin/list?resource=sink&cursor=0&limit=50`);
  assert(captured.ok(),'MAIL_CAPTURE_LIST_FAILED');
  const captureRows=(await captured.json()).data.items;
  const captureRow=captureRows.find(row=>row.template==='frightnight-payment-confirmed'&&row.payload?.brandVersion===7);
  assert(captureRow?.id,'PAYMENT_MAIL_CAPTURE_MISSING');
  const previewMail=await admin.context.request.get(`${target.origin}/api/frightnight/mail-preview?id=${captureRow.id}&cursor=0`);
  assert(previewMail.ok()&&previewMail.headers()['cache-control']==='private, no-store'&&previewMail.headers()['content-security-policy'].includes("default-src 'none'"),'MAIL_CAPTURE_PREVIEW_BOUNDARY_FAILED');
  const previewHtml=await previewMail.text();
  assert(previewHtml.includes('NIET VERZONDEN')&&previewHtml.includes('De Pompoenkoning')&&previewHtml.includes('data:image/webp;base64,'),'MAIL_CAPTURE_BRANDING_FAILED');
  assert((await a.context.request.get(`${target.origin}/api/frightnight/mail-preview?id=${captureRow.id}`)).status()===403,'PARTICIPANT_MAIL_CAPTURE_EXPOSED');
  checked('real branded private mail capture preview without delivery');
  await app(admin,'test.clock',{time:'2027-10-30T11:00:00Z'});
  const activity=(await snapshot(a)).activities[0];
  await app(a,'activity.book',{activityId:activity.id});await app(a,'activity.cancel',{activityId:activity.id});
  await app(admin,'test.clock',{time:'2027-10-30T15:05:00Z'});
  for(const [questId,answer] of [['riddle-1','kroon'],['riddle-2','lichtbaken'],['riddle-3','kraaienbode'],['game-1','kroon|veer|lantaarn|maan'],['game-2','amber|groen|wit'],['game-3','kroon:kroon|veer:veer|lantaarn:lantaarn']])await app(a,'quest.answer',{questId,answer});
  checked('activity booking/cancellation and six durable quests');
  await app(admin,'admin.zone.review',{zoneId:ownZone.id,decision:'approved'});ownZone=(await snapshot(resident)).ownZones[0];
  await app(resident,'zone.status',{zoneId:ownZone.id,status:'paused',expectedVersion:ownZone.version});
  ownZone=(await snapshot(resident)).ownZones[0];await app(resident,'zone.status',{zoneId:ownZone.id,status:'closed',expectedVersion:ownZone.version});
  const photo=await resident.context.request.post(`${target.origin}/api/frightnight/zone-photo`,{headers:{Origin:target.origin},multipart:{zoneId:ownZone.id,expectedVersion:String((await snapshot(resident)).ownZones[0].version),commandId:randomUUID(),photo:{name:'synthetisch-zonebeeld.webp',mimeType:'image/webp',buffer:await readFile('public/frightnight/zone-garden.webp')}}});
  assert(photo.ok(),'OWN_ZONE_PHOTO_UPLOAD_FAILED');
  const savedPhoto=(await photo.json()).data.snapshot.ownZones.find(z=>z.id===ownZone.id).photoPath;
  assert(savedPhoto,'PHOTO_PATH_NOT_PERSISTED');
  const foreignStorage=createClient(sbUrl,anonKey,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:`Bearer ${a.session.access_token}`}}});
  const forbiddenStorage=await foreignStorage.storage.from('frightnight-zone-photos').download(savedPhoto);
  assert(forbiddenStorage.error&&!forbiddenStorage.data,'STORAGE_RLS_FOREIGN_PHOTO_EXPOSED');
  const foreignPhoto=await a.context.request.get(`${target.origin}/api/frightnight/zone-photo?zoneId=${ownZone.id}`);assert([403,404].includes(foreignPhoto.status()),'FOREIGN_ZONE_PHOTO_EXPOSED');
  const print=await resident.context.request.get(`${target.origin}/api/frightnight/qr?zoneId=${ownZone.id}`);assert(print.ok()&&(await print.text()).includes('<svg'),'PRINTABLE_QR_FAILED');
  checked('resident review, status, private photo and real printable QR');
  const adminState=await snapshot(admin);const candy=adminState.zones.find(z=>z.type==='candy'&&z.id!==ownZone.id);
  await app(admin,'zone.profile',{zoneId:candy.id,name:candy.name,description:candy.description,capacity:4,opensAt:candy.opensAt,closesAt:candy.closesAt,expectedVersion:candy.version});
  const sb=await snapshot(b);
  const scanPage=await a.context.newPage();await scanPage.goto(`${target.origin}/nachtpas`);
  const startButton=scanPage.getByRole('button',{name:'Scan de start-QR',exact:true});await startButton.waitFor();
  await a.context.setOffline(true);await expect(startButton).toBeDisabled();
  await a.context.setOffline(false);await expect(startButton).toBeEnabled();
  await startButton.click();await scanPage.getByLabel('Of voer de code van het bord in').fill(startCode);
  const uiStart=async()=>{
    const result=scanPage.waitForResponse(response=>new URL(response.url()).pathname==='/api/frightnight/command'&&response.request().postDataJSON()?.operation==='journey.start');
    await scanPage.getByRole('button',{name:'Controleer code',exact:true}).click();
    assert((await result).ok(),'MANUAL_QR_UI_START_FAILED');return {status:200};
  };
  const starts=await Promise.all([uiStart(),app(b,'journey.start',{code:startCode,expectedVersion:sb.journey.version})]);
  assert(starts.every(x=>x.status===200),'CONCURRENT_START_FAILED');await checkCapacity();
  const [da,db]=await Promise.all([snapshot(a),snapshot(b)]);assert(da.current&&db.current&&da.current.zoneId!==db.current.zoneId,'CAPACITY_DID_NOT_SPREAD_FAMILIES');
  checked('two simultaneous authenticated start scans and atomic capacity');
  const key=randomUUID();const payload={code:codes.get(da.current.zoneId),destinationId:da.current.id,expectedVersion:da.journey.version};
  const secondTab=await a.context.newPage();await secondTab.goto(`${target.origin}/nachtpas`);await secondTab.locator('.fn-environment-nav').waitFor();
  const inTab=async page=>page.evaluate(async input=>{
    const response=await fetch('/api/frightnight/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(input)});
    const value=await response.json();return {status:response.status,value:value.data};
  },{commandId:key,operation:'journey.complete',payload});
  const repeats=await Promise.all([inTab(scanPage),inTab(secondTab)]);
  assert(repeats.every(x=>x.status===200),'MULTI_TAB_REPLAY_FAILED');
  assert(JSON.stringify(repeats[0].value.result)===JSON.stringify(repeats[1].value.result),'IDEMPOTENT_SCAN_RESULT_CHANGED');
  let nowA=await snapshot(a);assert(nowA.progress.visits.filter(v=>v.zoneId===da.current.zoneId).length===1,'SCAN_REPLAY_DOUBLE_REWARD');
  assert((await app(a,'journey.complete',payload,randomUUID(),true)).status===409,'STALE_SCAN_NOT_REJECTED');
  await scanPage.close();await secondTab.close();
  await app(b,'journey.complete',{code:codes.get(db.current.zoneId),destinationId:db.current.id,expectedVersion:db.journey.version});await checkCapacity();
  checked('multi-tab identical scan replay and stale-version rejection');
  const contactName=`Acceptatiecontact ${run}`;const contactPhone='0000002027';
  const contactPage=await a.context.newPage();await contactPage.goto(`${target.origin}/nachtpas`);await contactPage.locator('.fn-environment-nav').waitFor();
  await contactPage.getByRole('button',{name:'Gegevens',exact:true}).click();
  await contactPage.getByLabel('Naam contactpersoon',{exact:true}).fill(contactName);
  await contactPage.getByLabel('Telefoon (optioneel)',{exact:true}).fill(contactPhone);
  const contactSaved=contactPage.waitForResponse(response=>new URL(response.url()).pathname==='/api/frightnight/command'&&response.request().postDataJSON()?.operation==='contact.save');
  await contactPage.getByRole('button',{name:'Contactgegevens bewaren',exact:true}).click();assert((await contactSaved).ok(),'OWNER_CONTACT_UI_SAVE_FAILED');
  const contactState=await snapshot(a);assert(contactState.registration.contactName===contactName&&contactState.registration.contactPhone===contactPhone,'OWNER_CONTACT_NOT_DURABLE');
  const contactTab=await a.context.newPage();await contactTab.goto(`${target.origin}/nachtpas`);await contactTab.locator('.fn-environment-nav').waitFor();await contactTab.getByRole('button',{name:'Gegevens',exact:true}).click();
  await expect(contactTab.getByLabel('Naam contactpersoon',{exact:true})).toHaveValue(contactName);await expect(contactTab.getByLabel('Telefoon (optioneel)',{exact:true})).toHaveValue(contactPhone);
  const foreignContact=await app(b,'contact.save',{registrationId:contactState.registration.id,expectedVersion:contactState.registration.version,contactName:'Afgewezen vreemde actor',contactPhone:'0000000000'},randomUUID(),true);
  assert(foreignContact.status===403,'FOREIGN_REGISTRATION_CONTACT_WRITE_ALLOWED');
  const afterForeignContact=await snapshot(a);assert(afterForeignContact.registration.contactName===contactName&&afterForeignContact.registration.contactPhone===contactPhone,'FOREIGN_CONTACT_CHANGED_OWNER_DATA');
  const adminContactState=await snapshot(admin);assert((adminContactState.registrations??[]).every(row=>!Object.hasOwn(row,'contactName')&&!Object.hasOwn(row,'contactPhone')),'CONTACT_EXPOSED_IN_SHARED_ADMIN_DTO');
  const svgResponse=await a.context.request.get(`${target.origin}/api/frightnight/pass`);const svg=await svgResponse.text();
  assert(svgResponse.ok()&&svgResponse.headers()['content-type']?.startsWith('image/svg+xml')&&svgResponse.headers()['cache-control']==='private, no-store'&&/<svg\b/.test(svg)&&svg.includes(contactState.registration.label)&&svg.includes('data:image/png;base64,'),'PERSONAL_SVG_PASS_CONTRACT_FAILED');
  const downloadClockValid=body=>body.includes('werkelijke tijd')&&body.includes('Editieklok:')&&Math.abs(Date.now()-Date.parse(body.match(/Gedownload(?: op|:) ([0-9TZ:.+-]+)/)?.[1]??''))<120000;
  assert(downloadClockValid(svg),'SVG_REAL_DOWNLOAD_CLOCK_NOT_DISTINCT_FROM_EDITION_CLOCK');
  const privateAddress=contactState.current?.zone.address;
  assert(!svg.includes(contactPhone)&&!svg.includes(contactName)&&!svg.includes(startCode)&&![...codes.values()].some(code=>svg.includes(code))&&(!privateAddress||privateAddress==='Duinpad'||!svg.includes(privateAddress)),'PERSONAL_SVG_PASS_PRIVATE_DATA_LEAK');
  const htmlPass=await a.context.request.get(`${target.origin}/api/frightnight/pass?format=html`);
  const htmlPassBody=await htmlPass.text();assert(htmlPass.ok()&&htmlPass.headers()['content-type']?.startsWith('text/html')&&htmlPassBody.includes(contactState.registration.label)&&downloadClockValid(htmlPassBody),'PRINTABLE_HTML_PASS_ALTERNATIVE_FAILED');
  await contactPage.close();await contactTab.close();
  checked('owner contact UI, durable second tab, cross-household denial and private standalone SVG/HTML pass');
  const invite=await app(a,'party.invite');await app(b,'party.join',{token:invite.value.result.token,consent:true});
  nowA=await snapshot(a);let nowB=await snapshot(b);
  assert(nowA.journey.id===nowB.journey.id&&nowA.journey.party.persons===7&&nowA.journey.party.maxIntensity===1,'SHARED_PARTY_PREFERENCES_MISMATCH');
  assert(!nowA.current||nowA.current.zone.type==='candy'||nowA.current.zone.type==='finale'||nowA.current.zone.intensity<=1,'SHARED_INTENSITY_TOO_HIGH');
  await app(b,'party.leave');assert((await snapshot(a)).journey.id!==(await snapshot(b)).journey.id,'PARTY_LEAVE_FAILED');
  checked('consented shared route, combined comfort and transactional leaving');
  nowA=await snapshot(a);await app(a,'journey.pause',{expectedVersion:nowA.journey.version});nowA=await snapshot(a);
  await app(a,'journey.resume',{expectedVersion:nowA.journey.version});
  const state=await snapshot(admin);await app(admin,'admin.settings',{paused:true,expectedVersion:state.event.version});
  nowA=await snapshot(a);assert((await app(a,'journey.resume',{expectedVersion:nowA.journey.version},randomUUID(),true)).status===409,'GLOBAL_PAUSE_NOT_ENFORCED');
  const paused=await snapshot(admin);await app(admin,'admin.settings',{paused:false,expectedVersion:paused.event.version});
  await app(admin,'test.clock',{time:'2027-10-30T16:30:00Z'});
  nowA=await snapshot(a);await app(a,'journey.finish',{expectedVersion:nowA.journey.version});nowA=await snapshot(a);
  assert(nowA.current.zone.type==='finale'&&nowA.current.zone.address==='Duinpad','DUINPAD_FINALE_MISSING');
  await app(a,'journey.complete',{code:codes.get(nowA.current.zoneId),destinationId:nowA.current.id,expectedVersion:nowA.journey.version});
  await app(a,'beacon.complete');assert((await snapshot(a)).journey.state==='finished','FINALE_NOT_PERSISTED');
  checked('pause/resume, global pause, time boundary and final Duinpad scan');
  const pass=await a.context.request.get(`${target.origin}/api/frightnight/pass`);assert(pass.ok()&&(await pass.text()).includes('Synthetisch gezin-a'),'PERSONAL_PASS_DOWNLOAD_FAILED');
  const emergency=await a.context.request.get(`${target.origin}/api/frightnight/emergency`);const emergencyHtml=await emergency.text();assert(emergency.ok()&&emergencyHtml.includes('lokaal'),'EMERGENCY_PACKAGE_FAILED');
  assert(downloadClockValid(emergencyHtml),'EMERGENCY_REAL_DOWNLOAD_CLOCK_NOT_DISTINCT_FROM_EDITION_CLOCK');
  const operationalState=await snapshot(admin);const approvedZones=operationalState.zones.filter(zone=>zone.reviewStatus==='approved'&&zone.type!=='finale');
  assert(approvedZones.length>0,'APPROVED_OPERATIONAL_ZONE_FIXTURE_REQUIRED');
  const operationalEmergency=await admin.context.request.get(`${target.origin}/api/frightnight/emergency`);const operationalHtml=await operationalEmergency.text();
  assert(operationalEmergency.ok()&&operationalEmergency.headers()['cache-control']==='private, no-store'&&operationalHtml.includes('zonekaartjes voor de avondpost')&&operationalHtml.includes(approvedZones[0].name)&&operationalHtml.includes(approvedZones[0].address)&&operationalHtml.includes('Bevestigd om:')&&operationalHtml.includes('Capaciteit:')&&operationalHtml.includes('Europe/Amsterdam'),'OPERATIONAL_EMERGENCY_ZONE_CARDS_MISSING');
  assert(!emergencyHtml.includes('zonekaartjes voor de avondpost')&&approvedZones.every(zone=>!emergencyHtml.includes(zone.address)),'PARTICIPANT_EMERGENCY_FUTURE_ADDRESS_LEAK');
  checked('pre-downloadable operational approved-zone cards and participant future-address privacy');
  for(const [person,path,name] of [[a,'/nachtpas','participant'],[resident,'/mijn-zone','resident'],[admin,'/avondregie','operations'],[admin,'/testcentrum','test-center']])await capture(person,path,name);
  checked('complete authenticated mobile/desktop screens and personal downloads');
  await runRegieAcceptance({base:target.origin,slug,eventId,run,admin,a,b,resident,support,sql,app,assert,checked,literal,report,directory});
  await app(admin,'payment.refund',{registrationId:(await snapshot(a)).registration.id,reason:'Gecontroleerde contractterugbetaling van eigen synthetische acceptatie'});
  assert((await snapshot(a)).registration.paymentStatus==='refunded','CONTRACT_REFUND_FAILED');
  const preview=await app(admin,'test.reset.preview');assert(preview.value.result.slug===slug&&preview.value.result.syntheticRegistrations>=6,'RESET_PREVIEW_SCOPE_MISSING');
  const oldRun=preview.value.result.runId;await app(admin,'test.reset',{confirmation:slug,runId:oldRun});
  assert((await app(admin,'test.reset',{confirmation:slug,runId:oldRun},randomUUID(),true)).status===403,'STALE_RESET_SCOPE_ACCEPTED');
  await app(admin,'test.seed');
  assert((await snapshot(admin)).event.runId!==oldRun,'RESET_DID_NOT_ISOLATE_RUN');
  const final=await fingerprint2026();
  assert(final.event===before.event&&final.registrations===before.registrations&&final.households2026===before.households2026&&final.payments===before.payments&&final.canonicalTest===before.canonicalTest,'HISTORICAL_OR_CANONICAL_EVENT_ROWS_CHANGED');
  assert(Number(final.authCount)>=Number(before.authCount)+actors.length,'AUTH_IDENTITIES_NOT_PRESERVED');
  assert(before.authIds.every(id=>final.authIds.includes(id)),'HISTORICAL_AUTH_IDENTITY_REMOVED');
  assert(final.legacyOutboxCount===before.legacyOutboxCount,'UNEXPECTED_LEGACY_OUTBOX_ROWS');
  const mail=await sql(`select count(*)::integer unintended from app_private.email_outbox where recipient_email in(${actors.map(x=>literal(x.email)).join(',')})`);
  assert(mail[0].unintended===0&&actors.every(x=>x.forbidden()===0),'LEGACY_MAIL_OR_EXTERNAL_DELIVERY_ATTEMPT');
  checked('refund, scoped reset/reseed, 2026 preservation and zero fixture legacy mail');
} catch(error) {
  failed=error;report.failure=safeError(error);
} finally {
  const cleanupErrors=[];
  if(eventId) {
    try {
      assert(slug!==target.slug&&slug.startsWith('frightnight-2027-test-acceptance-'),'SIBLING_CLEANUP_CANONICAL_FORBIDDEN');
      assert(fixtureAdmin?.session&&fixtureAdmin.email.endsWith('@example.invalid'),'SIBLING_CLEANUP_REAL_ACTOR_REQUIRED');
      assert(Array.isArray(preservationBefore?.householdIds),'SIBLING_CLEANUP_HOUSEHOLD_BASELINE_REQUIRED');
      const ownActors=actors.map(person=>literal(person.id)+'::uuid').join(',');
      const householdScope=`(r.household_id is null or exists(select 1 from app_private.households h where h.id=r.household_id and h.primary_contact_user_id=r.owner_id and not(${literal(JSON.stringify(preservationBefore.householdIds))}::jsonb ? h.id::text) and exists(select 1 from app_private.household_members hm where hm.household_id=h.id and hm.user_id=r.owner_id and hm.revoked_at is null) and not exists(select 1 from app_private.household_members hm where hm.household_id=h.id and hm.revoked_at is null and (hm.user_id not in(${ownActors}) or not exists(select 1 from auth.users u where u.id=hm.user_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})))))`;
      const binding=await sql(`select f.run_id,
        exists(select 1 from auth.users u join app_private.event_capabilities c on c.user_id=u.id and c.event_id=f.event_id and c.capability='event_admin' and c.revoked_at is null where u.id=${literal(fixtureAdmin.id)}::uuid and u.email=${literal(fixtureAdmin.email)} and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}) actor_ok,
        (select count(*)::integer from app_private.fn_registrations r where r.event_id=f.event_id and (not ${householdScope} or (r.owner_id is not null and (r.owner_id not in(${ownActors}) or not exists(select 1 from auth.users u where u.id=r.owner_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}))))) foreign_records
        from app_private.fn_events f join app_private.events e on e.id=f.event_id where f.event_id=${literal(eventId)}::uuid and e.slug=${literal(slug)} and f.environment='staging' and f.is_test`);
      assert(binding.length===1&&binding[0].actor_ok===true&&Number(binding[0].foreign_records)===0&&/^[0-9a-f-]{36}$/.test(binding[0].run_id),'SIBLING_CLEANUP_SCOPE_NOT_PROVEN');
      const currentRun=binding[0].run_id;
      // Only newly created own .invalid actors in this exact event/run can be
      // marked synthetic after an early UI/setup failure. A linked household
      // must be new since the baseline and owned/membered only by this run.
      await sql(`update app_private.fn_registrations r set synthetic=true where r.event_id=${literal(eventId)}::uuid and r.run_id=${literal(currentRun)}::uuid and not r.synthetic and r.owner_id in(${ownActors}) and ${householdScope} and exists(select 1 from auth.users u where u.id=r.owner_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)})`,true);
      const financial=await sql(`select (select md5(coalesce(jsonb_agg(to_jsonb(o) order by o.id)::text,'')) from app_private.fn_orders o where o.event_id=${literal(eventId)}::uuid) orders,(select md5(coalesce(jsonb_agg(to_jsonb(l) order by l.id)::text,'')) from app_private.fn_ledger l where l.event_id=${literal(eventId)}::uuid) ledger,(select count(*)::integer from app_private.fn_audit where event_id=${literal(eventId)}::uuid) audit_count`);
      const reset=await rpc(fixtureAdmin,'frightnight_command',{p_slug:slug,p_command:'test.reset',p_payload:{confirmation:slug,runId:currentRun},p_key:randomUUID()});
      const resetEvent=reset.value.snapshot?.event;assert(resetEvent?.slug===slug&&resetEvent.runId!==currentRun,'SIBLING_CLEANUP_RESET_NOT_CONFIRMED');
      const closed=await rpc(fixtureAdmin,'frightnight_command',{p_slug:slug,p_command:'admin.settings',p_payload:{closed:true,expectedVersion:resetEvent.version,confirmation:slug,reason:'Eigen synthetische hosted acceptatie afgerond; scenario archiveren met behoud van historie'},p_key:randomUUID()});
      assert(closed.value.snapshot?.event.closed===true,'SIBLING_CLEANUP_CLOSE_NOT_CONFIRMED');
      const afterFinancial=await sql(`select (select md5(coalesce(jsonb_agg(to_jsonb(o) order by o.id)::text,'')) from app_private.fn_orders o where o.event_id=${literal(eventId)}::uuid) orders,(select md5(coalesce(jsonb_agg(to_jsonb(l) order by l.id)::text,'')) from app_private.fn_ledger l where l.event_id=${literal(eventId)}::uuid) ledger,(select count(*)::integer from app_private.fn_audit where event_id=${literal(eventId)}::uuid) audit_count`);
      assert(financial[0].orders===afterFinancial[0].orders&&financial[0].ledger===afterFinancial[0].ledger&&Number(afterFinancial[0].audit_count)>=Number(financial[0].audit_count),'SIBLING_CLEANUP_FINANCIAL_HISTORY_CHANGED');
      const preserved=await fingerprint2026();assert(preservationBefore&&preserved.event===preservationBefore.event&&preserved.registrations===preservationBefore.registrations&&preserved.households2026===preservationBefore.households2026&&preserved.payments===preservationBefore.payments&&preserved.canonicalTest===preservationBefore.canonicalTest&&preserved.legacyOutboxCount===preservationBefore.legacyOutboxCount&&preservationBefore.authIds.every(id=>preserved.authIds.includes(id))&&preservationBefore.householdIds.every(id=>preserved.householdIds.includes(id)),'SIBLING_CLEANUP_HISTORICAL_PRESERVATION_FAILED');
      report.editionCleanup={scopeVerified:true,ownRunArchived:true,siblingClosed:true,ordersPreserved:true,ledgerPreserved:true,auditPreserved:true,historical2026Preserved:true,legacyOutboxUnchanged:true,authDeleted:0};
    } catch(error) {cleanupErrors.push(safeError(error));report.editionCleanup={scope:'own-captured-sibling-only',status:'failed',blindReset:false};}
  } else if(bootstrapAttempted) {
    cleanupErrors.push('SIBLING_BOOTSTRAP_OUTCOME_UNCERTAIN');report.editionCleanup={status:'failed',blindReset:false};
  }
  for(const context of contexts)await context.close().catch(()=>{});
  if(browser)await browser.close().catch(()=>{});
  // Revoke only new fixture capabilities and retire only these newly created
  // synthetic identities. Auth users and all audit/financial history remain.
  if(actors.length) {
    let retiredActors=0;
    try {
      const scopes=[];
      if(eventId)scopes.push(`(e.id=${literal(eventId)}::uuid and e.slug=${literal(slug)})`);
      const regie=report.regieAcceptance;
      if(regie?.eventId&&regie.edition?.startsWith(slug+'-regie-'))scopes.push(`(e.id=${literal(regie.eventId)}::uuid and e.slug=${literal(regie.edition)})`);
      if(fixtureAdmin)scopes.push(`(e.slug=${literal(target.slug)} and c.user_id=${literal(fixtureAdmin.id)}::uuid and c.capability='event_admin' and c.granted_by=${literal(fixtureAdmin.id)}::uuid)`);
      if(scopes.length)await sql(`update app_private.event_capabilities c set revoked_at=now() where c.revoked_at is null and c.user_id in(${actors.map(x=>literal(x.id)+'::uuid').join(',')}) and exists(select 1 from auth.users u where u.id=c.user_id and u.email like '%@example.invalid' and u.raw_user_meta_data->>'synthetic_frightnight_run'=${literal(run)}) and exists(select 1 from app_private.fn_events f join app_private.events e on e.id=f.event_id where f.event_id=c.event_id and f.environment='staging' and f.is_test and (${scopes.join(' or ')}))`,true);
    } catch {cleanupErrors.push('SYNTHETIC_CAPABILITY_REVOKE_FAILED');}
    for(const person of actors) {
      try {
        if(person.session) {
          const signedOut=await service.auth.admin.signOut(person.session.access_token,'global');
          assert(!signedOut.error,'SYNTHETIC_SESSION_SIGNOUT_FAILED');
        }
        const retired=await service.auth.admin.updateUserById(person.id,{ban_duration:'8760h'});
        assert(!retired.error,'SYNTHETIC_AUTH_RETIRE_FAILED');
        retiredActors++;
      } catch(error) {cleanupErrors.push(safeError(error));}
    }
    report.fixtureCleanup={capabilitiesRevoked:!cleanupErrors.includes('SYNTHETIC_CAPABILITY_REVOKE_FAILED'),syntheticAccountsRetired:retiredActors,authDeleted:0,historyDeleted:0};
  }
  if(cleanupErrors.length){report.cleanupFailure=cleanupErrors.join(';');failed??=new Error('SYNTHETIC_FIXTURE_CLEANUP_INCOMPLETE');}
  report.completedAt=new Date().toISOString();report.status=failed?'failed':'passed';
  // Only a digest of the non-secret report is printed; credential-bearing
  // storageState, traces, HAR and raw provider/SQL responses are never saved.
  const encoded=JSON.stringify(report,null,2)+'\n';await writeFile(join(directory,'report.json'),encoded,{mode:0o600});
  console.log(JSON.stringify({frightnightHostedAcceptance:report.status,revision:report.revision,checks:report.checks.length,reportSha256:createHash('sha256').update(encoded).digest('hex')}));
}
if(failed)throw new Error(`FRIGHTNIGHT_HOSTED_ACCEPTANCE_FAILED: ${report.failure ?? report.cleanupFailure}`);
