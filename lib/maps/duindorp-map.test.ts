import { describe, expect, it } from "vitest";
import { DUINDORP_CENTER, DUINDORP_CENTER_SOURCE, publicMapZoom } from "./duindorp-map";

describe("public Duindorp map", () => {
  it("uses the verified OpenStreetMap position of Tesselseplein", () => {
    expect(DUINDORP_CENTER).toEqual([4.2579563, 52.0899891]);
    expect(DUINDORP_CENTER_SOURCE).toBe("https://www.openstreetmap.org/way/7497292");
  });

  it("shows a wider neighbourhood view on a small screen", () => {
    expect(publicMapZoom("preview", true)).toBeLessThan(publicMapZoom("preview", false));
    expect(publicMapZoom("public", true)).toBeLessThan(publicMapZoom("public", false));
  });
});
