"use client";
/* eslint-disable react-hooks/set-state-in-effect -- The persistent guide follows external Next routes and server progress without mutating event data. */
import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Dialog as Primitive } from 'radix-ui';
import { ArrowLeft, ArrowRight, BookOpen, Check, CheckCircle2, ChevronDown, ExternalLink, HelpCircle, MessageCircle, ShieldCheck, Sparkles, X } from 'lucide-react';
import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import {configureArrivalSync} from '@/lib/redesign/arrival-sync';
import { createClient } from '@/lib/supabase/client';
import {consumeWelcomeReplay} from "@/lib/account/welcome-replay";
import { GUIDANCE_VERSION, guidanceRole, resumeGuidancePath, type GuidanceRecord } from '@/lib/redesign/guidance-state';
import '../../modern/guidance.css';
import {GuidanceRequests} from '@/lib/redesign/guidance-requests';
import {GuidanceRequestError,guidanceProblem,readGuidanceResponse,type GuidanceProblem} from '@/lib/redesign/guidance-errors';
import { WELCOME_VERSION } from '@/lib/account/model';
import { InstallControls } from '@/components/pwa/install-controls';
import { PushNotificationSettings } from '@/components/pwa/pwa-experience';
import type {AuthChangeEvent,Session} from '@supabase/supabase-js';

