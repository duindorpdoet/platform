"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { portalTime, stockLabels } from "@/lib/domain/poortkamer";
type Snapshot = {
  realtimeTopic: string;
  portals: Array<{
    id: string;
    code: string;
    name: string;
    stock: keyof typeof stockLabels;
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
};
export function PoortkamerOverview({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [notice, setNotice] = useState("");
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
  useEffect(() => {
    const client = createClient();
    if (!client || !snapshot?.realtimeTopic) return;
    let disposed = false;
    let channel: ReturnType<typeof client.channel> | undefined;
    const topic = snapshot.realtimeTopic;
    void (async () => {
      const { data } = await client.auth.getSession();
      if (disposed || !data.session) return;
      await client.realtime.setAuth(data.session.access_token);
      if (disposed) return;
      channel = client
        .channel(topic, { config: { private: true } })
        .on("broadcast", { event: "snapshot_changed" }, () => void load())
        .subscribe();
    })();
    return () => {
      disposed = true;
      if (channel) void client.removeChannel(channel);
    };
  }, [snapshot?.realtimeTopic, load]);
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
  return (
    <section className="panel">
      <h2>Poortkamers</h2>
      <p>
        Teamtoegang, gereedheid en snoepvoorraad. Open een poort voor rollen,
        uitnodigingen, berichten en de Omroeper.
      </p>
      {notice && <p role="status">{notice}</p>}
      {!snapshot ? (
        <p>Ophalen…</p>
      ) : (
        <>
          <div className="portal-registration-list">
            {snapshot.portals.map((p) => (
              <article className="portal-list-row" key={p.id}>
                <h3>
                  {p.code} · {p.name}
                </h3>
                <p>
                  {p.ready}/9 gereed · {p.online} recent actief · {p.pending}{" "}
                  open sleutels · bijgewerkt {portalTime(p.lastActivity)}
                </p>
                {p.helpRequestedAt && (
                  <p role="alert">
                    Snoephulp gevraagd om {portalTime(p.helpRequestedAt)}
                  </p>
                )}
                <p
                  role={
                    ["low", "empty"].includes(p.stock) ? "alert" : undefined
                  }
                >
                  Snoep: <strong>{stockLabels[p.stock]}</strong>
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
        </>
      )}
    </section>
  );
}
