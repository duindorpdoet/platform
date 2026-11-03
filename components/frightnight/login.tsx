"use client";
import { useState } from "react";
import Link from "next/link";
import { KeyRound, ShieldCheck } from "lucide-react";
import { EmailOtpForm } from "@/components/auth/email-otp-form";
import { GoogleAuthButton } from "@/components/auth/google-auth-button";
import { WorkspaceHeader } from "./shared";

export function FestivalLogin({ destination, googleAvailable, error }: { destination: string; googleAvailable: boolean | null; error?: string }) {
  const [remember, setRemember] = useState(true);
  const [busy, setBusy] = useState(false);
  return <div className="theme theme-poster"><WorkspaceHeader title="JOUW NACHT BEGINT HIER" /><main id="main-content" className="fn-login"><section className="fn-login-art"><img src="/frightnight/king-head.webp" alt="De Pompoenkoning" /><span className="ui-kicker">30 oktober 2027 · Duindorp</span><h1>DE NACHT<br />IS VAN ONS.</h1><p>Jouw gezin. Jouw avontuur. Jouw Nachtpas.</p></section><section className="fn-panel fn-login-form"><KeyRound size={30} /><span className="ui-kicker">Welkom bij FrightNight</span><h2>OPEN JOUW NACHTPAS.</h2><p>Log in met een eenmalige e-mailcode. Je hebt geen wachtwoord nodig.</p>{error && <p className="fn-error" role="alert">De vorige aanmelding kon niet worden bevestigd. Vraag een nieuwe code aan.</p>}<EmailOtpForm nextPath={destination} variant="entry" rememberSession={remember} onRememberChange={setRemember} authBusy={busy} alternativeAuth={disabled => <GoogleAuthButton destination={destination} available={googleAvailable} remember={remember} disabled={disabled} onBusyChange={setBusy} />} /><p className="fn-caption"><ShieldCheck size={15} /> Alleen als jij een code aanvraagt, versturen we een inlogmail. Kinderen hebben geen eigen account nodig.</p><Link href="/">Terug naar het festival</Link></section></main></div>;
}
