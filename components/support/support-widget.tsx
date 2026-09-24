"use client";

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CheckCheck, MessageCircle, Minus, RefreshCw, Send, Wifi, WifiOff, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type MessengerMessage = {
  id: string;
  senderSide: "participant" | "organization";
  body: string;
  createdAt: string;
  isMine: boolean;
  readAt?: string | null;
};

type MessengerConversation = {
  id: string;
  subjectKind: "group" | "portal" | "viewer" | "user";
  subjectId: string;
  subjectLabel?: string | null;
  systemCode?: string | null;
  displayName?: string | null;
  status: "queued" | "live" | "awaiting_organization" | "awaiting_participant" | "closed";
  version: number;
  updatedAt: string;
  unreadCount: number;
  messages: MessengerMessage[];
};

type MessengerContext = {
  available: boolean;
  subjectKind: MessengerConversation["subjectKind"];
  subjectId: string;
  subjectLabel?: string | null;
  systemCode?: string | null;
  displayName?: string | null;
  conversation?: MessengerConversation | null;
};

export type SupportWidgetProps = {
  eventSlug: string;
  role: string;
  groupId?: string;
  portalId?: string;
  viewerAccessId?: string;
};

const statusText: Record<MessengerConversation["status"], string> = {
  queued: "Je staat in de wachtrij.",
  live: "Een beheerder is beschikbaar.",
  awaiting_organization: "Je bericht wacht op de organisatie.",
  awaiting_participant: "De organisatie wacht op jouw antwoord.",
  closed: "Dit gesprek is gesloten. Een nieuw bericht opent opnieuw een gesprek.",
};

async function requestHash(value: unknown) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function roleArguments(props: SupportWidgetProps) {
  return {
    _event_slug: props.eventSlug,
    // A registered walker can contact support before a group is assigned.
    // The server still authorizes the personal subject against their registration.
    _role: props.role === "walker" && !props.groupId ? "user" : props.role,
    _group_id: props.groupId ?? null,
    _portal_id: props.portalId ?? null,
    _viewer_access_id: props.viewerAccessId ?? null,
  };
}

