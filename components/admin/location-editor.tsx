"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Crosshair, MapPin, RotateCcw, Save, X } from "lucide-react";
import { DUINDORP_CENTER, DUINDORP_NIGHT_STYLE, validCoordinate } from "@/lib/maps/duindorp-map";

type Coordinate = [number, number];

function distanceMeters(first: Coordinate | null, second: Coordinate | null) {
  if (!first || !second) return null;
  const radians = (value: number) => value * Math.PI / 180;
  const latitudeDelta = radians(second[1] - first[1]);
  const longitudeDelta = radians(second[0] - first[0]);
  const value = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(radians(first[1])) * Math.cos(radians(second[1])) * Math.sin(longitudeDelta / 2) ** 2;
  return Math.round(6371000 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value)));
}

export type LocationSave = {
  latitude: number;
  longitude: number;
  reason: string;
  restoreFromAddress: boolean;
};

export function LocationEditor({
  label,
  coordinate,
  addressCoordinate,
  markerKind = "start",
  color = "#e7ad70",
  reason: savedReason,
  onSave,
  busy = false,
}: {
  label: string;
  coordinate: Coordinate | null;
  addressCoordinate: Coordinate | null;
  markerKind?: "start" | "portal" | "final";
  color?: string | null;
  reason?: string | null;
  onSave: (change: LocationSave) => Promise<void> | void;
  busy?: boolean;
}) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("maplibre-gl").Map | null>(null);
  const markerRef = useRef<import("maplibre-gl").Marker | null>(null);
  const libraryRef = useRef<typeof import("maplibre-gl") | null>(null);
  const editingRef = useRef(false);
  const [mapState, setMapState] = useState<"loading" | "ready" | "failed">("loading");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<Coordinate | null>(coordinate);
  const [reason, setReason] = useState(savedReason ?? "");
  const [restore, setRestore] = useState(false);
  const effectiveDraft = draft ?? coordinate ?? addressCoordinate ?? DUINDORP_CENTER;
  const drift = useMemo(() => distanceMeters(addressCoordinate, editing ? effectiveDraft : coordinate), [addressCoordinate, coordinate, editing, effectiveDraft]);

  useEffect(() => { editingRef.current = editing; }, [editing]);
  useEffect(() => {
    if (!container.current) return;
    let disposed = false;
    const timeout = window.setTimeout(() => { if (!disposed) setMapState("failed"); }, 12000);
    void import("maplibre-gl").then((library) => {
      if (disposed || !container.current) return;
      library.setWorkerUrl("/maplibre/maplibre-gl-worker.mjs");
      libraryRef.current = library;
      const map = new library.Map({
        container: container.current,
        style: DUINDORP_NIGHT_STYLE,
        center: coordinate ?? addressCoordinate ?? DUINDORP_CENTER,
        zoom: 16,
        cooperativeGestures: true,
        attributionControl: { compact: true },
      });
      mapRef.current = map;
      map.addControl(new library.NavigationControl({ showCompass: false }), "top-right");
      map.once("load", () => {
        if (disposed) return;
        window.clearTimeout(timeout);
        setMapState("ready");
      });
      map.on("click", (event) => {
        if (!editingRef.current) return;
        const next: Coordinate = [event.lngLat.lng, event.lngLat.lat];
        setDraft(next);
        markerRef.current?.setLngLat(next);
      });
      map.on("error", () => { if (!disposed) setMapState("failed"); });
    }).catch(() => { if (!disposed) setMapState("failed"); });
    return () => {
      disposed = true;
      window.clearTimeout(timeout);
      markerRef.current?.remove();
      markerRef.current = null;
      mapRef.current?.remove();
      mapRef.current = null;
      libraryRef.current = null;
    };
  }, [addressCoordinate, coordinate]);

  useEffect(() => {
    const map = mapRef.current;
    const library = libraryRef.current;
    if (!map || !library || mapState !== "ready") return;
    markerRef.current?.remove();
    const position = editing ? effectiveDraft : coordinate;
    if (!position || !validCoordinate(position)) return;
    const pin = document.createElement("button");
    pin.type = "button";
    pin.className = `location-editor-pin kind-${markerKind}${editing ? " is-editing" : ""}`;
    pin.style.setProperty("--marker-color", color ?? "#e7ad70");
    pin.setAttribute("aria-label", `${label}${editing ? ", versleepbare routingmarker" : ", routingmarker"}`);
    pin.textContent = markerKind === "final" ? "★" : markerKind === "portal" ? "P" : "S";
    const marker = new library.Marker({ element: pin, anchor: "bottom", draggable: editing })
      .setLngLat(position)
      .addTo(map);
    marker.on("dragend", () => {
      const next = marker.getLngLat();
      setDraft([next.lng, next.lat]);
    });
    markerRef.current = marker;
    if (editing || coordinate) map.easeTo({ center: position, zoom: Math.max(map.getZoom(), 16), duration: 350 });
    return () => { marker.remove(); if (markerRef.current === marker) markerRef.current = null; };
  }, [color, coordinate, editing, effectiveDraft, label, mapState, markerKind]);

  function begin() {
    setDraft(coordinate ?? addressCoordinate ?? DUINDORP_CENTER);
    setReason(savedReason ?? "");
    setRestore(false);
    setEditing(true);
  }

  function cancel() {
    setDraft(coordinate);
    setReason(savedReason ?? "");
    setRestore(false);
    setEditing(false);
  }

  async function save() {
    const next = restore ? addressCoordinate : draft;
    if (!next || (!restore && reason.trim().length < 5)) return;
    await onSave({ latitude: next[1], longitude: next[0], reason: restore ? "Routingmarker hersteld vanaf het officiële adres" : reason.trim(), restoreFromAddress: restore });
    setEditing(false);
    setRestore(false);
  }

  return <section className="location-editor" aria-label={`Locatie-editor voor ${label}`}>
    <div className="location-editor-map" ref={container} />
    {mapState !== "ready" && <div className="location-editor-map-state" role="status">
      <MapPin />{mapState === "failed" ? "De kaart is tijdelijk niet beschikbaar. De lijst en coördinaten blijven bruikbaar." : "Kaart laden…"}
    </div>}
    <div className="location-editor-panel">
      <div>
        <span className="location-editor-label"><Crosshair />Routingpositie</span>
        <strong>{coordinate ? "Marker ingesteld" : "Marker ontbreekt"}</strong>
        <small>{drift === null ? "Geen afstand tot een officieel adres beschikbaar." : drift === 0 ? "Marker staat op het officiële adres." : `Marker staat ${drift} meter van het officiële adres.`}</small>
        {savedReason && !editing && <small>{savedReason}</small>}
      </div>
      {!editing ? <button className="btn outline" type="button" onClick={begin}><MapPin />Marker verplaatsen</button> : <div className="location-editor-controls">
        <p>Versleep de marker of klik op de gewenste ingang. Het officiële adres verandert niet.</p>
        <label className="field"><span>Reden voor de afwijkende routingpositie</span><input value={reason} onChange={(event) => { setReason(event.target.value); setRestore(false); }} placeholder="Bijvoorbeeld: ingang hof aan zuidzijde" /></label>
        <details>
          <summary>Technische locatiegegevens</summary>
          <div className="location-editor-coordinates">
            <label className="field"><span>Breedtegraad</span><input inputMode="decimal" value={effectiveDraft[1]} onChange={(event) => setDraft([effectiveDraft[0], Number(event.target.value)])} /></label>
            <label className="field"><span>Lengtegraad</span><input inputMode="decimal" value={effectiveDraft[0]} onChange={(event) => setDraft([Number(event.target.value), effectiveDraft[1]])} /></label>
          </div>
        </details>
        <div className="actions">
          {addressCoordinate && <button className="btn outline" type="button" onClick={() => { setDraft(addressCoordinate); setRestore(true); setReason("Routingmarker hersteld vanaf het officiële adres"); }}><RotateCcw />Herstel vanaf adres</button>}
          <button className="btn outline" type="button" onClick={cancel}><X />Annuleren</button>
          <button className="btn" type="button" disabled={busy || !draft || (!restore && reason.trim().length < 5)} onClick={() => void save()}><Save />Locatie opslaan</button>
        </div>
      </div>}
    </div>
  </section>;
}
