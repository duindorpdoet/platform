import { worlds } from "@/features/content/public-content";

// OpenStreetMap way 7497292 (Tesselseplein), verified through Nominatim on
// 2026-09-24. Keep the source with the coordinate so this never becomes an
// unexplained, hand-estimated map point.
export const DUINDORP_CENTER: [number, number] = [4.2579563, 52.0899891];
export const DUINDORP_CENTER_SOURCE = "https://www.openstreetmap.org/way/7497292";
export const DUINDORP_NIGHT_STYLE = "/maps/duindorp-night.json";

export type PublicMapVariant = "preview" | "public";

export function publicMapZoom(variant: PublicMapVariant, mobile: boolean) {
  if (variant === "preview") return mobile ? 14.45 : 14.9;
  return mobile ? 14.65 : 15.15;
}

export type NightMapPortal = {
  id: string;
  code?: string;
  name: string;
  world: string;
  coordinate: [number, number] | null;
  address?: string;
  contactName?: string;
  phone?: string;
  status?: "scheduled" | "open" | "paused" | "closed" | string;
  isFinal?: boolean;
  color?: string;
};

export function portalColor(portal: Pick<NightMapPortal, "world" | "color">) {
  if (portal.color && /^#[0-9a-f]{6}$/i.test(portal.color)) return portal.color;
  const world = portal.world.trim().toLocaleLowerCase("nl-NL");
  return worlds.find((item) => item.slug === world || item.name.toLocaleLowerCase("nl-NL") === world)?.color ?? "#e8a46f";
}

export function validCoordinate(value: NightMapPortal["coordinate"]): value is [number, number] {
  return Array.isArray(value) && value.length === 2 &&
    value.every((part) => typeof part === "number" && Number.isFinite(part)) &&
    value[0] >= -180 && value[0] <= 180 && value[1] >= -90 && value[1] <= 90;
}
