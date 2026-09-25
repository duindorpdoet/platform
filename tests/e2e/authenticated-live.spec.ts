import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { assertReadableLayout } from "./helpers/layout";
import { readFile, writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const groupId = "23000000-0000-0000-0000-000000000001";
type LiveSnapshot = { run: { id: string; version: number; currentStop: { id: string }; participants: Array<{ id: string; statusVersion: number }> } };

function requireLocalAuth() {
  test.skip(!supabaseUrl || !publishableKey, "Local Supabase browser acceptance environment is not configured");
}

function sessionCookies(session: unknown) {
  const host = new URL(supabaseUrl!).hostname;
  const name = `sb-${host.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(session)).toString("base64url")}`;
  const chunks = value.length <= 3180 ? [{ name, value }] : Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180) }));
  return chunks.map((chunk) => ({ ...chunk, url: "http://127.0.0.1:3100", sameSite: "Lax" as const }));
}

async function fixtureClient(email = "leader-a@example.invalid") {
  const client = createClient(supabaseUrl!, publishableKey!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email, password: "local-test-only" });
  expect(login.error).toBeNull();
  expect(login.data.session).toBeTruthy();
  return { client, session: login.data.session! };
}

async function authenticate(context: BrowserContext, email: string) {
  const authenticated = await fixtureClient(email);
  await context.clearCookies();
  await context.addCookies(sessionCookies(authenticated.session));
  return authenticated.client;
}

async function selectAdminSection(page: Page, name: string) {
  await expect(page.locator(".admin-topbar")).toBeVisible();
  const menu = page.getByRole("button", { name: "Organisatienavigatie openen" });
  if (await menu.isVisible()) await menu.click();
  await page.locator(".admin-nav").getByRole("button", { name, exact: true }).click();
}

async function rpc(client: Awaited<ReturnType<typeof fixtureClient>>["client"], name: string, args: Record<string, unknown>) {
  const result = await client.schema("api").rpc(name, args);
  expect(result.error, `${name}: ${result.error?.message}`).toBeNull();
  return result.data;
}

test("the unified mobile participant environment keeps role navigation and payment-gated Night Pass clear", async ({ context, page }) => {
  requireLocalAuth();
  await page.setViewportSize({ width: 390, height: 844 });
  await authenticate(context, "parent-size-5@example.invalid");
  await page.goto("/omgeving/meeloper/nu");

  await expect(page.getByRole("heading", { name: "Klaar voor de nacht?" })).toBeVisible({ timeout: 15_000 });
  const bottomNavigation = page.getByRole("navigation", { name: "Mobiele omgevingsnavigatie" });
  await expect(bottomNavigation.getByRole("link", { name: "Nu" })).toBeVisible();
  await expect(bottomNavigation.getByRole("link", { name: "Route" })).toBeVisible();
  await expect(bottomNavigation.getByRole("link", { name: "Groep" })).toBeVisible();
  await expect(bottomNavigation.getByRole("link", { name: "Nachtpas" })).toBeVisible();
  await expect(bottomNavigation.getByRole("link", { name: "Meer" })).toBeVisible();
  await assertReadableLayout(page);

  await bottomNavigation.getByRole("link", { name: "Nachtpas" }).click();
  await expect(page.getByRole("heading", { name: "Jullie Nachtpas" })).toBeVisible();
  await expect(page.getByText("TOEGANG ACTIEF", { exact: true })).toBeVisible();
  await expect(page.getByText(/geen aparte QR-controle/i)).toBeVisible();
  await expect(page.locator('img[alt*="QR-code"]')).toHaveCount(0);
  await assertReadableLayout(page);
});

test("the homeowner cockpit labels schedules as planned rather than live ETA", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "owner@example.invalid");
  await page.goto("/omgeving/huiseigenaar/mijn-poort");

  await expect(page.getByText("Dit is een geplande aankomst, geen live ETA.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Open" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Pauze", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Gesloten" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Veilig ontvangen" })).toBeVisible();
  await assertReadableLayout(page);
});

test("forged cookies fail and offline group state reveals only the current stop before authoritative reconnect", async ({ context, page }, testInfo) => {
  test.skip(testInfo.project.name === "mobile-chromium", "The stateful route transition runs once; mobile route layout is covered separately.");
  requireLocalAuth();
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "mediaDevices", { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => { throw new DOMException("Camera denied", "NotAllowedError"); },
    } });
  });

  const forgedSession = {
    access_token: "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJmMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEiLCJyb2xlIjoiYXV0aGVudGljYXRlZCJ9.",
    refresh_token: "forged-session",
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    token_type: "bearer",
    user: { id: "f0000000-0000-0000-0000-000000000001" },
  };
  await context.addCookies(sessionCookies(forgedSession));
  await page.goto("/mijn-groep");
  await expect(page).toHaveURL(/\/inloggen\?next=/);
  await expect(page.getByLabel("E-mailadres")).toBeVisible();

  await context.clearCookies();
  const { client, session } = await fixtureClient();
  const roster = await rpc(client, "group_roster", { _group_id: groupId }) as Array<{ registrationChildId: string }>;
  const beforeStart = await rpc(client, "group_snapshot", { _group_id: groupId }) as { group: { version: number } };
  await rpc(client, "run_start", {
    _group_id: groupId,
    _present_registration_child_ids: roster.map((item) => item.registrationChildId),
    _expected_group_version: beforeStart.group.version,
    _idempotency_key: "browser-offline-run-start",
    _request_hash: "browser-offline-run-start",
  });
  await context.addCookies(sessionCookies(session));

  const groupPayloads: string[] = [];
  page.on("response", async (response) => {
    if (response.url().includes("/rpc/group_snapshot")) {
      try { groupPayloads.push(await response.text()); } catch { /* A deliberately interrupted offline response has no body. */ }
    }
  });
  await page.goto("/mijn-groep");
  await expect(page.getByRole("heading", { name: "Testpoort 01" })).toBeVisible();
  await expect(page.getByText(/volgende stop blijft nog een verrassing/i)).toBeVisible();

  const initialDocument = await page.content();
  const initialStorage = await page.evaluate(() => JSON.stringify(Array.from({ length: localStorage.length }, (_, index) => localStorage.getItem(localStorage.key(index)!))));
  const initialNetwork = groupPayloads.join("\n");
  for (const artifact of [initialDocument, initialStorage, initialNetwork]) {
    expect(artifact).not.toContain("Testpoort 02");
    expect(artifact).not.toContain("12000000-0000-0000-0000-000000000002");
  }

  await context.setOffline(true);
  await page.getByRole("button", { name: "Vernieuwen" }).click();
  await expect(page.locator(".offline-banner")).toContainText(/laatst door de server bevestigde opdracht/i);
  await expect(page.getByRole("heading", { name: "Testpoort 01" })).toBeVisible();
  await expect(page.getByRole("button", { name: "QR scannen" })).toBeDisabled();
  await expect(page.getByRole("button", { name: /overslaan/i }).first()).toBeDisabled();
  expect(await page.evaluate(() => JSON.stringify(Array.from({ length: localStorage.length }, (_, index) => localStorage.getItem(localStorage.key(index)!))))).not.toContain("Testpoort 02");

  let snapshot = await rpc(client, "group_snapshot", { _group_id: groupId }) as LiveSnapshot;
  await rpc(client, "run_scan", {
    _run_id: snapshot.run.id,
    _expected_stop_id: snapshot.run.currentStop.id,
    _expected_run_version: snapshot.run.version,
    _credential: "TEST-PORTAL-01-TOKEN",
    _method: "qr",
  });
  snapshot = await rpc(client, "group_snapshot", { _group_id: groupId }) as LiveSnapshot;
  await rpc(client, "run_update_participant", {
    _run_id: snapshot.run.id,
    _stop_id: snapshot.run.currentStop.id,
    _run_participant_id: snapshot.run.participants[0].id,
    _new_status: "visited",
    _expected_run_version: snapshot.run.version,
    _expected_status_version: snapshot.run.participants[0].statusVersion,
    _reason: null,
  });
  snapshot = await rpc(client, "group_snapshot", { _group_id: groupId }) as LiveSnapshot;
  await rpc(client, "run_complete_stop", {
    _run_id: snapshot.run.id,
    _stop_id: snapshot.run.currentStop.id,
    _expected_run_version: snapshot.run.version,
    _all_skip_confirmed: false,
    _idempotency_key: "browser-offline-complete-stop-1",
    _request_hash: "browser-offline-complete-stop-1",
  });

  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await expect(page.getByRole("heading", { name: "Testpoort 02" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Testpoort 02" })).toBeFocused();
  await expect(page.locator(".offline-banner")).toHaveCount(0);
  await expect.poll(() => groupPayloads.some((payload) => payload.includes("Testpoort 02"))).toBeTruthy();
  expect(groupPayloads.at(-1)).not.toContain("Testpoort 03");

  await page.getByRole("button", { name: "QR scannen" }).click();
  await expect(page.getByRole("dialog", { name: "QR-scanner" })).toBeVisible();
  await expect(page.getByText(/camera niet beschikbaar/i)).toBeVisible();
  await page.getByRole("dialog", { name: "QR-scanner" }).getByRole("button", { name: "Sluiten", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "QR-scanner" })).toHaveCount(0);
  await expect(page.getByLabel("Korte poortcode")).toBeVisible();

  // A canvas stream exercises real MediaStream tracks without physical hardware.
  await page.evaluate(() => {
    const state = window as typeof window & { cameraStreams: MediaStream[]; delayCamera: boolean; releaseCamera?: () => void };
    state.cameraStreams = [];
    state.delayCamera = false;
    navigator.mediaDevices.getUserMedia = async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 320; canvas.height = 240;
      const stream = canvas.captureStream(5);
      state.cameraStreams.push(stream);
      if (state.delayCamera) await new Promise<void>((resolve) => { state.releaseCamera = resolve; });
      return stream;
    };
  });
  const trackStates = () => page.evaluate(() => (window as typeof window & { cameraStreams: MediaStream[] }).cameraStreams.map((stream) => stream.getTracks().map((track) => track.readyState)));
  await page.getByRole("button", { name: "QR scannen" }).click();
  await expect.poll(trackStates).toEqual([["live"]]);
  await page.getByRole("dialog", { name: "QR-scanner" }).getByRole("button", { name: "Sluiten", exact: true }).click();
  await expect.poll(trackStates).toEqual([["ended"]]);

  await page.evaluate(() => { (window as typeof window & { delayCamera: boolean }).delayCamera = true; });
  await page.getByRole("button", { name: "QR scannen" }).click();
  await expect.poll(trackStates).toEqual([["ended"], ["live"]]);
  await page.getByRole("dialog", { name: "QR-scanner" }).getByRole("button", { name: "Sluiten", exact: true }).click();
  await page.evaluate(() => { (window as typeof window & { releaseCamera: () => void }).releaseCamera(); });
  await expect.poll(trackStates).toEqual([["ended"], ["ended"]]);

  await page.evaluate(() => { (window as typeof window & { delayCamera: boolean }).delayCamera = false; });
  await page.getByRole("button", { name: "QR scannen" }).click();
  await expect.poll(trackStates).toEqual([["ended"], ["ended"], ["live"]]);
  // Client navigation preserves the JS realm so stopped tracks remain observable.
  await page.locator('a[href="/"]').first().evaluate((link: HTMLAnchorElement) => link.click());
  await expect(page).toHaveURL("/");
  await expect.poll(trackStates).toEqual([["ended"], ["ended"], ["ended"]]);
});

