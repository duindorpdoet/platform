import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "node:events";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { createHash } from "node:crypto";
import { connectError, runConnectOnlyDiagnostics } from "./production-connect-only.mjs";
import { runDiagnostics } from "./production-db-diagnostics.mjs";

const ref = "dtubngvxfbupgvgfrjko";
const env = { DIAGNOSTIC_NATIVE_CONNECT_ONLY: "true", GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/production",
  GITHUB_REPOSITORY: "duindorpdoet/platform", APP_ENVIRONMENT: "production", SUPABASE_PROJECT_REF: ref,
  GITHUB_SHA: "a".repeat(40), SUPABASE_ACCESS_TOKEN: "PRIVATE_TOKEN", SUPABASE_DB_PASSWORD: "PRIVATE_PASSWORD" };
const project = { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co`, version: "17.6.1.167" } };
const pooler = { pool_mode: "transaction", db_host: "aws-1-eu-west-2.pooler.supabase.com", db_user: "postgres", db_name: "postgres", db_port: 6543 };
type ProcessResult = { code: number | null; expired: boolean; stderr: string; unavailable?: boolean };
function fixture(options: { connectError?: Error; endError?: Error; endPending?: boolean; processError?: boolean; prepared?: ProcessResult; libpq?: ProcessResult } = {}) {
  const order: string[] = [], clients: Client[] = [], bundles: Array<{path: string;pem: string;mode: number;directoryMode: number}> = [];
  const query = vi.fn(() => { throw new Error("SQL_MUST_NEVER_BE_SENT"); });
  class Client {
    config: Record<string, unknown>;
    raw = Object.assign(new EventEmitter(), { writable: true, destroy: vi.fn() });
    secure = Object.assign(new EventEmitter(), { writable: true, authorized: true, destroy: vi.fn() });
    connection = Object.assign(new EventEmitter(), { stream: this.raw, requestSsl: vi.fn(), startup: vi.fn(), sendSCRAMClientFinalMessage: vi.fn() });
    query = query;
    on() { return this; }
    constructor(config: Record<string, unknown>) { this.config = config; clients.push(this); }
    connect = vi.fn(async () => {
      order.push("native.connect");
      this.raw.emit("lookup", null, "PRIVATE_IP", 4, "PRIVATE_HOST"); this.raw.emit("connect"); this.connection.requestSsl("PRIVATE_SSL");
      this.connection.stream = this.secure; this.connection.emit("sslconnect"); this.secure.emit("secureConnect"); this.connection.startup("PRIVATE_STARTUP");
      this.connection.emit("authenticationSASL", { data: "PRIVATE_SCRAM" }); this.connection.emit("authenticationSASLContinue", { data: "PRIVATE_NONCE_SALT" });
      this.connection.sendSCRAMClientFinalMessage("PRIVATE_FINAL");
      if (options.connectError) throw options.connectError;
      this.connection.emit("authenticationSASLFinal", { data: "PRIVATE_SERVER_FINAL" }); this.connection.emit("authenticationOk");
      this.connection.emit("backendKeyData", { processID: 987654, secretKey: "PRIVATE_CANCEL_KEY" });
      this.connection.emit("readyForQuery"); this.connection.emit("readyForQuery");
    });
    end = vi.fn(async () => {
      order.push("native.end");
      if (options.endError) throw options.endError;
      if (options.endPending) await new Promise(() => {});
      this.secure.emit("end"); this.secure.emit("close");
    });
  }
  const execute = vi.fn(async (args: string[], environment: Record<string, string | undefined>, timeoutMs: number): Promise<ProcessResult> => {
    void environment; void timeoutMs;
    if (args[0] === "pull") { order.push("pull"); return options.prepared ?? { code: 0, expired: false, stderr: "PRIVATE_PULL_STDERR" }; }
    if (args[0] === "rm") { order.push("docker.cleanup"); return { code: 0, expired: false, stderr: "PRIVATE_CLEANUP" }; }
    order.push("psql");
    const path = args.find(value => value.startsWith("type=bind,src="))!.split("src=")[1].split(",dst=")[0];
    bundles.push({ path, pem: readFileSync(path, "utf8"), mode: statSync(path).mode & 0o777, directoryMode: statSync(dirname(path)).mode & 0o777 });
    if (options.processError) throw new Error("PRIVATE_PROCESS_ERROR");
    return options.libpq ?? { code: 0, expired: false, stderr: "PRIVATE_PSQL_STDERR" };
  });
  return { Client, execute, order, clients, query, bundles };
}

describe("manual native and libpq connections without SQL", () => {
  it("prepares once, opens and closes each client once, sends no SQL and verifies both TLS configurations", async () => {
    const f = fixture();
    const report = await runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute);
    expect(report).toMatchObject({ diagnostic: "production-connect-only", sqlSent: false, changedRows: 0, messagesSent: 0, connectionLimitMs: 30000,
      comparison: "INDEPENDENT_CLIENTS_NO_CAUSAL_INFERENCE", probes: [{ driver: "@supabase/pg8.21.1", connected: true }, { driver: "libpq/psql", connected: true }] });
    expect(f.order).toEqual(["pull", "native.connect", "native.end", "psql"]);
    expect(f.clients).toHaveLength(1); expect(f.clients[0].connect).toHaveBeenCalledOnce(); expect(f.clients[0].end).toHaveBeenCalledOnce(); expect(f.query).not.toHaveBeenCalled();
    expect(f.clients[0].config).toMatchObject({ host: pooler.db_host, port: 5432, database: "postgres", user: `postgres.${ref}`,
      password: env.SUPABASE_DB_PASSWORD, connectionTimeoutMillis: 30000, application_name: "duindorp-release-readonly", ssl: { rejectUnauthorized: true } });
    expect((f.clients[0].config.ssl as {ca: string[]}).ca).toContain(readFileSync(new URL("./supabase-root-2021.crt", import.meta.url), "utf8"));
    expect(f.bundles[0]).toMatchObject({ pem: (f.clients[0].config.ssl as {ca: string[]}).ca.join("\n"), mode: 0o600, directoryMode: 0o700 });
    expect(existsSync(dirname(f.bundles[0].path))).toBe(false);
    expect(f.execute).toHaveBeenCalledTimes(2);
    expect(f.execute.mock.calls[0]).toEqual([["pull", "supabase/postgres:17.6.1.167"], {}, 120000]);
    const [args, environment, bound] = f.execute.mock.calls[1];
    expect(args.slice(-6)).toEqual(["supabase/postgres:17.6.1.167", "-X", "-qAt", "-w", "-c", "\\q"]);
    expect(args).toContain("--network"); expect(args).toContain("host");
    expect(args.some(value => value.includes("dst=/run/duindorp-supabase-ca.crt,readonly"))).toBe(true);
    expect(args).not.toContain("-i");
    expect(environment).toMatchObject({ PGHOST: pooler.db_host, PGPORT: "5432", PGPASSWORD: env.SUPABASE_DB_PASSWORD,
      PGUSER: `postgres.${ref}`, PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full", PGSSLROOTCERT: "/run/duindorp-supabase-ca.crt", PGAPPNAME: "duindorp-release-readonly" });
    expect(bound).toBe(30000);
    expect(environment.PGOPTIONS).toBeUndefined();
    expect(f.clients[0].config.options).toBeUndefined();
    expect(args.join(" ")).not.toMatch(/PRIVATE|\bselect\b|\bbegin\b|\brollback\b/i);
    const events = report.probes[0].events!;
    expect(events.map(row => row.event)).toEqual(["DNS_LOOKUP_COMPLETED", "TCP_CONNECTED", "POSTGRES_SSL_REQUEST_LOCAL_QUEUED", "TLS_SOCKET_CREATED",
      "TLS_ESTABLISHED_VERIFIED", "POSTGRES_STARTUP_LOCAL_QUEUED", "AUTH_SASL_CHALLENGE", "AUTH_SASL_CONTINUE", "SCRAM_CLIENT_FINAL_LOCAL_QUEUED",
      "AUTH_SASL_FINAL_RECEIVED", "AUTH_OK_RECEIVED", "BACKEND_KEY_RECEIVED", "READY_FOR_QUERY", "TLS_STREAM_END", "TLS_STREAM_CLOSE"]);
    expect(events.every(row => Number.isFinite(Date.parse(row.at)) && Number.isFinite(row.elapsedMs) && row.elapsedMs >= 0 && Object.keys(row).sort().join(",") === "at,elapsedMs,event")).toBe(true);
    expect(JSON.stringify(report)).not.toMatch(/PRIVATE|987654/);
  });
  it("requires the explicit flag and exact production metadata before either client is touched", async () => {
    for (const changes of [{ DIAGNOSTIC_NATIVE_CONNECT_ONLY: "false" }, { DIAGNOSTIC_NATIVE_CONNECT_ONLY: "" }, { GITHUB_REF: "refs/heads/staging" },
      { GITHUB_REPOSITORY: "other/platform" }, { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" }, { GITHUB_EVENT_NAME: "push" }, { SUPABASE_DB_PASSWORD: "" }]) {
      const f = fixture();
      await expect(runConnectOnlyDiagnostics({ ...env, ...changes }, project, [pooler], f.Client, f.execute)).rejects.toThrow(/EXPLICIT_FLAG_REQUIRED|PRODUCTION_BOUNDARY/);
      expect(f.execute).not.toHaveBeenCalled(); expect(f.clients).toHaveLength(0);
    }
    const f = fixture();
    await expect(runConnectOnlyDiagnostics(env, project, [{ ...pooler, db_host: "PRIVATE_UNTRUSTED" }], f.Client, f.execute)).rejects.toThrow("TRUSTED_SESSION_POOLER_REQUIRED");
    expect(f.execute).not.toHaveBeenCalled();
  });
  it.each([
    ["ECIRCUITBREAKER", "POOL_CIRCUIT_BREAKER"], ["EMAXCONNSESSION", "POOL_SESSION_CLIENT_LIMIT"], ["EMAXCONN", "POOL_CLIENT_LIMIT"],
    ["ECHECKOUTTIMEOUT", "POOL_CHECKOUT_TIMEOUT"], ["EAUTHQUERY", "POOL_AUTH_QUERY"], ["EAUTHSECRETS", "POOL_AUTH_SECRETS"],
    ["ENOTFOUND", "POOL_TENANT_OR_USER_NOT_FOUND"], ["EPOOLCHECKOUT", "POOL_CHECKOUT_FAILED"],
  ])("classifies only the exact official (%s) prefix and never its private suffix", async (prefix, errorClass) => {
    const message = `(${prefix}) PRIVATE_HOST PRIVATE_PASSWORD PRIVATE_NONCE`;
    const f = fixture({ connectError: Object.assign(new Error(message), { code: "XX000", detail: "PRIVATE_DETAIL", hint: "PRIVATE_HINT" }),
      libpq: { code: 2, expired: false, stderr: `psql: error: connection to server at "PRIVATE_HOST" (PRIVATE_IP), port 5432 failed: FATAL: XX000: ${message}\n` } });
    const report = await runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute);
    expect(report.probes).toEqual([expect.objectContaining({ connected: false, sqlState: "XX000", prefix, errorClass }), expect.objectContaining({ connected: false, sqlState: "XX000", prefix, errorClass })]);
    expect(f.clients[0].connect).toHaveBeenCalledOnce(); expect(f.clients[0].end).toHaveBeenCalledOnce(); expect(f.execute).toHaveBeenCalledTimes(2); expect(f.query).not.toHaveBeenCalled();
    expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
  it("does not promote embedded, unknown or DNS error codes into a Supavisor prefix", () => {
    for (const message of ["PRIVATE (ECIRCUITBREAKER) PRIVATE", "(EPRIVATE) PRIVATE", "ECIRCUITBREAKER PRIVATE"]) {
      expect(connectError(Object.assign(new Error(message), { code: "XX000" }))).toEqual({ sqlState: "XX000", errorClass: "SERVER_ERROR", prefix: null });
    }
    expect(connectError(Object.assign(new Error("PRIVATE_HOST"), { code: "ENOTFOUND" }))).toEqual({ sqlState: null, errorClass: "DNS", prefix: null });
    expect(connectError("PRIVATE stderr (EMAXCONNSESSION)", true)).toEqual({ sqlState: null, errorClass: "UNKNOWN", prefix: null });
    expect(connectError("psql: error: FATAL: PRIVATE server timeout", true)).toEqual({ sqlState: null, errorClass: "SERVER_ERROR", prefix: null });
  });
  it.each([
    ["Circuit breaker open: PRIVATE", "LEGACY_CIRCUIT_BREAKER", "POOL_CIRCUIT_BREAKER"],
    ["MaxClientsInSessionMode: max clients reached - in Session mode max clients are limited to pool_size", "LEGACY_SESSION_CLIENT_LIMIT", "POOL_SESSION_CLIENT_LIMIT"],
    ["Max client connections reached", "LEGACY_CLIENT_LIMIT", "POOL_CLIENT_LIMIT"],
    ["Unable to check out process from the pool due to timeout", "LEGACY_CHECKOUT_TIMEOUT", "POOL_CHECKOUT_TIMEOUT"],
    ["Tenant or user not found", "LEGACY_TENANT_OR_USER_NOT_FOUND", "POOL_TENANT_OR_USER_NOT_FOUND"],
    ["Authentication error, reason: PRIVATE", "LEGACY_AUTH", "POOL_AUTH_ERROR"],
    ["Address not in tenant allow_list: PRIVATE", "LEGACY_ADDRESS_DENIED", "POOL_ADDRESS_DENIED"],
    ["SSL connection is required", "LEGACY_TLS_REQUIRED", "POOL_TLS_REQUIRED"],
    ["DbHandler exited", "LEGACY_UPSTREAM_EXITED", "POOL_UPSTREAM_EXITED"],
  ])("retains only a fixed enum for the official legacy prefix (%#)", (message, prefix, errorClass) => {
    expect(connectError(Object.assign(new Error(message), { code: "XX000" }))).toEqual({ sqlState: "XX000", prefix, errorClass });
    expect(connectError(`psql: FATAL: ${message}`, true)).toEqual({ sqlState: null, prefix, errorClass });
    expect(JSON.stringify(connectError(`psql: FATAL: ${message}`, true))).not.toContain("PRIVATE");
  });
  it("does not retry connection, transport or cleanup failures and still independently runs libpq", async () => {
    const f = fixture({ connectError: new Error("connect timeout PRIVATE"), endError: Object.assign(new Error("PRIVATE_CLOSE"), { code: "ECONNRESET" }), processError: true });
    const report = await runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute);
    expect(report.probes[0]).toMatchObject({ connected: false, errorClass: "CLIENT_TIMEOUT", cleanupErrorClass: "CONNECTION_FAILED" });
    expect(report.probes[1]).toMatchObject({ connected: false, errorClass: "CLIENT_UNAVAILABLE" });
    expect(f.clients[0].secure.destroy).toHaveBeenCalledOnce(); expect(f.clients[0].end).toHaveBeenCalledOnce();
    expect(f.clients[0].connect).toHaveBeenCalledOnce(); expect(f.execute).toHaveBeenCalledTimes(3); expect(f.query).not.toHaveBeenCalled();
    expect(f.execute.mock.calls[2]).toEqual([["rm", "--force", f.execute.mock.calls[1][0][3]], {}, 5000]);
    expect(existsSync(dirname(f.bundles[0].path))).toBe(false);
    expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
  it("bounds native cleanup and libpq without queueing any SQL or replaying a probe", async () => {
    vi.useFakeTimers();
    try {
      const f = fixture({ endPending: true, libpq: { code: null, expired: true, stderr: "PRIVATE_TIMEOUT" } });
      const pending = runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute);
      await vi.advanceTimersByTimeAsync(3000);
      const report = await pending;
      expect(report.probes[0]).toMatchObject({ connected: true, cleanupErrorClass: "CLIENT_TIMEOUT" });
      expect(report.probes[1]).toMatchObject({ connected: false, errorClass: "CLIENT_TIMEOUT" });
      expect(f.clients[0].secure.destroy).toHaveBeenCalledOnce(); expect(f.query).not.toHaveBeenCalled(); expect(f.execute).toHaveBeenCalledTimes(3);
      expect(f.execute.mock.calls[2]).toEqual([["rm", "--force", f.execute.mock.calls[1][0][3]], {}, 5000]);
    } finally { vi.useRealTimers(); }
  });
  it("fails safely before connection attempts if preparing the pinned image fails", async () => {
    const f = fixture({ prepared: { code: 1, expired: false, stderr: "PRIVATE_REGISTRY" } });
    await expect(runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute)).rejects.toThrow(/^POOLER_CONNECT_ONLY_IMAGE_PREPARATION_FAILED$/);
    expect(f.execute).toHaveBeenCalledOnce(); expect(f.clients).toHaveLength(0);
  });
  it("enters connect-only mode only after the existing metadata boundaries, without executing the old activity SQL", async () => {
    const request = vi.fn<typeof fetch>(async input => Response.json(String(input).endsWith("/pooler") ? [pooler] : project));
    const execute = vi.fn();
    const f = fixture(); const report = await runConnectOnlyDiagnostics(env, project, [pooler], f.Client, f.execute);
    const connectOnly = vi.fn(async () => report);
    expect(await runDiagnostics(env, request, execute, connectOnly)).toBe(report);
    expect(connectOnly).toHaveBeenCalledExactlyOnceWith(env, project, [pooler]);
    expect(request.mock.calls.map(([, options]) => options?.method)).toEqual(["GET", "GET"]);
    expect(execute).not.toHaveBeenCalled();
    await expect(runDiagnostics({ ...env, GITHUB_REF: "refs/heads/main" }, request, execute, connectOnly)).rejects.toThrow("PRODUCTION_BOUNDARY");
    expect(connectOnly).toHaveBeenCalledOnce();
  });
  it("changes only the existing protected diagnostic job and retains the actual release helper byte-for-byte", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/deploy-production.yml", import.meta.url), "utf8");
    const job = (name: string) => workflow.split(`\n  ${name}:\n`)[1]?.split(/\n  [a-z][a-z-]+:\n/)[0] ?? "";
    const diagnostic = job("database-connection-diagnostics");
    expect(diagnostic).toContain('DIAGNOSTIC_NATIVE_CONNECT_ONLY: "true"');
    expect(diagnostic).toContain("pnpm install --frozen-lockfile");
    expect(diagnostic).toContain("name: production\n      deployment: false");
    expect(diagnostic).toContain("github.event_name == 'workflow_dispatch'");
    expect(readFileSync(new URL("./production-db-diagnostics.mjs", import.meta.url), "utf8")).toContain("/^POOLER_(?:DIAGNOSTICS|CONNECT_ONLY)_[A-Z0-9_]+$/");
    for (const name of ["backup-restore", "deploy", "database-connection-recovery", "readonly-baseline", "mail-worker-diagnostics"]) expect(job(name)).not.toContain("DIAGNOSTIC_NATIVE_CONNECT_ONLY");
    expect(createHash("sha256").update(readFileSync(new URL("./production-read-query.mjs", import.meta.url))).digest("hex"))
      .toBe("c5c26eb00908b5ae741006dfbb60afbecb39d281d3b13fe88b7736ae276d9c51");
  });
  it("opens only the explicitly authorized direct project endpoint and fetches only its project metadata", async () => {
    const directEnv = { ...env, DIAGNOSTIC_DIRECT_CAPABILITY: "true" };
    const f = fixture();
    const report = await runConnectOnlyDiagnostics(directEnv, project, undefined, f.Client, f.execute, "direct");
    expect(report.connectionPath).toBe("direct"); expect(report.probes.every(probe => probe.connected)).toBe(true);
    expect(f.clients[0].config).toMatchObject({ host: project.database.host, user: "postgres", port: 5432, database: "postgres", connectionTimeoutMillis: 30000, ssl: { rejectUnauthorized: true } });
    expect(f.execute.mock.calls[1][1]).toMatchObject({ PGHOST: project.database.host, PGUSER: "postgres", PGPORT: "5432", PGSSLMODE: "verify-full" });
    expect(f.query).not.toHaveBeenCalled(); expect(f.clients[0].connect).toHaveBeenCalledOnce(); expect(f.execute).toHaveBeenCalledTimes(2);
    const request = vi.fn<typeof fetch>(async () => Response.json(project)), execute = vi.fn(), probe = vi.fn(async () => report);
    expect(await runDiagnostics(directEnv, request, execute, probe)).toBe(report);
    expect(request).toHaveBeenCalledExactlyOnceWith(`https://api.supabase.com/v1/projects/${ref}`, expect.objectContaining({ method: "GET" }));
    expect(probe).toHaveBeenCalledExactlyOnceWith(directEnv, project, undefined, "direct"); expect(execute).not.toHaveBeenCalled();
  });
  it("rejects direct capability without explicit mode, trusted project metadata and connect-only authorization", async () => {
    for (const [changes, metadata, mode] of [
      [{}, project, "direct"], [{ DIAGNOSTIC_DIRECT_CAPABILITY: "true" }, project, "pooler"],
      [{ DIAGNOSTIC_DIRECT_CAPABILITY: "true" }, { ...project, database: { ...project.database, host: "PRIVATE_UNTRUSTED" } }, "direct"],
      [{ DIAGNOSTIC_DIRECT_CAPABILITY: "true" }, { ...project, id: "nocteiuvohesvqbowchw" }, "direct"],
    ] as const) {
      const f = fixture();
      await expect(runConnectOnlyDiagnostics({ ...env, ...changes }, metadata, [pooler], f.Client, f.execute, mode)).rejects.toThrow(/ENDPOINT_MODE_REQUIRED|PROJECT_METADATA_BOUNDARY/);
      expect(f.clients).toHaveLength(0); expect(f.execute).not.toHaveBeenCalled();
    }
    const request = vi.fn();
    await expect(runDiagnostics({ ...env, DIAGNOSTIC_DIRECT_CAPABILITY: "true", DIAGNOSTIC_NATIVE_CONNECT_ONLY: "false" }, request)).rejects.toThrow("EXPLICIT_CONNECT_ONLY_REQUIRED");
    expect(request).not.toHaveBeenCalled();
  });
  it("does not fall back to the pooler or replay either direct connection after failure", async () => {
    const f = fixture({ connectError: Object.assign(new Error("PRIVATE_DIRECT_FAILURE"), { code: "ECONNREFUSED" }), libpq: { code: 2, expired: false, stderr: "PRIVATE_FAILURE" } });
    const report = await runConnectOnlyDiagnostics({ ...env, DIAGNOSTIC_DIRECT_CAPABILITY: "true" }, project, undefined, f.Client, f.execute, "direct");
    expect(report.probes.every(probe => !probe.connected)).toBe(true);
    expect(f.clients).toHaveLength(1); expect(f.clients[0].config.host).toBe(project.database.host);
    expect(f.execute.mock.calls[1][1].PGHOST).toBe(project.database.host); expect(f.execute).toHaveBeenCalledTimes(2); expect(f.query).not.toHaveBeenCalled();
    expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
});
