import { expect, test } from "@playwright/test";

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
  await expect(page.getByRole("heading", { name: /sfeerkaart/i })).toBeVisible();
  await expect(page.getByText(/exacte adressen en routevolgorde/i)).toBeVisible();
  await expect(page.locator("body")).not.toContainText("NIET-BESTAAND TESTADRES");
  await expect(page.locator("body")).not.toContainText("Testpoort 01");
});

test("authentication uses a six-digit email OTP without a role picker", async ({ page }) => {
  await page.goto("/inloggen");
  await expect(page.getByRole("heading", { name: /Inloggen met e-mail/i })).toBeVisible();
  await expect(page.getByLabel("E-mailadres")).toBeVisible();
  await expect(page.locator("body")).toContainText("geen universele democode");
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
