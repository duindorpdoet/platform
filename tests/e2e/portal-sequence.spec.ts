import { test, expect, type BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { mkdir } from "node:fs/promises";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";

const url=process.env.NEXT_PUBLIC_SUPABASE_URL, key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const event="duindorp-halloween-2026",groupId="23000000-0000-0000-0000-000000000001",pointId="20000000-0000-0000-0000-000000000001";
async function login(context:BrowserContext,email:string){
  const client=createClient(url!,key!,{auth:{persistSession:false,autoRefreshToken:false}});
  const result=await client.auth.signInWithPassword({email,password:"local-test-only"});expect(result.error).toBeNull();
  await prepareFixtureGuidance(client);
  const name=`sb-${new URL(url!).hostname.split(".")[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:"http://127.0.0.1:3100",sameSite:"Lax" as const})));
  return client;
}

test("mobile organization and participant complete the destination sequence with no street network or directions service",async({page,context,browser})=>{
  test.skip(!url||!key,"Requires isolated real Auth and database");test.setTimeout(180_000);requireLocalTogetherDatabase();
  // Only this isolated synthetic event is changed. Yesterday's selectable start
  // is always in the past; no clock override or publication backdoor is needed.
  sql(`update app_private.walking_edges set approved_at=null;
    update app_private.walking_nodes set verified_at=null;
    update app_private.start_points set walking_node_id=null,verified_at=null,version=version+1;
    update app_private.start_points set name='Horror Zone',public_label='Horor zone' where id='${pointId}';
    update app_private.events set local_date=(clock_timestamp() at time zone 'Europe/Amsterdam')::date-1 where slug='${event}';
    update app_private.portal_windows set opens_at=date_trunc('day',clock_timestamp())-interval '36 hours',closes_at=date_trunc('day',clock_timestamp())+interval '36 hours';
    update app_private.event_route_settings set planner_mode='dynamic',first_start_at=date_trunc('day',clock_timestamp())-interval '36 hours',
      global_ordinary_stop_at=clock_timestamp()+interval '1 hour',preferred_start_min_local='17:30',preferred_start_max_local='18:30',preferred_start_step_minutes=30,
      final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '4 hours',
      finale_closes_at=clock_timestamp()+interval '5 hours',finale_available=true,finale_max_concurrent_groups=10,finale_max_concurrent_children=100,
      ordinary_visit_seconds=60,route_buffer_seconds=0;
    update app_private.walking_groups set desired_ordinary_visits=2 where id='${groupId}';`);
  let providerCalls=0;
  await context.route(/directions|route\.project-osrm|api\.openrouteservice/,async route=>{providerCalls++;await route.fulfill({status:503,body:"Synthetic provider unavailable"});});
  const admin=await login(context,"admin@example.invalid");
  const created=await admin.schema("api").rpc("admin_startregie_start_point_save",{_event_slug:event,_point_id:null,_expected_version:null,
    _payload:{name:"Welcome to the Freakshow",publicLabel:"Welcome to the Freakshow",pointType:"gathering",privateAddress:"FICTIEF STARTADRES",geocodedLatitude:52.10,geocodedLongitude:4.27,active:true,maxGroups:1,maxChildren:30},
    _reason:"Afzonderlijke synthetische locatie voor de handmatige markerproef"});expect(created.error).toBeNull();
  const snapshot=async()=>{const r=await admin.schema("api").rpc("admin_startregie_snapshot",{_event_slug:event});expect(r.error).toBeNull();return r.data;};
  const initial=await snapshot(),unassigned=initial.ops.groups.filter((g:{state:string})=>g.state==="unassigned").length;
  await page.setViewportSize({width:390,height:844});await page.goto("/admin");await selectOrganizationSection(page,"Startregie");
  await expect(page.getByText(/Wandelroute ontbreekt|wandelnetwerk aansluiten|wandelroute nog aansluiten/i)).toHaveCount(0);
  await page.getByRole("tab",{name:"Kaart",exact:true}).click();
  await page.getByRole("combobox",{name:"Locatie bewerken"}).selectOption(`start|${pointId}`);
  const editor=page.getByRole("region",{name:"Locatie-editor voor Startpunt · Horor zone"});
  await expect(editor).toContainText("officiële adrespositie");await editor.getByRole("button",{name:"Deze marker bevestigen"}).click();
  await expect(editor).toContainText("Locatie bevestigd");
  const manualPoint=(await snapshot()).startPoints.find((p:{id:string})=>p.id===created.data.id);
  const manual=await admin.schema("api").rpc("admin_location_marker_save",{_event_slug:event,_resource_type:"start_point",_resource_id:manualPoint.id,_latitude:52.101234,_longitude:4.271234,_reason:"Gecontroleerde synthetische handmatige startmarker",_restore_from_address:false,_expected_version:manualPoint.version});
  expect(manual.error).toBeNull();
  expect((await admin.schema("api").rpc("admin_startregie_confirm_point",{_event_slug:event,_point_id:manualPoint.id,_expected_version:manual.data.version})).error).toBeNull();
  await page.getByRole("tab",{name:"Indeling",exact:true}).click();
  const group=(await snapshot()).groups.find((g:{id:string})=>g.id===groupId);
  const card=page.locator(".start-ops-assignment").filter({has:page.getByText(group.systemCode,{exact:true})});
  await card.getByRole("combobox",{name:`Startpunt voor ${group.systemCode}`}).selectOption(pointId);
  await card.getByRole("combobox",{name:`Starttijd voor ${group.systemCode}`}).selectOption({label:"17:30 uur"});
  await card.getByRole("button",{name:"Concept opslaan"}).click();
  await card.getByRole("button",{name:"Start bevestigen"}).click();
  await card.getByRole("button",{name:"Poortvolgorde controleren"}).click();
  const preview=page.getByRole("dialog");await expect(preview).toContainText("Privé poortvolgorde");await expect(preview).toContainText("hemelsbreed");
  expect(await preview.locator(".start-ops-route-stops li").count()).toBeGreaterThan(2);await assertReadableLayout(page);
  await mkdir("docs/ops/screenshots",{recursive:true});await page.screenshot({path:"docs/ops/screenshots/sequence-admin-390.png"});
  await page.keyboard.press("Escape");await card.getByRole("checkbox").check();
  await page.getByRole("button",{name:"1 starttijd(en) publiceren"}).click();await page.getByRole("dialog").getByRole("button",{name:"Starttijden publiceren",exact:true}).click();
  await expect(card).toContainText("Starttijd gepubliceerd");await page.reload();await expect(card).toContainText("Starttijd gepubliceerd");
  const after=await snapshot();expect(after.ops.groups.filter((g:{state:string})=>g.state==="unassigned")).toHaveLength(unassigned-1);
  expect(after.startPoints.find((p:{id:string})=>p.id===manualPoint.id).readiness.location.source).toBe("manual");
  expect(after.startPoints.find((p:{id:string})=>p.id===pointId).confirmed).toBe(true);
  const second=await browser.newContext({viewport:{width:390,height:844}});await login(second,"admin@example.invalid");
  const secondPage=await second.newPage();await secondPage.goto("/admin");await selectOrganizationSection(secondPage,"Startregie");
  await expect(secondPage.locator(".start-ops-assignment").filter({has:secondPage.getByText(group.systemCode,{exact:true})})).toContainText("Starttijd gepubliceerd");await second.close();

  const participant=await browser.newContext({viewport:{width:390,height:844}});
  await participant.route(/directions|route\.project-osrm|api\.openrouteservice/,async route=>{providerCalls++;await route.fulfill({status:503,body:"Synthetic provider unavailable"});});
  const leader=await login(participant,"leader-a@example.invalid"),routePage=await participant.newPage();
  routePage.on("dialog",dialog=>dialog.accept());await routePage.goto("/mijn-groep");
  await routePage.locator(".attendance-row label.present").first().click();
  await routePage.getByRole("button",{name:"Start groep met 1 aanwezig"}).click();
  await expect(routePage.locator("#route-destination h2")).toBeVisible();await assertReadableLayout(routePage);
  const current=async()=>{const r=await leader.schema("api").rpc("group_snapshot",{_group_id:groupId});expect(r.error).toBeNull();return r.data;};
  const first=await current(),stop=first.run.currentStop;
  expect(JSON.stringify(first)).not.toContain('"candidate_summary"');expect(first.ops).toBeUndefined();
  expect(first.run.nextStop).toBeFalsy();
  for(const future of after.ops.routes[groupId].stops.filter((candidate:{portalId:string})=>candidate.portalId!==stop.portal.id)){
    expect(JSON.stringify(first)).not.toContain(future.portalId);expect(JSON.stringify(first)).not.toContain(future.address);
  }
  await expect(routePage.locator(".participant-route-map .maplibregl-marker")).toHaveCount(1);
  await expect(routePage.locator(".participant-route-map .maplibregl-marker")).toBeVisible();
  await routePage.screenshot({path:"docs/ops/screenshots/sequence-current-390.png",fullPage:true});
  const code=sql(`select 'TEST-'||right('${stop.portal.id}',2)`);
  await routePage.getByRole("textbox",{name:"Korte poortcode"}).fill(code);await routePage.getByRole("button",{name:"Code controleren",exact:true}).click();
  const arrivalDialog=routePage.getByRole("dialog");await expect(arrivalDialog).toContainText("Aangekomen bij");
  await arrivalDialog.getByRole("checkbox").first().uncheck();
  let pendingArrival:Promise<void>|null=null;let allowArrival:()=>void=()=>{};let arrivalArgs:Record<string,unknown>={};
  await participant.route("**/rpc/run_arrive_and_advance",async request=>{arrivalArgs=request.request().postDataJSON();pendingArrival=new Promise<void>(resolve=>{allowArrival=resolve;});await pendingArrival;await request.continue();});
  await arrivalDialog.getByRole("button",{name:"Aankomst bevestigen & volgende poort"}).click();
  await expect.poll(()=>pendingArrival!==null).toBe(true);
  expect((await current()).run.currentStop.id).toBe(stop.id);await expect(routePage.locator("#route-destination h2")).toHaveText(stop.portal.name);
  expect(sql(`select count(*) from app_private.run_stop_arrivals where run_id='${first.run.id}'`)).toBe("0");
  const retries=Promise.all([leader.schema("api").rpc("run_arrive_and_advance",arrivalArgs),leader.schema("api").rpc("run_arrive_and_advance",arrivalArgs)]);
  allowArrival();for(const retry of await retries)expect(retry.error).toBeNull();await expect(arrivalDialog).not.toBeVisible();
  await expect.poll(async()=>(await current()).run.currentStop.id).not.toBe(stop.id);
  const next=await current();await expect(routePage.locator("#route-destination h2")).toHaveText(next.run.currentStop.portal.name);
  expect(next.run.currentStop.portal.address).toBeTruthy();expect(next.run.currentStop.portal.coordinate).toHaveLength(2);
  expect(sql(`select count(*) from app_private.poortenboek_passport_seals where run_id='${first.run.id}'`)).toBe("1");
  expect(sql(`select count(*) from app_private.run_stops where run_id='${first.run.id}'`)).toBe("2");
  expect(providerCalls).toBe(0);await assertReadableLayout(routePage);await expect(routePage.locator(".participant-route-map .maplibregl-marker")).toHaveCount(1);
  await expect(routePage.locator(".participant-route-map .maplibregl-marker")).toHaveAttribute("aria-label",new RegExp(next.run.currentStop.portal.name));
  await expect(routePage.locator(".participant-route-map .maplibregl-marker")).toBeVisible();
  await routePage.screenshot({path:"docs/ops/screenshots/sequence-next-390.png",fullPage:true});
  await participant.close();
});
