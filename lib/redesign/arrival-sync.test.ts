import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';

const mock = vi.hoisted(() => ({ userId: 'account-a' as string|null, rpc: vi.fn() }));
vi.mock('@/lib/supabase/client', () => ({ createClient: () => ({
  auth: { getUser: async () => ({ data: { user: mock.userId ? { id: mock.userId } : null } }), onAuthStateChange: vi.fn() },
  schema: () => ({ rpc: mock.rpc }),
}) }));
const scope = { accountId: 'account-a', eventId: 'event-a', groupId: 'group-a', runId:'run-a' };
const args = { _run_id: 'run-a', _expected_stop_id: 'stop-a', _expected_run_version: 2, _credential: 'private-qr-material', _participant_choices: { child: 'skipped' } };
const meta = { portalName: 'Eigen poort', childIds: ['child-a'], finale: false };
const connect = (online: boolean) => vi.stubGlobal('navigator', { onLine: online });
async function rawOutbox() {
  return new Promise<unknown[]>((resolve, reject) => { const request = indexedDB.open('duindorp-private-arrivals-v1', 1); request.onsuccess = () => { const db = request.result, tx = db.transaction('outbox', 'readonly'), read = tx.objectStore('outbox').getAll(); tx.oncomplete = () => { db.close(); resolve(read.result); }; }; request.onerror = () => reject(request.error); });
}

beforeEach(() => {
  vi.resetModules(); vi.stubGlobal('localStorage',undefined); vi.stubGlobal('indexedDB', new IDBFactory()); vi.stubGlobal('IDBKeyRange', IDBKeyRange);
  vi.stubGlobal('window', { addEventListener: vi.fn(), confirm: () => true }); connect(true);
  mock.userId = 'account-a'; mock.rpc.mockReset().mockResolvedValue({ data: { accepted: true }, error: null });
});

afterEach(async()=>{(await import('./arrival-sync')).clearArrivalMemory();vi.useRealTimers();vi.restoreAllMocks();});

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


