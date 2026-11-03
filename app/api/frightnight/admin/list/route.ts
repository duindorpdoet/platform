import { z } from "zod";
import { apiFailure, apiSuccess, correlationId } from "@/lib/http/api";
import { frightnightSnapshot, rpcError } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    const query = new URL(request.url).searchParams;
    const resource = z.enum(["zones", "registrations", "payments", "audit", "incidents", "bookings", "parties", "sink", "content"]).parse(query.get("resource"));
    const cursor = z.coerce.number().int().min(0).max(1_000_000).parse(query.get("cursor") ?? "0");
    const limit = z.coerce.number().int().min(1).max(100).parse(query.get("limit") ?? "50");
    const client = await createClient();
    const { data, error } = await client!.schema("api").rpc("frightnight_admin_list", { p_slug: snapshot.event.slug, p_resource: resource, p_cursor: cursor, p_limit: limit });
    if (error) rpcError(error);
    return apiSuccess(data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
