"use client";
import { useEffect, useMemo, useRef, useState } from 'react';
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
type ClosedSubmission={id:string;kind:'all'|'personal';portalId:string|null;choice:ThankChoice|null;message:string;createdAt:string;targetCount:number;processedCount:number};
type InboxMessage={id:string;kind:'all'|'personal';choice:ThankChoice|null;message:string;senderLabel:string;receivedAt:string;read:boolean;missingContacts:number;mailCounts:Record<string,number>};
type HouseInbox={portalId:string;messages:InboxMessage[];total:number;unread:number;nextCursor:string|null;portalName:string};
type ThanksSnapshot={closed?:boolean;submissions?:ClosedSubmission[];finished?:boolean;portals?:ArrivalPortal[];saved?:PortalThank[];thanks?:PortalThank[];familyCount?:number};
import '../../modern/portal-thanks.css';

function useThanks(scope:'family'|'house'|'admin',portalId?:string){
 const [snapshot,setSnapshot]=useState<ThanksSnapshot>({}),[error,setError]=useState('');
 const refresh=useRef<()=>Promise<void>>(async()=>{});
 const load=useCallback(()=>refresh.current(),[]);
 useEffect(()=>{
  let disposed=false,active=false,pending=false,timer:ReturnType<typeof setTimeout>|undefined;
  const controller=new AbortController();
  const available=()=>document.visibilityState!=='hidden'&&navigator.onLine!==false;
  const schedule=()=>{clearTimeout(timer);if(!disposed&&available())timer=setTimeout(()=>void run(),30000);};
  const run=async()=>{
   if(disposed||!available())return;
   if(active){pending=true;return;}
   clearTimeout(timer);active=true;
   try{const query=new URLSearchParams({scope,...(portalId?{portalId}:{})});const response=await fetch('/api/redesign/thanks?'+query,{cache:'no-store',signal:controller.signal});
    if(response.status===401||response.status===403){if(!disposed){setSnapshot({finished:false});setError('');}return;}
    if(!response.ok)throw new Error();const data=await response.json();if(!disposed){setSnapshot(data);setError('');}
   }catch{if(!disposed&&!controller.signal.aborted)setError('De bedankjes konden niet worden opgehaald. Probeer opnieuw.');}
   finally{active=false;if(!disposed){if(pending){pending=false;schedule();}else schedule();}}
  };
  const resume=()=>{clearTimeout(timer);if(available())void run();else pending=false;};
  refresh.current=run;timer=setTimeout(()=>void run(),0);
  document.addEventListener('visibilitychange',resume);window.addEventListener('online',resume);window.addEventListener('offline',resume);
  return()=>{disposed=true;clearTimeout(timer);controller.abort();refresh.current=async()=>{};document.removeEventListener('visibilitychange',resume);window.removeEventListener('online',resume);window.removeEventListener('offline',resume);};
 },[scope,portalId]);
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
export function FamilyPortalThanks({}: {eventSlug?:string}={}) {
  const { main,load,error } = useThanks('family'), portals = main.portals??[], saved = main.saved??[];
  if(error)return <p className="form-warning" role="alert">{error}<button className="text-link" onClick={()=>void load()}>Opnieuw proberen</button></p>;
  if (!main.finished) return null;
  if(main.closed)return <ClosedFamilyThanks portals={portals} submissions={main.submissions??[]} legacy={saved} onSaved={load}/>;
  return <section className="portal-thanks portal-thanks-family" aria-labelledby="family-thanks-title" data-tutorial="portal-thanks">
    <header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><MessageCircleHeart size={25}/></span><div><p>Een warm gebaar</p><h2 id="family-thanks-title">Bedank de poortbewoners</h2><span>De lichtjes, de ontvangst en iets lekkers: jullie buren maakten de avond bijzonder. Kies samen een bedankje voor de poorten die jullie bereikten.</span></div></header>
    {portals.length ? <><p className="portal-thanks-family-note"><Heart size={15}/>Een bedankje van jullie gezin, ook als een kind de beleving liever oversloeg. Bedanken is helemaal vrijwillig.</p><div className="portal-thanks-grid">{portals.map(portal => <ThankGate key={portal.id} portal={portal} saved={saved.find(item => item.portalId === portal.id)} onSaved={load}/>)}</div></> : <div className="portal-thanks-empty"><Sparkles size={23}/><div><strong>Fijn dat jullie erbij waren.</strong><p>Er staan nog geen bevestigde aankomsten in jullie route. Zodra een bereikte poort is bevestigd, kun je hier een bedankje bewaren.</p></div></div>}
    <p className="portal-thanks-local">Jullie bedankje wordt veilig in het portaal bewaard. Het verstuurt geen WhatsApp-bericht, e-mail of pushmelding.</p>
  </section>;
}
function LegacyHousePortalThanks({ portalId }: { portalId?: string }) {
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

const defaultAllMessage='Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃';
function ClosedThanksForm({kind,portal,saved,onSaved,onCancel,targetCount}:{kind:'all'|'personal';portal?:ArrivalPortal;saved?:ClosedSubmission;onSaved:()=>Promise<void>;onCancel:()=>void;targetCount:number}){
 const [message,setMessage]=useState(saved?.message??(kind==='all'?defaultAllMessage:'')),[choice,setChoice]=useState<ThankChoice>(saved?.choice??'beautiful'),[busy,setBusy]=useState(false),[error,setError]=useState(''),[unknown,setUnknown]=useState(false);
 const request=useRef<{kind:'all'|'personal';portalId:string|null;choice:ThankChoice|null;message:string;requestKey:string;submissionId:string|null}|null>(null);
 const busyGuard=useRef(false);
 async function send(){
  if(busyGuard.current)return;busyGuard.current=true;setBusy(true);setError('');
  setUnknown(true);request.current??={kind,portalId:portal?.id??null,choice:kind==='personal'?choice:null,message,requestKey:crypto.randomUUID(),submissionId:saved?.id??null};
  try{
   const response=await fetch('/api/redesign/thanks-closed',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(request.current),cache:'no-store'});
   if(!response.ok)throw new Error();const result=await response.json();
   if(result?.ok!==true||typeof result?.id!=='string'||!result.id)throw new Error();
   request.current=null;setUnknown(false);await onSaved();onCancel();
  }catch{setError('Bewaren is nog niet bevestigd. Probeer dezelfde aanvraag opnieuw; dit verstuurt geen dubbel bedankje.');}
  finally{busyGuard.current=false;setBusy(false);}
 }
 return <form className="portal-thanks-gate closed-thanks-form" onSubmit={event=>{event.preventDefault();void send();}}>
  <h3>{saved?'Bedankje aanpassen':kind==='all'?'Bedank alle huizen':'Dit huis verdient een extra bedankje!'}</h3>
  <p>{kind==='all'?`${targetCount} deelnemende huizen ontvangen jullie bedankje.`:portal?.name}</p>
  {kind==='personal'&&<fieldset disabled={busy||unknown}><legend>Kies jullie reactie</legend>{thankChoices.map(item=><label key={item.id}><input type="radio" name="closed-thanks-choice" checked={choice===item.id} onChange={()=>setChoice(item.id)}/><span>{item.message}</span></label>)}</fieldset>}
  <label className="closed-thanks-text">{kind==='all'?'Jullie bericht':'Persoonlijk bericht (optioneel)'}<textarea value={message} maxLength={500} rows={5} disabled={busy||unknown} onChange={event=>setMessage(event.target.value)}/><small>{message.length}/500 tekens</small></label>
  <p>{saved?'Aanpassen wijzigt het bericht in de Poortkamer en verstuurt geen nieuwe e-mail.':'Na jullie bevestiging wordt het bericht opgeslagen voor de bewoners en wordt de mailverwerking klaargezet.'}</p>
  {error&&<p className="portal-thanks-error" role="alert">{error}</p>}
  <div className="portal-thanks-actions"><button className="portal-thanks-cancel" type="button" disabled={busy} onClick={onCancel}>Annuleren</button><button className="portal-thanks-send" type="submit" disabled={busy}><Send size={16}/>{busy?'Bewaren…':unknown?'Dezelfde aanvraag opnieuw proberen':saved?'Wijziging bewaren':kind==='all'?'Verstuur naar alle huizen':'Verstuur persoonlijk bedankje'}</button></div>
 </form>;
}
function ClosedFamilyThanks({portals,submissions,legacy,onSaved}:{portals:ArrivalPortal[];submissions:ClosedSubmission[];legacy:PortalThank[];onSaved:()=>Promise<void>}){
 const [mode,setMode]=useState<'all'|'personal'|null>(null),[portalId,setPortalId]=useState(''),[search,setSearch]=useState(''),[notice,setNotice]=useState('');
 useEffect(()=>{
  let frame:number|undefined;
  const scroll=()=>{const id=window.location.hash.slice(1);if(['thanks-all-houses','thanks-personal-house','thanks-sent-history'].includes(id))frame=requestAnimationFrame(()=>document.getElementById(id)?.scrollIntoView({block:'start'}));};
  scroll();window.addEventListener('hashchange',scroll);return()=>{if(frame!==undefined)cancelAnimationFrame(frame);window.removeEventListener('hashchange',scroll);};
 },[]);
 const all=submissions.find(item=>item.kind==='all'),personal=submissions.find(item=>item.kind==='personal'&&item.portalId===portalId),selected=portals.find(portal=>portal.id===portalId);
 const save=async()=>{await onSaved();setNotice(mode==='all'?'Jullie bedankje is naar alle huizen gestuurd.':'Jullie persoonlijke bedankje is opgeslagen.');};
 return <section id="closed-family-thanks" className="portal-thanks portal-thanks-family" aria-labelledby="family-thanks-title">
  <header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><MessageCircleHeart size={25}/></span><div><p>Een warm gebaar</p><h2 id="family-thanks-title">Bedank de huizen van Duindorp</h2><span>Alle deelnemende huizen hebben meegeholpen. Bedanken is vrijwillig en kan ook buiten jullie eigen route.</span></div></header>
  {notice&&<p role="status" className="portal-thanks-family-note">{notice} De e-mails worden apart verwerkt.</p>}
  <div className="portal-thanks-actions closed-thanks-primary"><button id="thanks-all-houses" type="button" className="portal-thanks-send" onClick={()=>{setMode('all');setNotice('');}}>{all?'Algemeen bedankje bekijken of aanpassen':'Bedank alle huizen'}</button><button id="thanks-personal-house" type="button" className="portal-thanks-cancel" onClick={()=>{setMode('personal');setNotice('');}}>Geef een huis een extra bedankje</button></div>
  {mode==='all'&&<ClosedThanksForm key={all?.id??'all-new'} kind="all" saved={all} targetCount={portals.length} onSaved={save} onCancel={()=>setMode(null)}/>}
  {mode==='personal'&&<div className="closed-thanks-personal"><label>Zoek een deelnemend huis<input type="search" value={search} onChange={event=>setSearch(event.target.value)} placeholder="Poortnaam of wereld"/></label><label>Kies een huis<select value={portalId} onChange={event=>setPortalId(event.target.value)}><option value="">Kies een deelnemende poort…</option>{portals.filter(portal=>(portal.name+' '+portal.world).toLocaleLowerCase('nl').includes(search.toLocaleLowerCase('nl'))).map(portal=><option key={portal.id} value={portal.id}>{portal.name} · {portal.world}</option>)}</select></label>{selected&&<ClosedThanksForm key={selected.id+':'+(personal?.id??'new')} kind="personal" portal={selected} saved={personal} targetCount={1} onSaved={save} onCancel={()=>setMode(null)}/>}</div>}
  <div id="thanks-sent-history" className="closed-thanks-history"><h3>Jullie verstuurde bedankjes</h3>{submissions.length?submissions.map(item=><article key={item.id}><strong>{item.kind==='all'?'Aan alle huizen':portals.find(portal=>portal.id===item.portalId)?.name??'Persoonlijk bedankje'}</strong><p>{item.choice&&thankMessage(item.choice)}</p>{item.message&&<p className="closed-thanks-preserve">{item.message}</p>}<small>{item.processedCount}/{item.targetCount} ontvangsten verwerkt · {new Date(item.createdAt).toLocaleString('nl-NL',{timeZone:'Europe/Amsterdam'})}</small><button type="button" className="portal-thanks-cancel" onClick={()=>{setMode(item.kind);setPortalId(item.portalId??'');}}>Aanpassen</button></article>):<p>Jullie hebben nog geen bedankje verstuurd.</p>}
   {legacy.length>0&&<details><summary>Eerder tijdens de avond bewaard ({legacy.length})</summary>{legacy.map(item=><p key={item.portalId}>{portals.find(portal=>portal.id===item.portalId)?.name??'Een bezochte poort'}: {thankMessage(item.choice)}</p>)}</details>}
  </div>
 </section>;
}
const mailStatusLabels:Record<string,string>={pending:'In wachtrij',processing:'In verwerking',deferred:'Uitgesteld',accepted:'Provider geaccepteerd',delivered:'Bezorgd',failed:'Mislukt',suppressed:'Geblokkeerd',unknown:'Uitkomst onbekend',validated:'Test gecontroleerd'};
export function HousePortalThanks({portalId}:{portalId?:string}){
 const [inbox,setInbox]=useState<HouseInbox|null>(null),[error,setError]=useState(''),[busy,setBusy]=useState(false);
 const generation=useRef(0),active=useRef<number|null>(null);
 const load=useCallback(async(before?:string)=>{
  const current=generation.current;if(active.current===current)return;active.current=current;setBusy(true);
  try{const query=new URLSearchParams({...portalId?{portalId}:{},...before?{before}:{}});const response=await fetch('/api/redesign/thanks-inbox?'+query,{cache:'no-store'});
   if(response.status===401||response.status===403){if(current===generation.current)setInbox(null);return;}
   if(!response.ok)throw new Error();const data:HouseInbox=await response.json();if(current===generation.current){setInbox(prior=>before&&prior?{...data,messages:[...prior.messages,...data.messages]}:data);setError('');}
  }catch{if(current===generation.current)setError('De ontvangen bedankjes konden niet worden opgehaald.');}finally{if(active.current===current)active.current=null;if(current===generation.current)setBusy(false);}
 },[portalId]);
 useEffect(()=>{const current=generation.current+1;generation.current=current;const timer=setTimeout(()=>void load(),0);return()=>{generation.current=current+1;clearTimeout(timer);};},[load]);
 const visibleInbox=inbox&&(!portalId||inbox.portalId===portalId)?inbox:null;
 async function markRead(id:string){const current=generation.current;try{const response=await fetch('/api/redesign/thanks-read',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({receiptId:id})});if(!response.ok)throw new Error();if(current!==generation.current)return;setInbox(prior=>prior?{...prior,unread:Math.max(0,prior.unread-(prior.messages.some(item=>item.id===id&&!item.read)?1:0)),messages:prior.messages.map(item=>item.id===id?{...item,read:true}:item)}:prior);}catch{setError('Gelezen-status kon niet worden bewaard.');}}
 return <><section className="portal-thanks portal-thanks-house" aria-labelledby="house-received-thanks"><header className="portal-thanks-heading"><span className="portal-thanks-heading-icon"><Heart size={25}/></span><div><p>Van de gezinnen</p><h2 id="house-received-thanks">Bedankjes van deelnemers</h2><span>{visibleInbox?.portalName} · {visibleInbox?.total??0} ontvangen · {visibleInbox?.unread??0} ongelezen</span></div></header>
  {error&&<p role="alert" className="portal-thanks-error">{error}</p>}<button className="portal-thanks-cancel" type="button" disabled={busy} onClick={()=>void load()}>Bedankjes vernieuwen</button>
  <div className="closed-thanks-history">{visibleInbox?.messages.map(item=><article key={item.id} className={item.read?'':'is-unread'}><strong>{item.kind==='all'?'Algemeen bedankje':'Extra persoonlijk bedankje'} {!item.read&&<span>· Nieuw</span>}</strong><p>{item.senderLabel} · {new Date(item.receivedAt).toLocaleString('nl-NL',{timeZone:'Europe/Amsterdam'})}</p>{item.choice&&<p>{thankMessage(item.choice)}</p>}{item.message&&<p className="closed-thanks-preserve">{item.message}</p>}<small>{Object.entries(item.mailCounts).filter(([,count])=>count>0).map(([status,count])=>`${mailStatusLabels[status]??'Verwerking'}: ${count}`).join(' · ')||'Nog geen mailontvangers beschikbaar'}</small>{item.missingContacts>0&&<p>Voor {item.missingContacts} bewonerskoppeling(en) ontbreekt een bevestigd e-mailadres. Het bedankje blijft hier beschikbaar; na contactherstel wordt de ontbrekende mail eenmalig klaargezet.</p>}{((item.mailCounts.failed??0)+(item.mailCounts.suppressed??0)+(item.mailCounts.unknown??0)>0)&&<p>Een mail kon niet worden bevestigd of is geblokkeerd. Het bericht is hier wel opgeslagen.</p>}{!item.read&&<button type="button" className="portal-thanks-cancel" onClick={()=>void markRead(item.id)}>Markeer als gelezen</button>}</article>)}</div>
  {visibleInbox?.total===0&&<p>Hier verschijnen de bedankjes die gezinnen na de centrale afsluiting bewust aan jullie poort sturen.</p>}{visibleInbox?.nextCursor&&<button className="portal-thanks-cancel" type="button" disabled={busy} onClick={()=>void load(visibleInbox.nextCursor!)}>Meer bedankjes laden</button>}
 </section><LegacyHousePortalThanks portalId={portalId}/></>;
}