test("a multi-child registration draft survives refresh and submits once", async ({ context, page }, testInfo) => {
  requireLocalAuth();
  await page.setViewportSize({ width: 320, height: 844 });
  const registrationEmail = testInfo.project.name === "mobile-chromium"
    ? "browser-registration-mobile@example.invalid"
    : "browser-registration-desktop@example.invalid";
  const client = await authenticate(context, registrationEmail);
  const source = await fixtureClient("parent-a@example.invalid");
  const sourceSnapshot = await rpc(source.client, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as { registration: { togetherCode: string } };
  const sharedTogetherCode = sourceSnapshot.registration.togetherCode;
  await page.goto("/meelopen");
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.locator(".wizard").getByRole("alert")).toBeFocused();
  await expect(page.getByLabel("E-mailadres (geverifieerd account)")).toHaveValue(registrationEmail);
  await expect(page.getByLabel("E-mailadres (geverifieerd account)")).toHaveAttribute("readonly", "");
  await page.getByLabel("Naam verantwoordelijke volwassene").fill("Browser testouder");
  await page.getByLabel("Telefoonnummer voor de avond").fill("0612345678");
  for (const label of ["Gewenste starttijd", "Wanneer stoppen jullie met gewone poorten?"]) {
    const choices = await page.getByLabel(label, { exact: false }).locator("option").allTextContents();
    const times = choices.filter((choice) => /^\d{2}:\d{2}$/.test(choice));
    expect(times.length).toBeGreaterThan(1);
    expect(times.every((time) => Number(time.slice(3)) % 10 === 0)).toBe(true);
  }
  await page.getByLabel("Gewenste starttijd", { exact: false }).selectOption({ label: "17:10" });
  await page.getByLabel("Wanneer stoppen jullie met gewone poorten?", { exact: false }).selectOption({ label: "20:10" });
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.getByRole("heading", { name: "Deelnemende kinderen" })).toBeFocused();
  await assertReadableLayout(page);
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.locator(".wizard").getByRole("alert")).toBeFocused();
  await page.getByLabel("Voornaam kind 1").fill("Eerste testkind");
  // Install an actual changed worker while this value exists only in React state.
  const workerPath = "public/sw.js";
  const originalWorker = await readFile(workerPath, "utf8");
  try {
    await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) await new Promise<void>((resolve) => navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true }));
    });
    await writeFile(workerPath, `${originalWorker}\n// Acceptance update ${Date.now()}\n`);
    await page.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      const changed = new Promise<void>((resolve) => navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true }));
      await registration!.update();
      await changed;
    });
    await expect(page.getByRole("heading", { name: "Deelnemende kinderen" })).toBeVisible();
    await expect(page.getByLabel("Voornaam kind 1")).toHaveValue("Eerste testkind");
  } finally {
    await writeFile(workerPath, originalWorker);
  }
  await page.getByLabel("Leeftijd op 31 oktober").fill("8");
  await page.getByRole("button", { name: "Nog een kind" }).click();
  await page.getByLabel("Voornaam kind 2").fill("Tweede testkind");
  await page.getByLabel("Leeftijd op 31 oktober").nth(1).fill("10");
  await page.getByLabel("Samenloopcode (optioneel)").fill(sharedTogetherCode.toLowerCase());
  await expect(page.getByLabel("Samenloopcode (optioneel)")).toHaveValue(sharedTogetherCode);
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.getByRole("heading", { name: "Controleren" })).toBeVisible();

  await page.reload();
  await expect(page.getByLabel("Naam van het huishouden")).toHaveCount(0);
  await expect(page.getByLabel("Naam verantwoordelijke volwassene")).toHaveValue("Browser testouder");
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.getByLabel("Voornaam kind 1")).toHaveValue("Eerste testkind");
  await expect(page.getByLabel("Voornaam kind 2")).toHaveValue("Tweede testkind");
  await expect(page.getByLabel("Samenloopcode (optioneel)")).toHaveValue(sharedTogetherCode);
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await page.getByRole("checkbox", { name: /ik ga akkoord/i }).check();
  let submitCalls = 0;
  page.on("request", (request) => { if (request.url().includes("/rpc/registration_submit")) submitCalls += 1; });
  await page.route("**/rpc/registration_save_draft", (route) => route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ code: "P0001", message: "STALE_VERSION" }) }));
  await page.getByRole("button", { name: "Definitief inschrijven" }).click();
  await expect(page.locator(".wizard").getByRole("alert")).toBeFocused();
  await expect(page.locator(".wizard").getByRole("alert")).toContainText("intussen veranderd");
  expect(submitCalls).toBe(0);
  await page.unroute("**/rpc/registration_save_draft");
  await page.getByRole("button", { name: "Vorige" }).click();
  await expect(page.getByRole("heading", { name: "Deelnemende kinderen" })).toBeFocused();
  await assertReadableLayout(page);
  await expect(page.getByLabel("Voornaam kind 1")).toHaveValue("Eerste testkind");
  await page.getByRole("button", { name: "Opslaan en verder" }).click();
  await expect(page.getByRole("heading", { name: "Controleren" })).toBeFocused();
  await assertReadableLayout(page);
  await page.getByRole("button", { name: "Definitief inschrijven" }).click();
  await expect(page.getByRole("heading", { name: "Welkom bij de poorten!" })).toBeVisible();

  const snapshot = await rpc(client, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as { registration: { id: string; priceCents: number; togetherCode: string; togetherCount: number; togetherRequest?: { status: string; requestedCode: string } } };
  expect(snapshot.registration.id).toBeTruthy();
  expect(snapshot.registration.priceCents).toBe(500);
  expect(snapshot.registration.togetherCode).toMatch(/^[A-HJ-NP-Z2-9]{4}$/);
  expect(snapshot.registration.togetherCount).toBe(1);
  expect(snapshot.registration.togetherRequest).toMatchObject({ status: "pending", requestedCode: sharedTogetherCode });

  await page.goto("/mijn-inschrijving");
  await expect(page.getByText("Eerste testkind")).toBeVisible();
  await expect(page.getByText("Wacht op betaallink", { exact: true })).toBeVisible();
  await expect(page.getByText(snapshot.registration.togetherCode, { exact: true })).toBeVisible();
  await expect(page.locator("body")).not.toContainText("awaiting_link");
  const addChild = page.locator(".registration-child-form");
  await expect(addChild.getByRole("heading", { name: "Nog iemand aanmelden" })).toBeVisible();
  await assertReadableLayout(page);
  await addChild.getByLabel("Voornaam").fill("Derde browserkind");
  await addChild.getByLabel("Leeftijd op 31 oktober").fill("7");
  await addChild.getByRole("button", { name: "Kind toevoegen" }).click();
  await expect(page.getByRole("status")).toContainText(/Derde browserkind is aan de inschrijving toegevoegd/i);
  const addedChild = page.locator(".child-payment-row").filter({ hasText: "Derde browserkind" });
  await assertReadableLayout(page);
  await expect(addedChild).toBeVisible();
  page.once("dialog", (dialog) => dialog.accept());
  await addedChild.getByRole("button", { name: "Verwijderen", exact: true }).click();
  await expect(page.getByRole("status")).toContainText(/Derde browserkind is uit de inschrijving verwijderd/i);
  await expect(addedChild).toContainText("Afgezegd");
  await expect(addedChild.getByRole("button", { name: "Verwijderen", exact: true })).toHaveCount(0);
});

