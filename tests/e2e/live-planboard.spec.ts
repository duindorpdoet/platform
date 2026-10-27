import {expect,test,type BrowserContext} from '@playwright/test';
import {createClient,type SupabaseClient} from '@supabase/supabase-js';
import {mkdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {sql,requireLocalTogetherDatabase,createTogetherFixtures} from '../../scripts/acceptance/together-fixtures.mjs';
import {prepareFixtureGuidance,selectOrganizationSection} from './helpers/guidance';
import type {BoardSnapshot} from '../../lib/domain/live-planboard';
const event='duindorp-halloween-2026',gid='23000000-0000-0000-0000-000000000002';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL!,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;
async function login(context:BrowserContext,email='admin@example.invalid') {
 const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const r=await client.auth.signInWithPassword({email,password:'local-test-only'});expect(r.error).toBeNull();await prepareFixtureGuidance(client);
 const name=`sb-${new URL(url).hostname.split('.')[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(r.data.session)).toString('base64url')}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:'https://127.0.0.1:3443',sameSite:'Lax' as const})));return client;
}
async function rpc(client:SupabaseClient,name:string,args:Record<string,unknown>){const r=await client.schema('api').rpc(name,args);expect(r.error,JSON.stringify(r.error)).toBeNull();return r.data;}
async function snapshot(client:SupabaseClient):Promise<BoardSnapshot>{return rpc(client,'admin_live_planboard_snapshot',{_event_slug:event});}
test.describe.configure({mode:'serial'});
test.skip(!url||!key,'Requires isolated real Auth and database');
test.beforeAll(()=>{
 requireLocalTogetherDatabase();
 sql(`update app_private.event_route_settings set first_start_at='2026-10-31T15:00Z',global_ordinary_stop_at='2026-10-31T19:30Z',final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00Z',finale_last_arrival_at='2026-10-31T20:30Z',finale_closes_at='2026-10-31T21:00Z',finale_max_concurrent_groups=20,finale_max_concurrent_children=200,finale_available=true,planner_mode='dynamic';
 update app_private.walking_groups set desired_ordinary_visits=3 where id='${gid}';update app_private.registrations set requested_ordinary_stop_at=null,preferred_start_at=null where id in(select registration_id from app_private.group_registrations where group_id='${gid}');`);
});
test('real planboard route, keyboard move, equal shift, undo/redo and responsive timeline',async({page,context})=>{
 const client=await login(context);
 const point=await rpc(client,'admin_portal_start_point_set',{_portal_id:'12000000-0000-0000-0000-000000000001',_enabled:true,_expected_version:Number(sql("select version from app_private.portals where id='12000000-0000-0000-0000-000000000001'"))});
 await rpc(client,'admin_startregie_confirm_point',{_event_slug:event,_point_id:point.startPointId,_expected_version:Number(sql(`select version from app_private.start_points where id='${point.startPointId}'`))});
 await rpc(client,'admin_startregie_move_group',{_group_id:gid,_start_point_id:point.startPointId,_starts_at:'2026-10-31T17:00:00Z',_expected_group_version:Number(sql(`select version from app_private.walking_groups where id='${gid}'`)),_preference_match:'neutral',_reason:'Synthetische browserketen voor het echte live planbord'});
 const before=await snapshot(client);expect(before.visits.filter(v=>v.groupId===gid).length).toBeGreaterThan(1);
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Live planbord',exact:true}).click();
 await expect(page.locator('.planboard-row')).toHaveCount(before.portals.length);
 const visit=before.visits.find(v=>v.groupId===gid&&v.sequence===2)!;const mailBefore=sql('select count(*) from app_private.email_outbox');
 await page.getByRole('checkbox',{name:'Volgende stops meeschuiven',exact:true}).check();await page.locator(`[data-visit-id="${visit.id}"]`).focus();await page.keyboard.press('ArrowRight');
 const dialog=page.getByRole('dialog');await expect(dialog).toContainText('geen starttijdmail');await dialog.getByRole('textbox').fill('Alle volgende conceptstops in de echte browser gelijk verschuiven');await dialog.getByRole('button',{name:'Route-intentie opslaan',exact:true}).click();await expect(dialog).toHaveCount(0);
 await expect.poll(async()=>Date.parse((await snapshot(client)).visits.find(v=>v.id===visit.id)!.startsAt)).not.toBe(Date.parse(visit.startsAt));
 const after=await snapshot(client);const shifted=after.visits.filter(v=>v.groupId===gid&&v.sequence>=2);const deltas=shifted.map(v=>Date.parse(v.startsAt)-Date.parse(before.visits.find(old=>old.id===v.id)!.startsAt));expect(new Set(deltas).size).toBe(1);expect(sql('select count(*) from app_private.email_outbox')).toBe(mailBefore);
 await page.getByRole('button',{name:'Ongedaan',exact:true}).click();await page.getByRole('dialog').getByRole('textbox').fill('De conceptverplaatsing gecontroleerd ongedaan maken');await page.getByRole('dialog').getByRole('button',{name:'Route-intentie opslaan',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
 expect((await snapshot(client)).visits.find(v=>v.id===visit.id)!.startsAt).toBe(visit.startsAt);
 await page.getByRole('button',{name:'Opnieuw',exact:true}).click();await page.getByRole('dialog').getByRole('textbox').fill('Dezelfde gecontroleerde conceptverplaatsing opnieuw toepassen');await page.getByRole('dialog').getByRole('button',{name:'Route-intentie opslaan',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
 await mkdir('docs/ops/screenshots/live-planboard',{recursive:true});
 for(const width of [1440,390]){await page.setViewportSize({width,height:900});await page.getByRole('button',{name:'Hele avond passend',exact:true}).click();await expect(page.locator('.planboard-scroll')).toBeVisible();await page.screenshot({path:`docs/ops/screenshots/live-planboard/board-${width}.png`});}
});
test('pointer cancel retains the dragged node and creates no server mutation',async({page,context})=>{
 const client=await login(context);const before=await snapshot(client);const visit=before.visits.find(v=>v.groupId===gid&&v.sequence===2)!;
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Live planbord',exact:true}).click();
 const block=page.locator(`[data-visit-id="${visit.id}"]`);await block.scrollIntoViewIfNeeded();const box=(await block.boundingBox())!;await page.mouse.move(box.x+10,box.y+10);await page.mouse.down();await page.mouse.move(box.x+50,box.y+10,{steps:8});await expect(block).toHaveCount(1);await page.keyboard.press('Escape');await page.mouse.up();await expect(page.getByRole('dialog')).toHaveCount(0);expect((await snapshot(client)).inputHash).toBe(before.inputHash);
});
test('stale confirmed impact is refused across two authenticated admin sessions',async({context,browser})=>{
 const a=await login(context),other=await browser.newContext({ignoreHTTPSErrors:true}),b=await login(other);const before=await snapshot(a);const visit=before.visits.find(v=>v.groupId===gid&&v.sequence===2)!;
 const command={action:'move',visitId:visit.id,portalId:visit.portalId,startsAt:new Date(Math.round(Date.parse(visit.startsAt)/600000)*600000+600000).toISOString(),shiftFollowing:true};
 await rpc(a,'admin_live_planboard_preview',{_event_slug:event,_command:command,_input_hash:before.inputHash});
 await rpc(b,'portal_set_operational_state',{_portal_id:visit.portalId,_state:'paused',_expected_version:Number(sql(`select version from app_private.portals where id='${visit.portalId}'`)),_reason:'Tweede beheerder pauzeert deze synthetische poort'});
 const rejected=await a.schema('api').rpc('admin_live_planboard_apply',{_event_slug:event,_command:command,_input_hash:before.inputHash,_confirmed:true,_reason:'Oude impact mag niet stilzwijgend opnieuw worden toegepast',_idempotency_key:randomUUID()});expect(rejected.error?.message).toContain('STALE_VERSION');
 const current=await snapshot(a);expect(current.portals.some(p=>p.id===visit.portalId&&p.operationStatus==='paused')).toBe(true);expect(current.visits.find(v=>v.id===visit.id)!.startsAt).toBe(visit.startsAt);await other.close();
});
test('wrong house intake and real parent books coexist and only house participation is withdrawn',async({page,context})=>{
 const [family]=createTogetherFixtures(1,1,2);
 sql(`update app_private.household_members set user_id='a0000000-0000-0000-0000-000000000005' where household_id=(select household_id from app_private.registrations where id='${family.members[0].id}');
 update app_private.households set primary_contact_user_id='a0000000-0000-0000-0000-000000000005' where id=(select household_id from app_private.registrations where id='${family.members[0].id}');
 with numbered as(select child_id,row_number() over(order by child_id) n from app_private.registration_children where registration_id='${family.members[0].id}') update app_private.children c set first_name=case when n=1 then 'Avonturier A' else 'Avonturier B' end from numbered where c.id=numbered.child_id;`);
 const parent=await login(context,'parent-size-5@example.invalid');const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});expect((await admin.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'})).error).toBeNull();
 const trusted=createClient(url,process.env.SUPABASE_SECRET_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});
 await rpc(trusted,'portal_registration_begin',{_event_slug:event,_email:'parent-size-5@example.invalid',_contact_name:'Verkeerde synthetische aanmelding',_phone:'0612345678',_street:'',_house_number:'',_addition:'',_postal_code:'',_opaque_subject_hash:'a'.repeat(64)});const claimed=await rpc(parent,'portal_registration_claim',{_event_slug:event});
 const intake=sql(`select id from app_private.portal_registration_intakes where application_id='${claimed.id}'`);const preview=await rpc(admin,'admin_portal_registration_preview',{_event_slug:event,_kind:'intake',_id:intake});
 const familyBefore=sql("select md5(jsonb_agg(to_jsonb(rc) order by rc.id)::text) from app_private.registration_children rc");
 await page.goto('/poortenboek');await expect(page.getByRole('region',{name:'Poortenboeken van jouw kinderen'})).toBeVisible();const choices=page.getByRole('button',{name:/^Open Poortenboek van /});expect(await choices.count()).toBeGreaterThan(1);
 await rpc(admin,'admin_portal_registration_apply',{_event_slug:event,_kind:'intake',_id:intake,_action:'withdraw',_payload:{},_input_hash:preview.inputHash,_reason:'Alleen de foutieve synthetische poortdeelname intrekken',_idempotency_key:randomUUID()});
 await page.reload();await expect(choices.first()).toBeVisible();await choices.first().click();await expect(page.getByRole('button',{name:'Dit is mijn boek',exact:true})).toBeVisible();await page.getByRole('button',{name:'Dit is mijn boek',exact:true}).click();
 const childSnapshot=await page.request.get('/api/poortenboek/snapshot');expect(childSnapshot.ok()).toBe(true);const child=await childSnapshot.json();expect(child.childId).toBeTruthy();
 expect((await page.request.get('/api/poortenboek/parent')).ok()).toBe(true);
 await page.goto('/poortenboek/ouder');await expect(choices.first()).toBeVisible();await choices.nth(1).click();await expect.poll(async()=>{const r=await page.request.get('/api/poortenboek/snapshot');return r.ok()?(await r.json()).childId:null;}).not.toBe(child.childId);
 expect(sql("select md5(jsonb_agg(to_jsonb(rc) order by rc.id)::text) from app_private.registration_children rc")).toBe(familyBefore);
});
test('resolving a conflict during dragging keeps the active node under the conflicts filter',async({page,context})=>{
 const client=await login(context);const before=await snapshot(client);const visit=before.visits.find(v=>v.groupId===gid&&v.sequence===2)!;const ownPortals=new Set(before.visits.filter(v=>v.groupId===gid).map(v=>v.portalId));const target=before.portals.find(p=>!ownPortals.has(p.id)&&!p.finale&&p.operationStatus==='open')!;
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Live planbord',exact:true}).click();await page.getByRole('button',{name:'Schermvullend',exact:true}).click();await page.getByRole('combobox',{name:'Groep',exact:true}).selectOption(gid);await page.getByRole('checkbox',{name:'Alleen gekozen groep',exact:true}).check();await page.getByRole('checkbox',{name:'Alleen conflicten',exact:true}).check();
 const block=page.locator(`[data-visit-id="${visit.id}"]`);await block.scrollIntoViewIfNeeded();await expect(block).toHaveClass(/has-warning/);const start=(await block.boundingBox())!;const row=page.locator(`[data-portal-row="${target.id}"] .planboard-track`);const finish=(await row.boundingBox())!;
 await page.mouse.move(start.x+10,start.y+10);await page.mouse.down();await page.mouse.move(start.x+10,finish.y+40,{steps:10});await expect(block).toHaveCount(1);await expect(block).not.toHaveClass(/has-warning/);await page.keyboard.press('Escape');await page.mouse.up();await expect(page.getByRole('dialog')).toHaveCount(0);expect((await snapshot(client)).inputHash).toBe(before.inputHash);
});
test('real mobile touch opens details and touch cancellation leaves the server unchanged',async({browser})=>{
 const context=await browser.newContext({viewport:{width:390,height:844},hasTouch:true,isMobile:true,ignoreHTTPSErrors:true});const client=await login(context);const page=await context.newPage();
 const before=await snapshot(client);const visit=before.visits.find(v=>v.groupId===gid&&v.sequence===3&&v.editable)!;await page.goto('https://127.0.0.1:3443/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Live planbord',exact:true}).click();const block=page.locator(`[data-visit-id="${visit.id}"]`);await block.scrollIntoViewIfNeeded();await block.tap();await expect(page.getByRole('dialog',{name:/Bezoek/})).toBeVisible();await page.getByRole('dialog').getByRole('button',{name:'Sluiten',exact:true}).click();
 await block.scrollIntoViewIfNeeded();const box=(await block.boundingBox())!,cdp=await context.newCDPSession(page);const label=await page.locator(`[data-portal-row="${visit.portalId}"] .planboard-label`).boundingBox();const finger={x:Math.max(box.x+20,label!.x+label!.width+8),y:box.y+12,id:1};await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[finger]});await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{...finger,x:finger.x+30}]});await expect(block).toHaveClass(/is-dragging/);await cdp.send('Input.dispatchTouchEvent',{type:'touchCancel',touchPoints:[]});await expect(page.getByRole('dialog')).toHaveCount(0);expect((await snapshot(client)).inputHash).toBe(before.inputHash);await context.close();
});
test('archived portal is reachable through the real maintenance filter and saves only archive metadata',async({page,context,browser})=>{
 const client=await login(context);const created=await rpc(client,'admin_manual_portal_save',{_event_slug:event,_portal_id:null,_payload:{name:'Archief browserpoort',worldSlug:'anders',contactEmail:'parent-size-5@example.invalid',lifecycleStatus:'concept',approvalStatus:'draft',latitude:52.09,longitude:4.26,plannedOpensAt:'2026-10-31T16:00:00Z',plannedClosesAt:'2026-10-31T21:00:00Z'},_expected_version:null,_reason:'Synthetische actieve poort voor browseronderhoud'});
 const ownerContext=await browser.newContext({ignoreHTTPSErrors:true});await login(ownerContext,'parent-size-5@example.invalid');const ownerPage=await ownerContext.newPage();const token=sql(`select app_private.poortkamer_invite_token(id) from app_private.portal_team_invites where portal_id='${created.id}' and revoked_at is null order by created_at desc limit 1`);await ownerPage.goto(`https://127.0.0.1:3443/uitnodiging/poort/${token}`);await ownerPage.getByRole('button',{name:'Sleutel aannemen',exact:true}).click();await expect(ownerPage.getByRole('heading',{name:'Sleutel bevestigd',exact:true})).toBeVisible();await ownerContext.close();
 const activated=await rpc(client,'admin_manual_portal_save',{_event_slug:event,_portal_id:created.id,_payload:{name:'Archief browserpoort',worldSlug:'anders',contactEmail:'parent-size-5@example.invalid',lifecycleStatus:'active',approvalStatus:'approved',latitude:52.09,longitude:4.26,plannedOpensAt:'2026-10-31T16:00:00Z',plannedClosesAt:'2026-10-31T21:00:00Z'},_expected_version:created.version,_reason:'Na geverifieerde conceptuitnodiging bewust activeren'});
 const impact=await rpc(client,'admin_portal_change_impact',{_portal_id:created.id});await rpc(client,'admin_portal_remove_reviewed',{_portal_id:created.id,_expected_version:activated.version,_input_hash:impact.inputHash,_reason:'Synthetische poort voor archiefonderhoud intrekken',_key:randomUUID()});
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Poorten beheren',exact:true}).click();await page.getByRole('combobox',{name:'Poortrecords tonen',exact:true}).selectOption('archived');const card=page.locator('.manual-portal-list article').filter({hasText:'Archief browserpoort'});await expect(card).toBeVisible();await card.getByRole('button',{name:'Bewerken',exact:true}).click();const dialog=page.getByRole('dialog');await expect(dialog).toContainText('Deze poort blijft gearchiveerd');await dialog.getByRole('textbox',{name:'Telefoonnummer',exact:true}).fill('0612345678');await dialog.getByRole('button',{name:'Archiefgegevens opslaan',exact:true}).click();await expect(dialog).toHaveCount(0);expect(sql(`select contact_phone||':'||lifecycle_status from app_private.portals where id='${created.id}'`)).toBe('0612345678:archived');
});
test('archiving a future target retains its row, visit and visible domain conflict',async({page,context})=>{
 const client=await login(context),before=await snapshot(client),visit=before.visits.find(v=>v.groupId===gid&&v.sequence===3)!;
 const impact=await rpc(client,'admin_portal_change_impact',{_portal_id:visit.portalId});await rpc(client,'admin_portal_remove_reviewed',{_portal_id:visit.portalId,_expected_version:Number(sql(`select version from app_private.portals where id='${visit.portalId}'`)),_input_hash:impact.inputHash,_reason:'Synthetische toekomstige doelpoort intrekken en zichtbaar herstellen',_key:randomUUID()});
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:'Live planbord',exact:true}).click();await expect(page.locator(`[data-portal-row="${visit.portalId}"] .planboard-label`)).toContainText('Gearchiveerd');await expect(page.locator(`[data-visit-id="${visit.id}"]`)).toHaveClass(/has-warning/);
});
test('manual concept is visible in organization before mail confirmation',async({page,context})=>{
 const admin=await login(context);const name='Zichtbare conceptpoort browser';
 const created=await rpc(admin,'admin_manual_portal_save',{_event_slug:event,_portal_id:null,_payload:{name,worldSlug:'anders',contactEmail:'parent-size-5@example.invalid',lifecycleStatus:'concept',approvalStatus:'draft',commandKey:randomUUID()},_expected_version:null,_reason:'Synthetisch concept voor de echte beheerketen'});
 sql(`update app_private.email_outbox set status='unknown',last_error_code='WORKER_LEASE_EXPIRED_AFTER_CLAIM' where message_type='portal_manual_instructions' and payload->>'portalId'='${created.id}'`);
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:/^Conceptpoorten/}).click();
 const card=page.locator('.manual-portal-list article').filter({hasText:name});await expect(card).toBeVisible();await expect(card).toContainText('Verzending niet bevestigd');
 await card.getByRole('button',{name:'Bewerken',exact:true}).click();await expect(page.getByRole('dialog').getByRole('textbox',{name:'Poortnaam',exact:true})).toHaveValue(name);await page.keyboard.press('Escape');
 await page.reload();await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:/^Conceptpoorten/}).click();await expect(card).toBeVisible();
 const impact=await rpc(admin,'admin_portal_change_impact',{_portal_id:created.id});await rpc(admin,'admin_portal_remove_reviewed',{_portal_id:created.id,_expected_version:Number(sql(`select version from app_private.portals where id='${created.id}'`)),_input_hash:impact.inputHash,_reason:'Synthetisch concept na de browsercontrole archiveren',_key:randomUUID()});
});

