"use client";
import { useEffect, useRef } from "react";
import type { NewsItem } from "@/lib/editorial/content";
export function NewsInteraction({
  item,
  notificationId,
  subscriptionId,
}: {
  item: NewsItem;
  notificationId?: string;
  subscriptionId?: string;
}) {
  const viewed = useRef<string | null>(null);
  const record = (action: "view" | "click") =>
    fetch("/api/editorial/news", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        versionId: item.versionId,
        channel: item.channel,
        action,
        notificationId,
        subscriptionId,
      }),
      keepalive: true,
    }).catch(() => undefined);
  useEffect(() => {
    if (viewed.current === item.versionId) return;
    viewed.current = item.versionId;
    void fetch("/api/editorial/news", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        versionId: item.versionId,
        channel: item.channel,
        action: "view",
        notificationId,
        subscriptionId,
      }),
      keepalive: true,
    }).catch(() => undefined);
  }, [item.versionId, item.channel, notificationId, subscriptionId]);
  return item.cta ? (
    <a className="btn" href={item.cta.url} onClick={() => void record("click")}>
      {item.cta.label}
    </a>
  ) : null;
}
