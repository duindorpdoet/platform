import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { classifyConnectionError, diagnosticPlan, DIAGNOSTIC_SQL, runDiagnostics } from "./production-db-diagnostics.mjs";

const ref = "dtubngvxfbupgvgfrjko";
const env = { GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/production",
  GITHUB_REPOSITORY: "duindorpdoet/platform", APP_ENVIRONMENT: "production", SUPABASE_PROJECT_REF: ref,
  GITHUB_SHA: "a".repeat(40), SUPABASE_ACCESS_TOKEN: "fixture-token", SUPABASE_DB_PASSWORD: "fixture-password" };
const project = { id: ref, region: "eu-west-1", database: { host: `db.${ref}.supabase.co`, version: "17.6.1.071" } };
const pooler = { pool_mode: "session", db_host: "aws-0-eu-west-1.pooler.supabase.com", db_user: "postgres", db_name: "postgres", db_port: 5432 };

describe("production pooler read-only diagnostics", () => {
  it("binds the exact production context and never places credentials in arguments", () => {
    const plan = diagnosticPlan(env, project, [pooler]);
    expect(plan.environment.PGUSER).toBe(`postgres.${ref}`);
    expect(plan.environment.PGPASSWORD).toBe(env.SUPABASE_DB_PASSWORD);
    expect(plan.clientArgs.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD);
    expect(plan.clientArgs.join(" ")).not.toContain(env.SUPABASE_ACCESS_TOKEN);
    expect(plan.environment.PGOPTIONS).toContain("default_transaction_read_only=on");
    expect(DIAGNOSTIC_SQL).toMatch(/^begin read only;/);
    expect(DIAGNOSTIC_SQL.trim()).toMatch(/rollback;$/);
    expect(DIAGNOSTIC_SQL).not.toMatch(/pg_(cancel|terminate)_backend|\b(insert|update|delete|truncate|create|alter|drop)\b/i);
    expect(DIAGNOSTIC_SQL).toContain("set local statement_timeout='5s'");
    expect(DIAGNOSTIC_SQL).toContain("set local lock_timeout='500ms'");
  });
  it("rejects other branches/projects, arbitrary hosts, roles, databases and unknown pooler modes", () => {
    for (const GITHUB_REF of ["refs/heads/staging", "refs/heads/codex/startregie-production-db-diagnostics", "refs/heads/main"])
      expect(() => diagnosticPlan({ ...env, GITHUB_REF }, project, [pooler])).toThrow("PRODUCTION_BOUNDARY");
    expect(() => diagnosticPlan(env, { ...project, id: "nocteiuvohesvqbowchw" }, [pooler])).toThrow("PROJECT_METADATA_BOUNDARY");
    for (const change of [{ db_host: "aws-0-eu-west-1.pooler.supabase.com.evil.invalid" }, { db_host: "aws-0-eu-central-1.pooler.supabase.com" },
      { db_user: "supabase_admin" }, { db_user: "postgres.nocteiuvohesvqbowchw" }, { db_name: "other" }, { pool_mode: "unknown" }]) {
      expect(() => diagnosticPlan(env, project, [{ ...pooler, ...change }])).toThrow("TRUSTED_SESSION_POOLER_REQUIRED");
    }
  });
  it("uses the fixed session port even when the API only reports transaction metadata, and prefers an explicit session entry", () => {
    const transaction = { ...pooler, pool_mode: "transaction", db_port: 6543 };
    expect(diagnosticPlan(env, project, [transaction]).environment.PGPORT).toBe("5432");
    const session = { ...pooler, db_host: "aws-1-eu-west-1.pooler.supabase.com" };
    expect(diagnosticPlan(env, project, [transaction, session]).environment.PGHOST).toBe(session.db_host);
  });
  it("only requests metadata with GET and executes the fixed SQL through the protected client", async () => {
    const request = vi.fn<typeof fetch>(async input => new Response(JSON.stringify(String(input).endsWith("/pooler") ? [pooler] : project)));
    const execute = vi.fn().mockResolvedValueOnce({ code: 0, expired: false, stdout: "ignored pull output" })
      .mockResolvedValueOnce({ code: 0, expired: false, stdout: '{"connectivity":1,"readOnly":true}\n{"activity":[]}' });
    const result = await runDiagnostics(env, request, execute);
    expect(result).toMatchObject({ readOnly: true, changedRows: 0, messagesSent: 0, activity: [] });
    expect(request.mock.calls).toHaveLength(2);
    for (const [, options] of request.mock.calls) expect(options?.method).toBe("GET");
    expect(execute.mock.calls[1][1]).toBe(DIAGNOSTIC_SQL);
    expect(execute.mock.calls[1][2].PGPASSWORD).toBe(env.SUPABASE_DB_PASSWORD);
  });
  it("rejects outside context before network access and never exposes provider errors", async () => {
    const request = vi.fn();
    await expect(runDiagnostics({ ...env, GITHUB_EVENT_NAME: "push" }, request)).rejects.toThrow("PRODUCTION_BOUNDARY");
    expect(request).not.toHaveBeenCalled();
    await expect(runDiagnostics(env, async () => { throw new Error("fixture-secret-provider-error"); })).rejects.toThrow("METADATA_REQUEST_FAILED");
  });
  it("keeps the explicit diagnostic mode separate from production deployment and other diagnostics", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/deploy-production.yml", import.meta.url), "utf8");
    const job = (name: string) => workflow.split(`\n  ${name}:\n`)[1]?.split(/\n  [a-z][a-z-]+:\n/)[0] ?? "";
    expect(job("database-connection-diagnostics")).toContain("github.event_name == 'workflow_dispatch' && inputs.database_connection_diagnostics == true && inputs.database_diagnostics_scope == 'pooler' && !inputs.database_connection_recovery && github.ref == 'refs/heads/production' && github.repository == 'duindorpdoet/platform'");
    for (const name of ["prepare-database-client", "backup-export", "backup-restore", "deploy", "readonly-baseline", "mail-worker-diagnostics"])
      expect(job(name).split("\n").find(line => line.trim().startsWith("if:"))).toContain("!inputs.database_connection_diagnostics");
    expect(workflow).toMatch(/database_connection_diagnostics:\n(?:[^\n]*\n){2}        default: false/);
  });
  it("classifies connection failures without confusing authentication or SQL timeout with connection exhaustion", () => {
    expect(classifyConnectionError('psql: connection to server at "fixture" failed: timeout expired')).toBe("CONNECTION_TIMEOUT");
    expect(classifyConnectionError("password authentication failed for user fixture; timeout expired")).toBe("AUTH_FAILED");
    expect(classifyConnectionError("SSL certificate verification failed")).toBe("TLS");
    expect(classifyConnectionError("could not translate host name fixture: Name or service not known")).toBe("DNS");
    expect(classifyConnectionError("canceling statement due to statement timeout")).toBe("OTHER");
    expect(classifyConnectionError("connection refused")).toBe("OTHER");
  });
});
