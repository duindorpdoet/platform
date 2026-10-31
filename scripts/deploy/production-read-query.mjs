import { readFileSync } from "node:fs";
import { rootCertificates } from "node:tls";

const PROJECTS = { production: "dtubngvxfbupgvgfrjko", staging: "nocteiuvohesvqbowchw" };
// Public Supabase CA, downloaded from the official distribution endpoint:
// https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt
const supabaseCA = readFileSync(new URL("./supabase-root-2021.crt", import.meta.url), "utf8");
const fail = code => { throw new Error(`RELEASE_READ_${code}`); };
const isSqlState = code => typeof code === "string" && /^[0-9A-Z]{5}$/.test(code) && /[0-9]/.test(code);
const preservationPrefix = "begin read only;set local statement_timeout='5min';set local lock_timeout='3s';do $preservation_read_only$";
const metadataByRequest = new WeakMap();
const metadataTtlMs = 5 * 60_000;

async function validatedMetadata(env, request, load) {
  let entries = metadataByRequest.get(request);
  if (!entries) { entries = new Map(); metadataByRequest.set(request, entries); }
  // Credentials and context stay in process memory only. The caller still
  // validates its environment on every call and opens a new SQL connection.
  const context = JSON.stringify([env.GITHUB_REPOSITORY, env.GITHUB_REF, env.GITHUB_EVENT_NAME,
    env.GITHUB_SHA, env.APP_ENVIRONMENT, env.APP_REVISION, env.SUPABASE_PROJECT_REF,
    env.SUPABASE_ACCESS_TOKEN, env.SUPABASE_DB_PASSWORD]);
  const now = performance.now();
  for (const [key, entry] of entries) if (now < entry.createdAt || now >= entry.expiresAt) entries.delete(key);
  const cached = entries.get(context);
  if (cached) return cached.promise;
  const entry = { createdAt: now, expiresAt: now + metadataTtlMs, promise: null };
  entry.promise = (async () => {
    const project = await load("");
    const poolers = await load("/config/database/pooler");
    clientPlan(env, project, poolers); // Never retain invalid metadata.
    entry.expiresAt = performance.now() + metadataTtlMs;
    return { project, poolers };
  })().catch(error => {
    if (entries.get(context) === entry) entries.delete(context);
    throw error;
  });
  entries.set(context, entry);
  return entry.promise;
}

function configured(env) {
  return env.GITHUB_REPOSITORY === "duindorpdoet/platform"
    && Object.hasOwn(PROJECTS, env.APP_ENVIRONMENT ?? "")
    && env.SUPABASE_PROJECT_REF === PROJECTS[env.APP_ENVIRONMENT]
    && env.GITHUB_REF === `refs/heads/${env.APP_ENVIRONMENT}`
    && ["push", "workflow_dispatch"].includes(env.GITHUB_EVENT_NAME)
    && /^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
    && (!env.APP_REVISION || env.APP_REVISION === env.GITHUB_SHA)
    && Boolean(env.SUPABASE_ACCESS_TOKEN && env.SUPABASE_DB_PASSWORD);
}

export function enabledSessionReads(env = process.env) {
  if (env.RELEASE_READ_TRANSPORT !== "session-pooler") return false;
  if (!configured(env)) fail("ENVIRONMENT_BOUNDARY");
  return true;
}

