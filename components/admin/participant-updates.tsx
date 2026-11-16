"use client";

import { useId, useMemo, useRef, useState } from "react";
import { BellRing, Eye, ImagePlus, Send } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { renderParticipantUpdate } from "@/lib/participant-updates/content";

const MAX_BODY_LENGTH = 20_000;
const escapeAttribute = (value: string) => value.replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]!));

export function ParticipantUpdates({ eventSlug }: { eventSlug: string }) {
  const [role, setRole] = useState("all");
  const [priority, setPriority] = useState("normal");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [email, setEmail] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [showPreview, setShowPreview] = useState(false);
  const [previewMode, setPreviewMode] = useState<"formatted" | "text">("formatted");
  const [imageUrl, setImageUrl] = useState("");
  const [imageAlt, setImageAlt] = useState("");
  const [imageNotice, setImageNotice] = useState("");
  const editor = useRef<HTMLTextAreaElement>(null);
  const inputId = useId();
  const previewId = useId();
  const rendered = useMemo(() => renderParticipantUpdate(body), [body]);
  const hasContent = Boolean(rendered.text.trim() || /<img\b/i.test(rendered.html));
  const essential = priority === "important" || priority === "urgent";
  const sendEmail = essential || email;

  function insertImage() {
    let url: URL;
    try { url = new URL(imageUrl.trim()); }
    catch { setImageNotice("Vul het volledige https-adres van de afbeelding in."); return; }
    if (url.protocol !== "https:" || url.username || url.password) { setImageNotice("Gebruik een https-adres zonder gebruikersnaam of wachtwoord."); return; }
    if (!imageAlt.trim()) { setImageNotice("Beschrijf kort wat er op de afbeelding staat."); return; }
    const next = `${body}${body && !body.endsWith("\n") ? "\n" : ""}<img src="${escapeAttribute(url.href)}" alt="${escapeAttribute(imageAlt.trim())}">`;
    if (next.length > MAX_BODY_LENGTH) { setImageNotice("De afbeelding past niet meer binnen 20.000 tekens. Maak het bericht eerst korter."); return; }
    setBody(next); setImageUrl(""); setImageAlt("");
    setImageNotice("Afbeelding toegevoegd aan je bericht. Bekijk het voorbeeld voordat je publiceert.");
    editor.current?.focus();
  }

  async function publish() {
    if (title.trim().length < 3 || body.trim().length < 3 || !hasContent) return setNotice("Vul een duidelijke titel en zichtbare berichtinhoud in.");
    if (!window.confirm(`Publiceer deze update voor ${role === "all" ? "alle rollen" : role} ${essential ? "en stuur dit noodzakelijke evenementbericht naar iedereen in deze doelgroep, ook bij uitgeschakelde nieuwsbrief- of updatevoorkeuren" : email ? "en verstuur e-mail volgens de voorkeuren" : "zonder e-mail"}?`)) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_publish_participant_update", {
      _event_slug: eventSlug,
      _audience_role: role,
      _title: title.trim(),
      _body: body.trim(),
      _priority: priority,
      _send_email: sendEmail,
    });
    setBusy(false);
    if (error) return setNotice("Publiceren is niet gelukt. Controleer je rechten en probeer opnieuw.");
    const result = data as { emailCount: number };
    setTitle(""); setBody("");
    setNotice(`Update gepubliceerd${sendEmail ? ` en ${result.emailCount} e-mailmelding${result.emailCount === 1 ? "" : "en"} klaargezet` : ""}.`);
  }

  return <section className="panel">
    <div className="row-between"><div><p className="kicker">Rolgerichte communicatie</p><h2>Deelnemersupdates</h2><p>Publiceer alleen operationele informatie die deze doelgroep nodig heeft. Leesstatus wordt per account bijgehouden.</p></div><BellRing /></div>
    <div className="grid-2">
      <label className="field"><span>Doelgroep</span><select value={role} onChange={(event) => setRole(event.target.value)}><option value="all">Alle rollen</option><option value="walker">Meelopers</option><option value="viewer">Meekijkers</option><option value="homeowner">Huiseigenaren</option></select></label>
      <label className="field"><span>Prioriteit</span><select value={priority} onChange={(event) => setPriority(event.target.value)}><option value="normal">Normaal</option><option value="important">Belangrijk</option><option value="urgent">Urgent</option></select></label>
    </div>
    <label className="field" htmlFor={`${inputId}-title`}><span>Titel</span><input id={`${inputId}-title`} maxLength={120} value={title} onChange={(event) => setTitle(event.target.value)} /></label>
    <label className="field" htmlFor={inputId}><span>Bericht · tekst of HTML</span><textarea ref={editor} id={inputId} rows={10} maxLength={MAX_BODY_LENGTH} value={body} onChange={(event) => setBody(event.target.value)} aria-describedby={`${inputId}-hint`} /></label>
    <div id={`${inputId}-hint`} className="participant-update-hint">
      <p>Plak gewone tekst of HTML. Enter en lege regels blijven zichtbaar. Veilige opmaak, links en afbeeldingen worden in de update en e-mail weergegeven; scripts en onveilige HTML worden verwijderd.</p>
      <p>Voorbeeld: <code>{'<p>Beste deelnemers,</p><p><strong>Let op:</strong> we starten om 18:00.</p>'}</code></p>
      <p>{body.length.toLocaleString("nl-NL")} / 20.000 tekens</p>
    </div>
    <details className="participant-update-image-helper">
      <summary><ImagePlus aria-hidden="true" />Afbeelding invoegen via een URL</summary>
      <p>Gebruik een publiek bereikbaar https-adres. De afbeelding wordt onderaan je bericht toegevoegd; dit uploadt of verstuurt niets.</p>
      <div className="grid-2">
        <label className="field"><span>HTTPS-adres van de afbeelding</span><input type="url" maxLength={2048} placeholder="https://voorbeeld.nl/afbeelding.jpg" value={imageUrl} onChange={(event) => setImageUrl(event.target.value)} /></label>
        <label className="field"><span>Beschrijving van de afbeelding</span><input maxLength={200} placeholder="Wat is er op de afbeelding te zien?" value={imageAlt} onChange={(event) => setImageAlt(event.target.value)} /></label>
      </div>
      <button className="btn outline" type="button" disabled={busy || !imageUrl.trim() || !imageAlt.trim()} onClick={insertImage}><ImagePlus aria-hidden="true" />Afbeelding aan bericht toevoegen</button>
      {imageNotice && <p className="form-notice" role="status">{imageNotice}</p>}
      <p className="participant-update-hint">Je kunt ook zelf HTML plakken: <code>{'<img src="https://voorbeeld.nl/afbeelding.jpg" alt="Beschrijving van de afbeelding">'}</code></p>
    </details>
    <button className="btn outline" type="button" aria-expanded={showPreview} aria-controls={previewId} onClick={() => setShowPreview(value => !value)}><Eye aria-hidden="true" />{showPreview ? "Voorbeeld sluiten" : "Voorbeeld bekijken"}</button>
    {showPreview && <section id={previewId} className="participant-update-preview" aria-label="Voorbeeld van de update">
      <div className="row-between"><h3>Voorbeeld van je update</h3><div className="participant-update-preview-modes" role="group" aria-label="Weergave van het voorbeeld">
        <button className="btn outline" type="button" aria-pressed={previewMode === "formatted"} onClick={() => setPreviewMode("formatted")}>Opgemaakt</button>
        <button className="btn outline" type="button" aria-pressed={previewMode === "text"} onClick={() => setPreviewMode("text")}>Alleen tekst</button>
      </div></div>
      <p className="participant-update-hint">Dit voorbeeld verstuurt niets. De opgemaakte inhoud gebruikt dezelfde veilige weergave als de deelnemersomgeving.</p>
      <h4>{title.trim() || "Titel van je update"}</h4>
      {hasContent ? previewMode === "formatted" ? <div className="participant-update-content" dangerouslySetInnerHTML={{ __html: rendered.html }} /> : <div className="participant-update-plain">{rendered.text}</div> : <p>Voer een bericht in om het voorbeeld te bekijken.</p>}
    </section>}
    <label className="checkfield"><input type="checkbox" checked={sendEmail} disabled={essential} onChange={(event) => setEmail(event.target.checked)} />{essential ? "E-mail naar iedereen in de gekozen doelgroep is verplicht voor dit belangrijke evenementbericht." : "Stuur ook e-mail naar accounts die e-mailupdates aan hebben staan."}</label>
    {essential && <p className="form-notice">Gebruik Belangrijk en Urgent uitsluitend voor noodzakelijke informatie over veiligheid of uitvoering van het evenement. Alle huidige en nieuwe inschrijvers in de gekozen doelgroep komen automatisch in aanmerking. Afmelden voor Nachtpost blokkeert deze berichten niet; nieuwsbriefvoorkeuren blijven bewaard.</p>}
    <button className="btn" disabled={busy || title.trim().length < 3 || body.trim().length < 3 || !hasContent} onClick={() => void publish()}><Send />Publiceer update</button>
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </section>;
}
