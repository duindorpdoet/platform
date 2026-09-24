"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type ContentVersion = { id: string; pageKey: string; locale: string; content: { title?: string; body?: string }; status: string; version: number; publishedAt?: string | null };
type Sponsor = { id: string; contactName: string; contactEmail: string; contributionType: string; proposedAmountCents?: number | null; message?: string | null; status: string; version: number; publication?: { approvedName: string; websiteUrl?: string | null } | null };
type Snapshot = { versions: ContentVersion[]; sponsors: Sponsor[] };

export function ContentManagement({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot>({ versions: [], sponsors: [] });
  const [pageKey, setPageKey] = useState("home");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_content_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Contentbeheer kon niet worden opgehaald.");
    setSnapshot(data as Snapshot);
  }, [eventSlug]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function saveDraft() {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(pageKey) || !title.trim() || !body.trim()) return setNotice("Vul een geldige paginasleutel, titel en tekst in.");
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("admin_save_content_draft", { _event_slug: eventSlug, _page_key: pageKey, _locale: "nl-NL", _content: { title: title.trim(), body: body.trim() } });
    setNotice(error ? `Concept geweigerd: ${error.message}` : "Nieuwe contentversie als concept opgeslagen; publiek is niets gewijzigd.");
    if (!error) { setTitle(""); setBody(""); await load(); }
  }

  async function publishContent(version: ContentVersion) {
    if (!window.confirm(`Publiceer ${version.pageKey} versie ${version.version}?`)) return;
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("admin_publish_content", { _content_version_id: version.id, _expected_version: version.version, _reason: "Content gepubliceerd via beheeromgeving" });
    setNotice(error ? `Publicatie geweigerd: ${error.message}` : "Contentversie gepubliceerd; de vorige publicatie is gearchiveerd.");
    if (!error) await load();
  }

  async function publishSponsor(sponsor: Sponsor) {
    const approvedName = window.prompt("Publieke sponsornaam:", sponsor.publication?.approvedName ?? sponsor.contactName)?.trim();
    const websiteUrl = window.prompt("Publieke HTTPS-website (optioneel):", sponsor.publication?.websiteUrl ?? "")?.trim() ?? "";
    if (!approvedName || !window.confirm(`Publiceer ${approvedName} als sponsor?`)) return;
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("admin_publish_sponsor", { _application_id: sponsor.id, _expected_version: sponsor.version, _approved_name: approvedName, _website_url: websiteUrl, _sort_order: 0, _reason: "Sponsor gepubliceerd via beheeromgeving" });
    setNotice(error ? `Sponsorpublicatie geweigerd: ${error.message}` : "Alleen de goedgekeurde sponsornaam en website zijn gepubliceerd.");
    if (!error) await load();
  }

  return <div className="dashboard-stack">
    <section className="panel production-form">
      <p className="kicker">Versiebeheer</p><h2>Publieke content</h2>
      <p>Opslaan maakt altijd een concept. Alleen de aparte publicatieactie vervangt de publieke versie en schrijft een auditregel.</p>
      <label className="field"><span>Paginasleutel</span><input value={pageKey} onChange={(event) => setPageKey(event.target.value.toLowerCase())} /></label>
      <label className="field"><span>Titel</span><input value={title} onChange={(event) => setTitle(event.target.value)} /></label>
      <label className="field"><span>Tekst</span><textarea rows={7} value={body} onChange={(event) => setBody(event.target.value)} /></label>
      <button className="btn" onClick={() => void saveDraft()}>Sla nieuwe conceptversie op</button>
      {snapshot.versions.map((version) => <div className="summary-row" key={version.id}><span>{version.pageKey} · v{version.version} · {version.status}</span>{version.status === "draft" ? <button className="text-link" onClick={() => void publishContent(version)}>Publiceer</button> : <strong>{version.publishedAt ? new Date(version.publishedAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" }) : version.status}</strong>}</div>)}
    </section>
    <section className="panel">
      <p className="kicker">Goedkeuring</p><h2>Sponsoraanvragen</h2>
      <p>Contactgegevens, bijdrage en bericht blijven privé. Alleen de expliciet goedgekeurde naam en HTTPS-link verschijnen publiek.</p>
      {snapshot.sponsors.length === 0 ? <p>Geen aanvragen.</p> : snapshot.sponsors.map((sponsor) => <div className="incident-row" key={sponsor.id}><div><strong>{sponsor.contactName} · {sponsor.status}</strong><small>{sponsor.contactEmail} · {sponsor.contributionType}{sponsor.proposedAmountCents ? ` · € ${(sponsor.proposedAmountCents / 100).toFixed(2).replace(".", ",")}` : ""}</small>{sponsor.message && <p>{sponsor.message}</p>}</div><button className="btn outline" onClick={() => void publishSponsor(sponsor)}>{sponsor.publication ? "Publicatie bijwerken" : "Goedkeuren en publiceren"}</button></div>)}
    </section>
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </div>;
}