// These inputs are fixed repository release inspections, never user SQL. The
// database enforces read-only state, including statements after an inner COMMIT.
// Reject attempts to remove that session policy before sending any SQL.
function validateReadSql(sql) {
  if (typeof sql !== "string" || !sql.trim() || sql.includes("\0")) fail("SQL_REQUIRED");
  const normalized = sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ")
    .replace(/"(default_transaction_read_only|transaction_read_only|transaction|all)"/gi, "$1");
  if (/\bread\s+write\b|\b(?:reset|discard)\b|\bset\s+(?:(?:local|session)\s+)?(?:default_transaction_read_only|transaction_read_only|transaction|session\s+characteristics)\b/i.test(normalized)
    || /\bset_config\s*\(\s*'(?:default_transaction_read_only|transaction_read_only)'/i.test(normalized)) fail("READ_ONLY_POLICY_REQUIRED");
  for (const match of normalized.matchAll(/\bset_config\s*\(/gi)) {
    if (!/^\s*'(?:request\.jwt\.claims|app\.readiness_joint_input)'\s*,/i.test(normalized.slice(match.index + match[0].length))) fail("READ_ONLY_POLICY_REQUIRED");
  }
}

function clientPlan(env, project, poolers) {
  const ref = env.SUPABASE_PROJECT_REF;
  if (project?.id !== ref || !/^[a-z]{2}-[a-z]+-\d$/.test(project?.region ?? "")
    || project.database?.host !== `db.${ref}.supabase.co`) fail("PROJECT_METADATA_BOUNDARY");
  if (!Array.isArray(poolers)) fail("POOLER_METADATA_REQUIRED");
  const host = new RegExp(`^aws-[0-9]+-${project.region}\\.pooler\\.supabase\\.com$`);
  const trusted = poolers.filter(row => host.test(row?.db_host ?? "")
    && ["postgres", `postgres.${ref}`].includes(row.db_user) && row.db_name === "postgres");
  const pooler = trusted.find(row => row.pool_mode === "session") ?? trusted.find(row => row.pool_mode === "transaction");
  if (!pooler) fail("TRUSTED_SESSION_POOLER_REQUIRED");
  return { host: pooler.db_host, port: 5432, database: "postgres", user: `postgres.${ref}`,
    password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: true, ca: [...rootCertificates, supabaseCA] },
    connectionTimeoutMillis: 10_000, application_name: "duindorp-release-readonly" };
}

function safeErrorCode(error) {
  if (isSqlState(error?.code)) return `SQLSTATE_${error.code}`;
  if (/timeout/i.test(error?.message ?? "") || error?.name === "TimeoutError") return "CLIENT_TIMEOUT";
  if (/certificate|SSL|TLS/i.test(error?.message ?? "")) return "TLS";
  if (["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EAI_AGAIN", "ENOTFOUND"].includes(error?.code)) return "CONNECTION_FAILED";
  return "QUERY_FAILED";
}

function readBatch(sql, statementMs) {
  // Put the effective policy in the same wire message and transaction as the
  // read. SET (without LOCAL) also protects any command after an inner COMMIT.
  const policy = `set default_transaction_read_only=on;set local statement_timeout='${statementMs}ms';set local lock_timeout='3s';set local jit=off;
do $release_read_policy$begin
if current_setting('transaction_read_only')<>'on' or current_setting('default_transaction_read_only')<>'on'
 or current_setting('statement_timeout')<>'${statementMs === 300_000 ? "5min" : "1min"}'
 or current_setting('lock_timeout')<>'3s' or current_setting('jit')<>'off'
then raise exception 'RELEASE_READ_POLICY_REQUIRED';end if;end $release_read_policy$;`;
  // The fixed owner wrappers keep their own BEGIN/COMMIT, original SQL body and
  // narrower 15s/500ms or administrative 5min/3s settings after this prefix.
  const begin = /^begin read only;/i.exec(sql)?.[0];
  return begin ? begin + policy + sql.slice(begin.length) : `begin read only;${policy}${sql}\n;commit;`;
}

/** Explicit native SQL transport: SQL is never retried or replayed. */
export async function sessionReadQuery(sql, env = process.env, request = fetch, ClientOverride) {
  if (!enabledSessionReads(env)) fail("TRANSPORT_NOT_ENABLED");
  validateReadSql(sql);
  async function metadata(path) {
    // Only these two fixed idempotent metadata GETs tolerate transient provider
    // transport failures. Never replay database SQL, RPCs or authentication.
    for (let attempt = 1; attempt <= 3; attempt++) {
      let response;
      try { response = await request(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}${path}`, {
        method: "GET", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` }, signal: AbortSignal.timeout(15_000),
      }); } catch {
        if (attempt === 3) fail("METADATA_REQUEST_FAILED");
      }
      if (response?.ok) {
        try { return await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
      }
      if (response) {
        const retryable = [502, 503, 504, 544].includes(response.status);
        try { await response.body?.cancel(); } catch { /* Do not expose response data. */ }
        if (!retryable || attempt === 3) fail(`METADATA_HTTP_${response.status}`);
      }
      await new Promise(resolve => setTimeout(resolve, attempt * 250));
    }
  }
  const { project, poolers } = await validatedMetadata(env, request, metadata);
  const plan = clientPlan(env, project, poolers);
  // Preservation already has a bounded administrative five-minute wrapper.
  const longRead = sql.startsWith(preservationPrefix);
  const statementMs = longRead ? 300_000 : 60_000;
  const clientMs = statementMs + 10_000;
  let clientError = null;
  let safelyIdle = false;
  let client;
  let phase = "CONNECT";
  // An idle network failure must not become an unhandled EventEmitter error.
  const onError = error => { clientError = error; };
  try {
    const Client = ClientOverride ?? (await import("@supabase/pg")).Client;
    client = new Client(plan);
    client.on("error", onError);
    await client.connect();
    safelyIdle = true;
    phase = "POLICY";
    // SET is executed on this actual session: Supavisor can ignore startup GUCs.
    // A session default survives COMMIT in the existing owner-only SQL wrappers.
    async function query(text, timeoutMs) {
      safelyIdle = false;
      try {
        const answer = await client.query({ text, query_timeout: timeoutMs });
        safelyIdle = true;
        return answer;
      } catch (error) {
        // A PostgreSQL ErrorResponse completes the command. A client timer or
        // network failure does not prove the server has stopped running it.
        safelyIdle = isSqlState(error?.code);
        throw error;
      }
    }
    await query("set default_transaction_read_only=on", 10_000);
    await query(`set statement_timeout='${statementMs}ms';set lock_timeout='3s';set jit=off;set idle_in_transaction_session_timeout='${clientMs}ms'`, 10_000);
    const proof = await query("select current_setting('default_transaction_read_only') as read_only,current_setting('statement_timeout') as statement_timeout,current_setting('lock_timeout') as lock_timeout,current_setting('jit') as jit", 10_000);
    const settings = proof.rows?.[0];
    if (settings?.read_only !== "on" || settings.jit !== "off"
      || settings.lock_timeout !== "3s" || settings.statement_timeout !== (longRead ? "5min" : "1min")) fail("POLICY_NOT_CONFIRMED");
    phase = "ORIGINAL";
    const answer = await query(readBatch(sql, statementMs), clientMs);
    if (clientError) throw clientError;
    const results = Array.isArray(answer) ? answer : [answer];
    if (results.some(result => !Array.isArray(result?.rows))) fail("ORIGINAL_RESULT_REQUIRED");
    // Match postgres-meta's multi-statement response contract exactly. Setup
    // and proof queries above are separate, so they can never become data.
    return results.reverse().find(result => result.rows.length !== 0)?.rows ?? [];
  } catch (error) {
    if (!isSqlState(error?.code) && /^RELEASE_READ_[A-Z0-9_]+$/.test(error?.message ?? "")) throw error;
    if (error?.message === "RELEASE_READ_POLICY_REQUIRED") phase = "POLICY";
    fail(`${phase}_${safeErrorCode(error)}`);
  } finally {
    if (client && safelyIdle && !clientError) {
      // Restore the borrowed session only when its command has completed.
      try { await client.query({ text: "rollback;reset all", query_timeout: 10_000 }); }
      catch (error) { console.error(`RELEASE_READ_CLEANUP_${safeErrorCode(error)}`); }
    }
    // query_timeout does not cancel pg's active server query. end() destroys an
    // active connection; do not queue ROLLBACK behind the timed-out operation.
    if (client) {
      try { await client.end(); }
      catch (error) { console.error(`RELEASE_READ_CLEANUP_CLOSE_${safeErrorCode(error)}`); }
    }
  }
}

