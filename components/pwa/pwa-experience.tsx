"use client";

import { Bell, BellOff, Download, Share2, Smartphone, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { analyticsDeviceMetadata, trackProductAnalytics } from "@/lib/analytics/client";
import { installInviteStorageKey, shouldShowInstallInvite } from "@/lib/pwa/install-invitation";
import { consumeInstallPrompt, deviceStorage, endpointHash, isAppleMobile, useInstallRuntime } from "@/lib/pwa/device-runtime";
import "./pwa-experience.css";

function standalone() {
  return window.matchMedia("(display-mode: standalone)").matches
    || (navigator as Navigator & { standalone?: boolean }).standalone === true;
}

function mobileDevice() {
  return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) || window.matchMedia("(pointer: coarse)").matches;
}

function isIos() {
  return isAppleMobile();
}

function urlBase64ToUint8Array(value: string) {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(window.atob(base64), (character) => character.charCodeAt(0));
}

async function api<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers },
    cache: "no-store",
  });
  const body = await response.json() as { data?: T; error?: { message?: string } };
  if (!response.ok || body.data === undefined) throw new Error(body.error?.message || "Dat lukte nog niet.");
  return body.data;
}

export function PwaInstallInvitation({ userId }: { userId: string }) {
  const [visible, setVisible] = useState(false);
  const [instructions, setInstructions] = useState(false);
  const installRuntime = useInstallRuntime();

  useEffect(() => {
    const installed = () => {
      deviceStorage.setItem(`poorten:pwa-installed:${userId}`, "true");
      void trackProductAnalytics("pwa_install_completed", undefined, analyticsDeviceMetadata());
      setVisible(false);
    };
    window.addEventListener("appinstalled", installed);
    if (standalone()) void trackProductAnalytics("pwa_standalone_opened", undefined, analyticsDeviceMetadata());
    const show = () => {
      if(document.documentElement.dataset.participantGuidanceActive === "true")return;
      if (!standalone() && mobileDevice() && deviceStorage.getItem(`poorten:pwa-installed:${userId}`) !== "true" && shouldShowInstallInvite(deviceStorage, userId)) {
        deviceStorage.setItem(installInviteStorageKey(userId), "shown");
        setVisible(true);
      }
    };
    let timer=window.setTimeout(show,900);
    const guidanceChanged=()=>{window.clearTimeout(timer);if(document.documentElement.dataset.participantGuidanceActive === "true")setVisible(false);else timer=window.setTimeout(show,900);};
    window.addEventListener("poorten-guidance-status",guidanceChanged);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("appinstalled", installed);
      window.removeEventListener("poorten-guidance-status",guidanceChanged);
    };
  }, [userId]);

  async function install() {
    const deferredPrompt = consumeInstallPrompt();
    if (!deferredPrompt) {
      setInstructions(true);
      return;
    }
    await deferredPrompt.prompt();
    const choice = await deferredPrompt.userChoice;
    if (choice.outcome === "accepted") {
      void trackProductAnalytics("pwa_install_prompt_accepted", undefined, analyticsDeviceMetadata());
      setVisible(false);
    }
  }

  if (!visible || installRuntime.installed) return null;
  return <div className="pwa-dialog-backdrop" role="presentation">
    <section className="pwa-dialog" role="dialog" aria-modal="false" aria-labelledby="pwa-install-title">
      <button className="pwa-dialog-close" type="button" onClick={() => setVisible(false)} aria-label="Installatievenster sluiten"><X /></button>
      <span className="pwa-dialog-icon" aria-hidden="true"><Smartphone /></span>
      <p className="pwa-eyebrow">Jouw avond binnen handbereik</p>
      <h2 id="pwa-install-title">Zet De Poorten op je beginscherm</h2>
      <p>Open je persoonlijke omgeving sneller, in een rustige appweergave zonder browserbalken.</p>
      {instructions && <div className="pwa-instructions" role="status">
        <Share2 aria-hidden="true" />
        <span>{isIos()
          ? "Tik in Safari op Deel en daarna op ‘Zet op beginscherm’. Open De Poorten vervolgens via het nieuwe icoon."
          : "Open het browsermenu en kies ‘App installeren’ of ‘Toevoegen aan startscherm’. In Samsung Internet staat dit onder het menu rechtsonder."}</span>
      </div>}
      <div className="pwa-dialog-actions">
        <button className="btn" type="button" onClick={() => void install()}><Download aria-hidden="true" />Installeer app</button>
        <button className="btn outline" type="button" onClick={() => setVisible(false)}>Later</button>
      </div>
      <button className="pwa-already-installed" type="button" onClick={() => { deviceStorage.setItem(`poorten:pwa-installed:${userId}`, "true"); void trackProductAnalytics("pwa_install_manual_confirmed", undefined, analyticsDeviceMetadata()); setVisible(false); }}>Ik heb de app al geïnstalleerd</button>
      <PushNotificationSettings compact />
    </section>
  </div>;
}

