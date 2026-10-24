"use client";

import type { AuthChangeEvent, Session } from '@supabase/supabase-js';
import { createClient } from '@/lib/supabase/client';

export type ArrivalConnection = 'online' | 'offline';
type Scope = { accountId: string; eventId: string; groupId: string; runId?: string | null };
type Args = Record<string, unknown>;
export type ArrivalReceipt = {
  id: string; action: 'run_arrive_and_advance' | 'run_scan'; args: Args;
  portalName: string; childIds: string[]; finale: boolean; createdAt: string; updatedAt: string;
  status: 'sending' | 'pending' | 'confirmed' | 'attention'; error?: string;
  scope?: Scope; autoAttempts?: number; attemptCount?: number; nextRetryAt?: number;
  automaticPaused?: boolean; reviewed?: boolean;
};
type Envelope = { iv: Uint8Array<ArrayBuffer>; ciphertext: ArrayBuffer; revision?: number; leaseOwner?: string; leaseUntil?: number };
const owner = crypto.randomUUID(), MAX_ATTEMPTS = 6, DEADLINE = 8_000, LEASE = 12_000;
let scope: Scope | null = null, scopeKey = '', generation = 0, receipts: ArrivalReceipt[] = [];
let flushing: Promise<void> | null = null, configuring: Promise<void> | null = null;
let retryTimer: ReturnType<typeof setTimeout> | null = null, started = false, issue = '';
let channel: BroadcastChannel | null = null,activeController:AbortController|null=null,authorizationRetryAt=0;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach(listener => listener());
const now = () => new Date().toISOString();
const isWaiting = (row: ArrivalReceipt) => row.status === 'pending' || row.status === 'sending';
const belongs = (row: ArrivalReceipt) => !!scope && (!row.scope || row.scope.accountId === scope.accountId && row.scope.eventId === scope.eventId && row.scope.groupId === scope.groupId)
  && scope.runId !== undefined && row.args._run_id === scope.runId;
function cancelTimer() { if (retryTimer) clearTimeout(retryTimer); retryTimer = null; }

