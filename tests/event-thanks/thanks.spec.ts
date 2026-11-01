import{test,expect,Page}from'@playwright/test';
const portalId='e1000000-0000-4000-8000-000000000001',portalTwo='e1000000-0000-4000-8000-000000000002';
const portals=[{id:portalId,name:'De warme pompoen',world:'Duinwereld'},{id:portalTwo,name:'Het spookhuis',world:'Spookwereld'}];
type Submission={id:string;kind:string;portalId:string|null;choice:string|null;message:string;createdAt:string;targetCount:number;processedCount:number};
async function family(page:Page,options:{failFirst?:boolean;invalidSuccess?:boolean;legacy?:boolean}={}){
 const requests:Record<string,unknown>[]=[],submissions:Submission[]=[];let reads=0;
 await page.route('**/api/redesign/thanks?*',route=>{reads++;return route.fulfill({json:{closed:true,finished:true,portals,submissions,saved:options.legacy?[{portalId,choice:'beautiful'}]:[]}});});
 await page.route('**/api/redesign/thanks-closed',async route=>{
  const data=route.request().postDataJSON();requests.push(data);
  if(options.failFirst&&requests.length===1){await route.abort('failed');return;}
  if(options.invalidSuccess&&requests.length<=2){await route.fulfill({json:requests.length===1?{ok:false,id:portalId}:{ok:true}});return;}
  const old=submissions.find(s=>s.id===data.submissionId||(s.kind===data.kind&&s.portalId===data.portalId));
  if(old){if(data.submissionId)Object.assign(old,{message:data.message,choice:data.choice});}
  else submissions.push({id:crypto.randomUUID(),...data,createdAt:new Date().toISOString(),targetCount:data.kind==='all'?2:1,processedCount:data.kind==='all'?2:1});
  await route.fulfill({json:{ok:true,id:old?.id??submissions.at(-1)?.id}});
 });
 await page.goto('/');await expect(page.getByRole('heading',{name:'Bedank de huizen van Duindorp'})).toBeVisible();
 return{requests,submissions,readCount:()=>reads};
}
test('opening, editing and cancelling the general form creates no request',async({page})=>{
 const state=await family(page);await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();
 await expect(page.getByText('2 deelnemende huizen ontvangen jullie bedankje.')).toBeVisible();
 await page.getByLabel('Jullie bericht').fill('Een eigen aanvulling\nMet een tweede regel.');await page.getByRole('button',{name:'Annuleren',exact:true}).click();expect(state.requests).toHaveLength(0);
});
test('one conscious general confirmation stores editable text once',async({page})=>{
 const state=await family(page);await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();
 await page.getByLabel('Jullie bericht').fill('Dank jullie wel!\nEen eigen alinea.');await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).dblclick();
 await expect(page.getByText('Jullie bedankje voor alle huizen is opgeslagen.',{exact:false})).toBeVisible();expect(state.requests).toHaveLength(1);expect(state.requests[0].message).toBe('Dank jullie wel!\nEen eigen alinea.');
});
test('a failed/unknown transport outcome retries only the same durable request',async({page})=>{
 const state=await family(page,{failFirst:true});await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).click();
 await expect(page.getByRole('alert')).toContainText('Bewaren is nog niet bevestigd');expect(state.requests).toHaveLength(1);
 await expect(page.getByLabel('Jullie bericht')).toBeDisabled();await page.getByRole('button',{name:'Dezelfde aanvraag opnieuw proberen'}).click();await expect(page.getByText('Jullie bedankje voor alle huizen is opgeslagen.',{exact:false})).toBeVisible();
 expect(state.requests).toHaveLength(2);expect(state.requests[1]).toEqual(state.requests[0]);
});
test('a malformed HTTP 200 never claims a saved mutation and retains its durable retry identity',async({page})=>{
 const state=await family(page,{invalidSuccess:true});await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).click();
 await expect(page.getByRole('alert')).toContainText('Bewaren is nog niet bevestigd');await expect(page.getByText('Jullie bedankje voor alle huizen is opgeslagen.',{exact:false})).toHaveCount(0);expect(state.submissions).toHaveLength(0);
 await page.getByRole('button',{name:'Dezelfde aanvraag opnieuw proberen'}).click();await expect(page.getByRole('alert')).toContainText('Bewaren is nog niet bevestigd');expect(state.submissions).toHaveLength(0);
 await page.getByRole('button',{name:'Dezelfde aanvraag opnieuw proberen'}).click();await expect(page.getByText('Jullie bedankje voor alle huizen is opgeslagen.',{exact:false})).toBeVisible();expect(state.submissions).toHaveLength(1);expect(state.requests).toHaveLength(3);expect(state.requests[1]).toEqual(state.requests[0]);expect(state.requests[2]).toEqual(state.requests[0]);
});
test('general and extra personal thanks coexist with historical reactions',async({page})=>{
 const state=await family(page,{legacy:true});await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).click();
 await page.getByRole('button',{name:'Geef een huis een extra bedankje'}).click();await page.getByLabel('Zoek een deelnemend huis').fill('pompoen');await page.getByLabel('Kies een huis').selectOption(portalId);
 await page.getByLabel('Persoonlijk bericht (optioneel)').fill('<script>Dit blijft tekst</script>');await page.getByRole('button',{name:'Bewaar extra bedankje'}).click();
 await expect(page.locator('#thanks-sent-history')).toContainText('Aan alle huizen');
 expect(state.submissions.map(s=>s.kind)).toEqual(['all','personal']);await expect(page.locator('#thanks-sent-history')).toContainText('<script>Dit blijft tekst</script>');expect(await page.evaluate(()=>document.querySelectorAll('script:not([type="module"])').length)).toBe(0);
 await page.getByText('Eerder tijdens de avond bewaard (1)').click();await expect(page.locator('details')).toContainText('Bedankt voor jullie mooie poort!');
});
test('editing sends an explicit update for the same submission',async({page})=>{
 const state=await family(page);await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).click();
 await page.getByRole('button',{name:'Algemeen bedankje bekijken of aanpassen'}).click();await expect(page.getByText('Aanpassen wijzigt het bericht in de Poortkamer en verstuurt geen nieuwe e-mail.')).toBeVisible();await page.getByLabel('Jullie bericht').fill('Een aangepast bericht.');await page.getByRole('button',{name:'Wijziging bewaren'}).click();
 expect(state.submissions).toHaveLength(1);expect(state.requests[1].submissionId).toBe(state.submissions[0].id);await expect(page.locator('#thanks-sent-history')).toContainText('Een aangepast bericht.');
});
test('the textarea bounds optional text to five hundred characters',async({page})=>{
 await family(page);await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();await expect(page.getByLabel('Jullie bericht')).toHaveAttribute('maxlength','500');
});
test('a default general thank is editable, explained as a counter without mail and confirmed only as saved',async({page})=>{
 const state=await family(page);await page.getByRole('button',{name:'Bedank alle huizen',exact:true}).click();
 await expect(page.getByLabel('Jullie bericht')).toHaveValue('Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃');
 await expect(page.getByText('Een standaardbedankje telt mee in de Poortkamer, zonder losse berichten of e-mail.',{exact:false})).toBeVisible();
 await page.getByRole('button',{name:'Bewaar voor alle huizen',exact:true}).click();await expect(page.getByRole('status')).toHaveText('Jullie bedankje voor alle huizen is opgeslagen.');
 expect(state.requests).toHaveLength(1);await expect(page.getByRole('status')).not.toContainText('e-mail');
});
test('aggregate-only house thanks show totals and choice counts without individual default messages or unread items',async({page})=>{
 await page.route('**/api/redesign/thanks?*',route=>route.fulfill({json:{thanks:[{portalId,portalName:'De warme pompoen',choice:'treats'}]}}));
 await page.route('**/api/redesign/thanks-inbox?*',route=>route.fulfill({json:{portalId,portalName:'De warme pompoen',total:42,unread:0,counters:{general:40,personal:2,beautiful:1,welcome:0,treats:1},aggregateOnlyCount:42,customMessageCount:0,messages:[],nextCursor:null}}));
 await page.goto('/?house');await expect(page.getByRole('heading',{name:'Persoonlijke berichten (0)'})).toBeVisible();
 const totals=page.locator('[aria-label="Alle ontvangen bedankjes"]');await expect(totals).toContainText('40Algemene bedankjes');await expect(totals).toContainText('42Bedankjes zonder eigen tekst');
 await expect(page.getByText('Er zijn nog geen eigen aanvullende berichten.',{exact:false})).toBeVisible();await expect(page.getByRole('button',{name:'Markeer als gelezen'})).toHaveCount(0);
 await expect(page.getByText('Een gezin uit Duindorp',{exact:false})).toHaveCount(0);await expect(page.getByText('gezin heeft jullie bedankt.',{exact:false})).toBeVisible();
});
test('a delayed inbox response from the previous portal never restores its private message',async({page})=>{
 let release:()=>void=()=>{};const hold=new Promise<void>(resolve=>{release=resolve;});let started=false;
 await page.route('**/api/redesign/thanks?*',route=>route.fulfill({json:{thanks:[]}}));
 await page.route('**/api/redesign/thanks-inbox?*',async route=>{
  const previous=new URL(route.request().url()).searchParams.get('portalId')===portalId;
  if(previous){started=true;await hold;}
  await route.fulfill({json:{portalId:previous?portalId:portalTwo,portalName:previous?'Vorige poort':'Nieuwe poort',total:1,unread:1,counters:{general:0,personal:1,beautiful:1,welcome:0,treats:0},aggregateOnlyCount:0,customMessageCount:1,messages:[{id:previous?portalId:portalTwo,kind:'personal',choice:'beautiful',message:previous?'PRIVATE OLD PORTAL':'Bericht voor de nieuwe poort',senderLabel:'Een gezin uit Duindorp',receivedAt:new Date().toISOString(),read:false,missingContacts:0,mailCounts:{}}],nextCursor:null}});
 });
 await page.goto('/?house');await expect.poll(()=>started).toBe(true);await page.evaluate(id=>window.thanksHarness.mountHouse(id),portalTwo);
 await expect(page.getByText('Bericht voor de nieuwe poort')).toBeVisible();release();await page.waitForResponse(response=>response.url().includes('thanks-inbox')&&new URL(response.url()).searchParams.get('portalId')===portalId);
 await expect(page.getByText('PRIVATE OLD PORTAL')).toHaveCount(0);await expect(page.getByText('Bericht voor de nieuwe poort')).toBeVisible();
});
test('resident inbox shows private-safe types, pagination and persistent read requests',async({page})=>{
 const readRequests:string[]=[];let marked=false;
 const first={id:portalId,kind:'all',choice:null,message:'Bedankt allemaal',senderLabel:'Een gezin uit Duindorp',receivedAt:new Date().toISOString(),read:false,missingContacts:1,mailCounts:{pending:1}};
 await page.route('**/api/redesign/thanks?*',route=>route.fulfill({json:{thanks:[],familyCount:0}}));
 await page.route('**/api/redesign/thanks-inbox?*',route=>route.fulfill({json:{portalId,portalName:'De warme pompoen',total:12,counters:{general:10,personal:2,beautiful:2,welcome:0,treats:0},aggregateOnlyCount:10,customMessageCount:2,unread:marked?1:2,messages:new URL(route.request().url()).searchParams.has('before')?[{...first,id:portalTwo,kind:'personal',message:'Een extra dank',missingContacts:0}]:[{...first,read:marked}],nextCursor:new URL(route.request().url()).searchParams.has('before')?null:portalId}}));
 await page.route('**/api/redesign/thanks-read',route=>{readRequests.push(route.request().postDataJSON().receiptId);marked=true;return route.fulfill({json:{ok:true}});});
 await page.goto('/?house');await expect(page.getByRole('heading',{name:'Bedankjes van deelnemers'})).toBeVisible();await expect(page.getByText('Eigen bericht aan alle huizen · Nieuw')).toBeVisible();await expect(page.getByText('Een gezin uit Duindorp',{exact:false})).toBeVisible();await expect(page.getByText('Voor 1 actieve eigenaar(s)',{exact:false})).toBeVisible();await expect(page.getByText('In wachtrij: 1',{exact:false})).toBeVisible();
 await page.getByRole('button',{name:'Markeer als gelezen'}).click();expect(readRequests).toEqual([portalId]);await page.getByRole('button',{name:'Meer bedankjes laden'}).click();await expect(page.getByText('Extra persoonlijk bedankje · Nieuw')).toBeVisible();await expect(page.getByText('Een extra dank')).toBeVisible();
});
