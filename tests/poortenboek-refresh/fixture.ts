import type { BookSnapshot } from "../../lib/poortenboek/model";

/** Entirely synthetic child and event; no production data or credentials. */
export function bookFixture(childId = "child-a", firstName = "Mila"): BookSnapshot {
  return {
    childId, firstName, eventId: "fixture-event", medallion: 1,
    demo: false, expiresAt: "2026-11-01T00:00:00.000Z",
    updatedAt: "2026-10-31T15:00:00.000Z", eventDate: "2026-10-31", eventPhase: "live",
    welcomeRequired: false, checklist: Array(6).fill(false), soundEnabled: false,
    tutorial: { version: 1, completedAt: "2026-10-31T14:00:00.000Z", lastStep: 8 },
    companions: [], start: null, worlds: [], unlocks: [],
    identity: { avatarId: "nightwatcher", lanternShape: "classic", lanternColor: "amber" },
    practice: { completed: false },
    banner: { options: {}, ownVote: {}, votedCount: 0, eligibleCount: 1, result: null, locked: false },
    election: {
      id: "fixture-election", generation: 1, phase: "finished", eligibleCount: 1, votedCount: 1,
      options: [], ownChoices: [], winner: "De Nachtlopers", magicTiebreak: false,
      deadline: "2026-10-31T14:00:00.000Z", open: false,
    },
    journey: { visitedCount: 0, assignedCount: 1, upgradeLevel: 0, complete: false, chapters: [], seals: [] },
    v2: true,
  };
}
