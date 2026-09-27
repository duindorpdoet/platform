import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";

export function requireLocalTogetherDatabase() {
  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!url || !["127.0.0.1", "localhost", "::1"].includes(new URL(url).hostname)) throw new Error("Together acceptance only permits an isolated local Supabase URL");
  const container = process.env.TOGETHER_TEST_DB_CONTAINER ?? "supabase_db_duindorphalloween";
  if (!/^supabase_db_[a-zA-Z0-9_-]+$/.test(container)) throw new Error("Invalid local test container");
  return container;
}
export function sql(query) {
  const container = requireLocalTogetherDatabase();
  return execFileSync("docker", ["exec", "-i", container, "psql", "-U", "postgres", "-d", "postgres", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], { input: query, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
}
export function parallelSql(query) {
  const container = requireLocalTogetherDatabase();
  return new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, "psql", "-U", "postgres", "-d", "postgres", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]);
    let output = ""; let error = "";
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { error += data; });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve(output.trim()) : reject(new Error(error)));
    child.stdin.end(query);
  });
}
export function createTogetherFixtures(count = 5, members = 1, children = 1) {
  if (![count, members, children].every((value) => Number.isInteger(value) && value >= 1 && value <= 30)) throw new Error("Invalid fixture size");
  const helper = readFileSync("scripts/acceptance/fixtures/together-party.sql", "utf8");
  return JSON.parse(sql(`${helper}
    create temp table created as select pg_temp.fixture_party(${members}, ${children}) id from generate_series(1, ${count});
    select jsonb_agg(jsonb_build_object('partyId', p.id, 'clusterReference', p.cluster_reference,
      'members', (select jsonb_agg(jsonb_build_object('id', r.id, 'reference', r.reference, 'togetherCode', r.together_code) order by r.reference)
        from app_private.together_memberships m join app_private.registrations r on r.id=m.registration_id
        where m.party_id=p.id and m.left_at is null)))
    from created c join app_private.together_parties p on p.id=c.id;
  `));
}
