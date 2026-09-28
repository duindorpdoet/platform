import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { mkdirSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { amsterdamInput } from "../../lib/editorial/content";
import {
  sql,
  requireLocalTogetherDatabase,
} from "../../scripts/acceptance/together-fixtures.mjs";
const origin = "https://127.0.0.1:3443";
async function authenticate(context: BrowserContext, email: string) {
  requireLocalTogetherDatabase();
  const client = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const login = await client.auth.signInWithPassword({
    email,
    password: "local-test-only",
  });
  expect(login.error).toBeNull();
  const name = `sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  await context.clearCookies();
  await context.addCookies(
    Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
      name: value.length > 3180 ? `${name}.${i}` : name,
      value: value.slice(i * 3180, (i + 1) * 3180),
      url: origin,
      sameSite: "Lax" as const,
      secure: true,
    })),
  );
  return client;
}
async function redactie(page: Page) {
  await page.goto("/admin");
  await expect(page.locator(".admin-appbar")).toBeVisible();
  const more = page.getByRole("button", { name: "Meer", exact: true });
  const menu = page.getByRole("button", {
    name: "Organisatienavigatie openen",
  });
  if (await more.isVisible()) await more.click();
  else if (await menu.isVisible()) await menu.click();
  await page
    .locator(".admin-nav")
    .getByRole("button", { name: "Redactiekamer", exact: true })
    .click();
  await expect(
    page.getByRole("tab", { name: "Nieuwsberichten" }),
  ).toBeVisible();
}
async function screenshot(page: Page, name: string, project: string) {
  mkdirSync("docs/screenshots/redactiekamer", { recursive: true });
  for (const dialog of await page.getByRole("dialog").all())
    await expect(dialog).toHaveCSS("opacity", "1");
  await page.screenshot({
    path: `docs/screenshots/redactiekamer/${project}-${name}.png`,
  });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth + 1,
    ),
  ).toBe(true);
}
test("editor publishes selective news and prepares an immutable deduplicated Nachtpost", async ({
  page,
  context,
  browser,
}, info) => {
  const admin = await authenticate(context, "admin@example.invalid");
  const suffix = randomUUID().slice(0, 8);
  const parentContext = await browser.newContext({
    ...info.project.use,
    baseURL: origin,
    ignoreHTTPSErrors: true,
  });
  const parent = await authenticate(parentContext, "parent-a@example.invalid");
  const prefs = await parent.schema("api").rpc("editorial_preferences_set", {
    _event_slug: "duindorp-halloween-2026",
    _email: true,
    _parents_push: true,
    _houses_push: false,
  });
  expect(prefs.error).toBeNull();
  const device = randomUUID();
  sql(
    `delete from app_private.push_subscriptions where user_id='a0000000-0000-0000-0000-000000000001'; insert into app_private.push_preferences(user_id,enabled) values('a0000000-0000-0000-0000-000000000001',true) on conflict(user_id) do update set enabled=true; insert into app_private.push_subscriptions(id,user_id,endpoint,p256dh,auth_secret) values('${device}','a0000000-0000-0000-0000-000000000001','https://push.example.invalid/${device}','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','bbbbbbbbbbbbbbbb');`,
  );
  await redactie(page);
  await page
    .getByRole("button", { name: "Nieuw bericht", exact: true })
    .click();
  await page
    .getByLabel("Titel", { exact: true })
    .fill(`De poorten ontwaken ${suffix}`);
  await page
    .getByLabel(/Korte intro/)
    .fill(
      "De wijk maakt zich klaar voor een avond vol verhalen. Ontdek wat er achter de poorten gebeurt.",
    );
  await page.getByLabel("Auteur/vertoningsnaam").fill("Team Duindorp");
  await page
    .getByRole("textbox", { name: "Berichtinhoud" })
    .fill(
      "De eerste lichtjes gaan aan. Samen schrijven we een bijzondere nacht.",
    );
  await page
    .getByRole("button", { name: "Nieuwe afbeelding uploaden" })
    .click();
  const dialog = page.getByRole("dialog");
  await dialog
    .getByLabel("Afbeelding", { exact: true })
    .setInputFiles("public/images/pluvierstraat.webp");
  await dialog
    .getByLabel("Alt-tekst · verplicht")
    .fill(`Nachtelijk verlichte straat ${suffix}`);
  await dialog
    .getByLabel("Bijschrift", { exact: true })
    .fill("Een wijk. Duizend verhalen.");
  await dialog
    .getByRole("button", { name: "Toevoegen aan mediatheek" })
    .click();
  await expect(dialog).not.toBeVisible({ timeout: 20000 });
  await page
    .getByRole("combobox", { name: "Hoofdafbeelding", exact: true })
    .selectOption({ label: `Nachtelijk verlichte straat ${suffix}` });
  await page.getByLabel("Ouderportaal", { exact: true }).check();
  const planned = amsterdamInput(new Date(Date.now() + 3600000).toISOString());
  for (const input of await page
    .getByLabel("Publiceren op · leeg is direct")
    .all())
    await input.fill(planned);
  await page
    .getByRole("combobox", { name: "Pushnotificatie", exact: true })
    .selectOption("publish");
  await page.getByRole("button", { name: "Opslaan", exact: true }).click();
  await expect(
    page.getByText("Concept opgeslagen. Je live bericht blijft ongewijzigd."),
  ).toBeVisible();
  await page.getByRole("button", { name: "Voorbeeld", exact: true }).click();
  await expect(
    dialog.getByRole("heading", {
      name: `De poorten ontwaken ${suffix}`,
      exact: true,
    }),
  ).toBeVisible();
  await screenshot(page, "nieuws-preview", info.project.name);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Publicatie controleren" }).click();
  await expect(
    dialog.getByRole("heading", { name: "Publicatie bevestigen" }),
  ).toBeVisible();
  await dialog
    .getByRole("button", { name: "Bevestigen en publiceren" })
    .click();
  await expect(dialog).not.toBeVisible();
  const slug = `de-poorten-ontwaken-${suffix}`;
  const version = sql(
    `select v.id from app_private.content_versions v join app_private.news_articles a on a.id=v.article_id where a.slug='${slug}' and v.status='published'`,
  );
  expect(version).toMatch(/^[a-f0-9-]{36}$/);
  expect(
    sql(
      `select count(*) from app_private.news_placements where version_id='${version}' and state='live'`,
    ),
  ).toBe("0");
  sql(
    `update app_private.news_placements set starts_at=now()-interval '1 second',push_at=case when channel='parents' then now() else null end where version_id='${version}'; select api.worker_editorial_tick(false); select api.worker_editorial_tick(false);`,
  );
  expect(
    sql(
      `select count(*) from app_private.news_placements where version_id='${version}' and state='live'`,
    ),
  ).toBe("2");
  const notification = sql(
    `select id from app_private.portal_push_outbox where news_version_id='${version}'`,
  );
  expect(
    sql(
      `select count(*) from app_private.portal_push_deliveries where notification_id='${notification}'`,
    ),
  ).toBe("1");
  const jobs = JSON.parse(
    sql(
      `select api.worker_claim_editorial_push(array['parent-a@example.invalid'])`,
    ),
  );
  const job = jobs.find((j: { id: string }) => j.id === notification);
  expect(job.targets).toHaveLength(1);
  sql(
    `select api.worker_record_editorial_push('${notification}','${job.claimToken}','${device}','sent_to_pushservice'); select api.worker_finish_editorial_push('${notification}','${job.claimToken}');`,
  );
  expect(
    JSON.parse(
      sql(
        `select api.worker_claim_editorial_push(array['parent-a@example.invalid'])`,
      ),
    ),
  ).toEqual([]);
  const anonymous = await browser.newContext({
    ...info.project.use,
    baseURL: origin,
    ignoreHTTPSErrors: true,
  });
  const publicPage = await anonymous.newPage();
  await publicPage.goto(`/nieuws/${slug}`);
  await expect(
    publicPage.getByRole("heading", { name: `De poorten ontwaken ${suffix}` }),
  ).toBeVisible();
  await screenshot(publicPage, "website-nieuws", info.project.name);
  await publicPage.goto("/nieuws");
  await expect(publicPage.getByRole("heading", { name: `De poorten ontwaken ${suffix}` })).toBeVisible();
  await screenshot(publicPage, "website-feed", info.project.name);
  const parentPage = await parentContext.newPage();
  await parentPage.goto(
    `/omgeving/nieuws/${slug}?push=${notification}&device=${device}`,
  );
  await expect(
    parentPage.getByRole("heading", { name: `De poorten ontwaken ${suffix}` }),
  ).toBeVisible();
  await screenshot(parentPage, "oudernieuws", info.project.name);
  await expect
    .poll(() =>
      sql(
        `select status from app_private.portal_push_deliveries where notification_id='${notification}' and subscription_id='${device}'`,
      ),
    )
    .toBe("clicked");
  await parentPage.goto("/omgeving/nieuws/ouders");
  await expect(parentPage.getByRole("heading", { name: `De poorten ontwaken ${suffix}` })).toBeVisible();
  await screenshot(parentPage, "ouderfeed", info.project.name);
  const privateHeaders = await parentPage.request.get(
    `/omgeving/nieuws/ouders/${slug}`,
  );
  expect(privateHeaders.headers()["cache-control"]).toContain("no-store");
  const ownerContext = await browser.newContext({
    ...info.project.use,
    baseURL: origin,
    ignoreHTTPSErrors: true,
  });
  const owner = await authenticate(ownerContext, "owner@example.invalid");
  const excluded = await owner.schema("api").rpc("news_feed", {
    _event_slug: "duindorp-halloween-2026",
    _channel: "houses",
    _slug: slug,
  });
  expect(excluded.data).toEqual([]);
  const ownerPage = await ownerContext.newPage(); await ownerPage.goto("/omgeving/nieuws/huizen");
  await expect(ownerPage.getByRole("heading", { name: "Nieuws voor jullie poort" })).toBeVisible();
  await expect(ownerPage.getByRole("heading", { name: `De poorten ontwaken ${suffix}` })).toHaveCount(0);
  await screenshot(ownerPage, "huizenfeed", info.project.name);
  await page.getByRole("button", { name: "← Nieuwsoverzicht" }).click();
  await page
    .getByRole("textbox", { name: "Zoek nieuwsberichten" })
    .fill(suffix);
  const row = page.locator(".editorial-row").filter({ hasText: suffix });
  await row.getByRole("button", { name: "Voeg toe aan Nachtpost" }).click();
  await page.getByLabel("Interne campagnenaam").fill(`Nachtpost ${suffix}`);
  await page.getByLabel("Onderwerpregel").fill("De nacht komt dichterbij");
  await page
    .getByLabel("Titel", { exact: true })
    .fill("Een brief uit de nacht");
  await page
    .getByLabel(/Korte intro/)
    .fill("Welkom bij Nachtpost. Dit zijn de verhalen van onze wijk.");
  await page
    .getByRole("textbox", { name: "Berichtinhoud" })
    .fill("Samen maken we het mogelijk. Lees hieronder ons laatste nieuws.");
  await page.getByRole("button", { name: "Opslaan", exact: true }).click();
  await expect(
    page.getByText("Nachtpost opgeslagen en klaar voor controle."),
  ).toBeVisible();
  await page.getByRole("button", { name: "Voorbeeld", exact: true }).click();
  await expect(
    dialog.getByRole("heading", { name: "Nachtpostvoorbeeld" }),
  ).toBeVisible();
  await expect(dialog.locator("iframe")).toBeVisible();
  await screenshot(page, "nachtpost-preview", info.project.name);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Testmail naar mij" }).click();
  await expect(page.getByText(/Testmail staat in de wachtrij/)).toBeVisible();
  const cv = sql(
    `select v.id from app_private.content_versions v where v.content_kind='newsletter' and v.structured_content->>'internalName'='Nachtpost ${suffix}' order by version desc limit 1`,
  );
  // Local provider fixture: capture and acknowledge only this isolated test row.
  // The worker's signing/provider/receipt boundaries have separate integration tests.
  sql(
    `update app_private.email_outbox set status='accepted',provider_id='local-editorial-capture' where message_type='nachtpost' and payload->>'versionId'='${cv}' and payload->>'test'='true'`,
  );
  await expect(page.getByText("✓ Testmail geaccepteerd")).toBeVisible({
    timeout: 20000,
  });
  await page.getByRole("button", { name: "Verzending controleren" }).click();
  await expect(
    dialog.getByRole("heading", { name: "Definitief verzenden bevestigen" }),
  ).toBeVisible();
  await dialog.getByRole("button", { name: "Bevestigen en inplannen" }).click();
  await expect(dialog).not.toBeVisible();
  await expect(
    page.getByText(/Nachtpost ingepland. Inhoud en ontvangers/),
  ).toBeVisible();
  sql(
    "select api.worker_editorial_tick(true); select api.worker_editorial_tick(true);",
  );
  expect(
    Number(
      sql(
        `select count(*) from app_private.email_outbox where message_type='nachtpost' and payload->>'versionId'='${cv}' and payload->>'test' is distinct from 'true'`,
      ),
    ),
  ).toBe(1);
  const recipient = sql(
    `select id from app_private.newsletter_recipients where version_id='${cv}'`,
  );
  sql(`select api.worker_newsletter_unsubscribe('${recipient}');`);
  expect(
    sql(
      `select optional_updates_consent from app_private.participant_preferences where user_id='a0000000-0000-0000-0000-000000000001'`,
    ),
  ).toBe("f");
  await parentPage.goto("/omgeving/communicatie");
  await expect(
    parentPage.getByRole("heading", { name: "Nieuws op jouw manier." }),
  ).toBeVisible();
  await expect(
    parentPage.getByLabel("Nachtpost per e-mail", { exact: false }),
  ).not.toBeChecked();
  await screenshot(parentPage, "push-voorkeuren", info.project.name);
  await page.getByRole("button", { name: "← Nachtpostoverzicht" }).click();
  await screenshot(page, "redactiekamer", info.project.name);
  await anonymous.close();
  await parentContext.close();
  await ownerContext.close();
  expect(
    (
      await admin.schema("api").rpc("admin_editorial_snapshot", {
        _event_slug: "duindorp-halloween-2026",
      })
    ).error,
  ).toBeNull();
});

test("a draft-only editor has a usable cockpit without publication or send authority", async ({
  page,
  context,
}) => {
  const actor = "b0000000-0000-0000-0000-000000000001";
  requireLocalTogetherDatabase();
  sql(
    `insert into app_private.event_capabilities(event_id,user_id,capability) select id,'${actor}','content_manage' from app_private.events where slug='duindorp-halloween-2026' on conflict(event_id,user_id,capability) where revoked_at is null do nothing;`,
  );
  try {
    await authenticate(context, "parent-b@example.invalid");
    await page.goto("/admin");
    await expect(
      page.getByRole("heading", { name: "Redactiekamer", exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Nieuw bericht", exact: true })
      .click();
    await expect(
      page.getByRole("button", { name: "Opslaan", exact: true }),
    ).toBeEnabled();
    await expect(
      page.getByRole("button", { name: "Publicatie controleren" }),
    ).toBeDisabled();
    await expect(
      page.getByRole("tab", { name: "Nachtpost", exact: true }),
    ).toBeDisabled();
    expect(
      sql(
        `select count(*) from app_private.event_capabilities where user_id='${actor}' and revoked_at is null and capability in('content_publish','communications_send','event_admin')`,
      ),
    ).toBe("0");
  } finally {
    sql(
      `delete from app_private.event_capabilities where user_id='${actor}' and capability='content_manage';`,
    );
  }
});
