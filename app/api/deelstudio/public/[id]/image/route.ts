import { z } from "zod";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

export const runtime = "nodejs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[a-f0-9]{32}$/.test(id)) return new Response("Niet gevonden", { status: 404 });
  const kind = z.enum(["asset", "opengraph"]).catch("asset").parse(new URL(request.url).searchParams.get("kind"));
  const client = createPrivilegedClient();
  if (!client) return new Response("Niet beschikbaar", { status: 503 });
  const asset = await client.schema("api").rpc("social_share_public_asset", { _public_share_id: id, _kind: kind });
  const path = (asset.data as { path?: string } | null)?.path;
  if (asset.error || !path) return new Response("Niet gevonden", { status: 404 });
  const file = await client.storage.from("social-share-assets").download(path);
  if (file.error) return new Response("Niet gevonden", { status: 404 });
  return new Response(file.data, {
    headers: {
      "Content-Type": "image/png",
      "Content-Disposition": kind === "asset" ? `inline; filename="duindorpse-poorten-deelkaart-${id.slice(0, 8)}.png"` : "inline",
      "Cache-Control": kind === "opengraph" ? "public, max-age=3600, stale-while-revalidate=86400" : "private, max-age=300",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
