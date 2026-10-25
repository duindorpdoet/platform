import {test,expect,type BrowserContext} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {mkdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {syntheticPushMaterial} from '../../scripts/acceptance/push-fixtures.mjs';
import {prepareFixtureGuidance,selectOrganizationSection} from './helpers/guidance';
import {assertReadableLayout} from './helpers/layout';

const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const event='duindorp-halloween-2026',groupId='23000000-0000-0000-0000-000000000001';
function cookies(session:unknown){
 const name=`sb-${new URL(url!).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`;
 return Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:'http://127.0.0.1:3100',sameSite:'Lax' as const}));
}
async function login(context:BrowserContext,email='admin@example.invalid',password='local-test-only'){
 const client=createClient(url!,key!,{auth:{persistSession:false,autoRefreshToken:false}});
 const result=await client.auth.signInWithPassword({email,password});expect(result.error).toBeNull();
 await prepareFixtureGuidance(client);await context.addCookies(cookies(result.data.session));return client;
}
test.beforeEach(()=>test.skip(!url||!key,'Requires isolated real Auth and database'));
test('real Startregie concepts, confirmation, private route and publication persist across devices',async({page,context})=>{
 test.setTimeout(90_000);
 const client=await login(context);
 async function snapshot(){const result=await client.schema('api').rpc('admin_startregie_snapshot',{_event_slug:event});expect(result.error).toBeNull();return result.data;}
 let before=await snapshot();
 const configured=await client.schema('api').rpc('admin_startregie_settings_save',{_event_slug:event,_settings:{...before.settings,plannerMode:'dynamic',firstStartAt:'2026-10-31T15:00:00Z',globalOrdinaryStopAt:'2026-10-31T19:30:00Z',finalPortalId:'12000000-0000-0000-0000-000000000030',finaleOpensAt:'2026-10-31T18:00:00Z',finaleLastArrivalAt:'2026-10-31T20:30:00Z',finaleClosesAt:'2026-10-31T21:00:00Z',finaleMaxGroups:10,finaleMaxChildren:100,finaleAvailable:true},_expected_version:before.settings.version,_reason:'Isolated browser acceptance of the complete publication flow'});expect(configured.error).toBeNull();
 await page.setViewportSize({width:1348,height:926});await page.goto('/admin');await selectOrganizationSection(page,'Startregie');
 await expect(page.getByRole('heading',{name:'Iedere groep een goede start.'})).toBeVisible();
 await page.locator('.start-ops-point-shortcuts summary').click();
 const pointCard=page.locator('.start-ops-point-checks article').first();
 await expect(pointCard.getByRole('textbox')).toHaveCount(0);await expect(pointCard.getByRole('checkbox')).toHaveCount(0);
 const confirmation=page.waitForResponse(response=>response.url().includes('/rpc/admin_startregie_confirm_point'));
 await pointCard.getByRole('button',{name:'Startpunt bevestigen'}).click();expect((await confirmation).ok()).toBe(true);
 await expect(pointCard).toContainText('Startpunt: ja');await expect(pointCard).not.toContainText('75 meter');
 before=await snapshot();const group=before.groups.find((item:{id:string})=>item.id===groupId),point=before.startPoints[0];
 const card=page.locator('.start-ops-assignment').filter({has:page.getByText(group.systemCode,{exact:true})});
 await card.getByRole('combobox',{name:`Startpunt voor ${group.systemCode}`}).selectOption(point.id);
 await card.getByRole('combobox',{name:`Starttijd voor ${group.systemCode}`}).selectOption({label:'17:30 uur'});
 await card.getByRole('button',{name:'Concept opslaan'}).click();await expect(card).toContainText(/Conceptindeling|Nieuw concept/);
 await expect(card.getByRole('button',{name:'Startafspraken bevestigen en versturen'})).toBeEnabled();
 await card.getByRole('button',{name:'Startafspraken bevestigen en versturen'}).click();
 const publication=page.getByRole('dialog');await expect(publication).toContainText('Adres vanaf 16:30');
 await mkdir('docs/ops/screenshots',{recursive:true});await page.screenshot({path:'docs/ops/screenshots/publication-desktop.png'});
 await publication.getByRole('button',{name:'Startafspraken bevestigen en versturen',exact:true}).click();await expect(publication).not.toBeVisible();await expect(card).toContainText('Starttijd gepubliceerd');
 await card.getByRole('button',{name:'Poortvolgorde controleren'}).click();
 const route=page.getByRole('dialog');await expect(route).toContainText('Privé poortvolgorde');await expect(route.locator('.start-ops-route-stops li')).not.toHaveCount(0);
 await page.screenshot({path:'docs/ops/screenshots/route-desktop.png'});
 await page.keyboard.press('Escape');await expect(route).not.toBeVisible();await expect(card.getByRole('button',{name:'Poortvolgorde controleren'})).toBeFocused();
 await page.reload();await expect(card).toContainText('Starttijd gepubliceerd');
 const parent=createClient(url!,key!,{auth:{persistSession:false,autoRefreshToken:false}});expect((await parent.auth.signInWithPassword({email:'parent-a@example.invalid',password:'local-test-only'})).error).toBeNull();
 const publicSnapshot=await parent.schema('api').rpc('group_snapshot',{_group_id:groupId});expect(publicSnapshot.error).toBeNull();
 expect(publicSnapshot.data.group.start.startsAt).toBe('2026-10-31T16:30:00+00:00');expect(publicSnapshot.data.group.start.address).toBeNull();expect(publicSnapshot.data.group.start.coordinate).toBeNull();expect(publicSnapshot.data.group.start.name).toBe('Startlocatie volgt');
 for(const width of [1348,390,360]){
  await page.setViewportSize({width,height:width===1348?926:844});await assertReadableLayout(page);
  await page.evaluate(()=>{window.scrollTo(0,0);for(const element of document.querySelectorAll<HTMLElement>('*'))if(element.scrollTop>0)element.scrollTo({top:0,behavior:'instant'});});
  await page.screenshot({path:`docs/ops/screenshots/start-${width}.png`});
  await card.getByRole('button',{name:'Poortvolgorde controleren'}).click();await assertReadableLayout(page);await page.screenshot({path:`docs/ops/screenshots/route-${width}.png`});await page.keyboard.press('Escape');
 }
 await page.setViewportSize({width:390,height:844});await selectOrganizationSection(page,'Instellingen');
 const policy=page.locator('.group-size-policy');await expect(policy).toBeVisible();
 for(const value of ['30','45']){await policy.getByRole('spinbutton',{name:'Aantal kinderen per groep',exact:true}).fill(value);await policy.getByRole('textbox',{name:'Reden voor de wijziging'}).fill('Grotere groepen expliciet getest in de lokale browser');await policy.getByRole('button',{name:'Limiet opslaan',exact:true}).click();await expect(policy.getByRole('status')).toContainText(`opgeslagen: ${value}`);await expect(policy.getByRole('spinbutton',{name:'Aantal kinderen per groep',exact:true})).toHaveValue(value);}
 await policy.getByRole('spinbutton',{name:'Aantal kinderen per groep',exact:true}).fill('2');await policy.getByRole('textbox',{name:'Reden voor de wijziging'}).fill('Uitzonderingen beoordelen zonder een bestaande groep te wijzigen');await policy.getByRole('button',{name:'Limiet opslaan',exact:true}).click();await expect(policy.getByRole('region',{name:'Bestaande uitzonderingen'})).toBeVisible();await expect(policy.getByRole('button',{name:'Limiet opslaan',exact:true})).toBeDisabled();await page.screenshot({path:'docs/ops/screenshots/group-policy-impact-390.png'});
 // Leaving this unsaved preview cannot alter the existing groups or the maximum.
 expect((await snapshot()).settings.maxGroupSize).toBe(45);
});

