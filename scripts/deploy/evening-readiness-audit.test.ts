import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AUDIT_QUERY, PREVIEW_AUDIT_QUERY, JOINT_PROPOSAL_INPUT_QUERY, SNAPSHOT_STATS_QUERY, ownerPreviewAllowed, runAudit } from "./evening-readiness-audit.mjs";

const directories: string[] = [];
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(directories.splice(0).map(path => rm(path, { recursive: true, force: true }))); });
async function fixtureEnv(extra = {}) {
 const directory = await mkdtemp(join(tmpdir(), "coded-readonly-audit-")); directories.push(directory);
 return { SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst", SUPABASE_ACCESS_TOKEN: "fixture-never-log", RUNNER_TEMP: directory, ...extra };
}
const baseAudit = { readOnly: true, eventDate: "2026-10-31", settingsVersion: 103,
 registrationChannels: { housesOpen: false, participantsOpen: false },
 counts: { groups: 1, approvedActiveHouses: 0, storedBoardVisits: 0, runRecords: 0, begunRuns: 0 },
 finale: {}, worldCoverage: { active: null, pending: null, latest: null }, possiblePhysicalAliases: [],
 physicalCalendar: { source: "stored_current_board_and_current_run", groups: [], portals: [], visits: [] },
 groups: [{ code: "G-TEST", ordinaryHouses: null, expectedCompletionAt: "2026-10-31T20:10:00Z" }],
 checkpoint: { settings: "a".repeat(32), appointments: "b".repeat(32), routesAndRuns: "c".repeat(32) } };
describe("coded pure route inspection during the protected production release", () => {
 it("keeps privileged previews inside a fixed bounded read-only transaction and the existing verified capability", () => {
  expect(PREVIEW_AUDIT_QUERY).toMatch(/^begin read only;/);
  expect(PREVIEW_AUDIT_QUERY.trim()).toMatch(/commit;$/);
  expect(PREVIEW_AUDIT_QUERY).toContain("set local statement_timeout='15000ms'");
  expect(PREVIEW_AUDIT_QUERY).toContain("set local lock_timeout='500ms'");
  expect(PREVIEW_AUDIT_QUERY).toContain("c.capability='groups_manage' and c.revoked_at is null");
  expect(PREVIEW_AUDIT_QUERY).toContain("u.email_confirmed_at is not null");
  expect(PREVIEW_AUDIT_QUERY).not.toMatch(/\b(?:update|insert|delete|alter|grant|truncate|reset)\b/i);
  expect(PREVIEW_AUDIT_QUERY).not.toMatch(/admin_live_planboard_snapshot|live_planboard_seed|publish_group|email_outbox/);
 });
 it("counts printable portal availability without exporting any credential material", () => {
  expect(PREVIEW_AUDIT_QUERY).toContain("'portalPrintStatus'");
  expect(PREVIEW_AUDIT_QUERY).toContain("'encryptedPrintCredentials'");
  expect(PREVIEW_AUDIT_QUERY).toContain("app_private.portal_print_material material on material.credential_id=c.id");
  expect(PREVIEW_AUDIT_QUERY).not.toMatch(/token_hash|short_code_hash|material\.ciphertext|jsonb_build_object\('credentialId'/);
 });
 it("uses the limited management reader outside the protected production branch", async () => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  const request = vi.fn(async (_url: string, options: RequestInit) => {
   const body = JSON.parse(String(options.body)); expect(body.read_only).toBe(true);
   expect(body.query).not.toBe(PREVIEW_AUDIT_QUERY);
   return Response.json(body.query === AUDIT_QUERY ? [{ audit: structuredClone(baseAudit) }] : []);
  });
  const path = await runAudit(await fixtureEnv({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/main" }), request);
  const result = JSON.parse(await readFile(path, "utf8"));
  expect(result.routeProjection).toEqual({ readable: false, reasonCode: "PROTECTED_PRODUCTION_ENVIRONMENT_REQUIRED" });
  expect(request).toHaveBeenCalledTimes(2);
 });
 it("preserves SELECT output after COMMIT and joins only coded current source checks", async () => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  const routeCheck = { code: "G-TEST", source: "current_ops_preview", ordinaryHouses: 19, finales: 1, duplicatePhysicalLocations: [], startMarkerValid: true, ordinaryAndersReachable: true,
   linkedFirstVisitConfigured: true, linkedFirstVisitCount: 1,
   projectedOrdinaryEndsAt: "2026-10-31T19:30:00Z", projectedFinaleArrivalAt: "2026-10-31T19:45:00Z",
   projectedCompletionAt: "2026-10-31T19:51:00Z", projectedPhysicalEndsAt: "2026-10-31T19:53:00Z" };
  const request = vi.fn(async (_url: string, options: RequestInit) => {
   const body = JSON.parse(String(options.body));
   if (body.read_only === false) {
    if(body.query===JOINT_PROPOSAL_INPUT_QUERY)return Response.json([{joint_input:{available:false,reasonCode:"JOINT_PLANNING_MIGRATION_NOT_INSTALLED"}}]);
    expect(body.query).toBe(PREVIEW_AUDIT_QUERY);
    return Response.json([{ audit: { ...structuredClone(baseAudit), routeProjection: { readable: true, databaseReadOnly: true, authorizedExistingAdmin: true, groups: [routeCheck] } } }]);
   }
   return Response.json(body.query === AUDIT_QUERY ? [{ audit: structuredClone(baseAudit) }] : []);
  });
  const path = await runAudit(await fixtureEnv({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", APP_ENVIRONMENT: "production" }), request);
  const result = JSON.parse(await readFile(path, "utf8"));
  expect(result.groups[0].routeCheck).toEqual(routeCheck);
  expect(result.groups[0].expectedCompletionAt).toBe("2026-10-31T20:10:00Z");
  expect(result.groups[0].routeCheck.projectedCompletionAt).not.toBe(result.groups[0].expectedCompletionAt);
  expect(result.checkpoint).toEqual(baseAudit.checkpoint);
  expect(result.jointProposal).toMatchObject({available:false,reasonCode:"JOINT_PLANNING_MIGRATION_NOT_INSTALLED"});
  const proposal=JSON.parse(await readFile(join(path.replace(/audit\.json$/,""),"proposal.json"),"utf8"));expect(proposal).toMatchObject({available:false,saved:false,applied:false});
  expect(result.changedRows).toBe(0); expect(result.messagesSent).toBe(0);
  expect(JSON.stringify(result)).not.toContain("fixture-never-log");
  expect(request.mock.calls.map(([,options])=>JSON.parse(String(options.body)).query)).toEqual([PREVIEW_AUDIT_QUERY,JOINT_PROPOSAL_INPUT_QUERY,SNAPSHOT_STATS_QUERY]);
 });
 it("writes a separate unsaved proposal artifact through only the fixed owner READ ONLY query", async()=>{
  const logged=vi.spyOn(console,"log").mockImplementation(()=>{});
  const input={eventId:"10000000-0000-0000-0000-000000000001",sourceHash:"a".repeat(64),boardHash:"b".repeat(64),policyVersion:"synthetic",maxGroupOverrunSeconds:1800,maxLegWalkingSeconds:900,maxTotalWalkingSeconds:3600,needsAnders:false,groups:[],portals:[],legs:[],fixedVisits:[],before:[],privateName:"PRIVATE INPUT MUST NOT ESCAPE"};
  const request=vi.fn(async(_url:string,options:RequestInit)=>{
   const body=JSON.parse(String(options.body));
   if(body.query===JOINT_PROPOSAL_INPUT_QUERY){expect(body.read_only).toBe(false);return Response.json([{joint_input:{available:true,databaseReadOnly:true,authorizedExistingAdmin:true,inputFunctionStable:true,readAt:"2026-10-31T17:00:00Z",input}}]);}
   if(body.query===PREVIEW_AUDIT_QUERY)return Response.json([{audit:{...structuredClone(baseAudit),routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}}]);
   expect(body.read_only).toBe(true);return Response.json(body.query===AUDIT_QUERY?[{audit:structuredClone(baseAudit)}]:[]);
  });
  const path=await runAudit(await fixtureEnv({GITHUB_REPOSITORY:"duindorpdoet/platform",GITHUB_REF:"refs/heads/production"}),request);
  const proposal=JSON.parse(await readFile(path.replace(/audit\.json$/,"proposal.json"),"utf8"));expect(proposal).toMatchObject({available:true,readOnly:true,databaseReadOnly:true,saved:false,applied:false,published:false,changedRows:0,messagesSent:0,after:{valid:true}});
  expect(JSON.stringify(proposal)).not.toMatch(/PRIVATE|eventId|10000000-0000|privateName/);expect(JSON.stringify(logged.mock.calls)).not.toContain("PRIVATE");
  expect(request).toHaveBeenCalledTimes(3);
 });
 it("fails closed with an honest unavailable projection when owner inspection is rejected", async () => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  const request = vi.fn(async (_url: string, options: RequestInit) => {
   const body = JSON.parse(String(options.body));
   return body.read_only === false ? Response.json({ message: "private participant name must not escape" }, { status: 400 }) : Response.json(body.query === AUDIT_QUERY ? [{ audit: structuredClone(baseAudit) }] : []);
  });
  const path = await runAudit(await fixtureEnv({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production" }), request);
  const result = JSON.parse(await readFile(path, "utf8"));
  expect(result.routeProjection.readable).toBe(false);
  expect(request.mock.calls.map(([,options])=>JSON.parse(String(options.body)).query)).toEqual([PREVIEW_AUDIT_QUERY,AUDIT_QUERY,JOINT_PROPOSAL_INPUT_QUERY,SNAPSHOT_STATS_QUERY]);
  expect(JSON.stringify(result)).not.toContain("private participant");
  expect(ownerPreviewAllowed({ GITHUB_REPOSITORY: "another/repo", GITHUB_REF: "refs/heads/production" })).toBe(false);
  expect(ownerPreviewAllowed({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", APP_ENVIRONMENT: "staging" })).toBe(false);
 });
 it.each([
  {label:"missing projection",audit:{...baseAudit}},
  {label:"missing database proof",audit:{...baseAudit,routeProjection:{readable:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"false database proof",audit:{...baseAudit,routeProjection:{readable:true,databaseReadOnly:false,authorizedExistingAdmin:true,groups:[]}}},
  {label:"truthy forged database proof",audit:{...baseAudit,routeProjection:{readable:true,databaseReadOnly:"true",authorizedExistingAdmin:true,groups:[]}}},
  {label:"missing authorization",audit:{...baseAudit,routeProjection:{readable:true,databaseReadOnly:true,groups:[]}}},
  {label:"truthy forged authorization",audit:{...baseAudit,routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:"true",groups:[]}}},
  {label:"unreadable projection",audit:{...baseAudit,routeProjection:{readable:false,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"missing projection groups",audit:{...baseAudit,routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true}}},
  {label:"invalid complete base audit",audit:{...baseAudit,readOnly:false,routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"proof booleans without a complete base audit",audit:{readOnly:true,groups:[],routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"missing checkpoint",audit:{...baseAudit,checkpoint:undefined,routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"invalid physical calendar",audit:{...baseAudit,physicalCalendar:{...baseAudit.physicalCalendar,visits:null},routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
  {label:"inconsistent group count",audit:{...baseAudit,counts:{...baseAudit.counts,groups:2},routeProjection:{readable:true,databaseReadOnly:true,authorizedExistingAdmin:true,groups:[]}}},
 ])("rejects $label and obtains the mandatory base independently",async({audit})=>{
  vi.spyOn(console,"log").mockImplementation(()=>{});
  const request=vi.fn(async(_url:string,options:RequestInit)=>{
   const body=JSON.parse(String(options.body));
   if(body.query===PREVIEW_AUDIT_QUERY)return Response.json([{audit:{...audit,forgedMarker:"FORGED"}}]);
   if(body.query===AUDIT_QUERY)return Response.json([{audit:structuredClone(baseAudit)}]);
   if(body.query===JOINT_PROPOSAL_INPUT_QUERY)return Response.json([{joint_input:{available:false,reasonCode:"JOINT_PLANNING_MIGRATION_NOT_INSTALLED"}}]);
   return Response.json([]);
  });
  const path=await runAudit(await fixtureEnv({GITHUB_REPOSITORY:"duindorpdoet/platform",GITHUB_REF:"refs/heads/production",APP_ENVIRONMENT:"production"}),request);
  const result=JSON.parse(await readFile(path,"utf8"));
  expect(result.groups).toEqual(baseAudit.groups);
  expect(result.checkpoint).toEqual(baseAudit.checkpoint);
  expect(result.routeProjection).toEqual({readable:false,reasonCode:"OWNER_READ_ONLY_AUDIT_PROOF_MISSING"});
  expect(JSON.stringify(result)).not.toContain("FORGED");
  expect(request.mock.calls.filter(([,options])=>JSON.parse(String(options.body)).query===AUDIT_QUERY)).toHaveLength(1);
 });
 it.each(["http failure","missing event"])("still fails closed when preview is unavailable and the mandatory base has %s",async failure=>{
  const request=vi.fn(async(_url:string,options:RequestInit)=>{
   const body=JSON.parse(String(options.body));
   if(body.query===PREVIEW_AUDIT_QUERY)return Response.json({message:"private preview error"},{status:503});
   expect(body.query).toBe(AUDIT_QUERY);
   expect(body.read_only).toBe(true);
   return failure==="http failure"?Response.json({message:"private base error"},{status:503}):Response.json([]);
  });
  const context=await fixtureEnv({GITHUB_REPOSITORY:"duindorpdoet/platform",GITHUB_REF:"refs/heads/production",APP_ENVIRONMENT:"production"});
  await expect(runAudit(context,request)).rejects.toThrow(failure==="http failure"?"READ_ONLY_AUDIT_HTTP_503_SQLSTATE_UNKNOWN":"READ_ONLY_AUDIT_EVENT_MISSING");
  expect(request.mock.calls.map(([,options])=>JSON.parse(String(options.body)).query)).toEqual([PREVIEW_AUDIT_QUERY,AUDIT_QUERY]);
 });
});
