import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin !== "http://127.0.0.1:3220" || !["GET", "HEAD"].includes(route.request().method())) return route.abort("blockedbyclient");
    return route.continue();
  });
  await page.goto("/");
});

test("Enter, empty lines and the keyboard preview remain readable without publishing", async ({ page }) => {
  await page.getByLabel("Bericht · tekst of HTML").fill("Beste deelnemers,\n\nNeem je lantaarn mee.\nTot straks!");
  const toggle = page.getByRole("button", { name: "Voorbeeld bekijken", exact: true });
  await toggle.focus(); await page.keyboard.press("Enter");
  const preview = page.getByRole("region", { name: "Voorbeeld van de update" });
  await expect(preview.locator(".participant-update-content")).toHaveText("Beste deelnemers,Neem je lantaarn mee.Tot straks!");
  await expect(preview.locator("br")).toHaveCount(3);
  await preview.getByRole("button", { name: "Alleen tekst", exact: true }).click();
  await expect(preview.locator(".participant-update-plain")).toHaveText("Beste deelnemers,\n\nNeem je lantaarn mee.\nTot straks!");
  await expect(page.getByRole("button", { name: "Publiceer update" })).toBeDisabled();
  await page.getByRole("button", { name: "Voorbeeld sluiten" }).press("Enter");
  await expect(preview).toHaveCount(0);
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});

test("HTML renders safely, strips active content and fits a phone with a wide image", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.route("https://updates-image.invalid/photo.svg", route => route.fulfill({ contentType: "image/svg+xml", body: '<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="900"><rect width="1500" height="900" fill="#b96831"/></svg>' }));
  await page.getByLabel("Bericht · tekst of HTML").fill('<h2>Tot vanavond</h2><p><strong>Neem licht mee</strong><br>Regel twee</p><script>window.updateXss=true</script><img src="https://updates-image.invalid/photo.svg" alt="Koperkleurig testbeeld" onerror="window.updateXss=true"><a href="javascript:alert(1)">Verboden link</a>');
  await page.getByRole("button", { name: "Voorbeeld bekijken", exact: true }).click();
  const preview = page.getByRole("region", { name: "Voorbeeld van de update" });
  for (const name of ["Opgemaakt", "Alleen tekst"]) {
    const dimensions = await preview.getByRole("button", { name, exact: true }).evaluate(button => ({ width: button.getBoundingClientRect().width, height: button.getBoundingClientRect().height }));
    expect(dimensions.width).toBeGreaterThan(110);
    expect(dimensions.height).toBeLessThan(70);
  }
  const content = preview.locator(".participant-update-content");
  await expect(content.getByRole("heading", { name: "Tot vanavond" })).toBeVisible();
  await expect(content.locator("strong")).toHaveText("Neem licht mee");
  await expect(content.locator("script,[onerror],[href^='javascript:']")).toHaveCount(0);
  const image = content.getByRole("img", { name: "Koperkleurig testbeeld" });
  await expect(image).toBeVisible();
  expect(await image.evaluate(async node => { await (node as HTMLImageElement).decode(); return (node as HTMLImageElement).naturalWidth; })).toBe(1500);
  expect(await image.evaluate(node => node.getBoundingClientRect().width)).toBeLessThanOrEqual(358);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  expect(await page.evaluate(() => "updateXss" in window)).toBe(false);
  const hiddenRequests: string[] = [];
  page.on("request", request => { if (new URL(request.url()).hostname === "hidden.example.invalid") hiddenRequests.push(request.url()); });
  for (const tag of ["noscript", "style", "textarea", "script", "xmp"]) {
    await page.getByLabel("Bericht · tekst of HTML").fill(`<p>Veilig</p><![CDATA[ x > <${tag}>]]><a href="https://hidden.example.invalid">Verborgen</a><img src="https://hidden.example.invalid/beacon.gif"></${tag}>`);
    await expect.poll(() => content.evaluate(node => node.innerHTML.trim())).toBe("<p>Veilig</p>");
    await expect(content.locator("a,img")).toHaveCount(0);
  }
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  expect(hiddenRequests).toEqual([]);
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});

