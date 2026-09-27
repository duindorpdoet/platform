import { z } from "zod";
import { channels } from "@/lib/editorial/content";
import { newsFeed, editorialError } from "@/lib/editorial/server";
import {
  apiFailure,
  apiSuccess,
  ApiError,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";
export async function GET(request: Request) {
  const url = new URL(request.url);
  const channel = z
    .enum(channels)
    .safeParse(url.searchParams.get("channel") ?? "website");
  if (!channel.success) return new Response(null, { status: 400 });
  return apiSuccess(
    await newsFeed(
      channel.data,
      undefined,
      Number(url.searchParams.get("offset")) || 0,
    ),
  );
}
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const command = z
      .object({
        versionId: z.string().uuid(),
        channel: z.enum(channels),
        action: z.enum(["view", "click"]),
        notificationId: z.string().uuid().optional(),
        subscriptionId: z.string().uuid().optional(),
      })
      .strict()
      .parse(await request.json());
    const client = await createClient();
    if (!client)
      throw new ApiError(503, "UNAVAILABLE", "Probeer het later opnieuw.");
    const { error } = await client.schema("api").rpc("news_record", {
      _version: command.versionId,
      _channel: command.channel,
      _action: command.action,
    });
    if (error) throw editorialError(error);
    if (command.notificationId && command.subscriptionId)
      await client.schema("api").rpc("news_push_clicked", {
        _notification: command.notificationId,
        _subscription: command.subscriptionId,
      });
    return apiSuccess({ recorded: true });
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
