import { test, expect, type BrowserContext, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const event = "duindorp-halloween-2026";
test.beforeEach(() => test.skip(!url || !key, "Requires isolated real Auth and database"));
test.describe.configure({ mode: "serial" });

async function login(context: BrowserContext) {
  requireLocalTogetherDatabase();
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const result = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(result.error).toBeNull(); await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
    name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180),
    url: "http://127.0.0.1:3100", sameSite: "Lax" as const,
  })));
  return client;
}

async function openMap(page: Page, id: string) {
  await page.getByRole("tab", { name: "Kaart", exact: true }).click();
  await page.getByRole("combobox", { name: "Locatie bewerken" }).selectOption(`start|${id}`);
  return page.getByRole("region", { name: /Locatie-editor voor Startpunt/ });
}

test("saved official and manual positions can be confirmed on mobile without a walking graph or assigned groups", async ({ page, context, browser }) => {
  test.setTimeout(150_000);
  const client = await login(context), suffix = randomUUID().slice(0, 6);
  async function snapshot() {
    const result = await client.schema("api").rpc("admin_startregie_snapshot", { _event_slug: event });
    expect(result.error).toBeNull(); return result.data;
  }
  const edges = JSON.parse(sql("select jsonb_agg(jsonb_build_object('id',id,'approved_at',approved_at)) from app_private.walking_edges"));
  const ids: string[] = [];
  try {
    for (const [name, publicLabel] of [["Horror Zone", "Horor zone"], ["Welcome to the Freakshow", "Welcome to the Freakshow"]]) {
      const result = await client.schema("api").rpc("admin_startregie_start_point_save", {
        _event_slug: event, _point_id: null, _expected_version: null, _reason: "Isolated reproduction of saved markers without a graph",
        _payload: { name: `${name} ${suffix}`, publicLabel: `${publicLabel} ${suffix}`, pointType: "gathering", privateAddress: "FICTIEF STARTADRES", geocodedLatitude: 52.09, geocodedLongitude: 4.26, active: true, maxGroups: 1, maxChildren: 30 },
      });
      expect(result.error).toBeNull(); ids.push(result.data.id);
    }
    sql(`update app_private.walking_edges set approved_at=null;
      update app_private.start_points set walking_node_id=null,version=version+1 where id in ('${ids.join("','")}');`);
    const before = await snapshot();
    const unassigned = before.ops.groups.filter((group: { state: string }) => group.state === "unassigned").length;
    await page.setViewportSize({ width: 390, height: 844 }); await page.goto("/admin");
    await selectOrganizationSection(page, "Startregie");
    await openMap(page, ids[0]);
    await expect(page.getByRole("combobox", { name: "Locatie bewerken" })).toHaveValue(`start|${ids[0]}`);
    let editor = page.getByRole("region", { name: `Locatie-editor voor Startpunt · Horor zone ${suffix}` });
    await expect(editor).toContainText("Bron: officiële adrespositie");
    const confirmed = page.waitForResponse(response => response.url().includes("/rpc/admin_startregie_confirm_point"));
    await editor.getByRole("button", { name: "Deze marker bevestigen" }).click();
    expect((await confirmed).ok()).toBe(true);
    await expect(editor).toContainText("Locatie bevestigd");

    await editor.getByRole("button", { name: "Marker verplaatsen" }).click();
    await editor.getByText("Technische locatiegegevens", { exact: true }).click();
    await editor.getByRole("textbox", { name: "Breedtegraad", exact: true }).fill("52,091234");
    await editor.getByRole("textbox", { name: "Lengtegraad", exact: true }).fill("4,261234");
    await editor.getByRole("textbox", { name: "Reden voor de afwijkende routingpositie" }).fill("Synthetische gecontroleerde hofingang");
    await page.route("**/rest/v1/rpc/admin_location_marker_save", route => route.fulfill({ status: 403, contentType: "application/json", body: JSON.stringify({ code: "42501", message: "NOT_AUTHORIZED" }) }), { times: 1 });
    await editor.getByRole("button", { name: "Locatie opslaan" }).click();
    await expect(editor.getByRole("alert")).toContainText("opslaan geweigerd");
    await expect(page.locator(".start-regie-notice").filter({ hasText: "Locatie opgeslagen" })).toHaveCount(0);
    expect((await snapshot()).startPoints.find((point: { id: string }) => point.id === ids[0]).latitude).toBe(52.09);
    await page.route("**/rest/v1/rpc/admin_startregie_snapshot", route => route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ message: "Tijdelijke snapshotstoring" }) }));
    await editor.getByRole("button", { name: "Locatie opslaan" }).click();
    await expect(page.locator(".start-regie-notice")).toContainText("Startregie ophalen mislukt");
    expect((await snapshot()).startPoints.find((point: { id: string }) => point.id === ids[0]).latitude).toBe(52.091234);
    await page.unroute("**/rest/v1/rpc/admin_startregie_snapshot");
    await page.getByRole("button", { name: "Vernieuwen", exact: true }).click();
    await expect(editor.getByRole("button", { name: "Deze marker bevestigen" })).toBeVisible();
    await expect(page.locator(".start-regie-notice").filter({ hasText: "Startregie ophalen mislukt" })).toHaveCount(0);
    await expect(editor).toContainText("Bron: handmatige routingpositie");
    await editor.getByRole("button", { name: "Deze marker bevestigen" }).click();
    await expect(editor).toContainText("Locatie bevestigd");
    await expect(editor.locator(".location-editor-pin")).toBeVisible();
    await assertReadableLayout(page); await editor.scrollIntoViewIfNeeded();
    await mkdir("docs/ops/screenshots", { recursive: true });
    await page.screenshot({ path: "docs/ops/screenshots/start-marker-repaired-390.png" });

    editor = await openMap(page, ids[1]);
    await editor.getByRole("button", { name: "Deze marker bevestigen" }).click();
    await expect(editor).toContainText("Locatie bevestigd");
    await page.reload(); await selectOrganizationSection(page, "Startregie");
    editor = await openMap(page, ids[0]); await expect(editor).toContainText("Locatie bevestigd");
    const after = await snapshot();
    for (const id of ids) {
      expect(after.startPoints.find((point: { id: string }) => point.id === id).confirmed).toBe(true);
      expect(after.warnings.some((warning: { resourceId: string; code: string }) => warning.resourceId === id && warning.code === "MISSING_MARKER")).toBe(false);
      expect(after.warnings.some((warning: { resourceId: string; code: string }) => warning.resourceId === id && warning.code === "WALKING_ROUTE_MISSING")).toBe(false);
    }
    expect(after.startPoints.find((point: { id: string }) => point.id === ids[0]).readiness.location).toMatchObject({ latitude: 52.091234, longitude: 4.261234, source: "manual" });
    expect(after.ops.groups.filter((group: { state: string }) => group.state === "unassigned")).toHaveLength(unassigned);
    const otherContext = await browser.newContext();
    try {
      const other = await login(otherContext);
      const independent = await other.schema("api").rpc("admin_startregie_snapshot", { _event_slug: event });
      expect(independent.data.startPoints.find((point: { id: string }) => point.id === ids[0]).confirmed).toBe(true);
    } finally { await otherContext.close(); }
  } finally {
    for (const edge of edges) sql(`update app_private.walking_edges set approved_at=${edge.approved_at ? `'${edge.approved_at}'::timestamptz` : "null"} where id='${edge.id}'`);
  }
});

