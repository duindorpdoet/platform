import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { rootCertificates } from "node:tls";
import { diagnosticPlan, validateDiagnosticProject } from "./production-db-diagnostics.mjs";

const fail = code => { throw new Error(`POOLER_CONNECT_ONLY_${code}`); };
const caUrl = new URL("./supabase-root-2021.crt", import.meta.url);
// Supavisor v2.9.13 lib/supavisor/error.ex: only the fixed (CODE) prefix
// leaves this process. Its explanatory suffix may contain private information.
const prefixes = Object.freeze({ ECIRCUITBREAKER: "POOL_CIRCUIT_BREAKER", EMAXCONNSESSION: "POOL_SESSION_CLIENT_LIMIT",
  EMAXCONN: "POOL_CLIENT_LIMIT", ECHECKOUTTIMEOUT: "POOL_CHECKOUT_TIMEOUT", EAUTHQUERY: "POOL_AUTH_QUERY",
  EAUTHSECRETS: "POOL_AUTH_SECRETS", ENOTFOUND: "POOL_TENANT_OR_USER_NOT_FOUND", EPOOLCHECKOUT: "POOL_CHECKOUT_FAILED" });
// Official v2.7.4 client_handler.ex messages, plus the documented legacy
// circuit-breaker prefix. Only fixed enum names are retained, never suffixes.
const legacyPrefixes = [
  [/^Circuit breaker open(?::|$)/, "LEGACY_CIRCUIT_BREAKER", "POOL_CIRCUIT_BREAKER"],
  [/^MaxClientsInSessionMode: max clients reached - in Session mode max clients are limited to pool_size$/, "LEGACY_SESSION_CLIENT_LIMIT", "POOL_SESSION_CLIENT_LIMIT"],
  [/^Max client connections reached$/, "LEGACY_CLIENT_LIMIT", "POOL_CLIENT_LIMIT"],
  [/^Unable to check out process from the pool due to timeout$/, "LEGACY_CHECKOUT_TIMEOUT", "POOL_CHECKOUT_TIMEOUT"],
  [/^Tenant or user not found$/, "LEGACY_TENANT_OR_USER_NOT_FOUND", "POOL_TENANT_OR_USER_NOT_FOUND"],
  [/^Authentication error, reason: /, "LEGACY_AUTH", "POOL_AUTH_ERROR"],
  [/^Address not in tenant allow_list: /, "LEGACY_ADDRESS_DENIED", "POOL_ADDRESS_DENIED"],
  [/^SSL connection is required$/, "LEGACY_TLS_REQUIRED", "POOL_TLS_REQUIRED"],
  [/^DbHandler exited$/, "LEGACY_UPSTREAM_EXITED", "POOL_UPSTREAM_EXITED"],
];
const sqlState = value => typeof value === "string" && /^[A-Z0-9]{5}$/.test(value) && /[0-9]/.test(value) ? value : null;

