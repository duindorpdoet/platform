import { currentActorAccess, localActorStatus } from '@/lib/duinpad/actors';
import { showReceipt } from '@/lib/duinpad/show';
import { ApiError, apiFailure, apiSuccess, correlationId } from '@/lib/http/api';
import { serverEnv } from '@/lib/config/server-env';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Reads the current local finale slot, without revealing its original actor. */
export async function GET(request: Request) {
  try {
    if (new URL(request.url).search) throw new ApiError(422, 'ACTOR_RECOVERY_INVALID', 'De finalegroep wordt door de lokale regie bepaald.');
    const { access } = await currentActorAccess();
    if (!access.permissions.includes('finale.go')) throw new ApiError(403, 'ACTOR_PERMISSION_DENIED', 'Finalebediening is nodig om deze ontvangst te controleren.');
    const local = await localActorStatus(access);
    if (!local.connected) throw new ApiError(503, 'ACTOR_OFFLINE', 'Geen verbinding met de showcomputer.');
    // Disabled GO still carries the locally selected group during recovery. No
    // group, attempt, payload hash or original actor is accepted from a browser.
    const group = local.controls.find(control => control.action === 'finale.go')?.group_id;
    if (!group || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(group)) throw new ApiError(409, 'ACTOR_RECOVERY_NO_GROUP', 'De lokale regie heeft nog geen geldige finalegroep geselecteerd.');
    const receipt = await showReceipt(access.actorId, serverEnv().EVENT_SLUG, undefined, true, 'qr2', group);
    // The database rechecks current finale.go rights for this shared group read.
    // Return only the physical slot's public result, never its actor/payload.
    return apiSuccess(receipt ? { attemptId: receipt.attemptId, status: receipt.status, message: receipt.message, ...(receipt.duplicate === undefined ? {} : { duplicate: receipt.duplicate }) } : null);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
