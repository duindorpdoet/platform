import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { types } from "@supabase/pg";
import { validatePortablePostgresClient } from "./portable-postgres-clients.mjs";

const fail = code => { throw new Error(`RELEASE_READ_LIBPQ_${code}`); };
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;
// Exact result columns of the repository's fixed release inspections. PostgreSQL
// OIDs use the same pinned driver's parsers as the existing native transport.
const schemas = [
  ...["audit", "joint_input", "metadata", "preservation", "diagnostic", "nachtpost_activation", "manual_portals", "fingerprint"]
    .map(name => [[name], [3802]]),
  [["save_hash", "save_functions", "cleanup_hash", "trigger_valid", "contaminated_drafts", "versions", "wrapper_versions"], [25, 3802, 25, 16, 23, 3802, 3802]],
  [["actor_id", "functions_stable"], [2950, 16]],
  [["server_version", "database_bytes", "applied_migrations", "extensions", "storage_object_count", "event_configuration"], [25, 20, 3802, 3802, 20, 3802]],
  [["calls", "mean_ms", "max_ms", "rows", "rpc"], [20, 1700, 1700, 20, 25]],
];

/** Complete CSV parser retaining quoted fields and embedded line breaks. */
function csvRecords(source) {
  if (typeof source !== "string" || source.includes("\0")) fail("CSV_INVALID");
  const records = [];
  let record = [], value = "", quoted = false, state = "start";
  function field() { record.push({ value, quoted }); value = ""; quoted = false; state = "start"; }
  function row() { field(); records.push(record); record = []; }
  for (let index = 0; index < source.length; index++) {
    const character = source[index];
    if (state === "quoted") {
      if (character === '"') {
        if (source[index + 1] === '"') { value += '"'; index++; }
        else state = "closed";
      } else value += character;
      continue;
    }
    if (character === ",") { field(); continue; }
    if (character === "\n" || character === "\r") {
      if (character === "\r" && source[++index] !== "\n") fail("CSV_INVALID");
      row(); continue;
    }
    if (state === "closed") fail("CSV_INVALID");
    if (character === '"') {
      if (state !== "start") fail("CSV_INVALID");
      quoted = true; state = "quoted";
    } else { value += character; state = "unquoted"; }
  }
  if (state === "quoted") fail("CSV_INVALID");
  if (record.length || state !== "start") row();
  return records;
}

export function parseReleaseCsv(source, nullMarker) {
  if (!/^__duindorp_null_[a-f0-9]{64}__$/.test(nullMarker ?? "")) fail("NULL_MARKER_REQUIRED");
  const records = csvRecords(source);
  const header = records.shift()?.map(field => field.value);
  const schema = schemas.find(([columns]) => header?.length === columns.length && columns.every((name, index) => header[index] === name));
  if (!schema) fail("RESULT_SCHEMA_REQUIRED");
  const [columns, oids] = schema;
  return records.map(record => {
    if (record.length !== columns.length || record.every((field, index) => field.value === columns[index])) fail("RESULT_SCHEMA_REQUIRED");
    return Object.fromEntries(record.map((field, index) => {
      const oid = oids[index];
      if (field.value === nullMarker) return [columns[index], null];
      if (oid === 16 && !["t", "f"].includes(field.value)) fail("RESULT_TYPE_REQUIRED");
      if ([20, 23].includes(oid) && !/^-?\d+$/.test(field.value)) fail("RESULT_TYPE_REQUIRED");
      if (oid === 23 && (!Number.isSafeInteger(Number(field.value)) || Number(field.value) < -2147483648 || Number(field.value) > 2147483647)) fail("RESULT_TYPE_REQUIRED");
      if (oid === 1700 && !/^(?:-?\d+(?:\.\d+)?|NaN|[-+]?Infinity)$/.test(field.value)) fail("RESULT_TYPE_REQUIRED");
      if (oid === 2950 && !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(field.value)) fail("RESULT_TYPE_REQUIRED");
      try { return [columns[index], types.getTypeParser(oid, "text")(field.value)]; }
      catch { fail("RESULT_TYPE_REQUIRED"); }
    }));
  });
}

