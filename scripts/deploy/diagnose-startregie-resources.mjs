import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const PROJECT = "dtubngvxfbupgvgfrjko";
export const METRICS_ENDPOINT = `https://${PROJECT}.supabase.co/customer/v1/privileged/metrics`;
const MAX_BYTES = 2 * 1024 * 1024;
const fail = code => { throw new Error(`RESOURCE_DIAGNOSIS_${code}`); };
const errorClass = error => /^RESOURCE_DIAGNOSIS_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "RESOURCE_DIAGNOSIS_REQUEST_FAILED";
const MODES = ["resources-only", "resources-with-history"];
const CPU_MODES = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal", "guest", "guest_nice"];
const GAUGES = ["node_memory_MemAvailable_bytes", "node_memory_MemTotal_bytes", "node_memory_SwapFree_bytes", "node_memory_SwapTotal_bytes",
  "node_load1", "node_load5", "node_load15", "node_time_seconds", "node_boot_time_seconds", "process_start_time_seconds",
  "node_vmstat_pswpin", "node_vmstat_pswpout", "node_vmstat_oom_kill"];
const DISKS = ["node_disk_io_time_seconds_total", "node_disk_io_time_weighted_seconds_total", "node_disk_read_bytes_total", "node_disk_written_bytes_total",
  "node_disk_reads_completed_total", "node_disk_writes_completed_total", "node_disk_read_time_seconds_total", "node_disk_write_time_seconds_total", "node_disk_io_now"];
const FILESYSTEMS = ["node_filesystem_avail_bytes", "node_filesystem_size_bytes", "node_filesystem_free_bytes"];
const NAMES = new Set(["node_cpu_seconds_total", ...GAUGES, ...DISKS, ...FILESYSTEMS]);
const device = /^(?:nvme\d+n\d+(?:p\d+)?|[xsv]d[a-z]\d*|xvd[a-z]\d*|dm-\d+|md\d+)$/;
const mounts = new Set(["/", "/data", "/var/lib/postgresql", "/var/lib/postgresql/data", "/var/lib/postgresql/data/pgdata", "/home/postgres/pgdata"]);
const number = text => typeof text === "string" && /^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)
  && Number.isFinite(Number(text)) && Number(text) >= 0 && Number(text) <= Number.MAX_SAFE_INTEGER ? Number(text) : null;
const sameKeys = (a, b) => JSON.stringify(Object.keys(a).sort()) === JSON.stringify(Object.keys(b).sort());

function validateContext(env) {
  if (env.HISTORY_DIAGNOSTICS_REQUESTED !== "true" || !MODES.includes(env.HISTORY_DIAGNOSTIC_MODE)) fail("EXPLICIT_RESOURCE_MODE_REQUIRED");
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.GITHUB_REF !== "refs/heads/production"
    || env.APP_ENVIRONMENT !== "production" || env.SUPABASE_PROJECT_REF !== PROJECT || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
    || env.RUNNER_NAME !== "dg-sites-vps-01-duindorphalloweenprod-01"
    || !env.GITHUB_WORKSPACE?.startsWith("/srv/sites/duindorphalloweenprod/actions-runner/_work/")
    || !/^[A-Za-z0-9._-]{20,4096}$/.test(env.SUPABASE_SERVICE_ROLE_KEY ?? "")) fail("PRODUCTION_BOUNDARY");
  if (env.HISTORY_DIAGNOSTIC_MODE === "resources-with-history" && env.HISTORY_CONNECTION_PATH !== "direct-vps") fail("DIRECT_HISTORY_REQUIRED");
  if (env.HISTORY_DIAGNOSTIC_MODE === "resources-with-history" && (!env.SUPABASE_ACCESS_TOKEN || !env.SUPABASE_DB_PASSWORD)) fail("HISTORY_CREDENTIALS_REQUIRED");
}

