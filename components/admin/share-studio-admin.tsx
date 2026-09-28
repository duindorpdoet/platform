"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { BarChart3, CheckCircle2, Eye, RefreshCw, Save, ShieldCheck } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Template = {
  id: string; key: string; name: string; status: "live" | "archived"; roles: string[]; formats: string[];
  portraitAsset: string; landscapeAsset: string; textConfig: Record<string, string>; defaultCaption: string;
  ctaType: string; validFrom: string | null; validUntil: string | null; worldSlug: string | null;
  utmCampaign: string | null; safeAreas: Record<string, unknown>; version: number; publishedAt: string | null;
};
type Metric = { templateKey: string | null; eventType: string; count: number };
type Snapshot = { templates: Template[]; analytics: Metric[] };

const roleLabels: Record<string, string> = { public: "Publiek", walker: "Deelnemer", walker_lead: "Hoofdinschrijving", homeowner: "Poorteigenaar" };
const formatLabels: Record<string, string> = { story: "Story", feed: "Feed", square: "Vierkant", landscape: "Liggend", opengraph: "Open Graph" };
const eventLabels: Record<string, string> = {
  studio_opened: "Studio geopend", template_selected: "Template gekozen", preview_generated: "Preview gemaakt",
  image_downloaded: "Gedownload", caption_copied: "Bericht gekopieerd", link_copied: "Link gekopieerd",
  native_share_opened: "Deelmenu geopend", native_share_completed: "Deelactie voltooid", platform_fallback_opened: "Platformfallback", public_page_viewed: "Deelpagina bekeken",
};

