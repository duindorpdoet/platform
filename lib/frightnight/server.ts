import "server-only";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { ApiError } from "@/lib/http/api";
import { readBoundedJson } from "@/lib/http/bounded-json";
import type { FrightnightSnapshot } from "./model";
import { activeFrightnightSlug, validTestSlug } from "./edition-context";

export function frightnightConfig() {
  const env = serverEnv();
  if (env.FRIGHTNIGHT_ENABLED !== "true" || env.APP_ENVIRONMENT === "production") {
    throw new ApiError(503, "FRIGHTNIGHT_UNAVAILABLE", "De testeditie is nog niet beschikbaar.");
  }
  if (env.APP_ENVIRONMENT === "staging" && (
    env.FRIGHTNIGHT_PROJECT_REF !== "nocteiuvohesvqbowchw" ||
    new URL(env.NEXT_PUBLIC_SUPABASE_URL ?? "http://invalid").hostname !== `${env.FRIGHTNIGHT_PROJECT_REF}.supabase.co` ||
    new URL(env.APP_URL ?? "http://invalid").hostname !== "staging-halloween.duindorpdoet.nl" ||
    !env.EVENT_SLUG.startsWith("frightnight-2027-")
  )) throw new ApiError(503, "ENVIRONMENT_BINDING", "De testomgeving is niet veilig gekoppeld. Neem contact op met de organisatie.");
  return env;
}

export async function frightnightActor() {
  frightnightConfig();
  const actor = await getActor();
  if (!actor) throw new ApiError(401, "SIGN_IN_REQUIRED", "Log in om je Nachtpas te openen.");
  return actor;
}

export function rpcError(error: { code?: string; message?: string }): never {
  // Only controlled domain errors are suitable for the browser. Never expose SQL details.
  const match = /^(FN_[A-Z_]+)(?::\s*(.*))?$/.exec(error.message ?? "");
  if (match) {
    const code = match[1];
    const status = /FORBIDDEN|UNAUTHORIZED|CAPABILITY/.test(code) ? 403 : /NOT_FOUND/.test(code) ? 404 : 409;
    throw new ApiError(status, code, match[2]?.slice(0, 250) || "Deze actie past niet bij de actuele toestand. Vernieuw je Nachtpas.");
  }
  if (error.code === "42501") throw new ApiError(403, "FORBIDDEN", "Je hebt geen toegang tot deze actie.");
  const messages: Record<string, string> = {
    CONFIRMED_USER_REQUIRED: "Laat deze contactpersoon eerst zelf met een e-mailcode inloggen en het account bevestigen.",
    LAST_EVENT_ADMIN: "De laatste hoofdbeheerder blijft beschermd. Ken eerst een ander bevestigd account hoofdbeheer toe.",
    STALE_VERSION: "De gegevens zijn intussen gewijzigd. Vernieuw de lijst en controleer de actuele gegevens.",
    REFUND_ALREADY_REQUESTED: "Voor deze bestelling wordt al een terugbetaling verwerkt. Vernieuw de betaalstatus.",
    VERSION_CONFLICT: "De tocht is intussen gewijzigd. Vernieuw en gebruik de actuele bestemming.",
    IDEMPOTENCY_CONFLICT: "Deze opdrachtsleutel is al voor een andere actie gebruikt. Vernieuw de pagina.",
    OUTSIDE_ROUTE_WINDOW: "Jullie tocht is alleen beschikbaar binnen het gekozen avondvenster. Het startblok is adviserend.",
    EVENT_PAUSED: "De organisatie heeft alle tochten tijdelijk gepauzeerd. Wacht op het volgende bericht.",
    EDITION_CLOSED: "Deze editie is afgesloten. Je eigen Nachtpas en voortgang blijven beschikbaar.",
    ANSWER_INCORRECT: "Nog niet helemaal! Probeer gerust opnieuw.",
    INVALID_START_CODE: "Deze code hoort niet bij de start van jullie editie.",
    INVALID_ZONE_CODE: "Deze code hoort niet bij jullie actuele bestemming.",
    ACTIVITY_FULL: "Er zijn niet genoeg plaatsen voor jullie hele gezelschap. Kies een ander moment.",
    ACTIVITY_STARTED: "Deze activiteit is al begonnen. Kies een volgend moment.",
    RESERVATION_EXPIRED_RESUME: "Jullie reservering is verlopen. Kies Hervatten om de route veilig opnieuw te beoordelen.",
    ZONE_UNAVAILABLE_RESUME: "Deze zone is niet meer beschikbaar. Kies Hervatten voor een actuele bestemming.",
    PAID_PLACES_REQUIRE_SUPPORT: "Na betaling veranderen personen en tocht via de organisatie; er worden geen extra gratis plaatsen toegevoegd.",
    INVITATION_INVALID: "Deze uitnodiging is verlopen, ingetrokken of al gebruikt. Vraag een nieuwe uitnodiging.",
    PARTY_TOO_LARGE: "Het gezamenlijke gezelschap is te groot. Loop in kleinere gezelschappen.",
    SAME_PAID_ROUTE_REQUIRED: "Samenlopen vereist betaalde inschrijvingen voor hetzelfde avondvenster.",
    WALK_VERIFICATION_REQUIRED: "De wandelverbinding is nog niet gecontroleerd. De organisatie moet deze eerst bevestigen.",
    FINALE_REQUIRED: "Rond eerst de passende finale op het Duinpad af.",
    APPROVAL_REQUIRED: "De organisatie moet deze zone eerst goedkeuren.",
    RESET_BEFORE_RESEED: "Dit scenario bestaat al. Bekijk eerst de resetomvang en bevestig een nieuwe testronde.",
    DESTINATION_CONFLICT: "Deze actie hoort bij een vorige bestemming. Gebruik de actuele serverinformatie.",
  };
  const domainCode = error.message?.split(":")[0] ?? "";
  if (messages[domainCode]) throw new ApiError(409, domainCode, messages[domainCode]);
  if (error.code === "22023" || error.code === "23514" || error.code === "22P02" || error.code === "23502") throw new ApiError(422, "INVALID_COMMAND", "Controleer de ingevulde gegevens en de actuele editie. De actie is niet opgeslagen.");
  if (error.code === "P0001") throw new ApiError(409, "COMMAND_REJECTED", (error.message ?? "De actie is geweigerd.").slice(0, 250));
  if (error.code === "23505" || error.code === "40001" || error.code === "40P01") throw new ApiError(409, "CONCURRENT_CHANGE", "Er is tegelijk iets gewijzigd. Vernieuw en probeer opnieuw.");
  if (error.code === "57014" || error.code === "55P03") throw new ApiError(503, "TEMPORARILY_BUSY", "De server is even druk. Je vorige voortgang blijft bewaard.");
  throw new ApiError(503, "BACKEND_UNAVAILABLE", "Je gegevens zijn tijdelijk niet bereikbaar. Probeer later opnieuw of ga naar het hulppunt op het Duinpad.");
}

