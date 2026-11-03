"use client";
import { useEffect, useRef, useState } from "react";
import type { FrightnightDestination } from "@/lib/frightnight/model";

export function WalkingMap({ destination }: { destination: FrightnightDestination }) {
  const container = useRef<HTMLDivElement>(null);
  const [note, setNote] = useState("De wandelverbinding wordt gecontroleerd. Volg de aanwijzingen van de vrijwilligers.");
  useEffect(() => {
    let active = true;
    let map: import("maplibre-gl").Map | undefined;
    const abort = new AbortController();
    const lat = destination.zone.latitude; const lng = destination.zone.longitude;
    if (lat === undefined || lng === undefined) return () => { active = false; abort.abort(); };
    void Promise.all([import("maplibre-gl"), fetch(`/api/frightnight/walk?destinationId=${encodeURIComponent(destination.id)}`, { cache: "no-store", signal: abort.signal }).then(async response => response.ok ? response.json().then(body => body.data ?? body) : null)]).then(([module, path]) => {
      if (!active || !container.current) return;
      module.setWorkerUrl("/maplibre/maplibre-gl-worker.mjs");
      const instance = new module.Map({ container: container.current, style: "/maps/duindorp-night.json", center: [lng, lat], zoom: 15.7, attributionControl: { compact: true } });
      map = instance;
      instance.addControl(new module.NavigationControl({ showCompass: false }), "top-right");
      new module.Marker({ color: "#e8883c" }).setLngLat([lng, lat]).addTo(instance);
      instance.on("load", () => {
        if (path?.geometry?.type === "LineString" && Array.isArray(path.geometry.coordinates) && path.geometry.coordinates.length > 1 && map) {
          map.addSource("current-walk", { type: "geojson", data: { type: "Feature", properties: {}, geometry: path.geometry } });
          map.addLayer({ id: "current-walk", type: "line", source: "current-walk", paint: { "line-color": "#e8a65f", "line-width": 5 } });
          const bounds = new module.LngLatBounds();
          path.geometry.coordinates.forEach((point: [number, number]) => bounds.extend(point));
          map.fitBounds(bounds, { padding: 45, maxZoom: 17, animate: false });
          setNote(`Wandelpad: ${path.source ?? "gecontroleerde verbinding"}. ${path.minutes ?? destination.walkMinutes} minuten. Let ter plekke op oversteekplaatsen.`);
        } else setNote(path?.reason ?? "Er is geen gecontroleerd wandelpad beschikbaar. De pin toont alleen je vrijgegeven bestemming. Vraag bij twijfel de vrijwilliger; de kaartlijn wordt niet verzonnen.");
      });
      instance.on("error", () => { if (active) setNote("De kaart is niet beschikbaar. Het bevestigde adres hierboven blijft geldig. Vraag een vrijwilliger om de veilige looprichting."); });
    }).catch(() => { if (active) setNote("Kaart of wandelprovider niet bereikbaar. Gebruik het bevestigde adres en de aanwijzingen van de vrijwilligers."); });
    return () => { active = false; abort.abort(); map?.remove(); };
  }, [destination.id, destination.walkMinutes, destination.zone.latitude, destination.zone.longitude]);
  return <figure className="fn-walking-map"><div ref={container} aria-label={`Kaart van jouw bestemming ${destination.zone.name}`} /><figcaption>{note} · <a href="https://www.openstreetmap.org/fixthemap" target="_blank" rel="noopener noreferrer">© OpenStreetMap-bijdragers · kaartcorrectie</a></figcaption></figure>;
}
