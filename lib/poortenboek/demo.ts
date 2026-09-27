import "server-only";
import { worlds } from "@/features/content/public-content";
import { teamNames, type BookSnapshot, type DemoPhase } from "./model";
import { absoluteExpiry } from "./crypto";

export type DemoSession = {
  createdAt: number;
  expiresAt: number;
  phase: DemoPhase;
  welcomeSeen: boolean;
  checklist: boolean[];
  choices: string[];
  sound: boolean;
  identity: { avatarId: string; lanternShape: string; lanternColor: string };
  bannerVote: Record<string, string>;
  practiceCompleted: boolean;
  nonce: string;
};
export function newDemoSession(now: number): DemoSession {
  return {
    createdAt: now,
    expiresAt: absoluteExpiry(now),
    phase: "empty",
    welcomeSeen: false,
    checklist: Array(6).fill(false),
    choices: [],
    sound: false,
    identity: {
      avatarId: "nightwatcher",
      lanternShape: "classic",
      lanternColor: "amber",
    },
    bannerVote: {},
    practiceCompleted: false,
    nonce: crypto.randomUUID(),
  };
}
export function demoSnapshot(session: DemoSession): BookSnapshot {
  const identity = session.identity ?? {
    avatarId: "nightwatcher",
    lanternShape: "classic",
    lanternColor: "amber",
  };
  const finished = ["all", "finalists", "winner", "prepared"].includes(session.phase);
  const final = finished;
  const options = teamNames.map((label, index) => ({
    id: `demo-${index}`,
    label,
  }));
  return {
    firstName: "Mila",
    medallion: 0,
    expiresAt: new Date(session.expiresAt).toISOString(),
    welcomeRequired: !session.welcomeSeen,
    demo: true,
    eventDate: "2026-10-31",
    eventPhase: "registration_open",
    checklist: session.checklist,
    soundEnabled: session.sound,
    companions: ["Mila", "Sem", "Yara", "Finn", "Noor"].map((firstName, i) => ({
      firstName,
      medallion: i,
      avatarId: ["nightwatcher", "little-wizard", "ghost-scout", "pumpkin-guardian", "shadow-traveler"][i],
      lanternShape: ["classic", "moon", "tower", "crystal", "classic"][i],
      lanternColor: ["amber", "cyan", "violet", "emerald", "moonlight"][i],
      status:
        session.phase === "prepared" ||
        (i === 0 && session.checklist.every(Boolean)) ||
        i === 2
          ? "ready"
          : "preparing",
    })),
    election: {
      id: `demo-${final ? "final" : "first"}`,
      generation: 1,
      phase: finished ? "finished" : final ? "round_two" : "round_one",
      eligibleCount: 5,
      votedCount:
        finished || session.phase === "all"
          ? 5
          : session.phase === "three"
            ? 3
            : session.choices.length
              ? 1
              : 0,
      options: final ? [options[0], options[2], options[6]] : options,
      ownChoices: session.choices,
      winner: finished ? "De Nachtlopers" : null,
      magicTiebreak: finished,
      deadline: "2026-10-29T17:00:00Z",
      open: !finished,
    },
    start: null,
    worlds: worlds.map(({ slug, name, story }) => ({ slug, name, story })),
    unlocks: [],
    identity,
    practice: { completed: Boolean(session.practiceCompleted) || session.phase === "prepared" },
    banner: {
      options: {
        shape: ["shield", "swallowtail", "round", "split"],
        color: ["amber", "cyan", "violet", "emerald", "crimson", "moonlight"],
        secondaryColor: ["amber", "cyan", "violet", "emerald", "crimson", "moonlight"],
        border: ["rope", "metal", "thorns", "stars"],
        symbol: ["gate", "moon", "flame", "ghost", "key", "star", "bat", "pumpkin"],
        lantern: ["classic", "moon", "tower", "crystal"],
        glow: ["warm", "cold", "magic", "mist"],
      },
      ownVote: session.bannerVote ?? {},
      votedCount: session.phase === "empty" ? 0 : session.phase === "three" ? 3 : 5,
      eligibleCount: 5,
      result: final
        ? { shape: "shield", color: "violet", secondaryColor: "cyan", border: "stars", symbol: "gate", lantern: "classic", glow: "magic" }
        : null,
      locked: false,
    },
    journey: {
      visitedCount: finished ? 5 : 0,
      assignedCount: 6,
      upgradeLevel: finished ? 3 : 0,
      complete: finished,
      chapters: finished
        ? [1, 2, 3, 4, 5, 6].map((chapter) => ({ chapter, unlockedAt: new Date().toISOString() }))
        : [{ chapter: 1, unlockedAt: new Date().toISOString() }],
      seals: finished
        ? worlds.slice(0, 5).map((world, index) => ({
            portalId: `demo-portal-${index}`,
            worldId: `demo-world-${index}`,
            earnedAt: new Date(Date.now() - (5 - index) * 600_000).toISOString(),
            finale: index === 4,
            presentation: {
              version: 1,
              portalCode: `P-${String(index + 1).padStart(2, "0")}`,
              world: world.name,
              worldSlug: world.slug,
              publicName: `${world.name}poort`,
              shortDescription: world.story,
              story: world.story,
              symbol: "gate",
              color: "violet",
              imagePath: null,
              accessibility: "Volg de aanwijzingen van de groepsleider.",
              intensity: 2,
            },
          }))
        : [],
    },
    v2: true,
    updatedAt: new Date().toISOString(),
  };
}
