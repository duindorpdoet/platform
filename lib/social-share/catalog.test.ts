import { describe, expect, it } from "vitest";
import { interpolateShareText, privacySafeSerialized, shareFormats } from "./catalog";

describe("Deelstudio catalog", () => {
  it("defines every requested output size", () => {
    expect(shareFormats).toMatchObject({
      story: { width: 1080, height: 1920 }, feed: { width: 1080, height: 1350 },
      square: { width: 1080, height: 1080 }, landscape: { width: 1600, height: 900 },
      opengraph: { width: 1200, height: 630 },
    });
  });

  it("interpolates only public, safe fields", () => {
    expect(interpolateShareText("{{safe_team_name}} · {{public_event_url}}", { teamName: "De Nachtwachters" }, "https://example.nl"))
      .toBe("De Nachtwachters · https://example.nl");
  });

  it("rejects forbidden privacy keys and phrases", () => {
    expect(privacySafeSerialized({ teamName: "De Nachtwachters" })).toBe(true);
    expect(privacySafeSerialized({ childName: "Test" })).toBe(false);
    expect(privacySafeSerialized({ title: "We eindigen bij de laatste poort" })).toBe(false);
  });
});
