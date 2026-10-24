"use client";
import { useEffect, useState } from 'react';
import { RefreshCw } from 'lucide-react';
export type SourceHealth = {at:number|null;error:string|null};
export type EveningHealth = Record<'dashboard'|'cockpit'|'portals',SourceHealth>;
export const emptyEveningHealth:EveningHealth={dashboard:{at:null,error:null},cockpit:{at:null,error:null},portals:{at:null,error:null}};
export function EveningFreshness({health,connection,reload}:{health:EveningHealth;connection:string;reload:()=>Promise<void>}) {
  const [clock,setClock]=useState(()=>Date.now()),[busy,setBusy]=useState(false);
  useEffect(()=>{const timer=setInterval(()=>setClock(Date.now()),5000);return()=>clearInterval(timer);},[]);
  return <section className="evening-freshness" aria-label="Actualiteit van de gegevens"><header><div><h2>Weet hoe actueel je overzicht is.</h2><p>Een verbonden kanaal en bevestigde gegevens hebben elk hun eigen status.</p></div><button className="btn outline" disabled={busy} onClick={async()=>{setBusy(true);try{await reload();}finally{setBusy(false);}}}><RefreshCw className={busy?'spin':''}/>{busy?'Bijwerken…':'Gegevens vernieuwen'}</button></header><div className="evening-data-sources">{([['dashboard','Overzicht en meldingstellers'],['cockpit','Groepen en veiligheidssignalen'],['portals','Poorten en capaciteit']] as const).map(([key,title])=>{const source=health[key],fresh=source.at!==null&&!source.error&&clock-source.at<45000;return <div key={key} className={`evening-data-source ${source.error?'is-error':fresh?'':'is-stale'}`}><strong>{title}</strong><small>{source.at?`Laatst bijgewerkt ${new Date(source.at).toLocaleTimeString('nl-NL',{hour:'2-digit',minute:'2-digit',second:'2-digit',timeZone:'Europe/Amsterdam'})}`:'Nog geen bevestigde gegevens'}</small><small>{source.error||(fresh?'Actueel bevestigd':'Gegevens zijn verouderd. Vernieuw vóór een handeling.')}</small></div>;})}</div><p className="evening-realtime-status"><RefreshCw/>{connection==='live'?'Realtimekanaal verbonden':connection==='offline'?'Realtimekanaal verbroken · verversen blijft beschikbaar':'Realtimekanaal wordt verbonden'}</p></section>;
}
