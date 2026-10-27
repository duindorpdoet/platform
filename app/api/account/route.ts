import { z } from "zod";
import { accountClient, accountSnapshot } from "@/lib/account/server";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { readBoundedJson } from "@/lib/http/bounded-json";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";
const command = z.discriminatedUnion("action", [
  z.object({ action: z.literal("remember"), target: z.object({ kind: z.enum(["adult", "child"]), id: z.string().min(1).max(100) }).strict() }).strict(),
  z.object({ action: z.literal("welcome"), version: z.literal(1) }).strict(),
]);
export async function GET(request: Request) {
  try { return apiSuccess(await accountSnapshot()); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = command.parse(await readBoundedJson(request));
    const { client } = await accountClient();
    const result = await client.schema("api").rpc("account_app_command", { _event_slug: serverEnv().EVENT_SLUG, _action: input.action, _payload: "target" in input ? input.target : { version: input.version } });
    if (result.error) throw new ApiError(result.error.code === "42501" ? 403 : 409, "ACCOUNT_COMMAND_REJECTED", "Deze keuze is niet meer beschikbaar. Vernieuw je omgevingen.");
    return apiSuccess(result.data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
