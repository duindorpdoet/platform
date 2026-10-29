"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { GoogleAuthButton } from "@/components/auth/google-auth-button";
import { createClient } from "@/lib/supabase/client";
import { registrationActivationMessage, registrationActivationReturnPath } from "@/lib/auth/registration-activation";

export function RegistrationActivation({ token, verified, googleAvailable }: {
  token: string; verified: boolean; googleAvailable: boolean | null;
}) {
  const [busy, setBusy] = useState(false);
  const [oauthBusy, setOauthBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [expired, setExpired] = useState(false);
  const [activated, setActivated] = useState(false);
  const [renewed, setRenewed] = useState(false);
  const automaticAttempted = useRef(false);
  const pending = useRef(false);
  const claimCommands = useRef<Partial<Record<"fresh" | "explicit", string>>>({});
  const renewalCommand = useRef<string | null>(null);
  const destination = registrationActivationReturnPath(token);

  const claim = useCallback(async (mode: "fresh" | "explicit") => {
    if (pending.current) return;
    const client = createClient();
    if (!client) { setNotice("De aanmelding is tijdelijk niet bereikbaar. Probeer het later opnieuw."); return; }
    pending.current = true;
    setBusy(true);
    setNotice("");
    const commandId = claimCommands.current[mode] ??= crypto.randomUUID();
    try {
      const result = await client.schema("api").rpc("registration_activation_claim", {
        _token: token, _command_id: commandId, _mode: mode,
      });
      if (result.error || !result.data?.activated) {
        setExpired(result.error?.message === "INVITATION_EXPIRED");
        setNotice(registrationActivationMessage(result.error?.message));
        return;
      }
      setActivated(true);
    } catch { setNotice("De bevestiging kon niet worden opgehaald. Probeer het opnieuw; jullie gegevens blijven bewaard."); }
    finally { pending.current = false; setBusy(false); }
  }, [token]);

  // Only an explicit verified-login return can trigger the fresh-session mode.
  // PostgreSQL validates the real Auth session; query parameters prove no identity.
  useEffect(() => {
    if (!verified || automaticAttempted.current) return;
    automaticAttempted.current = true;
    void claim("fresh");
  }, [verified, claim]);

  async function renew() {
    if (pending.current) return;
    const client = createClient();
    if (!client) return;
    pending.current = true; setBusy(true); setNotice("");
    renewalCommand.current ??= crypto.randomUUID();
    try {
      const result = await client.schema("api").rpc("registration_activation_renew", { _token: token, _command_id: renewalCommand.current });
      if (result.error || !result.data?.queued) { setNotice(registrationActivationMessage(result.error?.message)); return; }
      setRenewed(true);
    } catch { setNotice("Een nieuwe uitnodiging aanvragen is nog niet gelukt. Probeer het opnieuw."); }
    finally { pending.current = false; setBusy(false); }
  }

  return <main className="page wrap"><section className="panel auth-required">
    <p className="kicker">Jullie inschrijving · Halloween</p>
    {activated ? <><h1>Jullie inschrijving is geactiveerd.</h1><p>De organisatie heeft jullie ouder- en kindgegevens al vastgelegd. Bekijk jullie inschrijving en eventuele groepsafspraak in je eigen omgeving.</p><div className="actions"><Link className="btn" href="/mijn-inschrijving">Bekijk mijn inschrijving</Link><Link className="btn outline" href="/omgeving/kiezen">Mijn omgevingen</Link></div></>
      : renewed ? <><h1>Nieuwe uitnodiging aangevraagd.</h1><p>Jullie inschrijving en kinderen zijn bewaard. Gebruik de nieuwste uitnodiging in je e-mail om verder te gaan.</p><Link className="btn outline" href="/inloggen">Naar inloggen</Link></>
      : <><h1>Bevestig jullie inschrijving.</h1><p>De organisatie heeft jou en je kinderen aangemeld. Log in met het e-mailadres waarop je deze persoonlijke uitnodiging ontving. Je hoeft het inschrijfformulier niet opnieuw in te vullen.</p>
        <EmailOtpForm onVerified={() => claim("fresh")} nextPath={destination} authBusy={busy || oauthBusy}
          alternativeAuth={disabled => <GoogleAuthButton destination={destination} available={googleAvailable} disabled={disabled || busy} onBusyChange={setOauthBusy} />} />
        <div className="panel"><p>Al ingelogd met het uitgenodigde e-mailadres?</p><button className="btn" disabled={busy || oauthBusy} onClick={() => void claim("explicit")}>{busy ? "Uitnodiging controleren…" : "Deze inschrijving activeren"}</button>
          {expired && <button className="btn outline" disabled={busy || oauthBusy} onClick={() => void renew()}>Nieuwe uitnodiging aanvragen</button>}
        </div>
        {notice && <p className="form-error" role="alert">{notice}</p>}
      </>}
  </section></main>;
}
