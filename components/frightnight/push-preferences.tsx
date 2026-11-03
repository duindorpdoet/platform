"use client";
import { useEffect, useState } from "react";
import { Bell, BellOff } from "lucide-react";
import type { FestivalController } from "./client";
type PushConfig = { available: boolean; key?: string; delivery?: string; message?: string };
function vapidBytes(value: string) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  const raw = atob(base64 + "=".repeat((4 - base64.length % 4) % 4));
  return Uint8Array.from(raw, character => character.charCodeAt(0));
}
export function PushPreferences({ controller: c }: { controller: FestivalController }) {
  const [config, setConfig] = useState<PushConfig | null>(null);
  const [supported, setSupported] = useState(false); const [consent, setConsent] = useState(false); const [busy, setBusy] = useState(false); const [message, setMessage] = useState("");
  useEffect(() => {
    const abort = new AbortController();
    const available = "Notification" in window && "PushManager" in window && "serviceWorker" in navigator;
    const timer = setTimeout(() => { setSupported(available); }, 0);
    void fetch("/api/frightnight/push/public-key", { cache: "no-store", signal: abort.signal }).then(async response => { if (response.ok) { const body = await response.json(); setConfig(body.data ?? body); } }).catch(() => {});
    return () => { clearTimeout(timer); abort.abort(); };
  }, []);
  async function enable() {
    if (!consent || !supported || !config?.available || !config.key) return;
    setBusy(true); setMessage("");
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") { setMessage("Meldingen zijn niet toegestaan. Je Nachtpas en alle routefuncties blijven beschikbaar."); return; }
      let registration = await navigator.serviceWorker.getRegistration("/");
      if (!registration) registration = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
      await Promise.race([navigator.serviceWorker.ready, new Promise<never>((_, reject) => setTimeout(() => reject(new Error("Het meldingenonderdeel is nog niet klaar. Probeer later opnieuw.")), 8000))]);
      const subscription = await registration.pushManager.getSubscription() ?? await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapidBytes(config.key) });
      const json = subscription.toJSON();
      const result = await c.command("push.subscribe", { endpoint: subscription.endpoint, keys: json.keys, consent: true });
      if (!result) { await subscription.unsubscribe(); setMessage("Er is geen serverbevestiging. Meldingen zijn voor deze browser niet ingeschakeld."); }
      else setMessage("Je toestemming en abonnement zijn veilig bewaard. Op staging is geen externe pushbezorging actief.");
    } catch (cause) { setMessage(cause instanceof Error ? cause.message : "Meldingen konden niet worden ingesteld. Je route blijft gewoon bruikbaar."); }
    finally { setBusy(false); }
  }
  async function disable() {
    setBusy(true); setMessage("");
    try {
      const result = await c.command("push.unsubscribe");
      const registration = await navigator.serviceWorker.getRegistration("/");
      await (await registration?.pushManager.getSubscription())?.unsubscribe();
      setMessage(result ? "Meldingen voor deze editie zijn uitgeschakeld." : "Deze browser is uitgeschakeld. Herstel de verbinding om je keuze ook op de server te bevestigen.");
    } catch { setMessage("De keuze kon niet volledig worden bevestigd. Probeer na herstel opnieuw."); }
    finally { setBusy(false); }
  }
  return <section className="fn-panel"><Bell size={26} /><h2>MELDINGEN OP JOUW MANIER.</h2><p>Je persoonlijke berichten blijven altijd in de Nachtpas beschikbaar. Push is vrijwillig en nooit nodig om te lopen.</p><p className="fn-caption">{config?.message ?? "We controleren of meldingen veilig beschikbaar zijn."} Op staging is er geen externe pushbezorging actief.</p>{!supported && <p>Deze browser biedt hier geen push aan. Je vindt nieuwe berichten gewoon onder Hulp.</p>}{c.snapshot?.pushEnabled ? <button className="ui-button" disabled={busy || c.busy} onClick={() => void disable()}><BellOff size={17} /> Meldingen voor deze editie uitschakelen</button> : <><label className="fn-check"><input type="checkbox" checked={consent} onChange={event => setConsent(event.target.checked)} /> Ik wil vrijwillig meldingen voor deze editie ontvangen.</label><button className="ui-button" disabled={busy || c.busy || !consent || !supported || !config?.available} onClick={() => void enable()}><Bell size={17} /> Toestemming vragen en veilig opslaan</button></>}{message && <p role="status" className="fn-caption">{message}</p>}</section>;
}
