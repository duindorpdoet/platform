'use client';

import React, { useEffect, useRef, useState } from 'react';
import { ArrowRight, ArrowUpRight, Candy, ChevronDown, Compass, DoorOpen, Heart, House, MapPin, Moon, ShieldCheck, Users } from 'lucide-react';
import { WorldExplorer } from './brand/world-explorer';

const scenes = [
  {
    id: 'de-avond', number: '01', label: 'De schemering', image: '/images/02-home-de-avond-straat.webp',
    alt: 'AI-sfeerbeeld van een Duindorpse straat met fictieve verklede kinderen en een begeleider.',
    eyebrow: 'DE STRAAT DIE JE KENT. MAAR DAN ANDERS.',
    title: <>De schemering valt.<br/><em>De voorpret begint.</em></>,
    copy: 'Je trekt je spannendste outfit aan, pakt je snoepemmertje en gaat samen op pad. Buiten brandt al licht bij de eerste huizen, portieken en buurtzaken. Vanavond is de hele wijk één groot avontuur.',
    detail: 'Verkleed, met je snoepemmertje en een volwassene op pad.', color: '#e6b38b', position: '67% 50%',
  },
  {
    id: 'de-poorten', number: '02', label: 'De poorten', image: '/images/03-home-de-poorten-gevels.webp',
    alt: 'AI-sfeerbeeld van bakstenen Duindorpse gevels met kleurrijk verlichte deuren.',
    eyebrow: 'ACHTER IEDERE DEUR WACHT IETS ANDERS.',
    title: <>Een bekend portiek.<br/><em>Een andere wereld.</em></>,
    copy: 'Een paarse gloed. Een sliertje mist. Iemand die achter de deur op jullie wacht. Woningen, portieken en bedrijven worden Halloweenpoorten, gemaakt door mensen uit onze eigen wijk.',
    detail: 'Jullie kiezen zelf hoe spannend het wordt. Overslaan mag altijd.', color: '#a995eb', position: '50% 50%',
  },
  {
    id: 'iets-lekkers', number: '03', label: 'Iets lekkers', image: '/images/04-home-iets-lekkers-steeg.webp',
    alt: 'AI-sfeerbeeld van fictieve kinderen die met een begeleider iets lekkers krijgen bij een verlichte deur.',
    eyebrow: 'EEN BEETJE KIPPENVEL. EEN GROTE GLIMLACH.',
    title: <>Even durven.<br/><em>En dan… iets lekkers.</em></>,
    copy: 'Bij de poorten krijgen de kinderen iets lekkers. Nog even zwaaien, het emmertje weer in de hand en samen door. Want om de hoek wacht alweer een nieuwe deur.',
    detail: 'Een avond vol kleine ontmoetingen en grote verhalen voor thuis.', color: '#f2b16d', position: '67% 50%',
  },
];

const motionOff = () => matchMedia('(prefers-reduced-motion: reduce)').matches || document.documentElement.classList.contains('motion-off');
function visitChapter(id: string) {
  const chapter = document.getElementById(id);
  chapter?.scrollIntoView({ block: 'start', behavior: motionOff() ? 'instant' : 'smooth' });
  chapter?.focus({ preventScroll: true });
}