async function database() {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open('duindorp-private-arrivals-v1', 1);
    request.onupgradeneeded = () => { request.result.createObjectStore('keys'); request.result.createObjectStore('outbox'); };
    request.onerror = () => reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
    request.onsuccess = () => resolve(request.result);
  });
}
async function stored<T>(store: string, id: string): Promise<T | undefined> {
  const db = await database();
  try { return await new Promise<T | undefined>((resolve, reject) => {
    const tx = db.transaction(store, 'readonly'), request = tx.objectStore(store).get(id);
    tx.oncomplete = () => resolve(request.result); tx.onerror = tx.onabort = () => reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
  }); } finally { db.close(); }
}
async function encryptionKey(id: string) {
  const existing = await stored<CryptoKey>('keys', id); if (existing) return existing;
  const generated = await crypto.subtle.generateKey({name:'AES-GCM', length:256}, false, ['encrypt','decrypt']);
  const db = await database();
  try { return await new Promise<CryptoKey>((resolve, reject) => {
    const tx = db.transaction('keys','readwrite'), store = tx.objectStore('keys'), request = store.get(id); let selected = generated;
    request.onsuccess = () => { if (request.result) selected = request.result; else store.put(generated,id); };
    tx.oncomplete = () => resolve(selected); tx.onerror = tx.onabort = () => reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
  }); } finally { db.close(); }
}
async function encryptedRows(id: string) {
  const db = await database();
  try { return await new Promise<Envelope[]>((resolve,reject) => {
    const tx=db.transaction('outbox','readonly'), request=tx.objectStore('outbox').getAll(IDBKeyRange.bound(id+':',id+':\uffff'));
    tx.oncomplete=()=>resolve(request.result); tx.onerror=tx.onabort=()=>reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
  }); } finally { db.close(); }
}
async function decode(value: Envelope, id: string) {
  const bytes=await crypto.subtle.decrypt({name:'AES-GCM',iv:value.iv,additionalData:new TextEncoder().encode(id)},await encryptionKey(id),value.ciphertext);
  const row=JSON.parse(new TextDecoder().decode(bytes)) as ArrivalReceipt;
  if (typeof row.id!=='string'||!row.id||!row.args||typeof row.args!=='object'||Array.isArray(row.args)
    ||row.args._idempotency_key!==row.id||typeof row.args._run_id!=='string'||typeof row.args._expected_stop_id!=='string'
    ||typeof row.portalName!=='string'||!Array.isArray(row.childIds)||row.childIds.some(id=>typeof id!=='string')||typeof row.finale!=='boolean'
    ||!Number.isFinite(Date.parse(row.createdAt))||!Number.isFinite(Date.parse(row.updatedAt))
    ||!['run_arrive_and_advance','run_scan'].includes(row.action)||!['pending','sending','confirmed','attention'].includes(row.status)
    ||row.scope&&(!row.scope.accountId||!row.scope.eventId||!row.scope.groupId)) throw new Error('INVALID_OUTBOX');
  return row;
}
async function encode(row: ArrivalReceipt, id: string) {
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:new TextEncoder().encode(id)},await encryptionKey(id),new TextEncoder().encode(JSON.stringify(row)));
  return {iv,ciphertext};
}
// Crypto runs outside the transaction; compare-and-swap prevents stale tabs from
// replacing newer receipts. A lease is claimed inside this same atomic write.
async function change(id: string, update: (row: ArrivalReceipt | undefined, envelope: Envelope | undefined) => ArrivalReceipt | null, claim=false) {
  const key=scopeKey, gen=generation;
  if (!key) throw new Error('AUTHENTICATION_REQUIRED');
  for (let attempt=0; attempt<8; attempt++) {
    const old=await stored<Envelope>('outbox',key+':'+id);
    const value=update(old ? await decode(old,key) : undefined,old); if (!value) return null;
    const encrypted=await encode(value,key);
    if (key!==scopeKey || gen!==generation) throw new Error('ACCOUNT_CHANGED');
    const db=await database();
    const saved=await new Promise<boolean>((resolve,reject)=>{
      const tx=db.transaction('outbox','readwrite'), store=tx.objectStore('outbox'), request=store.get(key+':'+id); let applied=false;
      request.onsuccess=()=>{
        const current=request.result as Envelope|undefined;
        const matches=(!old&&!current) || (!!old&&!!current&&(old.revision??0)===(current.revision??0)&&Array.from(old.iv).join()===Array.from(current.iv).join());
        if (!matches) return;
        const lease=claim?{leaseOwner:owner,leaseUntil:Date.now()+LEASE}:current?.leaseOwner===owner&&value.status!=='sending'?{leaseOwner:undefined,leaseUntil:undefined}:{leaseOwner:current?.leaseOwner,leaseUntil:current?.leaseUntil};
        store.put({...encrypted,revision:(current?.revision??0)+1,...lease},key+':'+id); applied=true;
      };
      tx.oncomplete=()=>resolve(applied); tx.onabort=tx.onerror=()=>reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
    }).finally(()=>db.close());
    if (saved) { channel?.postMessage('changed'); await restore(key,gen); return value; }
  }
  throw new Error('OUTBOX_BUSY');
}
async function restore(key=scopeKey, gen=generation) {
  const values: ArrivalReceipt[]=[]; let corrupt=false;
  for (const envelope of await encryptedRows(key)) {
    try { const row=await decode(envelope,key); values.push(row); } catch { corrupt=true; }
  }
  if (key!==scopeKey || gen!==generation) return;
  receipts=values.sort((a,b)=>a.createdAt.localeCompare(b.createdAt));
  issue=corrupt ? 'ARRIVAL_RECOVERY_REQUIRED' : receipts.some(row=>isWaiting(row)&&!belongs(row)) ? 'OTHER_RUN_PENDING' : '';
  // Legacy unscoped commands remain byte-for-byte intact and are never sent.
  if (typeof localStorage!=='undefined' && ['duindorp-arrival-outbox-v1','duindorp-arrival-outbox-v2'].some(key=>localStorage.getItem(key))) issue ||= 'LEGACY_OUTBOX_REQUIRES_HELP';
  notify();
}
export function clearArrivalMemory() {
  generation++; cancelTimer(); activeController?.abort(); authorizationRetryAt=0;scope=null; scopeKey=''; receipts=[]; configuring=null; issue=''; notify();
  // Durable ciphertext and keys survive sign-out. A new account cannot load it.
}
export async function configureArrivalSync(next: Scope) {
  const id=`${next.accountId}:${next.eventId}:${next.groupId}`;
  if (scopeKey===id) {
    const entered=generation;await configuring;
    if(scopeKey!==id||generation!==entered)return;
    if (next.runId!==undefined && scope?.runId!==next.runId) { generation++; scope={...next}; await restore(); schedule(); }
    return;
  }
  clearArrivalMemory(); scopeKey=id; scope={...next}; const gen=generation;
  configuring=(async()=>{
    const user=await createClient()?.auth.getUser();
    if (gen!==generation) return;
    if (user?.data.user && user.data.user.id!==next.accountId) { clearArrivalMemory(); return; }
    try { await restore(id,gen); }
    catch { if (gen===generation) { issue='ARRIVAL_RECOVERY_REQUIRED'; notify(); } throw new Error('ARRIVAL_RECOVERY_REQUIRED'); }
  })();
  await configuring;
  if (gen===generation) { startArrivalSync(); wake(); }
}
export const getArrivalConnection=():ArrivalConnection=>typeof navigator!=='undefined'&&navigator.onLine===false?'offline':'online';
export const isArrivalConnected=()=>getArrivalConnection()==='online';
export const getArrivalRecoveryIssue=()=>issue;
export const getArrivalReceipts=(childId?:string,includeReviewed=false)=>receipts.filter(row=>belongs(row)&&(includeReviewed||!row.reviewed)&&(!childId||row.childIds.includes(childId)));
export const getLatestArrival=(childId?:string)=>{const rows=getArrivalReceipts(childId);return rows.filter(row=>row.status!=='confirmed').at(-1)??rows.at(-1)??null;};
export const hasWaitingArrival=()=>receipts.some(row=>belongs(row)&&isWaiting(row));
export function subscribeArrivalSync(listener:()=>void) { listeners.add(listener); return()=>{listeners.delete(listener);}; }
function schedule() {
  cancelTimer();
  if (!scope?.runId || !isArrivalConnected() || issue==='ARRIVAL_RECOVERY_REQUIRED') return;
  const next=receipts.filter(row=>belongs(row)&&isWaiting(row)&&!row.automaticPaused).map(row=>row.nextRetryAt??Date.now()).sort((a,b)=>a-b)[0];
  if (next!==undefined) { retryTimer=setTimeout(wake,Math.max(30,Math.max(next,authorizationRetryAt)-Date.now())); (retryTimer as unknown as {unref?:()=>void}).unref?.(); }
}
function wake() { void flushArrivalQueue().catch(()=>{issue='ARRIVAL_RECOVERY_REQUIRED';notify();}); }
async function send(row: ArrivalReceipt) {
  const client=createClient(); if (!client) throw new Error('NETWORK_UNAVAILABLE');
  const controller=new AbortController(); activeController=controller; let timer:ReturnType<typeof setTimeout>|undefined;
  try {
    const request=client.schema('api').rpc(row.action==='run_scan'?'run_confirm_arrival':row.action,row.args);
    const abortable='abortSignal' in request ? request.abortSignal(controller.signal) : request;
    return await Promise.race([Promise.resolve(abortable),new Promise<never>((_,reject)=>{ timer=setTimeout(()=>{controller.abort();reject(new Error('REQUEST_TIMEOUT'));},DEADLINE); })]);
  } finally { if (timer) clearTimeout(timer);if(activeController===controller)activeController=null; }
}
export async function flushArrivalQueue():Promise<void> {
  if (flushing) { await flushing; if (scope?.runId && isArrivalConnected() && receipts.some(row=>belongs(row)&&isWaiting(row)&&!row.automaticPaused&&(row.nextRetryAt??0)<=Date.now())) return flushArrivalQueue(); return; }
  const gen=generation;
  flushing=(async()=>{
    if (!scopeKey || !scope?.runId || !isArrivalConnected()) return;
    await restore();
    if (issue==='ARRIVAL_RECOVERY_REQUIRED') return;
    for (const row of receipts.filter(row=>belongs(row)&&isWaiting(row)&&!row.automaticPaused)) {
      if (gen!==generation || !scope || !isArrivalConnected()) break;
      if ((row.nextRetryAt??0)>Date.now()) continue;
      const user=await createClient()?.auth.getUser();
      if (gen!==generation) break;
      if (!user?.data.user) {authorizationRetryAt=Date.now()+15_000;break;}
      authorizationRetryAt=0;
      if (user.data.user.id!==scope.accountId) { clearArrivalMemory(); break; }
      if((row.autoAttempts??0)>=MAX_ATTEMPTS){await change(row.id,(fresh,envelope)=>fresh&&isWaiting(fresh)&&(fresh.autoAttempts??0)>=MAX_ATTEMPTS&&(envelope?.leaseUntil??0)<=Date.now()?{...fresh,status:'pending',automaticPaused:true,nextRetryAt:undefined,error:'RESPONSE_UNCERTAIN'}:null);continue;}
      const claimed=await change(row.id,(fresh,envelope)=>{
        if (!fresh||!belongs(fresh)||!isWaiting(fresh)||fresh.automaticPaused||(fresh.autoAttempts??0)>=MAX_ATTEMPTS||(fresh.nextRetryAt??0)>Date.now()) return null;
        if ((envelope?.leaseUntil??0)>Date.now()) return null;
        return {...fresh,status:'sending',autoAttempts:(fresh.autoAttempts??0)+1,attemptCount:(fresh.attemptCount??0)+1,nextRetryAt:Date.now()+LEASE,updatedAt:now()};
      },true);
      if (!claimed) continue;
      if(gen!==generation||!scope)break;
      let patch:Partial<ArrivalReceipt>;
      try {
        const {data,error,status}=await send(claimed);
        if (error) {
          const transient=[408,425,429].includes(Number(status))||Number(status)>=500||/fetch|network|timeout|503|502|NETWORK_UNAVAILABLE/i.test(error.message);
          patch=transient ? {status:'pending',error:'RESPONSE_UNCERTAIN'} : {status:'attention',error:error.message,automaticPaused:true};
        } else if (data?.accepted||data?.completedStopId) patch={status:'confirmed',args:{_run_id:claimed.args._run_id,_expected_stop_id:claimed.args._expected_stop_id,_idempotency_key:claimed.args._idempotency_key},error:undefined,automaticPaused:false};
        else patch={status:'attention',error:'CONFIRMATION_MISSING',automaticPaused:true};
      } catch { patch={status:'pending',error:'RESPONSE_UNCERTAIN'}; }
      if (gen!==generation) break;
      if (patch.status==='pending') {
        const count=claimed.autoAttempts??1;
        patch.automaticPaused=count>=MAX_ATTEMPTS;
        patch.nextRetryAt=Date.now()+Math.min(16_000,1000*2**(count-1));
      } else patch.nextRetryAt=undefined;
      await change(row.id,(fresh,envelope)=>fresh&&envelope?.leaseOwner===owner&&fresh.status==='sending'?{...fresh,...patch,updatedAt:now()}:null);
    }
  })().finally(()=>{flushing=null; schedule();});
  return flushing;
}
export async function submitArrival(action:ArrivalReceipt['action'],args:Args,meta:Pick<ArrivalReceipt,'portalName'|'childIds'|'finale'>) {
  const entered=generation,enteredKey=scopeKey,enteredScope=scope?{...scope}:null;
  await configuring;
  const assertScope=()=>{if(generation!==entered||scopeKey!==enteredKey||scope?.accountId!==enteredScope?.accountId)throw new Error('ACCOUNT_CHANGED');};
  assertScope();
  if (!scope?.runId) throw new Error('AUTHENTICATION_REQUIRED');
  if (issue==='ARRIVAL_RECOVERY_REQUIRED') throw new Error(issue);
  if (scope.runId!==undefined&&args._run_id!==scope.runId) throw new Error('RUN_CHANGED');
  await restore(enteredKey,entered);assertScope();
  const existing=receipts.find(row=>belongs(row)&&row.args._run_id===args._run_id&&row.args._expected_stop_id===args._expected_stop_id&&row.action===action&&row.status!=='attention');
  if (existing) { await flushArrivalQueue(); return receipts.find(row=>row.id===existing.id)??existing; }
  const id=crypto.randomUUID(), timestamp=now();
  const row:ArrivalReceipt={id,action,args:{...args,_idempotency_key:id},...meta,scope:{...scope,runId:String(args._run_id)},createdAt:timestamp,updatedAt:timestamp,status:'pending',autoAttempts:0};
  await change(id,fresh=>fresh??row); // Sending is impossible before durable commit.
  await flushArrivalQueue(); return receipts.find(item=>item.id===id)??row;
}
export async function retryArrival(id:string) {
  await change(id,row=>row&&belongs(row)&&row.status==='pending'?{...row,autoAttempts:0,nextRetryAt:0,automaticPaused:false,error:undefined}:null);
  return flushArrivalQueue();
}
export async function dismissArrival(id:string) {
  await change(id,row=>row&&belongs(row)&&['attention','confirmed'].includes(row.status)?{...row,reviewed:true,updatedAt:now()}:null);
}
export function startArrivalSync() {
  if (started) return; started=true;
  for (const event of ['online','focus','pageshow']) window.addEventListener(event,wake);
  window.addEventListener('offline',()=>{cancelTimer();notify();});
  if (typeof document!=='undefined') document.addEventListener('visibilitychange',()=>{if(!document.hidden)wake();});
  if (typeof window.BroadcastChannel==='function') { channel=new BroadcastChannel('duindorp-arrival-receipts-v1'); channel.onmessage=()=>{if(scopeKey)void restore().then(schedule).catch(()=>{issue='ARRIVAL_RECOVERY_REQUIRED';notify();});}; }
  createClient()?.auth.onAuthStateChange((_event:AuthChangeEvent,session:Session|null)=>{if(!session||(scope&&session.user.id!==scope.accountId))clearArrivalMemory();});
}
