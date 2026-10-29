import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";
import type { AdminRegistration, RegistrationCreationOptions, RegistrationManagementPreview } from "../../lib/domain/admin-registrations";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const event = "duindorp-halloween-2026", registrationId = "22000000-0000-0000-0000-000000000001";
test.describe.configure({ mode: "serial" });
test.beforeEach(() => { test.skip(!url || !key, "Requires isolated local Supabase"); requireLocalTogetherDatabase(); });
async function login(context: BrowserContext, baseURL: string, email = "admin@example.invalid") {
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const result = await client.auth.signInWithPassword({ email, password: "local-test-only" });
  expect(result.error).toBeNull(); await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: value.length <= 3180 ? name : `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180), url: baseURL, sameSite: "Lax" as const })));
  return client;
}
async function rpc<T>(client: SupabaseClient, name: string, args: Record<string, unknown>): Promise<T> {
  const result = await client.schema("api").rpc(name, args); expect(result.error, name).toBeNull(); return result.data as T;
}
async function openRoster(page: Page) { await page.goto("/admin?view=registrations"); await selectOrganizationSection(page, "Inschrijvingen"); await expect(page.getByRole("heading", { name: "Alle inschrijvingen" })).toBeVisible(); }
async function fillChildren(dialog: ReturnType<Page["getByRole"]>, names: string[]) {
  for (let index = 0; index < names.length; index++) {
    if (index) await dialog.getByRole("button", { name: "Kind toevoegen", exact: true }).click();
    await dialog.getByRole("textbox", { name: `Voornaam kind ${index + 1}`, exact: true }).fill(names[index]);
    await dialog.getByRole("spinbutton", { name: `Leeftijd kind ${index + 1} op de avond`, exact: true }).fill(String(6 + index));
  }
}
function outbox() {
  return JSON.parse(sql("select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',message_type,'registrationId',payload->>'registrationId','recipient',recipient_email,'status',status)),'[]') from app_private.email_outbox")) as Array<{ id: string; type: string; registrationId: string; recipient: string; status: string }>;
}

test("closed public registration still allows one pending family with three children, safe retries, editing and explicit invitation correction", async ({ page, context, browser, baseURL }) => {
  test.setTimeout(120_000);
  const client = await login(context, baseURL!);
  const dashboard = await rpc<{ event: { settingsVersion: number; groupRegistrationOpen: boolean } }>(client, "admin_dashboard", { _event_slug: event });
  await rpc(client, "admin_set_registration_channel", { _event_slug: event, _channel: "groups", _open: false, _expected_settings_version: dashboard.event.settingsVersion, _reason: "Synthetische browserproef gesloten publieke deelnemersinschrijving" });
  const guest = await browser.newContext(), guestPage = await guest.newPage();
  try {
    await guestPage.goto(`${baseURL}/meelopen`); await expect(guestPage.getByRole("heading", { name: "De inschrijvingen zijn gesloten." })).toBeVisible(); await expect(guestPage.getByRole("button", { name: "Definitief inschrijven" })).toHaveCount(0);
    await openRoster(page);
    const options = await rpc<RegistrationCreationOptions>(client, "admin_registration_creation_options", { _event_slug: event });
    const suffix = crypto.randomUUID().slice(0, 8), email = `browser-family-${suffix}@example.invalid`, correctedEmail = `browser-corrected-${suffix}@example.invalid`;
    const before = new Set(outbox().map(row => row.id)), keys: string[] = [];
    page.on("request", request => { if (request.url().includes("/rpc/admin_registration_create")) keys.push(request.postDataJSON()._command_id); });
    await page.route("**/rpc/admin_registration_create", async route => { await new Promise(resolve => setTimeout(resolve, 300)); const accepted=await route.fetch();expect(accepted.ok()).toBe(true);await route.fulfill({ status: 503, json: { code: "PGRST000", message: "LOCAL_SYNTHETIC_CONFIRMATION_LOST" } }); }, { times: 1 });
    await page.getByRole("button", { name: "Inschrijving toevoegen", exact: true }).click(); let dialog = page.getByRole("dialog");
    await dialog.getByRole("textbox", { name: "Naam ouder", exact: true }).fill(`Browsergezin ${suffix}`);
    await dialog.getByRole("textbox", { name: "E-mailadres ouder", exact: true }).fill(email);
    await fillChildren(dialog, ["Browserkind Noor", "Browserkind Bo", "Browserkind Sam"]);
    await dialog.getByRole("textbox",{name:"Toegankelijkheidswens kind 1 (optioneel)",exact:true}).fill("Een rustige ontvangst graag; dit is geen drempelvrije route-eis");
    await expect(dialog.getByRole("combobox",{name:"Drempelvrije route voor kind 1",exact:true})).toHaveValue("not_required");
    if (options.allowedEndTimes.length) await dialog.getByRole("combobox", { name: "Gewenst klaar, inclusief finale", exact: true }).selectOption(options.allowedEndTimes.at(-1)!);
    await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Afgeschermde browserproef van een gezinsuitnodiging");
    await expect(dialog).toContainText("Nog geen groep gekozen"); await expect(dialog).toContainText("De inschrijving wacht daarna op de eerste juiste inlog");
    const save = dialog.getByRole("button", { name: "Inschrijving aanmaken en activatiemail versturen", exact: true });
    await save.click(); await dialog.locator("form").evaluate(form => (form as HTMLFormElement).requestSubmit());
    await expect(dialog.getByRole("alert")).toBeVisible(); expect(keys).toHaveLength(1);
    // The server really committed the first request; only its acknowledgement
    // was lost. Retrying must recover that receipt, not create/mail another family.
    expect((await rpc<AdminRegistration[]>(client,"admin_registrations_snapshot",{_event_slug:event})).filter(row=>row.parentEmail===email)).toHaveLength(1);
    expect(outbox().filter(row=>!before.has(row.id))).toHaveLength(1);
    await expect(dialog.getByRole("textbox", { name: "Voornaam kind 3", exact: true })).toHaveValue("Browserkind Sam");
    await expect(dialog.getByRole("textbox", { name: "E-mailadres ouder", exact: true })).toHaveValue(email);
    await save.click(); await expect(dialog).not.toBeVisible(); expect(keys).toHaveLength(2); expect(keys[1]).toBe(keys[0]);
    let rows = await rpc<AdminRegistration[]>(client, "admin_registrations_snapshot", { _event_slug: event });
    let registration = rows.find(row => row.parentEmail === email)!; expect(registration).toBeTruthy(); expect(registration.childCount).toBe(3); expect(registration.activation?.status).toBe("pending"); expect(registration.reservedChildCount).toBe(3); expect(registration.activatedChildCount).toBe(0); expect(registration.paidChildCount).toBe(0); expect(registration.children.every(child=>child.stepFreeRequired===false)).toBe(true);
    const created = outbox().filter(row => !before.has(row.id)); expect(created).toHaveLength(1); expect(created[0].registrationId).toBe(registration.id); expect(created[0].recipient).toBe(email);
    await page.getByRole("searchbox").fill(email); let card = page.locator(`#registration-${registration.id}`); await card.getByRole("button", { name: "Bekijk details", exact: true }).click(); await expect(card).toContainText("Wacht op eerste inlog"); await expect(card).toContainText("Geactiveerd: 0");
    await card.getByRole("button", { name: "Inschrijving bewerken", exact: true }).click(); dialog = page.getByRole("dialog");
    await expect(dialog.getByRole("textbox", { name: "Voornaam kind 1", exact: true })).toBeVisible(); const beforeEdit = await rpc<RegistrationManagementPreview>(client, "admin_registration_management_preview", { _event_slug: event, _registration_id: registration.id });
    const firstName = await dialog.getByRole("textbox", { name: "Voornaam kind 1", exact: true }).inputValue();
    await dialog.getByRole("textbox", { name: "Voornaam kind 1", exact: true }).fill(`${firstName} correctie`);
    await dialog.getByRole("combobox",{name:"Drempelvrije route voor kind 1",exact:true}).selectOption("required");
    await dialog.getByRole("button", { name: "Deelname kind 2 verwijderen", exact: true }).click(); await dialog.getByRole("button", { name: "Kind toevoegen", exact: true }).click();
    await dialog.getByRole("textbox", { name: "Voornaam kind 3", exact: true }).fill("Browserkind nieuw"); await dialog.getByRole("spinbutton", { name: "Leeftijd kind 3 op de avond", exact: true }).fill("9");
    await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Synthetische correctie met behoud van hetzelfde gezin"); await expect(dialog).toContainText("Na opslaan: 3 deelnemende kinderen"); await expect(dialog).toContainText("Deelname verwijderd");
    await dialog.getByRole("button", { name: "Wijziging van deelname opslaan", exact: true }).click(); await expect(dialog).not.toBeVisible();
    const afterEdit = await rpc<RegistrationManagementPreview>(client, "admin_registration_management_preview", { _event_slug: event, _registration_id: registration.id });
    expect(afterEdit.children.find(child => child.firstName === `${firstName} correctie`)?.id).toBe(beforeEdit.children.find(child => child.firstName === firstName)?.id); expect(afterEdit.children.filter(child => child.participationStatus === "active")).toHaveLength(3);expect(afterEdit.children.find(child=>child.firstName===`${firstName} correctie`)?.stepFreeRequired).toBe(true);
    await card.getByRole("button", { name: "Uitnodiging opnieuw versturen", exact: true }).click(); dialog = page.getByRole("dialog"); await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Synthetische expliciete herverzending"); await dialog.getByRole("button", { name: "Nieuwe uitnodiging versturen", exact: true }).click(); await expect(dialog).not.toBeVisible();
    await card.getByRole("button", { name: "E-mailadres corrigeren vóór activatie", exact: true }).click(); dialog = page.getByRole("dialog"); await dialog.getByRole("textbox", { name: "Gecorrigeerd e-mailadres ouder", exact: true }).fill(correctedEmail); await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Synthetische correctie van verkeerd getypt uitnodigingsadres"); await expect(dialog).toContainText("De bestaande uitnodigingslink wordt ingetrokken"); await dialog.getByRole("button", { name: "E-mailadres aanpassen en nieuwe uitnodiging versturen", exact: true }).click(); await expect(dialog).not.toBeVisible();
    await page.getByRole("searchbox").fill(correctedEmail); card = page.locator(`#registration-${registration.id}`); await expect(card).toContainText(correctedEmail);
    rows = await rpc<AdminRegistration[]>(client, "admin_registrations_snapshot", { _event_slug: event }); registration = rows.find(row => row.id === registration.id)!; expect(registration.activation?.status).toBe("pending"); expect(registration.childCount).toBe(3);
    await page.getByRole("button", { name: "Inschrijving toevoegen", exact: true }).click(); dialog = page.getByRole("dialog"); await dialog.getByRole("textbox", { name: "Naam ouder", exact: true }).fill("Geen dubbel gezin"); await dialog.getByRole("textbox", { name: "E-mailadres ouder", exact: true }).fill(correctedEmail.toUpperCase()); await fillChildren(dialog, ["Geen dubbel kind"]); if (options.allowedEndTimes.length) await dialog.getByRole("combobox", { name: "Gewenst klaar, inclusief finale", exact: true }).selectOption(options.allowedEndTimes.at(-1)!); await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Synthetische controle bestaande inschrijving");
    const beforeDuplicate = outbox().length; await dialog.getByRole("button", { name: "Inschrijving aanmaken en activatiemail versturen", exact: true }).click(); await expect(dialog).toContainText("Er is geen tweede gezin aangemaakt"); expect(outbox()).toHaveLength(beforeDuplicate); await dialog.getByRole("button", { name: "Bestaande inschrijving bekijken en bewerken", exact: true }).click(); await expect(dialog).not.toBeVisible(); await expect(card.getByRole("button", { name: "Inschrijving bewerken", exact: true })).toBeVisible();
    await assertReadableLayout(page); await card.getByRole("button", { name: "Inschrijving bewerken", exact: true }).click(); dialog = page.getByRole("dialog"); await expect(dialog.getByRole("textbox", { name: "Voornaam kind 1", exact: true })).toBeVisible();
    const overflow = await dialog.evaluate(element => element.scrollWidth > element.clientWidth + 1); expect(overflow).toBe(false); await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
  } finally {
    await guest.close();
    // This suite owns a reset stack. Keep the switch closed throughout the
    // acceptance flow; the surrounding reset restores the synthetic seed.

  }
});

