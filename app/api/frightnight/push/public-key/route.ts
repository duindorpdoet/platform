import { apiSuccess, apiFailure, correlationId } from "@/lib/http/api";
import { frightnightActor, frightnightConfig } from "@/lib/frightnight/server";
export async function GET(request: Request) {
  try {
    await frightnightActor();
    const key = frightnightConfig().NEXT_PUBLIC_VAPID_PUBLIC_KEY;
    return apiSuccess({ available: Boolean(key), key: key ?? null, delivery: "sink", message: "Push is vrijwillig. Staging bewaart je toestemming en abonnement; er worden geen externe pushberichten vanuit testscenario’s verzonden." });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
