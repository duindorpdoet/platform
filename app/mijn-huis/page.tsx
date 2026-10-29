import { Poortkamer } from "@/components/portal/poortkamer";
import type { PortalRoom } from "@/lib/domain/poortkamer";
import { redirect } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, House } from "lucide-react";
import styles from "@/components/portal/portal-premium.module.css";
import { PortalDashboard } from "@/components/portal/portal-dashboard";
import { SupportWidget } from "@/components/support/support-widget";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import { EnvironmentTracker } from "@/components/analytics/environment-tracker";

export const dynamic = "force-dynamic";

export default async function MyPortalPage({ searchParams }: { searchParams: Promise<{ poort?: string; qr?: string }> }) {
  if (!await getActor()) redirect("/inloggen?next=/mijn-huis");
  const eventSlug = serverEnv().EVENT_SLUG;
  const client = await createClient();
  const { poort: selected, qr } = await searchParams;
  const roomResult = client ? await client.schema("api").rpc("portal_room_snapshot", { _event_slug: eventSlug, _portal_id: selected && /^[0-9a-f-]{36}$/i.test(selected) ? selected : null }) : null;
  if (roomResult?.data) return <><EnvironmentTracker surface="homeowner" /><Poortkamer eventSlug={eventSlug} initial={roomResult.data as PortalRoom} initialQr={qr === "1"} /></>;
  const pending=client ? await client.schema("api").rpc("my_pending_manual_portals",{_event_slug:eventSlug}) : null;
  if(Array.isArray(pending?.data) && pending.data.length) return <div className="page wrap"><h1>Poort wacht op activering</h1>{pending.data.map((p:{id:string;code:string;name:string})=><p key={p.id}>{p.code} · {p.name}: je persoonlijke uitnodiging is bevestigd. De organisatie moet de poort nog activeren.</p>)}<Link className="btn" href="/omgeving">Mijn omgeving</Link><Link className="btn outline" href="/poortenboek/ouder">Poortenboeken van mijn kinderen</Link></div>;
  const { data } = client ? await client.schema("api").rpc("my_context", { _event_slug: eventSlug }) : { data: null };
  const portalId = ((data as { portalIds?: string[] } | null)?.portalIds ?? [])[0];
  return <><EnvironmentTracker surface="homeowner" /><div className={`page wrap ${styles.standalone}`}><header className={`app-heading ${styles.standaloneHeading}`}><div><p className="kicker"><House size={14} aria-hidden="true" />Poortomgeving</p><h1>Mijn plek</h1></div><div className={styles.headerActions}><Link className="btn outline" href="/omgeving/huiseigenaar/mijn-poort"><ArrowLeft size={16} aria-hidden="true" />Mijn omgeving</Link><SignOutButton /></div></header><PortalDashboard eventSlug={eventSlug} /></div>{portalId && <SupportWidget eventSlug={eventSlug} role="homeowner" portalId={portalId} />}</>;
}
