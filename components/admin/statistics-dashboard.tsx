"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Activity,
  Download,
  LogIn,
  RefreshCw,
  Share2,
  Smartphone,
  UsersRound,
  WandSparkles,
} from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import styles from "./statistics-dashboard.module.css";

type Summary = {
  adultLogins: number;
  uniqueAdultUsers: number;
  childLogins: number;
  uniqueChildAccounts: number;
  pwaInstalled: number;
  pwaManualConfirmed: number;
  pwaUniqueUsers: number;
  pwaStandaloneOpens: number;
  socialGenerated: number;
  socialDownloaded: number;
  socialShareCompleted: number;
  socialShareIntents: number;
  uniqueSocialActors: number;
};
type SurfaceMetric = { surface: string; count: number; uniqueActors: number };
type PwaMetric = { eventType: string; count: number; uniqueActors: number };
type SocialMetric = { eventType: string; platform: string | null; count: number; uniqueActors: number };
type TemplateMetric = { templateKey: string; templateName: string; generated: number; downloaded: number; shared: number };
type DailyMetric = { date: string; adultLogins: number; childLogins: number; pwaInstalled: number; socialShared: number };
type ActivityActor = { id: string | null; name: string; email: string | null; role: string; groupCode?: string | null; session?: string };
type RecentActivity = {
  kind: "auth" | "product" | "child" | "social";
  eventType: string;
  surface: string;
  actor: ActivityActor;
  detail: { provider?: string | null; platform?: string | null; templateKey?: string | null; templateName?: string | null; displayMode?: string; platformName?: string };
  occurredAt: string;
};
type Snapshot = {
  from: string;
  to: string;
  summary: Summary;
  loginDestinations: SurfaceMetric[];
  environmentOpens: SurfaceMetric[];
  pwa: PwaMetric[];
  social: SocialMetric[];
  templates: TemplateMetric[];
  daily: DailyMetric[];
  recent: RecentActivity[];
};

const surfaceLabels: Record<string, string> = {
  participant: "Deelnemersomgeving",
  group: "Groepsomgeving",
  homeowner: "Huizenomgeving",
  child: "Kinderomgeving",
  admin: "Organisatie",
  editorial: "Redactiekamer",
  share_studio: "Deelstudio",
  unknown: "Onbekende bestemming",
};
const eventLabels: Record<string, string> = {
  auth_login: "Ingelogd",
  login_completed: "Ingelogd",
  environment_opened: "Omgeving geopend",
  pwa_install_prompt_accepted: "Installatie geaccepteerd",
  pwa_install_completed: "PWA browser-bevestigd geïnstalleerd",
  pwa_install_manual_confirmed: "PWA-installatie zelf bevestigd",
  pwa_standalone_opened: "PWA als app geopend",
  preview_generated: "Social afbeelding gemaakt",
  image_downloaded: "Social afbeelding gedownload",
  native_share_opened: "Native deelmenu geopend",
  native_share_completed: "Native deelactie voltooid",
  platform_fallback_opened: "Deelroute via download geopend",
};
const pwaLabels: Record<string, string> = {
  pwa_install_prompt_accepted: "Installatieprompt geaccepteerd",
  pwa_install_completed: "Browser-bevestigde installaties",
  pwa_install_manual_confirmed: "Zelf bevestigde installaties",
  pwa_standalone_opened: "Als app geopend",
};
const socialLabels: Record<string, string> = {
  studio_opened: "Studio geopend",
  template_selected: "Template gekozen",
  preview_generated: "Afbeelding gemaakt",
  image_downloaded: "Afbeelding gedownload",
  caption_copied: "Bericht gekopieerd",
  link_copied: "Link gekopieerd",
  native_share_opened: "Deelmenu geopend",
  native_share_completed: "Deelactie voltooid",
  platform_fallback_opened: "Platformroute geopend",
  public_page_viewed: "Deelpagina bekeken",
  house_registration_started: "Huisaanmelding gestart",
  house_registration_completed: "Huisaanmelding voltooid",
  participant_registration_started: "Deelnemersinschrijving gestart",
  participant_registration_completed: "Deelnemersinschrijving voltooid",
};

