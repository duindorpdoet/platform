import { describe, expect, it } from "vitest";
import { analyticsSurfaceForPath } from "./client";

describe("analyticsSurfaceForPath", () => {
  it.each([
    ["/admin", "admin"],
    ["/admin/poortkamer/123", "admin"],
    ["/mijn-huis", "homeowner"],
    ["/omgeving/huiseigenaar/mijn-poort", "homeowner"],
    ["/mijn-groep", "group"],
    ["/omgeving/meeloper/nu", "group"],
    ["/poortenboek", "child"],
    ["/deel-de-magie", "share_studio"],
    ["/omgeving/communicatie", "editorial"],
    ["/omgeving", "participant"],
    ["/mijn-inschrijving", "participant"],
    ["/", "unknown"],
  ])("maps %s to %s", (path, surface) => {
    expect(analyticsSurfaceForPath(path)).toBe(surface);
  });
});
