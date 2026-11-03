import { beforeEach, describe, expect, it, vi } from "vitest";
const calls = vi.hoisted(() => ({ snapshot: vi.fn(), command: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", () => ({ frightnightSnapshot: calls.snapshot, frightnightCommand: calls.command, frightnightActor: async () => ({ userId: "actor" }) }));
vi.mock("qrcode", () => ({ default: { toString: async () => "<svg></svg>" } }));
import { GET } from "@/app/api/frightnight/qr/route";
const event = { slug: "frightnight-2027-test", runId: "run", seedVersion: 1 };
const snapshot = { event, ownZones: [], zones: [], registration: null as { id: string } | null };
beforeEach(() => {
  vi.resetAllMocks();
  calls.snapshot.mockResolvedValue(snapshot);
  calls.command.mockImplementation(async () => ({ result: { code: "a-valid-export-code-at-least-sixteen-long" }, snapshot }));
});
async function exportKey() {
  const response = await GET(new Request("https://staging-halloween.duindorpdoet.nl/api/frightnight/qr?format=svg"));
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  return calls.command.mock.lastCall?.[2];
}
describe("actor- en editiegebonden QR-downloadreceipts", () => {
  it("herhaalt dezelfde download met dezelfde idempotentiesleutel", async () => {
    const first = await exportKey();
    expect(await exportKey()).toBe(first);
  });
  it("gebruikt na een nieuwe eigen inschrijving geen onbevoegde oude receipt", async () => {
    const before = await exportKey();
    calls.snapshot.mockResolvedValue({ ...snapshot, registration: { id: crypto.randomUUID() } });
    expect(await exportKey()).not.toBe(before);
  });
  it("partitioneert een geselecteerde testeditie en een nieuwe testronde", async () => {
    const canonical = await exportKey();
    calls.snapshot.mockResolvedValue({ ...snapshot, event: { ...event, slug: "frightnight-2027-test-copy" } });
    const copy = await exportKey();
    expect(copy).not.toBe(canonical);
    calls.snapshot.mockResolvedValue({ ...snapshot, event: { ...event, runId: "next-run" } });
    expect(await exportKey()).not.toBe(canonical);
  });
});
