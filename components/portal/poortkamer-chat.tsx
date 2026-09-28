"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowDown, AtSign, BellOff, Flag, MessageCircle, MoreHorizontal, Pin, Send, ShieldCheck, Trash2 } from "lucide-react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { createClient } from "@/lib/supabase/client";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { portalTime, roomError, type ChatSnapshot, type PortalRoom, type RoomMessage } from "@/lib/domain/poortkamer";
import "@/components/ui/chat.css";

export type ChatRoom = Pick<PortalRoom, "userId" | "channels" | "team" | "updatedAt" | "portalTopic" | "communityTopic"> & { portal: { id: string | null } };
export function PoortkamerChat({ room, disabled, refresh, admin = false, initialChannel }: {
  room: ChatRoom; disabled: boolean; refresh: () => Promise<void>; admin?: boolean; initialChannel?: string;
}) {
  const [area, setArea] = useState(initialChannel ? room.channels.find(c => c.id === initialChannel)?.kind ?? "community" : admin && !room.portal.id ? "community" : "team");
  const [selected, setSelected] = useState(initialChannel ?? "");
  const channel = room.channels.find(c => c.id === selected && c.kind === area) ?? room.channels.find(c => c.kind === area);
  const channelId = channel?.id;
  const [snapshot, setSnapshot] = useState<ChatSnapshot | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const body = drafts[channelId ?? ""] ?? "";
  const [mention, setMention] = useState("");
  const [urgent, setUrgent] = useState(false);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const [hasHistory, setHasHistory] = useState(false);
  const [moderation, setModeration] = useState<{ message: RoomMessage; operation: "hide" | "report" | "mute_author" } | null>(null);
  const [reason, setReason] = useState("");
  const [newMessages, setNewMessages] = useState(false);
  const pending = useRef<{ fingerprint: string; key: string } | null>(null);
  const sending = useRef(false);
  const historyExhausted = useRef(false);
  const sequence = useRef(0);
  const invalidate = useCallback(() => { sequence.current++; }, []);
  const scroll = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  const read = useRef<Record<string, number>>({});
  const current = snapshot?.channelId === channelId ? snapshot : null;
  const load = useCallback(async (changedMessage?: number) => {
    if (!channelId || document.hidden || !navigator.onLine) return;
    const client = createClient();
    if (!client) return;
    const request = ++sequence.current;
    const { data, error } = await client.schema("api").rpc("portal_chat_snapshot", { _channel_id: channelId });
    if (request !== sequence.current) return;
    if (error) {
      if (error.code === "42501" || error.code === "PGRST301") setSnapshot(null);
      setNotice(roomError(error.message));
      return;
    }
    const next = data as ChatSnapshot;
    // Refresh a moderated older message too, without jumping away from history.
    let changed: RoomMessage | undefined;
    if (Number.isSafeInteger(changedMessage) && changedMessage! < (next.messages[0]?.id ?? 0)) {
      const history = await client.schema("api").rpc("portal_chat_snapshot", { _channel_id: channelId, _before: changedMessage! + 1 });
      if (request !== sequence.current) return;
      changed = (history.data as ChatSnapshot | null)?.messages.find(m => m.id === changedMessage);
    }
    setSnapshot(previous => {
      if (previous?.channelId !== next.channelId) return next;
      const oldest = next.messages[0]?.id ?? Infinity;
      return { ...next, messages: [...previous.messages.filter(m => m.id < oldest).map(m => changed?.id === m.id ? changed : m), ...next.messages] };
    });
    if (!historyExhausted.current) setHasHistory(next.messages.length === 60);
    const last = next.messages.at(-1)?.id;
    if (last && read.current[channelId] !== last) {
      read.current[channelId] = last;
      await client.schema("api").rpc("portal_chat_action", { _channel_id: channelId, _operation: "read", _payload: { messageId: last } });
    }
  }, [channelId]);
  const live = usePrivateBroadcast(area === "team" ? room.portalTopic : room.communityTopic, change => void load(change?.messageId));
  useEffect(() => {
    follow.current = true;
    const first = setTimeout(() => { setSnapshot(null); historyExhausted.current = false; setHasHistory(false); setNewMessages(false); setModeration(null); setReason(""); void load(); }, 0);
    const poll = setInterval(() => void load(), 15_000);
    const resume = () => { if (!document.hidden) { setSnapshot(null); historyExhausted.current = false; setHasHistory(false); void load(); } };
    document.addEventListener("visibilitychange", resume);
    window.addEventListener("online", resume);
    return () => { invalidate(); clearTimeout(first); clearInterval(poll); document.removeEventListener("visibilitychange", resume); window.removeEventListener("online", resume); };
  }, [load, invalidate]);
  const currentChannel = current?.channelId;
  const lastMessage = current?.messages.at(-1)?.id;
  useEffect(() => {
    if (!currentChannel) return;
    const timer = setTimeout(() => {
      if (follow.current && scroll.current) scroll.current.scrollTop = scroll.current.scrollHeight;
      else setNewMessages(true);
    }, 0);
    return () => clearTimeout(timer);
  }, [currentChannel, lastMessage]);
  async function history() {
    const client = createClient();
    if (!client || !current || loadingHistory) return;
    setLoadingHistory(true);
    const top = scroll.current?.scrollHeight ?? 0;
    const { data, error } = await client.schema("api").rpc("portal_chat_snapshot", { _channel_id: channelId, _before: current.messages[0]?.id });
    setLoadingHistory(false);
    if (error) return setNotice("Eerdere berichten laden lukt even niet. Probeer opnieuw.");
    const older = data as ChatSnapshot;
    historyExhausted.current = older.messages.length < 60;
    setHasHistory(!historyExhausted.current);
    setSnapshot(previous => previous?.channelId === older.channelId ? { ...previous, messages: [...older.messages.filter(m => !previous.messages.some(p => p.id === m.id)), ...previous.messages] } : previous);
    requestAnimationFrame(() => { if (scroll.current) scroll.current.scrollTop += scroll.current.scrollHeight - top; });
  }
  async function action(operation: string, payload: Record<string, unknown>) {
    if (disabled || busy || !navigator.onLine || !channelId) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    try {
      const { error } = await client.schema("api").rpc("portal_chat_action", { _channel_id: channelId, _operation: operation, _payload: payload });
      if (error) { setNotice(roomError(error.message)); return; }
      setModeration(null); setReason(""); setNotice(operation === "report" ? "Bedankt. Een moderator bekijkt je melding." : "");
      await load(typeof payload.messageId === "number" ? payload.messageId : undefined); await refresh();
    } catch { setNotice("Dat lukte even niet. Probeer opnieuw."); }
    finally { setBusy(false); }
  }
  async function send(event: React.FormEvent) {
    event.preventDefault();
    if (sending.current || disabled || !navigator.onLine || !channelId || !body.trim()) return;
    const client = createClient();
    if (!client) return;
    sending.current = true; setBusy(true); setNotice("");
    const fingerprint = JSON.stringify([channelId, body, mention, urgent]);
    if (pending.current?.fingerprint !== fingerprint) pending.current = { fingerprint, key: crypto.randomUUID() };
    try {
      const { error } = await client.schema("api").rpc("portal_chat_send", {
        _channel_id: channelId, _body: body, _key: pending.current.key, _portal_id: room.portal.id,
        _mentions: mention ? [mention] : [], _urgent: urgent,
      });
      if (error) { setNotice(roomError(error.message)); return; }
      setDrafts(previous => ({ ...previous, [channelId]: "" })); setMention(""); setUrgent(false);
      pending.current = null; follow.current = true;
      await load(); await refresh();
    } catch { setNotice("Nog niet verstuurd. Je bericht blijft klaarstaan. Probeer opnieuw."); }
    finally { sending.current = false; setBusy(false); }
  }
  const mentionOptions = area === "team" ? room.team.filter(m => !m.suspendedAt) : Array.from(new Map((current?.messages ?? []).filter(m => m.mentionUserId).map(m => [m.mentionUserId!, { userId: m.mentionUserId!, name: `${m.sender} · ${m.portalCode ?? "Poortwachter"}` }])).values());
  const title = area === "team" ? "Achter de Poort" : area === "community" ? "Praatkamer" : "Van de organisatie";
  return <section className="room-chat" aria-label="Berichten">
    <nav className="workspace-tabs" aria-label="Gesprekken kiezen">
      {(["team", "community", "announcements"] as const).filter(kind => room.channels.some(c => c.kind === kind)).map(kind => <button type="button" key={kind} aria-pressed={area === kind} onClick={() => { setArea(kind); setSelected(""); setMention(""); setNotice(""); }}>
        {kind === "team" ? "Achter de Poort" : kind === "community" ? "Praatkamer" : "De Omroeper"}
        {room.channels.filter(c => c.kind === kind).reduce((sum, c) => sum + c.unread, 0) > 0 && <span className="chat-unread">{room.channels.filter(c => c.kind === kind).reduce((sum, c) => sum + c.unread, 0)}</span>}
      </button>)}
    </nav>
    <div className="chat-window">
      <header className="chat-header">
        <span className="chat-avatar"><MessageCircle size={22} /></span>
        <div><h2>{title}</h2><p>{area === "team" ? "Jullie teamgesprek" : area === "community" ? "Tips en overleg met andere poorten" : "Korte updates voor alle poorten"} <span className="chat-connection">· {live ? "Live" : "Verbinden…"}</span></p></div>
        {channel && area !== "announcements" && <button type="button" className="chat-icon" title={channel.muted ? "Meldingen aanzetten" : "Meldingen dempen"} aria-label={channel.muted ? "Meldingen aanzetten" : "Meldingen dempen"} aria-pressed={channel.muted} disabled={disabled || busy} onClick={() => void action("mute", { muted: !channel.muted })}><BellOff size={18} /></button>}
      </header>
      {area === "community" && <nav className="chat-channels" aria-label="Praatkamer kanalen">{room.channels.filter(c => c.kind === area).map(c => <button type="button" key={c.id} aria-pressed={channelId === c.id} onClick={() => { setSelected(c.id); setMention(""); setNotice(""); }}>#{c.name}{c.unread > 0 && <b>{c.unread}</b>}</button>)}</nav>}
      {current?.pins.length ? <details className="chat-pins"><summary><Pin size={14} /> {current.pins.length} vastgezet</summary>{current.pins.map(pin => <p key={pin.id}>{pin.body}</p>)}</details> : null}
      {notice && <p className="chat-notice" role="status">{notice}</p>}
      <div className="chat-history" ref={scroll} role="log" aria-label="Berichtgeschiedenis" aria-live="polite" aria-relevant="additions text" onScroll={() => { const el = scroll.current; follow.current = !!el && el.scrollHeight - el.scrollTop - el.clientHeight < 100; if (follow.current) setNewMessages(false); }}>
        {hasHistory && <button type="button" className="chat-history-more" disabled={loadingHistory} onClick={() => void history()}>{loadingHistory ? "Laden…" : "Eerdere berichten"}</button>}
        {!current ? <p className="chat-empty">Berichten ophalen…</p> : !current.messages.length ? <div className="chat-empty"><MessageCircle size={36} /><h3>{area === "announcements" ? "Je bent helemaal bij" : "Hier begint jullie gesprek"}</h3><p>{area === "announcements" ? "Nieuwe berichten van de organisatie verschijnen hier." : "Stel een vraag, deel een idee of zeg even hallo."}</p></div> : current.messages.map((m, index) => <div className="chat-entry" key={m.id}>
          {(index === 0 || new Date(m.createdAt).toDateString() !== new Date(current.messages[index - 1].createdAt).toDateString()) && <div className="chat-date">{new Date(m.createdAt).toLocaleDateString("nl-NL", { day: "numeric", month: "long", timeZone: "Europe/Amsterdam" })}</div>}
          <article className={`chat-bubble ${m.own ? "is-mine" : ""} ${m.system ? "is-system" : ""}`}>
            {!m.system && <div className="chat-sender"><strong>{m.own ? "Jij" : m.sender}{m.portalCode ? ` · ${m.portalCode}` : ""}</strong>{m.pinned && <Pin size={13} />}
              {!m.hidden && (current.canPin || current.canModerate || !m.own) && <details className="chat-message-menu"><summary aria-label="Berichtopties"><MoreHorizontal size={18} /></summary><div>
                {current.canPin && <button type="button" disabled={disabled || busy} onClick={() => void action("pin", { messageId: m.id, pinned: !m.pinned })}><Pin size={15} />{m.pinned ? "Losmaken" : "Vastzetten"}</button>}{current.canModerate && <button type="button" onClick={() => setModeration({ message: m, operation: "hide" })}><Trash2 size={15} />Verbergen</button>}
                {admin && area === "community" && !m.own && <button type="button" onClick={() => setModeration({ message: m, operation: "mute_author" })}><BellOff size={15} />24 uur spreekpauze</button>}
                {!m.own && <button type="button" onClick={() => setModeration({ message: m, operation: "report" })}><Flag size={15} />Melden</button>}
              </div></details>}
            </div>}
            {m.urgent && <strong className="chat-important">Belangrijke update</strong>}
            <p>{m.body}</p><footer><time dateTime={m.createdAt}>{portalTime(m.createdAt)}</time>
              {!m.system && !m.hidden && area !== "announcements" && <div className="chat-reactions">{["👍", "❤️", "🎃"].map(emoji => { const reaction = m.reactions.find(r => r.emoji === emoji); return <button type="button" key={emoji} aria-label={`Reageer ${emoji}`} aria-pressed={reaction?.own ?? false} disabled={disabled || busy} onClick={() => void action("react", { messageId: m.id, emoji, active: !reaction?.own })}>{emoji}{reaction?.count ? ` ${reaction.count}` : ""}</button>; })}</div>}
            </footer>
          </article>
        </div>)}
      </div>
      {newMessages && <button type="button" className="chat-new" onClick={() => { follow.current = true; setNewMessages(false); if (scroll.current) scroll.current.scrollTop = scroll.current.scrollHeight; }}>Nieuwe berichten <ArrowDown size={15} /></button>}
      {current?.canPost ? <form className="chat-composer" onSubmit={send}>
        <div className="chat-compose-line"><label className="sr-only" htmlFor={`chat-${channelId}`}>Je bericht</label><textarea id={`chat-${channelId}`} placeholder={area === "announcements" ? "Schrijf een korte update…" : "Schrijf een bericht…"} rows={2} maxLength={1000} value={body} disabled={disabled || busy} onChange={e => setDrafts(previous => ({ ...previous, [channelId!]: e.target.value }))} onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing && matchMedia("(pointer:fine)").matches) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} /><button className="chat-send" type="submit" aria-label="Versturen" disabled={disabled || busy || !body.trim()}><Send size={20} /></button></div>
        <div className="chat-compose-tools">{area !== "announcements" && mentionOptions.some(m => m.userId !== room.userId) && <label><AtSign size={15} /><span className="sr-only">Vermeld een teamlid</span><select aria-label="Vermeld een teamlid" value={mention} onChange={e => setMention(e.target.value)}><option value="">Iemand vermelden</option>{mentionOptions.filter(m => m.userId !== room.userId).map(m => <option key={m.userId} value={m.userId}>{m.name}</option>)}</select></label>}{area === "announcements" && admin && <label><input type="checkbox" checked={urgent} onChange={e => setUrgent(e.target.checked)} /> Belangrijk · stuur ook een melding</label>}<small>{body.length}/1000</small></div>
      </form> : current && <p className="chat-readonly">{area === "announcements" ? "Een vraag over een update? Stuur de organisatie een privébericht via Hulp." : "Je kunt dit gesprek lezen. Berichten sturen is tijdelijk uitgezet."}</p>}
    </div>
    <p className="chat-guidance"><ShieldCheck size={14} />{area === "team" ? "Voor jullie eigen team. Houd het gezellig." : "De organisatie houdt toezicht in de Praatkamer. Houd rekening met elkaar."}</p>
    <Dialog open={!!moderation} onOpenChange={open => { if (!open && !busy) { setModeration(null); setReason(""); } }}><DialogContent className="chat-dialog"><DialogTitle>{moderation?.operation === "hide" ? "Bericht verbergen?" : moderation?.operation === "mute_author" ? "24 uur spreekpauze" : "Bericht melden"}</DialogTitle><DialogDescription>{moderation?.operation === "hide" ? "De tekst verdwijnt uit het gesprek. De andere berichten blijven staan." : "Vertel kort waarom dit bericht aandacht nodig heeft."}</DialogDescription><form onSubmit={e => { e.preventDefault(); if (moderation) void action(moderation.operation, { messageId: moderation.message.id, reason }); }}>{moderation?.operation !== "hide" && <label className="field">Reden<textarea required minLength={5} maxLength={500} value={reason} onChange={e => setReason(e.target.value)} /></label>}<div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={() => setModeration(null)}>Annuleren</button><button type="submit" className="btn" disabled={busy}>{moderation?.operation === "hide" ? "Verbergen" : "Bevestigen"}</button></div></form></DialogContent></Dialog>
  </section>;
}
