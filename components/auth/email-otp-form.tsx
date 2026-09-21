"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRight, CheckCircle2, Mail, RotateCcw } from "lucide-react";
import { InputOTP, InputOTPGroup, InputOTPSlot } from "@/components/ui/input-otp";
import { createClient } from "@/lib/supabase/client";
import { safeReturnPath } from "@/lib/auth/redirect";

const COOLDOWN_SECONDS = 60;

export function EmailOtpForm({ nextPath }: { nextPath?: string }) {
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
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { shouldCreateUser: true },
    });
    setBusy(false);
    setCooldown(COOLDOWN_SECONDS);
    if (error) {
      setMessage("De code kon nu niet worden aangevraagd. Wacht even en probeer het opnieuw.");
      return;
    }
    setStage("code");
    setMessage("Als dit adres e-mail kan ontvangen, staat er zo een eenmalige code klaar.");
  }

  async function verifyCode(event: FormEvent) {
    event.preventDefault();
    const supabase = createClient();
    if (!supabase) return;
    setBusy(true);
    setMessage(undefined);
    const { error } = await supabase.auth.verifyOtp({ email: email.trim().toLowerCase(), token: otp, type: "email" });
    setBusy(false);
    if (error) {
      setMessage("Deze code is onjuist of verlopen. Vraag zo nodig een nieuwe code aan.");
      return;
    }
    router.replace(destination);
    router.refresh();
  }

  if (stage === "email") {
    return (
      <form className="panel auth-form" onSubmit={requestCode} noValidate>
        <Mail size={32} />
        <h2>Ontvang je inlogcode.</h2>
        <p>We sturen een eenmalige code via e-mail. Er is geen wachtwoord en er bestaat geen universele democode.</p>
        <label className="field"><span>E-mailadres</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" required /></label>
        {message && <p className="form-error" role="alert">{message}</p>}
        <button className="btn full" type="submit" disabled={busy || !email.includes("@")}>{busy ? "Code aanvragen…" : "Stuur eenmalige code"}<ArrowRight size={17} /></button>
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
      <button className="btn full" type="submit" disabled={busy || otp.length !== 6}>{busy ? "Code controleren…" : "Inloggen"}<ArrowRight size={17} /></button>
      <button className="text-link" type="button" disabled={cooldown > 0 || busy} onClick={() => void requestCode()}><RotateCcw size={15} />{cooldown ? `Nieuwe code over ${cooldown}s` : "Nieuwe code aanvragen"}</button>
      <button className="text-link" type="button" onClick={() => { setStage("email"); setOtp(""); setMessage(undefined); }}>Ander e-mailadres</button>
    </form>
  );
}
