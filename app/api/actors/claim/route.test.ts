import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('server-only', () => ({}));
const state = vi.hoisted(() => ({ jar: { get: vi.fn(), set: vi.fn() }, client: vi.fn(), rpc: vi.fn() }));
vi.mock('next/headers', () => ({ cookies: async () => state.jar }));
vi.mock('@/lib/account/server', () => ({ accountClient: state.client }));
vi.mock('@/lib/config/server-env', () => ({ serverEnv: () => ({ APP_URL: 'https://app.example.invalid', EVENT_SLUG: 'synthetic-event' }), allowedOrigins: () => new Set(['https://app.example.invalid']) }));
import { POST } from './route';
import { payloadHash } from '@/lib/duinpad/actor-protocol';
const token = 't'.repeat(43);
const request = (body: object) => new Request('https://app.example.invalid/api/actors/claim', { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://app.example.invalid' }, body: JSON.stringify(body) });
beforeEach(() => { vi.clearAllMocks(); state.jar.get.mockReturnValue(undefined); state.rpc.mockResolvedValue({ data: { active: true, duplicate: false }, error: null }); state.client.mockResolvedValue({ client: { schema: () => ({ rpc: state.rpc }) } }); });
describe('explicit actor invitation claim', () => {
  it('opening the fragment only prepares an HttpOnly hash and never activates', async () => {
    const response = await POST(request({ action: 'prepare', token })); expect(response.status).toBe(200);
    expect(state.client).not.toHaveBeenCalled(); expect(state.rpc).not.toHaveBeenCalled();
    expect(state.jar.set).toHaveBeenCalledWith('duinpad_actor_claim', payloadHash(token), expect.objectContaining({ httpOnly: true, secure: true, sameSite: 'lax', maxAge: 3600 }));
    expect(JSON.stringify(state.jar.set.mock.calls)).not.toContain(token);
  });
  it('requires the invitation cookie and explicit claim action', async () => {
    expect((await POST(request({ action: 'claim' }))).status).toBe(409); expect(state.client).not.toHaveBeenCalled();
    expect((await POST(request({ token }))).status).toBe(422); expect(state.rpc).not.toHaveBeenCalled();
  });
  it('lets the authorized database match the verified account and consumes cookie only on success', async () => {
    state.jar.get.mockReturnValue({ value: payloadHash(token) });
    const response = await POST(request({ action: 'claim' })); expect((await response.json()).data.active).toBe(true);
    expect(state.rpc).toHaveBeenCalledWith('duinpad_actor_claim', { _event_slug: 'synthetic-event', _token_hash: payloadHash(token) });
    expect(state.jar.set).toHaveBeenCalledWith('duinpad_actor_claim', '', expect.objectContaining({ maxAge: 0, httpOnly: true }));
  });
  it('keeps invitation available after wrong Google account so the user can switch identities', async () => {
    state.jar.get.mockReturnValue({ value: payloadHash(token) }); state.rpc.mockResolvedValue({ data: null, error: { code: '42501', message: 'INVITATION_WRONG_ACCOUNT' } });
    const response = await POST(request({ action: 'claim' })); expect(response.status).toBe(403); expect((await response.json()).error.code).toBe('INVITATION_WRONG_ACCOUNT'); expect(state.jar.set).not.toHaveBeenCalled();
  });
  it('handles revoked/expired/replaced link without activation', async () => {
    state.jar.get.mockReturnValue({ value: payloadHash(token) }); state.rpc.mockResolvedValue({ data: null, error: { code: '22023', message: 'INVITATION_UNAVAILABLE' } });
    const response = await POST(request({ action: 'claim' })); expect(response.status).toBe(409); expect(state.jar.set).not.toHaveBeenCalled();
  });
  it('preserves database duplicate success after a lost claim response', async () => {
    state.jar.get.mockReturnValue({ value: payloadHash(token) }); state.rpc.mockResolvedValue({ data: { active: true, duplicate: true }, error: null });
    expect((await (await POST(request({ action: 'claim' }))).json()).data).toEqual({ active: true, duplicate: true });
  });
});
