"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowUpRight, CalendarDays, Menu, UserRound } from "lucide-react";
import { MotionAtmosphere, MotionToggle } from "@/components/poorten-cinematic";

const navigation = [
  ["Het verhaal", "/verhaal"],
  ["De werelden", "/werelden"],
  ["De kaart", "/kaart"],
  ["Meedoen", "/meelopen"],
  ["Vragen", "/faq"],
] as const;

const protectedPrefixes = ["/mijn-groep", "/mijn-huis", "/mijn-inschrijving", "/admin", "/omgeving"];

export function SiteChrome({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const isHome = pathname === "/";
  const isPortal = protectedPrefixes.some((prefix) => pathname.startsWith(prefix));
  const isParticipantEnvironment = pathname.startsWith("/omgeving");

  if (pathname.startsWith("/admin")) {
    return <>
      <a className="skip-link" href="#admin-content">Ga naar inhoud</a>
      <div className="admin-route-surface">{children}</div>
    </>;
  }

  if (isParticipantEnvironment) {
    return <>
      <a className="skip-link" href="#participant-content">Ga naar inhoud</a>
      <MotionAtmosphere route={pathname} />
      <main id="main-content" className="app-surface participant-surface">{children}</main>
      <MotionToggle />
    </>;
  }

  return (
    <>
      <a className="skip-link" href="#main-content">Ga naar inhoud</a>
      <MotionAtmosphere route={pathname} />
      <header className={`site-header ${!isHome ? "solid" : ""}`}>
        <Link className="brand" href="/">
          <img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width="190" height="80" />
        </Link>
        <nav aria-label="Hoofdnavigatie">
          {navigation.map(([label, href]) => (
            <Link key={href} className={pathname === href ? "active" : ""} href={href}>{label}</Link>
          ))}
        </nav>
        <div className="header-actions">
          <Link className="group-link" href="/omgeving"><UserRound size={16} /><span>Mijn omgeving</span></Link>
          <Link className="btn header-signup" href="/meelopen">Bekijk deelname <ArrowUpRight size={16} /></Link>
          <details className="mobile-navigation">
            <summary className="menu-btn" aria-label="Menu openen"><Menu /></summary>
            <div className="mobile-navigation-panel">
              {navigation.map(([label, href]) => <Link key={href} href={href}>{label}</Link>)}
              <Link href="/huis-aanmelden">Plek aanmelden</Link>
              <Link href="/sponsoren">Sponsoren</Link>
              <Link href="/omgeving">Mijn omgeving</Link>
            </div>
          </details>
        </div>
      </header>
      <main id="main-content" className={`${!isHome ? "inner-page" : ""} ${isPortal ? "app-surface" : ""}`}>{children}</main>
      {!isPortal && (
        <footer className="footer">
          <div className="wrap footer-top">
            <Link className="brand" href="/"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width="190" height="80" /></Link>
            <p>Eén avond. Eén wijk.<br /><em>Talloze werelden.</em></p>
            <div>
              <Link href="/huis-aanmelden">Plek aanmelden</Link>
              <Link href="/sponsoren">Sponsoren & doneren</Link>
              <Link href="/contact">Contact</Link>
            </div>
            <div><CalendarDays size={20} /><strong>31 oktober 2026</strong><span>Duindorp, Den Haag</span></div>
          </div>
          <div className="wrap footer-bottom">
            <span>© 2026 De Duindorpse Poorten van Halloween</span>
            <span><Link href="/privacy">Privacy</Link> · <Link href="/voorwaarden">Voorwaarden</Link> · <Link href="/toegankelijkheid">Toegankelijkheid</Link></span>
          </div>
          <p className="wrap image-disclosure">AI-bewerkte sfeerbeelden op basis van Duindorpse locaties. Afgebeelde personen zijn fictief; getoonde woningen zijn niet automatisch deelnemende adressen.</p>
        </footer>
      )}
      <MotionToggle />
    </>
  );
}
