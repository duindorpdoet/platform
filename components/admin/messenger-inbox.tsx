"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CheckCheck, Inbox, MessageSquarePlus, RefreshCw, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Message = {
  id: string;
  senderSide: "participant" | "organization";
  body: string;
  createdAt: string;
  readAt?: string | null;
  isMine?: boolean;
};

type Conversation = {
  id: string;
  subjectKind: "group" | "portal" | "viewer" | "user";
  subjectId: string;
  subjectLabel?: string | null;
  systemCode?: string | null;
  displayName?: string | null;
  status: "queued" | "live" | "awaiting_participant" | "awaiting_organization" | "closed";
  version: number;
  claimedBy?: string | null;
  updatedAt: string;
  unreadCount: number;
  messages: Message[];
};

async function digest(value: unknown) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(bytes)].map((item) => item.toString(16).padStart(2, "0")).join("");
}

const statusLabel: Record<Conversation["status"], string> = {
  queued: "Wacht op beheerder",
  live: "Live gesprek",
  awaiting_participant: "Wacht op antwoord",
  awaiting_organization: "Nieuwe reactie",
  closed: "Gesloten",
};

export function MessengerInbox({ eventSlug }: { eventSlug: string }) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [reply, setReply] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [available, setAvailable] = useState(true);
  const [realtimeTopic, setRealtimeTopic] = useState<string | null>(null);
  const messageEnd = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_messenger_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("De berichteninbox kon niet worden opgehaald.");
    setRealtimeTopic((data as { realtimeTopic?: string } | null)?.realtimeTopic ?? null);
    const next = (Array.isArray(data) ? data : (data as { conversations?: Conversation[] } | null)?.conversations ?? []) as Conversation[];
    setConversations(next);
    setSelectedId((current) => current && next.some((item) => item.id === current) ? current : next[0]?.id ?? null);
  }, [eventSlug]);

  useEffect(() => {
    const client = createClient();
    const first = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 20_000);
    if (!client || !realtimeTopic) return () => { window.clearTimeout(first); window.clearInterval(poll); };
    const channel = client.channel(realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe();
    return () => { window.clearTimeout(first); window.clearInterval(poll); void client.removeChannel(channel); };
  }, [load, realtimeTopic]);

  useEffect(() => {
    const client = createClient();
    if (!client) return;
    let active = true;
    const heartbeat = async () => {
      if (!active) return;
      await client.schema("api").rpc("admin_messenger_presence", { _event_slug: eventSlug, _available: available, _ttl_seconds: 90 });
    };
    void heartbeat();
    const timer = window.setInterval(() => void heartbeat(), 45_000);
    return () => { active = false; window.clearInterval(timer); };
  }, [available, eventSlug]);

  const selected = useMemo(() => conversations.find((item) => item.id === selectedId) ?? null, [conversations, selectedId]);

  useEffect(() => {
    messageEnd.current?.scrollIntoView({ block: "nearest" });
  }, [selected?.id, selected?.messages.length]);

  useEffect(() => {
    if (!selected?.unreadCount) return;
    const timer = window.setTimeout(async () => {
      const client = createClient();
      if (!client) return;
      await client.schema("api").rpc("participant_messenger_mark_read", { _conversation_id: selected.id });
      await load();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load, selected?.id, selected?.unreadCount]);

  async function claim() {
    if (!selected) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_messenger_claim", { _conversation_id: selected.id, _expected_version: selected.version });
    setBusy(false);
    setNotice(error ? "Een andere beheerder heeft dit gesprek intussen geopend." : "Gesprek geopend. Jouw antwoorden worden direct opgeslagen.");
    await load();
  }

  async function sendReply() {
    if (!selected || !reply.trim()) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const idempotencyKey = crypto.randomUUID();
    const payload = { conversationId: selected.id, version: selected.version, body: reply.trim() };
    const { error } = await client.schema("api").rpc("admin_messenger_reply", {
      _conversation_id: selected.id,
      _expected_version: selected.version,
      _body: payload.body,
      _idempotency_key: idempotencyKey,
      _request_hash: await digest(payload),
    });
    setBusy(false);
    if (error) setNotice("Het gesprek is intussen gewijzigd. De actuele versie is opgehaald.");
    else { setReply(""); setNotice("Bericht verstuurd."); }
    await load();
  }

  return <section className="panel messenger-admin">
    <div className="row-between">
      <div><p className="kicker">Eén duurzame inbox</p><h2>Messenger</h2><p>Nieuwe en bestaande gesprekken blijven bewaard. Realtime versnelt de weergave; de inbox ververst ook automatisch.</p></div>
      <div className="actions"><label className="messenger-availability"><input type="checkbox" checked={available} onChange={(event) => setAvailable(event.target.checked)} />Beschikbaar voor chat</label><button className="btn outline" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>
    </div>
    {notice && <p className="form-notice" role="status">{notice}</p>}
    <div className="ticket-layout">
      <div className="ticket-list" aria-label="Gesprekken">
        {conversations.length === 0 && <p><Inbox /> Geen gesprekken in de inbox.</p>}
        {conversations.map((conversation) => {
          const latest = conversation.messages.at(-1);
          return <button key={conversation.id} className={selectedId === conversation.id ? "active" : ""} onClick={() => setSelectedId(conversation.id)}>
            <span className="ticket-list-copy">
              <strong>{[conversation.systemCode, conversation.displayName || conversation.subjectLabel].filter(Boolean).join(" · ") || "Privégesprek"}</strong>
              <small className="ticket-preview">{latest?.body || "Gesprek zonder bericht"}</small>
              <small>{statusLabel[conversation.status]}</small>
            </span>
            <span className="ticket-list-time">{new Date(latest?.createdAt ?? conversation.updatedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}{conversation.unreadCount > 0 && <b aria-label={conversation.unreadCount + " ongelezen"}>{conversation.unreadCount}</b>}</span>
          </button>;
        })}
      </div>
      {selected ? <div className="ticket-thread">
        <div className="row-between"><div><p className="kicker">{selected.subjectKind}</p><h3>{[selected.systemCode, selected.displayName || selected.subjectLabel].filter(Boolean).join(" · ")}</h3><small>{statusLabel[selected.status]}</small></div><MessageSquarePlus /></div>
        <div className="ticket-messages" aria-live="polite">{selected.messages.map((message) => <article className={`ticket-message ${message.senderSide === "organization" || message.isMine ? "mine" : "theirs"}`} key={message.id}><strong>{message.senderSide === "organization" ? "Organisatie" : "Deelnemer"}</strong><p>{message.body}</p><small><time dateTime={message.createdAt}>{new Date(message.createdAt).toLocaleString("nl-NL", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Amsterdam" })}</time>{message.readAt && message.senderSide === "organization" ? <><CheckCheck size={14} /> gelezen</> : null}</small></article>)}<div ref={messageEnd} /></div>
        {selected.status === "queued" && <button className="btn" disabled={busy} onClick={() => void claim()}>Gesprek openen</button>}
        {selected.status !== "closed" && selected.status !== "queued" && <div className="ticket-reply"><label className="field"><span>Antwoord</span><textarea rows={4} maxLength={4000} value={reply} onChange={(event) => setReply(event.target.value)} /></label><button className="btn" disabled={busy || !reply.trim()} onClick={() => void sendReply()}><Send />Versturen</button></div>}
      </div> : <div className="ticket-thread empty-state"><Inbox /><p>Kies een gesprek.</p></div>}
    </div>
  </section>;
}
