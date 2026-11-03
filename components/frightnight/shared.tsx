import Link from "next/link";
import { ArrowRight, Clock, Moon, Sparkles, Sun } from "lucide-react";
import { CalmToggle } from "./calm-toggle";

export function Brand({ compact = false }: { compact?: boolean }) {
  return <span className={`brand fn-brand${compact ? " compact" : ""}`}><img src="/frightnight/logo.png" alt="" /><span>DUINDORP<br />FRIGHTNIGHT<small>De nacht is van ons.</small></span></span>;
}
export function Pumpkins({ level }: { level: number }) {
  return <span className="pumpkins fn-pumpkins" role="img" aria-label={`Spanningsniveau ${level} van 5`}>{[1, 2, 3, 4, 5].map(n => <img key={n} src="/frightnight/king-head.webp" alt="" aria-hidden="true" className={n > level ? "empty" : ""} />)}</span>;
}
export function Program() {
  const rows = [
    { time: "13:00", title: "Oogstdorp opent", text: "Ontmoet de Kraaienbode, ontdek het plein en begin de pleinmissies.", icon: <Sun size={22} /> },
    { time: "14:00", title: "Het Lantaarnatelier", text: "Maak een eigen lichtdrager voor jouw avontuur. Bekijk de beschikbare blokken in je Nachtpas.", href: "/nachtpas?tab=plein" },
    { time: "15:00", title: "Wortelrakkers maken", text: "Bouw een kleine pompoenfiguur van papier en herfstvondsten.", href: "/nachtpas?tab=plein" },
    { time: "16:15", title: "Ontdek het Lichtbaken", text: "Een lichtpuzzel, drie pleinspellen en het eerste licht van de avond.", icon: <Sparkles size={22} /> },
    { time: "17:00", title: "De Lantaarnentocht", text: "Licht, verwondering en maximaal twee pompoenen · tot 18:30.", href: "/nachtpas?tocht=mild" },
    { time: "18:30", title: "De Worteltocht", text: "Meer spanning, met jouw eigen maximum · tot 21:00.", href: "/nachtpas?tocht=scary" },
    { time: "Tot slot", title: "Samen terug bij het Lichtbaken", text: "Jouw laatste bezoek is de passende finale op het Duinpad. Breng het Duinlicht terug.", icon: <Moon size={22} /> },
  ];
  return <><p className="fn-programme-note"><Clock size={14} /> De middagindeling is het voorstel voor 2027; boekbare tijden staan in de Nachtpas.</p><div className="programme-list">{rows.map(row => <div className="programme-item" key={row.time}><time>{row.time}</time><div><h3>{row.title}</h3><p>{row.text}</p></div>{row.href ? <Link className="ui-button small" href={row.href}>Bekijk <ArrowRight size={15} /></Link> : row.icon}</div>)}</div></>;
}
export function WorkspaceHeader({ title }: { title: string }) {
  return <header className="pp-workspace-head fn-workspace-header"><Link href="/" aria-label="Naar het festival"><Brand compact /></Link><span>{title}</span><div className="fn-header-actions"><CalmToggle /><Link className="ui-button" href="/nachtpas">Mijn Nachtpas <ArrowRight size={15} /></Link></div></header>;
}
