import { expect, test } from "@playwright/test";
import { assertReadableLayout } from "./helpers/layout";

test("premium homepage keeps the supplied identity and closed participation path", async ({ page }, testInfo) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/Duindorpse Poorten/);
  await expect(page.getByRole("img", { name: "De Duindorpse Poorten van Halloween" }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: /Een gewone wijk/ })).toBeVisible();
  await expect(page.getByText("31 OKTOBER 2026").first()).toBeVisible();
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

test("public map never exposes exact route data", async ({ page }) => {
  await page.goto("/kaart");
  await expect(page.getByRole("heading", { name: /waar begint jullie avontuur/i })).toBeVisible();
  await expect(page.getByText(/deelnemende huizen en verrassingen houden we geheim/i)).toBeVisible();
  await expect(page.locator("body")).not.toContainText("NIET-BESTAAND TESTADRES");
  await expect(page.locator("body")).not.toContainText("Testpoort 01");
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
  const body = await response.text();
  expect(body).toContain("CLEAR_PRIVATE_CACHE");
  expect(body).toContain('"/mijn-"');
  expect(body).toContain('cache: "no-store"');
});

for (const size of [{ width: 320, doubleText: false }, { width: 390, doubleText: false }, { width: 390, doubleText: true }]) {
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

test("house registration starts with contact details and address before confirmation", async ({ page }) => {
  await page.goto("/huis-aanmelden");
  for (const name of ["E-mailadres", "Naam contactpersoon *", "Telefoonnummer *", "Straat *", "Huisnummer *", "Postcode *"]) {
    await expect(page.getByLabel(name, { exact: true })).toBeVisible();
  }
  await expect(page.getByLabel("Beschrijving *", { exact: true })).toHaveCount(0);
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
