import { expect, test, type BrowserContext } from "@playwright/test";
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
  await expect(page.getByText("23 kinderen", { exact: true })).toBeVisible();
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
  await page.getByLabel("Naam verantwoordelijke volwassene").fill("Browser testouder");
  await page.getByLabel("Telefoonnummer voor de avond").fill("0612345678");
  await page.getByLabel("Wanneer stoppen jullie met gewone poorten?", { exact: false }).selectOption({ label: "20:15" });
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
  await expect(page.getByText("Wacht op Tikkie", { exact: true })).toBeVisible();
  await expect(page.getByText(snapshot.registration.togetherCode, { exact: true })).toBeVisible();
  await expect(page.locator("body")).not.toContainText("awaiting_link");
  page.once("dialog", (dialog) => dialog.accept("Dit kind kan op de avond helaas niet meelopen."));
  await page.getByRole("button", { name: "Verwijdering aanvragen" }).first().click();
  await expect(page.getByRole("status")).toContainText(/verzoek is opgeslagen/i);
  await page.reload();
  await expect(page.getByText(/Dit kind kan op de avond helaas niet meelopen/i)).toBeVisible();
  await expect(page.getByText("In behandeling", { exact: true })).toBeVisible();
});

test("an event administrator can grant and revoke narrowly scoped access", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  await page.getByRole("button", { name: "Beheerders", exact: true }).click();
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
  await page.getByLabel("Reden voor deze wijziging").fill("Helpt met het beoordelen van aangemelde locaties.");
  await page.getByRole("button", { name: "Beheerder toevoegen" }).click();
  await expect(page.getByRole("status")).toContainText(/rechten.*bijgewerkt/i);

  const member = page.locator(".admin-access-member").filter({ hasText: "parent-a@example.invalid" });
  await expect(member).toContainText("Locaties");
  await member.getByRole("button", { name: "Bewerken" }).click();
  await expect(page.getByLabel("E-mailadres")).toHaveAttribute("readonly", "");
  await page.getByRole("checkbox", { name: /^Locaties/ }).uncheck();
  await page.getByLabel("Reden voor deze wijziging").fill("De tijdelijke locatiebeoordeling is afgerond.");
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Rechten opslaan" }).click();
  await expect(page.getByRole("status")).toContainText(/rechten.*bijgewerkt/i);
  await expect(member).toHaveCount(0);
});

test("an organizer sees portal identity and private contact details and can message the owner directly", async ({ context, page }) => {
  requireLocalAuth();
  await authenticate(context, "admin@example.invalid");
  await page.goto("/admin");
  await page.getByRole("button", { name: "Poortaanvragen", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Poortaanvragen" })).toBeVisible();

  const portalCard = page.locator(".incident-row").filter({ hasText: "P-01" }).first();
  await expect(portalCard).toContainText("Testpoort 01");
  await expect(portalCard).toContainText("Adres: NIET-BESTAAND TESTADRES 1, 0000AA Teststad");
  await expect(portalCard).toContainText("Contact: Test contactpersoon");
  await expect(portalCard.getByRole("link", { name: "0612345678" })).toHaveAttribute("href", "tel:0612345678");
  await expect(portalCard.getByRole("link", { name: "owner@example.invalid" })).toHaveAttribute("href", "mailto:owner@example.invalid");

  page.once("dialog", (dialog) => dialog.accept("Gericht browser-testbericht aan de poort."));
  await portalCard.getByRole("button", { name: "Bericht sturen" }).click();
  await expect(page.getByRole("status")).toContainText(/bericht staat in het gesprek/i);
  await assertReadableLayout(page);
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
  await page.getByRole("button", { name: "Hulp & contact", exact: true }).click();
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
  await page.getByLabel("Straat *").fill("NIET-BESTAANDE TESTSTRAAT");
  await page.getByLabel("Huisnummer *").fill("12");
  await page.getByLabel("Postcode *").fill("2584AB");
  await page.getByRole("button", { name: "Plek aanmelden" }).click();
  await expect(page).toHaveURL(/\/mijn-huis$/);
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByText(`E-mailadres: ${email} (bevestigd)`)).toBeVisible();
  for (const removed of ["Bezoekduur", "Groepen tegelijk", "Kinderen per bezoek", "Kinderen totaal"]) {
    await expect(page.getByLabel(removed, { exact: false })).toHaveCount(0);
  }
  await expect(page.getByLabel("Praktische toegankelijkheid (optioneel)")).toBeVisible();
  await page.reload();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Browser testbewoner");
  await expect(page.getByLabel("Straat *")).toHaveValue("NIET-BESTAANDE TESTSTRAAT");

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
          await expect(page.getByRole("switch", { name: /Open · klik om te sluiten/i })).toHaveCount(2);
          for (const section of ["Imports", "Inschrijvingen", "Hulp & contact", "Deelnemersupdates", "Betalingen", "Poortaanvragen", "Startpunten en indeling", "Content & sponsors", "Beheerders", "Avondcockpit"]) {
            await page.goto("/admin");
            await page.locator(".admin-nav").getByRole("button", { name: section, exact: true }).click();
            await expect(page.locator(".admin-nav").getByRole("button", { name: section, exact: true })).toHaveClass("active");
            await assertReadableLayout(page, doubleText);
          }
        }
      }
    }
  });
}

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
  await page.getByLabel("E-mailadres", { exact: true }).fill(email);
  await page.getByLabel("Naam contactpersoon *").fill("Nieuwe testbewoner");
  await page.getByLabel("Telefoonnummer *").fill("0612345678");
  await page.getByLabel("Straat *").fill("FICTIEVE STRAAT");
  await page.getByLabel("Huisnummer *").fill("15");
  await page.getByLabel("Postcode *").fill("2584AB");
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
  await expect(page.getByLabel("Beschrijving *", { exact: true })).toHaveCount(0);
  await page.locator('input[autocomplete="one-time-code"]').fill("");
  await page.locator('input[autocomplete="one-time-code"]').fill("123456");
  await page.getByRole("button", { name: "Bevestigen en verder" }).click();
  await expect(page).toHaveURL(/\/mijn-huis$/);
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Nieuwe testbewoner");
  await expect(page.getByLabel("Straat *")).toHaveValue("FICTIEVE STRAAT");
  await page.getByLabel("Naam contactpersoon *").fill("Nieuwe testbewoner gewijzigd");
  await page.getByRole("button", { name: "Concept opslaan" }).click();
  await expect(page.getByRole("status")).toContainText(/bewaard/i);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Werk jullie poort uit" })).toBeVisible();
  await expect(page.getByLabel("Naam contactpersoon *")).toHaveValue("Nieuwe testbewoner gewijzigd");
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
