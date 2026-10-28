import { expect, test, type BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import {
  requireLocalTogetherDatabase,
  sql,
} from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance } from "./helpers/guidance";

test.use({ serviceWorkers: "block" });
const eventSlug = "duindorp-halloween-2026";
const reason =
  "De bewoner heeft gevraagd deze aanvraag namens hen in te dienen.";
function client() {
  requireLocalTogetherDatabase();
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}
async function manager(context?: BrowserContext, origin?: string) {
  const c = client();
  const signed = await c.auth.signInWithPassword({
    email: "admin@example.invalid",
    password: "local-test-only",
  });
  expect(signed.error).toBeNull();
  await prepareFixtureGuidance(c);
  if (context) {
    const name = `sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split(".")[0]}-auth-token`;
    const value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
    await context.addCookies(
      Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
        name: value.length <= 3180 ? name : `${name}.${i}`,
        value: value.slice(i * 3180, (i + 1) * 3180),
        url: origin!,
        sameSite: "Lax" as const,
      })),
    );
  }
  return c;
}
async function application() {
  requireLocalTogetherDatabase();
  const service = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SECRET_KEY!,
    { auth: { persistSession: false } },
  );
  const email = `submit-${randomUUID()}@example.invalid`;
  const created = await service.auth.admin.createUser({
    email,
    password: "local-submit-only",
    email_confirm: true,
  });
  expect(created.error).toBeNull();
  sql(
    `select api.portal_registration_begin('${eventSlug}','${email}','Fictieve indienproef','0612345678','','','','','${"a".repeat(64)}');`,
  );
  const resident = client();
  expect(
    (
      await resident.auth.signInWithPassword({
        email,
        password: "local-submit-only",
      })
    ).error,
  ).toBeNull();
  const claimed = await resident
    .schema("api")
    .rpc("portal_registration_claim", { _event_slug: eventSlug });
  expect(claimed.error).toBeNull();
  const saved = await resident.schema("api").rpc("portal_application_save", {
    _event_slug: eventSlug,
    _expected_version: claimed.data.version,
    _payload: {
      contactName: "Fictieve indienproef",
      phone: "0612345678",
      address: { street: "Oefenpad", houseNumber: "7", postalCode: "2583PS" },
      portalName: "Fictieve aanvraag",
      description: "Alleen lokale acceptatiegegevens",
      requestedWorldSlug: "heksenrijk",
      intensity: "2",
      warnings: {},
      availableFrom: "17:00",
      availableUntil: "21:00",
      availability: true,
      locationConsent: false,
    },
  });
  expect(saved.error).toBeNull();
  const id = claimed.data.id as string;
  return {
    id,
    email,
    applicant: created.data.user!.id,
    code: sql(
      `select system_code from app_private.portal_applications where id='${id}'`,
    ),
  };
}
function state(id: string) {
  return JSON.parse(
    sql(
      `select jsonb_build_object('application',to_jsonb(a),'mail',(select count(*) from app_private.email_outbox where payload->>'applicationId'=a.id::text and message_type='portal_received'),'audit',(select count(*) from app_private.audit_events where resource_id=a.id and action='portal_application.submitted_by_organization'),'portals',(select count(*) from app_private.portals where application_id=a.id)) from app_private.portal_applications a where id='${id}'`,
    ),
  );
}

