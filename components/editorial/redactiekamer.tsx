"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  Bell,
  BookOpen,
  CalendarClock,
  Check,
  Copy,
  Eye,
  ImagePlus,
  Mail,
  Newspaper,
  Plus,
  Save,
  Send,
} from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  amsterdamInput,
  amsterdamToUtc,
  articleSchema,
  audienceLabels,
  blankArticle,
  campaignSchema,
  channelLabels,
  channels,
  emptyDocument,
  slugify,
  type ArticleContent,
  type Audience,
  type CampaignContent,
  type NewsChannel,
  type NewsItem,
  type Placement,
} from "@/lib/editorial/content";
import { MediaImage, NewsArticle, NewsCard } from "./news-view";
import { RichEditor, type EditorialMedia } from "./rich-editor";
import "./editorial.css";
type News = {
  id: string;
  slug: string;
  revision: number;
  versionId: string;
  version: number;
  content: ArticleContent;
  status: string;
  updatedAt: string;
  placements: (Placement & { versionId: string; state: string })[];
  planning: Partial<Record<NewsChannel, ChannelDraft>>;
  metrics: {
    channel: string;
    views: number;
    clicks: number;
    readers: number;
    audience: number;
    retainedPush: {
      users: number;
      devices: number;
      sent: number;
      invalid: number;
      failed: number;
      clicked: number;
    };
  }[];
};
type Campaign = {
  id: string;
  revision: number;
  versionId: string;
  status: string;
  content: CampaignContent;
  audience: Audience;
  scheduledAt: string | null;
  counts: Counts | null;
  testAccepted: boolean;
  testStatus?: string | null;
  testedVersion?: number | null;
  delivery: Record<string, number>;
  events: Record<string, number>;
};
type Counts = {
  profiles: number;
  uniqueEmails: number;
  duplicates: number;
  unsubscribed: number;
  suppressed: number;
  bounced: number;
  invalid: number;
  recipients: number;
  channelExcluded?: number;
};
type Snapshot = {
  news: News[];
  campaigns: Campaign[];
  media: EditorialMedia[];
  categories: {
    id: string;
    name: string;
    active: boolean;
    sort_order: number;
  }[];
  slots: { id: string; name: string; startsAt: string }[];
  worlds: { id: string; name: string }[];
  activeSubscriptions: number;
  mailHistory: {
    id: string;
    versionId: string;
    test: boolean;
    status: string;
    attempts: number;
    error: string | null;
    createdAt: string;
  }[];
  push: {
    id: string;
    versionId: string;
    createdAt: string;
    completedAt: string | null;
    failedAt: string | null;
    statuses: Record<string, number>;
  }[];
  sending: { email: boolean; push: boolean };
};
type Rights = {
  write: boolean;
  publish: boolean;
  compose: boolean;
  send: boolean;
};
const stateLabels: Record<string, string> = {
  draft: "Concept",
  ready: "Klaar voor controle",
  scheduled: "Ingepland",
  published: "Gepubliceerd",
  live: "Live",
  archived: "Gearchiveerd",
  preparing: "Voorbereiden",
  sending: "Verzenden",
  sent: "Verzonden",
  partial_failed: "Controle nodig",
  cancelled: "Geannuleerd",
  pending: "In wachtrij",
  queued: "In wachtrij",
  processing: "Wordt verwerkt",
  accepted: "Naar mailprovider",
  delivered: "Afgeleverd",
  deferred: "Tijdelijk uitgesteld",
  failed: "Mislukt",
  unknown: "Acceptatie onzeker · controleer provider",
  suppressed: "Uitgesloten",
  sent_to_pushservice: "Naar pushservice",
  invalid: "Verlopen abonnement",
  clicked: "Aangeklikt",
};
const format = (value: string | null) =>
  value
    ? new Intl.DateTimeFormat("nl-NL", {
        timeZone: "Europe/Amsterdam",
        dateStyle: "short",
        timeStyle: "short",
      }).format(new Date(value))
    : "—";