test('push HTTP boundary counts malformed requests, enforces quota and returns metadata only',async({page,context})=>{
 test.skip(!process.env.SUPABASE_SECRET_KEY,'Requires local Auth admin for an isolated account');
 const privileged=createClient(url!,process.env.SUPABASE_SECRET_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});
 const id=randomUUID(),email=`push-browser-${id}@example.invalid`,password=randomUUID();expect((await privileged.auth.admin.createUser({email,password,email_confirm:true})).error).toBeNull();
 await login(context,email,password);await page.goto('/');
 async function post(data:unknown){return page.request.post('/api/push/subscription',{headers:{origin:'http://127.0.0.1:3100'},data});}
 const material=Array.from({length:6},()=>syntheticPushMaterial());
 for(let i=0;i<5;i++){const device=material[i];const result=await post({endpoint:device.endpoint,keys:{p256dh:device.p256dh,auth:device.auth},deviceLabel:`Isolated device ${i}`});expect(result.status(),await result.text()).toBe(201);}
 const device=material[5],sixth=await post({endpoint:device.endpoint,keys:{p256dh:device.p256dh,auth:device.auth}});expect(sixth.status()).toBe(409);
 const update=await post({endpoint:material[0].endpoint,keys:{p256dh:material[0].p256dh,auth:material[0].auth},deviceLabel:'Updated at quota'});expect(update.status()).toBe(201);
 for(let i=0;i<3;i++){const invalid=await page.request.post('/api/push/subscription',{headers:{origin:'http://127.0.0.1:3100','content-type':'application/json'},data:'{'});expect(invalid.status()).toBe(422);}
 const rate=await post({endpoint:material[0].endpoint,keys:{p256dh:material[0].p256dh,auth:material[0].auth}});expect(rate.status()).toBe(429);
 const metadata=await page.request.get('/api/push/subscription');expect(metadata.status()).toBe(200);const text=await metadata.text();for(const entry of material){expect(text).not.toContain(entry.endpoint);expect(text).not.toContain(entry.p256dh);expect(text).not.toContain(entry.auth);}
});

