import { describe, expect, it } from "vitest";
import { parseLatitudeLongitude } from "@/lib/maps/coordinates";

describe("parseLatitudeLongitude", () => {
  it("accepts latitude and longitude in one comma-separated field", () => {
    expect(parseLatitudeLongitude("52.090522, 4.262384")).toEqual({
      latitude: 52.090522,
      longitude: 4.262384,
    });
  });

  it("accepts whitespace and negative coordinates", () => {
    expect(parseLatitudeLongitude(" -33.8688, 151.2093 ")).toEqual({
      latitude: -33.8688,
      longitude: 151.2093,
    });
  });

  it.each(["52,090522, 4,262384", "91, 4", "52, 181", "52.09 4.26", ""])(
    "rejects %j",
    (value) => expect(parseLatitudeLongitude(value)).toBeNull(),
  );
});
