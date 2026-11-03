import { describe, expect, it } from "vitest";
import { findAddress } from "./geocoding";
describe("begrensde adrescontrole", () => {
  it("accepteert alleen echte providercoördinaten binnen Duindorp en cachet de uitslag", async () => {
    let calls = 0;
    const transport: typeof fetch = async () => { calls++; return Response.json({ response: { docs: [{ id: "test-address", weergavenaam: "Synthetische providerfixture", centroide_ll: "POINT(4.255 52.095)" }, { id: "elsewhere", weergavenaam: "Buiten de wijk", centroide_ll: "POINT(5.1 53.2)" }] } }); };
    const a = await findAddress("Synthetisch adres test 2027", transport), b = await findAddress("Synthetisch adres test 2027", transport);
    expect(a).toHaveLength(1); expect(a[0].longitude).toBe(4.255); expect(b).toEqual(a); expect(calls).toBe(1);
  });
  it("geeft bij providerfout geen verzonnen locatie", async () => {
    const transport: typeof fetch = async () => new Response("", { status: 503 });
    await expect(findAddress("Andere synthetische testlocatie", transport)).rejects.toThrow("ADDRESS_PROVIDER_UNAVAILABLE");
  });
});
