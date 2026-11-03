"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import type { FrightnightCommand, FrightnightCommandResult, FrightnightSnapshot } from "@/lib/frightnight/model";
import { clearFestivalPending, queueFestival, readFestival, rememberFestival, verifiedFestivalPending } from "@/lib/frightnight/offline";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";
import { createClient } from "@/lib/supabase/client";

export function useFestival() {
  const [snapshot, setSnapshot] = useState<FrightnightSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [unauthorized, setUnauthorized] = useState(false);
  const [online, setOnline] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);
  const reading = useRef<Promise<void> | null>(null);
  const mutating = useRef(false);
  const pending = useRef<FrightnightCommand | null>(null);
  const errors = useRef(0);
  const actorId = useRef<string | null>(null);
  const identityVersion = useRef(0);
  const restore = useCallback(async () => {
    const identity = identityVersion.current;
    const client = createClient();
    const session = client ? await client.auth.getSession() : null;
    if (identity !== identityVersion.current) return;
    const actor = session?.data.session?.user.id;
    if (!actor) return;
    const stored = readFestival(actor);
    if (stored) {
      const queued = await verifiedFestivalPending(actor);
      if (identity !== identityVersion.current) return;
      actorId.current = actor; setSnapshot(stored.snapshot); setUpdatedAt(new Date(stored.captured));
      pending.current = queued;
      setNotice(stored.pending ? "Bezoek wacht op verbinding en servercontrole. Gebruik Opnieuw proberen na herstel." : "Je ziet eerder ontvangen informatie. Opening en beschikbaarheid kunnen veranderd zijn.");
    }
  }, []);

  const refresh = useCallback(async () => {
    if (reading.current) return reading.current;
    const identity = identityVersion.current;
    const task = (async () => {
      try {
        const response = await fetch("/api/frightnight/snapshot", { cache: "no-store", credentials: "same-origin", signal: AbortSignal.timeout(12000) });
        if (identity !== identityVersion.current) return;
        if (response.status === 401) { clearPrivateSnapshots(); actorId.current = null; pending.current = null; setUnauthorized(true); setSnapshot(null); return; }
        const body = await response.json();
        if (identity !== identityVersion.current) return;
        const data = body.data ?? body;
        if (!response.ok) throw new Error(data.message ?? data.error?.message ?? "De actuele gegevens zijn tijdelijk niet bereikbaar.");
        const next = (data.snapshot ?? data) as FrightnightSnapshot;
        if (actorId.current && actorId.current !== next.actor.id) { clearPrivateSnapshots(); pending.current = null; }
        actorId.current = next.actor.id; rememberFestival(next); setSnapshot(next);
        setUpdatedAt(new Date()); setUnauthorized(false); setError(pending.current ? "Een eerdere actie wacht nog op serverbevestiging. Gebruik Veilig opnieuw proberen om dezelfde opdracht te controleren." : ""); errors.current = 0;
      } catch (cause) { if (identity !== identityVersion.current) return; errors.current++; await restore(); setError(cause instanceof Error ? cause.message : "De verbinding is onderbroken. Je laatste serverbevestiging blijft zichtbaar."); }
      finally { setLoading(false); }
    })();
    reading.current = task;
    await task;
    reading.current = null;
  }, [restore]);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    let active = true;
    const tick = async () => {
      if (!active) return;
      setOnline(navigator.onLine);
      if (navigator.onLine && document.visibilityState === "visible") await refresh(); else if (!navigator.onLine) { await restore(); setLoading(false); }
      if (active) timer = setTimeout(tick, Math.min(120000, 25000 * 2 ** Math.min(errors.current, 2)) + Math.random() * 8000);
    };
    const wake = () => { setOnline(navigator.onLine); if (navigator.onLine && document.visibilityState === "visible") void refresh(); };
    const identity = () => { identityVersion.current++; clearPrivateSnapshots(); actorId.current = null; setSnapshot(null); setUnauthorized(true); pending.current = null; };
    timer = setTimeout(tick, 0);
    window.addEventListener("online", wake); window.addEventListener("offline", wake); document.addEventListener("visibilitychange", wake); window.addEventListener("frightnight:identity-changed", identity);
    return () => { active = false; clearTimeout(timer); window.removeEventListener("online", wake); window.removeEventListener("offline", wake); document.removeEventListener("visibilitychange", wake); window.removeEventListener("frightnight:identity-changed", identity); };
  }, [refresh, restore]);

  const send = useCallback(async (command: FrightnightCommand): Promise<Record<string, unknown> | null> => {
    const identity = identityVersion.current;
    if (mutating.current) return null;
    if (pending.current && pending.current.commandId !== command.commandId) { setError("Een eerdere actie wacht nog op bevestiging. Gebruik Opnieuw proberen om diezelfde opdracht veilig te controleren."); return null; }
    if (!navigator.onLine) {
      const queued = actorId.current ? await queueFestival(actorId.current, command) : false;
      if (identity !== identityVersion.current) return null;
      if (queued) pending.current = command;
      setError(queued ? "Bezoek wacht op verbinding. Er is nog geen bezoek, beloning of nieuwe bestemming bevestigd. Gebruik Opnieuw proberen na herstel." : "Je bent offline. Deze actie kan alleen met een actuele serververbinding."); return null;
    }
    mutating.current = true; setBusy(true); setError(""); setNotice(""); pending.current = command;
    try {
      const response = await fetch("/api/frightnight/command", { method: "POST", credentials: "same-origin", cache: "no-store", headers: { "Content-Type": "application/json" }, body: JSON.stringify(command), signal: AbortSignal.timeout(20000) });
      const body = await response.json();
      if (identity !== identityVersion.current) return null;
      const data = body.data ?? body;
      if (!response.ok || data.ok === false) {
        // A server failure may follow a committed transaction. Retry that same
        // command rather than creating a second payment, reservation or reward.
        if (response.status < 500) {
          pending.current = null;
          if (actorId.current) clearFestivalPending(actorId.current);
        }
        if (response.status === 401) { clearPrivateSnapshots(); setSnapshot(null); setUnauthorized(true); }
        if (response.status === 409) await refresh();
        throw new Error(data.message ?? data.error?.message ?? "Deze actie is niet toegestaan of past niet meer bij de actuele toestand.");
      }
      const result = data as FrightnightCommandResult;
      if (actorId.current) clearFestivalPending(actorId.current);
      if (result.snapshot) { actorId.current = result.snapshot.actor.id; rememberFestival(result.snapshot); setSnapshot(result.snapshot); } else await refresh();
      if (identity !== identityVersion.current) return null;
      pending.current = null; setUpdatedAt(new Date()); setNotice("Opgeslagen en bevestigd door de server.");
      return result.result ?? {};
    } catch (cause) {
      if (identity !== identityVersion.current) return null;
      if (pending.current && actorId.current) await queueFestival(actorId.current, pending.current);
      setError(cause instanceof Error ? cause.message : "Geen serverbevestiging ontvangen. Probeer dezelfde actie veilig opnieuw."); return null;
    }
    finally { mutating.current = false; setBusy(false); }
  }, [refresh]);

  const command = useCallback((operation: string, payload: Record<string, unknown> = {}, expectedVersion?: number) => {
    return send({ commandId: crypto.randomUUID(), operation, payload, ...(expectedVersion === undefined ? {} : { expectedVersion }) });
  }, [send]);
  const retry = useCallback(() => pending.current ? send(pending.current) : refresh(), [send, refresh]);
  return { snapshot, loading, busy, error, notice, unauthorized, online, updatedAt, refresh, command, retry, setNotice };
}
export type FestivalController = ReturnType<typeof useFestival>;
