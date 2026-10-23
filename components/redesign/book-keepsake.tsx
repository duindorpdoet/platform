"use client";
import { useState } from 'react';
import { Download, CheckCircle2, ShieldCheck, LoaderCircle } from 'lucide-react';
import type { BookSnapshot } from '@/lib/poortenboek/model';
import { createBookKeepsakePdf, loadBookKeepsakeFonts } from '@/lib/redesign/book-keepsake-pdf';
import '../../modern/book-keepsake.css';

export function BookKeepsake({snapshot}:{snapshot:BookSnapshot}){
 const [busy,setBusy]=useState(false),[notice,setNotice]=useState(''),[error,setError]=useState('');
 async function download(){if(busy)return;setBusy(true);setNotice('');setError('');try{await loadBookKeepsakeFonts();const pdf=createBookKeepsakePdf(snapshot),url=URL.createObjectURL(new Blob([new Uint8Array(pdf)],{type:'application/pdf'})),link=document.createElement('a');link.href=url;link.download=`Poortenboek-${snapshot.firstName.replace(/[^a-zA-Z0-9À-ÿ_-]/g,'-')||'avonturier'}.pdf`;document.body.appendChild(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),60_000);setNotice('Je persoonlijke PDF staat klaar in je downloads. Je kunt hem bewaren of op A4 afdrukken.');}catch{setError('De bewaarkaart kon even niet worden gemaakt. Controleer je verbinding en probeer opnieuw.');}finally{setBusy(false);}}
 return <section className="pb-keepsake" data-tutorial="book-keepsake"><div className="pb-keepsake-icon"><Download size={22}/></div><div><p className="pb-eyebrow">Alleen van jou</p><h3>Bewaar jouw avontuur</h3><p>{(snapshot.journey.complete||Boolean(snapshot.farewell))?'Jouw avond, je eigen zegels en jouw gekozen licht in een mooie PDF.':'Download alvast jouw tussenstand. Later maak je eenvoudig een nieuwe kaart met je nieuwste zegels.'}</p><span className="pb-keepsake-privacy"><ShieldCheck size={14}/>Alleen jouw voornaam en jouw avontuur. Zonder adressen of persoonlijke codes.</span></div><button className="pb-button" disabled={busy} onClick={()=>void download()}>{busy?<LoaderCircle className="spin" size={17}/>:<Download size={17}/>} {busy?'PDF maken…':'Download mijn bewaarkaart'}</button>{notice&&<p className="pb-keepsake-feedback" role="status"><CheckCircle2 size={16}/>{notice}</p>}{error&&<p className="pb-keepsake-feedback error" role="alert">{error}</p>}</section>;
}
