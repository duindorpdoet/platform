"use client";

const LEGACY_PREFIX = "duindorp-private-group:";
const PREFIX = `${LEGACY_PREFIX}ops2:`;

export function storePrivateSnapshot(userId: string, groupId: string, snapshot: unknown, ttlMinutes = 30) {
  localStorage.setItem(`${PREFIX}${userId}:${groupId}`, JSON.stringify({ userId, groupId, expiresAt: Date.now() + ttlMinutes * 60_000, snapshot }));
}

export function readPrivateSnapshot<T>(userId: string, groupId: string): T | null {
  try {
    localStorage.removeItem(`${LEGACY_PREFIX}${userId}:${groupId}`);
    localStorage.removeItem(`${LEGACY_PREFIX}ops1:${userId}:${groupId}`);
    const key = `${PREFIX}${userId}:${groupId}`;
    const stored = JSON.parse(localStorage.getItem(key) ?? "null") as { userId?: string; expiresAt?: number; snapshot?: T } | null;
    if (!stored || stored.userId !== userId || !stored.expiresAt || stored.expiresAt < Date.now()) { localStorage.removeItem(key); return null; }
    return stored.snapshot ?? null;
  } catch { return null; }
}

export function clearPrivateSnapshots() {
  try {
  for (let index = localStorage.length - 1; index >= 0; index -= 1) {
    const key = localStorage.key(index);
    if (key?.startsWith(LEGACY_PREFIX)) localStorage.removeItem(key);
  }
  } catch { /* Storage can be unavailable; sign-out must remain usable. */ }
  navigator.serviceWorker?.controller?.postMessage({ type: "CLEAR_PRIVATE_CACHE" });
}
