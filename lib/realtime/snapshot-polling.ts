import { createRefreshQueue, snapshotPollDelay } from "./refresh-queue";

/** Visible, online fallback reads, also used when the WebSocket is unavailable. */
export function startSnapshotPolling(refresh: () => void | Promise<unknown>, intervalMs = 15_000) {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout>;
  const queue = createRefreshQueue(async () => {
    if (document.visibilityState !== "hidden" && navigator.onLine) await refresh();
  }, () => Math.floor(Math.random() * 1000));
  const poll = async () => {
    try { await queue.load(); } catch { /* The source retains its own error UI. */ }
    finally { if (!stopped) timer = setTimeout(() => void poll(), snapshotPollDelay(intervalMs)); }
  };
  timer = setTimeout(() => void poll(), snapshotPollDelay(intervalMs));
  const listener = () => queue.invalidate();
  for (const name of ["focus", "pageshow", "online"]) window.addEventListener(name, listener);
  document.addEventListener("visibilitychange", listener);
  return () => {
    stopped = true;
    clearTimeout(timer);
    queue.dispose();
    for (const name of ["focus", "pageshow", "online"]) window.removeEventListener(name, listener);
    document.removeEventListener("visibilitychange", listener);
  };
}
