"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { startSnapshotPolling } from "@/lib/realtime/snapshot-polling";
import { retryAfterMs } from "@/lib/poortenboek/snapshot-response";
import { eveningClosureResponse, isEveningClosureSnapshot, type EveningClosureSnapshot } from "@/lib/event-evening/types";

/** One bounded read, including body parsing; mutations never share its signal. */
export function useClosureSnapshot({ eventSlug, eventId, scope, enabled = true, poll = false }: {
  eventSlug: string; eventId?: string; scope: "admin" | "participant"; enabled?: boolean; poll?: boolean;
}) {
  const [snapshot, setSnapshot] = useState<EveningClosureSnapshot | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const generation = useRef(0);
  const invalidate = useCallback(() => { generation.current++; }, []);
  const denied = useRef(false);
  const failures = useRef(0);
  const nextReadAt = useRef(0);
  const mounted = useRef(false);
  const request = useRef<{ controller: AbortController; promise: Promise<EveningClosureSnapshot | null> } | null>(null);
  const replace = useCallback((next: EveningClosureSnapshot) => {
    generation.current++;
    failures.current = 0; nextReadAt.current = 0;
    if (mounted.current) { setSnapshot(next); setError(""); }
  }, []);
  const load = useCallback((): Promise<EveningClosureSnapshot | null> => {
    if (!enabled || denied.current || !mounted.current || document.visibilityState === "hidden" || !navigator.onLine) return Promise.resolve(null);
    if (request.current) return request.current.promise;
    if (Date.now() < nextReadAt.current) return Promise.resolve(null);
    const identity = generation.current;
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 8_000);
    setLoading(true);
    const promise = (async () => {
      try {
        const response = await fetch(`/api/event-evening/closure?${new URLSearchParams({ eventSlug, scope })}`, { cache: "no-store", signal: controller.signal });
        if (!response.ok) {
          if (response.status === 429) nextReadAt.current = Date.now() + (retryAfterMs(response.headers.get("Retry-After")) ?? 30_000);
          if (response.status === 401 || response.status === 403) {
            denied.current = true;
            if (mounted.current && identity === generation.current) setSnapshot(null);
            throw new Error("Je toegang kon niet worden bevestigd. Log opnieuw in of laat je evenementrol controleren.");
          }
          throw new Error("De actuele afsluitstatus kon niet worden opgehaald. Probeer opnieuw.");
        }
        const next = eveningClosureResponse(await response.json());
        if (!isEveningClosureSnapshot(next, eventSlug, eventId)) throw new Error("De afsluitstatus hoort niet bij dit evenement. Vernieuw de pagina.");
        if (!controller.signal.aborted && mounted.current && identity === generation.current) { failures.current = 0; nextReadAt.current = 0; setSnapshot(next); setError(""); return next; }
      } catch (failure) {
        if (mounted.current && identity === generation.current && document.visibilityState !== "hidden") {
          const delay = Math.min(30_000, 5_000 * 2 ** Math.min(failures.current++, 3) + Math.random() * 500);
          nextReadAt.current = Math.max(nextReadAt.current, Date.now() + delay);
          setError(controller.signal.aborted ? "De statuscontrole duurde te lang. Probeer over enkele ogenblikken opnieuw." : failure instanceof Error ? failure.message : "De afsluitstatus kon niet worden opgehaald.");
        }
      } finally {
        clearTimeout(timer);
        if (request.current?.controller === controller) request.current = null;
        if (mounted.current) setLoading(false);
      }
      return null;
    })();
    request.current = { controller, promise };
    return promise;
  }, [enabled, eventSlug, eventId, scope]);
  useEffect(() => {
    mounted.current = true;
    denied.current = false;
    failures.current = 0; nextReadAt.current = 0;
    invalidate();
    const timer = window.setTimeout(() => void load(), 0);
    const abortHidden = () => { if (document.visibilityState === "hidden") request.current?.controller.abort(); };
    document.addEventListener("visibilitychange", abortHidden);
    const stop = enabled && poll ? startSnapshotPolling(load, 30_000) : undefined;
    return () => {
      mounted.current = false;
      invalidate();
      clearTimeout(timer);
      stop?.();
      document.removeEventListener("visibilitychange", abortHidden);
      request.current?.controller.abort();
      request.current = null;
    };
  }, [load, enabled, poll, invalidate]);
  return { snapshot, error, loading, load, replace };
}
