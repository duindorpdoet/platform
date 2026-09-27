import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import {
  createTogetherFixtures,
  requireLocalTogetherDatabase,
  sql,
} from "../../scripts/acceptance/together-fixtures.mjs";

const origin = "https://127.0.0.1:3443";
test.beforeAll(() => {
  requireLocalTogetherDatabase();
  expect(process.env.APP_ENVIRONMENT).toBe("staging");
  expect(process.env.POORTENBOEK_DEMO_ENABLED).toBe("true");
});
async function mutation(page: Page, action: string, payload: object = {}) {
  return page.evaluate(
    async ({ action, payload }) => {
      const response = await fetch(`/api/poortenboek/${action}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        cache: "no-store",
      });
      return { status: response.status, data: await response.json() };
    },
    { action, payload },
  );
}
async function login(page: Page, code: string, demo = false) {
  await page.goto(demo ? "/poortenboek/demo" : "/poortenboek/inloggen");
  await page
    .getByRole("textbox", { name: "Codeteken 1", exact: true })
    .fill(code.toLowerCase());
  await expect(
    page.getByRole("textbox", { name: "Codeteken 6", exact: true }),
  ).toHaveValue(code[5]);
  await page
    .getByRole("button", { name: "Open mijn Poortenboek", exact: true })
    .click();
  await expect(page.getByRole("heading", { name: /^Welkom, / })).toBeVisible();
}
async function dashboard(page: Page) {
  await page
    .getByRole("button", { name: "Open mijn boek", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "De wijk wordt wakker" }),
  ).toBeVisible();
}
async function screenshot(page: Page, name: string, project: string) {
  if (project !== "book-desktop" && project !== "book-samsung-chrome") return;
  mkdirSync("docs/screenshots/poortenboek", { recursive: true });
  await page.screenshot({
    path: `docs/screenshots/poortenboek/${project}-${name}.png`,
    fullPage: false,
  });
}
async function noOverflow(page: Page) {
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth + 1,
    ),
  ).toBe(true);
}
async function realFamily(context: BrowserContext) {
  const admin = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SECRET_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const email = `poortenboek-${randomUUID()}@example.invalid`;
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: "local-poortenboek-only",
    email_confirm: true,
  });
  expect(error).toBeNull();
  const [party] = createTogetherFixtures(1, 1, 2);
  const children = JSON.parse(
    sql(`update app_private.household_members set user_id='${data.user!.id}' where household_id=(select household_id from app_private.registrations where id='${party.members[0].id}');
    update app_private.households set primary_contact_user_id='${data.user!.id}' where id=(select household_id from app_private.registrations where id='${party.members[0].id}');
    with named as (select child_id,row_number() over(order by child_id) n from app_private.registration_children where registration_id='${party.members[0].id}')
      update app_private.children c set first_name=case when named.n=1 then 'Mila' else 'Sem' end from named where c.id=named.child_id;
    select jsonb_agg(jsonb_build_object('id',c.id,'firstName',c.first_name) order by c.first_name) from app_private.children c join app_private.registration_children rc on rc.child_id=c.id where rc.registration_id='${party.members[0].id}';`),
  ) as Array<{ id: string; firstName: string }>;
  const client = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const signed = await client.auth.signInWithPassword({
    email,
    password: "local-poortenboek-only",
  });
  expect(signed.error).toBeNull();
  // Auth and PostgREST run in separate local containers. Wait until the newly
  // issued fixture JWT is accepted before the browser's one-shot initial load.
  await expect.poll(async () => {
    const { error } = await client.schema("api").rpc("registration_snapshot", {
      _event_slug: "duindorp-halloween-2026",
    });
    return error?.code ?? null;
  }, { timeout: 10_000 }).toBeNull();
  const value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
  const name = `sb-${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).hostname.split(".")[0]}-auth-token`;
  const chunks =
    value.length <= 3180
      ? [{ name, value }]
      : Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
          name: `${name}.${i}`,
          value: value.slice(i * 3180, (i + 1) * 3180),
        }));
  await context.addCookies(
    chunks.map((chunk) => ({
      ...chunk,
      url: origin,
      sameSite: "Lax" as const,
      secure: true,
    })),
  );
  return children;
}

test("staging presentation: V2 identity, favourites, banner, practice and passport", async ({
  page,
  context,
}, info) => {
  const countBefore = sql(
    "select count(*) from app_private.poortenboek_sessions;",
  );
  const response = await page.goto("/poortenboek/demo");
  expect(response?.headers()["cache-control"]).toContain("no-store");
  expect(response?.headers()["x-robots-tag"]).toBe("noindex, nofollow");
  await screenshot(page, "login", info.project.name);
  await login(page, "DEMO26", true);
  await screenshot(page, "welkom", info.project.name);
  const cookie = (await context.cookies()).find(
    (value) => value.name === "__Host-poortenboek-demo",
  );
  expect(cookie?.secure).toBe(true);
  expect(cookie?.httpOnly).toBe(true);
  expect(cookie?.sameSite).toBe("Lax");
  await dashboard(page);
  await noOverflow(page);
  await screenshot(page, "nu", info.project.name);
  await expect(page.getByRole("heading", { name: "Open eerst de oefenpoort" })).toBeVisible();
  await page.goto("/poortenboek/team");
  await expect(
    page.getByRole("heading", { name: "Kies jullie favoriete namen" }),
  ).toBeVisible();
  await expect(page.locator(".pb-companions li")).toHaveCount(5);
  for (const label of [
    "De Nachtlopers",
    "De Poortwachters",
    "De Schaduwzoekers",
  ])
    await page.getByRole("button", { name: label, exact: true }).click();
  await expect(page.locator(".pb-own-choices li").first()).toContainText(
    "De Nachtlopers",
  );
  await page.getByRole("button", { name: "Verstuur mijn favorieten" }).click();
  await expect(
    page.getByText("Jouw keuze is bewaard.", { exact: false }),
  ).toBeVisible();
  await page.locator(".pb-demo-panel summary").click();
  await page
    .getByRole("button", { name: "Drie van de vijf gestemd", exact: true })
    .click();
  await expect(
    page.getByText("3 van de 5 reisgenootjes hebben gekozen", { exact: true }).first(),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Geef het vaandel jouw vonk" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Kies wie jij bent in de nacht" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Laat de oefenpoort ontwaken" })).toBeVisible();
  await page
    .getByRole("button", { name: "Allemaal gestemd", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: /Jullie zijn.*De Nachtlopers/ }),
  ).toBeVisible();
  await screenshot(page, "team", info.project.name);
  await page.goto("/poortenboek/boek");
  await noOverflow(page);
  await expect(page.locator(".pb-book-cover")).toContainText("Mila");
  await expect(page.locator(".pb-book-cover")).toContainText("De Nachtlopers");
  await screenshot(page, "boek", info.project.name);
  await page.goto("/poortenboek/ik");
  await expect(
    page.getByRole("button", { name: "Geluid uit", exact: true }),
  ).toHaveAttribute("aria-pressed", "false");
  await page
    .getByRole("button", { name: "Poortenboek sluiten", exact: true })
    .click();
  await expect(page).toHaveURL(/\/poortenboek\/inloggen$/);
  expect(sql("select count(*) from app_private.poortenboek_sessions;")).toBe(
    countBefore,
  );
});

test("parent opens each child directly and switches safely on one shared device", async ({ page, context }) => {
  const children = await realFamily(context);
  const parentCookies = (await context.cookies()).filter((cookie) => cookie.name.startsWith("sb-"));
  const childIds = children.map((child) => `'${child.id}'`).join(",");
  const codeCount = () => Number(sql(`select count(*) from app_private.poortenboek_codes where child_id in (${childIds});`));
  expect(codeCount()).toBe(0);
  let opens = 0;
  page.on("request", (request) => {
    if (request.url().endsWith("/api/poortenboek/parent") && request.method() === "POST" && request.postDataJSON()?.action === "open") opens++;
  });
  async function openChild(name: string) {
    await page.goto("/mijn-inschrijving");
    const card = page.getByRole("article", { name: `Poortenboek van ${name}`, exact: true });
    await expect(card).toBeVisible();
    await expect(card.locator("output")).toHaveCount(0);
    const response = page.waitForResponse((response) => response.url().endsWith("/api/poortenboek/parent") && response.request().method() === "POST");
    await card.getByRole("button", { name: `Open Poortenboek van ${name}`, exact: true }).click();
    expect((await response).status()).toBe(200);
    await expect(page.getByRole("heading", { name: `Welkom, ${name}!`, exact: true })).toBeVisible();
    await dashboard(page);
    await expect(page.getByText(`Welkom terug, ${name}`, { exact: true })).toBeVisible();
  }
  await openChild("Mila");
  const firstCookie = (await context.cookies()).find((cookie) => cookie.name === "__Host-poortenboek-session")!;
  expect(firstCookie.secure && firstCookie.httpOnly).toBe(true);
  expect(firstCookie.expires - Date.now() / 1000).toBeGreaterThan(43_170);
  expect(firstCookie.expires - Date.now() / 1000).toBeLessThanOrEqual(43_200);
  expect(codeCount()).toBe(1);
  const saved = page.waitForResponse((response) => response.url().endsWith("/api/poortenboek/checklist"));
  await page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true }).check();
  expect((await saved).status()).toBe(200);

  const [foreign] = createTogetherFixtures(1, 1, 1);
  const foreignChild = sql(`select child_id from app_private.registration_children where registration_id='${foreign.members[0].id}';`).trim();
  expect((await mutation(page, "parent", { action: "open", childId: foreignChild })).status).toBe(401);
  expect((await context.cookies()).find((cookie) => cookie.name === firstCookie.name)?.value).toBe(firstCookie.value);

  await openChild("Sem");
  await expect(page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true })).not.toBeChecked();
  const hash = createHash("sha256").update(firstCookie.value).digest("hex");
  expect(sql(`select revoked_at is not null from app_private.poortenboek_sessions where token_hash='${hash}';`)).toBe("t");
  await openChild("Mila");
  await expect(page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true })).toBeChecked();
  expect(codeCount()).toBe(2);
  expect(opens).toBe(4); // Three buttons plus the explicitly rejected foreign-child request.
  expect(Number(sql(`select count(*) from app_private.audit_events where action='poortenboek.parent_login' and resource_id in (${childIds});`))).toBe(3);
  expect((await context.cookies()).filter((cookie) => cookie.name.startsWith("sb-")).map(({ name, value }) => ({ name, value }))).toEqual(parentCookies.map(({ name, value }) => ({ name, value })));
  await page.goto("/poortenboek/ik");
  await page.getByRole("button", { name: "Poortenboek sluiten", exact: true }).click();
  await expect(page).toHaveURL(/\/poortenboek\/inloggen$/);
  await page.goto("/mijn-inschrijving");
  await expect(page.getByRole("button", { name: "Open Poortenboek van Sem", exact: true })).toBeVisible();
});

test("real parent codes, independent child sessions, renewal and account switch", async ({
  page,
  context,
}, info) => {
  const children = await realFamily(context);
  await page.goto("/mijn-inschrijving");
  const card = page.getByRole("article", {
    name: "Poortenboek van Mila",
    exact: true,
  });
  await expect(card).toBeVisible();
  await card
    .getByRole("button", { name: "Code bekijken", exact: true })
    .click();
  const code = await page
    .getByLabel("Poortenboekcode van Mila", { exact: true })
    .textContent();
  expect(code).toMatch(/^[A-HJ-NP-Z2-9]{6}$/);
  await screenshot(page, "ouderbeheer", info.project.name);
  await login(page, code!);
  await dashboard(page);
  const childCookie = (await context.cookies()).find(
    (cookie) => cookie.name === "__Host-poortenboek-session",
  )!;
  expect(childCookie.secure && childCookie.httpOnly).toBe(true);
  expect(childCookie.expires - Date.now() / 1000).toBeGreaterThan(43_180);
  expect(childCookie.expires - Date.now() / 1000).toBeLessThanOrEqual(43_200);
  const childOnly = await context
    .browser()!
    .newContext({ ignoreHTTPSErrors: true });
  try {
    await childOnly.addCookies([childCookie]);
    const childPage = await childOnly.newPage();
    await childPage.goto(`${origin}/mijn-inschrijving`);
    await expect(childPage).toHaveURL(/\/inloggen\?next=/);
    await childPage.goto(`${origin}/admin`);
    await expect(childPage).toHaveURL(/\/inloggen\?next=/);
  } finally {
    await childOnly.close();
  }
  await page.bringToFront();
  await page
    .getByRole("checkbox", { name: "Snoeptas klaar", exact: true })
    .check();
  await page.reload();
  await expect(
    page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true }),
  ).toBeChecked();
  expect(
    (await context.cookies()).find((cookie) => cookie.name === childCookie.name)
      ?.expires,
  ).toBe(childCookie.expires);
  expect(
    (await context.cookies()).some((cookie) => cookie.name.startsWith("sb-")),
  ).toBe(true);
  await page.goto("/mijn-inschrijving");
  await expect(card).toBeVisible();
  await card
    .getByRole("button", { name: "Code vernieuwen", exact: true })
    .click();
  await card.getByRole("button", { name: "Annuleren", exact: true }).click();
  expect(
    (
      await mutation(page, "parent", {
        action: "view",
        childId: children[0].id,
      })
    ).data.code,
  ).toBe(code);
  await card
    .getByRole("button", { name: "Code vernieuwen", exact: true })
    .click();
  await card
    .getByRole("button", { name: "Ja, bevestigen", exact: true })
    .click();
  const fresh = page.getByLabel("Poortenboekcode van Mila", { exact: true });
  await expect(fresh).not.toHaveText(code!);
  await page.goto("/poortenboek");
  await expect(page).toHaveURL(/\/poortenboek\/inloggen$/);
  expect((await mutation(page, "login", { code })).status).toBe(400);
  const semCode = (
    await mutation(page, "parent", { action: "view", childId: children[1].id })
  ).data.code;
  await login(page, semCode);
  await dashboard(page);
  await expect(
    page.getByText("Welkom terug, Sem", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true }),
  ).not.toBeChecked();
  await page.goto("/poortenboek/ik");
  await page
    .getByRole("button", { name: "Poortenboek sluiten", exact: true })
    .click();
  await expect(page).toHaveURL(/inloggen$/);
  expect(
    (await context.cookies()).some((cookie) => cookie.name.startsWith("sb-")),
  ).toBe(true);
});

test("private PWA responses, offline neutral view and no stored child data", async ({
  page,
  context,
}) => {
  await login(page, "DEMO26", true);
  await dashboard(page);
  await page.evaluate(async () => {
    await navigator.serviceWorker.register("/sw.js");
    await navigator.serviceWorker.ready;
  });
  await page.reload();
  const response = await page.request.get("/api/poortenboek/snapshot");
  expect(response.headers()["cache-control"]).toBe(
    "private, no-store, max-age=0",
  );
  await page.request.get("/poortenboek/team?_rsc=private-test", {
    headers: { RSC: "1" },
  });
  const cached = await page.evaluate(async () =>
    (
      await Promise.all(
        (await caches.keys()).map(async (key) =>
          (await (await caches.open(key)).keys()).map((request) => request.url),
        ),
      )
    ).flat(),
  );
  expect(cached.some((url) => /\/poortenboek|\/api\/|_rsc=/.test(url))).toBe(
    false,
  );
  expect(
    await page.evaluate(() =>
      JSON.stringify({ ...localStorage, ...sessionStorage }),
    ),
  ).not.toMatch(/Mila|DEMO26|poortenboek-session/);
  // Hold a real response after the network has returned it. Losing connectivity
  // or changing visibility must invalidate it before React can display it.
  await page.evaluate(() => {
    const original = window.fetch.bind(window);
    window.fetch = async (...args) => {
      const response = await original(...args);
      if (String(args[0]).endsWith("/api/poortenboek/checklist")) {
        const buffered = new Response(await response.arrayBuffer(), {
          status: response.status,
          headers: response.headers,
        });
        await new Promise<void>((resolve) => {
          Object.assign(window, { releaseChildResponse: resolve });
        });
        Object.assign(window, { childResponseReleased: true });
        return buffered;
      }
      return response;
    };
  });
  await page
    .getByRole("checkbox", { name: "Snoeptas klaar", exact: true })
    .check();
  await page.waitForFunction(() => "releaseChildResponse" in window);
  await context.setOffline(true);
  await expect(
    page.getByRole("heading", { name: "De verbinding rust even" }),
  ).toBeVisible();
  await expect(
    page.getByText("Welkom terug, Mila", { exact: true }),
  ).toHaveCount(0);
  await page.evaluate(() => {
    (
      window as unknown as { releaseChildResponse: () => void }
    ).releaseChildResponse();
  });
  await page.waitForFunction(() => "childResponseReleased" in window);
  await page.evaluate(
    () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
      ),
  );
  await expect(
    page.getByRole("heading", { name: "De verbinding rust even" }),
  ).toBeVisible();
  await expect(
    page.getByText("Welkom terug, Mila", { exact: true }),
  ).toHaveCount(0);
  await context.setOffline(false);
  await expect(
    page.getByRole("heading", { name: "De wijk wordt wakker" }),
  ).toBeVisible();
  await noOverflow(page);
});
