import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearFestivalPending, queueFestival, readFestival, rememberFestival, verifiedFestivalPending } from "./offline";
import type { FrightnightCommand, FrightnightSnapshot } from "./model";
function snapshot() { return { actor: { id: "actor-a", capabilities: ["event_admin"] }, event: { id: "event-a", slug: "frightnight-2027-test" }, registration: { label: "Testgezin" }, journey: { version: 4, party: { members: [{ label: "ander gezin" }] } }, current: { id: "destination-a", zone: { address: "Synthetische testlocatie" } }, progress: { visits: [], awards: [], sparks: 0 }, zones: [{ address: "PRIVE TOEKOMSTIG ADRES" }], registrations: [{ label: "ANDER GEZIN" }], ownZones: [], notifications: [{ message: "Niet nodig offline" }], activities: [], bookings: [], announcements: [], quests: [] } as unknown as FrightnightSnapshot; }
const command: FrightnightCommand = { commandId: "command-a", operation: "journey.complete", expectedVersion: 4, payload: { destinationId: "destination-a", code: "current-zone-code" } };
describe("private offline informatie en beperkte wachtrij", () => {
  afterEach(() => vi.restoreAllMocks());
  beforeEach(() => {
    const data = new Map<string, string>();
    vi.stubGlobal("localStorage", { getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => data.set(key, value), removeItem: (key: string) => data.delete(key) });
    vi.useRealTimers();
  });
  it("bewaart alleen de eigen vrijgegeven informatie zonder beheerrechten of toekomstadressen", () => {
    const value = snapshot(); value.registration!.contactName = "Privécontactpersoon"; value.registration!.contactPhone = "+31612345678";
    rememberFestival(value);
    const stored = readFestival("actor-a")!;
    expect(stored.snapshot.actor.capabilities).toEqual([]); expect(stored.snapshot.zones).toBeUndefined(); expect(stored.snapshot.registrations).toBeUndefined();
    expect(stored.snapshot.notifications).toEqual([]); expect(stored.snapshot.current?.zone.address).toBe("Synthetische testlocatie");
    expect(stored.snapshot.registration?.contactName).toBeUndefined(); expect(stored.snapshot.registration?.contactPhone).toBeUndefined();
    expect(JSON.stringify(stored)).not.toContain("Privécontactpersoon"); expect(JSON.stringify(stored)).not.toContain("+31612345678");
    expect(readFestival("actor-b")).toBeNull();
  });
  it("laat snapshots na dertig minuten vervallen", () => {
    vi.useFakeTimers(); rememberFestival(snapshot()); vi.advanceTimersByTime(31 * 60_000); expect(readFestival("actor-a")).toBeNull(); vi.useRealTimers();
  });
  it("queue alleen actuele bezoekcommand met vaste ID, versie en payloadhash", async () => {
    rememberFestival(snapshot());
    expect(await queueFestival("actor-a", command)).toBe(true);
    expect((await verifiedFestivalPending("actor-a"))?.commandId).toBe("command-a");
    expect(await queueFestival("actor-a", { ...command, commandId: "other-id" })).toBe(false);
    expect(await queueFestival("actor-a", { ...command, operation: "payment.checkout" })).toBe(false);
    expect(await queueFestival("actor-a", { ...command, expectedVersion: 3 })).toBe(false);
    clearFestivalPending("actor-a"); expect(await verifiedFestivalPending("actor-a")).toBeNull();
  });
  it("weigert een gewijzigde opgeslagen payload en een andere identiteit", async () => {
    rememberFestival(snapshot()); await queueFestival("actor-a", command);
    const key = "duindorp-private-group:frightnight-v1:actor-a:frightnight-2027-test";
    const value = JSON.parse(localStorage.getItem(key)!); value.pending.payload.code = "gewijzigd"; localStorage.setItem(key, JSON.stringify(value));
    expect(await verifiedFestivalPending("actor-a")).toBeNull(); expect(await queueFestival("actor-b", command)).toBe(false);
  });
  it("schrijft na wissen tijdens een lopende digest geen oude privégegevens terug", async () => {
    rememberFestival(snapshot());
    let finish!: (value: ArrayBuffer) => void;
    vi.spyOn(crypto.subtle, "digest").mockImplementation(() => new Promise<ArrayBuffer>(resolve => { finish = resolve; }));
    const queued = queueFestival("actor-a", command);
    localStorage.removeItem("duindorp-private-group:frightnight-v1:actor-a:frightnight-2027-test");
    finish(new ArrayBuffer(32));
    expect(await queued).toBe(false);
    expect(readFestival("actor-a")).toBeNull();
  });
});
