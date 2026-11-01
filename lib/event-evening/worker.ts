import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

/** One small, sequential fan-out pass. Retries belong to the next cron tick. */
export async function processEventEveningBatch(client: SupabaseClient, limit = 10) {
  const bounded = Number.isInteger(limit) ? Math.max(1, Math.min(25, limit)) : 10;
  for (const rpc of ["worker_event_closures", "worker_house_thanks_fanout"] as const) {
    try {
      const result = await client.schema("api").rpc(rpc, { _limit: bounded });
      if (result.error) {
        console.error("event_evening_fanout_unavailable", { worker: rpc });
      }
    } catch {
      // The durable targets remain pending. Never replay a provider request or
      // interrupt ordinary transactional mail because a fan-out pass failed.
      console.error("event_evening_fanout_unavailable", { worker: rpc });
    }
  }
}
