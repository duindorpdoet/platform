import { expect, test } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { assertReadableLayout } from "./helpers/layout";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

test("homeowner controls, profile and support fit 320, 375, 390 and 430 pixel screens", async ({ context, page }, testInfo) => {
  test.skip(!supabaseUrl || !publishableKey, "Requires the local authenticated Supabase fixtures");
  test.skip(testInfo.project.name !== "desktop-chromium", "This test explicitly covers all four mobile widths");
  test.setTimeout(180_000);
  const client = createClient(supabaseUrl!, publishableKey!, { auth: { persistSession: false, autoRefreshToken: false } });
  const result = await client.auth.signInWithPassword({ email: "owner@example.invalid", password: "local-test-only" });
  expect(result.error).toBeNull();
  expect(result.data.session).toBeTruthy();
  const cookieName = `sb-${new URL(supabaseUrl!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
  const chunks = value.length <= 3180 ? [{ name: cookieName, value }] : Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: `${cookieName}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180) }));
  await context.addCookies(chunks.map((chunk) => ({ ...chunk, url: "http://127.0.0.1:3100", sameSite: "Lax" as const })));

  for (const width of [320, 375, 390, 430]) {
    await page.setViewportSize({ width, height: 820 });
    for (const path of ["/omgeving/huiseigenaar/mijn-poort", "/mijn-huis"]) {
      await page.goto(path);
      await expect(page.getByRole("heading", { name: "Veilig ontvangen", exact: true })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Werk jullie poort uit", exact: true })).toBeVisible();
      await assertReadableLayout(page);
      const overflow = await page.locator(".homeowner-cockpit, .owner-profile").evaluateAll((roots) => roots.flatMap((root) => [...root.querySelectorAll<HTMLElement>("button, input, textarea, select, h2, h3, a")]).filter((element) => {
        if (!element.checkVisibility()) return false;
        const bounds = element.getBoundingClientRect();
        return bounds.left < -1 || bounds.right > document.documentElement.clientWidth + 1;
      }).map((element) => element.getAttribute("aria-label") || element.textContent?.slice(0, 70) || element.tagName));
      expect(overflow, `${path} at ${width}px`).toEqual([]);
      const statusButtons = page.locator(".owner-state-actions button");
      await expect(statusButtons).toHaveCount(3);
      for (const button of await statusButtons.all()) {
        const bounds = await button.boundingBox();
        expect(bounds?.height).toBeGreaterThanOrEqual(44);
        expect(bounds?.width).toBeGreaterThanOrEqual(44);
      }
      const contact = page.getByLabel("Naam contactpersoon *", { exact: true });
      await expect(contact).toHaveCSS("font-size", "16px");
      const submit = page.getByRole("button", { name: "Indienen voor beoordeling", exact: true });
      await submit.evaluate((element) => element.scrollIntoView({ block: "end" }));
      const overlap = await submit.evaluate((element) => {
        const action = element.getBoundingClientRect();
        const launcher = document.querySelector(".messenger-launcher")?.getBoundingClientRect();
        return Boolean(launcher && action.left < launcher.right && action.right > launcher.left && action.top < launcher.bottom && action.bottom > launcher.top);
      });
      expect(overlap, `Profile submit remains clear of support at ${path}, ${width}px`).toBe(false);
      await page.locator(".messenger-launcher").click();
      const dialog = page.getByRole("dialog", { name: "Hulp van de organisatie", exact: true });
      await expect(dialog).toBeVisible();
      await expect(dialog.getByLabel("Bericht", { exact: true })).toBeVisible();
      const dialogBounds = await dialog.boundingBox();
      expect(dialogBounds!.x).toBeGreaterThanOrEqual(0);
      expect(dialogBounds!.y).toBeGreaterThanOrEqual(0);
      expect(dialogBounds!.x + dialogBounds!.width).toBeLessThanOrEqual(width + 1);
      expect(dialogBounds!.y + dialogBounds!.height).toBeLessThanOrEqual(820);
      await dialog.getByRole("button", { name: "Gesprek sluiten", exact: true }).click();
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: testInfo.outputPath(`homeowner-${path.startsWith("/omgeving") ? "environment" : "standalone"}-${width}.png`), fullPage: true });
    }
  }
});
