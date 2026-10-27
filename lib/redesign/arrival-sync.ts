"use client";

import type {AuthChangeEvent,Session} from "@supabase/supabase-js";
import { createClient } from '@/lib/supabase/client';

export type ArrivalConnection = 'online' | 'offline';
type Scope = { accountId: string; eventId: string; groupId: string };
type Args = Record<string, unknown>;
export type ArrivalReceipt = {
  id: string; action: 'run_arrive_and_advance' | 'run_scan'; args: Args;
  portalName: string; childIds: string[]; finale: boolean; createdAt: string; updatedAt: string;
  status: 'sending' | 'pending' | 'confirmed' | 'attention'; error?: string;
};
let scope: Scope | null = null, receipts: ArrivalReceipt[] = [], generation = 0;
let flushing: Promise<void> | null = null, configuring: Promise<void> | null = null;
let scopeKey = '', started = false;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach(listener => listener());

async function database() {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open('duindorp-private-arrivals-v1', 1);
    request.onupgradeneeded = () => { request.result.createObjectStore('keys'); request.result.createObjectStore('outbox'); };
    request.onerror = () => reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
    request.onsuccess = () => resolve(request.result);
  });
}
async function stored<T>(store: string, id: string, write?: T): Promise<T | undefined> {
  const db = await database();
  try {
    return await new Promise<T | undefined>((resolve, reject) => {
      const tx = db.transaction(store, write === undefined ? 'readonly' : 'readwrite');
      const request = write === undefined ? tx.objectStore(store).get(id) : tx.objectStore(store).put(write, id);
      tx.oncomplete = () => resolve(write ?? request.result);
      tx.onabort = tx.onerror = () => reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));
    });
  } finally { db.close(); }
}
async function encryptionKey(id: string) {
  const existing=await stored<CryptoKey>('keys',id);if(existing)return existing;
  const generated=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  const db=await database();
  try{return await new Promise<CryptoKey>((resolve,reject)=>{const tx=db.transaction('keys','readwrite'),store=tx.objectStore('keys'),request=store.get(id);let selected=generated;request.onsuccess=()=>{if(request.result)selected=request.result;else store.put(generated,id);};tx.oncomplete=()=>resolve(selected);tx.onerror=tx.onabort=()=>reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));});}finally{db.close();}
}
async function encryptedRows(id:string){
 const db=await database();
 try{return await new Promise<Array<{iv:Uint8Array<ArrayBuffer>;ciphertext:ArrayBuffer}>>((resolve,reject)=>{const tx=db.transaction('outbox','readonly'),request=tx.objectStore('outbox').getAll(IDBKeyRange.bound(id+':',id+':\uffff'));tx.oncomplete=()=>resolve(request.result);tx.onerror=()=>reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));});}finally{db.close();}
}
async function persist(next: ArrivalReceipt[], current = scopeKey) {
  if (!current || current !== scopeKey) throw new Error('ACCOUNT_CHANGED');
  const key=await encryptionKey(current);
  // Each intent has its own durable record: another tab cannot overwrite a queue.
  for(const row of next){
   const iv=crypto.getRandomValues(new Uint8Array(12));
   const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:new TextEncoder().encode(current)},key,new TextEncoder().encode(JSON.stringify(row)));
   if(current!==scopeKey)throw new Error('ACCOUNT_CHANGED');
   await stored('outbox',current+':'+row.id,{iv,ciphertext});
  }
  if(current===scopeKey){receipts=next;notify();}
}
export function clearArrivalMemory() {
  generation++; scope = null; scopeKey = ''; receipts = []; configuring = null; notify();
  // Unconfirmed encrypted commands stay in their own account/event/route scope.
  // They can only be restored after that account is authenticated again.
}
export async function configureArrivalSync(next: Scope) {
  const id = `${next.accountId}:${next.eventId}:${next.groupId}`;
  if (scopeKey === id) { await configuring; return; }
  clearArrivalMemory(); scopeKey = id; scope = next;
  const current = generation;
  configuring = (async () => {
    const client = createClient(), user = await client?.auth.getUser();
    if (current !== generation) return;
    if (user?.data.user?.id !== next.accountId) { clearArrivalMemory(); return; }
    try {
      const encrypted=await encryptedRows(id),key=await encryptionKey(id),restored:ArrivalReceipt[]=[];
      for(const row of encrypted){const value=await crypto.subtle.decrypt({name:'AES-GCM',iv:row.iv,additionalData:new TextEncoder().encode(id)},key,row.ciphertext);restored.push(JSON.parse(new TextDecoder().decode(value)) as ArrivalReceipt);}
      if(current===generation)receipts=restored.sort((a,b)=>a.createdAt.localeCompare(b.createdAt));
    } catch {
      if (current === generation) {
        // Keep the encrypted outbox intact and permit a fresh recovery attempt.
        clearArrivalMemory();
        throw new Error('ARRIVAL_RECOVERY_REQUIRED');
      }
    }
    notify();
  })();
  await configuring;
  if (current === generation) { startArrivalSync(); void flushArrivalQueue(); }
}
export const getArrivalConnection = (): ArrivalConnection => typeof navigator !== 'undefined' && navigator.onLine === false ? 'offline' : 'online';
export const isArrivalConnected = () => getArrivalConnection() === 'online';
export const getLatestArrival = (childId?: string) => receipts.filter(row => !childId || row.childIds.includes(childId)).at(-1) ?? null;
export const hasWaitingArrival = () => receipts.some(row => ['pending', 'sending'].includes(row.status));
export function subscribeArrivalSync(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; }

