"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { retryAfterMs } from "@/lib/poortenboek/snapshot-response";
import { eveningClosureResponse } from "@/lib/event-evening/types";
import { validatePortalCertificateSnapshot, type PortalCertificateSnapshot } from "@/lib/event-evening/portal-certificates";

/** A single bounded status read; no periodic polling and no mutation cancellation. */
export function usePortalCertificateStatus(eventSlug: string, eventId: string) {
  const [snapshot, setSnapshot] = useState<PortalCertificateSnapshot | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const generation = useRef(0), mounted = useRef(false), denied = useRef(false), failures = useRef(0), nextReadAt = useRef(0);
  const pendingResume = useRef(false);
  const resumeRead = useRef<() => Promise<PortalCertificateSnapshot | null>>(async () => null);
  const request = useRef<{ identity: number; controller: AbortController; deadline: number; promise: Promise<PortalCertificateSnapshot | null> } | null>(null);
  const invalidate = useCallback(() => { generation.current++; }, []);
  const abortRead = useCallback(() => { if (request.current) { clearTimeout(request.current.deadline); request.current.controller.abort(); } }, []);
  const deny = useCallback(() => {
    denied.current = true; invalidate(); abortRead(); pendingResume.current = false;
    if (mounted.current) { setSnapshot(null); setLoading(false); setError("Je toegang kon niet worden bevestigd. Log opnieuw in of laat je evenementrol controleren."); }
  }, [invalidate, abortRead]);
  const replace = useCallback((value: PortalCertificateSnapshot) => {
    if (!mounted.current || denied.current) return false;
    invalidate(); abortRead(); pendingResume.current = false;
    failures.current = 0; nextReadAt.current = 0;
    setSnapshot(value); setLoading(false); setError(""); return true;
  }, [invalidate, abortRead]);
  const load = useCallback((): Promise<PortalCertificateSnapshot | null> => {
    if (!mounted.current || denied.current || document.visibilityState === "hidden" || navigator.onLine === false || Date.now() < nextReadAt.current) return Promise.resolve(null);
    if (request.current) {
      if (request.current.identity !== generation.current) pendingResume.current = true;
      return request.current.promise;
    }
    const identity = generation.current, controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 8_000);
    setLoading(true);
    const promise = (async () => {
      try {
        const response = await fetch(`/api/event-evening/portal-certificates?${new URLSearchParams({ eventSlug })}`, { cache: "no-store", signal: controller.signal });
        if (response.status === 401 || response.status === 403) { if (mounted.current && identity === generation.current && !controller.signal.aborted) deny(); return null; }
        if (response.status === 429 && mounted.current && identity === generation.current) nextReadAt.current = Date.now() + (retryAfterMs(response.headers.get("Retry-After")) ?? 30_000);
        if (!response.ok) throw new Error();
        const value = validatePortalCertificateSnapshot(eveningClosureResponse(await response.json()), eventSlug, eventId);
        controller.signal.throwIfAborted();
        if (!value) throw new Error();
        if (!controller.signal.aborted && mounted.current && identity === generation.current) {
          failures.current = 0; nextReadAt.current = 0; setSnapshot(value); setError(""); return value;
        }
      } catch {
        if (mounted.current && identity === generation.current && document.visibilityState !== "hidden") {
          nextReadAt.current = Math.max(nextReadAt.current, Date.now() + Math.min(30_000, 5_000 * 2 ** Math.min(failures.current++, 3) + Math.random() * 500));
          setError(controller.signal.aborted ? "De statuscontrole duurde te lang. Probeer over enkele ogenblikken opnieuw." : "De certificaatmailstatus kon niet worden opgehaald. Probeer over enkele ogenblikken opnieuw.");
        }
      } finally {
        clearTimeout(timer);
        if (request.current?.controller === controller) {
          request.current = null;
          if (mounted.current && identity === generation.current) setLoading(false);
          if (pendingResume.current && mounted.current) { pendingResume.current = false; void resumeRead.current(); }
        }
      }
      return null;
    })();
    request.current = { identity, controller, deadline: timer, promise };
    return promise;
  }, [eventSlug, eventId, deny]);
  useEffect(() => {
    mounted.current = true; denied.current = false; failures.current = 0; nextReadAt.current = 0;
    invalidate(); resumeRead.current = load;
    const timer = window.setTimeout(() => void load(), 0);
    const resume = () => {
      if (document.visibilityState === "hidden" || navigator.onLine === false) {
        invalidate(); abortRead();
      } else void load();
    };
    document.addEventListener("visibilitychange", resume);
    for (const name of ["focus", "pageshow", "online", "offline"]) window.addEventListener(name, resume);
    return () => {
      mounted.current = false; invalidate(); clearTimeout(timer); pendingResume.current = false;
      abortRead();
      document.removeEventListener("visibilitychange", resume);
      for (const name of ["focus", "pageshow", "online", "offline"]) window.removeEventListener(name, resume);
    };
  }, [load, invalidate, abortRead]);
  const currentSnapshot = snapshot?.event.id === eventId && snapshot.event.slug === eventSlug ? snapshot : null;
  return { snapshot: currentSnapshot, error, loading, load, replace, deny };
}