describe('evening recovery under uncertain outcomes',()=>{
  it('retries an online 503 exactly six times with the original command',async()=>{
    vi.useFakeTimers({toFake:['setTimeout','clearTimeout','Date']});
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);await queue.flushArrivalQueue();
    mock.rpc.mockResolvedValue({data:null,error:{message:'Service unavailable'},status:503});
    const row=await queue.submitArrival('run_arrive_and_advance',args,meta);
    expect(row.status).toBe('pending');
    for(const delay of [1000,2000,4000,8000,16000]){await vi.advanceTimersByTimeAsync(delay);await queue.flushArrivalQueue();}
    expect(mock.rpc).toHaveBeenCalledTimes(6);
    expect(queue.getLatestArrival()).toMatchObject({status:'pending',automaticPaused:true,autoAttempts:6});
    await vi.advanceTimersByTimeAsync(120000);await queue.flushArrivalQueue();expect(mock.rpc).toHaveBeenCalledTimes(6);
    for(const call of mock.rpc.mock.calls)expect(call[1]).toEqual({...args,_idempotency_key:row.id});
    mock.rpc.mockResolvedValue({data:{accepted:true},error:null});await queue.retryArrival(row.id);
    expect(mock.rpc).toHaveBeenCalledTimes(7);expect(queue.getLatestArrival()?.status).toBe('confirmed');
  });
  it('keeps a timed-out response uncertain and retries the same key',async()=>{
    vi.useFakeTimers({toFake:['setTimeout','clearTimeout','Date']});
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);await queue.flushArrivalQueue();
    const requested=new Promise<void>(resolve=>{mock.rpc.mockImplementationOnce(()=>{resolve();return new Promise(()=>{});});});
    const saving=queue.submitArrival('run_arrive_and_advance',args,meta);
    await requested;
    expect(mock.rpc).toHaveBeenCalledTimes(1);await vi.advanceTimersByTimeAsync(8000);
    expect((await saving).status).toBe('pending');
    await queue.retryArrival(queue.getLatestArrival()!.id);
    expect(mock.rpc.mock.calls[0][1]).toEqual(mock.rpc.mock.calls[1][1]);expect(queue.getLatestArrival()?.status).toBe('confirmed');
  });
  it('retains the original rejected command after it is marked reviewed',async()=>{
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);
    mock.rpc.mockResolvedValue({data:null,error:{message:'FINAL_RESERVATION_MISSED'}});
    const row=await queue.submitArrival('run_arrive_and_advance',args,meta);
    expect(row.args._credential).toBe(args._credential);await queue.dismissArrival(row.id);
    expect(queue.getLatestArrival()).toBeNull();expect(await rawOutbox()).toHaveLength(1);
    vi.resetModules();const reopened=await import('./arrival-sync');await reopened.configureArrivalSync(scope);await reopened.flushArrivalQueue();
    expect(reopened.getLatestArrival()).toBeNull();expect(mock.rpc).toHaveBeenCalledTimes(1);expect(await rawOutbox()).toHaveLength(1);
  });
  it('never sends a previous run or an unbound guidance scope',async()=>{
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);connect(false);
    await queue.submitArrival('run_arrive_and_advance',args,meta);queue.clearArrivalMemory();connect(true);
    await queue.configureArrivalSync({...scope,runId:undefined});await queue.flushArrivalQueue();
    expect(mock.rpc).not.toHaveBeenCalled();expect(queue.getLatestArrival()).toBeNull();
    await queue.configureArrivalSync({...scope,runId:'run-b'});await queue.flushArrivalQueue();
    expect(queue.getArrivalRecoveryIssue()).toBe('OTHER_RUN_PENDING');expect(mock.rpc).not.toHaveBeenCalled();
    expect(queue.hasWaitingArrival()).toBe(false);expect(await rawOutbox()).toHaveLength(1);
  });
  it('coordinates two tabs through an atomic lease',async()=>{
    const first=await import('./arrival-sync');await first.configureArrivalSync(scope);connect(false);
    await first.submitArrival('run_arrive_and_advance',args,meta);
    vi.resetModules();const second=await import('./arrival-sync');await second.configureArrivalSync(scope);connect(true);
    let resolveResult!:(value:unknown)=>void;const requested=new Promise<void>(ready=>{mock.rpc.mockImplementation(()=>new Promise(resolve=>{resolveResult=resolve;ready();}));});
    const sending=first.flushArrivalQueue();
    await requested;
    await second.flushArrivalQueue();expect(mock.rpc).toHaveBeenCalledTimes(1);
    resolveResult({data:{accepted:true},error:null});await sending;await second.flushArrivalQueue();
    expect(second.getLatestArrival()?.status).toBe('confirmed');first.clearArrivalMemory();
  });
  it('preserves every pending command, including more than twenty-four rows',async()=>{
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);connect(false);
    for(let index=0;index<27;index++)await queue.submitArrival('run_arrive_and_advance',{...args,_expected_stop_id:'stop-'+index},meta);
    queue.clearArrivalMemory();await queue.configureArrivalSync(scope);
    expect(await rawOutbox()).toHaveLength(27);expect(mock.rpc).not.toHaveBeenCalled();
  });
  it('leaves unknown legacy and corrupt raw storage intact',async()=>{
    const raw='[{"credential":"unknown-legacy-private"}]',values=new Map([['duindorp-arrival-outbox-v1',raw]]);
    vi.stubGlobal('localStorage',{getItem:(key:string)=>values.get(key)??null});
    const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);connect(false);
    expect(queue.getArrivalRecoveryIssue()).toBe('LEGACY_OUTBOX_REQUIRES_HELP');expect(values.get('duindorp-arrival-outbox-v1')).toBe(raw);
    const row=await queue.submitArrival('run_arrive_and_advance',args,meta);queue.clearArrivalMemory();
    const db=await new Promise<IDBDatabase>(resolve=>{const r=indexedDB.open('duindorp-private-arrivals-v1',1);r.onsuccess=()=>resolve(r.result);});
    await new Promise<void>(resolve=>{const tx=db.transaction('outbox','readwrite');tx.objectStore('outbox').put({iv:new Uint8Array(12),ciphertext:new Uint8Array([1,2,3]).buffer},`${scope.accountId}:${scope.eventId}:${scope.groupId}:${row.id}`);tx.oncomplete=()=>resolve();});db.close();
    const before=await rawOutbox();await queue.configureArrivalSync(scope);
    expect(queue.getArrivalRecoveryIssue()).toBe('ARRIVAL_RECOVERY_REQUIRED');expect(await rawOutbox()).toEqual(before);
    await expect(queue.submitArrival('run_arrive_and_advance',{...args,_expected_stop_id:'fresh'},meta)).rejects.toThrow('ARRIVAL_RECOVERY_REQUIRED');expect(mock.rpc).not.toHaveBeenCalled();
  });
});


