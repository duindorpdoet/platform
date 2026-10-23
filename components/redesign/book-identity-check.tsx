"use client";
/* eslint-disable @next/next/no-html-link-for-pages -- Private book navigation revalidates the cookie and discards the previous child snapshot. */
import { useEffect, useRef } from 'react';
import { ArrowRight, BookOpen, Check, Shuffle } from 'lucide-react';
import type { BookSnapshot } from '@/lib/poortenboek/model';
import { avatarOptions } from '@/lib/poortenboek/v2';
import { MagicLantern } from '@/components/poortenboek/magic-lantern';
import '../../modern/book-farewell.css';

const ACK_KEY = 'poortenboek-confirmed-identity-v1';
export function bookIdentitySource(snapshot: BookSnapshot) {
  return `${snapshot.eventDate}:${snapshot.childId ?? 'staging-demo-book'}`;
}
export async function bookIdentityKey(snapshot: BookSnapshot) {
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(bookIdentitySource(snapshot)));
  return Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('');
}
export function readConfirmedBookIdentity() {
  try { const value=sessionStorage.getItem(ACK_KEY)??'';if(/^[a-f0-9]{64}$/.test(value))return value;sessionStorage.removeItem(ACK_KEY);return ''; } catch { return ''; }
}
export function saveConfirmedBookIdentity(key: string) {
  try { if(/^[a-f0-9]{64}$/.test(key))sessionStorage.setItem(ACK_KEY,key);else sessionStorage.removeItem(ACK_KEY); } catch { /* The mounted book still keeps the acknowledgement. */ }
}

/** Name-first confirmation prevents accidentally continuing in a sibling's book. */
export function BookIdentityCheck({ snapshot, onConfirm }: { snapshot: BookSnapshot; onConfirm: () => void }) {
  const title = useRef<HTMLHeadingElement>(null);
  useEffect(() => { title.current?.focus(); }, []);
  const avatar = avatarOptions.find(item => item.id === snapshot.identity.avatarId);
  return <main className="pb-identity-check" id="poortenboek-content">
    <div className="pb-identity-backdrop" aria-hidden="true"><img src="/images/poortenboek/dashboard-night.webp" alt=""/></div>
    <section className="pb-identity-card" aria-labelledby="pb-identity-title">
      <a className="pb-identity-brand" href="/"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width="150" height="65"/></a>
      <p className="pb-eyebrow"><BookOpen size={16}/>Even samen kijken</p>
      <h1 id="pb-identity-title" ref={title} tabIndex={-1}>Je opent het boek van<br/><strong>{snapshot.firstName}</strong></h1>
      <p>Dit is jouw eigen plek in het avontuur. Klopt de naam? Dan gaan we verder in jouw boek.</p>
      <div className="pb-identity-art"><div className="pb-identity-avatar"><img src={`/images/poortenboek-v2/avatars/${snapshot.identity.avatarId}.webp`} alt={`De verschijning van ${snapshot.firstName}`}/><span>{avatar?.label ?? 'Jouw avonturenrol'}</span></div><MagicLantern shape={snapshot.identity.lanternShape} color={snapshot.identity.lanternColor} compact/></div>
      <div className="pb-identity-name"><Check size={16}/><span>Het Poortenboek van <strong>{snapshot.firstName}</strong></span></div>
      <button className="pb-button pb-identity-confirm" type="button" onClick={onConfirm}>Dit is mijn boek<ArrowRight size={18}/></button>
      <a className="pb-identity-other" href="/poortenboek/inloggen"><Shuffle size={15}/>Ik wil een ander boek openen</a>
      <p className="pb-identity-help">Een volwassene kan helpen met de juiste boekcode.</p>
    </section>
  </main>;
}
