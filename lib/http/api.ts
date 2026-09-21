import { NextResponse } from "next/server";
import { ZodError } from "zod";
import { allowedOrigins } from "@/lib/config/server-env";

export class ApiError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}

export function assertTrustedOrigin(request: Request) {
  const origin = request.headers.get("origin");
  if (!origin || !allowedOrigins().has(new URL(origin).origin)) {
    throw new ApiError(403, "ORIGIN_NOT_ALLOWED", "Dit verzoek komt niet van een toegestane omgeving.");
  }
}

export function correlationId(request: Request) {
  return request.headers.get("x-request-id")?.slice(0, 100) || crypto.randomUUID();
}

export function requireIdempotencyKey(request: Request) {
  const key = request.headers.get("idempotency-key")?.trim();
  if (!key || key.length < 8 || key.length > 100) throw new ApiError(400, "IDEMPOTENCY_KEY_REQUIRED", "Een geldige idempotency-sleutel ontbreekt.");
  return key;
}

export function apiSuccess<T>(data: T, status = 200) {
  return NextResponse.json({ data }, { status, headers: { "Cache-Control": "private, no-store" } });
}

export function apiFailure(error: unknown, requestId: string) {
  if (error instanceof ApiError) {
    return NextResponse.json({ error: { code: error.code, message: error.message, requestId } }, { status: error.status });
  }
  if (error instanceof ZodError) {
    return NextResponse.json({ error: { code: "VALIDATION_ERROR", message: "Controleer de gemarkeerde velden.", requestId, fields: error.flatten().fieldErrors } }, { status: 422 });
  }
  console.error("api_error", { requestId, name: error instanceof Error ? error.name : "unknown" });
  return NextResponse.json({ error: { code: "INTERNAL_ERROR", message: "Dat ging niet goed. Probeer het later opnieuw.", requestId } }, { status: 500 });
}
