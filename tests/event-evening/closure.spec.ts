import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => { await page.goto("/"); await page.waitForFunction(() => Boolean(window.evening)); });

test("open, edit, preview and cancel never close or send; input stays text", async ({ page }) => {
  await page.evaluate(() => window.evening.mountAdmin());
  await page.getByRole("button", { name: "Avond afsluiten…", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: "Avond afsluiten en iedereen bedanken" })).toBeVisible();
  await expect(dialog.getByText("2 deelnemersaccount(s) zonder beschikbaar contactadres.", { exact: false })).toBeVisible();
  await expect(dialog.getByLabel("Onderwerp", { exact: true })).toHaveValue("Bedankt voor een bijzondere Halloweenavond in Duindorp! 🎃");
  const text = "Dankjewel!\n\nMijn extra alinea.\n<script>window.closureXss=true</script>";
  await dialog.getByLabel("Bericht", { exact: true }).fill(text);
  await expect(dialog.getByRole("region", { name: "Voorvertoning in app en e-mail" })).toContainText("Mijn extra alinea.");
  await expect(dialog.locator("script")).toHaveCount(0);
  await dialog.getByRole("button", { name: "Annuleren", exact: true }).click();
  await expect(dialog).not.toBeVisible();
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST"))).toHaveLength(0);
  expect(await page.evaluate(() => window.evening.stats().closures)).toBe(0);
});

test("deliberate confirmation preserves exact editable message and prevents duplicate clicks", async ({ page }) => {
  await page.evaluate(() => window.evening.mountAdmin());
  await page.getByRole("button", { name: "Avond afsluiten…", exact: true }).click();
  const dialog = page.getByRole("dialog");
  const subject = "Onze eigen afsluiting 🎃";
  const body = "Beste buren,\n\nEen handmatig toegevoegde alinea.\n\nGroet, de organisatie";
  await dialog.getByLabel("Onderwerp", { exact: true }).fill(subject);
  await dialog.getByLabel("Bericht", { exact: true }).fill(body);
  await page.evaluate(() => window.evening.plan({ method: "POST", holdBody: true }));
  const button = dialog.getByRole("button", { name: "Avond afsluiten en bedankbericht versturen", exact: true });
  await button.click();
  await expect(dialog.getByRole("button", { name: "Afsluiting bevestigen…" })).toBeDisabled();
  await expect(dialog.getByRole("button", { name: "Annuleren" })).toBeDisabled();
  const posts = await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST"));
  expect(posts).toHaveLength(1);
  expect(posts[0].body).toMatchObject({ action: "confirm", subject, body });
  expect(posts[0].signal).toBe(false);
  await page.evaluate(() => window.evening.release());
  await expect(dialog).not.toBeVisible();
  await page.getByText("Bekijk het vastgelegde organisatiebericht").click();
  await expect(page.getByRole("heading", { name: subject })).toBeVisible();
  await expect(page.locator(".evening-confirmed-message .evening-message-text")).toHaveText(body);
  await expect(page.getByLabel("Verzendstatus bedankbericht")).toContainText("Provider geaccepteerd");
  expect(await page.evaluate(() => window.evening.stats().closures)).toBe(1);
});

