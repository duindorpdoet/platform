import { test, expect, type BrowserContext, type Locator } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { sql } from '../../scripts/acceptance/together-fixtures.mjs';
import { prepareStartedLegacyFixtures } from '../../scripts/acceptance/started-fixtures.mjs';
import { prepareFixtureGuidance, selectOrganizationSection } from './helpers/guidance';
import { assertReadableLayout } from './helpers/layout';
const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, event = 'duindorp-halloween-2026', group = '23000000-0000-0000-0000-000000000001';
async function actor(email: string) { const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } }); const signed = await client.auth.signInWithPassword({ email, password: 'local-test-only' }); expect(signed.error).toBeNull(); await prepareFixtureGuidance(client); return { client, session: signed.data.session }; }
async function browserLogin(context: BrowserContext, session: unknown) { const name = `sb-${new URL(url!).hostname.split('.')[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`; await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: 'http://127.0.0.1:3100', sameSite: 'Lax' as const }))); }
async function fitsDialog(dialog: Locator) {
    const overflow = await dialog.evaluate(root => { const bounds = root.getBoundingClientRect(); return [...root.querySelectorAll<HTMLElement>('button,input,textarea')].filter(element => element.checkVisibility()).filter(element => { const box = element.getBoundingClientRect(); return box.left < bounds.left - 1 || box.right > bounds.right + 1 || element.scrollWidth > element.clientWidth + 1; }).map(element => element.textContent?.trim().slice(0, 60) || element.getAttribute('aria-label')); });
    expect(overflow, 'dialog controls must fit its width, including inside vertical scroll areas').toEqual([]);
}
test.beforeEach(() => test.skip(!url || !key, 'Requires isolated real Auth and database'));
test('mobile evening choices use real capacity, recover lost commits and preserve arrivals through fixed waiting and safe withdrawal', async ({ page, context }) => {
    test.setTimeout(120000);
    prepareStartedLegacyFixtures();
    const { client: leader } = await actor('leader-a@example.invalid'), admin = await actor('admin@example.invalid'), owner = await actor('owner@example.invalid');
    async function rpc(client: typeof leader, name: string, args: Record<string, unknown>) { const result = await client.schema('api').rpc(name, args); expect(result.error, `${name}: ${result.error?.message}`).toBeNull(); return result.data; }
    const snapshot = () => rpc(leader, 'group_snapshot', { _group_id: group });
    sql(`update app_private.walking_groups set display_name='Een lange fictieve groepsnaam voor een buitengewoon drukke mobiele avond' where id='${group}';update app_private.portals set name='Eenheelerglangefictievepoortnaamzonderonderbrekingenvoordemobieletoets aan het plein' where id='12000000-0000-0000-0000-000000000002';`);
    let current = await snapshot();
    const roster = await rpc(leader, 'group_roster', { _group_id: group });
    await rpc(leader, 'run_start', { _group_id: group, _present_registration_child_ids: roster.map((child: {
            registrationChildId: string;
        }) => child.registrationChildId), _expected_group_version: current.group.version, _idempotency_key: randomUUID(), _request_hash: 'real-mobile-evening-start' });
    current = await snapshot();
    const originalStop = current.run.currentStop.id;
    await browserLogin(context, admin.session);
    await page.setViewportSize({ width: 360, height: 844 });
    await page.goto('/admin');
    await selectOrganizationSection(page, 'Livecockpit');
    const row = page.locator('.incident-row').filter({ has: page.locator('strong').filter({ hasText: 'Een lange fictieve groepsnaam' }) });
    await expect(row).toHaveCount(1);
    const ordinary = row.getByRole('button', { name: 'Andere gewone poort', exact: true }), dialog = page.getByRole('dialog');
    await page.route('**/rest/v1/rpc/admin_route_command_options', route => route.abort('failed'), { times: 1 });
    await ordinary.click();
    await expect(dialog.getByRole('alert')).toContainText('niet worden opgehaald');
    await expect(dialog.getByRole('button', { name: 'Keuze bevestigen' })).toBeDisabled();
    await dialog.getByRole('button', { name: 'Actuele mogelijkheden vernieuwen' }).click();
    await expect(dialog.getByRole('button', { name: /P-02/ })).toBeVisible();
    await mkdir('docs/evening/screenshots', { recursive: true });
    for (const width of [360, 390, 430]) {
        await page.setViewportSize({ width, height: 844 });
        await dialog.getByRole('searchbox').fill('P-02');
        await dialog.getByRole('button', { name: /P-02/ }).click();
        await dialog.getByRole('textbox', { name: 'Reden', exact: true }).fill('De organisatie kiest een passend bereikbaar volgend huis met actuele ontvangstcapaciteit.');
        await dialog.getByRole('checkbox').check();
        const confirm = dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true });
        await confirm.scrollIntoViewIfNeeded();
        await expect(confirm).toBeInViewport();
        await expect(confirm).toBeEnabled();
        await fitsDialog(dialog);
        await expect(dialog.getByRole("button", { name: "Close", exact: true })).toBeInViewport();
        await assertReadableLayout(page);
        await page.screenshot({ path: `docs/evening/screenshots/route-choice-${width}.png` });
    }
    const portalVersion = Number(sql("select version from app_private.portals where id='12000000-0000-0000-0000-000000000002'"));
    await rpc(owner.client, 'portal_set_operational_state', { _portal_id: '12000000-0000-0000-0000-000000000002', _state: 'closed', _expected_version: portalVersion, _reason: 'Het gekozen huis sluit nadat de echte mobiele dialoog is geopend' });
    await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
    await expect(dialog.getByRole('alert')).toContainText('Kies en bevestig opnieuw');
    expect((await snapshot()).run.currentStop.id).toBe(originalStop);
    await expect(dialog.getByRole('checkbox')).not.toBeChecked();
    await dialog.getByRole('searchbox').fill('P-02');
    await expect(dialog.getByRole('button', { name: /P-02/ })).toBeDisabled();
    await expect(dialog).toContainText('Gesloten');
    await dialog.getByRole('searchbox').fill('P-03');
    await dialog.getByRole('button', { name: /P-03/ }).click();
    await dialog.getByRole('checkbox').check();
    const redirects: unknown[] = [];
    page.on('request', request => { if (request.url().endsWith('/rpc/admin_redirect_group'))
        redirects.push(request.postDataJSON()); });
    let redirectCommitted!: () => void, releaseRedirect!: () => void;
    const committedRedirect = new Promise<void>(resolve => { redirectCommitted = resolve; }), heldRedirect = new Promise<void>(resolve => { releaseRedirect = resolve; });
    await page.route('**/rest/v1/rpc/admin_redirect_group', async (route) => { const committed = await route.fetch(); expect(committed.status()).toBe(200); redirectCommitted(); await heldRedirect; await route.abort('failed'); }, { times: 1 });
    try {
        await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
        await committedRedirect;
        await expect(dialog.getByRole('textbox', { name: 'Reden', exact: true })).toBeDisabled();
        await expect(dialog.getByRole('checkbox')).toBeDisabled();
        await expect(dialog.getByRole('searchbox')).toBeDisabled();
        await page.keyboard.press('Escape');
        await expect(dialog).toBeVisible();
        await expect(dialog.getByRole('button', { name: 'Close', exact: true })).toHaveCount(0);
        await page.keyboard.press('Tab');
        expect(await dialog.evaluate(root => root.contains(document.activeElement))).toBe(true);
    }
    finally {
        releaseRedirect();
    }
    await expect(dialog.getByRole('alert')).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true })).toBeEnabled();
    current = await snapshot();
    expect(current.run.currentStop.portal.id).toBe('12000000-0000-0000-0000-000000000003');
    const redirectedStop = current.run.currentStop.id;
    await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    expect(redirects).toHaveLength(2);
    expect(redirects[0]).toEqual(redirects[1]);
    expect((await snapshot()).run.currentStop.id).toBe(redirectedStop);
    expect(sql(`select count(*) from app_private.audit_events where action='group.destination_redirected' and resource_id='${current.run.id}'`)).toBe('1');
    await expect(ordinary).toBeFocused();
    current = await snapshot();
    await rpc(leader, 'run_arrive_and_advance', { _run_id: current.run.id, _expected_stop_id: current.run.currentStop.id, _expected_run_version: current.run.version, _credential: 'TEST-PORTAL-03-TOKEN', _participant_choices: Object.fromEntries(current.run.participants.map((child: {
            id: string;
        }) => [child.id, 'skipped'])), _idempotency_key: randomUUID() });
    const retained = () => sql(`select jsonb_build_object('arrivals',(select md5(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id)::text) from app_private.run_stop_arrivals a),'seals',(select md5(jsonb_agg(to_jsonb(s) order by s.run_stop_id,s.child_id)::text) from app_private.poortenboek_passport_seals s),'payments',(select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p),'credentials',(select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c))`);
    const before = retained();
    current = await snapshot();
    const appointment = current.run.finaleReservation;
    await row.getByRole('button', { name: 'Nu naar laatste poort', exact: true }).click();
    await expect(dialog.getByRole('checkbox')).toBeEnabled();
    await expect(dialog).toContainText('Gereserveerd om');
    await dialog.getByRole('textbox', { name: 'Reden', exact: true }).fill('De organisatie kiest bewust voor het reeds gereserveerde finalemoment.');
    await dialog.getByRole('checkbox').check();
    await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    current = await snapshot();
    expect(current.run.currentStop).toBeNull();
    expect(current.run.waitingReason).toBe('finale_window');
    expect(current.run.finaleReservation).toEqual(appointment);
    const worker = createClient(url!, process.env.SUPABASE_SECRET_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
    await rpc(worker, 'worker_dispatch_due_groups', { _event_slug: event, _batch_size: 50 });
    expect((await snapshot()).run.currentStop).toBeNull();
    expect(retained()).toBe(before);
    await row.getByRole('button', { name: 'Veilig afmelden', exact: true }).click();
    const options = await rpc(admin.client, 'admin_route_command_options', { _run_id: current.run.id });
    const adult = options.adults.find((adult: {
        userId: string;
    }) => adult.userId === 'a0000000-0000-0000-0000-000000000001');
    expect(adult).toBeTruthy();
    await expect(dialog.getByRole('searchbox')).toBeVisible();
    await dialog.getByRole('searchbox').fill('Een niet geregistreerde persoon');
    await expect(dialog.getByRole('checkbox')).toBeDisabled();
    await dialog.getByRole('searchbox').fill(adult.label);
    await dialog.getByRole('button', { name: adult.label, exact: true }).click();
    await dialog.getByRole('textbox', { name: 'Reden', exact: true }).fill('De organisatie heeft de echte geregistreerde ouder gesproken en draagt de groep veilig over.');
    await dialog.getByRole('checkbox').check();
    for (const width of [360, 390, 430]) {
        await page.setViewportSize({ width, height: 844 });
        await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).scrollIntoViewIfNeeded();
        await fitsDialog(dialog);
        await page.screenshot({ path: `docs/evening/screenshots/safe-withdraw-${width}.png` });
    }
    const departures: unknown[] = [];
    page.on('request', request => { if (request.url().endsWith('/rpc/admin_safe_withdraw_group'))
        departures.push(request.postDataJSON()); });
    await page.route('**/rest/v1/rpc/admin_safe_withdraw_group', async (route) => { const committed = await route.fetch(); expect(committed.status()).toBe(200); await route.abort('failed'); }, { times: 1 });
    await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
    await expect(dialog.getByRole('alert')).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true })).toBeEnabled();
    expect((await snapshot()).run.status).toBe('stopped');
    await dialog.getByRole('button', { name: 'Keuze bevestigen', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    expect(departures).toHaveLength(2);
    expect(departures[0]).toEqual(departures[1]);
    expect(sql(`select count(*) from app_private.group_safe_departures where run_id='${current.run.id}'`)).toBe('1');
    expect(retained()).toBe(before);
    await expect(row).toContainText('Afgemeld');
    await expect(row.getByRole('button', { name: 'Veilig afmelden', exact: true })).toHaveCount(0);
    await expect(page.locator('#admin-content')).toBeFocused();
    await assertReadableLayout(page);
});
