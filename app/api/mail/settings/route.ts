import { z } from "zod";
import { simulatedTestRecipient } from "@/supabase/functions/send-email-hook/testing";
import { mailAdmin, publicMailSettings, checkMailConfig } from "@/lib/mail/admin";
import { apiSuccess, apiFailure, assertTrustedOrigin, correlationId, ApiError, requireIdempotencyKey } from "@/lib/http/api";
import { mailAllowlist } from "@/lib/config/server-env";
import type { MailSettingsSnapshot } from "@/lib/mail/admin-types";
import { boundedBody } from "@/lib/http/bounded-body";
export const runtime = "nodejs";
const draftSchema = z.object({ provider: z.literal("resend"), fromName: z.string().trim().min(1).max(120).regex(/^[^\r\n<>]+$/), fromEmail: z.string().trim().email().max(320), replyTo: z.string().trim().email().max(320) }).strict();
const commandSchema = z.object({ command: z.enum(["save", "check", "activate", "test"]), expectedRevision: z.number().int().nonnegative(), configId: z.string().uuid().optional(), draft: draftSchema.optional(), confirmed: z.boolean().optional(), recipient: z.string().email().max(320).optional() }).strict();
export async function GET(request: Request) {
  try { const { snapshot } = await mailAdmin(); return apiSuccess(publicMailSettings(snapshot)); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const { client, args, snapshot } = await mailAdmin();
    const command = commandSchema.parse(JSON.parse(await boundedBody(request, 8000)));
    if (command.expectedRevision !== snapshot.revision) throw new ApiError(409, "CONFIG_VERSION_CONFLICT", "De configuratie is gewijzigd. Vernieuw het overzicht.");
    if (command.command === "test") {
      if (command.confirmed !== true || !command.recipient || !mailAllowlist().has(command.recipient.toLowerCase()) && !simulatedTestRecipient(command.recipient)) throw new ApiError(403, "TEST_RECIPIENT_NOT_ALLOWED", "Bevestig een ontvanger op de runtime-testlijst.");
      if ((snapshot.draft ?? snapshot.active).provider !== "resend") throw new ApiError(409, "RESEND_NOT_ACTIVE", "Sla eerst een Resend-concept op en voer de servercontrole uit.");
      const key = requireIdempotencyKey(request);
      if (!/^[a-zA-Z0-9_-]{8,100}$/.test(key)) throw new ApiError(422, "INVALID_TEST_KEY", "Ongeldige testsleutel.");
      const queued = await client.schema("api").rpc("mail_admin_test", { ...args, _expected_revision: snapshot.revision, _recipient: command.recipient.toLowerCase(), _command_key: key });
      if (queued.error) throw new ApiError(409, "TEST_COMMAND_CONFLICT", "De testopdracht kon niet worden ingepland. Vernieuw het overzicht.");
      return apiSuccess({ outboxId: queued.data, accepted: false, queued: true, simulated: /@resend\.dev$/i.test(command.recipient), deliveryStatus: "pending" });
    }
    let check: unknown = null;
    const config = snapshot.draft ?? snapshot.active;
    if (command.command === "save" && !command.draft) throw new ApiError(422, "DRAFT_REQUIRED", "Vul de afzendergegevens in.");
    if (command.command === "activate" && command.confirmed !== true) throw new ApiError(422, "CONFIRMATION_REQUIRED", "Bevestig de impact van activering.");
    if (["check", "activate"].includes(command.command)) {
      if (command.configId !== config.id) throw new ApiError(409, "CONFIG_VERSION_CONFLICT", "Controleer de nieuwste configuratie.");
      check = await checkMailConfig(config);
      // Activation repeats external checks; an earlier green result alone is
      // insufficient after credential rotation or a DNS/configuration change.
      if (command.command === "activate") {
        if (!(check as { ready: boolean }).ready) throw new ApiError(409, "CONFIG_NOT_READY", "De actuele providercontrole is niet geslaagd.");
        const checked = await client.schema("api").rpc("mail_admin_command", { ...args, _command: "check", _expected_revision: snapshot.revision, _config_id: config.id, _check: check });
        if (checked.error) throw new ApiError(409, "CONFIG_VERSION_CONFLICT", "De configuratie is intussen gewijzigd.");
        check = { confirmed: true };
      }
    }
    const stored = await client.schema("api").rpc("mail_admin_command", { ...args, _command: command.command, _expected_revision: command.expectedRevision, _config_id: command.configId ?? null, _draft: command.draft ?? null, _check: check });
    if (stored.error) {
      const reasons: Record<string, string> = { SUPPRESSION_IMPORT_REQUIRED: "Bevestig eerst de volledige SendGrid-suppressie-import via de beveiligde deploymentvoorziening.", VERIFIED_DRAFT_TEST_REQUIRED: "Verstuur eerst bewust een concepttest en wacht op een geldige afleverwebhook met de huidige credentials.", CONFIG_CHECK_REQUIRED: "Voer eerst de actuele servercontrole van dit concept uit." };
      const safeReason = reasons[stored.error.message];
      if (safeReason) throw new ApiError(409, stored.error.message, safeReason);
      const conflict = stored.error.code === "40001";
      throw new ApiError(409, conflict ? "CONFIG_VERSION_CONFLICT" : "MAIL_COMMAND_BLOCKED", conflict ? "De configuratie is gewijzigd. Vernieuw het overzicht." : "Activering vereist actuele controles en een bevestigde suppressie-import.");
    }
    return apiSuccess(publicMailSettings(stored.data as MailSettingsSnapshot));
  } catch (error) {
    if (error instanceof RangeError) return apiFailure(new ApiError(413, "BODY_TOO_LARGE", "Het verzoek is te groot."), requestId);
    return apiFailure(error, requestId);
  }
}
