import { cookies } from 'next/headers';
import { createClient } from '@/lib/supabase/server';
import { ActorClaim } from '@/components/actors/actor-claim';
export const dynamic = 'force-dynamic';
export const metadata = { title: 'Activeer jouw Acteurskamer · De Poorten', robots: { index: false, follow: false }, referrer: 'no-referrer' };
export default async function ActorInvitationPage() {
  const jar = await cookies();
  const client = await createClient();
  const result = await client?.auth.getUser();
  return <ActorClaim email={result?.data.user?.email_confirmed_at ? result.data.user.email ?? null : null} prepared={/^[a-f0-9]{64}$/.test(jar.get('duinpad_actor_claim')?.value ?? '')} />;
}
