begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

select ok(exists(
  select 1 from pg_trigger
  where tgname = 'email_outbox_immediate_dispatch' and tgrelid = 'app_private.email_outbox'::regclass and not tgisinternal
), 'the outbox has an immediate dispatch trigger');
select ok(not has_function_privilege('public', 'app_private.kick_mail_worker_after_outbox_insert()', 'execute'), 'public cannot execute the immediate trigger function');
select ok(not has_function_privilege('anon', 'app_private.kick_mail_worker_after_outbox_insert()', 'execute'), 'anon cannot execute the immediate trigger function');
select ok(not has_function_privilege('authenticated', 'app_private.kick_mail_worker_after_outbox_insert()', 'execute'), 'authenticated users cannot execute the immediate trigger function');
select ok(not has_function_privilege('public', 'api.dispatch_mail_worker_probe()', 'execute'), 'public cannot start mail worker probes');
select ok(not has_function_privilege('anon', 'api.mail_worker_probe_result(bigint)', 'execute'), 'anon cannot read mail worker probe results');
select ok(not has_function_privilege('authenticated', 'api.dispatch_mail_worker_probe()', 'execute'), 'authenticated users cannot start mail worker probes');
select ok(has_function_privilege('service_role', 'api.dispatch_mail_worker_probe()', 'execute'), 'service role can start mail worker probes');
select ok(has_function_privilege('service_role', 'api.mail_worker_probe_result(bigint)', 'execute'), 'service role can read mail worker probe results');

delete from app_private.job_configs where key = 'mail_outbox';
select lives_ok(
  $$ insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
     values ('immediate-trigger-without-worker', 'test', 'test', 'test@example.invalid', '{}'::jsonb) $$,
  'outbox insert remains durable when no active worker configuration exists'
);

select * from finish();
rollback;
