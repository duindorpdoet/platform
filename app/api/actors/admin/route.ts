import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { accountClient } from '@/lib/account/server';
import { actorRpcError, pushActorAccess } from '@/lib/duinpad/actors';
import { invitationToken, payloadHash, permissionSchema, type ActorAccess } from '@/lib/duinpad/actor-protocol';
import { ApiError, apiSuccess, apiFailure, assertTrustedOrigin, correlationId } from '@/lib/http/api';
import { readBoundedJson } from '@/lib/http/bounded-json';
import { serverEnv } from '@/lib/config/server-env';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
const command = z.discriminatedUnion('action', [
  z.object({ action: z.literal('invite'), name: z.string().trim().min(1).max(100), email: z.email().max(254) }).strict(),
  z.object({ action: z.literal('reinvite'), id: z.uuid(), email: z.email().max(254) }).strict(),
  z.object({ action: z.literal('permissions'), id: z.uuid(), revision: z.number().int().positive(), permissions: z.array(permissionSchema).max(11).refine(values => new Set(values).size === values.length) }).strict(),
  z.object({ action: z.literal('revoke'), id: z.uuid(), revision: z.number().int().positive() }).strict(),
]);
export async function GET(request: Request) {
  try {
    const { client } = await accountClient();
    const result = await client.schema('api').rpc('duinpad_actor_admin_snapshot', { _event_slug: serverEnv().EVENT_SLUG });
    actorRpcError(result.error);
    return apiSuccess(result.data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = command.parse(await readBoundedJson(request, 4096));
    const { client } = await accountClient();
    const env = serverEnv();
    let payload: Record<string, unknown> = input;
    if (input.action === 'invite' || input.action === 'reinvite') {
      if (!env.DUINPAD_ACTOR_INVITE_SECRET) throw new ApiError(503, 'ACTOR_INVITE_NOT_CONFIGURED', 'De beveiligde uitnodigingskoppeling is nog niet ingesteld.');
      const context = await client.schema('api').rpc('duinpad_actor_admin_snapshot', { _event_slug: env.EVENT_SLUG });
      actorRpcError(context.error);
      const id = randomUUID();
      const email = input.email.trim().toLowerCase();
      const token = invitationToken(id, context.data.eventId, email, env.DUINPAD_ACTOR_INVITE_SECRET);
      payload = { ...input, email, invitationId: id, tokenHash: payloadHash(token) };
    }
    const result = await client.schema('api').rpc('duinpad_actor_admin_command', { _event_slug: env.EVENT_SLUG, _action: input.action, _payload: payload });
    actorRpcError(result.error);
    let bridgeUpdated = false;
    if (result.data?.actorId) {
      try { await pushActorAccess(result.data as ActorAccess); bridgeUpdated = true; }
      catch { /* DB permissions already changed. Grants expire after at most five seconds; no queued replay. */ }
    }
    return apiSuccess({ saved: true, bridgeUpdated });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
