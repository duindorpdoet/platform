"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, CheckCheck, Inbox, RefreshCw, Search, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import "@/components/ui/chat.css";
type Message = { id: string; senderSide: "participant" | "organization"; body: string; createdAt: string; readAt?: string | null; isMine?: boolean };
type Conversation = {
  id: string; subjectKind: "group" | "portal" | "viewer" | "user"; subjectId: string;
  subjectLabel?: string | null; systemCode?: string | null; displayName?: string | null;
  status: "queued" | "live" | "awaiting_participant" | "awaiting_organization" | "closed";
  version: number; claimedBy?: string | null; updatedAt: string; unreadCount: number; messages: Message[];
};
const statusLabel = { queued: "Nieuw gesprek", live: "In gesprek", awaiting_participant: "Wacht op antwoord", awaiting_organization: "Nieuwe reactie", closed: "Afgerond" };
const title = (c: Conversation) => [c.systemCode, c.displayName || c.subjectLabel].filter(Boolean).join(" · ") || "Privégesprek";
const time = (value: string) => new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" });
async function digest(value: unknown) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(bytes)].map(item => item.toString(16).padStart(2, "0")).join("");
}
export function MessengerInbox({ eventSlug }: { eventSlug: string }) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const reply = drafts[selectedId ?? ""] ?? "";
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [available, setAvailable] = useState(true);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [topic, setTopic] = useState<string | null>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  const sending = useRef(false);
  const sequence = useRef(0);
  const invalidate = useCallback(() => { sequence.current++; }, []);
  const pending = useRef<{ fingerprint: string; key: string; hash: string; version: number } | null>(null);
  const load = useCallback(async () => {
    if (document.hidden || !navigator.onLine) return;
    const client = createClient(); if (!client) return;
    const request = ++sequence.current;
    try {
      const { data, error } = await client.schema("api").rpc("admin_messenger_snapshot", { _event_slug: eventSlug });
      if (request !== sequence.current) return;
      if (error) {
        if (error.code === "42501" || error.code === "PGRST301") { setConversations([]); setSelectedId(null); }
        setNotice("Gesprekken laden lukt even niet. Probeer opnieuw."); return;
      }
      setNotice(""); setLoaded(true);
      setTopic(data?.realtimeTopic ?? null);
      const next = (Array.isArray(data) ? data : data?.conversations ?? []) as Conversation[];
      setConversations(next);
      setSelectedId(current => current && next.some(item => item.id === current) ? current : null);
    } catch { setNotice("Geen verbinding. Je antwoord blijft klaarstaan."); }
  }, [eventSlug]);
  const live = usePrivateBroadcast(topic, () => void load());
  useEffect(() => {
    const first = setTimeout(() => void load(), 0), poll = setInterval(() => void load(), 15_000);
    const refresh = () => void load();
    document.addEventListener("visibilitychange", refresh); window.addEventListener("online", refresh);
    return () => { invalidate(); clearTimeout(first); clearInterval(poll); document.removeEventListener("visibilitychange", refresh); window.removeEventListener("online", refresh); };
  }, [load, invalidate]);
  useEffect(() => {
    const client = createClient(); if (!client) return;
    const heartbeat = async () => { if (!document.hidden && navigator.onLine) await client.schema("api").rpc("admin_messenger_presence", { _event_slug: eventSlug, _available: available, _ttl_seconds: 90 }); };
    void heartbeat(); const timer = setInterval(() => void heartbeat(), 45_000);
    return () => clearInterval(timer);
  }, [available, eventSlug]);
  const selected = useMemo(() => conversations.find(item => item.id === selectedId) ?? null, [conversations, selectedId]);
  useEffect(() => {
    if (follow.current && scroll.current) scroll.current.scrollTop = scroll.current.scrollHeight;
  }, [selected?.id, selected?.messages.length]);
  useEffect(() => {
    if (!selected?.unreadCount) return;
    const timer = setTimeout(async () => {
      const client = createClient(); if (!client) return;
      const { error } = await client.schema("api").rpc("participant_messenger_mark_read", { _conversation_id: selected.id });
      if (!error) await load();
    }, 0);
    return () => clearTimeout(timer);
  }, [load, selected?.id, selected?.unreadCount]);
  async function claim() {
    if (!selected || sending.current) return;
    const client = createClient(); if (!client) return;
    sending.current = true; setBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_messenger_claim", { _conversation_id: selected.id, _expected_version: selected.version });
      await load();
      if (error) setNotice("Een collega heeft dit gesprek intussen geopend. Je ziet nu de actuele stand.");
    } finally { sending.current = false; setBusy(false); }
  }
  async function sendReply(event: React.FormEvent) {
    event.preventDefault();
    if (!selected || !reply.trim() || sending.current) return;
    const client = createClient(); if (!client) return;
    sending.current = true; setBusy(true);
    const payload = { conversationId: selected.id, version: selected.version, body: reply.trim() };
    const fingerprint = JSON.stringify([payload.conversationId, payload.body]);
    if (pending.current?.fingerprint !== fingerprint) pending.current = { fingerprint, key: crypto.randomUUID(), hash: await digest(payload), version: payload.version };
    try {
      const { error } = await client.schema("api").rpc("admin_messenger_reply", { _conversation_id: selected.id, _expected_version: pending.current.version, _body: payload.body, _idempotency_key: pending.current.key, _request_hash: pending.current.hash });
      await load();
      if (error) {
        if (error.code === "40001" || error.message.includes("STALE_VERSION")) pending.current = null;
        setNotice("Je antwoord is nog niet verstuurd. Controleer het vernieuwde gesprek en probeer opnieuw.");
      }
      else { setDrafts(previous => ({ ...previous, [selected.id]: "" })); pending.current = null; follow.current = true; }
    } catch { setNotice("Nog niet verstuurd. Je antwoord blijft klaarstaan."); }
    finally { sending.current = false; setBusy(false); }
  }
  const visible = conversations.filter(c => (filter === "all" || (filter === "unread" ? c.unreadCount > 0 : c.status === "closed")) && `${title(c)} ${c.messages.at(-1)?.body ?? ""}`.toLocaleLowerCase("nl-NL").includes(query.toLocaleLowerCase("nl-NL")));
  return <section className="messenger-inbox" aria-label="Messenger">
    <header className="chat-header messenger-toolbar">
      {selected ? <button className="chat-icon" type="button" aria-label="Terug naar gesprekken" onClick={() => setSelectedId(null)}><ArrowLeft /></button> : <span className="chat-avatar"><Inbox size={22} /></span>}
      <div><h2>{selected ? title(selected) : "Gesprekken"}</h2><p>{selected ? statusLabel[selected.status] : `${conversations.filter(c => c.unreadCount > 0).length} ongelezen`} <span className="chat-connection">· {live ? "Live" : "Verbinden…"}</span></p></div>
      {!selected && <label className="messenger-availability"><input type="checkbox" checked={available} onChange={e => setAvailable(e.target.checked)} /><span>Beschikbaar</span></label>}
      <button type="button" className="chat-icon" aria-label="Gesprekken vernieuwen" onClick={() => void load()}><RefreshCw size={18} /></button>
    </header>
    {notice && <div className="chat-notice" role="status">{notice}</div>}
    {!selected ? <>
      <div className="messenger-search"><label><Search size={18} /><span className="sr-only">Zoek een gesprek</span><input type="search" placeholder="Zoek naam, groep of bericht…" value={query} onChange={e => setQuery(e.target.value)} /></label><nav className="workspace-tabs" aria-label="Gesprekken filteren">{[["all", "Alle"], ["unread", "Ongelezen"], ["closed", "Afgerond"]].map(([key, label]) => <button key={key} type="button" aria-pressed={filter === key} onClick={() => setFilter(key)}>{label}</button>)}</nav></div>
      <div className="messenger-conversations" aria-label="Gesprekken">{!loaded ? <p className="chat-empty">Gesprekken ophalen…</p> : !visible.length ? <div className="chat-empty"><Inbox size={36} /><h3>{query ? "Geen gesprek gevonden" : "Alles bijgewerkt"}</h3><p>{query ? "Probeer een andere naam of groepscode." : "Nieuwe gesprekken verschijnen vanzelf in deze inbox."}</p></div> : visible.map(c => { const latest = c.messages.at(-1); return <button type="button" className="messenger-conversation" key={c.id} onClick={() => { follow.current = true; setSelectedId(c.id); }}><span className="chat-avatar">{title(c).slice(0, 1).toUpperCase()}</span><span className="messenger-conversation-copy"><strong>{title(c)}</strong><span>{latest?.body ?? "Nieuw gesprek"}</span><small>{statusLabel[c.status]}</small></span><span className="messenger-conversation-time"><time>{time(latest?.createdAt ?? c.updatedAt)}</time>{c.unreadCount > 0 && <b className="chat-unread">{c.unreadCount}</b>}</span></button>; })}</div>
    </> : <>
      <div className="chat-history" ref={scroll} role="log" aria-label="Gesprek" aria-live="polite" onScroll={() => { const el = scroll.current; follow.current = !!el && el.scrollHeight - el.scrollTop - el.clientHeight < 100; }}>
        {selected.messages.map((m, i) => <div className="chat-entry" key={m.id}>{(i === 0 || new Date(m.createdAt).toDateString() !== new Date(selected.messages[i - 1].createdAt).toDateString()) && <div className="chat-date">{new Date(m.createdAt).toLocaleDateString("nl-NL", { day: "numeric", month: "long" })}</div>}<article className={`chat-bubble ${m.senderSide === "organization" || m.isMine ? "is-mine" : ""}`}><strong className="chat-sender">{m.senderSide === "organization" ? "Organisatie" : title(selected)}</strong><p>{m.body}</p><footer><time dateTime={m.createdAt}>{time(m.createdAt)}</time>{m.readAt && m.senderSide === "organization" && <span aria-label="Gelezen"><CheckCheck size={14} /></span>}</footer></article></div>)}
      </div>
      {selected.status === "queued" ? <div className="chat-composer"><button className="btn" disabled={busy} onClick={() => void claim()}>Gesprek openen</button></div> : selected.status === "closed" ? <p className="chat-readonly">Dit gesprek is afgerond.</p> : <form className="chat-composer" onSubmit={sendReply}><div className="chat-compose-line"><label htmlFor="messenger-reply" className="sr-only">Antwoord</label><textarea id="messenger-reply" rows={2} maxLength={4000} placeholder="Schrijf je antwoord…" value={reply} disabled={busy} onChange={e => setDrafts(previous => ({ ...previous, [selected.id]: e.target.value }))} onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing && matchMedia("(pointer:fine)").matches) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} /><button className="chat-send" type="submit" aria-label="Versturen" disabled={busy || !reply.trim()}><Send size={20} /></button></div></form>}
    </>}
  </section>;
}
