import { test, expect, type BrowserContext } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { requireLocalTogetherDatabase, sql } from '../../scripts/acceptance/together-fixtures.mjs';
import { prepareStartedLegacyFixtures } from '../../scripts/acceptance/started-fixtures.mjs';
import { prepareFixtureGuidance } from './helpers/guidance';
const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, group = '23000000-0000-0000-0000-000000000001';
async function cookies(context: BrowserContext, session: unknown) { const name = `sb-${new URL(url!).hostname.split('.')[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`; await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({ name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: 'http://127.0.0.1:3100', sameSite: 'Lax' as const }))); }
test('an online phone survives a real isolated database outage and a lost committed arrival response without another online event', async ({ context, page }, testInfo) => {
    test.skip(!url || !key || testInfo.project.name !== 'desktop-chromium', 'Requires a fresh isolated local database');
    test.setTimeout(90000);
    const container = requireLocalTogetherDatabase();
    expect(container).toMatch(/^supabase_db_(duindorphalloween|duindorp-ops-codex-\d{8})$/);
    expect(sql('select count(*) from app_private.group_runs')).toBe('0');
    prepareStartedLegacyFixtures();
    const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } }), login = await client.auth.signInWithPassword({ email: 'leader-a@example.invalid', password: 'local-test-only' });
    expect(login.error).toBeNull();
    await prepareFixtureGuidance(client);
    async function rpc(name: string, args: Record<string, unknown>) { const result = await client.schema('api').rpc(name, args); expect(result.error).toBeNull(); return result.data; }
    const before = await rpc('group_snapshot', { _group_id: group }), roster = await rpc('group_roster', { _group_id: group });
    await rpc('run_start', { _group_id: group, _present_registration_child_ids: roster.map((child: {
            registrationChildId: string;
        }) => child.registrationChildId), _expected_group_version: before.group.version, _idempotency_key: randomUUID(), _request_hash: 'actual-local-database-outage' });
    const initial = await rpc('group_snapshot', { _group_id: group });
    await cookies(context, login.data.session);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/mijn-groep');
    await expect(page.getByRole('heading', { name: 'Testpoort 01', exact: true })).toBeVisible();
    await page.getByLabel('Korte poortcode').fill('TEST-01');
    await page.getByRole('button', { name: 'Code controleren', exact: true }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toContainText('Jullie zijn bij de juiste poort');
    await dialog.getByRole('checkbox').uncheck();
    const commands: unknown[] = [];
    page.on('request', request => { if (request.url().endsWith('/rpc/run_arrive_and_advance'))
        commands.push(request.postDataJSON()); });
    await page.route('**/rest/v1/rpc/run_arrive_and_advance', async (route) => { const committed = await route.fetch(); expect(committed.status()).toBe(200); await route.abort('failed'); }, { times: 1 });
    let paused = false;
    const resume = () => { if (paused) {
        execFileSync('docker', ['unpause', container], { stdio: 'ignore' });
        paused = false;
    } };
    const failsafe = setTimeout(resume, 16000);
    try {
        execFileSync('docker', ['pause', container], { stdio: 'ignore' });
        paused = true;
        const began = Date.now();
        await dialog.getByRole('button', { name: 'Aankomst bevestigen & volgende poort', exact: true }).click();
        await expect(page.locator('.arrival-sync-notice.is-pending')).toContainText('Aankomst bewaard op deze telefoon');
        expect(await page.evaluate(() => navigator.onLine)).toBe(true);
        await expect(page.getByRole('heading', { name: 'Testpoort 01', exact: true })).toBeVisible();
        await expect(page.getByRole('heading', { name: 'Testpoort 02', exact: true })).toHaveCount(0);
        await expect.poll(() => Date.now() - began, { timeout: 12000 }).toBeGreaterThanOrEqual(9000);
    }
    finally {
        clearTimeout(failsafe);
        resume();
    }
    // No synthetic online/focus event or manual retry: the durable timer must recover.
    await expect(page.locator('.arrival-sync-notice.is-confirmed')).toContainText('Testpoort 01 is bevestigd', { timeout: 40000 });
    await expect(page.getByRole('heading', { name: 'Testpoort 02', exact: true })).toBeVisible();
    expect(await page.evaluate(() => navigator.onLine)).toBe(true);
    expect(commands).toHaveLength(2);
    expect(commands[0]).toEqual(commands[1]);
    const after = await rpc('group_snapshot', { _group_id: group });
    expect(after.run.history).toHaveLength(1);
    expect(after.run.currentStop.portal.id).toBe('12000000-0000-0000-0000-000000000002');
    expect(sql(`select count(*) from app_private.run_stop_arrivals where run_id='${initial.run.id}'`)).toBe('1');
    expect(sql(`select count(*) from app_private.poortenboek_passport_seals where run_id='${initial.run.id}'`)).toBe('1');
});
