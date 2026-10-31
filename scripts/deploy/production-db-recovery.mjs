import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { classifyConnectionError, diagnosticPlan, probePoolerConnection } from "./production-db-diagnostics.mjs";

const PROJECT = "dtubngvxfbupgvgfrjko";
const MANAGEMENT = `https://api.supabase.com/v1/projects/${PROJECT}`;
const SITE = `https://${PROJECT}.supabase.co`;
export const MANAGEMENT_PROBE_SQL = "select 1 as connectivity";
const fail = code => { throw new Error(`DATABASE_RECOVERY_${code}`); };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

// This explicit operator mode is never a deployment fallback. No migration,
// backup operation, restore, reset or SQL mutation exists in this module.
export async function recoverProductionDatabase(env = process.env, request = fetch, poolerProbe = probePoolerConnection,
  now = () => performance.now(), sleep = pause) {
  const reason = env.DATABASE_RECOVERY_REASON?.trim();
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REF !== "refs/heads/production"
    || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.APP_ENVIRONMENT !== "production"
    || env.SUPABASE_PROJECT_REF !== PROJECT || env.NEXT_PUBLIC_SUPABASE_URL !== SITE
    || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "") || env.DATABASE_RECOVERY_REQUESTED !== "true"
    || !reason || reason.length < 20 || reason.length > 500 || /[\r\n\x00-\x1f]/.test(reason)
    || !env.SUPABASE_ACCESS_TOKEN || !env.SUPABASE_DB_PASSWORD
    || !(env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY)) fail("EXPLICIT_PRODUCTION_AUTHORIZATION_REQUIRED");
  const headers = { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` };
  async function metadata(path) {
    // This allowlist cannot address Auth, credentials, restoration or config.
    if (!["", "/config/database/pooler", "/database/backups"].includes(path)) fail("METADATA_ENDPOINT_REFUSED");
    let response;
    try { response = await request(MANAGEMENT + path, { method: "GET", headers, redirect: "error", signal: AbortSignal.timeout(15_000) }); }
    catch { fail("METADATA_REQUEST_FAILED"); }
    if (!response.ok) fail(`METADATA_HTTP_${response.status}`);
    try { return await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
  }
  async function managementProbe(timeoutMs = 15_000) {
    let response;
    try {
      response = await request(MANAGEMENT + "/database/query", { method: "POST", redirect: "error",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ read_only: true, query: MANAGEMENT_PROBE_SQL }), signal: AbortSignal.timeout(timeoutMs) });
    } catch (error) {
      return { reachable: false, errorClass: ["TimeoutError", "AbortError"].includes(error?.name) ? "CONNECTION_TIMEOUT" : classifyConnectionError(String(error?.message ?? "")), status: null };
    }
    // Any successful SQL response vetoes restart, including unexpected JSON.
    if (response.ok) return { reachable: true, errorClass: null, status: response.status };
    if ([401, 403].includes(response.status)) return { reachable: false, errorClass: "AUTH_FAILED", status: response.status };
    let body = "";
    try { body = await response.text(); } catch { /* Unknown responses fail closed. */ }
    return { reachable: false, errorClass: [544, 504].includes(response.status) ? "CONNECTION_TIMEOUT" : classifyConnectionError(body), status: response.status };
  }
  async function anonymousReadProbe() {
    let response;
    const key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
    try {
      response = await request(SITE + "/rest/v1/rpc/admin_startregie_snapshot", { method: "POST", redirect: "error",
        headers: { apikey: key, "Content-Type": "application/json", "Content-Profile": "api", "Accept-Profile": "api" },
        body: JSON.stringify({ _event_slug: "duindorp-halloween-2026" }), signal: AbortSignal.timeout(15_000) });
    } catch { return { schemaCacheUnavailable: false, status: null, code: "UNKNOWN" }; }
    let code = "UNKNOWN";
    try { const body = await response.json(); if (body?.code === "PGRST002") code = "PGRST002"; } catch { /* Fail closed. */ }
    return { schemaCacheUnavailable: response.status === 503 && code === "PGRST002", status: response.status, code };
  }

  const [project, poolers, backupMetadata] = await Promise.all([metadata(""), metadata("/config/database/pooler"), metadata("/database/backups")]);
  diagnosticPlan(env, project, poolers);
  if (project.status !== "ACTIVE_HEALTHY") fail("PROJECT_STATE_RESTART_VETO");
  const backupRows = Array.isArray(backupMetadata?.backups) ? backupMetadata.backups : [];
  const backups = backupRows.map(row => ({ timestamp: row.inserted_at ?? row.created_at ?? row.started_at,
    status: typeof row.status === "string" && /^[A-Z_ -]{1,50}$/i.test(row.status) ? row.status : "UNKNOWN" }))
    .filter(row => typeof row.timestamp === "string" && Number.isFinite(Date.parse(row.timestamp)))
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp));
  console.log(JSON.stringify({ phase: "context", projectStatus: /^[A-Z_]{1,50}$/.test(project?.status ?? "") ? project.status : "UNKNOWN",
    latestBackup: backups.length ? { timestamp: new Date(backups[0].timestamp).toISOString(), status: backups[0].status } : { timestamp: null, status: "UNKNOWN" },
    reasonSha256: createHash("sha256").update(reason).digest("hex") }));

  // Docker/image preparation happens before the two short HTTP probes, keeping
  // all three failure observations close to the single restart decision.
  const pooler = await poolerProbe(env, project, poolers);
  console.log(JSON.stringify({ phase: "pooler", connectivity: pooler.connectivity, errorClass: pooler.errorClass }));
  if (pooler.connectivity || pooler.errorClass !== "CONNECTION_TIMEOUT") fail("POOLER_RESTART_VETO");
  const [management, dataApi] = await Promise.all([managementProbe(), anonymousReadProbe()]);
  console.log(JSON.stringify({ phase: "preconditions", management, dataApi }));
  if (management.reachable || management.errorClass !== "CONNECTION_TIMEOUT") fail("MANAGEMENT_RESTART_VETO");
  if (!dataApi.schemaCacheUnavailable) fail("DATA_API_RESTART_VETO");

  // Documented endpoint: POST /v1/projects/{ref}/restart, no body. A timeout or
  // ambiguous response is NEVER retried; the operator must inspect separately.
  let restart;
  try { restart = await request(MANAGEMENT + "/restart", { method: "POST", headers, redirect: "error", signal: AbortSignal.timeout(15_000) }); }
  catch { fail("RESTART_REQUEST_UNCONFIRMED_NO_RETRY"); }
  if (!restart.ok) fail(`RESTART_HTTP_${restart.status}_NO_RETRY`);
  console.log(JSON.stringify({ phase: "restart-request-accepted", status: restart.status, restartRequests: 1 }));

  const deadline = now() + 300_000;
  let attempts = 0;
  while (now() < deadline) {
    const remaining = deadline - now();
    const probe = await managementProbe(Math.max(1, Math.min(15_000, Math.floor(remaining))));
    attempts += 1;
    console.log(JSON.stringify({ phase: "post-restart-read", attempt: attempts, ...probe }));
    if (probe.reachable) return { restarted: true, restartRequests: 1, managementReachable: true, deployed: false,
      sqlWrites: 0, messagesSent: 0, nextStep: "Run the normal release with its required backup, restore, migrations and acceptance." };
    if (now() < deadline) await sleep(Math.min(10_000, deadline - now()));
  }
  fail("POST_RESTART_READ_UNCONFIRMED_NO_RETRY");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  recoverProductionDatabase().then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(/^DATABASE_RECOVERY_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "DATABASE_RECOVERY_FAILED");
    process.exitCode = 1;
  });
}
