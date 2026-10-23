"use client";
import { useEffect, useMemo, useState } from 'react';
import { Check, CheckCircle2, Heart, House, MessageCircleHeart, Pencil, Send, Sparkles } from 'lucide-react';
import { useCallback } from 'react';
type ThankChoice='beautiful'|'welcome'|'treats';
type ArrivalPortal={id:string;name:string;world:string};
type PortalThank={id?:string;portalId:string;portalName:string;world:string;choice:ThankChoice};
const thankChoices:[{id:ThankChoice;message:string;hint:string},{id:ThankChoice;message:string;hint:string},{id:ThankChoice;message:string;hint:string}]=[
 {id:'beautiful',message:'Bedankt voor jullie mooie poort!',hint:'Voor de versiering, de sfeer en het kleine stukje magie.'},
 {id:'welcome',message:'Wat een fijne ontvangst!',hint:'Voor het warme welkom en de aandacht voor ieder kind.'},
 {id:'treats',message:'Bedankt voor het lekkers!',hint:'Voor de kleine traktatie onderweg.'},
];
const thankMessage=(choice:ThankChoice)=>thankChoices.find(item=>item.id===choice)?.message;
type ThanksSnapshot={finished?:boolean;portals?:ArrivalPortal[];saved?:PortalThank[];thanks?:PortalThank[];familyCount?:number};
import '../../modern/portal-thanks.css';

