"use client";
/* eslint-disable react-hooks/set-state-in-effect -- Synchronize speech synthesis and the authorized child snapshot; these effects never write a domain action. */

import { useEffect, useMemo, useRef, useState } from 'react';
import { Dialog as Primitive } from 'radix-ui';
import { ArrowLeft, ArrowRight, BookOpen, Check, CheckCircle2, Clock3, LockKeyhole, Moon, Square, Volume2, X } from 'lucide-react';
import type { BookSnapshot } from '@/lib/poortenboek/model';
import { storyChapters } from '@/lib/poortenboek/v2';
import { personalizeStory } from '@/lib/poortenboek/story-content';
import '../../modern/book-stories.css';

type ReadingSnapshot = BookSnapshot & { reading?: { readChapters?: number[] } };
type Props = { snapshot: ReadingSnapshot; onRead?: (chapter: number) => void | Promise<void> };

export function StoryChapters({ snapshot, onRead }: Props) {
  const [active, setActive] = useState<number | null>(null);
  const [read, setRead] = useState<number[]>(snapshot.reading?.readChapters ?? []);
  const [speaking, setSpeaking] = useState(false);
  const [canSpeak, setCanSpeak] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const childKey = `${snapshot.eventId}:${snapshot.childId}:${snapshot.firstName}`;
  const child = useRef(childKey);
  const textPane = useRef<HTMLDivElement>(null);
  const utterance = useRef<SpeechSynthesisUtterance | null>(null);
  const unlocked = useMemo(() => new Set(snapshot.journey.chapters.map(item => item.chapter)), [snapshot.journey.chapters]);
  const chapter = storyChapters.find(item => item.chapter === active);
  const story = active !== null && unlocked.has(active) ? snapshot.reading?.stories?.find(item => item.chapter === active) : undefined;
  const allowed = storyChapters.filter(item => unlocked.has(item.chapter));
  const currentIndex = allowed.findIndex(item => item.chapter === active);
  const readCount = read.filter(number => unlocked.has(number)).length;

  function stopSpeaking() {
    if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.cancel();
    utterance.current = null; setSpeaking(false);
  }
  useEffect(() => {
    setCanSpeak('speechSynthesis' in window && typeof SpeechSynthesisUtterance !== 'undefined');
    return () => { if ('speechSynthesis' in window) window.speechSynthesis.cancel(); };
  }, []);
  useEffect(() => {
    if (child.current !== childKey) {
      stopSpeaking(); setActive(null); setError(''); setBusy(false); child.current = childKey;
    }
    setRead(snapshot.reading?.readChapters ?? []);
  }, [childKey, snapshot.reading]);
  useEffect(() => {
    stopSpeaking(); setError(''); textPane.current?.scrollTo({ top: 0 });
  }, [active]);
  useEffect(() => {
    if (active !== null && !unlocked.has(active)) { stopSpeaking(); setActive(null); }
  }, [active, unlocked]);

  function open(number: number) { if (unlocked.has(number)) setActive(number); }
  function close() { stopSpeaking(); setActive(null); }
  function speak() {
    if (!story || !chapter || !canSpeak) return;
    if (speaking) { stopSpeaking(); return; }
    window.speechSynthesis.cancel();
    const speech = new SpeechSynthesisUtterance([chapter.title, ...story.paragraphs.map(text => personalizeStory(text, snapshot.firstName)), story.wonder].join('\n\n'));
    speech.lang = 'nl-NL'; speech.rate = .88;
    const dutch = window.speechSynthesis.getVoices().find(voice => voice.lang.toLowerCase().startsWith('nl'));
    if (dutch) speech.voice = dutch;
    speech.onend = speech.onerror = () => { if (utterance.current === speech) { utterance.current = null; setSpeaking(false); } };
    utterance.current = speech; setSpeaking(true); window.speechSynthesis.speak(speech);
  }
  async function markRead() {
    if (!chapter || !story || busy || read.includes(chapter.chapter)) return;
    const number = chapter.chapter, owner = childKey;
    setBusy(true); setError('');
    try {
      if (onRead) await onRead(number);
      else {
        const response = await fetch('/api/poortenboek/chapter_read', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ chapter: number }) });
        if (!response.ok) throw new Error('save');
      }
      if (child.current === owner) setRead(current => [...new Set([...current, number])]);
    } catch {
      if (child.current === owner) setError('Het onthouden lukte even niet. Je kunt rustig verder lezen en het later nog eens proberen.');
    } finally { if (child.current === owner) setBusy(false); }
  }

  return <section className="pb-story-library" aria-labelledby="pb-story-library-title" data-tutorial="book-stories">
    <header className="pb-story-library-heading"><div><p className="pb-eyebrow">Jouw verhaal ontwaakt</p><h2 id="pb-story-library-title">Een hoofdstuk voor ieder stukje avontuur</h2><p>Open een wakker hoofdstuk. Lees zelf, luister of lees samen met een volwassene.</p></div><span className="pb-story-reading-count"><BookOpen size={17}/>{readCount} van {allowed.length} gelezen</span></header>
    <div className="pb-chapter-grid">{storyChapters.map(item => {
      const available = unlocked.has(item.chapter), done = read.includes(item.chapter), copy = snapshot.reading?.stories?.find(story => story.chapter === item.chapter);
      return <article className={`pb-chapter-card ${available ? 'is-awake' : 'is-sleeping'} ${done ? 'is-read' : ''}`} key={item.chapter}>
        <div className="pb-chapter-image"><img src={`/images/poortenboek-v2/${item.image}`} alt="" loading="lazy"/><span>{available ? done ? <CheckCircle2 size={17}/> : <BookOpen size={17}/> : <LockKeyhole size={17}/>} {done ? 'Gelezen' : available ? 'Wakker' : 'Slaapt nog'}</span></div>
        <div className="pb-chapter-copy"><p className="pb-eyebrow">Hoofdstuk {item.chapter}</p><h3>{item.title}</h3><p>{available ? copy?.subtitle : item.chapter === 6 ? 'Dit hoofdstuk opent na de laatste poort.' : 'Dit hoofdstuk wordt tijdens jouw tocht wakker.'}</p><button className="pb-chapter-open" type="button" disabled={!available} onClick={() => open(item.chapter)} aria-label={available ? `${done ? 'Lees opnieuw' : 'Lees'}: ${item.title}` : `${item.title} slaapt nog`}>{available ? <><span>{done ? 'Lees nog een keer' : 'Open het hoofdstuk'}</span><ArrowRight size={17}/></> : <><LockKeyhole size={15}/><span>Nog even dromen</span></>}</button></div>
      </article>;
    })}</div>
    <p className="pb-story-kind-note"><Moon size={16}/>Jouw avontuur is van jou. Je mag een spannende belevenis overslaan en bij je volwassene blijven. De zegel van jullie aankomst blijft van jou.</p>
    <Primitive.Root open={Boolean(chapter && story)} onOpenChange={open => { if (!open) close(); }}><Primitive.Portal><Primitive.Overlay className="pb-reader-overlay"/><Primitive.Content className="pb-story-reader" aria-describedby="pb-reader-description">
      {chapter && story && <><div className="pb-reader-cover"><img src={`/images/poortenboek-v2/${chapter.image}`} alt=""/><div><span>Hoofdstuk {chapter.chapter} van 6</span><BookOpen size={32}/><p>Het Poortenboek van<br/><strong>{snapshot.firstName}</strong></p></div></div><div className="pb-reader-main"><header className="pb-reader-heading"><div><p>Jouw Duindorpse avontuur</p><Primitive.Title>{chapter.title}</Primitive.Title><Primitive.Description id="pb-reader-description">{story.subtitle}</Primitive.Description></div><Primitive.Close className="pb-reader-close" aria-label="Hoofdstuk sluiten"><X size={20}/></Primitive.Close></header><div className="pb-reader-toolbar"><span><Clock3 size={15}/>Ongeveer {story.readingMinutes} minuten lezen</span>{canSpeak && <button type="button" onClick={speak} aria-pressed={speaking}>{speaking ? <Square size={14}/> : <Volume2 size={16}/>} {speaking ? 'Stop voorlezen' : 'Lees voor'}</button>}</div><div className="pb-reader-text" ref={textPane}>{story.paragraphs.map((text, index) => <p key={index}>{personalizeStory(text, snapshot.firstName)}</p>)}<aside className="pb-reader-wonder"><span>Even samen nadenken</span><p>{story.wonder}</p></aside>{error && <p className="pb-reader-error" role="alert">{error}</p>}<button className={`pb-reader-mark ${read.includes(chapter.chapter) ? 'is-read' : ''}`} type="button" disabled={busy || read.includes(chapter.chapter)} onClick={() => void markRead()}>{read.includes(chapter.chapter) ? <CheckCircle2 size={19}/> : <Check size={19}/>} {read.includes(chapter.chapter) ? 'Dit hoofdstuk heb je gelezen' : busy ? 'Even onthouden…' : 'Ik heb dit hoofdstuk gelezen'}</button></div><footer className="pb-reader-footer"><button type="button" disabled={currentIndex <= 0} onClick={() => open(allowed[currentIndex - 1].chapter)}><ArrowLeft size={17}/><span>Vorige</span></button><span>{currentIndex + 1} / {allowed.length} wakker</span><button type="button" disabled={currentIndex < 0 || currentIndex >= allowed.length - 1} onClick={() => open(allowed[currentIndex + 1].chapter)}><span>Volgende</span><ArrowRight size={17}/></button></footer></div></>}
    </Primitive.Content></Primitive.Portal></Primitive.Root>
  </section>;
}
