import { describe, expect, it } from "vitest";
import {
  activityActionLabels,
  activityMessage,
  activitySource,
  normalizeActivity,
} from "@/lib/domain/activity-labels";

describe("activity status labels", () => {
  it.each([
    ["registration.submitted", "registration", "Nieuwe inschrijving ontvangen", "Inschrijving"],
    ["together.join_requested", "registration", "Samenloopverzoek ontvangen", "Inschrijving"],
    ["release.notification_recipient_configured", "event", "Ontvanger voor organisatiemeldingen ingesteld", "Evenement"],
    ["payment.child_published", "child_payment_batch", "Tikkie voor kind verstuurd", "Tikkie voor kind"],
  ])("normalizes %s", (action, source, message, sourceLabel) => {
    expect(normalizeActivity(action, source)).toMatchObject({ message, source: sourceLabel });
  });

  it("keeps every known activity free of technical separators", () => {
    for (const action of Object.keys(activityActionLabels)) {
      expect(activityMessage(action)).not.toMatch(/[._]/);
    }
  });

  it("turns future action and source codes into readable text", () => {
    expect(activityMessage("portal.extra_check_started")).toBe("Poort: Extra controle gestart");
    expect(activitySource("new_resource_type")).toBe("New resource type");
  });

  it("uses a safe label for empty values", () => {
    expect(activityMessage(" ")).toBe("Activiteit bijgewerkt");
    expect(activitySource(" ")).toBe("Systeem");
  });
});
