"use client";
import { useCalmPreference } from "./motion-preference";
import { Pause, Play } from "lucide-react";
export function CalmToggle() {
  const { calm, paused, system, setPaused } = useCalmPreference();
  return <button type="button" className="fn-calm-toggle" aria-pressed={calm} disabled={system} onClick={() => setPaused(!paused)}>{calm ? <Play size={14} /> : <Pause size={14} />}<span>{system ? "Rustige weergave" : paused ? "Sfeer hervatten" : "Rustige weergave"}</span></button>;
}
