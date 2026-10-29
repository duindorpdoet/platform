import { validCoordinate } from "@/lib/maps/duindorp-map";

// GeoJSON is [longitude, latitude]; navigation providers take latitude first.
export function destinationNavigationUrl(coordinate: [number, number] | null | undefined): string | null {
  if (!validCoordinate(coordinate ?? null)) return null;
  return `https://www.google.com/maps/dir/?api=1&destination=${coordinate![1]},${coordinate![0]}&travelmode=walking`;
}
