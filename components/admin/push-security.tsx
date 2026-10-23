"use client";
import { useCallback,useEffect,useState } from "react";
import { Clock3,Globe,LockKeyhole,RefreshCw,ShieldCheck,Smartphone,Trash2,UsersRound,Zap } from "lucide-react";
import { PushNotificationSettings } from "@/components/pwa/pwa-experience";
import { useSnapshotRefresh } from "@/lib/realtime/use-snapshot-refresh";
import "../../modern/push-security.css";

type State={activeSubscriptionCount:number;devices:Array<{id:string;label:string;provider:string;updatedAt:string}>;policy:{maxDevicesPerAccount:number;writesPerMinute:number;maxBatchTargets:number;concurrency:number;attemptTimeoutMs:number;batchTimeoutMs:number}};
export function PushSecurity() {
  const [state,setState]=useState<State|null>(null);const [notice,setNotice]=useState("");const [busy,setBusy]=useState(false);
  const load=useCallback(async()=>{
    try {const response=await fetch("/api/push/subscription",{cache:"no-store"});const result=await response.json();
      if (!response.ok) throw new Error();setState(result.data as State);
    } catch {setNotice("De actuele apparaatinstellingen konden niet worden opgehaald. Probeer opnieuw.");}
  },[]);
  useSnapshotRefresh(load);
  useEffect(()=>{const timer=setTimeout(()=>void load(),0);return()=>clearTimeout(timer);},[load]);
  async function remove(id:string) {
    setBusy(true);
    try {const response=await fetch("/api/push/subscription",{method:"DELETE",headers:{"Content-Type":"application/json"},body:JSON.stringify({id})});
      const result=await response.json();if (!response.ok) {setNotice(result.error?.message??"Het apparaat is niet verwijderd.");return;}
      setState(result.data);setNotice("Dit apparaat is afgemeld voor pushmeldingen.");
    } catch {setNotice("Het apparaat is niet afgemeld. Controleer de verbinding en probeer opnieuw.");}
    finally {setBusy(false);}
  }
  return <div className="push-security">
    <section className="ps-hero"><div><span className="ps-eyebrow"><ShieldCheck size={14}/>PUSH & BEVEILIGING</span><h2>Meldingen met duidelijke grenzen.</h2><p>Beheer je eigen apparaten. De server controleert de pushdienst, encryptiesleutels, accounttoegang en actuele toestemming vóór verzending.</p></div><div className="ps-hero-shield"><ShieldCheck size={48}/><span>Instellingen van de echte server<br/>Bijgewerkt bij vernieuwen</span></div></section>
    {notice&&<p className="ps-notice" role="status">{notice}</p>}
    {state&&<div className="ps-policy-grid"><article><Smartphone/><div><strong>{state.policy.maxDevicesPerAccount}</strong><small>apparaten per account</small></div></article><article><Clock3/><div><strong>{state.policy.writesPerMinute}</strong><small>schrijfverzoeken per minuut</small></div></article><article><UsersRound/><div><strong>{state.policy.maxBatchTargets} / {state.policy.concurrency}</strong><small>bestemmingen / gelijktijdige pogingen</small></div></article><article><Zap/><div><strong>{state.policy.attemptTimeoutMs/1000} / {state.policy.batchTimeoutMs/1000} s</strong><small>limiet per poging / verzendronde</small></div></article></div>}
    <div className="ps-workspace"><section className="ps-card"><div className="ps-card-head"><div><span className="ps-eyebrow">JOUW APPARATEN</span><h3>Verbonden met jouw account.</h3></div><span className="ps-count">{state?.activeSubscriptionCount??"…"} actief</span></div>
      <div className="ps-devices">{state?.devices.map(device=><article key={device.id}><span className="ps-device-icon"><Smartphone/></span><div><strong>{device.label}</strong><small>{{google:"Chrome · Android",mozilla:"Firefox",apple:"Safari · iPhone",unknown:"Opnieuw controleren"}[device.provider]??"Pushdienst"}</small></div><button type="button" disabled={busy} aria-label={`${device.label} afmelden`} onClick={()=>void remove(device.id)}><Trash2 size={16}/></button></article>)}{state?.devices.length===0&&<div className="ps-empty"><Smartphone/><strong>Nog geen verbonden apparaten</strong><span>Zet meldingen hieronder aan op je eigen telefoon of computer.</span></div>}</div>
      <PushNotificationSettings/><button type="button" className="ps-secondary" disabled={busy} onClick={()=>void load()}><RefreshCw size={15}/>Apparaten vernieuwen</button></section>
      <section className="ps-card"><span className="ps-eyebrow">TOEGESTANE PUSHDIENSTEN</span><h3>Alleen de bekende diensten.</h3><div className="ps-provider-list">{[["Chrome · Android","fcm.googleapis.com"],["Firefox","updates.push.services.mozilla.com"],["Safari · iPhone","web.push.apple.com"]].map(([name,host])=><article key={host}><Globe size={18}/><div><strong>{name}</strong><code>{host}</code></div></article>)}</div><ul className="ps-rules"><li>HTTPS op de standaardpoort, zonder login, query of fragment.</li><li>Lokale netwerken, IP-adressen en afwijkende domeinen worden geweigerd.</li><li>Ook oude bestemmingen worden opnieuw gecontroleerd. Een gewijzigde of ingetrokken inschrijving wordt niet verzonden.</li></ul><p className="ps-hint"><LockKeyhole size={15}/>Apparaatsleutels en volledige bestemmingstokens worden hier niet getoond.</p></section></div>
    <p className="ps-scope">De instellingen tonen de ingestelde grenzen. Bezorging op een telefoon wordt apart getest met een eigen testapparaat.</p>
  </div>;
}
