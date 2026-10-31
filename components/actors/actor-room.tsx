'use client';
import Link from 'next/link';
import { useCallback, useEffect, useState } from 'react';
import { ACTOR_LABELS, type ActorPermission, type ActorReceipt, type ActorSnapshot } from '@/lib/duinpad/actor-model';
import './actors.css';

export function ActorRoom({ initial }: { initial: ActorSnapshot }) {
  const [snapshot, setSnapshot] = useState(initial);
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [denied, setDenied] = useState(false);
  const [now, setNow] = useState(() => Date.now() / 1000);
  const refresh = useCallback(async () => {
    try {
      const response = await fetch('/api/actors', { cache: 'no-store' });
      const body = await response.json();
      if ([401, 403].includes(response.status)) { setDenied(true); setNotice(body.error?.message || 'Je toegang is gewijzigd.'); return; }
      if (!response.ok) throw new Error('offline');
      setSnapshot(body.data); setDenied(false);
    } catch { setSnapshot(current => ({ ...current, connected: false })); }
  }, []);
  useEffect(() => {
    let inFlight = false;
    const update = async () => { if (inFlight || document.hidden) return; inFlight = true; try { await refresh(); } finally { inFlight = false; } };
    const poll = setInterval(() => void update(), 3000);
    const tick = setInterval(() => setNow(Date.now() / 1000), 1000);
    window.addEventListener('focus', update);
    document.addEventListener('visibilitychange', update);
    return () => { clearInterval(poll); clearInterval(tick); window.removeEventListener('focus', update); document.removeEventListener('visibilitychange', update); };
  }, [refresh]);
  const fresh = snapshot.connected && snapshot.compatible && now - snapshot.observedAt <= 5 && now - snapshot.observedAt >= -2;
  async function command(action: ActorPermission, ready?: boolean) {
    if (busy || denied || !fresh) return;
    setBusy(true); setNotice('Start aangevraagd. Wacht op de lokale bevestiging.');
    try {
      const response = await fetch('/api/actors/command', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ commandId: crypto.randomUUID(), action, ...(ready === undefined ? {} : { ready }) }) });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error?.message || 'De opdracht kon niet worden bevestigd.');
      setNotice(body.data.message || (body.data.status === 'started' ? 'Lokaal bevestigd.' : 'Vraag de begeleider om de regie te controleren.'));
      await refresh();
    } catch (error) { setNotice(error instanceof Error ? error.message : 'Geen startbevestiging ontvangen. Controleer de regie.'); }
    finally { setBusy(false); }
  }
  async function recover(receipt: ActorReceipt) {
    if (busy) return;
    setBusy(true);
    try {
      const response = await fetch(`/api/actors/receipts/${receipt.commandId}`, { cache: 'no-store' });
      const body = await response.json();
      setNotice(body.data?.result?.message || body.error?.message || 'Er is nog geen betrouwbare uitvoeringsuitslag. Vraag de regie.');
      await refresh();
    } catch { setNotice('De ontvangst kon niet worden opgehaald. Er wordt geen nieuwe start verstuurd.'); }
    finally { setBusy(false); }
  }
  return <div className="actor-page"><header className="actor-header"><Link href="/omgeving/kiezen"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" /></Link><Link href="/omgeving/kiezen" className="btn outline">Mijn omgevingen</Link></header><main className="actor-main">
    <p className="eyebrow">Jouw toegewezen bediening</p><h1>Acteurskamer</h1><p>Welkom {snapshot.name}. Wacht na iedere druk op de bevestiging van de showcomputer.</p>
    <p className={`actor-connection ${fresh && !denied ? 'is-connected' : ''}`} role="status">{denied ? 'Toegang gewijzigd' : fresh ? 'Showcomputer verbonden · actuele lokale status' : 'Geen actuele verbinding met de showcomputer'}</p>
    {notice && <p className="actor-notice" role="status" aria-live="polite">{notice}</p>}
    {!denied && snapshot.permissions.length === 0 && <section className="actor-card"><h2>Nog geen knoppen toegewezen</h2><p>De organisatie kan je expliciete showbediening toewijzen.</p></section>}
    {!denied && <section className="actor-controls" aria-label="Jouw showknoppen">{snapshot.controls.filter(control => snapshot.permissions.includes(control.action)).map(control => {
      const unresolved = snapshot.receipts.some(receipt => receipt.action === control.action && ['requested', 'unknown', 'interrupted', 'recovery_required'].includes(receipt.status));
      const disabled = busy || !fresh || !control.enabled || unresolved;
      const reason = unresolved ? 'Onzekere uitvoering: controleer eerst de regie' : !fresh ? 'Geen verbinding met de showcomputer' : control.blocked_reason;
      return <article key={control.action} className={`actor-card ${control.action === 'stop-all' ? 'actor-emergency' : ''}`}><h2>{ACTOR_LABELS[control.action]}</h2>{control.effect?.active && <p>Effect speelt</p>}{reason && <p>{reason}</p>}
        {control.action.endsWith('.ready') ? <div className="actor-ready"><button className="btn" disabled={disabled} onClick={() => void command(control.action, true)}>Gereed</button><button className="btn outline" disabled={disabled} onClick={() => void command(control.action, false)}>Niet gereed</button></div>
          : <button className="btn" disabled={disabled} onClick={() => void command(control.action)}>{ACTOR_LABELS[control.action]}</button>}
      </article>;
    })}</section>}
    {!denied && snapshot.receipts.some(receipt => ['requested', 'unknown', 'interrupted', 'recovery_required'].includes(receipt.status)) && <section className="actor-card"><h2>Controle bij de regie nodig</h2><p>Er is geen betrouwbare startbevestiging. Een ontvangst ophalen stuurt geen nieuwe start.</p>{snapshot.receipts.filter(receipt => ['requested', 'unknown', 'interrupted', 'recovery_required'].includes(receipt.status)).map(receipt => <div className="actor-receipt" key={receipt.commandId}><strong>{ACTOR_LABELS[receipt.action]}</strong><p>{receipt.result?.message || 'Geen startbevestiging ontvangen.'}</p><button className="btn outline" disabled={busy} onClick={() => void recover(receipt)}>Ontvangst controleren</button></div>)}</section>}
  </main></div>;
}