function EveningOpening({ go }: { go: (path: string) => void }) {
  const root = useRef<HTMLElement>(null);
  useEffect(() => {
    const element = root.current;
    if (!element) return;
    let frame = 0;
    const move = (e: PointerEvent) => {
      if (e.pointerType === 'touch' || motionOff()) return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const r = element.getBoundingClientRect();
        element.style.setProperty('--evening-x', `${((e.clientX - r.left) / r.width - .5) * -12}px`);
        element.style.setProperty('--evening-y', `${((e.clientY - r.top) / r.height - .5) * -8}px`);
      });
    };
    const reset = () => { element.style.setProperty('--evening-x', '0px'); element.style.setProperty('--evening-y', '0px'); };
    element.addEventListener('pointermove', move); element.addEventListener('pointerleave', reset); window.addEventListener('poorten-motion', reset);
    return () => { cancelAnimationFrame(frame); element.removeEventListener('pointermove', move); element.removeEventListener('pointerleave', reset); window.removeEventListener('poorten-motion', reset); };
  }, []);
  return <section ref={root} className="evening-opening" aria-labelledby="evening-title">
    <div className="evening-opening-art"><img src="/images/01-home-hero-duindorp-bij-avond.webp" srcSet="/images/01-home-hero-duindorp-bij-avond-960.webp 960w, /images/01-home-hero-duindorp-bij-avond.webp 1672w" sizes="100vw" width="1672" height="941" fetchPriority="high" alt="AI-sfeerbeeld van Duindorp bij avond, met warme ramen en subtiele Halloweenversiering."/></div>
    <div className="evening-opening-shade"/><div className="evening-haze" aria-hidden="true"/>
    <div className="evening-opening-copy wrap">
      <p className="evening-overline"><span/>31 OKTOBER 2026 <i/> HALLOWEEN AVONDLOOP</p>
      <h1 id="evening-title">Een gewone wijk.<br/><em>Een magische<br className="evening-title-break"/> avond.</em></h1>
      <p className="evening-opening-intro">Als de avond valt, gaan de poorten open.<br/>Loop samen door Duindorp, ontdek wat er achter de deuren wacht en verzamel onderweg de lekkerste snoepjes.</p>
      <div className="evening-opening-actions"><button className="btn" onClick={() => go('/huis-aanmelden')}><House size={18}/>Meld jouw plek aan <ArrowUpRight size={18}/></button><button className="btn outline" onClick={() => go('/meelopen')}>Wij lopen mee <ArrowUpRight size={18}/></button></div>
      <p className="evening-opening-note"><ShieldCheck size={15}/>€2,50 per kind · samen met een volwassene</p>
    </div>
    <div className="evening-location"><MapPin size={15}/><span>DUINDORP, DEN HAAG<small>Onze straten. Jullie avontuur.</small></span></div>
    <div className="evening-opening-bottom"><button onClick={() => visitChapter('de-avond')} className="evening-scroll"><span className="evening-scroll-line"/>DE AVOND BEGINT HIER <ChevronDown size={14}/></button><p>Een beetje spannend. <em>Vooral onvergetelijk.</em></p></div>
  </section>;
}

