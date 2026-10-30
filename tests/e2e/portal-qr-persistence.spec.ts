import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { fixtureSql, reviewCanonicalFixtureRoutes } from "./helpers/canonical-routes";
import { prepareFixtureGuidance } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
let portal: string, otherPortal: string;
const seedPortal = "12000000-0000-0000-0000-000000000001";
const event = "duindorp-halloween-2026", finale = "12000000-0000-0000-0000-000000000030", group = "23000000-0000-0000-0000-000000000001";
type Material = { credential: string; shortCode: string; credentialRevision: number; portalVersion: number; origin: string; canRotate: boolean };
const fromBrowser = createRequire(createRequire(resolve("package.json")).resolve("@zxing/browser"));
const { QRCodeReader, RGBLuminanceSource, BinaryBitmap, HybridBinarizer, DecodeHintType } = fromBrowser("@zxing/library");

test.beforeEach(() => { test.skip(!url || !key, "Requires isolated real Auth and database"); requireLocalTogetherDatabase(); });
async function login(context: BrowserContext, baseURL: string, email = "owner@example.invalid") {
  const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await client.auth.signInWithPassword({ email, password: "local-test-only" }); expect(signed.error).toBeNull(); await prepareFixtureGuidance(client);
  const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`, value = `base64-${Buffer.from(JSON.stringify(signed.data.session)).toString("base64url")}`;
  await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: value.length <= 3180 ? name : `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180), url: baseURL, sameSite: "Lax" as const })));
  return client;
}
async function api<T>(client: SupabaseClient, name: string, args: Record<string, unknown>): Promise<T> { const result = await client.schema("api").rpc(name, args); expect(result.error, name).toBeNull(); return result.data as T; }
async function setup(admin: SupabaseClient) {
  sql(`${fixtureSql("supabase/tests/helpers/joint-route-fixture.inc")}
    do $fixture$ begin
      perform pg_temp.joint_canonical_fixture(date_bin(interval '10 minutes',clock_timestamp(),timestamptz '2000-01-01')-interval '20 minutes');
      update app_private.walking_groups set retired_at=clock_timestamp() where id in('23000000-0000-0000-0000-000000000002','23000000-0000-0000-0000-000000000003','23000000-0000-0000-0000-000000000004');
      -- The compacted finale still needs room for today's actual walk and visit.
      -- Its existing last arrival, show, closing and group end remain enforced.
      update app_private.event_route_settings set finale_opens_at=clock_timestamp()+interval '1 hour'
        where event_id=(select id from app_private.events where slug='${event}');
      update app_private.children set step_free_required=false;
      update app_private.portals set accessibility_status='step_free',operation_status=case when id='${finale}' then 'open'::app_private.portal_operation_status else 'closed'::app_private.portal_operation_status end;
    end $fixture$;`);
  // Real management commands generate RFC-valid UUIDs; production HTTP UUID
  // validation remains intact. These receive only synthetic local locations.
  async function createPortal(name: string, operationStatus: string) {
    const payload = { name, worldSlug: "heksenrijk", lifecycleStatus: "active", approvalStatus: "approved", operationStatus,
      street: "FICTIEVE QR TESTLOCATIE", houseNumber: "999", postalCode: "0000AA", city: "Teststad", latitude: 52.1001, longitude: 4.2701,
      plannedOpensAt: new Date(Date.now() - 3_600_000).toISOString(), plannedClosesAt: new Date(Date.now() + 5 * 3_600_000).toISOString(),
      maxGroups: 10, maxChildren: 12, visitMinutes: 5, bufferMinutes: 0, arrivalHeadwaySeconds: 300, ordinaryEndGraceSeconds: 300,
      ordinaryHardClose: false, accessibilityStatus: "step_free", candidateStartPoint: false, saveMode: "activate" };
    const created = await api<{ id: string; version: number }>(admin, "admin_manual_portal_save", { _event_slug: event, _portal_id: null, _expected_version: null,
      _payload: { ...payload, lifecycleStatus: "concept", approvalStatus: "draft" }, _reason: "Synthetische afzonderlijke QR-testpoort aanmaken via het beheercommando" });
    sql(`insert into app_private.portal_owners(portal_id,user_id)select '${created.id}',o.user_id from app_private.portal_owners o join auth.users u on u.id=o.user_id where o.portal_id='${seedPortal}' and o.role='owner' and o.revoked_at is null and u.email_confirmed_at is not null`);
    await api(admin, "admin_manual_portal_save", { _event_slug: event, _portal_id: created.id, _expected_version: created.version, _payload: payload,
      _reason: "Synthetische QR-testpoort expliciet activeren met geverifieerde testeigenaar" });
    return created.id;
  }
  portal = await createPortal("Synthetische blijvende QR-poort één", "open"); otherPortal = await createPortal("Synthetische blijvende QR-poort twee", "closed");
  sql(`insert into app_private.portal_owners(portal_id,user_id,role,access_level)values('${portal}','a0000000-0000-0000-0000-000000000001','viewer','view');
    insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from,valid_until)
    select '${portal}',token_hash,short_code_hash,coalesce((select max(version)from app_private.portal_credentials where portal_id='${portal}'),0)+1,valid_from,valid_until from app_private.portal_credentials where portal_id='${seedPortal}' and version=1;`);
}
function checkpoint() {
  return JSON.parse(sql(`select jsonb_build_object('portalVersion',(select version from app_private.portals where id='${portal}'),
    'publications',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id)::text,''))from app_private.group_start_publications p),
    'mail',(select count(*)from app_private.email_outbox),'runs',(select count(*)from app_private.group_runs),
    'material',(select count(*)from app_private.portal_print_material m join app_private.portal_credentials c on c.id=m.credential_id where c.portal_id='${portal}'),
    'active',(select count(*)from app_private.portal_credentials where portal_id='${portal}' and revoked_at is null))`));
}
async function printable(context: BrowserContext, id = portal): Promise<Material> {
  const response = await context.request.get(`/api/redesign/poster?portalId=${id}`); expect(response.ok(), `authorized printable code HTTP ${response.status()}`).toBe(true); return await response.json() as Material;
}
async function decodeVisible(page: Page, expected: Material, id = portal) {
  const image = page.getByAltText("QR-code om aankomst bij deze poort te bevestigen"); await expect(image).toBeVisible(); await image.scrollIntoViewIfNeeded(); await expect(image).toBeInViewport();
  const pixels = await image.evaluate(async (element: HTMLImageElement) => {
    await element.decode();
    const svg = new DOMParser().parseFromString(decodeURIComponent(element.src.split(",")[1]), "image/svg+xml");
    const modules = Number(svg.documentElement.getAttribute("viewBox")?.trim().split(/\s+/)[2]);
    if (!element.complete || !element.naturalWidth || !Number.isInteger(modules) || modules < 21 || modules > 200) throw new Error("VISIBLE_QR_IMAGE_NOT_READY");
    // Read the actual displayed vector at integer pixels per module, matching
    // a printable QR. Fractional CSS downsampling can distort finder geometry.
    const box = element.getBoundingClientRect(), side = modules * 8, canvas = document.createElement("canvas");
    canvas.width = side; canvas.height = side; const ctx = canvas.getContext("2d")!; ctx.drawImage(element, 0, 0, side, side);
    const bytes = ctx.getImageData(0, 0, side, side).data;
    return { side, visibleWidth: box.width, whiteCorner: bytes[0] === 255 && bytes[1] === 255 && bytes[2] === 255, grey: Array.from({ length: side * side }, (_, index) => bytes[index * 4]) };
  });
  expect(pixels.visibleWidth).toBeGreaterThan(140); expect(pixels.whiteCorner).toBe(true);
  const bitmap = new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(Uint8ClampedArray.from(pixels.grey), pixels.side, pixels.side)));
  let decoded: string;
  try { decoded = new QRCodeReader().decode(bitmap, new Map([[DecodeHintType.TRY_HARDER, true]])).getText(); }
  catch {
    // The preview is a complete, front-facing QR. The pure-image decoder avoids
    // camera-perspective finder ambiguity at desktop's one CSS pixel per pixel.
    decoded = new QRCodeReader().decode(bitmap, new Map([[DecodeHintType.PURE_BARCODE, true]])).getText();
  }
  const target = new URL(decoded); expect(target.protocol).toBe("https:"); expect(target.searchParams.get("poort") === id).toBe(true); expect(target.searchParams.get("code") === expected.credential).toBe(true);
  await expect(page.locator(".gate-poster-code strong")).toHaveText(expected.shortCode); await expect(page.locator(".gate-paper-code strong")).toHaveText(expected.shortCode);
  return decoded;
}
async function simultaneousPrintable(context: BrowserContext) {
  const container = requireLocalTogetherDatabase();
  const blocker = spawn("docker", ["exec", "-i", container, "psql", "-U", "postgres", "-d", "postgres", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], { stdio: ["pipe", "pipe", "pipe"] });
  const ready = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("LOCAL_QR_LOCK_TIMEOUT")), 8_000);
    let output = ""; blocker.stdout.on("data", chunk => { output += String(chunk); if (output.includes("QR_LOCK_READY")) { clearTimeout(timeout); resolve(); } }); blocker.on("error", cause => { clearTimeout(timeout); reject(cause); }); blocker.on("exit", code => { clearTimeout(timeout); if (code) reject(new Error("LOCAL_QR_LOCK_FAILED")); });
  });
  blocker.stdin.write(`begin;set local idle_in_transaction_session_timeout='20s';do $lock$begin perform 1 from app_private.portals where id='${portal}' for update;end $lock$;select 'QR_LOCK_READY';\n`);
  try {
    await ready; const both = Promise.all([printable(context), printable(context)]);
    await expect.poll(() => Number(sql("select count(*) from pg_stat_activity where datname=current_database() and wait_event_type='Lock' and query like '%portal_print_access%' and pid<>pg_backend_pid()")), { timeout: 8_000, message: "both real HTTP requests wait before first credential insertion" }).toBeGreaterThanOrEqual(2);
    blocker.stdin.end("commit;\n"); const results = await both;
    expect(results[0].credential === results[1].credential).toBe(true); expect(results[0].shortCode === results[1].shortCode).toBe(true); return results[0];
  } finally { if (!blocker.stdin.writableEnded) blocker.stdin.end("rollback;\n"); }
}

