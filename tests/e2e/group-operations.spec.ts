import {test,expect,type BrowserContext} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {mkdir} from 'node:fs/promises';
import {prepareFixtureGuidance,selectOrganizationSection} from './helpers/guidance';
import {assertReadableLayout} from './helpers/layout';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,event='duindorp-halloween-2026';
async function login(context:BrowserContext){
 const client=createClient(url!,key!,{auth:{persistSession:false,autoRefreshToken:false}}),result=await client.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'});expect(result.error).toBeNull();
 await prepareFixtureGuidance(client);
 const name=`sb-${new URL(url!).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(result.data.session)).toString('base64url')}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:'http://127.0.0.1:3100',sameSite:'Lax' as const})));
 return client;
}
test.beforeEach(()=>test.skip(!url||!key,'Requires an isolated real Auth/database fixture'));
test('one organizer resets, groups, confirms composition, distributes existing groups and shares start appointments',async({page,context})=>{
 test.setTimeout(120000);
 const client=await login(context);
 async function rpc(name:string,args:Record<string,unknown>){const r=await client.schema('api').rpc(name,args);expect(r.error).toBeNull();return r.data;}
 let state=await rpc('admin_startregie_snapshot',{_event_slug:event});
 await rpc('admin_startregie_settings_save',{_event_slug:event,_settings:{...state.settings,plannerMode:'dynamic',firstStartAt:'2026-10-31T15:00:00Z',globalOrdinaryStopAt:'2026-10-31T19:30:00Z',finalPortalId:'12000000-0000-0000-0000-000000000030',finaleOpensAt:'2026-10-31T18:00:00Z',finaleLastArrivalAt:'2026-10-31T20:30:00Z',finaleClosesAt:'2026-10-31T21:00:00Z',finaleMaxGroups:50,finaleMaxChildren:500,finaleAvailable:true},_expected_version:state.settings.version,_reason:'Afgeschermde browserproef van de volledige groepsketen'});
 await page.goto('/admin?view=groups');await selectOrganizationSection(page,'Groepsindeling');
 async function openGroupActions(){const details=page.locator('.group-composition > .group-operations details');if(await details.getAttribute('open')===null)await details.locator('summary').click();}
 await openGroupActions();
 await page.getByRole('button',{name:'Alle groepen terugzetten',exact:true}).click();
 let dialog=page.getByRole('dialog');await expect(dialog).toContainText('gepubliceerde afspraken');
 await dialog.getByRole('textbox',{name:'Typ ALLE GROEPEN TERUGZETTEN'}).fill('ALLE GROEPEN TERUGZETTEN');
 await dialog.getByRole('button',{name:'Alle groepen terugzetten',exact:true}).click();await expect(dialog).not.toBeVisible();
 await expect(page.locator('.group-composition-column')).toHaveCount(1);
 await page.getByRole('button',{name:'Groepen automatisch vullen',exact:true}).click();dialog=page.getByRole('dialog');
 await expect(dialog).toContainText('Startslots zijn hiervoor niet nodig');await dialog.getByRole('button',{name:'Conceptgroepen opslaan'}).click();await expect(dialog).not.toBeVisible();
 const snapshot=await rpc('admin_group_composition_snapshot',{_event_slug:event});expect(snapshot.groups.length).toBeGreaterThan(0);
 const first=snapshot.groups.find((g:{childCount:number})=>g.childCount>0);
 const column=page.locator(`[data-column-id="${first.id}"]`);
 const picker=page.getByRole('combobox',{name:'Kies groep'});
 if(await picker.isVisible())await picker.selectOption(first.id);
 await expect(column).toContainText('Voorkeurstijd');await expect(column).toContainText('streef 15');
 await column.getByRole('button',{name:'Inklappen',exact:true}).click();await expect(column.locator('.group-composition-dropzone')).toBeHidden();
 await expect(column).toContainText(`${first.childCount} kinderen`);await column.getByRole('button',{name:'Uitklappen',exact:true}).click();
 await page.getByRole('button',{name:`${first.systemCode} · Groep bevestigen`,exact:true}).click();dialog=page.getByRole('dialog');await dialog.getByRole('button',{name:'Groep bevestigen',exact:true}).click();await expect(dialog).not.toBeVisible();await expect(column).toContainText('Groep bevestigd');
 await mkdir('docs/ops/screenshots/group-operations',{recursive:true});
 for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await assertReadableLayout(page);await page.screenshot({animations:"disabled",path:`docs/ops/screenshots/group-operations/groups-${width}.png`});}
 const before=(await rpc('admin_group_composition_snapshot',{_event_slug:event})).groups.map((g:{id:string;registrations:Array<{id:string}>})=>({id:g.id,members:g.registrations.map(r=>r.id).sort()}));
 await openGroupActions();
 await page.getByRole('button',{name:'Groepen over startpunten verdelen',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Iedere groep een goede start.'})).toBeVisible();
 state=await rpc('admin_startregie_snapshot',{_event_slug:event});
 for(const point of state.startPoints.filter((p:{active:boolean})=>p.active))await rpc('admin_startregie_confirm_point',{_event_slug:event,_point_id:point.id,_expected_version:point.version});
 await page.getByRole('button',{name:'Vernieuwen',exact:true}).first().click();
 await page.getByRole('button',{name:'Groepen automatisch over startpunten verdelen',exact:true}).click();
 await expect(page.getByRole('button',{name:'Conceptslotverdeling opslaan'})).toBeEnabled();
 await page.getByRole('button',{name:'Conceptslotverdeling opslaan'}).click();
 await expect(page.getByRole('button',{name:'Conceptslotverdeling opslaan'})).not.toBeVisible();
 const after=(await rpc('admin_group_composition_snapshot',{_event_slug:event})).groups.map((g:{id:string;registrations:Array<{id:string}>})=>({id:g.id,members:g.registrations.map(r=>r.id).sort()}));expect(after).toEqual(before);
 const card=page.locator('.start-ops-assignment').filter({has:page.getByText(first.systemCode,{exact:true})});
 await card.getByRole('button',{name:'Startafspraken bevestigen en versturen',exact:true}).click();dialog=page.getByRole('dialog');await expect(dialog).toContainText('Adres vanaf');
 await dialog.getByRole('button',{name:'Startafspraken bevestigen en versturen',exact:true}).click();await expect(dialog).not.toBeVisible();await expect(card).toContainText('Starttijd gepubliceerd');
 for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await assertReadableLayout(page);await page.screenshot({animations:"disabled",path:`docs/ops/screenshots/group-operations/start-${width}.png`});}
});
