"use client";

import { useEffect, useRef, useState } from "react";
import { Compass, LockKeyhole, MapPin } from "lucide-react";

export function PublicMap() {
  const container = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"loading" | "ready" | "unconfigured" | "failed">("loading");

  useEffect(() => {
    const style = process.env.NEXT_PUBLIC_MAP_STYLE_URL;
    if (!style || !container.current) {
      setState("unconfigured");
      return;
    }

    let disposed = false;
    let map: import("maplibre-gl").Map | undefined;
    void import("maplibre-gl").then(({ Map, Marker, NavigationControl }) => {
      if (disposed || !container.current) return;
      map = new Map({
        container: container.current,
        style,
        center: [4.273, 52.104],
        zoom: 13.4,
        attributionControl: { compact: true },
      });
      map.addControl(new NavigationControl({ visualizePitch: true }), "top-right");
      const marker = document.createElement("div");
      marker.className = "public-area-pin";
      marker.setAttribute("aria-label", "Duindorp, gebied van de avondloop");
      new Marker({ element: marker }).setLngLat([4.273, 52.104]).addTo(map);
      map.once("load", () => setState("ready"));
      map.once("error", () => setState("failed"));
    }).catch(() => setState("failed"));

    return () => {
      disposed = true;
      map?.remove();
    };
  }, []);

  return (
    <div className="public-map-container">
      <div ref={container} className="maplibre-host" aria-label="Openbare sfeerkaart van Duindorp" />
      {state !== "ready" && (
        <div className="map-fallback">
          {state === "unconfigured" ? <LockKeyhole size={38} /> : state === "failed" ? <MapPin size={38} /> : <Compass size={38} />}
          <h2>{state === "unconfigured" ? "De kaartdienst wordt nog ingericht." : state === "failed" ? "De kaart kon niet laden." : "Kaart laden…"}</h2>
          <p>De deelnemende huizen en verrassingen houden we geheim tot jullie op pad gaan.</p>
        </div>
      )}
    </div>
  );
}