export const GENERAL_WHATSAPP = 'https://chat.whatsapp.com/KwdGfmllTNW5tPU4widIhg';
export const HOUSE_WHATSAPP = 'https://chat.whatsapp.com/EaFlwGROVpW3N7YazyTx47';
type HouseView = { tab: string; moreSection?: string; preparationSection?: string };
type Step = { label: string; title: string; text: string; tip: string; path: string; target: string; houseView?: HouseView };
const parentSteps: Step[] = [
  { label: 'Welkom', title: 'Jullie hele avond op één plek', text: 'Dit is jullie persoonlijke omgeving. Hier vind je de deelnemende kinderen, de startafspraak, jullie groep en straks de route. Je hoeft geen adressen te onthouden.', tip: 'Deze rondleiding wijzigt geen inschrijving of betaling. Met Verder bekijken we steeds een echt scherm.', path: '/omgeving/meeloper/nu', target: '#participant-content' },
  { label: 'Inschrijving', title: 'Controleer wie er meegaan', text: 'Bij jullie inschrijving staan de kinderen en de deelnamegegevens. Controleer de namen en laat een correctie of afmelding via de omgeving aan de organisatie weten.', tip: 'Een wijzigingsverzoek wordt eerst beoordeeld. Kijk daarna of de organisatie de wijziging heeft bevestigd.', path: '/mijn-inschrijving', target: '.registration-dashboard, .registration-card, #main-content' },
  { label: 'Betaling', title: 'Een betaalstatus per kind', text: 'In de Nachtpas zie je welke kinderen zijn aangemeld en of hun betaling is bevestigd. Een verstuurde betaallink of een eigen betaalmelding is nog geen bevestigde ontvangst.', tip: 'Is iets nog niet bevestigd? Neem contact op met de organisatie; betaal niet opnieuw zonder overleg.', path: '/omgeving/meeloper/nachtpas', target: '.participant-children-card, .night-pass' },
  { label: 'Startafspraak', title: 'Kijk naar jullie eigen tijd en plek', text: 'Bij Mijn groep staan het toegewezen startmoment, de startplek en de groepscode. Ga naar die afspraak en houd rekening met de kinderen die nog moeten aansluiten.', tip: 'Tijdsvoorkeuren zijn wensen. De gepubliceerde startafspraak van de organisatie is leidend.', path: '/omgeving/meeloper/groep', target: '.group-summary, #participant-content' },
  { label: 'Samenlopen', title: 'Samen is pas samen na bevestiging', text: 'Een samenloopcode helpt de organisatie om groepen bij elkaar in te delen. Een verzoek betekent nog niet dat de indeling al is aangepast.', tip: 'Controleer de definitieve groep en startafspraak. De organisatie houdt rekening met beschikbare ruimte en veilige groepsgrootte.', path: '/mijn-inschrijving', target: '.together-card, .registration-dashboard, #main-content' },
  { label: 'Mijn groep', title: 'Houd jullie groep bij elkaar', text: 'Mijn groep toont de gekoppelde deelnemers en de voortgang. Spreek af wie de telefoon en route bedient, zodat jullie niet tegelijk verschillende handelingen uitvoeren.', tip: 'Kinderen blijven bij hun eigen verantwoordelijke volwassene. Meekijkers volgen alleen de beperkte voortgang.', path: '/omgeving/meeloper/groep', target: '.group-summary, #participant-content' },
  { label: 'Vertrekken', title: 'Controleer de aanwezigheid', text: 'Voor vertrek bevestigt de groepsleider welke kinderen er werkelijk zijn. Pas na de aanwezigheidscontrole kan de tocht beginnen. Tijdens een lopende tocht zie je hier de actuele opdracht.', tip: 'Start pas als iedereen klaarstaat en de toegewezen starttijd is bereikt. Wacht bij een blokkade op hulp van de organisatie.', path: '/omgeving/meeloper/route', target: '.attendance-panel, .group-pre-event, .group-route-context' },
  { label: 'De route', title: 'Je ziet steeds de huidige bestemming', text: 'De naam, het adres en de wereld van de vrijgegeven poort staan bovenaan. De volgende adressen verschijnen stap voor stap, zodat de groepen netjes over de wijk worden verdeeld.', tip: 'Werkt de kaart niet? Het adres blijft leesbaar. Blijf bij je groep en vraag hulp als je de locatie niet kunt vinden.', path: '/omgeving/meeloper/route', target: '#route-destination' },
  { label: 'Aankomst scannen', title: 'Scan de poster bij de juiste poort', text: 'Gebruik QR scannen bij de deur. De korte bezoekcode op de poster werkt ook. Controleer de aankomst en de kinderen in het bevestigingsscherm; daarna verschijnt de volgende poort.', tip: 'Alleen de code van jullie huidige poort werkt. Scannen van een oude of andere poort mag de route nooit overslaan.', path: '/omgeving/meeloper/route', target: '#route-scan' },
  { label: 'Meedoen mag, hoeft niet', title: 'Een kind mag altijd een stap overslaan', text: 'Een te spannende beleving hoeft niet. Ieder kind dat met de groep bij de poort aankomt, krijgt na de scan gewoon een zegel. Ook als het buiten blijft of liever niet meedoet.', tip: 'Laat een kind niet alleen wachten. Blijf samen; bij een gesloten poort of onveilige situatie neem je contact op met de organisatie.', path: '/omgeving/meeloper/route', target: '#route-children' },
  { label: 'Nachtpas', title: 'Jullie deelname blijft bij de hand', text: 'De Nachtpas bundelt de kinderen, groepscode, startinformatie en deelnamestatus. Laat hem zien als de organisatie daarom vraagt.', tip: 'De Nachtpas is geen toegang om op eigen initiatief andere poorten te bezoeken. Volg steeds de vrijgegeven route.', path: '/omgeving/meeloper/nachtpas', target: '.night-pass' },
  { label: 'Poortenboek', title: 'Open veilig het eigen kindboek', text: 'Kies vanuit Mijn omgeving het Poortenboek van je eigen ingeschreven kind. Bij meerdere kinderen kies je bewust welk boek je opent; je ouderlogin blijft bewaard. Met de ouderingang kun je weer van kind wisselen.', tip: 'De kindcode blijft beschikbaar voor zelfstandig inloggen. Ontbrekende werelden kunnen als afzonderlijk bonuszegel bij een echte snoeppoortaankomst van het type Anders verschijnen.', path: '/omgeving/meeloper/meer', target: '.poortenboek-parent-child, [aria-label="Poortenboeken van jouw kinderen"]' },
  { label: 'Updates', title: 'Lees wijzigingen van de organisatie', text: 'In Meer staan de organisatie-updates en jullie voorkeuren. Controleer deze berichten ook als je WhatsApp gebruikt: de actuele opdracht en startafspraak blijven in de omgeving staan.', tip: 'De WhatsApp-community is handig voor informatie en contact. Voor een verzoek over jouw eigen groep gebruik je de hulpknop.', path: '/omgeving/meeloper/meer', target: '.embedded-updates' },
  { label: 'Hulp & klaar', title: 'Je bent klaar om samen op pad te gaan', text: 'Gebruik Hulp van de organisatie voor een probleem onderweg. Beschrijf jullie groepscode, poort en wat er misgaat. Bij direct gevaar bel je 112.', tip: 'Via Hulp & community kun je deze rondleiding altijd opnieuw bekijken en de WhatsApp-links terugvinden.', path: '/omgeving/meeloper/meer', target: '.participant-contact-compact' },
];
function houseStep(label: string, title: string, text: string, tip: string, view: HouseView, target = '#poortkamer-content'): Step { return { label, title, text, tip, path: '/mijn-huis', target, houseView: view }; }
const houseSteps: Step[] = [
  houseStep('Welkom', 'Dit is jullie Poortkamer', 'Hier bereid je de poort voor en ontvang je de groepen. Een concept wacht nog op activering; een ingetrokken poortdeelname geeft geen toegang meer tot deze poort. Je eventuele ouderomgeving blijft zelfstandig beschikbaar. Je ziet jullie status, de verwachte bezoekers, het team en berichten van de organisatie bij elkaar.', 'De rondleiding wijzigt geen ontvangststatus of gegevens. Met Verder gaan we door jullie echte schermen.', { tab: 'night' }, '[data-guide="house-overview"], #poortkamer-content'),
  houseStep('Nachtwacht', 'Een rustig overzicht tijdens de avond', 'De Nachtwacht laat zien hoeveel groepen en kinderen jullie al hebben ontvangen en hoeveel er nog worden verwacht. De eerstvolgende groep staat apart in beeld.', 'Gepland is een verwachting, Onderweg volgt de uitgegeven bestemming en Aanwezig volgt een bevestigde aankomst. Een verwacht tijdvenster is een planning. Een groep kan onderweg iets eerder of later zijn; ververs bij twijfel.', { tab: 'night' }, '[data-guide="house-overview"], #poortkamer-content'),
  houseStep('Bezoeken', 'Bekijk de volgende groep', 'Bij Bezoeken kun je wisselen tussen wat nu komt, de verwachte instroom en eerdere bezoeken. Gebruik dit om de ontvangst klaar te zetten.', 'De planning is geen openbare adressenlijst. Deel informatie over groepen en kinderen niet buiten het eigen poortteam.', { tab: 'visits' }, '[data-guide="house-visits"], #poortkamer-content'),
  houseStep('Ontvangststatus', 'Open, Pauze of Gestopt', 'Open betekent dat de poort kan ontvangen. Pauze gebruik je voor een tijdelijke onderbreking. Gestopt betekent dat je geen nieuwe bezoeken meer kunt ontvangen.', 'Geef een wijziging direct door in de Poortkamer. Overleg met de organisatie over groepen die al onderweg zijn.', { tab: 'night' }, '[data-guide="house-status"], [aria-label="Ontvangststatus"]'),
  houseStep('QR-poster', 'Print de code van jullie eigen poort', 'Bij QR & print staat jullie unieke poster. Kies kleur of zwart-wit en download de PDF op A4. De QR-code en korte bezoekcode blijven op beide varianten hetzelfde.', 'Hang hem droog, vlak en goed zichtbaar bij de ingang. Test de leesbaarheid met een telefoon en zorg dat de code goed is verlicht.', { tab: 'more', moreSection: 'qr' }, '[data-tutorial="gate-qr"], #poortkamer-content'),
  houseStep('Scannen', 'De groep bevestigt zelf de aankomst', 'De groepsleider scant jullie poster, controleert wie de poort bezoekt en bevestigt de aankomst. Daarna komt de volgende bestemming beschikbaar voor die groep.', 'Een nieuwe QR-code maakt een oude poster ongeldig. Vernieuw de code alleen als dat nodig is en print daarna de nieuwe poster.', { tab: 'more', moreSection: 'qr' }, '[data-tutorial="gate-qr"], #poortkamer-content'),
  houseStep('Team', 'Verdeel rollen en taken', 'Bij Team staan de gekoppelde poortwachters. De hoofdpoortwachter beheert de toegang; rollen en taken helpen om ontvangst, acteren, veiligheid en techniek te verdelen.', 'Geef alleen de toegang die iemand nodig heeft. Trek een oude uitnodiging of toegang in als iemand niet meer helpt.', { tab: 'team' }, '[data-guide="house-team"], #poortkamer-content'),
  houseStep('Checklist', 'Controleer de voorbereiding samen', 'De voorbereidingslijst helpt om locatie, ontvangst, team en praktische afspraken langs te lopen. Rond de punten bewust af in overleg met jullie team.', 'Zorg voor een vrije ingang, voldoende verlichting en duidelijke afspraken over rook, geluid en eventuele allergenen.', { tab: 'more', moreSection: 'preparation', preparationSection: 'checklist' }),
  houseStep('Presentatie', 'Zo verschijnt jullie poort in het verhaal', 'Bij Presentatie bekijk je de naam, wereld en voorstelling van jullie poort. Dit helpt om wat kinderen in hun Poortenboek zien te laten aansluiten op de ontvangst.', 'Gebruik passende beelden en eenvoudige, vriendelijke informatie. Vermeld aandachtspunten zoals rook of flitsen duidelijk.', { tab: 'more', moreSection: 'preparation', preparationSection: 'presentation' }),
  houseStep('Oefenen', 'Probeer het vooraf rustig uit', 'Gebruik Oefenen om de bediening en aankomststappen te leren kennen vóór de drukte begint. Spreek met je team af wie de telefoon bedient.', 'Een oefening is geen echte bezoekregistratie. Controleer vlak voor de avond nogmaals de actuele poortstatus.', { tab: 'more', moreSection: 'preparation', preparationSection: 'simulation' }),
  houseStep('Berichten', 'Overleg op de juiste plek', 'Bij Berichten lees je de organisatie-updates en spreek je met het team. De WhatsApp-community voor huizen is een extra plek voor praktische informatie.', 'Jullie speciale huizenlink staat bij Hulp & community. Deel persoonlijke groeps- of kindgegevens alleen waar dat nodig is.', { tab: 'messages' }, '[data-guide="house-messages"], #poortkamer-content'),
  houseStep('Hulp', 'Meld een probleem direct', 'Bij Hulp & contact kun je de organisatie bereiken of een incident melden. Geef jullie poortcode en de situatie door en zet de ontvangst zo nodig op Pauze.', 'Bij direct gevaar bel je 112. Gebruik WhatsApp niet als vervanging voor spoedhulp.', { tab: 'more', moreSection: 'incident' }),
  houseStep('Instellingen', 'Houd jullie gegevens en voorkeuren actueel', 'Controleer de omschrijving en gegevens van de poort. Kies welke meldingen jullie willen ontvangen en wie gegevens mag aanpassen.', 'Toestemming voor pushmeldingen hangt ook af van de telefoon. Controleer daarom tijdens de avond zelf de Poortkamer.', { tab: 'more', moreSection: 'settings' }),
  houseStep('Terugblik & klaar', 'Sluit de avond samen netjes af', 'Na de laatste ontvangst zet je de poort op de juiste eindstatus en bekijk je de terugblik. Meld eventuele bijzonderheden aan de organisatie.', 'Deze rondleiding blijft beschikbaar via Hulp & community. Je bent klaar om de poort samen te openen!', { tab: 'more', moreSection: 'recap' }),
];
type Tour = { role: 'parent' | 'house'; mandatory: boolean; index: number; returnPath: string };
type Rect = { top: number; left: number; width: number; height: number };
function CommunityLinks({ house }: { house: boolean }) {
  return <div className="guidance-community-links"><a className="guidance-community-link" href={GENERAL_WHATSAPP} target="_blank" rel="noopener noreferrer"><span className="guidance-link-icon"><MessageCircle size={23}/></span><span><strong>Alle deelnemers</strong><small>Duindorpse Poorten · algemene community</small></span><ExternalLink size={17}/></a>{house && <a className="guidance-community-link house" href={HOUSE_WHATSAPP} target="_blank" rel="noopener noreferrer"><span className="guidance-link-icon"><ShieldCheck size={23}/></span><span><strong>Speciaal voor huizen & poortteams</strong><small>Praktisch overleg achter de poorten</small></span><ExternalLink size={17}/></a>}</div>;
}

