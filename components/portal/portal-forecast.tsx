"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Clock3, RefreshCw, Users } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Arrival = {
  groupCode: string;
  displayName?: string | null;
  plannedArrivalAt: string;
  plannedDepartureAt: string;
  expectedChildren: number;
  state: "planned" | "active" | "completed";
  classification: "assigned" | "forecast";
};
type Forecast = {
  portalId: string;
  operationStatus?: "scheduled" | "open" | "paused" | "closed";
  assignedGroups?: number;
  assignedChildren?: number;
  forecastGroups?: number;
  forecastChildren?: number;
  forecastAvailable?: boolean;
  nextArrivalAt?: string | null;
  updatedAt?: string;
  arrivals: Arrival[];
};

const time = (value?: string | null) => value ? new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "Nog niet berekend";

export function PortalForecast({ portalId, systemCode, name, operationStatus }: { portalId: string; systemCode?: string | null; name: string; operationStatus: string }) {
  const [snapshot, setSnapshot] = useState<Forecast | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("portal_arrivals_snapshot", { _portal_id: portalId });
    setUnavailable(Boolean(error));
    if (!error) setSnapshot(data as Forecast);
  }, [portalId]);

  useEffect(() => {
    const client = createClient();
    const first = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 30_000);
    if (!client) return () => { window.clearTimeout(first); window.clearInterval(poll); };
    const channel = client.channel(`portal:${portalId}`, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe();
    return () => { window.clearTimeout(first); window.clearInterval(poll); void client.removeChannel(channel); };
  }, [load, portalId]);

  const assigned = useMemo(() => snapshot?.arrivals?.filter((item) => item.classification === "assigned" && item.state !== "completed") ?? [], [snapshot]);
  const forecast = useMemo(() => snapshot?.arrivals?.filter((item) => item.classification === "forecast" && item.state !== "completed") ?? [], [snapshot]);
  const assignedChildren = snapshot?.assignedChildren ?? assigned.reduce((sum, item) => sum + item.expectedChildren, 0);
  const forecastChildren = snapshot?.forecastChildren ?? forecast.reduce((sum, item) => sum + item.expectedChildren, 0);
  const forecastAvailable = snapshot?.forecastAvailable !== false;
  const nextArrival = snapshot?.nextArrivalAt ?? [...assigned, ...forecast].sort((left, right) => left.plannedArrivalAt.localeCompare(right.plannedArrivalAt))[0]?.plannedArrivalAt;

  return <section className="panel portal-forecast" aria-labelledby="portal-forecast-title">
    <div className="row-between"><div><p className="kicker">{systemCode || "Poort"} · {name}</p><h2 id="portal-forecast-title">Wie kun je nog verwachten?</h2></div><button className="btn outline" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>
    <p className="portal-forecast-status"><span className={`status-dot ${operationStatus}`} />{operationStatus === "open" ? "Open voor nieuwe toewijzingen" : operationStatus === "paused" ? "Gepauzeerd: geen nieuwe prognose" : operationStatus === "closed" ? "Gesloten: geen nieuwe prognose" : "Nog ingepland"}</p>
    {unavailable ? <div className="form-warning">De prognose is tijdelijk niet beschikbaar. Reeds vrijgegeven opdrachten blijven leidend.</div> : <>
      <div className="portal-forecast-metrics">
        <span><Users /><small>Toegewezen of onderweg</small><strong>{assigned.length} groepen · {assignedChildren} kinderen</strong></span>
        <span><Users /><small>Mogelijk later</small><strong>{!forecastAvailable ? "Prognose tijdelijk niet beschikbaar" : operationStatus === "open" ? `${forecast.length} groepen · ${forecastChildren} kinderen` : "Geen nieuwe prognose"}</strong></span>
        <span><Clock3 /><small>Volgende indicatieve aankomst</small><strong>{time(nextArrival)}</strong></span>
      </div>
      {assigned.length === 0 && forecast.length === 0 && <p className="empty-state">Er staan nu geen groepen in de actuele planning voor jullie poort.</p>}
      <p className="note">Toegewezen groepen hebben jullie poort al in hun serverbevestigde route. De prognose kan nog veranderen door tempo, pauzes, veiligheid en beschikbaarheid. Dit is geen live GPS.</p>
      <small>Laatst door de server bijgewerkt: {snapshot?.updatedAt ? new Date(snapshot.updatedAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" }) : "nog niet beschikbaar"}</small>
    </>}
  </section>;
}
