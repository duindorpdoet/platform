import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('server-only', () => ({}));
const state = vi.hoisted(() => ({ access: vi.fn(), status: vi.fn(), relay: vi.fn(), rpc: vi.fn(), finish: vi.fn(), slot: vi.fn(), slotFinish: vi.fn() }));
vi.mock('@/lib/config/server-env', () => ({ serverEnv: () => ({ EVENT_SLUG: 'synthetic-event', DUINPAD_ACTOR_AUTH_SECRET: 'synthetic-actor-secret-32-bytes-local-only' }), allowedOrigins: () => new Set(['https://app.example.invalid']) }));
vi.mock('@/lib/duinpad/actors', async original => ({ ...await original<typeof import('@/lib/duinpad/actors')>(), currentActorAccess: state.access, localActorStatus: state.status, actorRelayRequest: state.relay, finishActorCommand: state.finish }));
vi.mock('@/lib/duinpad/show', () => ({ reserveActorFinale: state.slot, finishActorFinale: state.slotFinish }));
import { POST } from './route';
const id = '00000000-0000-4000-8000-000000000001';
const actor = { id: 'access', eventId: '485afb2c-730d-47e7-b032-9b89951bf6a1', actorId: '00000000-0000-4000-8000-000000000002', active: true, name: 'Synthetic', revision: 3, permissions: ['heks.go', 'finale.go', 'zone1.trigger'] };
function request(body: object, origin = true) { return new Request('https://app.example.invalid/api/actors/command', { method: 'POST', headers: { 'Content-Type': 'application/json', ...(origin ? { Origin: 'https://app.example.invalid' } : {}) }, body: JSON.stringify(body) }); }
const input = { commandId: id, action: 'heks.go' };
beforeEach(() => {
  vi.clearAllMocks();
  state.access.mockResolvedValue({ client: { schema: () => ({ rpc: state.rpc }) }, access: actor });
  state.status.mockResolvedValue({ connected: true, controls: actor.permissions.map(action => ({ action, enabled: true, blocked_reason: null, group_id: action.endsWith('.go') ? 'server-selected-run' : null, effect: null })) });
  state.rpc.mockResolvedValue({ data: { dispatch: true }, error: null });
  state.relay.mockResolvedValue(Response.json({ ok: true, command_id: id, outcome: 'started', meaning: 'scene_started' }));
  state.slot.mockResolvedValue({ dispatch: true, attemptId: id, status: 'requested' });
  state.finish.mockResolvedValue(undefined); state.slotFinish.mockResolvedValue(undefined);
});
describe('authenticated actor command route', () => {
  it('enforces trusted origin before auth or dispatch', async () => { expect((await POST(request(input, false))).status).toBe(403); expect(state.access).not.toHaveBeenCalled(); expect(state.relay).not.toHaveBeenCalled(); });
  it('does not execute an already aborted browser request', async () => {
    const controller = new AbortController(); controller.abort();
    expect((await POST(new Request(request(input), { signal: controller.signal }))).status).toBe(409);
    expect(state.access).not.toHaveBeenCalled(); expect(state.relay).not.toHaveBeenCalled();
  });
  it('rejects browser-selected groups/scopes/actions', async () => {
    expect((await POST(request({ ...input, groupId: 'other-run' }))).status).toBe(422);
    expect((await POST(request({ ...input, action: 'reset_groups' }))).status).toBe(422);
    expect(state.relay).not.toHaveBeenCalled();
  });
  it('checks current explicit permissions independently of authentication', async () => {
    state.access.mockResolvedValue({ access: { ...actor, permissions: [] } });
    expect((await POST(request(input))).status).toBe(403); expect(state.rpc).not.toHaveBeenCalled(); expect(state.relay).not.toHaveBeenCalled();
  });
  it('honors local conditions before reserving and shows exact blocked reason', async () => {
    state.status.mockResolvedValue({ connected: true, controls: [{ action: 'heks.go', enabled: false, blocked_reason: 'Wacht op finalestart', group_id: 'server-selected-run', effect: null }] });
    const response = await POST(request(input)); expect(response.status).toBe(409); expect((await response.json()).error.message).toBe('Wacht op finalestart'); expect(state.rpc).not.toHaveBeenCalled(); expect(state.relay).not.toHaveBeenCalled();
  });
  it('rechecks permissions immediately before dispatch and sends no revoked command', async () => {
    state.access.mockResolvedValueOnce({ client: { schema: () => ({ rpc: state.rpc }) }, access: actor }).mockResolvedValueOnce({ access: { ...actor, revision: 4, permissions: [] } });
    const response = await POST(request(input)); expect((await response.json()).data.status).toBe('not_dispatched'); expect(state.relay).not.toHaveBeenCalled(); expect(state.finish).toHaveBeenCalledWith(id, 'not_dispatched', expect.any(Object));
  });
  it('does not dispatch when the browser disconnects during authorization', async () => {
    const controller = new AbortController();
    state.access.mockResolvedValueOnce({ client: { schema: () => ({ rpc: state.rpc }) }, access: actor }).mockImplementationOnce(async () => { controller.abort(); return { access: actor }; });
    expect((await (await POST(new Request(request(input), { signal: controller.signal }))).json()).data.status).toBe('not_dispatched');
    expect(state.relay).not.toHaveBeenCalled();
  });
  it('returns an immutable duplicate receipt without relay dispatch', async () => {
    state.rpc.mockResolvedValue({ data: { dispatch: false, status: 'unknown' }, error: null });
    const response = await POST(request(input)); expect((await response.json()).data).toMatchObject({ status: 'unknown', duplicate: true }); expect(state.relay).not.toHaveBeenCalled();
  });
  it('sends only signed allowlisted fields and binds the trusted local group', async () => {
    const response = await POST(request(input)); expect((await response.json()).data.status).toBe('started');
    const [, path, init] = state.relay.mock.calls[0]; expect(path).toBe('/api/integration/actor-command');
    const envelope = JSON.parse(init.body); const payload = JSON.parse(Buffer.from(envelope.payload, 'base64url').toString());
    expect(payload).toMatchObject({ group_id: 'server-selected-run', actor_subject: actor.actorId, permissions_revision: 3, scope: { permission: 'heks.go', internal_zones: [1] }, args: {} });
    expect(payload.expires_at - payload.issued_at).toBe(8); expect(state.relay).toHaveBeenCalledOnce();
  });
  it('keeps HTTP200/body refusal distinct from start success', async () => {
    state.relay.mockResolvedValue(Response.json({ ok: false, command_id: id, outcome: 'blocked', error: 'Heks nog niet gereed' }));
    expect((await (await POST(request(input))).json()).data).toMatchObject({ status: 'blocked', ok: false, message: 'Heks nog niet gereed' });
  });
  it('never claims success from bare HTTP acceptance', async () => {
    state.relay.mockResolvedValue(Response.json({ ok: true }));
    expect((await (await POST(request(input))).json()).data).toMatchObject({ status: 'unknown', ok: false }); expect(state.relay).toHaveBeenCalledOnce();
  });
  it('retains a lost response as unknown without any automatic retry', async () => {
    state.relay.mockRejectedValue(new Error('synthetic transport timeout'));
    expect((await (await POST(request(input))).json()).data.status).toBe('unknown'); expect(state.relay).toHaveBeenCalledOnce(); expect(state.finish).toHaveBeenCalledWith(id, 'unknown', expect.objectContaining({ unknown: true }));
  });
  it('shares finale slot with visitor QR2 and needs both local ACKs', async () => {
    state.relay.mockResolvedValue(Response.json({ ok: true, command_id: id, outcome: 'started', meaning: 'finale_started', confirmation: { qlc_started: true, audio_started: true } }));
    expect((await (await POST(request({ commandId: id, action: 'finale.go' }))).json()).data.status).toBe('started');
    expect(state.slot).toHaveBeenCalledWith(expect.objectContaining({ eventId: actor.eventId, groupId: 'server-selected-run', actorId: actor.actorId, commandId: id }));
    expect(state.slotFinish).toHaveBeenCalledWith(expect.objectContaining({ attemptId: id, status: 'started' }));
  });
  it('does not dispatch a second physical finale when slot is already held/started', async () => {
    state.slot.mockResolvedValue({ dispatch: false, attemptId: 'previous-attempt', status: 'started' });
    expect((await (await POST(request({ commandId: id, action: 'finale.go' }))).json()).data.status).toBe('not_dispatched'); expect(state.relay).not.toHaveBeenCalled();
  });
});
