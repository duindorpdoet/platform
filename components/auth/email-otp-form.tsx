"use client";

import { FormEvent, ReactNode, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRight, CheckCircle2, Mail, RotateCcw } from "lucide-react";
import { InputOTP, InputOTPGroup, InputOTPSlot } from "@/components/ui/input-otp";
import { createClient } from "@/lib/supabase/client";
import { safeReturnPath } from "@/lib/auth/redirect";

const COOLDOWN_SECONDS = 60;

export function EmailOtpForm({ nextPath, children, onVerified }: { nextPath?: string; children?: ReactNode; onVerified?: () => Promise<void> }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [otp, setOtp] = useState("");
  const [stage, setStage] = useState<"email" | "code">("email");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const [cooldown, setCooldown] = useState(0);
  const destination = safeReturnPath(nextPath);

  useEffect(() => {
    if (!cooldown) return;
    const timer = window.setInterval(() => setCooldown((value) => Math.max(0, value - 1)), 1_000);
    return () => window.clearInterval(timer);
  }, [cooldown]);

  async function requestCode(event?: FormEvent) {
    event?.preventDefault();
    if (cooldown || busy) return;
    const supabase = createClient();
    if (!supabase) {
      setMessage("Inloggen is in deze omgeving nog niet gekoppeld. De organisatie is hiervan op de hoogte.");
      return;
    }
    setBusy(true);
    setMessage(undefined);
    try {
      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim().toLowerCase(),
        options: { shouldCreateUser: true },
      });

      setCooldown(COOLDOWN_SECONDS);
      if (error) {
        setMessage(error.status === 429 ? "Je hebt te snel of te vaak een code aangevraagd. Wacht even en probeer het opnieuw." : "De e-maildienst kon geen code versturen. Probeer het later opnieuw of neem contact op met de organisatie.");
        return;
      }
      setStage("code");
      setMessage("Als dit adres e-mail kan ontvangen, staat er zo een eenmalige code klaar.");
    } catch {
      setMessage("Geen verbinding met de e-maildienst. Controleer je internetverbinding en probeer opnieuw.");
    } finally { setBusy(false); }
  }

  async function verifyCode(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    const supabase = createClient();
    if (!supabase) return;
    setBusy(true);
    setMessage(undefined);
    try {
      const { error } = await supabase.auth.verifyOtp({ email: email.trim().toLowerCase(), token: otp, type: "email" });

      if (error) {
        setMessage("Deze code is onjuist of verlopen. Vraag zo nodig een nieuwe code aan.");
        return;
      }
      if (onVerified) { await onVerified(); return; }
      router.replace(destination);
      router.refresh();
    } catch {
      setMessage("De bevestiging is niet gelukt. Controleer je verbinding en probeer opnieuw.");
    } finally { setBusy(false); }
  }

  if (stage === "email") {
    return (
      <form className="panel auth-form" onSubmit={requestCode}>
        <Mail size={32} />
        <h2>{children ? "Meld je huis aan" : "Ontvang je inlogcode."}</h2>
        <p>{children ? "Vul je contactgegevens en adres in. Bevestig daarna je e-mailadres met een code; vervolgens kun je de details van je huis toevoegen." : "We sturen een eenmalige code via e-mail. Er is geen wachtwoord en er bestaat geen universele democode."}</p>
        <label className="field"><span>E-mailadres</span><input type="email" disabled={busy} value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" required /></label>
        {children}
        {message && <p className="form-error" role="alert">{message}</p>}
        <button className="btn full" type="submit" disabled={busy || cooldown > 0 || !email.includes("@")}>{busy ? "Code aanvragen…" : cooldown ? `Nieuwe code over ${cooldown}s` : "Stuur eenmalige code"}<ArrowRight size={17} /></button>
      </form>
    );
  }

  return (
    <form className="panel auth-form" onSubmit={verifyCode}>
      <CheckCircle2 size={32} />
      <h2>Vul de zes cijfers in.</h2>
      <p>De code is verstuurd naar <strong>{email}</strong>. Plakken mag.</p>
      <InputOTP maxLength={6} value={otp} onChange={setOtp} inputMode="numeric" autoComplete="one-time-code">
        <InputOTPGroup>{Array.from({ length: 6 }, (_, index) => <InputOTPSlot key={index} index={index} />)}</InputOTPGroup>
      </InputOTP>
      {message && <p className={message.startsWith("Als") ? "note" : "form-error"} role="status">{message}</p>}
      <button className="btn full" type="submit" disabled={busy || otp.length !== 6}>{busy ? "Code controleren…" : onVerified ? "Bevestigen en verder" : "Inloggen"}<ArrowRight size={17} /></button>
      <button className="text-link" type="button" disabled={cooldown > 0 || busy} onClick={() => void requestCode()}><RotateCcw size={15} />{cooldown ? `Nieuwe code over ${cooldown}s` : "Nieuwe code aanvragen"}</button>
      <button className="text-link" type="button" disabled={busy} onClick={() => { setStage("email"); setOtp(""); setMessage(undefined); }}>Ander e-mailadres</button>
    </form>
  );
}