function execute(command, args, environment, timeout) {
  return new Promise(resolve => execFile(command, args, { env: environment, encoding: "utf8", timeout, killSignal: "SIGKILL", maxBuffer: MAX_OUTPUT_BYTES },
    (error, stdout, stderr) => resolve({ error, stdout, stderr })));
}

/** One verified portable psql process; no query retry, fallback or output logs. */
export async function libpqReadQuery(batch, env, plan, caBundle, statementMs, run = execute, validate = validatePortablePostgresClient) {
  if (env.RELEASE_READ_CLIENT !== "libpq" || env.RELEASE_READ_TRANSPORT !== "direct" || env.APP_ENVIRONMENT !== "production"
    || typeof env.RELEASE_PG_CLIENT_DIRECTORY !== "string" || !env.RELEASE_PG_CLIENT_DIRECTORY
    || env.SUPABASE_PROJECT_REF !== "dtubngvxfbupgvgfrjko" || plan.host !== "db.dtubngvxfbupgvgfrjko.supabase.co"
    || plan.port !== 5432 || plan.database !== "postgres" || plan.user !== "postgres" || plan.ssl?.rejectUnauthorized !== true) fail("ENVIRONMENT_BOUNDARY");
  const tools = await validate(env.RELEASE_PG_CLIENT_DIRECTORY);
  const directory = await mkdtemp(join(tmpdir(), "duindorp-libpq-read-"));
  try {
    const ca = join(directory, "root.crt");
    await writeFile(ca, caBundle, { flag: "wx", mode: 0o600 });
    const environment = { PATH: process.env.PATH, HOME: directory, LANG: "C", LC_ALL: "C",
      PGHOST: plan.host, PGPORT: String(plan.port), PGDATABASE: plan.database, PGUSER: plan.user, PGPASSWORD: plan.password,
      PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full", PGSSLROOTCERT: ca, PGGSSENCMODE: "disable", PGAPPNAME: plan.application_name };
    const clientMs = statementMs + 10_000;
    // psql CSV otherwise prints SQL NULL and empty text identically. A fresh
    // 256-bit sentinel separates them without changing the inspected SQL.
    const nullMarker = `__duindorp_null_${randomBytes(32).toString("hex")}__`;
    // Same actual-session setup and unmodified readBatch, sent together. The DO
    // guard runs before the original SQL; a session default protects inner COMMIT.
    const sql = `set default_transaction_read_only=on;set statement_timeout='${statementMs}ms';set lock_timeout='3s';set jit=off;set idle_in_transaction_session_timeout='${clientMs}ms';${batch}`;
    let result;
    try { result = await run(tools.psql, ["-X", "-q", "--csv", "-w", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "--pset", `null=${nullMarker}`, "--command", sql], environment, 30_000 + clientMs); }
    catch { fail("PROCESS_FAILED"); }
    if (result.error) {
      const error = result.error;
      if (error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") fail("OUTPUT_LIMIT");
      if (error.killed) fail("CLIENT_TIMEOUT");
      if (error.code === "ENOENT") fail("CLIENT_UNAVAILABLE");
      const message = result.stderr ?? "";
      const state = /\b(?:ERROR|FATAL):\s*([0-9A-Z]{5}):/.exec(message)?.[1];
      if (state && /[0-9]/.test(state)) {
        const phase = state === "P0001" && message.includes("RELEASE_READ_POLICY_REQUIRED") ? "POLICY" : /\bFATAL:/.test(message) ? "CONNECT" : "ORIGINAL";
        throw new Error(`RELEASE_READ_${phase}_SQLSTATE_${state}`);
      }
      if (/certificate|SSL|TLS/i.test(message)) fail("CONNECT_TLS");
      if (/timeout/i.test(message)) fail("CONNECT_CLIENT_TIMEOUT");
      fail("CONNECT_FAILED");
    }
    return parseReleaseCsv(result.stdout, nullMarker);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
