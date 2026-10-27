"use client";
import Link from "next/link";
import { useState } from "react";
import { ArrowLeft, BookOpen, DoorOpen, KeyRound, ShieldCheck, Users } from "lucide-react";
import {GoogleAuthButton} from "./google-auth-button";
import { EmailOtpForm } from "./email-otp-form";

export function EntryHeader() {
  return <header className="entry-header"><Link href="/" aria-label="Naar de website"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" /></Link><Link href="/"><ArrowLeft size={15} />Naar de website</Link></header>;
}
export function AccountLogin({ destination, error, googleAvailable }: { destination: string; error?: string; googleAvailable: boolean | null }) {
  const [remember, setRemember] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState(error === "google_cancelled" ? "De Google-aanmelding is geannuleerd of toestemming is geweigerd. Je kunt opnieuw kiezen of een e-mailcode gebruiken." : error ? "Deze aanmelding is verlopen of kon niet worden bevestigd. Probeer opnieuw; e-mailcode blijft beschikbaar." : "");
  return <div className="entry-page"><EntryHeader /><main className="entry-login-layout">
    <section className="entry-story"><div className="entry-story-image" /><div className="entry-story-copy"><p className="entry-kicker"><span />31 oktober · Duindorp</p><h1>Eén nacht.<br />Duizend verhalen.<br /><em>Jouw avontuur.</em></h1><p>Van je eigen voordeur tot de laatste poort.<br />Alles voor jullie Halloweenavond op één plek.</p><div className="entry-story-detail"><span><Users size={17} />Jouw groep</span><span><DoorOpen size={17} />Jouw poort</span><span><BookOpen size={17} />Hun avontuur</span></div></div></section>
    <section className="entry-login-panel"><div className="entry-form-card"><span className="entry-small-icon"><KeyRound size={24} /></span><p className="entry-kicker">Welkom bij De Poorten</p><h2>De deur staat open.</h2><p className="entry-intro">Log veilig in en kies daarna jouw omgeving.<br />Een wachtwoord is niet nodig.</p>
      {notice && <p className="entry-error" role="alert">{notice}</p>}
      <EmailOtpForm nextPath={destination} variant="entry" rememberSession={remember} onRememberChange={setRemember} authBusy={busy} alternativeAuth={disabled=><GoogleAuthButton destination={destination} available={googleAvailable} remember={remember} disabled={disabled} onBusyChange={setBusy} onStart={()=>setNotice('')}/>} />
      <p className="entry-safe-note"><ShieldCheck size={14} />Gebruik het e-mailadres van je aanmelding.</p>
      <p className="entry-login-footer">Op een gedeeld apparaat kun je ‘Ingelogd blijven’ uitzetten. Log na afloop uit.<br />Voor je kind is geen eigen e-mailadres nodig.</p>
      <Link className="device-text-button" href="/poortenboek/inloggen">Ik heb een persoonlijke boekcode</Link>
    </div></section>
  </main></div>;
}