function useThanks(scope:'family'|'house'|'admin',portalId?:string){
 const [snapshot,setSnapshot]=useState<ThanksSnapshot>({}),[error,setError]=useState('');
 const load=useCallback(async()=>{try{const query=new URLSearchParams({scope,...(portalId?{portalId}:{})});const response=await fetch('/api/redesign/thanks?'+query,{cache:'no-store'});if(!response.ok)throw new Error();setSnapshot(await response.json());setError('');}catch{setError('De bedankjes konden niet worden opgehaald. Probeer opnieuw.');}},[scope,portalId]);
 useEffect(()=>{const timer=setTimeout(()=>void load(),0),refresh=setInterval(()=>{if(document.visibilityState==='visible')void load();},30000);return()=>{clearTimeout(timer);clearInterval(refresh);};},[load]);
 return {main:snapshot,thanks:snapshot.thanks??[],familyCount:snapshot.familyCount??0,error,load};
}
function ThankGate({ portal, saved, onSaved }: { portal: ArrivalPortal; saved?: PortalThank; onSaved:()=>Promise<void> }) {
  const [choice, setChoice] = useState<ThankChoice>(saved?.choice ?? 'beautiful'), [editing, setEditing] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const sending = !saved || editing;
  async function send(){if(busy)return;setBusy(true);setError('');try{const response=await fetch('/api/redesign/thanks',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({portalId:portal.id,choice}),cache:'no-store'});if(!response.ok)throw new Error();await onSaved();setEditing(false);}catch{setError('Het opslaan lukte even niet. Probeer opnieuw.');}finally{setBusy(false);}}
  return <article className={`portal-thanks-gate ${saved ? 'has-thanks' : ''}`}>
    <header><span className="portal-thanks-gate-icon"><House size={19}/></span><div><span>{portal.world}</span><h3>{portal.name}</h3></div>{saved && <CheckCircle2 className="portal-thanks-saved-icon" size={20} aria-label="Bedankje opgeslagen"/>}</header>
    {sending ? <><fieldset disabled={busy}><legend>Kies jullie bedankje voor {portal.name}</legend>{thankChoices.map(item => <label key={item.id} className={choice === item.id ? 'is-selected' : ''}><input type="radio" name={`thank-${portal.id}`} checked={choice === item.id} value={item.id} onChange={() => setChoice(item.id)}/><span><strong>{item.message}</strong><small>{item.hint}</small></span>{choice === item.id && <Check size={16}/>}</label>)}</fieldset><div className="portal-thanks-actions">{saved && <button className="portal-thanks-cancel" type="button" onClick={() => { setChoice(saved.choice); setEditing(false); setError(''); }}>Annuleren</button>}<button className="portal-thanks-send" type="button" onClick={send} disabled={busy}><Send size={16}/>{busy ? 'Opslaan…' : saved ? 'Bedankje aanpassen' : 'Bewaar ons bedankje'}</button></div></> : <><div className="portal-thanks-message"><Heart size={17}/><p>{thankMessage(saved.choice)}</p></div><div className="portal-thanks-saved"><span role="status"><CheckCircle2 size={14}/>Jullie bedankje staat klaar voor de poortbewoners.</span><button type="button" onClick={() => setEditing(true)} aria-label={`Bedankje voor ${portal.name} aanpassen`}><Pencil size={13}/>Aanpassen</button></div></>}
    {error && <p className="portal-thanks-error" role="alert">{error}</p>}
  </article>;
}
export function FamilyPortalThanks() {
  const { main,load,error } = useThanks('family'), portals = main.portals??[], saved = main.saved??[];
  if(error)return <p className="form-warning" role="alert">{error}<button className="text-link" onClick={()=>void load()}>Opnieuw proberen</button></p>;
  if (!main.finished) return null;
  return <section className="portal-thanks portal-thanks-family" aria-labelledby="family-thanks-title" data-tutorial="portal-thanks">
    <header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><MessageCircleHeart size={25}/></span><div><p>Een warm gebaar</p><h2 id="family-thanks-title">Bedank de poortbewoners</h2><span>De lichtjes, de ontvangst en iets lekkers: jullie buren maakten de avond bijzonder. Kies samen een bedankje voor de poorten die jullie bereikten.</span></div></header>
    {portals.length ? <><p className="portal-thanks-family-note"><Heart size={15}/>Een bedankje van jullie gezin, ook als een kind de beleving liever oversloeg. Bedanken is helemaal vrijwillig.</p><div className="portal-thanks-grid">{portals.map(portal => <ThankGate key={portal.id} portal={portal} saved={saved.find(item => item.portalId === portal.id)} onSaved={load}/>)}</div></> : <div className="portal-thanks-empty"><Sparkles size={23}/><div><strong>Fijn dat jullie erbij waren.</strong><p>Er staan nog geen bevestigde aankomsten in jullie route. Zodra een bereikte poort is bevestigd, kun je hier een bedankje bewaren.</p></div></div>}
    <p className="portal-thanks-local">Jullie bedankje wordt veilig in het portaal bewaard. Het verstuurt geen WhatsApp-bericht, e-mail of pushmelding.</p>
  </section>;
}
export function HousePortalThanks({ portalId }: { portalId?: string }) {
  const { thanks,error,load } = useThanks('house',portalId), rows=thanks, portalName=rows[0]?.portalName;
  if(error)return <p className="form-warning" role="alert">{error}<button onClick={()=>void load()}>Opnieuw proberen</button></p>;
  return <section className="portal-thanks portal-thanks-house" aria-label="Bedankjes voor jullie poort"><header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><Heart size={25}/></span><div><p>Van de gezinnen</p><h2>Bedankt voor jullie poort</h2><span>{portalName ? `${portalName} · ` : ''}Een kleine terugblik op wat jullie ontvangst betekende.</span></div></header>
    {rows.length ? <><div className="portal-thanks-house-summary"><Heart size={22}/><p><strong>{rows.length} {rows.length === 1 ? 'gezin heeft' : 'gezinnen hebben'} jullie bedankt.</strong><span>Jullie maakten samen de wijk een beetje magischer.</span></p></div><div className="portal-thanks-received">{thankChoices.map(choice => { const count = rows.filter(row => row.choice === choice.id).length; return count > 0 ? <div key={choice.id}><MessageCircleHeart size={18}/><p>{choice.message}</p><span>{count} {count === 1 ? 'gezin' : 'gezinnen'}</span></div> : null; })}</div></> : <div className="portal-thanks-empty"><MessageCircleHeart size={24}/><div><strong>De eerste bedankjes mogen nog komen.</strong><p>Na hun tocht kunnen gezinnen een vrijwillig bedankje achterlaten. Hier verschijnen alleen de bedankjes voor jullie eigen poort.</p></div></div>}
    <p className="portal-thanks-local">Alleen bedankjes voor jullie eigen poort. Gezinnen en kinderen worden hier niet bij naam getoond.</p>
  </section>;
}
export function AdminPortalThanks() {
  const {thanks,familyCount,error,load}=useThanks('admin');
  const portals = useMemo(() => { const map = new Map<string, { id: string; name: string; world: string; rows: PortalThank[] }>(); for (const thank of thanks) { if (!map.has(thank.portalId)) map.set(thank.portalId, { id: thank.portalId, name: thank.portalName, world: thank.world, rows: [] }); map.get(thank.portalId)!.rows.push(thank); } return [...map.values()].sort((a, b) => a.name.localeCompare(b.name, 'nl')); }, [thanks]);
  const families = familyCount;
  if(error)return <p className="form-warning" role="alert">{error}<button onClick={()=>void load()}>Opnieuw proberen</button></p>;
  return <section className="portal-thanks portal-thanks-admin" aria-labelledby="admin-thanks-title"><header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><MessageCircleHeart size={25}/></span><div><p>Een wijk die samen iets maakt</p><h2 id="admin-thanks-title">Bedankjes aan de poortbewoners</h2><span>Vrijwillige gebaren van gezinnen. Elk gezin kan iedere bereikte poort één bedankje geven; aanpassen telt niet opnieuw mee.</span></div></header><div className="portal-thanks-totals"><div><strong>{thanks.length}</strong><span>bedankjes bewaard</span></div><div><strong>{families}</strong><span>{families === 1 ? 'gezin deed' : 'gezinnen deden'} mee</span></div><div><strong>{portals.length}</strong><span>poorten bedankt</span></div></div>
    {portals.length ? <div className="portal-thanks-admin-portals">{portals.map(portal => <article key={portal.id}><header><House size={18}/><div><h3>{portal.name}</h3><span>{portal.world}</span></div></header><div>{portal.rows.map((row,index) => <p key={index}><Heart size={14}/>{thankMessage(row.choice)}</p>)}</div></article>)}</div> : <div className="portal-thanks-empty"><Heart size={23}/><div><strong>Er zijn nog geen bedankjes bewaard.</strong><p>Na het afronden of eerder afsluiten van de tocht verschijnt de mogelijkheid in de ouderomgeving. Bedankjes verschijnen vervolgens ook bij het eigen poortteam.</p></div></div>}
    <p className="portal-thanks-local">Poorten staan op naam, zonder ranglijst of beoordelingen. Alleen de vaste warme berichten worden getoond.</p>
  </section>;
}