test("submitted registrations appear immediately with group details in the backoffice", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  const registrationsMetric = page.locator(".cockpit-metrics .metric").filter({ hasText: "Inschrijvingen" });
  await expect(registrationsMetric).toContainText(/ingeschreven kinderen?/i);
  await page.getByRole("button", { name: /Inschrijvingen/ }).click();

  await expect(page.getByRole("heading", { name: "Alle inschrijvingen" })).toBeVisible();
  await expect(page.locator(".registration-roster-heading .registration-total")).toContainText(/inschrijvingen? · \d+ kinderen?/i);
  const registration = page.locator(".registration-admin-card").first();
  await expect(registration).toBeVisible();
  await expect(registration.locator(".registration-admin-name strong")).not.toBeEmpty();
  await registration.getByRole("button", { name: "Bekijk details" }).click();
  await expect(registration).toContainText("Contactpersoon");
  await expect(registration).toContainText("Kinderen");
  await expect(registration.getByRole("link", { name: /@/ })).toHaveAttribute("href", /^mailto:/);
  await assertReadableLayout(page);
});

test("an event administrator can grant and revoke narrowly scoped access", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  await selectAdminSection(page, "Beheerders");
  await expect(page.getByRole("heading", { name: "Beheerders en rechten" })).toBeVisible();

  await page.getByLabel("E-mailadres").fill("parent-a@example.invalid");
  for (const name of [
    "Hoofdbeheer",
    "Inschrijvingen",
    "Betalingen",
    "Groepen en routes",
    "Avondondersteuning",
    "Content en sponsors",
  ]) {
    await page.getByRole("checkbox", { name: new RegExp(`^${name}`) }).uncheck();
  }
  await page.getByRole("button", { name: "Beheerder toevoegen" }).click();
  await expect(page.getByRole("status")).toContainText(/rechten.*bijgewerkt/i);

  const member = page.locator(".admin-access-member").filter({ hasText: "parent-a@example.invalid" });
  await expect(member).toContainText("Locaties");
  await member.getByRole("button", { name: "Bewerken" }).click();
  await expect(page.getByLabel("E-mailadres")).toHaveAttribute("readonly", "");
  await page.getByRole("checkbox", { name: /^Locaties/ }).uncheck();
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Rechten opslaan" }).click();
  await expect(page.getByRole("status")).toContainText(/rechten.*bijgewerkt/i);
  await expect(member).toHaveCount(0);
});

test("an organizer sees deduplicated registrations and approved active portals", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  await selectAdminSection(page, "Poorten");
  await expect(page.getByRole("heading", { name: "Poorten", exact: true })).toBeVisible();
  await expect(page.getByRole("tab", { name: /Aangemelde poorten/ })).toHaveAttribute("aria-selected", "true");

  const registrationRow = page.locator(".portal-list-row").filter({ hasText: "P-01" }).first();
  await expect(registrationRow).toContainText("Test contactpersoon");
  await expect(registrationRow.getByRole("link", { name: "0612345678" })).toHaveAttribute("href", "tel:0612345678");
  await registrationRow.locator(".portal-primary").click();
  await expect(registrationRow).toHaveAttribute("open", "");
  await expect(registrationRow).toContainText("Voortgang aanvraag");
  await expect(registrationRow.getByRole("link", { name: "owner@example.invalid" })).toHaveAttribute("href", "mailto:owner@example.invalid");

  await page.getByRole("tab", { name: /Actieve poorten/ }).click();
  await expect(page.getByRole("tab", { name: /Actieve poorten/ })).toHaveAttribute("aria-selected", "true");
  const activePortal = page.locator(".active-portals-list .portal-list-row").filter({ hasText: "P-01" }).first();
  await expect(activePortal).toContainText("Testpoort 01");
  await activePortal.locator(".portal-primary").click();
  await expect(activePortal).toHaveAttribute("open", "");
  await expect(activePortal).toContainText("NIET-BESTAAND TESTADRES 1");
  await expect(activePortal.getByRole("button", { name: "Open", exact: true })).toBeVisible();
  await expect(activePortal.getByRole("button", { name: "Pauze", exact: true })).toBeVisible();
  await expect(activePortal.getByRole("button", { name: "Gestopt", exact: true })).toBeVisible();
  await assertReadableLayout(page);
});

