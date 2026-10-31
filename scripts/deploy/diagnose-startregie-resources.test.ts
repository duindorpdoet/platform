import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { METRICS_ENDPOINT, parseResourceMetrics, resourceRates, runResourceDiagnosis, runResourceMode } from "./diagnose-startregie-resources.mjs";

const project = "dtubngvxfbupgvgfrjko";
const env = { HISTORY_DIAGNOSTICS_REQUESTED: "true", HISTORY_DIAGNOSTIC_MODE: "resources-only", HISTORY_CONNECTION_PATH: "direct-vps",
  APP_ENVIRONMENT: "production", GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production",
  GITHUB_SHA: "a".repeat(40), SUPABASE_PROJECT_REF: project, SUPABASE_SERVICE_ROLE_KEY: "PRIVATE_EXISTING_SERVICE_ROLE_KEY",
  RUNNER_NAME: "dg-sites-vps-01-duindorphalloweenprod-01", GITHUB_WORKSPACE: "/srv/sites/duindorphalloweenprod/actions-runner/_work/platform/platform" };
const combinedEnv = { ...env, HISTORY_DIAGNOSTIC_MODE: "resources-with-history", SUPABASE_ACCESS_TOKEN: "PRIVATE_ACCESS_TOKEN", SUPABASE_DB_PASSWORD: "PRIVATE_DB_PASSWORD" };
const common = `supabase_project_ref="${project}",supabase_identifier="${project}",service_type="db"`;
const metric = (name: string, value: number | string, labels = "", timestamp = "") => `${name}{${common}${labels ? `,${labels}` : ""}} ${value}${timestamp ? ` ${timestamp}` : ""}`;
function body(second = false, sourceClock = false) {
  const cpu = { user: second ? 110 : 100, system: second ? 55 : 50, idle: second ? 840 : 800, iowait: second ? 24 : 20,
    steal: second ? 6 : 5, nice: 0, irq: 0, softirq: 0, guest: second ? 1000000 : 10, guest_nice: 0 };
  return [...Object.entries(cpu).map(([mode, value]) => metric("node_cpu_seconds_total", value, `cpu="0",mode="${mode}"`)),
    metric("node_memory_MemAvailable_bytes", second ? 128 : 256), metric("node_memory_MemTotal_bytes", 1024),
    metric("node_memory_SwapFree_bytes", 128), metric("node_memory_SwapTotal_bytes", 256), metric("node_load1", 1.2), metric("node_load5", 0.8), metric("node_load15", 0.5),
    metric("node_disk_io_time_seconds_total", second ? 145 : 100, 'device="nvme1n1"'),
    metric("node_disk_read_bytes_total", second ? 7000 : 1000, 'device="nvme1n1"'), metric("node_disk_reads_completed_total", second ? 160 : 100, 'device="nvme1n1"'),
    metric("node_filesystem_size_bytes", 10000, 'device="/dev/nvme1n1",device_error="",fstype="ext4",mountpoint="/data"'),
    metric("node_filesystem_avail_bytes", 4000, 'device="/dev/nvme1n1",device_error="",fstype="ext4",mountpoint="/data"'),
    metric("node_filesystem_free_bytes", 5000, 'device="/dev/nvme1n1",device_error="",fstype="ext4",mountpoint="/data"'),
    ...(sourceClock ? [metric("node_time_seconds", second ? 1800000060 : 1800000000), metric("node_boot_time_seconds", 1700000000)] : []),
    '# HELP PRIVATE_QUERY "select PRIVATE_TOKEN"', 'pg_stat_statements_calls{query="PRIVATE_SQL",user="PRIVATE_USER",table="PRIVATE_TABLE"} 999',
    metric("node_cpu_seconds_total", 7, 'cpu="PRIVATE_CPU",mode="idle"'), metric("node_load1", 99, 'email="PRIVATE_EMAIL"'),
    metric("node_disk_info", 1, 'serial="PRIVATE_SERIAL"'), 'node_aws_io_credit_balance{account="PRIVATE_ACCOUNT"} 123'].join("\n");
}
const snapshot = (second = false, sourceClock = false) => ({ ...parseResourceMetrics(body(second, sourceClock)), scrapeMidpointMs: second ? 60000 : 0 });
const timers = () => vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date", "performance"] });
afterEach(() => vi.useRealTimers());

