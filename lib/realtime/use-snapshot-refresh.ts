"use client";

import { useEffect, useEffectEvent } from "react";

/** Private realtime is supplemented by refreshes after suspension or disconnection. */
export function useSnapshotRefresh(refresh: () => void | Promise<void>) {
  const run = useEffectEvent(refresh);
  useEffect(() => {
    let running = false;
    const reload = async () => {
      if (running || document.visibilityState === "hidden" || !navigator.onLine) return;
      running = true;
      try { await run(); } finally { running = false; }
    };
    const timer = window.setInterval(() => void reload(), 15_000);
    const listener = () => void reload();
    for (const name of ["focus", "pageshow", "online"]) window.addEventListener(name, listener);
    document.addEventListener("visibilitychange", listener);
    return () => {
      window.clearInterval(timer);
      for (const name of ["focus", "pageshow", "online"]) window.removeEventListener(name, listener);
      document.removeEventListener("visibilitychange", listener);
    };
  }, []);
}
