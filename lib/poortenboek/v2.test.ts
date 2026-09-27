import { describe, expect, it } from "vitest";
import {
  avatarOptions,
  bannerUpgradeLevel,
  deterministicChoice,
  unlockedChapterNumbers,
} from "./v2";

describe("Poortenboek V2", () => {
  it("biedt uitsluitend de zes goedgekeurde avatars", () => {
    expect(avatarOptions.map((item) => item.id)).toEqual([
      "nightwatcher",
      "little-wizard",
      "ghost-scout",
      "pumpkin-guardian",
      "shadow-traveler",
      "moon-knight",
    ]);
  });

  it("ontgrendelt de vaste upgrades bij 1, 3, 5 en de finale", () => {
    expect([0, 1, 3, 5, 6].map((count) => bannerUpgradeLevel(count, 6))).toEqual([0, 1, 2, 3, 4]);
  });

  it("leidt hoofdstukken af zonder client-write", () => {
    expect(unlockedChapterNumbers(0, 6, false)).toEqual([1]);
    expect(unlockedChapterNumbers(2, 6, false)).toEqual([1, 2, 3]);
    expect(unlockedChapterNumbers(5, 6, false)).toEqual([1, 2, 3, 4, 5]);
    expect(unlockedChapterNumbers(6, 6, true)).toEqual([1, 2, 3, 4, 5, 6]);
  });

  it("kiest deterministisch bij een gelijke vaandelstem", () => {
    const first = deterministicChoice("event", "team", "color", ["violet", "amber"]);
    expect(first).toBe(deterministicChoice("event", "team", "color", ["amber", "violet"]));
  });
});
