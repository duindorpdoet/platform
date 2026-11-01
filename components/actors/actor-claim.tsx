'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { EntryHeader } from '@/components/auth/account-login';
import { SignOutButton } from '@/components/auth/account-actions';
import './actors.css';
export function ActorClaim({ email, prepared }: { email: string | null; prepared: boolean }) {
  const [ready, setReady] = useState(prepared);
  const [busy, setBusy] = useState(false);
  const [active, setActive] = useState(false);
  const [notice, setNotice] = useState('');
  useEffect(() => {
    const params = new URLSearchParams(window.location.hash.slice(1));
    const token = params.get('token');
    if (!token) return;
    history.replaceState(null, '', '/uitnodiging/acteur');
    let cancelled = false;
    void fetch('/api/actors/claim', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'prepare', token }) }).then(async response => {
      const body = await response.json();
      if (cancelled) return;
      if (response.ok) setReady(true); else setNotice(body.error?.message || 'Open de uitnodiging opnieuw.');
    }).catch(() => { if (!cancelled) setNotice('Open de uitnodigingslink opnieuw zodra je verbinding hebt.'); });
    return () => { cancelled = true; };
  }, []);
  async function claim() {
    setBusy(true); setNotice('');
    try {
      const response = await fetch('/api/actors/claim', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'claim' }) });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error?.message || 'Deze uitnodiging kon niet worden geactiveerd.');
      setActive(true);
    } catch (error) { setNotice(error instanceof Error ? error.message : 'Maak verbinding en probeer opnieuw.'); }
    finally { setBusy(false); }
  }
  return <div className="entry-page"><EntryHeader /><main className="actor-main"><section className="actor-card"><p className="eyebrow">Uitnodiging van de organisatie</p><h1>Jouw Acteurskamer</h1>
    {active ? <><p>Je acteursomgeving is geactiveerd. Je overige omgevingen blijven beschikbaar.</p><Link className="btn" href="/omgeving/acteur">Open mijn Acteurskamer</Link></> : <>
      <p>Log in met precies het e-mailadres waarop je bent uitgenodigd, met een e-mailcode of Google. Activeer daarna zelf deze uitnodiging.</p>
      {notice && <p role="alert" className="actor-notice">{notice}</p>}
      {!ready && <p>Open de geldige uitnodigingslink uit je e-mail. Een verlopen of ingetrokken link kan de organisatie opnieuw versturen.</p>}
      {ready && !email && <Link className="btn" href="/inloggen?next=/uitnodiging/acteur">Inloggen en uitnodiging bekijken</Link>}
      {email && <><p>Je bent ingelogd als <strong>{email}</strong>. Controleer dat dit het uitgenodigde adres is.</p><button className="btn" disabled={!ready || busy} onClick={() => void claim()}>Activeer mijn acteursomgeving</button><p><SignOutButton label="Met een ander account inloggen" destination="/inloggen?next=/uitnodiging/acteur" /></p></>}
    </>}
    <p><Link href="/omgeving/kiezen">Naar mijn omgevingen</Link></p>
  </section></main></div>;
}
