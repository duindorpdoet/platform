import 'server-only';
import { createHash, createHmac } from 'node:crypto';
import { z } from 'zod';
import { ACTOR_PERMISSIONS, type ActorPermission } from './actor-model';

export const permissionSchema = z.enum(ACTOR_PERMISSIONS);
const internalZones: Record<ActorPermission, number[]> = {
  'heks.ready': [1], 'heks.go': [1], 'zone1.trigger': [2], 'zone2.trigger': [3], 'zone3.trigger': [4],
  'finale.ready': [5], 'finale.go': [5], 'zone1.stop': [2], 'zone2.stop': [3], 'zone3.stop': [4], 'stop-all': [],
};
export const actorCommandInput = z.object({ commandId: z.uuid(), action: permissionSchema, ready: z.boolean().optional() }).strict().superRefine((value, context) => {
  if (value.action.endsWith('.ready') !== (typeof value.ready === 'boolean')) context.addIssue({ code: 'custom', path: ['ready'], message: 'Alleen gereed vraagt een expliciete ja/nee-keuze.' });
});
export type ActorAccess = { id: string; eventId: string; actorId: string; name: string; revision: number; active: boolean; permissions: ActorPermission[]; receipts?: import('./actor-model').ActorReceipt[] };
export function signedEnvelope(payloadText: string, secret: string) {
  if (Buffer.byteLength(secret) < 32) throw new Error('ACTOR_AUTH_NOT_CONFIGURED');
  const payload = Buffer.from(payloadText, 'utf8').toString('base64url');
  return { version: 'duinpad.actor-envelope.v1', payload, signature: createHmac('sha256', secret).update(payload, 'ascii').digest('base64url') };
}
export function accessGrant(access: ActorAccess, secret: string, now = Math.floor(Date.now() / 1000)) {
  return signedEnvelope(JSON.stringify({ version: 'duinpad.actor-access.v1', event_scope_id: access.eventId, actor_subject: access.actorId,
    permissions_revision: access.revision, permissions: access.permissions, active: access.active, issued_at: now, expires_at: now + 5 }), secret);
}
export function commandPayload(access: ActorAccess, input: z.infer<typeof actorCommandInput>, groupId: string | null, now = Math.floor(Date.now() / 1000)) {
  if (!access.active || !access.permissions.includes(input.action)) throw new Error('ACTOR_PERMISSION_DENIED');
  if (['heks.go', 'finale.go'].includes(input.action) && !/^[A-Za-z0-9_-]{1,40}$/.test(groupId ?? '')) throw new Error('ACTOR_GROUP_REQUIRED');
  if (!['heks.go', 'finale.go'].includes(input.action) && groupId !== null) throw new Error('ACTOR_GROUP_NOT_ALLOWED');
  return { version: 'duinpad.actor.v1', command_id: input.commandId, event_scope_id: access.eventId, actor_subject: access.actorId,
    permissions_revision: access.revision, action: input.action, group_id: groupId, args: input.action.endsWith('.ready') ? { ready: input.ready } : {},
    issued_at: now, expires_at: now + 8, scope: { permission: input.action, internal_zones: internalZones[input.action] } };
}
export function payloadHash(text: string) { return createHash('sha256').update(text, 'utf8').digest('hex'); }
export const actorStatusSchema = z.object({
  version: z.literal('duinpad.actor-status.v1'), compatible: z.literal(true), connected: z.boolean(), observed_at: z.number(), permissions_revision: z.number().int().positive(),
  controls: z.array(z.object({ action: permissionSchema, enabled: z.boolean(), blocked_reason: z.string().max(200).nullable(), group_id: z.string().regex(/^[A-Za-z0-9_-]{1,40}$/).nullable(),
    effect: z.object({ active: z.boolean(), remaining: z.number().min(0).max(86400) }).strict().nullable() }).strict()).max(ACTOR_PERMISSIONS.length),
}).strict();

// The random invitation UUID is a nonce. A separate 256-bit server secret makes
// the claim token unpredictable, while only its hash is stored in the database.
// The existing durable mail worker can regenerate it without persisting plaintext.
export function invitationToken(invitationId: string, eventId: string, email: string, secret: string) {
  if (Buffer.byteLength(secret) < 32) throw new Error('ACTOR_INVITE_NOT_CONFIGURED');
  return createHmac('sha256', secret).update(JSON.stringify(['duinpad.actor-invite.v1', invitationId, eventId, email.trim().toLowerCase()])).digest('base64url');
}

export function interpretActorAck(httpStatus: number, body: unknown, commandId: string, action: ActorPermission) {
  const b = body && typeof body === 'object' ? body as Record<string, unknown> : {};
  const confirmation = b.confirmation && typeof b.confirmation === 'object' ? b.confirmation as Record<string, unknown> : {};
  const expectedMeaning = action === 'finale.go' ? 'finale_started' : action.endsWith('.ready') ? 'ready_updated' : action.endsWith('.stop') ? 'zone_stopped' : action === 'stop-all' ? 'all_stopped' : 'scene_started';
  const matching = b.command_id === commandId;
  const confirmed = matching && b.outcome === 'started' && b.meaning === expectedMeaning && (action !== 'finale.go' || confirmation.qlc_started === true && confirmation.audio_started === true);
  const status = httpStatus === 503 ? 'not_dispatched' : httpStatus === 504 || b.unknown === true ? 'unknown'
    : httpStatus >= 200 && httpStatus < 300 && b.ok === true && confirmed ? 'started'
      : matching && b.ok === false && b.outcome === 'blocked' ? 'blocked' : 'unknown';
  const message = status === 'unknown' ? 'Geen startbevestiging ontvangen. Vraag de begeleider om de regie te controleren.'
    : status === 'not_dispatched' ? 'De showcomputer is niet verbonden. Vraag de begeleider.'
      : typeof b.message === 'string' ? b.message.slice(0, 200) : typeof b.error === 'string' && status === 'blocked' ? b.error.slice(0, 200) : status === 'started' ? action.endsWith('.ready') ? 'Gereedstand lokaal bevestigd.' : action.endsWith('.stop') || action === 'stop-all' ? 'Stop lokaal bevestigd.' : 'Gestart na lokale bevestiging.' : 'De lokale showvoorwaarden staan deze opdracht nog niet toe.';
  return { status, result: { ok: status === 'started', message, unknown: status === 'unknown', duplicate: b.duplicate === true } } as const;
}