// Source/auth: supabase.com/docs/guides/observability/metrics and the official
// supabase/supabase-grafana metrics.md. No query, database, table or user series.
export function parseResourceMetrics(text) {
  const cpu = {}, disks = {}, gauges = {}, filesystems = {}, seen = new Set();
  let acceptedSeries = 0, rejectedSeries = 0, sampleTimestampMinMs = null, sampleTimestampMaxMs = null;
  for (const line of text.split("\n")) {
    const name = line.match(/^([A-Za-z_:][A-Za-z0-9_:]*)/)?.[1];
    if (!NAMES.has(name)) continue;
    const match = line.length <= 4096 && line.match(/^[A-Za-z_:][A-Za-z0-9_:]*(?:\{([^{}]*)\})?\s+(\S+)(?:\s+(\d+))?\s*$/);
    if (!match) { rejectedSeries++; continue; }
    const labels = Object.create(null);
    let valid = true;
    for (const part of match[1] ? match[1].split(",") : []) {
      const label = part.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)="([^"\\]*)"\s*$/);
      if (!label || Object.hasOwn(labels, label[1])) { valid = false; break; }
      labels[label[1]] = label[2];
    }
    if (!valid || labels.supabase_project_ref !== PROJECT || labels.supabase_identifier !== PROJECT || labels.service_type !== "db") { rejectedSeries++; continue; }
    delete labels.supabase_project_ref; delete labels.supabase_identifier; delete labels.service_type;
    const value = number(match[2]), timestamp = match[3] === undefined ? null : number(match[3]);
    if (value === null || (match[3] !== undefined && timestamp === null)) { rejectedSeries++; continue; }
    let target, key;
    if (name === "node_cpu_seconds_total" && sameKeys(labels, { cpu: 0, mode: 0 }) && /^(?:0|[1-9]\d{0,2})$/.test(labels.cpu)
      && Number(labels.cpu) < 256 && CPU_MODES.includes(labels.mode)) {
      cpu[labels.cpu] ??= {}; target = cpu[labels.cpu]; key = labels.mode;
    } else if (GAUGES.includes(name) && Object.keys(labels).length === 0) { target = gauges; key = name; }
    else if (DISKS.includes(name) && sameKeys(labels, { device: 0 }) && device.test(labels.device)) {
      if (!Object.hasOwn(disks, labels.device) && Object.keys(disks).length >= 16) fail("TOO_MANY_DEVICES");
      disks[labels.device] ??= {}; target = disks[labels.device]; key = name;
    } else if (FILESYSTEMS.includes(name) && (sameKeys(labels, { device: 0, fstype: 0, mountpoint: 0 }) || sameKeys(labels, { device: 0, device_error: 0, fstype: 0, mountpoint: 0 }))
      && (labels.device === "/dev/root" || device.test(labels.device.replace(/^\/dev\//, ""))) && ["ext4", "xfs", "btrfs"].includes(labels.fstype)
      && mounts.has(labels.mountpoint) && (!Object.hasOwn(labels, "device_error") || labels.device_error === "")) {
      const identity = `${labels.device}:${labels.mountpoint}:${labels.fstype}`;
      if (!Object.hasOwn(filesystems, identity) && Object.keys(filesystems).length >= 16) fail("TOO_MANY_FILESYSTEMS");
      filesystems[identity] ??= {}; target = filesystems[identity]; key = name;
    } else { rejectedSeries++; continue; }
    const identity = `${name}:${JSON.stringify(Object.entries(labels).sort())}`;
    if (seen.has(identity)) fail("DUPLICATE_SERIES");
    seen.add(identity); target[key] = value; acceptedSeries++;
    if (timestamp !== null) { sampleTimestampMinMs = Math.min(sampleTimestampMinMs ?? timestamp, timestamp); sampleTimestampMaxMs = Math.max(sampleTimestampMaxMs ?? timestamp, timestamp); }
  }
  if (!acceptedSeries) fail("NO_ALLOWED_DATABASE_METRICS");
  const complete = Object.values(filesystems).filter(row => row.node_filesystem_size_bytes > 0 && Number.isFinite(row.node_filesystem_avail_bytes)
    && Number.isFinite(row.node_filesystem_free_bytes) && row.node_filesystem_avail_bytes <= row.node_filesystem_size_bytes && row.node_filesystem_free_bytes <= row.node_filesystem_size_bytes);
  return { acceptedSeries, rejectedSeries, cpu, disks, gauges, sampleTimestampMinMs, sampleTimestampMaxMs,
    filesystem: { completeSeriesCount: complete.length, minimumAvailableBytes: complete.length ? Math.min(...complete.map(row => row.node_filesystem_avail_bytes)) : null,
      minimumAvailableFraction: complete.length ? Math.min(...complete.map(row => row.node_filesystem_avail_bytes / row.node_filesystem_size_bytes)) : null,
      maximumSizeBytes: complete.length ? Math.max(...complete.map(row => row.node_filesystem_size_bytes)) : null } };
}

export function resourceRates(first, second) {
  const unavailable = reason => ({ status: "unavailable", reason });
  const localSeconds = (second.scrapeMidpointMs - first.scrapeMidpointMs) / 1000;
  if (!Number.isFinite(localSeconds) || localSeconds < 60) return { cpu: unavailable("INVALID_SAMPLE_INTERVAL"), disk: unavailable("INVALID_SAMPLE_INTERVAL") };
  const sourceStart = first.gauges.node_time_seconds, sourceEnd = second.gauges.node_time_seconds;
  const sourceAvailable = sourceStart !== undefined && sourceEnd !== undefined;
  if ((sourceAvailable && sourceEnd <= sourceStart) || (first.sampleTimestampMaxMs !== null && second.sampleTimestampMaxMs !== null && second.sampleTimestampMaxMs <= first.sampleTimestampMaxMs)
    || (first.gauges.node_boot_time_seconds !== undefined && second.gauges.node_boot_time_seconds !== undefined && first.gauges.node_boot_time_seconds !== second.gauges.node_boot_time_seconds)) {
    return { cpu: unavailable("STALE_SOURCE_OR_RESTART"), disk: unavailable("STALE_SOURCE_OR_RESTART") };
  }
  const seconds = sourceAvailable ? sourceEnd - sourceStart : localSeconds;
  if (!Number.isFinite(seconds) || seconds < 30 || seconds > localSeconds * 3) return { cpu: unavailable("INVALID_SOURCE_INTERVAL"), disk: unavailable("INVALID_SOURCE_INTERVAL") };
  const timing = { intervalSeconds: seconds, localIntervalSeconds: localSeconds, timeBasis: sourceAvailable ? "EXPORTER_CLOCK" : "LOCAL_SCRAPE_MIDPOINT",
    exporterClockAvailable: sourceAvailable, exporterRefresh: sourceAvailable ? "SOURCE_CLOCK_ADVANCED" : "PROVIDER_REFRESH_NOT_VERIFIED" };
  let cpu = unavailable("COUNTER_SET_CHANGED_OR_MISSING");
  if (Object.keys(first.cpu).length && sameKeys(first.cpu, second.cpu) && Object.keys(first.cpu).every(id => sameKeys(first.cpu[id], second.cpu[id]) && CPU_MODES.filter(mode => !["guest", "guest_nice"].includes(mode)).every(mode => first.cpu[id][mode] !== undefined))) {
    const deltas = Object.fromEntries(CPU_MODES.filter(mode => !["guest", "guest_nice"].includes(mode)).map(mode => [mode, 0]));
    let reset = false;
    for (const id of Object.keys(first.cpu)) for (const [mode, value] of Object.entries(first.cpu[id])) {
      const delta = second.cpu[id][mode] - value;
      if (!Number.isFinite(delta) || delta < 0) reset = true;
      if (Object.hasOwn(deltas, mode)) deltas[mode] += delta;
    }
    const total = Object.values(deltas).reduce((sum, value) => sum + value, 0);
    if (reset || !Number.isFinite(total)) cpu = unavailable("COUNTER_RESET_OR_INVALID");
    else if (total <= 0) cpu = unavailable("COUNTERS_DID_NOT_ADVANCE");
    else cpu = { status: "available", ...timing, cpuCount: Object.keys(first.cpu).length, counterCoveredSecondsPerCpu: total / Object.keys(first.cpu).length,
      executionFraction: (deltas.user + deltas.nice + deltas.system + deltas.irq + deltas.softirq) / total,
      idleFraction: deltas.idle / total, ioWaitFraction: deltas.iowait / total, stealFraction: deltas.steal / total,
      counterTimeShareByMode: Object.fromEntries(Object.entries(deltas).map(([mode, value]) => [mode, value / total])),
      rateStatus: sourceAvailable ? "SOURCE_CLOCK_RATE" : "COUNTER_TIME_SHARES_ONLY_NO_SOURCE_CLOCK",
      ...(sourceAvailable ? { secondsPerSecondByMode: Object.fromEntries(Object.entries(deltas).map(([mode, value]) => [mode, value / seconds])) } : {}) };
  }
  let disk = unavailable("COUNTER_SET_CHANGED_OR_MISSING");
  if (Object.keys(first.disks).length && sameKeys(first.disks, second.disks) && Object.keys(first.disks).every(id => sameKeys(first.disks[id], second.disks[id]) && first.disks[id].node_disk_io_time_seconds_total !== undefined)) {
    const perDevice = {}, counterDeltas = {}; let reset = false;
    for (const id of Object.keys(first.disks)) {
      perDevice[id] = {}; counterDeltas[id] = {};
      for (const [name, value] of Object.entries(first.disks[id])) {
        if (name === "node_disk_io_now") continue;
        const delta = second.disks[id][name] - value;
        if (!Number.isFinite(delta) || delta < 0) reset = true;
        counterDeltas[id][name] = delta; perDevice[id][name] = delta / seconds;
      }
    }
    disk = reset ? unavailable("COUNTER_RESET_OR_INVALID") : { status: "available", ...timing, deviceCount: Object.keys(perDevice).length,
      counterDeltaByDevice: counterDeltas, ...(sourceAvailable ? { perDevicePerSecond: perDevice } : { approximatePerDevicePerObservedSecond: perDevice }) };
  }
  return { cpu, disk };
}

async function boundedBody(response, signal) {
  if (!response.body) fail("EMPTY_RESPONSE");
  const reader = response.body.getReader(), chunks = []; let size = 0;
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      if (signal.aborted) fail("REQUEST_TIMEOUT");
      const { done, value } = await reader.read();
      if (signal.aborted) fail("REQUEST_TIMEOUT");
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) fail("RESPONSE_TOO_LARGE");
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks).toString("utf8");
  } catch (error) { void reader.cancel().catch(() => {}); throw error; }
  finally { signal.removeEventListener("abort", abort); reader.releaseLock(); }
}

