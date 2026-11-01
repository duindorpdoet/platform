import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('server-only', () => ({}));
const state = vi.hoisted(() => ({ current: vi.fn(), local: vi.fn(), receipt: vi.fn() }));
vi.mock('@/lib/duinpad/actors', () => ({ currentActorAccess: state.current, localActorStatus: state.local }));
vi.mock('@/lib/duinpad/show', () => ({ showReceipt: state.receipt }));
vi.mock('@/lib/config/server-env', () => ({ serverEnv: () => ({ EVENT_SLUG: 'synthetic-event' }) }));
import { GET } from './route';
import { ApiError } from '@/lib/http/api';
const group = '8a0c0275-7635-43bf-9fce-480e0e873b4d';
const access = { actorId: 'current-finale-actor-B', permissions: ['finale.go'], revision: 8 };
const request = (query = '') => new Request(`https://app.example.invalid/api/actors/finale-recovery${query}`);
beforeEach(() => {
  vi.clearAllMocks();
  state.current.mockResolvedValue({ access });
  state.local.mockResolvedValue({ connected: true, controls: [{ action: 'finale.go', enabled: false, blocked_reason: 'Herstelcontrole nodig', group_id: group }] });
  state.receipt.mockResolvedValue({ attemptId: 'original-A-attempt', status: 'blocked', message: 'De regie heeft niet-uitvoering bevestigd.' });
});
describe('current finale actor shared receipt recovery', () => {
  it('derives the local group even while GO is disabled and reads only the shared QR2 slot', async () => {
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(state.receipt).toHaveBeenCalledWith(access.actorId, 'synthetic-event', undefined, true, 'qr2', group);
    expect((await response.json()).data).toEqual({ attemptId: 'original-A-attempt', status: 'blocked', message: 'De regie heeft niet-uitvoering bevestigd.' });
    expect(response.headers.get('cache-control')).toBe('private, no-store');
  });
  it('does not require the original revoked actor or reveal their private command receipt', async () => {
    state.receipt.mockResolvedValue({ attemptId: 'original-A-attempt', status: 'unknown', message: 'Geen startbevestiging.', actorId: 'revoked-A', payload: 'private-original-payload', payloadHash: 'private-hash', permissions: ['stop-all'] });
    const body = await (await GET(request())).json();
    expect(body.data).toEqual({ attemptId: 'original-A-attempt', status: 'unknown', message: 'Geen startbevestiging.' });
    expect(JSON.stringify(body)).not.toContain('revoked-A'); expect(JSON.stringify(body)).not.toContain('private-');
  });
  it('rejects browser-selected groups, attempts and hashes', async () => {
    expect((await GET(request('?group_id=other&attempt=other&payload_hash=other'))).status).toBe(422);
    expect(state.current).not.toHaveBeenCalled(); expect(state.receipt).not.toHaveBeenCalled();
  });
  it('requires current finale.go, regardless of login or other actor permissions', async () => {
    state.current.mockResolvedValue({ access: { ...access, permissions: ['heks.go'] } });
    expect((await GET(request())).status).toBe(403); expect(state.local).not.toHaveBeenCalled(); expect(state.receipt).not.toHaveBeenCalled();
  });
  it('does not restore access to a revoked original actor', async () => {
    state.current.mockRejectedValue(new ApiError(403, 'ACTOR_ACCESS_DENIED', 'Toegang ingetrokken.'));
    expect((await GET(request())).status).toBe(403); expect(state.receipt).not.toHaveBeenCalled();
  });
  it('denies stale/offline local selection without a shared receipt lookup', async () => {
    state.local.mockRejectedValue(new ApiError(503, 'ACTOR_STATUS_STALE', 'Status verlopen.'));
    expect((await GET(request())).status).toBe(503); expect(state.receipt).not.toHaveBeenCalled();
    state.local.mockResolvedValue({ connected: false, controls: [{ action: 'finale.go', group_id: group }] });
    expect((await GET(request())).status).toBe(503); expect(state.receipt).not.toHaveBeenCalled();
  });
  it('requires a valid server-selected app run and never accepts arbitrary relay labels', async () => {
    state.local.mockResolvedValue({ connected: true, controls: [{ action: 'finale.go', group_id: 'G-12' }] });
    expect((await GET(request())).status).toBe(409); expect(state.receipt).not.toHaveBeenCalled();
  });
  it('keeps an absent shared receipt distinct from a confirmed start or retry permission', async () => {
    state.receipt.mockResolvedValue(null);
    expect((await (await GET(request())).json()).data).toBeNull();
    expect(state.receipt).toHaveBeenCalledOnce();
  });
});
