import { randomUUID } from "node:crypto";
import {
  sql,
  parallelSql,
  requireLocalTogetherDatabase,
} from "./together-fixtures.mjs";
import { createPortalRoomFixture } from "./poortkamer-fixtures.mjs";
requireLocalTogetherDatabase();
const fixture = createPortalRoomFixture("e0000000-0000-0000-0000-000000000001");
const first = "a0000000-0000-0000-0000-000000000001",
  second = "a0000000-0000-0000-0000-000000000002";
sql(
  `insert into app_private.portal_owners(portal_id,user_id,role) values('${fixture.id}','${first}','coadmin'),('${fixture.id}','${second}','coadmin');`,
);
function transfer(target) {
  return `begin;set local role authenticated;select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);select api.portal_team_command('${fixture.id}','transfer','{"userId":"${target}"}','${randomUUID()}');select pg_sleep(0.2);commit;`;
}
const outcomes = await Promise.allSettled([
  parallelSql(transfer(first)),
  parallelSql(transfer(second)),
]);
if (outcomes.filter((r) => r.status === "fulfilled").length !== 1)
  throw new Error("Exactly one concurrent owner transfer must succeed");
if (
  sql(
    `select count(*) from app_private.portal_owners where portal_id='${fixture.id}' and role='owner' and revoked_at is null`,
  ) !== "1"
)
  throw new Error("Primary owner invariant lost");
const primary = sql(
  `select user_id from app_private.portal_owners where portal_id='${fixture.id}' and role='owner' and revoked_at is null`,
);
const key = randomUUID();
const invite = `begin;set local role authenticated;select set_config('request.jwt.claims','{"sub":"${primary}","role":"authenticated"}',true);select api.portal_team_command('${fixture.id}','invite','{"firstName":"Concurrent","lastName":"Fixture","email":"room-concurrent-${key}@example.invalid","role":"viewer"}','${key}');select pg_sleep(0.2);commit;`;
await Promise.all([parallelSql(invite), parallelSql(invite)]);
if (
  sql(
    `select count(*) from app_private.portal_team_invites where portal_id='${fixture.id}'`,
  ) !== "1"
)
  throw new Error("Duplicate invite created");
if (
  sql(
    `select count(*) from app_private.audit_events where resource_id='${fixture.id}' and action='portal.team.invite'`,
  ) !== "1"
)
  throw new Error("Retry duplicated audit");
const chatKey = randomUUID();
// Resolve by declared kind, never presentation order.
const channel = JSON.parse(
  sql(
    `select set_config('request.jwt.claims','{"sub":"${primary}","role":"authenticated"}',false);select api.portal_room_snapshot('duindorp-halloween-2026','${fixture.id}');`,
  )
    .split("\n")
    .at(-1),
).channels.find((c) => c.kind === "team").id;
const chat = `begin;set local role authenticated;select set_config('request.jwt.claims','{"sub":"${primary}","role":"authenticated"}',true);select api.portal_chat_send('${channel}','Concurrent fixture','${chatKey}','${fixture.id}');commit;`;
await Promise.all([parallelSql(chat), parallelSql(chat)]);
if (
  sql(
    `select count(*) from app_private.portal_room_messages where dedupe_key='${chatKey}'`,
  ) !== "1"
)
  throw new Error("Concurrent chat duplicated");
console.log(
  JSON.stringify({
    status: "pass",
    checks: [
      "single primary owner under concurrent transfer",
      "invitation retry one membership request and audit",
      "concurrent chat exact once",
    ],
  }),
);
