import type { FrightnightEvent, FrightnightRouteType } from "./model";

/** Display advice from the last server snapshot. Commands always recheck in SQL. */
export function salesMessage(event: FrightnightEvent, route?: FrightnightRouteType): string | null {
  if (event.closed) return "Deze editie is afgesloten. Er komen geen nieuwe inschrijvingen of betalingen bij.";
  if (event.salesOpen === false || (event.salesClosesAt && Date.parse(event.serverTime) >= Date.parse(event.salesClosesAt))) {
    return "De verkoop is gesloten. Bestaande betaalde Nachtpassen, contactgegevens en routes blijven beschikbaar.";
  }
  if (event.enabledRoutes?.length === 0) return "Er zijn momenteel geen tochten beschikbaar voor nieuwe verkoop. Bestaande betaalde Nachtpassen blijven geldig.";
  if (route && event.enabledRoutes && !event.enabledRoutes.includes(route)) {
    return `De ${route === "lantern" ? "Lantaarnentocht" : "Worteltocht"} is gesloten voor nieuwe inschrijvingen en betaalpogingen.`;
  }
  return null;
}
