import { test, expect } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
test("saved start selects survive timestamp spelling and refresh; publication explains real unavailable-finale cause", async ({ page, context }) => {
  test.skip(!url || !key, "Requires isolated local Auth and database fixtures");
  if (!["127.0.0.1", "localhost"].includes(new URL(url!).hostname)) throw new Error("LOCAL_READINESS_FIXTURES_ONLY");
  test.setTimeout(90_000);
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(login.error).toBeNull(); await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: "http://127.0.0.1:3100", sameSite: "Lax" as const })));
  async function rpc(name: string, args: Record<string, unknown>) {
    const result = await client.schema("api").rpc(name, args); expect(result.error).toBeNull(); return result.data;
  }
  const event = "duindorp-halloween-2026", gid = "23000000-0000-0000-0000-000000000001";
  let state = await rpc("admin_startregie_snapshot", { _event_slug: event });
  await rpc("admin_startregie_settings_save", { _event_slug: event, _settings: { ...state.settings, plannerMode: "dynamic", firstStartAt: "2026-10-31T15:00:00Z", globalOrdinaryStopAt: "2026-10-31T19:30:00Z", finalPortalId: "12000000-0000-0000-0000-000000000030", finaleOpensAt: "2026-10-31T18:00:00Z", finaleLastArrivalAt: "2026-10-31T20:30:00Z", finaleClosesAt: "2026-10-31T21:00:00Z", finaleAvailable: true }, _expected_version: state.settings.version, _reason: "Synthetic readiness browser fixture without publication" });
  const point = await rpc("admin_startregie_start_point_save", { _event_slug: event, _point_id: null, _payload: { name: "Synthetic readiness start", publicLabel: "Synthetic readiness start", pointType: "gathering", privateAddress: "FICTIEF TESTADRES", geocodedLatitude: 52.1, geocodedLongitude: 4.27, active: true, maxGroups: 1, maxChildren: 30 }, _expected_version: null, _reason: "Synthetic start time presentation fixture" });
  await rpc("admin_startregie_confirm_point", { _event_slug: event, _point_id: point.id, _expected_version: point.version });
  state = await rpc("admin_startregie_snapshot", { _event_slug: event });
  const group = state.groups.find((item: { id: string }) => item.id === gid);
  await rpc("admin_startregie_move_group", { _group_id: gid, _start_point_id: point.id, _starts_at: "2026-10-31T16:00:00+00:00", _expected_group_version: group.version, _preference_match: "neutral", _reason: "Synthetic stored exact appointment for timestamp regression" });
  const publicationWrites: string[] = [];
  page.on("request", request => { if (request.url().includes("/rpc/admin_startregie_confirm_and_send")) publicationWrites.push(request.url()); });
  await page.goto("/admin"); await selectOrganizationSection(page, "Startregie");
  const card = page.locator(".start-ops-assignment").filter({ has: page.getByText(group.systemCode, { exact: true }) });
  const selectedTime = card.getByRole("combobox", { name: `Starttijd voor ${group.systemCode}` });
  await expect(selectedTime).toHaveValue("2026-10-31T16:00:00.000Z");
  await expect(card.getByRole("combobox", { name: `Startpunt voor ${group.systemCode}` })).toHaveValue(point.id);
  await selectedTime.selectOption({ label: "17:10 uur" });
  const refreshed = page.waitForResponse(response => response.url().includes("/rpc/admin_startregie_snapshot"));
  await page.getByRole("button", { name: "Vernieuwen", exact: true }).first().click(); await refreshed;
  await expect(selectedTime).toHaveValue("2026-10-31T16:10:00.000Z");
  await expect(card.getByRole("button", { name: "Startafspraken bevestigen en versturen", exact: true })).toBeDisabled();
  const saved = page.waitForResponse(response => response.url().includes("/rpc/admin_startregie_move_group"));
  await card.getByRole("button", { name: "Concept opslaan", exact: true }).click(); await saved;
  await expect(card.getByRole("button", { name: "Concept opslaan", exact: true })).toBeDisabled();
  // A valid appointment exists before availability changes. New saves must
  // still reject an unavailable finale; publication explains the later change.
  state = await rpc("admin_startregie_snapshot", { _event_slug: event });
  await rpc("admin_startregie_settings_save", { _event_slug: event, _settings: { ...state.settings, finaleAvailable: false }, _expected_version: state.settings.version, _reason: "Synthetic finale becomes unavailable after the valid draft was saved" });
  await page.reload(); await expect(selectedTime).toHaveValue("2026-10-31T16:10:00.000Z");
  await card.getByRole("button", { name: "Startafspraken bevestigen en versturen", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Synthetic readiness start · 17:10 uur");
  await expect(dialog).toContainText("Adres vanaf 16:10");
  await expect(dialog).toContainText("Laatste poort veilig beschikbaar is nog niet bevestigd");
  await expect(dialog.getByRole("button", { name: "Startafspraken bevestigen en versturen", exact: true })).toBeDisabled();
  await dialog.getByRole("button", { name: "Open Kaders", exact: true }).click();
  const available = page.getByRole("checkbox", { name: "Laatste poort veilig beschikbaar", exact: true });
  await expect(available).not.toBeChecked();
  await available.check(); await expect(page.getByRole("status").filter({ hasText: "niet-opgeslagen Kaders" })).toBeVisible();
  await page.getByRole("button", { name: "Kaders opslaan", exact: true }).click();
  await expect(page.getByText("Opgeslagen serverwaarden: finalekaders gereed", { exact: true })).toBeVisible();
  await page.getByRole("tab", { name: "Indeling", exact: true }).click();
  await expect(selectedTime).toHaveValue("2026-10-31T16:10:00.000Z");
  expect(publicationWrites).toEqual([]);
});
