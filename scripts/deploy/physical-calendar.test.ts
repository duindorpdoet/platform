import { describe, expect, it } from "vitest";
import { auditPhysicalCalendar, codedJointProposal } from "./physical-calendar.mjs";
import { proposeJointRoutes, validateJointRoutes, type JointRouteInput } from "../../lib/domain/joint-route-planner";

const at=(minutes:number,seconds=0)=>new Date(Date.UTC(2026,9,31,17,minutes,seconds)).toISOString();
const group=(code:string,latest=at(60))=>({code,children:3,scheduledFinaleAt:null,latestCompletionAt:latest,ordinaryStopAt:at(120),hasStoredSchedule:true});
const portal=(extra={})=>({code:"P-SYNTH",physicalCode:"P-SYNTH",finale:false,headwaySeconds:300,windows:[{opensAt:at(0),arrivalClosesAt:at(60),physicalClosesAt:at(65),arrivalCloseInclusive:false,maxGroups:100,maxChildren:10,maxTotalChildren:100,visitSeconds:360,bufferSeconds:120}],...extra});
const visit=(groupCode:string,minutes:number,extra={})=>({groupCode,portalCode:"P-SYNTH",physicalCode:"P-SYNTH",kind:"ordinary",sequence:1,startsAt:at(minutes),durationSeconds:360,bufferSeconds:120,source:"expected",timingEvidence:"stored_visit",...extra});
export function syntheticJointInput():JointRouteInput {
 const gid="10000000-0000-0000-0000-000000000001",pid="20000000-0000-0000-0000-000000000001",fid="20000000-0000-0000-0000-000000000002";
 return {eventId:"30000000-0000-0000-0000-000000000001",sourceHash:"a".repeat(64),boardHash:"b".repeat(64),policyVersion:"policy-synthetic",maxGroupOverrunSeconds:1800,maxLegWalkingSeconds:900,maxTotalWalkingSeconds:3600,needsAnders:false,
 groups:[{id:gid,code:"G-SYNTH",childCount:3,startNodeId:"synthetic-start-node",startsAt:at(0),startConfirmed:true,ordinaryStopAt:at(60),desiredEndAt:at(65),maxOrdinaryVisits:1,requiresStepFree:false,accessibilityNeedsReview:false,fixedFirstPortalId:null,excludedPortalIds:[],finale:{portalId:fid,reservedAt:at(59),reservationValid:true,latestArrivalAt:at(70)}}],
 portals:[{id:pid,code:"P-SYNTH",name:"PRIVATE HOUSE NAME",nodeId:`portal:${pid}`,worldSlug:"anders",finale:false,accessibilityStatus:"step_free",windows:[{opensAt:at(0),arrivalClosesAt:at(59),closesAt:at(60),visitSeconds:360,bufferSeconds:120,maxGroups:1,maxChildren:20,maxTotalChildren:100,headwaySeconds:300}]},
 {id:fid,code:"P-FINAL",name:"PRIVATE FINALE NAME",nodeId:`portal:${fid}`,worldSlug:"anders",finale:true,accessibilityStatus:"step_free",windows:[{opensAt:at(59),arrivalClosesAt:at(70),closesAt:at(80),visitSeconds:360,bufferSeconds:120,maxGroups:1,maxChildren:20,maxTotalChildren:100,headwaySeconds:300}]}],
 legs:[{from:"synthetic-start-node",to:`portal:${pid}`,seconds:60,meters:70},{from:"synthetic-start-node",to:`portal:${fid}`,seconds:60,meters:70},{from:`portal:${pid}`,to:`portal:${fid}`,seconds:60,meters:70}],fixedVisits:[],before:[]};
}
describe("coded physical calendar diagnostics",()=>{
 it("distinguishes exact headway from occupancy and counts administrative starts separately",()=>{
  const calendar={groups:[group("G-A"),group("G-B")],portals:[portal()],visits:[visit("G-A",0),visit("G-B",4,{startsAt:at(4,59)}),visit("G-A",0,{kind:"start"})]};
  expect(auditPhysicalCalendar(calendar).counts).toMatchObject({headwayPairs:1,administrativeStarts:1,physicalVisits:2,duplicateGroupPhysicalVisits:0});
  calendar.visits[1]=visit("G-B",5);expect(auditPhysicalCalendar(calendar).counts).toMatchObject({headwayPairs:0,groupCapacityConflicts:0});
  calendar.portals=[portal({windows:[{...portal().windows[0],maxGroups:1}]})];expect(auditPhysicalCalendar(calendar).counts.groupCapacityConflicts).toBe(1);
  calendar.visits[1]=visit("G-B",8);expect(auditPhysicalCalendar(calendar).counts.groupCapacityConflicts).toBe(0);
 });
 it("reports the effective finale opening and hard physical end independently from ordinary finishing grace",()=>{
  const ordinary=portal(),finale=portal({finale:true,windows:[{...portal().windows[0],opensAt:at(59),arrivalClosesAt:at(70),physicalClosesAt:at(80),arrivalCloseInclusive:true}]});
  expect(auditPhysicalCalendar({groups:[group("G-A")],portals:[finale],visits:[visit("G-A",30,{kind:"finale"})]}).counts.earlyVisits).toBe(1);
  expect(auditPhysicalCalendar({groups:[group("G-A")],portals:[ordinary],visits:[visit("G-A",57)]}).counts.forbiddenEnds).toBe(0);
  const hard=portal({windows:[{...portal().windows[0],physicalClosesAt:at(60)}]});expect(auditPhysicalCalendar({groups:[group("G-A")],portals:[hard],visits:[visit("G-A",57)]}).counts.forbiddenEnds).toBe(1);
  expect(auditPhysicalCalendar({groups:[group("G-A")],portals:[ordinary],visits:[visit("G-A",60)]}).counts.lateOrClosedArrivals).toBe(1);
 });
 it("keeps per-group completion deadlines and show duration separate from physical changeover",()=>{
  const calendar={groups:[group("G-EARLY",at(60)),group("G-LATE",at(90))],portals:[portal({finale:true,windows:[{...portal().windows[0],arrivalClosesAt:at(100),physicalClosesAt:at(110),arrivalCloseInclusive:true}]})],visits:[visit("G-EARLY",54,{kind:"finale",bufferSeconds:600}),visit("G-LATE",84,{kind:"finale"})]};
  expect(auditPhysicalCalendar(calendar).counts.completionOverruns).toBe(0);
  calendar.visits[0]=visit("G-EARLY",54,{kind:"finale",startsAt:at(54,1),bufferSeconds:600});expect(auditPhysicalCalendar(calendar).counts.completionOverruns).toBe(1);
 });
 it("deduplicates physical group loads but reports repeated physical house visits and simultaneous child limits",()=>{
  const p=portal({windows:[{...portal().windows[0],maxConcurrentChildren:5,maxTotalChildren:5}]});
  const two={groups:[group("G-A"),group("G-B")],portals:[p],visits:[visit("G-A",0),visit("G-B",5)]};
  expect(auditPhysicalCalendar(two).counts).toMatchObject({concurrentChildCapacityConflicts:1,totalChildCapacityConflicts:1});
  two.visits=[visit("G-A",0),visit("G-A",10)];expect(auditPhysicalCalendar(two).counts).toMatchObject({concurrentChildCapacityConflicts:0,totalChildCapacityConflicts:0,duplicateGroupPhysicalVisits:1});
 });
 it("does not turn an uncomputed route or reservation-only service into a successful zero-visit match",()=>{
  const result=auditPhysicalCalendar({groups:[group("G-UNKNOWN"),group("G-FINAL")],portals:[portal()],visits:[visit("G-FINAL",0,{kind:"finale",timingEvidence:"reservation_occupation_only"})]});
  expect(result.counts).toMatchObject({uncomputedGroups:1,zeroOrdinaryGroups:1,unknownServiceTiming:1});expect(result.byGroup.find(group=>group.code==="G-UNKNOWN")?.ordinaryVisits).toBeNull();
 });
 it("exports only whitelisted code-based proposal fields, including before validity and real metrics",()=>{
  const input=syntheticJointInput(),proposal=proposeJointRoutes(input);expect(proposal.valid).toBe(true);
  input.before=structuredClone(proposal.groups);input.before[0].visits[0].startsAt=at(-1);
  const before=validateJointRoutes(input,input.before);
  // Future accidental metadata and even diagnostic messages cannot cross this exporter.
  Object.assign(input,{privateNote:"PRIVATE CHILD NOTE",coordinate:[4.27,52.1]});Object.assign(proposal.groups[0],{childName:"PRIVATE CHILD NAME"});
  proposal.conflicts.push({code:"UNRECOGNISED_DIAGNOSTIC",severity:"warning",groupId:input.groups[0].id,message:"PRIVATE MESSAGE"});
  const missing="40000000-0000-0000-0000-000000000001";proposal.conflicts.push({code:"START_APPOINTMENT_REQUIRED",severity:"block",groupId:missing,message:"PRIVATE MISSING-GROUP MESSAGE"});
  const exported=codedJointProposal(input,proposal,before,at(0),{groups:{[missing]:"G-MISSING"}}),json=JSON.stringify(exported);
  expect(exported).toMatchObject({readOnly:true,available:true,saved:false,applied:false,published:false,changedRows:0,messagesSent:0,before:{valid:false},after:{valid:true}});
  expect((exported.after.conflicts as Array<{groupCode:string}>).at(-1)?.groupCode).toBe("G-MISSING");
  expect(exported.after.groups[0].code).toBe("G-SYNTH");expect(exported.after.metrics.totalOrdinaryVisits).toBe(1);
  expect(json).not.toMatch(/PRIVATE|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|synthetic-start-node|coordinate|privateNote|childName/i);
 });
});