/** Exactly two deliberate metrics reads. No native client, SQL or metadata API. */
export async function runResourceDiagnosis(env = process.env, request = fetch, onFirstSnapshot = () => {}) {
  const report = { diagnostic: "startregie-resources", mode: MODES.includes(env.HISTORY_DIAGNOSTIC_MODE) ? env.HISTORY_DIAGNOSTIC_MODE : null,
    revision: /^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "") ? env.GITHUB_SHA : null, status: "failed", readOnly: true, changedRows: 0,
    nativeConnectionsStarted: 0, sqlStatementsStarted: 0, limits: { snapshots: 2, separationMs: 60000, requestMs: 15000, totalMs: 100000, responseBytes: MAX_BYTES },
    snapshots: [], requests: [], creditMetrics: "NOT_EXPOSED_BY_DOCUMENTED_ALLOWLIST", inference: "RESOURCE_OBSERVATION_ONLY_NO_THROTTLING_CAUSALITY_CLAIM" };
  const started = performance.now(), budget = new AbortController();
  const totalTimer = setTimeout(() => budget.abort(), 100000);
  try {
    validateContext(env);
    for (let index = 0; index < 2; index++) {
      if (budget.signal.aborted) fail("TOTAL_DEADLINE_EXPIRED");
      const controller = new AbortController(), signal = AbortSignal.any([controller.signal, budget.signal]);
      const entry = { index: index + 1, startedAt: new Date().toISOString(), status: "failed", wallMs: null };
      report.requests.push(entry);
      const before = performance.now(); let timer;
      try {
        const pending = (async () => {
          const response = await request(METRICS_ENDPOINT, { method: "GET", redirect: "error", credentials: "omit", cache: "no-store", signal,
            headers: { Authorization: `Basic ${Buffer.from(`service_role:${env.SUPABASE_SERVICE_ROLE_KEY}`).toString("base64")}`, Accept: "text/plain" } });
          if (signal.aborted) fail("REQUEST_TIMEOUT");
          entry.httpStatus = response.status;
          if (!response.ok) { void response.body?.cancel().catch(() => {}); fail(`HTTP_${response.status}`); }
          const body = await boundedBody(response, signal);
          if (signal.aborted) fail("REQUEST_TIMEOUT");
          return parseResourceMetrics(body);
        })();
        const timeout = new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error("RESOURCE_DIAGNOSIS_REQUEST_TIMEOUT")); }, 15000); });
        const values = await Promise.race([pending, timeout]);
        const after = performance.now();
        const snapshot = { index: index + 1, observedAt: new Date().toISOString(), scrapeMidpointMs: (before + after) / 2, ...values };
        report.snapshots.push(snapshot); entry.status = "passed";
        if (index === 0) onFirstSnapshot();
      } finally { clearTimeout(timer); entry.wallMs = Math.round(performance.now() - before); }
      if (index === 0) await new Promise((resolve, reject) => {
        const finish = () => { clearTimeout(wait); budget.signal.removeEventListener("abort", abort); };
        const abort = () => { finish(); reject(new Error("RESOURCE_DIAGNOSIS_TOTAL_DEADLINE_EXPIRED")); };
        const wait = setTimeout(() => { finish(); resolve(); }, 60000);
        budget.signal.addEventListener("abort", abort, { once: true });
        if (budget.signal.aborted) abort();
      });
    }
    report.rates = resourceRates(report.snapshots[0], report.snapshots[1]);
    report.status = "passed";
  } catch (error) { report.errorClass = budget.signal.aborted ? "RESOURCE_DIAGNOSIS_TOTAL_DEADLINE_EXPIRED" : errorClass(error); }
  finally { clearTimeout(totalTimer); report.totalMs = Math.round(performance.now() - started); }
  return report;
}

