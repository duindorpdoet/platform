"use client";

import { useState } from "react";
import { ArrowUpRight, ChevronLeft, ChevronRight, DoorOpen, Flame, ShieldCheck } from "lucide-react";
import { worlds } from "@/features/content/public-content";

type Props = { onNavigate: (path: string) => void };

export function WorldExplorer({ onNavigate }: Props) {
  const [selected, setSelected] = useState(4);
  const world = worlds[selected];

  return (
    <div className="world-explorer" style={{ "--world": world.color } as React.CSSProperties}>
      <div className="explorer-selectors" role="tablist" aria-label="Kies een wereld">
        {worlds.map((item, index) => (
          <button
            key={item.slug}
            type="button"
            role="tab"
            aria-selected={selected === index}
            className="explorer-selector"
            style={{ "--world": item.color } as React.CSSProperties}
            onClick={() => setSelected(index)}
          >
            <img src={`/images/world-${index}.webp`} alt="" loading="lazy" />
            <span className="explorer-selector-copy">
              <small>WERELD {String(index + 1).padStart(2, "0")}</small>
              <strong>{item.name}</strong>
              <span>{item.subtitle}</span>
            </span>
          </button>
        ))}
      </div>
      <section className="explorer-stage" role="tabpanel" aria-label={world.name}>
        <div className="explorer-scene" style={{ "--world": world.color } as React.CSSProperties}>
          <div className="explorer-art">
            <img src={`/images/world-${selected}.webp`} alt={world.name} />
            <span className="explorer-aura" />
          </div>
          <div className="explorer-copy">
            <span className="explorer-eyebrow">WERELD {String(selected + 1).padStart(2, "0")} · {world.subtitle}</span>
            <h3>{world.name}</h3>
            <p>{world.story}</p>
            <div className="explorer-facts">
              <span><DoorOpen size={17} /> Meerdere unieke poorten</span>
              <span><Flame size={17} /> Spanning {world.intensity} / 4</span>
            </div>
            <div className="explorer-warnings">
              {world.warnings.map((warning) => <span key={warning}>{warning}</span>)}
            </div>
            <button className="btn explorer-enter" onClick={() => onNavigate(`/werelden/${world.slug}`)}>
              Betreed deze wereld <ArrowUpRight size={18} />
            </button>
          </div>
          <span className="explorer-watermark" aria-hidden="true">{String(selected + 1).padStart(2, "0")}</span>
        </div>
        <div className="explorer-controls">
          <span><b>{String(selected + 1).padStart(2, "0")}</b> / {String(worlds.length).padStart(2, "0")}</span>
          <button aria-label="Vorige wereld" onClick={() => setSelected((selected + worlds.length - 1) % worlds.length)}><ChevronLeft /></button>
          <button aria-label="Volgende wereld" onClick={() => setSelected((selected + 1) % worlds.length)}><ChevronRight /></button>
        </div>
      </section>
      <div className="explorer-footer">
        <span><ShieldCheck size={15} /> Overslaan mag altijd.</span>
        <span>Zes themawerelden · aantallen poorten zijn configureerbaar</span>
      </div>
    </div>
  );
}
