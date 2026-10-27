import { beforeEach, describe, expect, it, vi } from 'vitest';
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';

const mock = vi.hoisted(() => ({ userId: 'account-a', rpc: vi.fn() }));
vi.mock('@/lib/supabase/client', () => ({ createClient: () => ({
  auth: { getUser: async () => ({ data: { user: { id: mock.userId } } }), onAuthStateChange: vi.fn() },
  schema: () => ({ rpc: mock.rpc }),
}) }));
const scope = { accountId: 'account-a', eventId: 'event-a', groupId: 'group-a' };
const args = { _run_id: 'run-a', _expected_stop_id: 'stop-a', _expected_run_version: 2, _credential: 'private-qr-material', _participant_choices: { child: 'skipped' } };
const meta = { portalName: 'Eigen poort', childIds: ['child-a'], finale: false };
const connect = (online: boolean) => vi.stubGlobal('navigator', { onLine: online });
async function rawOutbox() {
  return new Promise<unknown[]>((resolve, reject) => { const request = indexedDB.open('duindorp-private-arrivals-v1', 1); request.onsuccess = () => { const db = request.result, tx = db.transaction('outbox', 'readonly'), read = tx.objectStore('outbox').getAll(); tx.oncomplete = () => { db.close(); resolve(read.result); }; }; request.onerror = () => reject(request.error); });
}

beforeEach(() => {
  vi.resetModules(); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange);
  vi.stubGlobal('window', { addEventListener: vi.fn(), confirm: () => true }); connect(true);
  mock.userId = 'account-a'; mock.rpc.mockReset().mockResolvedValue({ data: { accepted: true }, error: null });
});

describe('durable, scoped arrival intents', () => {
  it('persists encrypted intent offline without a confirmed seal or route advance', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope); connect(false);
    const receipt = await queue.submitArrival('run_arrive_and_advance', args, meta);
    expect(receipt.status).toBe('pending'); expect(mock.rpc).not.toHaveBeenCalled();
    const records = await rawOutbox(); expect(records).toHaveLength(1);
    expect(JSON.stringify(records)).not.toContain(args._credential);
    expect(JSON.stringify(records)).not.toContain(meta.portalName);
  });
  it('restores an interrupted phone session and retries exactly the saved command key', async () => {
    const first = await import('./arrival-sync'); await first.configureArrivalSync(scope); connect(false);
    const receipt = await first.submitArrival('run_arrive_and_advance', args, meta);
    vi.resetModules(); connect(true);
    const restored = await import('./arrival-sync'); await restored.configureArrivalSync(scope); await restored.flushArrivalQueue();
    expect(restored.getLatestArrival()?.status).toBe('confirmed'); expect(mock.rpc).toHaveBeenCalledTimes(1);
    expect(mock.rpc.mock.calls[0][1]._idempotency_key).toBe(receipt.id);
    expect(restored.getLatestArrival()?.args).not.toHaveProperty('_credential');
  });
  it('reconciles a missing response after commit using the same idempotency key', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope);
    mock.rpc.mockResolvedValueOnce({ data: null, error: { message: 'Failed to fetch' } });
    const receipt = await queue.submitArrival('run_arrive_and_advance', args, meta);
    expect(receipt.status).toBe('pending'); await queue.retryArrival(receipt.id);
    expect(queue.getLatestArrival()?.status).toBe('confirmed');
    expect(mock.rpc.mock.calls[0][1]).toEqual(mock.rpc.mock.calls[1][1]);
  });
  it('shows a stale route as requiring review and never reports it confirmed', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope);
    mock.rpc.mockResolvedValue({ data: null, error: { message: 'STALE_VERSION' } });
    const receipt = await queue.submitArrival('run_arrive_and_advance', args, meta);
    expect(receipt.status).toBe('attention'); expect(queue.hasWaitingArrival()).toBe(false);
    await queue.flushArrivalQueue(); expect(mock.rpc).toHaveBeenCalledTimes(1);
  });
  it('does not lose an intent submitted while the previous flush was empty', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope);
    const empty = queue.flushArrivalQueue();
    const pending = queue.submitArrival('run_arrive_and_advance', args, meta);
    await empty; expect((await pending).status).toBe('confirmed'); expect(mock.rpc).toHaveBeenCalledTimes(1);
  });
  it('never exposes or plays another account’s saved intent', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope); connect(false);
    await queue.submitArrival('run_arrive_and_advance', args, meta); queue.clearArrivalMemory();
    mock.userId = 'account-b'; connect(true); await queue.configureArrivalSync({ ...scope, accountId: 'account-b' });
    await queue.flushArrivalQueue(); expect(queue.getLatestArrival()).toBeNull(); expect(mock.rpc).not.toHaveBeenCalled();
    mock.userId = 'account-a'; await queue.configureArrivalSync(scope); await queue.flushArrivalQueue();
    expect(queue.getLatestArrival()?.status).toBe('confirmed');
  });
  it('does not claim local success when storage is unavailable', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope);
    vi.spyOn(indexedDB, 'open').mockImplementation(() => { throw new Error('QuotaExceededError'); });
    await expect(queue.submitArrival('run_arrive_and_advance', args, meta)).rejects.toThrow();
    expect(queue.getLatestArrival()).toBeNull(); expect(mock.rpc).not.toHaveBeenCalled();
  });
  it('manual scan confirmation uses its own receipt contract without awarding a seal', async () => {
    const queue = await import('./arrival-sync'); await queue.configureArrivalSync(scope);
    const receipt = await queue.submitArrival('run_scan', args, meta);
    expect(mock.rpc.mock.calls[0][0]).toBe('run_confirm_arrival'); expect(receipt.action).toBe('run_scan');
  });
});
