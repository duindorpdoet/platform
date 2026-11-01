import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => { await page.goto("/"); await page.waitForFunction(() => Boolean(window.portalCampaign)); });
async function open(page: import("@playwright/test").Page) {
  await page.evaluate(() => window.portalCampaign.mount()); await page.getByRole("button", { name: "Certificaatbericht aan poortteams…" }).click();
  return page.getByRole("dialog");
}
test("opening, editing, previewing and cancelling never sends a campaign", async ({ page }) => {
  const dialog = await open(page);
  await expect(dialog.getByLabel("Onderwerp", { exact: true })).toHaveValue("Jullie certificaat staat klaar — bedankt, poortwachters en crew! 🎃");
  await expect(dialog.getByLabel("Bericht", { exact: true })).toContainText("Duindorp FrightNight");
  await expect(dialog.getByRole("region", { name: "Voorvertoning certificaatmail" })).toContainText("vooraf geregistreerde groepen en kids");
  await expect(dialog.getByRole("region", { name: "Voorvertoning certificaatmail" })).not.toContainText("echte bezoekcijfers");
  await expect(dialog.getByText("2 teamaccount(s) zonder beschikbaar bevestigd contactadres.", { exact: false })).toBeVisible();
  const body = "Dank team!\n\nEigen uitnodiging voor volgend jaar.\n<script>window.campaignXss=true</script>";
  await dialog.getByLabel("Bericht", { exact: true }).fill(body);
  await expect(dialog.getByRole("region", { name: "Voorvertoning certificaatmail" })).toContainText(body);
  await expect(dialog.locator("script")).toHaveCount(0); await expect(dialog.getByRole("link", { name: "Open jullie Poortkamer" })).toHaveAttribute("href", "/mijn-huis");
  await expect(dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" })).toBeDisabled();
  await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
  expect(await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST"))).toHaveLength(0);
});
test("final checked confirmation sends the exact raw draft once and never borrows the read AbortSignal", async ({ page }) => {
  const dialog = await open(page), subject = "  Ons team 🎃  ", body = "\nBeste crew,\n\nEen eigen extra alinea.\n\n  ";
  await dialog.getByLabel("Onderwerp", { exact: true }).fill(subject); await dialog.getByLabel("Bericht", { exact: true }).fill(body);
  await dialog.getByRole("checkbox").check(); await page.evaluate(() => window.portalCampaign.plan({ method: "POST", holdBody: true }));
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click();
  await expect(dialog.getByRole("button", { name: "Campagne bevestigen…" })).toBeDisabled(); await expect(dialog.getByRole("button", { name: "Annuleren" })).toBeDisabled();
  const posts = await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST")); expect(posts).toHaveLength(1); expect(posts[0]).toMatchObject({ body: { action: "confirm", eventSlug: "duindorp-halloween-2026", subject, body }, hasSignal: false });
  await page.evaluate(() => window.portalCampaign.hidden(true)); expect(await page.evaluate(() => window.portalCampaign.requests().find(row => row.method === "POST")!.signalAborted)).toBe(false);
  await page.evaluate(() => { window.portalCampaign.hidden(false); window.portalCampaign.release(); }); await expect(dialog).not.toBeVisible();
  await page.getByText("Bekijk het vastgelegde certificaatbericht").click(); await expect(page.locator(".evening-confirmed-message .evening-message-text")).toHaveText(body); expect(await page.evaluate(() => window.portalCampaign.stats().campaigns)).toBe(1);
});
test("a concurrent organizer's immutable text is authoritative", async ({ page }) => {
  const dialog = await open(page); await dialog.getByLabel("Onderwerp", { exact: true }).fill("Verliezend concept"); await dialog.getByRole("checkbox").check();
  await page.evaluate(() => window.portalCampaign.confirm()); await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click();
  await page.getByText("Bekijk het vastgelegde certificaatbericht").click(); await expect(page.getByRole("heading", { name: "Bevestigd door andere organisator" })).toBeVisible(); await expect(page.locator(".evening-confirmed-message")).not.toContainText("Verliezend concept");
});
test("an unknown outcome is not retried automatically; status read discovers one completed campaign", async ({ page }) => {
  const dialog = await open(page); await dialog.getByRole("checkbox").check(); await page.evaluate(() => window.portalCampaign.plan({ method: "POST", networkError: true, persist: true }));
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click(); await expect(dialog.getByText("De uitkomst is nog niet bevestigd.", { exact: false })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" })).toBeDisabled(); await dialog.getByRole("button", { name: "Actuele certificaatmailstatus controleren" }).click();
  await expect(dialog).not.toBeVisible(); expect(await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST"))).toHaveLength(1); expect(await page.evaluate(() => window.portalCampaign.stats().campaigns)).toBe(1);
});
test("a deliberate retry after an unconfirmed status keeps the command UUID and original text", async ({ page }) => {
  const dialog = await open(page); await dialog.getByRole("checkbox").check(); await page.evaluate(() => window.portalCampaign.plan({ method: "POST", networkError: true }));
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click(); await expect(dialog.getByText("De uitkomst is nog niet bevestigd.", { exact: false })).toBeVisible();
  await dialog.getByRole("button", { name: "Actuele certificaatmailstatus controleren" }).click(); await expect(dialog.getByLabel("Bericht", { exact: true })).toBeDisabled();
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click(); await expect(dialog).not.toBeVisible();
  const posts = await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST")); expect(posts).toHaveLength(2); expect(posts[1].body).toEqual(posts[0].body);
});
for (const malformed of ["invalid", "unconfirmed"] as const) test(`HTTP 200 ${malformed} confirmation never claims a saved campaign`, async ({ page }) => {
  const dialog = await open(page); await dialog.getByRole("checkbox").check(); await page.evaluate(kind => window.portalCampaign.plan({ method: "POST", result: kind === "invalid" ? { ok: true } : window.portalCampaign.snapshot() }), malformed);
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click(); await expect(dialog.getByText("De uitkomst is nog niet bevestigd.", { exact: false })).toBeVisible();
  await expect(page.getByText("De certificaatcampagne is vastgelegd.", { exact: false })).toHaveCount(0); expect(await page.evaluate(() => window.portalCampaign.stats().campaigns)).toBe(0);
});
test("without organizer capability there is no card, status request or action", async ({ page }) => {
  await page.evaluate(() => window.portalCampaign.mount(false)); await expect(page.getByRole("heading")).toHaveCount(0); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(0);
});
test("not-ready status prevents campaign confirmation", async ({ page }) => {
  await page.evaluate(() => { const next = window.portalCampaign.snapshot(); next.ready = false; window.portalCampaign.setSnapshot(next); window.portalCampaign.mount(); });
  await expect(page.getByText("Sluit de avond eerst bewust af.", { exact: false })).toBeVisible(); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeDisabled();
  await page.evaluate(() => { const next = window.portalCampaign.snapshot(); next.ready = true; window.portalCampaign.setSnapshot(next); }); await page.getByRole("button", { name: "Certificaatmailstatus vernieuwen" }).click(); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeEnabled();
});
test("the full response-body phase is serialized across focus, online and visibility events", async ({ page }) => {
  await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", holdBody: true }); window.portalCampaign.mount(); }); await page.waitForFunction(() => window.portalCampaign.stats().active === 1);
  await page.evaluate(() => { for (let n = 0; n < 10; n++) { window.dispatchEvent(new Event("focus")); window.dispatchEvent(new Event("online")); document.dispatchEvent(new Event("visibilitychange")); } });
  expect(await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "GET"))).toHaveLength(1); expect(await page.evaluate(() => window.portalCampaign.stats().maxActive)).toBe(1);
  await page.evaluate(() => window.portalCampaign.release()); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeEnabled();
});
test("there is no interval polling and hidden/offline views cannot start status requests", async ({ page }) => {
  await page.clock.install(); await page.evaluate(() => window.portalCampaign.mount()); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeEnabled();
  await page.clock.fastForward(120_000); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
  await page.evaluate(() => { window.portalCampaign.hidden(true); window.dispatchEvent(new Event("focus")); window.portalCampaign.online(false); }); await page.clock.fastForward(120_000); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
  await page.evaluate(() => { window.portalCampaign.online(true); window.portalCampaign.hidden(false); }); await expect.poll(async () => page.evaluate(() => window.portalCampaign.requests().length)).toBe(2);
});
test("429 Retry-After cannot be bypassed with repeated focus or online events", async ({ page }) => {
  await page.clock.install(); await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", status: 429, headers: { "Retry-After": "60" } }); window.portalCampaign.mount(); }); await expect(page.getByRole("status")).toContainText("kon niet worden opgehaald");
  await page.clock.fastForward(30_000); await page.evaluate(() => { window.dispatchEvent(new Event("focus")); window.dispatchEvent(new Event("online")); }); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
  await page.clock.fastForward(30_001); await page.evaluate(() => window.dispatchEvent(new Event("focus"))); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeEnabled();
});
test("an eight-second read timeout keeps its body guard and backoff until an explicit later refresh", async ({ page }) => {
  await page.clock.install(); await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", holdBody: true }); window.portalCampaign.mount(); }); await page.waitForFunction(() => window.portalCampaign.stats().active === 1);
  await page.clock.fastForward(8_001); expect(await page.evaluate(() => window.portalCampaign.requests()[0].signalAborted)).toBe(true);
  await page.evaluate(() => window.dispatchEvent(new Event("focus"))); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
  await page.evaluate(() => window.portalCampaign.release()); await expect(page.getByRole("status")).toContainText("duurde te lang");
  await page.clock.fastForward(6_000); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1); await page.evaluate(() => window.dispatchEvent(new Event("focus"))); await expect(page.getByRole("button", { name: "Certificaatbericht aan poortteams…" })).toBeEnabled();
});
for (const status of [401, 403]) test(`snapshot ${status} clears access and stops automatic retries`, async ({ page }) => {
  await page.evaluate(code => { window.portalCampaign.plan({ method: "GET", status: code }); window.portalCampaign.mount(); }, status); await expect(page.getByRole("status")).toContainText("Je toegang kon niet worden bevestigd");
  await page.evaluate(() => { window.dispatchEvent(new Event("focus")); window.dispatchEvent(new Event("online")); }); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
});
test("unmount aborts a status read and a late body cannot restore the previous event", async ({ page }) => {
  await page.evaluate(() => { window.portalCampaign.confirm("PRIVATE OLD EVENT", "PRIVATE OLD BODY"); window.portalCampaign.plan({ method: "GET", holdBody: true }); window.portalCampaign.mount(); }); await page.waitForFunction(() => window.portalCampaign.stats().active === 1);
  await page.evaluate(() => window.portalCampaign.unmount()); await expect(page.getByRole("heading")).toHaveCount(0); expect(await page.evaluate(() => window.portalCampaign.requests()[0].signalAborted)).toBe(true); await page.evaluate(() => window.portalCampaign.release());
  await page.evaluate(() => window.portalCampaign.mount(true, "event-two", "different-event")); await expect(page.getByRole("status")).toContainText("kon niet worden opgehaald"); await expect(page.getByText("PRIVATE OLD BODY")).toHaveCount(0);
});
test("a late aborted 401 cannot deny the new generation and effect re-setup keeps one full-cycle read guard", async ({ page }) => {
  await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", status: 401, holdHeaders: true }); window.portalCampaign.mountProbe(); });
  await page.waitForFunction(() => window.portalCampaign.requests().length === 1);
  await page.evaluate(() => { const next = window.portalCampaign.snapshot(); next.event = { ...next.event, id: "event-two", slug: "different-event" }; window.portalCampaign.setSnapshot(next); window.portalCampaign.mountProbe("event-two", "different-event"); });
  await expect.poll(async () => page.evaluate(() => window.portalCampaign.requests()[0].signalAborted)).toBe(true);
  expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1); await page.evaluate(() => window.portalCampaign.release());
  await expect(page.getByTestId("hook-probe")).toContainText('"id":"event-two"'); await expect(page.getByRole("status")).toHaveText("");
  expect(await page.evaluate(() => window.portalCampaign.stats().maxActive)).toBe(1);
});
test("an abort-ignoring old body settles before one resumed read and cannot hide the newer loading state", async ({ page }) => {
  await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", holdBody: true }); window.portalCampaign.mountProbe(); }); await page.waitForFunction(() => window.portalCampaign.stats().active === 1);
  await page.evaluate(() => { const next = window.portalCampaign.snapshot(); next.event = { ...next.event, id: "event-two", slug: "different-event" }; window.portalCampaign.setSnapshot(next); window.portalCampaign.plan({ method: "GET", holdBody: true }); window.portalCampaign.mountProbe("event-two", "different-event"); });
  await expect.poll(async () => page.evaluate(() => window.portalCampaign.requests()[0].signalAborted)).toBe(true); expect(await page.evaluate(() => window.portalCampaign.requests())).toHaveLength(1);
  await page.evaluate(() => window.portalCampaign.release()); await page.waitForFunction(() => window.portalCampaign.requests().length === 2);
  await expect(page.getByTestId("hook-probe")).toHaveAttribute("data-loading", "true"); await expect(page.getByTestId("hook-probe")).not.toContainText('"id":"event-one"');
  expect(await page.evaluate(() => window.portalCampaign.stats().maxActive)).toBe(1); await page.evaluate(() => window.portalCampaign.release());
  await expect(page.getByTestId("hook-probe")).toHaveAttribute("data-loading", "false"); await expect(page.getByTestId("hook-probe")).toContainText('"id":"event-two"');
});
test("a revoked status during a pending mutation prevents its late response from restoring the campaign UI", async ({ page }) => {
  const dialog = await open(page); await dialog.getByRole("checkbox").check(); await page.evaluate(() => window.portalCampaign.plan({ method: "POST", holdBody: true }));
  await dialog.getByRole("button", { name: "Certificaatbericht definitief versturen" }).click();
  await page.evaluate(() => { window.portalCampaign.plan({ method: "GET", status: 403 }); window.dispatchEvent(new Event("focus")); });
  await expect(page.getByText("Je toegang kon niet worden bevestigd.", { exact: false })).toBeVisible(); await page.evaluate(() => window.portalCampaign.release());
  await expect(dialog).not.toBeVisible(); await expect(page.getByText("Bekijk het vastgelegde certificaatbericht")).toHaveCount(0);
  expect(await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST"))).toHaveLength(1);
});
test("recovery only queues eligible failed jobs and reports zero truthfully", async ({ page }) => {
  await page.evaluate(() => { window.portalCampaign.confirm(); const next = window.portalCampaign.snapshot(); next.mail = { ...next.mail, failed: 2, unknown: 1, retryableFailed: 2 }; window.portalCampaign.setSnapshot(next); window.portalCampaign.mount(); });
  const retry = page.getByRole("button", { name: "Alleen mislukte certificaatmails herstellen" }); await expect(retry).toBeVisible();
  await page.evaluate(() => { const next = window.portalCampaign.snapshot(); next.requeued = 0; window.portalCampaign.plan({ method: "POST", result: next }); }); await retry.click();
  await expect(page.getByRole("status")).toHaveText("Geen verzendjobs opnieuw klaargezet; controleer de bestaande mailregistratie.");
  await retry.click(); await expect(page.getByRole("status")).toHaveText("2 aantoonbaar mislukte verzendjob(s) opnieuw klaargezet.");
  const posts = await page.evaluate(() => window.portalCampaign.requests().filter(row => row.method === "POST")); expect(posts.map(row => row.body)).toEqual([{ eventSlug: "duindorp-halloween-2026", action: "retry_failed" }, { eventSlug: "duindorp-halloween-2026", action: "retry_failed" }]);
});
test("the confirmation dialog fits a 360px viewport", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 }); const dialog = await open(page); await expect(dialog.getByRole("checkbox")).toBeVisible();
  expect(await dialog.evaluate(element => element.scrollWidth <= element.clientWidth + 1)).toBe(true); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
