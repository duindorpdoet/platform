"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Check, Clock, DoorOpen } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Snapshot = { application: { id: string; status: string; version: number; draft: Record<string, unknown> }; portal: null | { id: string; name: string; description: string; intensity: number; approvalStatus: string; operationStatus: "scheduled" | "open" | "paused" | "closed"; version: number; world: string; nextArrival?: string | null } };

export function PortalDashboard({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data } = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug }); setSnapshot(data as Snapshot | null); }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function setState(state: "open" | "paused" | "closed") {
    const client = createClient(); if (!client || !snapshot?.portal) return;
    const { error } = await client.schema("api").rpc("portal_set_operational_state", { _portal_id: snapshot.portal.id, _state: state, _expected_version: snapshot.portal.version, _reason: state === "open" ? "Bewoner meldt poort gereed" : "Bewoner wijzigt operationele status" });
    setNotice(error ? "De status was verouderd; de actuele stand is opgehaald." : "Status door de server bevestigd."); await load();
  }
  if (!snapshot) return <div className="panel">Poortgegevens ophalen…</div>;
  if (!snapshot.portal) return <div className="panel empty-state"><Clock /><h2>Aanmelding in beoordeling</h2><p>Status: {snapshot.application.status}. Een huis wordt pas een poort na expliciete goedkeuring.</p></div>;
  const portal = snapshot.portal;
  return <div className="house-grid"><section className="house-art"><img src="/images/pluvierstraat.webp" alt="Verlichte Duindorpse poort" /><div><p className="kicker">{portal.world}</p><h1>{portal.name}</h1><p>{portal.description}</p></div></section><section className="panel"><p className="kicker">Avondbediening</p><h2>Status: {portal.operationStatus}</h2><p>Gebruik pauze zodra ontvangst niet veilig is. Groepen krijgen na verversen de gewijzigde status.</p>{portal.nextArrival && <div className="arrival"><Clock /><span>Volgende geplande groep</span><strong>{new Date(portal.nextArrival).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</strong></div>}<div className="house-actions"><button className="btn" disabled={portal.operationStatus === "open"} onClick={() => void setState("open")}><Check />Open</button><button className="btn outline" disabled={portal.operationStatus === "paused"} onClick={() => void setState("paused")}><AlertTriangle />Pauze</button><button className="btn outline" disabled={portal.operationStatus === "closed"} onClick={() => void setState("closed")}><DoorOpen />Sluiten</button></div>{notice && <p className="form-notice">{notice}</p>}</section></div>;
}
