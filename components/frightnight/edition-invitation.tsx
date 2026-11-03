"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { ArrowRight, Ticket } from "lucide-react";
import type { FestivalController } from "./client";
const INVITATION_KEY = "frightnight-pending-test-invite";
export function useTestInvitation(initial?: string) {
  const [invitation, setInvitation] = useState(initial ?? "");
  useEffect(() => {
    const read = () => {
      const url = new URL(location.href);
      const fragment = new URLSearchParams(url.hash.slice(1)).get("testinvite");
      let pending: string | null = null;
      try { pending = sessionStorage.getItem(INVITATION_KEY); } catch { /* The original invitation can be reopened after login if browser storage is disabled. */ }
      const next = fragment ?? url.searchParams.get("testinvite") ?? initial ?? pending;
      if (next && next.length <= 10000) {
        try { sessionStorage.setItem(INVITATION_KEY, next); } catch { /* No authorization ever comes from this browser value. */ }
        setInvitation(next);
      }
      if (fragment || url.searchParams.has("testinvite")) {
        if (fragment) url.hash = "";
        url.searchParams.delete("testinvite");
        history.replaceState(null, "", url.pathname + url.search + url.hash);
      }
    };
    const timer = setTimeout(read, 0);
    window.addEventListener("hashchange", read);
    return () => { clearTimeout(timer); window.removeEventListener("hashchange", read); };
  }, [initial]);
  const clear = () => { try { sessionStorage.removeItem(INVITATION_KEY); } catch { /* Optional transient storage. */ } setInvitation(""); };
  return { invitation, clear };
}
export function EditionInvitation({ controller: c, invitation, onClose }: { controller: FestivalController; invitation: string; onClose: () => void }) {
  const [busy, setBusy] = useState(false); const [message, setMessage] = useState("");
  return <section className="fn-panel fn-gate"><Ticket size={33} /><span className="ui-kicker">Een persoonlijke testavond</span><h1>JE BENT UITGENODIGD.</h1><p>Deze link opent een afgeschermde testeditie. Je krijgt alleen toegang tot jouw eigen inschrijving en geen beheerdersrechten of gegevens van andere gezinnen.</p>{c.loading ? <p>We controleren je inlogstatus…</p> : c.unauthorized ? <Link className="ui-button primary" href={`/inloggen?next=${encodeURIComponent(typeof window === "undefined" ? "/nachtpas" : location.pathname + location.search)}`}>Eerst zelf inloggen met e-mailcode <ArrowRight size={16} /></Link> : <form onSubmit={async event => { event.preventDefault(); setBusy(true); setMessage(""); try { const response = await fetch("/api/frightnight/edition", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ invitation, consent: true }) }); const body = await response.json(); if (!response.ok) throw new Error(body.error?.message ?? "Deze testuitnodiging kon niet worden bevestigd."); try { sessionStorage.removeItem(INVITATION_KEY); } catch { /* Optional transient storage. */ } history.replaceState(null, "", "/nachtpas"); location.reload(); } catch (cause) { setMessage(cause instanceof Error ? cause.message : "Maak verbinding en probeer opnieuw."); setBusy(false); } }}><label className="fn-check"><input type="checkbox" required /> Ik wil deelnemen aan deze testeditie en begrijp dat betalingen en ervaringen in testmodus zijn.</label><button className="ui-button primary" disabled={busy}>Open deze testeditie <ArrowRight size={16} /></button></form>}{message && <p className="fn-error" role="alert">{message}</p>}<button type="button" className="ui-button" onClick={onClose} disabled={busy}>Uitnodiging sluiten</button><p className="fn-caption">Een uitnodiging verloopt na acht uur en kan niet worden gebruikt voor een afgesloten editie. Vraag de organisator zo nodig een nieuwe link.</p></section>;
}
