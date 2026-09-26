import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { createTogetherFixtures, parallelSql, requireLocalTogetherDatabase, sql } from "./together-fixtures.mjs";

requireLocalTogetherDatabase();
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY;
const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const login = await client.auth.signInWithPassword({ email: "admin@example.invalid", password: "local-test-only" });
assert.equal(login.error, null);
const rpc = async (name, args) => client.schema("api").rpc(name, { _event_slug: "duindorp-halloween-2026", ...args });
const fixtures = createTogetherFixtures(4);
const preview = async (s, t) => {
  const result = await rpc("admin_together_merge_preview", { _source_party_id: s.partyId, _target_party_id: t.partyId });
  assert.equal(result.error, null);
  assert.equal(result.data.canMerge, true);
  return result.data;
};
function args(p, key) {
  return { _source_party_id: p.source.partyId, _target_party_id: p.target.partyId, _expected_source_state: p.source.stateToken, _expected_target_state: p.target.stateToken, _reason: "Handmatig gekoppeld tijdens lokale concurrencytest", _idempotency_key: key };
}
const initial = await preview(fixtures[0], fixtures[1]);
const same = args(initial, crypto.randomUUID());
const retries = await Promise.all(Array.from({ length: 8 }, () => rpc("admin_merge_together_parties", same)));
assert(retries.every((result) => result.error === null), JSON.stringify(retries.map((r) => r.error)));
assert(retries.every((result) => result.data.clusterReference === retries[0].data.clusterReference));
assert.equal(sql(`select count(*) from app_private.audit_events where action='together.admin_merged' and resource_id='${fixtures[1].partyId}';`), "1");
const a = await preview(fixtures[2], fixtures[1]);
const b = await preview(fixtures[2], fixtures[3]);
const competing = await Promise.all([rpc("admin_merge_together_parties", args(a, crypto.randomUUID())), rpc("admin_merge_together_parties", args(b, crypto.randomUUID()))]);
assert.equal(competing.filter((r) => !r.error).length, 1, "competing destinations must commit only once");
assert.equal(sql(`select count(*) from app_private.together_memberships where registration_id='${fixtures[2].members[0].id}' and left_at is null;`), "1");

// Multiple database sessions race the generator for the same historical party.
const helper = readFileSync(new URL("./fixtures/together-party.sql", import.meta.url), "utf8");
const partyId = sql(`begin; ${helper}
alter table app_private.together_memberships disable trigger together_memberships_changed;
select pg_temp.fixture_party(2);
alter table app_private.together_memberships enable trigger together_memberships_changed;
commit;`);
assert.match(partyId, /^[a-f0-9-]{36}$/);
const generated = await Promise.all(Array.from({ length: 12 }, () => parallelSql(`select app_private.ensure_together_party_cluster_reference('${partyId}');`)));
assert.match(generated[0], /^SL-2026-[A-HJ-NP-Z2-9]{6}$/);
assert.equal(new Set(generated).size, 1, "parallel generator calls converge on one stable reference");
assert.equal(sql(`select count(*) from app_private.together_parties where event_id=(select event_id from app_private.together_parties where id='${partyId}') and cluster_reference='${generated[0]}';`), "1");
console.log("Together concurrency: 8 idempotent merges, competing destinations and 12 parallel generators passed.");