test("a delayed snapshot and an outdated open editor cannot replace a newer server position", async ({ page, context }) => {
  test.setTimeout(120_000);
  const client = await login(context);
  const created = await client.schema("api").rpc("admin_startregie_start_point_save", { _event_slug: event, _point_id: null, _expected_version: null, _reason: "Isolated two-editor location conflict acceptance", _payload: { name: `Gelijktijdige marker ${randomUUID().slice(0, 8)}`, privateAddress: "FICTIEF STARTADRES", geocodedLatitude: 52.09, geocodedLongitude: 4.26, active: true } });
  expect(created.error).toBeNull(); const id = created.data.id;
  await page.setViewportSize({ width: 360, height: 844 }); await page.goto("/admin"); await selectOrganizationSection(page, "Startregie");
  const editor = await openMap(page, id);
  let releaseOld!: () => void, receivedOld!: () => void;
  const held = new Promise<void>(resolve => { releaseOld = resolve; });
  const received = new Promise<void>(resolve => { receivedOld = resolve; });
  await page.route("**/rest/v1/rpc/admin_startregie_snapshot", async route => {
    const response = await route.fetch(); receivedOld(); await held; await route.fulfill({ response });
  }, { times: 1 });
  await page.getByRole("button", { name: "Vernieuwen", exact: true }).click(); await received;
  try {
    await editor.getByRole("button", { name: "Marker verplaatsen" }).click();
    await editor.getByText("Technische locatiegegevens", { exact: true }).click();
    await editor.getByRole("textbox", { name: "Breedtegraad", exact: true }).fill("52.091111");
    await editor.getByRole("textbox", { name: "Lengtegraad", exact: true }).fill("4.261111");
    await editor.getByRole("textbox", { name: "Reden voor de afwijkende routingpositie" }).fill("Eerste editor controleert deze synthetische positie");
    const saved = await client.schema("api").rpc("admin_location_marker_save", { _event_slug: event, _resource_type: "start_point", _resource_id: id, _latitude: 52.092222, _longitude: 4.262222, _reason: "Tweede editor bewaart een nieuwere marker", _restore_from_address: false, _expected_version: created.data.version });
    expect(saved.error).toBeNull();
    await editor.getByRole("button", { name: "Locatie opslaan" }).click();
    await expect(editor.getByRole("alert").filter({ hasText: "opslaan geweigerd" })).toBeVisible();
    await editor.getByRole("button", { name: "Annuleren", exact: true }).click();
    await expect(editor).toContainText("handmatige routingpositie");
    releaseOld(); await page.waitForTimeout(300);
    await expect(editor).toContainText("handmatige routingpositie");
    await editor.getByRole("button", { name: "Marker verplaatsen" }).click();
    await editor.getByText("Technische locatiegegevens", { exact: true }).click();
    await expect(editor.getByRole("textbox", { name: "Breedtegraad", exact: true })).toHaveValue("52.092222");
    await editor.getByRole("button", { name: "Annuleren", exact: true }).click();
    await editor.getByRole("button", { name: "Deze marker bevestigen" }).click();
    await expect(editor).toContainText("Locatie bevestigd");
    await assertReadableLayout(page);
  } finally { releaseOld(); }
});

