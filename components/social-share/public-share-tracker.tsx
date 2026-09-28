"use client";

import { useEffect } from "react";

export function PublicShareTracker({ publicShareId }: { publicShareId: string }) {
  useEffect(() => {
    const viewedKey = `deelstudio-viewed:${publicShareId}`;
    if (sessionStorage.getItem(viewedKey)) return;
    sessionStorage.setItem(viewedKey, "true");
    const key = "deelstudio-session";
    let sessionId = sessionStorage.getItem(key);
    if (!sessionId) { sessionId = crypto.randomUUID(); sessionStorage.setItem(key, sessionId); }
    void fetch("/api/deelstudio/events", {
      method: "POST", headers: { "Content-Type": "application/json" }, keepalive: true,
      body: JSON.stringify({ publicShareId, eventType: "public_page_viewed", sessionId }),
    });
  }, [publicShareId]);
  return null;
}