test('mobile point errors remain inside the keyboard-accessible dialog without a write',async({context,page})=>{
 await login(context);await page.setViewportSize({width:360,height:844});await page.goto('/admin');await selectOrganizationSection(page,'Startregie');
 await page.getByRole('tab',{name:'Startpunten',exact:true}).click();const opener=page.getByRole('button',{name:'Startpunt toevoegen',exact:true});await opener.click();
 const dialog=page.getByRole('dialog');await dialog.getByRole('textbox',{name:'Interne naam',exact:true}).fill('Een heel lange fictieve verzamelpleknaam voor de mobiele controle');
 await dialog.getByText('Technische locatiegegevens',{exact:true}).click();await dialog.getByRole('textbox',{name:'Adres-breedtegraad'}).fill('52.1');await dialog.getByRole('textbox',{name:'Adres-lengtegraad'}).fill('4.3');
 await dialog.getByLabel('Beschikbaar vanaf',{exact:true}).fill('2026-03-29T02:30');await dialog.getByLabel('Beschikbaar tot',{exact:true}).fill('2026-03-29T04:00');
 const writes:string[]=[];page.on('request',request=>{if(request.url().includes('/rpc/admin_startregie_start_point_save'))writes.push(request.url());});
 await dialog.getByRole('button',{name:'Startpunt toevoegen',exact:true}).click();await expect(dialog.getByRole('alert')).toContainText('geldige Nederlandse tijd');await expect(dialog.getByLabel('Beschikbaar vanaf',{exact:true})).toHaveValue('2026-03-29T02:30');expect(writes).toHaveLength(0);
 await assertReadableLayout(page);await page.screenshot({path:'docs/ops/screenshots/point-invalid-time-360.png'});
 await dialog.getByRole('button',{name:'Sluiten',exact:true}).focus();await page.keyboard.press('Shift+Tab');await expect(dialog.getByRole('button',{name:'Startpunt toevoegen',exact:true})).toBeFocused();await page.keyboard.press('Escape');await expect(dialog).not.toBeVisible();await expect(opener).toBeFocused();
 await selectOrganizationSection(page,'Push & beveiliging');await expect(page.getByRole('heading',{name:'Meldingen met duidelijke grenzen.',exact:true})).toBeVisible();await assertReadableLayout(page);await page.screenshot({path:'docs/ops/screenshots/push-security-360.png'});
});

test('a start point can be confirmed in one click without an inspection form',async({page,context})=>{
 const client=await login(context),name='Eenvoudig bevestigen '+randomUUID().slice(0,8);
 const created=await client.schema('api').rpc('admin_startregie_start_point_save',{_event_slug:event,_point_id:null,_payload:{name,publicLabel:name,pointType:'gathering',privateAddress:'FICTIEF STARTADRES',geocodedLatitude:52.12,geocodedLongitude:4.29,active:true,maxGroups:1,maxChildren:30},_expected_version:null,_reason:'Isolated one-click start confirmation browser acceptance'});expect(created.error).toBeNull();
 await page.setViewportSize({width:390,height:844});await page.goto('/admin');await selectOrganizationSection(page,'Startregie');await page.getByRole('tab',{name:'Startpunten',exact:true}).click();
 const card=page.locator('.start-point-card').filter({has:page.getByText(name,{exact:true})});
 await expect(card.getByRole('checkbox')).toHaveCount(0);await expect(card).not.toContainText('75 meter');
 const response=page.waitForResponse(result=>result.url().includes('/rpc/admin_startregie_confirm_point'));
 await card.getByRole('button',{name:'Startpunt bevestigen'}).click();expect((await response).ok()).toBe(true);
 await expect(card).toContainText('Startpunt: ja');await card.scrollIntoViewIfNeeded();await assertReadableLayout(page);
 await mkdir('docs/ops/screenshots',{recursive:true});await page.screenshot({path:'docs/ops/screenshots/start-simple-confirmation-390.png'});
 const after=await client.schema('api').rpc('admin_startregie_snapshot',{_event_slug:event});expect(after.error).toBeNull();expect(after.data.startPoints.find((point:{name:string})=>point.name===name).verified).toBe(true);
});
