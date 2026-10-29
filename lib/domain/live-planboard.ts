export type BoardVisit = {id:string;groupId:string;portalId:string;sequence:number;kind:"ordinary"|"finale"|"start";source:"expected"|"manual"|"actual";version:number;startsAt:string;plannedStartsAt:string;endsAt:string;durationSeconds:number;bufferSeconds:number;status:"planned"|"underway"|"present"|"completed"|"skipped";editable:boolean;confirmed:boolean;actualArrivalAt:string|null;actualDepartureAt:string|null};
export type BoardPortal = {id:string;name:string;code:string;world:string;worldSlug:string;operationStatus:string;lifecycleStatus?:string;approvalStatus?:string;finale:boolean;arrivalHeadwaySeconds?:number;ordinaryEndGraceSeconds?:number;ordinaryHardClose?:boolean;accessibilityStatus?:"unknown"|"step_free"|"not_step_free"|null;maxTotalChildren?:number|null;windows:Array<{opensAt:string;closesAt:string;arrivalClosesAt?:string;physicalClosesAt?:string;maxGroups:number;maxChildren:number;maxTotalChildren?:number|null;maxConcurrentChildren?:number|null;headwaySeconds?:number;durationSeconds:number;bufferSeconds:number}>};
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
  if(!v.editable||v.status!=="planned"||v.source==="actual"||v.groupId!==selected.groupId||(v.id!==selected.id&&(!following||v.sequence<=selected.sequence)))return v;
  const start=Date.parse(v.startsAt)+delta;const duration=v.id===selected.id?durationSeconds:v.durationSeconds;
  return {...v,portalId:v.id===selected.id?portalId:v.portalId,startsAt:new Date(start).toISOString(),endsAt:new Date(start+duration*1000).toISOString(),durationSeconds:duration};
 });
}
/** Physical occupation includes the real visit and buffer, independent of label width or zoom. */
export function visitLanes(visits:BoardVisit[]) {
 const ends:number[]=[];const lanes=new Map<string,number>();
 for(const v of [...visits].filter(visit=>visit.kind!=="start").sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt)||a.id.localeCompare(b.id))){const start=Date.parse(v.startsAt);let lane=ends.findIndex(end=>end<=start);if(lane<0)lane=ends.length;ends[lane]=visitOccupationEnd(v);lanes.set(v.id,lane);}
 return {lanes,count:Math.max(1,ends.length)};
}
export function visitServiceEnd(visit:BoardVisit) {
 if(visit.kind==="start")return Date.parse(visit.startsAt);
 const actual=visit.source==="actual"?Date.parse(visit.actualDepartureAt??visit.endsAt):NaN;
 return Number.isFinite(actual)?actual:Date.parse(visit.startsAt)+visit.durationSeconds*1000;
}
export function visitOccupationEnd(visit:BoardVisit) {return visitServiceEnd(visit)+(visit.kind==="start"?0:visit.bufferSeconds*1000);}
export function visitGeometry(visit:BoardVisit,rangeStart:number,pxPerMinute:number) {
 return {left:(Date.parse(visit.startsAt)-rangeStart)/60000*pxPerMinute,serviceWidth:(visitServiceEnd(visit)-Date.parse(visit.startsAt))/60000*pxPerMinute,bufferWidth:visit.kind==="start"?0:visit.bufferSeconds/60*pxPerMinute};
}
export function portalWindowPhysicalEnd(portal:BoardPortal,window:BoardPortal["windows"][number]) {
 return window.physicalClosesAt?Date.parse(window.physicalClosesAt):Date.parse(window.closesAt)+(portal.finale||portal.ordinaryHardClose?0:(portal.ordinaryEndGraceSeconds??0)*1000);
}
export function portalWindowReceives(portal:BoardPortal,window:BoardPortal["windows"][number],start:number) {
 const end=Date.parse(window.arrivalClosesAt??window.closesAt);
 return start>=Date.parse(window.opensAt)&&(portal.finale?start<=end:start<end);
}
export function localBoardWarnings(visits:BoardVisit[],portals:BoardPortal[],groups:BoardGroup[]=[]):BoardWarning[] {
 const warnings:BoardWarning[]=[];
 const childrenFor=(groupId:string)=>{const group=groups.find(group=>group.id===groupId);return group?.activeChildren??group?.households.reduce((sum,household)=>sum+household.childCount,0);};
 const physical=visits.filter(visit=>visit.kind!=="start"&&visit.status!=="skipped"&&!(visit.status==="planned"&&visit.source!=="actual"&&childrenFor(visit.groupId)===0));
 for(const visit of physical){
  const portal=portals.find(portal=>portal.id===visit.portalId),start=Date.parse(visit.startsAt);
  if(!portal?.windows.some(window=>portalWindowReceives(portal,window,start)&&visitOccupationEnd(visit)<=portalWindowPhysicalEnd(portal,window)&&visit.durationSeconds>=window.durationSeconds&&visit.bufferSeconds>=window.bufferSeconds))
   warnings.push({code:"OPENING_WINDOW",severity:visit.source==="actual"?"warning":"block",message:"Aankomst ligt buiten de poortopening of bezoek en wisseltijd overschrijden de toegestane sluiting.",visitIds:[visit.id],groupIds:[visit.groupId]});
 }
 for(let i=0;i<physical.length;i++)for(let j=i+1;j<physical.length;j++){
  const a=physical[i],b=physical[j];
  if(a.groupId===b.groupId&&Date.parse(a.startsAt)<visitServiceEnd(b)&&Date.parse(b.startsAt)<visitServiceEnd(a))
   warnings.push({code:"GROUP_OVERLAP",severity:"block",message:"Bezoeken van deze groep overlappen. Wisseltijd telt afzonderlijk voor de poort.",visitIds:[a.id,b.id],groupIds:[a.groupId]});
 }
 for(const portal of portals){
  const items=physical.filter(visit=>visit.portalId===portal.id).sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt)||a.id.localeCompare(b.id));
  for(let i=0;i<items.length;i++)for(let j=i+1;j<items.length;j++){
   const a=items[i],b=items[j];
   if(a.groupId!==b.groupId&&portal.arrivalHeadwaySeconds!==undefined&&Date.parse(b.startsAt)-Date.parse(a.startsAt)<portal.arrivalHeadwaySeconds*1000)
    warnings.push({code:"ARRIVAL_HEADWAY",severity:"block",message:`Groepsaankomsten liggen minder dan ${portal.arrivalHeadwaySeconds/60} minuten uit elkaar.`,visitIds:[a.id,b.id],groupIds:[a.groupId,b.groupId]});
  }
  for(const visit of items){
   const at=Date.parse(visit.startsAt),window=portal.windows.find(window=>portalWindowReceives(portal,window,at));
   if(!window)continue;
   const concurrent=items.filter(other=>Date.parse(other.startsAt)<=at&&visitOccupationEnd(other)>at),involved=[...new Set(concurrent.map(other=>other.groupId))];
   if(involved.length>window.maxGroups)warnings.push({code:"PORTAL_CAPACITY",severity:"block",message:"Gelijktijdige groepscapaciteit overschreden, inclusief wisseltijd.",visitIds:concurrent.map(other=>other.id),groupIds:involved});
   const concurrentChildren=involved.map(childrenFor);
   if(window.maxConcurrentChildren!==undefined&&window.maxConcurrentChildren!==null&&concurrentChildren.every(count=>count!==undefined)&&concurrentChildren.reduce<number>((sum,count)=>sum+count!,0)>window.maxConcurrentChildren)
    warnings.push({code:"CONCURRENT_CHILD_CAPACITY",severity:"block",message:"Het aantal gelijktijdig aanwezige kinderen overschrijdt de fysieke capaciteit.",visitIds:concurrent.map(other=>other.id),groupIds:involved});
   const children=childrenFor(visit.groupId);
   if(children!==undefined&&children>window.maxChildren)warnings.push({code:"CHILD_CAPACITY",severity:"block",message:"Deze groep heeft meer kinderen dan dit ontvangstvenster toestaat.",visitIds:[visit.id],groupIds:[visit.groupId]});
  }
  const totalLimits=items.flatMap(visit=>portal.windows.filter(window=>portalWindowReceives(portal,window,Date.parse(visit.startsAt))).flatMap(window=>window.maxTotalChildren===undefined||window.maxTotalChildren===null?[]:[window.maxTotalChildren]));
  if(portal.maxTotalChildren!==null&&portal.maxTotalChildren!==undefined)totalLimits.push(portal.maxTotalChildren);
  if(totalLimits.length){
   const groupIds=[...new Set(items.map(visit=>visit.groupId))],counts=groupIds.map(childrenFor);
   if(counts.every(count=>count!==undefined)&&counts.reduce<number>((sum,count)=>sum+count!,0)>Math.min(...totalLimits))
    warnings.push({code:"TOTAL_CHILD_CAPACITY",severity:"block",message:"Het totale aantal unieke kinderen overschrijdt de avondcapaciteit van deze poort.",visitIds:items.map(visit=>visit.id),groupIds});
  }
 }
 return warnings;
}
export function warningForGroup(warning:BoardWarning,groupId:string){return warning.groupIds.includes(groupId);}
export function keepVisibleDuringDrag(visit:BoardVisit,draggedId:string|null,conflictsOnly:boolean,warnings:BoardWarning[]){return visit.id===draggedId||!conflictsOnly||warnings.some(w=>w.visitIds.includes(visit.id)||w.groupIds.includes(visit.groupId));}
