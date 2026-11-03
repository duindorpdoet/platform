'use client';

import { useState, type CSSProperties } from 'react';
import Link from 'next/link';
import { motion, useScroll, useSpring, useTransform } from 'motion/react';
import { ArrowDown, ArrowUpRight, ArrowRight, Ticket, Sun, Moon, Sparkles, MapPin, Menu, X, ChevronDown, ScanLine, Footprints, Pause, Play, Crown } from 'lucide-react';

import { Brand, Pumpkins, Program } from './shared';
import { PublishedContent } from './published-content';
import { useCalmPreference } from './motion-preference';





const intensityCopy = [
  ['Een klein beetje kippenvel.', 'Vriendelijke decoraties, zacht licht en een verhaal om samen te ontdekken.'],
  ['Spannend, maar gezellig.', 'Een onverwacht geluid, een geheimzinnige tuin en vooral veel plezier.'],
  ['Hier gaat je hart sneller.', 'Donkere hoekjes en acteurs die je kunnen verrassen. Voor wie al wat meer durft.'],
  ['Voor echte durfals.', 'Intensere scènes en verrassingen. Kies bewust of dit bij jouw gezin past.'],
  ['De nacht op zijn spannendst.', 'Onze hoogste intensiteit. Je kunt een zone altijd overslaan of een rustiger avontuur kiezen.'],
];

