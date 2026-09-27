"use client";
import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import { Send, Pin, Megaphone, Flag } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  portalRoles,
  portalTime,
  roomError,
  type ChatSnapshot,
  type PortalRoom,
  type RoomChannel,
} from "@/lib/domain/poortkamer";
import s from "./poortkamer.module.css";

export function PoortkamerChat({
  room,
  disabled,
  refresh,
  admin = false,
  initialChannel,
}: {
  room: PortalRoom;
  disabled: boolean;
  refresh: () => Promise<void>;
  admin?: boolean;
  initialChannel?: string;
}) {
  const [area, setArea] = useState<RoomChannel["kind"]>(
    initialChannel
      ? (room.channels.find((c) => c.id === initialChannel)?.kind ??
          "community")
      : "team",
  );
  const [selected, setSelected] = useState(initialChannel ?? "");
  const channel =
    room.channels.find((c) => c.id === selected && c.kind === area) ??
    room.channels.find((c) => c.kind === area);
  const [snapshot, setSnapshot] = useState<ChatSnapshot | null>(null);
  const [body, setBody] = useState("");
  const [mention, setMention] = useState("");
  const [urgent, setUrgent] = useState(false);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  const pending = useRef<{ fingerprint: string; key: string } | null>(null);
  const channelId = channel?.id;
  const load = useCallback(async () => {
    if (!channelId || document.hidden || !navigator.onLine) return;
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("portal_chat_snapshot", { _channel_id: channelId });
    if (error) {
      if (error.code === "42501") setSnapshot(null);
      setNotice(roomError(error.message));
      return;
    }
    const next = data as ChatSnapshot;
    setSnapshot(next);
    const last = next.messages.at(-1)?.id;
    if (last)
      await client.schema("api").rpc("portal_chat_action", {
        _channel_id: channelId,
        _operation: "read",
        _payload: { messageId: last },
      });
  }, [channelId]);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 20_000);
    return () => {
      clearTimeout(timer);
      clearInterval(poll);
    };
  }, [load, room.updatedAt]);
  async function action(operation: string, payload: Record<string, unknown>) {
    if (disabled || !navigator.onLine || !channel) return;
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("portal_chat_action", {
      _channel_id: channel.id,
      _operation: operation,
      _payload: payload,
    });
    if (error) setNotice(roomError(error.message));
    else {
      await load();
      await refresh();
    }
  }
  async function send(event: React.FormEvent) {
    event.preventDefault();
    if (
      sending.current ||
      disabled ||
      !navigator.onLine ||
      !channel ||
      !body.trim()
    )
      return;
    const client = createClient();
    if (!client) return;
    sending.current = true;
    setBusy(true);
    setNotice("");
    const fingerprint = JSON.stringify([channel.id, body, mention, urgent]);
    if (pending.current?.fingerprint !== fingerprint)
      pending.current = { fingerprint, key: crypto.randomUUID() };
    try {
      const { error } = await client.schema("api").rpc("portal_chat_send", {
        _channel_id: channel.id,
        _body: body,
        _key: pending.current.key,
        _portal_id: room.portal.id,
        _mentions: mention ? [mention] : [],
        _urgent: urgent,
      });
      if (error) {
        setNotice(roomError(error.message));
        return;
      }
      setBody("");
      setMention("");
      setUrgent(false);
      pending.current = null;
      await load();
      await refresh();
    } catch {
      setNotice(
        "Bericht niet bevestigd. Je tekst blijft staan; probeer opnieuw zodra je verbinding hebt.",
      );
    } finally {
      sending.current = false;
      setBusy(false);
    }
  }
  const current = snapshot?.channelId === channelId ? snapshot : null;
  const mentionOptions =
    area === "team"
      ? room.team
      : Array.from(
          new Map(
            (current?.messages ?? [])
              .filter((m) => m.mentionUserId)
              .map((m) => [
                m.mentionUserId!,
                {
                  userId: m.mentionUserId!,
                  name: `${m.sender} · ${m.portalCode ?? "Poortwachter"}`,
                },
              ]),
          ).values(),
        );
  return (
    <section aria-label="Berichten">
      <div className={s.tabs}>
        {([...["team", "community", "announcements"]] as const).map((kind) => (
          <button
            key={kind}
            className={s.button}
            aria-pressed={area === kind}
            onClick={() => {
              setArea(kind);
              setMention("");
              setSelected("");
              setBody("");
              setNotice("");
            }}
          >
            {kind === "team"
              ? "Achter de Poort"
              : kind === "community"
                ? "Het Poortplein"
                : "De Omroeper"}
          </button>
        ))}
      </div>
      <div className={s.card}>
        <h2>
          {area === "team"
            ? "Achter de Poort"
            : area === "community"
              ? "Het Poortplein"
              : "De Omroeper"}
        </h2>
        <p className={s.muted}>
          {area === "team"
            ? "Jullie eigen team. Stem af, deel een tip en houd samen de poort klaar."
            : area === "community"
              ? "Een besloten plein voor goedgekeurde Poortwachters, crew en organisatie. Deel hier geen adressen of contactgegevens."
              : "Mededelingen van de organisatie. Hier kun je lezen, maar niet antwoorden."}
        </p>
        {area === "community" && (
          <div className={s.channelList}>
            {room.channels
              .filter((c) => c.kind === area)
              .map((c) => (
                <button
                  className={s.button}
                  key={c.id}
                  aria-pressed={channelId === c.id}
                  onClick={() => setSelected(c.id)}
                >
                  {c.name}
                  {c.unread > 0 ? ` · ${c.unread}` : ""}
                </button>
              ))}
          </div>
        )}
        {channel && area !== "announcements" && (
          <label className={s.check}>
            <input
              type="checkbox"
              checked={channel.muted}
              disabled={disabled}
              onChange={(e) => void action("mute", { muted: e.target.checked })}
            />
            Meldingen voor dit kanaal dempen
          </label>
        )}
        {current?.pins.map((pin) => (
          <p className={s.notice} key={pin.id}>
            <Pin size={16} /> {pin.body}
          </p>
        ))}
        {!current ? (
          <p role="status">Berichten ophalen…</p>
        ) : current.messages.length === 0 ? (
          <div className={s.empty}>
            {area !== "announcements" && (
              <Image
                className={s.cardImage}
                src={`/images/poortkamer/${area === "team" ? "behind-the-gate-chat.webp" : "portal-square-community.webp"}`}
                width={720}
                height={405}
                sizes="(max-width: 650px) 90vw, 700px"
                alt=""
              />
            )}
            <p>
              {area === "announcements"
                ? "Er zijn nog geen mededelingen."
                : "Het is nog stil achter de poort. Begin het gesprek."}
            </p>
          </div>
        ) : (
          <div aria-label="Berichtgeschiedenis">
            {current.messages.map((m) => (
              <article
                className={s.message}
                data-own={m.own}
                data-system={m.system}
                key={m.id}
              >
                <div className={s.messageHeader}>
                  <strong>
                    {m.sender}
                    {m.role ? ` · ${portalRoles[m.role]}` : ""}
                    {m.portalCode ? ` · ${m.portalCode} ${m.portalName}` : ""}
                  </strong>
                  <time dateTime={m.createdAt}>{portalTime(m.createdAt)}</time>
                </div>
                {m.urgent && (
                  <strong>
                    <Megaphone size={16} /> Belangrijk
                  </strong>
                )}
                <p className={s.messageBody}>{m.body}</p>
                {!m.system && !m.hidden && (
                  <div className={s.actions}>
                    {area !== "announcements" &&
                      ["👍", "❤️", "🎃"].map((emoji) => {
                        const reaction = m.reactions.find(
                          (r) => r.emoji === emoji,
                        );
                        return (
                          <button
                            className={s.reaction}
                            aria-label={`Reageer ${emoji}`}
                            aria-pressed={reaction?.own ?? false}
                            disabled={disabled}
                            key={emoji}
                            onClick={() =>
                              void action("react", {
                                messageId: m.id,
                                emoji,
                                active: !reaction?.own,
                              })
                            }
                          >
                            {emoji} {reaction?.count ?? ""}
                          </button>
                        );
                      })}
                    <button
                      className={s.linkButton}
                      disabled={disabled}
                      onClick={() => {
                        const reason = window.prompt(
                          "Waarom meld je dit bericht? (5–500 tekens)",
                        );
                        if (reason)
                          void action("report", { messageId: m.id, reason });
                      }}
                    >
                      <Flag size={14} /> Melden
                    </button>
                    {(admin ||
                      (area === "team" &&
                        ["owner", "coadmin", "admin"].includes(room.role))) && (
                      <button
                        className={s.linkButton}
                        disabled={disabled}
                        onClick={() =>
                          void action("pin", {
                            messageId: m.id,
                            pinned: !m.pinned,
                          })
                        }
                      >
                        {m.pinned ? "Losmaken" : "Vastzetten"}
                      </button>
                    )}
                    {admin && (
                      <>
                        <button
                          className={s.linkButton}
                          disabled={disabled}
                          onClick={() => {
                            if (window.confirm("Dit bericht verbergen?"))
                              void action("hide", { messageId: m.id });
                          }}
                        >
                          Verbergen
                        </button>
                        {area === "community" && (
                          <button
                            className={s.linkButton}
                            onClick={() => {
                              const reason = window.prompt(
                                "Reden voor 24 uur spreekpauze op het Poortplein:",
                              );
                              if (reason)
                                void action("mute_author", {
                                  messageId: m.id,
                                  reason,
                                });
                            }}
                          >
                            Spreekpauze
                          </button>
                        )}
                      </>
                    )}
                  </div>
                )}
              </article>
            ))}
          </div>
        )}
        {current && current.messages.length === 60 && (
          <button
            className={s.button}
            onClick={async () => {
              const client = createClient();
              if (!client || !channel) return;
              const { data, error } = await client
                .schema("api")
                .rpc("portal_chat_snapshot", {
                  _channel_id: channel.id,
                  _before: current.messages[0].id,
                });
              if (!error) setSnapshot(data as ChatSnapshot);
            }}
          >
            Eerdere berichten
          </button>
        )}
        {notice && (
          <p className={s.notice} role="alert">
            {notice}
          </p>
        )}
      </div>
      {(area !== "announcements" || admin) && (
        <form className={s.composer} onSubmit={(event) => void send(event)}>
          <label className={s.field}>
            Bericht
            <textarea
              maxLength={1000}
              value={body}
              onChange={(e) => setBody(e.target.value)}
              disabled={disabled || busy}
              placeholder="Schrijf aan je Poortwachters…"
            />
          </label>
          {area !== "announcements" && (
            <label className={s.field}>
              {area === "team"
                ? "Vermeld een teamlid"
                : "Vermeld een Poortwachter uit dit gesprek"}
              <select
                value={mention}
                onChange={(e) => setMention(e.target.value)}
              >
                <option value="">Geen vermelding</option>
                {mentionOptions
                  .filter((m) => m.userId !== room.userId)
                  .map((m) => (
                    <option value={m.userId} key={m.userId}>
                      {m.name}
                    </option>
                  ))}
              </select>
            </label>
          )}
          {area === "announcements" && admin && (
            <label className={s.check}>
              <input
                type="checkbox"
                checked={urgent}
                onChange={(e) => setUrgent(e.target.checked)}
              />
              Urgent · verstuur ook een melding
            </label>
          )}
          <div className={s.actions}>
            <small>{body.length}/1000</small>
            <button
              className={`${s.button} ${s.primary}`}
              type="submit"
              disabled={disabled || busy || !body.trim()}
            >
              <Send size={16} />
              {busy ? "Versturen…" : "Versturen"}
            </button>
          </div>
        </form>
      )}
      <p className={s.footerNote}>
        Berichten worden automatisch verwijderd één maand na het evenement. Deel
        geen gegevens van kinderen, contactgegevens of volledige routes.
      </p>
    </section>
  );
}