test("concurrent winner response is authoritative and cannot be overwritten by this organizer's draft", async ({ page }) => {
  await page.evaluate(() => window.evening.mountAdmin());
  await page.getByRole("button", { name: "Avond afsluiten…", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Onderwerp", { exact: true }).fill("Verliezend concept");
  await page.evaluate(() => {
    window.evening.close("Andere organisator bevestigde eerst", "Dit is de vaste winnende tekst.");
    window.evening.plan({ method: "POST", result: window.evening.snapshot() });
  });
  await dialog.getByRole("button", { name: "Avond afsluiten en bedankbericht versturen", exact: true }).click();
  await page.getByText("Bekijk het vastgelegde organisatiebericht").click();
  await expect(page.getByRole("heading", { name: "Andere organisator bevestigde eerst" })).toBeVisible();
  await expect(page.locator(".evening-confirmed-message")).not.toContainText("Verliezend concept");
  await expect(page.getByRole("button", { name: "Avond afsluiten…", exact: true })).toHaveCount(0);
});

test("unknown mutation outcome never retries automatically and is resolved by a read", async ({ page }) => {
  await page.evaluate(() => window.evening.mountAdmin());
  await page.getByRole("button", { name: "Avond afsluiten…", exact: true }).click();
  await page.evaluate(() => window.evening.plan({ method: "POST", networkError: true }));
  await page.getByRole("dialog").getByRole("button", { name: "Avond afsluiten en bedankbericht versturen", exact: true }).click();
  await expect(page.getByRole("dialog").getByRole("button", { name: "Avond afsluiten en bedankbericht versturen", exact: true })).toBeDisabled();
  await expect(page.getByRole("dialog")).toContainText("het verzoek wordt niet automatisch herhaald");
  await page.evaluate(() => window.evening.close());
  await page.getByRole("dialog").getByRole("button", { name: "Actuele afsluitstatus controleren" }).click();
  await expect(page.getByRole("dialog")).not.toBeVisible();
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST"))).toHaveLength(1);
});

test("no organizer capability means no action and no privileged request", async ({ page }) => {
  await page.evaluate(() => window.evening.mountAdmin(false));
  await expect(page.getByRole("button", { name: "Avond afsluiten…", exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(0);
});

test("response body stays inside single-flight read guard during focus bursts", async ({ page }) => {
  await page.clock.install();
  await page.evaluate(() => { window.evening.plan({ method: "GET", holdBody: true }); window.evening.mountAdmin(); });
  await page.clock.runFor(10);
  await page.evaluate(() => { for (let index = 0; index < 20; index++) window.dispatchEvent(new Event("focus")); });
  await page.clock.runFor(35_000);
  expect(await page.evaluate(() => window.evening.stats())).toMatchObject({ activeReads: 1, maxActiveReads: 1, closures: 0 });
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(1);
  await page.evaluate(() => window.evening.release());
  await page.clock.runFor(1_000);
  expect(await page.evaluate(() => window.evening.stats().maxActiveReads)).toBe(1);
});

test("recap renders immutable text safely, voluntary navigation and server read receipt", async ({ page }) => {
  await page.evaluate(() => { window.evening.close("Ons bedankbericht", "Eerste alinea.\n\nEen aanvulling. <img src=x onerror=alert(1)>"); window.evening.mountRecap(); });
  await expect(page.getByRole("heading", { name: "Bedankt, dappere Duindorpers!" })).toBeVisible();
  await expect(page.locator(".evening-message-text")).toHaveText("Eerste alinea.\n\nEen aanvulling. <img src=x onerror=alert(1)>");
  await expect(page.locator(".evening-message-text img")).toHaveCount(0);
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Bedank alle huizen", exact: true })).toHaveAttribute("href", "#thanks-all-houses");
  await expect(page.getByRole("link", { name: "Bekijk de complete Nachtpas" })).toHaveAttribute("href", "/omgeving/meeloper/nachtpas");
  await page.getByRole("button", { name: "Markeer dit bericht als gelezen" }).click();
  await expect(page.locator(".evening-read-status")).toContainText("Bericht gelezen");
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST").map(request => request.body))).toEqual([{ eventSlug: "duindorp-halloween-2026", action: "acknowledge", closureId: "closure-one" }]);
});

test("complete Nightpass shows actual frozen portals including finale for every own child", async ({ page }) => {
  await page.evaluate(() => { window.evening.close(); window.evening.mountPass(); });
  const list = page.getByRole("list", { name: "Alle vrijgegeven poortzegels" });
  await expect(list.getByRole("listitem")).toHaveCount(3);
  await expect(list).toContainText("De echte finalepoort");
  await expect(list).toContainText("Finalepoort");
  await expect(page.getByRole("list", { name: "Zegels per kind" })).toContainText("Mila");
  await expect(page.getByRole("list", { name: "Zegels per kind" })).toContainText("Sem");
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST"))).toHaveLength(0);
});

test("late login recap points to reachable thanks forms and leaves other account navigation free", async ({ page }) => {
  await page.evaluate(() => { window.evening.close(); window.evening.mountRecap(false); });
  await expect(page.getByRole("link", { name: "Bedank alle huizen", exact: true })).toHaveAttribute("href", "/omgeving/meeloper/nu#thanks-all-houses");
  await expect(page.getByRole("link", { name: "Geef een huis een extra bedankje", exact: true })).toHaveAttribute("href", "/omgeving/meeloper/nu#thanks-personal-house");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(0);
});

test("child book distinguishes gifts from physical arrival and keeps its real time", async ({ page }) => {
  await page.evaluate(() => window.evening.mountBook());
  const gift = page.locator(".pb-v2-seals article").filter({ has: page.getByRole("heading", { name: "De cadeau-finalepoort" }) });
  const physical = page.locator(".pb-v2-seals article").filter({ has: page.getByRole("heading", { name: "De fysiek bezochte poort" }) });
  await expect(gift).toContainText("Cadeauzegel van de organisatie");
  await expect(gift.locator("time")).toHaveCount(0);
  await expect(physical.locator("time")).toHaveText("20:00");
  await expect(page.locator(".pb-farewell-memory")).toContainText("De organisatie heeft alle zegels cadeau gegeven");
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(0);
});

test("401 stops automatic status requests rather than retrying a revoked organizer", async ({ page }) => {
  await page.clock.install();
  await page.evaluate(() => { window.evening.plan({ method: "GET", status: 401 }); window.evening.mountAdmin(); });
  await page.clock.runFor(50);
  await expect(page.getByText("Je toegang kon niet worden bevestigd.", { exact: false })).toBeVisible();
  await page.evaluate(() => { for (let index = 0; index < 20; index++) window.dispatchEvent(new Event("focus")); });
  await page.clock.runFor(90_000);
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(1);
  await expect(page.getByRole("button", { name: "Avond afsluiten…", exact: true })).toBeDisabled();
});

test("a status response for another event cannot enable the organizer action", async ({ page }) => {
  await page.evaluate(() => {
    const wrong = window.evening.snapshot(); wrong.event = { id: "wrong-event", slug: "another-event", title: "Another event" };
    window.evening.plan({ method: "GET", result: wrong }); window.evening.mountAdmin();
  });
  await expect(page.getByText("De afsluitstatus hoort niet bij dit evenement.", { exact: false })).toBeVisible();
  await expect(page.getByRole("button", { name: "Avond afsluiten…", exact: true })).toBeDisabled();
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST"))).toHaveLength(0);
});

test("Retry-After also prevents focus events from bypassing a status cooldown", async ({ page }) => {
  await page.clock.install();
  await page.evaluate(() => { Math.random = () => 0; window.evening.plan({ method: "GET", status: 429, headers: { "Retry-After": "130" } }); window.evening.mountAdmin(); });
  await page.clock.runFor(50);
  await expect(page.getByText("De actuele afsluitstatus kon niet worden opgehaald.", { exact: false })).toBeVisible();
  await page.evaluate(() => { for (let index = 0; index < 20; index++) window.dispatchEvent(new Event("focus")); });
  await page.clock.runFor(129_000);
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(1);
  await page.clock.runFor(2_000);
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await page.clock.runFor(1_100);
  expect(await page.evaluate(() => window.evening.requests())).toHaveLength(2);
});

for (const requeued of [0, 2]) test(`mail recovery reports the actual ${requeued} requeued jobs`, async ({ page }) => {
  await page.evaluate(() => {
    window.evening.close();
    const current = window.evening.snapshot(); current.mail!.failed = 2;
    window.evening.setSnapshot(current); window.evening.mountAdmin();
  });
  await page.getByRole("button", { name: "Alleen mislukte verzendjobs herstellen" }).click({ trial: true });
  await page.evaluate(value => window.evening.plan({ method: "POST", result: { ...window.evening.snapshot(), requeued: value } }), requeued);
  await page.getByRole("button", { name: "Alleen mislukte verzendjobs herstellen" }).click();
  await expect(page.getByRole("status")).toContainText(requeued ? "2 mislukte of aantoonbaar niet uitgevoerde verzendjob(s) opnieuw klaargezet." : "Geen verzendjobs opnieuw klaargezet; controleer de bestaande mailregistratie.");
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST").map(request => request.body))).toEqual([{ eventSlug: "duindorp-halloween-2026", action: "retry_failed" }]);
});

test("resident-only failures expose the shared recovery action without mixing campaign counts", async ({ page }) => {
  await page.evaluate(() => {
    window.evening.close();
    const current = window.evening.snapshot(); current.mail!.failed = 0; current.mail!.houseFailed = 2;
    window.evening.setSnapshot(current); window.evening.mountAdmin();
  });
  await expect(page.getByText("Mislukte bewonersberichten:", { exact: false })).toHaveText("Mislukte bewonersberichten: 2");
  const campaign = page.getByLabel("Verzendstatus bedankbericht");
  await expect(campaign).not.toContainText("bewonersberichten");
  await expect(campaign.locator("div").filter({ has: page.getByText("Mislukt", { exact: true }) }).locator("strong")).toHaveText("0");
  await page.evaluate(() => window.evening.plan({ method: "POST", result: { ...window.evening.snapshot(), requeued: 1 } }));
  await page.getByRole("button", { name: "Alleen mislukte verzendjobs herstellen" }).click();
  await expect(page.getByRole("status")).toContainText("1 mislukte of aantoonbaar niet uitgevoerde verzendjob(s) opnieuw klaargezet.");
  expect(await page.evaluate(() => window.evening.requests().filter(request => request.method === "POST").map(request => request.body))).toEqual([{ eventSlug: "duindorp-halloween-2026", action: "retry_failed" }]);
});
