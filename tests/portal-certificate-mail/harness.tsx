import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { PortalCertificateMailAdmin } from "../../components/event-evening/portal-certificate-admin";
import { usePortalCertificateStatus } from "../../components/event-evening/use-portal-certificate-status";
import type { PortalCertificateSnapshot } from "../../lib/event-evening/portal-certificates";
const event = { id: "event-one", slug: "duindorp-halloween-2026", title: "Duindorp Halloween 2026" };
let snapshot: PortalCertificateSnapshot = { event, ready: true, confirmed: false, campaign: null, message: null, counts: { participatingHouses: 3, teamAccounts: 7, uniqueEmailRecipients: 5, missingContactAccounts: 2 }, mail: { pending: 0, queued: 0, processed: 0, providerAccepted: 0, delivered: 0, failed: 0, unknown: 0, suppressed: 0, retryableFailed: 0 } };
type Plan = { method?: string; status?: number; headers?: Record<string, string>; holdBody?: boolean; holdHeaders?: boolean; networkError?: boolean; result?: unknown; persist?: boolean };
const requests: Array<{ method: string; body: Record<string, unknown> | null; hasSignal: boolean; signalAborted: boolean }> = [], plans: Plan[] = [], releases: Array<() => void> = [];
let active = 0, maxActive = 0, campaigns = 0, hidden = false, online = true;
Object.defineProperty(document, "visibilityState", { configurable: true, get: () => hidden ? "hidden" : "visible" });
Object.defineProperty(navigator, "onLine", { configurable: true, get: () => online });
const native = window.fetch.bind(window);
window.fetch = async (input, options) => {
  if (!String(input).startsWith("/api/event-evening/portal-certificates")) return native(input, options);
  const method = options?.method ?? "GET", index = plans.findIndex(plan => !plan.method || plan.method === method), plan = index < 0 ? {} : plans.splice(index, 1)[0];
  const body = typeof options?.body === "string" ? JSON.parse(options.body) as Record<string, unknown> : null;
  const entry = { method, body, hasSignal: Boolean(options?.signal), signalAborted: options?.signal?.aborted ?? false };
  requests.push(entry); options?.signal?.addEventListener("abort", () => { entry.signalAborted = true; });
  if (method === "GET") { active++; maxActive = Math.max(maxActive, active); }
  if (method === "POST" && body?.action === "confirm" && !snapshot.confirmed && (plan.persist || (!plan.networkError && (plan.status ?? 200) < 400 && plan.result === undefined))) api.confirm(String(body.subject), String(body.body));
  if (plan.networkError) { if (method === "GET") active--; throw new TypeError("Controlled transport failure"); }
  if (method === "POST" && body?.action === "retry_failed" && plan.result === undefined) snapshot = { ...snapshot, requeued: snapshot.mail.retryableFailed, mail: { ...snapshot.mail, retryableFailed: 0 } };
  const result = structuredClone(plan.result === undefined ? snapshot : plan.result);
  if (plan.holdHeaders) await new Promise<void>(resolve => releases.push(resolve));
  const response = new Response(null, { status: plan.status ?? 200, headers: plan.headers });
  if (method === "GET" && !response.ok) active--;
  const wait = plan.holdBody ? new Promise<void>(resolve => releases.push(resolve)) : Promise.resolve();
  response.json = async () => { try { await wait; return { data: result }; } finally { if (method === "GET") active--; } };
  return response;
};
const root = createRoot(document.getElementById("root")!);
function HookProbe({ id, slug }: { id: string; slug: string }) {
  const state = usePortalCertificateStatus(slug, id);
  return <section data-testid="hook-probe" data-loading={String(state.loading)}><p role="status">{state.error}</p><pre>{JSON.stringify(state.snapshot)}</pre></section>;
}
const api = {
  mount(authorized = true, id = event.id, slug = event.slug) { root.render(<StrictMode><main style={{ padding: 20, maxWidth: 1000, margin: "auto" }}><PortalCertificateMailAdmin eventSlug={slug} eventId={id} eventTitle={event.title} authorized={authorized}/></main></StrictMode>); },
  mountProbe(id = event.id, slug = event.slug) { root.render(<StrictMode><HookProbe id={id} slug={slug}/></StrictMode>); },
  plan(plan: Plan) { plans.push(plan); },
  setSnapshot(value: PortalCertificateSnapshot) { snapshot = value; }, snapshot() { return structuredClone(snapshot); },
  confirm(subject = "Bevestigd door andere organisator", body = "Dit is de definitieve tekst.") { if (!snapshot.confirmed) campaigns++; snapshot = { ...snapshot, confirmed: true, campaign: { id: "campaign-one", createdAt: "2026-11-01T22:00:00Z", createdBy: "organizer-one", subject, body }, message: { subject, body }, mail: { ...snapshot.mail, pending: 5 } }; },
  hidden(value: boolean) { hidden = value; document.dispatchEvent(new Event("visibilitychange")); },
  online(value: boolean) { online = value; window.dispatchEvent(new Event(value ? "online" : "offline")); },
  release() { releases.splice(0).forEach(release => release()); },
  requests() { return structuredClone(requests); }, stats() { return { active, maxActive, campaigns }; }, unmount() { root.render(null); },
};
declare global { interface Window { portalCampaign: typeof api } }
window.portalCampaign = api;
