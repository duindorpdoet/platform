import { expect, test, type Page } from "@playwright/test";

const now = new Date("2026-10-31T15:00:00.000Z");
const stats = (page: Page) => page.evaluate(() => window.__poortenboekTest.stats());
const reads = async (page: Page) => (await stats(page)).records.filter(record => record.method === "GET");

async function ready(page: Page, installClock = true) {
  if (installClock) {
    await page.clock.install({ time: now });
    await page.clock.pauseAt(now);
  }
  await page.goto("/");
  await expect.poll(() => page.evaluate(() => Boolean(window.__poortenboekTest?.ready))).toBe(true);
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toBeVisible();
  await expect.poll(async () => (await stats(page)).readActive).toBe(0);
}
async function triggerHeldRead(page: Page, phase: "headers" | "body" = "body", ignoreAbort = false) {
  await page.evaluate(({ phase, ignoreAbort }) => {
    window.__poortenboekTest.hidden(true);
    window.__poortenboekTest.queueRead({ holdHeaders: phase === "headers", holdBody: phase === "body", ignoreAbort });
    window.__poortenboekTest.hidden(false);
  }, { phase, ignoreAbort });
  await expect.poll(async () => (await reads(page)).at(-1)?.phase).toBe(phase);
  return (await reads(page)).at(-1)!.id;
}

test("Strict Mode: slow body, focus/online/manual/poll bursts share one active read and one follow-up", async ({ page }) => {
  await ready(page);
  const before = (await reads(page)).length;
  const held = await triggerHeldRead(page);
  await page.evaluate(() => window.__poortenboekTest.burst());
  await page.getByRole("button", { name: "Opnieuw proberen", exact: true }).click();
  await page.clock.runFor(12_000);
  expect((await reads(page)).length).toBe(before + 1);
  expect((await stats(page)).readActive).toBe(1);
  await page.evaluate(id => window.__poortenboekTest.releaseBody(id), held);
  await expect.poll(async () => (await reads(page)).length).toBe(before + 2);
  expect((await stats(page)).maxReadActive).toBe(1);
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toBeVisible();
});

test("503/504/network failures back off 5, 10, 20, 30 seconds and recover to one 12-second poll", async ({ page }) => {
  await ready(page);
  const before = (await reads(page)).length;
  await page.evaluate(() => {
    window.__poortenboekTest.queueRead({ status: 503 }, { status: 504 }, { networkError: true }, { status: 503 }, {});
    window.dispatchEvent(new Event("focus"));
  });
  await expect.poll(async () => (await reads(page)).length).toBe(before + 1);
  await expect(page.getByText("Verversen lukt even niet. Je ziet de laatst bevestigde stand.")).toBeVisible();
  for (const [index, delay] of [5_000, 10_000, 20_000, 30_000].entries()) {
    await page.evaluate(() => window.__poortenboekTest.burst());
    await page.clock.runFor(delay - 1);
    expect((await reads(page)).length).toBe(before + index + 1);
    await page.clock.runFor(1);
    await expect.poll(async () => (await reads(page)).length).toBe(before + index + 2);
  }
  await expect(page.getByText("Verversen lukt even niet. Je ziet de laatst bevestigde stand.")).toHaveCount(0);
  await page.clock.runFor(11_999);
  expect((await reads(page)).length).toBe(before + 5);
  await page.clock.runFor(1);
  await expect.poll(async () => (await reads(page)).length).toBe(before + 6);
  expect((await stats(page)).maxReadActive).toBe(1);
});

test("429 Retry-After cannot be bypassed by focus/online events", async ({ page }) => {
  await ready(page);
  const before = (await reads(page)).length;
  await page.evaluate(() => {
    window.__poortenboekTest.queueRead({ status: 429, headers: { "Retry-After": "45" } });
    window.dispatchEvent(new Event("focus"));
  });
  await expect.poll(async () => (await reads(page)).length).toBe(before + 1);
  await page.evaluate(() => window.__poortenboekTest.burst());
  await page.clock.runFor(44_999);
  expect((await reads(page)).length).toBe(before + 1);
  await page.clock.runFor(1);
  await expect.poll(async () => (await reads(page)).length).toBe(before + 2);
});