export function SupportWidget({ eventSlug, role, groupId, portalId, viewerAccessId }: SupportWidgetProps) {
  const [context, setContext] = useState<MessengerContext | null>(null);
  const [open, setOpen] = useState(false);
  const [minimized, setMinimized] = useState(false);
  const [online, setOnline] = useState(true);
  const [live, setLive] = useState(false);
  const [connectionNotice, setConnectionNotice] = useState("");
  const [body, setBody] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const launcherRef = useRef<HTMLButtonElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const pendingSend = useRef<{ text: string; hash: string; key: string; conversationId: string | null; version: number | null } | null>(null);
  const sending = useRef(false);
  const conversation = context?.conversation ?? null;

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) {
      setConnectionNotice("De chat is tijdelijk niet beschikbaar. Probeer het later opnieuw.");
      return;
    }
    try {
      const { data, error } = await client.schema("api").rpc("participant_messenger_context", roleArguments({ eventSlug, role, groupId, portalId, viewerAccessId }));
      if (error) {
        if (error.code === "42501" || error.code === "PGRST301") {
          setContext(null);
          setConnectionNotice("Je chattoegang kon niet worden bevestigd. Log zo nodig opnieuw in.");
        } else {
          setConnectionNotice("Berichten konden niet worden vernieuwd. Je tekst blijft staan. Probeer het opnieuw.");
        }
        return;
      }
      setOnline(true);
      setConnectionNotice("");
      setContext(data as MessengerContext);
    } catch {
      setConnectionNotice("Berichten konden niet worden vernieuwd. Je tekst blijft staan. Probeer het opnieuw.");
    }
  }, [eventSlug, groupId, portalId, role, viewerAccessId]);

  useEffect(() => {
    const reconnect = () => { setOnline(true); void load(); };
    const disconnect = () => setOnline(false);
    const first = window.setTimeout(() => { setOnline(navigator.onLine); if (navigator.onLine) void load(); }, 0);
    const polling = window.setInterval(() => { if (navigator.onLine) void load(); }, 15_000);
    window.addEventListener("online", reconnect);
    window.addEventListener("offline", disconnect);
    return () => {
      window.clearTimeout(first);
      window.clearInterval(polling);
      window.removeEventListener("online", reconnect);
      window.removeEventListener("offline", disconnect);
    };
  }, [load]);

  useEffect(() => {
    const client = createClient();
    if (!client || !conversation?.id) return;
    let active = true;
    const channel = client
      .channel("messenger:" + conversation.id, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe((status: string) => { if (active) setLive(status === "SUBSCRIBED"); });
    return () => {
      active = false;
      void client.removeChannel(channel);
    };
  }, [conversation?.id, load]);

  useEffect(() => {
    if (!open || minimized) return;
    closeRef.current?.focus();
  }, [open, minimized]);

  useEffect(() => {
    if (open && !minimized) threadRef.current?.scrollTo({ top: threadRef.current.scrollHeight });
  }, [open, minimized, conversation?.messages.length]);

  useEffect(() => {
    if (!open || minimized || !conversation?.unreadCount) return;
    const client = createClient();
    if (!client) return;
    const timer = window.setTimeout(async () => {
      const { error } = await client
        .schema("api")
        .rpc("participant_messenger_mark_read", { _conversation_id: conversation.id });
      if (!error) await load();
    }, 250);
    return () => window.clearTimeout(timer);
  }, [conversation?.id, conversation?.unreadCount, load, minimized, open]);

  const unread = conversation?.unreadCount ?? 0;
  const subjectLabel = useMemo(
    () => [context?.systemCode, context?.displayName || context?.subjectLabel].filter((value, index, values) => value && values.indexOf(value) === index).join(" · "),
    [context?.displayName, context?.subjectLabel, context?.systemCode],
  );

  function closeDialog() {
    setOpen(false);
    setMinimized(false);
    window.setTimeout(() => launcherRef.current?.focus(), 0);
  }

  async function send(event: FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || !context || sending.current || !navigator.onLine) return;
    const client = createClient();
    if (!client) return;
    sending.current = true;
    setBusy(true);
    setNotice("");
    const payload = conversation && conversation.status !== "closed"
      ? { conversationId: conversation.id, version: conversation.version, body: text }
      : { eventSlug, subjectKind: context.subjectKind, subjectId: context.subjectId, body: text };
    try {
      // Keep the original request even if polling discovers the committed message
      // before a lost-response retry. The server returns the same durable receipt.
      if (pendingSend.current?.text !== text) pendingSend.current = {
        text, hash: await requestHash(payload), key: crypto.randomUUID(),
        conversationId: conversation && conversation.status !== "closed" ? conversation.id : null,
        version: conversation?.version ?? null,
      };
      const { key, hash, conversationId, version } = pendingSend.current;
      const request = conversationId
        ? client.schema("api").rpc("participant_messenger_reply", {
            _conversation_id: conversationId,
            _expected_version: version,
            _body: text,
            _idempotency_key: key,
            _request_hash: hash,
          })
        : client.schema("api").rpc("participant_messenger_create", {
            _event_slug: eventSlug,
            _subject_kind: context.subjectKind,
            _subject_id: context.subjectId,
            _body: text,
            _idempotency_key: key,
            _request_hash: hash,
          });
      const { error } = await request;
      if (error) {
        if (error.code === "40001" || error.message === "CONVERSATION_CLOSED") {
          pendingSend.current = null;
          setNotice("Het gesprek is intussen gewijzigd. Bekijk de nieuwste berichten en verstuur je tekst opnieuw.");
          await load();
        } else if (error.code === "42501" || error.code === "PGRST301") {
          setNotice("Je chattoegang kon niet worden bevestigd. Je tekst blijft staan; log zo nodig opnieuw in.");
          await load();
        } else if (error.message === "RATE_LIMITED") {
          pendingSend.current = null;
          setNotice("Je verstuurt veel berichten achter elkaar. Wacht even en probeer het opnieuw.");
        } else {
          setNotice("Verzenden is niet bevestigd. Je tekst blijft staan. Probeer opnieuw zodra je verbinding hebt.");
        }
        return;
      }
      pendingSend.current = null;
      setBody("");
      setNotice("Bericht verstuurd.");
      await load();
    } catch {
      setNotice("Verzenden is niet bevestigd. Je tekst blijft staan. Probeer het opnieuw.");
    } finally {
      sending.current = false;
      setBusy(false);
    }
  }

  return (
    <div className="messenger-widget">
      {!open && (
        <button
          ref={launcherRef}
          className="messenger-launcher"
          type="button"
          aria-haspopup="dialog"
          aria-expanded="false"
          onClick={() => setOpen(true)}
        >
          <MessageCircle aria-hidden="true" />
          <span>Hulp van de organisatie</span>
          {unread > 0 && <b className="messenger-unread" aria-label={String(unread) + " ongelezen berichten"}>{unread}</b>}
        </button>
      )}

      {open && (
        <section
          className={"messenger-dialog" + (minimized ? " is-minimized" : "")}
          role="dialog"
          aria-modal="false"
          aria-labelledby="messenger-heading"
          onKeyDown={(event) => {
            if (event.key === "Escape") closeDialog();
          }}
        >
          <header className="messenger-header">
            <div>
              <p className="messenger-eyebrow">
                {online ? <Wifi aria-hidden="true" /> : <WifiOff aria-hidden="true" />}
                <span>{!online ? "Je bent offline" : !context ? "Chat verbinden" : live && context.available ? "Chat beschikbaar" : "Berichten beschikbaar"}</span>
              </p>
              <h2 id="messenger-heading">Hulp van de organisatie</h2>
              {subjectLabel && <small>{subjectLabel}</small>}
            </div>
            <div className="messenger-controls">
              <button type="button" aria-label={minimized ? "Gesprek uitklappen" : "Gesprek minimaliseren"} onClick={() => setMinimized((value) => !value)}>
                <Minus aria-hidden="true" />
              </button>
              <button ref={closeRef} type="button" aria-label="Gesprek sluiten" onClick={closeDialog}>
                <X aria-hidden="true" />
              </button>
            </div>
          </header>

          {!minimized && (
            <>
              <div className="messenger-thread" ref={threadRef} aria-live="polite" aria-relevant="additions text">
                {!conversation?.messages.length && (
                  <div className="messenger-empty">
                    <MessageCircle aria-hidden="true" />
                    <p>Waar kunnen we mee helpen? Jullie gesprek blijft hier bewaard.</p>
                  </div>
                )}
                {conversation?.messages.map((message) => (
                  <article className={"messenger-message " + (message.isMine ? "is-mine" : "is-theirs")} key={message.id}>
                    <strong>{message.isMine ? "Jij" : "Organisatie"}</strong>
                    <p>{message.body}</p>
                    <small>
                      {new Date(message.createdAt).toLocaleString("nl-NL", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}
                      {message.isMine && message.readAt && <><CheckCheck aria-hidden="true" /> gelezen</>}
                    </small>
                  </article>
                ))}
              </div>
              <p className="messenger-status">{conversation ? statusText[conversation.status] : "Start een privégesprek met de organisatie."}</p>
              {(notice || connectionNotice || !online) && <div className="messenger-notice" role="status">
                <p>{!online ? "Je bent offline. Je tekst blijft staan; verzend zodra je weer verbinding hebt." : connectionNotice || notice}</p>
                {online && connectionNotice && <button type="button" onClick={() => void load()}><RefreshCw aria-hidden="true" />Opnieuw verbinden</button>}
              </div>}
              <form className="messenger-compose" onSubmit={send}>
                <label htmlFor="messenger-body">Bericht</label>
                <textarea
                  id="messenger-body"
                  rows={3}
                  maxLength={4000}
                  value={body}
                  onChange={(event) => setBody(event.target.value)}
                  placeholder="Schrijf je bericht…"
                  disabled={busy}
                  required
                />
                <div>
                  <small>{body.length}/4000</small>
                  <button type="submit" disabled={busy || !body.trim() || !context || !online}>
                    <Send aria-hidden="true" />
                    {busy ? "Versturen…" : "Versturen"}
                  </button>
                </div>
              </form>
            </>
          )}
        </section>
      )}
    </div>
  );
}