describe("bounded resource-only diagnosis", () => {
  it("keeps only fixed database system metrics and numeric safe aggregates", () => {
    const parsed = parseResourceMetrics(body());
    expect(parsed.cpu["0"]).toMatchObject({ user: 100, idle: 800 });
    expect(parsed.gauges.node_memory_MemAvailable_bytes).toBe(256);
    expect(parsed.filesystem).toEqual({ completeSeriesCount: 1, minimumAvailableBytes: 4000, minimumAvailableFraction: 0.4, maximumSizeBytes: 10000 });
    expect(parsed.disks).toHaveProperty("nvme1n1");
    expect(JSON.stringify(parsed)).not.toContain("PRIVATE");
    expect(JSON.stringify(parsed)).not.toContain("/data");
    expect(parsed.rejectedSeries).toBeGreaterThan(0);
  });
  it.each(["service_type=\"auth\"", `supabase_project_ref="${"x".repeat(20)}"`, `supabase_identifier="${project}-replica"`])("rejects another service or project identity: %s", replacement => {
    const original = replacement.startsWith("service_type") ? 'service_type="db"' : replacement.startsWith("supabase_project_ref") ? `supabase_project_ref="${project}"` : `supabase_identifier="${project}"`;
    expect(() => parseResourceMetrics(body().replaceAll(original, replacement))).toThrow("NO_ALLOWED_DATABASE_METRICS");
  });
  it("rejects non-finite and unsafe values, unexpected labels, devices and mounts without echoing them", () => {
    for (const value of ["NaN", "+Inf", "-1", "9007199254740992", "1e309"]) expect(() => parseResourceMetrics(metric("node_load1", value))).toThrow("NO_ALLOWED_DATABASE_METRICS");
    const parsed = parseResourceMetrics([body(), metric("node_load15", 99, '__proto__="PRIVATE_PROTO"'),
      metric("node_disk_io_time_seconds_total", 1, 'device="PRIVATE_DEVICE"'),
      metric("node_filesystem_size_bytes", 1, 'device="/dev/nvme1n1",fstype="ext4",mountpoint="/PRIVATE_ACCOUNT"')].join("\n"));
    expect(parsed.gauges.node_load15).toBe(0.5); expect(JSON.stringify(parsed)).not.toContain("PRIVATE");
    expect(() => parseResourceMetrics(`${body()}\n${metric("node_load1", 3)}`)).toThrow("DUPLICATE_SERIES");
  });
  it("derives CPU time shares without double-counting guests and labels IO wall-time estimates", () => {
    const rates = resourceRates(snapshot(), snapshot(true));
    expect(rates.cpu).toMatchObject({ status: "available", executionFraction: 0.25, idleFraction: 2 / 3, ioWaitFraction: 1 / 15, stealFraction: 1 / 60,
      counterCoveredSecondsPerCpu: 60, rateStatus: "COUNTER_TIME_SHARES_ONLY_NO_SOURCE_CLOCK", exporterRefresh: "PROVIDER_REFRESH_NOT_VERIFIED" });
    expect(rates.cpu).not.toHaveProperty("secondsPerSecondByMode");
    expect(rates.disk).toMatchObject({ status: "available", counterDeltaByDevice: { nvme1n1: { node_disk_read_bytes_total: 6000 } },
      approximatePerDevicePerObservedSecond: { nvme1n1: { node_disk_read_bytes_total: 100 } } });
    expect(rates.disk).not.toHaveProperty("perDevicePerSecond");
  });
  it("uses source-clock rates only when an exposed source clock advanced", () => {
    const rates = resourceRates(snapshot(false, true), snapshot(true, true));
    expect(rates.cpu).toMatchObject({ rateStatus: "SOURCE_CLOCK_RATE", timeBasis: "EXPORTER_CLOCK", secondsPerSecondByMode: { user: 1 / 6 } });
    expect(rates.disk).toHaveProperty("perDevicePerSecond");
  });
  it("makes resets, changed counter sets, stale source timestamps and invalid intervals unavailable", () => {
    const first = snapshot(false, true);
    const reset = snapshot(true, true); reset.cpu["0"].idle = 1;
    expect(resourceRates(first, reset).cpu).toMatchObject({ status: "unavailable", reason: "COUNTER_RESET_OR_INVALID" });
    const missing = snapshot(true, true); delete missing.cpu["0"].user;
    expect(resourceRates(first, missing).cpu.status).toBe("unavailable");
    const stale = snapshot(true, true); stale.gauges.node_time_seconds = first.gauges.node_time_seconds;
    expect(resourceRates(first, stale).cpu).toMatchObject({ reason: "STALE_SOURCE_OR_RESTART" });
    const stamp = snapshot(true); stamp.sampleTimestampMaxMs = 100; const old = snapshot(); old.sampleTimestampMaxMs = 100;
    expect(resourceRates(old, stamp).disk.status).toBe("unavailable");
    expect(resourceRates(snapshot(), { ...snapshot(true), scrapeMidpointMs: 1 }).cpu.status).toBe("unavailable");
    expect(resourceRates(snapshot(), { ...snapshot(), scrapeMidpointMs: 60000 }).cpu).toMatchObject({ reason: "COUNTERS_DID_NOT_ADVANCE" });
    const diskReset = snapshot(true); diskReset.disks.nvme1n1.node_disk_read_bytes_total = 1;
    expect(resourceRates(snapshot(), diskReset).disk).toMatchObject({ reason: "COUNTER_RESET_OR_INVALID" });
  });
  it("does not turn missing CPU wait/steal modes or missing disk counters into healthy zero rates", () => {
    for (const mode of ["iowait", "steal"]) {
      const first = snapshot(), second = snapshot(true); delete first.cpu["0"][mode]; delete second.cpu["0"][mode];
      expect(resourceRates(first, second).cpu).toMatchObject({ status: "unavailable", reason: "COUNTER_SET_CHANGED_OR_MISSING" });
    }
    const first = { ...snapshot(), disks: { nvme1n1: { node_disk_io_now: 1 } } }, second = { ...snapshot(true), disks: { nvme1n1: { node_disk_io_now: 2 } } };
    expect(resourceRates(first, second).disk).toMatchObject({ status: "unavailable", reason: "COUNTER_SET_CHANGED_OR_MISSING" });
  });
  it("sends exactly two fixed Basic-auth GETs at least sixty seconds apart and never starts history", async () => {
    timers(); const started: number[] = [];
    const request = vi.fn<typeof fetch>(async () => { started.push(performance.now()); return new Response(body(started.length === 2)); });
    const history = vi.fn(async () => ({ status: "passed" }));
    const pending = runResourceMode(env, request, history);
    await vi.advanceTimersByTimeAsync(60000);
    const report = await pending;
    expect(report.status).toBe("passed"); expect(report).toMatchObject({ nativeConnectionsStarted: 0, sqlStatementsStarted: 0 });
    expect(history).not.toHaveBeenCalled(); expect(request).toHaveBeenCalledTimes(2);
    expect(started[1] - started[0]).toBeGreaterThanOrEqual(60000);
    for (const [url, options] of request.mock.calls) {
      expect(url).toBe(METRICS_ENDPOINT); expect(options).toMatchObject({ method: "GET", redirect: "error", credentials: "omit", cache: "no-store" });
      expect(options?.headers).toEqual({ Authorization: `Basic ${Buffer.from(`service_role:${env.SUPABASE_SERVICE_ROLE_KEY}`).toString("base64")}`, Accept: "text/plain" });
    }
    expect(JSON.stringify(report)).not.toContain("PRIVATE");
    expect(JSON.stringify(report)).not.toContain(Buffer.from(`service_role:${env.SUPABASE_SERVICE_ROLE_KEY}`).toString("base64"));
  });
  it("rejects mode, explicit request, project and VPS boundaries before any request or history", async () => {
    for (const change of [{ HISTORY_DIAGNOSTIC_MODE: "history" }, { HISTORY_DIAGNOSTIC_MODE: "resources" }, { HISTORY_DIAGNOSTICS_REQUESTED: "false" },
      { GITHUB_REF: "refs/heads/staging" }, { GITHUB_EVENT_NAME: "push" }, { SUPABASE_PROJECT_REF: "anotherproject" }, { RUNNER_NAME: "other" },
      { GITHUB_WORKSPACE: "/tmp/work" }, { SUPABASE_SERVICE_ROLE_KEY: "" }, { SUPABASE_SERVICE_ROLE_KEY: "PRIVATE\nHEADER" }]) {
      const request = vi.fn<typeof fetch>(); const history = vi.fn(async () => ({ status: "passed" }));
      const report = await runResourceMode({ ...env, ...change }, request, history);
      expect(report.status).toBe("failed"); expect(request).not.toHaveBeenCalled(); expect(history).not.toHaveBeenCalled();
    }
  });
  it.each([401, 429, 502])("does not retry an HTTP %s failure or expose its body", async status => {
    const request = vi.fn<typeof fetch>(async () => new Response("PRIVATE_ERROR_BODY", { status }));
    const report = await runResourceDiagnosis(env, request);
    expect(report).toMatchObject({ status: "failed", errorClass: `RESOURCE_DIAGNOSIS_HTTP_${status}` });
    expect(request).toHaveBeenCalledOnce(); expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
  it("does not retry the second failed read", async () => {
    timers(); const request = vi.fn<typeof fetch>(async (): Promise<Response> => request.mock.calls.length === 1 ? new Response(body()) : new Response("PRIVATE", { status: 503 }));
    const pending = runResourceDiagnosis(env, request); await vi.advanceTimersByTimeAsync(60000);
    const report = await pending; expect(report.status).toBe("failed"); expect(request).toHaveBeenCalledTimes(2); expect(report.snapshots).toHaveLength(1);
  });
  it("bounds connection and response-body time to fifteen seconds without a later request", async () => {
    timers(); const request = vi.fn<typeof fetch>(async () => new Promise<Response>(() => {}));
    const pending = runResourceDiagnosis(env, request); await vi.advanceTimersByTimeAsync(15000);
    const report = await pending; expect(report).toMatchObject({ status: "failed", errorClass: "RESOURCE_DIAGNOSIS_REQUEST_TIMEOUT", totalMs: 15000 });
    expect(request.mock.calls[0][1]?.signal?.aborted).toBe(true); expect(request).toHaveBeenCalledOnce();
    const bodyRequest = vi.fn<typeof fetch>(async () => new Response(new ReadableStream({ start() {} })));
    const bodyPending = runResourceDiagnosis(env, bodyRequest); await vi.advanceTimersByTimeAsync(15000);
    expect(await bodyPending).toMatchObject({ errorClass: "RESOURCE_DIAGNOSIS_REQUEST_TIMEOUT" }); expect(bodyRequest).toHaveBeenCalledOnce();
  });
  it("bounds body size and sanitizes transport or malformed response failures", async () => {
    const large = await runResourceDiagnosis(env, vi.fn<typeof fetch>(async () => new Response("x".repeat(2 * 1024 * 1024 + 1))));
    expect(large).toMatchObject({ errorClass: "RESOURCE_DIAGNOSIS_RESPONSE_TOO_LARGE" });
    const malformed = await runResourceDiagnosis(env, vi.fn<typeof fetch>(async () => new Response("PRIVATE_RAW_BODY")));
    expect(malformed).toMatchObject({ errorClass: "RESOURCE_DIAGNOSIS_NO_ALLOWED_DATABASE_METRICS" });
    const thrown = await runResourceDiagnosis(env, vi.fn<typeof fetch>(async () => { throw new Error("PRIVATE_TOKEN_IN_TRANSPORT_ERROR"); }));
    expect(JSON.stringify([large, malformed, thrown])).not.toContain("PRIVATE");
  });
});

describe("explicit resource and direct-history coordination", () => {
  it("starts history after the first parsed snapshot and awaits it after the second resource snapshot", async () => {
    timers(); let resolveHistory: (value: {status: string}) => void = () => {};
    const history = vi.fn(async () => new Promise<{status: string}>(resolve => { resolveHistory = resolve; }));
    const request = vi.fn<typeof fetch>(async (): Promise<Response> => new Response(body(request.mock.calls.length === 2)));
    const pending = runResourceMode(combinedEnv, request, history);
    let finished = false; void pending.then(() => { finished = true; });
    await vi.advanceTimersByTimeAsync(0); expect(history).toHaveBeenCalledOnce(); expect(request).toHaveBeenCalledOnce();
    expect(history).toHaveBeenCalledWith(combinedEnv);
    await vi.advanceTimersByTimeAsync(60000); expect(request).toHaveBeenCalledTimes(2); expect(finished).toBe(false);
    resolveHistory({ status: "passed" }); const report = await pending;
    expect(report).toMatchObject({ status: "passed", mode: "resources-with-history", resources: { status: "passed" }, history: { status: "passed" } });
  });
  it("starts no history after invalid combined credentials, path or failed first resource baseline", async () => {
    for (const change of [{ HISTORY_CONNECTION_PATH: "session-pooler" }, { SUPABASE_DB_PASSWORD: "" }, {}]) {
      const request = vi.fn<typeof fetch>(async () => new Response("PRIVATE", { status: 502 })); const history = vi.fn(async () => ({ status: "passed" }));
      const report = await runResourceMode({ ...combinedEnv, ...change }, request, history);
      expect(report.status).toBe("failed"); expect(history).not.toHaveBeenCalled();
      expect(report).toMatchObject({ history: { status: "skipped", nativeConnectionsStarted: 0 } });
      expect(request.mock.calls.length).toBe(Object.keys(change).length ? 0 : 1);
    }
  });
  it("awaits history after a second-resource failure and sanitizes a rejected history promise", async () => {
    timers(); let rejectHistory: (error: Error) => void = () => {};
    const history = vi.fn(async () => new Promise<{status: string}>((_, reject) => { rejectHistory = reject; }));
    const request = vi.fn<typeof fetch>(async (): Promise<Response> => request.mock.calls.length === 1 ? new Response(body()) : new Response("PRIVATE", { status: 502 }));
    const pending = runResourceMode(combinedEnv, request, history); let finished = false; void pending.then(() => { finished = true; });
    await vi.advanceTimersByTimeAsync(60000); expect(finished).toBe(false);
    rejectHistory(new Error("PRIVATE_HISTORY_ERROR")); const report = await pending;
    expect(report).toMatchObject({ status: "failed", history: { errorClass: "HISTORY_DIAGNOSIS_UNAVAILABLE" } });
    expect(request).toHaveBeenCalledTimes(2); expect(history).toHaveBeenCalledOnce(); expect(JSON.stringify(report)).not.toContain("PRIVATE");
  });
  it("keeps resource-only credentials and execution separate in the manual VPS workflow", () => {
    const workflow = readFileSync(new URL("../../.github/workflows/diagnose-startregie-history.yml", import.meta.url), "utf8");
    expect(workflow).toContain("default: history"); expect(workflow).toContain("- resources-only"); expect(workflow).toContain("- resources-with-history");
    expect(workflow).toContain("if: inputs.diagnostic_mode != 'resources-only'");
    expect(workflow).toContain("if: inputs.diagnostic_mode == 'history'");
    expect(workflow).toContain("SUPABASE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_SERVICE_ROLE_KEY }}");
    expect(workflow).toContain("inputs.diagnostic_mode == 'resources-with-history' && secrets.SUPABASE_DB_PASSWORD || ''");
    expect(workflow).toContain("inputs.diagnostic_mode == 'resources-with-history' && secrets.SUPABASE_ACCESS_TOKEN || ''");
    expect(workflow).toContain("run: node scripts/deploy/diagnose-startregie-resources.mjs");
    expect(workflow).toContain("path: ${{ runner.temp }}/startregie-resource-diagnosis/report.json");
    expect(workflow).toContain("deployment: false"); expect(workflow).toContain("clean: false");
    expect(workflow).not.toMatch(/^  push:|dg-site-deploy|restart|supabase db/m);
  });
});
