import "server-only";
import { ApiError } from "@/lib/http/api";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import type { NewsChannel, NewsItem } from "./content";
export const editorialPrivateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
  "X-Robots-Tag": "noindex, nofollow",
  "Referrer-Policy": "no-referrer",
};
const errors: Record<string, string> = {
  NOT_AUTHORIZED: "Je hebt geen toegang tot deze actie.",
  STALE_VERSION: "Dit concept is intussen gewijzigd. Vernieuw de pagina.",
  AUDIENCE_CHANGED:
    "De ontvangerselectie is gewijzigd. Controleer het nieuwe voorbeeld.",
  HERO_REQUIRED: "Kies vóór publicatie een hoofdafbeelding met alt-tekst.",
  MEDIA_IN_USE:
    "Deze afbeelding is nog in gebruik en kan niet worden verwijderd.",
  TEST_MAIL_REQUIRED:
    "Verstuur eerst een testmail van deze versie en wacht op het verzendresultaat.",
  CAMPAIGN_FROZEN:
    "Deze campagne is bevroren. Dupliceer haar voor wijzigingen.",
  NEWS_NOT_PUBLISHED:
    "Een geselecteerde nieuwsversie is niet meer gepubliceerd.",
  PUBLISHED_SLUG_IMMUTABLE:
    "De link van een gepubliceerd bericht blijft behouden.",
  RETRY_NOT_SAFE:
    "Deze verzending kan niet veilig automatisch worden herhaald. Controleer eerst het providerresultaat.",
};
export function editorialError(error: { message?: string; code?: string }) {
  if (error.code === "23505")
    return new ApiError(
      409,
      "ALREADY_EXISTS",
      "Deze link of naam bestaat al. Kies een andere.",
    );
  const code = Object.keys(errors).find((key) => error.message?.includes(key));
  return new ApiError(
    error.code === "42501" ? 403 : 409,
    code ?? "EDITORIAL_ACTION_FAILED",
    code
      ? errors[code]
      : "Controleer de inhoud en publicatie-instellingen. De actie kon niet worden uitgevoerd.",
  );
}
export function editorialEnabled() {
  return serverEnv().REDACTIEKAMER_ENABLED === "true";
}
export function editorialAllowlist() {
  return new Set(
    serverEnv()
      .EDITORIAL_ALLOWED_RECIPIENTS.split(",")
      .map((v) => v.trim().toLowerCase())
      .filter(Boolean),
  );
}
export async function newsFeed(
  channel: NewsChannel,
  slug?: string,
  offset = 0,
): Promise<NewsItem[]> {
  const client = await createClient();
  if (!client) return [];
  const { data, error } = await client.schema("api").rpc("news_feed", {
    _event_slug: serverEnv().EVENT_SLUG,
    _channel: channel,
    _slug: slug ?? null,
    _offset: offset,
  });
  if (error) return [];
  return (data ?? []) as NewsItem[];
}
