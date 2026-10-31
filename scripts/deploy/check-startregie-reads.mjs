import { createHmac } from "node:crypto";
import { pathToFileURL } from "node:url";

const EVENT_SLUG = "duindorp-halloween-2026";
const PROJECTS = { production: "dtubngvxfbupgvgfrjko", staging: "nocteiuvohesvqbowchw" };
const RPCS = new Set(["admin_startregie_snapshot", "admin_startregie_publication_readiness"]);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const fail = code => { throw new Error(`STARTREGIE_READ_CHECK_${code}`); };

// Existing, confirmed organization account only. This request cannot change Auth
// sessions, capabilities, participant records, schedules or routes.
export const ACTOR_QUERY = `select capability.user_id actor_id,
(select count(*)=2 from pg_proc proc where proc.oid in(
to_regprocedure('api.admin_startregie_snapshot(text)'),
to_regprocedure('api.admin_startregie_publication_readiness(text,jsonb,integer)'))
and proc.provolatile='s') functions_stable
from app_private.event_capabilities capability
join app_private.events event on event.id=capability.event_id
join auth.users account on account.id=capability.user_id
where event.slug='duindorp-halloween-2026' and capability.capability='groups_manage'
and capability.revoked_at is null and account.email_confirmed_at is not null
and account.deleted_at is null and (account.banned_until is null or account.banned_until<=statement_timestamp())
order by capability.user_id limit 1`;

function reasonCodes(readiness) {
  if (!readiness || typeof readiness.ready !== "boolean" || !Array.isArray(readiness.reasons)) fail("INVALID_READINESS");
  return [...new Set(readiness.reasons.map(reason => {
    if (typeof reason?.code !== "string" || !/^[A-Z][A-Z0-9_]{0,99}$/.test(reason.code)) fail("INVALID_REASON_CODE");
    return reason.code;
  }))].sort();
}

export async function checkStartregieReads(env = process.env, request = fetch, now = () => performance.now()) {
  const environment = env.APP_ENVIRONMENT, ref = env.SUPABASE_PROJECT_REF;
  if (!["production", "staging"].includes(environment) || !/^[a-z]{20}$/.test(ref ?? "")
    || ref !== PROJECTS[environment]
    || env.NEXT_PUBLIC_SUPABASE_URL !== `https://${ref}.supabase.co`
    || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.GITHUB_REF !== `refs/heads/${environment}`
    || !/^[a-f0-9]{40}$/.test(env.APP_REVISION ?? "") || env.APP_REVISION !== env.GITHUB_SHA
    || !env.SUPABASE_ACCESS_TOKEN || !(env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY)) fail("RELEASE_CONFIGURATION");

  async function json(url, options, operation) {
    let response;
    try { response = await request(url, { ...options, signal: AbortSignal.timeout(20_000) }); }
    catch { fail(`${operation}_REQUEST_FAILED`); }
    if (!response.ok) fail(`${operation}_HTTP_${response.status}`);
    try { return await response.json(); } catch { fail(`${operation}_INVALID_JSON`); }
  }
  const managementHeaders = { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, "Content-Type": "application/json" };
  const managementUrl = `https://api.supabase.com/v1/projects/${ref}`;
  const actors = await json(`${managementUrl}/database/query`, {
    method: "POST", headers: managementHeaders, body: JSON.stringify({ read_only: true, query: ACTOR_QUERY }),
  }, "ACTOR");
  const actor = actors?.[0]?.actor_id;
  if (!UUID.test(actor ?? "")) fail("EXISTING_AUTHORIZED_ADMIN_REQUIRED");
  if (actors[0].functions_stable !== true) fail("STABLE_READ_FUNCTIONS_REQUIRED");
  const config = await json(`${managementUrl}/postgrest`, { method: "GET", headers: managementHeaders }, "CONFIG");
  if (typeof config.jwt_secret !== "string" || config.jwt_secret.length < 20 || config.jwt_secret.trim().startsWith("{")) fail("LEGACY_SIGNING_SECRET_UNAVAILABLE");

  function actorToken() {
    const issued = Math.floor(Date.now() / 1000);
    const encode = value => Buffer.from(JSON.stringify(value)).toString("base64url");
    const value = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub: actor, role: "authenticated", aud: "authenticated", iss: `${env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1`, iat: issued, exp: issued + 120 })}`;
    return `${value}.${createHmac("sha256", config.jwt_secret).update(value).digest("base64url")}`;
  }
  async function rpc(name, args) {
    if (!RPCS.has(name)) fail("READ_RPC_REQUIRED");
    const started = now();
    const data = await json(`${env.NEXT_PUBLIC_SUPABASE_URL}/rest/v1/rpc/${name}`, {
      method: "POST", headers: {
        apikey: env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
        Authorization: `Bearer ${actorToken()}`, "Content-Type": "application/json", "Content-Profile": "api", "Accept-Profile": "api",
      }, body: JSON.stringify(args),
    }, name === "admin_startregie_snapshot" ? "SNAPSHOT" : "READINESS");
    const durationMs = Math.round((now() - started) * 100) / 100;
    if (!Number.isFinite(durationMs) || durationMs < 0 || durationMs >= 10_000) fail("TEN_SECOND_MARGIN_EXCEEDED");
    return { data, durationMs };
  }

  const checks = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    const snapshot = await rpc("admin_startregie_snapshot", { _event_slug: EVENT_SLUG });
    const groups = snapshot.data?.ops?.groups, settingsVersion = snapshot.data?.settings?.eventSettingsVersion;
    if (!Array.isArray(groups) || !Number.isSafeInteger(settingsVersion) || settingsVersion < 0) fail("INVALID_SNAPSHOT");
    const selection = groups.filter(group => group.scheduleId != null).map(group => {
      if (!UUID.test(group.scheduleId) || !Number.isSafeInteger(group.revision) || group.revision < 1) fail("INVALID_CURRENT_SCHEDULE");
      return { id: group.scheduleId, revision: group.revision };
    });
    if (new Set(selection.map(schedule => schedule.id)).size !== selection.length) fail("DUPLICATE_CURRENT_SCHEDULE");
    if (environment === "production" && (!groups.length || !selection.length)) fail("REAL_PRODUCTION_GROUPS_REQUIRED");
    const entry = { attempt, groups: groups.length, currentSchedules: selection.length, snapshotMs: snapshot.durationMs };
    if (selection.length) {
      const readiness = await rpc("admin_startregie_publication_readiness", {
        _event_slug: EVENT_SLUG, _expected_revisions: selection, _expected_settings_version: settingsVersion,
      });
      entry.readinessMs = readiness.durationMs;
      entry.ready = readiness.data?.ready;
      entry.reasonCodes = reasonCodes(readiness.data);
    } else {
      entry.readinessSkipped = "No current schedules; staging does not prove production performance.";
    }
    checks.push(entry);
  }
  return { environment, revision: env.APP_REVISION, transport: "PostgREST", readOnly: true, changedRows: 0, messagesSent: 0, productionPerformanceProven: environment === "production", maximumDurationMs: Math.max(...checks.flatMap(check => [check.snapshotMs, check.readinessMs ?? 0])), checks };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  checkStartregieReads().then(result => console.log(JSON.stringify(result))).catch(error => {
    console.error(/^STARTREGIE_READ_CHECK_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "STARTREGIE_READ_CHECK_FAILED");
    process.exitCode = 1;
  });
}
