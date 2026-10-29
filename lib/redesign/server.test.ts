import { beforeEach, expect, it, vi } from 'vitest';
import { createHash } from 'node:crypto';
vi.mock('server-only', () => ({}));
const state = vi.hoisted(() => ({ rpc: vi.fn(), getUser: vi.fn() }));
vi.mock('@/lib/supabase/server', () => ({ createClient: async () => ({ auth: { getUser: state.getUser } }) }));
vi.mock('@/lib/supabase/privileged', () => ({ createPrivilegedClient: () => ({ schema: () => ({ rpc: state.rpc }) }) }));
vi.mock('@/lib/config/server-env', () => ({ serverEnv: () => ({ CHILD_CODE_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'), APP_URL: 'https://fixture.invalid' }), allowedOrigins: () => new Set(['https://fixture.invalid']) }));
import { portalPrint } from './server';
const portal = '12000000-0000-0000-0000-000000000001';
beforeEach(() => {
  state.rpc.mockReset();
  state.getUser.mockReset().mockResolvedValue({ data: { user: { id: 'owner-fixture' } }, error: null });
});
it('provisions encrypted material once and recovers the same QR and short code on later views', async () => {
  let stored = '';
  state.rpc.mockImplementation(async (_name, args) => {
    stored ||= args._ciphertext;
    return { data: { ciphertext: stored, credentialId: 'private-id', credentialRevision: 2, portalVersion: 4, canRotate: true, legacy: false }, error: null };
  });
  const first = await portalPrint(portal), next = await portalPrint(portal);
  expect(next).toEqual(first);
  expect(first.credential).toMatch(/^[a-f0-9]{64}$/);
  expect(first.shortCode).toMatch(/^[A-F0-9]{12}$/);
  expect(first).not.toHaveProperty('ciphertext');
  expect(first).not.toHaveProperty('credentialId');
  const args = state.rpc.mock.calls[0][1];
  expect(args._action).toBe('ensure');
  expect(args._ciphertext).not.toContain(first.credential);
  expect(args._ciphertext).not.toContain(first.shortCode);
  expect(args._token_hash).toHaveLength(66);
  expect([...args._token_hash.slice(0, 2)].map(char => char.charCodeAt(0))).toEqual([92, 120]);
  expect(args._token_hash).toBe('\\x' + createHash('sha256').update(first.credential).digest('hex'));
  expect(args._short_hash).toBe('\\x' + createHash('sha256').update(first.shortCode).digest('hex'));
});
it('keeps rotation explicit and passes its expected portal version', async () => {
  state.rpc.mockImplementation(async (_name, args) => ({ data: { ciphertext: args._ciphertext, credentialRevision: 3, portalVersion: 5, canRotate: true, legacy: false }, error: null }));
  await portalPrint(portal, 4);
  expect(state.rpc.mock.calls[0][1]).toMatchObject({ _action: 'rotate', _expected_version: 4 });
});
it('does not generate a replacement if stored material cannot be decrypted', async () => {
  state.rpc.mockResolvedValue({ data: { ciphertext: 'invalid-encrypted-envelope', credentialRevision: 2 }, error: null });
  await expect(portalPrint(portal)).rejects.toMatchObject({ status: 503, code: 'PRINT_UNAVAILABLE' });
  expect(state.rpc).toHaveBeenCalledTimes(1);
});
it('denies unauthenticated reads before any privileged RPC', async () => {
  state.getUser.mockResolvedValue({ data: { user: null }, error: { name: 'AuthSessionMissingError', status: 401 } });
  await expect(portalPrint(portal)).rejects.toMatchObject({ status: 401, code: 'NOT_AUTHORIZED' });
  expect(state.rpc).not.toHaveBeenCalled();
});
it('returns no material after the server rejects ownership or a stale rotation', async () => {
  state.rpc.mockResolvedValue({ data: null, error: { message: 'NOT_AUTHORIZED' } });
  await expect(portalPrint(portal)).rejects.toMatchObject({ status: 403, code: 'PRINT_UNAVAILABLE' });
  state.rpc.mockResolvedValue({ data: null, error: { message: 'STALE_VERSION' } });
  await expect(portalPrint(portal, 4)).rejects.toMatchObject({ status: 409, code: 'PRINT_UNAVAILABLE' });
});

it('reports temporary database or transport failures as retryable without pretending authorization was lost', async () => {
  state.rpc.mockResolvedValue({ data: null, error: { code: 'PGRST000', message: 'Connection timeout' } });
  await expect(portalPrint(portal)).rejects.toMatchObject({ status: 503, code: 'PRINT_UNAVAILABLE' });
});
