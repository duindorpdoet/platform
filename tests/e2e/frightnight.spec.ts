import { expect, test } from "@playwright/test";

for (const width of [320, 390, 430, 768, 1024, 1440]) {
  test(`de gekozen v7 blijft leesbaar op ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: width < 768 ? 844 : 1000 });
    const errors: string[] = []; page.on("pageerror", error => errors.push(error.message));
    await page.goto("/");
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("DIT WORDTJOUW NACHT.");
    await expect(page.locator(".pp-king")).toBeVisible();
    await expect(page.locator(".pp-ticket")).toHaveCount(2);
    await expect(page.getByRole("heading", { name: "LANTAARNEN TOCHT.", exact: false })).toBeVisible();
    await expect(page.getByRole("link", { name: "Deze tocht kies ik" })).toHaveAttribute("href", "/nachtpas?tocht=mild");
    await expect(page.getByRole("link", { name: "Ik durf het aan" })).toHaveAttribute("href", "/nachtpas?tocht=scary");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    expect(await page.locator(".pp-king").evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth > 500)).toBe(true);
    expect(await page.locator(".theme-poster").evaluate(element => getComputedStyle(element).getPropertyValue("--bg").trim())).toBe("#081712");
    expect(errors).toEqual([]);
  });
}

test("publieke kerninhoud en echte navigatie blijven beschikbaar zonder JavaScript", async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, serviceWorkers: "block", viewport: { width: 390, height: 844 } });
  const page = await context.newPage(); await page.goto(baseURL!);
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  await expect(page.locator(".pp-king")).toBeVisible();
  await expect(page.getByRole("heading", { name: /HOE DAPPER/ })).toBeVisible();
  await page.getByRole("link", { name: "Deze tocht kies ik" }).click();
  await expect(page).toHaveURL(/\/nachtpas\?tocht=mild$/);
  await context.close();
});

test("systeemvoorkeur stopt decoratieve beweging zonder taken te verbergen", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".theme-poster")).toHaveAttribute("data-motion", "still");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  expect(await page.locator(".pp-ember").first().evaluate(element => getComputedStyle(element).animationName)).toBe("none");
  await page.getByRole("link", { name: "Ik durf het aan" }).click();
  await expect(page).toHaveURL(/tocht=scary/);
});

test("zichtbare sfeerpauze en mobiel menu werken met toetsenbord", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" }); await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await page.keyboard.press("Tab"); await expect(page.getByRole("link", { name: "Direct naar de inhoud" })).toBeFocused();
  const menu = page.getByRole("button", { name: "Menu openen" }); await menu.focus(); await page.keyboard.press("Enter");
  await expect(page.getByRole("button", { name: "Menu sluiten" })).toHaveAttribute("aria-expanded", "true");
  await page.getByRole("button", { name: "Menu sluiten" }).click();
  await page.getByRole("button", { name: "Pauzeer sfeereffecten" }).click();
  await expect(page.locator(".theme-poster")).toHaveAttribute("data-motion", "still");
  await expect(page.getByRole("link", { name: "Deze tocht kies ik" })).toBeVisible();
});

for (const path of ["/nachtpas", "/mijn-zone", "/avondregie", "/testcentrum"]) {
  test(`${path} toont een echte inloggrens zonder rolselector`, async ({ page, request }) => {
    const response = await request.get("/api/frightnight/snapshot");
    expect(response.status()).toBe(401); expect(response.headers()["cache-control"]).toContain("no-store");
    await page.setViewportSize({ width: 390, height: 844 }); await page.goto(path);
    await expect(page.getByRole("link", { name: "Inloggen met e-mailcode" })).toBeVisible();
    await expect(page.locator("select[name=role],select[name=actor]")).toHaveCount(0);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await expect(page.locator("body")).not.toContainText("De Poorten");
  });
}

test("inloggen verstuurt geen code zonder expliciete testeractie", async ({ page }) => {
  const sent: string[] = []; page.on("request", request => { if (request.method() === "POST" && request.url().includes("/auth/v1/otp")) sent.push(request.url()); });
  await page.goto("/inloggen?next=%2Fnachtpas");
  await expect(page.getByRole("heading", { name: "OPEN JOUW NACHTPAS." })).toBeVisible();
  await expect(page.getByLabel("E-mailadres", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Stuur eenmalige code" })).toBeDisabled();
  expect(sent).toEqual([]);
});

test("openbare inhoud hangt niet van een live databaseaanroep in de browser af", async ({ page }) => {
  const externalDatabase: string[] = [];
  await page.route(/https?:\/\/[^/]+\.supabase\.(co|in)\//, async route => { externalDatabase.push(route.request().url()); await route.abort("internetdisconnected"); });
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible(); await expect(page.locator(".pp-king")).toBeVisible();
  await expect(page.getByRole("link", { name: "Deze tocht kies ik" })).toBeVisible();
  expect(externalDatabase.filter(url => /rest\/v1|rpc/.test(url))).toEqual([]);
});

test("PWA en onafhankelijke noodinformatie hebben de nieuwe identiteit", async ({ page, request }) => {
  const manifestResponse = await request.get("/manifest.webmanifest"); const manifest = await manifestResponse.json();
  expect(manifest).toMatchObject({ name: "Duindorp FrightNight 2027", start_url: "/nachtpas", background_color: "#081712" });
  for (const icon of manifest.icons) expect((await request.get(icon.src)).ok()).toBe(true);
  await page.goto("/offline.html");
  await expect(page.getByRole("heading", { level: 1 })).toContainText("EVEN GEEN VERBINDING");
  await expect(page.locator("body")).toContainText("Duinpad / Oogstdorp");
  await expect(page.locator("body")).toContainText("lokale bediening");
  await expect(page.locator("body")).toContainText("geen actuele huisstatus");
});
