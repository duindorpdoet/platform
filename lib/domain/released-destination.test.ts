import { describe, expect, it } from "vitest";
import { destinationNavigationUrl } from "./released-destination";

describe("released entrance navigation", () => {
  it("uses the exact entrance longitude/latitude pair in the provider's latitude/longitude order", () => {
    const url = new URL(destinationNavigationUrl([4.261234, 52.091234])!);
    expect(url.searchParams.get("destination")).toBe("52.091234,4.261234");
    expect(url.searchParams.get("travelmode")).toBe("walking");
  });
  it("never creates a navigation destination for a missing, incomplete or invalid pin", () => {
    for (const coordinate of [null, undefined, [NaN, 52], [4, Infinity], [4, 91], [181, 52], [null, 52], [4]] as unknown as Array<[number, number] | null | undefined>) {
      expect(destinationNavigationUrl(coordinate)).toBeNull();
    }
  });
});
