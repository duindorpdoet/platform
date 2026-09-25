import { expect, test } from "@playwright/test";
import { assertReadableLayout } from "./helpers/layout";

test("premium homepage keeps the supplied identity and closed participation path", async ({ page }, testInfo) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/Duindorpse Poorten/);
  await expect(page.getByRole("img", { name: "De Duindorpse Poorten van Halloween" }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: /Een gewone wijk/ })).toBeVisible();
  await expect(page.getByText("31 OKTOBER 2026").first()).toBeVisible();
  const portalCta = page.getByRole("button", { name: /Meld jouw plek aan/i }).first();
  await expect(portalCta).toBeVisible();
  await portalCta.click();
  await expect(page).toHaveURL(/\/huis-aanmelden$/);
  await page.goBack();
  await expect(page.locator("body")).not.toContainText(/democode|demo-account|rollen kiezen/i);
  const reveals = page.locator(".reveal");
  for (let index = 0; index < await reveals.count(); index += 1) {
    await reveals.nth(index).scrollIntoViewIfNeeded();
    await expect(reveals.nth(index)).toHaveClass(/visible/);
  }
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await expect(page.getByRole("heading", { name: /Een gewone wijk/ })).toBeInViewport();
  await page.screenshot({ path: testInfo.outputPath("homepage.png"), animations: "allow" });
});

test("public map shows a living fictional route without exposing real participants", async ({ page }) => {
  await page.goto("/kaart");
  await expect(page.getByRole("heading", { name: /zie de nacht tot leven komen/i })).toBeVisible();
  await expect(page.getByText(/fictieve live-demonstratie met verzonnen poorten/i)).toBeVisible();
  const style = await page.request.get("/maps/duindorp-night.json");
  expect(style.ok()).toBeTruthy();
  for (const file of ["maplibre-gl-worker.mjs", "maplibre-gl-shared.mjs"]) {
    const response = await page.request.get(`/maplibre/${file}`);
    expect(response.ok(), `${file} moet met de app worden gedeployd`).toBeTruthy();
  }
  await expect(page.locator("body")).not.toContainText("NIET-BESTAAND TESTADRES");
  await expect(page.locator("body")).not.toContainText("Testpoort 01");
  const map = page.locator('[data-map-center="4.2579563,52.0899891"]');
  await expect(map).toHaveAttribute("data-map-privacy", "area-only");
  await expect(map).toHaveAttribute("data-map-demo", "fictional");
  await expect(map.locator(".night-map-portal-pin")).toHaveCount(4, { timeout: 10_000 });
  await expect(map).toHaveAttribute("data-map-route-points", "4");
  await page.getByRole("button", { name: "Pauzeren" }).click();
  await map.locator(".night-map-portal-pin").first().dispatchEvent("mouseenter");
  const popup = map.locator(".night-map-popup");
  await expect(popup).toContainText("Fictieve demonstratie");
  await expect(popup).toContainText(/Heksenrijk|Circuswereld|Geestenwereld|Vampierrijk/);
  await expect(popup).not.toContainText("Adres:");
  await expect(popup).not.toContainText("Contact:");

  const experience = page.locator(".public-map-experience");
  const firstScene = await experience.getAttribute("data-demo-scene");
  await page.getByRole("button", { name: "Nieuwe voorbeeldroute" }).click();
  await expect(experience).not.toHaveAttribute("data-demo-scene", firstScene ?? "0");
  await expect(map.locator(".night-map-portal-pin")).toHaveCount(3);
});

test("homepage preview keeps the verified Tesselseplein centre without house markers", async ({ page }) => {
  await page.goto("/");
  const map = page.locator('[data-map-center="4.2579563,52.0899891"]').first();
  await expect(map).toBeVisible();
  await expect(map).toHaveAttribute("data-map-privacy", "area-only");
  await expect(map.locator(".night-map-portal-pin")).toHaveCount(0);
  await expect(page.locator("body")).not.toContainText("NIET-BESTAAND TESTADRES");
});

