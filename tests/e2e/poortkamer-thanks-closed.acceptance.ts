import { randomUUID } from "node:crypto";
import { expect, test, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { requireLocalTogetherDatabase, sql } from "../../scripts/acceptance/together-fixtures.mjs";
import { createPortalRoomFixture } from "../../scripts/acceptance/poortkamer-fixtures.mjs";
import { prepareFixtureGuidance } from "./helpers/guidance";

const eventSlug = "duindorp-halloween-2026";
const password = "isolated-thanks-http-only";
const standardMessage = "Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃";
const ownMessage = "Een eigen dankwoord voor jullie ontvangst. <script>Dit blijft gewone tekst.</script>";
type Actor = { id: string; email: string };
type Inbox = {
  portalId: string; total: number; unread: number; customMessageCount: number;
  aggregateOnlyCount: number; messages: Array<{ id: string; message: string; read: boolean }>;
  counters: { general: number; personal: number; beautiful: number; welcome: number; treats: number };
};
type LoggedIn = { context: BrowserContext; client: SupabaseClient };
const actors: Record<string, Actor> = {};
let portalId: string;
let privileged: SupabaseClient;
let publicUrl: string;
let publicKey: string;
let eventId: string;
const familyHomes: string[] = [];
const scalar = (query: string) => sql(query).split("\n").at(-1)!;

function requireLocal() {
  requireLocalTogetherDatabase();
  publicUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  publicKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  const secret = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!publicKey || !secret) throw new Error("REAL_LOCAL_AUTH_KEYS_REQUIRED_NO_MOCK_OR_SKIP");
  if (!['localhost', '127.0.0.1', '::1'].includes(new URL(publicUrl).hostname)) throw new Error("LOCAL_THANKS_HTTP_ONLY");
  privileged = createClient(publicUrl, secret, { auth: { persistSession: false, autoRefreshToken: false } });
  const preconditions = JSON.parse(scalar(`select jsonb_build_object(
    'fixture', exists(select 1 from app_private.events where slug='${eventSlug}' and settings->>'fixture'='true'),
    'closed', exists(select 1 from app_private.event_closures),
    'cronDisabled', current_setting('cron.launch_active_jobs',true)='off');`));
  expect(preconditions, "Use a fresh isolated synthetic fixture with Cron disabled; never an application database").toEqual({ fixture: true, closed: false, cronDisabled: true });
}

async function account(name: string) {
  const email = `thanks-http-${name}-${randomUUID()}@example.invalid`;
  const result = await privileged.auth.admin.createUser({ email, password, email_confirm: true });
  expect(result.error, `create local ${name}`).toBeNull();
  actors[name] = { id: result.data.user!.id, email };
}

