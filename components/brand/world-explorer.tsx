"use client";

import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { ArrowUpRight, ChevronLeft, ChevronRight, DoorOpen, Flame, ShieldCheck } from "lucide-react";
import { worlds } from "@/features/content/public-content";

type Props = { onNavigate: (path: string) => void };

export function WorldExplorer({ onNavigate }: Props) {
  const [selected, setSelected] = useState(4);
  const world = worlds[selected];
  const selectors = useRef<HTMLDivElement>(null);
  const tabs = useRef<Array<HTMLButtonElement | null>>([]);
  useEffect(() => {
    const strip = selectors.current;
    const tab = tabs.current[selected];
    if (!strip || !tab) return;
    const left = tab.offsetLeft - strip.offsetLeft;
    if (left < strip.scrollLeft || left + tab.offsetWidth > strip.scrollLeft + strip.clientWidth) {
      strip.scrollTo({ left: left - (strip.clientWidth - tab.offsetWidth) / 2, behavior: "instant" });
    }
  }, [selected]);
  function navigateTabs(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    const next = event.key === "ArrowRight" ? (index + 1) % worlds.length
      : event.key === "ArrowLeft" ? (index + worlds.length - 1) % worlds.length
      : event.key === "Home" ? 0 : event.key === "End" ? worlds.length - 1 : null;
    if (next === null) return;
    event.preventDefault();
    setSelected(next);
    tabs.current[next]?.focus({ preventScroll: true });
  }

  return (
    <div className="world-explorer" style={{ "--world": world.color } as React.CSSProperties}>
      <div ref={selectors} className="explorer-selectors" role="tablist" aria-label="Kies een wereld">
        {worlds.map((item, index) => (
          <button
            key={item.slug}
            type="button"
            ref={(element) => { tabs.current[index] = element; }}
            id={`world-tab-${item.slug}`}
            aria-controls="world-panel"
            tabIndex={selected === index ? 0 : -1}
            onKeyDown={(event) => navigateTabs(event, index)}
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
      <section id="world-panel" className="explorer-stage" role="tabpanel" aria-labelledby={`world-tab-${world.slug}`} tabIndex={0}>
        <div key={world.slug} className="explorer-scene" style={{ "--world": world.color } as React.CSSProperties}>
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
              <span><Flame size={17} /> Spanningsniveau {world.intensity} / 4</span>
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
        <span>Zes themawerelden · kies wat bij jullie past</span>
      </div>
    </div>
  );
}
