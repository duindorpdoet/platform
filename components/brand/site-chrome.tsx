"use client";
import { useEventDetails } from "@/components/redesign/event-details";
import type { ReactNode } from "react";
import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowUpRight, BookOpen, ChevronDown, Menu, MoonStar, UserRound, X } from "lucide-react";
const navGroups = [
 { label:"De avond", links:[["Het verhaal","/verhaal"],["De zes werelden","/werelden"],["De wijkkaart","/kaart"]]},
 { label:"Meedoen", links:[["Loop met ons mee","/meelopen"],["Meld jouw poort aan","/huis-aanmelden"],["Help mee & sponsoren","/sponsoren"]]},
 { label:"Ontdek", links:[["Poortenboek & de app","/ontdek"],["Nieuws uit de wijk","/nieuws"],["Deel de magie","/deel-de-magie"]]},
];
export function SiteChrome({children}:{children:ReactNode}) {
 const event=useEventDetails();
 const pathname=usePathname();const[menuState,setMenuState]=useState({path:pathname,open:false});const menuOpen=menuState.path===pathname&&menuState.open;const setMenuOpen=useCallback((open:boolean)=>setMenuState({path:pathname,open}),[pathname]);const headerRef=useRef<HTMLElement>(null);
 useEffect(()=>{headerRef.current?.querySelectorAll("details[open]").forEach(item=>item.removeAttribute("open"))},[pathname]);
 useEffect(()=>{const close=(e:KeyboardEvent)=>{if(e.key==='Escape')setMenuOpen(false)};window.addEventListener('keydown',close);return()=>window.removeEventListener('keydown',close)},[setMenuOpen]);
 if(pathname.startsWith('/admin'))return <><a className="skip-link" href="#admin-content">Ga naar inhoud</a><div className="admin-route-surface">{children}</div></>;
 if(pathname.startsWith('/mijn-huis')||pathname.startsWith('/poortkamer'))return <><a className="skip-link" href="#poortkamer-content">Ga naar de Poortkamer</a>{children}</>;
 if(pathname.startsWith('/poortenboek'))return <><a className="skip-link" href="#poortenboek-content">Ga naar jouw Poortenboek</a>{children}</>;
 if(pathname.startsWith('/omgeving'))return <><a className="skip-link" href="#participant-content">Ga naar inhoud</a><main id="main-content" className="app-surface participant-surface">{children}</main></>;
 return <div className="public-shell"><a className="skip-link" href="#main-content">Ga naar inhoud</a>
 <header className="public-header" ref={headerRef}><div className="public-header-inner"><Link href="/" className="public-brand" aria-label="Duindorpse Poorten, naar home"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width="145" height="70"/><span className="public-brand-divider"/><span className="public-brand-edition">DE NACHT VAN<br/><strong>DUINDORP</strong></span></Link>
 <nav className="public-desktop-nav" aria-label="Hoofdnavigatie">{navGroups.map(group=><details key={group.label} name="public-navigation" className="public-nav-dropdown"><summary className={group.links.some(([,href])=>pathname===href)?'active':''}>{group.label}<ChevronDown size={13}/></summary><div className="public-nav-popover">{group.links.map(([label,href])=><Link key={href} href={href} aria-current={pathname===href?'page':undefined}>{label}<ArrowUpRight size={14}/></Link>)}</div></details>)}<Link href="/faq" className={pathname==='/faq'?'active':''}>Veelgestelde vragen</Link></nav>
 <div className="public-header-actions"><Link className="public-account-link" href="/omgeving"><UserRound size={17}/><span>Mijn omgeving</span></Link><Link className="public-button public-button-small" href="/meelopen">Loop mee<ArrowUpRight size={15}/></Link><button className="public-menu-button" aria-label={menuOpen?'Menu sluiten':'Menu openen'} aria-expanded={menuOpen} aria-controls="public-mobile-menu" onClick={()=>setMenuOpen(!menuOpen)}>{menuOpen?<X/>:<Menu/>}</button></div></div>
 {menuOpen&&<nav id="public-mobile-menu" className="public-mobile-menu" aria-label="Mobiele hoofdnavigatie">{navGroups.map(group=><div key={group.label}><p>{group.label}</p>{group.links.map(([label,href])=><Link key={href} href={href}>{label}<ArrowUpRight size={15}/></Link>)}</div>)}<div><p>Handig om te weten</p><Link href="/faq">Veelgestelde vragen<ArrowUpRight size={15}/></Link><Link href="/contact">Contact met de organisatie<ArrowUpRight size={15}/></Link><Link href="/omgeving">Mijn persoonlijke omgeving<UserRound size={15}/></Link><Link href="/poortenboek">Mijn Poortenboek<BookOpen size={15}/></Link></div></nav>}</header>
 <main id="main-content" className={`public-main${pathname==='/'?' public-main-home':' public-main-inner'}`}>{children}</main>
 <footer className="public-footer"><div className="public-container public-footer-main"><div className="public-footer-story"><Link href="/" className="public-footer-logo"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width="155" height="75"/></Link><h2>Onze straten.<br/><span>Jullie avontuur.</span></h2><p>Eén avond waarop Duindorp samen de deur opent.</p><div className="public-footer-date"><MoonStar size={16}/><span>{event.weekday} {event.dateLong} · {event.times}</span></div></div>
 <div className="public-footer-links"><h3>Beleef de avond</h3><Link href="/verhaal">Het verhaal</Link><Link href="/werelden">De werelden</Link><Link href="/kaart">Duindorp op de kaart</Link><Link href="/meelopen">Meelopen</Link></div>
 <div className="public-footer-links"><h3>Doe de deur open</h3><Link href="/huis-aanmelden">Jouw plek aanmelden</Link><Link href="/mijn-huis">De Poortkamer</Link><Link href="/sponsoren">Help mee & sponsoren</Link><Link href="/contact">Contact</Link></div>
 <div className="public-footer-links"><h3>Altijd bij de hand</h3><Link href="/omgeving">Mijn omgeving</Link><Link href="/poortenboek">Het Poortenboek</Link><Link href="/ontdek">De app ontdekken</Link><Link href="/nieuws">Nieuws uit de wijk</Link><Link href="/deel-de-magie">Deel de magie</Link><Link href="/faq">Vragen & antwoorden</Link></div></div>
 <div className="public-container public-footer-bottom"><span>© {event.year} De Duindorpse Poorten van Halloween</span><div><Link href="/privacy">Privacy</Link><Link href="/voorwaarden">Voorwaarden</Link><Link href="/toegankelijkheid">Toegankelijkheid</Link></div></div><p className="public-container public-image-disclosure">AI-bewerkte sfeerbeelden op basis van Duindorpse locaties. Personen zijn fictief; afgebeelde woningen zijn niet automatisch deelnemende adressen.</p></footer></div>;
}
