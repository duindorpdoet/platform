import { actorCommandInput, commandPayload, payloadHash, signedEnvelope, interpretActorAck } from '@/lib/duinpad/actor-protocol';
import { actorRpcError, actorRelayRequest, currentActorAccess, finishActorCommand, localActorStatus } from '@/lib/duinpad/actors';
import { reserveActorFinale, finishActorFinale } from '@/lib/duinpad/show';
import { ApiError, apiSuccess, apiFailure, assertTrustedOrigin, correlationId } from '@/lib/http/api';
import { readBoundedJson } from '@/lib/http/bounded-json';
import { serverEnv } from '@/lib/config/server-env';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function POST(request: Request) {
  let commandId: string | undefined;
  let attemptId: string | undefined;
  let reserved = false;
  let dispatchAttempted = false;
  try {
    assertTrustedOrigin(request);
    const input = actorCommandInput.parse(await readBoundedJson(request, 1024));
    commandId = input.commandId;
    if (request.signal.aborted) throw new ApiError(409, 'ACTOR_REQUEST_ABORTED', 'De aanvraag is afgebroken voordat deze is verstuurd.');
    const { client, access } = await currentActorAccess();
    if (!access.permissions.includes(input.action)) throw new ApiError(403, 'ACTOR_PERMISSION_DENIED', 'Deze knop is niet aan jou toegewezen.');
    // Local selection is authoritative. Browser requests contain no group or scope.
    const local = await localActorStatus(access);
    const control = local.controls.find(item => item.action === input.action);
    if (!local.connected || !control?.enabled) throw new ApiError(409, 'ACTOR_BLOCKED', control?.blocked_reason || 'Deze knop is lokaal nog niet vrijgegeven.');
    const payload = commandPayload(access, input, control.group_id);
    const text = JSON.stringify(payload);
    const hash = payloadHash(text);
    const reserve = await client.schema('api').rpc('duinpad_actor_reserve', { _event_slug: serverEnv().EVENT_SLUG, _command_id: input.commandId, _payload_text: text });
    actorRpcError(reserve.error);
    if (!reserve.data?.dispatch) return apiSuccess({ ...reserve.data, duplicate: true });
    reserved = true;
    if (input.action === 'finale.go') {
      const slot = await reserveActorFinale({ eventId: access.eventId, groupId: control.group_id!, actorId: access.actorId, commandId: input.commandId, payloadHash: hash, payload });
      if (!slot.dispatch) {
        const result = { ok: false, message: slot.status === 'started' ? 'Deze groep heeft al een bevestigde finalestart.' : 'De finalestart van deze groep vereist eerst controle bij de regie.' };
        await finishActorCommand(input.commandId, 'not_dispatched', result);
        return apiSuccess({ commandId: input.commandId, status: 'not_dispatched', ...result });
      }
      attemptId = slot.attemptId;
    }
    // Recheck live DB permissions immediately before signing/dispatching. A saved
    // receipt never creates a new command and no transport layer retries this POST.
    const fresh = await currentActorAccess();
    if (fresh.access.revision !== access.revision || !fresh.access.permissions.includes(input.action)) throw new ApiError(403, 'ACTOR_PERMISSION_CHANGED', 'Je rechten zijn gewijzigd. Vernieuw de Acteurskamer.');
    if (request.signal.aborted || Date.now() / 1000 - payload.issued_at > 5 || Date.now() / 1000 - local.observed_at > 5) throw new ApiError(409, 'ACTOR_REQUEST_EXPIRED', 'De aanvraag of lokale status is verlopen voordat deze is verstuurd.');
    const envelope = signedEnvelope(text, serverEnv().DUINPAD_ACTOR_AUTH_SECRET!);
    dispatchAttempted = true;
    const response = await actorRelayRequest(fresh.access, '/api/integration/actor-command', { method: 'POST', body: JSON.stringify(envelope), signal: request.signal });
    const body = await response.json().catch(() => null);
    const { status, result } = interpretActorAck(response.status, body, input.commandId, input.action);
    if (attemptId) await finishActorFinale({ attemptId, commandId: input.commandId, status, result });
    await finishActorCommand(input.commandId, status, result);
    return apiSuccess({ commandId: input.commandId, status, ...result });
  } catch (error) {
    if (reserved && commandId) {
      // A lost response may already have started hardware. Preserve uncertainty.
      const status = dispatchAttempted ? 'unknown' : 'not_dispatched';
      const result = { ok: false, unknown: dispatchAttempted, message: dispatchAttempted ? 'Geen startbevestiging ontvangen. Vraag de begeleider om de regie te controleren.' : 'De opdracht is niet verstuurd. Vernieuw je rechten en controleer de regie.' };
      try { await finishActorCommand(commandId, status, result); if (attemptId) await finishActorFinale({ attemptId, commandId, status, result }); } catch { /* Requested stays blocking if receipt persistence is unavailable. */ }
      return apiSuccess({ commandId, status, ...result });
    }
    return apiFailure(error, correlationId(request));
  }
}