test("explicit organization submission previews, cancels, preserves consent and exposes separate review", async ({
  page,
  context,
  baseURL,
}) => {
  const fixture = await application();
  await manager(context, baseURL);
  const before = state(fixture.id);
  await page.goto("/admin?view=portals");
  await page.getByRole("tab", { name: /^Aangemelde poorten/ }).click();
  const row = page
    .locator("details.portal-list-row")
    .filter({ hasText: fixture.code });
  await row.locator("summary .portal-code").click();
  await expect(
    row.getByText("Gegevens ingevuld · nog niet ingediend", { exact: true }),
  ).toBeVisible();
  await expect(
    row.getByRole("button", { name: "Goedkeuren", exact: true }),
  ).toHaveCount(0);
  await row
    .getByRole("button", { name: "Namens bewoner indienen", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText(fixture.email, { exact: false })).toBeVisible();
  await expect(
    dialog.getByRole("region", { name: "Toestemmingsstatus" }),
  ).toContainText("Locatietoestemming: Niet bevestigd");
  await expect(
    dialog.getByRole("region", { name: "Nog nodig vóór goedkeuren" }),
  ).not.toContainText("Locatietoestemming");
  await expect(
    dialog.getByRole("button", {
      name: "Indienen voor beoordeling",
      exact: true,
    }),
  ).toBeDisabled();
  await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
  expect(state(fixture.id)).toEqual(before);
  await row
    .getByRole("button", { name: "Namens bewoner indienen", exact: true })
    .click();
  await dialog
    .getByLabel("Reden voor indienen namens bewoner (10–500 tekens)")
    .fill(reason);
  await dialog.getByRole("checkbox").check();
  await dialog
    .getByRole("button", { name: "Indienen voor beoordeling", exact: true })
    .click();
  await expect(dialog).toHaveCount(0);
  await expect(
    row.getByRole("button", { name: "Goedkeuren", exact: true }),
  ).toBeVisible();
  await expect(
    row.getByText("Namens bewoner ingediend door organisatie", { exact: true }),
  ).toBeVisible();
  const after = state(fixture.id);
  expect(after.application.review_status).toBe("submitted");
  expect(after.application.private_draft_data).toEqual(
    before.application.private_draft_data,
  );
  expect(after.application.applicant_user_id).toBe(fixture.applicant);
  expect(after).toMatchObject({ mail: 1, audit: 1, portals: 0 });
  expect(
    sql(
      `select recipient_ref||':'||recipient_email from app_private.email_outbox where message_type='portal_received' and payload->>'applicationId'='${fixture.id}'`,
    ),
  ).toBe(`${fixture.applicant}:${fixture.email}`);
  expect(
    sql(
      `select actor_id from app_private.audit_events where resource_id='${fixture.id}' and action='portal_application.submitted_by_organization'`,
    ),
  ).toBe("f0000000-0000-0000-0000-000000000001");
});

test("missing submit data can be repaired and a changed preview cannot submit", async ({
  page,
  context,
  baseURL,
}) => {
  const fixture = await application();
  sql(
    `update app_private.portal_applications set private_draft_data=private_draft_data-'phone',version=version+1 where id='${fixture.id}'`,
  );
  await manager(context, baseURL);
  await page.goto("/admin?view=portals");
  await page.getByRole("tab", { name: /^Aangemelde poorten/ }).click();
  const row = page
    .locator("details.portal-list-row")
    .filter({ hasText: fixture.code });
  await row.locator("summary .portal-code").click();
  await row
    .getByRole("button", { name: "Namens bewoner indienen", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Vul een telefoonnummer");
  await dialog
    .getByRole("button", { name: "Aanmeldgegevens aanvullen", exact: true })
    .click();
  await dialog.getByLabel("Telefoon", { exact: true }).fill("0612345678");
  await dialog
    .getByLabel("Reden (minimaal 10 tekens)")
    .fill("Telefoon op verzoek van bewoner aangevuld");
  await dialog
    .getByRole("button", { name: "Gegevens opslaan", exact: true })
    .click();
  await expect(dialog).toHaveCount(0);
  expect(state(fixture.id).mail).toBe(0);
  await row
    .getByRole("button", { name: "Namens bewoner indienen", exact: true })
    .click();
  await dialog
    .getByLabel("Reden voor indienen namens bewoner (10–500 tekens)")
    .fill(reason);
  await dialog.getByRole("checkbox").check();
  sql(
    `update app_private.portal_applications set version=version+1 where id='${fixture.id}'`,
  );
  await dialog
    .getByRole("button", { name: "Indienen voor beoordeling", exact: true })
    .click();
  await expect(dialog.getByRole("alert")).toContainText("gewijzigd");
  expect(state(fixture.id)).toMatchObject({ mail: 0, audit: 0 });
  await dialog
    .getByRole("button", { name: "Preview vernieuwen", exact: true })
    .click();
  await expect(dialog.getByRole("checkbox")).not.toBeChecked();
  await expect(
    dialog.getByLabel("Reden voor indienen namens bewoner (10–500 tekens)"),
  ).toHaveValue(reason);
  await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
});

test("a committed command with a lost response retries its original receipt and sends one mail", async ({
  page,
  context,
  baseURL,
}) => {
  const fixture = await application();
  await manager(context, baseURL);
  const requests: unknown[] = [];
  await page.route("**/rpc/admin_portal_application_submit", async (route) => {
    requests.push(route.request().postDataJSON());
    if (requests.length === 1) {
      await route.fetch();
      await route.abort("failed");
    } else await route.continue();
  });
  await page.goto("/admin?view=portals");
  await page.getByRole("tab", { name: /^Aangemelde poorten/ }).click();
  const row = page
    .locator("details.portal-list-row")
    .filter({ hasText: fixture.code });
  await row.locator("summary .portal-code").click();
  await row
    .getByRole("button", { name: "Namens bewoner indienen", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await dialog
    .getByLabel("Reden voor indienen namens bewoner (10–500 tekens)")
    .fill(reason);
  await dialog.getByRole("checkbox").check();
  await dialog
    .getByRole("button", { name: "Indienen voor beoordeling", exact: true })
    .click();
  await expect(dialog.getByRole("alert")).toContainText(
    "uitkomst is nog niet bevestigd",
  );
  await expect(
    dialog.getByLabel("Reden voor indienen namens bewoner (10–500 tekens)"),
  ).toBeDisabled();
  expect(state(fixture.id)).toMatchObject({ mail: 1, audit: 1 });
  await dialog
    .getByRole("button", { name: "Uitkomst controleren", exact: true })
    .click();
  await expect(dialog).toHaveCount(0);
  expect(requests).toHaveLength(2);
  expect(requests[1]).toEqual(requests[0]);
  expect(state(fixture.id)).toMatchObject({ mail: 1, audit: 1, portals: 0 });
});

test("real simultaneous requests serialize managers and return identical receipts for retries", async () => {
  const first = await manager();
  const second = client();
  expect(
    (
      await second.auth.signInWithPassword({
        email: "parent-size-5@example.invalid",
        password: "local-test-only",
      })
    ).error,
  ).toBeNull();
  sql(
    `insert into app_private.event_capabilities(event_id,user_id,capability) select id,'a0000000-0000-0000-0000-000000000005','portals_manage' from app_private.events where slug='${eventSlug}' on conflict do nothing`,
  );
  const fixture = await application();
  const preview = await first
    .schema("api")
    .rpc("admin_portal_application_submit_preview", {
      _event_slug: eventSlug,
      _application_id: fixture.id,
    });
  expect(preview.error).toBeNull();
  const payload = {
    _event_slug: eventSlug,
    _application_id: fixture.id,
    _expected_version: preview.data.version,
    _input_hash: preview.data.inputHash,
    _reason: reason,
    _idempotency_key: randomUUID(),
  };
  const simultaneous = await Promise.all([
    first.schema("api").rpc("admin_portal_application_submit", payload),
    second.schema("api").rpc("admin_portal_application_submit", {
      ...payload,
      _idempotency_key: randomUUID(),
    }),
  ]);
  expect(simultaneous.filter((result) => !result.error)).toHaveLength(1);
  expect(simultaneous.find((result) => result.error)?.error?.code).toBe(
    "40001",
  );
  expect(state(fixture.id)).toMatchObject({ mail: 1, audit: 1 });
  const other = await application();
  const p = await first
    .schema("api")
    .rpc("admin_portal_application_submit_preview", {
      _event_slug: eventSlug,
      _application_id: other.id,
    });
  const command = {
    ...payload,
    _application_id: other.id,
    _expected_version: p.data.version,
    _input_hash: p.data.inputHash,
    _idempotency_key: randomUUID(),
  };
  const retries = await Promise.all(
    Array.from({ length: 4 }, () =>
      first.schema("api").rpc("admin_portal_application_submit", command),
    ),
  );
  expect(retries.every((result) => !result.error)).toBe(true);
  expect(new Set(retries.map((result) => result.data.receiptId)).size).toBe(1);
  expect(state(other.id)).toMatchObject({ mail: 1, audit: 1 });
});
