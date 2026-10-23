"use client";
import { useId,useState } from "react";
import { ShieldCheck,X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { AdminDialog } from "./admin-dialog";

export function PortalWalkingConnection({eventSlug,portal,onChanged}:{eventSlug:string;portal:{id:string;version:number;name:string;walkingConnectionVerified?:boolean;approvalStatus:string};onChanged:()=>void|Promise<void>}) {
  const titleId=useId();const [open,setOpen]=useState(false);const [approach,setApproach]=useState("");
  const [checked,setChecked]=useState(false);const [stepFree,setStepFree]=useState(false);const [busy,setBusy]=useState(false);const [notice,setNotice]=useState("");
  async function verify() {
    const client=createClient();if (!client||!checked||!approach.trim()) return;
    setBusy(true);setNotice("");
    try {
      const {error}=await client.schema("api").rpc("admin_verify_portal_walking_connection",{
        _event_slug:eventSlug,_portal_id:portal.id,_expected_version:portal.version,
        _safe_connection_checked:true,_safe_approach:approach.trim(),_step_free_checked:stepFree,
      });
      if (error) {
        setNotice(error.message.includes("CONNECTION_TOO_FAR")?"Er is geen gecontroleerde wandelroute binnen 75 meter. Deze verbinding is niet goedgekeurd.":error.message.includes("STALE_VERSION")?"De poort is intussen gewijzigd. Vernieuw de gegevens en controleer opnieuw.":"De loopverbinding is niet goedgekeurd. Controleer de locatie en goedkeuring van de poort.");
        if (error.message.includes("STALE_VERSION")) await onChanged();return;
      }
      await onChanged();setOpen(false);setChecked(false);
    } finally {setBusy(false);}
  }
  return <><button className="btn outline" type="button" disabled={portal.approvalStatus!=="approved"} onClick={()=>{setNotice("");setOpen(true);}}><ShieldCheck/>{portal.walkingConnectionVerified?"Loopaansluiting gecontroleerd":"Loopaansluiting controleren"}</button>
    {open&&<AdminDialog labelledBy={titleId} close={()=>{if (!busy)setOpen(false);}}><header><div><p className="kicker">Veilige route</p><h3 id={titleId}>{portal.name}</h3></div><button type="button" className="icon-button" aria-label="Controle sluiten" disabled={busy} onClick={()=>setOpen(false)}><X/></button></header>
      <p>Controleer ter plekke hoe de groep vanaf de bestaande wandelroute bij deze poort komt. De aansluiting moet binnen 75 meter liggen. Een opgeslagen kaartmarker geeft op zichzelf geen goedkeuring.</p>
      <label className="field"><span>Concrete veilige aanloop</span><textarea data-initial-focus value={approach} maxLength={1000} onChange={event=>setApproach(event.target.value)} placeholder="Beschrijf de veilige ingang, oversteek en aanloop."/></label>
      <label className="check-row"><input type="checkbox" checked={checked} onChange={event=>setChecked(event.target.checked)}/><span>Ik heb deze loopaansluiting gecontroleerd en veilig bevonden.</span></label>
      <label className="check-row"><input type="checkbox" checked={stepFree} onChange={event=>setStepFree(event.target.checked)}/><span>Ik heb ook gecontroleerd dat deze verbinding zonder trappen te gebruiken is.</span></label>
      {notice&&<p className="form-warning" role="alert">{notice}</p>}
      <footer><button type="button" className="btn outline" disabled={busy} onClick={()=>setOpen(false)}>Terug</button><button type="button" className="btn" disabled={busy||!checked||!approach.trim()} onClick={()=>void verify()}><ShieldCheck/>Loopaansluiting goedkeuren</button></footer>
    </AdminDialog>}
  </>;
}
