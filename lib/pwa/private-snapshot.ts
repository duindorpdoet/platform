"use client";

const LEGACY_PREFIX = "duindorp-private-group:";
const PREFIX = `${LEGACY_PREFIX}ops1:`;

export function storePrivateSnapshot(userId: string, groupId: string, snapshot: unknown, ttlMinutes = 30) {
  localStorage.setItem(`${PREFIX}${userId}:${groupId}`, JSON.stringify({ userId, groupId, expiresAt: Date.now() + ttlMinutes * 60_000, snapshot }));
}

export function readPrivateSnapshotEntry<T>(userId:string,groupId:string):{snapshot:T;expiresAt:number}|null {
  try {
    localStorage.removeItem(`${LEGACY_PREFIX}${userId}:${groupId}`);
    const key = `${PREFIX}${userId}:${groupId}`;
    const stored = JSON.parse(localStorage.getItem(key) ?? "null") as { userId?: string; groupId?: string; expiresAt?: number; snapshot?: T } | null;
    if (!stored || stored.userId !== userId || stored.groupId !== groupId || !Number.isFinite(stored.expiresAt) || !stored.expiresAt || stored.expiresAt <= Date.now()) { localStorage.removeItem(key); return null; }
    return stored.snapshot?{snapshot:stored.snapshot,expiresAt:stored.expiresAt}:null;
  } catch { return null; }
}

export function readPrivateSnapshot<T>(userId:string,groupId:string):T|null{return readPrivateSnapshotEntry<T>(userId,groupId)?.snapshot??null;}

export function clearPrivateSnapshots() {
  try {
    for (let index = localStorage.length - 1; index >= 0; index -= 1) {
      const key = localStorage.key(index);
      if (key?.startsWith(LEGACY_PREFIX)) localStorage.removeItem(key);
    }
  } catch { /* Storage denial must not prevent sign-out or pausing the outbox. */ }
  if(typeof navigator!=='undefined')navigator.serviceWorker?.controller?.postMessage({ type: "CLEAR_PRIVATE_CACHE" });
}
