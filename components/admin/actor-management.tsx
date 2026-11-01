'use client';
import { useCallback, useEffect, useState } from 'react';
import { ACTOR_LABELS, ACTOR_PERMISSIONS, type ActorAdminRow, type ActorPermission } from '@/lib/duinpad/actor-model';
import '../actors/actors.css';
const presets: Array<{ label: string; permissions: ActorPermission[] }> = [
  { label: 'Geen rechten', permissions: [] }, { label: 'Heks', permissions: ['heks.ready', 'heks.go'] },
  { label: 'Pad 1', permissions: ['zone1.trigger'] }, { label: 'Pad 2', permissions: ['zone2.trigger'] }, { label: 'Pad 3', permissions: ['zone3.trigger'] },
  { label: 'Finale', permissions: ['finale.ready', 'finale.go'] },
];
const invitationStatus = { pending: 'Uitgenodigd', active: 'Actief', revoked: 'Ingetrokken', expired: 'Verlopen' };
function shownTime(value: string | null) { return value ? new Date(value).toLocaleString('nl-NL', { timeZone: 'Europe/Amsterdam' }) : 'Nog niet'; }
function mailStatus(value: string | null) { return value === 'accepted' ? 'Provider heeft geaccepteerd; aflevering onbekend' : value === 'delivered' ? 'Aflevering bevestigd' : ['pending', 'processing', 'deferred'].includes(value ?? '') ? 'In wachtrij / wordt verwerkt' : value === 'failed' ? 'Verzenden mislukt' : value === 'suppressed' ? 'Niet verstuurd' : 'Nog niet verstuurd'; }
export function ActorManagement() {
  const [actors, setActors] = useState<ActorAdminRow[]>([]);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const response = await fetch('/api/actors/admin', { cache: 'no-store' });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error?.message || 'Acteurs konden niet worden opgehaald.');
    setActors(body.data.actors);
  }, []);
  useEffect(() => { const timer = setTimeout(() => void load().catch(error => setNotice(error.message)), 0); return () => clearTimeout(timer); }, [load]);
  async function mutate(body: Record<string, unknown>) {
    if (busy) return;
    setBusy(true); setNotice('');
    try {
      const response = await fetch('/api/actors/admin', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error?.message || 'De wijziging kon niet worden bevestigd.');
      setNotice(result.data.bridgeUpdated ? 'Opgeslagen en aan de showcomputer bevestigd.' : 'Opgeslagen. De showverbinding en mailstatus worden afzonderlijk gecontroleerd.');
      if (body.action === 'invite') { setName(''); setEmail(''); }
      await load();
    } catch (error) { setNotice(error instanceof Error ? error.message : 'Maak verbinding en probeer opnieuw.'); }
    finally { setBusy(false); }
  }
  return <div className="actor-admin"><section className="actor-admin-card"><h2>Acteurs & showbediening</h2><p>Uitnodigingen maken een eigen acteurskoppeling. Iedere acteur begint zonder rechten. Alleen expliciet opgeslagen knoppen geven bediening.</p>{notice && <p role="status" className="notice">{notice}</p>}<form onSubmit={event => { event.preventDefault(); void mutate({ action: 'invite', name, email }); }}><label>Naam<input required maxLength={100} value={name} onChange={event => setName(event.target.value)} autoComplete="name" /></label><label>E-mailadres<input required type="email" maxLength={254} value={email} onChange={event => setEmail(event.target.value)} autoComplete="email" /></label><div><button className="btn" disabled={busy}>Uitnodigen zonder rechten</button></div></form></section>
    {actors.map(actor => <ActorAccessCard key={`${actor.id}:${actor.revision}`} actor={actor} busy={busy} mutate={mutate} />)}
  </div>;
}
function ActorAccessCard({ actor, busy, mutate }: { actor: ActorAdminRow; busy: boolean; mutate: (body: Record<string, unknown>) => Promise<void> }) {
  const [permissions, setPermissions] = useState(actor.permissions);
  return <section className="actor-admin-card"><h3>{actor.name}</h3><p>{actor.email}</p><dl><dt>Uitnodiging</dt><dd>{invitationStatus[actor.status]}</dd><dt>Mail</dt><dd>{mailStatus(actor.mailStatus)}</dd><dt>Activatie</dt><dd>{shownTime(actor.activatedAt)}</dd><dt>Link verloopt</dt><dd>{shownTime(actor.expiresAt)}</dd><dt>Laatst gezien</dt><dd>{shownTime(actor.lastSeenAt)}</dd></dl>
    <p>Presets kiezen zichtbare knoppen. Een zonenaam geeft geen extra rechten. Globale stop wordt altijd afzonderlijk toegewezen.</p><div className="actor-presets">{presets.map(preset => <button type="button" className="btn outline" key={preset.label} disabled={busy || actor.status === 'revoked'} onClick={() => setPermissions(preset.permissions)}>{preset.label}</button>)}</div>
    <fieldset className="actor-permissions" disabled={busy || actor.status === 'revoked'}><legend>Expliciete bediening</legend>{ACTOR_PERMISSIONS.map(permission => <label key={permission}><input type="checkbox" checked={permissions.includes(permission)} onChange={event => setPermissions(current => event.target.checked ? [...current, permission] : current.filter(item => item !== permission))} />{ACTOR_LABELS[permission]}</label>)}</fieldset>
    <div className="actor-admin-actions"><button className="btn" disabled={busy || actor.status === 'revoked'} onClick={() => void mutate({ action: 'permissions', id: actor.id, revision: actor.revision, permissions })}>Rechten opslaan</button><button className="btn outline" disabled={busy} onClick={() => void mutate({ action: 'reinvite', id: actor.id, email: actor.email })}>Opnieuw uitnodigen</button><button className="btn outline" disabled={busy || actor.status === 'revoked'} onClick={() => void mutate({ action: 'revoke', id: actor.id, revision: actor.revision })}>Toegang intrekken</button></div>
  </section>;
}
