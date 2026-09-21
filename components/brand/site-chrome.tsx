"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowUpRight, CalendarDays, Menu, Users } from "lucide-react";
import { MotionAtmosphere, MotionToggle } from "@/components/poorten-cinematic";

const navigation = [
  ["Het verhaal", "/verhaal"],
  ["De werelden", "/werelden"],
  ["De kaart", "/kaart"],
  ["Meedoen", "/meelopen"],
  ["Vragen", "/faq"],
] as const;

const protectedPrefixes = ["/mijn-groep", "/mijn-huis", "/mijn-inschrijving", "/admin"];

export function SiteChrome({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const isHome = pathname === "/";
  const isPortal = protectedPrefixes.some((prefix) => pathname.startsWith(prefix));

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
          <Link className="group-link" href="/mijn-groep"><Users size={16} /><span>Mijn groep</span></Link>
          <Link className="btn header-signup" href="/meelopen">Bekijk deelname <ArrowUpRight size={16} /></Link>
          <details className="mobile-navigation">
            <summary className="menu-btn" aria-label="Menu openen"><Menu /></summary>
            <div className="mobile-navigation-panel">
              {navigation.map(([label, href]) => <Link key={href} href={href}>{label}</Link>)}
              <Link href="/huis-aanmelden">Huis aanmelden</Link>
              <Link href="/sponsoren">Sponsoren</Link>
              <Link href="/mijn-groep">Mijn groep</Link>
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
              <Link href="/huis-aanmelden">Huis aanmelden</Link>
              <Link href="/sponsoren">Sponsoren & doneren</Link>
              <Link href="/contact">Contact</Link>
            </div>
            <div><CalendarDays size={20} /><strong>31 oktober 2026</strong><span>Duindorp, Den Haag</span></div>
          </div>
          <div className="wrap footer-bottom">
            <span>© 2026 De Duindorpse Poorten van Halloween</span>
            <span><Link href="/privacy">Privacy</Link> · <Link href="/voorwaarden">Voorwaarden</Link> · <Link href="/toegankelijkheid">Toegankelijkheid</Link></span>
          </div>
        </footer>
      )}
      <MotionToggle />
    </>
  );
}
