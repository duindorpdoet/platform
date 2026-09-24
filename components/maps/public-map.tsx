"use client";

import { NightMap } from "@/components/maps/night-map";

export function PublicMap({ compact = false }: { compact?: boolean }) {
  return <NightMap variant={compact ? "preview" : "public"} ariaLabel="Interactieve wijkkaart van Duindorp zonder privé-adressen" />;
}
