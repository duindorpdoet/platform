import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";
import type { BoardSnapshot } from "../../lib/domain/live-planboard";
import type { JointRouteInput, JointRouteProposal } from "../../lib/domain/joint-route-planner";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const event = "duindorp-halloween-2026", firstPortal = "12000000-0000-0000-0000-000000000001", finalPortal = "12000000-0000-0000-0000-000000000030";
test.describe.configure({ mode: "serial" });
test.beforeEach(() => { test.skip(!url || !key, "Requires isolated real Auth and database"); requireLocalTogetherDatabase(); });
async function login(context: BrowserContext, baseURL: string, email = "admin@example.invalid") {
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email, password: "local-test-only" }); expect(signed.error).toBeNull(); await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: value.length <= 3180 ? name : `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180), url: baseURL, sameSite: "Lax" as const })));
  return client;
}
async function rpc<T>(client: SupabaseClient, name: string, args: Record<string, unknown>): Promise<T> { const result = await client.schema("api").rpc(name, args); expect(result.error, name).toBeNull(); return result.data as T; }
async function snapshot(client: SupabaseClient): Promise<BoardSnapshot> {
  for (let attempt = 0; attempt < 100; attempt++) { const board = await rpc<BoardSnapshot>(client, "admin_live_planboard_snapshot", { _event_slug: event }); if (!board.initializationPending) return board; }
  throw new Error("Synthetic board initialization did not finish");
}
function invariants() {
  return JSON.parse(sql(`select jsonb_build_object(
    'publishedStarts',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id)::text,'')) from app_private.group_start_publications p),
    'scheduleTimes',(select md5(coalesce(jsonb_agg(jsonb_build_array(s.id,s.revision,s.state,s.start_slot_id,slot.start_point_id,slot.starts_at,s.effective_ordinary_stop_at,s.expected_finale_arrival_at) order by s.id)::text,'')) from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id),
    'families',(select md5(coalesce(jsonb_agg(to_jsonb(g) order by g.id)::text,'')) from app_private.group_registrations g),
    'children',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id)::text,'')) from app_private.children c),
    'payments',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id)::text,'')) from app_private.payment_requests p),
    'mail',(select count(*) from app_private.email_outbox),
    'runs',(select count(*) from app_private.group_runs where started_at is not null))`));
}
function setup() {
  const starts = new Date(Math.ceil((Date.now() + 20 * 60_000) / 600_000) * 600_000).toISOString();
  const helper = readFileSync("scripts/acceptance/fixtures/registration-management.sql", "utf8");
  const joint = readFileSync("supabase/tests/helpers/joint-route-fixture.inc", "utf8").replace(/^\\ir registration-management\.inc$/m, "");
  sql(`${helper}\n${joint}
    do $fixture$ declare fixture jsonb; begin
      fixture:=pg_temp.joint_canonical_fixture('${starts}'::timestamptz);
      update app_private.children set step_free_required=false where household_id in(select household_id from app_private.registrations where reference like 'FIXTURE-%');
      update app_private.portals set accessibility_status='step_free',arrival_headway_seconds=300,ordinary_end_grace_seconds=300,ordinary_hard_close=false where id::text like '12000000-0000-0000-0000-%';
      update app_private.walking_groups set desired_ordinary_visits=6 where id::text like '23000000-0000-0000-0000-%';
      update app_private.portal_windows set opens_at='${starts}'::timestamptz-interval '1 hour',closes_at='${starts}'::timestamptz+interval '5 hours',visit_minutes=5,buffer_minutes=0 where portal_id::text like '12000000-0000-0000-0000-%';
      update app_private.portal_windows set visit_minutes=6,buffer_minutes=2 where portal_id='${finalPortal}';
      update app_private.event_route_settings set finale_max_concurrent_groups=1 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
      -- The initial stored route is explicitly reviewed fixture input. A read is
      -- forbidden to generate it; the tested UI must produce a separate proposal.
      perform api.admin_joint_route_plan_apply('duindorp-halloween-2026',pg_temp.joint_proposal(),true,'Synthetisch expliciet beoordeeld beginconcept voor echte tijdgrafiek en vergelijking','0cca0000-0000-4000-8000-000000000001');
    end $fixture$;`);
}
async function openBoard(page: Page) { await page.goto("/admin"); await selectOrganizationSection(page, "Poorten"); await page.getByRole("tab", { name: "Live planbord", exact: true }).click(); await expect(page.locator(".planboard-row").first()).toBeVisible(); }

// This fixture contains only local synthetic seed identities, never production participants.
test("a joint proposal is read-only until reviewed draft apply, and true timebars stay six minutes at every zoom", async ({ page, context, baseURL }) => {
  test.setTimeout(120_000); setup(); const client = await login(context, baseURL!), before = await snapshot(client), saved = invariants();
  await openBoard(page);
  const finale = before.visits.find(visit => visit.portalId === finalPortal && visit.kind === "finale")!; expect(finale).toBeTruthy(); expect(finale.durationSeconds).toBe(360);
  const service = page.locator(`[data-service-bar="${finale.id}"]`), buffer = page.locator(`[data-buffer-bar="${finale.id}"]`);
  async function exactBar() {
    const ticks = await page.locator(".planboard-axis [data-axis-at]").evaluateAll(elements => elements.slice(0, 2).map(element => ({ at: Number((element as HTMLElement).dataset.axisAt), left: (element as HTMLElement).offsetLeft })));
    expect(ticks).toHaveLength(2); const scale = (ticks[1].left - ticks[0].left) / ((ticks[1].at - ticks[0].at) / 60_000);
    expect((await service.boundingBox())!.width).toBeCloseTo(6 * scale, 0); expect((await buffer.boundingBox())!.width).toBeCloseTo(2 * scale, 0);
  }
  await exactBar(); const lane = await page.locator(`[data-visit-id="${finale.id}"]`).getAttribute("data-physical-lane");
  await page.getByRole("button", { name: "Inzoomen", exact: true }).click(); await exactBar(); await expect(page.locator(`[data-visit-id="${finale.id}"]`)).toHaveAttribute("data-physical-lane", lane!);
  await page.getByRole("button", { name: "Hele avond passend", exact: true }).click(); await exactBar();
  const noBuffer = before.visits.find(visit => visit.kind === "ordinary" && visit.bufferSeconds === 0)!; expect(noBuffer).toBeTruthy();
  expect(await page.locator(`[data-buffer-bar="${noBuffer.id}"]`).evaluate(element => element.getBoundingClientRect().width)).toBe(0);
  const row = page.locator(`[data-portal-row="${finalPortal}"]`); await row.getByRole("button", { name: /Bekijk \d+ bezoeken/ }).click(); const list = page.getByRole("dialog", { name: /Bezoeken/ });
  const touch = list.getByRole("button", { name: new RegExp(before.groups.find(group => group.id === finale.groupId)!.code) }).first(); expect((await touch.boundingBox())!.height).toBeGreaterThanOrEqual(44); await touch.click();
  const detail = page.getByRole("dialog", { name: /Bezoek/ }); await expect(detail).toContainText("Einde fysieke bezetting, inclusief wisseltijd"); await expect(detail).toContainText("minimale aankomstafstand"); await detail.getByRole("button", { name: "Sluiten", exact: true }).click();
  const response = page.waitForResponse(response => response.url().endsWith("/api/admin/routes/proposal") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Routes opnieuw berekenen met bevestigde starts", exact: true }).click(); const computed = await response; expect(computed.status()).toBe(200); const proposal = (await computed.json()).data as JointRouteProposal;
  expect(proposal.valid, JSON.stringify(proposal.conflicts)).toBe(true); expect(proposal.groups).toHaveLength(4); expect(proposal.metrics.after.zeroVisitGroups).toBe(0);
  expect(invariants()).toEqual(saved); expect((await snapshot(client)).inputHash).toBe(before.inputHash);
  const dialog = page.getByRole("dialog", { name: "Gezamenlijk routevoorstel controleren", exact: true }); await expect(dialog).toContainText("Einde gewone poorten"); await expect(dialog).toContainText("Onbenutte tijd vóór vaste finale");
  const save = dialog.getByRole("button", { name: "Beoordeeld routeconcept opslaan", exact: true }); await expect(save).toBeDisabled(); await dialog.getByRole("textbox").fill("Synthetisch beoordeeld gezamenlijk routeconcept met behoud van starts"); await dialog.getByRole("checkbox").check(); await expect(save).toBeEnabled(); await save.click(); await expect(dialog).toHaveCount(0);
  await expect(page.getByRole("status").filter({ hasText: /Routeconcept .*opgeslagen/ })).toBeVisible(); expect(invariants()).toEqual(saved);
  const accepted = await snapshot(client), input = await rpc<JointRouteInput>(client, "admin_joint_route_planning_input", { _event_slug: event });
  function routeRows(groups: JointRouteInput["before"]) { return groups.flatMap(group => group.visits.filter(visit => visit.kind !== "start").map(visit => ({ group: group.groupId, portal: visit.portalId, kind: visit.kind, sequence: visit.sequence, at: Date.parse(visit.startsAt), seconds: visit.visitSeconds, buffer: visit.bufferSeconds }))).sort((a, b) => a.group.localeCompare(b.group) || a.sequence - b.sequence); }
  expect(routeRows(input.before)).toEqual(routeRows(proposal.groups));
  expect(accepted.visits.filter(visit => visit.kind !== "start").map(visit => ({ group: visit.groupId, portal: visit.portalId, kind: visit.kind, sequence: visit.sequence, at: Date.parse(visit.startsAt), seconds: visit.durationSeconds, buffer: visit.bufferSeconds })).sort((a,b)=>a.group.localeCompare(b.group)||a.sequence-b.sequence)).toEqual(routeRows(proposal.groups));
  await assertReadableLayout(page);
});

test("actual owner policy controls preserve input on retry and a policy change invalidates a frozen route proposal", async ({ page, context, browser, baseURL }) => {
  test.setTimeout(120_000); const admin = await login(context, baseURL!), saved = invariants(); await openBoard(page);
  const response = page.waitForResponse(response => response.url().endsWith("/api/admin/routes/proposal") && response.request().method() === "POST"); await page.getByRole("button", { name: "Routes opnieuw berekenen met bevestigde starts", exact: true }).click(); const proposal = (await (await response).json()).data as JointRouteProposal;
  const dialog = page.getByRole("dialog", { name: "Gezamenlijk routevoorstel controleren", exact: true }); await dialog.getByRole("textbox").fill("Dit bevroren voorstel moet na een beleidswijziging ongeldig zijn"); await dialog.getByRole("checkbox").check();
  const ownerContext = await browser.newContext({ viewport: page.viewportSize() ?? undefined });
  try {
    await login(ownerContext, baseURL!, "owner@example.invalid"); const owner = await ownerContext.newPage(); await owner.goto(`${baseURL}/mijn-huis?poort=${firstPortal}`); await owner.getByRole("button", { name: "Meer", exact: true }).click(); await owner.getByRole("button", { name: "Instellingen", exact: true }).click();
    await owner.getByRole("button", { name: "Ontvangstbeleid wijzigen", exact: true }).click(); const form = owner.locator(".portal-planning-policy-editor"); await form.getByRole("combobox", { name: "Minimale afstand tussen groepsaankomsten", exact: true }).selectOption("600"); await form.getByRole("checkbox", { name: /Harde sluiting/ }).check(); await expect(form.getByRole("combobox", { name: "Toegestane einduitloop voor bezoek en wisseltijd", exact: true })).toBeDisabled();
    const commands: Array<Record<string, unknown>> = []; let rejectOnce = true; await owner.route("**/rest/v1/rpc/portal_planning_policy_save", async route => { commands.push(route.request().postDataJSON()); if (rejectOnce) { rejectOnce = false; await route.fulfill({ status: 503, json: { code: "PGRST000", message: "Synthetic transport interruption" } }); } else await route.continue(); });
    await form.getByRole("button", { name: "Ontvangstbeleid opslaan", exact: true }).click(); await expect(form).toContainText("invoer blijft staan"); await expect(form.getByRole("combobox", { name: "Minimale afstand tussen groepsaankomsten", exact: true })).toHaveValue("600"); await form.getByRole("button", { name: "Ontvangstbeleid opslaan", exact: true }).click(); await expect(form).toContainText("Ontvangstbeleid opgeslagen"); expect(commands).toHaveLength(2); expect(commands[0]._idempotency_key).toBe(commands[1]._idempotency_key);
    await page.bringToFront(); await page.evaluate(() => window.dispatchEvent(new Event("focus"))); await expect(dialog).toContainText("gewijzigd sinds deze berekening", { timeout: 20_000 }); await expect(dialog.getByRole("button", { name: "Beoordeeld routeconcept opslaan", exact: true })).toBeDisabled();
    const rejected = await admin.schema("api").rpc("admin_joint_route_plan_apply", { _event_slug: event, _proposal: proposal, _confirmed: true, _reason: "Synthetische directe stale-broncontrole buiten de browserknop", _idempotency_key: crypto.randomUUID() }); expect(rejected.error?.message).toMatch(/STALE|SOURCE_CHANGED|INPUT_CHANGED/); expect(invariants()).toEqual(saved);
    await assertReadableLayout(owner); await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
    const records = await rpc<{portals:Array<{id:string;systemCode:string}>}>(admin,"admin_portal_records_snapshot",{_event_slug:event}), record=records.portals.find(portal=>portal.id===firstPortal)!;
    await page.getByRole("tab",{name:"Poorten beheren",exact:true}).click();
    const card=page.locator(".manual-portal-list article").filter({has:page.getByText(record.systemCode,{exact:true})});await card.getByRole("button",{name:"Bewerken",exact:true}).click();
    const editor=page.getByRole("dialog");await expect(editor.getByRole("combobox",{name:"Minimale afstand tussen groepsaankomsten",exact:true})).toHaveValue("600");
    await editor.getByRole("combobox",{name:"Minimale afstand tussen groepsaankomsten",exact:true}).selectOption("900");await editor.getByRole("combobox",{name:"Toegankelijkheid van de ontvangstingang",exact:true}).selectOption("unknown");
    const livePolicy=sql(`select jsonb_build_array(arrival_headway_seconds,ordinary_end_grace_seconds,ordinary_hard_close,accessibility_status) from app_private.portals where id='${firstPortal}'`);
    await editor.getByRole("button",{name:"Concept opslaan",exact:true}).click();await expect(editor).toHaveCount(0);
    expect(sql(`select jsonb_build_array(arrival_headway_seconds,ordinary_end_grace_seconds,ordinary_hard_close,accessibility_status) from app_private.portals where id='${firstPortal}'`)).toBe(livePolicy);
    await card.getByRole("button",{name:"Bewerken",exact:true}).click();await expect(page.getByRole("dialog").getByRole("combobox",{name:"Minimale afstand tussen groepsaankomsten",exact:true})).toHaveValue("900");await expect(page.getByRole("dialog").getByRole("combobox",{name:"Toegankelijkheid van de ontvangstingang",exact:true})).toHaveValue("unknown");await page.getByRole("dialog").getByRole("button",{name:"Annuleren",exact:true}).click();expect(invariants()).toEqual(saved);
  } finally { await ownerContext.close(); }
});
