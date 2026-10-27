"use client";

import { useEffect, useEffectEvent } from "react";
import { startSnapshotPolling } from "./snapshot-polling";

/** Private realtime is supplemented by refreshes after suspension or disconnection. */
export function useSnapshotRefresh(refresh: () => void | Promise<void>, { enabled = true, intervalMs = 15_000 }: { enabled?: boolean; intervalMs?: number } = {}) {
  const run = useEffectEvent(refresh);
  useEffect(() => {
    if (!enabled) return;
    return startSnapshotPolling(() => run(), intervalMs);
  }, [enabled, intervalMs]);
}