async function command<T = unknown>(
  value: Record<string, unknown>,
): Promise<T> {
  const response = await fetch("/api/editorial/admin", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  });
  const body = await response.json();
  if (!response.ok)
    throw new Error(
      body.error?.message ?? "De actie kon niet worden uitgevoerd.",
    );
  return body.data as T;
}
function errorMessage(cause: unknown) {
  return cause instanceof Error
    ? cause.message
    : "Dat ging niet goed. Probeer het opnieuw.";
}
function CountPreview({ counts }: { counts: Counts }) {
  const labels: Record<string, string> = {
    profiles: "Gevonden profielen",
    uniqueEmails: "Unieke e-mailadressen",
    duplicates: "Samengevoegde dubbelen",
    unsubscribed: "Zonder toestemming",
    suppressed: "Suppressions",
    bounced: "Bounce/blokkade",
    invalid: "Ongeldige adressen",
    channelExcluded: "Geen kanaaltoegang",
    recipients: "Definitieve ontvangers",
  };
  return (
    <div className="editorial-counts">
      {Object.entries(labels).map(([key, label]) => (
        <div key={key}>
          <strong>{counts[key as keyof Counts] ?? 0}</strong>
          <small>{label}</small>
        </div>
      ))}
    </div>
  );
}
function Empty({
  title,
  children,
  action,
}: {
  title: string;
  children: React.ReactNode;
  action?: React.ReactNode;
}) {
  return (
    <div className="editorial-empty">
      <BookOpen size={30} style={{ margin: "auto", color: "#e7b983" }} />
      <h2>{title}</h2>
      <p>{children}</p>
      {action}
    </div>
  );
}
function CtaFields({
  value,
  onChange,
}: {
  value: ArticleContent["cta"];
  onChange: (value: ArticleContent["cta"]) => void;
}) {
  return (
    <>
      <label className="editorial-check">
        <input
          type="checkbox"
          checked={!!value}
          onChange={(e) =>
            onChange(
              e.target.checked ? { label: "Lees meer", url: "/nieuws" } : null,
            )
          }
        />
        <span>Primaire knop tonen</span>
      </label>
      {value && (
        <>
          <label>
            Knoptekst
            <input
              maxLength={60}
              value={value.label}
              onChange={(e) => onChange({ ...value, label: e.target.value })}
            />
          </label>
          <label>
            Link
            <input
              value={value.url}
              onChange={(e) => onChange({ ...value, url: e.target.value })}
              placeholder="/nieuws of https://…"
            />
          </label>
        </>
      )}
    </>
  );
}
function ArticleFields({
  content,
  update,
  snapshot,
  disabled,
  upload,
  editorKey,
}: {
  content: ArticleContent;
  update: (value: ArticleContent) => void;
  snapshot: Snapshot;
  disabled: boolean;
  upload: () => void;
  editorKey: string;
}) {
  return (
    <>
      <fieldset disabled={disabled}>
        <label>
          Titel
          <input
            className="editorial-title-input"
            maxLength={160}
            value={content.title}
            onChange={(e) => update({ ...content, title: e.target.value })}
          />
        </label>
        <label>
          Korte intro · {content.intro.length}/220
          <textarea
            rows={3}
            maxLength={220}
            value={content.intro}
            onChange={(e) => update({ ...content, intro: e.target.value })}
          />
        </label>
        <div className="editorial-fields-row">
          <label>
            Auteur/vertoningsnaam
            <input
              value={content.author}
              maxLength={100}
              onChange={(e) => update({ ...content, author: e.target.value })}
            />
          </label>
          <label>
            Categorie
            <select
              value={content.categoryId ?? ""}
              onChange={(e) =>
                update({ ...content, categoryId: e.target.value || null })
              }
            >
              <option value="">Geen categorie</option>
              {snapshot.categories
                .filter((c) => c.active || c.id === content.categoryId)
                .map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
            </select>
          </label>
        </div>
        <div className="editorial-hero-choice">
          {content.heroId && (
            <MediaImage id={content.heroId} alt={content.heroAlt} />
          )}
          <label>
            Hoofdafbeelding
            <select
              aria-label="Hoofdafbeelding"
              value={content.heroId ?? ""}
              onChange={(e) => {
                const media = snapshot.media.find(
                  (m) => m.id === e.target.value,
                );
                update({
                  ...content,
                  heroId: media?.id ?? null,
                  heroAlt: media?.alt ?? "",
                  heroCaption: media?.caption ?? "",
                });
              }}
            >
              <option value="">Kies uit de mediatheek</option>
              {snapshot.media.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.alt}
                </option>
              ))}
            </select>
          </label>
          <button type="button" className="btn outline" onClick={upload}>
            <ImagePlus size={16} />
            Nieuwe afbeelding uploaden
          </button>
          {content.heroId && (
            <>
              <label>
                Alt-tekst
                <input
                  maxLength={300}
                  value={content.heroAlt}
                  onChange={(e) =>
                    update({ ...content, heroAlt: e.target.value })
                  }
                />
              </label>
              <label>
                Bijschrift
                <input
                  maxLength={500}
                  value={content.heroCaption}
                  onChange={(e) =>
                    update({ ...content, heroCaption: e.target.value })
                  }
                />
              </label>
            </>
          )}
        </div>
      </fieldset>
      <label>Berichtinhoud</label>
      <RichEditor
        key={editorKey}
        value={content.body}
        onChange={(body) => update({ ...content, body })}
        media={snapshot.media}
        disabled={disabled}
      />
      <fieldset disabled={disabled}>
        <CtaFields
          value={content.cta}
          onChange={(cta) => update({ ...content, cta })}
        />
      </fieldset>
    </>
  );
}
function NewsPreview({
  content,
  slug,
  snapshot,
  close,
}: {
  content: ArticleContent;
  slug: string;
  snapshot: Snapshot;
  close: () => void;
}) {
  const [view, setView] = useState("desktop");
  const item: NewsItem = {
    id: "preview",
    slug,
    versionId: "preview",
    version: 1,
    content,
    category:
      snapshot.categories.find((c) => c.id === content.categoryId)?.name ??
      null,
    publishedAt: new Date().toISOString(),
    featured: false,
    read: false,
    cta: content.cta,
    channel:
      view === "parents" ? "parents" : view === "houses" ? "houses" : "website",
  };
  return (
    <Dialog open onOpenChange={(open) => !open && close()}>
      <DialogContent className="editorial-dialog">
        <DialogTitle>Voorbeeld van je nieuwsbericht</DialogTitle>
        <DialogDescription>
          Zo verschijnt deze versie op de gekozen plek. Dit voorbeeld publiceert
          niets.
        </DialogDescription>
        <div
          className="editorial-tabs"
          role="tablist"
          aria-label="Voorbeeldweergave"
        >
          {[
            ["desktop", "Website desktop"],
            ["mobile", "Website mobiel"],
            ["parents", "Ouderportaal"],
            ["houses", "Huizenportaal"],
            ["email", "E-mailkaart"],
            ["push", "Push"],
          ].map(([id, label]) => (
            <button
              key={id}
              role="tab"
              tabIndex={view === id ? 0 : -1}
              onKeyDown={(event) => {
                if (
                  !["ArrowLeft", "ArrowRight", "Home", "End"].includes(
                    event.key,
                  )
                )
                  return;
                event.preventDefault();
                const tabs = Array.from(
                  event.currentTarget.parentElement!.querySelectorAll<HTMLButtonElement>(
                    'button[role="tab"]:not(:disabled)',
                  ),
                );
                const index = tabs.indexOf(event.currentTarget);
                const next =
                  event.key === "Home"
                    ? 0
                    : event.key === "End"
                      ? tabs.length - 1
                      : (index +
                          (event.key === "ArrowRight" ? 1 : -1) +
                          tabs.length) %
                        tabs.length;
                tabs[next].focus();
                tabs[next].click();
              }}
              aria-selected={view === id}
              onClick={() => setView(id)}
            >
              {label}
            </button>
          ))}
        </div>
        <div
          className={`editorial-preview ${["mobile", "parents", "houses"].includes(view) ? "mobile" : ""}`}
        >
          {view === "push" ? (
            <div className="editorial-push-preview">
              <Bell />
              <div>
                <strong>De Duindorpse Poorten</strong>
                <p>Er staat een nieuw bericht voor je klaar.</p>
                <small>Opent dit nieuwsbericht in je eigen omgeving</small>
              </div>
            </div>
          ) : view === "email" ? (
            <div className="editorial-email-card">
              {content.heroId && (
                <MediaImage
                  id={content.heroId}
                  alt={content.heroAlt}
                  variant="email"
                />
              )}
              <h2>{content.title}</h2>
              <p>{content.intro}</p>
              <span className="editorial-text-link">
                Lees het nieuwsbericht →
              </span>
            </div>
          ) : ["parents", "houses"].includes(view) ? (
            <>
              <p className="kicker">
                {view === "parents"
                  ? "Nieuws voor jouw groep"
                  : "Nieuws voor jullie poort"}
              </p>
              <NewsCard item={item} base="/omgeving/nieuws" />
              <NewsArticle item={item} />
            </>
          ) : (
            <NewsArticle item={item} />
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
type ChannelDraft = {
  enabled: boolean;
  listed: boolean;
  featured: boolean;
  starts: string;
  ends: string;
  push: "none" | "publish" | "later";
  pushTime: string;
  cta: ArticleContent["cta"];
};
function NewsComposer({
  initial,
  snapshot,
  rights,
  reload,
  dirty,
  close,
  upload,
}: {
  initial: News | null;
  snapshot: Snapshot;
  rights: Rights;
  reload: () => Promise<void>;
  dirty: (value: boolean) => void;
  close: () => void;
  upload: () => void;
}) {
  const [content, setContent] = useState<ArticleContent>(
    initial?.content ?? structuredClone(blankArticle),
  );
  const [slug, setSlug] = useState(initial?.slug ?? "");
  const [slugEdited, setSlugEdited] = useState(!!initial);
  const [saved, setSaved] = useState({
    id: initial?.id ?? null,
    revision: initial?.revision ?? 0,
    versionId: initial?.versionId ?? "",
  });
  const [changed, setChanged] = useState(!initial);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [preview, setPreview] = useState(false);
  const [confirm, setConfirm] = useState<Placement[] | null>(null);
  const [pushCounts, setPushCounts] = useState<{
    users: number;
    devices: number;
    withoutConsent: number;
  } | null>(null);
  const [planning, setPlanning] = useState<Record<NewsChannel, ChannelDraft>>(
    () =>
      Object.fromEntries(
        channels.map((c) => {
          const p = initial?.placements.find((p) => p.channel === c);
          if (initial?.planning?.[c]) return [c, initial.planning[c]];
          return [
            c,
            {
              enabled: !!p || c === "website",
              listed: p?.listed ?? true,
              featured: p?.featured ?? false,
              starts: "",
              ends: p?.endsAt ? amsterdamInput(p.endsAt) : "",
              push: "none",
              pushTime: "",
              cta: p?.cta ?? null,
            },
          ];
        }),
      ) as Record<NewsChannel, ChannelDraft>,
  );
  function update(value: ArticleContent) {
    setContent(value);
    if (!slugEdited) setSlug(slugify(value.title));
    setChanged(true);
    dirty(true);
  }
  function plan(channel: NewsChannel, patch: Partial<ChannelDraft>) {
    setChanged(true);
    dirty(true);
    setPlanning((old) => ({
      ...old,
      [channel]: { ...old[channel], ...patch },
    }));
  }
  async function save() {
    setBusy(true);
    setMessage("");
    try {
      const valid = articleSchema.parse(content);
      const result = await command<{
        id: string;
        revision: number;
        versionId: string;
      }>({ action: "saveNews", ...saved, slug, content: valid, planning });
      setSaved(result);
      setChanged(false);
      dirty(false);
      setMessage("Concept opgeslagen. Je live bericht blijft ongewijzigd.");
      await reload();
      return result;
    } catch (cause) {
      setMessage(errorMessage(cause));
      return null;
    } finally {
      setBusy(false);
    }
  }
  async function reviewPublication() {
    setMessage("");
    setBusy(true);
    try {
      let version = saved;
      if (changed && rights.write) {
        const result = await save();
        if (!result) return;
        version = result;
      }
      if (changed && !rights.write && initial?.status !== "draft")
        throw new Error(
          "Laat eerst een nieuw concept maken voor deze wijziging.",
        );
      if (!version.versionId || !content.heroId)
        throw new Error(
          "Sla het concept op en kies een hoofdafbeelding met alt-tekst.",
        );
      const placements = channels
        .filter((c) => planning[c].enabled)
        .map((c) => {
          const p = planning[c];
          const startsAt = p.starts
            ? amsterdamToUtc(p.starts)
            : new Date().toISOString();
          const endsAt = p.ends ? amsterdamToUtc(p.ends) : null;
          const pushAt =
            p.push === "publish"
              ? startsAt
              : p.push === "later"
                ? amsterdamToUtc(p.pushTime)
                : null;
          if (endsAt && endsAt <= startsAt)
            throw new Error("De eindtijd moet na de publicatie liggen.");
          if (pushAt && (pushAt < startsAt || (endsAt && pushAt >= endsAt)))
            throw new Error("Plan push tijdens de publicatieperiode.");
          return {
            channel: c,
            listed: p.listed,
            featured: p.featured,
            startsAt,
            endsAt,
            pushAt,
            cta: p.cta,
          };
        });
      if (!placements.length)
        throw new Error("Kies minimaal één publicatieplek.");
      const pushChannels = placements
        .filter((p) => p.pushAt)
        .map((p) => p.channel);
      setPushCounts(
        pushChannels.length
          ? await command({ action: "pushPreview", channels: pushChannels })
          : null,
      );
      setConfirm(placements);
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }
  async function publish() {
    if (!confirm || busy) return;
    setBusy(true);
    try {
      await command({
        action: "publishNews",
        versionId: saved.versionId,
        placements: confirm,
      });
      setConfirm(null);
      setMessage(
        "Publicatie vastgelegd. Ingeplande kanalen worden op het gekozen moment geopend.",
      );
      dirty(false);
      await reload();
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <div className="editorial-toolbar">
        <button className="btn outline" onClick={close}>
          ← Nieuwsoverzicht
        </button>
        <span className="editorial-badge">
          {saved.revision ? `Versie ${saved.revision}` : "Nieuw concept"}
          {changed ? " · niet opgeslagen" : ""}
        </span>
      </div>
      {message && (
        <p role="status" className="editorial-notice">
          {message}
        </p>
      )}
      <div className="editorial-compose">
        <div className="editorial-compose-main">
          <ArticleFields
            content={content}
            update={update}
            snapshot={snapshot}
            disabled={!rights.write || busy}
            upload={upload}
            editorKey={initial?.versionId ?? "new"}
          />
          <label>
            Link van het bericht
            <input
              disabled={!rights.write || !!initial?.placements.length}
              value={slug}
              onChange={(e) => {
                setSlug(e.target.value);
                setSlugEdited(true);
                setChanged(true);
                dirty(true);
              }}
            />
          </label>
          <p className="editorial-small">
            /nieuws/{slug || "jouw-bericht"} · Een gepubliceerde link blijft
            behouden.
          </p>
        </div>
        <aside className="editorial-compose-side">
          <h3>Publicatieplekken</h3>
          <p className="editorial-small">
            Eén verhaal, gericht gepubliceerd. Alle tijden zijn in Amsterdam.
          </p>
          {channels.map((c) => {
            const p = planning[c];
            return (
              <section className="editorial-planning" key={c}>
                <label className="editorial-check">
                  <input
                    type="checkbox"
                    checked={p.enabled}
                    disabled={!rights.write && !rights.publish}
                    onChange={(e) => plan(c, { enabled: e.target.checked })}
                  />
                  <strong>{channelLabels[c]}</strong>
                </label>
                {p.enabled && (
                  <fieldset
                    disabled={(!rights.write && !rights.publish) || busy}
                  >
                    <label className="editorial-check">
                      <input
                        type="checkbox"
                        checked={p.listed}
                        onChange={(e) => plan(c, { listed: e.target.checked })}
                      />
                      <span>In het nieuwsoverzicht</span>
                    </label>
                    <label className="editorial-check">
                      <input
                        type="checkbox"
                        checked={p.featured}
                        onChange={(e) =>
                          plan(c, { featured: e.target.checked })
                        }
                      />
                      <span>Uitlichten op dashboard/home</span>
                    </label>
                    <label>
                      Publiceren op · leeg is direct
                      <input
                        type="datetime-local"
                        value={p.starts}
                        onChange={(e) => plan(c, { starts: e.target.value })}
                      />
                    </label>
                    <label>
                      Einddatum · optioneel
                      <input
                        type="datetime-local"
                        value={p.ends}
                        onChange={(e) => plan(c, { ends: e.target.value })}
                      />
                    </label>
                    <CtaFields
                      value={p.cta}
                      onChange={(cta) => plan(c, { cta })}
                    />
                    {c !== "website" && (
                      <>
                        <label>
                          Pushnotificatie
                          <select
                            disabled={!rights.send}
                            value={p.push}
                            onChange={(e) =>
                              plan(c, {
                                push: e.target.value as ChannelDraft["push"],
                              })
                            }
                          >
                            <option value="none">Geen push</option>
                            <option value="publish">Op publicatiemoment</option>
                            <option value="later">Later inplannen</option>
                          </select>
                        </label>
                        {p.push === "later" && (
                          <label>
                            Push versturen op
                            <input
                              type="datetime-local"
                              value={p.pushTime}
                              onChange={(e) =>
                                plan(c, { pushTime: e.target.value })
                              }
                            />
                          </label>
                        )}
                      </>
                    )}
                  </fieldset>
                )}
              </section>
            );
          })}
          {!snapshot.sending.push && (
            <p className="editorial-small">
              Pushverzending staat uit. Nieuws kan wel worden gepubliceerd.
            </p>
          )}
        </aside>
      </div>
      <div className="editorial-footer">
        <span className="editorial-small">
          {changed
            ? "Je hebt niet-opgeslagen wijzigingen"
            : "Concept is opgeslagen"}
        </span>
        <div className="editorial-actions">
          <button
            className="btn outline"
            disabled={busy || !rights.write}
            onClick={() => void save()}
          >
            <Save size={16} />
            Opslaan
          </button>
          <button
            className="btn outline"
            disabled={!content.title}
            onClick={() => setPreview(true)}
          >
            <Eye size={16} />
            Voorbeeld
          </button>
          <button
            className="btn"
            disabled={busy || !rights.publish}
            onClick={() => void reviewPublication()}
          >
            <CalendarClock size={16} />
            Publicatie controleren
          </button>
        </div>
      </div>
      {preview && (
        <NewsPreview
          content={content}
          slug={slug}
          snapshot={snapshot}
          close={() => setPreview(false)}
        />
      )}
      <Dialog
        open={!!confirm}
        onOpenChange={(open) => !open && !busy && setConfirm(null)}
      >
        <DialogContent className="editorial-dialog">
          <DialogTitle>Publicatie bevestigen</DialogTitle>
          <DialogDescription>
            Deze versie wordt vastgelegd. Een wijziging daarna krijgt een nieuw
            concept.
          </DialogDescription>
          <h3>{content.title}</h3>
          {confirm?.map((p) => (
            <p key={p.channel}>
              <strong>{channelLabels[p.channel]}</strong> · {format(p.startsAt)}
              {p.endsAt && ` tot ${format(p.endsAt)}`}
              {p.pushAt && ` · push ${format(p.pushAt)}`}
            </p>
          ))}
          {pushCounts && (
            <>
              <div className="editorial-push-preview">
                <Bell />
                <div>
                  <strong>De Duindorpse Poorten</strong>
                  <p>Er staat een nieuw bericht voor je klaar.</p>
                </div>
              </div>
              <p>
                {pushCounts.users} gebruikers · {pushCounts.devices} actieve
                apparaten · {pushCounts.withoutConsent} zonder nieuwstoestemming
                uitgesloten.
              </p>
              <p className="editorial-small">
                Staging verwerkt uitsluitend apparaten op de expliciete
                testlijst.
              </p>
            </>
          )}
          <div className="editorial-actions">
            <button
              className="btn outline"
              disabled={busy}
              onClick={() => setConfirm(null)}
            >
              Annuleren
            </button>
            <button
              className="btn"
              disabled={busy}
              onClick={() => void publish()}
            >
              <Check size={16} />
              Bevestigen en publiceren
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
function AudienceFields({
  value,
  update,
  snapshot,
  disabled,
}: {
  value: Audience;
  update: (v: Audience) => void;
  snapshot: Snapshot;
  disabled: boolean;
}) {
  const boolFilter = (
    key:
      | "paid"
      | "assigned"
      | "portalComplete"
      | "portalApproved"
      | "portalActive",
    label: string,
  ) => (
    <label key={key}>
      {label}
      <select
        value={value[key] === undefined ? "all" : String(value[key])}
        onChange={(e) => {
          const next = { ...value };
          if (e.target.value === "all") delete next[key];
          else next[key] = e.target.value === "true";
          update(next);
        }}
      >
        <option value="all">Geen extra voorwaarde</option>
        <option value="true">Ja</option>
        <option value="false">Nee</option>
      </select>
    </label>
  );
  return (
    <fieldset disabled={disabled}>
      <h3>Voor wie is deze Nachtpost?</h3>
      <p className="editorial-small">
        Doelgroepen werken als <strong>OF</strong>. Extra voorwaarden gelden als{" "}
        <strong>EN</strong> voor de hele selectie. Alleen volwassenen met
        expliciete nieuwsbrief­toestemming worden opgenomen.
      </p>
      {Object.entries(audienceLabels).map(([key, label]) => (
        <label className="editorial-check" key={key}>
          <input
            type="checkbox"
            checked={value.roles.includes(key as keyof typeof audienceLabels)}
            onChange={(e) =>
              update({
                ...value,
                roles: e.target.checked
                  ? [...value.roles, key as keyof typeof audienceLabels]
                  : value.roles.filter((r) => r !== key),
              })
            }
          />
          <span>{label}</span>
        </label>
      ))}
      <details>
        <summary>Extra voorwaarden</summary>
        <label>
          Inschrijvingsstatus
          <select
            value={value.registrationStatus ?? ""}
            onChange={(e) => {
              const next = { ...value };
              if (!e.target.value) delete next.registrationStatus;
              else
                next.registrationStatus = e.target
                  .value as Audience["registrationStatus"];
              update(next);
            }}
          >
            <option value="">Alle statussen</option>
            <option value="submitted">Ingeschreven</option>
            <option value="draft">Conceptinschrijving</option>
            <option value="cancelled">Geannuleerd</option>
          </select>
        </label>
        {boolFilter("paid", "Betaald")}
        {boolFilter("assigned", "Groep toegewezen")}
        <label>
          Startpunt / tijdslot
          <select
            value={value.startSlotId ?? ""}
            onChange={(e) => {
              const next = { ...value };
              if (e.target.value) next.startSlotId = e.target.value;
              else delete next.startSlotId;
              update(next);
            }}
          >
            <option value="">Alle startpunten</option>
            {snapshot.slots.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} · {format(s.startsAt)}
              </option>
            ))}
          </select>
        </label>
        {(["startsAfter", "startsBefore"] as const).map((key) => (
          <label key={key}>
            {key === "startsAfter" ? "Starttijd vanaf" : "Starttijd tot"}
            <input
              type="datetime-local"
              value={value[key] ? amsterdamInput(value[key]!) : ""}
              onChange={(e) => {
                const next = { ...value };
                try {
                  if (e.target.value)
                    next[key] = amsterdamToUtc(e.target.value);
                  else delete next[key];
                  e.currentTarget.setCustomValidity("");
                  update(next);
                } catch {
                  e.currentTarget.setCustomValidity(
                    "Kies een eenduidige datum en tijd.",
                  );
                  e.currentTarget.reportValidity();
                }
              }}
            />
          </label>
        ))}
        {boolFilter("portalComplete", "Huisgegevens ingediend")}
        {boolFilter("portalApproved", "Huis goedgekeurd")}
        {boolFilter("portalActive", "Poort actief")}
        <label>
          Wereld
          <select
            value={value.worldId ?? ""}
            onChange={(e) => {
              const next = { ...value };
              if (e.target.value) next.worldId = e.target.value;
              else delete next.worldId;
              update(next);
            }}
          >
            <option value="">Alle werelden</option>
            {snapshot.worlds.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </select>
        </label>
      </details>
    </fieldset>
  );
}
function CampaignComposer({
  initial,
  fromNews,
  snapshot,
  rights,
  reload,
  dirty,
  close,
  upload,
}: {
  initial: Campaign | null;
  fromNews: string[];
  snapshot: Snapshot;
  rights: Rights;
  reload: () => Promise<void>;
  dirty: (value: boolean) => void;
  close: () => void;
  upload: () => void;
}) {
  const initialContent = initial?.content;
  const [content, setContent] = useState<CampaignContent>(() =>
    initialContent
      ? {
          internalName: initialContent.internalName,
          subject: initialContent.subject,
          preheader: initialContent.preheader,
          eyebrow: initialContent.eyebrow,
          article: initialContent.article,
          newsVersionIds: initialContent.newsVersionIds,
          closing: initialContent.closing,
          senderName: initialContent.senderName,
        }
      : {
          internalName: "",
          subject: "",
          preheader: "Nieuws uit de wijk, voor de nacht.",
          eyebrow: "NACHTPOST · HALLOWEEN 2026",
          article: { ...structuredClone(blankArticle), body: emptyDocument },
          newsVersionIds: fromNews,
          closing: "Tot tussen de poorten,\nTeam Duindorpse Poorten",
          senderName: "De Duindorpse Poorten van Halloween",
        },
  );
  const [audience, setAudience] = useState<Audience>(
    initial?.audience ?? { roles: ["parents"] },
  );
  const [saved, setSaved] = useState({
    id: initial?.id ?? null,
    revision: initial?.revision ?? 0,
    versionId: initial?.versionId ?? "",
  });
  const [changed, setChanged] = useState(!initial);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [counts, setCounts] = useState<Counts | null>(initial?.counts ?? null);
  const [html, setHtml] = useState("");
  const [preview, setPreview] = useState(false);
  const [mobile, setMobile] = useState(false);
  const [schedule, setSchedule] = useState("");
  const [confirm, setConfirm] = useState(false);
  const current = snapshot.campaigns.find((c) => c.id === saved.id);
  const frozen = !!current && !["draft", "ready"].includes(current.status);
  const editable = rights.compose && !frozen;
  const testKey = useRef(crypto.randomUUID());
  const stale = !!current && current.versionId !== saved.versionId;
  const testAccepted = !stale && !!current?.testAccepted;
  const testPending = ["pending", "processing", "deferred"].includes(
    current?.testStatus ?? "",
  );
  const testMessage = changed
    ? "Sla je wijzigingen op voordat je de testmail en verzending controleert."
    : stale
      ? "Dit concept is elders gewijzigd. Open het opnieuw vanuit het Nachtpostoverzicht."
      : frozen
        ? "Deze Nachtpost is vastgelegd."
        : testAccepted
          ? current?.testStatus === "delivered"
            ? "✓ Testmail afgeleverd. Je kunt de verzending controleren."
            : "✓ Testmail verstuurd. Je kunt de verzending controleren."
          : testPending
            ? "Je testmail wordt verstuurd. De status verschijnt hier automatisch."
            : current?.testStatus === "failed" || current?.testStatus === "suppressed"
              ? "De testmail kon niet worden verstuurd. Controleer de verzendhistorie en probeer het opnieuw."
              : current?.testStatus === "unknown"
                ? "De verzendstatus is nog niet bevestigd. Vernieuw de status of bekijk de verzendhistorie."
                : "Stuur eerst een testmail. Daarna kun je de verzending controleren.";
  function update(value: CampaignContent) {
    setContent(value);
    setChanged(true);
    dirty(true);
    setCounts(null);
  }
  function changeAudience(value: Audience) {
    setAudience(value);
    setChanged(true);
    dirty(true);
    setCounts(null);
  }
  async function saveDraft() {
    const valid = campaignSchema.parse(content);
    const result = await command<{
      id: string;
      revision: number;
      versionId: string;
    }>({
      action: "saveCampaign",
      ...saved,
      content: valid,
      audience,
      ready: true,
    });
    setSaved(result);
    setChanged(false);
    dirty(false);
    testKey.current = crypto.randomUUID();
    setMessage("Nachtpost opgeslagen en klaar voor controle.");
    await reload();
    return result;
  }
  async function save() {
    if (busy) return;
    setBusy(true);
    setMessage("");
    try {
      await saveDraft();
    } catch (cause) {
      setMessage(errorMessage(cause));
      return null;
    } finally {
      setBusy(false);
    }
  }
  async function review(mode: "preview" | "recipients" | "send") {
    if (busy) return;
    setBusy(true);
    setMessage("");
    try {
      let version = saved;
      if (changed) {
        version = await saveDraft();
      }
      const data = await command<Counts & { html: string }>({
        action: "previewCampaign",
        versionId: version.versionId,
      });
      setCounts(data);
      setHtml(data.html);
      if (mode === "preview") setPreview(true);
      if (mode === "send") setConfirm(true);
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }
  async function testMail() {
    if (busy) return;
    setBusy(true);
    setMessage("");
    try {
      if (changed || !saved.versionId)
        throw new Error(
          "Sla eerst de actuele versie op en bekijk het voorbeeld.",
        );
      await command({
        action: "testCampaign",
        versionId: saved.versionId,
        key: testKey.current,
      });
      testKey.current = crypto.randomUUID();
      setMessage(
        "Testmail aangevraagd voor je eigen beheeradres. Hieronder zie je de actuele verzendstatus.",
      );
      await reload();
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }
  async function send() {
    if (!counts || busy) return;
    setBusy(true);
    try {
      const at = schedule ? amsterdamToUtc(schedule) : new Date().toISOString();
      await command({
        action: "scheduleCampaign",
        versionId: saved.versionId,
        at,
        count: counts.recipients,
      });
      setConfirm(false);
      dirty(false);
      setMessage(
        "Nachtpost ingepland. Inhoud en ontvangers zijn nu vastgelegd.",
      );
      await reload();
    } catch (cause) {
      setMessage(errorMessage(cause));
      setConfirm(false);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <div className="editorial-toolbar">
        <button className="btn outline" onClick={close}>
          ← Nachtpostoverzicht
        </button>
        <span className="editorial-badge">
          {stateLabels[current?.status ?? "draft"]} · versie{" "}
          {saved.revision || 1}
        </span>
      </div>
      <div className="editorial-notice">
        <strong>Nachtpost is redactioneel en afmeldbaar.</strong> Gebruik
        Gerichte updates voor cruciale deelname- of veiligheidsinformatie.
        Kindaccounts komen nooit in deze selectie.
      </div>
      {message && (
        <p role="status" className="editorial-notice">
          {message}
        </p>
      )}
      {frozen && (
        <p className="editorial-notice">
          Deze campagne is vastgelegd. Maak een kopie vanuit het overzicht voor
          wijzigingen.
        </p>
      )}
      <div className="editorial-compose">
        <div className="editorial-compose-main">
          <fieldset disabled={!editable || busy}>
            <label>
              Interne campagnenaam
              <input
                value={content.internalName}
                maxLength={120}
                onChange={(e) =>
                  update({ ...content, internalName: e.target.value })
                }
              />
            </label>
            <label>
              Onderwerpregel
              <input
                value={content.subject}
                maxLength={200}
                onChange={(e) =>
                  update({ ...content, subject: e.target.value })
                }
              />
            </label>
            <label>
              Preheader
              <input
                value={content.preheader}
                maxLength={180}
                onChange={(e) =>
                  update({ ...content, preheader: e.target.value })
                }
              />
            </label>
            <div className="editorial-fields-row">
              <label>
                Eyebrow
                <input
                  value={content.eyebrow}
                  maxLength={100}
                  onChange={(e) =>
                    update({ ...content, eyebrow: e.target.value })
                  }
                />
              </label>
              <label>
                Afzendernaam
                <input
                  value={content.senderName}
                  maxLength={120}
                  onChange={(e) =>
                    update({ ...content, senderName: e.target.value })
                  }
                />
              </label>
            </div>
          </fieldset>
          <ArticleFields
            content={content.article}
            update={(article) => update({ ...content, article })}
            snapshot={snapshot}
            disabled={!editable || busy}
            upload={upload}
            editorKey={initial?.versionId ?? "campaign-new"}
          />
          <fieldset disabled={!editable || busy}>
            <h3 className="editorial-subheading">Nieuwskaarten toevoegen</h3>
            <p className="editorial-small">
              Gepubliceerde versies worden bij inplannen vastgelegd. Latere
              nieuwsaanpassingen veranderen deze campagne niet.
            </p>
            {snapshot.news
              .filter((n) => n.placements.some((p) => p.state === "live"))
              .map((n) => {
                const id = n.placements.find(
                  (p) => p.state === "live",
                )!.versionId;
                return (
                  <label key={n.id} className="editorial-check">
                    <input
                      type="checkbox"
                      checked={content.newsVersionIds.includes(id)}
                      onChange={(e) =>
                        update({
                          ...content,
                          newsVersionIds: e.target.checked
                            ? [...content.newsVersionIds, id]
                            : content.newsVersionIds.filter((v) => v !== id),
                        })
                      }
                    />
                    <span>{n.content.title}</span>
                  </label>
                );
              })}
            <label>
              Afsluiting
              <textarea
                rows={3}
                value={content.closing}
                maxLength={2000}
                onChange={(e) =>
                  update({ ...content, closing: e.target.value })
                }
              />
            </label>
          </fieldset>
        </div>
        <aside className="editorial-compose-side">
          <AudienceFields
            value={audience}
            update={changeAudience}
            snapshot={snapshot}
            disabled={!editable || busy}
          />
          <button
            className="btn outline"
            disabled={busy || (!rights.compose && !rights.send)}
            onClick={() => void review("recipients")}
          >
            Ontvangers controleren
          </button>
          {counts && <CountPreview counts={counts} />}
          <label>
            Verzenden op · leeg is direct
            <input
              type="datetime-local"
              value={schedule}
              disabled={frozen || !rights.send}
              onChange={(e) => setSchedule(e.target.value)}
            />
          </label>
          <p className="editorial-small">
            Tijdzone: Europe/Amsterdam. Op staging worden uitsluitend expliciete
            testadressen verwerkt.
          </p>
          {!snapshot.sending.email && (
            <p className="editorial-notice">Nieuwsbriefverzending staat uit.</p>
          )}
        </aside>
      </div>
      <div className="editorial-footer" aria-label="Nachtpostacties">
        <p className="editorial-small" role="status">{testMessage}</p>
        <div className="editorial-actions">
          <button
            className="btn outline"
            disabled={busy || !editable || !changed || stale}
            onClick={() => void save()}
          >
            <Save size={16} />
            Opslaan
          </button>
          <button
            className="btn outline"
            disabled={busy || !content.subject}
            onClick={() => void review("preview")}
          >
            <Eye size={16} />
            Voorbeeld
          </button>
          <button
            className="btn outline"
            disabled={
              busy ||
              !rights.send ||
              frozen ||
              stale ||
              testPending ||
              changed ||
              !saved.versionId ||
              !snapshot.sending.email
            }
            onClick={() => void testMail()}
          >
            <Mail size={16} />
            Testmail naar mij
          </button>
          <button
            className="btn outline"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              void reload()
                .catch((cause) => setMessage(errorMessage(cause)))
                .finally(() => setBusy(false));
            }}
          >
            Status vernieuwen
          </button>
          <button
            className="btn editorial-send"
            disabled={
              busy ||
              !rights.send ||
              frozen ||
              changed ||
              !testAccepted ||
              !snapshot.sending.email
            }
            onClick={() => void review("send")}
          >
            <Send size={16} />
            Verzending controleren
          </button>
        </div>
      </div>
      <Dialog open={preview} onOpenChange={setPreview}>
        <DialogContent className="editorial-dialog">
          <DialogTitle>Nachtpostvoorbeeld</DialogTitle>
          <DialogDescription>
            Dezelfde premium renderer als voor de uiteindelijke e-mail.
          </DialogDescription>
          <div className="editorial-actions">
            <button
              className="btn outline"
              aria-pressed={!mobile}
              onClick={() => setMobile(false)}
            >
              Desktop
            </button>
            <button
              className="btn outline"
              aria-pressed={mobile}
              onClick={() => setMobile(true)}
            >
              Mobiel
            </button>
          </div>
          <div className={`editorial-preview${mobile ? " mobile" : ""}`}>
            <iframe
              title="Nachtpost e-mailvoorbeeld"
              sandbox="allow-same-origin"
              srcDoc={html}
            />
          </div>
        </DialogContent>
      </Dialog>
      <Dialog
        open={confirm}
        onOpenChange={(open) => !open && !busy && setConfirm(false)}
      >
        <DialogContent className="editorial-dialog">
          <DialogTitle>Definitief verzenden bevestigen</DialogTitle>
          <DialogDescription>
            Je staat op het punt “{content.internalName}” naar{" "}
            {counts?.recipients ?? 0} unieke ontvangers te sturen. De inhoud en
            ontvangers kunnen daarna niet meer worden aangepast.
          </DialogDescription>
          {counts && <CountPreview counts={counts} />}
          <p>
            {schedule
              ? `Ingepland: ${schedule.replace("T", " ")} (Amsterdam)`
              : "Verzending begint bij de eerstvolgende verwerking."}
          </p>
          <p className="editorial-small">
            Staging: alleen de expliciete testlijst ontvangt mail, ook als de
            selectie hierboven groter is.
          </p>
          <div className="editorial-actions">
            <button
              className="btn outline"
              disabled={busy}
              onClick={() => setConfirm(false)}
            >
              Annuleren
            </button>
            <button className="btn" disabled={busy} onClick={() => void send()}>
              Bevestigen en inplannen
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
function MediaUpload({
  close,
  reload,
}: {
  close: () => void;
  reload: () => Promise<void>;
}) {
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState("");
  const [alt, setAlt] = useState("");
  const [caption, setCaption] = useState("");
  const [focal, setFocal] = useState([50, 50]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const objectUrl = useRef("");
  useEffect(
    () => () => {
      if (objectUrl.current) URL.revokeObjectURL(objectUrl.current);
    },
    [],
  );
  async function upload(e: React.FormEvent) {
    e.preventDefault();
    if (!file || !alt.trim() || busy) return;
    setBusy(true);
    try {
      const form = new FormData();
      form.set("file", file);
      form.set("alt", alt);
      form.set("caption", caption);
      form.set("focalX", String(focal[0]));
      form.set("focalY", String(focal[1]));
      const response = await fetch("/api/editorial/media", {
        method: "POST",
        body: form,
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error?.message);
      await reload();
      close();
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Dialog open onOpenChange={(open) => !open && !busy && close()}>
      <DialogContent className="editorial-dialog editorial-upload">
        <DialogTitle>Een beeld voor je verhaal</DialogTitle>
        <DialogDescription>
          JPG, PNG of WebP, maximaal 12 MB. Er worden automatisch uitsneden
          gemaakt voor website, portalen, e-mail en social.
        </DialogDescription>
        <form onSubmit={(e) => void upload(e)}>
          <label>
            Afbeelding
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp"
              required
              disabled={busy}
              onChange={(e) => {
                const next = e.target.files?.[0] ?? null;
                setFile(next);
                if (objectUrl.current) URL.revokeObjectURL(objectUrl.current);
                objectUrl.current = next ? URL.createObjectURL(next) : "";
                setPreview(objectUrl.current);
              }}
            />
          </label>
          {preview && (
            <>
              <div
                className="editorial-upload-preview"
                onClick={(e) => {
                  const bounds = e.currentTarget.getBoundingClientRect();
                  setFocal([
                    Math.round(
                      ((e.clientX - bounds.left) / bounds.width) * 100,
                    ),
                    Math.round(
                      ((e.clientY - bounds.top) / bounds.height) * 100,
                    ),
                  ]);
                }}
              >
                <img src={preview} alt="Gekozen upload" />
                <span style={{ left: `${focal[0]}%`, top: `${focal[1]}%` }} />
              </div>
              <p className="editorial-small">
                Klik op het belangrijkste deel, of gebruik de focuspuntvelden
                hieronder.
              </p>
            </>
          )}
          <div className="editorial-fields-row">
            <label>
              Focuspunt horizontaal (0–100)
              <input
                type="number"
                min={0}
                max={100}
                value={focal[0]}
                onChange={(e) => setFocal([Number(e.target.value), focal[1]])}
              />
            </label>
            <label>
              Focuspunt verticaal (0–100)
              <input
                type="number"
                min={0}
                max={100}
                value={focal[1]}
                onChange={(e) => setFocal([focal[0], Number(e.target.value)])}
              />
            </label>
          </div>
          <label>
            Alt-tekst · verplicht
            <input
              required
              maxLength={300}
              value={alt}
              onChange={(e) => setAlt(e.target.value)}
              placeholder="Beschrijf wat op de afbeelding te zien is"
            />
          </label>
          <label>
            Bijschrift
            <input
              maxLength={500}
              value={caption}
              onChange={(e) => setCaption(e.target.value)}
            />
          </label>
          {message && (
            <p className="editorial-notice error" role="alert">
              {message}
            </p>
          )}
          <div className="editorial-actions">
            <button
              type="button"
              className="btn outline"
              disabled={busy}
              onClick={close}
            >
              Annuleren
            </button>
            <button
              type="submit"
              className="btn"
              disabled={busy || !file || !alt.trim()}
            >
              {busy
                ? "Beeld en varianten opslaan…"
                : "Toevoegen aan mediatheek"}
            </button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
export function Redactiekamer({ capabilities }: { capabilities: string[] }) {
  const can = (cap: string) =>
    capabilities.includes("event_admin") || capabilities.includes(cap);
  const rights: Rights = {
    write: can("content_manage"),
    publish: can("content_publish"),
    compose: can("communications_manage"),
    send: can("communications_send"),
  };
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [tab, setTab] = useState("news");
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [news, setNews] = useState<News | null | undefined>(undefined);
  const [campaign, setCampaign] = useState<Campaign | null | undefined>(
    undefined,
  );
  const [selectedNews, setSelectedNews] = useState<string[]>([]);
  const [fromNews, setFromNews] = useState<string[]>([]);
  const [upload, setUpload] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [editorKey, setEditorKey] = useState(0);
  const [categoriesOpen, setCategoriesOpen] = useState(false);
  const [categoryName, setCategoryName] = useState("");
  const [working, setWorking] = useState(false);
  const [pending, setPending] = useState<{
    title: string;
    text: string;
    action: () => Promise<void>;
  } | null>(null);
  const loadSequence = useRef(0);
  const load = useCallback(async () => {
    const sequence = ++loadSequence.current;
    const response = await fetch("/api/editorial/admin", { cache: "no-store" });
    const body = await response.json();
    if (!response.ok)
      throw new Error(
        body.error?.message ?? "De Redactiekamer is niet bereikbaar.",
      );
    if (sequence === loadSequence.current) setSnapshot(body.data);
  }, []);
  useEffect(() => {
    const timer = setTimeout(
      () => void load().catch((cause) => setMessage(errorMessage(cause))),
      0,
    );
    const poll = setInterval(() => {
      if (document.visibilityState === "visible")
        void load().catch(() => undefined);
    }, 15000);
    const refreshVisible = () => {
      if (document.visibilityState === "visible")
        void load().catch(() => undefined);
    };
    window.addEventListener("focus", refreshVisible);
    document.addEventListener("visibilitychange", refreshVisible);
    return () => {
      clearTimeout(timer);
      clearInterval(poll);
      window.removeEventListener("focus", refreshVisible);
      document.removeEventListener("visibilitychange", refreshVisible);
    };
  }, [load]);
  useEffect(() => {
    if (!dirty) return;
    const guard = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    const navigation = (e: MouseEvent) => {
      const target =
        e.target instanceof Element
          ? e.target.closest(
              "a[href], .admin-nav button, .admin-bottomnav button",
            )
          : null;
      if (!target || target.closest(".redactiekamer")) return;
      if (
        !window.confirm(
          "Je hebt niet-opgeslagen wijzigingen. Wil je die verlaten?",
        )
      ) {
        e.preventDefault();
        e.stopPropagation();
      }
    };
    window.addEventListener("beforeunload", guard);
    document.addEventListener("click", navigation, true);
    return () => {
      window.removeEventListener("beforeunload", guard);
      document.removeEventListener("click", navigation, true);
    };
  }, [dirty]);
  const leave = (action: () => void) => {
    if (
      dirty &&
      !window.confirm(
        "Je hebt niet-opgeslagen wijzigingen. Wil je die verlaten?",
      )
    )
      return;
    setDirty(false);
    setMessage("");
    action();
  };
  const openNews = (n: News | null) =>
    leave(() => {
      setNews(n);
      setCampaign(undefined);
      setTab("news");
      setEditorKey((n) => n + 1);
    });
  const openCampaign = (c: Campaign | null, ids: string[] = []) =>
    leave(() => {
      setCampaign(c);
      setNews(undefined);
      setFromNews(ids);
      setTab("campaigns");
      setEditorKey((n) => n + 1);
    });
  async function act(action: () => Promise<void>) {
    if (working) return;
    setWorking(true);
    setMessage("");
    try {
      await action();
      await load();
      setPending(null);
    } catch (cause) {
      setMessage(errorMessage(cause));
    } finally {
      setWorking(false);
    }
  }
  async function duplicate(c: Campaign) {
    const copy = {
      ...c.content,
      internalName: `${c.content.internalName.slice(0, 106)} · kopie`,
    } as CampaignContent & { newsCards?: unknown };
    delete copy.newsCards;
    const saved = await command<{
      id: string;
      revision: number;
      versionId: string;
    }>({
      action: "saveCampaign",
      id: null,
      revision: 0,
      content: copy,
      audience: c.audience,
      ready: false,
    });
    await load();
    openCampaign({
      ...c,
      ...saved,
      content: copy,
      status: "draft",
      scheduledAt: null,
      counts: null,
      testAccepted: false,
      delivery: {},
      events: {},
    });
  }
  if (!snapshot)
    return (
      <section className="editorial-room">
        <p className="editorial-notice" role="status" aria-busy={!message}>
          {message || "De Redactiekamer wordt geopend…"}
        </p>
        {message && (
          <button
            className="btn"
            onClick={() =>
              void load().catch((cause) => setMessage(errorMessage(cause)))
            }
          >
            Opnieuw proberen
          </button>
        )}
      </section>
    );
  const items = snapshot.news.filter(
    (n) =>
      `${n.content.title} ${n.content.intro} ${n.slug}`
        .toLowerCase()
        .includes(search.toLowerCase()) &&
      (status === "all" ||
        (status === "draft"
          ? n.status === "draft"
          : n.placements.some((p) => p.state === status))),
  );
  const campaigns = snapshot.campaigns.filter((c) =>
    `${c.content.internalName} ${c.content.subject}`
      .toLowerCase()
      .includes(search.toLowerCase()),
  );
  const stats = [
    [
      "Conceptberichten",
      snapshot.news.filter((n) => n.status === "draft").length,
    ],
    [
      "Ingeplande berichten",
      snapshot.news.filter((n) =>
        n.placements.some((p) => p.state === "scheduled"),
      ).length,
    ],
    [
      "Live berichten",
      snapshot.news.filter((n) => n.placements.some((p) => p.state === "live"))
        .length,
    ],
    [
      "Geplande Nachtpost",
      snapshot.campaigns.filter((c) => c.status === "scheduled").length,
    ],
    ["Actieve pushapparaten", snapshot.activeSubscriptions],
    [
      "Actiepunten",
      snapshot.mailHistory.filter((m) =>
        ["failed", "unknown"].includes(m.status),
      ).length + snapshot.push.filter((p) => p.failedAt).length,
    ],
  ];
  return (
    <section className="editorial-room">
      <div className="editorial-cockpit">
        {stats.map(([label, value]) => (
          <div className="editorial-stat" key={label}>
            <small>{label}</small>
            <strong>{value}</strong>
          </div>
        ))}
      </div>
      <p className="editorial-small">
        Laatste mailresultaat:{" "}
        {snapshot.mailHistory[0]
          ? `${stateLabels[snapshot.mailHistory[0].status] ?? snapshot.mailHistory[0].status} · ${format(snapshot.mailHistory[0].createdAt)}`
          : "Nog geen verzending"}
      </p>
      <nav className="editorial-tabs" role="tablist" aria-label="Redactiekamer">
        {[
          ["news", "Nieuwsberichten", Newspaper],
          ["campaigns", "Nachtpost", Mail],
          ["media", "Mediatheek", ImagePlus],
          ["history", "Verzendhistorie", CalendarClock],
        ].map(([key, label, Icon]) => {
          const Glyph = Icon as typeof Mail;
          return (
            <button
              key={String(key)}
              role="tab"
              tabIndex={tab === key ? 0 : -1}
              onKeyDown={(event) => {
                if (
                  !["ArrowLeft", "ArrowRight", "Home", "End"].includes(
                    event.key,
                  )
                )
                  return;
                event.preventDefault();
                const tabs = Array.from(
                  event.currentTarget.parentElement!.querySelectorAll<HTMLButtonElement>(
                    'button[role="tab"]:not(:disabled)',
                  ),
                );
                const index = tabs.indexOf(event.currentTarget);
                const next =
                  event.key === "Home"
                    ? 0
                    : event.key === "End"
                      ? tabs.length - 1
                      : (index +
                          (event.key === "ArrowRight" ? 1 : -1) +
                          tabs.length) %
                        tabs.length;
                tabs[next].focus();
                tabs[next].click();
              }}
              aria-selected={tab === key}
              disabled={key === "campaigns" && !rights.compose && !rights.send}
              onClick={() =>
                leave(() => {
                  setTab(String(key));
                  setNews(undefined);
                  setCampaign(undefined);
                  setSearch("");
                })
              }
            >
              <Glyph size={17} />
              {String(label)}
            </button>
          );
        })}
      </nav>
      {message && (
        <p className="editorial-notice error" role="alert">
          {message}
        </p>
      )}
      {tab === "news" &&
        (news !== undefined ? (
          <NewsComposer
            key={editorKey}
            initial={news}
            snapshot={snapshot}
            rights={rights}
            reload={load}
            dirty={setDirty}
            close={() => leave(() => setNews(undefined))}
            upload={() => setUpload(true)}
          />
        ) : (
          <>
            <div className="editorial-toolbar">
              <input
                aria-label="Zoek nieuwsberichten"
                placeholder="Zoek een titel, verhaal of link…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
              <div className="editorial-actions">
                <select
                  aria-label="Filter nieuwsstatus"
                  style={{ width: "auto" }}
                  value={status}
                  onChange={(e) => setStatus(e.target.value)}
                >
                  <option value="all">Alle statussen</option>
                  <option value="draft">Concept</option>
                  <option value="scheduled">Ingepland</option>
                  <option value="live">Live</option>
                </select>
                {rights.write && (
                  <button
                    className="btn outline"
                    onClick={() => setCategoriesOpen(true)}
                  >
                    Categorieën
                  </button>
                )}
                {rights.write && (
                  <button className="btn" onClick={() => openNews(null)}>
                    <Plus size={17} />
                    Nieuw bericht
                  </button>
                )}
              </div>
            </div>
            {selectedNews.length > 0 && rights.compose && (
              <button
                className="btn"
                onClick={() => openCampaign(null, selectedNews)}
              >
                Voeg {selectedNews.length} berichten toe aan Nachtpost
              </button>
            )}
            {!items.length ? (
              <Empty
                title="Hier begint het volgende verhaal."
                action={
                  rights.write && (
                    <button className="btn" onClick={() => openNews(null)}>
                      Schrijf een nieuwsbericht
                    </button>
                  )
                }
              >
                Schrijf één verhaal en kies daarna waar het verschijnt: op de
                website, bij ouders of achter de poorten.
              </Empty>
            ) : (
              <div className="editorial-list">
                {items.map((n) => {
                  const live = n.placements.find((p) => p.state === "live");
                  return (
                    <article className="editorial-row" key={n.id}>
                      {n.content.heroId ? (
                        <MediaImage
                          id={n.content.heroId}
                          alt=""
                          variant="card"
                        />
                      ) : (
                        <BookOpen aria-hidden="true" />
                      )}
                      <div>
                        <div className="editorial-meta">
                          <span className="editorial-badge gold">
                            {stateLabels[n.status]}
                          </span>
                          {n.placements.map((p) => (
                            <span className="editorial-badge" key={p.channel}>
                              {channelLabels[p.channel]} ·{" "}
                              {stateLabels[p.state]}
                            </span>
                          ))}
                        </div>
                        <h3>{n.content.title}</h3>
                        <small>
                          Versie {n.revision} · bewerkt {format(n.updatedAt)}
                        </small>
                        {n.metrics.length > 0 && (
                          <p className="editorial-small">
                            {n.metrics
                              .map(
                                (m) =>
                                  `${channelLabels[m.channel as NewsChannel]}: ${m.views} weergaven · ${m.clicks} klikken${m.channel !== "website" ? ` · ${m.readers} gelezen in de laatste 30 dagen · ${Math.max(0, m.audience - m.readers)} ongelezen` : ""}${m.retainedPush?.devices ? ` · Pusharchief: ${m.retainedPush.sent}/${m.retainedPush.devices} naar pushservice · ${m.retainedPush.clicked} aangeklikt` : ""}`,
                              )
                              .join(" | ")}
                          </p>
                        )}
                        {live && rights.compose && (
                          <label className="editorial-check">
                            <input
                              type="checkbox"
                              checked={selectedNews.includes(live.versionId)}
                              onChange={(e) =>
                                setSelectedNews((ids) =>
                                  e.target.checked
                                    ? [...ids, live.versionId]
                                    : ids.filter((id) => id !== live.versionId),
                                )
                              }
                            />
                            <span>Selecteer voor Nachtpost</span>
                          </label>
                        )}
                      </div>
                      <div className="editorial-actions">
                        <button
                          className="btn outline"
                          onClick={() => openNews(n)}
                        >
                          {rights.write ? "Bewerken" : "Bekijken"}
                        </button>
                        {live && rights.compose && (
                          <button
                            className="btn outline"
                            onClick={() => openCampaign(null, [live.versionId])}
                          >
                            Voeg toe aan Nachtpost
                          </button>
                        )}
                        {n.placements.length > 0 && rights.publish && (
                          <button
                            className="editorial-text-link"
                            onClick={() =>
                              setPending({
                                title: "Nieuwsbericht archiveren",
                                text: "Dit bericht verdwijnt uit alle publicatiekanalen. De versies blijven bewaard.",
                                action: async () => {
                                  await command({
                                    action: "archiveNews",
                                    id: n.id,
                                  });
                                },
                              })
                            }
                          >
                            Archiveren
                          </button>
                        )}
                      </div>
                    </article>
                  );
                })}
              </div>
            )}
          </>
        ))}
      {tab === "campaigns" &&
        (campaign !== undefined ? (
          <CampaignComposer
            key={editorKey}
            initial={campaign}
            fromNews={fromNews}
            snapshot={snapshot}
            rights={rights}
            reload={load}
            dirty={setDirty}
            close={() => leave(() => setCampaign(undefined))}
            upload={() => setUpload(true)}
          />
        ) : (
          <>
            <div className="editorial-toolbar">
              <input
                aria-label="Zoek Nachtpost"
                placeholder="Zoek campagne of onderwerp…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
              {rights.compose && (
                <button className="btn" onClick={() => openCampaign(null)}>
                  <Plus size={17} />
                  Nieuwe Nachtpost
                </button>
              )}
            </div>
            {!campaigns.length ? (
              <Empty
                title="Een brief uit de nacht."
                action={
                  rights.compose && (
                    <button className="btn" onClick={() => openCampaign(null)}>
                      Maak je eerste Nachtpost
                    </button>
                  )
                }
              >
                Breng verhalen samen in een persoonlijke nieuwsbrief. Alleen
                volwassenen die daarvoor toestemming hebben gegeven ontvangen
                Nachtpost.
              </Empty>
            ) : (
              <div className="editorial-list">
                {campaigns.map((c) => (
                  <article className="editorial-row" key={c.id}>
                    <Mail size={32} />
                    <div>
                      <span className="editorial-badge gold">
                        {stateLabels[c.status]}
                      </span>
                      <h3>{c.content.internalName}</h3>
                      <p className="editorial-small">
                        {c.content.subject} · versie {c.revision}
                        {c.scheduledAt && ` · ${format(c.scheduledAt)}`}
                        {c.counts && ` · ${c.counts.recipients} ontvangers`}
                      </p>
                      {Object.keys(c.delivery).length > 0 && (
                        <p className="editorial-small">
                          {Object.entries(c.delivery)
                            .map(([s, n]) => `${stateLabels[s] ?? s}: ${n}`)
                            .join(" · ")}
                        </p>
                      )}
                    </div>
                    <div className="editorial-actions">
                      <button
                        className="btn outline"
                        onClick={() => openCampaign(c)}
                      >
                        Openen
                      </button>
                      {rights.compose && (
                        <button
                          className="btn outline"
                          disabled={working}
                          onClick={() => void act(() => duplicate(c))}
                        >
                          <Copy size={15} />
                          Dupliceren
                        </button>
                      )}
                      {rights.send &&
                        ["draft", "ready", "scheduled"].includes(c.status) && (
                          <button
                            className="editorial-text-link"
                            onClick={() =>
                              setPending({
                                title: "Nachtpost annuleren",
                                text: "Deze campagne wordt niet gestart. Je kunt later een nieuwe kopie maken.",
                                action: async () => {
                                  await command({
                                    action: "cancelCampaign",
                                    id: c.id,
                                  });
                                },
                              })
                            }
                          >
                            Annuleren
                          </button>
                        )}
                    </div>
                  </article>
                ))}
              </div>
            )}
          </>
        ))}
      {tab === "media" && (
        <>
          <div className="editorial-toolbar">
            <div>
              <h2>Beelden die een verhaal vertellen.</h2>
              <p className="editorial-small">
                Conceptbeelden blijven afgeschermd. Uitsneden worden automatisch
                voor alle kanalen gemaakt.
              </p>
            </div>
            {(rights.write || rights.compose) && (
              <button className="btn" onClick={() => setUpload(true)}>
                <ImagePlus size={17} />
                Afbeelding uploaden
              </button>
            )}
          </div>
          {!snapshot.media.length ? (
            <Empty title="Geef je verhaal een gezicht.">
              Voeg een eigen hoogwaardige foto of illustratie toe, met een
              duidelijke beschrijving voor mensen die het beeld niet kunnen
              zien.
            </Empty>
          ) : (
            <div className="editorial-media-grid">
              {snapshot.media.map((m) => (
                <article className="editorial-media-tile" key={m.id}>
                  <MediaImage id={m.id} alt={m.alt} variant="card" />
                  <strong>{m.alt}</strong>
                  <p>{m.caption}</p>
                  <p className="editorial-small">
                    {m.width} × {m.height} · focus {m.focalX}% / {m.focalY}%
                  </p>
                  <details>
                    <summary>
                      {m.uses.length
                        ? `Gebruikt in ${m.uses.length} versies`
                        : "Nog niet gebruikt"}
                    </summary>
                    {m.uses.map((u) => (
                      <p className="editorial-small" key={u.versionId}>
                        {u.title} · {u.kind === "news" ? "nieuws" : "Nachtpost"}
                      </p>
                    ))}
                  </details>
                  {(rights.write || rights.compose) && (
                    <button
                      className="editorial-text-link"
                      disabled={m.uses.length > 0 || working}
                      onClick={() =>
                        setPending({
                          title: "Afbeelding verwijderen",
                          text: "Dit beeld wordt verwijderd wanneer het nergens gebruikt wordt.",
                          action: async () => {
                            const r = await fetch("/api/editorial/media", {
                              method: "DELETE",
                              headers: { "content-type": "application/json" },
                              body: JSON.stringify({ id: m.id }),
                            });
                            const body = await r.json();
                            if (!r.ok) throw new Error(body.error?.message);
                          },
                        })
                      }
                    >
                      Verwijderen
                    </button>
                  )}
                </article>
              ))}
            </div>
          )}
        </>
      )}
      {tab === "history" && (
        <>
          <div className="editorial-toolbar">
            <h2>Iedere verzending in beeld.</h2>
            <button
              className="btn outline"
              onClick={() =>
                void load().catch((cause) => setMessage(errorMessage(cause)))
              }
            >
              Vernieuwen
            </button>
          </div>
          <p className="editorial-small">
            Een bericht dat de mail- of pushservice accepteert is nog niet
            noodzakelijk afgeleverd. Openingen en klikken zijn indicatief.
          </p>
          <h3 className="editorial-subheading">Nachtpost</h3>
          <div className="editorial-table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Moment</th>
                  <th>Type</th>
                  <th>Status</th>
                  <th>Pogingen / actie</th>
                </tr>
              </thead>
              <tbody>
                {snapshot.mailHistory.map((m) => (
                  <tr key={m.id}>
                    <td>{format(m.createdAt)}</td>
                    <td>{m.test ? "Testmail" : "Nachtpost"}</td>
                    <td>
                      {stateLabels[m.status] ?? m.status}
                      {m.error && (
                        <small style={{ display: "block" }}>{m.error}</small>
                      )}
                    </td>
                    <td>
                      {m.attempts}
                      {rights.send &&
                        m.status === "failed" &&
                        [
                          "MAIL_GATEWAY_502",
                          "MAIL_NOT_CONFIGURED",
                          "MAIL_DISABLED",
                          "RECIPIENT_NOT_ALLOWED",
                        ].includes(m.error ?? "") && (
                          <button
                            className="editorial-text-link"
                            onClick={() =>
                              void act(async () => {
                                await command({
                                  action: "retry",
                                  id: m.id,
                                  kind: "mail",
                                });
                              })
                            }
                          >
                            Veilig opnieuw proberen
                          </button>
                        )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!snapshot.mailHistory.length && (
              <p>Er zijn nog geen mailverzendingen.</p>
            )}
          </div>
          {snapshot.campaigns
            .filter((c) => Object.keys(c.events).length > 0)
            .map((c) => (
              <section className="editorial-panel" key={c.id}>
                <h3>{c.content.internalName}</h3>
                <p>
                  {Object.entries(c.events)
                    .map(
                      ([key, value]) =>
                        `${({ delivered: "Afgeleverd", bounce: "Bounce", dropped: "Geweigerd", spamreport: "Spamklacht", unsubscribe: "Afmelding", group_unsubscribe: "Afmelding", open: "Opening (indicatief)", click: "Klik (indicatief)", deferred: "Uitgesteld", processed: "Verwerkt" } as Record<string, string>)[key] ?? key}: ${value}`,
                    )
                    .join(" · ")}
                </p>
              </section>
            ))}
          <h3 className="editorial-subheading">Pushnotificaties</h3>
          <div className="editorial-table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Moment</th>
                  <th>Resultaat per apparaat</th>
                  <th>Actie</th>
                </tr>
              </thead>
              <tbody>
                {snapshot.push.map((p) => (
                  <tr key={p.id}>
                    <td>{format(p.createdAt)}</td>
                    <td>
                      {Object.entries(p.statuses)
                        .map(([s, n]) => `${stateLabels[s] ?? s}: ${n}`)
                        .join(" · ")}
                    </td>
                    <td>
                      {rights.send && p.failedAt && (
                        <button
                          className="editorial-text-link"
                          onClick={() =>
                            void act(async () => {
                              await command({
                                action: "retry",
                                id: p.id,
                                kind: "push",
                              });
                            })
                          }
                        >
                          Mislukte apparaten opnieuw proberen
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!snapshot.push.length && (
              <p>Er zijn nog geen nieuws-pushverzendingen.</p>
            )}
          </div>
        </>
      )}
      {upload && <MediaUpload close={() => setUpload(false)} reload={load} />}
      <Dialog open={categoriesOpen} onOpenChange={setCategoriesOpen}>
        <DialogContent className="editorial-dialog">
          <DialogTitle>Nieuwscategorieën</DialogTitle>
          <DialogDescription>
            Uitgeschakelde categorieën blijven bij bestaande berichten bewaard.
          </DialogDescription>
          {snapshot.categories.map((c) => (
            <div className="editorial-actions" key={c.id}>
              <strong>{c.name}</strong>
              <button
                className="btn outline"
                disabled={working}
                onClick={() =>
                  void act(async () => {
                    await command({
                      action: "category",
                      id: c.id,
                      name: c.name,
                      active: !c.active,
                      sort: c.sort_order,
                    });
                  })
                }
              >
                {c.active ? "Uitschakelen" : "Activeren"}
              </button>
            </div>
          ))}
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void act(async () => {
                await command({
                  action: "category",
                  id: null,
                  name: categoryName,
                  active: true,
                  sort: snapshot.categories.length + 1,
                });
                setCategoryName("");
              });
            }}
          >
            <label>
              Nieuwe categorie
              <input
                value={categoryName}
                maxLength={60}
                required
                onChange={(e) => setCategoryName(e.target.value)}
              />
            </label>
            <button className="btn" disabled={working || !categoryName.trim()}>
              Toevoegen
            </button>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!pending}
        onOpenChange={(open) => !open && !working && setPending(null)}
      >
        <DialogContent className="editorial-dialog">
          <DialogTitle>{pending?.title}</DialogTitle>
          <DialogDescription>{pending?.text}</DialogDescription>
          <div className="editorial-actions">
            <button
              className="btn outline"
              disabled={working}
              onClick={() => setPending(null)}
            >
              Annuleren
            </button>
            <button
              className="btn"
              disabled={working}
              onClick={() => pending && void act(pending.action)}
            >
              Bevestigen
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </section>
  );
}
