import { expect, test } from "@playwright/test";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");

test("public Deelstudio selects, previews, copies and downloads without personal data", async ({ page }) => {
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.route("**/api/deelstudio/context", (route) => route.fulfill({
    contentType: "application/json",
    body: JSON.stringify({ data: { event: { title: "De Duindorpse Poorten van Halloween", localDate: "2026-10-31", timezone: "Europe/Amsterdam" }, authenticated: false, cards: [{ key: "general_event", name: "Algemene eventkaart", version: 1, formats: ["story", "feed", "square", "landscape", "opengraph"], portraitAsset: "/images/social-share/general/general-event-portrait.webp", landscapeAsset: "/images/social-share/general/general-event-landscape.webp", textConfig: { eyebrow: "HALLOWEEN AVONDLOOP", title: "DE DUINDORPSE POORTEN VAN HALLOWEEN" }, defaultCaption: "De poorten komen eraan. https://duindorpdoet.nl", ctaType: "event", dynamic: {}, worldStyleAvailable: false }] } }),
  }));
  await page.route("**/api/deelstudio/generate", (route) => route.fulfill({
    status: 201, contentType: "application/json",
    body: JSON.stringify({ data: { generationId: "10000000-0000-0000-0000-000000000001", publicShareId: "0123456789abcdef0123456789abcdef", imageUrl: `data:image/png;base64,${png.toString("base64")}`, publicPageUrl: "https://duindorpdoet.nl/delen/0123456789abcdef0123456789abcdef", caption: "De poorten komen eraan. https://duindorpdoet.nl", cached: false } }),
  }));
  await page.route("**/api/deelstudio/events", (route) => route.fulfill({ status: 202, contentType: "application/json", body: '{"data":{"accepted":true}}' }));

  await page.goto("/deel-de-magie");
  await expect(page.getByRole("heading", { name: "Maak jouw deelkaart" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Algemene eventkaart/ })).toBeVisible();
  await page.getByRole("button", { name: /Vierkant/ }).click();
  await page.getByRole("button", { name: "Maak mijn deelkaart" }).click();
  await expect(page.getByRole("heading", { name: "Klaar om de magie te delen?" })).toBeVisible();
  await expect(page.getByText(/geen adressen of kindgegevens/i)).toBeVisible();
  await expect(page.locator("body")).not.toContainText(/samenloopcode|kindnaam|startpunt/i);
  await page.getByRole("button", { name: "Bericht kopiëren" }).click();
  await expect(page.getByRole("status")).toContainText("Bericht gekopieerd");
  await page.getByRole("button", { name: "Afbeelding opslaan" }).click();
  await expect(page.getByRole("status")).toContainText("Afbeelding opgeslagen");
});
