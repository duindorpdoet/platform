"use client";

const PREFIX = "duindorp-private-group:";

export function storePrivateSnapshot(userId: string, groupId: string, snapshot: unknown, ttlMinutes = 30) {
  localStorage.setItem(`${PREFIX}${userId}:${groupId}`, JSON.stringify({ userId, groupId, expiresAt: Date.now() + ttlMinutes * 60_000, snapshot }));
}

export function readPrivateSnapshot<T>(userId: string, groupId: string): T | null {
  try {
    const key = `${PREFIX}${userId}:${groupId}`;
    const stored = JSON.parse(localStorage.getItem(key) ?? "null") as { userId?: string; expiresAt?: number; snapshot?: T } | null;
    if (!stored || stored.userId !== userId || !stored.expiresAt || stored.expiresAt < Date.now()) { localStorage.removeItem(key); return null; }
    return stored.snapshot ?? null;
  } catch { return null; }
}

export function clearPrivateSnapshots() {
  for (let index = localStorage.length - 1; index >= 0; index -= 1) {
    const key = localStorage.key(index);
    if (key?.startsWith(PREFIX)) localStorage.removeItem(key);
  }
  navigator.serviceWorker?.controller?.postMessage({ type: "CLEAR_PRIVATE_CACHE" });
}
