import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { EventEveningClosureAdmin } from "../../components/event-evening/closure-admin";
import { CompleteEveningNightPass, EventEveningRecap } from "../../components/event-evening/closure-recap";
import type { EveningClosureSnapshot } from "../../lib/event-evening/types";
import { JourneyBook } from "../../components/poortenboek/v2-experience";
import { bookFixture } from "../poortenboek-refresh/fixture";

const event = { id: "event-one", slug: "duindorp-halloween-2026", title: "Duindorp Halloween 2026" };
function initial(): EveningClosureSnapshot {
  return { event, closed: false, closure: null, counts: { participantAccounts: 12, children: 24, participatingHouses: 3, uniqueEmailRecipients: 10, missingContactAccounts: 2 }, mail: { queued: 0, processed: 0, providerAccepted: 0, delivered: 0, failed: 0, unknown: 0, suppressed: 0 } };
}
type Plan = { method?: string; status?: number; headers?: Record<string, string>; holdBody?: boolean; networkError?: boolean; result?: unknown };
let snapshot = initial();
const plans: Plan[] = [];
const requests: Array<{ method: string; body: unknown; signal: boolean }> = [];
const releases: Array<() => void> = [];
let activeReads = 0, maxActiveReads = 0, closures = 0;
const nativeFetch = window.fetch.bind(window);
window.fetch = async (input, options) => {
  if (!String(input).startsWith("/api/event-evening/closure")) return nativeFetch(input, options);
  const method = options?.method ?? "GET";
  const index = plans.findIndex(plan => !plan.method || plan.method === method);
  const plan = index < 0 ? {} : plans.splice(index, 1)[0];
  const body = typeof options?.body === "string" ? JSON.parse(options.body) : null;
  requests.push({ method, body, signal: Boolean(options?.signal) });
  if (method === "GET") { activeReads++; maxActiveReads = Math.max(maxActiveReads, activeReads); }
  if (plan.networkError) { if (method === "GET") activeReads--; throw new TypeError("Controlled network failure"); }
  if (method === "POST" && body.action === "confirm" && !snapshot.closed && (plan.status ?? 200) < 400) {
    closures++;
    snapshot = { ...snapshot, closed: true, closure: { id: "closure-one", closedAt: "2026-11-01T20:00:00Z", subject: body.subject, body: body.body, messageVersion: 1, readAt: null, portalCount: 3 }, mail: { queued: 10, processed: 0, providerAccepted: 0, delivered: 0, failed: 0, unknown: 0, suppressed: 0 } };
  }
  if (method === "POST" && body.action === "acknowledge" && snapshot.closure) snapshot.closure.readAt = "2026-11-01T20:05:00Z";
  const result = structuredClone(plan.result === undefined ? snapshot : plan.result);
  const response = new Response(null, { status: plan.status ?? 200, headers: plan.headers });
  let released: Promise<void> = Promise.resolve();
  if (plan.holdBody) released = new Promise<void>(resolve => releases.push(resolve));
  response.json = async () => {
    try { await released; return { data: result }; }
    finally { if (method === "GET") activeReads--; }
  };
  return response;
};
const root = createRoot(document.getElementById("root")!);
function close(subject = "Ons definitieve onderwerp", body = "Beste Duindorpers,\n\nOnze eigen extra alinea.") {
  snapshot = { ...snapshot, closed: true, closure: { id: "closure-one", closedAt: "2026-11-01T20:00:00Z", subject, body, readAt: null, portalCount: 3 }, portals: [
    { id: "gate-a", name: "De Spookpoort", worldName: "Spoken", visited: true, source: "event_closure" },
    { id: "gate-b", name: "De Nachtpoort", worldName: "Nacht", visited: true, source: "event_closure" },
    { id: "gate-final", name: "De echte finalepoort", worldName: "Duinpad", finale: true, visited: true, source: "event_closure" },
  ] };
}
declare global { interface Window { evening: typeof api } }
const api = {
  mountAdmin(authorized = true) { root.render(<StrictMode><EventEveningClosureAdmin eventSlug={event.slug} eventId={event.id} eventTitle={event.title} authorized={authorized}/></StrictMode>); },
  mountRecap(withThanks = true) { if (!snapshot.closure) close(); root.render(<StrictMode><EventEveningRecap closure={snapshot.closure!} eventSlug={event.slug} withThanks={withThanks}/></StrictMode>); },
  mountPass() { if (!snapshot.closure) close(); root.render(<StrictMode><CompleteEveningNightPass closure={snapshot.closure!} eventSlug={event.slug} childProfiles={[{ id: "child-a", firstName: "Mila" }, { id: "child-b", firstName: "Sem" }]}/></StrictMode>); },
  mountBook() {
    const book = bookFixture();
    book.eventPhase = "completed";
    book.eveningClosure = { id: "closure-one", closedAt: "2026-11-01T20:00:00Z" };
    book.journey.complete = true;
    book.journey.seals = ["physical", "event_closure"].map((source, index) => ({
      portalId: `book-gate-${index}`, worldId: "world-spoken", earnedAt: "2026-10-31T19:00:00Z", finale: index === 1,
      source: source as "physical" | "event_closure",
      presentation: { version: 1, portalCode: `G-${index}`, world: "Spoken", worldSlug: "spokenrijk", publicName: index ? "De cadeau-finalepoort" : "De fysiek bezochte poort", shortDescription: "Een Halloweenpoort", story: "Een verhaal", symbol: "gate", color: "amber", imagePath: null, accessibility: "", intensity: 1 },
    }));
    book.journey.visitedCount = 2; book.journey.assignedCount = 2;
    root.render(<StrictMode><JourneyBook snapshot={book}/></StrictMode>);
  },
  plan(plan: Plan) { plans.push(plan); }, close,
  setSnapshot(next: EveningClosureSnapshot) { snapshot = next; },
  snapshot() { return structuredClone(snapshot); },
  release() { releases.splice(0).forEach(release => release()); },
  requests() { return structuredClone(requests); },
  stats() { return { activeReads, maxActiveReads, closures }; },
  unmount() { root.render(null); },
};
window.evening = api;
