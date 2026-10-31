import { describe, expect, it, vi } from "vitest";
import { existsSync, readFileSync, statSync } from "node:fs";
import { libpqReadQuery, parseReleaseCsv as parse } from "./production-libpq-read.mjs";
import { adminDatabasePlan, enabledSessionReads } from "./production-read-query.mjs";
import { releaseMetadataQuery } from "./redesign-reconciliation.mjs";

const ref = "dtubngvxfbupgvgfrjko";
const env = { RELEASE_READ_TRANSPORT: "direct", RELEASE_READ_CLIENT: "libpq", RELEASE_PG_CLIENT_DIRECTORY: "/fixed/public-clients",
  GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/production", GITHUB_REPOSITORY: "duindorpdoet/platform",
  APP_ENVIRONMENT: "production", SUPABASE_PROJECT_REF: ref, GITHUB_SHA: "a".repeat(40),
  SUPABASE_ACCESS_TOKEN: "private-provider-token", SUPABASE_DB_PASSWORD: "private-database-password" };
const plan = adminDatabasePlan(env, { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co` } });
const tools = { psql: "/fixed/public-clients/bin/psql" };
const nullMarker = "__duindorp_null_" + "a".repeat(64) + "__";
const parseReleaseCsv = (source: string) => parse(source, nullMarker);
const csv = (fields: unknown[]) => fields.map(value => value === null ? nullMarker : `"${String(value).replaceAll('"', '""')}"`).join(",") + "\n";
function commandBody(args: string[]) {
  expect(args[10]).toBe("--file");
  const file = args[11], source = readFileSync(file, "utf8");
  expect(statSync(file).mode & 0o777).toBe(0o600);
  const matched = /^SELECT (\$duindorp_read_[a-f0-9]{64}\$)([\s\S]*)\1\n\\gexec\n$/.exec(source);
  expect(matched).not.toBeNull();
  expect(matched![2]).not.toContain(matched![1]);
  return matched![2];
}

describe("fixed release CSV result contract", () => {
  it.each(["audit", "joint_input", "metadata", "preservation", "diagnostic", "nachtpost_activation", "manual_portals", "fingerprint"])("decodes the fixed %s JSON result with native JSON semantics", header => {
    const value = { quoted: 'a,"b"\nnew\rline', number: 7, boolean: false, empty: "", null: null, array: [1, true, null] };
    expect(parseReleaseCsv(header + "\n" + csv([JSON.stringify(value)]))).toEqual([{ [header]: value }]);
    expect(parseReleaseCsv(header + "\r\n")).toEqual([]);
    expect(parseReleaseCsv(header + "\n" + nullMarker + "\n")).toEqual([{ [header]: null }]);
  });
  it("preserves native booleans, int4 numbers, JSON arrays and SQL NULL in the canonical history proof", () => {
    const header = "save_hash,save_functions,cleanup_hash,trigger_valid,contaminated_drafts,versions,wrapper_versions\n";
    const row = csv(["", '{"nested":true}', null, "t", "0", '["20261027033940"]', "[]"]);
    const expected = [
      { save_hash: "", save_functions: { nested: true }, cleanup_hash: null, trigger_valid: true, contaminated_drafts: 0,
        versions: ["20261027033940"], wrapper_versions: [] },
    ];
    expect(parseReleaseCsv(header + row)).toEqual(expected);
    expect(parseReleaseCsv(header + row.replace(/^""/, ""))).toEqual(expected);
  });
  it("requires the explicit per-process NULL marker", () => {
    expect(() => parse("audit\n{}\n", "")).toThrow("RELEASE_READ_LIBPQ_NULL_MARKER_REQUIRED");
  });
  it("preserves int8 and numeric strings without guessing or precision loss", () => {
    expect(parseReleaseCsv("calls,mean_ms,max_ms,rows,rpc\n" + csv(["9223372036854775806", "1.20", "9007199254740993.00", "7", "a,\"b\"\n"]))).toEqual([
      { calls: "9223372036854775806", mean_ms: "1.20", max_ms: "9007199254740993.00", rows: "7", rpc: 'a,"b"\n' },
    ]);
  });
  it("decodes actor and inventory schemas without coercing UUID or bigint", () => {
    const actor = "01234567-89ab-cdef-0123-456789abcdef";
    expect(parseReleaseCsv("actor_id,functions_stable\n" + csv([actor, "f"]))).toEqual([{ actor_id: actor, functions_stable: false }]);
    expect(parseReleaseCsv("server_version,database_bytes,applied_migrations,extensions,storage_object_count,event_configuration\n" + csv(["17.6", "9007199254740993", "[]", '[{"name":"x"}]', "2", "[]"]))).toEqual([
      { server_version: "17.6", database_bytes: "9007199254740993", applied_migrations: [], extensions: [{ name: "x" }], storage_object_count: "2", event_configuration: [] },
    ]);
  });
  it.each(["", "unknown\n1\n", 'audit\n"{}"junk\n', 'audit\n"unclosed', 'audit\nabc"def\n', "audit\r{}", "audit\n{}\0\n",
    "audit\n{}\nmetadata\n{}\n", "audit\n{}\naudit\n{}\n", "audit\n{},extra\n", "actor_id,functions_stable\ninvalid,t\n",
    "actor_id,functions_stable\n01234567-89ab-cdef-0123-456789abcdef,true\n",
    "save_hash,save_functions,cleanup_hash,trigger_valid,contaminated_drafts,versions,wrapper_versions\nx,{},x,t,2147483648,[],[]\n"])("fails closed on malformed, unknown or extra result output %j", output => {
    expect(() => parseReleaseCsv(output)).toThrow(/^RELEASE_READ_LIBPQ_/);
  });
});

describe("explicit production portable libpq read", () => {
  it("validates the client before executing one bounded process with exact minimal endpoint/TLS environment", async () => {
    const batch = "begin read only;select '{}'::jsonb audit;commit;";
    let ca = "", home = "";
    const validate = vi.fn(async () => tools);
    const run = vi.fn(async (command: string, args: string[], environment: Record<string, string | undefined>, timeout: number) => {
      expect(validate).toHaveBeenCalledExactlyOnceWith(env.RELEASE_PG_CLIENT_DIRECTORY);
      expect(command).toBe(tools.psql); expect(timeout).toBe(100_000);
      expect(args.slice(0, 9)).toEqual(["-X", "-q", "--csv", "-w", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "--pset"]);
      expect(args[9]).toMatch(/^null=__duindorp_null_[a-f0-9]{64}__$/);
      expect(commandBody(args)).toBe("set default_transaction_read_only=on;set statement_timeout='60000ms';set lock_timeout='3s';set jit=off;set idle_in_transaction_session_timeout='70000ms';" + batch);
      expect(args.join(" ")).not.toContain(env.SUPABASE_DB_PASSWORD);
      ca = environment.PGSSLROOTCERT!; home = environment.HOME!;
      expect(statSync(ca).mode & 0o777).toBe(0o600); expect(statSync(home).mode & 0o777).toBe(0o700);
      expect(readFileSync(ca, "utf8")).toBe("PUBLIC-CA");
      expect(environment).toEqual({ PATH: process.env.PATH, HOME: home, LANG: "C", LC_ALL: "C", PGHOST: plan.host, PGPORT: "5432",
        PGDATABASE: "postgres", PGUSER: "postgres", PGPASSWORD: env.SUPABASE_DB_PASSWORD, PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full",
        PGSSLROOTCERT: ca, PGGSSENCMODE: "disable", PGAPPNAME: "duindorp-release-readonly" });
      return { error: null, stdout: "audit\n{}\n", stderr: "" };
    });
    const poisoned = { ...env, PGHOSTADDR: "wrong", PGSERVICE: "wrong", PGSERVICEFILE: "", PGPASSFILE: "wrong", PGSSLCERT: "wrong",
      PGSSLKEY: "wrong", PGSSLPASSWORD: "wrong", PGOPTIONS: "wrong", LD_PRELOAD: "wrong", SSL_CERT_FILE: "wrong", PRIVATE_SECRET: "wrong" };
    expect(await libpqReadQuery(batch, poisoned, plan, "PUBLIC-CA", 60_000, run, validate)).toEqual([{ audit: {} }]);
    expect(run).toHaveBeenCalledOnce(); expect(existsSync(ca)).toBe(false); expect(existsSync(home)).toBe(false);
  });
  it("preserves the administrative five-minute limit and uses no retry", async () => {
    const run = vi.fn(async (_command: string, _args: string[], _environment: unknown, timeout: number) => {
      expect(timeout).toBe(340_000); return { error: null, stdout: "preservation\n{}\n", stderr: "" };
    });
    await libpqReadQuery("fixed-batch", env, plan, "PUBLIC", 300_000, run, async () => tools);
    expect(run).toHaveBeenCalledOnce();
  });
  it("uses the trusted production session-pooler plan with project-qualified owner, full client TLS and port 5432", async () => {
    const sessionEnv = { ...env, RELEASE_READ_TRANSPORT: "session-pooler" };
    const sessionPlan = adminDatabasePlan(sessionEnv, { id: ref, region: "eu-west-2", database: { host: `db.${ref}.supabase.co` } },
      [{ pool_mode: "session", db_host: "aws-1-eu-west-2.pooler.supabase.com", db_user: "postgres", db_name: "postgres" }]);
    expect(enabledSessionReads(sessionEnv)).toBe(true);
    const run = vi.fn(async (_command: string, args: string[], environment: Record<string, string | undefined>) => {
      expect(args[5]).toBe("ON_ERROR_STOP=0"); expect(args.slice(-2)).toEqual(["--command", "rollback;reset all"]);
      expect(args.filter(value => value === "fixed-batch")).toHaveLength(0);
      expect(commandBody(args).endsWith("fixed-batch")).toBe(true);
      expect(environment).toMatchObject({ PGHOST: "aws-1-eu-west-2.pooler.supabase.com", PGPORT: "5432", PGUSER: `postgres.${ref}`,
        PGSSLMODE: "verify-full", PGCONNECT_TIMEOUT: "30", PGGSSENCMODE: "disable" });
      return { error: null, stdout: "audit\n{}\n", stderr: "" };
    });
    expect(await libpqReadQuery("fixed-batch", sessionEnv, sessionPlan, "PUBLIC-CA", 60_000, run, async () => tools)).toEqual([{ audit: {} }]);
    expect(run).toHaveBeenCalledOnce();
    for (const changes of [{ port: 6543 }, { user: "postgres" }, { user: "postgres.nocteiuvohesvqbowchw" },
      { host: "aws-1-eu-west-1.pooler.supabase.com" }, { host: "aws-1-eu-west-2.pooler.supabase.com.private.invalid" },
      { host: `db.${ref}.supabase.co` }, { ssl: { rejectUnauthorized: false } }]) {
      await expect(libpqReadQuery("batch", sessionEnv, { ...sessionPlan, ...changes } as typeof sessionPlan,
        "CA", 60_000, run, async () => tools)).rejects.toThrow("RELEASE_READ_LIBPQ_ENVIRONMENT_BOUNDARY");
    }
    expect(run).toHaveBeenCalledOnce();
  });
  it.each(["ERROR:  57014: private original SQL error", "ERROR:  42501: private cleanup error", "FATAL:  08006: private connection error", "ERROR: private unclassified server error"])("vetoes a server failure even after successful session cleanup exit zero: %s", async stderr => {
    const sessionEnv = { ...env, RELEASE_READ_TRANSPORT: "session-pooler" };
    const sessionPlan = { ...plan, host: "aws-1-eu-west-2.pooler.supabase.com", user: `postgres.${ref}` };
    const run = vi.fn(async () => ({ error: null, stdout: "audit\n{}\n", stderr }));
    await expect(libpqReadQuery("fixed-batch", sessionEnv, sessionPlan, "CA", 60_000, run, async () => tools)).rejects.toThrow(/^RELEASE_READ_/);
    expect(run).toHaveBeenCalledOnce();
  });
  it("rejects client, environment and endpoint changes before validation or processes", async () => {
    const run = vi.fn(), validate = vi.fn();
    for (const change of [{ RELEASE_READ_CLIENT: "node" }, { RELEASE_READ_TRANSPORT: "session-pooler" }, { APP_ENVIRONMENT: "staging" },
      { RELEASE_PG_CLIENT_DIRECTORY: "" }, { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw" }]) {
      await expect(libpqReadQuery("batch", { ...env, ...change }, plan, "CA", 60_000, run, validate)).rejects.toThrow("RELEASE_READ_LIBPQ_ENVIRONMENT_BOUNDARY");
    }
    await expect(libpqReadQuery("batch", env, { ...plan, host: "wrong" }, "CA", 60_000, run, validate)).rejects.toThrow("RELEASE_READ_LIBPQ_ENVIRONMENT_BOUNDARY");
    expect(run).not.toHaveBeenCalled(); expect(validate).not.toHaveBeenCalled();
    expect(() => enabledSessionReads({ ...env, APP_ENVIRONMENT: "staging" })).toThrow("RELEASE_READ_CLIENT_ENVIRONMENT_BOUNDARY");
    expect(() => enabledSessionReads({ ...env, RELEASE_READ_TRANSPORT: "transaction-pooler" })).toThrow("RELEASE_READ_CLIENT_ENVIRONMENT_BOUNDARY");
    expect(() => enabledSessionReads({ ...env, RELEASE_PG_CLIENT_DIRECTORY: "" })).toThrow("RELEASE_READ_CLIENT_ENVIRONMENT_BOUNDARY");
  });
  it("keeps a real post-migration metadata body above 128KiB out of argv and in one private gexec value", async () => {
    const query = releaseMetadataQuery({ cronBoundary: "0", cronHistory: [], migrationHistory: [], cronJobs: [],
      cronTerminal: { rows: 0, sha256: "a".repeat(64) }, mailEventOriginal: { rows: 5000, sha256: "a".repeat(64) },
      addedMailEvents: 0, invalidAddedMailEvents: 0, mailEventIds: Array.from({ length: 5000 }, (_, index) =>
        `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`) });
    const batch = "begin read only;" + query + ";commit;";
    expect(Buffer.byteLength(batch)).toBeGreaterThan(128 * 1024);
    let file = "";
    const run = vi.fn(async (_command: string, args: string[]) => {
      file = args[11];
      expect(args.every(value => Buffer.byteLength(value) < 4096)).toBe(true);
      expect(args.join(" ")).not.toContain("original_mail_ids");
      expect(commandBody(args).endsWith(batch)).toBe(true);
      return { error: null, stdout: "metadata\n{}\n", stderr: "" };
    });
    expect(await libpqReadQuery(batch, env, plan, "CA", 60_000, run, async () => tools)).toEqual([{ metadata: {} }]);
    expect(run).toHaveBeenCalledOnce(); expect(existsSync(file)).toBe(false);
  });
  it("sanitizes a synchronous E2BIG process failure and removes its private command file without replay", async () => {
    let file = "";
    const run = vi.fn(async (_command: string, args: string[]) => {
      file = args[11]; commandBody(args);
      throw Object.assign(new Error("PRIVATE_SQL_AND_PROCESS_DATA"), { code: "E2BIG" });
    });
    await expect(libpqReadQuery("fixed-batch", env, plan, "CA", 60_000, run, async () => tools)).rejects.toThrow(/^RELEASE_READ_LIBPQ_ARGUMENT_LIMIT$/);
    expect(run).toHaveBeenCalledOnce(); expect(existsSync(file)).toBe(false);
  });
  it.each([
    [{ code: 1 }, "ERROR:  57014: canceling statement due to statement timeout private-data", "RELEASE_READ_ORIGINAL_SQLSTATE_57014"],
    [{ code: 1 }, "ERROR:  P0001: RELEASE_READ_POLICY_REQUIRED private-data", "RELEASE_READ_POLICY_SQLSTATE_P0001"],
    [{ code: 1 }, "FATAL:  XX000: private-data", "RELEASE_READ_CONNECT_SQLSTATE_XX000"],
    [{ killed: true }, "private-data", "RELEASE_READ_LIBPQ_CLIENT_TIMEOUT"],
    [{ code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" }, "private-data", "RELEASE_READ_LIBPQ_OUTPUT_LIMIT"],
    [{ code: "ENOENT" }, "private-data", "RELEASE_READ_LIBPQ_CLIENT_UNAVAILABLE"],
    [{ code: "E2BIG" }, "private-data", "RELEASE_READ_LIBPQ_ARGUMENT_LIMIT"],
    [{ code: 1 }, "TLS certificate private-data", "RELEASE_READ_LIBPQ_CONNECT_TLS"],
    [{ code: 1 }, "private-data", "RELEASE_READ_LIBPQ_CONNECT_FAILED"],
  ] as const)("returns only fixed sanitized failures and never retries %j", async (error, stderr, expected) => {
    let home = "";
    const run = vi.fn(async (_command: string, _args: string[], environment: Record<string, string | undefined>) => {
      home = environment.HOME!; return { error, stdout: "private-output", stderr };
    });
    await expect(libpqReadQuery("batch", env, plan, "CA", 60_000, run, async () => tools)).rejects.toThrow(new RegExp("^" + expected + "$"));
    expect(run).toHaveBeenCalledOnce(); expect(existsSync(home)).toBe(false);
  });
});
