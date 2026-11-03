import { NextResponse } from "next/server";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export function GET() {
  const env = serverEnv();
  return NextResponse.json({
    status: "ok",
    service: "duindorphalloween",
    environment: env.APP_ENVIRONMENT,
    revision: env.APP_REVISION ?? "development",
    registrationMode: env.REGISTRATION_MODE,
    eventSlug: env.EVENT_SLUG,
    brand: env.FRIGHTNIGHT_ENABLED === "true" ? "frightnight-2027-v7" : "halloween-2026",
    paymentProvider: env.FRIGHTNIGHT_ENABLED === "true" ? env.FRIGHTNIGHT_PAYMENT_PROVIDER : undefined,
  }, { headers: { "Cache-Control": "no-store" } });
}
