import { describe, expect, it } from "vitest";
import { locationCoordinate, parseCoordinatePart } from "./location-readiness";

describe("location input at the editor boundary", () => {
  it("accepts decimal commas without turning missing input into zero", () => {
    expect(parseCoordinatePart("52,090123")).toBe(52.090123);
    expect(parseCoordinatePart(" 4.260001 ")).toBe(4.260001);
    for (const text of ["", " ", "NaN", "Infinity", "4,2,6", "4.2x", "0x20"]) {
      expect(parseCoordinatePart(text)).toBeNull();
    }
  });
  it("requires a complete finite pair in longitude/latitude order", () => {
    expect(locationCoordinate(4.26, 52.09)).toEqual([4.26, 52.09]);
    for (const pair of [[null, 52], [4, null], [NaN, 52], [4, Infinity], [4, 91], [-181, 52]] as const) {
      expect(locationCoordinate(pair[0], pair[1])).toBeNull();
    }
  });
});
