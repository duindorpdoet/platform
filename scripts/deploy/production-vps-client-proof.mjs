import { execFile } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { adminDatabasePlan, publicReleaseCaBundle } from "./production-read-query.mjs";
import { validatePortablePostgresClient } from "./portable-postgres-clients.mjs";
import { connectError } from "./production-connect-only.mjs";

const fail = code => { throw new Error(`VPS_CLIENT_PROOF_${code}`); };
const SQL = `begin read only;set local default_transaction_read_only=on;set local statement_timeout='5s';set local lock_timeout='1s';set local jit=off;
select json_build_object('connectivity',1,'backendPid',pg_backend_pid(),'serverTime',clock_timestamp(),'readOnly',current_setting('transaction_read_only')='on' and current_setting('default_transaction_read_only')='on','tls',(select ssl from pg_catalog.pg_stat_ssl where pid=pg_backend_pid()));commit;`;

function execute(command, args, environment) {
  return new Promise(resolve => execFile(command, args, { env: environment, timeout: 20_000, killSignal: "SIGKILL", maxBuffer: 16_384 },
    (error, stdout, stderr) => resolve({ error, stdout, stderr })));
}

/** Three independent bounded libpq reads. No retry, fallback or write SQL. */
export async function runVpsClientProof(env = process.env, request = fetch, run = execute, validate = validatePortablePostgresClient) {
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REPOSITORY !== "duindorpdoet/platform"
    || env.GITHUB_REF !== "refs/heads/production" || env.APP_ENVIRONMENT !== "production"
    || env.RUNNER_NAME !== "dg-sites-vps-01-duindorphalloweenprod-01"
    || !env.GITHUB_WORKSPACE?.startsWith("/srv/sites/duindorphalloweenprod/actions-runner/_work/")
    || !env.RUNNER_TEMP || !env.RELEASE_PG_CLIENT_DIRECTORY) fail("ENVIRONMENT_BOUNDARY");
  // Validate the repository/project/SHA/credentials before any metadata request.
  const directEnv = { ...env, RELEASE_READ_TRANSPORT: "direct" };
  const { enabledSessionReads } = await import("./production-read-query.mjs");
  try { if (!enabledSessionReads(directEnv)) fail("ENVIRONMENT_BOUNDARY"); } catch { fail("ENVIRONMENT_BOUNDARY"); }
  async function metadata(path) {
    let response;
    try { response = await request(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}${path}`, {
      method: "GET", redirect: "error", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` }, signal: AbortSignal.timeout(15_000),
    }); } catch { fail("METADATA_REQUEST_FAILED"); }
    if (!response.ok) { try { await response.body?.cancel(); } catch { /* No response data is exposed. */ } fail("METADATA_HTTP_FAILED"); }
    try { return await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
  }
  const project = await metadata("");
  const poolers = await metadata("/config/database/pooler");
  let direct, session;
  try { direct = adminDatabasePlan(directEnv, project); session = adminDatabasePlan({ ...env, RELEASE_READ_TRANSPORT: "session-pooler" }, project, poolers); }
  catch { fail("METADATA_BOUNDARY"); }
  const tools = await validate(env.RELEASE_PG_CLIENT_DIRECTORY);
  const home = await mkdtemp(join(env.RUNNER_TEMP, "duindorp-vps-client-home-"));
  const report = { diagnostic: "production-vps-libpq-readonly-proof", revision: env.GITHUB_SHA, status: "completed", changedRows: 0,
    limits: { perEndpointMs: 20_000, connectSeconds: 15, statementMs: 5000, lockMs: 1000 }, probes: [] };
  try {
    const ca = join(home, "roots.crt");
    await writeFile(ca, publicReleaseCaBundle(), { flag: "wx", mode: 0o600 });
    for (const [endpoint, plan] of [["DIRECT_5432", direct], ["SESSION_POOLER_5432", session], ["TRANSACTION_POOLER_6543", { ...session, port: 6543 }]]) {
      const started = performance.now();
      const environment = { PATH: process.env.PATH, HOME: home, LANG: "C", LC_ALL: "C", PGHOST: plan.host, PGPORT: String(plan.port),
        PGUSER: plan.user, PGDATABASE: "postgres", PGPASSWORD: plan.password, PGCONNECT_TIMEOUT: "15", PGSSLMODE: "verify-full", PGSSLROOTCERT: ca,
        PGGSSENCMODE: "disable",
        PGAPPNAME: "duindorp-vps-client-proof", PGOPTIONS: "-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=1000 -c jit=off" };
      let result;
      try { result = await run(tools.psql, ["-X", "-qAt", "-w", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "--command", SQL], environment); }
      catch { result = { error: { code: "CLIENT_FAILURE" }, stderr: "", stdout: "" }; }
      const probe = { endpoint, durationMs: Math.round(performance.now() - started), success: false, readOnly: false, tls: false, errorClass: null, sqlState: null };
      if (result.error) {
        const safe = connectError(result.stderr ?? "", true);
        const state = /\b(?:ERROR|FATAL):\s*([A-Z0-9]{5}):/.exec(result.stderr ?? "")?.[1];
        probe.sqlState = state && /[0-9]/.test(state) ? state : safe.sqlState;
        probe.errorClass = result.error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "OUTPUT_LIMIT"
          : result.error.killed ? "CLIENT_TIMEOUT" : result.error.code === "ENOENT" ? "CLIENT_UNAVAILABLE" : safe.errorClass;
      } else {
        try {
          const row = JSON.parse(result.stdout.trim());
          probe.readOnly = row.readOnly === true; probe.tls = row.tls === true;
          if (row.connectivity !== 1 || !Number.isSafeInteger(row.backendPid) || row.backendPid <= 0 || typeof row.serverTime !== "string"
            || !Number.isFinite(Date.parse(row.serverTime)) || row.readOnly !== true || row.tls !== true) throw new Error();
          probe.success = probe.readOnly = probe.tls = true;
        } catch { probe.errorClass = "READ_ONLY_TLS_PROOF_INVALID"; }
      }
      report.probes.push(probe);
    }
    const directory = join(env.RUNNER_TEMP, "duindorp-vps-client-proof");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    console.log(JSON.stringify(report));
    return report;
  } finally { await rm(home, { recursive: true, force: true }); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runVpsClientProof().catch(error => { console.error(/^VPS_CLIENT_PROOF_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "VPS_CLIENT_PROOF_FAILED"); process.exitCode = 1; });
}
