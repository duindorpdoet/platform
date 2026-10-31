import { z } from "zod";
import type { BookSnapshot } from "./model";
import type { RefreshResult } from "./refresh-queue";

// Validate the response before it can replace confirmed data or reset backoff.
const text = z.string();
const strings = z.array(text);
const snapshotSchema = z.object({
  v2: z.literal(true), firstName: text, medallion: z.number(),
  childId: text.optional(), eventId: text.optional(), demo: z.boolean(),
  eventDate: text, eventPhase: text, expiresAt: z.iso.datetime({ offset: true }), updatedAt: text,
  welcomeRequired: z.boolean(), soundEnabled: z.boolean(),
  checklist: z.array(z.boolean()).length(6),
  identity: z.object({ avatarId: text, lanternShape: text, lanternColor: text }),
  practice: z.object({ completed: z.boolean() }),
  companions: z.array(z.object({ firstName: text, medallion: z.number(), avatarId: text, lanternShape: text, lanternColor: text, status: text })),
  election: z.object({ id: text, generation: z.number(), phase: text, eligibleCount: z.number(), votedCount: z.number(), options: z.array(z.object({ id: text, label: text })), ownChoices: strings, winner: text.nullable(), magicTiebreak: z.boolean(), deadline: text, open: z.boolean() }),
  start: z.object({ name: text, startsAt: text }).nullable(),
  worlds: z.array(z.object({ slug: text, name: text, story: text })),
  unlocks: z.array(z.object({ kind: text, world: text.nullable(), earnedAt: text })),
  banner: z.object({ options: z.record(text, strings), ownVote: z.record(text, text), votedCount: z.number(), eligibleCount: z.number(), result: z.record(text, text).nullable(), locked: z.boolean() }),
  journey: z.object({ visitedCount: z.number(), assignedCount: z.number(), upgradeLevel: z.number(), complete: z.boolean(), chapters: z.array(z.object({ chapter: z.number(), unlockedAt: text })), seals: z.array(z.object({ portalId: text, worldId: text, earnedAt: text, finale: z.boolean(), presentation: z.object({ world: text, worldSlug: text }) })) }),
});

export function sameBookIdentity(value: BookSnapshot, expected: BookSnapshot) {
  return value.childId === expected.childId && value.eventId === expected.eventId &&
    value.demo === expected.demo && value.eventDate === expected.eventDate &&
    value.expiresAt === expected.expiresAt;
}

export function validateBookSnapshot(value: unknown, expected: BookSnapshot): RefreshResult<BookSnapshot> {
  if (!snapshotSchema.safeParse(value).success) return { kind: "retry" };
  const snapshot = value as BookSnapshot;
  if (!sameBookIdentity(snapshot, expected) || Date.parse(snapshot.expiresAt) <= Date.now()) return { kind: "stopped" };
  return { kind: "success", value: snapshot };
}

export function retryAfterMs(value: string | null, now = Date.now()): number | undefined {
  if (!value) return undefined;
  const seconds = /^\d+(?:\.\d+)?$/.test(value.trim()) ? Number(value) : NaN;
  const delay = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(value) - now;
  return Number.isFinite(delay) ? Math.max(0, delay) : undefined;
}

export async function readBookSnapshot(signal: AbortSignal, expected: BookSnapshot): Promise<RefreshResult<BookSnapshot>> {
  const response = await fetch("/api/poortenboek/snapshot", { cache: "no-store", signal });
  if (response.status === 401 || response.status === 403) return { kind: "stopped" };
  if (!response.ok) return { kind: "retry", retryAfterMs: response.status === 429 ? retryAfterMs(response.headers.get("Retry-After")) : undefined };
  return validateBookSnapshot(await response.json(), expected);
}
