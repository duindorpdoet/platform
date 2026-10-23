"use client";
/* eslint-disable @next/next/no-html-link-for-pages -- Private book navigation revalidates the cookie and discards the previous child snapshot. */
import { ArrowRight, Heart, Sparkles, Star } from 'lucide-react';
import type { BookSnapshot } from '@/lib/poortenboek/model';
import { MagicLantern } from '@/components/poortenboek/magic-lantern';
import { BookKeepsake } from './book-keepsake';
import '../../modern/book-farewell.css';

export function hasBookFarewell(snapshot: BookSnapshot) {
  return Boolean(snapshot.farewell || snapshot.journey.complete);
}

/** A family can finish its own evening without completing the group's route. */
export function BookFarewell({ snapshot, home = false }: { snapshot: BookSnapshot; home?: boolean }) {
  const count = snapshot.journey.seals.length;
  return <section className="pb-farewell" aria-labelledby="pb-farewell-title" data-tutorial="book-farewell">
    <div className="pb-farewell-scene" aria-hidden="true"><img src="/images/poortenboek-v2/recap-hero-wide.webp" alt=""/><div className="pb-farewell-light"><MagicLantern shape={snapshot.identity.lanternShape} color={snapshot.identity.lanternColor}/></div><span className="pb-farewell-spark one">✦</span><span className="pb-farewell-spark two">✧</span><span className="pb-farewell-spark three">✦</span></div>
    <div className="pb-farewell-copy">
      <p className="pb-eyebrow"><Sparkles size={15}/>Jouw nacht om te bewaren</p>
      {home ? <h1 id="pb-farewell-title">{snapshot.firstName},<br/>jij bracht licht in Duindorp.</h1> : <h2 id="pb-farewell-title">{snapshot.firstName}, jij bracht licht in Duindorp.</h2>}
      <p>Jullie zijn voor vandaag klaar. Samen op pad zijn, verwonderen en je eigen keuzes maken: dat hoort allemaal bij jouw avontuur.</p>
      <div className="pb-farewell-memory"><Star size={24}/><div><strong>{count ? `${count} ${count === 1 ? 'zegel' : 'zegels'} van jouw avond` : 'Een avond helemaal van jou'}</strong><span>{count ? 'Iedere zegel bewaart jullie aankomst. Ook als jij de beleving liever oversloeg.' : 'Ook de voorpret en samen op pad zijn horen bij jouw verhaal.'}</span></div></div>
      <p className="pb-farewell-kind"><Heart size={17}/>Je hoeft niet iedere poort te bereiken om een mooie herinnering te hebben. Jouw eigen avontuur telt.</p>
      {home && <a className="pb-button" href="/poortenboek/boek">Bekijk mijn herinneringen<ArrowRight size={17}/></a>}
    </div>
    <div className="pb-farewell-download"><BookKeepsake snapshot={snapshot}/></div>
  </section>;
}
