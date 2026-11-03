import type { FrightnightCommand, FrightnightDestination, FrightnightSnapshot } from "./model";
const PREFIX = "duindorp-private-group:frightnight-v1:";
const TTL = 30 * 60_000;
type Stored = { actor: string; expires: number; captured: number; snapshot: FrightnightSnapshot; pending?: FrightnightCommand; payloadHash?: string };
function activeCacheSlug(actor: string) {
  if (typeof document === "undefined") return "frightnight-2027-test";
  const hint = document.cookie.split("; ").find(x => x.startsWith("frightnight-edition-cache="))?.split("=").slice(1).join("=");
  if (!hint) return "frightnight-2027-test";
  const [owner, slug] = decodeURIComponent(hint).split(":");
  return owner === actor && /^frightnight-2027-test(?:-[a-z0-9-]+)?$/.test(slug) ? slug : "frightnight-2027-test";
}
function key(actor: string, slug = activeCacheSlug(actor)) { return `${PREFIX}${actor}:${slug}`; }

function offlineDestination(current: FrightnightDestination | null | undefined): FrightnightDestination | null {
  if (!current?.zone) return null;
  const z = current.zone;
  return {
    id: current.id, zoneId: current.zoneId, sequence: current.sequence, visitReference: current.visitReference,
    leaseUntil: current.leaseUntil, arrivalAt: current.arrivalAt, walkMinutes: current.walkMinutes, reason: current.reason,
    zone: {
      id: z.id, name: z.name, address: z.address, type: z.type, intensity: z.intensity,
      capacity: z.capacity, status: z.status, smoke: z.smoke, strobes: z.strobes, stepFree: z.stepFree,
      description: z.description, version: z.version, opensAt: z.opensAt, closesAt: z.closesAt,
      latitude: z.latitude, longitude: z.longitude,
    },
  };
}

/** Cached projections are visibly stale information. They never authorize a command. */
export function rememberFestival(snapshot: FrightnightSnapshot) {
  try {
    const old = readFestival(snapshot.actor.id);
    const current = offlineDestination(snapshot.current ?? snapshot.journey?.current);
    const minimal: FrightnightSnapshot = {
      event: snapshot.event, actor: { id: snapshot.actor.id, capabilities: [] }, registration: snapshot.registration ? {
        id: snapshot.registration.id, label: snapshot.registration.label, routeType: snapshot.registration.routeType,
        adults: snapshot.registration.adults, children: snapshot.registration.children, persons: snapshot.registration.persons,
        maxIntensity: snapshot.registration.maxIntensity, avoidSmoke: snapshot.registration.avoidSmoke,
        avoidStrobes: snapshot.registration.avoidStrobes, stepFree: snapshot.registration.stepFree,
        startSlot: snapshot.registration.startSlot, status: snapshot.registration.status,
        paymentStatus: snapshot.registration.paymentStatus, paymentQuoteLocked: snapshot.registration.paymentQuoteLocked,
        amountCents: snapshot.registration.amountCents, version: snapshot.registration.version,
      } : null,
      journey: snapshot.journey ? {
        id: snapshot.journey.id, version: snapshot.journey.version, membershipVersion: snapshot.journey.membershipVersion,
        state: snapshot.journey.state, reason: snapshot.journey.reason, current,
        party: { persons: snapshot.journey.party.persons, maxIntensity: snapshot.journey.party.maxIntensity,
          avoidSmoke: snapshot.journey.party.avoidSmoke, avoidStrobes: snapshot.journey.party.avoidStrobes,
          stepFree: snapshot.journey.party.stepFree, members: [] },
      } : null,
      current, progress: snapshot.progress, startSlots: [], activities: [], bookings: [], notifications: [], announcements: [], quests: [], ownZones: [], ownIncidents: [], ownThanks: [], registrationAccess: [], pushEnabled: false,
    };
    localStorage.setItem(key(snapshot.actor.id, snapshot.event.slug), JSON.stringify({ actor: snapshot.actor.id, captured: Date.now(), expires: Date.now() + TTL, snapshot: minimal, ...(old?.pending && old.snapshot.event.id === snapshot.event.id ? { pending: old.pending, payloadHash: old.payloadHash } : {}) } satisfies Stored));
  } catch { /* Storage refusal never prevents a server task. */ }
}
export function readFestival(actor: string): Stored | null {
  try {
    const value = JSON.parse(localStorage.getItem(key(actor)) ?? "null") as Stored | null;
    if (!value || value.actor !== actor || value.snapshot.actor.id !== actor || value.snapshot.event.slug !== activeCacheSlug(actor) || value.expires <= Date.now() || value.captured > Date.now() + 60_000) {
      localStorage.removeItem(key(actor)); return null;
    }
    if (value.pending && (value.pending.operation !== "journey.complete" || value.pending.expectedVersion !== value.snapshot.journey?.version || value.pending.payload.destinationId !== value.snapshot.current?.id)) { delete value.pending; delete value.payloadHash; }
    return value;
  } catch { return null; }
}
export async function verifiedFestivalPending(actor: string) {
  const stored = readFestival(actor); if (!stored?.pending || !stored.payloadHash) return null;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(stored.pending)));
  const actual = Array.from(new Uint8Array(digest)).map(x => x.toString(16).padStart(2, "0")).join("");
  if (actual !== stored.payloadHash) { clearFestivalPending(actor); return null; }
  return stored.pending;
}
export async function queueFestival(actor: string, command: FrightnightCommand): Promise<boolean> {
  const stored = readFestival(actor);
  if (!stored || command.operation !== "journey.complete" || !stored.snapshot.current || !stored.snapshot.journey || command.expectedVersion !== stored.snapshot.journey.version || command.payload.destinationId !== stored.snapshot.current.id) return false;
  if (stored.pending && stored.pending.commandId !== command.commandId) return false;
  try {
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(command)));
    // Logout or another identity can clear storage while the digest is running.
    // Never resurrect that previous person's projection after the clear.
    const current = readFestival(actor);
    if (!current || current.captured !== stored.captured || current.snapshot.current?.id !== stored.snapshot.current?.id || (current.pending && current.pending.commandId !== command.commandId)) return false;
    current.payloadHash = Array.from(new Uint8Array(hash)).map(x => x.toString(16).padStart(2, "0")).join("");
    current.pending = command; localStorage.setItem(key(actor), JSON.stringify(current)); return true;
  } catch { return false; }
}
export function clearFestivalPending(actor: string) {
  try { const stored = readFestival(actor); if (stored) { delete stored.pending; delete stored.payloadHash; localStorage.setItem(key(actor), JSON.stringify(stored)); } } catch { /* Optional browser cache. */ }
}