test("image helper validates HTTPS and description, escapes attributes and returns focus", async ({ page }) => {
  await page.getByText("Afbeelding invoegen via een URL", { exact: true }).click();
  await page.getByLabel("HTTPS-adres van de afbeelding").fill("http://updates-image.invalid/photo.jpg");
  await page.getByLabel("Beschrijving van de afbeelding").fill('Een lamp "en" licht');
  await page.getByRole("button", { name: "Afbeelding aan bericht toevoegen" }).click();
  await expect(page.getByRole("status")).toContainText("Gebruik een https-adres");
  await expect(page.getByLabel("Bericht · tekst of HTML")).toHaveValue("");
  await page.getByLabel("HTTPS-adres van de afbeelding").fill("https://updates-image.invalid/photo.jpg?x=1&y=2");
  await page.getByRole("button", { name: "Afbeelding aan bericht toevoegen" }).click();
  await expect(page.getByLabel("Bericht · tekst of HTML")).toHaveValue('<img src="https://updates-image.invalid/photo.jpg?x=1&amp;y=2" alt="Een lamp &quot;en&quot; licht">');
  await expect(page.getByLabel("Bericht · tekst of HTML")).toBeFocused();
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});

test("only active content cannot be published and longer legitimate source remains accepted", async ({ page }) => {
  await page.getByLabel("Titel", { exact: true }).fill("Avondupdate");
  const body = page.getByLabel("Bericht · tekst of HTML");
  await expect(body).toHaveAttribute("maxlength", "20000");
  await body.fill('<script>alert("geen bericht")</script>');
  await expect(page.getByRole("button", { name: "Publiceer update" })).toBeDisabled();
  await body.fill("Een langere update. ".repeat(100));
  await expect(page.getByRole("button", { name: "Publiceer update" })).toBeEnabled();
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});

test("publishing keeps the original RPC payload and explicit confirmation with optional mail off", async ({ page }) => {
  await page.getByLabel("Titel", { exact: true }).fill("Avondupdate");
  const html = "<p>Beste deelnemers,</p><p>Neem een <strong>lantaarn</strong> mee.</p>";
  await page.getByLabel("Bericht · tekst of HTML").fill(html);
  await page.getByRole("combobox", { name: "Doelgroep", exact: true }).selectOption("walker");
  await page.getByRole("checkbox").uncheck();
  page.once("dialog", dialog => dialog.dismiss());
  await page.getByRole("button", { name: "Publiceer update" }).click();
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
  page.once("dialog", dialog => { expect(dialog.message()).toContain("zonder e-mail"); return dialog.accept(); });
  await page.getByRole("button", { name: "Publiceer update" }).click();
  await expect(page.getByRole("status")).toHaveText("Update gepubliceerd.");
  expect(await page.evaluate(() => window.updateCalls)).toEqual([{ name: "admin_publish_participant_update", payload: { _event_slug: "updates-component-test", _audience_role: "walker", _title: "Avondupdate", _body: html, _priority: "normal", _send_email: false } }]);
});

test("important updates retain their existing compulsory mail behavior", async ({ page }) => {
  await page.getByLabel("Titel", { exact: true }).fill("Veiligheidsupdate");
  await page.getByLabel("Bericht · tekst of HTML").fill("Volg de aanwijzingen van de organisatie.");
  await page.getByRole("checkbox").uncheck();
  await page.getByRole("combobox", { name: "Prioriteit", exact: true }).selectOption("important");
  await expect(page.getByRole("checkbox")).toBeChecked();
  await expect(page.getByRole("checkbox")).toBeDisabled();
  page.once("dialog", dialog => dialog.accept());
  await page.getByRole("button", { name: "Publiceer update" }).click();
  await expect(page.getByRole("status")).toContainText("2 e-mailmeldingen klaargezet");
  expect((await page.evaluate(() => window.updateCalls))[0].payload._send_email).toBe(true);
});

