import { apiSuccess, apiFailure, correlationId } from "@/lib/http/api";
import { frightnightSnapshot } from "@/lib/frightnight/server";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  try { return apiSuccess(await frightnightSnapshot()); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
