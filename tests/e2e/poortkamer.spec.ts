import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { prepareFixtureGuidance, selectOrganizationSection } from "./helpers/guidance";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import {
  sql,
  requireLocalTogetherDatabase,
} from "../../scripts/acceptance/together-fixtures.mjs";
import { createPortalRoomFixture } from "../../scripts/acceptance/poortkamer-fixtures.mjs";
const origin = "https://127.0.0.1:3443";
const eventSlug = "duindorp-halloween-2026";
const uuid = /^[a-f0-9-]{36}$/i;
function localAdmin() {
  requireLocalTogetherDatabase();
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SECRET_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}
async function owner(context: BrowserContext) {
  const admin = localAdmin(),
    email = `room-owner-${randomUUID()}@example.invalid`;
  const created = await admin.auth.admin.createUser({
    email,
    password: "local-room-only",
    email_confirm: true,
  });
  expect(created.error).toBeNull();
  const portal = createPortalRoomFixture(created.data.user!.id);
  const client = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const signed = await client.auth.signInWithPassword({
    email,
    password: "local-room-only",
  });
  expect(signed.error).toBeNull();
  await prepareFixtureGuidance(client);
  await expect
    .poll(
      async () =>
        (
          await client.schema("api").rpc("portal_room_snapshot", {
            _event_slug: eventSlug,
            _portal_id: portal.id,
          })
        ).error?.code ?? null,
    )
    .toBeNull();
  const name = `sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
  const chunks =
    value.length <= 3180
      ? [{ name, value }]
      : Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
          name: `${name}.${i}`,
          value: value.slice(i * 3180, (i + 1) * 3180),
        }));
  await context.addCookies(
    chunks.map((chunk) => ({
      ...chunk,
      url: origin,
      sameSite: "Lax" as const,
      secure: true,
    })),
  );
  return { ...portal, client, admin };
}
async function noOverflow(page: Page) {
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth + 1,
    ),
  ).toBe(true);
}
async function viewportShellScrolls(page: Page, mouseWheelSupported = true) {
  const shell = page.locator("[data-poortkamer-shell]");
  const content = page.locator("#poortkamer-content");
  await expect(shell).toBeVisible();
  await expect(content).toBeVisible();
  const before = await page.evaluate(() => {
    const shellElement = document.querySelector<HTMLElement>(
      "[data-poortkamer-shell]",
    )!;
    const contentElement = document.querySelector<HTMLElement>(
      "#poortkamer-content",
    )!;
    const header = contentElement.previousElementSibling as HTMLElement;
    const shellRect = shellElement.getBoundingClientRect();
    return {
      documentScroll: document.scrollingElement?.scrollTop ?? -1,
      headerTop: header.getBoundingClientRect().top,
      shellTop: shellRect.top,
      shellBottom: shellRect.bottom,
      scrollHeight: contentElement.scrollHeight,
      clientHeight: contentElement.clientHeight,
      overflowY: getComputedStyle(contentElement).overflowY,
    };
  });
  expect(before.scrollHeight).toBeGreaterThan(before.clientHeight);
  expect(before.overflowY).toBe("auto");
  expect(before.shellTop).toBeGreaterThanOrEqual(-1);
  expect(before.shellBottom).toBeLessThanOrEqual(
    await page.evaluate(() => innerHeight + 1),
  );
  if (mouseWheelSupported) {
    await content.hover();
    await page.mouse.wheel(0, 800);
  } else {
    await content.evaluate((element) => element.scrollBy(0, 800));
  }
  await expect
    .poll(() => content.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(0);
  const after = await page.evaluate(() => {
    const contentElement = document.querySelector<HTMLElement>(
      "#poortkamer-content",
    )!;
    const header = contentElement.previousElementSibling as HTMLElement;
    return {
      documentScroll: document.scrollingElement?.scrollTop ?? -1,
      headerTop: header.getBoundingClientRect().top,
    };
  });
  expect(after.documentScroll).toBe(before.documentScroll);
  expect(Math.abs(after.headerTop - before.headerTop)).toBeLessThan(1);
  await content.evaluate((element) => {
    element.scrollTop = 0;
  });
}
async function screenshot(page: Page, name: string, project: string) {
  if (
    !["room-desktop", "room-samsung-chrome", "room-iphone-webkit"].includes(
      project,
    )
  )
    return;
  mkdirSync("docs/screenshots/poortkamer", { recursive: true });
  await page.screenshot({
    path: `docs/screenshots/poortkamer/${project}-${name}.png`,
  });
}

function eveningDomainState() {
  requireLocalTogetherDatabase();
  const tables = ["portals", "run_stops", "portal_reservations", "poortenboek_passport_seals", "portal_room_messages", "messenger_conversations", "messenger_messages", "portal_incidents", "portal_incident_history", "email_outbox", "portal_push_outbox", "portal_simulation_runs", "portal_simulation_events"];
  return Object.fromEntries(tables.map(table => [table, sql(`select md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,'')) from app_private.${table} t`)]));
}

test("fictional rehearsal completes guided and free scenarios without live commands or domain changes", async ({ page, context }, info) => {
  await owner(context);
  await page.addLocatorHandler(page.getByRole("button", { name: "Installatievenster sluiten" }), async close => close.click());
  await page.goto("/mijn-huis");
  await page.getByRole("button", { name: "Meer", exact: true }).click();
  await page.getByRole("button", { name: "Voorbereiden", exact: true }).click();
  await page.getByRole("button", { name: "Oefenen", exact: true }).click();
  const practice = page.locator(".pes");
  await expect(practice.getByText("Oefenstand — fictieve groepen", { exact: true })).toBeVisible();
  const before = eveningDomainState();
  const commands: string[] = [];
  page.on("request", request => {
    if (request.method() === "POST" && /\/rpc\/(portal_room_command|.*simulation.*|.*incident.*|.*passport.*|.*scan.*|.*chat.*|.*message_send.*|.*operation.*)/.test(request.url())) commands.push(request.url());
  });
  await practice.getByRole("button", { name: "Start de oefenavond", exact: true }).click();
  const coach = practice.locator(".pes-coach");
  const metrics = practice.locator(".pes-metrics strong");
  await coach.getByRole("button", { name: "Open de oefenpoort", exact: true }).click();
  await expect(practice.getByRole("img", { name: /Fictieve oefenstraat met jullie open poort/ })).toBeVisible();
  await coach.getByRole("button", { name: "Stuur een oefengroep", exact: true }).click();
  await practice.getByRole("button", { name: "4×", exact: true }).click();
  await expect(practice.locator(".pes-map-group.arrived")).toHaveCount(1);
  await practice.locator(".pes-scene-top").scrollIntoViewIfNeeded();
  await screenshot(page, "oefenstraat", info.project.name);
  await expect(metrics).toHaveText(["0", "0", "0"]);
  await practice.locator(".pes-current-visit").getByRole("button", { name: "Bevestig oefenaankomst", exact: true }).dblclick();
  await expect(metrics).toHaveText(["1", "12", "0"]);
  await practice.locator(".pes-current-visit").getByRole("button", { name: "Bezoek afronden & oefenzegel", exact: true }).dblclick();
  await expect(metrics).toHaveText(["1", "12", "12"]);
  await expect(practice.locator(".pes-map-group.done")).toHaveCount(1);
  await coach.getByRole("button", { name: "Maak het wat drukker", exact: true }).click();
  await expect(practice.locator(".pes-map-group.waiting")).toHaveCount(1);
  await coach.getByRole("button", { name: "Pauzeer de oefenpoort", exact: true }).click();
  await expect(practice.getByRole("button", { name: "Een groep op pad", exact: true })).toBeDisabled();
  await expect(practice.locator(".pes-map-group.arrived")).toHaveCount(1);
  await practice.locator(".pes-current-visit").getByRole("button", { name: "Bevestig oefenaankomst", exact: true }).click();
  await practice.locator(".pes-current-visit").getByRole("button", { name: "Bezoek afronden & oefenzegel", exact: true }).click();
  await expect(metrics).toHaveText(["2", "22", "22"]);
  await expect(practice.locator(".pes-map-group.waiting")).toHaveCount(1);
  await expect(practice.locator(".pes-map-group.approaching")).toHaveCount(0);
  await practice.getByRole("button", { name: "Bericht oefenen", exact: true }).click();
  await practice.getByLabel("Oefenbericht aan de fictieve regie").fill("Dit is uitsluitend een fictieve hulpvraag");
  await practice.getByRole("button", { name: "Oefenbericht versturen", exact: true }).click();
  await expect(practice.locator(".pes-regie-note")).toContainText("lokaal gemaakt");
  await practice.getByRole("button", { name: "Hulpvraag oefenen", exact: true }).click();
  await expect(practice.locator(".pes-regie-note")).toContainText("lokale demo");
  await coach.getByRole("button", { name: "Hervat de oefenpoort", exact: true }).click();
  await expect(practice.locator(".pes-map-group.waiting")).toHaveCount(0);
  await expect(practice.locator(".pes-map-group.arrived")).toHaveCount(1);
  await coach.getByRole("button", { name: "Ontvang de laatste oefengroep", exact: true }).click();
  await coach.getByRole("button", { name: "Rond huidig oefenbezoek af", exact: true }).click();
  await practice.getByRole("button", { name: "Bekijk de oefenfinale", exact: true }).click();
  await expect(practice.locator(".pes-village.is-finale")).toBeVisible();
  await coach.getByRole("button", { name: "Sluit de oefenpoort", exact: true }).click();
  await expect(practice.locator(".pes-steps .is-done")).toHaveCount(9);
  await expect(metrics).toHaveText(["3", "30", "30"]);
  await expect(coach).toContainText("Jullie openden de poort");
  await noOverflow(page);
  await screenshot(page, "oefenavond", info.project.name);
  // An unmount/remount, a real snapshot refresh and temporary offline mode keep
  // local progress; a hard reload deliberately starts a new fictional exercise.
  await page.getByRole("button", { name: "Checklist", exact: true }).click();
  await page.getByRole("button", { name: "Oefenen", exact: true }).click();
  await expect(metrics).toHaveText(["3", "30", "30"]);
  const refreshed = page.waitForResponse(response => response.url().includes("/rpc/portal_room_snapshot") && response.ok());
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await refreshed;
  await expect(metrics).toHaveText(["3", "30", "30"]);
  await practice.getByRole("button", { name: "Vrij oefenen", exact: true }).click();
  await context.setOffline(true);
  await practice.locator(".pes-gate-buttons").getByRole("button", { name: "Open", exact: true }).click();
  await practice.getByRole("button", { name: "Even lekker druk", exact: true }).click();
  await expect(practice.locator(".pes-map-group.waiting")).toHaveCount(1);
  await practice.getByRole("button", { name: "Opnieuw", exact: true }).click();
  const reset = page.getByRole("dialog", { name: "Nog een rondje oefenen?" });
  await expect(reset.getByRole("button", { name: "Verder oefenen", exact: true })).toBeFocused();
  await reset.getByRole("button", { name: "Opnieuw beginnen", exact: true }).focus();
  await page.keyboard.press("Tab");
  await expect(reset.getByRole("button", { name: "Resetvenster sluiten", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(reset).toHaveCount(0);
  await expect(metrics).toHaveText(["3", "30", "30"]);
  await practice.getByRole("button", { name: "Opnieuw", exact: true }).click();
  await reset.getByRole("button", { name: "Opnieuw beginnen", exact: true }).click();
  await expect(practice.getByRole("button", { name: "Start de oefenavond", exact: true })).toBeFocused();
  await expect(metrics).toHaveText(["0", "0", "0"]);
  await context.setOffline(false);
  await practice.getByRole("button", { name: "Start de oefenavond", exact: true }).click();
  await page.reload();
  await page.getByRole("button", { name: "Meer", exact: true }).click();
  await page.getByRole("button", { name: "Voorbereiden", exact: true }).click();
  await page.getByRole("button", { name: "Oefenen", exact: true }).click();
  await expect(practice.getByRole("button", { name: "Start de oefenavond", exact: true })).toBeVisible();
  await page.emulateMedia({ reducedMotion: "reduce" });
  expect(await practice.evaluate(element => Array.from(element.querySelectorAll("*"), el => getComputedStyle(el).animationDuration).every(duration => duration === "0s" || duration === "1e-05s" || duration === "0.00001s"))).toBe(true);
  expect(commands).toEqual([]);
  expect(eveningDomainState()).toEqual(before);
});

test("owner invitation, real Auth OTP, viewer chat, promotion, realtime and revocation", async ({
  page,
  context,
  browser,
}, info) => {
  const fixture = await owner(context);
  await page.goto("/mijn-huis");
  await expect(
    page.getByRole("heading", { name: /^(Samen klaar voor de nacht\.|Welkom op de Nachtwacht\.|De nacht leeft voort\.)$/ }),
  ).toBeVisible();
  await noOverflow(page);
  await expect(page.getByText(/^Live · Bijgewerkt/)).toBeVisible({
    timeout: 15_000,
  });
  await screenshot(page, "nachtwacht", info.project.name);
  await page.getByText("Bezoeklog en verwachte instroom", { exact: true }).click();
  await expect(page.getByRole("heading", { name: "De stroom door jullie poort" })).toBeVisible();
  await page.getByRole("button", { name: "Team", exact: true }).click();
  await page.getByRole("button", { name: "Deel een sleutel" }).click();
  const dialog = page.getByRole("dialog");
  const email = `room-guest-${randomUUID()}@example.invalid`;
  await dialog.getByLabel("Voornaam", { exact: true }).fill("Sem");
  await dialog.getByLabel("Achternaam", { exact: true }).fill("Privénaam");
  await dialog.getByLabel("E-mailadres").fill(email);
  await expect(dialog.getByLabel("Rol", { exact: true })).toHaveValue("viewer");
  await dialog.getByRole("button", { name: "Sleutel versturen" }).click();
  await expect(dialog).not.toBeVisible();
  await expect(
    page.getByText("Wacht op bevestiging", { exact: false }),
  ).toBeVisible();
  const inviteId = sql(
    `select id from app_private.portal_team_invites where email='${email}'`,
  );
  expect(inviteId).toMatch(uuid);
  const material = await fixture.admin
    .schema("api")
    .rpc("portal_invitation_mail_payload", { _invite_id: inviteId });
  expect(material.error).toBeNull();
  const guestContext = await browser.newContext({
    ...info.project.use,
    baseURL: origin,
    ignoreHTTPSErrors: true,
  });
  const guest = await guestContext.newPage();
  await guest.goto(material.data.actionPath);
  await guest.getByLabel("E-mailadres").fill(email);
  await guest.getByRole("button", { name: "Stuur eenmalige code" }).click();
  await expect(
    guest.getByRole("heading", { name: "Vul de zes cijfers in." }),
  ).toBeVisible();
  // Supabase issues a real local test OTP. Delivery is separately covered by local-auth and the durable mailworker contracts.
  const issued = await fixture.admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  expect(issued.error).toBeNull();
  await guest
    .locator('input[autocomplete="one-time-code"]')
    .fill(issued.data.properties!.email_otp);
  await guest
    .getByRole("button", { name: /Bevestig|Open mijn|Inloggen/ })
    .click();
  await expect(guest).toHaveURL(/\/mijn-huis$/);
  // The newly invited adult follows the real house-team introduction once.
  const community=guest.locator('.guidance-community-dialog');
  await expect(community).toBeVisible();
  await community.getByRole('button',{name:'Gelezen, verder naar mijn omgeving',exact:true}).click();
  const guide=guest.locator('.guidance-tour-dialog');
  await expect(guide).toBeVisible();
  for(let step=0;step<13;step++){
    await expect(guide.getByRole('progressbar')).toHaveAttribute('aria-valuenow',String(step+1));
    await expect(guest).toHaveURL(/\/mijn-huis$/);
    if(step!==3)await expect(guide.locator('.guidance-screen-indicator .is-ready')).toHaveCount(1);
    await guide.getByRole('button',{name:'Verder',exact:true}).click();
  }
  await guide.getByRole('button',{name:'Rondleiding afronden',exact:true}).click();
  await expect(guide).toHaveCount(0);
  // Finishing the guide returns here through the app router. A second hard
  // navigation races that transition in WebKit and interrupts its own load.
  await expect(guest).toHaveURL(/\/mijn-huis$/);
  await expect(
    guest.getByText("Meekijker", { exact: false }).first(),
  ).toBeVisible();
  await expect(
    guest.getByRole("button", { name: "Open", exact: true }),
  ).toHaveCount(0);
  await guest.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ }).click();
  const privateChannels = guest
    .getByRole("navigation", { name: "Kamers van dit huis" })
    .getByRole("button");
  await expect(privateChannels).toHaveCount(4);
  await expect(privateChannels.nth(0)).toHaveText(/^#Achter de Poort/);
  await expect(privateChannels.nth(1)).toHaveText(/^#Voorbereiding/);
  await expect(privateChannels.nth(2)).toHaveText(/^#Decor en techniek/);
  await expect(privateChannels.nth(3)).toHaveText(/^#Tijdens de avond/);
  await guest
    .getByLabel("Je bericht", { exact: true })
    .fill("We staan klaar bij de poort.");
  await guest.getByRole("button", { name: "Versturen", exact: true }).click();
  await expect(
    guest
      .getByLabel("Berichtgeschiedenis")
      .getByText("We staan klaar bij de poort.", { exact: true }),
  ).toBeVisible();
  await page.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ }).click();
  await expect(
    page
      .getByLabel("Berichtgeschiedenis")
      .getByText("We staan klaar bij de poort.", { exact: true }),
  ).toBeVisible({ timeout: 25_000 });
  await screenshot(page, "berichten", info.project.name);
  // Both nested consumers must keep the same private subscription alive.
  const liveMessage = `Live in de teamkamer ${randomUUID()}`;
  await guest.getByLabel("Je bericht", { exact: true }).fill(liveMessage);
  await guest.getByRole("button", { name: "Versturen", exact: true }).click();
  await expect(page.getByRole("log").getByText(liveMessage, { exact: true })).toBeVisible({ timeout: 5_000 });
  await page.getByRole("button", { name: "Team", exact: true }).click();
  await page.getByRole("checkbox", { name: "Moderatorrechten voor Sem Privénaam" }).click();
  await expect(page.getByRole("checkbox", { name: "Moderatorrechten voor Sem Privénaam" })).toBeChecked();
  const moderated = guest.locator(".chat-bubble").filter({ hasText: liveMessage });
  await moderated.getByLabel("Berichtopties").click();
  await expect(moderated.getByRole("button", { name: "Verbergen", exact: true })).toBeVisible({ timeout: 5_000 });
  await moderated.getByRole("button", { name: "Verbergen", exact: true }).click();
  await guest.getByRole("dialog").getByRole("button", { name: "Verbergen", exact: true }).click();
  await expect(guest.getByRole("log").getByText(liveMessage, { exact: true })).toHaveCount(0);
  await page.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ }).click();
  await expect(page.getByRole("log").getByText(liveMessage, { exact: true })).toHaveCount(0);

  await guest
    .getByRole("button", { name: /^Praatkamer/ })
    .click();
  const communityChannels = guest
    .getByRole("navigation", { name: "Praatkamer kanalen" })
    .getByRole("button");
  await expect(communityChannels).toHaveCount(2);
  await expect(communityChannels.first()).toHaveText(/^#Algemeen/);
  await expect(communityChannels.nth(1)).toHaveText(/^#Hulp gevraagd/);
  await expect(communityChannels.first()).toHaveAttribute("aria-pressed", "true");
  await guest
    .getByLabel("Je bericht", { exact: true })
    .fill(`Groet vanaf onze poort ${randomUUID()}`);
  await guest.getByRole("button", { name: "Versturen", exact: true }).click();
  await page
    .getByRole("button", { name: /^Praatkamer/ })
    .click();
  const mention = page.getByLabel("Vermeld een teamlid");
  await expect(
    mention.locator(`option[value="${issued.data.user!.id}"]`),
  ).toHaveText(/Sem · P-/);
  await expect(page.getByLabel("Berichtgeschiedenis")).not.toContainText(
    "Privénaam",
  );
  await mention.selectOption(issued.data.user!.id);
  await page
    .getByLabel("Je bericht", { exact: true })
    .fill("Dank je wel voor je bericht op het plein.");
  await page.getByRole("button", { name: "Versturen", exact: true }).click();
  await expect
    .poll(() =>
      sql(
        `select count(*) from app_private.portal_push_outbox where user_id='${issued.data.user!.id}' and kind='mention'`,
      ),
    )
    .toBe("1");

  await page.getByRole("button", { name: "Team", exact: true }).click();
  await page.getByRole("button", { name: "Tijdelijk deactiveren", exact: true }).click();
  await expect(
    guest.getByRole("heading", { name: "Open je Poortkamer opnieuw" }),
  ).toBeVisible({ timeout: 25_000 });
  await page.getByRole("button", { name: "Toegang activeren", exact: true }).click();
  await guest.reload();
  await expect(guest.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ })).toBeVisible({ timeout: 25_000 });
  page.once("dialog", (d) => d.accept());
  await page.getByLabel("Rol voor Sem Privénaam").selectOption("portal_manager");
  await guest.getByRole("button", { name: "Nachtwacht", exact: true }).click();
  await expect(
    guest.getByRole("button", { name: "Open", exact: true }),
  ).toBeVisible({ timeout: 25_000 });
  await guest.getByRole("button", { name: "Open", exact: true }).click();
  await expect(page.getByRole("button", { name: "Open", exact: true })).toHaveAttribute("aria-pressed", "true", { timeout: 25_000 });
  await screenshot(page, "team", info.project.name);
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Toegang intrekken" }).click();
  await expect(
    guest.getByRole("heading", { name: "Open je Poortkamer opnieuw" }),
  ).toBeVisible({ timeout: 25_000 });
  await guest.reload();
  await expect(
    guest
      .getByLabel("Berichtgeschiedenis")
      .getByText("We staan klaar bij de poort.", { exact: true }),
  ).toHaveCount(0);
  await guestContext.close();
});
test("status dialogs, shared checklist, privacy, offline and all viewport controls", async ({
  page,
  context,
  browserName,
}, info) => {
  const fixture = await owner(context);
  await page.addLocatorHandler(page.getByRole("button", { name: "Installatievenster sluiten" }), async close => close.click());
  await page.goto("/mijn-huis");
  await viewportShellScrolls(page, browserName !== "webkit");
  await page.getByRole("button", { name: "Pauze", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Hervatten").selectOption("5");
  await dialog.getByRole("button", { name: "Annuleren" }).click();
  expect(
    sql(
      `select operation_status from app_private.portals where id='${fixture.id}'`,
    ),
  ).toBe("scheduled");
  await page.getByRole("button", { name: "Pauze", exact: true }).click();
  await dialog.getByLabel("Hervatten").selectOption("5");
  await dialog.getByRole("button", { name: "Bevestigen" }).click();
  await expect(dialog).not.toBeVisible();
  expect(
    sql(
      `select pause_until is not null from app_private.portals where id='${fixture.id}'`,
    ),
  ).toBe("t");
  await page.getByRole("button", { name: "Meer", exact: true }).click();
  await page.getByRole("button", { name: "Presentatie", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Het verhaal dat kinderen meenemen" })).toBeVisible();
  await page.getByRole("button", { name: "Hulp & contact", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Meld wat de ontvangst belemmert" })).toBeVisible();
  await page.getByRole("button", { name: "Voorbereiden", exact: true }).click();
  await page.getByRole("button", { name: "Oefenen", exact: true }).click();
  await expect(page.getByText("Oefenstand — fictieve groepen", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Checklist", exact: true }).click();
  await expect(page.getByText(/snoepvoorraad/i)).toHaveCount(0);
  const installDismiss = page.getByRole("button", {
    name: "Ik heb de app al geïnstalleerd",
    exact: true,
  });
  if (await installDismiss.isVisible()) await installDismiss.click();
  await page.getByLabel("Telefoon is opgeladen", { exact: false }).click();
  await expect
    .poll(() =>
      sql(
        `select done from app_private.portal_readiness where portal_id='${fixture.id}' and item='phone'`,
      ),
    )
    .toBe("t");
  await noOverflow(page);
  await screenshot(page, "voorbereiding", info.project.name);
  await page.getByRole("button", { name: "Bezoeken", exact: true }).click();
  await noOverflow(page);
  await expect(
    page.getByText("Er is nog geen groep toegewezen. Je hoeft niets te doen."),
  ).toBeVisible();
  await screenshot(page, "bezoeken", info.project.name);
  await page.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ }).click();
  await page
    .getByRole("button", { name: /^Praatkamer/ })
    .click();
  const escapedMessage = `<script>geen uitvoering ${randomUUID()}</script>`;
  await page.getByLabel("Je bericht", { exact: true }).fill(escapedMessage);
  await page.getByRole("button", { name: "Versturen", exact: true }).click();
  await expect(
    page
      .getByLabel("Berichtgeschiedenis")
      .getByText(escapedMessage, { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Nachtwacht", exact: true }).click();
  await context.setOffline(true);
  await expect(
    page.getByText(/Je ziet tijdelijk de laatste stand/),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Open", exact: true }),
  ).toBeDisabled();
  await context.setOffline(false);
  await expect(
    page.getByRole("button", { name: "Open", exact: true }),
  ).toBeEnabled();
  expect(
    await page.evaluate(() =>
      JSON.stringify({ ...localStorage, ...sessionStorage }),
    ),
  ).not.toMatch(/Lantaarnpoort|Telefoon is opgeladen|geen uitvoering/);
  const response = await page.request.get("/mijn-huis");
  expect(response.headers()["cache-control"]).toContain("no-store");
  await page.getByRole("button", { name: "Meer", exact: true }).click();
  await page.evaluate(() =>
    Object.defineProperty(navigator, "canShare", {
      configurable: true,
      value: undefined,
    }),
  );
  await page.getByRole("button", { name: "Terugblik", exact: true }).click();
  await expect(
    page.getByRole("link", { name: "Deel ons Nachtverslag", exact: true }),
  ).toHaveAttribute("href", "/deel-de-magie?from=poortkamer-terugblik");
  const installed = page.getByRole("button", {
    name: "Ik heb de app al geïnstalleerd",
    exact: true,
  });
  if (await installed.isVisible()) await installed.click();
  await page.getByRole("button", { name: "Instellingen", exact: true }).click();
  await page.getByRole("button", { name: /Uitloggen/ }).click();
  await page.goBack();
  await expect(page.getByText("De Lantaarnpoort", { exact: true })).toHaveCount(
    0,
  );
});

test.describe('late snapshot after disconnect',()=>{
 // A controlling service worker can bypass Playwright routing, especially
 // after the wake-up jitter. This test must hold the actual RPC response.
 test.use({serviceWorkers:'block'});
test("a successful snapshot arriving after disconnect cannot re-enable reception controls", async ({page,context})=>{
  await owner(context);await page.goto('/mijn-huis');
  await expect(page.getByRole('button',{name:'Open',exact:true})).toBeEnabled();
  let ready!:()=>void,release!:()=>void;
  const received=new Promise<void>(resolve=>{ready=resolve;}),held=new Promise<void>(resolve=>{release=resolve;});
  let intercepted=false;
  const pattern='**/rest/v1/rpc/portal_room_snapshot';
  await page.route(pattern,async route=>{
    if(route.request().method()!=="POST" || intercepted){await route.continue();return;}intercepted=true;
    const actual=await route.fetch();ready();await held;await route.fulfill({response:actual});
  });
  await page.evaluate(()=>window.dispatchEvent(new Event('online')));await received;
  const response=page.waitForResponse(r=>r.request().method()==="POST" && r.url().includes('/rest/v1/rpc/portal_room_snapshot'));
  await context.setOffline(true);release();await (await response).finished();
  await page.evaluate(()=>new Promise<void>(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve()))));
  await expect(page.getByText(/Je ziet tijdelijk de laatste stand/)).toBeVisible();
  await expect(page.getByRole('button',{name:'Open',exact:true})).toBeDisabled();
  await page.unroute(pattern);await context.setOffline(false);
  await expect(page.getByRole('button',{name:'Open',exact:true})).toBeEnabled();
});
});

test.describe('temporary guide availability',()=>{
 test.use({serviceWorkers:'block'});
test("a temporary guide failure keeps house controls visible and arrival verification closed",async({page,context})=>{
  await owner(context);
  const pattern='**/api/redesign/guidance';
  await page.route(pattern,route=>route.request().method()==='GET'?route.fulfill({status:503,json:{error:{code:'AUTH_UNAVAILABLE'}}}):route.continue());
  await page.goto('/mijn-huis');
  await expect(page.getByRole('complementary',{name:'Uitleg tijdelijk niet beschikbaar'})).toBeVisible();
  await expect(page.getByRole('button',{name:'Open',exact:true})).toBeEnabled();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect.poll(()=>page.evaluate(()=>document.documentElement.dataset.participantGuidanceActive)).toBe('true');
  await page.unroute(pattern);await page.evaluate(()=>window.dispatchEvent(new Event('online')));
  await expect(page.getByRole('complementary',{name:'Uitleg tijdelijk niet beschikbaar'})).toHaveCount(0);
  await expect.poll(()=>page.evaluate(()=>document.documentElement.dataset.participantGuidanceActive)).toBe('false');
  await expect(page.getByRole('button',{name:'Open',exact:true})).toBeEnabled();
});
});

test("standalone presentation and offline reload never recover cached private data", async ({
  page,
  context,
}) => {
  await owner(context);
  await page.addInitScript(() => {
    const media = window.matchMedia.bind(window);
    window.matchMedia = (query) =>
      query === "(display-mode: standalone)"
        ? Object.defineProperty(media(query), "matches", { value: true })
        : media(query);
  });
  await page.goto("/mijn-huis");
  await expect(
    page.getByRole("heading", { name: /^(Samen klaar voor de nacht\.|Welkom op de Nachtwacht\.|De nacht leeft voort\.)$/ }),
  ).toBeVisible();
  await noOverflow(page);
  const cached = await page.evaluate(async () => {
    const keys = await caches.keys();
    const urls: string[] = [];
    for (const key of keys)
      for (const request of await (await caches.open(key)).keys())
        urls.push(new URL(request.url).pathname);
    return urls;
  });
  expect(
    cached.some((path) => /^\/(mijn-|uitnodiging|api\/|omgeving)/.test(path)),
  ).toBe(false);
  await context.setOffline(true);
  await page.reload().catch(() => {});
  await expect(page.getByText("De Lantaarnpoort", { exact: true })).toHaveCount(
    0,
  );
  await context.setOffline(false);
});

test("organization updates reach the cockpit live and only organization moderates Praatkamer", async ({ page, context, browser }, info) => {
  await owner(context);
  await page.goto("/mijn-huis");
  await expect(page.getByText(/^Live · Bijgewerkt/)).toBeVisible({ timeout: 15_000 });
  const client = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(signed.error).toBeNull();
  await prepareFixtureGuidance(client);
  const adminContext = await browser.newContext({ ...info.project.use, baseURL: origin, ignoreHTTPSErrors: true });
  const name = `sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
  const chunks = value.length <= 3180 ? [{ name, value }] : Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180) }));
  await adminContext.addCookies(chunks.map(chunk => ({ ...chunk, url: origin, secure: true, sameSite: "Lax" as const })));
  const organization = await adminContext.newPage();
  await organization.goto("/admin");
  await expect(organization.locator(".admin-appbar")).toBeVisible();
  await selectOrganizationSection(organization,'Poorten');
  await organization.getByRole("tab", { name: /Poortkamers en moderatie/ }).click();
  await organization.getByRole("button", { name: "Korte updates", exact: true }).click();
  const update = `Vanavond nemen we een lampje mee ${randomUUID()}`;
  await organization.getByLabel("Je bericht", { exact: true }).fill(update);
  await organization.getByRole("button", { name: "Versturen", exact: true }).click();
  await expect(page.getByText(update, { exact: true })).toBeVisible({ timeout: 5_000 });
  await screenshot(page, "organisatie-update", info.project.name);

  await page.getByRole("navigation", { name: "Poortkamer navigatie" }).getByRole("button", { name: /^Berichten/ }).click();
  await page.getByRole("button", { name: /^Praatkamer/ }).click();
  const message = `Een voorbeeld voor moderatie ${randomUUID()}`;
  await page.getByLabel("Je bericht", { exact: true }).fill(message);
  await page.getByRole("button", { name: "Versturen", exact: true }).click();
  const own = page.locator(".chat-bubble").filter({ hasText: message });
  await expect(own).toBeVisible();
  await expect(own.getByRole("button", { name: "Verbergen", exact: true })).toHaveCount(0);
  const bottomNavigation = organization.getByRole("navigation", { name: "Snelle organisatienavigatie" });
  if (await bottomNavigation.isVisible()) {
    await expect(bottomNavigation.getByRole("button", { name: "Groepen", exact: true })).toHaveCount(0);
    await bottomNavigation.getByRole("button", { name: "Praatkamer", exact: true }).click();
    await expect(bottomNavigation.getByRole("button", { name: "Praatkamer", exact: true })).toHaveAttribute("aria-current", "page");
  } else {
    await selectOrganizationSection(organization,'Praatkamer');
  }
  await expect(organization.getByRole("heading", { name: "Praatkamer", level: 2 })).toBeVisible();
  const received = organization.locator(".chat-bubble").filter({ hasText: message });
  await expect(received).toBeVisible();
  await received.getByLabel("Berichtopties").click();
  await received.getByRole("button", { name: "Verbergen", exact: true }).click();
  await organization.getByRole("dialog").getByRole("button", { name: "Verbergen", exact: true }).click();
  await expect(page.getByRole("log").getByText(message, { exact: true })).toHaveCount(0, { timeout: 5_000 });
  await noOverflow(organization);
  await adminContext.close();
});
