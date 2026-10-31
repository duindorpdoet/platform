import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { adminDatabasePlan, enabledSessionReads, publicReleaseCaBundle, sessionReadQuery } from "./production-read-query.mjs";

const CLI_DEADLINE_MS = 300_000;
const OUTPUT_LIMIT_BYTES = 256 * 1024;
const REPORT_FILE = new URL("./nachtpost-activation-report.sql", import.meta.url);
const MIGRATIONS_DIRECTORY = new URL("../../supabase/migrations/", import.meta.url);
const FAILURE_CODES = new Set(["ENVIRONMENT_BOUNDARY", "METADATA_REQUEST_FAILED", "METADATA_HTTP_FAILED", "METADATA_INVALID_JSON",
  "METADATA_BOUNDARY", "CLI_FAILED", "CLI_START_FAILED", "CLI_TIMEOUT", "CLI_OUTPUT_LIMIT", "CA_CLEANUP_FAILED"]);
const fail = code => { throw new Error(`PRODUCTION_DIRECT_MIGRATION_${code}`); };

function requireContext(env) {
  if (env.RELEASE_READ_TRANSPORT !== "direct" || env.APP_ENVIRONMENT !== "production") fail("ENVIRONMENT_BOUNDARY");
  try { if (!enabledSessionReads(env)) fail("ENVIRONMENT_BOUNDARY"); }
  catch { fail("ENVIRONMENT_BOUNDARY"); }
}

function safeSqlStates(output) {
  return [...new Set([...output.matchAll(/\bSQLSTATE\s+([0-9A-Z]{5})\b/g)]
    .map(match => match[1]).filter(value => /[0-9]/.test(value)))].sort();
}

function safeFailure(error) {
  const message = typeof error?.message === "string" ? error.message : "";
  const prefix = "PRODUCTION_DIRECT_MIGRATION_";
  if (message.startsWith(prefix) && FAILURE_CODES.has(message.slice(prefix.length))) return message;
  const state = /^(?:RELEASE_READ_[A-Z0-9_]*|PRODUCTION_DIRECT_MIGRATION_FAILED_)SQLSTATE_([0-9A-Z]{5})$/.exec(message);
  return `PRODUCTION_DIRECT_MIGRATION_FAILED${state ? `_SQLSTATE_${state[1]}` : ""}`;
}

function migrationEnvironment(env, plan, caFile) {
  const childEnv = { ...env };
  // Explicit flags and these replacements prevent libpq service files, hostaddr,
  // endpoint overrides or weaker inherited TLS options from selecting a peer.
  for (const key of Object.keys(childEnv)) if (key.startsWith("PG")) delete childEnv[key];
  for (const key of ["DATABASE_URL", "SUPABASE_DB_URL", "SSL_CERT_FILE", "SSL_CERT_DIR", "SUPABASE_CLI_BINARY_OVERRIDE"]) delete childEnv[key];
  return { ...childEnv, PGHOST: plan.host, PGPORT: String(plan.port), PGDATABASE: plan.database,
    PGUSER: plan.user, PGPASSWORD: plan.password, SUPABASE_DB_PASSWORD: plan.password,
    // Optional libpq overrides must be absent, rather than empty: an empty
    // PGSERVICEFILE is itself a filename and can fail before connecting.
    PGGSSENCMODE: "disable",
    PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full",
    PGSSLROOTCERT: caFile, PGAPPNAME: "duindorp-production-migrate",
    PGOPTIONS: "-c lock_timeout=5000 -c statement_timeout=300000", NODE_TLS_REJECT_UNAUTHORIZED: "1" };
}

