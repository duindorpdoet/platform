import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { apiFailure, ApiError, correlationId } from "@/lib/http/api";
import { frightnightSnapshot, rpcError } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
import { renderFrightnightTransactionalMail } from "@/lib/frightnight/transactional-mail";

let logo: Promise<string> | undefined;
const getLogo = () => logo ??= readFile(join(process.cwd(), "public/frightnight/king-head.webp")).then(bytes => `data:image/webp;base64,${bytes.toString("base64")}`).catch(() => "");
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    if (!snapshot.actor.capabilities.some(capability => capability === "event_admin" || capability === "payments_manage")) throw new ApiError(403, "PAYMENTS_REQUIRED", "Je hebt geen toegang tot deze mailcapture.");
    const query = new URL(request.url).searchParams;
    const id = z.uuid().parse(query.get("id"));
    const client = await createClient();
    if (!client) throw new ApiError(503, "BACKEND_UNAVAILABLE", "Het mailvoorbeeld is tijdelijk niet bereikbaar.");
    const { data, error } = await client.schema("api").rpc("frightnight_admin_list", { p_slug: snapshot.event.slug, p_resource: "sink", p_cursor: 0, p_limit: 100, p_search: id, p_filters: {} });
    if (error) rpcError(error);
    const row = (data as { items?: { id: string; template: string; mode: string; payload: unknown }[] })?.items?.find(item => item.id === id);
    if (!row || row.mode !== "sink") throw new ApiError(404, "MAIL_CAPTURE_NOT_FOUND", "Dit mailvoorbeeld is niet beschikbaar in jouw testeditie.");
    let rendered;
    try { rendered = renderFrightnightTransactionalMail(row.template, row.payload, { eventSlug: snapshot.event.slug, logoDataUri: await getLogo() || undefined }); }
    catch { throw new ApiError(409, "MAIL_CAPTURE_INVALID", "Deze capture past niet bij een ondersteund bericht of bevat ongeldige gegevens."); }
    return new Response(rendered.html, { headers: {
      "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
      "Content-Disposition": `inline; filename="frightnight-testmail-${id}.html"`, "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    } });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