function GuidanceError({problem,role,onReload}:{problem:GuidanceProblem;role?:'parent'|'house'|null;onReload:()=>void}) {
  const destination=resumeGuidancePath(window.location.pathname+window.location.search,role??'parent');
  return <div className="guidance-save-error" role="alert"><p>{problem.message}</p>{problem.requestId&&<small>Referentie: {problem.requestId}</small>}
    {problem.kind==='session'?<a className="guidance-text-button" href={`/inloggen?next=${encodeURIComponent(destination)}`}>Opnieuw inloggen</a>:problem.kind==='access'?<><Link className="guidance-text-button" href="/omgeving/kiezen">Mijn toegang controleren</Link><a className="guidance-text-button" href="/contact">Contact met de organisatie</a></>:['invalid','conflict'].includes(problem.kind)?<button type="button" className="guidance-text-button" onClick={onReload}>Actuele uitleg opnieuw laden</button>:null}</div>;
}

export function ParticipantGuidance({ path, initial, persist, reload }: { path: string; initial: GuidanceRecord; persist:(input:Record<string,unknown>)=>Promise<GuidanceRecord>;reload:()=>Promise<boolean> }) {
  const router = useRouter();
  const navigate = useCallback((destination: string) => router.push(destination),[router]);
  const requested = guidanceRole(path);
  const role = requested && initial.roles.includes(requested) ? requested : null;
  const record=initial;
  const [saving,setSaving]=useState(false),[saveError,setSaveError]=useState<GuidanceProblem|null>(null);
  const pending=useRef(false),mounted=useRef(true);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  async function save(input: Record<string,unknown>) {
    if(pending.current)return false;
    pending.current=true;setSaving(true);
    try {await persist(input);if(!mounted.current)return false;setSaveError(null);return true;}
    catch(error){if(mounted.current&&!(error instanceof DOMException&&error.name==='AbortError'))setSaveError(error instanceof GuidanceRequestError?error.problem:guidanceProblem());return false;}
    finally {pending.current=false;if(mounted.current)setSaving(false);}
  }
  const [communityOpen, setCommunityOpen] = useState(false);
  const [dockOpen, setDockOpen] = useState(false);
  const [tour, setTour] = useState<Tour | null>(null);
  const [rect, setRect] = useState<Rect | null>(null);
  const [targetFound, setTargetFound] = useState(false);
  const tourTitle = useRef<HTMLHeadingElement>(null);
  const welcomeDue = (record.welcomeVersion ?? 0) < WELCOME_VERSION;
  const showCommunity = Boolean((role || communityOpen) && (welcomeDue || communityOpen));
  const guidanceActive = welcomeDue || showCommunity || Boolean(tour) || Boolean(role && role !== 'viewer' && role !== 'admin' && record.completed[role] !== GUIDANCE_VERSION);
  const steps = tour?.role === 'house' ? houseSteps : parentSteps;
  const step = tour ? steps[tour.index] : null;

  useLayoutEffect(() => {
    document.documentElement.dataset.participantGuidanceActive = String(guidanceActive);
    window.dispatchEvent(new Event('poorten-guidance-status'));
    return () => {
      document.documentElement.dataset.participantGuidanceActive = 'true';
      window.dispatchEvent(new Event('poorten-guidance-status'));
    };
  }, [guidanceActive]);
  useEffect(() => { const open=()=>{consumeWelcomeReplay();setCommunityOpen(true);};if(consumeWelcomeReplay())setCommunityOpen(true);window.addEventListener('poorten-open-welcome',open);return()=>window.removeEventListener('poorten-open-welcome',open); }, []);
  useEffect(() => {
    if (!role || role === 'viewer' || role === 'admin' || welcomeDue || communityOpen || tour || saving) return;
    if (record.completed[role] !== GUIDANCE_VERSION) {
      const saved = record.progress?.[role];
      const count = role === 'house' ? houseSteps.length : parentSteps.length;
      const resumable = saved?.version === GUIDANCE_VERSION && saved.index < count;
      const start = { role, mandatory: true, index: resumable ? saved.index : 0, returnPath: resumable ? saved.returnPath : window.location.pathname + window.location.search };
      setTour({...start,returnPath:resumeGuidancePath(start.returnPath,role)});
    }
  }, [role, welcomeDue, communityOpen, record, path, tour,saving]);
  useEffect(() => {
    if (!tour || !step) { setRect(null); return; }
    setRect(null); setTargetFound(false);
    if (path !== step.path) navigate(step.path);
    let attempts = 0;
    let scrolled = false;
    const update = () => {
      if (step.houseView) window.dispatchEvent(new CustomEvent('poorten-guide-navigate', { detail: step.houseView }));
      const target = Array.from(document.querySelectorAll<HTMLElement>(step.target)).find(el=>{const box=el.getBoundingClientRect();return box.width>0&&box.height>0;});
      if (!target || target.getBoundingClientRect().width < 1) { setRect(null); return; }
      if (!scrolled) { scrolled = true; target.scrollIntoView({ behavior: 'instant', block: 'center' }); }
      const box = target.getBoundingClientRect();
      setTargetFound(true);
      setRect({ top: Math.max(40, box.top - 6), left: Math.max(6, box.left - 6), width: Math.min(box.width + 12, window.innerWidth - 12), height: Math.max(30, Math.min(box.height + 12, window.innerHeight - Math.max(40, box.top) - 12)) });
    };
    const timeout = window.setTimeout(() => { update(); tourTitle.current?.focus(); }, 80);
    const retry = window.setInterval(() => { update(); attempts++; if (attempts > 8) clearInterval(retry); }, 200);
    window.addEventListener('resize', update); window.addEventListener('scroll', update, true);
    return () => { clearTimeout(timeout); clearInterval(retry); window.removeEventListener('resize', update); window.removeEventListener('scroll', update, true); };
  }, [tour, step, path, navigate]);
  async function acknowledge() {
    if(saving)return;
    if(!welcomeDue || await save({action:'acknowledge'})){setCommunityOpen(false);setDockOpen(false);}
  }
  function replay() {
    const nextRole = role === 'house' ? 'house' : 'parent';
    setDockOpen(false); setTour({role:nextRole,mandatory:false,index:0,returnPath:resumeGuidancePath(window.location.pathname+window.location.search,nextRole)});
  }
  async function finish() {
    if (!tour || pending.current || tour.index !== steps.length - 1) return;
    if(tour.mandatory && !await save({action:'tutorial',role:tour.role,version:GUIDANCE_VERSION,index:tour.index,returnPath:resumeGuidancePath(tour.returnPath,tour.role),completed:true}))return;
    const back=resumeGuidancePath(tour.returnPath,tour.role);setTour(null);navigate(back);
  }
  async function moveStep(index:number) {
    if(!tour||pending.current||index<0||index>=steps.length)return;
    if(tour.mandatory && !await save({action:'tutorial',role:tour.role,version:GUIDANCE_VERSION,index,returnPath:resumeGuidancePath(tour.returnPath,tour.role)}))return;
    if(mounted.current)setTour({...tour,index,returnPath:resumeGuidancePath(tour.returnPath,tour.role)});
  }
  function closeReplay() { if (tour && !tour.mandatory) { const back = resumeGuidancePath(tour.returnPath,tour.role); setTour(null); navigate(back); } }
  async function recover(){if(pending.current)return;pending.current=true;setSaving(true);try{if(await reload()){setSaveError(null);setTour(null);}}finally{pending.current=false;if(mounted.current)setSaving(false);}}
  if (!role && !communityOpen) return null;
  return <>
    <div className="guidance-dock"><button className="guidance-dock-toggle" type="button" aria-label="Hulp & community" aria-expanded={dockOpen} aria-controls="guidance-help-card" onClick={() => setDockOpen(!dockOpen)}><HelpCircle size={18}/><span>Hulp & community</span><ChevronDown size={13}/></button>{dockOpen && <aside id="guidance-help-card" className="guidance-help-card" aria-label="Rondleiding en WhatsApp"><div className="guidance-help-heading"><strong>Samen goed op pad</strong><button aria-label="Hulpkaart sluiten" onClick={() => setDockOpen(false)}><X size={17}/></button></div><CommunityLinks house={record.roles.includes('house')}/>{(role === "parent" || role === "house") && <button className="guidance-replay" onClick={replay}><BookOpen size={18}/><span><strong>Bekijk de rondleiding opnieuw</strong><small>{role === 'house' ? '14 stappen door jullie Poortkamer' : '14 stappen door de ouderomgeving'}</small></span><ArrowRight size={17}/></button>}<button className="guidance-text-button" onClick={() => { setCommunityOpen(true); setDockOpen(false); }}>Bekijk de community-melding</button></aside>}</div>
    <Primitive.Root open={showCommunity} onOpenChange={open => { if (!welcomeDue) setCommunityOpen(open); }}><Primitive.Portal><Primitive.Overlay className="guidance-backdrop"/><Primitive.Content className="guidance-community-dialog" onEscapeKeyDown={e => { if (welcomeDue) e.preventDefault(); }} onPointerDownOutside={e => { if (welcomeDue) e.preventDefault(); }}><div className="guidance-dialog-symbol"><MessageCircle size={30}/></div><p className="guidance-kicker">Samen maken we de avond</p><Primitive.Title className="guidance-community-title">Samen goed op pad</Primitive.Title><Primitive.Description className="guidance-community-intro">Lees deze uitleg één keer voor jouw account. Hier vind je de communities, installatiehulp en de vrijwillige meldingen voor jouw apparaat.</Primitive.Description><CommunityLinks house={record.roles.includes('house')}/><InstallControls /><PushNotificationSettings compact /><div className="guidance-community-note"><ShieldCheck size={18}/><p>De startafspraak, route en officiële status blijven in je persoonlijke omgeving staan. Bij direct gevaar bel je 112.</p></div><p className="guidance-joining-note">De uitleg lezen is verplicht. Deelnemen aan WhatsApp, installeren en meldingen toestaan zijn jouw eigen keuze.</p>{saveError&&<GuidanceError problem={saveError} role={role==='parent'||role==='house'?role:null} onReload={()=>void recover()}/>}<button className="guidance-primary" disabled={saving} onClick={()=>void acknowledge()}><Check size={18}/>{welcomeDue ? 'Gelezen, verder naar mijn omgeving' : 'Melding sluiten'}</button><p className="guidance-daily-caption">Eenmaal per account en uitlegversie. Later opnieuw bereikbaar via App & meldingen.</p></Primitive.Content></Primitive.Portal></Primitive.Root>
    <Primitive.Root open={Boolean(tour) && !showCommunity} onOpenChange={open => { if (!open) closeReplay(); }}><Primitive.Portal><Primitive.Overlay className="guidance-tour-backdrop"/>{rect && <div className="guidance-spotlight" style={rect} aria-hidden="true"/>}<Primitive.Content className="guidance-tour-dialog" onEscapeKeyDown={e => { if (tour?.mandatory) e.preventDefault(); }} onPointerDownOutside={e => e.preventDefault()} onOpenAutoFocus={e => { e.preventDefault(); tourTitle.current?.focus(); }}>{tour && step && <><div className="guidance-tour-top"><span><Sparkles size={16}/>{tour.role === 'house' ? 'Rondleiding voor poortteams' : 'Rondleiding voor ouders'}</span>{!tour.mandatory && <button aria-label="Rondleiding sluiten" onClick={closeReplay}><X size={18}/></button>}</div><div className="guidance-progress" role="progressbar" aria-label="Voortgang rondleiding" aria-valuemin={1} aria-valuemax={steps.length} aria-valuenow={tour.index + 1}><span style={{ width: `${(tour.index + 1) / steps.length * 100}%` }}/></div><p className="guidance-step-count">Stap {tour.index + 1} van {steps.length} <span>{step.label}</span></p><Primitive.Title ref={tourTitle} tabIndex={-1} className="guidance-tour-title">{step.title}</Primitive.Title><Primitive.Description className="guidance-tour-copy">{step.text}</Primitive.Description><div className="guidance-tip"><CheckCircle2 size={18}/><p>{step.tip}</p></div><p className="guidance-screen-indicator"><span className={targetFound ? 'is-ready' : ''}/>{targetFound ? 'Dit onderdeel staat achter de uitleg in beeld.' : 'Deze stap hoort bij dit scherm. De inhoud kan per fase van de avond verschillen.'}</p>{saveError&&<GuidanceError problem={saveError} role={role==='parent'||role==='house'?role:null} onReload={()=>void recover()}/>}<div className="guidance-tour-actions"><button className="guidance-secondary" disabled={saving || tour.index === 0} onClick={() => moveStep(tour.index - 1)}><ArrowLeft size={16}/>Vorige</button>{tour.index < steps.length - 1 ? <button className="guidance-primary" disabled={saving} onClick={() => void moveStep(tour.index + 1)}>Verder<ArrowRight size={17}/></button> : <button className="guidance-primary" disabled={saving} onClick={()=>void finish()}><Check size={17}/>Rondleiding afronden</button>}</div>{tour.mandatory && <p className="guidance-required-note">Bekijk alle stappen één keer. Je voortgang blijft bewaard; je kunt de uitleg later opnieuw openen.</p>}</>}</Primitive.Content></Primitive.Portal></Primitive.Root>
  </>;
}

