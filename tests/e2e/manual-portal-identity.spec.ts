import { expect, test } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { requireLocalTogetherDatabase, sql } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance } from "./helpers/guidance";

test("an approved portal with an old empty-number draft can be edited and activated without renumbering", async ({ context, page, baseURL }) => {
  requireLocalTogetherDatabase();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  expect(key).toBeTruthy();
  const portalId = "12000000-0000-0000-0000-000000000029";
  // Existing approved fixture has its real owner, verified position and window.
  // Recreate P-38's broken draft shape without touching any hosted records.
  sql(`update app_private.portals set application_id=null,record_source='manual',lifecycle_status='approved',operation_status='scheduled',
    contact_name='Handmatige poortwachter',contact_phone='0612345678',contact_email='parent-size-5@example.invalid' where id='${portalId}';
    insert into app_private.portal_maintenance_drafts(portal_id,actor_id,payload)
    values('${portalId}','f0000000-0000-0000-0000-000000000001','{"systemNumber":null,"lifecycleStatus":"approved","approvalStatus":"approved","saveMode":"activate"}')
    on conflict(portal_id) do update set payload=excluded.payload;`);
  const client = createClient(url, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
  expect(login.error).toBeNull();
  await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
    name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: baseURL!, sameSite: "Lax" as const,
  })));
  let lastSave: Record<string, unknown> | undefined;
  page.on("request", request => {
    if (request.url().endsWith("/rpc/admin_manual_portal_save")) lastSave = request.postDataJSON();
  });
  await page.goto("/admin?view=portals");
  await page.getByRole("tab", { name: /Actieve poorten/ }).click();
  await expect(page.locator(`#portal-${portalId}`)).toBeVisible();
  await expect(page.locator(`#portal-${portalId}`)).toContainText("Handmatige poortwachter");
  await expect(page.locator(`#portal-${portalId}`)).toContainText("Voorbereiding");
  expect(sql(`select lifecycle_status from app_private.portals where id='${portalId}'`)).toBe("approved");
  await page.getByRole("tab", { name: "Poorten beheren", exact: true }).click();
  const card = page.locator(".manual-portal-list article").filter({ has: page.getByText("P-29", { exact: true }) });
  await expect(card).toBeVisible();
  await card.getByRole("button", { name: "Bewerken", exact: true }).click();
  let editor = page.locator(".manual-portal-editor");
  await expect(editor.getByLabel("Voorgesteld poortnummer")).toHaveValue("29");
  await expect(editor.getByLabel("Voorgesteld poortnummer")).toBeDisabled();
  await editor.getByLabel("Lifecycle-status").selectOption("active");
  await editor.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
  await expect(editor).not.toBeVisible();
  expect((lastSave?._payload as { systemNumber: number }).systemNumber).toBe(29);
  expect(sql(`select system_code||':'||lifecycle_status from app_private.portals where id='${portalId}'`)).toBe("P-29:active");

  await card.getByRole("button", { name: "Bewerken", exact: true }).click();
  editor = page.locator(".manual-portal-editor");
  await editor.getByLabel("Poortnaam", { exact: true }).fill("Bewerkbare goedgekeurde testpoort");
  await editor.getByRole("button", { name: "Activeren / gegevens afronden", exact: true }).click();
  await expect(editor).not.toBeVisible();
  expect(sql(`select system_code||':'||name from app_private.portals where id='${portalId}'`)).toBe("P-29:Bewerkbare goedgekeurde testpoort");

  const payload: Record<string, unknown> = { ...(lastSave!._payload as Record<string, unknown>), systemNumber: 99, commandKey: crypto.randomUUID() };
  delete payload.impactHash; delete payload.impactConfirmed;
  const renumber = await client.schema("api").rpc("admin_manual_portal_save", {
    ...lastSave, _payload: payload, _expected_version: Number(sql(`select version from app_private.portals where id='${portalId}'`)),
  });
  expect(renumber.error?.message).toBe("PORTAL_CODE_IS_STABLE");
  expect(sql(`select system_code from app_private.portals where id='${portalId}'`)).toBe("P-29");
  await page.getByRole("tab", { name: /Actieve poorten/ }).click();
  await expect(page.getByText("Bewerkbare goedgekeurde testpoort", { exact: true })).toBeVisible();
  await client.auth.signOut();
});
