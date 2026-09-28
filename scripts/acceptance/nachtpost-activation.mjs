import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

// Run only against the isolated local database; all fixtures and changes roll back.
const container = process.env.LOCAL_DB_CONTAINER ?? "supabase_db_duindorphalloween-poortenboek";
assert.match(container, /^supabase_db_[a-z0-9_-]+$/i);
const migration = readFileSync(new URL("../../supabase/migrations/20260928154407_activate_existing_nachtpost_accounts.sql", import.meta.url), "utf8");
const sql = `
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('test.eid', (select id::text from app_private.events where slug='duindorp-halloween-2026'), true);
-- Only this isolated transaction removes a previous local completion marker.
delete from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928';
insert into auth.users(id, aud, role, email, email_confirmed_at, created_at, updated_at)
select ('b8500000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
  'authenticated','authenticated','activation-' || n || '@example.invalid',now(),now(),now()
from generate_series(1,8) n;
update auth.users set email_confirmed_at=null where id='b8500000-0000-0000-0000-000000000005';
update auth.users set banned_until=now()+interval '1 day' where id='b8500000-0000-0000-0000-000000000006';
update auth.users set is_anonymous=true where id='b8500000-0000-0000-0000-000000000007';
update auth.users set deleted_at=now() where id='b8500000-0000-0000-0000-000000000008';
insert into app_private.participant_preferences(event_id,user_id,optional_updates_consent,reduced_motion,readable_mode,email_updates,editorial_push_parents)
values
  (current_setting('test.eid')::uuid,'b8500000-0000-0000-0000-000000000001',false,true,true,false,true),
  (current_setting('test.eid')::uuid,'b8500000-0000-0000-0000-000000000003',true,false,false,true,false),
  (current_setting('test.eid')::uuid,'b8500000-0000-0000-0000-000000000004',true,false,false,true,false);
update app_private.participant_preferences set optional_updates_consent=false
  where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000004';
create temporary table activation_before as select
  (select count(*) from app_private.email_outbox) outbox_count,
  (select count(*) from app_private.newsletter_recipients) recipient_count,
  (select to_jsonb(p) from app_private.participant_preferences p where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000003') existing_opt_in;
insert into app_private.editorial_suppressions(email_hash,reason)
values (extensions.digest('activation-4@example.invalid','sha256'),'unsubscribe');

${migration}

select is((select count(*)::int from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id::text like 'b8500000-%' and optional_updates_consent),4,'all existing verified active accounts are enabled');
select is((select count(*)::int from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id in ('b8500000-0000-0000-0000-000000000005','b8500000-0000-0000-0000-000000000006','b8500000-0000-0000-0000-000000000007','b8500000-0000-0000-0000-000000000008')),0,'unverified, banned, anonymous and deleted accounts stay excluded');
select is((select editorial_consent_source from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000001'),'organization_activation_20260928','administrative source does not claim user opt-in');
select ok((select reduced_motion and readable_mode and not email_updates and editorial_push_parents from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000001'),'unrelated accessibility, operational email and push preferences stay unchanged');
select is((select to_jsonb(p) from app_private.participant_preferences p where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000003'),(select existing_opt_in from activation_before),'existing voluntary opt-in metadata stays unchanged');
select is((select count(*)::int from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928' and resource_id::text like 'b8500000-%'),3,'each newly activated profile has one administrative audit');
select is((select minimal_change->'previousPreferences'->>'optional_updates_consent' from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928' and resource_id='b8500000-0000-0000-0000-000000000001'),'false','audit retains the previous preference');
select ok((select minimal_change->'previousPreferences'->>'editorial_unsubscribed_at' is not null from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928' and resource_id='b8500000-0000-0000-0000-000000000004'),'previous unsubscribe history remains in the audit');
select is((select count(*)::int from app_private.editorial_audience(current_setting('test.eid')::uuid,'{"roles":["subscribers"]}') where user_id::text like 'b8500000-%' and eligible),3,'the real audience includes enabled accounts but retains suppression');
select is((select reason from app_private.editorial_suppressions where email_hash=extensions.digest('activation-4@example.invalid','sha256')),'unsubscribe','provider suppression remains unchanged');
select is((select count(*) from app_private.email_outbox),(select outbox_count from activation_before),'activation sends no email');
select is((select count(*) from app_private.newsletter_recipients),(select recipient_count from activation_before),'activation does not queue or freeze a campaign');
select is((select count(*)::int from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928' and action='newsletter.existing_accounts_activation_completed'),1,'one completed batch is recorded');

-- A later self-service unsubscribe must win, including when the migration retries.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b8500000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.editorial_preferences_set('duindorp-halloween-2026',false,false,false);
reset role;
insert into auth.users(id,aud,role,email,email_confirmed_at,created_at,updated_at)
values ('b8500000-0000-0000-0000-000000000009','authenticated','authenticated','activation-later@example.invalid',now(),now(),now());

${migration}

select ok(not (select optional_updates_consent from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000001'),'later account unsubscribe is respected after a retry');
select is((select count(*)::int from app_private.participant_preferences where event_id=current_setting('test.eid')::uuid and user_id='b8500000-0000-0000-0000-000000000009'),0,'future accounts are not automatically enrolled');
select is((select count(*)::int from app_private.audit_events where correlation_id='nachtpost-existing-accounts-20260928' and resource_id::text like 'b8500000-%'),3,'retry does not duplicate activation audits');
select * from finish();
rollback;
`;
const output = execFileSync("docker", ["exec", "-i", container, "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"], { input: sql, encoding: "utf8" });
assert.doesNotMatch(output, /not ok|Looks like you failed/);
assert.match(output, /1\.\.16/);
console.log(output.split("\n").filter((line) => /^(ok |1\.\.)/.test(line)).join("\n"));
