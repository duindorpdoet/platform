"use client";
import {useEffect,useRef,useState} from "react";
import {QrCode} from "lucide-react";
export function QrScanner({ onResult, onCancel }: { onResult: (value: string) => void; onCancel: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const resultHandler = useRef(onResult);
  const [error, setError] = useState("");
  useEffect(() => { resultHandler.current = onResult; }, [onResult]);
  useEffect(() => {
    let stopped = false;
    let stream: MediaStream | undefined;
    let controls: { stop: () => void } | undefined;
    const preview = video.current;
    function release() {
      controls?.stop();
      stream?.getTracks().forEach((track) => track.stop());
      if (preview) preview.srcObject = null;
    }
    void (async () => {
      try {
        const { BrowserQRCodeReader } = await import("@zxing/browser");
        if (stopped || !preview) return;
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" } } });
        if (stopped) { release(); return; }
        controls = await new BrowserQRCodeReader().decodeFromStream(stream, preview, (result) => {
          if (result && !stopped) { stopped = true; release(); resultHandler.current(result.getText()); }
        });
        if (stopped) release();
      } catch {
        release();
        if (!stopped) setError("Camera niet beschikbaar. Gebruik de korte code.");
      }
    })();
    return () => { stopped = true; release(); };
  }, []);
  return <div className="scanner-overlay" role="dialog" aria-modal="true" aria-label="QR-scanner"><div className="panel scanner-dialog"><QrCode size={28} /><h2>Scan de huidige poort</h2><video ref={video} className="scanner-video" muted playsInline />{error && <p className="form-warning">{error}</p>}<button className="btn outline" onClick={onCancel}>Sluiten</button></div></div>;
}
