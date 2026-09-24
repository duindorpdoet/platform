"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { createClient } from "@/lib/supabase/client";

export function PortalRegistration({ eventSlug, email, hasApplication }: { eventSlug: string; email?: string; hasApplication: boolean }) {
  const router = useRouter();
  const [details, setDetails] = useState({ contactName: "", phone: "" });
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [startedAt] = useState(() => Date.now());

  async function saveConfirmedApplication() {
    setBusy(true); setNotice("");
    try {
      const client = createClient();
      if (!client) throw new Error("unavailable");
      const { data: user, error: userError } = await client.auth.getUser();
      if (userError || !user.user?.email_confirmed_at) throw new Error("unverified");
      const result = await client.schema("api").rpc("portal_application_save", {
        _event_slug: eventSlug,
        _payload: { ...details, email: user.user.email },
        _expected_version: null,
      });
      if (result.error) throw result.error;
      router.replace("/mijn-huis");
      router.refresh();
    } catch (error) {
      setNotice(error instanceof Error && error.message.includes("PORTAL_REGISTRATION_CLOSED")
        ? "De organisatie heeft nieuwe locatieaanmeldingen zojuist gepauzeerd. Je gegevens staan nog hieronder."
        : "Je e-mailadres is bevestigd, maar de plek kon niet worden opgeslagen. Je gegevens staan nog hieronder. Probeer opnieuw.");
    } finally { setBusy(false); }
  }

  async function saveIntake(normalizedEmail: string) {
    const response = await fetch("/api/public/portal-registration", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: normalizedEmail, ...details, website: "", startedAt }),
    });
    if (!response.ok) {
      const body = await response.json().catch(() => null) as { error?: { code?: string } } | null;
      if (body?.error?.code === "PORTAL_REGISTRATION_CLOSED") throw new Error("PORTAL_REGISTRATION_CLOSED");
      throw new Error("PORTAL_INTAKE_FAILED");
    }
  }

  async function claimAfterVerification() {
    const client = createClient();
    if (!client) throw new Error("unavailable");
    const { error } = await client.schema("api").rpc("portal_registration_claim", { _event_slug: eventSlug });
    if (error) throw error;
    router.replace("/mijn-huis");
    router.refresh();
  }

  if (hasApplication) return <div className="panel"><h2>Jullie plek is al aangemeld</h2><p>Er wordt geen tweede huis gemaakt. Bekijk en bewerk de bestaande gegevens in Mijn huis.</p><button className="btn" onClick={() => router.replace("/mijn-huis")}>Naar Mijn huis</button></div>;

  const fields = <fieldset className="form-fieldset" disabled={busy}>
    <label className="field"><span>Naam contactpersoon *</span><input required minLength={2} maxLength={120} autoComplete="name" value={details.contactName} onChange={(event) => setDetails({ ...details, contactName: event.target.value })} /></label>
    <label className="field"><span>Telefoonnummer *</span><input required type="tel" minLength={6} maxLength={30} autoComplete="tel" value={details.phone} onChange={(event) => setDetails({ ...details, phone: event.target.value })} /></label>
    <p className="note">Na bevestiging vul je in Mijn huis desgewenst het adres, de aankleding en andere praktische gegevens aan.</p>
  </fieldset>;

  if (!email) return <EmailOtpForm beforeRequestCode={saveIntake} onVerified={claimAfterVerification}>{fields}</EmailOtpForm>;
  return <form className="panel production-form" onSubmit={(event) => { event.preventDefault(); void saveConfirmedApplication(); }}>
    <h2>Meld jullie plek aan</h2>
    <p>Je e-mailadres is bevestigd{email ? `: ${email}` : ""}. Vul je naam en telefoonnummer in om verder te gaan.</p>
    {fields}
    {notice && <p className="form-error" role="alert">{notice}</p>}
    <button className="btn full" disabled={busy}>{busy ? "Plek opslaan…" : "Plek aanmelden"}</button>
  </form>;
}