function EveningStory() {
  const root = useRef<HTMLElement>(null);
  const [active, setActive] = useState(0);
  useEffect(() => {
    const section = root.current;
    if (!section) return;
    const media = matchMedia('(prefers-reduced-motion: reduce)');
    let frame = 0;
    const update = () => {
      frame = 0;
      const viewport = section.querySelector<HTMLElement>('.evening-story-screen');
      const beats = Array.from(section.querySelectorAll<HTMLElement>('.evening-story-beat'));
      const center = innerHeight * .52;
      let closest = 0, distance = Infinity;
      beats.forEach((beat, i) => { const rect = beat.getBoundingClientRect(); const d = Math.abs(rect.top + rect.height / 2 - center); if (d < distance) { closest = i; distance = d; } });
      setActive(previous => previous === closest ? previous : closest);
      if (viewport) {
        const rect = section.getBoundingClientRect();
        const progress = Math.max(0, Math.min(1, (76 - rect.top) / Math.max(1, rect.height - viewport.offsetHeight)));
        section.style.setProperty('--evening-progress', String(progress));
        section.style.setProperty('--scene-drift', motionOff() ? '0px' : `${(progress - .5) * -34}px`);
      }
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
    window.addEventListener('scroll', schedule, { passive: true }); window.addEventListener('resize', schedule); window.addEventListener('poorten-motion', schedule); media.addEventListener('change', schedule);
    update();
    return () => { cancelAnimationFrame(frame); window.removeEventListener('scroll', schedule); window.removeEventListener('resize', schedule); window.removeEventListener('poorten-motion', schedule); media.removeEventListener('change', schedule); };
  }, []);
  return <section ref={root} className="evening-story" aria-label="Zo beleef je de Halloween-avondloop" style={{ '--scene-color': scenes[active].color } as React.CSSProperties}>
    <div className="evening-story-screen"><div className="evening-story-images" aria-hidden="true">{scenes.map((scene, i) => <div className={'evening-scene ' + (i === active ? 'is-active' : '')} key={scene.id} style={{ '--scene-position': scene.position } as React.CSSProperties}><img src={scene.image} srcSet={`${scene.image.replace('.webp', '-960.webp')} 960w, ${scene.image} 1672w`} sizes="100vw" width="1672" height="941" alt="" loading="lazy" decoding="async"/><span className="evening-scene-glow"/></div>)}</div><div className="evening-story-shade" aria-hidden="true"/><span className="evening-scene-frame" aria-hidden="true"/><div className="evening-story-caption" aria-hidden="true"><span>DUINDORP / 31.10.2026</span><span>DE AVOND IN DRIE MOMENTEN</span></div></div>
    <div className="evening-story-controls">
      <nav className="evening-scene-navigation" aria-label="Momenten van de avond"><div className="evening-scene-track" aria-hidden="true"><span/></div>{scenes.map((scene, i) => <button key={scene.id} aria-current={i === active ? 'step' : undefined} onClick={() => visitChapter(scene.id)}><span>{scene.number}</span><strong>{scene.label}</strong></button>)}</nav>
    </div>
    <div className="evening-story-track">{scenes.map((scene, i) => <article className={'evening-story-beat ' + (i === active ? 'is-current' : '')} id={scene.id} key={scene.id} tabIndex={-1} style={{ '--scene-color': scene.color } as React.CSSProperties} aria-labelledby={scene.id + '-title'}><img className="evening-static-art" src={scene.image} srcSet={`${scene.image.replace('.webp', '-960.webp')} 960w, ${scene.image} 1672w`} sizes="100vw" width="1672" height="941" alt={scene.alt} loading="lazy" decoding="async"/><div className="evening-beat-copy wrap"><span className="evening-chapter">{scene.number}<i/>{scene.eyebrow}</span><h2 id={scene.id + '-title'}>{scene.title}</h2><p>{scene.copy}</p><div className="evening-beat-detail">{i === 0 ? <Moon size={17}/> : i === 1 ? <ShieldCheck size={17}/> : <Candy size={19}/>}<span>{scene.detail}</span></div></div></article>)}</div>
  </section>;
}

export function HomeExperience({ go, map, faq }: { go: (path: string) => void; map: React.ReactNode; faq: React.ReactNode }) {
  return <div className="home-experience">
    <EveningOpening go={go}/>
    <div className="evening-event-strip"><div className="wrap"><span><Moon size={18}/><strong>Een avondloop door Duindorp</strong></span><i/><span><DoorOpen size={18}/>Langs verrassende plekken</span><i/><span><Candy size={19}/>Iets lekkers voor de kinderen</span></div></div>
    <EveningStory/>
    <section className="evening-worlds section wrap reveal" id="werelden"><div className="evening-section-heading"><div><p className="kicker">NIET ELKE POORT LEIDT NAAR DEZELFDE WERELD</p><h2>Zo vertrouwd van buiten.<br/><em>Zo anders van binnen.</em></h2></div><div><p>Van magie en mist tot een spannend circus: ontdek de zes werelden. Jullie kiezen samen wat past bij de leeftijd en het karakter van jullie kinderen.</p><button className="text-link" onClick={() => go('/werelden')}>Verken de werelden <ArrowUpRight size={17}/></button></div></div><WorldExplorer onNavigate={go}/><div className="evening-worlds-footnote"><span><ShieldCheck size={16}/>Een poort overslaan mag altijd.</span><span>Zes themawerelden · voor kleine én dappere avonturiers</span></div></section>
    <section className="evening-neighborhood wrap reveal"><div className="evening-neighborhood-copy"><p className="kicker">GEWOON BIJ ONS OM DE HOEK</p><h2>Jullie avontuur.<br/><em>Onze straten.</em></h2><p>Geen verre reis. Geen groot pretpark. Bewoners, huizen, portieken en buurtbedrijven maken deze avond samen bijzonder.</p><p>De organisatie deelt jullie in een groep in. Samen lopen jullie van poort naar poort; de route onthult zich tijdens de avond.</p><button className="btn outline" onClick={() => go('/kaart')}><Compass size={17}/>Bekijk de wijk <ArrowUpRight size={17}/></button><span className="evening-map-note"><MapPin size={14}/>Globale wijkweergave · geen adressen</span></div><div className="evening-neighborhood-map"><div className="evening-map-heading"><span>DE WIJK ONTWAAKT</span><span>DUINDORP</span></div>{map}<div className="evening-map-caption"><DoorOpen size={17}/><span>Iedere deelnemende plek wordt een unieke poort.</span></div></div></section>
    <section className="evening-practical section wrap reveal"><div className="evening-section-heading"><div><p className="kicker">EN ZO LOPEN JULLIE MEE</p><h2>Een klein beetje regelen.<br/><em>Een hele avond beleven.</em></h2></div><p>De voorpret begint bij jullie thuis.<br/>Wij helpen met de rest.</p></div><div className="evening-three-steps">{[{ n: '01', Icon: Users, title: 'Meld je avonturiers aan.', text: 'Schrijf je kinderen in en vertel met wie jullie graag samenlopen. De bijdrage is €2,50 per kind voor snoep bij deelnemende huizen waar nodig.' }, { n: '02', Icon: Moon, title: 'Verkleed de avond in.', text: 'Je hoort bij welke groep jullie zitten en hoe laat jullie starten. Neem een snoepemmertje en een volwassene mee.' }, { n: '03', Icon: Candy, title: 'Van poort naar poort.', text: 'Ontdek de versierde huizen, beleef de verrassingen en ontvang snoepjes. Samen gaan jullie door naar de volgende deur.' }].map(({ n, Icon, title, text }) => <article key={n}><div><span>{n}</span><Icon size={25} strokeWidth={1.3}/></div><h3>{title}</h3><p>{text}</p></article>)}</div></section>
    <section className="evening-invitation" aria-labelledby="evening-invitation-title"><div className="evening-invitation-art"><img src="/images/04-home-iets-lekkers-steeg.webp" srcSet="/images/04-home-iets-lekkers-steeg-960.webp 960w, /images/04-home-iets-lekkers-steeg.webp 1672w" sizes="100vw" width="1672" height="941" alt="AI-sfeerbeeld van fictieve kinderen die met een begeleider iets lekkers krijgen bij een verlichte deur." loading="lazy" decoding="async"/></div><div className="wrap evening-invitation-copy reveal"><p className="kicker">31 OKTOBER 2026 · DUINDORP</p><h2 id="evening-invitation-title">Kleine voetstappen.<br/><em>Grote herinneringen.</em></h2><p>De mooiste verhalen beginnen soms<br/>gewoon aan de overkant van de straat.</p><button className="btn" onClick={() => go('/meelopen')}>Ja, wij lopen mee <ArrowRight size={18}/></button><span className="evening-invitation-note">17:00–21:00 · €2,50 per kind · volwassen begeleiding</span></div></section>
    <section className="evening-host wrap reveal"><div><span className="evening-host-icon"><House size={29} strokeWidth={1.2}/></span><div><p className="kicker">DE MOOISTE POORT IS MISSCHIEN WEL DIE VAN JOU</p><h2>Doe de deur open.<br/><em>Maak de avond mee.</em></h2><p>Versier je voordeur, gevel, portiek of zaak, ontvang de kinderen en deel iets lekkers uit. Of help als sponsor om de avond mogelijk te maken.</p></div></div><div className="evening-host-actions"><button className="btn outline" onClick={() => go('/huis-aanmelden')}>Mijn plek wordt een poort <ArrowUpRight size={17}/></button><button className="text-link" onClick={() => go('/sponsoren')}><Heart size={16}/>Steun de avondloop</button></div></section>
    <section className="section wrap evening-questions reveal"><div><p className="kicker">VOOR JULLIE DE DEUR UITGAAN</p><h2>Kleine vragen.<br/><em>Grote voorpret.</em></h2><p>Lees hoe de avond werkt, wat ouders meenemen en hoe kinderen zelf kunnen kiezen wat prettig voelt.</p><button className="text-link" onClick={() => go('/faq')}>Alle vragen en antwoorden <ArrowUpRight size={17}/></button></div>{faq}</section>
  </div>;
}
