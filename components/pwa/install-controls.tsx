"use client";
import { useState } from "react";
import { Download, Smartphone } from "lucide-react";
import { consumeInstallPrompt, isAppleMobile, useInstallRuntime } from "@/lib/pwa/device-runtime";

export function InstallControls() {
  const runtime = useInstallRuntime();
  const [instructions, setInstructions] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  async function install() {
    const prompt = consumeInstallPrompt();
    if (!prompt) { setInstructions(true); setNotice("Volg de stappen voor jouw browser. Er is nog geen installatie bevestigd."); return; }
    setBusy(true);
    try {
      await prompt.prompt();
      const choice = await prompt.userChoice;
      setNotice(choice.outcome === "accepted" ? "Installatie aangevraagd. Open de app straks via het nieuwe icoon." : "Installatie geannuleerd. Je kunt de website gewoon blijven gebruiken.");
    } catch { setInstructions(true); setNotice("De browser kon de installatie nog niet starten. Gebruik het browsermenu."); }
    finally { setBusy(false); }
  }
  return <section className="device-setting-card" aria-label="De Poorten installeren"><span className="device-card-icon"><Smartphone /></span><div className="device-setting-copy"><div className="device-card-heading"><h3>De Poorten op je beginscherm</h3><span className="device-status">{runtime.installed ? "Geïnstalleerd / appweergave" : "Via je browser"}</span></div><p>Jouw omgevingen snel bij de hand, met een eigen icoon en een rustige appweergave.</p><div className="device-actions"><button className="entry-button entry-button-outline" type="button" disabled={busy || !runtime.ready || runtime.installed} onClick={() => void install()}><Download size={16} />{runtime.installed ? "Je gebruikt de app" : "Installeer de app"}</button><button className="device-text-button" type="button" onClick={() => setInstructions(!instructions)}>Bekijk installatiestappen</button></div>{instructions && <div className="device-install-guide" role="status">{runtime.ready && isAppleMobile() ? <><strong>Op iPhone of iPad</strong><ol><li>Open deze website in Safari.</li><li>Tik op Deel en kies ‘Zet op beginscherm’.</li><li>Tik op ‘Voeg toe’.</li><li>Open De Poorten via het nieuwe icoon. Daarna kun je meldingen apart toestaan.</li></ol></> : <><strong>Android of computer</strong><ol><li>Open het browsermenu in Chrome, Edge of Samsung Internet.</li><li>Kies ‘App installeren’ of ‘Toevoegen aan startscherm’. In Samsung Internet staat dit in het menu rechtsonder.</li><li>Bevestig en open het nieuwe icoon.</li></ol><p>Staat deze optie er niet? Gebruik de website verder of probeer een ondersteunende browser.</p></>}</div>}{notice && <p className="device-feedback" role="status">{notice}</p>}</div></section>;
}