export async function frightnightSnapshot(): Promise<FrightnightSnapshot> {
  const actor = await frightnightActor();
  const client = await createClient();
  if (!client) throw new ApiError(503, "BACKEND_UNAVAILABLE", "De server is tijdelijk niet beschikbaar.");
  const { data, error } = await client.schema("api").rpc("frightnight_snapshot", { p_slug: await activeFrightnightSlug(actor.userId) });
  if (error) rpcError(error);
  return data as FrightnightSnapshot;
}

export async function frightnightCommand(operation: string, payload: Record<string, unknown>, commandId: string) {
  const actor = await frightnightActor();
  const client = await createClient();
  if (!client) throw new ApiError(503, "BACKEND_UNAVAILABLE", "De server is tijdelijk niet beschikbaar.");
  const { data, error } = await client.schema("api").rpc("frightnight_command", {
    p_slug: await activeFrightnightSlug(actor.userId), p_command: operation, p_payload: payload, p_key: z.uuid().parse(commandId),
  });
  if (error) rpcError(error);
  return data;
}

export async function frightnightServiceRpc(name: string, args: Record<string, unknown>) {
  const env = frightnightConfig();
  const client = createPrivilegedClient();
  if (!client) throw new ApiError(503, "SERVICE_CONFIGURATION", "De serverconfiguratie is nog niet volledig.");
  const actor = typeof args.p_slug === "string" ? null : await getActor();
  const selected = typeof args.p_slug === "string" ? args.p_slug : actor ? await activeFrightnightSlug(actor.userId) : env.EVENT_SLUG;
  if (!validTestSlug(selected)) throw new ApiError(403, "TEST_SCOPE_REQUIRED", "Ongeldige testeditie.");
  const { data, error } = await client.schema("api").rpc(name, { ...args, p_slug: selected }).abortSignal(AbortSignal.timeout(name === "frightnight_public_content" ? 1600 : 7500));
  if (error) rpcError(error);
  return data;
}

export async function smallJson(request: Request) {
  return readBoundedJson(request, 32_768);
}
