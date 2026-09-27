import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import {
  createTogetherFixtures,
  parallelSql,
  requireLocalTogetherDatabase,
  sql,
} from "./together-fixtures.mjs";
requireLocalTogetherDatabase();
const [party] = createTogetherFixtures(1, 1, 2);
const children = JSON.parse(
  sql(
    `select jsonb_agg(child_id order by child_id) from app_private.registration_children where registration_id='${party.members[0].id}'`,
  ),
);
const digest = randomBytes(32).toString("hex");
const provision = (child, value) =>
  `select api.poortenboek_parent('f0000000-0000-0000-0000-000000000001','duindorp-halloween-2026','view','${child}','${value}','${"encrypted".repeat(8)}');`;
const collision = await Promise.allSettled(
  children.map((child) => parallelSql(provision(child, digest))),
);
assert.equal(
  collision.filter((result) => result.status === "fulfilled").length,
  1,
  "exactly one child may claim a digest",
);
assert.equal(
  collision.filter((result) => result.status === "rejected").length,
  1,
  "concurrent collision is rejected atomically",
);
const retryIndex = collision.findIndex(
  (result) => result.status === "rejected",
);
const secondDigest = randomBytes(32).toString("hex");
sql(provision(children[retryIndex], secondDigest));
assert.equal(
  sql(
    `select count(*) from app_private.poortenboek_codes where child_id in('${children[0]}','${children[1]}') and revoked_at is null;`,
  ),
  "2",
);
const tokens = children.map(() => randomBytes(32).toString("hex"));
for (const [index, child] of children.entries()) {
  sql(
    `select api.poortenboek_login((select code_digest from app_private.poortenboek_codes where child_id='${child}' and revoked_at is null),'${tokens[index]}','${randomBytes(32).toString("hex")}','${randomBytes(32).toString("hex")}');`,
  );
}
const initial = JSON.parse(
  sql(`select api.poortenboek_child_action('${tokens[0]}','snapshot');`),
);
const choices = initial.election.options.slice(0, 3).map((option) => option.id);
const payload = JSON.stringify({
  electionId: initial.election.id,
  round: "round_one",
  choices,
});
const command = randomUUID();
const vote = (index, key = command) =>
  `select api.poortenboek_child_action('${tokens[index]}','vote','${payload}'::jsonb,'${key}');`;
await Promise.all([parallelSql(vote(0)), parallelSql(vote(0))]);
assert.equal(
  sql(
    `select count(*) from app_private.poortenboek_ballots where election_id='${initial.election.id}'`,
  ),
  "1",
  "concurrent retry stores one ballot",
);
await Promise.all([parallelSql(vote(0)), parallelSql(vote(1, randomUUID()))]);
assert.equal(
  sql(
    `select phase from app_private.poortenboek_elections where id='${initial.election.id}'`,
  ),
  "round_two",
  "last ballot advances the round exactly once",
);
assert.equal(
  sql(
    `select count(*) from app_private.poortenboek_commands where request_id='${command}'`,
  ),
  "1",
);
const finalPayload = JSON.stringify({
  electionId: initial.election.id,
  round: "round_two",
  choices: [choices[0]],
});
await Promise.all(
  tokens.map((token) =>
    parallelSql(
      `select api.poortenboek_child_action('${token}','vote','${finalPayload}'::jsonb,'${randomUUID()}');`,
    ),
  ),
);
assert.equal(
  sql(
    `select winner_id from app_private.poortenboek_elections where id='${initial.election.id}'`,
  ),
  choices[0],
  "simultaneous final votes produce one stable winner",
);
console.log(
  "Poortenboek concurrency: collision/retry, duplicate commands, round advancement and final winner passed.",
);
