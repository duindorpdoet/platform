import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
const session = vi.hoisted(() => vi.fn());
vi.mock("@/lib/supabase/proxy", () => ({ updateSession: session }));
import { proxy } from "@/proxy";
afterEach(() => { vi.unstubAllEnvs(); vi.resetAllMocks(); });
describe("publieke festivalpagina tijdens backenduitval", () => {
  it("rendert de publieke shell, noodinformatie en beelden zonder Authverzoek", async () => {
    vi.stubEnv("FRIGHTNIGHT_ENABLED", "true");
    for (const path of ["/", "/privacy", "/offline.html", "/frightnight/logo.png", "/api/health", "/api/frightnight/public"]) {
      const response = await proxy(new NextRequest(`https://staging-halloween.duindorpdoet.nl${path}`));
      expect(response.status).toBe(200);
    }
    expect(session).not.toHaveBeenCalled();
  });
  it("houdt de echte private ingang en actor-API achter sessieverversing", async () => {
    vi.stubEnv("FRIGHTNIGHT_ENABLED", "true");
    session.mockResolvedValue(new Response(null, { status: 200 }));
    await proxy(new NextRequest("https://staging-halloween.duindorpdoet.nl/nachtpas"));
    await proxy(new NextRequest("https://staging-halloween.duindorpdoet.nl/api/frightnight/command"));
    expect(session).toHaveBeenCalledTimes(2);
  });
});
