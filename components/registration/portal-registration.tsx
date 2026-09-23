"use client";

import { useState } from "react";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { PortalWizard } from "./portal-wizard";
import { createClient } from "@/lib/supabase/client";

export function PortalRegistration({ eventSlug, email, hasApplication }: { eventSlug: string; email?: string; hasApplication: boolean }) {
  const [details, setDetails] = useState({ contactName: "", phone: "", address: { street: "", houseNumber: "", addition: "", postalCode: "" } });
  const [confirmed, setConfirmed] = useState(Boolean(email));
  const [ready, setReady] = useState(hasApplication);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  async function register() {
    setConfirmed(true); setBusy(true); setNotice("");
    try {
      const client = createClient();
      if (!client) throw new Error("unavailable");
      const { data: user, error: userError } = await client.auth.getUser();
      if (userError || !user.user?.email_confirmed_at) throw new Error("unverified");
      const snapshot = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug });
      if (snapshot.error) throw snapshot.error;
      // A returning resident continues their existing application without replacing it.
      if (!snapshot.data?.application) {
        const result = await client.schema("api").rpc("portal_application_save", {
          _event_slug: eventSlug,
          _payload: { ...details, email: user.user.email },
          _expected_version: null,
        });
        if (result.error) throw result.error;
      }
      setReady(true);
    } catch {
      setNotice("Je e-mailadres is bevestigd, maar de plek kon niet worden opgeslagen. Je gegevens staan nog hieronder. Probeer opnieuw.");
    } finally { setBusy(false); }
  }

  if (ready) return <PortalWizard eventSlug={eventSlug} />;

  const fields = <fieldset className="form-fieldset" disabled={busy}>
    <label className="field"><span>Naam contactpersoon *</span><input required minLength={2} maxLength={120} autoComplete="name" value={details.contactName} onChange={(event) => setDetails({ ...details, contactName: event.target.value })} /></label>
    <label className="field"><span>Telefoonnummer *</span><input required type="tel" minLength={6} maxLength={30} autoComplete="tel" value={details.phone} onChange={(event) => setDetails({ ...details, phone: event.target.value })} /></label>
    <div className="two-fields"><label className="field"><span>Straat *</span><input required maxLength={120} autoComplete="address-line1" value={details.address.street} onChange={(event) => setDetails({ ...details, address: { ...details.address, street: event.target.value } })} /></label><label className="field"><span>Huisnummer *</span><input required maxLength={12} value={details.address.houseNumber} onChange={(event) => setDetails({ ...details, address: { ...details.address, houseNumber: event.target.value } })} /></label></div>
    <div className="two-fields"><label className="field"><span>Toevoeging</span><input maxLength={12} value={details.address.addition} onChange={(event) => setDetails({ ...details, address: { ...details.address, addition: event.target.value } })} /></label><label className="field"><span>Postcode *</span><input required pattern="[0-9]{4} ?[A-Za-z]{2}" autoComplete="postal-code" value={details.address.postalCode} onChange={(event) => setDetails({ ...details, address: { ...details.address, postalCode: event.target.value.toUpperCase() } })} /></label></div>
    <p className="note">Je adres en contactgegevens zijn alleen beschikbaar voor de organisatie en je eigen aanmelding.</p>
  </fieldset>;

  if (!confirmed) return <EmailOtpForm onVerified={register}>{fields}</EmailOtpForm>;
  return <form className="panel production-form" onSubmit={(event) => { event.preventDefault(); void register(); }}>
    <h2>Meld jullie plek aan</h2>
    <p>Je e-mailadres is bevestigd{email ? `: ${email}` : ""}. Vul je naam, telefoonnummer en adres in om verder te gaan.</p>
    {fields}
    {notice && <p className="form-error" role="alert">{notice}</p>}
    <button className="btn full" disabled={busy}>{busy ? "Plek opslaan…" : "Verder met jullie idee"}</button>
  </form>;
}
