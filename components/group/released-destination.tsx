"use client";

import { useMemo } from "react";
import { MapPin, Navigation } from "lucide-react";
import { NightMap } from "@/components/maps/night-map";
import { validCoordinate } from "@/lib/maps/duindorp-map";
import { destinationNavigationUrl } from "@/lib/domain/released-destination";

export function ReleasedDestination({ id, name, address, coordinate, instruction, locationSource, start = false }: {
  id: string; name: string; address: string; coordinate?: [number, number] | null;
  instruction?: string | null; locationSource?: string | null; start?: boolean;
}) {
  const pin = validCoordinate(coordinate ?? null) ? coordinate! : null;
  const navigation = destinationNavigationUrl(pin);
  const portals = useMemo(() => [{ id, name, address, coordinate: pin, world: start ? "Startpunt" : "Huidige bestemming" }], [id, name, address, pin, start]);
  return <div className="released-destination" data-destination-coordinate={pin?.join(",")}>
    <p className="released-destination-address"><MapPin size={16}/><strong>{address}</strong></p>
    {instruction && <div className="released-destination-entrance"><strong>Zo vind je de ingang</strong><p>{instruction}</p></div>}
    {locationSource === "manual" && <p className="released-destination-pin-note">De pin wijst naar de gekozen ingang. Die kan afwijken van het officiële adres.</p>}
    {!pin && <p className="form-warning">De locatiepin is nog niet bruikbaar. Gebruik het adres en de ingangsinstructie; vraag bij twijfel de organisatie om hulp.</p>}
    <NightMap variant="route" portals={portals} ariaLabel={start ? "Kaart met het vrijgegeven startpunt" : "Kaart met de huidige vrijgegeven poort"}/>
    {navigation && <a className="btn outline released-destination-navigation" href={navigation} target="_blank" rel="noopener noreferrer"><Navigation size={16}/>Open navigatie naar de ingang</a>}
    <p className="released-destination-pin-note">De kaart toont jullie bestemming. Kies zelf een veilige wandelweg; de kaart geeft geen gecontroleerde wandelroute.</p>
  </div>;
}