function localDate(value: string | null) {
  return value ? new Date(value).toISOString().slice(0, 16) : "";
}
export function ShareStudioAdmin({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [selected, setSelected] = useState("");
  const [draft, setDraft] = useState<Template | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const result = await client.schema("api").rpc("admin_social_share_snapshot", { _event_slug: eventSlug });
    if (result.error) { setNotice("De Deelstudio-instellingen konden niet worden opgehaald."); return; }
    const next = result.data as unknown as Snapshot;
    setSnapshot(next);
    const key = selected || next.templates[0]?.key || "";
    setSelected(key);
    setDraft(next.templates.find((item) => item.key === key) ?? null);
  }, [eventSlug, selected]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => clearTimeout(timer); }, [load]);
  const metrics = useMemo(() => snapshot?.analytics.filter((item) => !selected || item.templateKey === selected) ?? [], [snapshot, selected]);

  function choose(key: string) {
    setSelected(key);
    setDraft(snapshot?.templates.find((item) => item.key === key) ?? null);
    setNotice("");
  }

  function toggleList(field: "roles" | "formats", value: string) {
    if (!draft) return;
    const list = draft[field];
    setDraft({ ...draft, [field]: list.includes(value) ? list.filter((item) => item !== value) : [...list, value] });
  }

  async function publish() {
    if (!draft || busy) return;
    setBusy(true); setNotice("");
    const client = createClient();
    if (!client) { setBusy(false); return; }
    const result = await client.schema("api").rpc("admin_social_share_publish", {
      _event_slug: eventSlug, _template_key: draft.key, _active: draft.status === "live", _roles: draft.roles,
      _formats: draft.formats, _portrait_asset: draft.portraitAsset, _landscape_asset: draft.landscapeAsset,
      _text_config: draft.textConfig, _default_caption: draft.defaultCaption,
      _valid_from: draft.validFrom || null, _valid_until: draft.validUntil || null,
      _world_slug: draft.worldSlug || null, _utm_campaign: draft.utmCampaign || null,
    });
    setBusy(false);
    setNotice(result.error ? "Publiceren is niet gelukt. Controleer velden, rollen en periode." : `Versie ${(result.data as { version: number }).version} is gepubliceerd; de vorige versie is gearchiveerd.`);
    if (!result.error) await load();
  }

  if (!snapshot || !draft) return <section className="panel loading-state"><RefreshCw className="spin" />Deelstudio ophalen…</section>;
  return <div className="admin-share-studio">
    <header className="app-heading row-between"><div><p className="kicker">Communicatie → Deelstudio</p><h1>Beheer iedere deelkaart.</h1><p>Nieuwe publicaties maken altijd een vaste templateversie. Historische kaarten veranderen niet.</p></div><a className="btn outline" href="/deel-de-magie" target="_blank" rel="noreferrer"><Eye />Open gebruikersstudio</a></header>
    {notice && <p className="form-notice" role="status">{notice}</p>}
    <div className="admin-share-layout">
      <nav className="panel admin-share-list" aria-label="Deeltemplates">{snapshot.templates.map((item) => <button type="button" key={item.key} className={selected === item.key ? "active" : ""} onClick={() => choose(item.key)}><span><strong>{item.name}</strong><small>{item.key} · v{item.version}</small></span><em className={item.status}>{item.status === "live" ? "Actief" : "Uit"}</em></button>)}</nav>
      <div className="admin-share-editor">
        <section className="panel">
          <div className="row-between"><div><p className="kicker">Template · versie {draft.version}</p><h2>{draft.name}</h2></div><label className="admin-share-switch"><input type="checkbox" checked={draft.status === "live"} onChange={(event) => setDraft({ ...draft, status: event.target.checked ? "live" : "archived" })} /><span>{draft.status === "live" ? "Actief" : "Uitgeschakeld"}</span></label></div>
          <div className="admin-share-previews"><figure><img src={draft.portraitAsset} alt={`Portrait achtergrond van ${draft.name}`} /><figcaption>Portrait safe area</figcaption></figure><figure><img src={draft.landscapeAsset} alt={`Landscape achtergrond van ${draft.name}`} /><figcaption>Landscape safe area</figcaption></figure></div>
          <div className="admin-share-form-grid">
            <label className="field"><span>Portrait achtergrond</span><input value={draft.portraitAsset} onChange={(event) => setDraft({ ...draft, portraitAsset: event.target.value })} /></label>
            <label className="field"><span>Landscape achtergrond</span><input value={draft.landscapeAsset} onChange={(event) => setDraft({ ...draft, landscapeAsset: event.target.value })} /></label>
            <label className="field"><span>Geldig vanaf</span><input type="datetime-local" value={localDate(draft.validFrom)} onChange={(event) => setDraft({ ...draft, validFrom: event.target.value ? new Date(event.target.value).toISOString() : null })} /></label>
            <label className="field"><span>Geldig tot</span><input type="datetime-local" value={localDate(draft.validUntil)} onChange={(event) => setDraft({ ...draft, validUntil: event.target.value ? new Date(event.target.value).toISOString() : null })} /></label>
            <label className="field"><span>UTM-campagne</span><input maxLength={80} value={draft.utmCampaign ?? ""} onChange={(event) => setDraft({ ...draft, utmCampaign: event.target.value })} /></label>
            <label className="field"><span>Wereldvariant (slug)</span><input value={draft.worldSlug ?? ""} onChange={(event) => setDraft({ ...draft, worldSlug: event.target.value })} /></label>
          </div>
          <fieldset className="admin-share-checks"><legend>Beschikbaar voor</legend>{Object.entries(roleLabels).map(([value, label]) => <label key={value}><input type="checkbox" checked={draft.roles.includes(value)} onChange={() => toggleList("roles", value)} />{label}</label>)}</fieldset>
          <fieldset className="admin-share-checks"><legend>Formaten</legend>{Object.entries(formatLabels).map(([value, label]) => <label key={value}><input type="checkbox" checked={draft.formats.includes(value)} onChange={() => toggleList("formats", value)} />{label}</label>)}</fieldset>
          <label className="field"><span>Standaardbericht</span><textarea rows={10} maxLength={4000} value={draft.defaultCaption} onChange={(event) => setDraft({ ...draft, defaultCaption: event.target.value })} /></label>
          <div className="admin-share-form-grid"><label className="field"><span>Eventlink</span><input value={draft.textConfig.publicEventPath ?? "/"} onChange={(event) => setDraft({ ...draft, textConfig: { ...draft.textConfig, publicEventPath: event.target.value } })} /></label><label className="field"><span>Inschrijflink</span><input value={draft.textConfig.houseRegistrationPath ?? "/huis-aanmelden"} onChange={(event) => setDraft({ ...draft, textConfig: { ...draft.textConfig, houseRegistrationPath: event.target.value } })} /></label></div>
          <div className="form-notice"><ShieldCheck /> Safe areas en logoformaat zijn vast onderdeel van de serverrenderer. Alleen gecureerde lokale WebP-achtergronden worden geaccepteerd.</div>
          <button className="btn" type="button" disabled={busy || !draft.roles.length || !draft.formats.length} onClick={() => void publish()}><Save />{busy ? "Publiceren…" : "Publiceer nieuwe versie"}</button>
        </section>
        <section className="panel"><div className="row-between"><div><p className="kicker">Eerlijke funnel</p><h2>Gebruik van deze kaart</h2></div><BarChart3 /></div><p>Een geopend native deelmenu wordt bewust niet als succesvolle plaatsing geteld.</p><div className="admin-share-metrics">{metrics.length ? metrics.map((item) => <div key={item.eventType}><span>{eventLabels[item.eventType] ?? item.eventType}</span><strong>{item.count}</strong></div>) : <p>Nog geen gebeurtenissen voor deze template.</p>}</div><p className="note"><CheckCircle2 /> Er worden geen IP-adressen of volledige user agents opgeslagen.</p></section>
      </div>
    </div>
  </div>;
}
