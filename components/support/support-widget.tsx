"use client";

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CheckCheck, MessageCircle, Minus, Send, Wifi, WifiOff, X } from "lucide-react";
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
    _role: props.role,
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
  const [body, setBody] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const launcherRef = useRef<HTMLButtonElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const conversation = context?.conversation ?? null;

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("participant_messenger_context", roleArguments({ eventSlug, role, groupId, portalId, viewerAccessId }));
    if (error) {
      setOnline(false);
      setContext(null);
      return;
    }
    setOnline(true);
    setContext(data as MessengerContext);
  }, [eventSlug, groupId, portalId, role, viewerAccessId]);

  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const polling = window.setInterval(() => void load(), 15_000);
    return () => {
      window.clearTimeout(first);
      window.clearInterval(polling);
    };
  }, [load]);

  useEffect(() => {
    const client = createClient();
    if (!client || !conversation?.id) return;
    const channel = client
      .channel("messenger:" + conversation.id, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe((status: string) => setOnline(status === "SUBSCRIBED"));
    return () => {
      void client.removeChannel(channel);
    };
  }, [conversation?.id, load]);

  useEffect(() => {
    if (!open || minimized) return;
    closeRef.current?.focus();
    threadRef.current?.scrollTo({ top: threadRef.current.scrollHeight });
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
  const heading = useMemo(
    () => context?.displayName || context?.subjectLabel || "Hulp van de organisatie",
    [context?.displayName, context?.subjectLabel],
  );

  function closeDialog() {
    setOpen(false);
    setMinimized(false);
    window.setTimeout(() => launcherRef.current?.focus(), 0);
  }

  async function send(event: FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || !context) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    setNotice("");
    const key = crypto.randomUUID();
    const payload = conversation
      ? { conversationId: conversation.id, version: conversation.version, body: text }
      : { eventSlug: eventSlug, subjectKind: context.subjectKind, subjectId: context.subjectId, body: text };
    const hash = await requestHash(payload);
    const request = conversation && conversation.status !== "closed"
      ? client.schema("api").rpc("participant_messenger_reply", {
          _conversation_id: conversation.id,
          _expected_version: conversation.version,
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
    setBusy(false);
    if (error) {
      setNotice("Het gesprek is intussen gewijzigd. De nieuwste berichten zijn opgehaald; probeer het opnieuw.");
      await load();
      return;
    }
    setBody("");
    setNotice("Bericht verstuurd.");
    await load();
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
                {online ? (context?.available ? "Chat beschikbaar" : "Berichten beschikbaar") : "Verbinding wordt hersteld"}
              </p>
              <h2 id="messenger-heading">{heading}</h2>
              {context?.systemCode && <small>{context.systemCode}</small>}
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
              {notice && <p className="messenger-notice" role="status">{notice}</p>}
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
                  <button type="submit" disabled={busy || !body.trim()}>
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
