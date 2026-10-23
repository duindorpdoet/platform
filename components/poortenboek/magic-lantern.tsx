"use client";

import { useId, type CSSProperties } from "react";
import "../../modern/book-lantern.css";

export const lanternPalette = {
  amber: { label: "amber", light: "#fff2ba", main: "#ffc36c", deep: "#b76523" },
  cyan: { label: "cyaan", light: "#dcffff", main: "#74e7f2", deep: "#247b9c" },
  violet: { label: "paars", light: "#f2e6ff", main: "#bca0ff", deep: "#6942b8" },
  emerald: { label: "smaragdgroen", light: "#d5ffe8", main: "#6fe1ad", deep: "#267e63" },
  rose: { label: "roze", light: "#ffe5f0", main: "#f8a3c3", deep: "#b34277" },
  moonlight: { label: "maanlicht", light: "#ffffff", main: "#d5e4ff", deep: "#728ab9" },
} as const;

const shapeNames = { classic: "Klassieke lantaarn", moon: "Maanlantaarn", tower: "Torenlantaarn", crystal: "Kristallantaarn" } as const;

/** A code-native lantern: choosing its silhouette and light changes the artwork immediately. */
export function MagicLantern({ shape, color, compact = false }: { shape: string; color: string; compact?: boolean }) {
  const uid = `lantern-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const selectedShape = Object.hasOwn(shapeNames, shape) ? shape as keyof typeof shapeNames : "classic";
  const selectedColor = Object.hasOwn(lanternPalette, color) ? color as keyof typeof lanternPalette : "amber";
  const palette = lanternPalette[selectedColor];
  const gradient = (id: string) => `url(#${uid}-${id})`;
  const label = `${shapeNames[selectedShape]} met ${palette.label} licht`;
  return <figure className={`pb-magic-lantern${compact ? " compact" : ""}`} data-lantern-shape={selectedShape} data-lantern-color={selectedColor} style={{ "--lantern-light": palette.main, "--lantern-halo": `${palette.main}28` } as CSSProperties}>
    <svg viewBox="0 0 240 280" role="img" aria-labelledby={`${uid}-title ${uid}-description`} focusable="false">
      <title id={`${uid}-title`}>{label}</title>
      <desc id={`${uid}-description`}>Een eigen magische lantaarn. De vorm en lichtkleur volgen jouw keuze.</desc>
      <defs>
        <radialGradient id={`${uid}-halo`}><stop offset="0" stopColor={palette.main} stopOpacity=".32"/><stop offset=".65" stopColor={palette.main} stopOpacity=".07"/><stop offset="1" stopColor={palette.main} stopOpacity="0"/></radialGradient>
        <linearGradient id={`${uid}-metal`} x1="0" y1="0" x2="1" y2="1"><stop stopColor="#64778c"/><stop offset=".2" stopColor="#293e56"/><stop offset=".58" stopColor="#101d30"/><stop offset=".86" stopColor="#3f526b"/><stop offset="1" stopColor="#162338"/></linearGradient>
        <linearGradient id={`${uid}-edge`} x1="0" y1="0" x2="1" y2="0"><stop stopColor="#7189a0"/><stop offset=".45" stopColor="#b4c4d1"/><stop offset="1" stopColor="#34475e"/></linearGradient>
        <linearGradient id={`${uid}-glass`} x1="0" y1="0" x2="1" y2="1"><stop stopColor={palette.light} stopOpacity=".83"/><stop offset=".42" stopColor={palette.main} stopOpacity=".72"/><stop offset="1" stopColor={palette.deep} stopOpacity=".82"/></linearGradient>
        <radialGradient id={`${uid}-flame`}><stop stopColor="#ffffff"/><stop offset=".38" stopColor={palette.light}/><stop offset="1" stopColor={palette.main}/></radialGradient>
        <filter id={`${uid}-soft`} x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="7"/></filter>
      </defs>
      <ellipse cx="120" cy="151" rx="116" ry="122" fill={gradient("halo")} className="pb-lantern-halo"/>
      <ellipse cx="120" cy="253" rx={selectedShape === "moon" ? "49" : "59"} ry="9" fill="#000000" opacity=".23"/>
      <g className="pb-lantern-object">
        {selectedShape === "classic" && <>
          <path d="M102 65V45a18 18 0 0 1 36 0v20" fill="none" stroke={gradient("edge")} strokeWidth="5"/>
          <path d="M86 96 96 67h48l10 29 12 14v108l-18 19H92l-18-19V110Z" fill={gradient("metal")} stroke="#6d8497" strokeWidth="1.7"/>
          <path d="m87 110 11-10h44l11 10v100l-12 11h-42l-12-11Z" fill={gradient("glass")}/>
          <ellipse cx="120" cy="174" rx="27" ry="40" fill={palette.main} opacity=".64" filter={gradient("soft")}/>
          <path d="M120 126c-11 19-21 26-21 43a21 21 0 0 0 42 0c0-15-11-25-13-34-2 9-8 13-10 16 3-9 4-15 2-25Z" fill={gradient("flame")} className="pb-lantern-flame"/>
          <path d="M100 101v120m40-120v120M84 110h72M82 211h76M95 68h50M91 83h58" fill="none" stroke={gradient("edge")} strokeWidth="4"/>
          <path d="m93 227 8 9h38l8-9" fill="none" stroke="#8d9eac" strokeWidth="2"/>
          <path d="m108 115 9-7v27l-9 7Z" fill="#fff" opacity=".23"/>
        </>}
        {selectedShape === "moon" && <>
          <path d="M112 66V47a12 12 0 0 1 24 0v19" fill="none" stroke={gradient("edge")} strokeWidth="4"/>
          <path d="M135 69c-56-7-89 32-89 80 0 52 44 93 95 83 17-3 35-13 46-28-42 12-80-19-80-61 0-30 13-56 28-74Z" fill={gradient("metal")} stroke="#70859d" strokeWidth="2"/>
          <path d="M113 83c-31 6-54 32-54 67 0 39 29 70 64 71-29-16-44-42-42-73 2-25 14-48 32-65Z" fill={gradient("glass")} stroke={palette.light} strokeOpacity=".4"/>
          <path d="M91 97c-22 18-31 43-27 67" fill="none" stroke="#fff" strokeOpacity=".35" strokeWidth="3" strokeLinecap="round"/>
          <path d="m151 119 7 15 16 3-12 11 2 16-14-8-14 7 3-16-11-12 16-2Z" fill={gradient("glass")} stroke={palette.light} strokeWidth="1.5"/>
          <path d="M151 97v20m25 63 4 8 9 1-7 6 1 9-8-5-8 4 2-9-6-6 9-1Z" fill={palette.light} stroke={palette.main} strokeWidth="1.2"/>
          <circle cx="149" cy="145" r="15" fill={palette.main} opacity=".4" filter={gradient("soft")}/>
          <path d="m115 234 5 10 6-10" fill={gradient("edge")}/>
        </>}
        {selectedShape === "tower" && <>
          <path d="M120 27v15" stroke={gradient("edge")} strokeWidth="3"/><circle cx="120" cy="25" r="4" fill={palette.main}/>
          <path d="m86 98 34-59 34 59Z" fill={gradient("metal")} stroke="#7890a7" strokeWidth="1.7"/>
          <path d="m119 51 1 47h25Z" fill="#58738f" opacity=".5"/>
          <path d="M86 101h68v129H86Z" fill={gradient("metal")} stroke="#70899f" strokeWidth="1.7"/>
          <path d="M61 126v-14h10v10h9v-10h10v112H61Zm89-14h10v10h9v-10h10v112h-29Z" fill={gradient("metal")} stroke="#70899f" strokeWidth="1.5"/>
          <path d="M103 133a17 17 0 0 1 34 0v30h-34Zm0 65a17 17 0 0 1 34 0v27h-34Z" fill={gradient("glass")} stroke={palette.light} strokeOpacity=".5"/>
          <path d="M120 118v45m-17-20h34m-17 39v43" stroke="#465e75" strokeWidth="3"/>
          <path d="M70 151h11v24H70Zm89 0h11v24h-11Z" fill={gradient("glass")}/>
          <path d="M80 101h80M82 176h76M69 230h102l6 10H63Z" fill={gradient("metal")} stroke={gradient("edge")} strokeWidth="2"/>
          <circle cx="120" cy="148" r="19" fill={palette.main} opacity=".38" filter={gradient("soft")}/>
          <path d="M95 107v59" stroke="#fff" opacity=".12" strokeWidth="3"/>
        </>}
        {selectedShape === "crystal" && <>
          <path d="M109 62V43a11 11 0 0 1 22 0v19" fill="none" stroke={gradient("edge")} strokeWidth="4"/>
          <path d="m120 63 47 41 16 67-63 73-63-73 16-67Z" fill={gradient("glass")} stroke={palette.light} strokeWidth="2" strokeOpacity=".8"/>
          <path d="m120 63-21 56 21 113 22-113Z" fill={palette.light} opacity=".4"/>
          <path d="m73 104 26 15-42 52 63 73-21-125 21-56m47 41-25 15 41 52-63 73 22-125-22-56M57 171h126M73 104h94" fill="none" stroke={palette.light} strokeWidth="1.2" strokeOpacity=".55"/>
          <path d="m120 103-13 53 13 35 14-35Z" fill={gradient("flame")} className="pb-lantern-flame"/>
          <ellipse cx="120" cy="156" rx="24" ry="33" fill={palette.main} opacity=".5" filter={gradient("soft")}/>
          <path d="m99 119 9-29-22 20Z" fill="#fff" opacity=".7"/>
          <path d="m104 63 16-8 16 8-2 12-14-6-14 6Z" fill={gradient("metal")} stroke={gradient("edge")} strokeWidth="1.6"/>
        </>}
      </g>
      <g fill={palette.light} className="pb-lantern-sparks" aria-hidden="true"><circle className="spark-a" cx="42" cy="113" r="2"/><circle className="spark-b" cx="191" cy="94" r="2.5"/><circle className="spark-c" cx="185" cy="213" r="1.6"/><path className="spark-d" d="m51 207 2-5 2 5 5 2-5 2-2 5-2-5-5-2Z"/><circle className="spark-e" cx="161" cy="47" r="1.4"/></g>
    </svg>
    {!compact && <figcaption><span>{shapeNames[selectedShape]}</span><small>{palette.label} licht · helemaal van jou</small></figcaption>}
  </figure>;
}
