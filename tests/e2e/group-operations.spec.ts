import {test,expect,type BrowserContext} from '@playwright/test';
import {createClient} from '@supabase/supabase-js';
import {sql} from '../../scripts/acceptance/together-fixtures.mjs';
import {mkdir} from 'node:fs/promises';
import {prepareFixtureGuidance,selectOrganizationSection} from './helpers/guidance';
import {assertReadableLayout} from './helpers/layout';
import {reviewCanonicalFixtureRoutes} from './helpers/canonical-routes';
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
 // This flow deliberately configures a high-capacity finale; its physical
 // local fixture must provide the same capacity as its route settings.
 sql("update app_private.portal_windows set max_concurrent_groups=50,max_children_per_visit=50,max_children_total=500 where portal_id='12000000-0000-0000-0000-000000000030'");
 async function rpc(name:string,args:Record<string,unknown>){const r=await client.schema('api').rpc(name,args);expect(r.error).toBeNull();return r.data;}
 let state=await rpc('admin_startregie_snapshot',{_event_slug:event});
 await rpc('admin_startregie_settings_save',{_event_slug:event,_settings:{...state.settings,plannerMode:'dynamic',firstStartAt:'2026-10-31T15:00:00Z',globalOrdinaryStopAt:'2026-10-31T19:30:00Z',finalPortalId:'12000000-0000-0000-0000-000000000030',finaleOpensAt:'2026-10-31T18:00:00Z',finaleLastArrivalAt:'2026-10-31T20:30:00Z',finaleClosesAt:'2026-10-31T21:00:00Z',finaleMaxGroups:50,finaleMaxChildren:500,finaleAvailable:true},_expected_version:state.settings.version,_reason:'Afgeschermde browserproef van de volledige groepsketen'});
 // Auto-grouping deliberately targets 15 children, while the seeded ordinary
 // houses receive at most 12. Add a real separate synthetic receiver through
 // the normal API; every existing house keeps its original hard capacity.
 const receiverPayload={name:'Synthetische groepsontvangst 15',worldSlug:'heksenrijk',lifecycleStatus:'active',approvalStatus:'approved',operationStatus:'scheduled',
   street:'FICTIEVE EXTRA TESTLOCATIE',houseNumber:'999',postalCode:'0000AA',city:'Teststad',latitude:52.10055,longitude:4.27055,
   plannedOpensAt:'2026-10-31T15:00:00Z',plannedClosesAt:'2026-10-31T19:30:00Z',maxGroups:1,maxChildren:15,
   visitMinutes:5,bufferMinutes:2,accessibilityStatus:'unknown',candidateStartPoint:false,saveMode:'activate'};
 const receiver=await rpc('admin_manual_portal_save',{_event_slug:event,_portal_id:null,_expected_version:null,
  _payload:{...receiverPayload,lifecycleStatus:'concept',approvalStatus:'draft'},
  _reason:'Afzonderlijke synthetische ontvangstlocatie voor de beoogde 15 kinderen'});
 expect(receiver.id).toMatch(/^[a-f0-9-]{36}$/);
 // Reuse the seed's already verified portal owner; activation still passes
 // the actual primary-owner constraint and the complete management API.
 sql(`insert into app_private.portal_owners(portal_id,user_id)
  select '${receiver.id}',o.user_id from app_private.portal_owners o join auth.users u on u.id=o.user_id
  where o.portal_id='12000000-0000-0000-0000-000000000001' and o.role='owner' and o.revoked_at is null and u.email_confirmed_at is not null`);
 await rpc('admin_manual_portal_save',{_event_slug:event,_portal_id:receiver.id,_expected_version:receiver.version,_payload:receiverPayload,
  _reason:'Synthetische ontvangst activeren met de bestaande geverifieerde testeigenaar'});
 expect(sql("select bool_and(max_children_per_visit=12) from app_private.portal_windows where portal_id::text like '12000000-%' and portal_id<>'12000000-0000-0000-0000-000000000030'")).toBe('t');
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
 await expect(column).toContainText('Dominante startvoorkeur');await expect(column).toContainText('gewenst einde');await expect(column).toContainText('streef 15');
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
 const communicationBefore=(await rpc('admin_group_composition_snapshot',{_event_slug:event})).groups.map((g:{id:string;communication:unknown})=>({id:g.id,communication:g.communication}));
 await page.getByRole('button',{name:'Groepen automatisch over startpunten verdelen',exact:true}).click();
 await expect(page.getByRole('button',{name:'Conceptslotverdeling opslaan'})).toBeEnabled();
 const proposal=page.getByRole('region',{name:'Bestaande groepen automatisch plannen'});
 await expect(proposal.locator('.proposal-row').first()).toContainText('Startvoorkeur');
 await expect(proposal.locator('.proposal-row').first()).toContainText('Gewenst klaar');
 await expect(proposal.locator('.proposal-row').first()).toContainText('vertrek');
 await expect(proposal.locator('.proposal-row').first()).toContainText('Waarom hier?');
 await page.getByRole('button',{name:'Conceptslotverdeling opslaan'}).click();
 await expect(page.getByRole('button',{name:'Conceptslotverdeling opslaan'})).not.toBeVisible();
 const after=(await rpc('admin_group_composition_snapshot',{_event_slug:event})).groups.map((g:{id:string;registrations:Array<{id:string}>})=>({id:g.id,members:g.registrations.map(r=>r.id).sort()}));expect(after).toEqual(before);
 const savedGroups=(await rpc('admin_group_composition_snapshot',{_event_slug:event})).groups;
 expect(savedGroups.map((g:{id:string;communication:unknown})=>({id:g.id,communication:g.communication}))).toEqual(communicationBefore);
 expect(savedGroups.find((g:{id:string})=>g.id===first.id).compositionConfirmed).toBe(true);
 state=await rpc('admin_startregie_snapshot',{_event_slug:event});
 const departureKeys:string[]=[];
 for(const group of state.groups.filter((g:{schedule:unknown})=>g.schedule)){
  const point=state.startPoints.find((p:{slots:Array<{id:string}>})=>p.slots.some(slot=>slot.id===group.schedule.startSlotId));
  const slot=point.slots.find((s:{id:string})=>s.id===group.schedule.startSlotId);
  expect(Date.parse(slot.startsAt)%600000).toBe(0);
  departureKeys.push(`${point.linkedPortalId??point.id}:${Date.parse(slot.startsAt)}`);
 }
 expect(new Set(departureKeys).size).toBe(departureKeys.length);
 await reviewCanonicalFixtureRoutes(client,event);
 const card=page.locator('.start-ops-assignment').filter({has:page.getByText(first.systemCode,{exact:true})});
 await card.getByRole('button',{name:'Startafspraken bevestigen en versturen',exact:true}).click();dialog=page.getByRole('dialog');await expect(dialog).toContainText('Adres vanaf');
 await dialog.getByRole('button',{name:'Startafspraken bevestigen en versturen',exact:true}).click();await expect(dialog).not.toBeVisible();await expect(card).toContainText('Starttijd gepubliceerd');
 for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await assertReadableLayout(page);await page.screenshot({animations:"disabled",path:`docs/ops/screenshots/group-operations/start-${width}.png`});}
});
