"use client";
import {useCallback,useEffect,useRef,useState} from 'react';
import type {AuthChangeEvent,Session} from '@supabase/supabase-js';
import {Download,Printer,QrCode,RefreshCw,ShieldCheck,CheckCircle2} from 'lucide-react';
import {gateArrivalUrl} from '@/lib/redesign/gate-credentials';
import {createGatePosterPdf,loadPosterFonts,type PosterMode} from '@/lib/redesign/pdf-writer';
import {createClient} from '@/lib/supabase/client';
import '../../modern/gate-poster.css';
type Gate={id:string;code?:string;systemCode?:string;name:string;version:number};
type Credential={credential?:string;shortCode?:string;credentialRevision:number;legacy:boolean;origin:string;eventDate:string;portalVersion:number;canRotate?:boolean};
type GatePosterProps={portal:Gate;canRotate?:boolean;disabled?:boolean;onRefresh?:()=>void|Promise<void>};
export function GatePoster(props:GatePosterProps){return <GatePosterSession key={props.portal.id} {...props}/>;}
function GatePosterSession({portal,canRotate,disabled=false,onRefresh}:GatePosterProps){
 const [value,setValue]=useState<Credential|null>(null),[mode,setMode]=useState<PosterMode>('mono'),[preview,setPreview]=useState(''),[busy,setBusy]=useState(false),[notice,setNotice]=useState(''),[error,setError]=useState(''),[loading,setLoading]=useState(true);
 const sequence=useRef(0),controller=useRef<AbortController|null>(null),rotating=useRef(false),material=useRef<Credential|null>(null);
 const gateCode=portal.code||portal.systemCode||'Poort';
 const cancelRequest=useCallback(()=>{sequence.current++;controller.current?.abort();},[]);
 const clearPrivate=useCallback(()=>{cancelRequest();material.current=null;setValue(null);setPreview('');setLoading(false);},[cancelRequest]);
 const prepare=useCallback(async(data:Credential,ticket:number)=>{
  if(!data.credential||!data.shortCode)throw new Error(data.legacy?'De bestaande poster blijft geldig, maar de afdrukbare code kon nog niet worden opgehaald. Probeer opnieuw of neem contact op met de organisatie.':'Er is nog geen afdrukbare bezoekcode beschikbaar. Controleer de goedkeuring van jullie poort of neem contact op met de organisatie.');
  if(sequence.current!==ticket)return;
  if(material.current?.credential!==data.credential){setValue(null);setPreview('');}
  const {default:QR}=await import('qrcode');
  const svg=await QR.toString(gateArrivalUrl({id:portal.id},data.credential,data.origin),{type:'svg',margin:4,errorCorrectionLevel:'M',color:{dark:'#000000',light:'#ffffff'}});
  if(sequence.current===ticket){material.current=data;setValue(data);setPreview('data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg));}
 },[portal.id]);
 const load=useCallback(async()=>{
  if(rotating.current)return;
  const ticket=++sequence.current;controller.current?.abort();const request=new AbortController();controller.current=request;
  const timeout=setTimeout(()=>request.abort(),8_000);setLoading(true);setError('');
  try{
   const response=await fetch('/api/redesign/poster?'+new URLSearchParams({portalId:portal.id}),{cache:'no-store',signal:request.signal});
   if(sequence.current!==ticket)return;
   if(response.status===401||response.status===403){material.current=null;setValue(null);setPreview('');throw new Error('De bezoekcode is niet beschikbaar voor deze aanmelding. Open jullie Poortkamer opnieuw of log opnieuw in.');}
   if(!response.ok)throw new Error('De QR-code kon niet worden opgehaald. De laatst opgehaalde code blijft zichtbaar. Probeer opnieuw.');
   await prepare(await response.json() as Credential,ticket);
  }catch(cause){if(sequence.current===ticket)setError(cause instanceof Error&&cause.name!=='AbortError'?cause.message:'Het ophalen duurde te lang. Probeer opnieuw; jullie bestaande code wordt niet vervangen.');}
  finally{clearTimeout(timeout);if(sequence.current===ticket)setLoading(false);}
 },[portal.id,prepare]);
 useEffect(()=>{const timer=setTimeout(()=>void load(),0);return()=>{clearTimeout(timer);cancelRequest();};},[load,portal.version,cancelRequest]);
 useEffect(()=>{
  const client=createClient();if(!client)return;let actor:string|null=null;
  const {data}=client.auth.onAuthStateChange((event:AuthChangeEvent,session:Session|null)=>{const next=session?.user.id??null;if(event==='SIGNED_OUT'||!next||actor&&actor!==next)clearPrivate();actor=next;});
  return()=>data.subscription.unsubscribe();
 },[clearPrivate]);
 function file(){if(!value?.credential||!value.shortCode)return null;return createGatePosterPdf({gateName:portal.name,gateCode,shortCode:value.shortCode,arrivalUrl:gateArrivalUrl(portal,value.credential,value.origin),revision:value.credentialRevision,eventDate:value.eventDate},mode);}
 function blobUrl(){const bytes=file();return bytes?URL.createObjectURL(new Blob([new Uint8Array(bytes)],{type:'application/pdf'})):null;}
 async function download(){try{await loadPosterFonts();}catch{setError('De PDF-lettertypen konden niet worden geladen. Controleer de verbinding en probeer opnieuw.');return;}const url=blobUrl();if(!url)return;const a=document.createElement('a');a.href=url;a.download=`Poort-${gateCode}-${mode==='mono'?'zwart-wit':'kleur'}.pdf`;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);setNotice('De A4-PDF is gedownload. Print op 100% en houd de QR-code volledig zichtbaar.');}
 async function print(){try{await loadPosterFonts();}catch{setError('De PDF-lettertypen konden niet worden geladen. Download opnieuw zodra de verbinding hersteld is.');return;}const url=blobUrl();if(!url)return;const frame=document.createElement('iframe');frame.style.position='fixed';frame.style.width='1px';frame.style.height='1px';frame.style.opacity='0';frame.src=url;frame.title='QR-poster afdrukken';document.body.appendChild(frame);frame.onload=()=>{try{frame.contentWindow?.focus();frame.contentWindow?.print();setNotice('De printweergave is geopend. Werkt dit niet op je telefoon? Download dan de PDF.');}catch{download();}setTimeout(()=>{frame.remove();URL.revokeObjectURL(url);},60000);};}
 async function rotate(){
  if(rotating.current||disabled||!value?.canRotate||canRotate===false||!confirm('Een nieuwe code maakt alle vorige QR-posters van deze poort ongeldig. Print daarna de nieuwe poster en vervang de oude. Nieuwe code maken?'))return;
  rotating.current=true;setBusy(true);setLoading(true);setError('');const ticket=++sequence.current;controller.current?.abort();const request=new AbortController();controller.current=request;
  const timeout=setTimeout(()=>request.abort(),8_000);let refresh=false;const portalVersion=value.portalVersion;material.current=null;setValue(null);setPreview('');
  try{
   const response=await fetch('/api/redesign/poster',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({portalId:portal.id,version:portalVersion,confirmRotation:true}),cache:'no-store',signal:request.signal});
   if(sequence.current!==ticket)return;
   if(!response.ok)throw new Error('Vernieuwen is niet bevestigd. Haal de actuele code opnieuw op; eerdere posters worden niet nogmaals vervangen.');
   await prepare(await response.json() as Credential,ticket);
   if(sequence.current===ticket){setNotice('Nieuwe code actief. Print opnieuw en vervang alle oude posters.');refresh=true;}
  }catch(cause){if(sequence.current===ticket)setError(cause instanceof Error&&cause.name!=='AbortError'?cause.message:'Vernieuwen is niet bevestigd. Haal de actuele code opnieuw op; druk niet opnieuw op vernieuwen.');}
  finally{clearTimeout(timeout);rotating.current=false;setBusy(false);if(sequence.current===ticket)setLoading(false);}
  if(refresh){try{await onRefresh?.();}catch{setError('De nieuwe code is actief. De Poortkamer kon nog niet opnieuw worden opgehaald.');}}
 }
 return <section className="gate-poster-workspace" data-tutorial="gate-qr"><div className="gate-poster-intro"><p className="kicker">Ontvang je volgende bezoekers</p><h1>Jullie QR-code, klaar voor de deur.</h1><p>Hang deze A4-poster goed zichtbaar bij jullie poort. De groepsleider scant de code, bevestigt de aanwezige kinderen en ziet daarna de volgende bestemming.</p></div><div className="gate-poster-grid"><div className="gate-poster-controls"><div className="gate-poster-card"><span className="gate-poster-icon"><QrCode/></span><h2>Print jullie poortposter</h2><p>{gateCode} · {portal.name}</p><fieldset className="gate-poster-modes"><legend>Uitvoering</legend><label className={mode==='mono'?'selected':''}><input type="radio" name="poster-mode" checked={mode==='mono'} onChange={()=>setMode('mono')}/><span>Zwart-wit<small>Zuinig met inkt, veel contrast</small></span></label><label className={mode==='colour'?'selected':''}><input type="radio" name="poster-mode" checked={mode==='colour'} onChange={()=>setMode('colour')}/><span>Kleur<small>Donkerblauw met warm oranje</small></span></label></fieldset><div className="gate-poster-buttons"><button className="btn" disabled={!value?.credential||busy} onClick={download}><Download size={17}/>Download A4-PDF</button><button className="btn outline" disabled={!value?.credential||busy} onClick={print}><Printer size={17}/>Afdrukken</button><button className="btn outline" disabled={busy||loading} onClick={()=>void load()}><RefreshCw size={17}/>Code opnieuw ophalen</button></div>{value&&<p className="gate-poster-code">Korte bezoekcode <strong>{value.shortCode}</strong><small>Versie {value.credentialRevision||1}</small></p>}{notice&&<p className="gate-poster-notice" role="status"><CheckCircle2 size={17}/>{notice}</p>}{error&&<p className="gate-poster-error" role="alert">{error}<button disabled={busy||loading} onClick={()=>void load()}>Opnieuw proberen</button></p>}</div><div className="gate-poster-card"><h3><ShieldCheck size={18}/>Zo werkt het aan de deur</h3><ol><li>Print op A4, op 100% of ware grootte.</li><li>Hang de poster vlak en op een goed verlichte plek.</li><li>Laat de groepsleider scannen in de route of met de telefooncamera.</li><li>De korte code werkt ook als scannen niet lukt.</li></ol><p className="gate-poster-demo">Bewaar de poster veilig. Opnieuw downloaden of deze pagina vernieuwen verandert jullie geldige code niet.</p></div>{value?.canRotate&&canRotate!==false&&<details className="gate-poster-rotate"><summary>Een nieuwe bezoekcode nodig?</summary><p>Alleen vernieuwen wanneer de oude code niet meer gebruikt mag worden. Bestaande posters werken daarna niet meer.</p><button className="btn outline" disabled={disabled||busy} onClick={()=>void rotate()}><RefreshCw size={16}/>Nieuwe code maken</button></details>}</div><div className={'gate-paper-preview '+mode} aria-label={`Voorbeeld A4-poster in ${mode==='mono'?'zwart-wit':'kleur'}`}><header><small>DE DUINDORPSE POORTEN<br/>VAN HALLOWEEN</small><p>{value?.eventDate?new Date(value.eventDate+'T12:00:00Z').toLocaleDateString('nl-NL',{dateStyle:'long',timeZone:'Europe/Amsterdam'}):'JULLIE HALLOWEENAVOND'}</p><strong>Welkom bij deze poort</strong></header><h2>{portal.name}</h2><p className="gate-paper-sub">{gateCode} · SCAN BIJ AANKOMST</p>{preview?<img src={preview} alt="QR-code om aankomst bij deze poort te bevestigen"/>:<div className="gate-paper-loading">{loading?'QR-code ophalen…':'QR-code nog niet beschikbaar. Probeer opnieuw bij de code-instellingen.'}</div>}<div className="gate-paper-code"><small>LUKT SCANNEN NIET? VUL DEZE CODE IN:</small><strong>{value?.shortCode||'Nog niet beschikbaar'}</strong></div><ol><li>Open de route van jullie groep.</li><li>Scan deze QR of vul de korte poortcode in.</li><li>Bevestig wie erbij is. De volgende poort verschijnt.</li></ol><footer>Blijf samen met jullie groep. Overslaan mag.<b>ALLEEN DE GROEPSLEIDER BEVESTIGT DE AANKOMST</b></footer></div></div></section>;
}
