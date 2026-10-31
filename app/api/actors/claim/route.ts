import { cookies } from 'next/headers';
import { z } from 'zod';
import { accountClient } from '@/lib/account/server';
import { actorRpcError } from '@/lib/duinpad/actors';
import { payloadHash } from '@/lib/duinpad/actor-protocol';
import { ApiError, apiSuccess, apiFailure, assertTrustedOrigin, correlationId } from '@/lib/http/api';
import { readBoundedJson } from '@/lib/http/bounded-json';
import { serverEnv } from '@/lib/config/server-env';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const ACTOR_CLAIM_COOKIE = 'duinpad_actor_claim';
const command = z.discriminatedUnion('action', [
  z.object({ action: z.literal('prepare'), token: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }).strict(),
  z.object({ action: z.literal('claim') }).strict(),
  z.object({ action: z.literal('clear') }).strict(),
]);
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = command.parse(await readBoundedJson(request, 1024));
    const jar = await cookies();
    const options = { httpOnly: true, sameSite: 'lax' as const, secure: new URL(serverEnv().APP_URL).protocol === 'https:', path: '/', maxAge: 3600 };
    if (input.action === 'prepare') {
      // Link opening only remembers a hash in an HttpOnly cookie. It grants no access.
      jar.set(ACTOR_CLAIM_COOKIE, payloadHash(input.token), options);
      return apiSuccess({ prepared: true });
    }
    if (input.action === 'clear') { jar.set(ACTOR_CLAIM_COOKIE, '', { ...options, maxAge: 0 }); return apiSuccess({ cleared: true }); }
    const hash = jar.get(ACTOR_CLAIM_COOKIE)?.value;
    if (!hash || !/^[a-f0-9]{64}$/.test(hash)) throw new ApiError(409, 'INVITATION_UNAVAILABLE', 'Open de geldige uitnodigingslink uit je e-mail opnieuw.');
    const { client } = await accountClient();
    const result = await client.schema('api').rpc('duinpad_actor_claim', { _event_slug: serverEnv().EVENT_SLUG, _token_hash: hash });
    actorRpcError(result.error);
    jar.set(ACTOR_CLAIM_COOKIE, '', { ...options, maxAge: 0 });
    return apiSuccess(result.data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
