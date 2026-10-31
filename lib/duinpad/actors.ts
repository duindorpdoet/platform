import 'server-only';
import { accountClient } from '@/lib/account/server';
import { serverEnv } from '@/lib/config/server-env';
import { ApiError } from '@/lib/http/api';
import { createPrivilegedClient } from '@/lib/supabase/privileged';
import { accessGrant, actorStatusSchema, type ActorAccess } from './actor-protocol';
import type { ActorSnapshot } from './actor-model';

export function actorRpcError(error: { code?: string; message?: string } | null) {
  if (!error) return;
  if (error.message?.includes('INVITATION_WRONG_ACCOUNT')) throw new ApiError(403, 'INVITATION_WRONG_ACCOUNT', 'Log in met precies het e-mailadres waarop de organisatie je heeft uitgenodigd. Je huidige account is niet geactiveerd.');
  if (error.message?.includes('INVITATION_')) throw new ApiError(409, 'INVITATION_UNAVAILABLE', 'Deze uitnodiging is verlopen, ingetrokken of vervangen. Vraag de organisatie om een nieuwe uitnodiging.');
  if (error.code === '42501') throw new ApiError(403, 'ACTOR_ACCESS_DENIED', 'Je hebt hiervoor geen actuele acteurs- of organisatiebevoegdheid.');
  if (error.message?.includes('RATE_LIMITED')) throw new ApiError(429, 'ACTOR_RATE_LIMITED', 'Wacht even voordat je opnieuw een opdracht geeft.');
  if (error.code === '23505') throw new ApiError(409, 'ACTOR_RECOVERY_REQUIRED', 'Er staat al een onzekere opdracht open. Controleer eerst de ontvangst bij de regie.');
  throw new ApiError(409, 'ACTOR_COMMAND_REJECTED', 'Deze opdracht kon niet worden bevestigd. Vernieuw de gegevens en controleer de actuele status.');
}
export async function currentActorAccess() {
  const { client } = await accountClient();
  const result = await client.schema('api').rpc('duinpad_actor_snapshot', { _event_slug: serverEnv().EVENT_SLUG });
  actorRpcError(result.error);
  if (!result.data) throw new ApiError(403, 'ACTOR_ACCESS_DENIED', 'Er is geen actieve acteurskoppeling.');
  return { client, access: result.data as ActorAccess };
}
function relayConfig(eventId: string) {
  const env = serverEnv();
  if (!env.DUINPAD_SHOW_API_BASE_URL || !env.DUINPAD_SHOW_API_TOKEN || !env.DUINPAD_ACTOR_AUTH_SECRET || env.DUINPAD_EVENT_SCOPE_ID !== eventId) {
    throw new ApiError(503, 'ACTOR_NOT_CONFIGURED', 'De showverbinding is nog niet ingesteld voor dit evenement.');
  }
  const base = new URL(env.DUINPAD_SHOW_API_BASE_URL);
  if (base.protocol !== 'https:' || base.pathname !== '/' || base.search || base.hash || base.username || base.password) throw new ApiError(503, 'ACTOR_NOT_CONFIGURED', 'De showverbinding is nog niet ingesteld.');
  return { base: base.origin, token: env.DUINPAD_SHOW_API_TOKEN, secret: env.DUINPAD_ACTOR_AUTH_SECRET };
}
export async function actorRelayRequest(access: ActorAccess, path: string, init?: RequestInit) {
  const config = relayConfig(access.eventId);
  const grant = Buffer.from(JSON.stringify(accessGrant(access, config.secret)), 'utf8').toString('base64url');
  return fetch(`${config.base}${path}`, { ...init, redirect: 'error', cache: 'no-store', signal: init?.signal ? AbortSignal.any([init.signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}`, 'X-Duinpad-Actor-Grant': grant } });
}
export async function localActorStatus(access: ActorAccess) {
  const response = await actorRelayRequest(access, '/api/integration/actor-status');
  if (!response.ok) throw new ApiError(503, 'ACTOR_OFFLINE', 'Geen verbinding met de showcomputer.');
  const data = actorStatusSchema.parse(await response.json());
  const now = Date.now() / 1000;
  if (data.permissions_revision !== access.revision || data.observed_at < now - 5 || data.observed_at > now + 2 || data.controls.some(c => !access.permissions.includes(c.action)) || new Set(data.controls.map(c => c.action)).size !== data.controls.length) {
    throw new ApiError(503, 'ACTOR_STATUS_STALE', 'De lokale status moet eerst opnieuw worden bevestigd.');
  }
  return data;
}
export async function actorSnapshot(): Promise<ActorSnapshot> {
  const { access } = await currentActorAccess();
  try {
    const local = await localActorStatus(access);
    return { name: access.name, revision: access.revision, permissions: access.permissions, connected: local.connected, compatible: local.compatible,
      observedAt: local.observed_at, controls: local.controls, receipts: access.receipts ?? [] };
  } catch {
    return { name: access.name, revision: access.revision, permissions: access.permissions, connected: false, compatible: false, observedAt: 0,
      controls: access.permissions.map(action => ({ action, enabled: false, blocked_reason: 'Geen verbinding met de showcomputer', group_id: null, effect: null })), receipts: access.receipts ?? [] };
  }
}
export async function finishActorCommand(commandId: string, status: string, result: Record<string, unknown>) {
  const service = createPrivilegedClient();
  if (!service) throw new ApiError(503, 'ACTOR_RECEIPT_UNAVAILABLE', 'De ontvangstbevestiging is nog niet opgeslagen. Controleer de regie.');
  const stored = await service.schema('api').rpc('duinpad_actor_finish', { _command_id: commandId, _status: status, _result: result });
  actorRpcError(stored.error);
}
export async function pushActorAccess(access: ActorAccess) {
  // This sends only revocation/revision state; it never requests show execution.
  const config = relayConfig(access.eventId);
  const response = await actorRelayRequest(access, '/api/integration/actor-access', { method: 'POST', body: JSON.stringify(accessGrant(access, config.secret)) });
  if (!response.ok) throw new ApiError(503, 'ACTOR_REVOCATION_PENDING', 'De rechten zijn opgeslagen. De showcomputer moet de gewijzigde rechten nog bevestigen.');
}
