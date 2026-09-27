import { renderNewsletter } from "@/lib/editorial/mail";
import { z } from "zod";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import {
  apiFailure,
  apiSuccess,
  ApiError,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";
import {
  articleSchema,
  audienceSchema,
  campaignSchema,
  channels,
  ctaSchema,
  uuid,
} from "@/lib/editorial/content";
import { editorialEnabled, editorialError } from "@/lib/editorial/server";
const placement = z
  .object({
    channel: z.enum(channels),
    listed: z.boolean(),
    featured: z.boolean(),
    startsAt: z.string().datetime(),
    endsAt: z.string().datetime().nullable(),
    pushAt: z.string().datetime().nullable(),
    cta: ctaSchema.nullable(),
  })
  .strict();
const commandSchema = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("saveNews"),
    id: uuid.nullable(),
    revision: z.number().int().min(0),
    slug: z
      .string()
      .regex(/^[a-z0-9]+(-[a-z0-9]+)*$/)
      .max(100),
    content: articleSchema,
    planning: z
      .record(
        z.enum(channels),
        z
          .object({
            enabled: z.boolean(),
            listed: z.boolean(),
            featured: z.boolean(),
            starts: z.string().max(30),
            ends: z.string().max(30),
            push: z.enum(["none", "publish", "later"]),
            pushTime: z.string().max(30),
            cta: ctaSchema.nullable(),
          })
          .strict(),
      )
      .optional(),
  }),
  z.object({
    action: z.literal("publishNews"),
    versionId: uuid,
    placements: z.array(placement).min(1).max(3),
  }),
  z.object({ action: z.literal("archiveNews"), id: uuid }),
  z.object({
    action: z.literal("pushPreview"),
    channels: z.array(z.enum(channels)).max(3),
  }),
  z.object({
    action: z.literal("saveCampaign"),
    id: uuid.nullable(),
    revision: z.number().int().min(0),
    content: campaignSchema,
    audience: audienceSchema,
    ready: z.boolean(),
  }),
  z.object({ action: z.literal("audience"), audience: audienceSchema }),
  z.object({ action: z.literal("previewCampaign"), versionId: uuid }),
  z.object({ action: z.literal("testCampaign"), versionId: uuid, key: uuid }),
  z.object({
    action: z.literal("scheduleCampaign"),
    versionId: uuid,
    at: z.string().datetime(),
    count: z.number().int().min(0),
  }),
  z.object({ action: z.literal("cancelCampaign"), id: uuid }),
  z.object({
    action: z.literal("category"),
    id: uuid.nullable(),
    name: z.string().trim().min(1).max(60),
    active: z.boolean(),
    sort: z.number().int().min(0).max(1000),
  }),
  z.object({
    action: z.literal("retry"),
    id: uuid,
    kind: z.enum(["mail", "push"]),
  }),
]);
async function clientForEditor() {
  if (!editorialEnabled())
    throw new ApiError(404, "NOT_FOUND", "Niet gevonden.");
  if (!(await getActor()))
    throw new ApiError(401, "LOGIN_REQUIRED", "Log opnieuw in.");
  const client = await createClient();
  if (!client)
    throw new ApiError(
      503,
      "UNAVAILABLE",
      "De Redactiekamer is even niet bereikbaar.",
    );
  return client.schema("api");
}
export async function GET(request: Request) {
  try {
    const client = await clientForEditor();
    const { data, error } = await client.rpc("admin_editorial_snapshot", {
      _event_slug: serverEnv().EVENT_SLUG,
    });
    if (error) throw editorialError(error);
    return apiSuccess({
      ...data,
      sending: {
        email: serverEnv().NEWSLETTER_SENDING_ENABLED === "true",
        push: serverEnv().WEB_PUSH_SENDING_ENABLED === "true",
      },
    });
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const client = await clientForEditor();
    if (Number(request.headers.get("content-length")) > 150000)
      throw new ApiError(413, "TOO_LARGE", "Dit bericht is te groot.");
    const text = await request.text();
    if (text.length > 150000)
      throw new ApiError(413, "TOO_LARGE", "Dit bericht is te groot.");
    const command = commandSchema.parse(JSON.parse(text));
    const event = { _event_slug: serverEnv().EVENT_SLUG };
    let rpc: string;
    let args: Record<string, unknown>;
    switch (command.action) {
      case "saveNews":
        rpc = "admin_news_save";
        args = {
          ...event,
          _id: command.id,
          _expected_revision: command.revision,
          _slug: command.slug,
          _content: command.content,
          _planning: command.planning ?? {},
        };
        break;
      case "publishNews":
        rpc = "admin_news_publish";
        args = {
          _version_id: command.versionId,
          _placements: command.placements,
        };
        break;
      case "archiveNews":
        rpc = "admin_news_archive";
        args = { _id: command.id };
        break;
      case "pushPreview":
        rpc = "admin_news_push_preview";
        args = { ...event, _channels: command.channels };
        break;
      case "saveCampaign":
        rpc = "admin_newsletter_save";
        args = {
          ...event,
          _id: command.id,
          _expected_revision: command.revision,
          _content: command.content,
          _audience: command.audience,
          _ready: command.ready,
        };
        break;
      case "audience":
        rpc = "admin_newsletter_audience";
        args = { ...event, _definition: command.audience };
        break;
      case "previewCampaign":
        rpc = "admin_newsletter_preview";
        args = { _version: command.versionId };
        break;
      case "testCampaign":
        if (serverEnv().NEWSLETTER_SENDING_ENABLED !== "true")
          throw new ApiError(
            409,
            "SENDING_DISABLED",
            "Nachtpost verzenden staat uit.",
          );
        rpc = "admin_newsletter_test";
        args = { _version: command.versionId, _key: command.key };
        break;
      case "scheduleCampaign":
        rpc = "admin_newsletter_schedule";
        args = {
          _version: command.versionId,
          _at: command.at,
          _expected_count: command.count,
        };
        break;
      case "cancelCampaign":
        rpc = "admin_newsletter_cancel";
        args = { _id: command.id };
        break;
      case "category":
        rpc = "admin_editorial_category";
        args = {
          ...event,
          _id: command.id,
          _name: command.name,
          _active: command.active,
          _sort: command.sort,
        };
        break;
      case "retry":
        rpc = "admin_editorial_retry";
        args = { _id: command.id, _kind: command.kind };
        break;
    }
    const { data, error } = await client.rpc(rpc, args);
    if (error) throw editorialError(error);
    if (command.action === "previewCampaign") {
      const snapshot = await client.rpc("admin_editorial_snapshot", event);
      if (snapshot.error) throw editorialError(snapshot.error);
      const campaign = snapshot.data.campaigns.find(
        (c: { versionId: string }) => c.versionId === command.versionId,
      );
      if (!campaign)
        throw new ApiError(404, "NOT_FOUND", "Campagne niet gevonden.");
      const { html } = renderNewsletter(
        {
          content: { ...campaign.content, newsCards: data.cards },
          recipientId: null,
          eventId: snapshot.data.eventId,
          versionId: command.versionId,
          test: true,
        },
        true,
      );
      return apiSuccess({ ...data, html });
    }
    return apiSuccess(data);
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
