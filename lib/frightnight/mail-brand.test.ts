import { describe, expect, it } from "vitest";
import { renderAuthMail } from "@/supabase/functions/send-email-hook/auth-template";
describe("editiegebonden FrightNight Authmail", () => {
  const input = { template: "auth_otp" as const, token: "123456", siteUrl: "https://staging-halloween.duindorpdoet.nl", supportEmail: "halloween@duindorpdoet.nl" };
  it("brandeert alleen de expliciet gekozen nieuwe testeditie", () => {
    const result = renderAuthMail({ ...input, brand: "frightnight-2027" });
    expect(result.subject).toBe("Je code voor FrightNight 2027"); expect(result.html).toContain("/frightnight/logo.png"); expect(result.html).toContain("#081712");
    expect(result.html).not.toContain("Poorten"); expect(result.subject).not.toContain(input.token); expect(result.preheader).not.toContain(input.token);
    expect(renderAuthMail(input).subject).toContain("Duindorpse Poorten");
  });
});
