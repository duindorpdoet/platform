import { createClient } from "@supabase/supabase-js";
import { writeFile } from "node:fs/promises";

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY;
if (!url || !key || !["localhost", "127.0.0.1", "[::1]"].includes(new URL(url).hostname)) {
  throw new Error("Load acceptance requires an explicitly configured local Supabase instance");
}
const groupId = "23000000-0000-0000-0000-000000000001";
const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await client.auth.signInWithPassword({ email: "leader-a@example.invalid", password: "local-test-only" });
if (login.error) throw new Error(`Fixture login failed: ${login.error.code}`);
async function rpc(name, args) {
  const { data, error } = await client.schema("api").rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code} ${error.message}`);
  return data;
}
const snapshot = () => rpc("group_snapshot", { _group_id: groupId });
const before = await snapshot();
if (before.run) throw new Error("Reset local fixtures before load acceptance");
const roster = await rpc("group_roster", { _group_id: groupId });
await rpc("run_start", {
  _group_id: groupId, _present_registration_child_ids: roster.map((item) => item.registrationChildId),
  _expected_group_version: before.group.version, _idempotency_key: "load-start", _request_hash: "load-start",
});
let live = await snapshot();
await rpc("run_scan", {
  _run_id: live.run.id, _expected_stop_id: live.run.currentStop.id, _expected_run_version: live.run.version,
  _credential: "TEST-PORTAL-01-TOKEN", _method: "qr",
});
live = await snapshot();
for (const participant of live.run.participants) {
  await rpc("run_update_participant", {
    _run_id: live.run.id, _stop_id: live.run.currentStop.id, _run_participant_id: participant.id,
    _new_status: "visited", _expected_run_version: live.run.version,
    _expected_status_version: participant.statusVersion, _reason: null,
  });
  live = await snapshot();
}
// Independent HTTP clients share one authorized fixture identity; this is not 200 households.
const clients = Array.from({ length: 200 }, () => createClient(url, key, {
  global: { headers: { Authorization: `Bearer ${login.data.session.access_token}` } },
  auth: { persistSession: false, autoRefreshToken: false },
}));
const report = { environment: "local", clients: clients.length, identityCount: 1, phases: [] };
async function phase(name, command, args, validate) {
  const start = performance.now();
  const results = await Promise.all(clients.map(async (actor) => {
    const began = performance.now();
    const result = await actor.schema("api").rpc(command, args).abortSignal(AbortSignal.timeout(30_000));
    return { ...result, latencyMs: performance.now() - began };
  }));
  const latencies = results.map((result) => result.latencyMs).sort((a, b) => a - b);
  const failures = results.filter((result) => result.error || !validate(result.data));
  const percentile = (p) => Math.round(latencies[Math.ceil(latencies.length * p) - 1]);
  report.phases.push({ name, requests: results.length, failures: failures.length, elapsedMs: Math.round(performance.now() - start), p50Ms: percentile(.5), p95Ms: percentile(.95), p99Ms: percentile(.99), maxMs: percentile(1) });
  if (failures.length) throw new Error(`${name}: ${failures.length} invalid or failed responses; ${JSON.stringify(report)}`);
}
for (let round = 1; round <= 3; round += 1) {
  await phase(`snapshot-${round}`, "group_snapshot", { _group_id: groupId }, (data) => data.run?.currentStop.id === live.run.currentStop.id && data.run.version === live.run.version);
}
const args = {
  _run_id: live.run.id, _stop_id: live.run.currentStop.id, _expected_run_version: live.run.version,
  _all_skip_confirmed: false, _idempotency_key: "load-complete", _request_hash: "load-complete",
};
let receipt;
await phase("same-key-completion", "run_complete_stop", args, (data) => {
  const encoded = JSON.stringify(data);
  receipt ??= encoded;
  return encoded === receipt;
});
const after = await snapshot();
if (after.run.currentStop.sequence !== 2 || after.run.history.length !== 1) throw new Error("Concurrent completion advanced more than once");
report.status = "pass";
report.checks = ["OPS-08"];
report.invariant = "200 concurrent completion requests return one receipt and advance exactly one stop";
const output = `${JSON.stringify(report, null, 2)}\n`;
if (process.argv[2]) await writeFile(process.argv[2], output);
process.stdout.write(output);
