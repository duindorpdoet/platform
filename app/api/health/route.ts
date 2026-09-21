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
  }, { headers: { "Cache-Control": "no-store" } });
}
