import { describe, expect, it } from "vitest";
import { validatedPortalImage } from "./image-signature";

describe("portal image content validation", () => {
  it.each([
    ["image/jpeg", [0xff, 0xd8, 0xff, 0xe0], "jpg"],
    ["image/png", [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "png"],
    ["image/webp", [...Buffer.from("RIFF0000WEBP")], "webp"],
  ])("accepts a real %s signature", (contentType, bytes, extension) => {
    expect(validatedPortalImage(Uint8Array.from(bytes), contentType)).toEqual({ contentType, extension });
  });

  it("rejects executable or SVG content even when the browser claims it is an image", () => {
    expect(validatedPortalImage(Uint8Array.from(Buffer.from("<svg><script>alert(1)</script></svg>")), "image/png")).toBeNull();
    expect(validatedPortalImage(Uint8Array.from(Buffer.from("MZ executable")), "image/jpeg")).toBeNull();
  });

  it("rejects an allowed signature paired with a different declared MIME type", () => {
    expect(validatedPortalImage(Uint8Array.from([0xff, 0xd8, 0xff]), "image/png")).toBeNull();
  });

  it("rejects empty and oversized files before storage", () => {
    expect(validatedPortalImage(new Uint8Array(), "image/png")).toBeNull();
    expect(validatedPortalImage(Uint8Array.from([0xff, 0xd8, 0xff]), "image/jpeg", 8 * 1024 * 1024 + 1)).toBeNull();
  });
});