/** Error messages are consumed privately; only predefined fields are returned. */
export function connectError(error, libpq = false) {
  const raw = typeof error === "string" ? error : typeof error?.message === "string" ? error.message : "";
  // libpq adds its own connection context before the server's FATAL message.
  // Never retain that context, host/address, message, detail, hint or SCRAM data.
  const fatal = libpq ? raw.match(/(?:^|\n)[^\n]*?FATAL:\s*(?:([A-Z0-9]{5}):\s*)?([^\r\n]*)/) : null;
  const message = libpq ? fatal?.[2] ?? "" : raw;
  const prefix = message.match(/^\(([A-Z]+)\)(?: |$)/)?.[1];
  const known = prefix && Object.hasOwn(prefixes, prefix) ? prefix : null;
  const legacy = legacyPrefixes.find(([pattern]) => pattern.test(message));
  const state = sqlState(error?.code) ?? sqlState(fatal?.[1]);
  let errorClass = known ? prefixes[known] : legacy ? legacy[2] : state || fatal ? "SERVER_ERROR" : "UNKNOWN";
  if (!known && !legacy && !state && !fatal) {
    if (error?.name === "TimeoutError" || /timeout|timed out/i.test(raw)) errorClass = "CLIENT_TIMEOUT";
    else if (/certificate|SSL|TLS/i.test(raw)) errorClass = "TLS";
    else if (["ENOTFOUND", "EAI_AGAIN"].includes(error?.code) || /could not translate host name|name resolution|name or service not known/i.test(raw)) errorClass = "DNS";
    else if (["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "ENETUNREACH", "EHOSTUNREACH", "EPIPE"].includes(error?.code)) errorClass = "CONNECTION_FAILED";
  }
  return { sqlState: state, errorClass, prefix: known ?? legacy?.[1] ?? null };
}

/** pg8.21.1 event semantics; callbacks never retain protocol payloads. */
function trace(client, events) {
  const connection = client.connection;
  if (!connection?.once || !connection?.stream?.once) return;
  const began = performance.now(), seen = new Set(), streams = new WeakSet();
  const record = event => {
    if (!seen.has(event)) { seen.add(event); events.push({ event, at: new Date().toISOString(), elapsedMs: Math.round((performance.now() - began) * 1000) / 1000 }); }
  };
  function stream(socket, secure) {
    if (!socket?.once || streams.has(socket)) return;
    streams.add(socket);
    if (secure) socket.once("secureConnect", () => record(socket.authorized === true ? "TLS_ESTABLISHED_VERIFIED" : "TLS_ESTABLISHED_UNVERIFIED"));
    else { socket.once("lookup", error => record(error ? "DNS_LOOKUP_FAILED" : "DNS_LOOKUP_COMPLETED")); socket.once("connect", () => record("TCP_CONNECTED")); }
    socket.once("end", () => record(secure ? "TLS_STREAM_END" : "TCP_STREAM_END"));
    socket.once("close", () => record(secure ? "TLS_STREAM_CLOSE" : "TCP_STREAM_CLOSE"));
  }
  stream(connection.stream, false);
  connection.once("sslconnect", () => { record("TLS_SOCKET_CREATED"); stream(connection.stream, true); });
  for (const [method, event] of [["requestSsl", "POSTGRES_SSL_REQUEST_LOCAL_QUEUED"], ["startup", "POSTGRES_STARTUP_LOCAL_QUEUED"], ["sendSCRAMClientFinalMessage", "SCRAM_CLIENT_FINAL_LOCAL_QUEUED"]]) {
    const original = connection[method];
    if (typeof original === "function") connection[method] = function (...args) {
      const writable = this.stream?.writable === true;
      const answer = Reflect.apply(original, this, args);
      record(writable ? event : event.replace("QUEUED", "NOT_WRITABLE"));
      return answer;
    };
  }
  for (const [event, fixed] of [["authenticationCleartextPassword", "AUTH_CLEARTEXT_CHALLENGE"], ["authenticationMD5Password", "AUTH_MD5_CHALLENGE"],
    ["authenticationSASL", "AUTH_SASL_CHALLENGE"], ["authenticationSASLContinue", "AUTH_SASL_CONTINUE"],
    ["authenticationSASLFinal", "AUTH_SASL_FINAL_RECEIVED"], ["authenticationOk", "AUTH_OK_RECEIVED"], ["backendKeyData", "BACKEND_KEY_RECEIVED"], ["readyForQuery", "READY_FOR_QUERY"]]) connection.once(event, () => record(fixed));
  connection.once("error", () => record("CONNECTION_ERROR"));
  connection.once("errorMessage", () => record("POSTGRES_ERROR"));
}

function capture(args, environment, timeoutMs) {
  return new Promise(resolve => {
    let stderr = "", expired = false, settled = false;
    const child = spawn("docker", args, { env: { PATH: process.env.PATH, HOME: process.env.HOME, ...environment }, stdio: ["ignore", "ignore", "pipe"] });
    const finish = value => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
    const timer = setTimeout(() => { expired = true; child.kill(); finish({ code: null, expired: true, stderr: "" }); }, timeoutMs);
    child.stderr.on("data", chunk => { if (stderr.length < 16_384) stderr = (stderr + chunk.toString()).slice(0, 16_384); });
    child.once("error", () => finish({ code: null, expired: false, stderr: "", unavailable: true }));
    child.once("close", code => finish({ code, expired, stderr }));
  });
}

/** Two independent connection clients, once each. Neither sends any SQL. */
export async function runConnectOnlyDiagnostics(env, project, poolers, ClientOverride, execute = capture, endpointMode = "pooler") {
  if (env.DIAGNOSTIC_NATIVE_CONNECT_ONLY !== "true") fail("EXPLICIT_FLAG_REQUIRED");
  let plan;
  if (endpointMode === "direct" && env.DIAGNOSTIC_DIRECT_CAPABILITY === "true") {
    const { image } = validateDiagnosticProject(env, project);
    plan = { image, environment: { PGHOST: project.database.host, PGPORT: "5432", PGDATABASE: "postgres", PGUSER: "postgres", PGPASSWORD: env.SUPABASE_DB_PASSWORD } };
  } else if (endpointMode === "pooler" && env.DIAGNOSTIC_DIRECT_CAPABILITY !== "true") plan = diagnosticPlan(env, project, poolers);
  else fail("ENDPOINT_MODE_REQUIRED");
  const certificates = [...rootCertificates, readFileSync(caUrl, "utf8")];
  const report = { diagnostic: "production-connect-only", readOnly: true, sqlSent: false, changedRows: 0, messagesSent: 0,
    comparison: "INDEPENDENT_CLIENTS_NO_CAUSAL_INFERENCE", connectionPath: endpointMode === "direct" ? "direct" : "session-pooler", connectionLimitMs: 30000, probes: [] };
  // Prepare the existing exact Postgres image before starting either connection.
  let prepared;
  try { prepared = await execute(["pull", plan.image], {}, 120_000); } catch { fail("IMAGE_PREPARATION_FAILED"); }
  if (prepared.code !== 0 || prepared.expired) fail("IMAGE_PREPARATION_FAILED");
  let client, idleError;
  const native = { driver: "@supabase/pg8.21.1", connected: false, durationMs: null, sqlState: null, errorClass: null, prefix: null, events: [] };
  report.probes.push(native);
  let began = performance.now();
  try {
    const Client = ClientOverride ?? (await import("@supabase/pg")).Client;
    client = new Client({ host: plan.environment.PGHOST, port: 5432, database: "postgres", user: plan.environment.PGUSER,
      password: env.SUPABASE_DB_PASSWORD, application_name: "duindorp-release-readonly", connectionTimeoutMillis: 30000,
      ssl: { rejectUnauthorized: true, ca: certificates } });
    client.on("error", error => { idleError = error; });
    trace(client, native.events);
    await client.connect();
    native.connected = true;
    if (idleError) Object.assign(native, connectError(idleError));
  } catch (error) { Object.assign(native, connectError(error)); }
  finally {
    native.durationMs = Math.round(performance.now() - began);
    if (client) {
      let timer;
      try {
        await Promise.race([client.end(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("cleanup timeout")), 3000); })]);
      } catch (error) { native.cleanupErrorClass = connectError(error).errorClass; try { client.connection?.stream?.destroy(); } catch { /* Never expose close errors. */ } }
      finally { clearTimeout(timer); }
    }
  }
  const environment = { ...plan.environment, PGAPPNAME: "duindorp-release-readonly", PGCONNECT_TIMEOUT: "30", PGSSLMODE: "verify-full", PGSSLROOTCERT: "/run/duindorp-supabase-ca.crt" };
  // Match the normal native helper's startup packet: it has no GUC options.
  // No SQL is sent, so the activity probe's startup policy is unnecessary here.
  delete environment.PGOPTIONS;
  const libpq = { driver: "libpq/psql", connected: false, durationMs: null, sqlState: null, errorClass: null, prefix: null };
  report.probes.push(libpq);
  const container = `duindorp-connect-only-${randomUUID()}`;
  let directory, containerStarted = false, uncertainContainer = false;
  began = performance.now();
  try {
    directory = await mkdtemp(join(tmpdir(), "duindorp-connect-ca-"));
    const bundle = join(directory, "roots.crt");
    await writeFile(bundle, certificates.join("\n"), { mode: 0o600 });
    const args = ["run", "--rm", "--name", container, "--network", "host", "--mount", `type=bind,src=${bundle},dst=${environment.PGSSLROOTCERT},readonly`,
      ...Object.keys(environment).flatMap(name => ["--env", name]), "--entrypoint", "psql", plan.image, "-X", "-qAt", "-w", "-c", "\\q"];
    containerStarted = true;
    const result = await execute(args, environment, 30_000);
    uncertainContainer = result.expired || result.unavailable === true;
    libpq.connected = result.code === 0 && !result.expired && !result.unavailable;
    if (!libpq.connected) Object.assign(libpq, result.expired ? { errorClass: "CLIENT_TIMEOUT" } : result.unavailable ? { errorClass: "CLIENT_UNAVAILABLE" } : connectError(result.stderr, true));
  } catch { libpq.errorClass = "CLIENT_UNAVAILABLE"; uncertainContainer = containerStarted; }
  finally {
    libpq.durationMs = Math.round(performance.now() - began);
    // Killing the Docker CLI alone cannot prove that its container stopped.
    // Remove only this run's randomly named container after uncertain outcomes.
    if (uncertainContainer) try {
      const cleanup = await execute(["rm", "--force", container], {}, 5000);
      if (cleanup.code !== 0 || cleanup.expired || cleanup.unavailable) libpq.cleanupErrorClass = "LOCAL_CLEANUP_FAILED";
    } catch { libpq.cleanupErrorClass = "LOCAL_CLEANUP_FAILED"; }
    if (directory) try { await rm(directory, { recursive: true, force: true }); } catch { libpq.cleanupErrorClass = "LOCAL_CLEANUP_FAILED"; }
  }
  return report;
}
