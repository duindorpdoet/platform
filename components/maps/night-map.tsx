"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Compass, MapPin } from "lucide-react";
import {
  DUINDORP_CENTER,
  DUINDORP_NIGHT_STYLE,
  portalColor,
  publicMapZoom,
  validCoordinate,
  type NightMapPortal,
} from "@/lib/maps/duindorp-map";

type MapLibrary = typeof import("maplibre-gl");
type MapVariant = "preview" | "public" | "route" | "admin";
const EMPTY_PORTALS: readonly NightMapPortal[] = [];

export function NightMap({
  variant = "public",
  portals = EMPTY_PORTALS,
  ariaLabel = "Interactieve nachtkaart van Duindorp",
}: {
  variant?: MapVariant;
  portals?: readonly NightMapPortal[];
  ariaLabel?: string;
}) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("maplibre-gl").Map | null>(null);
  const libraryRef = useRef<MapLibrary | null>(null);
  const markersRef = useRef<import("maplibre-gl").Marker[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "failed">("loading");
  const mappable = useMemo(() => portals.filter((portal) => validCoordinate(portal.coordinate)), [portals]);

  useEffect(() => {
    if (!container.current) return;
    let disposed = false;
    let failed = false;
    const timeout = window.setTimeout(() => { if (!disposed) { failed = true; setState("failed"); } }, 15000);
    void import("maplibre-gl").then((library) => {
      if (disposed || !container.current) return;
      library.setWorkerUrl("/maplibre/maplibre-gl-worker.mjs");
      libraryRef.current = library;
      const mobile = window.matchMedia("(max-width: 700px)").matches;
      const map = new library.Map({
        container: container.current,
        style: DUINDORP_NIGHT_STYLE,
        center: DUINDORP_CENTER,
        zoom: variant === "preview" || variant === "public"
          ? publicMapZoom(variant, mobile)
          : 14.8,
        attributionControl: { compact: false },
        cooperativeGestures: variant === "preview",
      });
      mapRef.current = map;
      if (variant !== "preview") map.addControl(new library.NavigationControl({ showCompass: false }), "top-right");
      map.once("load", () => {
        if (disposed || failed) return;
        window.clearTimeout(timeout);
        setState("ready");
      });
      map.on("error", () => { if (!disposed) { failed = true; setState("failed"); } });
    }).catch((error: unknown) => {
      console.error("Nachtkaart kon MapLibre niet starten", error);
      if (!disposed) { failed = true; setState("failed"); }
    });

    return () => {
      disposed = true;
      window.clearTimeout(timeout);
      markersRef.current.forEach((marker) => marker.remove());
      markersRef.current = [];
      mapRef.current?.remove();
      mapRef.current = null;
      libraryRef.current = null;
    };
  }, [variant]);

  useEffect(() => {
    const map = mapRef.current;
    const library = libraryRef.current;
    if (!map || !library || state !== "ready") return;
    markersRef.current.forEach((marker) => marker.remove());
    markersRef.current = [];

    if (mappable.length === 0 && (variant === "preview" || variant === "public")) {
      const marker = document.createElement("span");
      marker.className = "night-map-area-marker";
      marker.textContent = "Duindorp";
      markersRef.current.push(new library.Marker({ element: marker }).setLngLat(DUINDORP_CENTER).addTo(map));
      return;
    }

    mappable.forEach((portal) => {
      const coordinate = portal.coordinate;
      if (!validCoordinate(coordinate)) return;
      const pin = document.createElement("button");
      pin.type = "button";
      pin.className = "night-map-portal-pin";
      pin.style.setProperty("--portal-color", portalColor(portal));
      pin.setAttribute("aria-label", `${portal.name}, ${portal.world}${portal.address ? `, ${portal.address}` : ""}`);
      const symbol = document.createElement("span");
      symbol.textContent = "✦";
      pin.append(symbol);

      const popup = document.createElement("div");
      popup.className = "night-map-popup";
      const title = document.createElement("strong");
      title.textContent = portal.name;
      const world = document.createElement("small");
      world.textContent = portal.world;
      popup.append(world, title);
      if (portal.address) {
        const address = document.createElement("span");
        address.textContent = portal.address;
        popup.append(address);
      }
      markersRef.current.push(new library.Marker({ element: pin, anchor: "bottom" })
        .setLngLat(coordinate)
        .setPopup(new library.Popup({ offset: 25, closeButton: false }).setDOMContent(popup))
        .addTo(map));
    });

    if (mappable.length === 1 && validCoordinate(mappable[0].coordinate)) {
      map.easeTo({ center: mappable[0].coordinate, zoom: variant === "route" ? 16 : 15, duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 750 });
    } else if (mappable.length > 1) {
      const bounds = new library.LngLatBounds();
      mappable.forEach((portal) => { if (validCoordinate(portal.coordinate)) bounds.extend(portal.coordinate); });
      map.fitBounds(bounds, { padding: 55, maxZoom: 16, duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 750 });
    }
    return () => {
      markersRef.current.forEach((marker) => marker.remove());
      markersRef.current = [];
    };
  }, [state, mappable, variant]);

  return <div
    className={`night-map night-map--${variant}`}
    data-map-center={`${DUINDORP_CENTER[0]},${DUINDORP_CENTER[1]}`}
    data-map-privacy={variant === "preview" || variant === "public" ? "area-only" : "authorized-destinations"}
  >
    <div ref={container} className="night-map-canvas" aria-label={ariaLabel} />
    {state !== "ready" && <div className="night-map-fallback" role={state === "failed" ? "status" : undefined}>
      {state === "failed" ? <MapPin size={27} /> : <Compass size={27} className="night-map-loading-icon" />}
      <strong>{state === "failed" ? "Kaart tijdelijk niet beschikbaar" : "De nachtkaart verschijnt…"}</strong>
      {portals.length ? <div className="night-map-fallback-addresses">
        {portals.map((portal) => <p key={portal.id}><b style={{ color: portalColor(portal) }}>{portal.name}</b><span>{portal.address ?? "Adres volgt na bevestiging"}</span></p>)}
      </div> : <p>De avondloop vindt plaats in Duindorp, Den Haag. Poortadressen verschijnen alleen wanneer ze voor jullie zijn vrijgegeven.</p>}
    </div>}
    {state === "ready" && variant === "route" && portals.length > 0 && mappable.length === 0 && <div className="night-map-unpinned">
      <MapPin size={18} /><span>De locatiepin wordt nog gecontroleerd. Gebruik het adres van de vrijgegeven poort.</span>
    </div>}
    {(variant === "preview" || variant === "public") && state === "ready" && <div className="night-map-privacy-note">Wijkkaart · privé-adressen blijven verborgen</div>}
  </div>;
}
