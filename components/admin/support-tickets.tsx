"use client";

import { useCallback, useEffect, useState } from "react";
import { CheckCheck, LifeBuoy, RefreshCw, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Ticket = {
  id: string; reference: string; groupCode: string; leaderEmail?: string | null;
  subject: string; category: string; status: string; version: number;
  updatedAt: string; unreadCount: number;
  messages: Array<{ id: string; senderSide: string; body: string; createdAt: string; readAt?: string | null; isMine: boolean }>;
};
const statuses: Record<string, string> = { awaiting_organization: "Organisatie aan zet", awaiting_leader: "Groepsleider aan zet", resolved: "Opgelost", closed: "Gesloten" };

async function digest(value: unknown) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(bytes)].map((item) => item.toString(16).padStart(2, "0")).join("");
}

export function SupportTickets({ eventSlug }: { eventSlug: string }) {
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [reply, setReply] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_group_ticket_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Het ticketoverzicht is niet toegankelijk voor dit account.");
    const next = data as Ticket[]; setTickets(next);
    setSelectedId((current) => current && next.some((ticket) => ticket.id === current) ? current : next[0]?.id ?? null);
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  const selected = tickets.find((ticket) => ticket.id === selectedId) ?? null;
  useEffect(() => {
    if (!selected?.unreadCount) return;
    const timer = window.setTimeout(async () => { const client = createClient(); if (!client) return; await client.schema("api").rpc("group_ticket_mark_read", { _ticket_id: selected.id }); await load(); }, 0);
    return () => window.clearTimeout(timer);
  }, [selected?.id, selected?.unreadCount, load]);

  async function sendReply() {
    if (!selected || !reply.trim()) return;
    const client = createClient(); if (!client) return;
    setBusy(true); const key = crypto.randomUUID(); const payload = { ticketId: selected.id, version: selected.version, body: reply.trim() };
    const { error } = await client.schema("api").rpc("group_ticket_reply", { _ticket_id: selected.id, _expected_version: selected.version, _body: payload.body, _idempotency_key: key, _request_hash: await digest(payload) });
    setBusy(false);
    if (error) return setNotice("Het ticket is intussen gewijzigd. De actuele versie wordt opgehaald.");
    setReply(""); setNotice("Reactie verstuurd; beide kanten ontvangen de e-mailmelding."); await load();
  }
  async function setStatus(status: "open" | "resolved" | "closed") {
    if (!selected) return;
    const reason = window.prompt("Leg kort vast waarom je deze status kiest (minimaal vijf tekens):")?.trim();
    if (!reason || reason.length < 5) return setNotice("Een korte auditreden is verplicht.");
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("group_ticket_set_status", { _ticket_id: selected.id, _expected_version: selected.version, _status: status, _reason: reason });
    setNotice(error ? "De status kon niet worden aangepast." : "Ticketstatus bijgewerkt en geaudit."); await load();
  }

  return <section className="panel ticket-center admin-ticket-center">
    <div className="row-between ticket-heading"><div><p className="kicker">Groepsleiders & organisatie</p><h2>Tickets</h2><p>Beantwoord vragen in één doorlopend gesprek. Gelezen-status en iedere statuswijziging blijven zichtbaar.</p></div><button className="btn outline" onClick={() => void load()}><RefreshCw size={17} />Vernieuwen</button></div>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    <div className="ticket-layout">
      <div className="ticket-list">{tickets.length === 0 && <p>Er zijn nog geen tickets.</p>}{tickets.map((ticket) => <button key={ticket.id} className={ticket.id === selectedId ? "active" : ""} onClick={() => setSelectedId(ticket.id)}><span><strong>{ticket.subject}</strong><small>{ticket.reference} · groep {ticket.groupCode}</small><small>{statuses[ticket.status] ?? ticket.status}</small></span>{ticket.unreadCount > 0 && <b>{ticket.unreadCount}</b>}</button>)}</div>
      {selected && <div className="ticket-thread"><div className="row-between"><div><h3>{selected.subject}</h3><small>{selected.reference} · groep {selected.groupCode} · {selected.leaderEmail ?? "geen leideradres"}</small></div><LifeBuoy /></div>
        <div className="ticket-messages">{selected.messages.map((message) => <article key={message.id} className={`ticket-message ${message.isMine ? "mine" : "theirs"}`}><strong>{message.isMine ? "Organisatie" : "Groepsleider"}</strong><p>{message.body}</p><small>{new Date(message.createdAt).toLocaleString("nl-NL")}{message.isMine && message.readAt ? <><CheckCheck size={14} /> gelezen</> : ""}</small></article>)}</div>
        {selected.status !== "closed" && <div className="ticket-reply"><label className="field"><span>Reactie namens de organisatie</span><textarea rows={4} maxLength={4000} value={reply} onChange={(event) => setReply(event.target.value)} /></label><button className="btn" disabled={busy || !reply.trim()} onClick={() => void sendReply()}><Send size={17} />Versturen</button></div>}
        <div className="actions"><button className="btn outline" onClick={() => void setStatus("open")}>Heropenen</button><button className="btn outline" onClick={() => void setStatus("resolved")}>Opgelost</button><button className="text-link" onClick={() => void setStatus("closed")}>Sluiten</button></div>
      </div>}
    </div>
  </section>;
}