test("the night cockpit exposes verified portals and the group board without leaking through public roles", async ({ context, page }) => {
  requireLocalAuth();
  test.setTimeout(60_000);
  const admin = await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");

  const activityMessages = page.locator(".cockpit-live-log .activity-row strong");
  await expect(activityMessages.first()).toBeVisible({ timeout: 15_000 });
  for (const message of await activityMessages.allTextContents()) expect(message).not.toMatch(/[._]/);
  for (const detail of await page.locator(".cockpit-live-log .activity-row small").allTextContents()) {
    expect(detail.split(" · ")[0]).not.toMatch(/[._]/);
  }

  const mapPanel = page.locator(".cockpit-map-panel");
  await expect(mapPanel).toContainText(/bevestigde bestemming/i);
  await expect(mapPanel.getByRole("group", { name: "Filter poorten op status" })).toBeVisible({ timeout: 15_000 });
  await expect(mapPanel.getByRole("button", { name: "Open", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.waitForTimeout(850); // Let the initial fit animation settle before verifying keyboard focus.
  for (let attempt = 0; attempt < 4 && await mapPanel.locator(".night-map-portal-pin").count() === 0; attempt += 1) {
    const cluster = mapPanel.locator(".night-map-cluster").first();
    await expect(cluster).toBeVisible();
    await expect.poll(async () => {
      if (!(await cluster.isVisible())) return false;
      return cluster.evaluate((element) => {
        (element as HTMLElement).focus();
        return document.activeElement === element;
      }).catch(() => false);
    }, { timeout: 5_000 }).toBe(true);
    await cluster.click();
    await page.waitForTimeout(550);
  }
  const pins = mapPanel.locator(".night-map-portal-pin");
  const interactivePinIndex = await pins.evaluateAll((elements) => {
    const map = elements[0]?.closest(".maplibregl-map")?.getBoundingClientRect();
    if (!map) return -1;
    return elements.findIndex((element) => {
      const rect = element.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const hit = document.elementFromPoint(x, y);
      return x > map.left && x < map.right && y > map.top && y < map.bottom && Boolean(hit && (hit === element || element.contains(hit)));
    });
  });
  expect(interactivePinIndex).toBeGreaterThanOrEqual(0);
  const pin = pins.nth(interactivePinIndex);
  await expect(pin).toBeVisible();
  await pin.hover();
  const popup = mapPanel.locator(".night-map-popup").filter({ hasText: "Adres:" }).first();
  await expect(popup).toContainText("Contact:");
  await expect(popup).toContainText("Status:");
  await expect(popup.getByRole("link", { name: /^Bel / })).toHaveAttribute("href", /^tel:/);
  await pin.focus();
  await expect(pin).toBeFocused();
  await expect(popup.getByRole("button", { name: "Poort bekijken" })).toBeVisible();

  type PortalOperations = { portals: Array<{ portalId: string; systemCode: string; operationStatus: "scheduled" | "open" | "paused" | "closed"; version: number }> };
  const before = await rpc(admin, "admin_portal_operations_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PortalOperations;
  const livePortal = before.portals.find((portal) => portal.systemCode === "P-01")!;
  const nextStatus = livePortal.operationStatus === "paused" ? "open" : "paused";
  await rpc(admin, "portal_set_operational_state", {
    _portal_id: livePortal.portalId,
    _state: nextStatus,
    _expected_version: livePortal.version,
    _reason: "Browseracceptatie live kaartstatus",
  });
  try {
    await expect(page.locator(".cockpit-portal-card").filter({ hasText: "P-01" })).toContainText(nextStatus === "open" ? "Open" : "Pauze", { timeout: 25_000 });
  } finally {
    const changed = await rpc(admin, "admin_portal_operations_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PortalOperations;
    const changedPortal = changed.portals.find((portal) => portal.portalId === livePortal.portalId)!;
    await rpc(admin, "portal_set_operational_state", {
      _portal_id: livePortal.portalId,
      _state: livePortal.operationStatus,
      _expected_version: changedPortal.version,
      _reason: "Browseracceptatie kaartstatus hersteld",
    });
  }

  await selectAdminSection(page, "Poorten");
  const operation = page.locator(".portal-operation-tile").filter({ hasText: "P-01" });
  await expect(operation).toContainText("NIET-BESTAAND TESTADRES 1, 0000AA Teststad");
  await expect(operation).toContainText("Test contactpersoon");
  await expect(operation.getByRole("link", { name: "0612345678" })).toHaveAttribute("href", "tel:0612345678");
  await expect(operation.getByRole("button", { name: "Open", exact: true })).toBeVisible();

  await selectAdminSection(page, "Groepsindeling");
  await expect(page.getByRole("heading", { name: "Maak de wandelgroepen." })).toBeVisible();
  await expect(page.locator(".group-composition-column").first()).toContainText(/kinderen/i);
  await expect(
    page.locator(".group-registration-children").filter({ hasText: /\(\d+ jaar\)/ }).first(),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Groep maken" })).toBeVisible();
  await assertReadableLayout(page);
});

test("the organizer map reports a style outage and can be reloaded", async ({ browser }, testInfo) => {
  requireLocalAuth();
  test.skip(testInfo.project.name !== "desktop-chromium", "The map outage path only needs one browser run.");
  const isolated = await browser.newContext({ baseURL: "http://127.0.0.1:3100", serviceWorkers: "block" });
  try {
    const page = await isolated.newPage();
    await page.route("**/maps/duindorp-night.json", (route) => route.fulfill({ status: 503, contentType: "application/json", body: "{}" }));
    await authenticate(isolated, "admin@example.invalid");
    await page.goto("/admin");
    const map = page.locator(".cockpit-map-panel .night-map");
    await expect(map.getByText("Kaart tijdelijk niet beschikbaar")).toBeVisible({ timeout: 15_000 });
    await expect(map.getByRole("button", { name: "Kaart opnieuw laden" })).toBeVisible();
    await page.unroute("**/maps/duindorp-night.json");
    await map.getByRole("button", { name: "Kaart opnieuw laden" }).click();
    await expect(map.locator(".maplibregl-canvas")).toBeVisible({ timeout: 15_000 });
    await expect(map.getByText("Kaart tijdelijk niet beschikbaar")).toHaveCount(0);
  } finally {
    await isolated.close();
  }
});

test("a group leader and organizer can exchange messages through the private support widget", async ({ context, page }, testInfo) => {
  requireLocalAuth();
  const suffix = testInfo.project.name === "mobile-chromium" ? "mobiel" : "desktop";
  const leaderMessage = `Kunnen jullie het startmoment voor ${suffix} bevestigen?`;
  const organizerReply = `Ja, het startmoment voor ${suffix} staat definitief vast.`;

  await authenticate(context, "leader-a@example.invalid");
  await page.goto("/mijn-groep");
  const launcher = page.getByRole("button", { name: /Hulp van de organisatie/ });
  await expect(launcher).toBeVisible();
  await launcher.click();
  const participantDialog = page.getByRole("dialog");
  await expect(participantDialog).toBeVisible();
  await participantDialog.getByLabel("Bericht").fill(leaderMessage);
  await participantDialog.getByRole("button", { name: "Versturen" }).click();
  await expect(participantDialog).toContainText(leaderMessage);
  await expect(participantDialog.getByRole("status")).toContainText(/verstuurd/i);
  await assertReadableLayout(page);

  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  await selectAdminSection(page, "Messenger");
  const conversationButton = page.locator(".ticket-list button").filter({ hasText: "G-01" }).first();
  await expect(conversationButton).toBeVisible();
  await conversationButton.click();
  await expect(page.locator(".ticket-thread")).toContainText(leaderMessage);
  const claimButton = page.getByRole("button", { name: "Gesprek openen" });
  if (await claimButton.isVisible()) await claimButton.click();
  await page.getByLabel("Antwoord").fill(organizerReply);
  await page.locator(".ticket-reply").getByRole("button", { name: "Versturen" }).click();
  await expect(page.locator(".ticket-thread")).toContainText(organizerReply);
  await expect(page.getByRole("status")).toContainText(/verstuurd/i);
  await assertReadableLayout(page);

  await authenticate(context, "leader-a@example.invalid");
  await page.goto("/mijn-groep");
  await page.getByRole("button", { name: /Hulp van de organisatie/ }).click();
  await expect(page.getByRole("dialog")).toContainText(organizerReply);
});

test("a portal draft survives refresh and rejects disguised executable upload content", async ({ context, page }, testInfo) => {
  requireLocalAuth();
  const email = testInfo.project.name === "mobile-chromium" ? "parent-size-7@example.invalid" : "leader-b@example.invalid";
  await authenticate(context, email);
  await page.goto("/huis-aanmelden");
  await page.getByLabel("Naam contactpersoon *").fill("Browser testbewoner");
  await page.getByLabel("Telefoonnummer *").fill("0612345678");
  await page.getByRole("button", { name: "Plek aanmelden" }).click();
  await expect(page).toHaveURL(/\/mijn-huis$/);
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByLabel("E-mailadres *")).toHaveValue(email);
  for (const removed of ["Bezoekduur", "Groepen tegelijk", "Kinderen per bezoek", "Kinderen totaal"]) {
    await expect(page.getByLabel(removed, { exact: false })).toHaveCount(0);
  }
  await expect(page.getByLabel("Praktische toegankelijkheid (optioneel)")).toBeVisible();
  await expect(page.getByLabel("Straat")).toHaveValue("");
  await expect(page.getByLabel("Categorie of gewenste wereld")).toHaveValue("anders");
  await expect(page.getByLabel("Beschikbaar vanaf")).toHaveValue("17:00");
  await expect(page.getByLabel("Beschikbaar tot")).toHaveValue("21:00");
  await page.getByLabel("Straat").fill("NIET-BESTAANDE TESTSTRAAT");
  await page.getByLabel("Huisnummer").fill("12");
  await page.getByLabel("Postcode").fill("2584AB");
  await page.getByRole("button", { name: "Concept opslaan" }).click();
  await expect(page.getByRole("status")).toContainText(/bewaard/i);
  await page.reload();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Browser testbewoner");
  await expect(page.getByLabel("Straat")).toHaveValue("NIET-BESTAANDE TESTSTRAAT");

  const chooser = page.getByLabel("Foto van de opstelling (optioneel)");
  await chooser.setInputFiles({ name: "misleidend.png", mimeType: "image/png", buffer: Buffer.from("<svg><script>alert(1)</script></svg>") });
  await expect(page.getByRole("status")).toContainText(/geen geldige/i);
  await chooser.setInputFiles({ name: "poort.png", mimeType: "image/png", buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) });
  await expect(page.getByRole("status")).toContainText(/foto staat bij jullie aanmelding/i);
  await expect(page.getByText(/1 afbeelding.*veilig/i)).toBeVisible();
  await page.reload();
  await expect(page.getByText(/1 afbeelding.*veilig/i)).toBeVisible();
});

test("an existing homeowner account is routed to the same house instead of creating a duplicate", async ({ context, page }) => {
  requireLocalAuth();
  const { client } = await fixtureClient("owner@example.invalid");
  const before = await rpc(client, "portal_snapshot", { _event_slug: "duindorp-halloween-2026" }) as { application: { id: string } };
  await authenticate(context, "owner@example.invalid");
  await page.goto("/huis-aanmelden");
  await expect(page.getByRole("heading", { name: "Jullie plek is al aangemeld" })).toBeVisible();
  await page.getByRole("button", { name: "Naar Mijn huis" }).click();
  await expect(page).toHaveURL(/\/mijn-huis$/);
  const after = await rpc(client, "portal_snapshot", { _event_slug: "duindorp-halloween-2026" }) as { application: { id: string } };
  expect(after.application.id).toBe(before.application.id);
});

for (const size of [{ width: 320, doubleText: false }, { width: 390, doubleText: true }, { width: 768, doubleText: false }, { width: 1440, doubleText: false }]) {
  const { doubleText } = size;
  test(`private screens fit ${size.width}px with ${doubleText ? "200%" : "100%"} text`, async ({ context, page }) => {
    requireLocalAuth();
    test.setTimeout(180_000);
    await page.setViewportSize({ width: size.width, height: 844 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    for (const actor of [
      { email: "parent-a@example.invalid", paths: ["/mijn-inschrijving", "/meelopen"] },
      { email: "owner@example.invalid", paths: ["/mijn-huis", "/huis-aanmelden", "/omgeving/huiseigenaar/mijn-poort", "/omgeving/huiseigenaar/verwacht", "/omgeving/huiseigenaar/updates", "/omgeving/huiseigenaar/meer"] },
      { email: "leader-a@example.invalid", paths: ["/mijn-groep", "/omgeving/meeloper/nu", "/omgeving/meeloper/route", "/omgeving/meeloper/groep", "/omgeving/meeloper/nachtpas", "/omgeving/meeloper/meer"] },
      { email: "admin@example.invalid", paths: ["/admin"] },
    ]) {
      await authenticate(context, actor.email);
      for (const path of actor.paths) {
        await page.goto(path);
        await expect(page.locator(".loading-state, .participant-loading")).toHaveCount(0);
        await assertReadableLayout(page, doubleText);
        if (path === "/admin") {
          await selectAdminSection(page, "Instellingen");
          await expect(page.getByRole("switch", { name: /Open · klik om te sluiten/i })).toHaveCount(2);
          for (const section of ["Cockpit", "Imports", "Inschrijvingen", "Groepsindeling", "Messenger", "Deelnemersupdates", "Betalingen", "Poorten", "Startpunten en indeling", "Content & sponsors", "Beheerders", "Avond live", "Avondsimulatie", "Instellingen"]) {
            await page.goto("/admin");
            await selectAdminSection(page, section);
            await expect(page.locator(".admin-nav button").filter({ hasText: section }).first()).toHaveClass("active");
            await assertReadableLayout(page, doubleText);
          }
        }
      }
    }
  });
}

test("a rapid double tap requests only one email code", async ({ page }) => {
  requireLocalAuth();
  let requestCount = 0;
  await page.route(`${supabaseUrl}/auth/v1/otp`, async (route) => {
    requestCount += 1;
    await new Promise((resolve) => setTimeout(resolve, 150));
    await route.fulfill({ json: {} });
  });
  await page.goto("/inloggen");
  await page.getByLabel("E-mailadres").fill("mobile-double-tap@example.invalid");
  const submit = page.getByRole("button", { name: "Stuur eenmalige code" });
  await submit.evaluate((element: HTMLButtonElement) => {
    element.click();
    element.click();
  });
  await expect(page.getByRole("heading", { name: "Vul de zes cijfers in." })).toBeVisible();
  expect(requestCount).toBe(1);
});

test("house details unlock only after successful email confirmation", async ({ page }, testInfo) => {
  requireLocalAuth();
  const email = testInfo.project.name === "mobile-chromium" ? "parent-size-10@example.invalid" : "parent-size-5@example.invalid";
  const { client, session } = await fixtureClient(email);
  // Simulate delivery and entering an OTP, then use a real local Auth session and database.
  await page.route(`${supabaseUrl}/auth/v1/otp`, (route) => route.fulfill({ json: {} }));
  await page.route(`${supabaseUrl}/auth/v1/verify`, (route) => {
    const token = route.request().postDataJSON().token;
    return token === "123456"
      ? route.fulfill({ json: session })
      : route.fulfill({ status: 403, json: { code: "otp_expired", msg: "Invalid code" } });
  });
  await page.goto("/huis-aanmelden");
  await page.getByLabel("E-mailadres *", { exact: true }).fill(email);
  await page.getByLabel("Naam contactpersoon *").fill("Nieuwe testbewoner");
  await page.getByLabel("Telefoonnummer *").fill("0612345678");
  await page.getByRole("button", { name: "Stuur eenmalige code" }).click();
  await expect(page.getByRole("heading", { name: "Vul de zes cijfers in." })).toBeVisible();
  await assertReadableLayout(page);
  const otpWidth = await page.locator('[data-slot="input-otp-group"]').evaluate((element) => element.getBoundingClientRect().width);
  const formWidth = await page.locator(".auth-form").evaluate((element) => element.getBoundingClientRect().width);
  expect(otpWidth).toBeGreaterThan(formWidth * 0.75);
  expect(await rpc(client, "portal_snapshot", { _event_slug: "duindorp-halloween-2026" })).toBeNull();
  await page.locator('input[autocomplete="one-time-code"]').fill("000000");
  await page.getByRole("button", { name: "Bevestigen en verder" }).click();
  await expect(page.getByRole("status")).toContainText("onjuist of verlopen");
  await expect(page.getByLabel("Beschrijving (optioneel)", { exact: true })).toHaveCount(0);
  await page.locator('input[autocomplete="one-time-code"]').fill("");
  await page.locator('input[autocomplete="one-time-code"]').fill("123456");
  await page.getByRole("button", { name: "Bevestigen en verder" }).click();
  await expect(page).toHaveURL(/\/mijn-huis$/);
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Nieuwe testbewoner");
  await expect(page.getByLabel("E-mailadres *")).toHaveValue(email);
  await expect(page.getByLabel("Straat")).toHaveValue("");
  await expect(page.getByLabel("Categorie of gewenste wereld")).toHaveValue("anders");
  await expect(page.getByLabel("Beschikbaar vanaf")).toHaveValue("17:00");
  await expect(page.getByLabel("Beschikbaar tot")).toHaveValue("21:00");
  await page.getByLabel("Straat").fill("FICTIEVE STRAAT");
  await page.getByLabel("Huisnummer").fill("15");
  await page.getByLabel("Postcode").fill("2584AB");
  await expect(page.getByLabel("Straat")).toHaveValue("FICTIEVE STRAAT");
  await page.getByLabel("Naam contactpersoon *").fill("Nieuwe testbewoner gewijzigd");
  await page.getByRole("button", { name: "Concept opslaan" }).click();
  await expect(page.getByRole("status")).toContainText(/bewaard/i);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Nieuwe testbewoner gewijzigd");
  await expect(page.getByLabel("Straat")).toHaveValue("FICTIEVE STRAAT");
});


test("participant Messenger is opaque and account actions stay reachable on desktop and mobile", async ({ context, page }, testInfo) => {
  requireLocalAuth();
  await authenticate(context, "parent-size-5@example.invalid");
  for (const viewport of [{ width: 1440, height: 900 }, { width: 700, height: 844 }, { width: 320, height: 568 }]) {
    await page.setViewportSize(viewport);
    await page.goto("/omgeving/meeloper/meer");
    await expect(page.getByRole("heading", { name: "Jouw voorkeuren" })).toBeVisible();
    await expect(page.locator(".motion-toggle")).toHaveCount(0);
    await expect(page.getByLabel("Verminder beweging")).toBeVisible();
    const logout = page.locator(".participant-account").getByRole("button", { name: "Uitloggen", exact: true });
    await logout.scrollIntoViewIfNeeded();
    await expect(logout).toBeVisible();
    await logout.click({ trial: true });
    await page.getByRole("button", { name: "Hulp van de organisatie" }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toHaveCSS("background-color", "rgb(14, 25, 35)");
    await expect(dialog).toHaveCSS("color", "rgb(237, 241, 241)");
    await expect(dialog.getByRole("button", { name: "Gesprek sluiten" })).toBeVisible();
    await expect(dialog.getByLabel("Bericht", { exact: true })).toBeVisible();
    const bounds = await dialog.boundingBox();
    expect(bounds!.x).toBeGreaterThanOrEqual(0);
    expect(bounds!.y).toBeGreaterThanOrEqual(0);
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(viewport.width);
    expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(viewport.height);
    if (viewport.width <= 760) {
      const navigation = await page.locator(".participant-bottomnav").boundingBox();
      expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(navigation!.y);
    }
    await page.screenshot({ path: testInfo.outputPath(`messenger-${viewport.width}.png`) });
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Hulp van de organisatie" })).toBeFocused();
    await assertReadableLayout(page);
  }
});


test("a walker awaiting a group can send and recover chat without realtime", async ({ context, page }, testInfo) => {
  requireLocalAuth();
  test.skip(testInfo.project.name !== "desktop-chromium", "The stateful recovery flow runs once at the mobile viewport; responsive chat is covered in both projects.");
  await page.setViewportSize({ width: 390, height: 844 });
  const client = await authenticate(context, "browser-chat-unassigned@example.invalid");
  const participant = await rpc(client, "participant_context", { _event_slug: "duindorp-halloween-2026" }) as { roles: Array<{ key: string; groupId: string | null }> };
  expect(participant.roles.find((role) => role.key === "walker")?.groupId).toBeNull();
  // Polling and HTTP sends must keep working when the realtime socket cannot connect.
  await page.routeWebSocket(/\/realtime\/v1\/websocket/, (socket) => socket.close());
  let failContext = true;
  await page.route("**/rest/v1/rpc/participant_messenger_context", async (route) => {
    if (failContext) {
      await route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ message: "Temporarily unavailable" }) });
    } else await route.continue();
  });
  await page.goto("/omgeving/meeloper/nu");
  await page.getByRole("button", { name: "Hulp van de organisatie" }).click();
  const dialog = page.getByRole("dialog");
  const input = dialog.getByLabel("Bericht", { exact: true });
  const send = dialog.getByRole("button", { name: "Versturen", exact: true });
  const body = `Browserbericht zonder groepsindeling ${testInfo.testId}-${Date.now()}`;
  const deliveredMessage = dialog.locator("article").getByText(body, { exact: true });
  await input.fill(body);
  await expect(dialog.getByText(/Berichten konden niet worden vernieuwd/)).toBeVisible();
  await expect(send).toBeDisabled();
  failContext = false;
  await dialog.getByRole("button", { name: "Opnieuw verbinden" }).click();
  await expect(send).toBeEnabled();
  await expect(input).toHaveCSS("scrollbar-width", "thin");
  await expect(input).toHaveCSS("resize", "none");

  // Simulate a response lost after the server committed the message.
  await page.route("**/rest/v1/rpc/participant_messenger_create", async (route) => {
    const response = await route.fetch();
    expect(response.ok()).toBe(true);
    await route.abort("connectionreset");
  }, { times: 1 });
  await send.click();
  // A fast polling refresh can discover the committed message before the local
  // connection-reset notice paints. Either state proves the ambiguous response
  // was reconciled without duplicating the server-side message.
  await expect(dialog.getByText(/Verzenden is niet bevestigd/).or(deliveredMessage).first()).toBeVisible();
  const draftWasKept = await input.inputValue() === body;
  // A refresh may already discover the committed message before the user retries.
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await expect(deliveredMessage).toBeVisible();
  if (draftWasKept) {
    await expect(send).toBeEnabled();
    await send.click();
  }
  await expect(input).toHaveValue("");
  await expect(deliveredMessage).toHaveCount(1);
  const snapshot = await rpc(client, "participant_messenger_context", { _event_slug: "duindorp-halloween-2026", _role: "user" }) as { conversation: { messages: Array<{ body: string }> } };
  expect(snapshot.conversation.messages.filter((message) => message.body === body)).toHaveLength(1);

  await page.reload();
  await page.getByRole("button", { name: "Hulp van de organisatie" }).click();
  await expect(deliveredMessage).toBeVisible();
  const recoveryBody = `Deze reactie blijft staan bij verbindingsverlies (${testInfo.project.name}-${Date.now()}).`;
  await input.fill(recoveryBody);
  await context.setOffline(true);
  await expect(dialog.getByText("Je bent offline", { exact: true })).toBeVisible();
  await expect(send).toBeDisabled();
  await context.setOffline(false);
  await expect(send).toBeEnabled();
  await expect(input).toHaveValue(recoveryBody);
  await send.click();
  await expect(input).toHaveValue("");
  await expect(dialog.getByText(recoveryBody, { exact: true })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("messenger-sent-mobile.png") });
});

test("legacy joint Tikkie links retain parent authorization and settle their full total", async ({}, testInfo) => {
  requireLocalAuth();
  test.skip(testInfo.project.name !== "desktop-chromium", "The legacy payment lifecycle mutates isolated fixtures once.");
  type PaymentSnapshot = { registration: { id: string; payment: { version: number; status: string; externalUrl: string | null; batch: { id: string; version: number; status: string; totalAmountCents: number; externalUrl: string | null; canPay: boolean; payerName: string } } } };
  const admin = (await fixtureClient("admin@example.invalid")).client;
  const parentA = (await fixtureClient("parent-payment-a@example.invalid")).client;
  const parentB = (await fixtureClient("parent-payment-b@example.invalid")).client;
  const tikkieUrl = "https://tikkie.me/pay/browser-shared-link";
  const existing = await rpc(admin, "admin_payments_snapshot", { _event_slug: "duindorp-halloween-2026" }) as Array<{ id: string; version: number; reference: string }>;
  const selected = existing.filter((payment) => payment.reference.startsWith("PAY-BROWSER-PAYMENT-"));
  expect(selected).toHaveLength(2);
  await rpc(admin, "admin_payment_batch_publish", {
    _event_slug: "duindorp-halloween-2026", _payments: selected.map(({ id, version }) => ({ id, version })),
    _external_url: tikkieUrl, _reason: "Gezinnen hebben één gezamenlijke betaling afgesproken.",
    _idempotency_key: "browser-legacy-joint-publish", _payer_payment_request_id: "28000000-0000-0000-0000-000000000081",
  });
  const otherSnapshot = await rpc(parentB, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PaymentSnapshot;
  expect(otherSnapshot.registration.payment.batch.canPay).toBe(false);
  expect(otherSnapshot.registration.payment.batch.externalUrl).toBeNull();
  expect(otherSnapshot.registration.payment.externalUrl).toBeNull();
  expect(otherSnapshot.registration.payment.batch.payerName).toBe("Betaalouder Alfa");
  const forbiddenReport = await parentB.schema("api").rpc("registration_report_payment", { _registration_id: otherSnapshot.registration.id, _expected_version: otherSnapshot.registration.payment.version });
  expect(forbiddenReport.error?.message).toContain("NOT_AUTHORIZED");
  const payerSnapshot = await rpc(parentA, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PaymentSnapshot;
  expect(payerSnapshot.registration.payment.batch.externalUrl).toBe(tikkieUrl);
  await rpc(parentA, "registration_report_payment", { _registration_id: payerSnapshot.registration.id, _expected_version: payerSnapshot.registration.payment.version });
  const reported = await rpc(parentA, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PaymentSnapshot;
  expect(reported.registration.payment.status).toBe("reported");
  expect(reported.registration.payment.batch.totalAmountCents).toBe(750);
  const confirmation = {
    _batch_id: reported.registration.payment.batch.id, _expected_version: reported.registration.payment.batch.version,
    _amount_cents: 750, _external_reference: "BROWSER-JOINT-RECEIVED", _reason: "Het gezamenlijke bedrag is gecontroleerd op de bank.",
    _idempotency_key: "browser-legacy-joint-confirm",
  };
  await rpc(admin, "admin_payment_batch_confirm", confirmation);
  await rpc(admin, "admin_payment_batch_confirm", confirmation);
  const payments = await rpc(admin, "admin_payments_snapshot", { _event_slug: "duindorp-halloween-2026" }) as Array<{ reference: string; status: string; netCollectedCents: number }>;
  expect(payments.filter((payment) => payment.reference.startsWith("PAY-BROWSER-PAYMENT-")).map(({ status, netCollectedCents }) => ({ status, netCollectedCents })).sort((a, b) => a.netCollectedCents - b.netCollectedCents)).toEqual([{ status: "confirmed", netCollectedCents: 250 }, { status: "confirmed", netCollectedCents: 500 }]);
  for (const client of [parentA, parentB]) {
    const snapshot = await rpc(client, "registration_snapshot", { _event_slug: "duindorp-halloween-2026" }) as PaymentSnapshot;
    expect(snapshot.registration.payment.status).toBe("confirmed");
    expect(snapshot.registration.payment.externalUrl).toBeNull();
    expect(snapshot.registration.payment.batch.externalUrl).toBeNull();
  }
});

test("payment links select individual siblings and expose one payment action per linked set", async ({ context, page, browser }, testInfo) => {
  requireLocalAuth();
  test.skip(testInfo.project.name !== "desktop-chromium", "Isolated child payment fixtures run once; the parent flow includes a narrow phone.");
  const eventSlug = "duindorp-halloween-2026";
  const ids = [1, 2, 3].map((number) => `25000083-0000-0000-0000-${String(number).padStart(12, "0")}`);
  const registrationChildIds = ids.map((id) => id.replace("25000083", "26000083"));
  type ChildRow = { childId: string; status: string; version: number; amountCents: number; batch: null | { id: string; version: number; totalAmountCents: number; status: string } };
  const admin = await authenticate(context, "admin@example.invalid");
  const childRows = async () => await rpc(admin, "admin_child_payments_snapshot", { _event_slug: eventSlug }) as ChildRow[];
  const before = (await childRows()).find((row) => row.childId === ids[2])!;
  expect(before.status).toBe("awaiting_link");
  expect(before.amountCents).toBe(250);
  await page.goto("/admin");
  await selectAdminSection(page, "Betalingen");
  await page.getByRole("searchbox", { name: "Zoek kind, ouder, e-mail, groep of referentie" }).fill("Kindbetaalouder Alfa");
  await expect(page.getByRole("heading", { name: "Nog een betaallink sturen" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Betaallink verstuurd" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Betaalde inschrijvingen" })).toBeVisible();
  const paymentRegistration = page.locator(".payment-registration-group").filter({ hasText: "Kindbetaalouder Alfa" });
  await expect(paymentRegistration).toHaveCount(1);
  await paymentRegistration.locator("summary").click();
  for (const index of [0, 1]) await page.getByTestId(`child-payment-${ids[index]}`).getByRole("checkbox").check();
  await expect(page.getByText(/2 kind\(eren\) geselecteerd/)).toContainText("5,00");
  await page.getByRole("combobox", { name: "Betaalknop bij", exact: true }).selectOption(ids[0]);
  const sharedUrl = "https://betaalverzoek.ing.nl/verzoek/browser-two-siblings";
  const singleUrl = "https://tikkie.me/pay/browser-third-sibling";
  const publish = async (url: string) => {
    await page.getByLabel("Betaallink voor het totaalbedrag").fill(url);
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Betaallink publiceren en e-mail versturen" }).click();
    await expect(page.getByRole("status")).toContainText("Gezamenlijke betaallink gepubliceerd");
    await expect(page.getByRole("heading", { name: "Betaallink voor geselecteerde kinderen" })).toHaveCount(0);
  };
  await publish(sharedUrl);
  const afterShared = await childRows();
  expect(afterShared.find((row) => row.childId === ids[2])).toEqual(before);
  const sharedBatch = afterShared.find((row) => row.childId === ids[0])!.batch!;
  expect(sharedBatch.totalAmountCents).toBe(500);
  expect(afterShared.find((row) => row.childId === ids[1])!.batch!.id).toBe(sharedBatch.id);
  await expect(page.getByRole("link", { name: "Betaallink bij Betaalkind Alfa 1", exact: true })).toHaveAttribute("href", sharedUrl);
  await expect(page.getByRole("button", { name: "Nieuwe betaallink sturen", exact: true })).toBeVisible();
  await expect(page.getByTestId(`child-payment-${ids[1]}`).getByRole("button", { name: "Inbegrepen bij Betaalkind Alfa 1", exact: true })).toBeDisabled();
  await page.getByTestId(`child-payment-${ids[2]}`).getByRole("checkbox").check();
  await expect(page.getByText(/1 kind\(eren\) geselecteerd/)).toContainText("2,50");
  await publish(singleUrl);
  await page.screenshot({ path: testInfo.outputPath("child-tikkies-admin-desktop.png"), fullPage: true });

  const parentContext = await browser.newContext({ baseURL: "http://127.0.0.1:3100", viewport: { width: 320, height: 740 } });
  try {
    const parent = await authenticate(parentContext, "parent-child-payment-a@example.invalid");
    const parentPage = await parentContext.newPage();
    await parentPage.goto("/omgeving/meeloper/nachtpas");
    const rows = registrationChildIds.map((id) => parentPage.locator(`[data-child-payment-row="${id}"]`));
    await expect(rows[0].getByRole("link", { name: /Open betaallink voor Betaalkind Alfa 1/ })).toHaveAttribute("href", sharedUrl);
    await expect(rows[1].getByRole("button", { name: "Betaallink inbegrepen", exact: true })).toBeDisabled();
    await expect(rows[1]).toContainText("Inbegrepen bij Betaalkind Alfa 1");
    await expect(rows[1].getByRole("link")).toHaveCount(0);
    await expect(rows[2].getByRole("link", { name: /Open betaallink voor Betaalkind Alfa 3/ })).toHaveAttribute("href", singleUrl);
    await expect(parentPage.locator("a.child-tikkie-action")).toHaveCount(2);
    await parentPage.reload();
    await expect(rows[0].getByRole("link")).toHaveAttribute("href", sharedUrl);
    await expect(rows[2].getByRole("link")).toHaveAttribute("href", singleUrl);
    await assertReadableLayout(parentPage);
    await parentPage.screenshot({ path: testInfo.outputPath("child-tikkies-parent-mobile.png"), fullPage: true });

    const stranger = (await fixtureClient("parent-child-payment-b@example.invalid")).client;
    const unauthorized = await stranger.schema("api").rpc("child_payment_report", { _batch_id: sharedBatch.id, _expected_version: sharedBatch.version });
    expect(unauthorized.error?.message).toContain("NOT_AUTHORIZED");
    const strangerSnapshot = await rpc(stranger, "registration_snapshot", { _event_slug: eventSlug });
    expect(JSON.stringify(strangerSnapshot)).not.toContain(sharedUrl);
    expect(JSON.stringify(strangerSnapshot)).not.toContain(singleUrl);

    await rows[0].getByRole("button", { name: "Betaling voor Betaalkind Alfa 1 melden" }).click();
    await expect(rows[0].getByRole("button", { name: "In controle", exact: true })).toBeDisabled();
    await expect(rows[1].getByRole("button", { name: "In controle", exact: true })).toBeDisabled();
    await expect(rows[2].getByRole("link")).toHaveAttribute("href", singleUrl);

    await page.reload();
    await selectAdminSection(page, "Betalingen");
    await page.getByRole("searchbox", { name: "Zoek kind, ouder, e-mail, groep of referentie" }).fill("Kindbetaalouder Alfa");
    let adminPaymentRegistration = page.locator(".payment-registration-group").filter({ hasText: "Kindbetaalouder Alfa" });
    await adminPaymentRegistration.locator("summary").click();
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByTestId(`child-payment-${ids[0]}`).getByRole("combobox", { name: "Status door admin" }).selectOption("unpaid");
    await expect(page.getByRole("status")).toContainText("staat weer op niet betaald");

    await parentPage.reload();
    await expect(rows[0].getByRole("link")).toHaveAttribute("href", sharedUrl);
    await rows[0].getByRole("button", { name: "Betaling voor Betaalkind Alfa 1 melden" }).click();
    await expect(rows[0].getByRole("button", { name: "In controle", exact: true })).toBeDisabled();

    await page.reload();
    await selectAdminSection(page, "Betalingen");
    await page.getByRole("searchbox", { name: "Zoek kind, ouder, e-mail, groep of referentie" }).fill("Kindbetaalouder Alfa");
    adminPaymentRegistration = page.locator(".payment-registration-group").filter({ hasText: "Kindbetaalouder Alfa" });
    await adminPaymentRegistration.locator("summary").click();
    const answers = ["5,00", "BROWSER-CHILD-RECEIPT", ""];
    const confirm = async (dialog: import("@playwright/test").Dialog) => { await dialog.accept(answers.shift()); };
    page.on("dialog", confirm);
    await page.getByRole("button", { name: /Bevestig ontvangst.*5,00/ }).click();
    await expect(page.getByRole("status")).toContainText("Ontvangst bevestigd voor de gekoppelde kinderen");
    page.off("dialog", confirm);
    expect(answers).toHaveLength(0);
    const afterConfirm = await childRows();
    expect(ids.map((id) => afterConfirm.find((row) => row.childId === id)!.status)).toEqual(["confirmed", "confirmed", "awaiting_payment"]);
    await parentPage.reload();
    await expect(rows[0].getByRole("button", { name: "Betaald", exact: true })).toBeDisabled();
    await expect(rows[1].getByRole("button", { name: "Betaald", exact: true })).toBeDisabled();
    await expect(rows[2].getByRole("link")).toHaveAttribute("href", singleUrl);
    await expect(parentPage.locator("a.child-tikkie-action")).toHaveCount(1);
    const snapshot = await rpc(parent, "registration_snapshot", { _event_slug: eventSlug }) as { registration: { children: Array<{ id: string; payment: { status: string } }> } };
    expect(registrationChildIds.map((id) => snapshot.registration.children.find((child) => child.id === id)!.payment.status)).toEqual(["confirmed", "confirmed", "awaiting_payment"]);
  } finally { await parentContext.close(); }
});


for (const width of [320, 375, 390, 430]) {
  test(`organisation navigation is a keyboard accessible drawer at ${width}px`, async ({ context, page }) => {
    requireLocalAuth();
    await page.setViewportSize({ width, height: 844 });
    await authenticate(context, "admin@example.invalid");
    await page.goto("/admin");
    const opener = page.getByRole("button", { name: "Organisatienavigatie openen" });
    const navigation = page.locator("#admin-navigation");
    await expect(opener).toBeVisible();
    await expect(navigation).toBeHidden();
    expect(await page.locator(".admin-topbar").evaluate((element) => element.getBoundingClientRect().height)).toBeLessThan(90);
    await assertReadableLayout(page);
    await opener.click();
    await expect(navigation).toHaveAttribute("aria-modal", "true");
    await expect(page.getByRole("button", { name: "Menu sluiten", exact: true })).toBeFocused();
    await expect(navigation.getByRole("button", { name: "Cockpit", exact: true })).toHaveAttribute("aria-current", "page");
    await expect(navigation.locator("button b").first()).toBeVisible();
    expect(await page.evaluate(() => document.body.style.overflow)).toBe("hidden");
    await page.keyboard.press("Shift+Tab");
    await expect(navigation.getByRole("button", { name: "Instellingen", exact: true })).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(page.getByRole("button", { name: "Menu sluiten", exact: true })).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(navigation).toBeHidden();
    await expect(opener).toBeFocused();
    expect(await page.evaluate(() => document.body.style.overflow)).not.toBe("hidden");
    await opener.click();
    await navigation.getByRole("button", { name: "Instellingen", exact: true }).click();
    await expect(navigation).toBeHidden();
    await expect(page.locator(".admin-mobile-section")).toContainText("Instellingen");
    await assertReadableLayout(page);
    await opener.click();
    await page.locator(".admin-nav-backdrop").click({ position: { x: width - 8, y: 100 } });
    await expect(navigation).toBeHidden();
    await opener.click();
    await page.setViewportSize({ width: 1440, height: 900 });
    await expect(navigation).toBeVisible();
    await expect(navigation).not.toHaveAttribute("aria-modal", "true");
    expect(await page.evaluate(() => document.body.style.overflow)).not.toBe("hidden");
  });
}