export async function flushArrivalQueue(): Promise<void> {
  if (flushing) { await flushing; if (isArrivalConnected() && hasWaitingArrival()) return flushArrivalQueue(); return; }
  const current = generation;
  flushing = (async () => {
    for (const row of receipts.filter(item => ['pending', 'sending'].includes(item.status))) {
      if (current !== generation || !scope || !isArrivalConnected()) break;
      const client = createClient(), user = await client?.auth.getUser();
      if (!client || current !== generation || user?.data.user?.id !== scope.accountId) { clearArrivalMemory(); break; }
      await persist(receipts.map(item => item.id === row.id ? { ...item, status: 'sending', updatedAt: new Date().toISOString() } : item));
      let patch: Partial<ArrivalReceipt>;
      try {
        const { data, error } = await client.schema('api').rpc(row.action === 'run_scan' ? 'run_confirm_arrival' : row.action, row.args);
        if (error) {
          patch = /fetch|network|timeout|503|502/i.test(error.message) ? { status: 'pending' } : { status: 'attention', error: error.message };
        } else if (data?.accepted || data?.completedStopId) {
          patch = { status: 'confirmed', args: { _run_id: row.args._run_id, _expected_stop_id: row.args._expected_stop_id }, error: undefined };
        } else patch = { status: 'attention', error: 'CONFIRMATION_MISSING' };
      } catch { patch = { status: 'pending' }; }
      if (current !== generation) break;
      await persist(receipts.map(item => item.id === row.id ? { ...item, ...patch, updatedAt: new Date().toISOString() } : item));
      if (patch.status === 'pending') break;
    }
  })().finally(() => { flushing = null; });
  return flushing;
}
export async function submitArrival(action: ArrivalReceipt['action'], args: Args, meta: Pick<ArrivalReceipt, 'portalName' | 'childIds' | 'finale'>) {
  await configuring;
  if (!scope) throw new Error('AUTHENTICATION_REQUIRED');
  const existing = receipts.find(row => row.args._run_id === args._run_id && row.args._expected_stop_id === args._expected_stop_id && row.action === action && row.status !== 'attention');
  if (existing) { await flushArrivalQueue(); return receipts.find(row => row.id === existing.id)!; }
  const id = crypto.randomUUID(), now = new Date().toISOString();
  const row: ArrivalReceipt = { id, action, args: { ...args, _idempotency_key: id }, ...meta, createdAt: now, updatedAt: now, status: 'pending' };
  await persist([...receipts, row]);
  await flushArrivalQueue();
  return receipts.find(item => item.id === id) ?? row;
}
export async function retryArrival(id: string) { await persist(receipts.map(row => row.id === id ? { ...row, status: 'pending', error: undefined } : row)); return flushArrivalQueue(); }
export async function dismissArrival(id: string) {
  const row = receipts.find(item => item.id === id);
  if (row?.status !== 'attention' && row?.status !== 'confirmed') return;
  if (row.status === 'attention' && !window.confirm('Deze onbevestigde aankomst verwijderen? Controleer eerst de actuele route.')) return;
  const db=await database();
  try{await new Promise<void>((resolve,reject)=>{const tx=db.transaction('outbox','readwrite');tx.objectStore('outbox').delete(scopeKey+':'+id);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(new Error('LOCAL_STORAGE_UNAVAILABLE'));});}finally{db.close();}
  receipts=receipts.filter(item=>item.id!==id);notify();
}
export function startArrivalSync() {
  if (started) return; started = true;
  window.addEventListener('online', () => { notify(); void flushArrivalQueue(); });
  window.addEventListener('offline', notify);
  const client = createClient();
  client?.auth.onAuthStateChange((_event:AuthChangeEvent, session:Session|null) => { if (!session || (scope && session.user.id !== scope.accountId)) clearArrivalMemory(); });
}
