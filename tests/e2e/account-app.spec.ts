import {test,expect,type BrowserContext} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {mkdir} from 'node:fs/promises';
import {sql,requireLocalTogetherDatabase} from '../../scripts/acceptance/together-fixtures.mjs';
import {prepareFixtureGuidance} from './helpers/guidance';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL!,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,parent='a0000000-0000-0000-0000-000000000001',finn='25000001-0000-4000-8000-000000000099',event='duindorp-halloween-2026';
test.skip(!url||!key,'Requires isolated real Supabase Auth and API');

async function login(context:BrowserContext,email='parent-a@example.invalid',prepared=false){
 const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const r=await client.auth.signInWithPassword({email,password:'local-test-only'});expect(r.error).toBeNull();
 if(prepared)await prepareFixtureGuidance(client);
 const name=`sb-${new URL(url).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(r.data.session)).toString('base64url')}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:'https://127.0.0.1:3443',sameSite:'Lax' as const})));return client;
}
test.beforeAll(()=>{
 requireLocalTogetherDatabase();
 sql(`delete from app_private.portal_owners where portal_id='12000000-0000-0000-0000-000000000001' and user_id='${parent}';
 insert into app_private.portal_owners(portal_id,user_id,role) values('12000000-0000-0000-0000-000000000001','${parent}','coadmin');
 update app_private.registration_children set participation_status='cancelled' where child_id in ('25000001-0000-0000-0000-000000000001','25000001-0000-0000-0000-000000000099');
 insert into app_private.children(id,household_id,first_name,age_at_event) select kid.id,household_id,kid.name,8 from app_private.children cross join (values ('${finn}'::uuid,'Finn account fixture'),('25000001-0000-4000-8000-000000000098'::uuid,'Mila account fixture')) kid(id,name) where app_private.children.id='25000001-0000-0000-0000-000000000001' on conflict do nothing;
 insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) select event_id,registration_id,kid.id,250 from app_private.registration_children cross join (values ('${finn}'::uuid),('25000001-0000-4000-8000-000000000098'::uuid)) kid(id) where app_private.registration_children.child_id='25000001-0000-0000-0000-000000000001' on conflict(event_id,child_id) do update set participation_status='active';
 delete from app_private.account_app_preferences where user_id='${parent}';`);
});
test.afterAll(()=>sql(`update app_private.portal_owners set revoked_at=now() where portal_id='12000000-0000-0000-0000-000000000001' and user_id='${parent}';update app_private.registration_children set participation_status=case when child_id='25000001-0000-0000-0000-000000000001' then 'active' else 'cancelled' end where child_id in ('25000001-0000-0000-0000-000000000001','${finn}','25000001-0000-4000-8000-000000000098');`));
test('app without a session gives complete Google/OTP login and controlled cancellation',async({page},info)=>{
 await page.goto('/app');await expect(page).toHaveURL(/inloggen/);await expect(page.getByRole('button',{name:'Doorgaan met Google'})).toBeVisible();await expect(page.getByLabel('E-mailadres',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Doorgaan met Google'}).click();await expect(page.locator('.entry-error[role=alert]')).toContainText('Google-aanmelding wordt nog ingericht');
 await expect(page.getByLabel('E-mailadres',{exact:true})).toBeEnabled();
 await mkdir('docs/ops/screenshots/account-app',{recursive:true});await page.screenshot({path:`docs/ops/screenshots/account-app/login-${info.project.name}.png`,fullPage:true});
 await page.goto('/auth/callback?error=access_denied&next=//evil.invalid');await expect(page.locator('.entry-error[role=alert]')).toContainText('geannuleerd');await expect(page.getByLabel('E-mailadres',{exact:true})).toBeVisible();
});
test('real parent and gate choices, protected separate children, resume and account logout',async({page,context},info)=>{
 await login(context,undefined,true);await page.goto('/app');
 await expect(page.getByRole('heading',{name:'Ouder & meeloper'})).toBeVisible();await expect(page.getByRole('heading',{name:'Poortwachter'})).toBeVisible();
 const select=page.getByRole('combobox',{name:'Kies een kinderomgeving'});await expect(select.locator('option')).toHaveCount(3);await expect(page.getByRole('button',{name:'Open Poortenboek',exact:true})).toBeDisabled();
 await page.screenshot({path:`docs/ops/screenshots/account-app/chooser-${info.project.name}.png`,fullPage:true});
 const rejected=await page.request.post('/api/poortenboek/parent',{headers:{origin:'https://127.0.0.1:3443'},data:{action:'open',childId:'25000002-0000-4000-8000-000000000001'}});expect(rejected.status()).toBe(401);
 await select.selectOption(finn);await page.getByRole('button',{name:'Open Poortenboek',exact:true}).click();await expect(page).toHaveURL(/\/poortenboek$/);
 const first=await page.request.get('/api/poortenboek/snapshot');expect(first.ok()).toBeTruthy();const firstBody=await first.json();expect(firstBody.firstName??firstBody.data?.firstName).toBe('Finn account fixture');
 await page.goto('/omgeving/kiezen');await expect(page.getByRole('button',{name:/Ga verder waar je was/})).toContainText('Finn account fixture');
 await page.getByRole('combobox',{name:'Kies een kinderomgeving'}).selectOption('25000001-0000-4000-8000-000000000098');await page.getByRole('button',{name:'Open Poortenboek',exact:true}).click();await expect(page).toHaveURL(/\/poortenboek$/);
 const second=await(await page.request.get('/api/poortenboek/snapshot')).json();expect(second.firstName??second.data?.firstName).toBe('Mila account fixture');
 await page.goto('/omgeving/kiezen');await page.getByRole('button',{name:'Wissel account',exact:true}).click();await expect(page).toHaveURL(/\/inloggen$/);expect((await page.request.get('/api/account')).status()).toBe(401);expect((await page.request.get('/api/poortenboek/snapshot')).status()).toBe(401);
});
test('once-only welcome survives reload, role change and previous-day acknowledgment; help can replay',async({page,context})=>{
 const client=await login(context,undefined,true);sql(`update app_private.account_app_preferences set welcome_version=0,welcome_acknowledged_at=null where user_id='${parent}';`);
 await page.goto('/omgeving/meeloper/nu');const welcome=page.getByRole('dialog',{name:'Samen goed op pad'});await expect(welcome).toBeVisible();await expect(welcome).toContainText('vrijwillig');
 await welcome.getByRole('button',{name:'Gelezen, verder naar mijn omgeving'}).click();await expect(welcome).toHaveCount(0);await page.reload();await expect(welcome).toHaveCount(0);
 sql(`delete from app_private.community_acknowledgements where user_id='${parent}' and local_day<current_date;update app_private.community_acknowledgements set local_day=current_date-1 where user_id='${parent}';`);
 await page.goto('/mijn-huis?poort=12000000-0000-0000-0000-000000000001');await expect(page.locator('#poortkamer-content')).toBeVisible();await expect(welcome).toHaveCount(0);
 expect((await client.schema('api').rpc('participant_guidance',{_event_slug:event})).data.welcomeVersion).toBe(1);
 await page.goto('/app/meldingen');await page.getByRole('button',{name:'Welkom, WhatsApp & appuitleg opnieuw bekijken'}).click();await expect(welcome).toBeVisible();await welcome.getByRole('button',{name:'Melding sluiten'}).click();await expect(welcome).toHaveCount(0);
});
test('iPad desktop agent gets Safari installation and push instructions',async({page})=>{
 await page.addInitScript(()=>{Object.defineProperty(navigator,'platform',{get:()=> 'MacIntel'});Object.defineProperty(navigator,'maxTouchPoints',{get:()=>5});});
 await page.goto('/app/hulp');await page.getByRole('button',{name:'Installeer de app',exact:true}).click();await expect(page.locator('.device-install-guide')).toContainText('Zet op beginscherm');await expect(page.locator('.device-install-guide')).toContainText('Voeg toe');
});

test('native installation waits for a real click and does not claim an accepted request is installed',async({page})=>{
 await page.goto('/app/hulp');
 await page.evaluate(()=>{const event=new Event('beforeinstallprompt',{cancelable:true});Object.assign(event,{prompt:async()=>{document.documentElement.dataset.installCalls=String(Number(document.documentElement.dataset.installCalls??0)+1);},userChoice:Promise.resolve({outcome:'accepted'})});window.dispatchEvent(event);});
 await expect(page.locator('html')).not.toHaveAttribute('data-install-calls');
 await page.getByRole('button',{name:'Installeer de app',exact:true}).click();await expect(page.locator('html')).toHaveAttribute('data-install-calls','1');await expect(page.getByRole('status')).toContainText('Installatie aangevraagd');await expect(page.getByText('Geïnstalleerd / appweergave',{exact:true})).toHaveCount(0);
 await page.evaluate(()=>window.dispatchEvent(new Event('appinstalled')));await expect(page.getByRole('button',{name:'Je gebruikt de app'})).toBeDisabled();
});
test('browser permission alone is not active server push, denial never blocks the app',async({page,context})=>{
 await login(context,undefined,true);
 await page.addInitScript(()=>{Object.defineProperty(Notification,'permission',{get:()=> 'granted'});Notification.requestPermission=async()=>{document.documentElement.dataset.permissionCalls='1';return 'denied';};});
 await page.route('**/api/push/subscription',route=>route.fulfill({json:{data:{enabled:true,activeSubscriptionCount:0,currentDeviceRegistered:false}}}));
 await page.goto('/app/meldingen');await expect(page.getByText('Browsertoestemming:',{exact:false})).toContainText('toegestaan');await expect(page.getByText('Actief op dit apparaat',{exact:true})).toHaveCount(0);await expect(page.locator('html')).not.toHaveAttribute('data-permission-calls');
 await page.getByRole('button',{name:'Meldingen aanzetten',exact:true}).click();await expect(page.locator('html')).toHaveAttribute('data-permission-calls','1');await expect(page.getByRole('status')).toContainText('niet toegestaan');await expect(page.getByRole('link',{name:'Wissel omgeving',exact:true})).toBeEnabled();
});
