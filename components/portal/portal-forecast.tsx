"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Clock3, RefreshCw, Users } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import styles from "@/components/portal/portal-premium.module.css";

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

  const currentStatus = snapshot?.operationStatus ?? operationStatus;
  const assignedGroups = snapshot?.assignedGroups ?? assigned.length;
  const forecastGroups = snapshot?.forecastGroups ?? forecast.length;

  return <section className={`${styles.forecast} portal-forecast owner-forecast`} aria-labelledby="portal-forecast-title">
    <div className={styles.forecastHead}><div><p className={styles.eyebrow}><Clock3 aria-hidden="true" />Avondoverzicht · {systemCode || name}</p><h2 id="portal-forecast-title">Wie kun je nog verwachten?</h2></div><button className="btn outline" onClick={() => void load()}><RefreshCw aria-hidden="true" />Vernieuwen</button></div>
    <span className={styles.state} data-state={currentStatus}>{currentStatus === "open" ? "Open voor nieuwe toewijzingen" : currentStatus === "paused" ? "Gepauzeerd: geen nieuwe prognose" : currentStatus === "closed" ? "Gesloten: geen nieuwe prognose" : "Nog ingepland"}</span>
    {unavailable ? <div className="form-warning">De prognose is tijdelijk niet beschikbaar. Reeds vrijgegeven opdrachten blijven leidend.</div> : !snapshot ? <p className={styles.empty}>De actuele ontvangstplanning wordt opgehaald…</p> : <>
      <div className={`${styles.metrics} owner-arrival-metrics`}>
        <div><small>Toegewezen of onderweg</small><strong>{assignedGroups} groepen</strong><span>{assignedChildren} kinderen toegewezen</span></div>
        <div><small>Mogelijk later</small>{forecastAvailable && currentStatus === "open" ? <><strong>{forecastGroups} groepen</strong><span>{forecastChildren} kinderen mogelijk later</span></> : <strong className={styles.metricText}>{!forecastAvailable ? "Prognose tijdelijk niet beschikbaar" : "Geen nieuwe prognose"}</strong>}</div>
        <div><small>Volgende indicatieve aankomst</small><strong className={!nextArrival ? styles.metricText : undefined}>{time(nextArrival)}</strong><span>Gepland venster · geen live ETA</span></div>
      </div>
      {assigned.length > 0 && <div><p className={styles.eyebrow}><Users aria-hidden="true" />Al toegewezen</p><div className={styles.arrivals}>{assigned.map((arrival) => <article className={styles.arrival} key={`${arrival.groupCode}-${arrival.plannedArrivalAt}`}><strong>{arrival.displayName || arrival.groupCode}</strong><span>{arrival.displayName ? `${arrival.groupCode} · ` : ""}{arrival.expectedChildren} kinderen</span><span>{time(arrival.plannedArrivalAt)}–{time(arrival.plannedDepartureAt)}</span></article>)}</div></div>}
      {assigned.length === 0 && forecast.length === 0 && <p className={styles.empty}>Er staan nu geen groepen in de actuele planning voor jullie poort.</p>}
      <p className={styles.forecastExplanation}>Toegewezen groepen hebben jullie poort al in hun serverbevestigde route. De prognose kan nog veranderen door tempo, pauzes, veiligheid en beschikbaarheid. Dit is geen live GPS.</p>
      <div className={styles.forecastFoot}><span>{name} · ontvangstplanning</span><span>Laatst door de server bijgewerkt: {snapshot.updatedAt ? new Date(snapshot.updatedAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" }) : "nog niet beschikbaar"}</span></div>
    </>}
  </section>;
}