/** One private CLI attempt. No output or error object from the child is logged. */
async function pushDatabase(url, password, childEnv, filenames, spawnProcess, dryRun) {
  const allowed = new Set(filenames.filter(name => /^\d{14}_[a-z0-9_]+\.sql$/.test(name)));
  let stdout = "", stderr = "", bytes = 0, terminal = null, child;
  const result = await new Promise(resolve => {
    let finished = false;
    let timer;
    const complete = (code, signal) => {
      if (finished) return;
      finished = true; clearTimeout(timer);
      resolve({ status: terminal ?? (code === 0 && signal == null ? "SUCCESS" : "CLI_FAILED") });
    };
    const stop = reason => {
      if (terminal || finished) return;
      terminal = reason;
      // pnpm starts the CLI as a child. Kill the private process group as well
      // as its leader so a timeout cannot leave a migration child running.
      try { if (child.pid) process.kill(-child.pid, "SIGKILL"); } catch { /* The child may already have exited. */ }
      try { child.kill("SIGKILL"); } catch { /* No private error data is returned. */ }
      complete(null, "SIGKILL");
    };
    try {
      // Pinned CLI 2.117.0's parseLegacyConnectionString/resolveLibpqPassword
      // uses PGPASSWORD when --db-url omits a password. Keep it out of argv.
      // https://github.com/supabase/cli/blob/v2.117.0/apps/cli/src/command-internal/legacy-db-config.parse.ts#L270-L298
      child = spawnProcess("pnpm", ["exec", "supabase", "db", "push", "--db-url", url,
        ...(dryRun ? ["--dry-run"] : []), "--include-all", "--yes"], {
        env: childEnv, detached: true, stdio: ["ignore", "pipe", "pipe"],
      });
      const capture = stream => chunk => {
        if (terminal || finished) return;
        bytes += Buffer.byteLength(chunk);
        if (bytes > OUTPUT_LIMIT_BYTES) { stop("CLI_OUTPUT_LIMIT"); return; }
        if (stream === "stdout") stdout += chunk.toString(); else stderr += chunk.toString();
      };
      child.stdout.on("data", capture("stdout")); child.stderr.on("data", capture("stderr"));
      child.once("error", () => { terminal ??= "CLI_START_FAILED"; complete(null, null); });
      child.once("close", complete);
      timer = setTimeout(() => stop("CLI_TIMEOUT"), CLI_DEADLINE_MS);
    } catch { terminal = "CLI_START_FAILED"; complete(null, null); }
  });
  let output = stdout + "\n" + stderr;
  for (const secret of [password, childEnv.SUPABASE_ACCESS_TOKEN]) if (secret) output = output.replaceAll(secret, "[redacted]");
  const summary = { ...result, sqlStates: safeSqlStates(output),
    migrations: [...new Set([...output.matchAll(/\b\d{14}_[a-z0-9_]+\.sql\b/g)].map(match => match[0]).filter(name => allowed.has(name)))].sort() };
  stdout = ""; stderr = "";
  return summary;
}

async function runMigration(env, request, spawnProcess, dryRun) {
  requireContext(env); // Before metadata, private files, child processes or SQL.
  let directory;
  try {
    let response;
    try { response = await request(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}`, {
      method: "GET", redirect: "error", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` },
      signal: AbortSignal.timeout(15_000),
    }); } catch { fail("METADATA_REQUEST_FAILED"); }
    if (!response.ok) {
      try { await response.body?.cancel(); } catch { /* Never expose provider response data. */ }
      fail("METADATA_HTTP_FAILED");
    }
    let project, plan;
    try { project = await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
    try { plan = adminDatabasePlan(env, project); } catch { fail("METADATA_BOUNDARY"); }
    // Read the checked-out allowlist before the only mutating command.
    const filenames = await readdir(MIGRATIONS_DIRECTORY);
    directory = await mkdtemp(join(tmpdir(), "duindorp-direct-migrate-"));
    await chmod(directory, 0o700);
    const caFile = join(directory, "root.crt");
    await writeFile(caFile, publicReleaseCaBundle(), { mode: 0o600, flag: "wx" });
    const url = new URL(`postgresql://postgres@${plan.host}:5432/postgres`);
    url.searchParams.set("sslmode", "verify-full"); url.searchParams.set("sslrootcert", caFile);
    const migration = await pushDatabase(url.href, plan.password, migrationEnvironment(env, plan, caFile), filenames, spawnProcess, dryRun);
    if (migration.status !== "SUCCESS") {
      // Only fixed classes, explicit SQLSTATEs and exact repository filenames
      // are observable. In particular, never stringify the child process.
      console.error(JSON.stringify(migration));
      fail(migration.status);
    }
    if (dryRun) {
      const result = { ...migration, dryRun: true };
      console.log(JSON.stringify(result));
      return result;
    }
    const sql = await readFile(REPORT_FILE, "utf8");
    const rows = await sessionReadQuery(sql, env, request);
    const result = { ...migration, activationReport: "COMPLETED", activationReportRows: rows.length };
    console.log(JSON.stringify(result));
    return result;
  } catch (error) {
    throw new Error(safeFailure(error));
  } finally {
    if (directory) {
      try { await rm(directory, { recursive: true, force: true }); }
      catch { fail("CA_CLEANUP_FAILED"); }
    }
  }
}

/** Production-only direct migration; no link, retry, replay or history repair. */
export async function runProductionDirectMigration(env = process.env, request = fetch, spawnProcess = spawn) {
  return runMigration(env, request, spawnProcess, false);
}

/** Explicit manual connection proof. Its command always includes --dry-run. */
export async function runProductionDirectMigrationDryRun(env = process.env, request = fetch, spawnProcess = spawn) {
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.MIGRATION_CONNECT_PROOF !== "true") fail("ENVIRONMENT_BOUNDARY");
  return runMigration(env, request, spawnProcess, true);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runProductionDirectMigration().catch(error => { console.error(safeFailure(error)); process.exitCode = 1; });
}