test("a whole family moves between confirmed starts, only that family is mailed and the parent refresh loses old access and cached entrance", async ({ page, context, browser, baseURL }) => {
  test.setTimeout(120_000);
  const fixture = JSON.parse(sql(`${readFileSync("scripts/acceptance/fixtures/registration-management.sql", "utf8")}\nselect pg_temp.registration_management_fixture(to_timestamp(ceil(extract(epoch from clock_timestamp()+interval '20 minutes')/600)*600));`)) as { source: { groupId: string; startsAt: string }; target: { groupId: string; startsAt: string } };
  await login(context, baseURL!);
  const parentContext = await browser.newContext();
  try {
    const parent = await login(parentContext, baseURL!, "parent-a@example.invalid"), parentPage = await parentContext.newPage();
    await parentPage.goto(`${baseURL}/omgeving/meeloper/route`); await expect(parentPage.locator(".group-start-destination")).toContainText("FICTIEF GEZINSSTARTADRES 1");
    await expect.poll(() => parentPage.evaluate(groupId => Object.keys(localStorage).some(key => key.startsWith("duindorp-private-group:") && key.endsWith(groupId)), fixture.source.groupId)).toBe(true);
    const schedulesBefore = sql("select jsonb_agg(jsonb_build_object('groupId',group_id,'startsAt',starts_at,'point',point_snapshot) order by publication_order) from app_private.group_start_publications");
    await openRoster(page); await page.getByRole("searchbox").fill("parent-a@example.invalid"); const card = page.locator(`#registration-${registrationId}`); await card.getByRole("button", { name: "Bekijk details", exact: true }).click();
    await card.getByRole("button", { name: "Verplaatsen naar andere groep", exact: true }).click(); const dialog = page.getByRole("dialog"); await expect(dialog.getByRole("combobox", { name: "Nieuwe loopgroep", exact: true })).toBeVisible(); await expect(dialog).toContainText("Dezelfde groep: er verandert niets");
    await dialog.getByRole("combobox", { name: "Nieuwe loopgroep", exact: true }).selectOption(fixture.target.groupId); await expect(dialog).toContainText("Startafspraak bevestigd"); await expect(dialog).toContainText("Alleen deze ouder ontvangt een wijzigingsmail");
    await dialog.getByRole("textbox", { name: "Reden voor deze beheerhandeling", exact: true }).fill("Synthetische gerichte gezinsverhuizing tussen bevestigde groepen");
    const oldOutbox = new Set(outbox().map(row => row.id));
    await dialog.getByRole("button", { name: "Inschrijving verplaatsen en ouder mailen", exact: true }).click(); await expect(dialog).not.toBeVisible();
    const newMail = outbox().filter(row => !oldOutbox.has(row.id)); expect(newMail).toHaveLength(1); expect(newMail[0].registrationId).toBe(registrationId); expect(newMail[0].recipient).toBe("parent-a@example.invalid");
    expect(sql("select jsonb_agg(jsonb_build_object('groupId',group_id,'startsAt',starts_at,'point',point_snapshot) order by publication_order) from app_private.group_start_publications")).toBe(schedulesBefore);
    const oldAccess = await parent.schema("api").rpc("group_snapshot", { _group_id: fixture.source.groupId }); expect(oldAccess.error?.code).toBe("42501");
    const parentState = await rpc<{ roles: Array<{ key: string; groupId?: string }> }>(parent, "participant_context", { _event_slug: event }); expect(parentState.roles.find(role => role.key === "walker")?.groupId).toBe(fixture.target.groupId);
    await parentPage.bringToFront(); await parentPage.evaluate(() => window.dispatchEvent(new Event("focus"))); await expect(parentPage.locator(".group-start-destination")).toContainText("FICTIEF GEZINSSTARTADRES 2", { timeout: 20_000 }); await expect(parentPage.locator("body")).not.toContainText("FICTIEF GEZINSSTARTADRES 1");
    await expect.poll(() => parentPage.evaluate(groupId => Object.keys(localStorage).some(key => key.startsWith("duindorp-private-group:") && key.endsWith(groupId)), fixture.source.groupId)).toBe(false);
    await assertReadableLayout(parentPage);
  } finally { await parentContext.close(); }
});

