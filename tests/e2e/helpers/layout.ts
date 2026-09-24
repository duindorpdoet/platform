import { expect, type Page } from "@playwright/test";

export async function assertReadableLayout(page: Page, doubleText = false) {
  if (doubleText) {
    await page.evaluate(() => {
      const elements = [...document.querySelectorAll<HTMLElement>("body, body *")];
      const sizes = elements.map((element) => {
        const style = getComputedStyle(element);
        return { font: parseFloat(style.fontSize), line: parseFloat(style.lineHeight) };
      });
      elements.forEach((element, index) => {
        element.style.fontSize = `${sizes[index].font * 2}px`;
        if (Number.isFinite(sizes[index].line)) element.style.lineHeight = `${sizes[index].line * 2}px`;
      });
    });
  }
  await expect(page.locator("h1").first()).toBeVisible();
  const overflow = await page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    return [...document.querySelectorAll<HTMLElement>("main h1, main h2, main input:not([type=hidden]), main select, main textarea, main button")]
      .filter((element) => {
        if (!element.checkVisibility() || element.closest(".honeypot")) return false;
        // MapLibre keeps focusable markers just outside the viewport while its
        // canvas pans; the map container deliberately clips that map content.
        if (element.closest(".maplibregl-map")) return false;
        // Tables and navigation strips may intentionally scroll horizontally.
        for (let parent = element.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
          if (["auto", "scroll"].includes(getComputedStyle(parent).overflowX)) return false;
        }
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && (rect.left < -1 || rect.right > width + 1);
      }).map((element) => `${element.tagName}: ${(element.textContent || element.getAttribute("aria-label") || element.getAttribute("name") || "").trim().slice(0, 80)}`);
  });
  expect(overflow, `Clipped controls or headings at ${page.url()}`).toEqual([]);
}
