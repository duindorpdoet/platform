"use client";
import { useEffect, useRef, useState } from "react";
import { Camera, X } from "lucide-react";
import { useDialogFocus } from "@/lib/ui/use-dialog-focus";

export function ScanDialog({ onCode, onClose, busy, error }: { onCode: (code: string) => Promise<boolean>; onClose: () => void; busy: boolean; error?: string }) {
  const [code, setCode] = useState("");
  const [camera, setCamera] = useState(false);
  const [message, setMessage] = useState("");
  const video = useRef<HTMLVideoElement>(null);
  const submitting = useRef(false);
  const submitRef = useRef(onCode);
  useEffect(() => { submitRef.current = onCode; }, [onCode]);
  useDialogFocus(true, "#fn-scan-dialog", onClose, busy);
  useEffect(() => {
    if (!camera) return;
    const videoElement = video.current;
    let stopped = false;
    let controls: { stop: () => void } | undefined;
    void import("@zxing/browser").then(async ({ BrowserQRCodeReader }) => {
      if (stopped || !video.current) return;
      const reader = new BrowserQRCodeReader();
      controls = await reader.decodeFromConstraints({ video: { facingMode: "environment" }, audio: false }, video.current, async result => {
        if (!result || submitting.current || stopped) return;
        submitting.current = true;
        const text = result.getText(); setCode(text);
        const success = await submitRef.current(text);
        if (success) controls?.stop();
        submitting.current = false;
      });
      if (stopped) controls.stop();
    }).catch(() => { setMessage("De camera is niet beschikbaar of toestemming is geweigerd. Gebruik de code op het bord."); setCamera(false); });
    return () => { stopped = true; controls?.stop(); if (videoElement?.srcObject) (videoElement.srcObject as MediaStream).getTracks().forEach(track => track.stop()); };
  }, [camera]);
  return <div className="fn-modal-backdrop"><section id="fn-scan-dialog" className="fn-modal" role="dialog" aria-modal="true" aria-labelledby="fn-scan-title"><button className="fn-close" aria-label="Scanner sluiten" disabled={busy} onClick={onClose}><X /></button><span className="ui-kicker">Eén scan. Eén volgende bestemming.</span><h2 id="fn-scan-title">SCAN HET LICHT.</h2><p>Scan bij de start of jouw huidige bestemming. De server controleert de editie, bestemming en routeversie.</p>{camera ? <video ref={video} className="fn-camera" autoPlay playsInline muted aria-label="Live camerabeeld voor QR-herkenning" /> : <button className="ui-button fn-camera-start" onClick={() => setCamera(true)}><Camera size={30} /> Open camera</button>}{message && <p role="status" className="fn-error">{message}</p>}{error && <p role="alert" className="fn-error">{error}</p>}<form onSubmit={async event => { event.preventDefault(); if (!busy) await onCode(code); }}><label className="ui-field">Of voer de code van het bord in<input className="ui-input" required maxLength={1200} autoComplete="off" value={code} onChange={event => setCode(event.target.value)} /></label><button className="ui-button primary wide" disabled={busy || !code.trim()}>{busy ? "Server controleert…" : "Controleer code"}</button></form><p className="fn-caption">Geen verbinding? Een scan is pas geldig na serverbevestiging. Het hulppunt op het Duinpad blijft het vaste terugkeerpunt.</p></section></div>;
}
