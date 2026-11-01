import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { PortalCertificate, PortalImpactCounts } from "../../components/portal/portal-impact";
import type { PortalRoom } from "../../lib/domain/poortkamer";
const root = createRoot(document.getElementById("root")!);
const fixture = { userId: "PRIVATE_USER", eventId: "event-one", eventDate: "2026-10-31", portal: { id: "gate-a", name: "De warme pompoen", code: "P-42", address: "PRIVATE_ADDRESS" }, impact: { actualGroups: 3, actualChildren: 8 }, children: [{ name: "PRIVATE_CHILD" }], visits: { recap: { groups: 999, children: 9999 } }, seals: [{ source: "event_closure" }] } as unknown as PortalRoom;
const api = {
  mount(changes: Partial<PortalRoom> = {}) { const room = { ...fixture, ...changes }; root.render(<StrictMode><main className="modern-ui" style={{ maxWidth: 900, padding: 18, margin: "auto" }}><div data-testid="overview-counts"><PortalImpactCounts room={room}/></div><PortalCertificate room={room}/></main></StrictMode>); },
  switchPortal() { api.mount({ userId: "PRIVATE_OTHER_ACCOUNT", portal: { ...fixture.portal, id: "gate-b", name: "Het spookhuis", code: "P-99" }, impact: { actualGroups: 2, actualChildren: 5 } }); },
  unmount() { root.render(null); },
};
declare global { interface Window { portalImpact: typeof api; certificateTexts: string[]; shareCalls: Array<{ name: string; type: string; size: number; active: boolean }>; downloads: string[]; pendingCanvas: Array<() => void>; holdCanvas: boolean; shareMode: "success" | "cancel" | "hold"; releaseShare?: () => void } }
window.portalImpact = api;
