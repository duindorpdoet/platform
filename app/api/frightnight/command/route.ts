import { z } from "zod";
import { apiSuccess, apiFailure, ApiError, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightCommand, smallJson } from "@/lib/frightnight/server";
import { armPaymentSandbox, paymentCheckout, paymentReconcile, paymentRefund, simulatePayment } from "@/lib/frightnight/payment-server";
import { StagingBeaconAdapter } from "@/lib/frightnight/beacon";
import type { FrightnightCommandResult } from "@/lib/frightnight/model";
const input = z.object({ commandId: z.uuid(), operation: z.string().regex(/^[a-z]+(?:\.[a-z_]+)+$/).max(70), payload: z.record(z.string().max(60), z.unknown()).default({}), expectedVersion: z.number().int().nonnegative().optional() }).strict();
export async function POST(request: Request) {
  const requestId = correlationId(request);
  const started = performance.now();
  let operation = "invalid";
  try {
    assertTrustedOrigin(request);
    const command = input.parse(await smallJson(request));
    operation = command.operation;
    let result;
    if (operation === "payment.checkout") result = await paymentCheckout(command.commandId);
    else if (operation === "payment.reconcile") result = await paymentReconcile();
    else if (operation === "test.payment.sandbox") {
      const payload = z.object({ confirmation: z.string().min(1).max(140), runId: z.uuid() }).strict().parse(command.payload);
      result = await armPaymentSandbox(payload.runId, payload.confirmation);
    } else if (operation === "test.payment") {
      const payload = z.object({ status: z.enum(["paid", "failed", "canceled", "expired", "pending", "open"]), registrationId: z.uuid().optional(), scenario: z.enum(["normal", "duplicate", "delayed"]).default("normal") }).strict().parse(command.payload);
      result = await simulatePayment(command.commandId, payload.status, payload.registrationId, payload.scenario);
    } else if (operation === "payment.refund") {
      const payload = z.object({ registrationId: z.uuid(), reason: z.string().trim().min(5).max(250) }).strict().parse(command.payload);
      result = await paymentRefund(command.commandId, payload.registrationId, payload.reason);
    } else {
      result = await frightnightCommand(operation, { ...command.payload, ...(command.expectedVersion === undefined ? {} : { expectedVersion: command.expectedVersion }) }, command.commandId);
      if (operation === "beacon.complete") {
        const confirmed = result as FrightnightCommandResult;
        const acknowledgement = await new StagingBeaconAdapter().receive({ eventId: confirmed.snapshot.event.id, registrationId: confirmed.snapshot.registration!.id, commandId: command.commandId, mode: "finale" });
        result = { ...confirmed, result: { ...confirmed.result, beacon: acknowledgement } };
      }
    }
    console.info("frightnight_command", { requestId, operation, milliseconds: Math.round(performance.now() - started), status: "ok" });
    return apiSuccess(result);
  } catch (error) {
    console.info("frightnight_command", { requestId, operation, milliseconds: Math.round(performance.now() - started), status: "rejected", code: error instanceof ApiError ? error.code : error instanceof z.ZodError ? "VALIDATION_ERROR" : "INTERNAL_ERROR" });
    return apiFailure(error, requestId);
  }
}
