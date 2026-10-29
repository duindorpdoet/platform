import { test, expect } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { prepareFixtureGuidance } from "./helpers/guidance";
import { assertReadableLayout } from "./helpers/layout";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const groupId = "23000000-0000-0000-0000-000000000001";

// SQL acceptance exercises the real release/privacy boundary. These authenticated
// browser projections isolate every screen state without changing a real route.
test("ordinary parent and leader find the exact released entrance on mobile, including when the map fails", async ({ page, context, baseURL }) => {
  test.skip(!url || !key || !["localhost", "127.0.0.1"].includes(new URL(url).hostname), "Requires isolated local Auth fixtures");
  test.setTimeout(90_000);
  await page.setViewportSize({ width: 390, height: 844 });
  let payload: Record<string, unknown> = {};
  await page.route("**/rest/v1/rpc/group_snapshot", route => route.fulfill({ json: payload }));
  await page.route("**/maps/duindorp-night.json", route => route.abort("failed"));

  for (const email of ["leader-a@example.invalid", "parent-a@example.invalid"]) {
    const client = createClient(url!, key!, { auth: { persistSession: false, autoRefreshToken: false } });
    const login = await client.auth.signInWithPassword({ email, password: "local-test-only" });
    expect(login.error).toBeNull(); await prepareFixtureGuidance(client);
    const original = await client.schema("api").rpc("group_snapshot", { _group_id: groupId });
    expect(original.error).toBeNull();
    const actual = original.data as Record<string, unknown>;
    const leader = email.startsWith("leader");
    const group = actual.group as Record<string, unknown>;
    const startsAt = new Date(Date.now() + 2 * 3600_000).toISOString();
    payload = { ...actual, group: { ...group, start: { startsAt, locationName: "Startlocatie volgt", addressReleased: false, addressReleaseAt: new Date(Date.now() + 3600_000).toISOString(), coordinate: null, address: null, canStart: false } }, run: null };
    const name = `sb-${new URL(url!).hostname.split(".")[0]}-auth-token`;
    const value = `base64-${Buffer.from(JSON.stringify(login.data.session)).toString("base64url")}`;
    await context.clearCookies();
    await context.addCookies(Array.from({ length: Math.ceil(value.length / 3180) }, (_, index) => ({ name: value.length <= 3180 ? name : `${name}.${index}`, value: value.slice(index * 3180, (index + 1) * 3180), url: baseURL!, sameSite: "Lax" as const })));
    await page.goto("/mijn-groep");
    await page.evaluate(() => localStorage.clear());
    await expect(page.getByText(/Jullie eerste adres verschijnt/)).toBeVisible();
    await expect(page.locator(".released-destination")).toHaveCount(0);
    await expect(page.getByRole("link", { name: /Open navigatie/ })).toHaveCount(0);

    payload = { ...actual, group: { ...group, start: { startsAt, locationName: "Synthetisch startpunt", address: "FICTIEF STARTADRES A, 0000AA Teststad", addressReleased: true, canStart: false, coordinate: [4.261111, 52.091111], locationSource: "manual", arrivalInstructions: "Ingang via het hof bij start B" } }, run: null };
    await page.reload();
    await expect(page.locator(".group-start-destination")).toContainText("FICTIEF STARTADRES A");
    await expect(page.locator(".group-start-destination")).toContainText("Ingang via het hof bij start B");
    await expect(page.locator(".group-start-destination .released-destination")).toHaveAttribute("data-destination-coordinate", "4.261111,52.091111");
    await expect(page.locator(".group-start-destination a")).toHaveAttribute("href", /destination=52\.091111,4\.261111/);

    payload = { ...actual, access: { leader, support: false }, run: { id: "10000000-0000-0000-0000-000000000001", status: "live", version: 1, lastServerConfirmation: new Date().toISOString(), emergencyInstruction: null, elapsedSeconds: 60, remainingStopCount: null, waitingInstruction: false, participants: [], history: [], currentStop: { id: "10000000-0000-0000-0000-000000000002", sequence: 1, version: 1, kind: "ordinary", openedAt: new Date().toISOString(), reservedArrivalAt: null, scanAccepted: false, portal: { id: "10000000-0000-0000-0000-000000000003", name: "Synthetische poortingang B", description: "Alleen deze vrijgegeven bestemming", world: "Anders", intensity: 1, operationStatus: "open", address: "FICTIEF OFFICIEEL ADRES A", postalCode: "0000AA", city: "Teststad", coordinate: [4.261234, 52.091234], locationSource: "manual", publicEntranceInstructions: "Ingang via het hof achter het huis; volg het steegje links." } } } };
    await page.reload();
    const destination = page.locator(".participant-route-map");
    await expect(destination).toContainText("FICTIEF OFFICIEEL ADRES A, 0000AA Teststad");
    await expect(destination).toContainText("Ingang via het hof achter het huis; volg het steegje links.");
    await expect(destination.locator(".released-destination")).toHaveAttribute("data-destination-coordinate", "4.261234,52.091234");
    await expect(destination.getByRole("link", { name: /Open navigatie naar de ingang/ })).toHaveAttribute("href", /destination=52\.091234,4\.261234/);
    await expect(destination).toContainText("Die kan afwijken van het officiële adres");
    await expect(destination).toContainText("Kaart tijdelijk niet beschikbaar", { timeout: 20_000 });
    if (leader) {
      const destinationBox = await destination.boundingBox(); const scanBox = await page.locator("#route-scan").boundingBox();
      expect(destinationBox!.y + destinationBox!.height).toBeLessThanOrEqual(scanBox!.y + 1);
    }
    await assertReadableLayout(page);

    const activeRun = payload.run as Record<string, unknown>;
    const stop = activeRun.currentStop as Record<string, unknown>;
    payload = { ...payload, run: { ...activeRun, currentStop: { ...stop, portal: { ...(stop.portal as Record<string, unknown>), coordinate: null } } } };
    await page.reload();
    await expect(page.locator(".participant-route-map")).toContainText("De locatiepin is nog niet bruikbaar");
    await expect(page.locator(".participant-route-map")).toContainText("Ingang via het hof achter het huis");
    await expect(page.getByRole("link", { name: /Open navigatie/ })).toHaveCount(0);
    await expect(page.locator(".participant-route-map .maplibregl-marker")).toHaveCount(0);
    await page.screenshot({ path: test.info().outputPath(`entrance-${leader ? "leader" : "parent"}-mobile.png`), fullPage: true });
    await client.auth.signOut();
  }
});
