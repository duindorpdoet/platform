"use client";

import { useCallback, useEffect, useRef } from "react";
import { createRefreshQueue } from "./refresh-queue";

/** Keep reads local to this mounted source/account; do not share private results. */
export function useSnapshotLoader(refresh: () => void | Promise<unknown>) {
  const queue = useRef<{ source: typeof refresh; work: ReturnType<typeof createRefreshQueue> } | null>(null);
  useEffect(() => {
    const current = { source: refresh, work: createRefreshQueue(refresh) };
    queue.current = current;
    return () => {
      current.work.dispose();
      if (queue.current === current) queue.current = null;
    };
  }, [refresh]);
  const load = useCallback(() => queue.current?.source === refresh ? queue.current.work.load() : Promise.resolve(), [refresh]);
  const invalidate = useCallback(() => {
    if (document.visibilityState === "hidden" || !navigator.onLine) return;
    if (queue.current?.source === refresh) queue.current.work.invalidate();
  }, [refresh]);
  return { load, invalidate };
}
