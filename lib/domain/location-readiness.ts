import { validCoordinate } from "@/lib/maps/duindorp-map";

export type RoutingLocation = {
  valid: boolean;
  latitude: number | null;
  longitude: number | null;
  source: "address" | "manual";
  reason?: string | null;
};

export type StartPointReadiness = {
  location: RoutingLocation;
  confirmed: boolean;
  confirmedAt: string | null;
  canConfirm: boolean;
  confirmationReason: string | null;
  routeReady: boolean;
  linkedPortalName: string | null;
};

export function locationCoordinate(longitude: number | null, latitude: number | null): [number, number] | null {
  const value: [number, number] = [longitude!, latitude!];
  return validCoordinate(value) ? value : null;
}

// Empty fields must stay missing; Number("") would invent a zero coordinate.
export function parseCoordinatePart(value: string): number | null {
  const text = value.trim().replace(",", ".");
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text)) return null;
  const number = Number(text);
  return Number.isFinite(number) ? number : null;
}

export function locationError(message: string) {
  if (/abort|fetch failed|failed to fetch|network|timeout/i.test(message)) return "Opslag niet bevestigd. Controleer de verbinding, vernieuw de locatie en probeer opnieuw.";
  const errors: Record<string, string> = {
    START_POINT_POSITION_MISSING: "Geen opgeslagen positie — plaats een marker en sla deze op.",
    START_POINT_POSITION_INVALID: "Ongeldige positie — controleer de coördinaten en sla opnieuw op.",
    START_POINT_ADDRESS_MISSING: "Adres ontbreekt — vul het adres van deze startlocatie in.",
    SOURCE_POSITION_INVALID: "De laatst bevestigde locatie heeft geen geldige opgeslagen positie. Vraag de organisatie deze marker te controleren.",
    FINAL_PORTAL_POSITION_INVALID: "De eindpoort heeft geen geldige opgeslagen positie. Controleer de finalemarker.",
    LINKED_START_PORTAL_POSITION_INVALID: "De gekoppelde eerste poort heeft geen geldig adres of geldige positie. Controleer het adres en de marker van deze poort.",
    LINKED_PORTAL_NOT_AVAILABLE: "De gekoppelde poort is niet beschikbaar. Controleer de gekoppelde poort.",
    INVALID_COORDINATE: "Vul een geldige breedtegraad en lengtegraad in.",
    ADDRESS_LOCATION_MISSING: "Geen opgeslagen adrespositie. Plaats en bewaar een marker.",
    LOCATION_WRITE_NOT_CONFIRMED: "De server heeft de locatie niet bevestigd. Vernieuw en probeer opnieuw.",
  };
  return Object.entries(errors).find(([code]) => message.includes(code))?.[1] ?? null;
}
