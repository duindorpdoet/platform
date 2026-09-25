"use client";

import { useEffect, useMemo, useState } from "react";
import { Pause, Play, Route, Sparkles } from "lucide-react";
import { NightMap } from "@/components/maps/night-map";
import type { NightMapPortal } from "@/lib/maps/duindorp-map";

const DEMO_PORTALS: readonly NightMapPortal[] = [
  { id: "demo-heks", code: "P-03", name: "De Fluisterende Ketel", world: "Heksenrijk", coordinate: [4.2549, 52.09115], status: "open", description: "Een ketel borrelt, spreuken lichten op en niets is helemaal wat het lijkt.", demo: true },
  { id: "demo-doden", code: "P-07", name: "De Klok Zonder Tijd", world: "Dodenrijk", coordinate: [4.2582, 52.09135], status: "open", description: "Een vergeten klok telt af terwijl schaduwen langzaam dichterbij komen.", demo: true },
  { id: "demo-circus", code: "P-11", name: "Circus van de Schaduw", world: "Circuswereld", coordinate: [4.26155, 52.09015], status: "open", description: "Achter het doek wacht een wonderlijk circus met een griezelige glimlach.", demo: true },
  { id: "demo-zone", code: "P-14", name: "Laboratorium 13", world: "Besmette zone", coordinate: [4.26045, 52.08795], status: "open", description: "Waarschuwingslampen knipperen. Durven jullie het besmette laboratorium binnen?",
    demo: true },
  { id: "demo-geest", code: "P-18", name: "De Verloren Ziel", world: "Geestenwereld", coordinate: [4.25675, 52.08765], status: "open", description: "Blauwe nevel wijst de weg naar een ziel die al jaren op bezoek wacht.", demo: true },
  { id: "demo-vampier", code: "P-24", name: "Het Rode Balkon", world: "Vampierrijk", coordinate: [4.25335, 52.08925], status: "open", description: "Onder rood maanlicht opent het balkon voor bezoekers met stalen zenuwen.", demo: true },
] as const;

const SCENES = [
  [0, 2, 4, 5],
  [0, 1, 4],
  [1, 3, 5],
  [0, 3, 4, 5],
  [1, 2, 4],
  [0, 2, 3, 5],
] as const;

function nextScene(current: number) {
  return (current + 1) % SCENES.length;
}

export function PublicMap({ compact = false }: { compact?: boolean }) {
  const [scene, setScene] = useState(0);
  const [playing, setPlaying] = useState(true);

  useEffect(() => {
    if (compact) return;
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const applyMotionPreference = () => { if (media.matches) setPlaying(false); };
    applyMotionPreference();
    media.addEventListener("change", applyMotionPreference);
    return () => media.removeEventListener("change", applyMotionPreference);
  }, [compact]);

  useEffect(() => {
    if (compact || !playing) return;
    const timer = window.setInterval(() => setScene(nextScene), 6500);
    return () => window.clearInterval(timer);
  }, [compact, playing]);

  const activePortals = useMemo(() => SCENES[scene].map((index) => DEMO_PORTALS[index]), [scene]);
  const route = useMemo(() => activePortals.map((portal) => portal.coordinate).filter((coordinate): coordinate is [number, number] => coordinate !== null), [activePortals]);

  if (compact) {
    return <NightMap variant="preview" ariaLabel="Interactieve wijkkaart van Duindorp zonder privé-adressen" />;
  }

  return <section className="public-map-experience" aria-label="Fictieve live-demonstratie van de Halloweenkaart" data-demo-scene={scene}>
    <div className="public-map-stage">
      <NightMap
        variant="public"
        portals={activePortals}
        route={route}
        routeAnimated={playing}
        ariaLabel="Interactieve fictieve demonstratiekaart van Duindorp"
      />
      <div className="public-map-demo-label"><Sparkles size={15} aria-hidden="true" /><span>Fictieve live-demo</span></div>
    </div>
    <div className="public-map-livebar">
      <div className="public-map-livecopy">
        <span className={playing ? "is-live" : ""}><i />{playing ? "De kaart leeft" : "Animatie gepauzeerd"}</span>
        <strong>{activePortals.length} voorbeeldpoorten zichtbaar</strong>
        <p>Poorten komen en gaan; de koperkleurige lijn toont een tijdelijke voorbeeldroute.</p>
      </div>
      <div className="public-map-live-actions">
        <button type="button" className="btn outline" onClick={() => setPlaying((current) => !current)} aria-pressed={!playing}>
          {playing ? <Pause aria-hidden="true" /> : <Play aria-hidden="true" />}{playing ? "Pauzeren" : "Verder spelen"}
        </button>
        <button type="button" className="btn outline" onClick={() => setScene(nextScene)}>
          <Route aria-hidden="true" />Nieuwe voorbeeldroute
        </button>
      </div>
    </div>
  </section>;
}
