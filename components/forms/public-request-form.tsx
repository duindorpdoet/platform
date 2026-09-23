"use client";

import { useRef, useState } from "react";

type Mode = "contact" | "sponsor";

export function PublicRequestForm({ mode }: { mode: Mode }) {
  const startedAt = useRef<number | null>(null);
  const [status, setStatus] = useState<"idle" | "sending" | "done" | "error">("idle");
  const [message, setMessage] = useState("");

  async function submit(formData: FormData) {
    setStatus("sending");
    setMessage("");
    const common = { name: String(formData.get("name") ?? ""), email: String(formData.get("email") ?? ""), website: String(formData.get("website") ?? ""), startedAt: startedAt.current ?? Date.now() - 2_000 };
    const payload = mode === "contact"
      ? { ...common, subject: String(formData.get("subject") ?? ""), body: String(formData.get("body") ?? "") }
      : { ...common, contributionType: String(formData.get("contributionType") ?? "anders"), amountEuros: Number(formData.get("amountEuros") ?? 0), message: String(formData.get("message") ?? "") };
    try {
      const response = await fetch(`/api/public/${mode}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error?.message ?? "Verzenden mislukt.");
      setStatus("done");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Verzenden mislukt.");
      setStatus("error");
    }
  }

  if (status === "done") return <div className="panel form-success" role="status"><h2>Bedankt!</h2><p>We hebben je {mode === "contact" ? "bericht" : "voorstel"} ontvangen. We lezen het rustig na en nemen contact op als dat nodig is.</p></div>;
  return (
    <form className="panel production-form" action={submit} onFocusCapture={() => { startedAt.current ??= Date.now(); }}>
      <label className="field"><span>Naam</span><input name="name" required maxLength={120} autoComplete="name" /></label>
      <label className="field"><span>E-mailadres</span><input name="email" type="email" required autoComplete="email" /></label>
      <label className="honeypot" aria-hidden="true">Website<input name="website" tabIndex={-1} autoComplete="off" /></label>
      {mode === "contact" ? <>
        <label className="field"><span>Onderwerp</span><input name="subject" required minLength={3} maxLength={160} /></label>
        <label className="field"><span>Bericht</span><textarea name="body" required minLength={3} maxLength={4000} rows={7} /></label>
      </> : <>
        <label className="field"><span>Soort bijdrage</span><select name="contributionType" defaultValue="geld"><option value="geld">Financieel</option><option value="materiaal">Materiaal</option><option value="dienst">Dienst of expertise</option><option value="anders">Anders</option></select></label>
        <label className="field"><span>Voorgesteld bedrag in euro’s (optioneel)</span><input name="amountEuros" type="number" min={0} max={100000} defaultValue={0} /></label>
        <label className="field"><span>Toelichting</span><textarea name="message" maxLength={4000} rows={7} /></label>
      </>}
      {status === "error" && <p className="form-error" role="alert">{message}</p>}
      <button className="btn" disabled={status === "sending"}>{status === "sending" ? "Veilig verzenden…" : "Versturen"}</button>
      <p className="note">We gebruiken deze gegevens alleen om je aanvraag af te handelen. Verstuur geen medische of andere gevoelige informatie.</p>
    </form>
  );
}
