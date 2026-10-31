import { afterEach, describe, expect, it, vi } from "vitest";
import { EventEmitter } from "node:events";
import { readFileSync, statSync, existsSync } from "node:fs";
import type { spawn } from "node:child_process";
import { runProductionDirectMigration, runProductionDirectMigrationDryRun } from "./migrate-production-direct.mjs";
import { publicReleaseCaBundle, sessionReadQuery } from "./production-read-query.mjs";

vi.mock("./production-read-query.mjs", async importOriginal => ({
  ...await importOriginal<typeof import("./production-read-query.mjs")>(), sessionReadQuery: vi.fn(),
}));
const ref = "dtubngvxfbupgvgfrjko";
const env = { RELEASE_READ_TRANSPORT: "direct", GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/production", GITHUB_REPOSITORY: "duindorpdoet/platform", APP_ENVIRONMENT: "production",
  SUPABASE_PROJECT_REF: ref, GITHUB_SHA: "a".repeat(40), APP_REVISION: "a".repeat(40),
  SUPABASE_ACCESS_TOKEN: "fixture-private-token", SUPABASE_DB_PASSWORD: "fixture-private-password" };
const project = { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co` } };
const pooler = { pool_mode: "transaction", db_host: "aws-1-eu-west-2.pooler.supabase.com", db_user: "postgres", db_name: "postgres", db_port: 6543 };
const migrationName = "20261030231652_bound_startregie_snapshot_reads.sql";
const report = readFileSync(new URL("./nachtpost-activation-report.sql", import.meta.url), "utf8");
const stdout = vi.spyOn(console, "log").mockImplementation(() => {});
const stderr = vi.spyOn(console, "error").mockImplementation(() => {});

afterEach(() => { vi.useRealTimers(); vi.mocked(sessionReadQuery).mockReset(); stdout.mockClear(); stderr.mockClear(); });

function fixture(options: { status?: number; metadata?: unknown; poolers?: unknown; poolerStatus?: number; requestError?: Error; exit?: number; signal?: string;
  output?: string; error?: Error; pending?: boolean; startError?: Error; onSpawn?: (args: readonly string[], options: Record<string, unknown>) => void } = {}) {
  const request = vi.fn<typeof fetch>(async input => {
    if (options.requestError) throw options.requestError;
    if (String(input).endsWith("/pooler")) return new Response(JSON.stringify(options.poolers ?? [pooler]), { status: options.poolerStatus ?? 200 });
    return new Response(JSON.stringify(options.metadata ?? project), { status: options.status ?? 200 });
  });
  const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), stderr: new EventEmitter(),
    kill: vi.fn(() => true), pid: undefined as number | undefined });
  let caFile = "";
  let spawnedAt = 0;
  const spawnProcess = vi.fn((command: string, args: readonly string[], spawnOptions: Record<string, unknown>) => {
    spawnedAt = Date.now();
    expect(command).toBe("pnpm");
    caFile = new URL(args[5]).searchParams.get("sslrootcert") ?? "";
    options.onSpawn?.(args, spawnOptions);
    if (options.startError) throw options.startError;
    queueMicrotask(() => {
      if (options.output) { child.stdout.emit("data", Buffer.from(options.output)); child.stderr.emit("data", Buffer.from(options.output)); }
      if (options.error) child.emit("error", options.error);
      else if (!options.pending) child.emit("close", options.exit ?? 0, options.signal ?? null);
    });
    return child;
  });
  vi.mocked(sessionReadQuery).mockResolvedValue([{ nachtpost_activation: { private: "never-print-report" } }]);
  return { request, child, spawnProcess, caFile: () => caFile, spawnedAt: () => spawnedAt,
    run: (context: Record<string, string | undefined> = env) => runProductionDirectMigration(context, request, spawnProcess as unknown as typeof spawn),
    runDry: (context: Record<string, string | undefined> = { ...env, MIGRATION_CONNECT_PROOF: "true" }) => runProductionDirectMigrationDryRun(context, request, spawnProcess as unknown as typeof spawn) };
}

function observedOutput() { return [...stdout.mock.calls, ...stderr.mock.calls].flat().join("\n"); }

describe("production direct migration", () => {
  it.each(["apply", "dry-run"])("uses one verified session-pooler owner connection on 5432 for %s", async mode => {
    const context = { ...env, RELEASE_READ_TRANSPORT: "session-pooler", RELEASE_READ_CLIENT: "libpq", RELEASE_PG_CLIENT_DIRECTORY: "/fixed", MIGRATION_CONNECT_PROOF: "true" };
    const f = fixture({ onSpawn: (args, options) => {
      const url = new URL(args[5]);
      expect(url.hostname).toBe(pooler.db_host); expect(url.port).toBe("5432"); expect(url.username).toBe(`postgres.${ref}`);
      expect(url.password).toBe(""); expect(url.searchParams.get("sslmode")).toBe("verify-full");
      expect(args.includes("--dry-run")).toBe(mode === "dry-run");
      expect(args.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD);
      expect(options).toMatchObject({ env: { PGHOST: pooler.db_host, PGPORT: "5432", PGUSER: `postgres.${ref}`,
        PGSSLMODE: "verify-full", PGPASSWORD: env.SUPABASE_DB_PASSWORD } });
    } });
    const result = await (mode === "dry-run" ? f.runDry(context) : f.run(context));
    expect(result.status).toBe("SUCCESS"); expect(f.spawnProcess).toHaveBeenCalledOnce();
    expect(f.request.mock.calls.map(call => call[0])).toEqual([
      `https://api.supabase.com/v1/projects/${ref}`, `https://api.supabase.com/v1/projects/${ref}/config/database/pooler`,
    ]);
    expect(sessionReadQuery).toHaveBeenCalledTimes(mode === "dry-run" ? 0 : 1); expect(existsSync(f.caFile())).toBe(false);
  });
  it.each([{ db_host: "untrusted.example" }, { db_user: "supabase_admin" }, { db_name: "another_database" }])("rejects untrusted session-pooler metadata %j before CLI or SQL", async changed => {
    const f = fixture({ poolers: [{ ...pooler, ...changed }] });
    await expect(f.run({ ...env, RELEASE_READ_TRANSPORT: "session-pooler", RELEASE_READ_CLIENT: "libpq", RELEASE_PG_CLIENT_DIRECTORY: "/fixed" }))
      .rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_METADATA_BOUNDARY$/);
    expect(f.request).toHaveBeenCalledTimes(2); expect(f.spawnProcess).not.toHaveBeenCalled(); expect(sessionReadQuery).not.toHaveBeenCalled();
  });
  it.each([401, 503])("never retries session-pooler metadata HTTP %s or starts CLI", async status => {
    const f = fixture({ poolerStatus: status });
    await expect(f.run({ ...env, RELEASE_READ_TRANSPORT: "session-pooler", RELEASE_READ_CLIENT: "libpq", RELEASE_PG_CLIENT_DIRECTORY: "/fixed" }))
      .rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_METADATA_HTTP_FAILED$/);
    expect(f.request).toHaveBeenCalledTimes(2); expect(f.spawnProcess).not.toHaveBeenCalled(); expect(sessionReadQuery).not.toHaveBeenCalled();
  });
  it("requires explicit manual dry-run proof before any metadata, command or report", async () => {
    for (const changes of [{ MIGRATION_CONNECT_PROOF: undefined }, { MIGRATION_CONNECT_PROOF: "false" }, { GITHUB_EVENT_NAME: "push" },
      { GITHUB_REF: "refs/heads/main" }, { GITHUB_REPOSITORY: "other/platform" }, { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" }]) {
      const f = fixture();
      await expect(f.runDry({ ...env, MIGRATION_CONNECT_PROOF: "true", ...changes })).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_ENVIRONMENT_BOUNDARY$/);
      expect(f.request).not.toHaveBeenCalled(); expect(f.spawnProcess).not.toHaveBeenCalled(); expect(sessionReadQuery).not.toHaveBeenCalled();
    }
  });
  it("hardcodes one dry-run command with environment-only credentials and never runs the activation report", async () => {
    const f = fixture({ output: `${migrationName}\n20990101010101_private.sql\n${env.SUPABASE_DB_PASSWORD}`, onSpawn: (args, options) => {
      const url = new URL(args[5]);
      expect(args).toEqual(["exec", "supabase", "db", "push", "--db-url", url.href, "--dry-run", "--include-all", "--yes"]);
      expect(args.filter(arg => arg === "--dry-run")).toHaveLength(1);
      expect(url.hostname).toBe(project.database.host); expect(url.password).toBe("");
      expect(args.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD);
      expect(options).toMatchObject({ env: { PGPASSWORD: env.SUPABASE_DB_PASSWORD, PGSSLMODE: "verify-full" } });
    } });
    const result = await f.runDry({ ...env, MIGRATION_CONNECT_PROOF: "true", DRY_RUN: "false", SUPABASE_CLI_ARGS: "--no-dry-run" });
    expect(result).toEqual({ status: "SUCCESS", sqlStates: [], migrations: [migrationName], dryRun: true });
    expect(f.spawnProcess).toHaveBeenCalledOnce(); expect(f.request).toHaveBeenCalledOnce(); expect(sessionReadQuery).not.toHaveBeenCalled();
    expect(existsSync(f.caFile())).toBe(false); expect(observedOutput()).not.toContain(env.SUPABASE_DB_PASSWORD);
    expect(observedOutput()).not.toContain("20990101010101_private.sql");
  });
  it("never lets a proof environment toggle change the normal apply API", async () => {
    const f = fixture(); await f.run({ ...env, MIGRATION_CONNECT_PROOF: "true", DRY_RUN: "true" });
    expect(f.spawnProcess.mock.calls[0][1]).not.toContain("--dry-run"); expect(sessionReadQuery).toHaveBeenCalledOnce();
  });
  it("fails a dry-run CLI attempt without a report, replay or unredacted output", async () => {
    const f = fixture({ exit: 1, output: `${env.SUPABASE_ACCESS_TOKEN} ${env.SUPABASE_DB_PASSWORD}\n(SQLSTATE 57014)` });
    await expect(f.runDry()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_CLI_FAILED$/);
    expect(f.spawnProcess).toHaveBeenCalledOnce(); expect(f.spawnProcess.mock.calls[0][1]).toContain("--dry-run");
    expect(sessionReadQuery).not.toHaveBeenCalled(); expect(existsSync(f.caFile())).toBe(false);
    expect(observedOutput()).not.toContain(env.SUPABASE_DB_PASSWORD); expect(observedOutput()).not.toContain(env.SUPABASE_ACCESS_TOKEN);
  });
  it("rejects every foreign release boundary before metadata, CLI or report SQL", async () => {
    for (const changes of [{ RELEASE_READ_TRANSPORT: "transaction-pooler" }, { RELEASE_READ_TRANSPORT: "" },
      { APP_ENVIRONMENT: "staging", GITHUB_REF: "refs/heads/staging", SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" },
      { GITHUB_REPOSITORY: "other/platform" }, { GITHUB_REF: "refs/heads/main" }, { GITHUB_EVENT_NAME: "pull_request" },
      { GITHUB_SHA: "invalid" }, { APP_REVISION: "b".repeat(40) }, { SUPABASE_ACCESS_TOKEN: "" }, { SUPABASE_DB_PASSWORD: "" }]) {
      const f = fixture(); await expect(f.run({ ...env, ...changes })).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_ENVIRONMENT_BOUNDARY$/);
      expect(f.request).not.toHaveBeenCalled(); expect(f.spawnProcess).not.toHaveBeenCalled();
      expect(sessionReadQuery).not.toHaveBeenCalled();
    }
  });
  it("validates a single fixed metadata GET and rejects foreign ID, region or database host before CLI", async () => {
    for (const metadata of [{ ...project, id: "nocteiuvohesvqbowchw" }, { ...project, region: "unknown" },
      { ...project, database: { host: "aws-1-eu-west-2.pooler.supabase.com" } },
      { ...project, database: { host: `${project.database.host}.private.invalid` } }]) {
      const f = fixture({ metadata }); await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_METADATA_BOUNDARY$/);
      expect(f.request).toHaveBeenCalledOnce(); expect(f.spawnProcess).not.toHaveBeenCalled();
      expect(sessionReadQuery).not.toHaveBeenCalled();
    }
  });
  it.each([502, 503, 544])("never retries metadata HTTP %s or starts the CLI", async status => {
    const f = fixture({ status }); await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_METADATA_HTTP_FAILED$/);
    expect(f.request).toHaveBeenCalledOnce(); expect(f.spawnProcess).not.toHaveBeenCalled(); expect(sessionReadQuery).not.toHaveBeenCalled();
  });
  it("redacts network errors and never follows a metadata redirect", async () => {
    const f = fixture({ requestError: new Error(env.SUPABASE_ACCESS_TOKEN) });
    await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_METADATA_REQUEST_FAILED$/);
    expect(f.request.mock.calls[0]).toMatchObject([`https://api.supabase.com/v1/projects/${ref}`, {
      method: "GET", redirect: "error", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` }, signal: expect.any(AbortSignal),
    }]);
    expect(f.spawnProcess).not.toHaveBeenCalled(); expect(observedOutput()).not.toContain(env.SUPABASE_ACCESS_TOKEN);
  });
  it("uses exact direct host, full TLS and private CA, preserving limits while overriding all ambient PG routing", async () => {
    const f = fixture();
    // Inspect the actual command; credentials are restricted to the child environment.
    f.spawnProcess.mockImplementationOnce((command, args, options) => {
      expect(command).toBe("pnpm");
      const url = new URL(args[5]); const ca = url.searchParams.get("sslrootcert")!;
      expect(url.protocol).toBe("postgresql:"); expect(url.hostname).toBe(project.database.host); expect(url.port).toBe("5432");
      expect(url.username).toBe("postgres"); expect(url.password).toBe(""); expect(url.pathname).toBe("/postgres");
      expect(url.searchParams.get("sslmode")).toBe("verify-full"); expect([...url.searchParams.keys()].sort()).toEqual(["sslmode", "sslrootcert"]);
      expect(args).toEqual(["exec", "supabase", "db", "push", "--db-url", url.href, "--include-all", "--yes"]);
      expect(args.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD); expect(args.join(" ")).not.toContain(env.SUPABASE_ACCESS_TOKEN);
      expect(args.join(" ")).not.toContain("--linked"); expect(args.join(" ")).not.toContain("link "); expect(args.join(" ")).not.toContain("repair");
      expect(statSync(ca).mode & 0o777).toBe(0o600); expect(statSync(new URL(".", `file://${ca}`)).mode & 0o777).toBe(0o700);
      expect(readFileSync(ca, "utf8")).toBe(publicReleaseCaBundle());
      expect(options).toMatchObject({ detached: true, stdio: ["ignore", "pipe", "pipe"], env: {
        PGHOST: project.database.host, PGPORT: "5432", PGDATABASE: "postgres", PGUSER: "postgres", PGPASSWORD: env.SUPABASE_DB_PASSWORD,
        PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full", PGSSLROOTCERT: ca, PGGSSENCMODE: "disable", PGOPTIONS: "-c lock_timeout=5000 -c statement_timeout=300000",
        SUPABASE_ACCESS_TOKEN: env.SUPABASE_ACCESS_TOKEN, NODE_TLS_REJECT_UNAUTHORIZED: "1",
      } });
      for (const key of ["PGSERVICE", "PGSERVICEFILE", "PGPASSFILE", "PGHOSTADDR", "PGSSLCERT", "PGSSLKEY", "PGSSLPASSWORD"])
        expect(options.env).not.toHaveProperty(key);
      for (const key of ["DATABASE_URL", "SUPABASE_DB_URL", "SSL_CERT_FILE", "SSL_CERT_DIR", "SUPABASE_CLI_BINARY_OVERRIDE", "PGTARGETSESSIONATTRS", "PGSSLSNI"])
        expect(options.env).not.toHaveProperty(key);
      queueMicrotask(() => { f.child.stdout.emit("data", Buffer.from(`Applying migration ${migrationName}\n`)); f.child.emit("close", 0, null); });
      return f.child;
    });
    const result = await f.run({ ...env, PGHOST: "wrong", PGHOSTADDR: "127.0.0.1", PGPORT: "6543", PGUSER: "supabase_admin",
      PGSERVICE: "wrong", PGSERVICEFILE: "/wrong", PGPASSFILE: "/wrong", PGSSLCERT: "/wrong", PGSSLKEY: "/wrong", PGSSLPASSWORD: "wrong",
      PGGSSENCMODE: "require", PGTARGETSESSIONATTRS: "read-write", PGSSLSNI: "0", PGSSLMODE: "disable", PGOPTIONS: "-c statement_timeout=0",
      DATABASE_URL: "wrong", SUPABASE_DB_URL: "wrong", SSL_CERT_FILE: "/wrong", SSL_CERT_DIR: "/wrong", SUPABASE_CLI_BINARY_OVERRIDE: "/wrong",
      NODE_TLS_REJECT_UNAUTHORIZED: "0" });
    expect(result).toEqual({ status: "SUCCESS", sqlStates: [], migrations: [migrationName], activationReport: "COMPLETED", activationReportRows: 1 });
    expect(sessionReadQuery).toHaveBeenCalledExactlyOnceWith(report, expect.objectContaining(env), f.request);
    expect(f.request).toHaveBeenCalledOnce(); expect(f.spawnProcess).toHaveBeenCalledOnce();
    const ca = new URL(f.spawnProcess.mock.calls[0][1][5]).searchParams.get("sslrootcert")!; expect(existsSync(ca)).toBe(false);
    expect(observedOutput()).not.toContain("never-print-report"); expect(observedOutput()).not.toContain(env.SUPABASE_DB_PASSWORD);
  });
  it("exposes only fixed failure class, SQLSTATE and repository migration filenames and never runs report after CLI failure", async () => {
    const privateOutput = `private SQL SELECT '${env.SUPABASE_DB_PASSWORD}' token=${env.SUPABASE_ACCESS_TOKEN}\n(SQLSTATE 57014)\n${migrationName}\n20990101010101_private.sql\n`;
    const f = fixture({ exit: 1, output: privateOutput }); await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_CLI_FAILED$/);
    expect(f.spawnProcess).toHaveBeenCalledOnce(); expect(sessionReadQuery).not.toHaveBeenCalled(); expect(existsSync(f.caFile())).toBe(false);
    expect(stderr).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ status: "CLI_FAILED", sqlStates: ["57014"], migrations: [migrationName] }));
    for (const privateValue of [env.SUPABASE_ACCESS_TOKEN, env.SUPABASE_DB_PASSWORD, "private SQL", "20990101010101_private.sql"])
      expect(observedOutput()).not.toContain(privateValue);
  });
  it.each(["apply", "dry-run"])("kills the %s CLI at the same five-minute client deadline without replay or report SQL", async mode => {
    vi.useFakeTimers(); const f = fixture({ pending: true });
    const killGroup = vi.spyOn(process, "kill").mockReturnValue(true); f.child.pid = 12345;
    try {
      const promise = mode === "dry-run" ? f.runDry() : f.run(); const failure = expect(promise).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_CLI_TIMEOUT$/);
      // Filesystem setup is real; let it finish before advancing the CLI deadline.
      await vi.waitFor(() => expect(f.spawnProcess).toHaveBeenCalledOnce());
      await vi.advanceTimersByTimeAsync(299_999 - (Date.now() - f.spawnedAt())); expect(f.child.kill).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1); await failure;
      expect(killGroup).toHaveBeenCalledExactlyOnceWith(-12345, "SIGKILL");
      expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL"); expect(f.spawnProcess).toHaveBeenCalledOnce();
      expect(sessionReadQuery).not.toHaveBeenCalled(); expect(existsSync(f.caFile())).toBe(false);
    } finally { killGroup.mockRestore(); }
  });
  it("bounds private output, kills the child and never runs report after overflow", async () => {
    const f = fixture({ pending: true, output: "x".repeat(256 * 1024 + 1) });
    await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_CLI_OUTPUT_LIMIT$/);
    expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL"); expect(sessionReadQuery).not.toHaveBeenCalled();
    expect(observedOutput().length).toBeLessThan(200); expect(existsSync(f.caFile())).toBe(false);
  });
  it.each(["start", "event"])("redacts CLI %s errors and cleans CA without report SQL", async kind => {
    const error = new Error(`${env.SUPABASE_DB_PASSWORD} ${env.SUPABASE_ACCESS_TOKEN}`);
    const f = fixture(kind === "start" ? { startError: error } : { error });
    await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_CLI_START_FAILED$/);
    expect(f.spawnProcess).toHaveBeenCalledOnce(); expect(sessionReadQuery).not.toHaveBeenCalled(); expect(existsSync(f.caFile())).toBe(false);
    expect(observedOutput()).not.toContain(env.SUPABASE_DB_PASSWORD);
  });
  it("runs fresh exact report SQL only after successful CLI, propagates safe SQLSTATE and never replays", async () => {
    const f = fixture(); vi.mocked(sessionReadQuery).mockRejectedValue(new Error("RELEASE_READ_ORIGINAL_SQLSTATE_57014"));
    await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_FAILED_SQLSTATE_57014$/);
    expect(sessionReadQuery).toHaveBeenCalledExactlyOnceWith(report, env, f.request); expect(f.spawnProcess).toHaveBeenCalledOnce();
    expect(existsSync(f.caFile())).toBe(false); expect(stdout).not.toHaveBeenCalled();
  });
  it.each([env.SUPABASE_DB_PASSWORD, "PRODUCTION_DIRECT_MIGRATION_PRIVATE_PASSWORD"])("redacts arbitrary report errors", async message => {
    const f = fixture(); vi.mocked(sessionReadQuery).mockRejectedValue(new Error(message));
    await expect(f.run()).rejects.toThrow(/^PRODUCTION_DIRECT_MIGRATION_FAILED$/);
    expect(f.spawnProcess).toHaveBeenCalledOnce(); expect(sessionReadQuery).toHaveBeenCalledOnce();
    expect(observedOutput()).not.toContain(message); expect(existsSync(f.caFile())).toBe(false);
  });
});