test("organizer can create and edit a portal on mobile and edit an existing finale without selecting it again", async ({ page, context }) => {
  test.setTimeout(120_000);
  const client = await login(context), name = `Markerpoort ${randomUUID().slice(0, 8)}`;
  const originalFinal = sql("select coalesce(final_portal_id::text,'') from app_private.event_route_settings limit 1");
  let id: string | undefined;
  async function manager() {
    await page.goto("/admin"); await selectOrganizationSection(page, "Poorten");
    await page.getByRole("tab", { name: "Poorten beheren", exact: true }).click();
    return page.locator(".manual-portal-manager");
  }
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    let list = await manager();
    await list.getByRole("button", { name: "Poort toevoegen", exact: true }).click();
    let dialog = page.getByRole("dialog");
    await dialog.getByRole("textbox", { name: "Poortnaam", exact: true }).fill(name);
    const editor = dialog.getByRole("region", { name: `Locatie-editor voor ${name}` });
    await editor.getByRole("button", { name: "Marker plaatsen" }).click();
    await editor.getByText("Technische locatiegegevens", { exact: true }).click();
    await editor.getByRole("textbox", { name: "Breedtegraad", exact: true }).fill("52,091111");
    await editor.getByRole("textbox", { name: "Lengtegraad", exact: true }).fill("4,261111");
    await editor.getByRole("textbox", { name: "Reden voor de afwijkende routingpositie" }).fill("Bewust gekozen synthetische poortingang");
    await editor.getByRole("button", { name: "Positie overnemen" }).click();
    const created = page.waitForResponse(response => response.url().includes("/rpc/admin_manual_portal_save"));
    await dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
    const creation = await created; expect(creation.ok(), await creation.text()).toBe(true);
    id = (await creation.json()).id;
    await expect(dialog).not.toBeVisible();
    let card = list.locator("article").filter({ has: page.getByText(name, { exact: true }) });
    await card.getByRole("button", { name: "Bewerken", exact: true }).click();
    dialog = page.getByRole("dialog");
    await dialog.getByRole("textbox", { name: "Omschrijving", exact: true }).fill("Synthetische gewijzigde aankomstinstructie");
    await page.route("**/rest/v1/rpc/admin_manual_portal_save", route => route.fulfill({ status: 403, contentType: "application/json", body: JSON.stringify({ code: "42501", message: "NOT_AUTHORIZED" }) }), { times: 1 });
    await dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
    await expect(dialog.getByRole("alert")).toContainText("Opslaan geweigerd");
    await expect(dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true })).toBeEnabled();
    await dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
    await expect(dialog).not.toBeVisible();
    let stored = await client.schema("api").rpc("admin_portal_editor_snapshot", { _event_slug: event });
    expect(stored.error).toBeNull();
    expect(stored.data.portals.find((portal: { id: string }) => portal.id === id)).toMatchObject({ description: "Synthetische gewijzigde aankomstinstructie", latitude: 52.091111, longitude: 4.261111, locationSource: "manual" });
    sql(`update app_private.event_route_settings set final_portal_id='${id}'`);
    list = await manager();
    card = list.locator("article").filter({ has: page.getByText(name, { exact: true }) });
    await expect(card).toContainText("Eindpoort");
    await card.getByRole("button", { name: "Bewerken", exact: true }).click();
    dialog = page.getByRole("dialog");
    await expect(dialog.getByText("Ik begrijp dat dit de eindpoortconfiguratie wijzigt.", { exact: true })).toHaveCount(0);
    await dialog.getByRole("textbox", { name: "Omschrijving", exact: true }).fill("Bestaande finale gewoon bewerkt");
    await expect(dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true })).toBeEnabled();
    await dialog.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
    await expect(dialog).not.toBeVisible();
    stored = await client.schema("api").rpc("admin_portal_editor_snapshot", { _event_slug: event });
    expect(stored.data.portals.find((portal: { id: string }) => portal.id === id)).toMatchObject({ description: "Bestaande finale gewoon bewerkt", isFinal: true, latitude: 52.091111 });
    expect(sql("select final_portal_id::text from app_private.event_route_settings limit 1")).toBe(id);
    await assertReadableLayout(page);
  } finally {
    if (id) sql(`update app_private.event_route_settings set final_portal_id=${originalFinal ? `'${originalFinal}'::uuid` : "null"}`);
  }
});
