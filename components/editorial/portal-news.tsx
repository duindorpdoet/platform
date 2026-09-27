"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import type { NewsChannel, NewsItem } from "@/lib/editorial/content";
import { NewsCard } from "./news-view";
export function PortalNews({
  channel,
  compact = false,
}: {
  channel: NewsChannel;
  compact?: boolean;
}) {
  const [items, setItems] = useState<NewsItem[]>([]);
  const [error, setError] = useState("");
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    fetch(`/api/editorial/news?channel=${channel}`, {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (r) => {
        if (!r.ok) throw new Error();
        const body = await r.json();
        setItems(body.data);
        setLoaded(true);
      })
      .catch((cause) => {
        if (cause.name !== "AbortError") {
          setError(
            "Nieuws is even niet bereikbaar. Vernieuw de pagina om opnieuw te proberen.",
          );
          setLoaded(true);
        }
      });
    return () => controller.abort();
  }, [channel]);
  const title =
    channel === "parents"
      ? "Nieuws voor jouw groep"
      : "Nieuws voor jullie poort";
  const base = `/omgeving/nieuws/${channel === "parents" ? "ouders" : "huizen"}`;
  const featured = items.find((item) => item.featured);
  const visible = compact
    ? [
        ...(featured ? [featured] : []),
        ...items.filter((i) => i.id !== featured?.id),
      ].slice(0, 3)
    : items;
  return (
    <section className="editorial-feed" aria-label={title}>
      <div className="editorial-section-heading">
        <div>
          <p className="kicker">Uit de Redactiekamer</p>
          <h2>{title}</h2>
        </div>
        {compact && (
          <Link className="editorial-text-link" href={base}>
            Alle nieuws →
          </Link>
        )}
      </div>
      {!loaded ? (
        <p aria-busy="true">Het nieuws wordt opgehaald…</p>
      ) : error ? (
        <p role="status">{error}</p>
      ) : !items.length ? (
        <p>Hier lees je binnenkort het nieuws van de organisatie.</p>
      ) : (
        <div className="editorial-grid">
          {visible.map((item) => (
            <NewsCard key={item.id} item={item} base={base} />
          ))}
        </div>
      )}
    </section>
  );
}
