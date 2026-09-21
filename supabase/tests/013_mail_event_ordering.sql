begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

create temporary table mail_values(outbox_id uuid) on commit drop;
with inserted as (
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload, status)
  values ('mail-ordering-fixture', 'registration_received', 'fixture', 'recipient@example.invalid', '{}'::jsonb, 'processing')
  returning id
)
insert into mail_values select id from inserted;
grant select on mail_values to service_role;

set local role service_role;
select is(
  api.worker_store_email_event('provider-delivered-1', (select outbox_id from mail_values), 'delivered', now()),
  true,
  'first provider event is stored'
);
set local role postgres;
select is(
  (select status::text from app_private.email_outbox where id = (select outbox_id from mail_values)),
  'delivered',
  'delivered provider event promotes the outbox state'
);

set local role service_role;
select is(
  api.worker_store_email_event('provider-delivered-1', (select outbox_id from mail_values), 'delivered', now()),
  false,
  'duplicate provider event is acknowledged as an idempotent no-op'
);
set local role postgres;
select is(
  (select count(*)::integer from app_private.email_events where provider_event_id = 'provider-delivered-1'),
  1,
  'duplicate provider event has one durable record'
);

set local role service_role;
select is(
  api.worker_store_email_event('provider-processed-late', (select outbox_id from mail_values), 'processed', now() - interval '1 minute'),
  true,
  'distinct late processed event is durably recorded'
);
select is(
  api.worker_store_email_event('provider-bounce-late', (select outbox_id from mail_values), 'bounce', now() + interval '1 minute'),
  true,
  'distinct late terminal event is durably recorded for audit'
);
select lives_ok(
  $$ select api.worker_update_outbox((select outbox_id from mail_values), 'accepted', 'provider-message-id', null, null) $$,
  'late worker acknowledgement is accepted without rewriting terminal delivery'
);
set local role postgres;
select is(
  (select status::text from app_private.email_outbox where id = (select outbox_id from mail_values)),
  'delivered',
  'out-of-order webhook and worker updates cannot regress delivered state'
);

select * from finish();
rollback;
