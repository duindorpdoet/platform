import { describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import type { SupabaseClient } from "@supabase/supabase-js";
import { processEventEveningBatch } from "./worker";
describe("bounded durable evening fan-out tick", () => {
  it("runs only one small sequential pass per worker, without provider calls or a local retry loop", async () => {
    let active = 0, maximum = 0;
    const rpc = vi.fn(async () => { active++; maximum = Math.max(maximum, active); await Promise.resolve(); active--; return { data: { pending: 1000 }, error: null }; });
    await processEventEveningBatch({ schema: () => ({ rpc }) } as unknown as SupabaseClient);
    expect(maximum).toBe(1);
    expect(rpc.mock.calls).toHaveLength(2);
    expect(rpc).toHaveBeenNthCalledWith(1, "worker_event_closures", { _limit: 10 });
    expect(rpc).toHaveBeenNthCalledWith(2, "worker_house_thanks_fanout", { _limit: 10 });
  });
  it("keeps malformed configuration within the low 1..25 limit", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: {}, error: null });
    const client = { schema: () => ({ rpc }) } as unknown as SupabaseClient;
    await processEventEveningBatch(client, 1000);
    expect(rpc).toHaveBeenCalledWith("worker_event_closures", { _limit: 25 });
    await processEventEveningBatch(client, -100);
    expect(rpc).toHaveBeenCalledWith("worker_event_closures", { _limit: 1 });
    await processEventEveningBatch(client, NaN);
    expect(rpc).toHaveBeenCalledWith("worker_event_closures", { _limit: 10 });
  });
  it("leaves failed durable work for the next cron, continues the other worker and logs no private data", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const rpc = vi.fn().mockResolvedValueOnce({ error: { message: "PRIVATE ACCOUNT", code: "42501" } }).mockRejectedValueOnce(new Error("PRIVATE MAIL"));
      await processEventEveningBatch({ schema: () => ({ rpc }) } as unknown as SupabaseClient);
      expect(rpc).toHaveBeenCalledTimes(2);
      expect(JSON.stringify(logged.mock.calls)).not.toContain("PRIVATE");
    } finally { logged.mockRestore(); }
  });
});
