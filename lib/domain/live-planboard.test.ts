import {describe,it,expect} from "vitest";
import {snappedStart,shiftedVisits,visitLanes,keepVisibleDuringDrag,localBoardWarnings,warningForGroup,planboardErrorText,visitGeometry,type BoardVisit,type BoardPortal} from "./live-planboard";
const visit=(id:string,groupId="a",minute=0):BoardVisit=>({id,groupId,portalId:"p",sequence:Number(id)||1,kind:"ordinary",source:"expected",version:1,startsAt:new Date(Date.UTC(2026,9,31,17,minute)).toISOString(),plannedStartsAt:"",endsAt:new Date(Date.UTC(2026,9,31,17,minute+5)).toISOString(),durationSeconds:300,bufferSeconds:120,status:"planned",editable:true,confirmed:false,actualArrivalAt:null,actualDepartureAt:null});
describe("live planboard interactions",()=>{
 it("translates transport timeout and abort variants without hiding a stale revision",()=>{
  for(const failure of ["TimeoutError: signal timed out",new DOMException("signal timed out","TimeoutError"),{message:"AbortError: operation was aborted"}])expect(planboardErrorText(failure)).toContain("Probeer opnieuw");
  expect(planboardErrorText({message:"STALE_VERSION"})).toContain("oude opdracht is niet toegepast");
  expect(planboardErrorText({message:"LIVE_PLANBOARD_INITIALIZING"})).toContain("nog voorbereid");
 });
 it("snaps 18:13 to 18:10 without turning a five minute visit into ten minutes",()=>{expect(new Date(snappedStart(Date.UTC(2026,9,31,17,13))).getUTCMinutes()).toBe(10);});
 it("shifts only later planned stops of the selected group by one equal delta",()=>{const all=[{...visit("1"),status:"completed" as const,editable:false,source:"actual" as const},visit("2","a",10),visit("3","a",25),visit("4","b",30)];const after=shiftedVisits(all,all[1],"q",new Date(Date.UTC(2026,9,31,17,20)).toISOString(),true);expect(after[0]).toBe(all[0]);expect(after[3]).toBe(all[3]);expect(after[1].portalId).toBe("q");expect(after[2].portalId).toBe("p");expect(Date.parse(after[2].startsAt)-Date.parse(after[1].startsAt)).toBe(15*60000);expect(after[1].durationSeconds).toBe(300);});
 it("keeps a protected reserved finale fixed while shifting later ordinary draft visits",()=>{
  const first=visit("1"),last={...visit("3","a",40),kind:"finale" as const,editable:false};
  const before=[first,visit("2","a",15),last],after=shiftedVisits(before,first,"p","2026-10-31T17:10:00Z",true);
  expect(after[1].startsAt).toBe("2026-10-31T17:25:00.000Z");expect(after[2]).toBe(last);
 });
 it("does not cap a delayed visit back into the standard evening",()=>{const v=visit("1");const after=shiftedVisits([v],v,"p","2026-10-31T22:00:00Z",true);expect(after[0].startsAt).toBe("2026-10-31T22:00:00.000Z");});
 it("allocates separate lanes for overlaps and permits touching half-open intervals",()=>{const a=visit("1"),b=visit("2","b",2),c=visit("3","c",7);const result=visitLanes([a,b,c]);expect(result.lanes.get(a.id)).not.toBe(result.lanes.get(b.id));expect(result.lanes.get(a.id)).toBe(result.lanes.get(c.id));});
 it("keeps the dragged element present after resolving a conflict under the conflicts filter",()=>{const v=visit("1");expect(keepVisibleDuringDrag(v,v.id,true,[])).toBe(true);expect(keepVisibleDuringDrag(v,null,true,[])).toBe(false);});
 it("shows a shared warning to every implicated group",()=>{const w={code:"CAPACITY",severity:"block" as const,message:"Capacity",visitIds:["1","2"],groupIds:["a","b"]};expect(warningForGroup(w,"a")).toBe(true);expect(warningForGroup(w,"b")).toBe(true);});
 it("accepts exact closing but rejects gaps between two openings",()=>{const p:BoardPortal={id:"p",name:"Gate",code:"P-1",world:"Anders",worldSlug:"anders",operationStatus:"scheduled",finale:false,windows:[{opensAt:"2026-10-31T17:00Z",closesAt:"2026-10-31T17:07Z",maxGroups:1,maxChildren:20,durationSeconds:300,bufferSeconds:120},{opensAt:"2026-10-31T18:00Z",closesAt:"2026-10-31T19:00Z",maxGroups:1,maxChildren:20,durationSeconds:300,bufferSeconds:120}]};expect(localBoardWarnings([visit("1")],[p])).toHaveLength(0);expect(localBoardWarnings([visit("1","a",10)],[p]).some(w=>w.code==="OPENING_WINDOW")).toBe(true);});
 it("draws a six-minute service and two-minute buffer exactly at every zoom",()=>{
  const six={...visit("1"),durationSeconds:360,bufferSeconds:120,endsAt:"2026-10-31T17:06:00Z"};
  const base=Date.parse("2026-10-31T16:00:00Z"),normal=visitGeometry(six,base,3.5),zoomed=visitGeometry(six,base,14);
  expect(normal).toEqual({left:210,serviceWidth:21,bufferWidth:7});
  expect(zoomed).toEqual({left:840,serviceWidth:84,bufferWidth:28});
  expect(visitLanes([six,visit("2","b",7)]).count).toBe(2);
  expect(visitLanes([six,visit("2","b",8)]).count).toBe(1);
 });
 it("keeps a real departure separate from the portal changeover",()=>{
  const first=visit("1"),next={...visit("2","a",5),portalId:"q"};
  expect(localBoardWarnings([first,next],[]).some(w=>w.code==="GROUP_OVERLAP")).toBe(false);
 });
 it("checks headway even when overlapping groups have ample capacity and excludes administrative starts",()=>{
  const portal:BoardPortal={id:"p",code:"P-1",name:"Poort",world:"Anders",worldSlug:"anders",operationStatus:"open",finale:false,arrivalHeadwaySeconds:300,windows:[{opensAt:"2026-10-31T17:00Z",closesAt:"2026-10-31T18:00Z",maxGroups:100,maxChildren:20,durationSeconds:300,bufferSeconds:120}]};
  const first=visit("1"),early={...visit("2","b",5),startsAt:"2026-10-31T17:04:59Z"};
  expect(localBoardWarnings([first,early],[portal]).some(w=>w.code==="ARRIVAL_HEADWAY")).toBe(true);
  expect(localBoardWarnings([first,visit("2","b",5)],[portal])).toHaveLength(0);
  expect(localBoardWarnings([first,{...early,kind:"start"}],[portal])).toHaveLength(0);
  expect(localBoardWarnings([first,visit("2","b",5)],[{...portal,windows:[{...portal.windows[0],maxGroups:1}]}]).some(w=>w.code==="PORTAL_CAPACITY")).toBe(true);
 });
 it("allows only an explicit ordinary finishing grace and never a late arrival or finale grace",()=>{
  const portal:BoardPortal={id:"p",code:"P-1",name:"Poort",world:"Anders",worldSlug:"anders",operationStatus:"open",finale:false,ordinaryEndGraceSeconds:300,windows:[{opensAt:"2026-10-31T17:00Z",closesAt:"2026-10-31T17:05Z",maxGroups:1,maxChildren:20,durationSeconds:300,bufferSeconds:120}]};
  const last=visit("1","a",3); // service to17:08, changeover to17:10
  expect(localBoardWarnings([last],[portal])).toHaveLength(0);
  for(const blocked of [{...portal,ordinaryHardClose:true},{...portal,finale:true}])expect(localBoardWarnings([last],[blocked]).some(w=>w.code==="OPENING_WINDOW")).toBe(true);
  expect(localBoardWarnings([visit("1","a",5)],[portal]).some(w=>w.code==="OPENING_WINDOW")).toBe(true);
 });
 it("ignores an empty planned group while retaining unknown groups and a real completed visit's buffer",()=>{
  const portal:BoardPortal={id:"p",code:"P-1",name:"Poort",world:"Anders",worldSlug:"anders",operationStatus:"open",finale:false,arrivalHeadwaySeconds:300,windows:[{opensAt:"2026-10-31T17:00Z",closesAt:"2026-10-31T18:00Z",maxGroups:1,maxChildren:20,durationSeconds:300,bufferSeconds:120}]};
  const groups=["empty","b"].map(id=>({id,code:id,name:id,version:1,runId:null,publishedStartsAt:null,draftStartsAt:null,scheduleId:id,scheduleRevision:1,settingsVersion:1,confirmed:false,recipients:1,activeChildren:id==="empty"?0:3,households:[]}));
  const empty=visit("1","empty",4),arriving=visit("2","b",5);
  expect(localBoardWarnings([empty,arriving],[portal],groups)).toHaveLength(0);
  expect(localBoardWarnings([empty,arriving],[portal],groups.filter(group=>group.id!=="empty")).map(warning=>warning.code)).toContain("ARRIVAL_HEADWAY");
  const departed={...visit("1","empty"),source:"actual" as const,status:"completed" as const,actualDepartureAt:"2026-10-31T17:04:00Z"};
  expect(localBoardWarnings([departed,arriving],[portal],groups).map(warning=>warning.code)).toContain("PORTAL_CAPACITY");
 });

 it("uses explicit receiving/physical ends once and allows exactly the final last arrival",()=>{
  const portal:BoardPortal={id:"p",code:"P-1",name:"Poort",world:"Anders",worldSlug:"anders",operationStatus:"open",finale:false,ordinaryEndGraceSeconds:300,windows:[{opensAt:"2026-10-31T17:00Z",arrivalClosesAt:"2026-10-31T17:05Z",closesAt:"2026-10-31T17:05Z",physicalClosesAt:"2026-10-31T17:10Z",maxGroups:1,maxChildren:20,durationSeconds:300,bufferSeconds:120}]};
  expect(localBoardWarnings([visit("1","a",3)],[portal])).toHaveLength(0);
  expect(localBoardWarnings([{...visit("1","a",3),startsAt:"2026-10-31T17:03:01Z"}],[portal]).some(w=>w.code==="OPENING_WINDOW")).toBe(true);
  const finale={...portal,finale:true,windows:[{...portal.windows[0],arrivalClosesAt:"2026-10-31T17:03Z",closesAt:"2026-10-31T17:11Z",physicalClosesAt:"2026-10-31T17:11Z"}]};
  expect(localBoardWarnings([{...visit("1","a",3),kind:"finale"}],[finale])).toHaveLength(0);
  expect(localBoardWarnings([{...visit("1","a",3),kind:"finale",startsAt:"2026-10-31T17:03:01Z"}],[finale]).some(w=>w.code==="OPENING_WINDOW")).toBe(true);
 });
 it("enforces the separate simultaneous-child ceiling even when every group fits individually",()=>{
  const portal:BoardPortal={id:"p",code:"P-1",name:"Poort",world:"Anders",worldSlug:"anders",operationStatus:"open",finale:true,arrivalHeadwaySeconds:300,windows:[{opensAt:"2026-10-31T17:00Z",closesAt:"2026-10-31T18:00Z",maxGroups:10,maxChildren:20,maxConcurrentChildren:5,durationSeconds:300,bufferSeconds:120}]};
  const groups=["a","b"].map(id=>({id,code:id,name:id,version:1,runId:null,publishedStartsAt:null,draftStartsAt:null,scheduleId:id,scheduleRevision:1,settingsVersion:1,confirmed:false,recipients:1,activeChildren:3,households:[]}));
  expect(localBoardWarnings([visit("1"),visit("2","b",5)],[portal],groups).some(w=>w.code==="CONCURRENT_CHILD_CAPACITY")).toBe(true);
  expect(localBoardWarnings([visit("1"),visit("2","b",7)],[portal],groups)).toHaveLength(0);
 });

 it("keeps a still-present physical visit occupied through the authoritative running end",()=>{
  const at=(minute:number)=>visit("clock","a",minute).startsAt;
  const present={...visit("1"),source:"actual" as const,status:"present" as const,actualArrivalAt:at(0),endsAt:at(10)};
  expect(visitGeometry(present,Date.parse(at(0)),4)).toEqual({left:0,serviceWidth:40,bufferWidth:8});
  expect(visitLanes([present,visit("2","b",8)]).count).toBe(2);
  expect(visitGeometry({...present,status:"completed",actualDepartureAt:at(4)},Date.parse(at(0)),4)).toEqual({left:0,serviceWidth:16,bufferWidth:8});
 });

 it("renders an administrative gathering marker without physical duration or an extra occupation lane",()=>{
  const admin={...visit("1"),kind:"start" as const},ordinary=visit("2","b");
  expect(visitLanes([admin,ordinary]).count).toBe(1);expect(visitLanes([admin,ordinary]).lanes.get(ordinary.id)).toBe(0);
  expect(visitGeometry(admin,Date.parse(admin.startsAt),4)).toEqual({left:0,serviceWidth:0,bufferWidth:0});
 });

});
