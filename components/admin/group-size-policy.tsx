"use client";
import { useState } from "react";
import { UsersRound } from "lucide-react";
import { parseGroupSize } from "@/lib/domain/group-size-policy";
import { createClient } from "@/lib/supabase/client";

type ImpactItem={id:string;code:string;childCount:number;status?:string;published?:boolean};
type Impact={settingsVersion:number;impactHash:string;groups:ImpactItem[];parties:ImpactItem[]};
export function GroupSizePolicy({eventSlug,maximum,target,followsMaximum,settingsVersion,onSaved,onOpenGroups}:{
 eventSlug:string;maximum:number;target:number;followsMaximum:boolean;settingsVersion:number;
 onSaved:()=>Promise<void>;onOpenGroups:()=>void;
}){
 const [maximumDraft,setMaximumDraft]=useState<string>();
 const [targetDraft,setTargetDraft]=useState<string>();
 const [followDraft,setFollowDraft]=useState<boolean>();
 const [reason,setReason]=useState("");
 const [impact,setImpact]=useState<Impact|null>(null);
 const [reviewed,setReviewed]=useState(false);
 const [busy,setBusy]=useState(false);
 const [notice,setNotice]=useState("");
 const rawMaximum=maximumDraft??String(maximum),rawTarget=targetDraft??String(target);
 const follow=followDraft??followsMaximum;
 const nextMaximum=parseGroupSize(rawMaximum),nextTarget=follow?nextMaximum:parseGroupSize(rawTarget);
 const valid=nextMaximum!==null&&nextTarget!==null&&nextTarget<=nextMaximum;
 const changed=nextMaximum!==maximum||nextTarget!==target||follow!==followsMaximum;
 const impacted=Boolean(impact&&(impact.groups.length||impact.parties.length));
 function invalidate(){setImpact(null);setReviewed(false);setNotice("");}
 async function save(){
  if(!valid||busy)return;
  const client=createClient();if(!client)return;
  setBusy(true);setNotice("");
  try{
   let current=impact;
   if(!current){
    const preview=await client.schema('api').rpc('admin_group_size_policy_preview',{_event_slug:eventSlug,_max_group_size:nextMaximum,_target_group_size:follow?null:nextTarget});
    if(preview.error)throw preview.error;
    current=preview.data as Impact;
    if(current.settingsVersion!==settingsVersion)throw new Error('STALE_VERSION');
    if(current.groups.length||current.parties.length){setImpact(current);setNotice('Controleer de bestaande uitzonderingen en bevestig dat alle groepen behouden blijven.');return;}
   }
   if((current.groups.length||current.parties.length)&&!reviewed)return;
   const result=await client.schema('api').rpc('admin_group_size_policy_save',{
    _event_slug:eventSlug,_max_group_size:nextMaximum,_target_group_size:follow?null:nextTarget,
    _expected_settings_version:current.settingsVersion,_expected_impact_hash:current.impactHash,_reason:reason.trim(),
   });
   if(result.error)throw result.error;
   await onSaved();
   setMaximumDraft(undefined);setTargetDraft(undefined);setFollowDraft(undefined);setImpact(null);setReviewed(false);setReason('');
   setNotice(`Maximale groepsgrootte opgeslagen: ${nextMaximum} kinderen per groep. Bestaande groepen zijn behouden.`);
  }catch(cause){
   const message=typeof cause==='object'&&cause&&'message'in cause?String(cause.message):'';
   const conflict=/STALE_VERSION|GROUP_SIZE_IMPACT_CHANGED/.test(message);
   setImpact(null);setReviewed(false);
   setNotice(conflict?'Deze instelling of indeling is ondertussen gewijzigd. De actuele waarde is opgehaald; controleer je wijziging opnieuw.':'De groepslimiet kon niet worden opgeslagen. Controleer je invoer en rechten en probeer opnieuw.');
   if(conflict)await onSaved();
  }finally{setBusy(false);}
 }
 return <article className="panel group-size-policy">
  <div className="row-between"><div><p className="kicker">Evenementinstelling · versie {settingsVersion}</p><h3>Maximale groepsgrootte</h3></div><UsersRound/></div>
  <p>Geldt voor wandelgroepen, samenlopen en nieuwe indelingen. De capaciteit van startpunten, poorten en de finale blijft apart gelden.</p>
  <label className="field"><span>Aantal kinderen per groep</span><input type="number" min={1} step={1} value={rawMaximum} disabled={busy} aria-describedby="group-size-validation" onChange={event=>{setMaximumDraft(event.target.value);invalidate();}}/></label>
  {nextMaximum===null&&<p id="group-size-validation" role="alert">Vul een heel aantal kinderen van minimaal 1 in. De technische opslaggrens is 2.147.483.647.</p>}
  <label className="checkfield"><input type="checkbox" checked={follow} disabled={busy} onChange={event=>{setFollowDraft(event.target.checked);invalidate();}}/>Streefaantal volgt het maximum</label>
  {!follow&&<label className="field"><span>Streefaantal kinderen per groep</span><input type="number" min={1} step={1} value={rawTarget} disabled={busy} onChange={event=>{setTargetDraft(event.target.value);invalidate();}}/></label>}
  {!follow&&(nextTarget===null||(nextMaximum!==null&&nextTarget>nextMaximum))&&<p role="alert">Vul een heel streefaantal in tussen 1 en het groepsmaximum.</p>}
  <label className="field"><span>Reden voor de wijziging</span><textarea minLength={10} maxLength={500} value={reason} disabled={busy} onChange={event=>setReason(event.target.value)}/></label>
  {impact&&impacted&&<section className="form-warning" aria-label="Bestaande uitzonderingen">
   <h4>{impact.groups.length} bestaande groep(en) en {impact.parties.length} samenloop/samenlopen boven {nextMaximum} kinderen</h4>
   <p>Deze groepen, kinderen, betalingen, startafspraken en verdiende zegels blijven behouden. Verdere groei boven het maximum is geblokkeerd. Gepubliceerde of lopende groepen blijven operationeel.</p>
   <ul>{impact.groups.map(group=><li key={group.id}>{group.code}: {group.childCount} kinderen{group.published?' · gepubliceerd':''}</li>)}{impact.parties.map(party=><li key={party.id}>{party.code}: {party.childCount} kinderen</li>)}</ul>
   <button type="button" className="text-link" onClick={onOpenGroups}>Bekijk betrokken groepen</button>
   <label className="checkfield"><input type="checkbox" checked={reviewed} disabled={busy} onChange={event=>setReviewed(event.target.checked)}/>Ik heb de bestaande uitzonderingen gecontroleerd. Alle bestaande groepen blijven behouden.</label>
  </section>}
  <p role="status">{notice}</p>
  <button className="btn" type="button" disabled={busy||!valid||!changed||reason.trim().length<10||(impacted&&!reviewed)} onClick={()=>void save()}>{busy?'Limiet opslaan…':'Limiet opslaan'}</button>
 </article>;
}
