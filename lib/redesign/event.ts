import 'server-only';
import { createClient } from '@/lib/supabase/server';
import { serverEnv } from '@/lib/config/server-env';
import type { EventDetails } from '@/components/redesign/event-details';

export async function publicEvent(): Promise<EventDetails> {
  const client = await createClient();
  const result = await client?.schema('api').rpc('event_public_snapshot', { _event_slug: serverEnv().EVENT_SLUG });
  const data = result?.data;
  return { date: data?.date ?? null, phase: data?.phase ?? null, priceCents: data?.priceCents ?? null, startsAt: data?.startsAt ?? null, endsAt: data?.endsAt ?? null };
}
