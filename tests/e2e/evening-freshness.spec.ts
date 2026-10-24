import { test, expect, type BrowserContext } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { sql } from '../../scripts/acceptance/together-fixtures.mjs';
import { prepareStartedLegacyFixtures } from '../../scripts/acceptance/started-fixtures.mjs';
import { prepareFixtureGuidance, selectOrganizationSection } from './helpers/guidance';
import { assertReadableLayout } from './helpers/layout';
const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, group = '23000000-0000-0000-0000-000000000001';
async function cookies(context: BrowserContext, session: unknown) { const name = `sb-${new URL(url!).hostname.split('.')[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`; await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: 'http://127.0.0.1:3100', sameSite: 'Lax' as const }))); }
test('connected cockpit retains each last good source through partial failures, stale time and out-of-order real responses', async ({ context, page }, testInfo) => {
    test.skip(!url || !key || testInfo.project.name !== 'desktop-chromium', 'Requires isolated real Auth');
    test.setTimeout(60000);
    prepareStartedLegacyFixtures();
    const leader = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } }), admin = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
    expect((await leader.auth.signInWithPassword({ email: 'leader-a@example.invalid', password: 'local-test-only' })).error).toBeNull();
    const login = await admin.auth.signInWithPassword({ email: 'admin@example.invalid', password: 'local-test-only' });
    expect(login.error).toBeNull();
    await prepareFixtureGuidance(admin);
    const snapshot = await leader.schema('api').rpc('group_snapshot', { _group_id: group }), roster = await leader.schema('api').rpc('group_roster', { _group_id: group });
    expect(snapshot.error).toBeNull();
    expect(roster.error).toBeNull();
    expect((await leader.schema('api').rpc('run_start', { _group_id: group, _present_registration_child_ids: roster.data.map((c: {
            registrationChildId: string;
        }) => c.registrationChildId), _expected_group_version: snapshot.data.group.version, _idempotency_key: randomUUID(), _request_hash: 'cockpit-source-proof' })).error).toBeNull();
    sql(`update app_private.walking_groups set display_name='Eerder werkelijk bevestigd testoverzicht' where id='${group}'`);
    await cookies(context, login.data.session);
    await page.goto('/admin');
    await selectOrganizationSection(page, 'Livecockpit');
    const freshness = page.getByRole('region', { name: 'Actualiteit van de gegevens' }), sources = freshness.locator('.evening-data-source'), cockpit = sources.filter({ hasText: 'Groepen en veiligheidssignalen' }), portals = sources.filter({ hasText: 'Poorten en capaciteit' }), refresh = freshness.getByRole('button', { name: 'Gegevens vernieuwen', exact: true });
    await expect(freshness).toContainText('Realtimekanaal verbonden');
    await expect(sources.filter({ hasText: 'Actueel bevestigd' })).toHaveCount(3);
    await expect(page.locator('.incident-row')).toContainText(['Eerder werkelijk bevestigd testoverzicht']);
    // Actual private broadcast delivery must not multiply three source RPCs
    // by every invalidation in the same burst.
    let burstRequests=0;
    const countBurst=(request:{url:()=>string})=>{if(/\/rest\/v1\/rpc\/(admin_dashboard|admin_evening_cockpit|admin_portal_operations_snapshot)$/.test(request.url()))burstRequests++;};
    page.on('request',countBurst);
    try {
        sql("select realtime.send(jsonb_build_object('source','isolated-refresh-burst','n',n),'snapshot_changed','admin-event:'||e.id::text,true) from app_private.events e cross join generate_series(1,20)n where e.slug='duindorp-halloween-2026'");
        await expect.poll(()=>burstRequests).toBeGreaterThanOrEqual(3);
        await page.waitForTimeout(1500);
        expect(burstRequests).toBeLessThanOrEqual(6);
        await expect(sources.filter({hasText:'Actueel bevestigd'})).toHaveCount(3);
    } finally {page.off('request',countBurst);}
    const lastGood = await cockpit.locator('small').first().innerText();
    await page.route('**/rest/v1/rpc/admin_evening_cockpit', route => route.abort('failed'), { times: 1 });
    await refresh.click();
    await expect(cockpit).toHaveClass(/is-error/);
    await expect(cockpit).toContainText('konden niet worden bijgewerkt');
    await expect(cockpit.locator('small').first()).toHaveText(lastGood);
    await expect(portals).toContainText('Actueel bevestigd');
    await expect(freshness).toContainText('Realtimekanaal verbonden');
    await expect(page.locator('.incident-row').filter({ hasText: 'Eerder werkelijk bevestigd testoverzicht' })).toHaveCount(1);
    await mkdir('docs/evening/screenshots', { recursive: true });
    for (const width of [360, 390, 430]) {
        await page.setViewportSize({ width, height: 844 });
        await freshness.scrollIntoViewIfNeeded();
        await assertReadableLayout(page);
        await page.screenshot({ path: `docs/evening/screenshots/cockpit-partial-error-${width}.png` });
    }
    await refresh.click();
    await expect(cockpit).toContainText('Actueel bevestigd');
    await page.route('**/rest/v1/rpc/admin_portal_operations_snapshot', route => route.abort('failed'), { times: 1 });
    await refresh.click();
    await expect(portals).toHaveClass(/is-error/);
    await expect(cockpit).toContainText('Actueel bevestigd');
    await expect(page.locator('.incident-row').filter({ hasText: 'Eerder werkelijk bevestigd testoverzicht' })).toHaveCount(1);
    await refresh.click();
    await expect(sources.filter({ hasText: 'Actueel bevestigd' })).toHaveCount(3);
    // Move only the browser presentation clock; server instants and RPCs stay real.
    await page.evaluate(() => Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' }));
    await page.clock.setFixedTime(new Date(Date.now() + 46000));
    await expect(sources.filter({ hasText: 'Gegevens zijn verouderd' })).toHaveCount(3, { timeout: 7000 });
    await expect(freshness).toContainText('Realtimekanaal verbonden');
    await page.evaluate(() => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' }); window.dispatchEvent(new Event('focus')); });
    await expect(sources.filter({ hasText: 'Actueel bevestigd' })).toHaveCount(3);
    let fetched!: () => void, release!: () => void;
    const oldFetched = new Promise<void>(resolve => { fetched = resolve; }), held = new Promise<void>(resolve => { release = resolve; });
    await page.route('**/rest/v1/rpc/admin_evening_cockpit', async (route) => { const old = await route.fetch(); expect(old.status()).toBe(200); expect(await old.text()).toContain('Eerder werkelijk bevestigd testoverzicht'); fetched(); await held; await route.fulfill({ response: old }); }, { times: 1 });
    try {
        await refresh.click();
        await oldFetched;
        sql(`update app_private.walking_groups set display_name='Nieuwere echte serverstand blijft zichtbaar' where id='${group}'`);
        await page.evaluate(() => window.dispatchEvent(new Event('focus')));
        await expect(page.locator('.incident-row').filter({ hasText: 'Nieuwere echte serverstand blijft zichtbaar' })).toHaveCount(1);
    }
    finally {
        release();
    }
    await expect(refresh).toBeEnabled();
    await expect(page.locator('.incident-row').filter({ hasText: 'Nieuwere echte serverstand blijft zichtbaar' })).toHaveCount(1);
    await expect(page.locator('.incident-row').filter({ hasText: 'Eerder werkelijk bevestigd testoverzicht' })).toHaveCount(0);
});