// Generated local credentials never become test reports or production fixtures.
test("real printable QR and manual code survive concurrent provisioning, reload, navigation, failed reads and another house", async ({ page, context, browser, baseURL }) => {
  const admin = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  expect((await admin.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" })).error).toBeNull();
  await setup(admin); const owner = await login(context, baseURL!);
  const proposal = await reviewCanonicalFixtureRoutes(admin, event); expect(proposal.groups).toHaveLength(1); expect(proposal.groups[0].visits.some(visit => visit.portalId === portal && visit.kind === "ordinary")).toBe(true);
  const finalVisit=proposal.groups[0].visits.at(-1)!;expect(finalVisit.kind).toBe("finale");expect(finalVisit.portalId).toBe(finale);
  expect(Date.parse(finalVisit.startsAt)).toBeGreaterThan(Date.now()+30*60_000);
  const inputBefore = await api<{ sourceHash: string }>(admin, "admin_joint_route_planning_input", { _event_slug: event }), before = checkpoint();
  expect(before.material).toBe(0); const material = await simultaneousPrintable(context), after = checkpoint();
  expect(after.material - before.material).toBe(1); expect(after.active - before.active).toBe(1);
  expect({ ...after, active: before.active, material: before.material }).toEqual(before);
  expect((await api<{ sourceHash: string }>(admin, "admin_joint_route_planning_input", { _event_slug: event })).sourceHash).toBe(inputBefore.sourceHash);
  expect(material.canRotate).toBe(true);
  const viewer = await browser.newContext({ baseURL, ignoreHTTPSErrors: true }); await login(viewer, baseURL!, "parent-a@example.invalid");
  try {
    const readable = await printable(viewer); expect(readable.credential === material.credential).toBe(true); expect(readable.canRotate).toBe(false);
    const viewPage = await viewer.newPage(); await viewPage.goto(`/mijn-huis?poort=${portal}&qr=1`); await decodeVisible(viewPage, material);
    await expect(viewPage.getByRole("button", { name: "Nieuwe code maken", exact: true })).toHaveCount(0);
    const denied = await viewer.request.post("/api/redesign/poster", { headers: { origin: baseURL! }, data: { portalId: portal, version: material.portalVersion, confirmRotation: true } }); expect(denied.status()).toBe(403);
  } finally { await viewer.close(); }
  await page.goto(`/mijn-huis?poort=${portal}&qr=1`); await decodeVisible(page, material); await assertReadableLayout(page);
  await page.reload(); await expect(page).toHaveURL(/qr=1/); const arrival = await decodeVisible(page, material);
  // Both visible methods and the already printed legacy QR pass the actual
  // leader/expected-stop/version check; validation grants no arrival or seal.
  const leader = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
  expect((await leader.auth.signInWithPassword({ email: "leader-a@example.invalid", password: "local-test-only" })).error).toBeNull();
  const state = await api<{ group: { version: number; children: { registrationChildId: string }[] } }>(leader, "group_snapshot", { _group_id: group });
  const present = JSON.parse(sql(`select jsonb_agg(rc.id) from app_private.group_registrations gr join app_private.registration_children rc on rc.registration_id=gr.registration_id where gr.group_id='${group}' and gr.superseded_at is null and rc.participation_status='active'`)) as string[];
  const startResult=await api<{dispatch:{decision:string}}>(leader, "run_start", { _group_id: group, _present_registration_child_ids: present, _expected_group_version: state.group.version, _idempotency_key: randomUUID(), _request_hash: present.sort().join(":") });
  expect(startResult.dispatch.decision,JSON.stringify(startResult)).toBe("ordinary");
  const active = await api<{ run: { id: string; version: number; currentStop: { id: string; portal: { id: string } } } }>(leader, "group_snapshot", { _group_id: group });
  expect(active.run.currentStop.portal.id).toBe(portal); const seals = Number(sql("select count(*)from app_private.poortenboek_passport_seals"));
  for (const [credential, method] of [[new URL(arrival).searchParams.get("code")!, "qr"], [material.shortCode, "short_code"], ["TEST-PORTAL-01-TOKEN", "qr"], ["TEST-01", "short_code"]]) {
    await api(leader, "run_scan_validate", { _run_id: active.run.id, _expected_stop_id: active.run.currentStop.id, _expected_run_version: active.run.version, _credential: credential, _portal_id: portal, _method: method });
  }
  expect(Number(sql("select count(*)from app_private.poortenboek_passport_seals"))).toBe(seals);
  await page.getByRole("button", { name: "Nachtwacht", exact: true }).click(); await expect(page).not.toHaveURL(/qr=1/);
  await page.getByRole("button", { name: "QR-code & printen", exact: true }).first().click(); await decodeVisible(page, material);
  // A failed read retains the last valid pair, with an explicit retry.
  await page.route("**/api/redesign/poster?*", route => route.fulfill({ status: 503, contentType: "application/json", body: "{}" }), { times: 1 });
  await page.getByRole("button", { name: "Code opnieuw ophalen", exact: true }).click(); await expect(page.locator(".gate-poster-error")).toBeVisible(); await decodeVisible(page, material);
  await page.getByRole("button", { name: "Opnieuw proberen", exact: true }).click(); await expect(page.locator(".gate-poster-error")).toHaveCount(0); await decodeVisible(page, material);
  const secondContext = await browser.newContext({ baseURL, ignoreHTTPSErrors: true }); await login(secondContext, baseURL!);
  try { const second = await printable(secondContext); expect(second.credential === material.credential && second.shortCode === material.shortCode).toBe(true); } finally { await secondContext.close(); }
  // Switching while an old read is in flight must never show the first house's
  // usable code under the second house's name, even before its own read finishes.
  let releaseOld!: () => void, oldStarted!: () => void;
  const hold = new Promise<void>(resolve => { releaseOld = resolve; }), started = new Promise<void>(resolve => { oldStarted = resolve; });
  await page.route(`**/api/redesign/poster?portalId=${portal}`, async route => { const response = await route.fetch(); oldStarted(); await hold; await route.fulfill({ response }).catch(() => {}); }, { times: 1 });
  await page.getByRole("button", { name: "Code opnieuw ophalen", exact: true }).click(); await started;
  const other = await printable(context, otherPortal); await page.getByLabel("Jouw poort", { exact: false }).selectOption(otherPortal);
  await expect(page).toHaveURL(new RegExp(`poort=${otherPortal}.*qr=1`)); await decodeVisible(page, other, otherPortal); releaseOld(); await decodeVisible(page, other, otherPortal);
  await page.reload(); await decodeVisible(page, other, otherPortal);
  // Actual unauthorized access stays denied; a denied refresh removes cached
  // material rather than retaining another actor's QR on screen.
  const unrelated = await browser.newContext({ baseURL, ignoreHTTPSErrors: true }); await login(unrelated, baseURL!, "parent-b@example.invalid");
  try { expect((await unrelated.request.get(`/api/redesign/poster?portalId=${otherPortal}`)).status()).toBe(403); } finally { await unrelated.close(); }
  await page.route("**/api/redesign/poster?*", route => route.fulfill({ status: 403, contentType: "application/json", body: "{}" }), { times: 1 });
  await page.getByRole("button", { name: "Code opnieuw ophalen", exact: true }).click(); await expect(page.getByAltText("QR-code om aankomst bij deze poort te bevestigen")).toHaveCount(0);
  await expect(page.locator(".gate-poster-code")).toHaveCount(0); await expect(page.locator(".gate-poster-error")).toContainText("aanmelding");
  await page.getByRole("button", { name: "Opnieuw proberen", exact: true }).click(); await decodeVisible(page, other, otherPortal);
  // An explicit rotation can commit while its response is lost. Its bounded
  // timeout offers a GET retry; it must never silently submit a second rotation.
  let releasePost!: () => void, committedPost!: () => void, rotations = 0;
  const lostResponse = new Promise<void>(resolve => { releasePost = resolve; }), committed = new Promise<void>(resolve => { committedPost = resolve; });
  await page.route("**/api/redesign/poster", async route => { rotations++; const response = await route.fetch(); expect(response.ok()).toBe(true); committedPost(); await lostResponse; await route.fulfill({ response }).catch(() => {}); }, { times: 1 });
  await page.getByText("Een nieuwe bezoekcode nodig?", { exact: true }).click(); page.once("dialog", dialog => dialog.accept());
  await page.getByRole("button", { name: "Nieuwe code maken", exact: true }).click(); await committed;
  // The parent can already observe the committed portal version while the POST
  // response is still missing; this must not cancel its bounded recovery path.
  await page.getByRole("button", { name: "Vernieuwen", exact: true }).click();
  const recovered = await printable(context, otherPortal);
  expect(recovered.credential !== other.credential).toBe(true); expect(recovered.credentialRevision).toBe(other.credentialRevision + 1); expect(rotations).toBe(1);
  await decodeVisible(page, recovered, otherPortal); await expect(page.getByRole("button", { name: "Code opnieuw ophalen", exact: true })).toBeEnabled();
  releasePost(); await page.reload(); await decodeVisible(page, recovered, otherPortal); expect(rotations).toBe(1);
  // Without a parent refresh, losing another explicitly confirmed POST still
  // terminates within eight seconds and recovers by GET, without a second POST.
  let releaseTimeout!: () => void, timeoutCommitted!: () => void, timeoutRotations = 0;
  const timeoutHold = new Promise<void>(resolve => { releaseTimeout = resolve; }), timeoutReady = new Promise<void>(resolve => { timeoutCommitted = resolve; });
  await page.route("**/api/redesign/poster", async route => { timeoutRotations++; const response = await route.fetch(); expect(response.ok()).toBe(true); timeoutCommitted(); await timeoutHold; await route.fulfill({ response }).catch(() => {}); }, { times: 1 });
  await page.getByText("Een nieuwe bezoekcode nodig?", { exact: true }).click(); page.once("dialog", dialog => dialog.accept());
  await page.getByRole("button", { name: "Nieuwe code maken", exact: true }).click(); await timeoutReady;
  const afterTimeout = await printable(context, otherPortal);
  await expect.poll(async () => {
    if ((await page.locator(".gate-poster-code strong").allTextContents())[0] === afterTimeout.shortCode) return "recovered";
    if ((await page.locator(".gate-poster-error").allTextContents()).join(" ").includes("niet bevestigd")) return "retry";
    return "pending";
  }, { timeout: 12_000 }).not.toBe("pending");
  if (await page.locator(".gate-poster-error").isVisible()) await page.getByRole("button", { name: "Opnieuw proberen", exact: true }).click();
  await decodeVisible(page, afterTimeout, otherPortal); expect(afterTimeout.credentialRevision).toBe(recovered.credentialRevision + 1); expect(timeoutRotations).toBe(1);
  releaseTimeout(); await page.reload(); await decodeVisible(page, afterTimeout, otherPortal); expect(timeoutRotations).toBe(1);
  expect(checkpoint().material).toBe(1); await owner.auth.signOut();
});