test('a stale maintenance form keeps input until an explicit current-version reload, then saves again',async({page,context})=>{
 const admin=await login(context),name='Versieherstel browserpoort';
 const created=await rpc(admin,'admin_manual_portal_save',{_event_slug:event,_portal_id:null,_payload:{name,worldSlug:'anders',lifecycleStatus:'concept',approvalStatus:'draft',commandKey:randomUUID()},_expected_version:null,_reason:'Synthetische conceptpoort voor expliciet formulierherstel'});
 await page.goto('/admin');await selectOrganizationSection(page,'Poorten');await page.getByRole('tab',{name:/^Conceptpoorten/}).click();
 await page.locator('.manual-portal-list article').filter({hasText:name}).getByRole('button',{name:'Bewerken',exact:true}).click();
 const dialog=page.locator('.manual-portal-editor');await dialog.getByRole('textbox',{name:'Poortnaam',exact:true}).fill('Mijn nog niet opgeslagen invoer');
 await rpc(admin,'admin_manual_portal_save',{_event_slug:event,_portal_id:created.id,_payload:{name:'Intussen opgeslagen actuele naam',worldSlug:'anders',saveMode:'draft',commandKey:randomUUID()},_expected_version:created.version,_reason:'Een tweede bewerking maakt het geopende formulier verouderd'});
 await dialog.getByRole('button',{name:'Concept opslaan',exact:true}).click();await expect(dialog.getByRole('button',{name:'Actuele versie laden en opnieuw beoordelen'})).toBeVisible();
 await expect(dialog.getByRole('textbox',{name:'Poortnaam',exact:true})).toHaveValue('Mijn nog niet opgeslagen invoer');
 await dialog.getByRole('button',{name:'Actuele versie laden en opnieuw beoordelen'}).click();await expect(dialog.getByRole('textbox',{name:'Poortnaam',exact:true})).toHaveValue('Intussen opgeslagen actuele naam');
 await dialog.getByRole('textbox',{name:'Poortnaam',exact:true}).fill('Na actuele beoordeling opgeslagen');await dialog.getByRole('button',{name:'Concept opslaan',exact:true}).click();await expect(dialog).toHaveCount(0);
 expect(sql(`select payload->>'name' from app_private.portal_maintenance_drafts where portal_id='${created.id}'`)).toBe('Na actuele beoordeling opgeslagen');
});
