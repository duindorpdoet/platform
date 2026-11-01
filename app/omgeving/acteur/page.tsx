import Link from 'next/link';
import { redirect } from 'next/navigation';
import { actorSnapshot } from '@/lib/duinpad/actors';
import { ApiError } from '@/lib/http/api';
import { ActorRoom } from '@/components/actors/actor-room';
export const dynamic = 'force-dynamic';
export const metadata = { title: 'Acteurskamer · De Duindorpse Poorten', robots: { index: false, follow: false } };
export default async function ActorRoomPage() {
  let snapshot;
  try { snapshot = await actorSnapshot(); }
  catch (error) { if (error instanceof ApiError && error.status === 401) redirect('/inloggen?next=/omgeving/acteur'); }
  if (!snapshot) return <main className="wrap page"><h1>Je Acteurskamer is niet beschikbaar.</h1><p>Je hebt een actieve uitnodigingskoppeling nodig. De organisatie kan je toegang controleren.</p><Link className="btn" href="/omgeving/kiezen">Mijn omgevingen</Link></main>;
  return <ActorRoom initial={snapshot} />;
}
