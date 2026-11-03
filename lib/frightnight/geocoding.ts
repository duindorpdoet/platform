import { z } from "zod";
export type AddressCandidate = { id: string; label: string; latitude: number; longitude: number };
const responseSchema = z.object({ response: z.object({ docs: z.array(z.object({ id: z.string(), weergavenaam: z.string(), centroide_ll: z.string() })).max(10) }) });
const cache = new Map<string, { until: number; candidates: AddressCandidate[] }>();
let active = 0;
export async function findAddress(address: string, transport: typeof fetch = fetch): Promise<AddressCandidate[]> {
  const normalized = z.string().trim().min(3).max(220).parse(address).replace(/\s+/g, " ");
  const hit = cache.get(normalized); if (hit && hit.until > Date.now()) return hit.candidates;
  if (active >= 4) throw new Error("ADDRESS_PROVIDER_BUSY");
  active++;
  try {
    const url = new URL("https://api.pdok.nl/bzk/locatieserver/search/v3_1/free");
    url.searchParams.set("q", `${normalized} Den Haag`); url.searchParams.set("fq", "type:adres"); url.searchParams.set("rows", "3");
    const response = await transport(url, { signal: AbortSignal.timeout(3000), redirect: "error", cache: "no-store" });
    if (!response.ok) throw new Error("ADDRESS_PROVIDER_UNAVAILABLE");
    const data = responseSchema.parse(await response.json());
    const candidates = data.response.docs.flatMap(doc => {
      const coordinate = /^POINT\(([0-9.]+) ([0-9.]+)\)$/.exec(doc.centroide_ll);
      if (!coordinate) return [];
      const longitude = Number(coordinate[1]), latitude = Number(coordinate[2]);
      if (latitude < 52.075 || latitude > 52.115 || longitude < 4.22 || longitude > 4.29) return [];
      return [{ id: doc.id, label: doc.weergavenaam, latitude, longitude }];
    });
    if (cache.size >= 128) cache.delete(cache.keys().next().value!);
    cache.set(normalized, { until: Date.now() + 86_400_000, candidates });
    return candidates;
  } finally { active--; }
}
