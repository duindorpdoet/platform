import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { createTogetherFixtures, requireLocalTogetherDatabase, sql } from "../../scripts/acceptance/together-fixtures.mjs";
import { assertReadableLayout } from "./helpers/layout";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const slug = "duindorp-halloween-2026";
test.beforeEach(() => {
  test.skip(!url || !key, "Requires the local Supabase acceptance job");
  requireLocalTogetherDatabase();
});
async function authenticate(context: BrowserContext, email = "admin@example.invalid") {
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const result = await client.auth.signInWithPassword({ email, password: "local-test-only" });
  expect(result.error).toBeNull();
  const value = `base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`;
  const chunks = value.length <= 3180 ? [{ name, value }] : Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180) }));
  await context.addCookies(chunks.map((chunk) => ({ ...chunk, url: "http://127.0.0.1:3100", sameSite: "Lax" as const })));
  return client;
}
async function section(page: Page, name: string) {
  await expect(page.locator(".admin-appbar")).toBeVisible();
  const more = page.getByRole("button", { name: "Meer", exact: true });
  const menu = page.getByRole("button", { name: "Organisatienavigatie openen" });
  if (await more.isVisible()) await more.click();
  else if (await menu.isVisible()) await menu.click();
  await page.locator(".admin-nav").getByRole("button", { name, exact: true }).click();
}
async function open(page: Page, context: BrowserContext) {
  const client = await authenticate(context);
  await page.goto("/admin"); await section(page, "Samenloop");
  await expect(page.getByRole("button", { name: /^Bevestigde samenlopen \(/ })).toBeVisible();
  return client;
}
async function preview(page: Page, source: string, target: string) {
  await page.getByRole("button", { name: "Samenloop koppelen", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("textbox", { name: "Bron", exact: true }).fill(source);
  await dialog.getByRole("textbox", { name: "Doel", exact: true }).fill(target);
  await dialog.getByRole("button", { name: "Controleren", exact: true }).click();
  await expect(dialog.getByRole("heading", { name: "Samenloop controleren" })).toBeVisible();
  return dialog;
}

test("confirmed clusters stay whole when searching by cluster, registration, code, contact and child", async ({ page, context }) => {
  const [party] = createTogetherFixtures(1, 2, 2);
  const childName = `Clusterkind-${party.partyId.slice(0, 8)}`;
  sql(`update app_private.children set first_name='${childName}' where id in(select child_id from app_private.registration_children where registration_id='${party.members[1].id}');`);
  await open(page, context);
  const search = page.getByRole("searchbox", { name: "Zoeken", exact: true });
  for (const query of [party.clusterReference!, party.members[1].reference, party.members[1].togetherCode, childName]) {
    await search.fill(query);
    const card = page.locator(`[data-party-id="${party.partyId}"]`);
    await expect(card).toBeVisible(); await expect(card).toContainText("2 inschrijvingen · 4 kinderen");
    await card.locator("summary").click();
    for (const member of party.members) await expect(card.locator(".together-members")).toContainText(member.reference);
    if (query !== party.clusterReference) await expect(card).toContainText(`Gevonden via: ${party.members[1].reference}`);
    await card.locator("summary").click();
  }
  await assertReadableLayout(page);
  await page.getByRole("button", { name: /^Open verzoeken/ }).click();
  await expect(page.locator(`[data-party-id="${party.partyId}"]`)).toHaveCount(0);
  await page.getByRole("button", { name: /^Problemen/ }).click();
  await expect(page.getByText("Bekijk deze samenlopen nog even.", { exact: false })).toBeVisible();
});

for (const variant of ["DPH + DPH", "DPH + SL", "code + DPH"] as const) {
  test(`manual linking ${variant} previews, cancels without mutation and confirms exactly once`, async ({ page, context }) => {
    const [source] = createTogetherFixtures(1);
    const [target] = createTogetherFixtures(1, variant === "DPH + SL" ? 2 : 1);
    await open(page, context);
    const calls: Array<Record<string, unknown>> = [];
    await page.route("**/rest/v1/rpc/admin_merge_together_parties", async (route) => {
      calls.push(route.request().postDataJSON());
      await new Promise((resolve) => setTimeout(resolve, 200));
      await route.continue();
    });
    const sourceIdentifier = variant === "code + DPH" ? source.members[0].togetherCode : source.members[0].reference;
    const targetIdentifier = variant === "DPH + SL" ? target.clusterReference! : target.members[0].reference;
    let dialog = await preview(page, sourceIdentifier, targetIdentifier);
    await expect(dialog).toContainText(`${target.members.length + 1} inschrijvingen · ${target.members.length + 1} kinderen`);
    expect(await dialog.evaluate((element) => element.matches(":modal"))).toBe(true);
    await page.getByRole("searchbox", { name: "Zoeken", exact: true }).evaluate((element) => element.focus());
    expect(await dialog.evaluate((element) => element.contains(document.activeElement))).toBe(true);
    await dialog.getByRole("button", { name: "Annuleren" }).click();
    expect(calls).toHaveLength(0);
    expect(sql(`select count(*) from app_private.together_memberships where party_id='${target.partyId}' and left_at is null;`)).toBe(String(target.members.length));
    await expect(page.getByRole("button", { name: "Samenloop koppelen", exact: true })).toBeFocused();
    dialog = await preview(page, sourceIdentifier, targetIdentifier);
    await dialog.getByRole("textbox", { name: "Reden", exact: true }).fill("Handmatig gekoppeld na verzoek per e-mail");
    await dialog.getByRole("button", { name: "Bevestigen en koppelen" }).click();
    await dialog.locator("form").evaluate((form) => { (form as HTMLFormElement).requestSubmit(); (form as HTMLFormElement).requestSubmit(); });
    await expect(dialog).toHaveCount(0);
    expect(calls).toHaveLength(1);
    expect(calls[0]._source_party_id).toBe(source.partyId); expect(calls[0]._target_party_id).toBe(target.partyId);
    const reference = sql(`select cluster_reference from app_private.together_parties where id='${target.partyId}';`);
    expect(reference).toMatch(/^SL-2026-[A-HJ-NP-Z2-9]{6}$/);
    if (target.clusterReference) expect(reference).toBe(target.clusterReference);
    await page.getByRole("searchbox", { name: "Zoeken", exact: true }).fill(reference);
    await expect(page.locator(`[data-party-id="${target.partyId}"]`)).toContainText(`${target.members.length + 1} inschrijvingen`);
    expect(sql(`select count(*) from app_private.audit_events where action='together.admin_merged' and resource_id='${target.partyId}';`)).toBe("1");
  });
}

for (const conflict of ["different_groups", "locked", "published", "over_capacity"] as const) {
  test(`manual preview blocks ${conflict} without a mutation button`, async ({ page, context }) => {
    const [source] = createTogetherFixtures(1, 1, conflict === "over_capacity" ? 20 : 1);
    const [target] = createTogetherFixtures(1);
    const client = await open(page, context);
    if (conflict === "locked") sql(`update app_private.together_parties set locked_at=now() where id='${target.partyId}';`);
    if (conflict === "different_groups" || conflict === "published") {
      for (const party of [source, target]) {
        const group = await client.schema("api").rpc("admin_group_create", { _event_slug: slug, _display_name: "Browser samenloopconflict" }); expect(group.error).toBeNull();
        const move = await client.schema("api").rpc("admin_group_move_registration", { _event_slug: slug, _registration_id: party.members[0].id, _target_group_id: group.data.id }); expect(move.error).toBeNull();
      }
      if (conflict === "published") sql(`update app_private.group_registrations set published_at=now() where registration_id='${source.members[0].id}' and superseded_at is null;`);
    }
    const dialog = await preview(page, source.members[0].reference, target.members[0].reference);
    await expect(dialog.getByText("Niet mogelijk", { exact: true })).toBeVisible();
    await expect(dialog.getByRole("button", { name: "Bevestigen en koppelen" })).toHaveCount(0);
    await expect(dialog).toContainText(conflict === "different_groups" ? "Pas eerst de groepsindeling aan" : conflict === "locked" ? "vergrendeld" : conflict === "published" ? "gepubliceerd" : "groepslimiet");
    await assertReadableLayout(page);
    await dialog.getByRole("button", { name: "Annuleren" }).click();
  });
}

test("group composition shows the cluster number and moves every member with one RPC", async ({ page, context }) => {
  const [party] = createTogetherFixtures(1, 3);
  const client = await authenticate(context);
  const group = await client.schema("api").rpc("admin_group_create", { _event_slug: slug, _display_name: "Cluster samen verplaatsen" }); expect(group.error).toBeNull();
  const moves: Array<Record<string, unknown>> = [];
  await page.route("**/rest/v1/rpc/admin_group_move_registration", async (route) => { moves.push(route.request().postDataJSON()); await route.continue(); });
  await page.goto("/admin"); await section(page, "Groepsindeling");
  await page.getByRole("textbox", { name: "Zoek in groepsindeling" }).fill(party.clusterReference!);
  const card = page.locator(".group-registration-card").filter({ hasText: party.clusterReference! });
  await expect(card).toHaveCount(1); await expect(card).toContainText("3 inschrijvingen");
  await expect(card.getByRole("button", { name: `${party.clusterReference} verplaatsen` })).toBeEnabled();
  await card.getByRole("button", { name: "Details tonen" }).click();
  for (const member of party.members) await expect(card).toContainText(member.reference);
  await card.getByRole("combobox", { name: "Verplaatsen naar…" }).selectOption(group.data.id);
  await expect.poll(() => moves.length).toBe(1);
  expect(moves[0]._registration_id).toBe(party.members[0].id);
  await expect.poll(() => sql(`select count(*) from app_private.group_registrations where group_id='${group.data.id}' and superseded_at is null;`)).toBe("3");
});

test("accepted join requests create an SL number and refresh the open overview through realtime", async ({ page, context }) => {
  const [source, target] = createTogetherFixtures(2);
  const client = await open(page, context);
  await page.getByRole("searchbox", { name: "Zoeken", exact: true }).fill(target.members[0].reference);
  await expect(page.getByText("Geen bevestigde samenlopen gevonden.")).toBeVisible();
  const requestId = sql(`insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,requested_code,child_count_at_request,group_limit_at_request)
    select event_id,'${source.partyId}','${target.partyId}','${source.members[0].id}','${target.members[0].togetherCode}',1,10
    from app_private.together_parties where id='${target.partyId}' returning id;`);
  await page.getByRole("button", { name: /^Open verzoeken/ }).click();
  const request = page.locator(".together-card").filter({ hasText: source.members[0].reference });
  await expect(request).toBeVisible({ timeout: 10_000 });
  await expect(request).toContainText(target.members[0].reference);
  await expect(request).toContainText("Na acceptatie: 2 kinderen");
  await page.getByRole("button", { name: /^Bevestigde samenlopen/ }).click();
  const result = await client.schema("api").rpc("admin_decide_together_request", { _request_id: requestId, _expected_version: 1, _decision: "accept", _override_limit: false, _reason: "Samenloopverzoek gecontroleerd en akkoord" });
  expect(result.error).toBeNull();
  const card = page.locator(`[data-party-id="${target.partyId}"]`);
  await expect(card).toBeVisible({ timeout: 10_000 });
  await expect(card).toContainText(/SL-2026-[A-HJ-NP-Z2-9]{6}/);
  await expect(card).toContainText("2 inschrijvingen · 2 kinderen");
});

test("a stale manual preview requires another check before any merge", async ({ page, context }) => {
  const [source, target] = createTogetherFixtures(2);
  await open(page, context);
  const dialog = await preview(page, source.members[0].reference, target.members[0].reference);
  sql(`update app_private.registrations set preferred_start_at='2026-10-31 19:00:00+01' where id='${source.members[0].id}';`);
  await dialog.getByRole("textbox", { name: "Reden", exact: true }).fill("Handmatig gekoppeld na verzoek per e-mail");
  await dialog.getByRole("button", { name: "Bevestigen en koppelen" }).click();
  await expect(dialog.getByRole("alert")).toContainText("De gegevens zijn gewijzigd");
  await expect(dialog.getByRole("button", { name: "Controleren", exact: true })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Bevestigen en koppelen" })).toHaveCount(0);
  expect(sql(`select count(*) from app_private.together_memberships where party_id='${target.partyId}' and left_at is null;`)).toBe("1");
});

test("participants can request, cancel and see rejected or approved samenloop on both account pages", async ({ page, context }) => {
  const [source, target] = createTogetherFixtures(2);
  const secret = process.env.SUPABASE_SECRET_KEY;
  expect(secret, "Local Auth admin fixture key").toBeTruthy();
  const adminAuth = createClient(url!, secret!, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = `together-browser-${crypto.randomUUID()}@example.invalid`;
  const created = await adminAuth.auth.admin.createUser({ email, password: "local-test-only", email_confirm: true });
  expect(created.error).toBeNull();
  const userId = created.data.user!.id;
  // The install invitation has its own acceptance coverage; keep this flow on samenloop.
  await page.addInitScript((id) => localStorage.setItem(`poorten:pwa-installed:${id}`, "true"), userId);
  sql(`update app_private.households set primary_contact_user_id='${userId}' where id=(select household_id from app_private.registrations where id='${source.members[0].id}');
    update app_private.household_members set user_id='${userId}' where household_id=(select household_id from app_private.registrations where id='${source.members[0].id}');`);
  await authenticate(context, email);
  await page.goto("/omgeving/meeloper/groep");
  const card = page.getByRole("region", { name: "Jullie samenloop", exact: true });
  await expect(card).toContainText(source.members[0].togetherCode);
  const submitCode = async () => {
    await card.getByRole("textbox", { name: "Samenloopcode van een andere inschrijving" }).fill(target.members[0].togetherCode);
    await card.getByRole("button", { name: "Samenloop aanvragen", exact: true }).click();
    await expect(card.getByText("Aangevraagd · wacht op beoordeling", { exact: true })).toBeVisible();
  };
  await submitCode();
  await card.getByRole("button", { name: "Verzoek annuleren", exact: true }).click();
  await card.getByRole("button", { name: "Verzoek behouden", exact: true }).click();
  await expect(card.getByText("Aangevraagd · wacht op beoordeling", { exact: true })).toBeVisible();
  await card.getByRole("button", { name: "Verzoek annuleren", exact: true }).click();
  await card.getByRole("button", { name: "Ja, verzoek intrekken", exact: true }).click();
  await expect(card.getByText("Geannuleerd", { exact: true })).toBeVisible();
  expect(sql(`select status from app_private.registrations where id='${source.members[0].id}';`)).toBe("submitted");
  const organizer = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  expect((await organizer.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" })).error).toBeNull();
  for (const decision of ["reject", "accept"]) {
    await submitCode();
    const requestId = sql(`select id from app_private.together_join_requests where requested_by_registration_id='${source.members[0].id}' and status='pending';`);
    const result = await organizer.schema("api").rpc("admin_decide_together_request", { _request_id: requestId, _expected_version: 1, _decision: decision, _override_limit: false, _reason: "Aanvraag gecontroleerd via de organisatie" });
    expect(result.error).toBeNull();
    await expect(card.getByText(decision === "accept" ? "Goedgekeurd" : "Geweigerd", { exact: true })).toBeVisible({ timeout: 10_000 });
  }
  await expect(card).toContainText("Samenloop bevestigd");
  await expect(card).toContainText(/SL-2026-[A-HJ-NP-Z2-9]{6}/);
  await expect(card).toContainText("2 inschrijvingen");
  await expect(card).not.toContainText(target.members[0].reference);
  await expect(card.getByRole("button", { name: "Verzoek annuleren", exact: true })).toHaveCount(0);
  // A manual addition must refresh existing members, not just the moved registration.
  const [extra] = createTogetherFixtures(1);
  const mergePreview = await organizer.schema("api").rpc("admin_together_merge_preview", {
    _event_slug: slug, _source_party_id: extra.partyId, _target_party_id: target.partyId,
  });
  expect(mergePreview.error).toBeNull();
  const merge = await organizer.schema("api").rpc("admin_merge_together_parties", {
    _event_slug: slug, _source_party_id: extra.partyId, _target_party_id: target.partyId,
    _expected_source_state: mergePreview.data.source.stateToken, _expected_target_state: mergePreview.data.target.stateToken,
    _reason: "Extra inschrijving gekoppeld op verzoek van de deelnemers", _idempotency_key: crypto.randomUUID(),
  });
  expect(merge.error).toBeNull();
  await expect(card).toContainText("3 inschrijvingen", { timeout: 10_000 });
  await assertReadableLayout(page);
  await page.goto("/mijn-inschrijving");
  await expect(page.getByRole("region", { name: "Jullie samenloop", exact: true })).toContainText("Samenloop bevestigd");
});
