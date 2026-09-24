begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

set local role service_role;
select lives_ok(
  $$ select api.submit_public_contact(
    'duindorp-halloween-2026', 'Providerstoring test', 'sender@example.invalid',
    'Test van duurzame opslag', 'Dit bericht moet bewaard blijven als de provider uitvalt.',
    'contact-provider-outage-test'
  ) $$,
  'a public contact request is durably accepted before provider delivery'
);

set local role postgres;
select is((select count(*)::integer from app_private.contact_messages where sender_email = 'sender@example.invalid'), 1, 'the contact message is stored independently of mail delivery');
select is((select recipient_email from app_private.email_outbox where message_type = 'contact_notification' order by created_at desc limit 1), 'halloween@duindorpdoet.nl', 'the notification remains fixed to the organization mailbox');

set local role service_role;
select is((select count(*)::integer from api.worker_claim_outbox(20, 10)), 2, 'the receipt and organization notification can be leased by one worker');
set local role postgres;
update app_private.email_outbox set lease_until = now() - interval '1 second' where message_type = 'contact_notification';

set local role service_role;
select is((select count(*)::integer from api.worker_claim_outbox(20, 10)), 0, 'an expired processing lease is not blindly sent again');
set local role postgres;
select is((select status::text from app_private.email_outbox where message_type = 'contact_notification' order by created_at desc limit 1), 'unknown', 'a possible post-acceptance worker crash becomes explicit reconciliation state');
select is((select attempts from app_private.email_outbox where message_type = 'contact_notification' order by created_at desc limit 1), 1, 'reconciliation does not silently increment another provider attempt');
select is((select count(*)::integer from app_private.contact_messages where sender_email = 'sender@example.invalid'), 1, 'provider uncertainty never deletes the original contact message');

select * from finish();
rollback;
