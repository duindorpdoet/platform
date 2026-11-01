import { z } from "zod";
import { accountClient } from "@/lib/account/server";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { readBoundedJson } from "@/lib/http/bounded-json";
import { serverEnv } from "@/lib/config/server-env";
import { EVENING_CLOSURE_BODY_LIMIT, EVENING_CLOSURE_SUBJECT_LIMIT } from "@/lib/event-evening/defaults";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const slug = z.string().min(1).max(100).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/);
const command = z.discriminatedUnion("action", [
  z.object({ eventSlug: slug, action: z.literal("confirm"), commandId: z.uuid(), subject: z.string().min(1).max(EVENING_CLOSURE_SUBJECT_LIMIT).regex(/^[^\r\n\u0000]+$/).refine(value => Boolean(value.trim())), body: z.string().min(1).max(EVENING_CLOSURE_BODY_LIMIT).refine(value => Boolean(value.trim()) && !value.includes("\u0000")) }).strict(),
  z.object({ eventSlug: slug, action: z.literal("retry_failed") }).strict(),
]);

function eventSlug(value: unknown) {
  const parsed = slug.parse(value);
  if (parsed !== serverEnv().EVENT_SLUG) throw new ApiError(404, "EVENT_NOT_FOUND", "Dit evenement is niet beschikbaar in deze app.");
  return parsed;
}

function rpcError(error: { code?: string; message?: string } | null) {
  if (!error) return;
  if (["PGRST301", "PGRST303"].includes(error.code ?? "")) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in.");
  if (error.code === "42501" || error.message === "NOT_AUTHORIZED") throw new ApiError(403, "NOT_AUTHORIZED", "Je hebt geen toegang tot deze organisatieactie.");
  if (error.code === "22023" || error.message === "INVALID_INPUT") throw new ApiError(422, "INVALID_INPUT", "Controleer het onderwerp en bericht.");
  if (error.message === "EVENT_NOT_FOUND") throw new ApiError(404, "EVENT_NOT_FOUND", "Het evenement is niet gevonden.");
  if (error.message === "CERTIFICATES_NOT_READY") throw new ApiError(409, "CERTIFICATES_NOT_READY", "Sluit de avond eerst bewust af voordat je de certificaten aankondigt.");
  if (error.message === "RATE_LIMITED" || error.code === "P0003") throw new ApiError(429, "RATE_LIMITED", "Wacht even voordat je het opnieuw probeert.");
  throw new ApiError(503, "PORTAL_CERTIFICATE_UNAVAILABLE", "De actuele bevestiging is niet beschikbaar. Controleer de status voordat je opnieuw bevestigt.");
}

function secured(response: Response) {
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.set("Vary", "Cookie");
  response.headers.set("X-Robots-Tag", "noindex, nofollow");
  if (response.status === 429) response.headers.set("Retry-After", "30");
  return response;
}

export async function GET(request: Request) {
  try {
    const event = eventSlug(new URL(request.url).searchParams.get("eventSlug"));
    const { client } = await accountClient();
    const result = await client.schema("api").rpc("portal_certificate_admin_snapshot", { _event_slug: event }).abortSignal(request.signal);
    rpcError(result.error);
    return secured(apiSuccess(result.data));
  } catch (error) { return secured(apiFailure(error, correlationId(request))); }
}

export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = command.parse(await readBoundedJson(request, 96 * 1024));
    const event = eventSlug(input.eventSlug);
    const { client } = await accountClient();
    // This deliberate command must retain its identity after a lost response.
    // Cancellation of a status read never aborts or retries the campaign.
    const result = input.action === "confirm"
      ? await client.schema("api").rpc("portal_certificate_confirm", { _event_slug: event, _subject: input.subject, _body: input.body, _command_id: input.commandId })
      : await client.schema("api").rpc("portal_certificate_retry_failed", { _event_slug: event });
    rpcError(result.error);
    return secured(apiSuccess(result.data));
  } catch (error) { return secured(apiFailure(error, correlationId(request))); }
}