function number(value: number) {
  return new Intl.NumberFormat("nl-NL").format(value ?? 0);
}

function localDateTime(value: string) {
  return new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" }).format(new Date(value));
}

function detailLabel(item: RecentActivity) {
  if (item.kind === "child") return item.actor.groupCode ? `Groep ${item.actor.groupCode}` : "Kinderomgeving";
  if (item.kind === "social") return [item.detail.templateName, item.detail.platform].filter(Boolean).join(" · ") || "Deelstudio";
  if (item.detail.displayMode === "standalone") return "Geopend als app";
  if (item.detail.platform) return item.detail.platform;
  if (item.detail.provider) return `via ${item.detail.provider}`;
  return surfaceLabels[item.surface] ?? item.surface;
}

function MetricList({ items, labels = surfaceLabels }: { items: Array<{ count: number; uniqueActors: number; key: string; id?: string; label?: string }>; labels?: Record<string, string> }) {
  const max = Math.max(1, ...items.map((item) => item.count));
  if (!items.length) return <p className={styles.empty}>Nog geen metingen in deze periode.</p>;
  return <div className={styles.metricList}>{items.map((item) => <div className={styles.metricRow} key={item.id ?? item.key}>
    <div><strong>{item.label ?? labels[item.key] ?? item.key}</strong><span>{number(item.uniqueActors)} uniek</span></div>
    <div className={styles.meter} aria-hidden="true"><span style={{ width: `${Math.max(3, item.count / max * 100)}%` }} /></div>
    <b>{number(item.count)}</b>
  </div>)}</div>;
}

