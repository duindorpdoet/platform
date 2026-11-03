"use client";
import { useState } from "react";
import { Pause, Play } from "lucide-react";
export function CalmToggle() {
  const [calm, setCalm] = useState(false);
  return <button type="button" className="fn-calm-toggle" aria-pressed={calm} onClick={() => { const next = !calm; setCalm(next); document.documentElement.classList.toggle("fn-calm", next); }}>{calm ? <Play size={14} /> : <Pause size={14} />}<span>{calm ? "Sfeer hervatten" : "Rustige weergave"}</span></button>;
}
