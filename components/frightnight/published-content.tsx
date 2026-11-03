"use client";
import { useEffect, useState } from "react";
import { Bell } from "lucide-react";
type Content = { key: string; body: string | { title?: string; text?: string }; version: number };
export function PublishedContent() {
  const [content, setContent] = useState<Content[]>([]);
  const [stale, setStale] = useState(false);
  useEffect(() => {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 5000);
    void fetch("/api/frightnight/public", { signal: abort.signal }).then(async response => {
      if (!response.ok) return;
      const body = await response.json(); const data = body.data ?? body;
      if (Array.isArray(data.content)) setContent(data.content.filter((item: Content) => item && typeof item.key === "string" && (typeof item.body === "string" || typeof item.body?.text === "string")));
      setStale(data.stale === true);
    }).catch(() => {}).finally(() => clearTimeout(timer));
    return () => { clearTimeout(timer); abort.abort(); };
  }, []);
  if (!content.length) return null;
  const labels: Record<string, string> = { programme: "Het actuele programma", practical: "Goed om te weten", story: "Het verhaal gaat verder", emergency: "Veilig op pad" };
  return <aside className="fn-published" aria-label="Gepubliceerde informatie van de organisatie"><span className="ui-kicker"><Bell size={15} /> Bericht uit het Oogstdorp</span>{content.map(item => <article key={item.key}><h3>{typeof item.body === "object" && item.body.title ? item.body.title : labels[item.key] ?? "Van de organisatie"}</h3><p>{typeof item.body === "string" ? item.body : item.body.text}</p></article>)}{stale && <p className="fn-caption">Dit is de laatst beschikbare organisatie-informatie. De vaste programma- en noodinformatie blijft hierboven beschikbaar.</p>}</aside>;
}
