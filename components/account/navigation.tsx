"use client";
import {requestWelcomeReplay} from "@/lib/account/welcome-replay";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowLeftRight, Bell, HelpCircle } from "lucide-react";

export function WelcomeReplayButton(){return <button className="btn outline" type="button" onClick={requestWelcomeReplay}>Welkom, WhatsApp & appuitleg opnieuw bekijken</button>}
export function AccountNavigation(){
 const path=usePathname();
 if(path.startsWith('/poortenboek'))return <nav className="account-app-links child-app-help" aria-label="Hulp bij de app"><Link href="/app/hulp"><HelpCircle size={16}/>App & hulp met een volwassene</Link></nav>;
 if(path.startsWith('/admin')||path==='/mijn-huis'||path.startsWith('/poortkamer'))return null;
 if(path==='/omgeving/kiezen'||path==='/inloggen'||!(path.startsWith('/omgeving')||path.startsWith('/mijn-')||path.startsWith('/admin')))return null;
 return <nav className="account-app-links" aria-label="Account en app"><Link href="/omgeving/kiezen"><ArrowLeftRight size={16}/>Wissel omgeving</Link><Link href="/app/meldingen"><Bell size={16}/>App & meldingen</Link></nav>;
}