test("hidden/offline states clear private data, abort reads, and stop polling until one resume", async ({ page }) => {
  await ready(page);
  const held = await triggerHeldRead(page);
  await page.evaluate(() => window.__poortenboekTest.hidden(true));
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toHaveCount(0);
  await expect.poll(async () => (await reads(page)).find(record => record.id === held)?.aborted).toBe(true);
  const count = (await reads(page)).length;
  await page.clock.runFor(60_000);
  expect((await reads(page)).length).toBe(count);
  await page.evaluate(() => { window.__poortenboekTest.online(false); window.__poortenboekTest.hidden(false); });
  await page.clock.runFor(60_000);
  expect((await reads(page)).length).toBe(count);
  await page.evaluate(() => window.__poortenboekTest.online(true));
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toBeVisible();
  expect((await reads(page)).length).toBe(count + 1);
  expect((await stats(page)).maxReadActive).toBe(1);
});

test("late body after child switch or unmount cannot restore the old child", async ({ page }) => {
  await ready(page);
  const held = await triggerHeldRead(page, "body", true);
  await page.evaluate(() => window.__poortenboekTest.renderBook("child-b", "Sem"));
  await expect(page.getByText("Welkom terug, Sem", { exact: true })).toBeVisible();
  await page.evaluate(id => window.__poortenboekTest.releaseBody(id), held);
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toHaveCount(0);
  const heldSecond = await triggerHeldRead(page, "body", true);
  await page.evaluate(() => window.__poortenboekTest.unmount());
  await page.evaluate(id => window.__poortenboekTest.releaseBody(id), heldSecond);
  const count = (await reads(page)).length;
  await page.clock.runFor(60_000);
  expect((await reads(page)).length).toBe(count);
  await expect(page.locator("#root")).toBeEmpty();
});

test("checklist mutation is sent once, never shares snapshot abort, and unknown outcome stays unconfirmed", async ({ page }) => {
  await ready(page);
  await page.evaluate(() => window.__poortenboekTest.queueMutation({ holdHeaders: true }));
  const checkbox = page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true });
  await checkbox.click();
  await expect.poll(async () => (await stats(page)).records.filter(record => record.method === "POST").length).toBe(1);
  await expect(checkbox).not.toBeChecked();
  const mutation = (await stats(page)).records.find(record => record.method === "POST")!;
  expect(mutation.hasSignal).toBe(false);
  await page.evaluate(() => window.__poortenboekTest.burst());
  await page.clock.runFor(30_000);
  expect((await stats(page)).records.filter(record => record.method === "POST")).toHaveLength(1);
  expect((await stats(page)).records.find(record => record.id === mutation.id)?.aborted).toBe(false);
  await page.evaluate(id => window.__poortenboekTest.releaseHeaders(id), mutation.id);
  await expect(checkbox).toBeEnabled();
  await expect(checkbox).not.toBeChecked();
  // A separate manual action with a lost response is never retried automatically.
  await page.evaluate(() => window.__poortenboekTest.queueMutation({ networkError: true }));
  await checkbox.click();
  await expect(page.getByText("De wijziging is nog niet bevestigd. Controleer je boek voordat je het opnieuw probeert.")).toBeVisible();
  await page.clock.runFor(30_000);
  expect((await stats(page)).records.filter(record => record.method === "POST")).toHaveLength(2);
  await expect(checkbox).not.toBeChecked();
});

test("KidGuide recovers after unavailable shared read when a fresh authorized snapshot arrives", async ({ page }) => {
  await ready(page);
  await page.evaluate(() => window.__poortenboekTest.renderUnavailableGuide());
  await expect(page.getByRole("alert")).toContainText("De uitleg wacht op een actuele verbinding.");
  await expect(page.getByRole("button", { name: "Verder", exact: true })).toBeDisabled();
  await page.evaluate(() => window.__poortenboekTest.freshGuideSnapshot());
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Verder", exact: true })).toBeEnabled();
});

for (const status of [401, 403]) {
  test(`snapshot ${status} clears private content and follows safe reauthentication`, async ({ page }) => {
    await ready(page);
    await page.route("**/poortenboek/inloggen", route => route.fulfill({
      contentType: "text/html", body: "<!doctype html><h1>Veilig opnieuw openen</h1>",
    }));
    await page.evaluate(status => {
      window.__poortenboekTest.queueRead({ status });
      window.dispatchEvent(new Event("focus"));
    }, status);
    await expect(page).toHaveURL(/\/poortenboek\/inloggen$/);
    await expect(page.getByRole("heading", { name: "Veilig opnieuw openen" })).toBeVisible();
    await expect(page.getByText("Welkom terug, Mila", { exact: true })).toHaveCount(0);
  });
}

