import { readFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { rootCertificates } from "node:tls";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { cpus, freemem, loadavg } from "node:os";
import { diagnosticPlan } from "./production-db-diagnostics.mjs";
import { componentBodies, originalHistorySha256 } from "./startregie-history-components.mjs";
import { assertInstalledHotfix, hotfixProofQuery, hotfixRepairActions } from "./repair-portal-hotfix-history.mjs";
import { sessionReadQuery } from "./production-read-query.mjs";

const fail = code => { throw new Error(`HISTORY_DIAGNOSIS_${code}`); };
const sqlState = error => typeof error?.code === "string" && /^[0-9A-Z]{5}$/.test(error.code) && /[0-9]/.test(error.code) ? error.code : error?.message?.match(/^RELEASE_READ_SQLSTATE_([0-9A-Z]{5})$/)?.[1] ?? null;
const cancelReason = error => sqlState(error) !== "57014" ? undefined
  : /^canceling statement due to statement timeout$/i.test(error?.message ?? "") ? "STATEMENT_TIMEOUT"
    : /^canceling statement due to user request$/i.test(error?.message ?? "") ? "USER_CANCEL" : "UNKNOWN";
export function diagnosticError(error) {
  const state = sqlState(error);
  if (state) return `SQLSTATE_${state}`;
  if (/timeout|timed out/i.test(error?.message ?? "") || error?.name === "TimeoutError") return "CLIENT_TIMEOUT";
  if (/certificate|SSL|TLS/i.test(error?.message ?? "")) return "TLS";
  if (["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "ENOTFOUND", "EAI_AGAIN"].includes(error?.code)) return "CONNECTION_FAILED";
  return /^(?:HISTORY_DIAGNOSIS|RELEASE_READ)_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "CLIENT_ERROR";
}
const connectionErrorCode = error => ["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "ENOTFOUND", "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "EPIPE",
  "CERT_HAS_EXPIRED", "DEPTH_ZERO_SELF_SIGNED_CERT", "SELF_SIGNED_CERT_IN_CHAIN", "UNABLE_TO_VERIFY_LEAF_SIGNATURE", "UNABLE_TO_GET_ISSUER_CERT_LOCALLY", "ERR_TLS_CERT_ALTNAME_INVALID", "ERR_SSL_WRONG_VERSION_NUMBER"].includes(error?.code)
  ? error.code : diagnosticError(error);
/** Observe pg8.21.1 lifecycle events without retaining protocol payloads. */
export function traceConnection(client, entry) {
  entry.events = [];
  const connection = client.connection;
  entry.eventsAvailable = Boolean(connection?.once && connection?.stream?.once);
  if (!entry.eventsAvailable) return;
  const began = performance.now(), cpuBegan = process.cpuUsage(), seen = new Set(), streams = new WeakSet();
  // These counters include all work in this Node process, including concurrent
  // connections. They do not attribute CPU to SCRAM, one client or the database.
  entry.cpuMeasurementScope = "SHARED_NODE_PROCESS";
  entry.cpuMeasurementBaseline = "TRACE_START";
  const record = (event, error) => {
    if (seen.has(event)) return;
    seen.add(event);
    const cpu = process.cpuUsage(cpuBegan);
    const value = { event, elapsedMs: Math.round((performance.now() - began) * 1000) / 1000,
      sharedProcessCpuDeltaMs: Math.round((cpu.user + cpu.system)) / 1000 };
    if (error) value.errorCode = connectionErrorCode(error);
    entry.events.push(value);
  };
  function attachStream(stream, secure) {
    if (!stream?.once || streams.has(stream)) return;
    streams.add(stream);
    if (secure) stream.once("secureConnect", () => record(stream.authorized === true ? "TLS_ESTABLISHED_VERIFIED" : "TLS_ESTABLISHED_UNVERIFIED"));
    else {
      stream.once("lookup", error => record(error ? "DNS_LOOKUP_FAILED" : "DNS_LOOKUP_COMPLETED", error));
      stream.once("connect", () => record("TCP_CONNECTED"));
    }
    const kind = secure ? "TLS" : "TCP";
    stream.once("error", error => record(`${kind}_STREAM_ERROR`, error));
    stream.once("end", () => record(`${kind}_STREAM_END`));
    stream.once("close", () => record(`${kind}_STREAM_CLOSE`));
  }
  attachStream(connection.stream, false);
  // pg emits sslconnect after creating the TLSSocket, before its handshake.
  connection.once("sslconnect", () => { record("TLS_SOCKET_CREATED"); attachStream(connection.stream, true); });
  // Successful method return proves local queueing, never remote receipt.
  for (const [method, event] of [["requestSsl", "POSTGRES_SSL_REQUEST_QUEUED"], ["startup", "POSTGRES_STARTUP_QUEUED"]]) {
    const original = connection[method];
    if (typeof original === "function") connection[method] = function (...args) { const answer = Reflect.apply(original, this, args); record(event); return answer; };
  }
  const finalMessage = connection.sendSCRAMClientFinalMessage;
  if (typeof finalMessage === "function") connection.sendSCRAMClientFinalMessage = function (...args) {
    // pg's method discards _send's false return when the stream is no longer
    // writable. Successful method return alone therefore cannot prove queueing.
    const writable = this.stream?.writable === true;
    const answer = Reflect.apply(finalMessage, this, args);
    record(writable ? "SCRAM_CLIENT_FINAL_LOCAL_QUEUED" : "SCRAM_CLIENT_FINAL_LOCAL_NOT_WRITABLE");
    return answer;
  };
  connection.once("authenticationSASLContinue", message => {
    // Retain only a bounded positive integer. Salt, nonce and SCRAM data never
    // enter the report, even when parsing fails or the iteration field repeats.
    if (typeof message?.data === "string" && message.data.length <= 8192) {
      const values = message.data.split(",").filter(value => value.startsWith("i="));
      if (values.length === 1 && /^i=[1-9]\d{0,9}$/.test(values[0])) {
        const iterations = Number(values[0].slice(2));
        if (Number.isSafeInteger(iterations) && iterations <= 2147483647) entry.serverScramIterations = iterations;
      }
    }
    record("AUTH_SASL_CONTINUE");
  });
  for (const [event, fixed] of [["authenticationCleartextPassword", "AUTH_CLEARTEXT_CHALLENGE"], ["authenticationMD5Password", "AUTH_MD5_CHALLENGE"],
    ["authenticationSASL", "AUTH_SASL_CHALLENGE"], ["authenticationSASLFinal", "AUTH_SASL_FINAL_RECEIVED"],
    ["authenticationOk", "AUTH_OK_RECEIVED"], ["backendKeyData", "BACKEND_KEY_RECEIVED"], ["readyForQuery", "READY_FOR_QUERY"], ["end", "CONNECTION_END"]]) connection.once(event, () => record(fixed));
  connection.once("error", error => record("CONNECTION_ERROR", error));
  connection.once("errorMessage", error => record("POSTGRES_ERROR", error));
}
export const PHASE_BODIES = Object.freeze({ ...componentBodies });
const finite = value => (typeof value === "number" || (typeof value === "string" && /^-?\d+(?:\.\d+)?$/.test(value))) && Number.isFinite(Number(value)) ? Number(value) : null;
const rowsOf = answer => (Array.isArray(answer) ? answer : [answer]).filter(row => Array.isArray(row?.rows));
const epoch = "extract(epoch from clock_timestamp())*1000";
function policy(reader) {
  return `set default_transaction_read_only=on;set local statement_timeout='${reader ? "5s" : "2s"}';set local lock_timeout='${reader ? "500ms" : "200ms"}';set local jit=off;set local idle_in_transaction_session_timeout='60s';`;
}
export function phaseSql(name) {
  if (!Object.hasOwn(PHASE_BODIES, name)) fail("UNKNOWN_PHASE");
  return `savepoint history_diagnosis_phase;${policy(true)}select ${epoch} as diagnostic_server_start,pg_backend_pid() as diagnostic_reader_pid,current_setting('transaction_read_only') as diagnostic_read_only,current_setting('jit') as diagnostic_jit,current_setting('statement_timeout') as diagnostic_timeout,current_setting('lock_timeout') as diagnostic_lock;\n${PHASE_BODIES[name]}\n;select ${epoch} as diagnostic_server_end;release savepoint history_diagnosis_phase;`;
}
export function observerSql(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1 || pid > 2147483647) fail("INVALID_READER_PID");
  return `select pg_stat_clear_snapshot();select jsonb_build_object('observedAtMs',${epoch},'targets',coalesce((select jsonb_agg(jsonb_build_object('pid',a.pid,'state',a.state,'wait_event_type',a.wait_event_type,'wait_event',a.wait_event,'blocking_pids',pg_blocking_pids(a.pid),'query_started_at_ms',extract(epoch from a.query_start)*1000)) from pg_catalog.pg_stat_get_activity(${pid}) a),'[]'::jsonb),'otherActive','[]'::jsonb) diagnostic_observation;`;
}
function safeSample(answer) {
  const row = rowsOf(answer).flatMap(result => result.rows).find(value => value.diagnostic_observation)?.diagnostic_observation;
  if (!row || !Array.isArray(row.targets) || row.targets.length > 4 || !Array.isArray(row.otherActive) || row.otherActive.length !== 0 || finite(row.observedAtMs) === null) fail("INVALID_OBSERVER_RESULT");
  const text = value => value === null ? null : typeof value === "string" && /^[A-Za-z_ ()]{1,80}$/.test(value) ? value : "other";
  const targets = row.targets.map(value => {
    if (!Number.isSafeInteger(value.pid) || !Array.isArray(value.blocking_pids) || !value.blocking_pids.every(pid => Number.isSafeInteger(pid) && pid > 0) || value.blocking_pids.length > 100) fail("INVALID_OBSERVER_RESULT");
    return { readerPid: value.pid, state: text(value.state), waitType: text(value.wait_event_type), waitEvent: text(value.wait_event), blockingPids: value.blocking_pids,
      queryStartedAtMs: finite(value.query_started_at_ms) };
  });

  return { targetSeen: targets.length > 0, inference: "NO_REACHABILITY_INFERENCE_FROM_ABSENCE", observedAtMs: finite(row.observedAtMs), targets, otherActive: [] };
}

export const CAPACITY_SQL = `select jsonb_build_object('maxConnections',current_setting('max_connections'),'reservedConnections',current_setting('reserved_connections',true),'superuserReservedConnections',current_setting('superuser_reserved_connections',true),'databaseConnectionLimit',(select datconnlimit from pg_database where datname=current_database()),'roleConnectionLimit',(select rolconnlimit from pg_roles where rolname=current_user),'totalBackends',count(*),'activeBackends',count(*) filter(where state='active'),'idleBackends',count(*) filter(where state='idle'),'idleInTransactionBackends',count(*) filter(where state like 'idle in transaction%'),'clientBackends',count(*) filter(where backend_type='client backend'),'clientBackendsCurrentDatabase',count(*) filter(where backend_type='client backend' and datname=current_database()),'clientBackendsCurrentRole',count(*) filter(where backend_type='client backend' and usename=current_user),'clientBackendsActive',count(*) filter(where backend_type='client backend' and state='active'),'clientBackendsIdle',count(*) filter(where backend_type='client backend' and state='idle'),'clientBackendsIdleInTransaction',count(*) filter(where backend_type='client backend' and state like 'idle in transaction%'),'walSenderBackends',count(*) filter(where backend_type='walsender'),'otherBackendProcesses',count(*) filter(where backend_type is distinct from 'client backend' and backend_type is distinct from 'walsender')) diagnostic_capacity from pg_stat_activity;`;

function clientHostSample() {
  return { loadAverage: loadavg(), cpuCount: cpus().length, freeMemoryBytes: freemem() };
}

/** Fixed, read-only diagnosis only. No retries, repairs or deployments. */
export async function runHistoryDiagnosis(env = process.env, request = fetch, ClientOverride) {
  const report = { diagnostic: "startregie-history", revision: /^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "") ? env.GITHUB_SHA : null, readOnly: true, changedRows: 0,
    status: "failed", limits: { statementMs: 5000, lockMs: 500, readerClientMs: 7000, observerStatementMs: 2000,
      observerClientMs: 3000, configuredDriverConnectMs: 30000, normalReleaseConfiguredDriverConnectMs: 10000, samplesPerSplitPhase: 4, samplesOriginalMaximum: 36, originalSampleIntervalMs: 5000, totalMs: 180000, normalReleaseConfiguredStatementMs: 60000, normalReleaseConfiguredClientMs: 70000 },
    connections: {}, phases: [], observerAvailable: false, checks: { splitCanonical: null, combinedCanonical: null, combinedMatchesSplit: null } };
  let reader, observer, reproduction, unsafeReader = false, unsafeObserver = false, totalExpired = false;
  const started = performance.now();
  const budget = new AbortController();
  const ensureBudget = () => { if (totalExpired || budget.signal.aborted) fail("TOTAL_DEADLINE_EXPIRED"); };
  async function boundedRequest(url, options = {}) {
    ensureBudget();
    const response = await request(url, { ...options, signal: options.signal ? AbortSignal.any([options.signal, budget.signal]) : budget.signal });
    ensureBudget();
    return response;
  }
  const closed = new WeakSet();
  const close = async client => {
    if (!client || closed.has(client)) return;
    closed.add(client);
    try { await client.end(); } catch (error) { report.cleanupErrors ??= []; report.cleanupErrors.push(diagnosticError(error)); }
  };
  const totalTimer = setTimeout(() => { totalExpired = true; budget.abort(); unsafeReader = unsafeObserver = true; void close(reader); void close(observer); void close(reproduction); }, 180_000);
  try {
    if (env.HISTORY_DIAGNOSTICS_REQUESTED !== "true") fail("EXPLICIT_REQUEST_REQUIRED");
    if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.GITHUB_REF !== "refs/heads/production"
      || env.APP_ENVIRONMENT !== "production" || env.SUPABASE_PROJECT_REF !== "dtubngvxfbupgvgfrjko" || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
      || !env.SUPABASE_ACCESS_TOKEN || !env.SUPABASE_DB_PASSWORD) fail("PRODUCTION_BOUNDARY");
    const connectionPath = env.HISTORY_CONNECTION_PATH ?? "session-pooler";
    if (!["session-pooler", "direct-vps"].includes(connectionPath)) fail("INVALID_CONNECTION_PATH");
    const direct = connectionPath === "direct-vps";
    if (direct && (env.RUNNER_NAME !== "dg-sites-vps-01-duindorphalloweenprod-01"
      || !env.GITHUB_WORKSPACE?.startsWith("/srv/sites/duindorphalloweenprod/actions-runner/_work/"))) fail("DIRECT_VPS_BOUNDARY");
    if (env.RUNNER_NAME === "dg-sites-vps-01-duindorphalloweenprod-01"
      && env.GITHUB_WORKSPACE?.startsWith("/srv/sites/duindorphalloweenprod/actions-runner/_work/")) {
      report.clientHost = { scope: "VPS_CLIENT", interpretation: "WORKFLOW_RUNNER_NOT_DATABASE", initial: clientHostSample() };
    }
    report.connectionPath = connectionPath;
    report.originalSessionPoolerReproduction = !direct;
    report.capacityInterpretation = "COUNTS_ONLY_NO_EXHAUSTION_INFERENCE";
    if (createHash("sha256").update(hotfixProofQuery).digest("hex") !== originalHistorySha256) fail("ORIGINAL_QUERY_CHANGED");
    report.originalHelperSha256 = createHash("sha256").update(readFileSync(new URL("./production-read-query.mjs", import.meta.url))).digest("hex");
    async function metadata(path) {
      const began = performance.now();
      const entry = { kind: path ? "pooler" : "project", stage: "split_setup", status: "failed", wallMs: null };
      report.metadata ??= []; report.metadata.push(entry);
      let response;
      try {
      try { response = await boundedRequest(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}${path}`, {
        method: "GET", headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` }, signal: AbortSignal.timeout(15_000),
      }); } catch { fail("METADATA_REQUEST_FAILED"); }
      if (!response.ok) fail(`METADATA_HTTP_${response.status}`);
      let result;
      try { result = await response.json(); } catch { fail("METADATA_INVALID_JSON"); }
      ensureBudget();
      entry.status = "passed";
      return result;
      } finally { entry.wallMs = Math.round(performance.now() - began); }
    }
    const project = await metadata("");
    const poolers = await metadata("/config/database/pooler");
    const plan = diagnosticPlan(env, project, poolers).environment;
    report.poolerLimits = poolers.map(row => Object.fromEntries(["pool_size", "default_pool_size", "max_client_conn"].filter(key => /^\d+$/.test(String(row[key] ?? "")) && Number.isSafeInteger(Number(row[key]))).map(key => [key, Number(row[key])]))).filter(row => Object.keys(row).length);
    const Client = ClientOverride ?? (await import("@supabase/pg")).Client;
    ensureBudget();
    // Both metadata responses still pass the unchanged production plan checks.
    // The explicit direct path changes only the connection endpoint and owner.
    const endpoint = direct ? { host: project.database.host, port: 5432, user: "postgres" } : { host: plan.PGHOST, port: 5432, user: plan.PGUSER };
    const configuration = { ...endpoint, database: "postgres", password: env.SUPABASE_DB_PASSWORD,
      ssl: { rejectUnauthorized: true, ca: [...rootCertificates, readFileSync(new URL("./supabase-root-2021.crt", import.meta.url), "utf8")] },
      connectionTimeoutMillis: 30000 };
    reader = new Client({ ...configuration, application_name: "duindorp-release-history-diagnosis" });
    observer = new Client({ ...configuration, application_name: "duindorp-release-history-observer" });
    reader.on("error", () => { unsafeReader = true; });
    observer.on("error", () => { unsafeObserver = true; });
    async function establish(client, name, isReader) {
      const entry = { stage: "driver_connect", status: "failed", configuredDriverConnectMs: configuration.connectionTimeoutMillis, driverConnectMs: null, backendProofMs: null, backendPid: null };
      report.connections[name] = entry;
      traceConnection(client, entry);
      let began = performance.now();
      try {
        ensureBudget();
        await client.connect();
        ensureBudget();
        entry.driverConnectMs = Math.round(performance.now() - began);
        entry.stage = "backend_readonly_proof"; began = performance.now();
        const answer = await client.query({ text: `${isReader ? "begin isolation level repeatable read read only;" : "begin read only;"}${policy(isReader)}select pg_backend_pid() as diagnostic_pid,current_user='postgres' as diagnostic_owner,current_setting('transaction_read_only') as diagnostic_read_only,current_setting('jit') as diagnostic_jit,current_setting('statement_timeout') as diagnostic_timeout,current_setting('lock_timeout') as diagnostic_lock,${epoch} as diagnostic_backend_at;`, query_timeout: isReader ? 7000 : 3000 });
        ensureBudget();
        entry.backendProofMs = Math.round(performance.now() - began);
        const row = rowsOf(answer).flatMap(result => result.rows).find(value => value.diagnostic_pid !== undefined);
        if (!Number.isSafeInteger(row?.diagnostic_pid) || row.diagnostic_pid <= 0 || row.diagnostic_owner !== true
          || row.diagnostic_read_only !== "on" || row.diagnostic_jit !== "off" || row.diagnostic_timeout !== (isReader ? "5s" : "2s") || row.diagnostic_lock !== (isReader ? "500ms" : "200ms")
          || finite(row.diagnostic_backend_at) === null) fail("BACKEND_POLICY_NOT_PROVEN");
        entry.backendPid = row.diagnostic_pid; entry.backendEstablishedAtMs = finite(row.diagnostic_backend_at);
        entry.status = "ready"; entry.stage = "ready";
      } catch (error) {
        if (entry.stage === "driver_connect") entry.driverConnectMs = Math.round(performance.now() - began);
        else entry.backendProofMs = Math.round(performance.now() - began);
        entry.errorClass = diagnosticError(error); if (isReader) unsafeReader = true; else unsafeObserver = true;
        await close(client);
      }
    }
    await Promise.all([establish(reader, "reader", true), establish(observer, "observer", false)]);
    if (report.connections.reader.status !== "ready" || unsafeReader) fail("READER_BACKEND_NOT_READY");
    const readerPid = report.connections.reader.backendPid;
    if (report.connections.observer.status === "ready" && !unsafeObserver) {
      if (readerPid === report.connections.observer.backendPid) fail("DISTINCT_BACKENDS_NOT_PROVEN");
      report.observerAvailable = true;
    } else { unsafeObserver = true; report.observerAvailable = false; await close(observer); }
    const componentResults = {};
    async function observe(phase, pid, original = false) {
      if (unsafeObserver || totalExpired) return;
      if (original && pid === null) {
        phase.samples.push({ observationStatus: "NOT_SAMPLED_BACKEND_PID_NOT_YET_PROVEN", otherActiveCollection: "NOT_COLLECTED",
          inference: "NO_REACHABILITY_INFERENCE_FROM_ABSENCE", wallObservedAt: new Date().toISOString() });
        return;
      }
      const sampled = performance.now();
      try {
        ensureBudget();
        const value = safeSample(await observer.query({ text: observerSql(pid), query_timeout: 3000 }));
        ensureBudget();
        if (value.targets.some(target => target.readerPid !== pid)) fail("OBSERVER_PID_MISMATCH");
        value.targetAttribution = "KNOWN_READER_PID_ONLY"; value.otherActiveCollection = "NOT_COLLECTED";
        phase.samples.push({ ...value, wallMs: Math.round(performance.now() - sampled), wallObservedAt: new Date().toISOString() });
      } catch (failure) {
        unsafeObserver = true; report.observerAvailable = false;
        phase.samples.push({ observerErrorClass: diagnosticError(failure), observerCancelReason: cancelReason(failure) });
        await close(observer);
      }
    }
    for (const name of Object.keys(PHASE_BODIES)) {
      if (unsafeReader || totalExpired) break;
      const phase = { name, status: "failed", wallStartedAt: new Date().toISOString(), wallMs: null, serverStartedAtMs: null,
        serverEndedAtMs: null, serverMs: null, serverStopProven: false, observerAvailableAtStart: !unsafeObserver && report.observerAvailable, samples: [] };
      report.phases.push(phase);
      const began = performance.now();
      let answer, error, settled = false;
      const pending = reader.query({ text: phaseSql(name), query_timeout: 7000 }).then(value => { answer = value; settled = true; }, value => { error = value; settled = true; });
      for (let index = 0; index < 3 && !settled && !unsafeObserver; index++) {
        await observe(phase, readerPid);
        if (!settled) await Promise.race([pending, new Promise(resolve => setTimeout(resolve, 1500))]);
      }
      await pending;
      phase.wallMs = Math.round(performance.now() - began);
      phase.wallEndedAt = new Date().toISOString();
      if (error) {
        phase.errorClass = diagnosticError(error);
        phase.cancelReason = cancelReason(error);
        phase.serverStopProven = Boolean(sqlState(error));
        if (!phase.serverStopProven) { unsafeReader = true; await close(reader); }
      } else {
        try {
          const results = rowsOf(answer);
          const start = results.flatMap(result => result.rows).find(row => row.diagnostic_server_start !== undefined);
          const end = results.flatMap(result => result.rows).find(row => row.diagnostic_server_end !== undefined);
          const data = results.filter(result => result.rows.length && !Object.keys(result.rows[0]).some(key => key.startsWith("diagnostic_")));
          if (start?.diagnostic_reader_pid !== readerPid || start.diagnostic_read_only !== "on" || start.diagnostic_jit !== "off"
            || start.diagnostic_timeout !== "5s" || start.diagnostic_lock !== "500ms" || data.length !== 1 || data[0].rows.length !== 1
            || finite(start.diagnostic_server_start) === null || finite(end?.diagnostic_server_end) === null) fail("PHASE_RESULT_NOT_PROVEN");
          phase.serverStartedAtMs = finite(start.diagnostic_server_start); phase.serverEndedAtMs = finite(end.diagnostic_server_end);
          phase.serverMs = Math.round((phase.serverEndedAtMs - phase.serverStartedAtMs) * 1000) / 1000;
          phase.serverStopProven = true; phase.status = "passed";
          componentResults[name] = data[0].rows[0];
        } catch (failure) { phase.errorClass = diagnosticError(failure); unsafeReader = true; }
      }
      await observe(phase, readerPid);
      for (const value of phase.samples) value.overlapsCompletedServerInterval = phase.serverStartedAtMs !== null && value.observedAtMs >= phase.serverStartedAtMs && value.observedAtMs <= phase.serverEndedAtMs;
      phase.observerAvailableAtEnd = !unsafeObserver && report.observerAvailable;
      phase.observationStatus = phase.samples.some(value => value.targetSeen && value.overlapsCompletedServerInterval) ? "OBSERVED_DURING_SERVER_INTERVAL"
        : unsafeObserver ? "UNOBSERVED_OBSERVER_UNAVAILABLE" : "NO_PROVEN_OVERLAPPING_OBSERVATION";
      if (error && phase.serverStopProven && !unsafeReader && !totalExpired) {
        try { await reader.query({ text: "rollback to savepoint history_diagnosis_phase;release savepoint history_diagnosis_phase;", query_timeout: 7000 }); }
        catch (failure) { phase.recoveryErrorClass = diagnosticError(failure); unsafeReader = true; }
      }
    }
    if (report.phases.length === 4 && report.phases.every(phase => phase.status === "passed") && !unsafeReader && !totalExpired) {
      const split = Object.assign({}, ...Object.keys(componentBodies).map(name => componentResults[name]));
      try { assertInstalledHotfix(split); hotfixRepairActions(split, "production"); report.checks.splitCanonical = true; }
      catch { report.checks.splitCanonical = false; }
      if (unsafeObserver || !report.observerAvailable) {
        report.originalSkippedReason = "OBSERVER_UNAVAILABLE";
        fail("OBSERVER_UNAVAILABLE_FOR_ORIGINAL");
      }
      await reader.query({ text: "rollback;reset all", query_timeout: 7000 });
      await close(reader); reader = null;
      const phase = { name: "combined_original", status: "failed", stage: "metadata", samples: [], originalSqlInvocations: 0,
        connectionPath, originalSessionPoolerReproduction: !direct, connectionOverrides: direct ? ["host", "port", "user"] : [],
        originalBodySha256: originalHistorySha256, configuredStatementMs: 60000, configuredClientMs: 70000,
        serverMs: null, serverTiming: "OBSERVATION_ONLY_TO_PRESERVE_ORIGINAL_SQL", serverStopProven: false,
        wallStartedAt: new Date().toISOString(), proofBackendPid: null };
      report.phases.push(phase);
      let combined, failure, settled = false;
      const began = performance.now();
      const ensureOriginalReady = () => { ensureBudget(); if (unsafeObserver || !report.observerAvailable) fail("OBSERVER_UNAVAILABLE"); };
      async function originalRequest(url, options) {
        ensureOriginalReady();
        const kind = String(url).endsWith("/config/database/pooler") ? "pooler" : "project";
        const entry = { kind, stage: "combined_original", status: "failed", wallMs: null };
        report.metadata.push(entry);
        phase.stage = `metadata_${kind}`;
        const time = performance.now();
        try {
          const response = await boundedRequest(url, options);
          entry.status = `HTTP_${response.status}`;
          return response;
        } finally { entry.wallMs = Math.round(performance.now() - time); }
      }
      class OriginalClient {
        constructor(config) {
          // Preserve the old helper, SQL, policy and timeouts. Direct VPS is
          // explicitly a transport variant, not an unchanged pooler reproduction.
          ensureOriginalReady(); reproduction = new Client(direct ? { ...config, ...endpoint } : config); phase.beforeDriverMs = Math.round(performance.now() - began);
          phase.connection = { configuredDriverConnectMs: config.connectionTimeoutMillis }; traceConnection(reproduction, phase.connection);
        }
        on(...args) { reproduction.on(...args); return this; }
        async connect() {
          ensureOriginalReady();
          phase.stage = "driver_connect";
          const time = performance.now();
          try { await reproduction.connect(); ensureOriginalReady(); phase.stage = "session_policy"; }
          finally { phase.driverConnectMs = Math.round(performance.now() - time); }
        }
        async query(input) {
          ensureOriginalReady();
          const proofQuery = input.text.startsWith("select current_setting('default_transaction_read_only')");
          const originalQuery = input.text === hotfixProofQuery;
          const step = proofQuery ? "policy_proof" : originalQuery ? "original_sql" : input.text === "set default_transaction_read_only=on" ? "policy_default_readonly"
            : input.text.startsWith("set statement_timeout=") ? "policy_limits" : input.text === "rollback;reset all" ? "cleanup" : "unexpected_sql";
          if (step === "unexpected_sql") fail("ORIGINAL_HELPER_UNEXPECTED_SQL");
          phase.stage = step; phase.pendingStep = step; phase.timeline ??= [];
          const trace = { step, wallStartedAt: new Date().toISOString(), status: "failed" };
          phase.timeline.push(trace);
          const time = performance.now();
          try {
          if (proofQuery) {
            // Only add an observation column to the existing policy proof.
            const answer = await reproduction.query({ ...input, text: input.text + ",pg_backend_pid() as diagnostic_pid" });
            ensureBudget();
            phase.backendProofMs = Math.round(performance.now() - time);
            const row = answer.rows?.[0];
            if (!Number.isSafeInteger(row?.diagnostic_pid) || row.diagnostic_pid <= 0) fail("ORIGINAL_BACKEND_PID_NOT_PROVEN");
            phase.proofBackendPid = row.diagnostic_pid;
            const setting = value => typeof value === "string" && /^(?:on|off|\d+(?:ms|s|min|h))$/.test(value) ? value : "other";
            phase.proofSettings = { defaultReadOnly: setting(row?.read_only), statementTimeout: setting(row?.statement_timeout), lockTimeout: setting(row?.lock_timeout), jit: setting(row?.jit) };
            trace.status = "passed"; return answer;
          }
          if (originalQuery) {
            phase.stage = "original_sql"; phase.originalSqlInvocations++;
            phase.originalWallStartedAt = new Date().toISOString();
            try { const answer = await reproduction.query(input); ensureBudget(); trace.status = "passed"; return answer; }
            finally { phase.originalWallMs = Math.round(performance.now() - time); phase.originalWallEndedAt = new Date().toISOString(); }
          }
          const answer = await reproduction.query(input); ensureBudget(); trace.status = "passed"; return answer;
          } catch (error) {
            trace.errorClass = diagnosticError(error); trace.cancelReason = cancelReason(error);
            phase.cancelReason ??= trace.cancelReason; phase.failureStep ??= step; throw error;
          }
          finally { trace.wallMs = Math.round(performance.now() - time); trace.wallEndedAt = new Date().toISOString(); phase.pendingStep = null; }
        }
        async end() { await close(reproduction); }
      }
      const pending = sessionReadQuery(hotfixProofQuery, { ...env, RELEASE_READ_TRANSPORT: "session-pooler" }, originalRequest, OriginalClient)
        .then(rows => { combined = rows[0]; settled = true; }, error => { failure = error; settled = true; });
      // Spread bounded samples across backend acquisition and the entire old
      // 70s client deadline. Repeated observation prevents observer idle expiry.
      for (let count = 0; count < 35 && !settled && !unsafeObserver && !totalExpired; count++) {
        await observe(phase, phase.proofBackendPid, true);
        if (!settled) await Promise.race([pending, new Promise(resolve => setTimeout(resolve, 5000))]);
      }
      await pending;
      phase.wallMs = Math.round(performance.now() - began); phase.wallEndedAt = new Date().toISOString();
      if (failure) { phase.errorClass = diagnosticError(failure); phase.cancelReason ??= cancelReason(failure); phase.serverStopProven = Boolean(sqlState(failure)); }
      else {
        phase.serverStopProven = true;
        if (phase.originalSqlInvocations === 1) phase.status = "passed";
        try { assertInstalledHotfix(combined); hotfixRepairActions(combined, "production"); report.checks.combinedCanonical = true; }
        catch { report.checks.combinedCanonical = false; }
        report.checks.combinedMatchesSplit = isDeepStrictEqual(split, combined);
      }
      await observe(phase, phase.proofBackendPid, true);
      if (phase.status === "passed" && Object.values(report.checks).every(value => value === true) && report.observerAvailable && !unsafeObserver && !totalExpired) report.status = "passed";
    }
  } catch (error) { report.errorClass = diagnosticError(error); }
  finally {
    // Optional aggregate metadata comes after every history phase. It must
    // never consume the observer before the queries it is meant to observe.
    report.capacityStage = "after_history_reads";
    const unsafeHistorySql = unsafeReader || report.phases.some(phase => phase.name === "combined_original" && phase.failureStep && !phase.serverStopProven);
    if (observer && report.observerAvailable && !unsafeObserver && !unsafeHistorySql && !totalExpired) {
      try {
        ensureBudget();
        const capacityAnswer = await observer.query({ text: CAPACITY_SQL, query_timeout: 3000 });
        ensureBudget();
        const capacity = rowsOf(capacityAnswer).flatMap(result => result.rows).find(row => row.diagnostic_capacity)?.diagnostic_capacity;
        const keys = ["maxConnections", "reservedConnections", "superuserReservedConnections", "databaseConnectionLimit", "roleConnectionLimit", "totalBackends", "activeBackends", "idleBackends", "idleInTransactionBackends", "clientBackends", "clientBackendsCurrentDatabase", "clientBackendsCurrentRole", "clientBackendsActive", "clientBackendsIdle", "clientBackendsIdleInTransaction", "walSenderBackends", "otherBackendProcesses"];
        if (!capacity || keys.some(key => capacity[key] !== null && (!/^-?\d+$/.test(String(capacity[key])) || !Number.isSafeInteger(Number(capacity[key]))))) fail("CAPACITY_INVALID_RESULT");
        report.capacity = Object.fromEntries(keys.map(key => [key, capacity[key] === null ? null : Number(capacity[key])]));
      } catch (error) {
        report.capacity = { unavailable: diagnosticError(error) };
        // A real PostgreSQL error proves completion. A client/network timeout
        // does not: close directly and never queue cleanup behind that query.
        if (!sqlState(error) && error?.message !== "HISTORY_DIAGNOSIS_CAPACITY_INVALID_RESULT") {
          unsafeObserver = true; report.observerAvailable = false; await close(observer);
        }
      }
    } else report.capacity = { unavailable: totalExpired ? "HISTORY_DIAGNOSIS_TOTAL_DEADLINE_EXPIRED"
      : unsafeHistorySql ? "HISTORY_DIAGNOSIS_UNCONFIRMED_HISTORY_COMPLETION" : "HISTORY_DIAGNOSIS_OBSERVER_UNAVAILABLE" };
    for (const [client, unsafe] of [[reader, unsafeReader], [observer, unsafeObserver]]) {
      if (client && !unsafe && !totalExpired) try { ensureBudget(); await client.query({ text: "rollback;reset all", query_timeout: 3000 }); } catch { /* Socket close remains mandatory. */ }
      await close(client);
    }
    await close(reproduction);
    clearTimeout(totalTimer);
    if (totalExpired) { report.status = "failed"; report.errorClass ??= "HISTORY_DIAGNOSIS_TOTAL_DEADLINE_EXPIRED"; }
    report.totalMs = Math.round(performance.now() - started);
    report.totalExpired = totalExpired;
    if (report.clientHost) report.clientHost.final = clientHostSample();
  }
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const report = await runHistoryDiagnosis();
  const directory = join(process.env.RUNNER_TEMP ?? "/tmp", "startregie-history-diagnosis");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
  if (report.status !== "passed") process.exitCode = 1;
}
