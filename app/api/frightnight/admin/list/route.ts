import { z } from "zod";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightSnapshot, rpcError, smallJson } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
const input = z.object({
  resource: z.enum(["zones", "registrations", "payments", "audit", "incidents", "bookings", "parties", "sink", "content", "announcements"]),
  cursor: z.coerce.number().int().min(0).max(100_000).default(0), limit: z.coerce.number().int().min(1).max(100).default(50),
  search: z.string().trim().max(120).default(""), status: z.string().regex(/^[a-z_]{1,40}$/).optional(),
  routeType: z.enum(["lantern", "roots"]).optional(),
  paymentStatus: z.enum(["unpaid", "open", "paid", "failed", "cancelled", "expired", "refunded"]).optional(),
}).strict();
async function list(values: unknown) {
  const snapshot = await frightnightSnapshot();
  const { resource, cursor, limit, search, status, routeType, paymentStatus } = input.parse(values);
  const client = await createClient();
  const { data, error } = await client!.schema("api").rpc("frightnight_admin_list", { p_slug: snapshot.event.slug, p_resource: resource, p_cursor: cursor, p_limit: limit, p_search: search, p_filters: { ...(status ? { status } : {}), ...(routeType ? { routeType } : {}), ...(paymentStatus ? { paymentStatus } : {}) } });
  if (error) rpcError(error);
  return apiSuccess(data);
}
export async function GET(request: Request) {
  try {
    const query = new URL(request.url).searchParams;
    return await list(Object.fromEntries(["resource", "cursor", "limit", "search", "status", "routeType", "paymentStatus"].filter(key => query.has(key) && query.get(key) !== "").map(key => [key, query.get(key)])));
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function POST(request: Request) {
  try { assertTrustedOrigin(request); return await list(await smallJson(request)); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
