import { describe, expect, it } from "vitest";
import { dominantEndPreference, dominantStartPreference, dominantTimePreference, explicitOrdinaryStopPreference, type RegistrationTimePreferences } from "./start-preference";
const at = (time: string) => `2026-10-31T${time}:00+01:00`;
const iso = (time: string) => new Date(at(time)).toISOString();

describe("shared dominant household time preferences", () => {
  it.each(["preferredStartAt", "desiredEndAt"] as const)("counts original registrations, neutral values and duplicate snapshots once for %s", field => {
    const households = [
      { id: "together-a", [field]: at("19:00"), childCount: 1, togetherKey: "block" },
      { id: "together-b", [field]: at("19:00"), childCount: 1, togetherKey: "block" },
      { id: "large-minority", [field]: at("18:00"), childCount: 19 },
      { id: "neutral", [field]: null, childCount: 30 },
    ];
    expect(dominantTimePreference([...households, households[2]], field)).toBe(iso("19:00"));
    expect(dominantTimePreference([...households].reverse(), field)).toBe(iso("19:00"));
  });
  it.each(["preferredStartAt", "desiredEndAt"] as const)("uses mode, absolute deviation and earliest tie breakers for %s", field => {
    const households = ["17:00", "18:00", "19:00"].map((time, id) => ({ id: String(id), [field]: at(time) }));
    expect(dominantTimePreference(households, field)).toBe(iso("18:00"));
    expect(dominantTimePreference([...households].reverse(), field)).toBe(iso("18:00"));
    expect(dominantTimePreference(households.slice(0, 2), field)).toBe(iso("17:00"));
    expect(dominantTimePreference([{ id: "neutral", [field]: "invalid" }, { id: "empty" }], field)).toBeNull();
  });
  it("shares the same rule between the start and end wrappers", () => {
    const households: RegistrationTimePreferences[] = [
      { id: "a", preferredStartAt: at("17:00"), desiredEndAt: at("20:00") },
      { id: "b", preferredStartAt: at("17:00"), desiredEndAt: at("20:00") },
      { id: "c", preferredStartAt: at("18:00"), desiredEndAt: at("18:00") },
    ];
    expect(dominantStartPreference(households)).toBe(iso("17:00"));
    expect(dominantEndPreference(households)).toBe(iso("20:00"));
  });
  it("distinguishes legacy end copies from an independent ordinary-stop wish", () => {
    expect(explicitOrdinaryStopPreference({ requestedStopAt: at("18:00"), desiredEndAt: iso("18:00") })).toBeNull();
    expect(explicitOrdinaryStopPreference({ requestedStopAt: at("18:00"), desiredEndAt: at("20:00") })).toBe(at("18:00"));
    expect(explicitOrdinaryStopPreference({ requestedStopAt: null, desiredEndAt: at("20:00") })).toBeNull();
  });
  it("is deterministic for conflicting duplicate snapshots without giving them another vote", () => {
    const households = [
      { id: "a", preferredStartAt: at("17:00") },
      { id: "a", preferredStartAt: at("18:00") },
      { id: "b", preferredStartAt: at("19:00") },
    ];
    expect(dominantStartPreference(households)).toBe(iso("19:00"));
    expect(dominantStartPreference([...households].reverse())).toBe(iso("19:00"));
  });
});
