import { expect, test } from "@playwright/test";

test("an invitation waits for hydration before accepting an email address", async ({ page }) => {
  let releaseScripts!: () => void;
  const scriptsReleased = new Promise<void>(resolve => { releaseScripts = resolve; });
  let heldScripts = 0;
  const email = "hydration-guest@example.invalid";
  await page.route("**/_next/static/**", async route => {
    if (new URL(route.request().url()).pathname.endsWith(".js")) {
      heldScripts++;
      await scriptsReleased;
    }
    await route.continue();
  });
  try {
    await page.goto(`/uitnodiging/poort/${"a".repeat(64)}`, { waitUntil: "commit" });
    await expect(page.getByRole("heading", { name: "Welkom achter de poort", exact: true })).toBeVisible();
    await expect.poll(() => heldScripts).toBeGreaterThan(0);
    const field = page.getByLabel("E-mailadres", { exact: true });
    const submit = page.getByRole("button", { name: "Stuur eenmalige code", exact: true });
    await expect(field).toBeDisabled();
    await expect(submit).toBeDisabled();
    const fill = field.fill(email);
    await expect(field).toHaveValue("");
    releaseScripts();
    await fill;
    await expect(field).toHaveValue(email);
    await expect(submit).toBeEnabled();
    // Readiness is independent of Auth configuration; no code is requested.
  } finally {
    releaseScripts();
    await page.waitForLoadState("load");
  }
});
