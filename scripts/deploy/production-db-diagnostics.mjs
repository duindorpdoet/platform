import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const PROJECT = "dtubngvxfbupgvgfrjko";
const BRANCH = "refs/heads/production";
const fail = code => { throw new Error(`POOLER_DIAGNOSTICS_${code}`); };

// Only predefined classifications leave the runner. No query text, client
// addresses, account data, credentials or arbitrary role names are selected.
export const DIAGNOSTIC_SQL = `begin read only;
set local statement_timeout='5s';
set local lock_timeout='500ms';
select jsonb_build_object('connectivity',1,'readOnly',current_setting('transaction_read_only')='on');
with classified as materialized (
 select case when usename in ('postgres','authenticator','authenticated','anon','service_role','supabase_admin','supabase_auth_admin','supabase_storage_admin','supabase_read_only_user','supabase_replication_admin','dashboard_user','pgbouncer') then usename else 'other' end role,
 case when state in ('active','idle','idle in transaction','idle in transaction (aborted)','fastpath function call','disabled') then state else 'other' end state,
 case when wait_event_type in ('Activity','BufferPin','Client','Extension','IO','IPC','Lock','LWLock','Timeout') then wait_event_type else 'none_or_other' end wait_type,
 case when wait_event ~ '^[A-Za-z0-9_]{1,80}$' then wait_event else 'none_or_other' end wait_event,
 case when query ilike '%admin_startregie_publication_readiness%' then 'startregie_readiness'
 when query ilike '%admin_startregie_snapshot%' then 'startregie_snapshot'
 when query ~* '(pg_catalog|pg_stat_activity|pg_settings|current_setting|select[[:space:]]+1)' then 'metadata'
 when query is null then 'unavailable' else 'other' end query_class,
 case when state='active' then greatest(0,extract(epoch from statement_timestamp()-query_start))::integer else null end active_seconds
 from pg_catalog.pg_stat_activity where datname=current_database() and pid<>pg_backend_pid()
), summary as (
 select role,state,wait_type,wait_event,query_class,count(*) backends,
 count(*) filter(where active_seconds>=15) active_at_least_15s,
 max(active_seconds) longest_active_seconds
 from classified group by role,state,wait_type,wait_event,query_class
)
select jsonb_build_object('activity',coalesce(jsonb_agg(to_jsonb(summary) order by role,state,wait_type,wait_event,query_class),'[]'::jsonb)) from summary;
rollback;
`;

export function diagnosticPlan(env, project, poolers) {
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REF !== BRANCH
    || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.APP_ENVIRONMENT !== "production"
    || env.SUPABASE_PROJECT_REF !== PROJECT || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
    || !env.SUPABASE_ACCESS_TOKEN || !env.SUPABASE_DB_PASSWORD) fail("PRODUCTION_BOUNDARY");
  if (project?.id !== PROJECT || !/^[a-z]{2}-[a-z]+-\d$/.test(project?.region ?? "")
    || project.database?.host !== `db.${PROJECT}.supabase.co`
    || !/^\d+\.\d+\.\d+\.\d+$/.test(project.database?.version ?? "")) fail("PROJECT_METADATA_BOUNDARY");
  const allowedHost = new RegExp(`^aws-[0-9]+-${project.region}\\.pooler\\.supabase\\.com$`);
  if (!Array.isArray(poolers)) fail("POOLER_METADATA_REQUIRED");
  const trusted = poolers.filter(row => allowedHost.test(row.db_host ?? "")
    && ["postgres", `postgres.${PROJECT}`].includes(row.db_user) && row.db_name === "postgres");
  // The API may only return transaction/6543 metadata for the same host. Its
  // session endpoint is still port 5432, as in the existing backup procedure.
  const pooler = trusted.find(row => row.pool_mode === "session") ?? trusted.find(row => row.pool_mode === "transaction");
  if (!pooler) fail("TRUSTED_SESSION_POOLER_REQUIRED");
  const image = `supabase/postgres:${project.database.version}`;
  const environment = {
    PGHOST: pooler.db_host, PGPORT: "5432", PGDATABASE: "postgres",
    PGUSER: pooler.db_user === "postgres" ? `postgres.${PROJECT}` : pooler.db_user,
    PGPASSWORD: env.SUPABASE_DB_PASSWORD, PGSSLMODE: "require", PGCONNECT_TIMEOUT: "5",
    PGAPPNAME: "duindorp-startregie-readonly-diagnostics",
    PGOPTIONS: "-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=500 -c idle_in_transaction_session_timeout=10000 -c jit=off",
  };
  return { image, environment, clientArgs: ["run", "--rm", "-i", "--network", "host",
    ...Object.keys(environment).flatMap(name => ["--env", name]),
    "--entrypoint", "psql", image, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"] };
}

export function classifyConnectionError(stderr) {
  if (/authentication failed|invalid password|tenant or user not found|role .+ does not exist/i.test(stderr)) return "AUTH_FAILED";
  if (/SSL|TLS|certificate|secure connection/i.test(stderr)) return "TLS";
  if (/could not translate host name|name or service not known|getaddrinfo|name resolution|nodename nor servname/i.test(stderr)) return "DNS";
  if (/connection[^\n]*timed out|timeout expired|connection timeout|connect[^\n]*ETIMEDOUT/i.test(stderr)) return "CONNECTION_TIMEOUT";
  return "OTHER";
}

function capture(args, input = "", environment = {}, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", args, { env: { PATH: process.env.PATH, HOME: process.env.HOME, ...environment }, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "", expired = false;
    const timer = setTimeout(() => { expired = true; child.kill(); }, timeoutMs);
    child.stdout.on("data", chunk => { if (stdout.length < 100_000) stdout += chunk.toString(); });
    child.stderr.on("data", chunk => { if (stderr.length < 16_000) stderr += chunk.toString(); });
    child.stdin.on("error", () => {});
    child.once("error", () => { clearTimeout(timer); reject(new Error("POOLER_DIAGNOSTICS_DOCKER_UNAVAILABLE")); });
    // Raw stderr stays inside this function; only its predefined class leaves.
    child.once("close", code => { clearTimeout(timer); resolve({ code, expired, stdout, errorClass: code === 0 && !expired ? null : classifyConnectionError(stderr) }); });
    child.stdin.end(input);
  });
}

