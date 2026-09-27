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
    nonce: crypto.randomUUID(),
  };
}
export function demoSnapshot(session: DemoSession): BookSnapshot {
  const final = ["finalists", "winner", "prepared"].includes(session.phase);
  const finished = ["winner", "prepared"].includes(session.phase);
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
    updatedAt: new Date().toISOString(),
  };
}