/** History starts only after a successful resource baseline; both are awaited. */
export async function runResourceMode(env = process.env, request = fetch, historyRunner) {
  if (env.HISTORY_DIAGNOSTIC_MODE !== "resources-with-history") return runResourceDiagnosis(env, request);
  let announce;
  const firstReady = new Promise(resolve => { announce = resolve; });
  const resourcesPending = runResourceDiagnosis(env, request, () => announce(true)).then(report => { announce(false); return report; });
  const ready = await firstReady;
  const historyPending = ready ? (async () => {
    const run = historyRunner ?? (await import("./diagnose-startregie-history.mjs")).runHistoryDiagnosis;
    return run(env);
  })() : Promise.resolve({ status: "skipped", reason: "INITIAL_RESOURCE_SNAPSHOT_NOT_AVAILABLE", nativeConnectionsStarted: 0 });
  const [resources, history] = await Promise.allSettled([resourcesPending, historyPending]);
  const resourceReport = resources.status === "fulfilled" ? resources.value : { status: "failed", errorClass: "RESOURCE_DIAGNOSIS_UNEXPECTED_FAILURE" };
  const historyReport = history.status === "fulfilled" ? history.value : { status: "failed", errorClass: "HISTORY_DIAGNOSIS_UNAVAILABLE" };
  return { diagnostic: "startregie-resources-with-history", mode: "resources-with-history", readOnly: true, changedRows: 0,
    status: resourceReport.status === "passed" && historyReport.status === "passed" ? "passed" : "failed", resources: resourceReport, history: historyReport };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const report = await runResourceMode();
  const directory = join(process.env.RUNNER_TEMP ?? "/tmp", "startregie-resource-diagnosis");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  console.log(JSON.stringify(report));
  if (report.status !== "passed") process.exitCode = 1;
}
