"use client";
import { useState } from "react";
import { amsterdamDateTimeInput, amsterdamInputToIso } from "@/lib/time/amsterdam";

export function AmsterdamDateTime({label,value,onChange,onValidity}:{label:string;value:string|null;onChange:(value:string|null)=>void;onValidity:(valid:boolean)=>void}) {
  const [raw,setRaw]=useState(()=>amsterdamDateTimeInput(value));
  const [error,setError]=useState(false);
  return <label className="field"><span>{label}</span><input type="datetime-local" value={raw} aria-invalid={error}
    onChange={event=>{
      const next=event.target.value;setRaw(next);
      const parsed=next?amsterdamInputToIso(next):null;const invalid=!!next&&!parsed;
      setError(invalid);onValidity(!invalid);
      event.target.setCustomValidity(invalid?"Kies een eenduidige Nederlandse tijd buiten het ontbrekende of dubbele uur.":"");
      if (!invalid) onChange(parsed);
    }}/>{error&&<small role="alert">Deze Nederlandse tijd ontbreekt of komt twee keer voor door de klokwissel. Kies een andere tijd; je invoer is bewaard.</small>}</label>;
}
