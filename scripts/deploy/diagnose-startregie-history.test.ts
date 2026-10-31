import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { CAPACITY_SQL, diagnosticError, observerSql, phaseSql, PHASE_BODIES, runHistoryDiagnosis, traceConnection } from "./diagnose-startregie-history.mjs";
import { hotfixProofQuery } from "./repair-portal-hotfix-history.mjs";
import { originalHistorySha256 } from "./startregie-history-components.mjs";

const ref = "dtubngvxfbupgvgfrjko";
const env = { HISTORY_DIAGNOSTICS_REQUESTED: "true", APP_ENVIRONMENT: "production", GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production", GITHUB_SHA: "a".repeat(40),
  SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: "PRIVATE_TOKEN", SUPABASE_DB_PASSWORD: "PRIVATE_PASSWORD" };
const directEnv = { ...env, HISTORY_CONNECTION_PATH: "direct-vps", RUNNER_NAME: "dg-sites-vps-01-duindorphalloweenprod-01",
  GITHUB_WORKSPACE: "/srv/sites/duindorphalloweenprod/actions-runner/_work/platform/platform" };
const project = { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co`, version: "17.6.1.167" } };
const pooler = { pool_mode: "transaction", db_host: "aws-1-eu-west-2.pooler.supabase.com", db_user: "postgres", db_name: "postgres", pool_size: 15, max_client_conn: "200", private: "PRIVATE_METADATA" };
const proof = { save_hash: "b173e2e2a2fe8341cb6e146e62be8b99", save_functions: {
  admin_manual_portal_save: { hash: "b173e2e2a2fe8341cb6e146e62be8b99", normalized_hash: "b173e2e2a2fe8341cb6e146e62be8b99" },
}, cleanup_hash: "ce66c8115d726e623cd6c638e5eef587", trigger_valid: true, contaminated_drafts: 0,
versions: ["20261027033940"], wrapper_versions: [] };
type Result = { rows: Record<string, unknown>[]; fields?: {name: string}[] };
const result = (row?: Record<string, unknown>): Result => ({ rows: row ? [row] : [] });
function fixture(options: { splitError?: { name: string; code?: string; message?: string }; connectFailure?: string; observerFailure?: boolean;
  emptyObserver?: boolean; nullServerTime?: boolean; nullBackendTime?: boolean; originalError?: Error; originalDelayMs?: number; capacityFailure?: boolean; capacityClientFailure?: boolean; capacitySize?: unknown; metadataStatus?: number } = {}) {
  const clients: FakeClient[] = [];
  const queries: { client: string; text: string; query_timeout: number }[] = [];
  let queryPhase = "", tick = 1_800_000_000_000;
  class FakeClient {
    pid: number; name: string; config: Record<string, unknown>;
    connect = vi.fn(async () => { if (options.connectFailure === this.name) throw Object.assign(new Error("PRIVATE_CONNECTION_ERROR"), { code: "ECONNREFUSED" }); });
    end = vi.fn(async () => {});
    constructor(config: Record<string, unknown>) { this.config = config; this.name = String(config.application_name); this.pid = clients.length + 101; clients.push(this); }
    on() { return this; }
    async query(input: {text: string; query_timeout: number}): Promise<Result | Result[]> {
      queries.push({ client: this.name, ...input });
      if (input.text === CAPACITY_SQL) {
        if (options.capacityClientFailure) throw new Error("Query read timeout PRIVATE");
        if (options.capacityFailure) throw Object.assign(new Error("PRIVATE_CAPACITY_ERROR"), { code: "42501" });
        return result({ diagnostic_capacity: { maxConnections: "60", reservedConnections: "3", superuserReservedConnections: "3", databaseConnectionLimit: -1, roleConnectionLimit: -1, databaseSizeBytes: options.capacitySize ?? "104857600", totalBackends: 8, activeBackends: 2, idleBackends: 3, idleInTransactionBackends: 1, clientBackends: 6, clientBackendsCurrentDatabase: 5, clientBackendsCurrentRole: 2, clientBackendsActive: 2, clientBackendsIdle: 3, clientBackendsIdleInTransaction: 1, walSenderBackends: 1, otherBackendProcesses: 1, private: "PRIVATE_CAPACITY" } });
      }
      if (input.text.startsWith("select pg_stat_clear_snapshot()")) {
        if (options.observerFailure) throw new Error("PRIVATE_OBSERVER_ERROR");
        const original = /from activity where (?:false|pid=\d+)\s+or\b/.test(input.text);
        return result({ diagnostic_observation: { observedAtMs: ++tick, targets: options.emptyObserver ? [] : [{ pid: original ? 103 : 101, state: "idle in transaction", wait_event_type: "Client", wait_event: "ClientRead", blocking_pids: [], query_started_at_ms: tick - 1, original_query_matches: original }], otherActive: [{ class: "startregie_snapshot", backends: 2, max_active_age_ms: 100 }] } });
      }
      if (input.text.startsWith("begin ") && input.text.includes("as diagnostic_pid")) return result({ diagnostic_pid: this.pid, diagnostic_owner: true, diagnostic_read_only: "on", diagnostic_jit: "off", diagnostic_timeout: this.pid === 101 ? "5s" : "2s", diagnostic_lock: this.pid === 101 ? "500ms" : "200ms", diagnostic_backend_at: options.nullBackendTime ? null : ++tick });
      if (input.text.startsWith("savepoint history_diagnosis_phase")) {
        queryPhase = Object.keys(PHASE_BODIES).find(name => input.text.includes(PHASE_BODIES[name])) ?? "";
        if (queryPhase === options.splitError?.name) throw Object.assign(new Error(options.splitError.message ?? "PRIVATE_SQL_ERROR"), options.splitError.code ? { code: options.splitError.code } : {});
        const data = queryPhase === "function_hashes" ? { save_hash: proof.save_hash, save_functions: proof.save_functions, cleanup_hash: proof.cleanup_hash }
          : queryPhase === "trigger_definition" ? { trigger_valid: proof.trigger_valid }
          : queryPhase === "draft_metadata" ? { contaminated_drafts: 0 } : { versions: proof.versions, wrapper_versions: proof.wrapper_versions };
        return [result(), result({ diagnostic_server_start: options.nullServerTime ? null : ++tick, diagnostic_reader_pid: 101, diagnostic_read_only: "on", diagnostic_jit: "off", diagnostic_timeout: "5s", diagnostic_lock: "500ms" }), result(data), result({ diagnostic_server_end: ++tick }), result()];
      }
      if (input.text.startsWith("select current_setting('default_transaction_read_only')")) return result({ read_only: "on", statement_timeout: "1min", lock_timeout: "3s", jit: "off", diagnostic_pid: this.pid });
      if (input.text === hotfixProofQuery) {
        if (options.originalDelayMs) await new Promise(resolve => setTimeout(resolve, options.originalDelayMs));
        if (options.originalError) throw options.originalError;
        return result(proof);
      }
      return result();
    }
  }
  const request = vi.fn<typeof fetch>(async input => options.metadataStatus ? new Response("PRIVATE_PROVIDER_BODY", { status: options.metadataStatus }) : Response.json(String(input).endsWith("/pooler") ? [pooler] : project));
  return { request, Client: FakeClient, clients, queries };
}

describe("focused native history diagnosis", () => {
  it("binds exact fixed component bodies and preserves the original full query byte hash", () => {
    expect(Object.keys(PHASE_BODIES)).toEqual(["function_hashes", "trigger_definition", "draft_metadata", "migration_history"]);
    expect(createHash("sha256").update(hotfixProofQuery).digest("hex")).toBe(originalHistorySha256);
    for (const name of Object.keys(PHASE_BODIES)) expect(phaseSql(name)).toContain(`\n${PHASE_BODIES[name]}\n;`);
    expect(() => phaseSql("combined_original")).toThrow("UNKNOWN_PHASE");
    expect(() => observerSql(-1)).toThrow("INVALID_READER_PID");
    expect(observerSql(101)).toContain("pg_stat_clear_snapshot()");
    expect(observerSql(101)).not.toMatch(/jsonb_build_object\([^;]*(?:'query'|'address'|'email')/);
  });
  it("establishes two actual backend proofs, runs four components once and reproduces the unchanged old helper once", async () => {
    const f = fixture(); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("passed");
    expect(report.phases.map(phase => phase.name)).toEqual([...Object.keys(PHASE_BODIES), "combined_original"]);
    expect(report.checks).toEqual({ splitCanonical: true, combinedCanonical: true, combinedMatchesSplit: true });
    expect(f.clients).toHaveLength(3);
    expect(f.clients.every(client => client.config.connectionTimeoutMillis === 10_000)).toBe(true);
    expect(report.limits).toMatchObject({ configuredDriverConnectMs: 10000 });
    expect(report).toMatchObject({ connectionPath: "session-pooler", originalSessionPoolerReproduction: true });
    expect(f.clients.every(client => client.config.host === pooler.db_host && client.config.user === `postgres.${ref}` && client.config.port === 5432)).toBe(true);
    expect(f.clients.every(client => client.end.mock.calls.length === 1)).toBe(true);
    const firstComponent = f.queries.findIndex(query => query.text.startsWith("savepoint"));
    expect(f.queries.slice(0, firstComponent).filter(query => query.text.includes("as diagnostic_pid"))).toHaveLength(2);
    expect(f.queries.filter(query => query.text === hotfixProofQuery)).toHaveLength(1);
    expect(f.queries.find(query => query.text === hotfixProofQuery)?.query_timeout).toBe(70_000);
    expect(f.queries.filter(query => query.text.startsWith("savepoint"))).toHaveLength(4);
    expect(f.request).toHaveBeenCalledTimes(4);
    expect(report.capacity).toMatchObject({ maxConnections: 60, databaseConnectionLimit: -1 });
    expect(report.poolerLimits).toEqual([{ pool_size: 15, max_client_conn: 200 }]);
    for (const client of f.clients) expect(client.config.ssl).toMatchObject({ rejectUnauthorized: true });
    const printed = JSON.stringify(report);
    for (const value of ["PRIVATE", proof.save_hash, "save_definitions", env.SUPABASE_DB_PASSWORD, env.SUPABASE_ACCESS_TOKEN]) expect(printed).not.toContain(value);
    expect(report.phases.at(-1)).toMatchObject({ originalSqlInvocations: 1, proofBackendPid: 103, configuredStatementMs: 60000, configuredClientMs: 70000, connectionPath: "session-pooler", originalSessionPoolerReproduction: true, connectionOverrides: [] });
  });
  it("uses only the three explicit direct endpoint overrides for both split clients and the old-helper client", async () => {
    const pooled = fixture(), direct = fixture();
    const pooledReport = await runHistoryDiagnosis({ ...env, HISTORY_CONNECTION_PATH: "session-pooler" }, pooled.request, pooled.Client);
    const directReport = await runHistoryDiagnosis(directEnv, direct.request, direct.Client);
    expect(pooledReport.status).toBe("passed"); expect(directReport.status).toBe("passed");
    expect(directReport).toMatchObject({ connectionPath: "direct-vps", originalSessionPoolerReproduction: false });
    expect(directReport.phases.at(-1)).toMatchObject({ connectionPath: "direct-vps", originalSessionPoolerReproduction: false,
      connectionOverrides: ["host", "port", "user"], originalBodySha256: originalHistorySha256, originalSqlInvocations: 1,
      configuredStatementMs: 60000, configuredClientMs: 70000 });
    expect(direct.clients).toHaveLength(3);
    for (const [index, client] of direct.clients.entries()) {
      expect(client.config).toEqual({ ...pooled.clients[index].config, host: project.database.host, port: 5432, user: "postgres" });
      expect(client.config).toMatchObject({ connectionTimeoutMillis: 10000, ssl: { rejectUnauthorized: true } });
    }
    expect(direct.queries).toEqual(pooled.queries);
    expect(direct.request.mock.calls.map(call => call[0])).toEqual(pooled.request.mock.calls.map(call => call[0]));
    expect(direct.request).toHaveBeenCalledTimes(4);
  });
  it("rejects unknown paths and a direct path outside the dedicated VPS before any metadata or SQL", async () => {
    for (const changes of [{ HISTORY_CONNECTION_PATH: "direct" }, { HISTORY_CONNECTION_PATH: "" },
      { HISTORY_CONNECTION_PATH: "direct-vps", RUNNER_NAME: "other-runner" },
      { HISTORY_CONNECTION_PATH: "direct-vps", GITHUB_WORKSPACE: "/tmp/platform" }]) {
      const f = fixture(); const report = await runHistoryDiagnosis({ ...directEnv, ...changes }, f.request, f.Client);
      expect(report.status).toBe("failed"); expect(report.errorClass).toMatch(/INVALID_CONNECTION_PATH|DIRECT_VPS_BOUNDARY/);
      expect(f.request).not.toHaveBeenCalled(); expect(f.clients).toHaveLength(0); expect(f.queries).toHaveLength(0);
    }
  });
  it.each(["project", "pooler"])("keeps original %s metadata validation on the direct path", async kind => {
    const f = fixture(); const request = vi.fn<typeof fetch>(async url => Response.json(String(url).endsWith("/pooler")
      ? [{ ...pooler, ...(kind === "pooler" ? { db_host: "PRIVATE_UNTRUSTED_HOST" } : {}) }]
      : { ...project, ...(kind === "project" ? { database: { ...project.database, host: "PRIVATE_UNTRUSTED_HOST" } } : {}) }));
    const report = await runHistoryDiagnosis(directEnv, request, f.Client);
    expect(report.status).toBe("failed"); expect(report.errorClass).toBe("CLIENT_ERROR");
    expect(f.clients).toHaveLength(0); expect(JSON.stringify(report)).not.toContain("PRIVATE_UNTRUSTED_HOST");
  });
  it("separates client, WAL sender and background counts without inferring connection exhaustion", async () => {
    const f = fixture(); const report = await runHistoryDiagnosis(directEnv, f.request, f.Client);
    expect(report.capacityInterpretation).toBe("COUNTS_ONLY_NO_EXHAUSTION_INFERENCE");
    expect(report.capacity).toMatchObject({ databaseSizeBytes: 104857600, totalBackends: 8, clientBackends: 6,
      clientBackendsCurrentDatabase: 5, clientBackendsCurrentRole: 2, clientBackendsActive: 2, clientBackendsIdle: 3,
      clientBackendsIdleInTransaction: 1, walSenderBackends: 1, otherBackendProcesses: 1 });
    expect(f.queries.filter(query => query.text === CAPACITY_SQL)).toHaveLength(1);
    expect(CAPACITY_SQL.match(/pg_database_size\(current_database\(\)\)/g)).toHaveLength(1);
    expect(CAPACITY_SQL).toContain("'clientBackends',count(*) filter(where backend_type='client backend')");
    expect(CAPACITY_SQL).toContain("'walSenderBackends',count(*) filter(where backend_type='walsender')");
    expect(CAPACITY_SQL).toContain("backend_type is distinct from 'client backend' and backend_type is distinct from 'walsender'");
    expect(JSON.stringify(report)).not.toContain("PRIVATE_CAPACITY");
  });
  it.each(["PRIVATE_DATABASE_SIZE", "9007199254740992"])("does not expose malformed or unsafe capacity values: %s", async capacitySize => {
    const f = fixture({ capacitySize }); const report = await runHistoryDiagnosis(directEnv, f.request, f.Client);
    expect(report.capacity).toEqual({ unavailable: "HISTORY_DIAGNOSIS_CAPACITY_INVALID_RESULT" });
    expect(JSON.stringify(report)).not.toContain(capacitySize);
  });
  it.each(["57014", "55P03"])("recovers an aborted component with SQLSTATE %s without replaying it or attempting the fifth phase", async code => {
    const f = fixture({ splitError: { name: "trigger_definition", code } });
    const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("failed");
    expect(report.phases).toHaveLength(4);
    expect(report.phases[1]).toMatchObject({ errorClass: `SQLSTATE_${code}`, serverStopProven: true });
    expect(f.queries.filter(query => query.text.includes("rollback to savepoint"))).toHaveLength(1);
    expect(f.queries.filter(query => query.text === hotfixProofQuery)).toHaveLength(0);
    expect(f.queries.filter(query => query.text.startsWith("savepoint"))).toHaveLength(4);
  });
  it("stops later SQL and directly closes when a client failure does not prove server completion", async () => {
    const f = fixture({ splitError: { name: "function_hashes" } });
    const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.phases).toHaveLength(1);
    expect(report.phases[0]).toMatchObject({ serverStopProven: false });
    expect(f.queries.filter(query => query.client === f.clients[0].name && /rollback|reset all/.test(query.text))).toHaveLength(0);
    expect(f.clients[0].end).toHaveBeenCalledOnce();
  });
  it.each([
    ["canceling statement due to statement timeout", "STATEMENT_TIMEOUT"],
    ["canceling statement due to user request", "USER_CANCEL"],
    ["PRIVATE_UNKNOWN_CANCELLATION", "UNKNOWN"],
  ])("distinguishes cancellation reason without exposing its raw message: %s", async (message, expected) => {
    const f = fixture({ splitError: { name: "function_hashes", code: "57014", message } });
    const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.phases[0]).toMatchObject({ errorClass: "SQLSTATE_57014", cancelReason: expected });
    expect(JSON.stringify(report)).not.toContain(message);
  });
  it("reports independently failed observer connection before any component", async () => {
    const f = fixture({ connectFailure: "duindorp-release-history-observer" });
    const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.connections.observer).toMatchObject({ stage: "driver_connect", status: "failed", errorClass: "CONNECTION_FAILED" });
    expect(report.connections.reader).toMatchObject({ status: "ready", backendPid: 101 });
    expect(report.phases).toHaveLength(0);
  });
  it("never infers reachability from absent observer targets", async () => {
    const f = fixture({ emptyObserver: true });
    const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("passed");
    expect(report.phases.flatMap(phase => phase.samples).every(sample => sample.targetSeen === false && sample.inference === "NO_REACHABILITY_INFERENCE_FROM_ABSENCE")).toBe(true);
  });
  it("requires a real server timestamp for both initial backend proofs", async () => {
    const f = fixture({ nullBackendTime: true }); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("failed"); expect(report.phases).toHaveLength(0);
    expect(report.connections.reader).toMatchObject({ errorClass: "HISTORY_DIAGNOSIS_BACKEND_POLICY_NOT_PROVEN" });
    expect(report.connections.observer).toMatchObject({ errorClass: "HISTORY_DIAGNOSIS_BACKEND_POLICY_NOT_PROVEN" });
  });
  it("does not proceed after an observer failure or a null required server timestamp", async () => {
    for (const options of [{ observerFailure: true }, { nullServerTime: true }]) {
      const f = fixture(options); const report = await runHistoryDiagnosis(env, f.request, f.Client);
      expect(report.status).toBe("failed");
      expect(report.phases).toHaveLength(1);
      expect(report.phases[0].status === "failed" || !report.observerAvailable).toBe(true);
    }
  });
  it("keeps optional capacity failure separate and restores the observer transaction before mandatory reads", async () => {
    const f = fixture({ capacityFailure: true }); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("passed");
    expect(report.capacity).toEqual({ unavailable: "SQLSTATE_42501" });
    expect(f.queries.some(query => query.client.includes("observer") && query.text.startsWith("rollback;begin read only;"))).toBe(true);
  });
  it("never queues capacity rollback behind an uncertain observer timeout", async () => {
    const f = fixture({ capacityClientFailure: true }); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("failed"); expect(report.phases).toHaveLength(0);
    expect(f.queries.some(query => query.client.includes("observer") && query.text.startsWith("rollback;"))).toBe(false);
    expect(f.clients[1].end).toHaveBeenCalledOnce();
  });
  it.each([new Error("RELEASE_READ_SQLSTATE_57014"), new Error("RELEASE_READ_CLIENT_TIMEOUT")])("retains the exact sanitized old-helper failure and pending SQL step: %s", async error => {
    const f = fixture({ originalError: error }); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.status).toBe("failed");
    expect(report.phases.at(-1)).toMatchObject({ failureStep: "original_sql", originalSqlInvocations: 1 });
    expect(JSON.stringify(report)).toContain(error.message.includes("57014") ? "SQLSTATE_57014" : "CLIENT_TIMEOUT");
  });
  it("fails exact-context checks before any network and never retries metadata HTTP failures", async () => {
    for (const change of [{ HISTORY_DIAGNOSTICS_REQUESTED: "false" }, { GITHUB_REF: "refs/heads/staging" }, { GITHUB_EVENT_NAME: "push" }, { GITHUB_REPOSITORY: "other/repo" }]) {
      const f = fixture(); const report = await runHistoryDiagnosis({ ...env, ...change }, f.request, f.Client);
      expect(report.status).toBe("failed"); expect(f.request).not.toHaveBeenCalled();
    }
    const f = fixture({ metadataStatus: 502 }); const report = await runHistoryDiagnosis(env, f.request, f.Client);
    expect(report.errorClass).toContain("METADATA_HTTP_502"); expect(f.request).toHaveBeenCalledOnce(); expect(f.clients).toHaveLength(0);
    expect(diagnosticError(new Error("PRIVATE raw error"))).toBe("CLIENT_ERROR");
  });
  it("is a dedicated protected manual diagnosis workflow with no deployment or schema action", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/diagnose-startregie-history.yml", import.meta.url), "utf8");
    expect(workflow).toContain("workflow_dispatch:"); expect(workflow).not.toMatch(/^  push:/m);
    expect(workflow).toContain("github.ref == 'refs/heads/production'");
    expect(workflow).toContain("github.repository == 'duindorpdoet/platform'");
    expect(workflow).toContain("name: production"); expect(workflow).toContain("deployment: false");
    expect(workflow).toContain("default: session-pooler"); expect(workflow).toContain("type: choice");
    expect(workflow).toContain("inputs.connection_path == 'direct-vps'");
    expect(workflow).toContain('["self-hosted","Linux","X64","dg-sites","production","duindorphalloweenprod"]');
    expect(workflow).toContain("|| '[\"ubuntu-latest\"]'"); expect(workflow).toContain("clean: false");
    expect(workflow).toContain("HISTORY_CONNECTION_PATH: ${{ inputs.connection_path }}");
    for (const guard of ['test "$(id -un)" = "duindorphalloweenprod"', 'test "${RUNNER_NAME}" = "dg-sites-vps-01-duindorphalloweenprod-01"',
      '[[ "${GITHUB_WORKSPACE}" == /srv/sites/duindorphalloweenprod/actions-runner/_work/* ]]', 'test "$(git rev-parse HEAD)" = "${GITHUB_SHA}"']) expect(workflow).toContain(guard);
    expect(workflow.indexOf("Verify dedicated direct VPS runner boundary")).toBeLessThan(workflow.indexOf("Install pinned native driver"));
    expect(workflow).toContain("pnpm install --frozen-lockfile --ignore-scripts");
    expect(workflow).not.toMatch(/supabase (?:db push|migration|functions)|dg-site-deploy|restart/);
  });
  it("times a failed original-helper metadata GET before any reproduction client is created", async () => {
    const f = fixture();
    const request = vi.fn<typeof fetch>(async (url, options): Promise<Response> => request.mock.calls.length === 3
      ? new Response("PRIVATE_CONTROL_PLANE_ERROR", { status: 502 }) : f.request(url, options));
    const report = await runHistoryDiagnosis(env, request, f.Client);
    expect(report.status).toBe("failed"); expect(f.clients).toHaveLength(2);
    expect(report.phases.at(-1)).toMatchObject({ stage: "metadata_project", originalSqlInvocations: 0, errorClass: "RELEASE_READ_METADATA_HTTP_502" });
    expect(report.metadata).toEqual(expect.arrayContaining([expect.objectContaining({ kind: "project", stage: "combined_original", status: "HTTP_502", wallMs: expect.any(Number) })]));
    expect(JSON.stringify(report)).not.toContain("PRIVATE_CONTROL_PLANE_ERROR");
  });
  it("aborts pending original metadata at the total deadline and cannot construct or query a later backend", async () => {
    vi.useFakeTimers();
    try {
      const f = fixture();
      let release: (response: Response) => void = () => {};
      let started: () => void = () => {};
      const ready = new Promise<void>(resolve => { started = resolve; });
      let signal: AbortSignal | undefined;
      const request = vi.fn<typeof fetch>(async (url, options) => {
        if (request.mock.calls.length === 3) {
          signal = options?.signal ?? undefined;
          started();
          return new Promise<Response>(resolve => { release = resolve; });
        }
        return f.request(url, options);
      });
      const pending = runHistoryDiagnosis(env, request, f.Client);
      await ready;
      await vi.advanceTimersByTimeAsync(180_000);
      expect(signal?.aborted).toBe(true);
      const sent = f.queries.length;
      release(Response.json(project));
      const report = await pending;
      expect(report.status).toBe("failed"); expect(report.totalExpired).toBe(true);
      expect(f.clients).toHaveLength(2);
      expect(f.queries).toHaveLength(sent);
      expect(f.queries.some(query => query.text === hotfixProofQuery)).toBe(false);
    } finally { vi.useRealTimers(); }
  });
  it("observes a long original query throughout its wait without replaying it", async () => {
    vi.useFakeTimers();
    try {
      const f = fixture({ originalDelayMs: 11_000 });
      const pending = runHistoryDiagnosis(env, f.request, f.Client);
      await vi.advanceTimersByTimeAsync(11_000);
      const report = await pending;
      expect(report.status).toBe("passed");
      const phase = report.phases.at(-1)!;
      expect(phase.originalSqlInvocations).toBe(1);
      expect(phase.samples.length).toBeGreaterThanOrEqual(3);
      const times = phase.samples.map(sample => Date.parse(String(sample.wallObservedAt)));
      expect(Math.max(...times) - Math.min(...times)).toBeGreaterThanOrEqual(10_000);
      expect(f.queries.filter(query => query.text === hotfixProofQuery)).toHaveLength(1);
    } finally { vi.useRealTimers(); }
  });
});

describe("native connection lifecycle timing", () => {
  it("follows the SSL stream replacement without confusing socket creation, handshake or backend-key payloads", () => {
    const raw = new EventEmitter(), secure = Object.assign(new EventEmitter(), { authorized: true });
    const requestSsl = vi.fn(), startup = vi.fn();
    const connection = Object.assign(new EventEmitter(), { stream: raw, requestSsl, startup });
    const entry: Record<string, unknown> = {};
    traceConnection({ connection }, entry);
    raw.emit("lookup", null, "PRIVATE_IP_ADDRESS", 4, "PRIVATE_HOST");
    raw.emit("connect");
    connection.requestSsl("PRIVATE_SSL_ARGUMENT");
    connection.stream = secure;
    connection.emit("sslconnect");
    const events = () => entry.events as Array<{event: string;elapsedMs: number}>;
    expect(events().map(row => row.event)).toEqual(["DNS_LOOKUP_COMPLETED", "TCP_CONNECTED", "POSTGRES_SSL_REQUEST_QUEUED", "TLS_SOCKET_CREATED"]);
    secure.emit("secureConnect");
    connection.startup("PRIVATE_STARTUP_ARGUMENT");
    for (const name of ["authenticationSASL", "authenticationSASLContinue", "authenticationSASLFinal", "authenticationOk", "backendKeyData", "readyForQuery", "readyForQuery"]) connection.emit(name, { secretKey: "PRIVATE_CANCEL_SECRET", data: "PRIVATE_SCRAM_DATA", processID: 777 });
    secure.emit("end"); secure.emit("close"); raw.emit("close"); connection.emit("end");
    expect(events().map(row => row.event)).toEqual(["DNS_LOOKUP_COMPLETED", "TCP_CONNECTED", "POSTGRES_SSL_REQUEST_QUEUED", "TLS_SOCKET_CREATED", "TLS_ESTABLISHED_VERIFIED", "POSTGRES_STARTUP_QUEUED", "AUTH_SASL_CHALLENGE", "AUTH_SASL_CONTINUE", "AUTH_SASL_FINAL_RECEIVED", "AUTH_OK_RECEIVED", "BACKEND_KEY_RECEIVED", "READY_FOR_QUERY", "TLS_STREAM_END", "TLS_STREAM_CLOSE", "TCP_STREAM_CLOSE", "CONNECTION_END"]);
    expect(events().every(row => Number.isFinite(row.elapsedMs) && row.elapsedMs >= 0)).toBe(true);
    expect(requestSsl).toHaveBeenCalledExactlyOnceWith("PRIVATE_SSL_ARGUMENT");
    expect(startup).toHaveBeenCalledExactlyOnceWith("PRIVATE_STARTUP_ARGUMENT");
    expect(JSON.stringify(entry)).not.toContain("PRIVATE");
    expect(JSON.stringify(entry)).not.toContain("777");
  });
  it("records only fixed connection error codes and never claims unverified TLS as verified", () => {
    const raw = new EventEmitter(), secure = Object.assign(new EventEmitter(), { authorized: false });
    const connection = Object.assign(new EventEmitter(), { stream: raw });
    const entry: Record<string, unknown> = {};
    traceConnection({ connection }, entry);
    raw.emit("lookup", Object.assign(new Error("PRIVATE_DNS_ERROR"), { code: "ENOTFOUND" }), "PRIVATE_IP", 4, "PRIVATE_HOST");
    connection.stream = secure; connection.emit("sslconnect"); secure.emit("secureConnect");
    raw.emit("error", Object.assign(new Error("PRIVATE_RAW_ERROR"), { code: "PRIVATE_ARBITRARY_CODE" }));
    secure.emit("error", Object.assign(new Error("PRIVATE_TLS_ERROR"), { code: "SELF_SIGNED_CERT_IN_CHAIN" }));
    connection.emit("error", Object.assign(new Error("PRIVATE_CONNECT_ERROR"), { code: "ENETUNREACH" }));
    connection.emit("errorMessage", Object.assign(new Error("PRIVATE_AUTH_ERROR"), { code: "28P01" }));
    expect(entry.events).toEqual(expect.arrayContaining([
      expect.objectContaining({ event: "DNS_LOOKUP_FAILED", errorCode: "ENOTFOUND" }),
      expect.objectContaining({ event: "TLS_ESTABLISHED_UNVERIFIED" }),
      expect.objectContaining({ event: "TCP_STREAM_ERROR", errorCode: "CLIENT_ERROR" }),
      expect.objectContaining({ event: "TLS_STREAM_ERROR", errorCode: "SELF_SIGNED_CERT_IN_CHAIN" }),
      expect.objectContaining({ event: "CONNECTION_ERROR", errorCode: "ENETUNREACH" }),
      expect.objectContaining({ event: "POSTGRES_ERROR", errorCode: "SQLSTATE_28P01" }),
    ]));
    expect(JSON.stringify(entry)).not.toMatch(/PRIVATE|TLS_ESTABLISHED_VERIFIED/);
  });
});
