import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AUDIT_QUERY, PREVIEW_AUDIT_QUERY, ownerPreviewAllowed, runAudit } from "./evening-readiness-audit.mjs";

const directories: string[] = [];
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(directories.splice(0).map(path => rm(path, { recursive: true, force: true }))); });
async function fixtureEnv(extra = {}) {
 const directory = await mkdtemp(join(tmpdir(), "coded-readonly-audit-")); directories.push(directory);
 return { SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst", SUPABASE_ACCESS_TOKEN: "fixture-never-log", RUNNER_TEMP: directory, ...extra };
}
const baseAudit = { readOnly: true, groups: [{ code: "G-TEST", ordinaryHouses: null }], checkpoint: { appointments: "same", routesAndRuns: "same" } };
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
  const routeCheck = { code: "G-TEST", source: "current_ops_preview", ordinaryHouses: 19, finales: 1, duplicatePhysicalLocations: [], startMarkerValid: true, ordinaryAndersReachable: true };
  const request = vi.fn(async (_url: string, options: RequestInit) => {
   const body = JSON.parse(String(options.body));
   if (body.read_only === false) {
    expect(body.query).toBe(PREVIEW_AUDIT_QUERY);
    return Response.json([{ audit: { ...structuredClone(baseAudit), routeProjection: { readable: true, databaseReadOnly: true, authorizedExistingAdmin: true, groups: [routeCheck] } } }]);
   }
   return Response.json(body.query === AUDIT_QUERY ? [{ audit: structuredClone(baseAudit) }] : []);
  });
  const path = await runAudit(await fixtureEnv({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", APP_ENVIRONMENT: "production" }), request);
  const result = JSON.parse(await readFile(path, "utf8"));
  expect(result.groups[0].routeCheck).toEqual(routeCheck);
  expect(result.checkpoint).toEqual(baseAudit.checkpoint);
  expect(result.changedRows).toBe(0); expect(result.messagesSent).toBe(0);
  expect(JSON.stringify(result)).not.toContain("fixture-never-log");
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
  expect(JSON.stringify(result)).not.toContain("private participant");
  expect(ownerPreviewAllowed({ GITHUB_REPOSITORY: "another/repo", GITHUB_REF: "refs/heads/production" })).toBe(false);
  expect(ownerPreviewAllowed({ GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", APP_ENVIRONMENT: "staging" })).toBe(false);
 });
});
