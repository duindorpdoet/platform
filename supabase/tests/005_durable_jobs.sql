begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select ok(not has_function_privilege('authenticated', 'api.configure_mail_worker(text,text,boolean)', 'execute'), 'browser cannot configure worker schedule');
select ok(has_function_privilege('service_role', 'api.configure_mail_worker(text,text,boolean)', 'execute'), 'service role can configure worker schedule');

set local role service_role;
select lives_ok(
  $$ select api.configure_mail_worker('https://staging-halloween.duindorpdoet.nl/api/jobs/mail', repeat('x', 40), true) $$,
  'durable mail worker can be configured without exposing its bearer secret'
);

set local role postgres;
select is((select count(*)::integer from cron.job where jobname = 'duindorp-halloween-mail-outbox'), 1, 'exactly one one-minute schedule exists');
select is((select active from app_private.job_configs where key = 'mail_outbox'), true, 'worker is active after explicit configuration');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$ select api.retention_preview('duindorp-halloween-2026') $$, 'admin can preview retention without deleting production data');

select * from finish();
rollback;
