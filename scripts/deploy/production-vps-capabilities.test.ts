import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { runVpsCapabilities } from "./production-vps-capabilities.mjs";

const env = { DIAGNOSTIC_VPS_CAPABILITIES: "true", APP_ENVIRONMENT: "production", GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", GITHUB_SHA: "a".repeat(40),
  RUNNER_NAME: "dg-sites-vps-01-duindorphalloweenprod-01", GITHUB_WORKSPACE: "/srv/sites/duindorphalloweenprod/actions-runner/_work/platform/platform", RUNNER_TEMP: "/PRIVATE_TEMP",
  SUPABASE_DB_PASSWORD: "PRIVATE_PASSWORD", SUPABASE_ACCESS_TOKEN: "PRIVATE_TOKEN" };
describe("dedicated VPS local capabilities", () => {
  it("executes only fixed local version commands and emits parsed public versions, booleans and free-byte counts", async () => {
    const execute = vi.fn(async (name: string, args: string[], timeoutMs: number) => {
      void args; void timeoutMs;
      return { available: true, stdout: name === "docker" ? "PRIVATE_DOCKER_DETAILS" : `${name} (PostgreSQL) 17.6 (PRIVATE_BUILD)\n` };
    });
    const filesystem = vi.fn(async (path: string) => ({ bavail: path === env.RUNNER_TEMP ? 2n : 3n, bsize: 4096n }));
    const report = await runVpsCapabilities(env, execute, filesystem);
    expect(report).toEqual({ diagnostic: "production-vps-local-capabilities", scope: "VPS_CLIENT", databaseAccessed: false, sqlSent: false,
      tools: { psql: { available: true, version: "17.6" }, pg_dump: { available: true, version: "17.6" }, pg_restore: { available: true, version: "17.6" } },
      workspaceAvailableBytes: 12288, tempAvailableBytes: 8192, dockerServerReachable: true });
    expect(execute.mock.calls).toEqual([["psql", ["--version"], 3000], ["pg_dump", ["--version"], 3000], ["pg_restore", ["--version"], 3000], ["docker", ["--host", "unix:///var/run/docker.sock", "version", "--format", "{{.Server.Version}}"], 5000]]);
    expect(filesystem.mock.calls).toEqual([[env.GITHUB_WORKSPACE], [env.RUNNER_TEMP]]);
    expect(JSON.stringify(report)).not.toMatch(/PRIVATE|password|host|address|path/i);
  });
  it("rejects outside the exact manual production VPS boundary before any local command or filesystem call", async () => {
    for (const changes of [{ DIAGNOSTIC_VPS_CAPABILITIES: "false" }, { APP_ENVIRONMENT: "staging" }, { GITHUB_EVENT_NAME: "push" },
      { GITHUB_REPOSITORY: "other/platform" }, { GITHUB_REF: "refs/heads/main" }, { GITHUB_SHA: "bad" }, { RUNNER_NAME: "other" }, { GITHUB_WORKSPACE: "/tmp/platform" }]) {
      const execute = vi.fn(), filesystem = vi.fn();
      await expect(runVpsCapabilities({ ...env, ...changes }, execute, filesystem)).rejects.toThrow("VPS_CAPABILITY_BOUNDARY");
      expect(execute).not.toHaveBeenCalled(); expect(filesystem).not.toHaveBeenCalled();
    }
  });
  it("reports unavailable or unrecognized tools and unsafe space values without exposing raw failures", async () => {
    const execute = vi.fn(async (name: string) => {
      if (name === "psql") return { available: false, stdout: "PRIVATE_PATH" };
      if (name === "pg_dump") return { available: true, stdout: "PRIVATE_RAW_OUTPUT" };
      throw new Error("PRIVATE_FAILURE");
    });
    const filesystem = vi.fn(async (path: string) => ({ bavail: path === env.RUNNER_TEMP ? -1n : BigInt(Number.MAX_SAFE_INTEGER), bsize: 4096n }));
    const report = await runVpsCapabilities(env, execute, filesystem);
    expect(report.tools).toEqual({ psql: { available: false, version: null }, pg_dump: { available: true, version: null }, pg_restore: { available: false, version: null } });
    expect(report).toMatchObject({ workspaceAvailableBytes: null, tempAvailableBytes: null, dockerServerReachable: false });
    expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
  it("separates the two direct capability jobs from the default pooler probe and all normal release actions", () => {
    const source = readFileSync(new URL("../../.github/workflows/deploy-production.yml", import.meta.url), "utf8");
    const job = (name: string) => source.split(`\n  ${name}:\n`)[1]?.split(/\n  [a-z][a-z-]+:\n/)[0] ?? "";
    expect(source).toContain("database_diagnostics_scope:"); expect(source).toContain("default: pooler");
    expect(job("database-connection-diagnostics")).toContain("inputs.database_diagnostics_scope != 'direct-capability'");
    for (const name of ["database-direct-capability", "database-vps-capability"]) {
      const value = job(name);
      for (const guard of ["github.event_name == 'workflow_dispatch'", "inputs.database_connection_diagnostics == true", "inputs.database_diagnostics_scope == 'direct-capability'", "!inputs.database_connection_recovery", "github.ref == 'refs/heads/production'", "github.repository == 'duindorpdoet/platform'"]) expect(value).toContain(guard);
      expect(value).toContain("name: production\n      deployment: false");
    }
    expect(job("database-direct-capability")).toContain('DIAGNOSTIC_DIRECT_CAPABILITY: "true"');
    expect(job("database-direct-capability")).toContain("pnpm install --frozen-lockfile");
    const local = job("database-vps-capability");
    expect(local).toContain("- duindorphalloweenprod"); expect(local).toContain('test "$(id -un)" = "duindorphalloweenprod"');
    expect(local).toContain("clean: false"); expect(local).toContain("externals/node24/bin/node");
    expect(local).not.toMatch(/SUPABASE|pnpm|npm |setup-node|sudo|curl|psql /);
    for (const name of ["backup-restore", "deploy"]) expect(job(name).split("\n").find(line => line.trim().startsWith("if:"))).toContain("!inputs.database_connection_diagnostics");
  });
});