test("public map mounts a canvas in a WebGL2 browser", async ({ page }) => {
  await page.goto("/kaart");
  const webgl2 = await page.evaluate(() => Boolean(document.createElement("canvas").getContext("webgl2")));
  test.skip(!webgl2, "Deze browser heeft geen WebGL2 en gebruikt de adresfallback.");
  await expect(page.locator(".maplibregl-canvas")).toBeVisible({ timeout: 10_000 });
});

test("map outage shows a usable Duindorp text fallback", async ({ page }) => {
  await page.route("https://tiles.openfreemap.org/**", (route) => route.abort());
  await page.goto("/kaart");
  await expect(page.getByText("Kaart tijdelijk niet beschikbaar")).toBeVisible();
  await expect(page.getByText(/fictieve voorbeeldpoort/i).first()).toBeVisible();
  await expect(page.locator(".night-map-fallback")).not.toContainText("Adres:");
});

test("world overview presents six optional themes in a stable grid", async ({ page }) => {
  await page.goto("/werelden");
  await expect(page.getByRole("heading", { name: /welke wereld durf jij te betreden/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /hoofdthema’s ter inspiratie, geen vast draaiboek/i })).toBeVisible();
  await expect(page.getByText(/elk deelnemend huis kiest zelf een thema/i)).toBeVisible();
  await expect(page.getByText(/geen garantie dat iedere wereld/i)).toBeVisible();
  const grid = page.locator(".worlds-page .all-worlds");
  await expect(grid).toHaveCSS("display", "grid");
  const cards = grid.locator(".world-card");
  await expect(cards).toHaveCount(6);
  const boxes = await cards.evaluateAll((elements) => elements.map((element) => {
    const box = element.getBoundingClientRect();
    return { width: box.width, height: box.height, top: box.top, bottom: box.bottom };
  }));
  expect(boxes.every((box) => box.width > 180 && box.height > 240)).toBe(true);
  expect(boxes[3].top).toBeGreaterThan(boxes[0].top);
});

test("authentication uses a six-digit email OTP without a role picker", async ({ page }) => {
  await page.goto("/inloggen");
  await expect(page.getByRole("heading", { name: /Inloggen met e-mail/i })).toBeVisible();
  await expect(page.getByLabel("E-mailadres")).toBeVisible();
  await expect(page.locator("body")).toContainText("geen wachtwoord nodig");
  await expect(page.locator("body")).not.toContainText("Kies een rol");
});

test("protected route redirects to login and keeps safe return path", async ({ page }) => {
  await page.goto("/mijn-groep");
  await expect(page).toHaveURL(/\/inloggen\?next=%2Fmijn-groep|\/inloggen\?next=\/mijn-groep/);
  await expect(page.getByLabel("E-mailadres")).toBeVisible();
});

test("keyboard navigation and reduced motion remain usable", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  await page.keyboard.press("Tab");
  await expect(page.locator(":focus")).toBeVisible();
  await expect(page.locator("html")).toHaveCSS("scroll-behavior", "auto");
});

test("service worker is a real script with private network-only rules", async ({ request }) => {
  const response = await request.get("/sw.js");
  expect(response.ok()).toBeTruthy();
  expect(response.headers()["cache-control"]).toContain("no-store");
  const body = await response.text();
  expect(body).toContain('VERSION = "duindorp-public-v3"');
  expect(body).toContain('OFFLINE_URL = "/offline.html"');
  expect(body).toContain("SAFE_ASSETS");
  expect(body).toContain("CLEAR_PRIVATE_CACHE");
  expect(body).toContain('"/mijn-"');
  expect(body).toContain('event.request.mode === "navigate"');
  expect(body).toContain('cache: "no-store"');
  expect(body).toContain("legacyPublicCaches.length > 0");
  expect(body).toContain("client.navigate(client.url)");
  expect(body).not.toContain("await Promise.allSettled(clients.map");
  expect(body).not.toContain('caches.match("/")');
  expect(body).not.toContain('["/", "/verhaal"');
});

