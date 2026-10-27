"use client";
import Link from 'next/link';
import { useSyncExternalStore } from 'react';
import { AlertTriangle, Footprints, Mail, Phone, Sun } from 'lucide-react';

export type RouteContact = { email: string; phone?: string | null };
export type PortalVisitInformation = { warnings?: Partial<Record<'smoke'|'flashes'|'sound'|'actors'|'allergens',boolean>> | null; warningNotes?: string | null; accessibility?: string | null; accessibilityNotes?: string | null };
const listeners=new Set<()=>void>();
const transient=new Map<string,boolean>();
function subscribe(listener:()=>void) { const storage=(event:StorageEvent)=>{if(event.key)transient.delete(event.key);listener();};listeners.add(listener);window.addEventListener('storage',storage);return()=>{listeners.delete(listener);window.removeEventListener('storage',storage);}; }
export function useOutdoorMode(userId:string) {
  const key=`duindorp-outdoor-v1:${userId}`;
  const enabled=useSyncExternalStore(subscribe,()=>{if(transient.has(key))return transient.get(key)!;try{return localStorage.getItem(key)==='on';}catch{return false;}},()=>false);
  const toggle=()=>{transient.set(key,!enabled);try{localStorage.setItem(key,!enabled?'on':'off');}catch{}listeners.forEach(listener=>listener());};
  return {enabled,toggle};
}
export function OutdoorButton({enabled,onClick}:{enabled:boolean;onClick:()=>void}) { return <button type="button" className="route-outdoor-toggle" aria-pressed={enabled} onClick={onClick}><Sun size={18}/><span>Buitenmodus {enabled?'aan':'uit'}</span></button>; }
export function RouteHelp({contact}:{contact?:RouteContact}) { return <div className="route-direct-help"><div>{contact?.phone?<a href={'tel:'+contact.phone.replace(/\s/g,'')}><Phone size={17}/>Bel organisatie</a>:contact?.email?<a href={'mailto:'+contact.email}><Mail size={17}/>Hulp vragen</a>:<Link href="/omgeving/meeloper/meer">Hulp & contact</Link>}</div></div>; }
export function DestinationWarnings({portal}:{portal:PortalVisitInformation}) {
  const labels: Array<[keyof NonNullable<PortalVisitInformation['warnings']>,string]>=[['smoke','Rook of nevel'],['flashes','Flitslicht'],['sound','Hard geluid'],['actors','Acteurs'],['allergens','Allergenen · vraag de bewoner']];
  const active=labels.filter(([key])=>portal.warnings?.[key]===true);
  const known=labels.every(([key])=>typeof portal.warnings?.[key]==='boolean');
  const access:Record<string,string>={step_free:'Drempelvrij',steps:'Er zijn treden',mixed:'Gedeeltelijk toegankelijk',unknown:'Toegankelijkheid niet opgegeven'};
  return <section className="route-destination-warnings" aria-label="Praktisch voor jullie bezoek"><h3><AlertTriangle size={16}/>Goed om vooraf te weten</h3>{active.length>0&&<ul>{active.map(([key,label])=><li key={key}>{label}</li>)}</ul>}{!known?<p>Bijzonderheden zijn nog niet volledig doorgegeven. Vraag bij twijfel de bewoner.</p>:!active.length&&<p>Geen extra effecten doorgegeven.</p>}{portal.warningNotes&&<p>{portal.warningNotes}</p>}<p className="route-accessibility"><Footprints size={15}/><span>{access[portal.accessibility??'unknown']??'Vraag de bewoner naar de toegang'}{portal.accessibilityNotes?` · ${portal.accessibilityNotes}`:''}</span></p><small>Rustig buiten blijven mag. Ieder aanwezig kind krijgt bij bevestigde aankomst gewoon een zegel.</small></section>;
}
