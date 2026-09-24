import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { assertReadableLayout } from "./helpers/layout";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

// Uses existing local fixtures only; these layout checks never update participation or payments.
async function authenticate(context: BrowserContext, email: string) {
  const client = createClient(supabaseUrl!, publishableKey!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await client.auth.signInWithPassword({ email, password: "local-test-only" });
  expect(error).toBeNull();
  expect(data.session).toBeTruthy();
  const name = `sb-${new URL(supabaseUrl!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(data.session)).toString("base64url")}`;
  const chunks = value.length <= 3180 ? [{ name, value }] : Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180) }));
  await context.clearCookies();
  await context.addCookies(chunks.map((chunk) => ({ ...chunk, url: "http://127.0.0.1:3100", sameSite: "Lax" as const })));
}

async function assertPhoneLayout(page: Page) {
  await assertReadableLayout(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), `Horizontal document overflow at ${page.url()}`).toBeLessThanOrEqual(1);
  const clippedText = await page.locator(".child-payment-name-action,.registration-dashboard .summary-row,.group-route-context").evaluateAll((items) => items.filter((item) => item.scrollWidth > item.clientWidth + 1).map((item) => item.textContent));
  expect(clippedText).toEqual([]);
}

for (const width of [320, 375, 390, 430]) {
  test(`parent and group screens remain usable at ${width}px`, async ({ context, page }, testInfo) => {
    test.skip(testInfo.project.name !== "desktop-chromium", "Explicit phone matrix runs once.");
    test.skip(!supabaseUrl || !publishableKey, "Local Supabase browser acceptance environment is not configured");
    test.setTimeout(180_000);
    await page.setViewportSize({ width, height: 844 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await authenticate(context, "parent-a@example.invalid");
    await page.goto("/mijn-inschrijving");
    await expect(page.locator(".registration-reference")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Kinderen en wijzigingen" })).toBeVisible();
    await assertPhoneLayout(page);
    const invitation = page.getByRole("button", { name: "Verstuur eenmalige uitnodiging" });
    await invitation.scrollIntoViewIfNeeded();
    const invitationBounds = await invitation.boundingBox();
    expect(invitationBounds!.height).toBeGreaterThanOrEqual(44);

    await authenticate(context, "leader-a@example.invalid");
    for (const path of ["/mijn-groep", "/omgeving", "/omgeving/meeloper/route", "/omgeving/meeloper/groep", "/omgeving/meeloper/nachtpas", "/omgeving/meeloper/meer"]) {
      if (path === "/omgeving") await authenticate(context, "parent-size-5@example.invalid");
      await page.goto(path);
      await expect(page.locator(".group-route-context,.participant-page-head").first()).toBeVisible();
      await expect(page.locator(".loading-state,.participant-loading")).toHaveCount(0);
      await assertPhoneLayout(page);
      if (path.startsWith("/omgeving")) {
        const navigation = page.getByRole("navigation", { name: "Mobiele omgevingsnavigatie" });
        await expect(navigation).toBeVisible();
        for (const link of await navigation.getByRole("link").all()) {
          await expect(link).toBeVisible();
          expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(44);
        }
        const support = page.getByRole("button", { name: "Hulp van de organisatie" });
        const supportBounds = await support.boundingBox();
        const navigationBounds = await navigation.boundingBox();
        expect(supportBounds!.y + supportBounds!.height).toBeLessThanOrEqual(navigationBounds!.y);
      }
      if (path.endsWith("/nachtpas")) {
        // Stress only rendered labels, preserving all underlying fixtures and RPC data.
        await page.locator(".child-payment-name-action>strong").first().evaluate((element) => { element.textContent = "AlexandervanderDuinmeteenlangenaam"; });
        await assertPhoneLayout(page);
        for (const action of await page.locator(".child-tikkie-action").all()) expect((await action.boundingBox())!.height).toBeGreaterThanOrEqual(44);
        await page.screenshot({ path: testInfo.outputPath(`nightpass-${width}.png`), fullPage: true });
      }
      if (path.endsWith("/meer")) {
        const logout = page.locator(".participant-account").getByRole("button", { name: "Uitloggen", exact: true });
        await logout.scrollIntoViewIfNeeded();
        await logout.click({ trial: true });
        await page.getByRole("button", { name: "Hulp van de organisatie" }).click();
        const dialog = page.getByRole("dialog");
        await expect(dialog.getByLabel("Bericht", { exact: true })).toBeVisible();
        const bounds = await dialog.boundingBox();
        const nav = await page.locator(".participant-bottomnav").boundingBox();
        expect(bounds!.x).toBeGreaterThanOrEqual(0);
        expect(bounds!.y).toBeGreaterThanOrEqual(0);
        expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
        expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(nav!.y);
        await page.keyboard.press("Escape");
        await expect(dialog).toHaveCount(0);
      }
    }
  });
}
