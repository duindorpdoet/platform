import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { MANAGEMENT_PROBE_SQL, recoverProductionDatabase } from "./production-db-recovery.mjs";
import type { ConnectionErrorClass } from "./production-db-diagnostics.mjs";

const ref = "dtubngvxfbupgvgfrjko", base = `https://api.supabase.com/v1/projects/${ref}`;
const env = { GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/production", GITHUB_REPOSITORY: "duindorpdoet/platform",
  GITHUB_SHA: "a".repeat(40), APP_ENVIRONMENT: "production", SUPABASE_PROJECT_REF: ref,
  NEXT_PUBLIC_SUPABASE_URL: `https://${ref}.supabase.co`, NEXT_PUBLIC_SUPABASE_ANON_KEY: "fixture-public-key",
  SUPABASE_ACCESS_TOKEN: "fixture-private-token", SUPABASE_DB_PASSWORD: "fixture-private-password",
  DATABASE_RECOVERY_REQUESTED: "true", DATABASE_RECOVERY_REASON: "Fixture confirmed triple connection outage only" };

function fixture(options: { managementStatus?: number; dataStatus?: number; dataCode?: string; poolerConnected?: boolean;
  poolerClass?: ConnectionErrorClass; restartFailure?: boolean; postRestartUnavailable?: boolean } = {}) {
  let restarted = false, clock = 0;
  const request = vi.fn<typeof fetch>(async (input, init) => {
    const url = String(input);
    if (url === base && init?.method === "GET") return Response.json({ id: ref, status: "ACTIVE_HEALTHY", region: "eu-west-1",
      database: { host: `db.${ref}.supabase.co`, version: "17.6.1.071" } });
    if (url === base + "/config/database/pooler" && init?.method === "GET") return Response.json([
      { pool_mode: "session", db_host: "aws-0-eu-west-1.pooler.supabase.com", db_user: "postgres", db_name: "postgres", db_port: 5432 }]);
    if (url === base + "/database/backups" && init?.method === "GET") return Response.json({ backups: [{ inserted_at: "2026-10-31T00:00:00Z", status: "COMPLETED" }] });
    if (url === base + "/database/query" && init?.method === "POST") {
      expect(JSON.parse(String(init.body))).toEqual({ read_only: true, query: MANAGEMENT_PROBE_SQL });
      const status = restarted ? options.postRestartUnavailable ? 544 : 200 : options.managementStatus ?? 544;
      return Response.json(status === 200 ? [{ connectivity: 1 }] : { message: "fixture private provider timeout" }, { status });
    }
    if (url === `https://${ref}.supabase.co/rest/v1/rpc/admin_startregie_snapshot` && init?.method === "POST") {
      expect(new Headers(init.headers).get("content-profile")).toBe("api");
      return Response.json({ code: options.dataCode ?? "PGRST002", message: "fixture private unavailable schema" }, { status: options.dataStatus ?? 503 });
    }
    if (url === base + "/restart" && init?.method === "POST") {
      expect(init.body).toBeUndefined();
      restarted = true;
      if (options.restartFailure) throw new Error("fixture private ambiguous restart");
      return Response.json({});
    }
    throw new Error("UNEXPECTED_ENDPOINT");
  });
  const pooler = vi.fn(async () => ({ connectivity: options.poolerConnected ?? false, errorClass: options.poolerClass ?? "CONNECTION_TIMEOUT" as ConnectionErrorClass }));
  const run = (overrides = {}) => recoverProductionDatabase({ ...env, ...overrides }, request, pooler, () => clock, async ms => { clock += ms; });
  return { request, pooler, run, restartRequests: () => request.mock.calls.filter(([url]) => String(url).endsWith("/restart")), elapsed: () => clock };
}