test("late unauthorized mutation from an unmounted child cannot log out the new child", async ({ page }) => {
  await ready(page);
  await page.evaluate(() => window.__poortenboekTest.queueMutation({ holdHeaders: true, status: 401 }));
  await page.getByRole("checkbox", { name: "Snoeptas klaar", exact: true }).click();
  const mutation = (await stats(page)).records.find(record => record.method === "POST")!;
  await page.evaluate(() => window.__poortenboekTest.renderBook("child-b", "Sem"));
  await expect(page.getByText("Welkom terug, Sem", { exact: true })).toBeVisible();
  await page.evaluate(id => window.__poortenboekTest.releaseHeaders(id), mutation.id);
  await expect(page.getByText("Welkom terug, Sem", { exact: true })).toBeVisible();
  await expect(page).not.toHaveURL(/inloggen/);
  expect((await stats(page)).records.filter(record => record.method === "POST")).toHaveLength(1);
});

test("timeout during a body that ignores abort retains the in-flight guard until settlement", async ({ page }) => {
  await ready(page);
  const held = await triggerHeldRead(page, "body", true);
  const before = (await reads(page)).length;
  await page.clock.runFor(15_000);
  await page.evaluate(() => window.__poortenboekTest.burst());
  expect((await reads(page)).find(record => record.id === held)?.aborted).toBe(true);
  expect((await reads(page)).length).toBe(before);
  expect((await stats(page)).readActive).toBe(1);
  await page.evaluate(id => window.__poortenboekTest.releaseBody(id), held);
  await expect.poll(async () => (await stats(page)).readActive).toBe(0);
  await page.clock.runFor(4_999);
  expect((await reads(page)).length).toBe(before);
  await page.clock.runFor(1);
  await expect.poll(async () => (await reads(page)).length).toBe(before + 1);
  expect((await stats(page)).maxReadActive).toBe(1);
});

test("late response after privacy hiding cannot make private content visible", async ({ page }) => {
  await ready(page);
  const held = await triggerHeldRead(page, "body", true);
  await page.evaluate(() => window.__poortenboekTest.hidden(true));
  await page.evaluate(id => window.__poortenboekTest.releaseBody(id), held);
  await expect.poll(async () => (await stats(page)).readActive).toBe(0);
  const count = (await reads(page)).length;
  await page.clock.runFor(60_000);
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toHaveCount(0);
  expect((await reads(page)).length).toBe(count);
});

test("session expiry still clears private content while polling is paused offline", async ({ page }) => {
  await ready(page);
  await page.route("**/poortenboek/inloggen", route => route.fulfill({
    contentType: "text/html", body: "<!doctype html><h1>Veilig opnieuw openen</h1>",
  }));
  await page.evaluate(() => window.__poortenboekTest.renderBook("child-a", "Mila", new Date(Date.now() + 1_000).toISOString()));
  await expect(page.getByText("Welkom terug, Mila", { exact: true })).toBeVisible();
  await page.evaluate(() => window.__poortenboekTest.online(false));
  await page.clock.runFor(1_000);
  await expect(page).toHaveURL(/\/poortenboek\/inloggen$/);
  await expect(page.getByRole("heading", { name: "Veilig opnieuw openen" })).toBeVisible();
});

test("two tabs keep independent serial queues and each retain their normal polling load", async ({ page, context }) => {
  await ready(page);
  const second = await context.newPage();
  // Playwright's clock is shared by every page in this browser context.
  await ready(second, false);
  const firstCount = (await reads(page)).length;
  const secondCount = (await reads(second)).length;
  await page.clock.runFor(12_000);
  await expect.poll(async () => (await reads(page)).length).toBe(firstCount + 1);
  await expect.poll(async () => (await reads(second)).length).toBe(secondCount + 1);
  expect((await stats(page)).maxReadActive).toBe(1);
  expect((await stats(second)).maxReadActive).toBe(1);
});