test("the 2026 withdrawal template is selectable and fills only an unpublished concept", async ({ page }) => {
  await page.goto("/?event=2026");
  await page.getByRole("combobox", { name: "Doelgroep", exact: true }).selectOption("homeowner");
  await page.getByRole("combobox", { name: "Prioriteit", exact: true }).selectOption("important");
  await page.getByText("Sjabloon: betaalverzoek ingetrokken", { exact: true }).click();
  await expect(page.getByText("Dit sjabloon trekt geen betaalverzoeken in.", { exact: false })).toBeVisible();
  await expect(page.getByText("zonder individueel betaalfilter", { exact: false })).toBeVisible();
  const source = page.getByLabel("Kopieerbare HTML van het sjabloon");
  await expect(source).toHaveAttribute("readonly", "");
  const html = await source.inputValue();
  expect(html).toContain("Gebruik de oude betaallink niet meer.");
  expect(html).toContain("Staat er volgens onze administratie daarna nog een bedrag open");
  expect(html).toContain("Hebben jullie via de eerdere link al betaald en is dat nog niet verwerkt?");
  expect(html.match(/<p>/g)).toHaveLength(3);
  expect(html).not.toMatch(/<!doctype|<html|<img|Groetjes|Team Duindorpse Poorten|Vragen\?|Je ontvangt deze mail|Website:/i);
  await page.getByRole("button", { name: "Selecteer sjabloon", exact: true }).click();
  await expect(source).toBeFocused();
  expect(await source.evaluate(node => { const textarea = node as HTMLTextAreaElement; return { start: textarea.selectionStart, end: textarea.selectionEnd }; })).toEqual({ start: 0, end: html.length });
  const unexpectedDialogs: string[] = [];
  page.on("dialog", dialog => { unexpectedDialogs.push(dialog.message()); return dialog.dismiss(); });
  await page.getByRole("button", { name: "Gebruik als concept", exact: true }).click();
  await expect(page.getByLabel("Titel", { exact: true })).toHaveValue("Het eerdere betaalverzoek is ingetrokken");
  await expect(page.getByLabel("Bericht · tekst of HTML")).toHaveValue(html);
  await expect(page.getByRole("combobox", { name: "Doelgroep", exact: true })).toHaveValue("homeowner");
  await expect(page.getByRole("combobox", { name: "Prioriteit", exact: true })).toHaveValue("important");
  await expect(page.getByRole("checkbox")).toBeChecked();
  await expect(page.getByRole("checkbox")).toBeDisabled();
  await expect(page.getByRole("status")).toContainText("Er is niets gepubliceerd of verstuurd.");
  expect(unexpectedDialogs).toEqual([]);
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});

test("template overwrite requires confirmation, preserves delivery choices and is absent outside 2026", async ({ page }) => {
  await expect(page.getByText("Sjabloon: betaalverzoek ingetrokken", { exact: true })).toHaveCount(0);
  await page.goto("/?event=2026");
  await page.getByRole("combobox", { name: "Doelgroep", exact: true }).selectOption("walker");
  await page.getByRole("checkbox").uncheck();
  await page.getByLabel("Titel", { exact: true }).fill("Eigen concept");
  await page.getByLabel("Bericht · tekst of HTML").fill("Deze eigen tekst moet bewaard blijven.");
  await page.getByText("Sjabloon: betaalverzoek ingetrokken", { exact: true }).click();
  page.once("dialog", dialog => dialog.dismiss());
  await page.getByRole("button", { name: "Gebruik als concept", exact: true }).click();
  await expect(page.getByLabel("Titel", { exact: true })).toHaveValue("Eigen concept");
  await expect(page.getByLabel("Bericht · tekst of HTML")).toHaveValue("Deze eigen tekst moet bewaard blijven.");
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
  page.once("dialog", dialog => { expect(dialog.message()).toContain("Je huidige titel en bericht vervangen"); return dialog.accept(); });
  await page.getByRole("button", { name: "Gebruik als concept", exact: true }).click();
  await expect(page.getByLabel("Titel", { exact: true })).toHaveValue("Het eerdere betaalverzoek is ingetrokken");
  await expect(page.getByLabel("Bericht · tekst of HTML")).toHaveValue(await page.getByLabel("Kopieerbare HTML van het sjabloon").inputValue());
  await expect(page.getByRole("combobox", { name: "Doelgroep", exact: true })).toHaveValue("walker");
  await expect(page.getByRole("combobox", { name: "Prioriteit", exact: true })).toHaveValue("normal");
  await expect(page.getByRole("checkbox")).not.toBeChecked();
  await expect(page.getByRole("checkbox")).toBeEnabled();
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
  await page.goto("/?event=2027");
  await expect(page.getByText("Sjabloon: betaalverzoek ingetrokken", { exact: true })).toHaveCount(0);
  await expect(page.getByLabel("Titel", { exact: true })).toHaveValue("");
  expect(await page.evaluate(() => window.updateCalls ?? [])).toEqual([]);
});
