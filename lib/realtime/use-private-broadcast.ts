"use client";

import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";

// Supabase allows one subscription per topic. Share it across nested screens so
// opening a chat does not disconnect the cockpit or another organizer panel.
export type BroadcastChange = { id?: string; messageId?: number };
type Listener = { refresh: (change?: BroadcastChange) => void; status: (live: boolean) => void };
type Subscription = { listeners: Set<Listener>; dispose: () => void; live: boolean };
const subscriptions = new Map<string, Subscription>();

export function usePrivateBroadcast(topic: string | null | undefined, refresh: (change?: BroadcastChange) => void) {
  const callback = useRef(refresh);
  useEffect(() => { callback.current = refresh; }, [refresh]);
  const [live, setLive] = useState(false);
  useEffect(() => {
    const client = createClient();
    if (!client || !topic) return;
    const listener: Listener = { refresh: (change) => callback.current(change), status: setLive };
    let entry = subscriptions.get(topic);
    if (!entry) {
      let disposed = false;
      let channel: ReturnType<typeof client.channel> | undefined;
      entry = { listeners: new Set(), live: false, dispose: () => {
        disposed = true;
        if (channel) void client.removeChannel(channel);
      } };
      subscriptions.set(topic, entry);
      const current = entry;
      void (async () => {
        const { data } = await client.auth.getSession();
        if (disposed || !data.session) return;
        await client.realtime.setAuth(data.session.access_token);
        if (disposed) return;
        channel = client.channel(topic, { config: { private: true } })
          .on("broadcast", { event: "snapshot_changed" }, (message: { payload: BroadcastChange }) => {
            current.listeners.forEach((item) => item.refresh(message.payload));
          })
          .subscribe((status: string) => {
            if (disposed) return;
            current.live = status === "SUBSCRIBED";
            current.listeners.forEach((item) => item.status(current.live));
            if (current.live) current.listeners.forEach((item) => item.refresh());
          });
      })().catch(() => { if (!disposed) current.listeners.forEach(item => item.status(false)); });
    }
    entry.listeners.add(listener);
    const initial = window.setTimeout(() => setLive(entry.live), 0);
    return () => {
      clearTimeout(initial);
      entry.listeners.delete(listener);
      if (entry.listeners.size === 0) {
        entry.dispose();
        subscriptions.delete(topic);
      }
    };
  }, [topic]);
  return live;
}
