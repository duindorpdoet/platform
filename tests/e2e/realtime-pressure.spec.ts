import { expect, test, type Request } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { requireLocalTogetherDatabase, sql } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareStartedLegacyFixtures } from "../../scripts/acceptance/started-fixtures.mjs";
import { prepareFixtureGuidance } from "./helpers/guidance";

// This test writes synthetic fixtures and broadcasts only to a local database.
// It measures rendered client reads, not hosted capacity or 254 independent users.
test("route reads coalesce real private broadcasts and omit the unused parent snapshots", async ({ context, page, baseURL }) => {
  requireLocalTogetherDatabase();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  expect(key).toBeTruthy();
  prepareStartedLegacyFixtures();
  const client = createClient(url, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const login = await client.auth.signInWithPassword({ email: "leader-a@example.invalid", password: "local-test-only" });
  expect(login.error).toBeNull();
  await prepareFixtureGuidance(client);
  const groupId = "23000000-0000-0000-0000-000000000001";
  const snapshot = await client.schema("api").rpc("group_snapshot", { _group_id: groupId });
  expect(snapshot.error).toBeNull();
  if (!snapshot.data.run) {
    const roster = await client.schema("api").rpc("group_roster", { _group_id: groupId });
    expect(roster.error).toBeNull();
    const started = await client.schema("api").rpc("run_start", {
      _group_id: groupId, _present_registration_child_ids: roster.data.map((child: { registrationChildId: string }) => child.registrationChildId),
      _expected_group_version: snapshot.data.group.version, _idempotency_key: "realtime-pressure-start", _request_hash: "realtime-pressure-start",
    });
    expect(started.error).toBeNull();
  }
  const name = `sb-${new URL(url).hostname.split(".")[0]}-auth-token`;
  const value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, i) => ({
    name: value.length <= 3180 ? name : `${name}.${i}`, value: value.slice(i * 3180, (i + 1) * 3180), url: baseURL!, sameSite: "Lax" as const,
  })));
  let subscribed = false;
  let broadcasts = 0;
  page.on("websocket", socket => socket.on("framereceived", frame => {
    const text = frame.payload.toString();
    if (text.includes(`realtime:group:${groupId}`) && text.includes('"status":"ok"')) subscribed = true;
    // Database Broadcast frames may use the SDK's binary topic framing.
    broadcasts += [...text.matchAll(/local-read-pressure/g)].length;
  }));
  const requests: string[] = [], active = new Set<Request>();
  let maximumActive = 0;
  page.on("request", request => {
    const rpc = new URL(request.url()).pathname.match(/\/rpc\/([a-z_]+)$/)?.[1];
    if (!rpc) return;
    requests.push(rpc);
    if (rpc === "group_snapshot") { active.add(request); maximumActive = Math.max(maximumActive, active.size); }
  });
  page.on("requestfinished", request => active.delete(request));
  page.on("requestfailed", request => active.delete(request));
  let hold = false, held = false, release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/rpc/group_snapshot", async route => {
    if (hold) { hold = false; held = true; await gate; }
    await route.continue();
  });
  try {
    await page.goto("/omgeving/meeloper/route");
    await expect(page.getByRole("heading", { name: "Testpoort 01" })).toBeVisible();
    await expect.poll(() => subscribed).toBe(true);
    await expect.poll(() => active.size).toBe(0);
    expect(await page.evaluate(() => ({ visible: document.visibilityState, online: navigator.onLine }))).toEqual({ visible: "visible", online: true });
    // Let the subscription's first invalidation finish before measuring a burst.
    await page.waitForTimeout(750);
    const before = requests.filter(name => name === "group_snapshot").length;
    hold = true;
    const broadcast = (count: number) => sql(`select realtime.send('{"resource":"local-read-pressure"}'::jsonb,'snapshot_changed','group:${groupId}',true) from generate_series(1,${count})`);
    broadcast(1);
    await expect.poll(() => held).toBe(true);
    broadcast(20);
    await expect.poll(() => broadcasts).toBe(21);
    await page.waitForTimeout(750);
    expect(requests.filter(name => name === "group_snapshot")).toHaveLength(before + 1);
    release();
    await expect.poll(() => requests.filter(name => name === "group_snapshot").length).toBe(before + 2);
    await expect.poll(() => active.size).toBe(0);
    expect(maximumActive).toBe(1);
    expect(requests).not.toContain("registration_snapshot");
    expect(requests).not.toContain("registration_preferences_snapshot");
    await expect(page.getByRole("heading", { name: "Testpoort 01" })).toBeVisible();
  } finally {
    console.log(JSON.stringify({ name: "rendered-route-read-pressure", broadcasts, maximumActive, rpcCounts: Object.fromEntries([...new Set(requests)].map(name => [name, requests.filter(rpc => rpc === name).length])) }));
    release();
    await client.auth.signOut();
  }
});
