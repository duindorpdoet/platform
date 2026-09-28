"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { PoortkamerChat } from "@/components/portal/poortkamer-chat";
import type { RoomChannel } from "@/lib/domain/poortkamer";
import { portalTime } from "@/lib/domain/poortkamer";
type Snapshot = {
  realtimeTopic: string;
  userId: string;
  communityTopic: string;
  channels: RoomChannel[];
  portals: Array<{
    id: string;
    code: string;
    name: string;
    stock: string;
    ready: number;
    online: number;
    pending: number;
    lastActivity: string;
    helpRequestedAt: string | null;
  }>;
  reports: Array<{
    id: string;
    channelId: string;
    messageId: number;
    body: string;
    reason: string;
  }>;
  incidents: Array<{
    id: string;
    portalId: string;
    portalCode: string;
    portalName: string;
    category: string;
    urgency: "normal" | "high";
    status: string;
    description: string;
    callbackRequested: boolean;
    createdAt: string;
  }>;
  presentations: Array<{
    id: string;
    portalId: string;
    portalCode: string;
    version: number;
    status: string;
    publicName: string;
    submittedAt: string | null;
  }>;
};
export function PoortkamerOverview({ eventSlug, praatkamerOnly = false }: { eventSlug: string; praatkamerOnly?: boolean }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [notice, setNotice] = useState("");
  const [tab, setTab] = useState(praatkamerOnly ? "community" : "rooms");
  const load = useCallback(async () => {
    if (document.hidden) return;
    const client = createClient();
    if (!client) return;
    const result = await client
      .schema("api")
      .rpc("admin_portal_room_snapshot", { _event_slug: eventSlug });
    if (result.error) {
      if (result.error.code === "42501" || result.error.code === "PGRST301")
        setSnapshot(null);
      setNotice("Poortkamergegevens konden niet worden opgehaald.");
    } else setSnapshot(result.data as Snapshot);
  }, [eventSlug]);
  useEffect(() => {
    const first = setTimeout(() => void load(), 0);
    const poll = setInterval(() => void load(), 20_000);
    return () => {
      clearTimeout(first);
      clearInterval(poll);
    };
  }, [load]);
  usePrivateBroadcast(snapshot?.realtimeTopic, () => void load());
  async function moderate(
    channelId: string,
    messageId: number,
    operation: string,
  ) {
    const client = createClient();
    if (!client) return;
    if (
      !window.confirm(
        operation === "hide"
          ? "Dit bericht verbergen en de melding afhandelen?"
          : "Deze melding als afgehandeld markeren?",
      )
    )
      return;
    const { error } = await client.schema("api").rpc("portal_chat_action", {
      _channel_id: channelId,
      _operation: operation,
      _payload: { messageId },
    });
    setNotice(
      error ? "Moderatie kon niet worden opgeslagen." : "Melding afgehandeld.",
    );
    await load();
  }
  async function v2Command(
    operation: string,
    id: string,
    payload: Record<string, unknown> = {},
  ) {
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("admin_portal_v2_command", {
      _event_slug: eventSlug,
      _operation: operation,
      _id: id,
      _payload: payload,
      _key: crypto.randomUUID(),
    });
    setNotice(error ? "De wijziging kon niet worden opgeslagen." : "De wijziging is opgeslagen.");
    await load();
  }
  return (
    <section className="portal-room-overview">
      {!praatkamerOnly && <nav className="workspace-tabs portal-room-admin-tabs" aria-label="Poortkamers beheren">{[["rooms", "Teams & toegang"], ["review", "Presentaties"], ["incidents", "Hulpvragen"], ["community", "Praatkamer"], ["announcements", "Korte updates"], ["reports", "Moderatie"]].map(([key, label]) => <button type="button" key={key} aria-pressed={tab === key} onClick={() => setTab(key)}>{label}</button>)}</nav>}
      {notice && <p role="status">{notice}</p>}
      {!snapshot ? (
        <p>Ophalen…</p>
      ) : (
        <>
          {tab === "rooms" && <div className="portal-registration-list">
            {snapshot.portals.map((p) => (
              <article className="portal-list-row" key={p.id}>
                <h3>
                  {p.code} · {p.name}
                </h3>
                <p>
                  {p.ready} controles afgerond · {p.online} recent actief · {p.pending}{" "}
                  open sleutels · bijgewerkt {portalTime(p.lastActivity)}
                </p>
                <Link
                  className="btn outline"
                  href={`/admin/poortkamer/${p.id}`}
                >
                  Open poort en team
                </Link>
              </article>
            ))}
          </div>
          }
          {tab === "review" && <>
          <h3>Poortpresentaties ter beoordeling ({snapshot.presentations.length})</h3>
          {snapshot.presentations.length === 0 && <p>Er wachten geen presentaties op beoordeling.</p>}
          {snapshot.presentations.map((presentation) => (
            <article className="panel" key={presentation.id}>
              <h4>{presentation.portalCode} · {presentation.publicName}</h4>
              <p>Versie {presentation.version} · {({ submitted: "Wacht op beoordeling", changes_requested: "Aanpassing gevraagd" }[presentation.status] ?? "Ter beoordeling")}</p>
              <div className="actions">
                <button className="btn primary" onClick={() => void v2Command("presentation_approve", presentation.id)}>
                  Goedkeuren
                </button>
                <button
                  className="btn outline"
                  onClick={() => {
                    const note = window.prompt("Welke aanpassing is nodig?");
                    if (note && note.trim().length >= 5)
                      void v2Command("presentation_changes", presentation.id, { note: note.trim() });
                  }}
                >
                  Aanpassing vragen
                </button>
                <button
                  className="btn outline"
                  onClick={() => {
                    const note = window.prompt("Waarom is deze inhoud onveilig of ongeschikt?");
                    if (note && note.trim().length >= 5)
                      void v2Command("presentation_reject", presentation.id, { note: note.trim() });
                  }}
                >
                  Afwijzen
                </button>
              </div>
            </article>
          ))}
          </>}
          {tab === "incidents" && <>
          <h3>Operationele meldingen ({snapshot.incidents.length})</h3>
          {snapshot.incidents.length === 0 && <p>Er zijn geen open operationele meldingen.</p>}
          {snapshot.incidents.map((incident) => (
            <article className="panel" key={incident.id}>
              <h4>{incident.portalCode} · {incident.portalName}</h4>
              <p role={incident.urgency === "high" ? "alert" : undefined}>
                <strong>{incident.urgency === "high" ? "Hoge urgentie" : "Normaal"}</strong> · {({ crowding: "Drukte", lingering: "Groep blijft langer", technical: "Techniek", nuisance: "Overlast", unsafe: "Onveilig", contact_requested: "Contactverzoek", other: "Overige vraag" }[incident.category] ?? "Hulpvraag")} · {portalTime(incident.createdAt)}
              </p>
              <p>{incident.description}</p>
              {incident.callbackRequested && <p><strong>Terugbelverzoek</strong></p>}
              <div className="actions">
                {incident.status === "new" && <button className="btn outline" onClick={() => void v2Command("incident_status", incident.id, { status: "seen" })}>Gezien</button>}
                <button className="btn outline" onClick={() => {
                  const adminNote = window.prompt("Interne notitie voor de organisatie:");
                  if (adminNote && adminNote.trim().length >= 2)
                    void v2Command("incident_status", incident.id, { status: "in_progress", adminNote: adminNote.trim() });
                }}>In behandeling</button>
                <button className="btn primary" onClick={() => {
                  const resolutionMessage = window.prompt("Oplossingsbericht voor het huis:", "De organisatie heeft deze melding opgelost.");
                  if (resolutionMessage && resolutionMessage.trim().length >= 2)
                    void v2Command("incident_status", incident.id, { status: "resolved", resolutionMessage: resolutionMessage.trim() });
                }}>Opgelost</button>
              </div>
            </article>
          ))}
          </>}
          {tab === "reports" && <>
          <h3>Gemelde berichten ({snapshot.reports.length})</h3>
          {snapshot.reports.length === 0 && <p>Er zijn geen open meldingen.</p>}
          {snapshot.reports.map((r) => (
            <article className="panel" key={r.id}>
              <blockquote>{r.body}</blockquote>
              <p>Melding: {r.reason}</p>
              <div className="actions">
                <button
                  className="btn outline"
                  onClick={() =>
                    void moderate(r.channelId, r.messageId, "hide")
                  }
                >
                  Verbergen
                </button>
                <button
                  className="btn outline"
                  onClick={() =>
                    void moderate(r.channelId, r.messageId, "resolve")
                  }
                >
                  Afhandelen
                </button>
              </div>
            </article>
          ))}
          </>}
          {(tab === "community" || tab === "announcements") && <PoortkamerChat key={tab} admin disabled={false} refresh={load} initialChannel={snapshot.channels.find(c => c.kind === tab)?.id} room={{ userId: snapshot.userId, portal: { id: null }, portalTopic: "", communityTopic: snapshot.communityTopic, channels: snapshot.channels, team: [], updatedAt: "" }} />}
        </>
      )}
    </section>
  );
}
