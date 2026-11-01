"use client";

import { useEffect, useRef, useState } from "react";
import { Download, Share2 } from "lucide-react";
import { registeredPortalImpact, type PortalRoom } from "@/lib/domain/poortkamer";
import { downloadPortalCertificate, portalCertificateDetails, preparePortalCertificate, sharePortalCertificate } from "./portal-certificate";
import s from "./poortkamer.module.css";

export function PortalRegisteredCounts({ room }: { room: Pick<PortalRoom, "registeredImpact"> }) {
  const impact = registeredPortalImpact(room);
  return <div className={s.impactCounts} aria-label="Vooraf geregistreerd">
    <div className={s.metric}><strong>{impact?.registeredGroups ?? "—"}</strong><span>Geregistreerde groepen</span></div>
    <div className={s.metric}><strong>{impact?.registeredChildren ?? "—"}</strong><span>Geregistreerde kids</span></div>
  </div>;
}

export function PortalCertificate({ room }: { room: Pick<PortalRoom, "userId" | "eventId" | "portal" | "eventDate" | "registeredImpact"> }) {
  const details = portalCertificateDetails(room);
  const key = JSON.stringify([room.userId, room.eventId, room.portal.id, details]);
  const [prepared, setPrepared] = useState<{ key: string; file: File } | null>(null);
  const [status, setStatus] = useState<{ key: string; text: string } | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const sharing = useRef(false);
  const generation = useRef(0);
  const detailsJson = JSON.stringify(details);
  useEffect(() => {
    const controller = new AbortController(), current = ++generation.current;
    const payload = JSON.parse(detailsJson) as ReturnType<typeof portalCertificateDetails>;
    if (payload) void preparePortalCertificate(payload, controller.signal).then(file => {
      if (!controller.signal.aborted && current === generation.current) setPrepared({ key, file });
    }).catch(() => {
      if (!controller.signal.aborted && current === generation.current) setStatus({ key, text: "Het certificaat kon niet worden klaargezet. Herlaad de pagina om opnieuw te proberen." });
    });
    return () => { generation.current = current + 1; controller.abort(); };
  }, [key, detailsJson]);
  const file = prepared?.key === key ? prepared.file : null;
  const busy = busyKey === key;
  async function share() {
    if (!file || sharing.current) return;
    sharing.current = true; setBusyKey(key);
    const current = generation.current;
    try {
      const outcome = await sharePortalCertificate(file);
      if (current === generation.current) setStatus({ key, text: outcome === "shared" ? "De deelactie is voltooid." : outcome === "downloaded" ? "Het certificaat is als PNG gedownload." : "Delen geannuleerd." });
    } catch { if (current === generation.current) setStatus({ key, text: "Delen lukte niet. Je kunt het certificaat met Download PNG opslaan." }); }
    finally { sharing.current = false; setBusyKey(prior => prior === key ? null : prior); }
  }
  return <section aria-label="Poortcertificaat" className={s.certificateSection}>
    <div className={s.certificate}>
      <img src="/images/poortkamer-v2/certificates/gate-certificate-background.webp" alt=""/>
      <div><span>Digitaal certificaat</span><strong>Officiële Poort van {details?.year ?? room.eventDate.slice(0, 4)}</strong><small>{room.portal.name} · {room.portal.code}</small>
        <PortalRegisteredCounts room={room}/>
      </div>
    </div>
    <p className={s.muted}>Vooraf geregistreerde groepen en kids voor jullie poort, gebaseerd op de vastgelegde planning.</p>
    <div className={`${s.actions} ${s.certificateActions}`}>
      <button type="button" className={`${s.button} ${s.primary}`} disabled={!file || busy} onClick={() => void share()}><Share2 size={17}/>{busy ? "Delen…" : "Certificaat delen"}</button>
      <button type="button" className={s.button} disabled={!file || busy} onClick={() => { if (file) { downloadPortalCertificate(file); setStatus({ key, text: "Het certificaat is als PNG gedownload." }); } }}><Download size={17}/>Download PNG</button>
    </div>
    {!details && <p className={s.muted}>De geregistreerde aantallen zijn nog niet beschikbaar. Herlaad de pagina om ze op te halen.</p>}
    {status?.key === key && <p role="status">{status.text}</p>}
  </section>;
}
