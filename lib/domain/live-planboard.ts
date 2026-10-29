export type BoardVisit = {id:string;groupId:string;portalId:string;sequence:number;kind:"ordinary"|"finale"|"start";source:"expected"|"manual"|"actual";version:number;startsAt:string;plannedStartsAt:string;endsAt:string;durationSeconds:number;bufferSeconds:number;status:"planned"|"underway"|"present"|"completed"|"skipped";editable:boolean;confirmed:boolean;actualArrivalAt:string|null;actualDepartureAt:string|null};
export type BoardPortal = {id:string;name:string;code:string;world:string;worldSlug:string;operationStatus:string;lifecycleStatus?:string;approvalStatus?:string;finale:boolean;windows:Array<{opensAt:string;closesAt:string;maxGroups:number;maxChildren:number;durationSeconds:number;bufferSeconds:number}>};
export type BoardGroup = {id:string;code:string;name:string;version:number;runId:string|null;publishedStartsAt:string|null;draftStartsAt:string|null;scheduleId:string;scheduleRevision:number;settingsVersion:number;confirmed:boolean;recipients:number;activeChildren?:number|null;households:Array<{reference:string;preferredStartAt:string|null;ordinaryStopAt:string|null;desiredEndAt:string|null;childCount:number}>};
export type BoardWarning = {code:string;severity:"block"|"warning";message:string;visitIds:string[];groupIds:string[]};
export type BoardSnapshot = {eventId:string;eventDate:string;generatedAt:string;inputHash:string;realtimeTopic:string;initializationPending?:number;visits:BoardVisit[];portals:BoardPortal[];groups:BoardGroup[];warnings:BoardWarning[]};
export type BoardCommand = {action:"move";visitId:string;portalId:string;startsAt:string;durationSeconds:number;shiftFollowing:boolean}|{action:"undo"|"redo";restoreKey:string};
export type BoardChange = {id:string;groupId:string;portalId:string;startsAt:string;durationSeconds:number;bufferSeconds:number;source:string};
export type BoardPreview = {inputHash:string;groupCode:string;before:BoardChange[];changes:BoardChange[];warnings:BoardWarning[];requiresConfirmation:boolean;publishedStartsAt:string|null;changesStart:boolean;communication:string;recipients:number};
export const boardStatus = {planned:"Gepland",underway:"Onderweg",present:"Aanwezig",completed:"Afgerond",skipped:"Overgeslagen"};
export function planboardErrorText(error:unknown):string {
 const message=typeof error==="string"?error:error&&typeof error==="object"&&"message" in error?String(error.message):"";
 if(/STALE_/.test(message))return "De planning is intussen gewijzigd. Controleer de actuele impact opnieuw; de oude opdracht is niet toegepast.";
 if(/LIVE_PLANBOARD_INITIALIZING/.test(message))return "De routevoorstellen worden nog voorbereid. Wacht tot alle groepen zijn opgehaald en controleer de impact opnieuw.";
 if(/timeout|timed out|abort/i.test(message)||error instanceof Error&&/TimeoutError|AbortError/.test(error.name))return "Het ophalen van de planning duurde te lang of werd onderbroken. Probeer opnieuw.";
 return message||"De actuele planning kon niet worden opgehaald. Probeer opnieuw.";
}
export function snappedStart(value:number) {return Math.round(value/600_000)*600_000;}
export function shiftedVisits(visits:BoardVisit[],selected:BoardVisit,portalId:string,startsAt:string,following:boolean,durationSeconds=selected.durationSeconds):BoardVisit[] {
 const delta=Date.parse(startsAt)-Date.parse(selected.startsAt);
 return visits.map(v=>{
  if(v.status!=="planned"||v.source==="actual"||v.groupId!==selected.groupId||(v.id!==selected.id&&(!following||v.sequence<=selected.sequence)))return v;
  const start=Date.parse(v.startsAt)+delta;const duration=v.id===selected.id?durationSeconds:v.durationSeconds;
  return {...v,portalId:v.id===selected.id?portalId:v.portalId,startsAt:new Date(start).toISOString(),endsAt:new Date(start+duration*1000).toISOString(),durationSeconds:duration};
 });
}
/** Lane assignment uses half-open intervals, so touching visits can share a lane. */
export function visitLanes(visits:BoardVisit[],minimumDisplaySeconds=0) {
 const ends:number[]=[];const lanes=new Map<string,number>();
 for(const v of [...visits].sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt)||a.id.localeCompare(b.id))){const start=Date.parse(v.startsAt);let lane=ends.findIndex(end=>end<=start);if(lane<0)lane=ends.length;ends[lane]=Math.max(Date.parse(v.endsAt),start+minimumDisplaySeconds*1000);lanes.set(v.id,lane);}
 return {lanes,count:Math.max(1,ends.length)};
}
export function localBoardWarnings(visits:BoardVisit[],portals:BoardPortal[],groups:BoardGroup[]=[]):BoardWarning[] {
 const warnings:BoardWarning[]=[];
 for(const v of visits){if(!v.editable)continue;const p=portals.find(p=>p.id===v.portalId);const start=Date.parse(v.startsAt),end=start+(v.durationSeconds+v.bufferSeconds)*1000;
  if(!p?.windows.some(w=>start>=Date.parse(w.opensAt)&&end<=Date.parse(w.closesAt)&&v.durationSeconds>=w.durationSeconds&&v.bufferSeconds>=w.bufferSeconds))warnings.push({code:"OPENING_WINDOW",severity:"block",message:"Bezoek en buffer vallen buiten een openingsvenster.",visitIds:[v.id],groupIds:[v.groupId]});
 }
 for(let i=0;i<visits.length;i++)for(let j=i+1;j<visits.length;j++){const a=visits[i],b=visits[j];if(a.groupId!==b.groupId||a.kind==="start"||b.kind==="start")continue;if(Date.parse(a.startsAt)<Date.parse(b.endsAt)+b.bufferSeconds*1000&&Date.parse(b.startsAt)<Date.parse(a.endsAt)+a.bufferSeconds*1000)warnings.push({code:"GROUP_OVERLAP",severity:"block",message:"Bezoeken van deze groep overlappen.",visitIds:[a.id,b.id],groupIds:[a.groupId]});}
 for(const p of portals) {
  const items=visits.filter(v=>v.portalId===p.id&&v.status!=="skipped");
  for(const v of items){const at=Date.parse(v.startsAt);const window=p.windows.find(w=>at>=Date.parse(w.opensAt)&&at<Date.parse(w.closesAt));if(!window)continue;
   const concurrent=items.filter(x=>Date.parse(x.startsAt)<=at&&Date.parse(x.endsAt)+x.bufferSeconds*1000>at);const involved=[...new Set(concurrent.map(x=>x.groupId))];
   if(involved.length>window.maxGroups)warnings.push({code:"PORTAL_CAPACITY",severity:"block",message:"Gelijktijdige groepscapaciteit overschreden.",visitIds:concurrent.map(x=>x.id),groupIds:involved});
   const g=groups.find(g=>g.id===v.groupId);const children=g?.activeChildren??g?.households.reduce((sum,h)=>sum+h.childCount,0);
   if(children!==undefined&&children>window.maxChildren)warnings.push({code:"CHILD_CAPACITY",severity:"block",message:"Deze groep heeft meer kinderen dan dit ontvangstvenster toestaat.",visitIds:[v.id],groupIds:[v.groupId]});
  }
 }
 return warnings;
}
export function warningForGroup(warning:BoardWarning,groupId:string){return warning.groupIds.includes(groupId);}
export function keepVisibleDuringDrag(visit:BoardVisit,draggedId:string|null,conflictsOnly:boolean,warnings:BoardWarning[]){return visit.id===draggedId||!conflictsOnly||warnings.some(w=>w.visitIds.includes(visit.id)||w.groupIds.includes(visit.groupId));}