test("real verified OTP activates a new invited account, while an old session requires explicit claim and a wrong identity stays pending", async ({ context, browser, baseURL }) => {
  test.setTimeout(120_000);
  const secret = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY;
  expect(secret, "Local service key is required for generating an OTP without sending mail").toBeTruthy();
  const admin = await login(context, baseURL!), authAdmin = createClient(url!, secret!, { auth: { persistSession: false, autoRefreshToken: false } });
  async function pending(email: string) {
    const options = await rpc<RegistrationCreationOptions>(admin, "admin_registration_creation_options", { _event_slug: event });
    const result = await rpc<{ registrationId: string }>(admin, "admin_registration_create", { _event_slug: event, _expected_event_version: options.eventVersion, _command_id: crypto.randomUUID(), _reason: "Synthetische echte Auth-activatieproef zonder providerbezorging", _payload: { parentName: "Synthetische activatieouder", email, phone: null, children: [{ name: "Activatiekind", age: 7, accessibilityNote: null }], preferredStartAt: options.allowedStartTimes[0] ?? null, desiredEndAt: options.allowedEndTimes.at(-1) ?? null, groupId: null, partyId: null } });
    const token = sql(`select app_private.registration_activation_token('${result.registrationId}'::uuid)`);
    expect(token).toMatch(/^[a-f0-9]{64}$/);
    return { id: result.registrationId, path: `/uitnodiging/inschrijving/${token}` };
  }
  async function status(id: string) { return (await rpc<AdminRegistration[]>(admin, "admin_registrations_snapshot", { _event_slug: event })).find(row => row.id === id)!; }
  const suffix = crypto.randomUUID().slice(0, 8), oldEmail = `browser-oldsession-${suffix}@example.invalid`, newEmail = `browser-otp-${suffix}@example.invalid`;
  const oldUser = await authAdmin.auth.admin.createUser({ email: oldEmail, password: "local-test-only", email_confirm: true, user_metadata: { role: "event_admin", capabilities: ["event_admin", "groups_manage"] } }); expect(oldUser.error).toBeNull();
  const oldContext = await browser.newContext(), freshContext = await browser.newContext(), wrongContext = await browser.newContext();
  try {
    const oldClient = await login(oldContext, baseURL!, oldEmail); // The real session predates this invitation.
    const existing = await pending(oldEmail), oldPage = await oldContext.newPage(), claimCalls: string[] = [];
    oldPage.on("request", request => { if (request.url().includes("/rpc/registration_activation_claim")) claimCalls.push(request.url()); });
    await oldPage.goto(`${baseURL}${existing.path}`); await expect(oldPage.getByRole("heading", { name: "Bevestig jullie inschrijving." })).toBeVisible();
    await oldPage.evaluate(() => window.dispatchEvent(new Event("focus"))); await oldPage.reload(); await expect(oldPage.getByRole("heading", { name: "Bevestig jullie inschrijving." })).toBeVisible(); expect(claimCalls).toHaveLength(0); expect((await status(existing.id)).activation?.status).toBe("pending");
    await oldPage.goto(`${baseURL}${existing.path}?verified=1`); await expect(oldPage.locator(".form-error[role=alert]")).toContainText("Je was al eerder ingelogd"); expect((await status(existing.id)).activation?.status).toBe("pending");
    const beforeExplicit = new Set(outbox().map(row => row.id)); await oldPage.getByRole("button", { name: "Deze inschrijving activeren", exact: true }).click(); await expect(oldPage.getByRole("heading", { name: "Jullie inschrijving is geactiveerd." })).toBeVisible(); expect((await status(existing.id)).activation?.status).toBe("activated"); expect(outbox().filter(row => !beforeExplicit.has(row.id))).toHaveLength(0);
    await oldPage.goto(`${baseURL}/admin`); await expect(oldPage.getByRole("button", { name: "Inschrijving toevoegen", exact: true })).toHaveCount(0);
    // User-editable metadata above grants no organization permissions. A real
    // database capability enables registration management but not group moves.
    sql(`insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) select id,'${oldUser.data.user!.id}'::uuid,'registration_manage','f0000000-0000-0000-0000-000000000001'::uuid from app_private.events where slug='duindorp-halloween-2026' on conflict do nothing`);
    await prepareFixtureGuidance(oldClient); await openRoster(oldPage); await expect(oldPage.getByRole("button", { name: "Inschrijving toevoegen", exact: true })).toBeVisible(); await oldPage.getByRole("searchbox").fill(oldEmail); const limitedCard = oldPage.locator(`#registration-${existing.id}`); await limitedCard.getByRole("button", { name: "Bekijk details", exact: true }).click(); await expect(limitedCard.getByRole("button", { name: "Inschrijving bewerken", exact: true })).toBeVisible(); await expect(limitedCard.getByRole("button", { name: "Verplaatsen naar andere groep", exact: true })).toHaveCount(0);
    await oldPage.getByRole("button", { name: "Inschrijving toevoegen", exact: true }).click(); const limitedDialog = oldPage.getByRole("dialog"); await expect(limitedDialog).toContainText("groepsbeheerbevoegdheid nodig"); await expect(limitedDialog.getByRole("combobox", { name: "Loopgroep (optioneel)", exact: true })).toBeDisabled(); await expect(limitedDialog.getByRole("combobox", { name: /^Samenloop \(optioneel\)/ })).toBeDisabled(); await limitedDialog.getByRole("button", { name: "Annuleren", exact: true }).click();
    const fresh = await pending(newEmail), freshPage = await freshContext.newPage();
    // Delivery is intercepted, but token generation and verifyOtp below use the
    // real local GoTrue API and its real auth.sessions row; verify is not mocked.
    await freshPage.route(`${url}/auth/v1/otp`, route => route.fulfill({ json: {} }));
    await freshPage.goto(`${baseURL}${fresh.path}`); await freshPage.getByRole("textbox", { name: "E-mailadres", exact: true }).fill(newEmail); await freshPage.getByRole("button", { name: "Stuur eenmalige code", exact: true }).click(); await expect(freshPage.getByRole("heading", { name: "Vul de zes cijfers in." })).toBeVisible();
    const generated = await authAdmin.auth.admin.generateLink({ type: "magiclink", email: newEmail }); expect(generated.error).toBeNull(); if (!generated.data.properties) throw new Error("Local Auth did not return OTP properties"); const otp = generated.data.properties.email_otp; expect(otp).toMatch(/^\d{6}$/);
    const beforeOtp = new Set(outbox().map(row => row.id)); await freshPage.locator('input[autocomplete="one-time-code"]').fill(otp);
    const verified = freshPage.waitForResponse(response => response.url().includes("/auth/v1/verify") && response.request().method() === "POST"); await freshPage.getByRole("button", { name: "Bevestigen en verder", exact: true }).click(); expect((await verified).status()).toBe(200);
    await expect(freshPage.getByRole("heading", { name: "Jullie inschrijving is geactiveerd." })).toBeVisible(); const freshRow = await status(fresh.id); expect(freshRow.activation?.status).toBe("activated"); expect(freshRow.childCount).toBe(1); expect(freshRow.paidChildCount).toBe(0); expect(outbox().filter(row => !beforeOtp.has(row.id))).toHaveLength(0);
    const wrong = await pending(`browser-other-invited-${suffix}@example.invalid`); await login(wrongContext, baseURL!, "parent-b@example.invalid"); const wrongPage = await wrongContext.newPage(); await wrongPage.goto(`${baseURL}${wrong.path}?verified=1`); await expect(wrongPage.locator(".form-error[role=alert]")).toContainText("Deze uitnodiging kon niet worden bevestigd"); expect((await status(wrong.id)).activation?.status).toBe("pending"); await wrongPage.getByRole("button", { name: "Deze inschrijving activeren", exact: true }).click(); await expect(wrongPage.locator(".form-error[role=alert]")).toContainText("Deze uitnodiging kon niet worden bevestigd"); expect((await status(wrong.id)).activation?.status).toBe("pending");
    expect(sql("select coalesce((settings->>'groupRegistrationOpen')::boolean,true) from app_private.events where slug='duindorp-halloween-2026'")).toBe("f");
  } finally { await Promise.all([oldContext.close(), freshContext.close(), wrongContext.close()]); }
});
