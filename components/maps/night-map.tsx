"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Compass, MapPin, RefreshCw } from "lucide-react";
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
const EMPTY_ROUTE: readonly [number, number][] = [];

export function NightMap({
  variant = "public",
  portals = EMPTY_PORTALS,
  route = EMPTY_ROUTE,
  routeAnimated = true,
  ariaLabel = "Interactieve nachtkaart van Duindorp",
  onPortalSelect,
}: {
  variant?: MapVariant;
  portals?: readonly NightMapPortal[];
  route?: readonly [number, number][];
  routeAnimated?: boolean;
  ariaLabel?: string;
  onPortalSelect?: (portal: NightMapPortal) => void;
}) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("maplibre-gl").Map | null>(null);
  const libraryRef = useRef<MapLibrary | null>(null);
  const markersRef = useRef<import("maplibre-gl").Marker[]>([]);
  const routeMarkerRef = useRef<import("maplibre-gl").Marker | null>(null);
  const fittedPortalsRef = useRef("");
  const onPortalSelectRef = useRef(onPortalSelect);
  const [state, setState] = useState<"loading" | "ready" | "failed">("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [zoom, setZoom] = useState(14.8);
  const [statusFilter, setStatusFilter] = useState<Record<string, boolean>>({ scheduled: true, open: true, paused: true, closed: true });
  const mappable = useMemo(() => portals.filter((portal) => validCoordinate(portal.coordinate) && (variant !== "admin" || statusFilter[portal.status ?? "scheduled"] !== false)), [portals, statusFilter, variant]);
  const routeCoordinates = useMemo(() => route.filter(validCoordinate), [route]);
  const routeKey = useMemo(() => routeCoordinates.map((coordinate) => coordinate.join(",")).join("|"), [routeCoordinates]);

  useEffect(() => { onPortalSelectRef.current = onPortalSelect; }, [onPortalSelect]);

  useEffect(() => {
    if (!container.current) return;
    setState("loading");
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
      fittedPortalsRef.current = "";
      setZoom(map.getZoom());
      map.on("zoomend", () => { if (!disposed) setZoom(map.getZoom()); });
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
      routeMarkerRef.current?.remove();
      routeMarkerRef.current = null;
      mapRef.current?.remove();
      mapRef.current = null;
      libraryRef.current = null;
    };
  }, [retryKey, variant]);

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

    const clusterAll = mappable.length >= 20 && zoom < 16;
    const clusters = new Map<string, NightMapPortal[]>();
    mappable.forEach((portal) => {
      const coordinate = portal.coordinate;
      if (!validCoordinate(coordinate)) return;
      const key = clusterAll ? "all-visible-portals" : portal.id;
      clusters.set(key, [...(clusters.get(key) ?? []), portal]);
    });

    clusters.forEach((cluster) => {
      if (cluster.length > 1) {
        const coordinates = cluster.map((portal) => portal.coordinate).filter(validCoordinate);
        const coordinate: [number, number] = [
          coordinates.reduce((sum, value) => sum + value[0], 0) / coordinates.length,
          coordinates.reduce((sum, value) => sum + value[1], 0) / coordinates.length,
        ];
        const button = document.createElement("button");
        button.type = "button";
        button.className = "night-map-cluster";
        button.textContent = String(cluster.length);
        button.setAttribute("aria-label", `${cluster.length} poorten in dit gebied. Inzoomen.`);
        button.addEventListener("click", () => map.easeTo({ center: coordinate, zoom: Math.min(map.getZoom() + 2, 18), duration: 450 }));
        markersRef.current.push(new library.Marker({ element: button }).setLngLat(coordinate).addTo(map));
        return;
      }
      const portal = cluster[0];
      const coordinate = portal.coordinate;
      if (!validCoordinate(coordinate)) return;
      const pin = document.createElement("button");
      pin.type = "button";
      pin.className = `night-map-portal-pin status-${portal.status ?? "scheduled"}${portal.isFinal ? " is-final" : ""}`;
      pin.style.setProperty("--portal-color", portalColor(portal));
      const status = portal.status === "open" ? "open" : portal.status === "paused" ? "op pauze" : portal.status === "closed" ? "gestopt" : "in voorbereiding";
      pin.setAttribute("aria-label", `${portal.code ? `${portal.code}, ` : ""}${portal.name}, ${portal.world}, ${status}${portal.address ? `, ${portal.address}` : ""}`);
      const symbol = document.createElement("span");
      symbol.textContent = portal.isFinal ? "★" : portal.status === "paused" ? "Ⅱ" : portal.status === "closed" ? "×" : "✦";
      pin.append(symbol);

      const popup = document.createElement("div");
      popup.className = "night-map-popup";
      const eyebrow = document.createElement("small");
      eyebrow.textContent = portal.demo
        ? ["Fictieve demonstratie", portal.code, portal.world].filter(Boolean).join(" · ")
        : [portal.code, portal.world, portal.isFinal ? "Laatste poort" : null].filter(Boolean).join(" · ");
      const title = document.createElement("strong");
      title.textContent = portal.name;
      popup.append(eyebrow, title);
      const detail = (label: string, value: string) => {
        const row = document.createElement("span");
        const labelNode = document.createElement("b");
        labelNode.textContent = `${label}: `;
        row.append(labelNode, value);
        popup.append(row);
      };
      if (portal.demo) {
        const description = document.createElement("p");
        description.className = "night-map-popup-description";
        description.textContent = portal.description ?? "Een fictieve indruk van een poort tijdens de avondloop.";
        popup.append(description);
      } else {
        detail("Adres", portal.address ?? "Niet ingevuld");
        detail("Contact", portal.contactName ?? "Niet ingevuld");
      }
      const statusRow = document.createElement("span");
      const statusLabel = document.createElement("b");
      statusLabel.textContent = "Status: ";
      statusRow.append(statusLabel, status);
      popup.append(statusRow);
      if (portal.phone) {
        const phone = document.createElement("a");
        phone.href = `tel:${portal.phone.replace(/\s/g, "")}`;
        phone.textContent = portal.phone;
        phone.setAttribute("aria-label", `Bel ${portal.contactName ?? portal.name} op ${portal.phone}`);
        popup.append(phone);
      }
      if (onPortalSelectRef.current) {
        const action = document.createElement("button");
        action.type = "button";
        action.className = "night-map-popup-action";
        action.textContent = "Poort bekijken →";
        action.addEventListener("click", () => onPortalSelectRef.current?.(portal));
        popup.append(action);
      }
      const mapPopup = new library.Popup({ offset: 25, closeButton: true, closeOnClick: false }).setDOMContent(popup);
      const marker = new library.Marker({ element: pin, anchor: "bottom" })
        .setLngLat(coordinate)
        .setPopup(mapPopup)
        .addTo(map);
      let closeTimer: number | undefined;
      const cancelClose = () => { if (closeTimer !== undefined) window.clearTimeout(closeTimer); };
      const scheduleClose = () => {
        cancelClose();
        closeTimer = window.setTimeout(() => {
          if (!pin.matches(":hover") && !popup.matches(":hover") && !popup.contains(document.activeElement)) mapPopup.remove();
        }, 140);
      };
      pin.addEventListener("mouseenter", () => { if (!mapPopup.isOpen()) marker.togglePopup(); });
      pin.addEventListener("mouseleave", scheduleClose);
      pin.addEventListener("focus", () => { if (!mapPopup.isOpen()) marker.togglePopup(); });
      pin.addEventListener("blur", scheduleClose);
      popup.addEventListener("mouseenter", cancelClose);
      popup.addEventListener("mouseleave", scheduleClose);
      markersRef.current.push(marker);
    });

    const fitKey = mappable.map((portal) => `${portal.id}:${portal.coordinate?.join(",")}`).sort().join("|");
    if (fitKey !== fittedPortalsRef.current) {
      fittedPortalsRef.current = fitKey;
      if (mappable.length === 1 && validCoordinate(mappable[0].coordinate)) {
        map.easeTo({ center: mappable[0].coordinate, zoom: variant === "route" ? 16 : 15, duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 750 });
      } else if (mappable.length > 1) {
        const bounds = new library.LngLatBounds();
        mappable.forEach((portal) => { if (validCoordinate(portal.coordinate)) bounds.extend(portal.coordinate); });
        map.fitBounds(bounds, { padding: 55, maxZoom: 16, duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 750 });
      }
    }
    return () => {
      markersRef.current.forEach((marker) => marker.remove());
      markersRef.current = [];
    };
  }, [state, mappable, variant, zoom]);

  useEffect(() => {
    const map = mapRef.current;
    const library = libraryRef.current;
    if (!map || !library || state !== "ready" || routeCoordinates.length < 2) return;
    const sourceId = "night-map-example-route";
    const glowId = "night-map-example-route-glow";
    const lineId = "night-map-example-route-line";
    const feature = {
      type: "Feature" as const,
      properties: {},
      geometry: {
        type: "LineString" as const,
        coordinates: routeCoordinates,
      },
    };

    const source = map.getSource(sourceId) as import("maplibre-gl").GeoJSONSource | undefined;
    if (source) source.setData(feature);
    else map.addSource(sourceId, { type: "geojson", data: feature });
    if (!map.getLayer(glowId)) map.addLayer({
      id: glowId,
      type: "line",
      source: sourceId,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#e39b5d", "line-width": 11, "line-opacity": 0.16, "line-blur": 4 },
    });
    if (!map.getLayer(lineId)) map.addLayer({
      id: lineId,
      type: "line",
      source: sourceId,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#f4bd82", "line-width": 3.5, "line-opacity": 0.92, "line-dasharray": [1.2, 1.6] },
    });

    routeMarkerRef.current?.remove();
    const traveller = document.createElement("span");
    traveller.className = "night-map-route-traveller";
    traveller.setAttribute("aria-hidden", "true");
    const marker = new library.Marker({ element: traveller }).setLngLat(routeCoordinates[0]).addTo(map);
    routeMarkerRef.current = marker;
    let frame = 0;

    const placeTraveller = (progress: number) => {
      const scaled = Math.min(progress, 0.999999) * (routeCoordinates.length - 1);
      const index = Math.floor(scaled);
      const local = scaled - index;
      const from = routeCoordinates[index];
      const to = routeCoordinates[Math.min(index + 1, routeCoordinates.length - 1)];
      marker.setLngLat([from[0] + (to[0] - from[0]) * local, from[1] + (to[1] - from[1]) * local]);
    };

    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (routeAnimated && !reducedMotion) {
      const started = performance.now();
      const animate = (now: number) => {
        placeTraveller((Math.max(0, now - started) % 12_000) / 12_000);
        frame = window.requestAnimationFrame(animate);
      };
      frame = window.requestAnimationFrame(animate);
    } else {
      placeTraveller(0.5);
    }

    return () => {
      if (frame) window.cancelAnimationFrame(frame);
      marker.remove();
      if (routeMarkerRef.current === marker) routeMarkerRef.current = null;
      try {
        if (map.getLayer(lineId)) map.removeLayer(lineId);
        if (map.getLayer(glowId)) map.removeLayer(glowId);
        if (map.getSource(sourceId)) map.removeSource(sourceId);
      } catch {
        // The map instance may already be disposed while navigating away.
      }
    };
  }, [routeAnimated, routeCoordinates, routeKey, state]);

  return <div
    className={`night-map night-map--${variant}`}
    data-map-center={`${DUINDORP_CENTER[0]},${DUINDORP_CENTER[1]}`}
    data-map-privacy={variant === "preview" || variant === "public" ? "area-only" : "authorized-destinations"}
    data-map-demo={portals.some((portal) => portal.demo) ? "fictional" : undefined}
    data-map-route-points={routeCoordinates.length}
  >
    {variant === "admin" && portals.length > 0 && <div className="night-map-filters" role="group" aria-label="Filter poorten op status">
      {(["open", "paused", "closed", "scheduled"] as const).map((status) => <button type="button" key={status} className={statusFilter[status] ? "active" : ""} aria-pressed={statusFilter[status]} onClick={() => setStatusFilter((current) => ({ ...current, [status]: !current[status] }))}>
        <i className={`status-${status}`} />{status === "open" ? "Open" : status === "paused" ? "Pauze" : status === "closed" ? "Gestopt" : "Voorbereiding"}
      </button>)}
    </div>}
    <div ref={container} className="night-map-canvas" aria-label={ariaLabel} />
    {state !== "ready" && <div className="night-map-fallback" role={state === "failed" ? "status" : undefined}>
      {state === "failed" ? <MapPin size={27} /> : <Compass size={27} className="night-map-loading-icon" />}
      <strong>{state === "failed" ? "Kaart tijdelijk niet beschikbaar" : "De nachtkaart verschijnt…"}</strong>
      {portals.length ? <div className="night-map-fallback-addresses">
        {portals.map((portal) => <p key={portal.id}><b style={{ color: portalColor(portal) }}>{portal.name}</b><span>{portal.demo ? `${portal.world} · fictieve voorbeeldpoort` : portal.address ?? "Adres volgt na bevestiging"}</span></p>)}
      </div> : <p>De avondloop vindt plaats in Duindorp, Den Haag. Poortadressen verschijnen alleen wanneer ze voor jullie zijn vrijgegeven.</p>}
      {state === "failed" && <button type="button" className="btn outline" onClick={() => setRetryKey((value) => value + 1)}><RefreshCw />Kaart opnieuw laden</button>}
    </div>}
    {state === "ready" && variant === "route" && portals.length > 0 && mappable.length === 0 && <div className="night-map-unpinned">
      <MapPin size={18} /><span>De locatiepin wordt nog gecontroleerd. Gebruik het adres van de vrijgegeven poort.</span>
    </div>}
    {(variant === "preview" || variant === "public") && state === "ready" && <div className="night-map-privacy-note">{variant === "public" && portals.some((portal) => portal.demo) ? "Voorbeeldroute · alle poorten zijn fictief" : "Wijkkaart · privé-adressen blijven verborgen"}</div>}
  </div>;
}
