import { worlds } from "@/features/content/public-content";

export const DUINDORP_CENTER: [number, number] = [4.273, 52.104];
export const DUINDORP_NIGHT_STYLE = "/maps/duindorp-night.json";

export type NightMapPortal = {
  id: string;
  name: string;
  world: string;
  coordinate: [number, number] | null;
  address?: string;
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