type PushState = { enabled: boolean; activeSubscriptionCount: number; currentDeviceRegistered?: boolean };

export function PushNotificationSettings({ compact = false }: { compact?: boolean }) {
  const [wanted, setWanted] = useState(false);
  const [subscribed, setSubscribed] = useState(false);
  const [supported, setSupported] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [permission, setPermission] = useState<NotificationPermission>("default");
  const publicKey = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;

  const load = useCallback(async () => {
    const available = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && Boolean(publicKey);
    setSupported(available);
    if (!available) return;
    try {
      const registration = await navigator.serviceWorker.getRegistration("/");
      const current = await registration?.pushManager.getSubscription();
      const state = await api<PushState>("/api/push/subscription", current ? { headers: { "x-push-endpoint-hash": await endpointHash(current.endpoint) } } : undefined);
      setPermission(Notification.permission);
      setWanted(state.enabled);
      setSubscribed(Boolean(current && state.enabled && state.currentDeviceRegistered && Notification.permission === "granted"));
    } catch {
      setNotice("De meldingsvoorkeur kon niet worden opgehaald.");
    }
  }, [publicKey]);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function setPreference(enabled: boolean) {
    setBusy(true); setNotice("");
    try {
      if (!enabled) {
        const registration = await navigator.serviceWorker.getRegistration("/");
        const current = await registration?.pushManager.getSubscription();
        if (current) {
          await api<PushState>("/api/push/subscription", { method: "DELETE", body: JSON.stringify({ endpoint: current.endpoint }) });
          await current.unsubscribe();
        }
      }
      await api<PushState>("/api/push/subscription", { method: "PATCH", body: JSON.stringify({ enabled }) });
      setWanted(enabled); setSubscribed(enabled ? subscribed : false);
      setNotice(enabled ? "Je voorkeur is bewaard. Zet meldingen apart aan op dit apparaat." : "Je accountvoorkeur staat uit; je ontvangt op geen van je apparaten organisatiepush.");
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Dat lukte nog niet.");
    } finally { setBusy(false); }
  }

  async function enableOnDevice() {
    if (!publicKey) return;
    setBusy(true); setNotice("");
    try {
      if (isIos() && !standalone()) throw new Error("Installeer De Poorten eerst op je beginscherm en open de app daar om meldingen aan te zetten.");
      const permission = await Notification.requestPermission();
      setPermission(permission);
      if (permission !== "granted") throw new Error("Meldingen zijn niet toegestaan. Je kunt dit later wijzigen in de browser- of telefooninstellingen.");
      if (!await navigator.serviceWorker.getRegistration("/")) await navigator.serviceWorker.register("/sw.js", { scope: "/", updateViaCache: "none" });
      let timer: ReturnType<typeof setTimeout> | undefined;
      const registration = await Promise.race([navigator.serviceWorker.ready, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("De app is nog niet klaar voor meldingen. Vernieuw en probeer opnieuw.")), 10000); })]).finally(() => clearTimeout(timer));
      const current = await registration.pushManager.getSubscription();
      const subscription = current ?? await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(publicKey),
      });
      const serialized = subscription.toJSON();
      await api<PushState>("/api/push/subscription", {
        method: "POST",
        body: JSON.stringify({
          endpoint: subscription.endpoint,
          keys: serialized.keys,
          deviceLabel: `${navigator.platform || "mobiel"} · ${standalone() ? "app" : "browser"}`,
        }),
      });
      const proof = await api<PushState>("/api/push/subscription", { headers: { "x-push-endpoint-hash": await endpointHash(subscription.endpoint) } });
      if (!proof.enabled || !proof.currentDeviceRegistered) throw new Error("De browser heeft toestemming, maar de server heeft de apparaatinschrijving nog niet bevestigd. Probeer opnieuw.");
      setWanted(true); setSubscribed(true); setNotice("Meldingen staan aan op dit apparaat.");
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Meldingen konden niet worden aangezet.");
    } finally { setBusy(false); }
  }

  async function disableDevice() {
    setBusy(true); setNotice("");
    try {
      const registration = await navigator.serviceWorker.getRegistration("/");
      const current = await registration?.pushManager.getSubscription();
      if (current) {
        await api<PushState>("/api/push/subscription", { method: "DELETE", body: JSON.stringify({ endpoint: current.endpoint }) });
        await current.unsubscribe();
      }
      setSubscribed(false); setNotice("Meldingen op dit apparaat uitgezet. Andere apparaten behouden hun eigen inschrijving.");
    } catch { setNotice("Uitschakelen is niet bevestigd. Maak verbinding en probeer opnieuw."); }
    finally { setBusy(false); }
  }
  async function testDevice() {
    setBusy(true); setNotice("");
    try {
      const current = await (await navigator.serviceWorker.getRegistration("/"))?.pushManager.getSubscription();
      if (!current) throw new Error("Schrijf dit apparaat eerst opnieuw in.");
      await api("/api/push/test", { method: "POST", body: JSON.stringify({ endpointHash: await endpointHash(current.endpoint) }) });
      setNotice("De pushdienst heeft de test voor dit apparaat geaccepteerd. Controleer of de melding op je scherm verschijnt.");
    } catch (error) { setNotice(error instanceof Error ? error.message : "De test kon niet worden aangeboden."); }
    finally { setBusy(false); }
  }

  return <section className={compact ? "pwa-push-settings compact" : "participant-card pwa-push-settings"} aria-labelledby={compact ? undefined : "push-settings-title"}>
    <div className="pwa-push-heading">
      <span aria-hidden="true">{subscribed ? <Bell /> : <BellOff />}</span>
      <div><strong id={compact ? undefined : "push-settings-title"}>Appmeldingen</strong><small>Alleen operationele updates voor jouw avond.</small></div>
    </div>
    {!supported ? <p className="pwa-push-note">{isIos() && !standalone() ? "Op iPhone en iPad: installeer De Poorten via Safari en open het beginschermicoon voordat je meldingen aanzet." : "Meldingen zijn in deze browser niet beschikbaar of nog niet geconfigureerd. Je kunt de app blijven gebruiken."}</p> : <>
      <p className="pwa-push-note">Browsertoestemming: {permission === "granted" ? "toegestaan" : permission === "denied" ? "geblokkeerd" : "nog niet gevraagd"}. {subscribed ? "Apparaatinschrijving door de server bevestigd." : "Nog geen bevestigde actieve inschrijving op dit apparaat."}</p>
      <label className="pwa-push-choice"><span>Ik wil meldingen over mijn groep of poort ontvangen</span><input type="checkbox" checked={wanted} disabled={busy} onChange={(event) => void setPreference(event.target.checked)} /></label>
      {wanted && !subscribed && <button className="btn outline" type="button" disabled={busy} onClick={() => void enableOnDevice()}>Meldingen aanzetten</button>}
      {subscribed && <><p className="pwa-push-active"><Bell aria-hidden="true" />Actief op dit apparaat</p><div className="actions"><button className="btn outline" type="button" disabled={busy} onClick={() => void testDevice()}>Testmelding op dit apparaat</button><button className="text-link" type="button" disabled={busy} onClick={() => void disableDevice()}>Meldingen op dit apparaat uitzetten</button></div></>}
    </>}
    {notice && <p className="pwa-push-note" role="status">{notice}</p>}
  </section>;
}
