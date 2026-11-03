import { afterEach, describe, it, expect, vi } from "vitest";
import { walkingRoute } from "./walking";
afterEach(() => vi.restoreAllMocks());
describe("begrensde echte wandelroutes", () => {
  it("bundelt identieke aanvragen en tekent uitsluitend providergeometrie", async () => {
    let requests = 0;
    const transport: typeof fetch = async () => { requests++; return Response.json({ code: "Ok", routes: [{ duration: 240, distance: 280, geometry: { type: "LineString", coordinates: [[4.25, 52.095], [4.251, 52.096], [4.252, 52.096]] } }] }); };
    const [a, b] = await Promise.all([walkingRoute({ longitude: 4.25, latitude: 52.095 }, { longitude: 4.252, latitude: 52.096 }, transport), walkingRoute({ longitude: 4.25, latitude: 52.095 }, { longitude: 4.252, latitude: 52.096 }, transport)]);
    expect(requests).toBe(1); expect(a).toEqual(b); expect(a.geometry.coordinates).toHaveLength(3); expect(a.minutes).toBe(4);
  });
  it("weigert onbegrensde invoer en providerfouten zonder een rechte nepkaart", async () => {
    await expect(walkingRoute({ longitude: 100, latitude: 0 }, { longitude: 4.25, latitude: 52.1 })).rejects.toThrow();
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 2000);
    const transport = vi.fn(async () => Response.json({ code: "NoRoute" }));
    await expect(walkingRoute({ longitude: 4.254, latitude: 52.095 }, { longitude: 4.255, latitude: 52.096 }, transport)).rejects.toThrow();
    expect(transport).toHaveBeenCalledOnce();
  });
  it("weigert een extra unieke provideroproep binnen één seconde", async () => {
    const transport = vi.fn();
    await expect(walkingRoute({ longitude: 4.256, latitude: 52.095 }, { longitude: 4.257, latitude: 52.096 }, transport)).rejects.toThrow("WALK_PROVIDER_BUSY");
    expect(transport).not.toHaveBeenCalled();
  });
});