export default function FestivalHome() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [intensity, setIntensity] = useState(2);
  const [peek, setPeek] = useState<'mild' | 'scary' | null>(null);
  const closeMenu = () => setMenuOpen(false);
  const { calm, paused: effectsPaused, system: prefersCalm, setPaused: setEffectsPaused } = useCalmPreference();
  const [kingAwake, setKingAwake] = useState(false);
  const [storyOpen, setStoryOpen] = useState(false);

  const { scrollY } = useScroll();
  const heroY = useTransform(scrollY, [0, 800], [0, -65]);
  const heroLift = useSpring(heroY, { stiffness: 100, damping: 24 });
  const tiltX = useSpring(0, { stiffness: 140, damping: 22 });
  const tiltY = useSpring(0, { stiffness: 140, damping: 22 });
  const reveal = { initial: false as const, whileInView: { opacity: 1, y: 0 }, viewport: { once: true, amount: .12 }, transition: { duration: calm ? 0 : .65, ease: 'easeOut' as const } };


  return (
    <div className="theme theme-poster" data-motion={calm ? 'still' : 'full'}>
      <header className="pp-header">
        <a href="#pp-top" className="pp-brand-link" aria-label="Duindorp FrightNight, naar boven"><Brand compact /></a>
        <nav className={menuOpen ? 'pp-nav pp-nav-open' : 'pp-nav'} aria-label="Festivalnavigatie">
          <a href="#pp-programme" onClick={closeMenu}>Het programma</a>
          <a href="#pp-adventures" onClick={closeMenu}>De tochten</a>
          <a href="#pp-practical" onClick={closeMenu}>Goed om te weten</a>
          <Link href="/nachtpas" className="pp-nav-pass" onClick={closeMenu}>Mijn Nachtpas <ArrowUpRight size={15} /></Link>
        </nav>
        <button type="button" className="pp-menu" aria-expanded={menuOpen} aria-label={menuOpen ? 'Menu sluiten' : 'Menu openen'} onClick={() => setMenuOpen(!menuOpen)}>{menuOpen ? <X /> : <Menu />}</button>
      </header>

      <main id="main-content"><span id="pp-top" />
        <section className="pp-hero" aria-labelledby="pp-title">
          <img className="pp-night-landscape" src="/frightnight/coast-hero.webp" alt="" aria-hidden="true"/>
          <div className="pp-night-vignette" aria-hidden="true"/>
          <div className="pp-embers" aria-hidden="true">{[0,1,2,3,4,5,6,7].map(n=><i className="pp-ember" key={n} style={{left:`${8+n*12}%`,'--delay':`${-n*1.7}s`,'--drift':`${n%2===0?35:-45}px`} as CSSProperties}/>)}</div>
          <span className="pp-print-coordinate" aria-hidden="true">NACHTEDITIE / 07</span>
          <button type="button" className="pp-motion-toggle" aria-pressed={calm} disabled={prefersCalm} onClick={()=>setEffectsPaused(!effectsPaused)}>{calm?<Play size={12}/>:<Pause size={12}/>} {prefersCalm?'Rustige weergave':effectsPaused?'Speel sfeereffecten':'Pauzeer sfeereffecten'}</button>
          <div className="pp-hero-copy">
            <div className="pp-kicker"><span className="pp-dot" /> DUINDORP KOMT TOT LEVEN <span>2027</span></div>
            <h1 id="pp-title"><motion.span initial={false} animate={{opacity:1,y:0,rotate:0}} transition={{duration:calm?0:.75,ease:'easeOut'}}>DIT WORDT</motion.span><motion.span className="pp-hero-orange" initial={false} animate={{opacity:1,x:0,rotate:-1.5}} transition={{duration:calm?0:.8,delay:calm?0:.12,ease:'easeOut'}}>JOUW NACHT<span className="pp-title-dot">.</span></motion.span></h1>
            <motion.div initial={false} animate={{opacity:1,y:0}} transition={{duration:calm?0:.6,delay:calm?0:.25}} className="pp-title-note"><span aria-hidden="true">✳</span><span>Grote verhalen.<br /><strong>Een hele buurt aan licht.</strong></span></motion.div>
            <p className="pp-hero-subtitle">De Vloek van de Pompoenkoning</p>
            <p className="pp-hero-intro">Een middag vol licht. Een avond vol avontuur. Trek eropuit met je eigen gezin en ontdek wat er achter de deuren van Duindorp schuilt.</p>
            <div className="pp-hero-actions"><a className="pp-button pp-button-dark" href="#pp-adventures">Kies jouw avontuur <ArrowDown size={20} /></a><button type="button" className="pp-text-button" onClick={() => document.getElementById('pp-story')?.scrollIntoView({behavior:calm?'instant':'smooth'})}>Ontdek het verhaal <ArrowUpRight size={17} /></button></div>
            <div className="pp-hero-meta"><span><MapPin size={16} /> Start & finale: Duinpad</span><span><Footprints size={16} /> Samen, op je eigen tempo</span></div>
          </div>
          <div className="pp-hero-art" onPointerMove={event=>{if(calm||event.pointerType==='touch')return;const r=event.currentTarget.getBoundingClientRect();tiltX.set(-((event.clientY-r.top)/r.height-.5)*10);tiltY.set(((event.clientX-r.left)/r.width-.5)*13)}} onPointerLeave={()=>{tiltX.set(0);tiltY.set(0)}}>
            <span className="pp-art-serial" aria-hidden="true">30<br />10</span>
            <span className="pp-art-ticket-tag"><Ticket size={16} /> JOUW AVONTUUR BEGINT HIER</span>
            <div className="pp-art-stripe" aria-hidden="true" />
            <div className="pp-crown-halo" aria-hidden="true"/>
            <motion.div className="pp-king-scene" style={{y:calm?0:heroLift,rotateX:calm?0:tiltX,rotateY:calm?0:tiltY}}>
              <motion.img src="/frightnight/king-head.webp" alt="De Pompoenkoning ontwaakt met een gloeiende grijns en koperen kroon" className="pp-king" fetchPriority="high" initial={false} animate={calm?{opacity:1,scale:1,y:0,rotate:0}:{opacity:1,scale:kingAwake?1.075:1,y:[0,-13,0],rotate:[-.5,1,-.5]}} transition={{opacity:{duration:calm?0:.8},scale:{type:'spring',stiffness:130,damping:15},y:{duration:calm?0:6.5,repeat:calm?0:Infinity,ease:'easeInOut'},rotate:{duration:calm?0:8,repeat:calm?0:Infinity,ease:'easeInOut'}}}/>
            </motion.div>
            <div className="pp-king-caption" aria-live="polite">{kingAwake?'“Breng mijn licht terug… als je durft.”':'De kroon gloeit. De nacht begint.'}</div>
            <motion.button type="button" className="pp-awaken-button" aria-pressed={kingAwake} whileTap={calm?{}:{scale:.96}} onClick={()=>setKingAwake(v=>!v)}><Crown size={17}/>{kingAwake?'De koning is ontwaakt':'Wek de Pompoenkoning'}<Sparkles size={15}/></motion.button>
            <div className="pp-date-stamp"><span>ZATERDAG</span><strong>30.10</strong><span>TWEE DUIZEND ZEVENENTWINTIG</span></div>
            <div className="pp-art-label"><Sparkles size={20} /><span>HET LICHT<br /><strong>IS VAN ONS.</strong></span></div>
          </div>
        </section>

        <div className="pp-programme-strip" aria-label="De dag in drie delen">
          <a href="#pp-programme"><Sun size={27} /><span><small>DE MIDDAG</small><strong>OOGSTDORP</strong></span><ArrowUpRight size={20} /></a>
          <a href="#pp-adventures"><Ticket size={27} /><span><small>17:00 — 18:30</small><strong>LANTAARNEN<wbr />TOCHT</strong></span><ArrowUpRight size={20} /></a>
          <a href="#pp-adventures"><Moon size={27} /><span><small>18:30 — 21:00</small><strong>WORTELTOCHT</strong></span><ArrowUpRight size={20} /></a>
        </div>

        <motion.section id="pp-adventures" className="pp-adventures pp-section" {...reveal} aria-labelledby="pp-adventure-title">
          <div className="pp-section-heading"><span className="pp-section-number">01 / DE TOCHTEN</span><h2 id="pp-adventure-title">HOE DAPPER<br />IS JOUW GEZIN?</h2><p>Jullie bepalen de spanning.<br />De buurt zorgt voor de magie.</p></div>
          <div className="pp-tickets">
            <motion.article {...reveal} whileHover={calm?{}:{y:-9,rotate:0}} className={'pp-ticket pp-ticket-light' + (peek === 'mild' ? ' pp-ticket-open' : '')}>
              <div className="pp-ticket-series"><span>AVONTURENTICKET</span><span>TYPE A / LICHT</span></div>
              <div className="pp-ticket-top"><Sun size={31} /><span>LICHT, VERWONDERING & EEN BEETJE KIPPENVEL</span></div>
              <div className="pp-ticket-main"><span className="pp-ticket-index">A</span><h3>LANTAARNEN<br />TOCHT.</h3><p>Voor kleine avonturiers en grote verhalenvertellers. Ontdek vriendelijke zones, verzamel Lichtvonken en laat je verrassen.</p><Pumpkins level={2} /><button className="pp-ticket-peek" type="button" aria-expanded={peek === 'mild'} aria-controls="pp-mild-details" onClick={() => setPeek(peek === 'mild' ? null : 'mild')}>Kijk in jouw avontuur <ChevronDown size={15} /></button><div className="pp-ticket-reveal" id="pp-mild-details" hidden={peek !== 'mild'}><strong>Dit neem je mee de avond in.</strong><ul><li>Vriendelijke zones op jullie eigen tempo</li><li>Maximaal twee pompoenen spanning</li><li>Een Nachtpas vol Lichtvonken</li><li>Een finale bij het Lichtbaken</li></ul></div></div>
              <div className="pp-ticket-stub"><span><small>JOUW AVONDBLOK</small><strong>17:00 — 18:30</strong></span><Link href="/nachtpas?tocht=mild">Deze tocht kies ik <ArrowUpRight size={20} /></Link></div>
            </motion.article>
            <motion.article {...reveal} whileHover={calm?{}:{y:-9,rotate:0}} className={'pp-ticket pp-ticket-dark' + (peek === 'scary' ? ' pp-ticket-open' : '')}>
              <div className="pp-ticket-series"><span>AVONTURENTICKET</span><span>TYPE B / NACHT</span></div>
              <div className="pp-ticket-top"><Moon size={31} /><span>MEER NACHT. MEER SPANNING. MEER DURVEN.</span></div>
              <div className="pp-ticket-main"><span className="pp-ticket-index">B</span><h3>WORTEL<br />TOCHT.</h3><p>Als de avond valt, ontwaakt een andere kant van Duindorp. Volg jouw route langs duistere tuinen en eigenzinnige Frightzones.</p><Pumpkins level={5} /><button className="pp-ticket-peek" type="button" aria-expanded={peek === 'scary'} aria-controls="pp-scary-details" onClick={() => setPeek(peek === 'scary' ? null : 'scary')}>Kijk in jouw avontuur <ChevronDown size={15} /></button><div className="pp-ticket-reveal" id="pp-scary-details" hidden={peek !== 'scary'}><strong>Jullie grens. Jullie nacht.</strong><ul><li>Frightzones met één tot vijf pompoenen</li><li>Zelf de maximale spanning kiezen</li><li>Een andere zone als een huis even pauzeert</li><li>De laatste Lichtvonk op het Duinpad</li></ul></div></div>
              <div className="pp-ticket-stub"><span><small>JOUW AVONDBLOK</small><strong>18:30 — 21:00</strong></span><Link href="/nachtpas?tocht=scary">Ik durf het aan <ArrowUpRight size={20} /></Link></div>
            </motion.article>
          </div>
          <div className="pp-route-note"><ScanLine size={22} /><p>Geen vaste routegroepen. Jullie lopen zelfstandig, ontvangen steeds één volgende bestemming en kunnen zelf een ander gezin uitnodigen om samen te lopen.</p><Link className="pp-text-button" href="/nachtpas">Open je Nachtpas <ArrowRight size={18} /></Link></div>
        </motion.section>

        <motion.section id="pp-programme" className="pp-programme pp-section" {...reveal} aria-labelledby="pp-programme-title">
          <div className="pp-programme-heading"><span className="pp-programme-seal" aria-hidden="true"><Sun size={23} /><strong>VAN LICHT<br />NAAR NACHT</strong><Moon size={18} /></span><div><span className="pp-section-number">02 / VAN MIDDAG TOT NACHT</span><h2 id="pp-programme-title">EEN HELE DAG.<br />EEN GROOT VERHAAL.</h2></div><p>Het Duinpad wordt Oogstdorp.<br />De plek waar de middag begint<br />en de avond samenkomt.</p></div>
          <Program />
          <div className="pp-day-feature"><img src="/frightnight/oogstdorp.webp" alt="Een warm verlicht Oogstdorp met pompoenen en activiteiten" loading="lazy" /><div><span className="pp-section-number">MAAK HET LICHT ZELF</span><h3>KLEINE HANDEN.<br />GROOT AVONTUUR.</h3><p>Maak een lantaarn, ontdek een opdracht of help het Lichtbaken weer stralen. Kies een activiteit in het programma en bewaar deze bij je Nachtpas.</p><Link className="pp-button pp-button-dark" href="/nachtpas?tab=plein">Naar het lantaarnatelier <ArrowUpRight size={18} /></Link></div></div>
        </motion.section>

        <section className="pp-story" id="pp-story" aria-labelledby="pp-story-title">
          <div className="pp-story-image"><img src="/frightnight/zone-garden.webp" alt="Een mysterieuze tuin met raven, pompoenen en warme lantaarns" loading="lazy"/><motion.img className="pp-story-king" src="/frightnight/king-head.webp" alt="" aria-hidden="true" loading="lazy" initial={false} whileInView={{opacity:1,x:0,rotate:-3}} viewport={{once:true,amount:.2}} transition={{duration:calm?0:.9,ease:'easeOut'}}/><span className="pp-story-tag">ER SCHUILT IETS IN DE BUURT.</span></div>
          <div className="pp-story-copy"><span className="pp-section-number">03 / DE VLOEK</span><h2 id="pp-story-title">DE KONING<br />WIL HET DONKER.<br /><span>WIJ HET LICHT.</span></h2><p>De Pompoenkoning heeft zijn wortels door Duindorp geslagen. Alleen samen krijgen we het Duinlicht terug. Elke bezochte zone brengt een Lichtvonk dichter bij het baken.</p><button id="pp-story-toggle" type="button" className="pp-button pp-button-orange" aria-expanded={storyOpen} aria-controls="pp-story-details" onClick={() => setStoryOpen(value => !value)}>{storyOpen ? 'Verhaal sluiten' : 'Lees hoe het begon'} <ChevronDown size={19} /></button></div>
          <div id="pp-story-details" className="pp-story-details" role="region" aria-labelledby="pp-story-details-title" hidden={!storyOpen}>
            <div className="pp-story-chapters"><span className="pp-section-number">DE VLOEK VAN DE POMPOENKONING</span><h3 id="pp-story-details-title">EEN KROON VOL DUISTER.<br />EEN BUURT VOL LICHT.</h3><article><h4>I / Het verborgen licht</h4><p>Lang geleden hield het Duinlicht de nacht in evenwicht. Maar diep onder de duinen groeiden de wortels van de Pompoenkoning. Hij verstopte het licht in zijn kroon, en de wijk viel langzaam in zijn schaduw.</p></article><article><h4>II / De Kraaienbode</h4><p>De Kraaienbode heeft kleine Lichtvonken ontdekt bij de huizen. Soms wachten er snoep en verwondering. Soms moet je een Frightzone trotseren. Jij bepaalt hoeveel spanning je aankunt.</p></article><article><h4>III / Het Lichtbaken</h4><p>Verzamel de vonken in je Nachtpas. Keer na je tocht terug naar het Duinpad en breng het Lichtbaken tot leven. Alleen dan laat de kroon haar licht weer vrij. Ieder gezelschap kan slagen; alle huizen en opdrachten afronden hoeft niet.</p></article><Link className="pp-button pp-button-orange" href="/nachtpas">Mijn avontuur begint hier <ArrowUpRight size={18} /></Link></div>
            <aside className="pp-story-characters" aria-label="De personages"><img src="/frightnight/kraaienbode.webp" alt="De Kraaienbode met zijn lantaarn" loading="lazy" /><h3>WIE NEEMT JULLIE MEE?</h3><dl><dt>De Pompoenkoning</dt><dd>Hij houdt het Duinlicht verborgen in zijn kroon.</dd><dt>De Kraaienbode</dt><dd>Hij wijst jullie op de Lichtvonken die in de buurt zijn achtergebleven.</dd><dt>De Oogstmeester en de Wortelrakkers</dt><dd>Ook zij horen bij het verhaal van het Oogstdorp: samen maken, ontdekken en licht verzamelen.</dd></dl></aside>
          </div>
        </section>

        <motion.section className="pp-intensity pp-section" {...reveal} aria-labelledby="pp-intensity-title">
          <div><span className="pp-section-number">04 / JIJ BEPAALT DE SPANNING</span><h2 id="pp-intensity-title">KIPPENVEL<br />OP MAAT.</h2><p>Een Snoepzone of een Frightzone? De pompoenen laten zien wat je kunt verwachten. Kies hieronder een niveau om het verschil te ontdekken.</p></div>
          <div className="pp-intensity-picker"><motion.img className="pp-meter-king" src="/frightnight/king-head.webp" alt="" aria-hidden="true" loading="lazy" animate={{rotate:calm?0:(intensity-3)*3,scale:calm?1:1+intensity*.018}} transition={calm?{duration:0}:{type:'spring',stiffness:160,damping:16}}/><div className="pp-intensity-caption"><span>DE DURFMETER</span><span>JIJ KIEST DE SPANNING.</span></div><div className="pp-intensity-buttons" aria-label="Bekijk een spanningsniveau">{[1, 2, 3, 4, 5].map(level => <button type="button" key={level} aria-pressed={intensity === level} onClick={() => setIntensity(level)}><img src="/frightnight/king-head.webp" alt="" aria-hidden="true" /><strong>{level}</strong></button>)}</div><motion.div className="pp-intensity-result" initial={false} animate={{opacity:1,y:0}} transition={{duration:calm?0:.25}} key={intensity} aria-live="polite"><small>NIVEAU {intensity} VAN 5</small><h3>{intensityCopy[intensity - 1][0]}</h3><p>{intensityCopy[intensity - 1][1]}</p></motion.div><span className="pp-intensity-footnote">Overslaan mag altijd. Jullie avontuur past zich aan.</span></div>
        </motion.section>

        <PublishedContent contentKeys={['programme', 'practical', 'story', 'emergency']} /><motion.section id="pp-practical" className="pp-practical pp-section" {...reveal} aria-labelledby="pp-practical-title"><div><span className="pp-section-number">05 / GOED OM TE WETEN</span><h2 id="pp-practical-title">GOED VOORBEREID.<br />LEKKER OP PAD.</h2></div><div className="pp-faqs">
          <details><summary>Waar beginnen en eindigen we?<ChevronDown size={20} /></summary><p>Jullie beginnen bij het startpunt op het Duinpad. Daar scan je de eerste QR. De laatste Frightzone en het eindpunt zijn opnieuw bij het Duinpad.</p></details>
          <details><summary>Moeten we met een vaste groep lopen?<ChevronDown size={20} /></summary><p>Nee. Iedere inschrijving loopt zelfstandig. Via Samen in de app kunnen jullie vrijwillig een ander gezin uitnodigen om samen te lopen.</p></details>
          <details><summary>Hoe werkt onze route?<ChevronDown size={20} /></summary><p>De app toont één actuele bestemming. Na de QR-scan bij de zone verschijnt de volgende. De route houdt rekening met open zones, pauzes, drukte en jullie gekozen spanning.</p></details>
          <details><summary>Wat als een zone te spannend is?<ChevronDown size={20} /></summary><p>Bekijk vooraf het pompoenniveau en kies wat bij jullie past. In de app kun je een zone overslaan of het maximale spanningsniveau aanpassen.</p></details>
          <details><summary>Is er rekening met toegankelijkheid?<ChevronDown size={20} /></summary><p>Geef bij je inschrijving aan of jullie zonder treden willen lopen, rook of flitsen willen vermijden en hoeveel spanning past. Bij samenlopen geldt elke comfortvoorkeur voor het hele gezelschap. De Duinpadfinale heeft een passende rustige terugkomst.</p></details><details><summary>Is mijn startblok een vaste afspraak?<ChevronDown size={20} /></summary><p>Het startblok helpt verwachte aankomsten spreiden. Het is geen verplichte afspraak. Jullie kunnen wel pas starten vanaf het begin van de gekozen tocht: 17:00 of 18:30.</p></details><details><summary>Wat doen we zonder verbinding?<ChevronDown size={20} /></summary><p>Download vooraf het noodpakket in je Nachtpas. Bij totale uitval helpen de vrijwilligers met fysieke routekaartjes. Het Duinpad blijft het vaste hulppunt en het fysieke Lichtbaken werkt lokaal.</p></details><details><summary>Hoe werkt de testeditie?<ChevronDown size={20} /></summary><p>Dit is de afgeschermde testeditie van FrightNight 2027. Je logt met je eigen account in. Betalingen verlopen uitsluitend via testmodus; actuele beschikbaarheid en voortgang worden op de server bevestigd.</p></details>
        </div></motion.section>

        <section className="pp-last-call"><motion.img className="pp-final-king" src="/frightnight/king-head.webp" alt="" aria-hidden="true" loading="lazy" initial={false} whileInView={{opacity:.22,y:0,rotate:-6}} viewport={{once:true,amount:.1}} transition={{duration:calm?0:.8,ease:'easeOut'}}/><div><span className="pp-section-number">DUINDORP FRIGHTNIGHT / 30 OKTOBER 2027</span><h2>ZET DE NACHT<br />IN JE AGENDA.</h2></div><a className="pp-last-arrow" href="#pp-adventures" aria-label="Kies jouw avontuur"><ArrowUpRight /></a></section>
      </main>
      <footer className="pp-footer"><Brand /><div><span>DE NACHT IS VAN DE BUURT.</span><p>Oogstdorp · Lantaarnentocht · Worteltocht</p></div><div className="pp-footer-links"><Link href="/mijn-zone">Mijn huis doet mee <ArrowUpRight size={16} /></Link><Link href="/avondregie">Bekijk Avondregie <ArrowUpRight size={16} /></Link></div></footer>
    </div>
  );
}
