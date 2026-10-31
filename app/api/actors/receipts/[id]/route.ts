import { interpretActorAck } from '@/lib/duinpad/actor-protocol';
import { finishActorFinale } from '@/lib/duinpad/show';
import { z } from 'zod';
import { actorRpcError, actorRelayRequest, currentActorAccess, finishActorCommand } from '@/lib/duinpad/actors';
import { ApiError, apiSuccess, apiFailure, correlationId } from '@/lib/http/api';
import { serverEnv } from '@/lib/config/server-env';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    const id = z.uuid().parse((await context.params).id);
    const { client, access } = await currentActorAccess();
    const stored = await client.schema('api').rpc('duinpad_actor_receipt', { _event_slug: serverEnv().EVENT_SLUG, _command_id: id });
    actorRpcError(stored.error);
    const receipt = stored.data;
    if (!receipt) throw new ApiError(404, 'ACTOR_RECEIPT_NOT_FOUND', 'Deze ontvangst is niet beschikbaar.');
    if (!['requested', 'unknown', 'interrupted', 'recovery_required'].includes(receipt.status)) return apiSuccess({ commandId: id, action: receipt.action, status: receipt.status, result: receipt.result });
    const query = new URLSearchParams({ kind: 'actor', payload_hash: receipt.payloadHash });
    if (receipt.groupId) query.set('group_id', receipt.groupId);
    try {
      const response = await actorRelayRequest(access, `/api/integration/receipts/${encodeURIComponent(id)}?${query}`);
      const body = await response.json();
      if (response.ok && body?.found === true && body.command_id === id && body.payload_hash === receipt.payloadHash && body.group_id === receipt.groupId) {
        const recovery = body.group?.recovery_required === true || body.group?.group_status === 'interrupted';
        const { status, result } = recovery ? { status: 'recovery_required' as const, result: { ok: false, unknown: true, duplicate: false, message: 'De uitvoering is onderbroken. Vraag de regie om herstelcontrole.' } } : interpretActorAck(200, body.result, id, receipt.action);
        if (status !== 'unknown') {
          if (receipt.action === 'finale.go') await finishActorFinale({ attemptId: id, commandId: id, status, result, reconciled: true });
          await finishActorCommand(id, status, result);
          return apiSuccess({ commandId: id, action: receipt.action, status, result });
        }
      }
    } catch { /* Read-only recovery failure retains original uncertainty. */ }
    return apiSuccess({ commandId: id, action: receipt.action, status: receipt.status, result: receipt.result });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
