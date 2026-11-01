import { createHmac } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
vi.mock('server-only', () => ({}));
import { accessGrant, actorCommandInput, actorStatusSchema, commandPayload, interpretActorAck, invitationToken, payloadHash, signedEnvelope, type ActorAccess } from './actor-protocol';
const access: ActorAccess = { id: 'a', eventId: '485afb2c-730d-47e7-b032-9b89951bf6a1', actorId: '27000000-0000-4000-8000-000000000001', name: 'Testacteur', revision: 4, active: true, permissions: ['heks.ready', 'heks.go', 'finale.go', 'zone1.trigger', 'zone1.stop', 'stop-all'] };
const commandId = '27000000-0000-4000-8000-000000000002';
const secret = 'synthetic-actor-secret-32-bytes-only-local';
describe('actor v1 authority boundary', () => {
  it('signs the exact ASCII payload and binds every execution field', () => {
    const payload = commandPayload(access, { commandId, action: 'finale.go' }, 'route_uuid', 12345);
    const text = JSON.stringify(payload);
    const envelope = signedEnvelope(text, secret);
    expect(envelope).toEqual({ version: 'duinpad.actor-envelope.v1', payload: Buffer.from(text).toString('base64url'), signature: createHmac('sha256', secret).update(Buffer.from(text).toString('base64url'), 'ascii').digest('base64url') });
    expect(JSON.parse(Buffer.from(envelope.payload, 'base64url').toString())).toEqual({ version: 'duinpad.actor.v1', command_id: commandId, event_scope_id: access.eventId, actor_subject: access.actorId, permissions_revision: 4, action: 'finale.go', group_id: 'route_uuid', args: {}, issued_at: 12345, expires_at: 12353, scope: { permission: 'finale.go', internal_zones: [5] } });
    expect(signedEnvelope(JSON.stringify({ ...payload, group_id: 'other' }), secret).signature).not.toBe(envelope.signature);
  });
  it('matches the Python bridge cross-language signed fixture', () => {
    const fixture = { version: 'duinpad.actor.v1', command_id: '00000000-0000-4000-8000-000000000001', event_scope_id: 'event-fixture', actor_subject: 'actor-fixture', permissions_revision: 1, action: 'zone1.trigger', group_id: null, args: {}, issued_at: 1000, expires_at: 1008, scope: { permission: 'zone1.trigger', internal_zones: [2] } };
    expect(signedEnvelope(JSON.stringify(fixture), 'fixture-only-secret-32-characters-minimum').signature).toBe('V3iWM0Sx4TZGK1cT-Em4GTByX5bITPnr5LblHwyi9l8');
  });
  it('maps public pad 1 to internal 2 and permits global stop only explicitly', () => {
    expect(commandPayload(access, { commandId, action: 'zone1.stop' }, null).scope).toEqual({ permission: 'zone1.stop', internal_zones: [2] });
    expect(commandPayload(access, { commandId, action: 'stop-all' }, null).scope.internal_zones).toEqual([]);
    expect(() => commandPayload({ ...access, permissions: ['zone1.trigger'] }, { commandId, action: 'stop-all' }, null)).toThrow();
    expect(() => commandPayload(access, { commandId, action: 'finale.go' }, null)).toThrow();
    expect(() => commandPayload(access, { commandId, action: 'zone1.trigger' }, 'group')).toThrow();
  });
  it('rejects browser-chosen scope, groups and implicit ready values', () => {
    expect(actorCommandInput.safeParse({ commandId, action: 'heks.ready' }).success).toBe(false);
    expect(actorCommandInput.safeParse({ commandId, action: 'heks.ready', ready: false }).success).toBe(true);
    expect(actorCommandInput.safeParse({ commandId, action: 'heks.go', groupId: 'other' }).success).toBe(false);
    expect(actorCommandInput.safeParse({ commandId, action: 'heks.go', ready: true }).success).toBe(false);
    expect(actorCommandInput.safeParse({ commandId, action: 'zone5.stop' }).success).toBe(false);
  });
  it('uses a separate short lived access grant for revocation and event binding', () => {
    const grant = accessGrant({ ...access, active: false, permissions: [], revision: 5 }, secret, 100);
    const payload = JSON.parse(Buffer.from(grant.payload, 'base64url').toString());
    expect(payload).toMatchObject({ version: 'duinpad.actor-access.v1', permissions_revision: 5, active: false, issued_at: 100, expires_at: 105, permissions: [], event_scope_id: access.eventId });
  });
  it('accepts finalestart only with matching ID and both physical software start confirmations', () => {
    const ack = { ok: true, outcome: 'started', command_id: commandId, meaning: 'finale_started', confirmation: { qlc_started: true, audio_started: true } };
    expect(interpretActorAck(200, ack, commandId, 'finale.go').status).toBe('started');
    expect(interpretActorAck(200, { ...ack, confirmation: { qlc_started: true } }, commandId, 'finale.go').status).toBe('unknown');
    expect(interpretActorAck(200, { ...ack, command_id: 'other' }, commandId, 'finale.go').status).toBe('unknown');
    expect(interpretActorAck(200, { ok: true }, commandId, 'finale.go').status).toBe('unknown');
    expect(interpretActorAck(504, ack, commandId, 'finale.go').status).toBe('unknown');
    expect(interpretActorAck(503, null, commandId, 'finale.go').status).toBe('not_dispatched');
    expect(interpretActorAck(200, { ok: false, outcome: 'blocked', command_id: commandId, message: 'Wacht op finalestart' }, commandId, 'heks.go')).toMatchObject({ status: 'blocked', result: { ok: false, message: 'Wacht op finalestart' } });
  });
  it('does not accept a wrong ACK meaning or HTTP acceptance as zone/ready start proof', () => {
    expect(interpretActorAck(200, { ok: true, outcome: 'started', command_id: commandId, meaning: 'ready_updated' }, commandId, 'zone1.trigger').status).toBe('unknown');
    expect(interpretActorAck(200, { ok: true, outcome: 'started', command_id: commandId, meaning: 'ready_updated' }, commandId, 'heks.ready').status).toBe('started');
  });
  it('does not permit complete local regie state through the field whitelist', () => {
    const data = { version: 'duinpad.actor-status.v1', compatible: true, connected: true, observed_at: 123, permissions_revision: 1, controls: [] };
    expect(actorStatusSchema.safeParse(data).success).toBe(true);
    expect(actorStatusSchema.safeParse({ ...data, next_finale: 'hidden-group' }).success).toBe(false);
    expect(actorStatusSchema.safeParse({ ...data, controls: [{ action: 'zone1.trigger', enabled: true, blocked_reason: null, group_id: null, effect: null, dmx: [1, 2] }] }).success).toBe(false);
  });
  it('regenerates claim material only with the independent secret and binds email/event/nonce', () => {
    const token = invitationToken(commandId, access.eventId, ' Actor@Example.Invalid ', secret);
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(invitationToken(commandId, access.eventId, 'actor@example.invalid', secret)).toBe(token);
    expect(invitationToken(commandId, 'other-event', 'actor@example.invalid', secret)).not.toBe(token);
    expect(invitationToken('other-nonce', access.eventId, 'actor@example.invalid', secret)).not.toBe(token);
    expect(payloadHash(token)).toMatch(/^[a-f0-9]{64}$/);
    expect(() => invitationToken(commandId, access.eventId, 'actor@example.invalid', 'weak')).toThrow();
  });
});
