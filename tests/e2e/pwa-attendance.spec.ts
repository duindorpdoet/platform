import { expect, test, type BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

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

test("a leader must decide attendance for every child without preselection", async ({ context, page }) => {
  test.skip(!supabaseUrl || !publishableKey, "Requires local Supabase fixtures");
  await authenticate(context, "leader-a@example.invalid");
  await page.goto("/mijn-groep");
  const rows = page.locator(".attendance-row");
  await expect(rows.first()).toBeVisible();
  const total = await rows.count();
  expect(total).toBeGreaterThan(0);
  await expect(page.locator(".attendance-progress")).toContainText(`0 van ${total} gecontroleerd`);
  await expect(rows.locator("input:checked")).toHaveCount(0);

  const start = page.getByRole("button", { name: /Start groep met/ });
  await expect(start).toBeDisabled();
  await rows.first().getByText("Aanwezig", { exact: true }).click();
  for (let index = 1; index < total; index += 1) await rows.nth(index).getByText("Afwezig", { exact: true }).click();
  await expect(page.locator(".attendance-progress")).toContainText(`${total} van ${total} gecontroleerd`);
  await expect(start).toBeEnabled();

  let confirmation = "";
  page.on("dialog", async (dialog) => { confirmation = dialog.message(); await dialog.dismiss(); });
  await start.click();
  expect(confirmation).toContain("1 aanwezige kind");
  expect(confirmation).toContain("Klopt dit?");
});

test("the mobile invitation is daily, dismissible and exposes honest manual install help", async ({ context, page }, testInfo) => {
  test.skip(testInfo.project.name !== "mobile-chromium", "Mobile installation invitation only");
  test.skip(!supabaseUrl || !publishableKey, "Requires local Supabase fixtures");
  await authenticate(context, "parent-a@example.invalid");
  await page.goto("/omgeving");
  const invitation = page.getByRole("dialog", { name: "Zet De Poorten op je beginscherm" });
  await expect(invitation).toBeVisible();
  await expect(invitation.getByText("Ik wil meldingen over mijn groep of poort ontvangen")).toBeVisible();
  await invitation.getByRole("button", { name: "Installeer app" }).click();
  await expect(invitation).toContainText(/browsermenu|Deel/);
  await invitation.getByRole("button", { name: "Later" }).click();
  await expect(invitation).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("dialog", { name: "Zet De Poorten op je beginscherm" })).toHaveCount(0);
});