describe('account changes and interrupted leases',()=>{
  it('rejects a submit and stale configure when another account takes over during restore',async()=>{
    connect(false);const queue=await import('./arrival-sync');await queue.configureArrivalSync(scope);
    await queue.submitArrival('run_arrive_and_advance',args,meta);queue.clearArrivalMemory();
    let release!:()=>void;const original=crypto.subtle.decrypt.bind(crypto.subtle);
    const entered=new Promise<void>(ready=>{vi.spyOn(crypto.subtle,'decrypt').mockImplementationOnce(async(...values)=>{ready();await new Promise<void>(resolve=>{release=resolve;});return original(...values);});});
    const restoring=queue.configureArrivalSync(scope);await entered;
    const oldConfigure=queue.configureArrivalSync({...scope,runId:'obsolete-run'});
    const saving=expect(queue.submitArrival('run_arrive_and_advance',{...args,_expected_stop_id:'fresh'},meta)).rejects.toThrow('ACCOUNT_CHANGED');
    mock.userId='account-b';await queue.configureArrivalSync({...scope,accountId:'account-b',runId:'run-b'});
    release();await Promise.all([restoring,oldConfigure,saving]);
    expect(queue.getLatestArrival()).toBeNull();expect(await rawOutbox()).toHaveLength(1);expect(mock.rpc).not.toHaveBeenCalled();
    mock.userId='account-a';await queue.configureArrivalSync(scope);
    expect(queue.getLatestArrival()?.args._run_id).toBe('run-a');
  });
  it('does not alter another tab’s sending lease when authentication is unavailable',async()=>{
    connect(false);const first=await import('./arrival-sync');await first.configureArrivalSync(scope);
    await first.submitArrival('run_arrive_and_advance',args,meta);
    vi.resetModules();const second=await import('./arrival-sync');await second.configureArrivalSync(scope);connect(true);
    let finish!:(value:unknown)=>void;const requested=new Promise<void>(ready=>{mock.rpc.mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve;ready();}));});
    const sending=first.flushArrivalQueue();await requested;const before=await rawOutbox();
    mock.userId=null;await second.flushArrivalQueue();expect(await rawOutbox()).toEqual(before);
    mock.userId='account-a';finish({data:{accepted:true},error:null});await sending;await second.flushArrivalQueue();
    expect(mock.rpc).toHaveBeenCalledTimes(1);expect(second.getLatestArrival()?.status).toBe('confirmed');first.clearArrivalMemory();
  });
  it('pauses an interrupted sixth attempt after its lease expires',async()=>{
    vi.useFakeTimers({toFake:['setTimeout','clearTimeout','Date']});
    const first=await import('./arrival-sync');await first.configureArrivalSync(scope);await first.flushArrivalQueue();
    mock.rpc.mockResolvedValue({data:null,error:{message:'Service unavailable'},status:503});
    await first.submitArrival('run_arrive_and_advance',args,meta);
    for(const delay of [1000,2000,4000,8000]){await vi.advanceTimersByTimeAsync(delay);await first.flushArrivalQueue();}
    expect(mock.rpc).toHaveBeenCalledTimes(5);
    const requested=new Promise<void>(ready=>{mock.rpc.mockImplementationOnce(()=>{ready();return new Promise(()=>{});});});
    await vi.advanceTimersByTimeAsync(16000);await requested;expect(mock.rpc).toHaveBeenCalledTimes(6);
    first.clearArrivalMemory();vi.resetModules();const restored=await import('./arrival-sync');await restored.configureArrivalSync(scope);
    await vi.advanceTimersByTimeAsync(12001);await restored.flushArrivalQueue();
    expect(mock.rpc).toHaveBeenCalledTimes(6);expect(restored.getLatestArrival()).toMatchObject({status:'pending',automaticPaused:true,autoAttempts:6});
    expect(await rawOutbox()).toHaveLength(1);
  });
});
