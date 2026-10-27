"use client";
import { useCallback, useEffect, useState } from "react";
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import type { MailSettings } from "@/lib/mail/admin-types";
import { resendEvents } from "@/lib/mail/resend-events";

const when = (value: string | null) => value ? new Date(value).toLocaleString("nl-NL") : "Nog niet gecontroleerd";
const deliveryLabels: Record<string, string> = { pending: "In wachtrij", accepted: "Geaccepteerd door provider; wacht op afleverbevestiging", delivered: "Afgeleverd bij de ontvangende mailserver", delayed: "Provideraflevering vertraagd", bounced: "Afleverfout", complained: "Spamklacht / suppressie", suppressed: "Door provider tegengehouden", failed: "Providerfout", unknown: "Verzenduitkomst onbekend", reconcile: "Handmatige controle vereist", processing: "Verzending wordt verwerkt", deferred: "Wacht op volgende poging" };

export function EmailSettings() {
  const [data, setData] = useState<MailSettings | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [fromName, setFromName] = useState("");
  const [fromEmail, setFromEmail] = useState("");
  const [replyTo, setReplyTo] = useState("");
  const [dialog, setDialog] = useState<"activate" | "test" | null>(null);
  const [recipient, setRecipient] = useState("");
  const [testKey, setTestKey] = useState("");
  const load = useCallback(async (resetForm = true) => {
    try {
      const response = await fetch("/api/mail/settings", { cache: "no-store" });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error?.message ?? "Het overzicht is niet beschikbaar.");
      const next = body.data as MailSettings;
      setData(next); setError("");
      if (resetForm) { const form = next.draft ?? next.active; setFromName(form.from_name); setFromEmail(form.from_email); setReplyTo(form.reply_to); }
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Het overzicht is niet beschikbaar."); }
  }, []);
  useEffect(() => { const timer = setTimeout(() => void load(), 0); return () => clearTimeout(timer); }, [load]);
  useEffect(() => { const timer = setInterval(() => void load(false), 15000); return () => clearInterval(timer); }, [load]);
  async function command(action: "save" | "check" | "activate" | "test") {
    if (!data || busy) return;
    setBusy(true); setError(""); setNotice("");
    try {
      const response = await fetch("/api/mail/settings", { method: "POST", headers: { "content-type": "application/json", ...(action === "test" ? { "idempotency-key": testKey } : {}) }, body: JSON.stringify({ command: action, expectedRevision: data.revision,
        ...(action === "save" ? { draft: { provider: "resend", fromName, fromEmail, replyTo } } : {}),
        ...(["check", "activate"].includes(action) ? { configId: (data.draft ?? data.active).id } : {}),
        ...(action === "activate" || action === "test" ? { confirmed: true } : {}), ...(action === "test" ? { recipient } : {}),
      }) });
      const body = await response.json();
      if (!response.ok) {
        if (response.status === 409) await load();
        throw new Error(body.error?.message ?? "De opdracht is niet uitgevoerd.");
      }
      if (action !== "test") setData(body.data);
      setNotice(action === "test" ? "Testmail in de bestaande mailwachtrij. Wacht op provideracceptatie en daarna op een geldige afleverwebhook." : action === "save" ? "Concept opgeslagen. De actieve configuratie is ongewijzigd." : action === "activate" ? "Resend is actief voor nieuwe verzendenveloppen." : body.data.checkResult?.ready ? "Afzenderdomein, runtimevoorziening en gateway gecontroleerd zonder verzending. Een concepttest bevestigt het werkelijke verzendrecht." : `Controle nog niet geslaagd: ${body.data.checkResult?.code ?? "credentials of gateway ontbreken"}.`);
      setDialog(null);
      await load(action !== "test");
    } catch (cause) { setError(cause instanceof Error ? cause.message : "De opdracht is niet uitgevoerd."); }
    finally { setBusy(false); }
  }
  return <section className="panel" aria-label="E-mail & koppelingen">
    <p className="kicker">E-mail & koppelingen{data ? ` · ${data.environment}` : ""}</p>
    <h2>De juiste boodschap, betrouwbaar verstuurd.</h2>
    <p>Inlogcodes, applicatiemails en ingeschakelde Nachtpost gebruiken dezelfde beveiligde mailgateway.</p>
    {error && <p className="form-notice" role="alert">{error}</p>}
    {notice && <p className="form-notice" role="status">{notice}</p>}
    {!data ? <button className="btn outline" onClick={() => void load()}>Opnieuw laden</button> : <>
      <div className="settings-grid">
        <article className="panel"><p className="kicker">Effectief actief · versie {data.active.version}</p><h3>{data.active.provider === "resend" ? "Resend" : "SendGrid · migratie"}</h3><p>{data.active.from_name} &lt;{data.active.from_email}&gt;</p><p>Antwoordadres: {data.active.reply_to}</p><small>Nieuwe pogingen gebruiken deze versie. Begonnen pogingen behouden hun provider en inhoud.</small></article>
        <article className="panel"><h3>API en configuratie</h3><p>{data.checkResult?.ready ? "Niet-verzendende configuratiecontrole geslaagd" : "Nog niet gereed of nog niet gecontroleerd"}</p><p>Laatste controle: {when(data.checkedAt)}</p><p>RESEND_API_KEY: {data.secrets.apiKey ? "aanwezig in serverruntime" : "ontbreekt"}</p><p>RESEND_WEBHOOK_SECRET: {data.secrets.webhookSecret ? "aanwezig in serverruntime" : "ontbreekt"}</p><p>Beheercredential voor domeincontrole: {data.secrets.administrationKey ? "aanwezig" : "ontbreekt"}</p><small>Alleen een geslaagde controle bevestigt ook de Edge-configuratie. Stel secrets via de beveiligde runtime/deploymentvoorziening voor deze omgeving in.</small></article>
        <article className="panel"><h3>Afleverwebhook</h3><p>{data.lastWebhookAt ? `Laatste geldig opgeslagen event: ${when(data.lastWebhookAt)}` : "Nog geen geldige events ontvangen; de koppeling is nog niet bevestigd."}</p><p className="mail-webhook-url">{data.webhookUrl}</p><button className="btn outline" onClick={() => void navigator.clipboard.writeText(data.webhookUrl).then(() => setNotice("Webhook-URL gekopieerd.")).catch(() => setError("Kopiëren is niet beschikbaar. Selecteer de URL."))}>Webhook-URL kopiëren</button><p>Vereiste events: {resendEvents.join(", ")}</p><small>Provisioning wordt beheerd via deployment. Een secret aanwezig hebben bewijst geen aflevering.</small></article>
        <article className="panel"><h3>Beleid voor {data.environment}</h3><p>Applicatiemail: {data.modes.mail} · Auth: {data.modes.auth}</p><p>Nachtpost: {data.modes.newsletterEnabled ? "ingeschakeld" : "uitgeschakeld"}</p><p>{data.modes.transactionalAllowlist.length} toegestane testontvangers · {data.modes.editorialAllowlist.length} redactionele testontvangers</p><p>SendGrid-blokkades: {data.suppressionsImportedAt ? `overname bevestigd op ${when(data.suppressionsImportedAt)}` : "Worden automatisch overgenomen bij deployment; nog niet afgerond"}</p><p>{data.legacyReconciliation} eerdere SendGrid-pogingen vereisen controle.</p></article>
      </div>
      <form className="panel" onSubmit={event => { event.preventDefault(); void command("save"); }}>
        <p className="kicker">{data.draft ? `Concept · versie ${data.draft.version}` : "Nieuw concept"}</p><h3>Afzender voor Resend</h3>
        <div className="settings-grid"><label>Afzendernaam<input required maxLength={120} value={fromName} onChange={e => setFromName(e.target.value)} /></label><label>Afzenderadres<input required type="email" value={fromEmail} onChange={e => setFromEmail(e.target.value)} /></label><label>Antwoordadres<input required type="email" value={replyTo} onChange={e => setReplyTo(e.target.value)} /></label></div>
        <p>Concepttest: {data.draftTestVerified ? "afgeleverd en met de huidige webhook bevestigd" : "nog niet bevestigd met de huidige credentials"}.</p><p>Het afzenderdomein moet geverifieerd zijn. Open- en kliktracking blijven uit. Opslaan wijzigt uitsluitend het concept.</p>
        <div className="actions"><button disabled={busy} className="btn outline" type="submit">Concept opslaan</button><button disabled={busy || (data.draft ?? data.active).provider !== "resend"} className="btn outline" type="button" onClick={() => void command("check")}>Controle uitvoeren zonder verzending</button><button disabled={busy || !data.draft || !data.checkResult?.ready || data.checkedId !== data.draft?.id || !data.suppressionsImportedAt || !data.draftTestVerified} className="btn" type="button" onClick={() => setDialog("activate")}>Resend activeren</button></div>
      </form>
      <article className="panel"><h3>Bewuste testverzending</h3><p>Laatste test: {data.lastTest ? `${when(data.lastTest.at)} · ${deliveryLabels[data.lastTest.deliveryStatus === "pending" ? data.lastTest.status : data.lastTest.deliveryStatus] ?? data.lastTest.status}${data.lastTest.code ? ` · ${data.lastTest.code}` : ""}` : "nog geen testverzending geregistreerd"}</p>{data.lastTest?.simulated && <p>Deze laatste test simuleert een provideruitkomst en bewijst geen echte postbusontvangst.</p>}{data.lastTest && data.lastTest.configId !== (data.draft ?? data.active).id && <p>De laatste test hoort bij een andere configuratieversie.</p>}<p>Een test gebruikt de bestaande wachtrij en het gecontroleerde concept, of anders de actieve configuratie. Activering vereist eerst een door webhook bevestigde concepttest. Provider-testadressen simuleren een uitkomst en bewijzen geen ontvangst in een echte postbus.</p><button className="btn outline" disabled={busy || (data.draft ?? data.active).provider !== "resend" || (Boolean(data.draft) && !data.checkResult?.ready) || !data.modes.testRecipients.length} onClick={() => { setRecipient(data.modes.testRecipients[0] ?? ""); setTestKey(crypto.randomUUID()); setDialog("test"); }}>Testmail voorbereiden</button></article>
      <article className="panel"><h3>Recente verzendingen</h3><p>Afgeleverd betekent ontvangst bij de mailserver; geen leesbevestiging. Auth-inhoud en ontvangergegevens worden hier niet getoond.</p><div className="table-wrap overflow-x-auto"><table><thead><tr><th>Tijd</th><th>Kanaal / type</th><th>Provider</th><th>Status</th><th>Correlatie</th></tr></thead><tbody>{data.attempts.map(item => <tr key={item.id}><td>{when(item.first_attempt_at)}</td><td>{item.channel} · {item.message_type}</td><td>{item.provider}</td><td>{deliveryLabels[item.delivery_status === "pending" ? item.status : item.delivery_status] ?? item.status}{item.error_code && <small> · {item.error_code}</small>}</td><td><small>{item.provider_id ?? item.id}</small></td></tr>)}</tbody></table></div>{!data.attempts.length && <p>Nog geen verzendingen geregistreerd.</p>}</article>
      <article className="panel"><h3>Recent eventlog</h3><div className="table-wrap overflow-x-auto"><table><thead><tr><th>Tijd</th><th>Provider / event</th><th>Provider-ID</th><th>Diagnose</th></tr></thead><tbody>{data.events.map(item => <tr key={`${item.provider}/${item.provider_event_id}`}><td>{when(item.occurred_at)}</td><td>{item.channel ?? "historie / ongekoppeld"} · {item.message_type ?? item.kind}<small> · {item.provider} · {item.kind}</small></td><td><small>{item.provider_message_id ?? "Historisch event"}</small></td><td>{item.safe_code ?? "—"}</td></tr>)}</tbody></table></div></article>
      <Dialog open={dialog !== null} onOpenChange={open => { if (!open && !busy) setDialog(null); }}><DialogContent><DialogTitle>{dialog === "activate" ? "Resend activeren?" : "Testmail versturen?"}</DialogTitle><DialogDescription>{dialog === "activate" ? `Nieuwe verzendingen voor inlogcodes, applicatiemails en ingeschakelde Nachtpost gebruiken Resend via Supabase. Bestaande SendGrid-verzendingen en hun afleverhistorie blijven behouden. Er worden nu geen bestaande berichten opnieuw verstuurd. Configuratieversie ${data.draft?.version}; de server herhaalt de controles.` : "Kies een toegestane ontvanger. Deze opdracht verstuurt daadwerkelijk één testmail via de bestaande mailworker."}</DialogDescription>
        {dialog === "test" && <><label>Ontvanger en testscenario<select value={recipient} onChange={e => setRecipient(e.target.value)}>{data.modes.testRecipients.map(email => <option key={email} value={email}>{email}{/@resend\.dev$/i.test(email) ? " · gesimuleerde provideruitkomst" : " · echte postbus"}</option>)}</select></label><p>Scenario: {/@resend\.dev$/i.test(recipient) ? "gesimuleerde provideruitkomst" : "echte postbusontvangst controleren"}</p><p>Onderwerp: De Poorten · gecontroleerde testmail</p></>}
        <div className="actions"><button disabled={busy} className="btn outline" onClick={() => setDialog(null)}>Annuleren</button><button disabled={busy} className="btn" onClick={() => void command(dialog === "activate" ? "activate" : "test")}>{busy ? "Bezig…" : dialog === "activate" ? "Bevestigen en activeren" : "Testmail versturen"}</button></div>
      </DialogContent></Dialog>
    </>}
  </section>;
}

export function SettingsTabs({ children }: { children: React.ReactNode }) {
  const [tab, setTab] = useState("event");
  useEffect(() => {
    const sync = () => setTab(new URLSearchParams(window.location.search).get("settingsTab") === "email" ? "email" : "event");
    sync(); window.addEventListener("popstate", sync); return () => window.removeEventListener("popstate", sync);
  }, []);
  function select(next: string) {
    setTab(next); const url = new URL(window.location.href); url.searchParams.set("settingsTab", next); history.pushState(null, "", url);
  }
  return <><nav className="modern-admin-subnav" aria-label="Instellingen"><button className={tab === "event" ? "active" : ""} aria-current={tab === "event" ? "page" : undefined} onClick={() => select("event")}>Evenementinstellingen</button><button className={tab === "email" ? "active" : ""} aria-current={tab === "email" ? "page" : undefined} onClick={() => select("email")}>E-mail & koppelingen</button></nav>{tab === "email" ? <EmailSettings /> : children}</>;
}
