import { NextResponse } from "next/server";
import { frightnightConfig, frightnightServiceRpc } from "@/lib/frightnight/server";
type PublicContent = { key: string; body: Record<string, unknown>; version: number }[];
let cache: { until: number; content: PublicContent; updatedAt: string } | undefined;
let pending: Promise<void> | undefined;
export const dynamic = "force-dynamic";
export async function GET() {
  try {
    frightnightConfig();
    if (!cache || cache.until < Date.now()) {
      pending ??= (async () => {
        try {
          const content = await Promise.race([
            frightnightServiceRpc("frightnight_public_content", { p_slug: frightnightConfig().EVENT_SLUG }),
            new Promise((_, reject) => setTimeout(() => reject(new Error("PUBLIC_CONTENT_TIMEOUT")), 1800)),
          ]) as PublicContent;
          cache = { until: Date.now() + 60_000, content, updatedAt: new Date().toISOString() };
        } finally { pending = undefined; }
      })();
      try { await pending; } catch { /* Static website remains available, including during database failure. */ }
    }
  } catch { /* Configuration absence is an optional content enhancement failure. */ }
  return NextResponse.json({ data: { content: cache?.content ?? [], updatedAt: cache?.updatedAt ?? null, stale: !cache || cache.until < Date.now() } }, { headers: { "Cache-Control": "public, max-age=60, stale-while-revalidate=600" } });
}
