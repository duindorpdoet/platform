import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { getActor } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const subscriptionSchema = z.object({
  endpoint: z.string().url().max(2048),
  keys: z.object({
    p256dh: z.string().min(16).max(512),
    auth: z.string().min(8).max(256),
  }),
  deviceLabel: z.string().trim().max(120).optional(),
});

const preferenceSchema = z.object({ enabled: z.boolean() });
const deleteSchema = z.object({ endpoint: z.string().url().max(2048) });

async function authenticatedClient() {
  const actor = await getActor();
  const client = await createClient();
  if (!actor || !client) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in om meldingen te beheren.");
  return client;
}

export async function GET(request: Request) {
  const requestId = correlationId(request);
  try {
    const client = await authenticatedClient();
    const { data, error } = await client.schema("api").rpc("push_subscription_state");
    if (error) throw error;
    return apiSuccess(data);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = subscriptionSchema.parse(await request.json());
    const client = await authenticatedClient();
    const { data, error } = await client.schema("api").rpc("push_subscription_upsert", {
      _endpoint: input.endpoint,
      _p256dh: input.keys.p256dh,
      _auth_secret: input.keys.auth,
      _user_agent: request.headers.get("user-agent"),
      _device_label: input.deviceLabel ?? null,
    });
    if (error) throw error;
    return apiSuccess(data, 201);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}

export async function PATCH(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = preferenceSchema.parse(await request.json());
    const client = await authenticatedClient();
    const { data, error } = await client.schema("api").rpc("push_preference_set", { _enabled: input.enabled });
    if (error) throw error;
    return apiSuccess(data);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}

export async function DELETE(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = deleteSchema.parse(await request.json());
    const client = await authenticatedClient();
    const { data, error } = await client.schema("api").rpc("push_subscription_delete", { _endpoint: input.endpoint });
    if (error) throw error;
    return apiSuccess(data);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