test("service worker never serves cached page HTML on a first navigation", async ({ page }) => {
  await page.goto("/");
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise<void>((resolve) => {
        navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true });
      });
    }

    const cache = await caches.open("duindorp-public-v2:assets");
    await cache.put(
      new Request(`${window.location.origin}/werelden`),
      new Response("<!doctype html><title>Verouderd</title><p>VEROUDERDE PAGINA</p>", {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }),
    );
  });

  await page.goto("/werelden");
  await expect(page.getByRole("heading", { name: /welke wereld durf jij te betreden/i })).toBeVisible();
  await expect(page.locator("body")).not.toContainText("VEROUDERDE PAGINA");
});

for (const size of [{ width: 320, doubleText: false }, { width: 390, doubleText: false }, { width: 390, doubleText: true }, { width: 768, doubleText: false }, { width: 1440, doubleText: false }]) {
  test(`public pages fit ${size.width}px with ${size.doubleText ? "200%" : "100%"} text`, async ({ page }) => {
    test.setTimeout(90_000);
    await page.setViewportSize({ width: size.width, height: 844 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    for (const path of ["/", "/verhaal", "/werelden", "/werelden/heksenrijk", "/werelden/dodenrijk", "/werelden/circuswereld", "/werelden/besmette-zone", "/werelden/geestenwereld", "/werelden/vampierrijk", "/kaart", "/meelopen", "/huis-aanmelden", "/faq", "/sponsoren", "/contact", "/privacy", "/voorwaarden", "/toegankelijkheid", "/inloggen"]) {
      await page.goto(path);
      await assertReadableLayout(page, size.doubleText);
    }
    await page.getByLabel("E-mailadres").focus();
    await page.keyboard.type("keyboard@example.invalid");
    await expect(page.getByLabel("E-mailadres")).toHaveValue("keyboard@example.invalid");
    await page.keyboard.press("Tab");
    await expect(page.locator(":focus")).toBeVisible();
  });
}

test("world explorer displays its artwork and supports all six worlds and keyboard navigation", async ({ page }, testInfo) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  const explorer = page.locator(".world-explorer");
  await explorer.scrollIntoViewIfNeeded();
  const tabs = explorer.getByRole("tab");
  await expect(tabs).toHaveCount(6);
  for (let index = 0; index < 6; index += 1) {
    const tab = tabs.nth(index);
    await tab.click();
    await expect(tab).toHaveAttribute("aria-selected", "true");
    const name = await tab.locator("strong").innerText();
    await expect(explorer.getByRole("heading", { name, exact: true })).toBeVisible();
    const image = explorer.locator(".explorer-art img");
    await expect(image).toHaveAttribute("src", `/images/world-${index}.webp`);
    await expect.poll(() => image.evaluate((element: HTMLImageElement) => element.complete && element.naturalWidth > 0)).toBe(true);
    await expect(explorer.locator(".explorer-scene")).toHaveCSS("isolation", "isolate");
    const geometry = await tab.evaluate((element) => {
      const card = element.getBoundingClientRect();
      const photo = element.querySelector("img")!.getBoundingClientRect();
      return { cardWidth: card.width, photoWidth: photo.width, cardHeight: card.height, photoHeight: photo.height };
    });
    expect(geometry.cardHeight).toBeGreaterThanOrEqual(125);
    expect(geometry.photoWidth).toBeLessThan(geometry.cardWidth * 1.1);
    expect(geometry.photoHeight).toBeLessThan(geometry.cardHeight * 1.1);
  }
  await tabs.last().focus();
  await page.keyboard.press("ArrowRight");
  await expect(tabs.first()).toBeFocused();
  await expect(tabs.first()).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("End");
  await expect(tabs.last()).toBeFocused();
  await page.keyboard.press("Home");
  await expect(tabs.first()).toBeFocused();
  await explorer.getByRole("button", { name: "Vorige wereld", exact: true }).click();
  await expect(tabs.last()).toHaveAttribute("aria-selected", "true");
  await explorer.getByRole("button", { name: "Volgende wereld", exact: true }).click();
  await expect(tabs.first()).toHaveAttribute("aria-selected", "true");
  await explorer.screenshot({ path: testInfo.outputPath("world-explorer.png") });
  await explorer.getByRole("button", { name: "Betreed deze wereld" }).click();
  await expect(page).toHaveURL(/\/werelden\/heksenrijk$/);
});

test("house registration respects the release mode and starts with only the three required contact fields", async ({ page }) => {
  await page.goto("/huis-aanmelden");
  if (process.env.REGISTRATION_MODE === "closed") {
    await expect(page.getByRole("heading", { name: "Nieuwe plekken kunnen zich nu niet aanmelden." })).toBeVisible();
    await expect(page.getByLabel("E-mailadres", { exact: true })).toHaveCount(0);
    await assertReadableLayout(page, false);
    await page.goto("/meelopen");
    await expect(page.getByRole("heading", { name: "Groepsinschrijving opent later." })).toBeVisible();
    await expect(page.getByRole("link", { name: "Start met inschrijven" })).toHaveCount(0);
    return;
  }
  for (const name of ["E-mailadres *", "Naam contactpersoon *", "Telefoonnummer *"]) {
    await expect(page.getByLabel(name, { exact: true })).toBeVisible();
  }
  await expect(page.getByLabel("Straat", { exact: true })).toHaveCount(0);
  await expect(page.getByLabel("Beschrijving (optioneel)", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Stuur eenmalige code" })).toBeDisabled();
  await assertReadableLayout(page, false);
});

test("the Halloween image package is connected to every intended public role", async ({ page }) => {
  await page.goto("/");
  for (const stem of ["01-home-hero-duindorp-bij-avond", "02-home-de-avond-straat", "03-home-de-poorten-gevels", "04-home-iets-lekkers-steeg"]) {
    await expect(page.locator(`img[src*="${stem}"]`).first()).toHaveAttribute("src", new RegExp(stem));
  }
  for (const [id, stem] of [["de-avond", "02-home-de-avond-straat"], ["de-poorten", "03-home-de-poorten-gevels"], ["iets-lekkers", "04-home-iets-lekkers-steeg"]] as const) {
    await page.locator(`#${id}`).scrollIntoViewIfNeeded();
    const images = page.locator(`img[src*="${stem}"]`);
    await expect.poll(() => images.evaluateAll((elements: HTMLImageElement[]) => elements.some((element) => element.complete && element.naturalWidth > 0))).toBe(true);
  }
  for (const [route, hook, stem] of [["/meelopen", "meelopen", "05-meelopen-samen-op-pad"], ["/huis-aanmelden", "huis-aanmelden", "06-huis-aanmelden-jouw-deur"], ["/sponsoren", "sponsoren", "08-sponsoren-de-wijk-maakt-het"]] as const) {
    await page.goto(route);
    const image = page.locator(`[data-halloween-photo="${hook}"] img`);
    await expect(image).toHaveAttribute("src", new RegExp(stem));
    await expect.poll(() => image.evaluate((element: HTMLImageElement) => element.complete && element.naturalWidth > 0)).toBe(true);
  }
  await page.goto("/verhaal");
  await expect(page.locator(".story-hero img")).toHaveAttribute("src", /07-verhaal-wereld-achter-de-deur/);
});


test("motion preference lives in accessibility settings and persists without floating controls", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/toegankelijkheid");
  await expect(page.locator(".motion-toggle")).toHaveCount(0);
  await page.getByRole("button", { name: "Animaties pauzeren" }).click();
  await expect(page.locator("html")).toHaveClass(/motion-off/);
  await page.reload();
  await expect(page.getByRole("button", { name: "Animaties hervatten" })).toBeVisible();
  await page.getByRole("button", { name: "Animaties hervatten" }).click();
  await expect(page.locator("html")).not.toHaveClass(/motion-off/);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(page.getByRole("button", { name: "Animaties uit volgens je apparaatinstelling" })).toBeDisabled();
  await expect(page.locator("html")).toHaveClass(/motion-off/);
});
