import sharp from "sharp";
import { z } from "zod";
import { apiFailure, apiSuccess, ApiError, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightCommand, frightnightSnapshot } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
import { boundedRequestBytes } from "@/lib/frightnight/request-body";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const snapshot = await frightnightSnapshot();
    const bytes = await boundedRequestBytes(request, 5_500_000);
    let form: FormData;
    try { form = await new Response(new Uint8Array(bytes).buffer, { headers: { "Content-Type": request.headers.get("content-type") ?? "" } }).formData(); }
    catch { throw new ApiError(400, "INVALID_PHOTO_FORM", "De fotoaanvraag is ongeldig. Kies de foto opnieuw."); }
    const zoneId = z.uuid().parse(form.get("zoneId"));
    const version = z.coerce.number().int().min(1).parse(form.get("expectedVersion"));
    const commandId = z.uuid().parse(form.get("commandId"));
    const zone = [...snapshot.ownZones, ...(snapshot.zones ?? [])].find(x => x.id === zoneId);
    if (!zone || (!snapshot.ownZones.some(x => x.id === zoneId) && !snapshot.actor.capabilities.some(x => x === "event_admin" || x === "portals_manage"))) throw new ApiError(403, "ZONE_FORBIDDEN", "Je kunt alleen een foto voor je eigen zone toevoegen.");
    const file = form.get("photo");
    if (!(file instanceof File) || file.size > 5_000_000 || !["image/jpeg", "image/png", "image/webp"].includes(file.type)) throw new ApiError(422, "PHOTO_TYPE", "Kies een JPG-, PNG- of WebP-foto van maximaal 5 MB.");
    let encoded: Buffer;
    try { encoded = await sharp(await file.arrayBuffer(), { limitInputPixels: 20_000_000 }).rotate().resize({ width: 1400, height: 1400, fit: "inside", withoutEnlargement: true }).webp({ quality: 82 }).toBuffer(); }
    catch { throw new ApiError(422, "PHOTO_INVALID", "Deze afbeelding kan niet veilig worden gelezen. Kies een andere foto."); }
    const client = await createClient();
    const path = `${snapshot.event.id}/${zoneId}/${snapshot.actor.id}/${commandId}.webp`;
    const bucket = client!.storage.from("frightnight-zone-photos");
    const uploaded = await bucket.upload(path, encoded, { contentType: "image/webp", upsert: false });
    if (uploaded.error && !/already exists|Duplicate/i.test(uploaded.error.message)) throw new ApiError(503, "PHOTO_STORAGE", "De foto kon niet worden opgeslagen. Probeer later opnieuw.");
    let result;
    try { result = await frightnightCommand("zone.photo", { zoneId, path, expectedVersion: version }, commandId); }
    catch (error) { if (!uploaded.error) await bucket.remove([path]); throw error; }
    return apiSuccess(result);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    const zoneId = z.uuid().parse(new URL(request.url).searchParams.get("zoneId"));
    const zones = [...snapshot.ownZones, ...(snapshot.zones ?? []), ...(snapshot.current ? [snapshot.current.zone] : [])];
    const zone = zones.find(x => x.id === zoneId) as { photoPath?: string } | undefined;
    if (!zone?.photoPath) throw new ApiError(404, "PHOTO_NOT_FOUND", "Deze zone heeft geen beschikbare foto.");
    const client = await createClient();
    const { data, error } = await client!.storage.from("frightnight-zone-photos").download(zone.photoPath);
    if (error || !data) throw new ApiError(404, "PHOTO_NOT_FOUND", "De foto is tijdelijk niet bereikbaar.");
    return new Response(data, { headers: { "Content-Type": "image/webp", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
