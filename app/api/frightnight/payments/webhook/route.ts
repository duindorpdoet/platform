import { z } from "zod";
import { apiSuccess, apiFailure, correlationId } from "@/lib/http/api";
import { paymentWebhook } from "@/lib/frightnight/payment-server";
import { boundedRequestText } from "@/lib/frightnight/request-body";
export async function POST(request: Request) {
  try {
    const text = await boundedRequestText(request, 1024);
    const id = z.string().regex(/^tr_[A-Za-z0-9]{5,60}$/).parse(new URLSearchParams(text).get("id"));
    await paymentWebhook(id);
    return apiSuccess({ received: true });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
