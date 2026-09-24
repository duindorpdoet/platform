"use client";

import { useCallback, useEffect, useState } from "react";
import { CheckCheck, LifeBuoy, MessageSquarePlus, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type TicketMessage = {
  id: string;
  senderSide: "leader" | "organization";
  body: string;
  createdAt: string;
  readAt?: string | null;
  isMine: boolean;
};
type Ticket = {
  id: string;
  reference: string;
  subject: string;
  category: string;
  status: "awaiting_organization" | "awaiting_leader" | "resolved" | "closed";
  version: number;
  updatedAt: string;
  unreadCount: number;
  messages: TicketMessage[];
};

const statusLabels: Record<Ticket["status"], string> = {
  awaiting_organization: "Wacht op organisatie",
  awaiting_leader: "Jouw reactie gevraagd",
  resolved: "Opgelost",
  closed: "Gesloten",
};

async function digest(value: unknown) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(bytes)].map((item) => item.toString(16).padStart(2, "0")).join("");
}

export function GroupTickets({ groupId }: { groupId: string }) {
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [newTicket, setNewTicket] = useState(false);
  const [category, setCategory] = useState("question");
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [reply, setReply] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("group_ticket_snapshot", { _group_id: groupId });
    if (error) return setNotice("De berichten konden niet worden opgehaald.");
    const next = data as Ticket[];
    setTickets(next);
    setSelectedId((current) => current && next.some((ticket) => ticket.id === current) ? current : next[0]?.id ?? null);
  }, [groupId]);

  useEffect(() => {
    const client = createClient();
    const timer = window.setTimeout(() => void load(), 0);
    if (!client) return () => window.clearTimeout(timer);
    const channel = client.channel(`group:${groupId}`, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe();
    return () => { window.clearTimeout(timer); void client.removeChannel(channel); };
  }, [groupId, load]);

  const selected = tickets.find((ticket) => ticket.id === selectedId) ?? null;
  useEffect(() => {
    if (!selected?.unreadCount) return;
    const timer = window.setTimeout(async () => {
      const client = createClient();
      if (!client) return;
      await client.schema("api").rpc("group_ticket_mark_read", { _ticket_id: selected.id });
      await load();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [selected?.id, selected?.unreadCount, load]);

  async function createTicket() {
    if (subject.trim().length < 3 || !body.trim()) return setNotice("Vul een onderwerp en bericht in.");
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const key = crypto.randomUUID();
    const payload = { groupId, category, subject: subject.trim(), body: body.trim() };
    const { data, error } = await client.schema("api").rpc("group_ticket_create", {
      _group_id: groupId,
      _category: category,
      _subject: payload.subject,
      _body: payload.body,
      _idempotency_key: key,
      _request_hash: await digest(payload),
    });
    setBusy(false);
    if (error) return setNotice(error.message.includes("TOO_MANY_OPEN_TICKETS") ? "Er staan al tien gesprekken open. Rond eerst een gesprek af." : "Het bericht kon niet worden verstuurd.");
    setSubject(""); setBody(""); setNewTicket(false);
    setSelectedId((data as { id: string }).id);
    setNotice("Gesprek gestart. De organisatie en jij ontvangen een e-mailmelding.");
    await load();
  }

  async function sendReply() {
    if (!selected || !reply.trim()) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const key = crypto.randomUUID();
    const payload = { ticketId: selected.id, version: selected.version, body: reply.trim() };
    const { error } = await client.schema("api").rpc("group_ticket_reply", {
      _ticket_id: selected.id,
      _expected_version: selected.version,
      _body: payload.body,
      _idempotency_key: key,
      _request_hash: await digest(payload),
    });
    setBusy(false);
    if (error) return setNotice("Het gesprek is intussen gewijzigd. Vernieuw en probeer opnieuw.");
    setReply(""); setNotice("Reactie verstuurd en per e-mail gemeld."); await load();
  }

  async function setStatus(status: "open" | "closed") {
    if (!selected) return;
    const reason = window.prompt(status === "closed" ? "Waarom sluit je dit gesprek?" : "Waarom wil je dit gesprek heropenen?")?.trim();
    if (!reason || reason.length < 5) return setNotice("Geef een korte reden van minimaal vijf tekens.");
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("group_ticket_set_status", {
      _ticket_id: selected.id, _expected_version: selected.version, _status: status, _reason: reason,
    });
    setNotice(error ? "De status kon niet worden gewijzigd." : status === "closed" ? "Gesprek gesloten." : "Gesprek heropend.");
    await load();
  }

  return <section className="panel ticket-center">
    <div className="row-between ticket-heading">
      <div><p className="kicker">Contact met de organisatie</p><h2>Hulp & contact</h2><p>Stel een vraag over jullie groep en houd alle reacties op één plek. Bij direct gevaar bel je 112.</p></div>
      <button className="btn" onClick={() => setNewTicket((value) => !value)}><MessageSquarePlus size={18} />Nieuw gesprek</button>
    </div>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    {newTicket && <div className="ticket-new-form">
      <label className="field"><span>Waar gaat het over?</span><select value={category} onChange={(event) => setCategory(event.target.value)}><option value="question">Algemene vraag</option><option value="planning">Planning of route</option><option value="accessibility">Toegankelijkheid</option><option value="incident">Incident</option><option value="other">Iets anders</option></select></label>
      <label className="field"><span>Onderwerp</span><input maxLength={160} value={subject} onChange={(event) => setSubject(event.target.value)} /></label>
      <label className="field"><span>Bericht</span><textarea rows={5} maxLength={4000} value={body} onChange={(event) => setBody(event.target.value)} /></label>
      <button className="btn" disabled={busy} onClick={() => void createTicket()}><Send size={17} />Versturen</button>
    </div>}
    <div className="ticket-layout">
      <div className="ticket-list" aria-label="Gesprekken">
        {tickets.length === 0 && <p>Nog geen gesprekken. Start hierboven een gesprek als jullie hulp nodig hebben.</p>}
        {tickets.map((ticket) => <button key={ticket.id} className={ticket.id === selectedId ? "active" : ""} onClick={() => setSelectedId(ticket.id)}>
          <span><strong>{ticket.subject}</strong><small>{ticket.reference} · {statusLabels[ticket.status]}</small></span>
          {ticket.unreadCount > 0 && <b aria-label={`${ticket.unreadCount} ongelezen`}>{ticket.unreadCount}</b>}
        </button>)}
      </div>
      {selected && <div className="ticket-thread">
        <div className="row-between"><div><h3>{selected.subject}</h3><small>{selected.reference} · {statusLabels[selected.status]}</small></div><LifeBuoy /></div>
        <div className="ticket-messages">
          {selected.messages.map((message) => <article key={message.id} className={`ticket-message ${message.isMine ? "mine" : "theirs"}`}><strong>{message.isMine ? "Jij" : "Organisatie"}</strong><p>{message.body}</p><small>{new Date(message.createdAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })}{message.isMine && message.readAt ? <><CheckCheck size={14} /> gelezen</> : ""}</small></article>)}
        </div>
        {selected.status !== "closed" && <div className="ticket-reply"><label className="field"><span>Jouw reactie</span><textarea rows={4} maxLength={4000} value={reply} onChange={(event) => setReply(event.target.value)} /></label><button className="btn" disabled={busy || !reply.trim()} onClick={() => void sendReply()}><Send size={17} />Verstuur reactie</button></div>}
        <button className="text-link" onClick={() => void setStatus(selected.status === "closed" ? "open" : "closed")}>{selected.status === "closed" ? "Gesprek heropenen" : "Gesprek sluiten"}</button>
      </div>}
    </div>
  </section>;
}