export async function probePoolerConnection(env, project, poolers, execute = capture) {
  const plan = diagnosticPlan(env, project, poolers);
  const pull = await execute(["pull", plan.image], "", {}, 120_000);
  if (pull.code !== 0 || pull.expired) fail("IMAGE_PULL_FAILED");
  const started = performance.now();
  const result = await execute(plan.clientArgs, DIAGNOSTIC_SQL, plan.environment);
  const rows = result.stdout.trim().split("\n").filter(Boolean).map(line => {
    try { return JSON.parse(line); } catch { fail("UNEXPECTED_QUERY_OUTPUT"); }
  });
  return { connectivity: rows.some(row => row.connectivity === 1 && row.readOnly === true),
    durationMs: Math.round(performance.now() - started), code: result.code, expired: result.expired,
    errorClass: result.code === 0 && !result.expired ? null : ["CONNECTION_TIMEOUT", "AUTH_FAILED", "TLS", "DNS", "OTHER"].includes(result.errorClass) ? result.errorClass : "OTHER",
    activity: rows.find(row => Array.isArray(row.activity))?.activity ?? null };
}

export async function runDiagnostics(env = process.env, request = fetch, execute = capture, connectOnlyProbe) {
  // Reject outside context before even requesting project metadata.
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REF !== BRANCH
    || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.APP_ENVIRONMENT !== "production"
    || env.SUPABASE_PROJECT_REF !== PROJECT || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
    || !env.SUPABASE_ACCESS_TOKEN || !env.SUPABASE_DB_PASSWORD) fail("PRODUCTION_BOUNDARY");
  async function metadata(path) {
    let response;
    try { response = await request(`https://api.supabase.com/v1/projects/${PROJECT}${path}`, {
      method: "GET", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` }, signal: AbortSignal.timeout(15_000),
    }); } catch { fail("METADATA_REQUEST_FAILED"); }
    if (!response.ok) fail(`METADATA_HTTP_${response.status}`);
    try { return await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
  }
  const project = await metadata("");
  const poolers = await metadata("/config/database/pooler");
  const plan = diagnosticPlan(env, project, poolers);
  if (env.DIAGNOSTIC_NATIVE_CONNECT_ONLY === "true") {
    const probe = connectOnlyProbe ?? (await import("./production-connect-only.mjs")).runConnectOnlyDiagnostics;
    return probe(env, project, poolers);
  }
  console.log(JSON.stringify({ diagnostic: "production-session-pooler", readOnly: true, image: plan.image }));
  const result = await probePoolerConnection(env, project, poolers, execute);
  const { durationMs, connectivity, activity } = result;
  // Reconstruct output from an allowlisted shape. Do not print raw stdout even
  // on an unexpected psql/provider failure.
  console.log(JSON.stringify({ connectivity, durationMs, clientTimedOut: result.expired, clientExitCode: result.code, errorClass: result.errorClass }));
  if (result.code !== 0 || result.expired) fail("READ_FAILED");
  if (!connectivity || !activity) fail("INCOMPLETE_RESULT");
  const safeText = value => typeof value === "string" && /^[A-Za-z0-9_ ()]{1,80}$/.test(value);
  const safeActivity = activity.map(row => {
    if (![row.role, row.state, row.wait_type, row.wait_event, row.query_class].every(safeText)
      || !Number.isSafeInteger(row.backends) || row.backends < 0
      || !Number.isSafeInteger(row.active_at_least_15s) || row.active_at_least_15s < 0
      || (row.longest_active_seconds !== null && (!Number.isSafeInteger(row.longest_active_seconds) || row.longest_active_seconds < 0))) fail("UNEXPECTED_ACTIVITY_OUTPUT");
    return { role: row.role, state: row.state, waitType: row.wait_type, waitEvent: row.wait_event,
      queryClass: row.query_class, backends: row.backends, activeAtLeast15s: row.active_at_least_15s, longestActiveSeconds: row.longest_active_seconds };
  });
  return { readOnly: true, changedRows: 0, messagesSent: 0, durationMs, activity: safeActivity };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runDiagnostics().then(result => {
    console.log(JSON.stringify(result));
    if (result.diagnostic === "production-connect-only" && result.probes.some(probe => !probe.connected || probe.cleanupErrorClass)) process.exitCode = 1;
  }).catch(error => {
    console.error(/^POOLER_(?:DIAGNOSTICS|CONNECT_ONLY)_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "POOLER_DIAGNOSTICS_FAILED");
    process.exitCode = 1;
  });
}
