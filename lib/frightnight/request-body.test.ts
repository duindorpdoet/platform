import { describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import { boundedRequestBytes, boundedRequestText } from "./request-body";

function streamed(chunks: Uint8Array[], cancel = vi.fn()) {
  const body = new ReadableStream<Uint8Array>({ start(controller) { for (const chunk of chunks) controller.enqueue(chunk); }, cancel });
  return { request: new Request("https://example.invalid", { method: "POST", body, duplex: "half" } as RequestInit), cancel };
}
describe("begrensde FrightNight-verzoekinhoud", () => {
  it("weigert een grote chunked body zonder Content-Length en annuleert de stream", async () => {
    const { request, cancel } = streamed([new Uint8Array(6), new Uint8Array(6)]);
    await expect(boundedRequestBytes(request, 10)).rejects.toMatchObject({ status: 413, code: "BODY_TOO_LARGE" });
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("weigert een al aangekondigde overschrijding vóór de body wordt gelezen", async () => {
    const request = new Request("https://example.invalid", { method: "POST", headers: { "Content-Length": "1025" }, body: "id=tr_Test" });
    await expect(boundedRequestBytes(request, 1024)).rejects.toMatchObject({ status: 413 });
    expect(request.bodyUsed).toBe(false);
  });
  it("beëindigt een trage of onafgemaakte stream met een herstelbare408", async () => {
    const { request, cancel } = streamed([new Uint8Array(1)]);
    await expect(boundedRequestBytes(request, 10, 10)).rejects.toMatchObject({ status: 408, code: "BODY_TIMEOUT" });
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("leest geldige inhoud en weigert ongeldige UTF-8", async () => {
    await expect(boundedRequestText(new Request("https://example.invalid", { method: "POST", body: "id=tr_Valid" }), 1024)).resolves.toBe("id=tr_Valid");
    await expect(boundedRequestText(new Request("https://example.invalid", { method: "POST", body: new Uint8Array([0xff]) }), 1024)).rejects.toMatchObject({ status: 400, code: "INVALID_BODY" });
  });
});
