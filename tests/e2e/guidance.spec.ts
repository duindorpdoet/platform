import {test,expect,type BrowserContext,type Page} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {randomUUID} from 'node:crypto';
import {sql,requireLocalTogetherDatabase} from '../../scripts/acceptance/together-fixtures.mjs';
import {createPortalRoomFixture} from '../../scripts/acceptance/poortkamer-fixtures.mjs';
const origin='https://127.0.0.1:3443',event='duindorp-halloween-2026';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL!,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;
test.skip(!url||!key,'Isolated Supabase required');
async function account(context:BrowserContext,kind:'house'|'parent'|'dual'='house'){
 requireLocalTogetherDatabase();
 const admin=createClient(url,process.env.SUPABASE_SECRET_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});
 let email='parent-a@example.invalid',id='a0000000-0000-0000-0000-000000000001';
 if(kind==='house'){
  email=`guidance-${randomUUID()}@example.invalid`;
  const created=await admin.auth.admin.createUser({email,password:'local-test-only',email_confirm:true});expect(created.error).toBeNull();id=created.data.user!.id;
 }
 if(kind==='parent')sql(`update app_private.portal_owners set suspended_at=now() where user_id='${id}' and revoked_at is null;`);
 const portal=kind==='parent'?null:createPortalRoomFixture(id);
 sql(`delete from app_private.participant_tutorials where user_id='${id}';delete from app_private.community_acknowledgements where user_id='${id}';delete from app_private.account_app_preferences where user_id='${id}';`);
 const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}}),signed=await client.auth.signInWithPassword({email,password:'local-test-only'});expect(signed.error).toBeNull();
 const name=`sb-${new URL(url).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(signed.data.session)).toString('base64url')}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:origin,sameSite:'Lax' as const})));
 return {client,id,portal};
}
const tour=(page:Page)=>page.getByRole('dialog').filter({has:page.getByRole('progressbar',{name:'Voortgang rondleiding'})});
async function welcome(page:Page){const dialog=page.getByRole('dialog',{name:'Samen goed op pad'});await expect(dialog).toBeVisible();await dialog.getByRole('button',{name:'Gelezen, verder naar mijn omgeving'}).click();await expect(dialog).toHaveCount(0);}
async function enter(page:Page,path='/mijn-huis'){await page.goto(path);await welcome(page);await expect(tour(page)).toContainText('Stap 1 van 14');}
async function next(page:Page){const result=page.waitForResponse(r=>r.url().endsWith('/api/redesign/guidance')&&r.request().method()==='POST');await tour(page).getByRole('button',{name:'Verder',exact:true}).click();expect((await result).status()).toBe(200);}
test('legacy public entry and saved root: first house step is confirmed',async({page,context})=>{
 const owner=await account(context);
 sql(`insert into app_private.participant_tutorials(event_id,user_id,role,return_path) select id,'${owner.id}','house','/' from app_private.events where slug='${event}';`);
 await page.goto('/');await expect(page.getByRole('heading',{name:/Welkom|avond|Duindorp|Halloween|poort/i}).first()).toBeVisible();await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page).toHaveURL(origin+'/');
 await page.goto('/omgeving/kiezen');await expect(page.getByRole('heading',{name:'Ouder & meeloper'})).toHaveCount(0);await page.getByRole('button',{name:/Poortwachter/}).click();await welcome(page);
 const saved=page.waitForResponse(r=>r.url().endsWith('/api/redesign/guidance')&&r.request().method()==='POST');await tour(page).getByRole('button',{name:'Verder',exact:true}).click();
 const response=await saved;let code=null;if(!response.ok()){const diagnosed=await page.request.post('/api/redesign/guidance',{headers:{origin},data:response.request().postDataJSON()});code=(await diagnosed.json()).error?.code;}console.log(JSON.stringify({scenario:'legacy-root-first-step',returnPath:response.request().postDataJSON().returnPath,status:response.status(),code}));
 expect(response.status()).toBe(200);expect(response.request().postDataJSON().returnPath).toBe('/mijn-huis');await expect(tour(page)).toContainText('Stap 2 van 14');
});
test('direct house entry saves all 14 steps, resumes and retains completion on replay',async({page,context})=>{
 const owner=await account(context);const destination=`/mijn-huis?poort=${owner.portal!.id}&tab=night`;await enter(page,destination);
 for(let i=1;i<=4;i++)await next(page);
 await page.reload();await expect(tour(page)).toContainText('Stap 5 van 14');
 for(let i=5;i<14;i++)await next(page);
 await expect(tour(page)).toContainText('Stap 14 van 14');await tour(page).getByRole('button',{name:'Rondleiding afronden'}).click();await expect(tour(page)).toHaveCount(0);
 expect((await owner.client.schema('api').rpc('participant_guidance',{_event_slug:event})).data.completed.house).toBe(1);await expect(page).toHaveURL(origin+destination);
 await page.reload();await expect(tour(page)).toHaveCount(0);await page.getByRole('button',{name:'Hulp & community',exact:true}).click();await page.getByRole('button',{name:/Bekijk de rondleiding opnieuw/}).click();await expect(tour(page)).toContainText('Stap 1 van 14');await tour(page).getByRole('button',{name:'Rondleiding sluiten'}).click();
 expect((await owner.client.schema('api').rpc('participant_guidance',{_event_slug:event})).data.completed.house).toBe(1);
});
test('legacy open client normalizes root; unsafe requests and skipped steps are refused',async({page,context})=>{
 await account(context);
 const request=(returnPath:string,index=1)=>page.request.post('/api/redesign/guidance',{headers:{origin},data:{action:'tutorial',role:'house',version:1,index,returnPath}});
 expect((await request('/')).status()).toBe(200);
 for(const path of ['https://example.invalid','//example.invalid','/\\example.invalid','/%5cexample.invalid','/mijn-huis\n','/'+ 'x'.repeat(4096)])expect((await request(path)).status()).toBe(422);
 const conflict=await request('/mijn-huis',13);expect(conflict.status()).toBe(409);expect((await conflict.json()).error.code).toBe('TUTORIAL_STEP_REQUIRED');
});
test('parent-only remains separate; a house tutorial never grants house access',async({page,context})=>{
 const parent=await account(context,'parent');
 const denied=await page.request.post('/api/redesign/guidance',{headers:{origin},data:{action:'tutorial',role:'house',version:1,index:1,returnPath:'/'}});expect(denied.status()).toBe(403);
 await enter(page,'/omgeving/meeloper/nu');await next(page);await expect(tour(page)).toContainText('Stap 2 van 14');
 const record=(await parent.client.schema('api').rpc('participant_guidance',{_event_slug:event})).data;expect(record.progress.parent.index).toBe(1);expect(record.completed.house).toBeUndefined();
});
test('dual roles, query destination and suspended house access preserve the parent role',async({page,context})=>{
 const owner=await account(context,'dual');await enter(page,`/mijn-huis?poort=${owner.portal!.id}&tab=night`);await next(page);
 await page.goto('/omgeving/meeloper/nu');await expect(tour(page)).toContainText('Stap 1 van 14');await next(page);
 sql(`update app_private.portal_owners set suspended_at=now() where portal_id='${owner.portal!.id}' and user_id='${owner.id}';`);
 const denied=await page.request.post('/api/redesign/guidance',{headers:{origin},data:{action:'tutorial',role:'house',version:1,index:2,returnPath:'/mijn-huis'}});expect(denied.status()).toBe(403);
 const record=(await owner.client.schema('api').rpc('participant_guidance',{_event_slug:event})).data;expect(record.roles).toContain('parent');expect(record.progress.parent.index).toBe(1);
});
test('failed saves retain the step and error; double tap and older reads cannot roll back confirmation',async({page,context})=>{
 await account(context);await enter(page);
 let posts=0,fail=true,release:(()=>void)|undefined,oldRead:unknown;
 await page.route('**/api/redesign/guidance',async route=>{
  if(route.request().method()==='POST'){
   posts++;if(fail){await route.fulfill({status:422,json:{error:{code:'VALIDATION_ERROR',requestId:'synthetic-guidance-reference'}}});return;}
   await new Promise(resolve=>setTimeout(resolve,150));await route.continue();return;
  }
  if(oldRead){const data=oldRead;oldRead=null;await new Promise<void>(resolve=>{release=resolve;});await route.fulfill({json:data});return;}
  await route.continue();
 });
 await tour(page).getByRole('button',{name:'Verder',exact:true}).click();await expect(tour(page)).toContainText('Stap 1 van 14');await expect(tour(page).getByRole('alert')).toContainText('verouderd of ongeldig');await expect(tour(page).getByRole('alert')).toContainText('synthetic-guidance-reference');
 const record=await(await page.request.get('/api/redesign/guidance')).json();oldRead=record;await page.evaluate(()=>window.dispatchEvent(new Event('online')));await expect.poll(()=>Boolean(release)).toBe(true);
 fail=false;const before=posts;await tour(page).getByRole('button',{name:'Verder',exact:true}).evaluate((button:HTMLButtonElement)=>{button.click();button.click();});await expect(tour(page)).toContainText('Stap 2 van 14');expect(posts-before).toBe(1);const staleFinished=page.waitForResponse(r=>r.url().endsWith('/api/redesign/guidance')&&r.request().method()==='GET');release!();await staleFinished;
 await expect(tour(page)).toContainText('Stap 2 van 14');await expect(tour(page).getByRole('alert')).toHaveCount(0);await page.reload();await expect(tour(page)).toContainText('Stap 2 van 14');
});
test('network, expired session, access and server errors keep the current step with specific recovery',async({page,context})=>{
 await account(context);await enter(page);
 let failure:number|'network'=401;
 await page.route('**/api/redesign/guidance',async route=>{
  if(route.request().method()!=='POST'){await route.continue();return;}
  if(failure==='network'){await route.abort('internetdisconnected');return;}
  await route.fulfill({status:failure,json:{error:{code:failure===401?'NOT_AUTHORIZED':failure===403?'NOT_AUTHORIZED':'UNAVAILABLE'}}});
 });
 for(const [status,message,link] of [[401,'Je sessie is verlopen','Opnieuw inloggen'],[403,'geen toegang','Mijn toegang controleren'],[503,'Bewaren lukt nu even niet',null],['network','De verbinding is onderbroken',null]] as const){
  failure=status;await tour(page).getByRole('button',{name:'Verder',exact:true}).click();await expect(tour(page).getByRole('alert')).toContainText(message);await expect(tour(page)).toContainText('Stap 1 van 14');if(link)await expect(tour(page).getByRole('link',{name:link})).toBeVisible();
 }
 await page.unroute('**/api/redesign/guidance');await next(page);await expect(tour(page)).toContainText('Stap 2 van 14');
});
test('a delayed save from another role cannot overwrite the newly selected parent tour',async({page,context})=>{
 await account(context,'dual');await enter(page);
 let release:(()=>void)|undefined;
 await page.route('**/api/redesign/guidance',async route=>{
  if(route.request().method()==='POST'&&route.request().postDataJSON().role==='house'){
   const response=await route.fetch();await new Promise<void>(resolve=>{release=resolve;});await route.fulfill({response});return;
  }await route.continue();
 });
 await tour(page).getByRole('button',{name:'Verder',exact:true}).click();await expect.poll(()=>Boolean(release)).toBe(true);
 // Browser history changes environment within the same mounted app, like the mobile environment switcher.
 await page.evaluate(()=>{history.pushState({},'', '/omgeving/meeloper/nu');window.dispatchEvent(new PopStateEvent('popstate'));});
 await expect(tour(page)).toContainText('Rondleiding voor ouders');await expect(tour(page)).toContainText('Stap 1 van 14');
 const finished=page.waitForResponse(r=>r.request().method()==='POST'&&r.url().endsWith('/api/redesign/guidance'));release!();await finished;
 await expect(tour(page)).toContainText('Rondleiding voor ouders');await expect(tour(page)).toContainText('Stap 1 van 14');
});
test('login and both registration entries place an accessible compact Google icon below email',async({page})=>{
 for(const path of ['/inloggen','/huis-aanmelden','/meelopen']){
  await page.goto(path);const email=page.getByRole('textbox',{name:/e-mailadres/i}).first(),google=page.getByRole('button',{name:'Doorgaan met Google',exact:true});await expect(email).toBeVisible();await expect(google).toBeVisible();
  const field=await email.boundingBox(),button=await google.boundingBox();expect(button!.y).toBeGreaterThanOrEqual(field!.y+field!.height);expect(button!.width).toBeLessThanOrEqual(52);expect(button!.height).toBeGreaterThanOrEqual(44);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 }
});
