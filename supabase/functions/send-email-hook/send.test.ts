import { describe, expect, it, vi } from "vitest";
import { sendResend, type ResendMessage } from "./resend";
const id = "e07af2b0-ad41-4b87-81f1-6f633c83e87f";
const message: ResendMessage = { from: "De Poorten <mail@example.com>", to: ["recipient@example.com"], reply_to: "reply@example.com", subject: "Test", text: "Tekst", html: "<p>Tekst</p>", tags: [{ name: "message_type", value: "registration_received" }], headers: { "List-Unsubscribe": "<https://example.com/unsubscribe>", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } };
describe("bounded Resend transport", () => {
  it("uses the documented JSON response and preserves the complete individual envelope and stable key", async () => {
    const fetcher = vi.fn().mockResolvedValue(Response.json({ id }));
    expect(await sendResend(message, "mail/outbox/1", "test-key", { fetcher })).toEqual({ status: "accepted", providerId: id });
    const [url, init] = fetcher.mock.calls[0];
    expect(url).toBe("https://api.resend.com/emails");
    expect(init.headers["Idempotency-Key"]).toBe("mail/outbox/1");
    expect(JSON.parse(init.body)).toEqual(message);
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });
  it.each(["not json", "{}", JSON.stringify({id,extra:"x".repeat(9000)}), '{"id":""}', '{"id":"not-a-provider-id"}'])("treats broken success %s as unknown", async body => {
    expect(await sendResend(message, "same-key", "test", { fetcher: vi.fn().mockResolvedValue(new Response(body, { status: 200 })) })).toEqual({ status: "unknown", code: "RESEND_ACCEPTANCE_UNCERTAIN" });
  });
  it.each([[401,"failed"],[403,"failed"],[422,"failed"],[409,"unknown"],[500,"unknown"],[503,"unknown"]])("classifies HTTP %s without exposing provider text", async (status, state) => {
    const sent = await sendResend(message,"same-key","test",{fetcher:vi.fn().mockResolvedValue(new Response("secret token recipient@example.com",{status:status as number}))});
    expect(sent.status).toBe(state); expect(JSON.stringify(sent)).not.toMatch(/secret|recipient@/);
  });
  it("retains bounded retry information for throttling", async () => {
    expect(await sendResend(message,"same-key","test",{fetcher:vi.fn().mockResolvedValue(new Response(null,{status:429,headers:{"retry-after":"120"}}))})).toEqual({status:"deferred",code:"RESEND_RATE_LIMIT",retryAfterSeconds:120});
  });
  it("marks lost responses as unknown and repeats exactly the original key/body", async () => {
    const fetcher=vi.fn().mockRejectedValueOnce(new DOMException("private provider detail","TimeoutError")).mockResolvedValueOnce(Response.json({id}));
    expect((await sendResend(message,"same-key","test",{fetcher})).status).toBe("unknown");
    expect((await sendResend(message,"same-key","test",{fetcher})).status).toBe("accepted");
    expect(fetcher.mock.calls[0][1].body).toBe(fetcher.mock.calls[1][1].body);
    expect(fetcher.mock.calls[0][1].headers).toEqual(fetcher.mock.calls[1][1].headers);
  });
});
