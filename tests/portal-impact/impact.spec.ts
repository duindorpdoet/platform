import { test, expect } from "@playwright/test";
test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.certificateTexts = []; window.shareCalls = []; window.downloads = []; window.pendingCanvas = []; window.holdCanvas = false; window.shareMode = "success";
    const text = CanvasRenderingContext2D.prototype.fillText;
    CanvasRenderingContext2D.prototype.fillText = function (value, x, y, max) { window.certificateTexts.push(value); if (max === undefined) text.call(this, value, x, y); else text.call(this, value, x, y, max); };
    const blob = HTMLCanvasElement.prototype.toBlob;
    HTMLCanvasElement.prototype.toBlob = function (callback, type, quality) { const run = () => blob.call(this, callback, type, quality); if (window.holdCanvas) window.pendingCanvas.push(run); else run(); };
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () { if (this.download) window.downloads.push(this.download); click.call(this); };
    Object.defineProperty(navigator, "canShare", { configurable: true, value: () => true });
    Object.defineProperty(navigator, "share", { configurable: true, value: async (data: ShareData) => {
      window.shareCalls.push({ name: data.files![0].name, type: data.files![0].type, size: data.files![0].size, active: navigator.userActivation.isActive });
      if (window.shareMode === "cancel") throw new DOMException("Cancelled", "AbortError");
      if (window.shareMode === "hold") await new Promise<void>(resolve => { window.releaseShare = resolve; });
    } });
  });
  await page.goto("/"); await page.waitForFunction(() => Boolean(window.portalImpact));
});
test("certificate uses explicit registered totals, separate from physical arrivals and gifts, and contains only public fields", async ({ page }) => {
  await page.evaluate(() => window.portalImpact.mount());
  await expect(page.getByTestId("overview-counts")).toHaveText("12Geregistreerde groepen47Geregistreerde kids");
  await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeEnabled();
  const text = await page.evaluate(() => window.certificateTexts.join("\n"));
  expect(text).toContain("De warme pompoen"); expect(text).toContain("P-42"); expect(text).toContain("2026"); expect(text).not.toContain("PRIVATE"); expect(text).not.toContain("999");
  const texts = await page.evaluate(() => window.certificateTexts);
  expect(texts).toContain("12"); expect(texts).toContain("47"); expect(texts).not.toContain("3"); expect(texts).not.toContain("8");
  expect(texts).toContain("Geregistreerde groepen"); expect(texts).toContain("Geregistreerde kids"); expect(text).not.toMatch(/langsgekomen|fysieke aankomsten/);
  expect(await page.evaluate(() => ({ shares: window.shareCalls.length, downloads: window.downloads.length }))).toEqual({ shares: 0, downloads: 0 });
  await page.getByRole("button", { name: "Certificaat delen" }).click();
  await expect(page.getByRole("status")).toHaveText("De deelactie is voltooid.");
  const calls = await page.evaluate(() => window.shareCalls); expect(calls).toHaveLength(1); expect(calls[0]).toMatchObject({ name: "certificaat-P-42-2026.png", type: "image/png", active: true }); expect(calls[0].size).toBeGreaterThan(1000);
});
test("missing registered totals never export actual arrivals, legacy recap counts or gift seals", async ({ page }) => {
  await page.evaluate(() => window.portalImpact.mount({ registeredImpact: undefined }));
  await expect(page.getByTestId("overview-counts")).toHaveText("—Geregistreerde groepen—Geregistreerde kids");
  await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeDisabled(); await expect(page.getByText("De geregistreerde aantallen zijn nog niet beschikbaar. Herlaad de pagina om ze op te halen.")).toBeVisible();
});
test("explicit zero registered totals remain valid independently of actual arrivals", async ({ page }) => {
  await page.evaluate(() => window.portalImpact.mount({ registeredImpact: { registeredGroups: 0, registeredChildren: 0 } }));
  await expect(page.getByTestId("overview-counts")).toHaveText("0Geregistreerde groepen0Geregistreerde kids");
  await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeEnabled();
  expect(await page.evaluate(() => window.certificateTexts)).not.toContain("3");
});
test("a new snapshot without registered totals invalidates a previously prepared certificate", async ({ page }) => {
  await page.evaluate(() => window.portalImpact.mount()); await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeEnabled();
  await page.evaluate(() => window.portalImpact.mount({ registeredImpact: undefined }));
  await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Download PNG" })).toBeDisabled();
  expect(await page.evaluate(() => ({ shares: window.shareCalls.length, downloads: window.downloads.length }))).toEqual({ shares: 0, downloads: 0 });
});
test("unsupported file sharing downloads one PNG on the explicit click", async ({ page }) => {
  await page.evaluate(() => { Object.defineProperty(navigator, "canShare", { value: () => false }); window.portalImpact.mount(); });
  const button = page.getByRole("button", { name: "Certificaat delen" }); await expect(button).toBeEnabled();
  const [download] = await Promise.all([page.waitForEvent("download"), button.click()]);
  expect(download.suggestedFilename()).toBe("certificaat-P-42-2026.png");
  const stream = await download.createReadStream(); const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  const bytes = Buffer.concat(chunks); expect([...bytes.subarray(0, 8)]).toEqual([137,80,78,71,13,10,26,10]); expect(bytes.readUInt32BE(16)).toBe(1600); expect(bytes.readUInt32BE(20)).toBe(1100);
  await expect(page.getByRole("status")).toHaveText("Het certificaat is als PNG gedownload."); expect(await page.evaluate(() => window.downloads)).toEqual(["certificaat-P-42-2026.png"]); expect(await page.evaluate(() => window.shareCalls)).toHaveLength(0);
});
test("cancelling a native share never falls back to download or repeats the action", async ({ page }) => {
  await page.evaluate(() => { window.shareMode = "cancel"; window.portalImpact.mount(); });
  const button = page.getByRole("button", { name: "Certificaat delen" }); await expect(button).toBeEnabled(); await button.click();
  await expect(page.getByRole("status")).toHaveText("Delen geannuleerd."); expect(await page.evaluate(() => window.shareCalls)).toHaveLength(1); expect(await page.evaluate(() => window.downloads)).toHaveLength(0);
});
test("one in-flight share disables duplicate actions", async ({ page }) => {
  await page.evaluate(() => { window.shareMode = "hold"; window.portalImpact.mount(); });
  const button = page.getByRole("button", { name: "Certificaat delen" }); await expect(button).toBeEnabled(); await button.dblclick();
  await expect(page.getByRole("button", { name: "Delen…" })).toBeDisabled(); expect(await page.evaluate(() => window.shareCalls)).toHaveLength(1);
  await page.evaluate(() => window.releaseShare?.()); await expect(page.getByRole("status")).toHaveText("De deelactie is voltooid.");
});
test("a delayed old canvas cannot restore or export another portal after an account/portal switch", async ({ page }) => {
  await page.evaluate(() => { window.holdCanvas = true; window.portalImpact.mount(); });
  await page.waitForFunction(() => window.pendingCanvas.length > 0); await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeDisabled();
  await page.evaluate(() => window.portalImpact.switchPortal()); await page.waitForFunction(() => window.pendingCanvas.length > 1);
  await page.evaluate(() => { window.pendingCanvas.shift()?.(); }); await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeDisabled();
  await page.evaluate(() => { window.pendingCanvas.splice(0).forEach(run => run()); }); await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeEnabled();
  await page.getByRole("button", { name: "Certificaat delen" }).click(); expect(await page.evaluate(() => window.shareCalls.map(call => call.name))).toEqual(["certificaat-P-99-2026.png"]);
});
test("unmount invalidates delayed export preparation and never opens a share or download", async ({ page }) => {
  await page.evaluate(() => { window.holdCanvas = true; window.portalImpact.mount(); }); await page.waitForFunction(() => window.pendingCanvas.length > 0);
  await page.evaluate(() => { window.portalImpact.unmount(); window.pendingCanvas.splice(0).forEach(run => run()); }); await expect(page.getByRole("button")).toHaveCount(0);
  expect(await page.evaluate(() => ({ shares: window.shareCalls.length, downloads: window.downloads.length }))).toEqual({ shares: 0, downloads: 0 });
});
test("the certificate and actions fit a narrow mobile viewport", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 }); await page.evaluate(() => window.portalImpact.mount()); await expect(page.getByRole("button", { name: "Certificaat delen" })).toBeEnabled();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: test.info().outputPath("certificate-mobile.png") });
});
