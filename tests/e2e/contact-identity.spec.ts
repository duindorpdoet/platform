import { expect, test, type BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { selectOrganizationSection } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";
import { contentForMessage } from "../../lib/mail/mail-catalog";
import { renderPremiumEmail, type PremiumMailBrand } from "../../lib/mail/premium-template";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
async function authenticate(context: BrowserContext) {
  test.skip(!supabaseUrl || !key, "Local Supabase browser acceptance environment is not configured");
  expect(["localhost", "127.0.0.1"]).toContain(new URL(supabaseUrl!).hostname);
  const client = createClient(supabaseUrl!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(login.error).toBeNull();
  const cookieName = `sb-${new URL(supabaseUrl!).hostname.split(".")[0]}-auth-token`;
  const cookieValue = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  const chunks = Array.from({ length: Math.ceil(cookieValue.length / 3180) }, (_, index) => ({ name: cookieValue.length <= 3180 ? cookieName : `${cookieName}.${index}`, value: cookieValue.slice(index * 3180, (index + 1) * 3180), url: "http://127.0.0.1:3100", sameSite: "Lax" as const }));
  await context.addCookies(chunks);
  return login.data.user!.id;
}

test("inbox keeps person and per-message sender names separate from group context after reload", async ({ context, page }, testInfo) => {
  const userId = await authenticate(context);
  // Onboarding has its own acceptance suite; keep this render test read-only.
  await page.route("**/api/redesign/guidance", route => route.fulfill({ contentType: "application/json", body: JSON.stringify({ userId, eventId: "10000000-0000-0000-0000-000000000001", roles: ["admin"], welcomeVersion: 1, completed: {}, today: "2026-10-28", acknowledgedDay: "2026-10-28" }) }));
  let groupCode = "G-28";
  const message = (id: string, senderName: string, body: string) => ({ id, senderSide: "participant", senderName, body, createdAt: "2026-10-28T17:00:00Z", isMine: false });
  const conversation = (id: string, personName: string | null, code: string, body: string) => ({ id, subjectKind: "group", subjectId: "original-subject", participantUserId: id, personName, groupCode: code, householdLabel: "Gezelschap Voorbeeld", systemCode: code, displayName: code, subjectLabel: `${code} · ${code}`, status: "closed", version: 1, updatedAt: "2026-10-28T17:00:00Z", unreadCount: 0, messages: [message(`${id}-message`, "Daniël de la Cruz", body)] });
  await page.route("**/rest/v1/rpc/admin_messenger_presence", route => route.fulfill({ contentType: "application/json", body: "{}" }));
  await page.route("**/rest/v1/rpc/admin_messenger_snapshot", route => route.fulfill({ contentType: "application/json", body: JSON.stringify({ conversations: [
    conversation("person-1", "Élodie van 't Hof-de Peña", groupCode, "Bericht van de eerste contactpersoon"),
    conversation("person-2", null, "G-02", "Contactpersoon zonder geregistreerde naam"),
    conversation("person-3", "Sam de Jong", "G-11", "Eerste account met dezelfde naam"),
    conversation("person-4", "Sam de Jong", "G-11", "Tweede account met dezelfde naam"),
  ] }) }));
  await page.goto("/admin");
  await selectOrganizationSection(page, "Inbox");
  const inbox = page.locator(".messenger-inbox");
  await expect(inbox.locator(".messenger-conversation-copy strong")).toHaveText(["Élodie van 't Hof-de Peña · G-28", "Deelnemer · G-02", "Sam de Jong · G-11", "Sam de Jong · G-11"]);
  await expect(inbox).not.toContainText("G-28 · G-28");
  await expect(inbox).not.toContainText("G-02 · G-02");
  await expect(inbox).not.toContainText("G-11 · G-11");
  await inbox.locator(".messenger-conversation").first().click();
  await expect(inbox.getByRole("heading", { level: 2 })).toHaveText("Élodie van 't Hof-de Peña · G-28");
  await expect(inbox.locator(".chat-sender")).toHaveText("Daniël de la Cruz");
  groupCode = "G-46";
  await inbox.getByRole("button", { name: "Gesprekken vernieuwen" }).click();
  await expect(inbox.getByRole("heading", { level: 2 })).toHaveText("Élodie van 't Hof-de Peña · G-46");
  await expect(inbox.locator(".chat-sender")).toHaveText("Daniël de la Cruz");
  await inbox.getByRole("button", { name: "Terug naar gesprekken" }).click();
  const sameNames = inbox.locator(".messenger-conversation").filter({ hasText: "Sam de Jong · G-11" });
  await expect(sameNames).toHaveCount(2);
  await sameNames.nth(1).click();
  await expect(inbox.getByRole("log")).toContainText("Tweede account met dezelfde naam");
  await expect(inbox.getByRole("log")).not.toContainText("Eerste account met dezelfde naam");
  await assertReadableLayout(page);
  await page.screenshot({ path: testInfo.outputPath("contact-identity-inbox.png") });
});

test("final samenloop mail keeps group context separate on desktop and mobile", async ({ page }, testInfo) => {
  const brand: PremiumMailBrand = { name: "De Duindorpse Poorten van Halloween", supportEmail: "halloween@example.invalid", homeUrl: "https://example.invalid/", contactUrl: "https://example.invalid/contact", privacyUrl: "https://example.invalid/privacy", logoUrl: "https://example.invalid/logo.webp", heroUrl: "https://example.invalid/hero.webp", allowedLinkHosts: ["example.invalid"], allowedImageHosts: ["example.invalid"] };
  const mail = renderPremiumEmail(contentForMessage("group_merge_approved", { groupCode: "G-46", groupName: "G-46", headGroup: "G-46", clusterReference: "SL-2026-9VPTQB", personName: "Élodie van 't Hof", memberNames: ["Élodie van 't Hof", "Sam de Jong"] }, brand), brand);
  await page.route("https://example.invalid/**", route => route.abort());
  await page.setContent(mail.html);
  await expect(page.getByRole("heading", { name: "Jullie samenloop is bevestigd." })).toBeVisible();
  await expect(page.locator("body")).toContainText("SL-2026-9VPTQB");
  await expect(page.locator("body")).toContainText("Wandelgroep");
  await expect(page.locator("body")).toContainText("G-46");
  await expect(page.locator("body")).not.toContainText("De samenvoeging met G-46");
  await expect(page.locator("body")).not.toContainText("Élodie");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
  expect(overflow).toBe(false);
  await page.screenshot({ path: testInfo.outputPath("contact-identity-mail.png"), fullPage: true });
});