export function StatisticsDashboard({ eventSlug }: { eventSlug: string }) {
  const [days, setDays] = useState(30);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [busy, setBusy] = useState(true);
  const [notice, setNotice] = useState("");
  const [activityFilter, setActivityFilter] = useState<"all" | RecentActivity["kind"]>("all");

  const load = useCallback(async () => {
    setBusy(true);
    setNotice("");
    const client = createClient();
    if (!client) {
      setNotice("De statistiekenverbinding is niet beschikbaar.");
      setBusy(false);
      return;
    }
    const result = await client.schema("api").rpc("admin_product_analytics_snapshot", { _event_slug: eventSlug, _days: days });
    if (result.error || !result.data) setNotice("De statistieken konden niet worden opgehaald. Probeer het opnieuw.");
    else setSnapshot(result.data as unknown as Snapshot);
    setBusy(false);
  }, [days, eventSlug]);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  const recent = useMemo(() => snapshot?.recent.filter((item) => activityFilter === "all" || item.kind === activityFilter) ?? [], [activityFilter, snapshot]);
  const daily = snapshot?.daily.slice(-31) ?? [];
  const dailyMax = Math.max(1, ...daily.map((item) => item.adultLogins + item.childLogins + item.pwaInstalled + item.socialShared));

  if (!snapshot && busy) return <section className="panel loading-state"><RefreshCw className="spin" />Statistieken ophalen…</section>;
  if (!snapshot) return <section className="panel"><p className="form-error">{notice || "De statistieken zijn niet beschikbaar."}</p><button className="btn outline" type="button" onClick={() => void load()}><RefreshCw />Opnieuw proberen</button></section>;

  const summary = snapshot.summary;
  return <div className={styles.dashboard}>
    <header className={`app-heading row-between ${styles.heading}`}>
      <div><p className="kicker">Organisatie · inzicht</p><h1>Statistieken</h1><p>Installaties, logins, omgevingsgebruik en Deelstudio-activiteit op één plek.</p></div>
      <div className={styles.toolbar}>
        <label><span>Periode</span><select value={days} onChange={(event) => setDays(Number(event.target.value))}><option value={7}>7 dagen</option><option value={30}>30 dagen</option><option value={90}>90 dagen</option><option value={0}>Alles</option></select></label>
        <button className="btn outline" type="button" disabled={busy} onClick={() => void load()}><RefreshCw className={busy ? "spin" : undefined} />Vernieuwen</button>
      </div>
    </header>
    {notice && <p className="form-notice" role="status">{notice}</p>}

    <section className={styles.summary} aria-label="Kerncijfers">
      <article><span><LogIn /></span><strong>{number(summary.adultLogins + summary.childLogins)}</strong><p>Geslaagde logins</p><small>{number(summary.adultLogins)} volwassenen · {number(summary.childLogins)} kinderen</small></article>
      <article><span><UsersRound /></span><strong>{number(summary.uniqueAdultUsers + summary.uniqueChildAccounts)}</strong><p>Unieke accounts</p><small>{number(summary.uniqueAdultUsers)} volwassenen · {number(summary.uniqueChildAccounts)} kinderen</small></article>
      <article><span><Smartphone /></span><strong>{number(summary.pwaInstalled + summary.pwaManualConfirmed)}</strong><p>PWA-installaties</p><small>{number(summary.pwaInstalled)} browser-bevestigd · {number(summary.pwaManualConfirmed)} zelf bevestigd</small></article>
      <article><span><Share2 /></span><strong>{number(summary.socialShareCompleted)}</strong><p>Voltooide deelacties</p><small>{number(summary.socialShareIntents)} keer het delen gestart</small></article>
      <article><span><WandSparkles /></span><strong>{number(summary.socialGenerated)}</strong><p>Afbeeldingen gemaakt</p><small>{number(summary.uniqueSocialActors)} unieke makers</small></article>
      <article><span><Download /></span><strong>{number(summary.socialDownloaded)}</strong><p>Afbeeldingen gedownload</p><small>Inclusief fallback voor social-apps</small></article>
    </section>

    <section className={`panel ${styles.trend}`}>
      <div className={styles.sectionHeading}><div><p className="kicker">Trend</p><h2>Activiteit per dag</h2></div><div className={styles.legend}><span data-tone="adult">Volwassen login</span><span data-tone="child">Kinderlogin</span><span data-tone="pwa">PWA</span><span data-tone="share">Delen</span></div></div>
      <div className={styles.chart}>
        {daily.map((item) => <div className={styles.chartRow} key={item.date}>
          <time dateTime={item.date}>{new Intl.DateTimeFormat("nl-NL", { day: "2-digit", month: "short" }).format(new Date(`${item.date}T12:00:00`))}</time>
          <div className={styles.chartTrack} title={`${item.adultLogins} volwassen logins, ${item.childLogins} kinderlogins, ${item.pwaInstalled} PWA-installaties, ${item.socialShared} deelacties`}>
            <span data-tone="adult" style={{ width: `${item.adultLogins / dailyMax * 100}%` }} />
            <span data-tone="child" style={{ width: `${item.childLogins / dailyMax * 100}%` }} />
            <span data-tone="pwa" style={{ width: `${item.pwaInstalled / dailyMax * 100}%` }} />
            <span data-tone="share" style={{ width: `${item.socialShared / dailyMax * 100}%` }} />
          </div>
          <b>{number(item.adultLogins + item.childLogins + item.pwaInstalled + item.socialShared)}</b>
        </div>)}
      </div>
    </section>

    <div className={styles.twoColumns}>
      <section className="panel"><div className={styles.sectionHeading}><div><p className="kicker">Logins</p><h2>Bestemming na inloggen</h2></div><LogIn /></div><MetricList items={snapshot.loginDestinations.map((item) => ({ ...item, key: item.surface }))} /></section>
      <section className="panel"><div className={styles.sectionHeading}><div><p className="kicker">Gebruik</p><h2>Omgevingen geopend</h2></div><Activity /></div><MetricList items={snapshot.environmentOpens.map((item) => ({ ...item, key: item.surface }))} /></section>
    </div>

    <div className={styles.twoColumns}>
      <section className={`panel ${styles.explainer}`}>
        <div className={styles.sectionHeading}><div><p className="kicker">PWA</p><h2>Installatie & appgebruik</h2></div><Smartphone /></div>
        <p>Een PWA heeft geen app-store-download. Daarom onderscheiden we browser-bevestigde installaties, een handmatige bevestiging (zoals op iOS) en openen in standalone appweergave.</p>
        <MetricList items={snapshot.pwa.map((item) => ({ ...item, key: item.eventType }))} labels={pwaLabels} />
        <p className={styles.note}>{number(summary.pwaUniqueUsers)} unieke accounts met een bevestigd installatiesignaal · {number(summary.pwaStandaloneOpens)} standalone opens.</p>
      </section>
      <section className={`panel ${styles.explainer}`}>
        <div className={styles.sectionHeading}><div><p className="kicker">Deelstudio</p><h2>Social funnel</h2></div><Share2 /></div>
        <p>“Voltooid” betekent dat het native deelvenster zonder annulering sloot. Browsers en social-platforms bevestigen niet of een bericht daarna echt is gepubliceerd.</p>
        <MetricList items={snapshot.social.map((item) => ({ ...item, key: item.eventType, id: `${item.eventType}-${item.platform ?? "none"}`, label: `${socialLabels[item.eventType] ?? item.eventType}${item.platform ? ` · ${item.platform}` : ""}` }))} labels={socialLabels} />
      </section>
    </div>

    <section className={`panel ${styles.templates}`}>
      <div className={styles.sectionHeading}><div><p className="kicker">Content</p><h2>Resultaat per social template</h2></div><WandSparkles /></div>
      <div className={styles.tableWrap}><table><thead><tr><th>Template</th><th>Gemaakt</th><th>Gedownload</th><th>Gedeeld</th><th>Van gemaakt naar gedeeld</th></tr></thead><tbody>{snapshot.templates.map((item) => <tr key={item.templateKey}><th>{item.templateName}<small>{item.templateKey}</small></th><td>{number(item.generated)}</td><td>{number(item.downloaded)}</td><td>{number(item.shared)}</td><td>{item.generated ? `${Math.round(item.shared / item.generated * 100)}%` : "—"}</td></tr>)}</tbody></table></div>
    </section>

    <section className={`panel ${styles.activity}`}>
      <div className={styles.sectionHeading}><div><p className="kicker">Wie deed wat</p><h2>Recente activiteit</h2></div><Activity /></div>
      <div className={styles.filters} role="group" aria-label="Activiteit filteren">{(["all", "auth", "child", "product", "social"] as const).map((filter) => <button type="button" key={filter} className={activityFilter === filter ? styles.active : undefined} aria-pressed={activityFilter === filter} onClick={() => setActivityFilter(filter)}>{({ all: "Alles", auth: "Inlog", child: "Kind", product: "PWA & omgeving", social: "Social" })[filter]}</button>)}</div>
      <div className={styles.tableWrap}><table><thead><tr><th>Wie</th><th>Actie</th><th>Omgeving / detail</th><th>Tijdstip</th></tr></thead><tbody>{recent.map((item, index) => <tr key={`${item.occurredAt}-${item.kind}-${index}`}><th><span>{item.actor.name}</span><small>{item.actor.email ?? item.actor.role}</small></th><td>{eventLabels[item.eventType] ?? item.eventType}</td><td>{detailLabel(item)}</td><td><time dateTime={item.occurredAt}>{localDateTime(item.occurredAt)}</time></td></tr>)}</tbody></table>{!recent.length && <p className={styles.empty}>Geen activiteit voor dit filter.</p>}</div>
      <p className={styles.privacy}>Kinderactiviteit toont nooit een kindernaam. Nieuwe productmetingen slaan geen IP-adres of volledige user-agent op.</p>
    </section>
  </div>;
}
