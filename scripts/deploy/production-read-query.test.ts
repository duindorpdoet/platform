import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { enabledSessionReads, sessionReadQuery } from "./production-read-query.mjs";
import { AUDIT_QUERY, PREVIEW_AUDIT_QUERY, JOINT_PROPOSAL_INPUT_QUERY } from "./evening-readiness-audit.mjs";
import { hotfixProofQuery } from "./repair-portal-hotfix-history.mjs";
import { ACTOR_QUERY } from "./check-startregie-reads.mjs";
import { releaseMetadataQuery } from "./redesign-reconciliation.mjs";
import { preservationManagementRequest } from "./redesign-backup.mjs";

const ref = "dtubngvxfbupgvgfrjko";
const env = { RELEASE_READ_TRANSPORT: "session-pooler", GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/production", GITHUB_REPOSITORY: "duindorpdoet/platform", APP_ENVIRONMENT: "production",
  SUPABASE_PROJECT_REF: ref, GITHUB_SHA: "a".repeat(40), SUPABASE_ACCESS_TOKEN: "fixture-token", SUPABASE_DB_PASSWORD: "fixture-password" };
const project = { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co` } };
const pooler = { pool_mode: "transaction", db_port: 6543, db_host: "aws-1-eu-west-2.pooler.supabase.com", db_user: "postgres", db_name: "postgres" };
type Result = { command: string; fields: unknown[]; rows: Record<string, unknown>[] };
const result = (rows: Record<string, unknown>[] = [], command = "SELECT"): Result => ({ command, fields: command === "SELECT" ? [{}] : [], rows });
function fixture(options: { project?: unknown; poolers?: unknown; answer?: Result | Result[]; error?: Error; proof?: Record<string, unknown>;
  connectError?: Error; policyError?: Error; cleanupError?: Error; closeError?: Error } = {}) {
  const queries: { text: string; query_timeout: number }[] = [];
  let configuration: Record<string, unknown> = {};
  const end = vi.fn(async () => { if (options.closeError) throw options.closeError; });
  const connect = vi.fn(async () => { if (options.connectError) throw options.connectError; });
  class Client {
    constructor(config: Record<string, unknown>) { configuration = config; }
    on() { return this; }
    connect = connect;
    end = end;
    async query(input: { text: string; query_timeout: number }): Promise<Result | Result[]> {
      queries.push(input);
      if (input.text === "rollback;reset all") {
        if (options.cleanupError) throw options.cleanupError;
        return result([], "RESET");
      }
      if (queries.length <= 2 && options.policyError) throw options.policyError;
      if (input.text.startsWith("select current_setting")) return result([options.proof ?? { read_only: "on", statement_timeout: queries[1].text.includes("300000ms") ? "5min" : "1min", lock_timeout: "3s", jit: "off" }]);
      if (queries.length <= 2) return result([], "SET");
      if (options.error) throw options.error;
      return options.answer ?? result([{ connectivity: 1 }]);
    }
  }
  const request = vi.fn<typeof fetch>(async input => new Response(JSON.stringify(String(input).endsWith("/pooler") ? options.poolers ?? [pooler] : options.project ?? project)));
  return { request, Client, queries, end, connect, configuration: () => configuration };
}
function expectOriginalBody(batch: string, sql: string) {
  const begin = /^begin read only;/i.exec(sql)?.[0];
  expect(batch).toMatch(/^begin read only;set default_transaction_read_only=on;/);
  expect(batch).toContain("set local jit=off;");
  expect(batch).toContain("do $release_read_policy$begin");
  expect(batch.split("end $release_read_policy$;")[0]).not.toMatch(/select current_setting/);
  expect(batch.endsWith(begin ? sql.slice(begin.length) : `${sql}\n;commit;`)).toBe(true);
  expect(batch.match(/begin read only;/gi)).toHaveLength(1);
}

describe("explicit release session reads", () => {
  it("requires an explicit flag and exact release repository, project, environment, branch and revision", () => {
    expect(enabledSessionReads({})).toBe(false);
    expect(enabledSessionReads(env)).toBe(true);
    expect(enabledSessionReads({ ...env, APP_ENVIRONMENT: "staging", GITHUB_REF: "refs/heads/staging", SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw", GITHUB_EVENT_NAME: "push" })).toBe(true);
    for (const change of [{ GITHUB_REPOSITORY: "other/platform" }, { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" },
      { GITHUB_REF: "refs/heads/main" }, { APP_ENVIRONMENT: "development" }, { GITHUB_SHA: "bad" },
      { GITHUB_EVENT_NAME: "pull_request" }, { SUPABASE_DB_PASSWORD: "" }, { APP_REVISION: "b".repeat(40) }])
      expect(() => enabledSessionReads({ ...env, ...change })).toThrow("ENVIRONMENT_BOUNDARY");
    expect(enabledSessionReads({ ...env, APP_REVISION: env.GITHUB_SHA })).toBe(true);
  });
  it("sets and proves actual session read-only state before preserving original multi-statement SQL", async () => {
    const f = fixture({ answer: [result([], "BEGIN"), result([{ previous: true }]), result([]), result([], "COMMIT")] });
    const sql = "begin read only;select 1;select 2 where false;commit;";
    expect(await sessionReadQuery(sql, env, f.request, f.Client)).toEqual([{ previous: true }]);
    expect(f.queries.slice(0, 3).map(query => query.text)).toEqual([
      "set default_transaction_read_only=on",
      "set statement_timeout='60000ms';set lock_timeout='3s';set jit=off;set idle_in_transaction_session_timeout='70000ms'",
      "select current_setting('default_transaction_read_only') as read_only,current_setting('statement_timeout') as statement_timeout,current_setting('lock_timeout') as lock_timeout,current_setting('jit') as jit",
    ]);
    expectOriginalBody(f.queries[3].text, sql);
    expect(f.queries.at(-1)?.text).toBe("rollback;reset all");
    expect(f.queries.at(-2)?.query_timeout).toBe(70_000);
    expect(f.end).toHaveBeenCalledOnce();
    expect(f.request.mock.calls.map(([url, opts]) => [url, opts?.method])).toEqual([
      [`https://api.supabase.com/v1/projects/${ref}`, "GET"], [`https://api.supabase.com/v1/projects/${ref}/config/database/pooler`, "GET"],
    ]);
    expect(f.configuration()).toMatchObject({ host: pooler.db_host, port: 5432, user: `postgres.${ref}`, database: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: true } });
    const tls = f.configuration().ssl as { ca: string[] };
    expect(tls.ca).toContain(readFileSync(new URL("./supabase-root-2021.crt", import.meta.url), "utf8"));
    expect(f.queries.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD);
  });
  it("prefers session metadata, rejects foreign hosts, roles, databases and projects before connecting", async () => {
    const f = fixture({ poolers: [pooler, { ...pooler, pool_mode: "session", db_host: "aws-0-eu-west-2.pooler.supabase.com" }] });
    await sessionReadQuery("select 1", env, f.request, f.Client);
    expect(f.configuration().host).toBe("aws-0-eu-west-2.pooler.supabase.com");
    for (const change of [{ db_host: "aws-1-eu-west-2.pooler.supabase.com.evil.invalid" }, { db_host: "aws-1-eu-west-1.pooler.supabase.com" },
      { db_user: "supabase_admin" }, { db_user: "postgres.nocteiuvohesvqbowchw" }, { db_name: "other" }, { pool_mode: "other" }]) {
      const bad = fixture({ poolers: [{ ...pooler, ...change }] });
      await expect(sessionReadQuery("select 1", env, bad.request, bad.Client)).rejects.toThrow("TRUSTED_SESSION_POOLER_REQUIRED");
      expect(bad.connect).not.toHaveBeenCalled();
    }
    const bad = fixture({ project: { ...project, id: "nocteiuvohesvqbowchw" } });
    await expect(sessionReadQuery("select 1", env, bad.request, bad.Client)).rejects.toThrow("PROJECT_METADATA_BOUNDARY");
  });
  it("fails before network access for explicit attempts to remove read-only policy", async () => {
    for (const sql of ["begin read write;select 1", "set default_transaction_read_only=off;select 1", "set local transaction_read_only=off",
      "set /* gap */ session characteristics as transaction read write", 'set "default_transaction_read_only"=off',
      "select set_config('default_transaction_read_only','off',false)", "select set_config('default_'||'transaction_read_only','off',false)",
      "reset all;select 1", "discard all;select 1"]) {
      const f = fixture();
      await expect(sessionReadQuery(sql, env, f.request, f.Client)).rejects.toThrow("READ_ONLY_POLICY_REQUIRED");
      expect(f.request).not.toHaveBeenCalled();
    }
  });
  it("allows the existing fixed authentication and proposal context inside read-only owner wrappers", async () => {
    const f = fixture();
    const sql = "begin read only;do $proof$begin perform set_config('request.jwt.claims','{}',true);perform set_config('app.readiness_joint_input','{}',true);end $proof$;select 1;commit;";
    await sessionReadQuery(sql, env, f.request, f.Client);
    expectOriginalBody(f.queries.at(-2)?.text ?? "", sql);
  });
  it("preserves every actual fixed release inspection and owner preservation wrapper through the SQL guard", async () => {
    const catalog = [{ schema: "app_private", name: "events", columns: ["id", "settings"] }];
    for (const sql of [AUDIT_QUERY, PREVIEW_AUDIT_QUERY, JOINT_PROPOSAL_INPUT_QUERY, hotfixProofQuery, ACTOR_QUERY,
      releaseMetadataQuery(), preservationManagementRequest(catalog, { auditBoundary: "42" }).query]) {
      const f = fixture();
      await sessionReadQuery(sql, env, f.request, f.Client);
      const batch = f.queries.at(-2)?.text ?? "";
      expectOriginalBody(batch, sql);
      if (sql === PREVIEW_AUDIT_QUERY || sql === JOINT_PROPOSAL_INPUT_QUERY) {
        expect(batch.indexOf("set local statement_timeout='15000ms'")).toBeGreaterThan(batch.indexOf("set local statement_timeout='60000ms'"));
        expect(batch.indexOf("set local lock_timeout='500ms'")).toBeGreaterThan(batch.indexOf("set local lock_timeout='3s'"));
      }
      expect(f.end).toHaveBeenCalledOnce();
    }
  });
  it("preserves the existing administrative five-minute bound only for its exact owner wrapper", async () => {
    const sql = "begin read only;set local statement_timeout='5min';set local lock_timeout='3s';do $preservation_read_only$begin if current_setting('transaction_read_only')<>'on' then raise exception 'PRESERVATION_READ_ONLY_REQUIRED';end if;end $preservation_read_only$;select 1;commit;";
    const f = fixture();
    await sessionReadQuery(sql, env, f.request, f.Client);
    expect(f.queries[1].text).toContain("statement_timeout='300000ms'");
    expect(f.queries.at(-2)?.query_timeout).toBe(310_000);
  });
  it("aborts on an unproven policy and closes directly on errors without leaking query, credentials or row data", async () => {
    const bad = fixture({ proof: { read_only: "off", statement_timeout: "1min", lock_timeout: "3s", jit: "off" } });
    await expect(sessionReadQuery("select 'private-query'", env, bad.request, bad.Client)).rejects.toThrow("POLICY_NOT_CONFIRMED");
    expect(bad.queries).toHaveLength(4);
    expect(bad.end).toHaveBeenCalledOnce();
    for (const error of [Object.assign(new Error("private-query fixture-password fixture-row"), { code: "25006" }), new Error("Query read timeout private-query")]) {
      const f = fixture({ error });
      await expect(sessionReadQuery("select 'private-query'", env, f.request, f.Client)).rejects.toThrow(/^RELEASE_READ_ORIGINAL_(SQLSTATE_25006|CLIENT_TIMEOUT)$/);
      expect(f.end).toHaveBeenCalledOnce();
      expect(f.queries).toHaveLength(error.message.includes("timeout") ? 4 : 5);
      expect(f.queries.some(query => /^rollback/i.test(query.text))).toBe(!error.message.includes("timeout"));
    }
  });
  it("sanitizes bounded metadata network failures and never connects on invalid context", async () => {
    vi.useFakeTimers();
    const request = vi.fn<typeof fetch>(async () => { throw new Error("private-token provider-body"); });
    try {
      const rejection = expect(sessionReadQuery("select 1", env, request)).rejects.toThrow(/^RELEASE_READ_METADATA_REQUEST_FAILED$/);
      await vi.runAllTimersAsync();
      await rejection;
      expect(request).toHaveBeenCalledTimes(3);
      request.mockClear();
      await expect(sessionReadQuery("select 1", { ...env, RELEASE_READ_TRANSPORT: "" }, request)).rejects.toThrow("TRANSPORT_NOT_ENABLED");
      expect(request).not.toHaveBeenCalled();
    } finally { vi.useRealTimers(); }
  });
  it("retries only fixed metadata GETs with 250/500ms backoff, then executes the original SQL once", async () => {
    vi.useFakeTimers();
    try {
      const f = fixture();
      const attempts = new Map<string, number>();
      const request = vi.fn<typeof fetch>(async (url, options) => {
        const key = String(url), attempt = (attempts.get(key) ?? 0) + 1;
        attempts.set(key, attempt);
        if (attempt === 1) return new Response("private-provider-body", { status: 502 });
        if (attempt === 2 && key.endsWith("/pooler")) return new Response("private-provider-body", { status: 503 });
        return f.request(url, options);
      });
      const sql = "select 'original-release-inspection'";
      const pending = sessionReadQuery(sql, env, request, f.Client);
      await vi.advanceTimersByTimeAsync(0);
      expect(request).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(249);
      expect(request).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(request).toHaveBeenCalledTimes(3);
      await vi.advanceTimersByTimeAsync(250);
      expect(request).toHaveBeenCalledTimes(4);
      await vi.advanceTimersByTimeAsync(499);
      expect(request).toHaveBeenCalledTimes(4);
      await vi.advanceTimersByTimeAsync(1);
      expect(await pending).toEqual([{ connectivity: 1 }]);
      expect(request).toHaveBeenCalledTimes(5);
      expect(f.connect).toHaveBeenCalledOnce();
      expect(f.queries.filter(query => query.text.includes(sql))).toHaveLength(1);
      for (const [url, options] of request.mock.calls) {
        expect(options?.method).toBe("GET");
        expect([`https://api.supabase.com/v1/projects/${ref}`, `https://api.supabase.com/v1/projects/${ref}/config/database/pooler`]).toContain(String(url));
      }
    } finally { vi.useRealTimers(); }
  });
  it.each([502, 503, 504, 544])("bounds repeated metadata HTTP %i failures without connecting or exposing the body", async status => {
    vi.useFakeTimers();
    try {
      const f = fixture();
      const request = vi.fn<typeof fetch>(async () => new Response("private-token private-query private-row", { status }));
      const rejection = expect(sessionReadQuery("select 1", env, request, f.Client)).rejects.toThrow(new RegExp(`^RELEASE_READ_METADATA_HTTP_${status}$`));
      await vi.runAllTimersAsync();
      await rejection;
      expect(request).toHaveBeenCalledTimes(3);
      expect(f.connect).not.toHaveBeenCalled();
      expect(f.queries).toHaveLength(0);
    } finally { vi.useRealTimers(); }
  });
  it.each([400, 401, 403, 404, 429, 500])("never retries non-allowlisted metadata HTTP %i", async status => {
    const f = fixture();
    const request = vi.fn<typeof fetch>(async () => new Response("private-token provider-body", { status }));
    await expect(sessionReadQuery("select 1", env, request, f.Client)).rejects.toThrow(new RegExp(`^RELEASE_READ_METADATA_HTTP_${status}$`));
    expect(request).toHaveBeenCalledOnce();
    expect(f.connect).not.toHaveBeenCalled();
  });
  it("recovers from a transient metadata network failure without replaying SQL", async () => {
    vi.useFakeTimers();
    try {
      const f = fixture();
      const request = vi.fn<typeof fetch>().mockRejectedValueOnce(new TypeError("private-network-error"))
        .mockImplementation(f.request);
      const sql = "select 'single-native-execution'";
      const pending = sessionReadQuery(sql, env, request, f.Client);
      await vi.runAllTimersAsync();
      await pending;
      expect(request).toHaveBeenCalledTimes(3);
      expect(f.connect).toHaveBeenCalledOnce();
      expect(f.queries.filter(query => query.text.includes(sql))).toHaveLength(1);
    } finally { vi.useRealTimers(); }
  });
  it("does not retry invalid metadata JSON or any native SQL error", async () => {
    const f = fixture();
    const request = vi.fn<typeof fetch>(async () => new Response("private-invalid-json"));
    await expect(sessionReadQuery("select 1", env, request, f.Client)).rejects.toThrow(/^RELEASE_READ_METADATA_INVALID_JSON$/);
    expect(request).toHaveBeenCalledOnce();
    const broken = fixture({ error: Object.assign(new Error("private-sql-body"), { code: "57014" }) });
    const sql = "select 'single-failing-native-execution'";
    await expect(sessionReadQuery(sql, env, broken.request, broken.Client)).rejects.toThrow(/^RELEASE_READ_ORIGINAL_SQLSTATE_57014$/);
    expect(broken.request).toHaveBeenCalledTimes(2);
    expect(broken.connect).toHaveBeenCalledOnce();
    expect(broken.queries.filter(query => query.text.includes(sql))).toHaveLength(1);
  });
  it("never substitutes policy assertion rows for an empty original result", async () => {
    const f = fixture({ answer: [result([], "BEGIN"), result([], "SET"), result([], "DO"), result([]), result([], "COMMIT")] });
    expect(await sessionReadQuery("select 1 where false", env, f.request, f.Client)).toEqual([]);
  });
  it("labels connection, session policy and in-batch policy failures without private errors", async () => {
    for (const [options, expected] of [
      [{ connectError: new Error("private-client timeout") }, "RELEASE_READ_CONNECT_CLIENT_TIMEOUT"],
      [{ policyError: Object.assign(new Error("private-policy"), { code: "42501" }) }, "RELEASE_READ_POLICY_SQLSTATE_42501"],
      [{ error: Object.assign(new Error("RELEASE_READ_POLICY_REQUIRED"), { code: "P0001" }) }, "RELEASE_READ_POLICY_SQLSTATE_P0001"],
    ] as const) {
      const f = fixture(options);
      await expect(sessionReadQuery("select 1", env, f.request, f.Client)).rejects.toThrow(expected);
      expect(f.end).toHaveBeenCalledOnce();
    }
  });
  it("reports cleanup failure classes while preserving the result and always closing", async () => {
    const report = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const f = fixture({ cleanupError: Object.assign(new Error("private-query fixture-password private-row"), { code: "42501" }),
        closeError: new Error("private-TLS-certificate fixture-password") });
      expect(await sessionReadQuery("select 1", env, f.request, f.Client)).toEqual([{ connectivity: 1 }]);
      expect(f.end).toHaveBeenCalledOnce();
      expect(report.mock.calls).toEqual([["RELEASE_READ_CLEANUP_SQLSTATE_42501"], ["RELEASE_READ_CLEANUP_CLOSE_TLS"]]);
    } finally { report.mockRestore(); }
  });
});
