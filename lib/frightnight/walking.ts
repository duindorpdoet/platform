import { z } from "zod";
export type WalkingPoint = { latitude: number; longitude: number };
const point = z.object({ latitude: z.number().min(52.04).max(52.15), longitude: z.number().min(4.19).max(4.36) });
const geometry = z.object({ type: z.literal("LineString"), coordinates: z.array(z.tuple([z.number().min(4.19).max(4.36), z.number().min(52.04).max(52.15)])).min(2).max(5000) });
const responseSchema = z.object({ code: z.literal("Ok"), routes: z.array(z.object({ geometry, duration: z.number().nonnegative().max(7200), distance: z.number().nonnegative().max(12000) })).min(1) });
export type WalkingRoute = { geometry: z.infer<typeof geometry>; source: string; minutes: number; available: true };
const cache = new Map<string, { expires: number; route: WalkingRoute }>();
const inflight = new Map<string, Promise<WalkingRoute>>();
let nextProviderAt = 0;
export async function walkingRoute(from: WalkingPoint, to: WalkingPoint, transport: typeof fetch = fetch): Promise<WalkingRoute> {
  point.parse(from); point.parse(to);
  const key = `${from.longitude.toFixed(6)},${from.latitude.toFixed(6)};${to.longitude.toFixed(6)},${to.latitude.toFixed(6)}`;
  const existing = cache.get(key);
  if (existing && existing.expires > Date.now()) return existing.route;
  const current = inflight.get(key); if (current) return current;
  if (inflight.size >= 8) throw new Error("WALK_PROVIDER_BUSY");
  // The public FOSSGIS service permits at most one request per second.
  // Stored organisation-approved edges and the cache handle the evening load.
  if (Date.now() < nextProviderAt) throw new Error("WALK_PROVIDER_BUSY");
  nextProviderAt = Date.now() + 1050;
  const task = (async () => {
    try {
      const response = await transport(`https://routing.openstreetmap.de/routed-foot/route/v1/foot/${key}?overview=full&geometries=geojson&alternatives=false&steps=false`, { signal: AbortSignal.timeout(5000), redirect: "error", cache: "no-store", headers: { "User-Agent": "DuindorpFrightNightStaging/2027 (bounded walking lookup)" } });
      if (!response.ok) throw new Error("WALK_PROVIDER_UNAVAILABLE");
      const parsed = responseSchema.parse(await response.json());
      const data = parsed.routes[0];
      const route: WalkingRoute = { geometry: data.geometry, source: "OpenStreetMap · OSRM voetgangersroute. Volg veilige openbare paden en aanwijzingen ter plaatse.", minutes: Math.max(1, Math.ceil(data.duration / 60)), available: true };
      if (cache.size >= 256) cache.delete(cache.keys().next().value!);
      cache.set(key, { route, expires: Date.now() + 86_400_000 });
      return route;
    } finally { inflight.delete(key); }
  })();
  inflight.set(key, task);
  return task;
}
