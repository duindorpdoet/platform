import { apiFailure, correlationId } from "@/lib/http/api";
import { frightnightSnapshot } from "@/lib/frightnight/server";
import { emergencyDocument } from "@/lib/frightnight/downloads";
export async function GET(request: Request) {
  try { return new Response(emergencyDocument(await frightnightSnapshot()), { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store", "Content-Disposition": 'attachment; filename="FrightNight-2027-Noodpakket.html"', "X-Content-Type-Options": "nosniff" } }); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