export function GuidanceHost(){
 const path=usePathname();
 const scope=guidanceRole(path)??(path==='/app/meldingen'?'account':'public');
 const [record,setRecord]=useState<GuidanceRecord|null>(null),[loadError,setLoadError]=useState<GuidanceProblem|null>(null);
 const coordinator=useRef(new GuidanceRequests()),currentScope=useRef(scope),authUser=useRef<string|null|undefined>(undefined),active=useRef(true);
 const load=useCallback(async()=>{
  if(scope==='public')return false;
  const token=coordinator.current.beginRead();if(!token)return false;
  try{
   const response=await fetch('/api/redesign/guidance',{cache:'no-store'});
   const next=await readGuidanceResponse(response);
   if(!active.current||currentScope.current!==scope||!coordinator.current.acceptsRead(token)||(authUser.current!==undefined&&next.userId!==authUser.current))return false;
   setRecord(next);setLoadError(null);
   if(next.groupId)void configureArrivalSync({accountId:next.userId,eventId:next.eventId,groupId:next.groupId}).catch(()=>{});
   return true;
  }catch(error){
   if(active.current&&currentScope.current===scope&&coordinator.current.acceptsRead(token)){
    const problem=error instanceof GuidanceRequestError?error.problem:guidanceProblem();setLoadError(problem);
    if(problem.kind==='session'||problem.kind==='access'){setRecord(null);document.documentElement.dataset.participantGuidanceActive='true';window.dispatchEvent(new Event('poorten-guidance-status'));}
   }
   return false;
  }
 },[scope]);
 useLayoutEffect(()=>{
  currentScope.current=scope;coordinator.current.invalidate();setRecord(null);setLoadError(null);
  document.documentElement.dataset.participantGuidanceActive='true';window.dispatchEvent(new Event('poorten-guidance-status'));
 },[scope]);
 useEffect(()=>{
  const requests=coordinator.current;active.current=true;void load();
  const client=createClient();
  const auth=client?.auth.onAuthStateChange((_event:AuthChangeEvent,session:Session|null)=>{
   const id=session?.user.id??null;
   if(authUser.current!==id){authUser.current=id;coordinator.current.invalidate();setRecord(null);setLoadError(null);document.documentElement.dataset.participantGuidanceActive='true';window.dispatchEvent(new Event('poorten-guidance-status'));}
   queueMicrotask(()=>{if(active.current)void load();});
  });
  const online=()=>void load(),timer=setInterval(online,30000);window.addEventListener('online',online);
  return()=>{active.current=false;requests.invalidate();auth?.data.subscription.unsubscribe();clearInterval(timer);window.removeEventListener('online',online);};
 },[load]);
 async function persist(input:Record<string,unknown>){
  const token=coordinator.current.beginWrite();if(token===null)throw new DOMException('Busy','AbortError');
  const identity=record?.userId,event=record?.eventId,startedScope=scope;
  try{
   const response=await fetch('/api/redesign/guidance',{method:'POST',headers:{'Content-Type':'application/json'},cache:'no-store',body:JSON.stringify(input)});
   const next=await readGuidanceResponse(response);
   if(!active.current||currentScope.current!==startedScope||!coordinator.current.acceptsWrite(token)||next.userId!==identity||next.eventId!==event)throw new DOMException('Context changed','AbortError');
   setRecord(next);return next;
  }finally{coordinator.current.endWrite(token);}
 }
 if(scope==='public')return null;
 if(!record&&loadError)return <Primitive.Root open><Primitive.Portal><Primitive.Overlay className="guidance-backdrop"/><Primitive.Content className="guidance-community-dialog" onEscapeKeyDown={e=>e.preventDefault()} onPointerDownOutside={e=>e.preventDefault()}><Primitive.Title>De uitleg kon niet worden opgehaald</Primitive.Title><Primitive.Description>Je voortgang blijft bewaard. Herstel de verbinding of controleer je toegang om verder te gaan.</Primitive.Description><GuidanceError problem={loadError} role={scope==='house'?'house':'parent'} onReload={()=>void load()}/><button className="guidance-primary" onClick={()=>void load()}>Opnieuw proberen</button></Primitive.Content></Primitive.Portal></Primitive.Root>;
 return record?<ParticipantGuidance key={record.userId+record.eventId+scope} path={path} initial={record} persist={persist} reload={load}/>:null;
}