async function login(browser: Browser, baseURL: string, name: string): Promise<LoggedIn> {
  const client = createClient(publicUrl, publicKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email: actors[name].email, password });
  expect(signed.error, `real Auth login for ${name}`).toBeNull();
  await prepareFixtureGuidance(client);
  const context = await browser.newContext({ baseURL, ignoreHTTPSErrors: true, serviceWorkers: "block" });
  const cookieName = `sb-${new URL(publicUrl).hostname.split('.')[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString('base64url')}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({
    name: value.length <= 3180 ? cookieName : `${cookieName}.${index}`,
    value: value.slice(index * 3180, (index + 1) * 3180), url: baseURL, sameSite: "Lax" as const, secure: true,
  })));
  return { context, client };
}

async function inbox(context: BrowserContext) {
  const response = await context.request.get(`/api/redesign/thanks-inbox?portalId=${portalId}`);
  expect(response.status(), "actual authorized Next HTTP inbox").toBe(200);
  expect(response.headers()['cache-control']).toContain('private');
  expect(response.headers()['cache-control']).toContain('no-store');
  return await response.json() as Inbox;
}

async function showClosedRoom(page: Page, admin = false) {
  await page.goto(admin ? `/admin/poortkamer/${portalId}` : `/mijn-huis?poort=${portalId}`);
  const main = page.locator('#poortkamer-content');
  await expect(main).toBeVisible();
  await expect(main.locator(':scope > :first-child')).toHaveAttribute('data-testid', 'house-thanks-first');
  await expect(page.getByRole('heading', { name: 'Bedankjes van deelnemers', exact: true })).toHaveCount(1);
  await expect(page.getByRole('heading', { name: 'Bedankt voor jullie poort', exact: true })).toHaveCount(0);
  await expect(main.getByText('3 bedankjes', { exact: false })).toBeVisible();
  await expect(main.getByText('Reacties tijdens de avond (1)', { exact: true })).toBeVisible();
  await expect(main.getByText(ownMessage, { exact: true })).toBeVisible();
  await expect(main.locator('script')).toHaveCount(0);
  await expect(page.locator('[data-state="open"][aria-pressed]')).toBeDisabled();
  await expect(page.locator('[data-state="paused"][aria-pressed]')).toBeDisabled();
  await expect(page.getByText('Gesloten · Avond afgesloten', { exact: true }).first()).toBeVisible();
  return main;
}

test.describe.serial('real local Auth → Next HTTP → PostgreSQL → full closed Poortkamer', () => {
  test.beforeAll(async ({ browser, baseURL }) => {
    requireLocal();
    await Promise.all(['organization', 'narrowOrganization', 'owner', 'viewer', 'foreign', 'revoked', 'suspended', 'general', 'personal'].map(account));
    portalId = createPortalRoomFixture(actors.owner.id).id;
    eventId = scalar(`select event_id from app_private.portals where id='${portalId}';`);
    const foreignEvent = randomUUID();
    sql(`begin;
      insert into app_private.event_capabilities(event_id,user_id,capability) values
        ('${eventId}','${actors.organization.id}','event_admin'),('${eventId}','${actors.organization.id}','portals_manage'),
        ('${eventId}','${actors.narrowOrganization.id}','event_admin');
      insert into app_private.events(id,slug,title,local_date,price_cents,settings) values('${foreignEvent}','thanks-http-${foreignEvent}','Synthetic foreign event',current_date,0,'{"fixture":true}');
      insert into app_private.event_capabilities(event_id,user_id,capability) values('${foreignEvent}','${actors.foreign.id}','event_admin');
      insert into app_private.portal_owners(portal_id,user_id,role,access_level) values
        ('${portalId}','${actors.viewer.id}','viewer','read'),('${portalId}','${actors.revoked.id}','crew','live'),('${portalId}','${actors.suspended.id}','crew','live');
      update app_private.portal_owners set revoked_at=now() where portal_id='${portalId}' and user_id='${actors.revoked.id}';
      update app_private.portal_owners set suspended_at=now() where portal_id='${portalId}' and user_id='${actors.suspended.id}';
      update app_private.portals set operation_status='open',pause_until=now()+interval '1 hour',pause_after_current=true where id='${portalId}';
      update app_private.events set phase='live',local_date=(clock_timestamp() at time zone 'Europe/Amsterdam')::date where id='${eventId}';
      commit;`);
    for (const name of ['general', 'personal']) {
      const home = randomUUID(), registration = randomUUID(), child = randomUUID(); familyHomes.push(home);
      sql(`begin;
        insert into app_private.households(id,label,primary_contact_user_id) values('${home}','Synthetic HTTP family','${actors[name].id}');
        insert into app_private.household_members(household_id,user_id,relation_role) values('${home}','${actors[name].id}','owner');
        insert into app_private.registrations(id,event_id,household_id,status,reference) values('${registration}','${eventId}','${home}','submitted','HTTP-${registration}');
        insert into app_private.children(id,household_id,first_name,age_at_event) values('${child}','${home}','Synthetisch',8);
        insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values('${eventId}','${registration}','${child}',0);
        commit;`);
    }
    sql(`insert into app_private.portal_thanks(event_id,household_id,portal_id,choice) values('${eventId}','${familyHomes[0]}','${portalId}','beautiful');`);
    expect(scalar(`select count(*) from app_private.portal_owners where user_id='${actors.organization.id}';`)).toBe('0');
    const org = await login(browser, baseURL!, 'organization');
    try {
      const response = await org.context.request.post('/api/event-evening/closure', {
        headers: { origin: baseURL! }, data: { eventSlug, action: 'confirm', subject: 'Synthetic closure', body: 'Only an isolated local fixture.', commandId: randomUUID() },
      });
      expect(response.status()).toBe(200); expect((await response.json()).data.closed).toBe(true);
    } finally { await org.context.close(); }
    for (const name of ['general', 'personal']) {
      const family = await login(browser, baseURL!, name);
      try {
        const response = await family.context.request.post('/api/redesign/thanks-closed', { headers: { origin: baseURL! }, data: {
          kind: name === 'general' ? 'all' : 'personal', ...(name === 'personal' ? { portalId, choice: 'welcome' } : {}),
          message: name === 'general' ? standardMessage : ownMessage, requestKey: randomUUID(),
        } });
        expect(response.status()).toBe(200); expect((await response.json()).ok).toBe(true);
        const fanout = await privileged.schema('api').rpc('worker_house_thanks_fanout', { _limit: 25 });
        expect(fanout.error).toBeNull();
        if (name === 'general') expect(scalar(`select count(*) from app_private.email_outbox where message_type='house_thanks_received';`)).toBe('0');
      } finally { await family.context.close(); }
    }
    // No provider/job endpoint is invoked. Only the deliberate custom message may
    // queue a logical owner notification; default and historical gestures do not.
    expect(scalar(`select count(*) from app_private.event_house_thanks_receipts where portal_id='${portalId}';`)).toBe('2');
    expect(scalar(`select count(*) from app_private.portal_thanks where portal_id='${portalId}';`)).toBe('1');
  });

  test('organization without portal membership reads real receipts and sees one combined card at the top', async ({ browser, baseURL }) => {
    // The existing arrivals chain requires portals_manage for a full room.
    // Independently prove the new thanks permission for event_admin alone, so
    // the realistic full-room role cannot conceal the original inbox failure.
    const narrow = await login(browser, baseURL!, 'narrowOrganization');
    try {
      expect(scalar(`select count(*) from app_private.portal_owners where user_id='${actors.narrowOrganization.id}';`)).toBe('0');
      expect((await inbox(narrow.context)).total).toBe(2);
      const legacy = await narrow.context.request.get(`/api/redesign/thanks?scope=house&portalId=${portalId}`);
      expect(legacy.status()).toBe(200); expect((await legacy.json()).thanks).toHaveLength(1);
    } finally { await narrow.context.close(); }
    const org = await login(browser, baseURL!, 'organization');
    try {
      const data = await inbox(org.context);
      expect(data).toMatchObject({ portalId, total: 2, aggregateOnlyCount: 1, customMessageCount: 1, counters: { general: 1, personal: 1, welcome: 1 } });
      expect(data.messages.map(message => message.message)).toEqual([ownMessage]);
      const historical = await org.context.request.get(`/api/redesign/thanks?scope=house&portalId=${portalId}`);
      expect(historical.status()).toBe(200); expect((await historical.json()).thanks).toHaveLength(1);
      const page = await org.context.newPage(); await showClosedRoom(page, true);
      await page.setViewportSize({ width: 360, height: 800 });
      await expect(page.getByTestId('house-thanks-first')).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    } finally { await org.context.close(); }
  });

  test('owner and viewer may read while foreign-event, revoked and suspended actors are denied', async ({ browser, baseURL }) => {
    for (const name of ['owner', 'viewer', 'foreign', 'revoked', 'suspended']) {
      const actor = await login(browser, baseURL!, name);
      try {
        if (name === 'owner' || name === 'viewer') {
          const data = await inbox(actor.context); expect(data.total).toBe(2); expect(data.messages[0].message).toBe(ownMessage);
        } else {
          const denied = await actor.context.request.get(`/api/redesign/thanks-inbox?portalId=${portalId}`);
          expect(denied.status(), name).toBe(403); expect(await denied.text()).not.toContain(ownMessage);
        }
      } finally { await actor.context.close(); }
    }
  });

  test('central closure blocks reopen and pause while thanks, certificate and read status remain available', async ({ browser, baseURL }) => {
    const owner = await login(browser, baseURL!, 'owner');
    try {
      const snapshot = await owner.client.schema('api').rpc('portal_room_snapshot', { _event_slug: eventSlug, _portal_id: portalId });
      expect(snapshot.error).toBeNull(); expect(snapshot.data).toMatchObject({ eventClosed: true, portal: { state: 'closed', pauseUntil: null } });
      expect(snapshot.data.closedAt).toEqual(expect.any(String));
      expect(scalar(`select operation_status from app_private.portals where id='${portalId}';`)).toBe('open');
      for (const state of ['open', 'paused']) {
        const result = await owner.client.schema('api').rpc('portal_room_update', { _portal_id: portalId, _operation: 'status', _key: randomUUID(), _payload: { state, minutes: state === 'paused' ? 5 : null, version: snapshot.data.portal.version, reason: 'Synthetic closed evening check' } });
        expect(result.error?.message).toMatch(/EVENING_ENDED|EVENT_CLOSED/);
      }
      const direct = await owner.client.schema('api').rpc('portal_set_operational_state', { _portal_id: portalId, _state: 'open', _expected_version: snapshot.data.portal.version, _reason: 'Synthetic direct closed evening check' });
      expect(direct.error?.message).toMatch(/EVENING_ENDED|EVENT_CLOSED/);
      const page = await owner.context.newPage(); const main = await showClosedRoom(page);
      let statusWrites = 0; page.on('request', request => { if (/\/rpc\/(portal_room_update|portal_set_operational_state)$/.test(new URL(request.url()).pathname)) statusWrites++; });
      await page.locator('[data-state="open"][aria-pressed]').evaluate((button: HTMLButtonElement) => button.click());
      await page.locator('[data-state="paused"][aria-pressed]').evaluate((button: HTMLButtonElement) => button.click());
      expect(statusWrites).toBe(0);
      const message = (await inbox(owner.context)).messages[0];
      const blockedRead = await owner.context.request.post('/api/redesign/thanks-read', { headers: { origin: 'https://foreign.invalid' }, data: { receiptId: message.id } });
      expect(blockedRead.status()).toBe(403);
      const read = await owner.context.request.post('/api/redesign/thanks-read', { headers: { origin: baseURL! }, data: { receiptId: message.id } });
      expect(read.status()).toBe(200); expect((await inbox(owner.context)).messages[0].read).toBe(true);
      await page.getByRole('button', { name: 'Meer', exact: true }).click();
      await page.getByRole('button', { name: 'Terugblik', exact: true }).click();
      await expect(main.getByRole('region', { name: 'Poortcertificaat' })).toBeVisible();
      await expect(main.getByRole('button', { name: 'Download PNG', exact: true })).toBeEnabled();
      await page.getByRole('button', { name: 'Nachtwacht', exact: true }).click();
      await expect(main.getByText('3 bedankjes', { exact: false })).toBeVisible();
      expect(scalar(`select count(*) from app_private.event_house_thanks_receipts where portal_id='${portalId}';`)).toBe('2');
      expect(scalar(`select count(*) from app_private.portal_thanks where portal_id='${portalId}';`)).toBe('1');
    } finally { await owner.context.close(); }
  });
});
