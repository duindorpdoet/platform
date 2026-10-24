"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Check, Crosshair, MapPin, RotateCcw, Save, X } from "lucide-react";
import { DUINDORP_CENTER, DUINDORP_NIGHT_STYLE, validCoordinate } from "@/lib/maps/duindorp-map";
import { locationCoordinate, locationError, parseCoordinatePart, type StartPointReadiness } from "@/lib/domain/location-readiness";

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
  expectedVersion?: number;
};

export function LocationEditor({
  label,
  coordinate: rawCoordinate,
  addressCoordinate: rawAddressCoordinate,
  markerKind = "start",
  color = "#e7ad70",
  reason: savedReason,
  onSave,
  busy = false,
  version,
  readiness,
  onConfirm,
  staged = false,
}: {
  label: string;
  coordinate: Coordinate | null;
  addressCoordinate: Coordinate | null;
  markerKind?: "start" | "portal" | "final";
  color?: string | null;
  reason?: string | null;
  onSave: (change: LocationSave) => Promise<boolean | void> | void;
  busy?: boolean;
  version?: number;
  readiness?: StartPointReadiness;
  onConfirm?: () => void;
  staged?: boolean;
}) {
  const longitude = rawCoordinate?.[0] ?? null, latitude = rawCoordinate?.[1] ?? null;
  const addressLongitude = rawAddressCoordinate?.[0] ?? null, addressLatitude = rawAddressCoordinate?.[1] ?? null;
  const coordinate = useMemo(() => locationCoordinate(longitude, latitude), [longitude, latitude]);
  const addressCoordinate = useMemo(() => locationCoordinate(addressLongitude, addressLatitude), [addressLongitude, addressLatitude]);
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("maplibre-gl").Map | null>(null);
  const markerRef = useRef<import("maplibre-gl").Marker | null>(null);
  const libraryRef = useRef<typeof import("maplibre-gl") | null>(null);
  const editingRef = useRef(false);
  const [mapState, setMapState] = useState<"loading" | "ready" | "failed">("loading");
  const [mapGeneration, setMapGeneration] = useState(0);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<Coordinate | null>(coordinate);
  const [reason, setReason] = useState(savedReason ?? "");
  const [restore, setRestore] = useState(false);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [editVersion, setEditVersion] = useState(version);
  const [latitudeInput, setLatitudeInput] = useState(coordinate?.[1].toString() ?? "");
  const [longitudeInput, setLongitudeInput] = useState(coordinate?.[0].toString() ?? "");
  const chooseDraft = useCallback((value: Coordinate | null) => {
    setDraft(value);
    setLatitudeInput(value?.[1].toString() ?? "");
    setLongitudeInput(value?.[0].toString() ?? "");
  }, []);
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
        setMapGeneration(value => value + 1);
      });
      map.on("click", (event) => {
        if (!editingRef.current) return;
        const next: Coordinate = [event.lngLat.lng, event.lngLat.lat];
        chooseDraft(next);
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
  }, [addressCoordinate, coordinate, chooseDraft]);

  useEffect(() => {
    const map = mapRef.current;
    const library = libraryRef.current;
    if (!map || !library || mapState !== "ready") return;
    markerRef.current?.remove();
    const position = editing ? draft : coordinate;
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
      chooseDraft([next.lng, next.lat]);
    });
    markerRef.current = marker;
    if (editing || coordinate) map.easeTo({ center: position, zoom: Math.max(map.getZoom(), 16), duration: 350 });
    return () => { marker.remove(); if (markerRef.current === marker) markerRef.current = null; };
  }, [color, coordinate, editing, draft, label, mapState, mapGeneration, markerKind, chooseDraft]);

  function begin() {
    chooseDraft(coordinate ?? addressCoordinate);
    setEditVersion(version);
    setError("");
    setReason(savedReason ?? "");
    setRestore(false);
    setEditing(true);
  }

  function cancel() {
    chooseDraft(coordinate);
    setError("");
    setReason(savedReason ?? "");
    setRestore(false);
    setEditing(false);
  }

  async function save() {
    const next = restore ? addressCoordinate : draft;
    if (!validCoordinate(next) || (!restore && reason.trim().length < 5) || saving || busy) return;
    setSaving(true); setError("");
    try {
      const saved = await onSave({ latitude: next[1], longitude: next[0], reason: restore ? "Routingmarker hersteld vanaf het officiële adres" : reason.trim(), restoreFromAddress: restore, expectedVersion: editVersion });
      if (saved === false) return;
      setEditing(false); setRestore(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Locatie niet opgeslagen. Controleer de verbinding en probeer opnieuw.");
    } finally { setSaving(false); }
  }

  function changeCoordinate(latitude: string, longitude: string) {
    setLatitudeInput(latitude); setLongitudeInput(longitude); setRestore(false);
    const lat = parseCoordinatePart(latitude), lon = parseCoordinatePart(longitude);
    setDraft(lat === null || lon === null ? null : [lon, lat]);
  }

  return <section className="location-editor" aria-label={`Locatie-editor voor ${label}`}>
    <div className="location-editor-map" ref={container} />
    {mapState !== "ready" && <div className="location-editor-map-state" role="status">
      <MapPin />{mapState === "failed" ? "De kaart is tijdelijk niet beschikbaar. De lijst en coördinaten blijven bruikbaar." : "Kaart laden…"}
    </div>}
    <div className="location-editor-panel">
      <div>
        <span className="location-editor-label"><Crosshair />Routingpositie</span>
        <strong>{staged ? "Positie in formulier" : readiness?.confirmed ? "Locatie bevestigd" : coordinate ? "Positie opgeslagen" : "Geen opgeslagen positie"}</strong>
        <small>{staged ? "Sla het formulier op om deze positie te bewaren." : `Bron: ${readiness?.location.source === "manual" || savedReason ? "handmatige routingpositie" : "officiële adrespositie"}.`}</small>
        {readiness && coordinate && !readiness.confirmed && <small>Controleer de huidige pin en bevestig deze marker.</small>}
        {readiness?.confirmationReason && <small role="alert">{locationError(readiness.confirmationReason)}</small>}
        <small>{drift === null ? "Geen afstand tot een officieel adres beschikbaar." : drift === 0 ? "Marker staat op het officiële adres." : `Marker staat ${drift} meter van het officiële adres.`}</small>
        {savedReason && !editing && <small>{savedReason}</small>}
      </div>
      {!editing ? <div className="actions">
        {onConfirm && readiness && !readiness.confirmed && <button className="btn" type="button" disabled={busy || !readiness.canConfirm} onClick={onConfirm}><Check />Deze marker bevestigen</button>}
        <button className="btn outline" type="button" disabled={busy || saving} onClick={begin}><MapPin />{coordinate ? "Marker verplaatsen" : "Marker plaatsen"}</button>
      </div> : <div className="location-editor-controls">
        <p>Versleep de marker of klik op de gewenste ingang. Het officiële adres verandert niet.</p>
        <label className="field"><span>Reden voor de afwijkende routingpositie</span><input value={reason} onChange={(event) => { setReason(event.target.value); setRestore(false); }} placeholder="Bijvoorbeeld: ingang hof aan zuidzijde" /></label>
        <details>
          <summary>Technische locatiegegevens</summary>
          <div className="location-editor-coordinates">
            <label className="field"><span>Breedtegraad</span><input inputMode="decimal" value={latitudeInput} onChange={(event) => changeCoordinate(event.target.value, longitudeInput)} /></label>
            <label className="field"><span>Lengtegraad</span><input inputMode="decimal" value={longitudeInput} onChange={(event) => changeCoordinate(latitudeInput, event.target.value)} /></label>
          </div>
        </details>
        <div className="actions">
          {addressCoordinate && <button className="btn outline" type="button" disabled={busy || saving} onClick={() => { chooseDraft(addressCoordinate); setRestore(true); setReason("Routingmarker hersteld vanaf het officiële adres"); }}><RotateCcw />Herstel vanaf adres</button>}
          <button className="btn outline" type="button" disabled={busy || saving} onClick={cancel}><X />Annuleren</button>
          <button className="btn" type="button" disabled={busy || saving || !validCoordinate(draft) || (!restore && reason.trim().length < 5)} onClick={() => void save()}><Save />{staged ? "Positie overnemen" : "Locatie opslaan"}</button>
        </div>
        {editing && editVersion !== version && <p role="alert">Deze locatie is intussen gewijzigd. Annuleer en controleer de nieuwste positie. Opslaan met de oude versie wordt geweigerd.</p>}
        {error && <p className="form-warning" role="alert">{error}</p>}
      </div>}
    </div>
  </section>;
}