describe("explicit protected production database recovery", () => {
  it("requires the exact production boundary, explicit flag and substantial reason before network access", async () => {
    for (const overrides of [{ DATABASE_RECOVERY_REQUESTED: "false" }, { DATABASE_RECOVERY_REASON: "short" },
      { GITHUB_REF: "refs/heads/staging" }, { GITHUB_EVENT_NAME: "push" }, { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" }]) {
      const check = fixture();
      await expect(check.run(overrides)).rejects.toThrow("EXPLICIT_PRODUCTION_AUTHORIZATION_REQUIRED");
      expect(check.request).not.toHaveBeenCalled();
    }
  });
  it("sends one bodyless restart only after all independent outage checks and then requires a fresh SELECT1", async () => {
    const check = fixture(), log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      await expect(check.run()).resolves.toMatchObject({ restarted: true, restartRequests: 1, managementReachable: true, deployed: false, sqlWrites: 0, messagesSent: 0 });
      expect(check.restartRequests()).toHaveLength(1);
      const paths = check.request.mock.calls.map(([url]) => String(url));
      expect(paths.filter(url => url.endsWith("/database/query"))).toHaveLength(2);
      const restartIndex = paths.indexOf(base + "/restart");
      expect(paths.indexOf(base + "/database/query")).toBeLessThan(restartIndex);
      expect(paths.findIndex(url => url.includes("/rest/v1/rpc/"))).toBeLessThan(restartIndex);
      expect(paths.slice(restartIndex + 1)).toEqual([base + "/database/query"]);
      expect(paths.every(url => [base, base + "/config/database/pooler", base + "/database/backups", base + "/database/query", base + "/restart", `https://${ref}.supabase.co/rest/v1/rpc/admin_startregie_snapshot`].includes(url))).toBe(true);
      const printed = JSON.stringify(log.mock.calls);
      for (const secret of [env.SUPABASE_ACCESS_TOKEN, env.SUPABASE_DB_PASSWORD, env.DATABASE_RECOVERY_REASON, "fixture private"]) expect(printed).not.toContain(secret);
    } finally { log.mockRestore(); }
  });
  it.each(["AUTH_FAILED", "TLS", "DNS", "OTHER"] as const)("refuses pooler %s failures without restart", async poolerClass => {
    const check = fixture({ poolerClass });
    await expect(check.run()).rejects.toThrow("POOLER_RESTART_VETO");
    expect(check.restartRequests()).toEqual([]);
  });
  it("refuses any successful pooler or Management SQL connection", async () => {
    for (const options of [{ poolerConnected: true }, { managementStatus: 200 }]) {
      const check = fixture(options);
      await expect(check.run()).rejects.toThrow("RESTART_VETO");
      expect(check.restartRequests()).toEqual([]);
    }
  });
  it.each([{ dataStatus: 401 }, { dataStatus: 503, dataCode: "PGRST301" }, { dataStatus: 200 }])("refuses every Data API state except exact 503/PGRST002: %j", async options => {
    const check = fixture(options);
    await expect(check.run()).rejects.toThrow("DATA_API_RESTART_VETO");
    expect(check.restartRequests()).toEqual([]);
  });
  it("refuses Management authentication failures and never retries an ambiguous restart", async () => {
    const refused = fixture({ managementStatus: 403 });
    await expect(refused.run()).rejects.toThrow("MANAGEMENT_RESTART_VETO");
    expect(refused.restartRequests()).toEqual([]);
    const ambiguous = fixture({ restartFailure: true });
    await expect(ambiguous.run()).rejects.toThrow("RESTART_REQUEST_UNCONFIRMED_NO_RETRY");
    expect(ambiguous.restartRequests()).toHaveLength(1);
  });
  it("bounds post-restart reads to five minutes without another restart or deployment", async () => {
    const check = fixture({ postRestartUnavailable: true });
    await expect(check.run()).rejects.toThrow("POST_RESTART_READ_UNCONFIRMED_NO_RETRY");
    expect(check.elapsed()).toBe(300_000);
    expect(check.restartRequests()).toHaveLength(1);
    expect(check.request.mock.calls.filter(([url]) => String(url).endsWith("/database/query"))).toHaveLength(31);
  });
  it("only enables recovery explicitly and preserves all normal release gates", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/deploy-production.yml", import.meta.url), "utf8");
    const job = (name: string) => workflow.split(`\n  ${name}:\n`)[1]?.split(/\n  [a-z][a-z-]+:\n/)[0] ?? "";
    expect(job("database-connection-recovery")).toContain("github.event_name == 'workflow_dispatch' && inputs.database_connection_recovery == true && github.ref == 'refs/heads/production' && github.repository == 'duindorpdoet/platform'");
    for (const name of ["backup-restore", "deploy", "readonly-baseline", "mail-worker-diagnostics", "database-connection-diagnostics"])
      expect(job(name).split("\n").find(line => line.trim().startsWith("if:"))).toContain("!inputs.database_connection_recovery");
    expect(workflow).toMatch(/database_connection_recovery:\n(?:[^\n]*\n){2}        default: false/);
    expect(job("backup-restore")).toContain("Require exact successful staging revision");
    expect(job("deploy")).toContain("needs: [backup-restore, release-policy]");
    const script = readFileSync(new URL("./production-db-recovery.mjs", import.meta.url), "utf8");
    expect(script).not.toMatch(/\/restore|\/reset|pg_(cancel|terminate)_backend|\b(update|insert|delete|truncate|alter|drop)\s/i);
  });
});
