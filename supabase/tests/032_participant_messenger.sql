begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

select ok((select relrowsecurity from pg_class where oid = 'app_private.messenger_conversations'::regclass), 'messenger conversations use RLS');
select ok((select relrowsecurity from pg_class where oid = 'app_private.messenger_messages'::regclass), 'messenger messages use RLS');
select ok((select relrowsecurity from pg_class where oid = 'app_private.messenger_admin_presence'::regclass), 'presence uses RLS');
select ok(not has_table_privilege('authenticated', 'app_private.messenger_messages', 'select'), 'clients cannot query durable messages directly');
select ok(not has_function_privilege('anon', 'api.participant_messenger_create(text,text,uuid,text,text,text)', 'execute'), 'anonymous users cannot create conversations');

create temporary table messenger_state(
  id uuid,
  version integer
) on commit drop;
insert into messenger_state values (null, null);
grant select, update on messenger_state to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select matches(
  api.participant_messenger_context(
    'duindorp-halloween-2026', 'walker',
    '23000000-0000-0000-0000-000000000001', null, null
  ) ->> 'systemCode',
  '^G-[0-9]{2,}$',
  'a current group leader receives the stable G-code context'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.participant_messenger_context(
    'duindorp-halloween-2026', 'walker',
    '23000000-0000-0000-0000-000000000001', null, null
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'an unrelated participant cannot open a group conversation'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select matches(
  api.participant_messenger_context(
    'duindorp-halloween-2026', 'homeowner', null,
    '12000000-0000-0000-0000-000000000001', null
  ) ->> 'systemCode',
  '^P-[0-9]{2,}$',
  'an active portal owner receives the stable P-code context'
);

set local role postgres;
update app_private.events
set settings = settings || '{"supportEmail":"admin@example.invalid"}'::jsonb
where slug = 'duindorp-halloween-2026';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.admin_messenger_presence('duindorp-halloween-2026', true, 90) ->> 'available',
  'true',
  'an authorized organizer can publish a bounded presence heartbeat'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update messenger_state
     set id = (result ->> 'id')::uuid, version = (result ->> 'version')::integer
     from (
       select api.participant_messenger_create(
         'duindorp-halloween-2026', 'group',
         '23000000-0000-0000-0000-000000000001',
         'Kunnen jullie even meekijken?', 'participant-create-1', 'hash-create-1'
       ) result
     ) created $$,
  'a group leader can durably start one conversation'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.messenger_messages where conversation_id = (select id from messenger_state)),
  1,
  'the initial participant message is stored exactly once'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.participant_messenger_create(
    'duindorp-halloween-2026', 'group',
    '23000000-0000-0000-0000-000000000001',
    'Kunnen jullie even meekijken?', 'participant-create-1', 'hash-create-1'
  ) $$,
  'replaying the same idempotency key returns its stored safe result'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.messenger_messages where conversation_id = (select id from messenger_state)),
  1,
  'an idempotent replay does not duplicate a message'
);
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'messenger_incoming_admin' and recipient_ref = (select id::text from messenger_state)),
  1,
  'the first participant burst queues one admin notification'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.admin_messenger_snapshot('duindorp-halloween-2026') -> 'conversations') > 0,
  true,
  'the admin inbox contains the durable conversation'
);
select lives_ok(
  $$ update messenger_state set version = (result ->> 'version')::integer
     from (select api.admin_messenger_claim(
       (select id from messenger_state), (select version from messenger_state)
     ) result) claimed $$,
  'an available organizer can claim the queued conversation'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update messenger_state set version = (result ->> 'version')::integer
     from (select api.participant_messenger_reply(
       (select id from messenger_state), (select version from messenger_state),
       'Hierbij nog wat uitleg.', 'participant-reply-1', 'hash-participant-reply-1'
     ) result) replied $$,
  'the participant can append against the current conversation version'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (api.admin_messenger_snapshot('duindorp-halloween-2026') -> 'conversations' -> 0 ->> 'unreadCount')::integer,
  1,
  'the admin snapshot reports the unread participant reply'
);
select lives_ok(
  $$ update messenger_state set version = (result ->> 'version')::integer
     from (select api.admin_messenger_reply(
       (select id from messenger_state), (select version from messenger_state),
       'Dank, we pakken dit op.', 'admin-reply-1', 'hash-admin-reply-1'
     ) result) replied $$,
  'the claimed organizer can send a durable reply'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (api.participant_messenger_snapshot('duindorp-halloween-2026') -> 'conversations' -> 0 ->> 'unreadCount')::integer,
  1,
  'the participant snapshot reports the unread organization reply'
);
select is(
  api.participant_messenger_mark_read((select id from messenger_state)) ->> 'markedRead',
  '1',
  'opening the participant widget durably marks the organization reply read'
);
select is(
  (api.participant_messenger_snapshot('duindorp-halloween-2026') -> 'conversations' -> 0 ->> 'unreadCount')::integer,
  0,
  'the participant unread counter clears after marking read'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where message_type = 'messenger_admin_reply' and recipient_ref = (select id::text from messenger_state)),
  1,
  'an organization reply queues exactly one participant notification'
);
select ok(
  not exists (
    select 1 from app_private.email_outbox
    where message_type in ('messenger_incoming_admin', 'messenger_admin_reply')
      and (payload ? 'body' or payload ? 'email' or payload ? 'phone')
  ),
  'messenger outbox payloads contain no message body or participant contact data'
);
select ok(
  exists (
    select 1 from app_private.messenger_conversations conversation
    where conversation.id = (select id from messenger_state)
      and conversation.status = 'awaiting_participant'
      and conversation.claimed_by = 'f0000000-0000-0000-0000-000000000001'
  ),
  'the conversation keeps its durable ownership and waiting state'
);

set local role postgres;
insert into app_private.event_capabilities(event_id, user_id, capability, granted_by)
values (
  (select id from app_private.events where slug = 'duindorp-halloween-2026'),
  'a0000000-0000-0000-0000-000000000001',
  'groups_manage',
  'f0000000-0000-0000-0000-000000000001'
) on conflict do nothing;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_messenger_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'groups_manage alone cannot read the event-wide private messenger inbox'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $test$
  do $body$
  declare
    i integer;
    current_id uuid;
    current_version integer;
    result jsonb;
  begin
    for i in 2..29 loop
      select id, version into current_id, current_version from messenger_state;
      result := api.participant_messenger_reply(
        current_id,
        current_version,
        'Begrensd testbericht ' || i,
        'participant-rate-' || i,
        'hash-participant-rate-' || i
      );
      update messenger_state set version = (result ->> 'version')::integer;
    end loop;
  end
  $body$
  $test$,
  'a participant can send up to thirty messages in the durable hourly budget'
);
select throws_ok(
  $$ select api.participant_messenger_reply(
    (select id from messenger_state),
    (select version from messenger_state),
    'Dit bericht overschrijdt de limiet.',
    'participant-rate-30',
    'hash-participant-rate-30'
  ) $$,
  'P0001', 'RATE_LIMITED',
  'the thirty-first participant message in an hour is rejected'
);

set local role postgres;
select is(
  (
    select count
    from app_private.rate_limit_buckets
    where scope = 'messenger_message_actor'
      and opaque_subject_hash = encode(extensions.digest(convert_to('c0000000-0000-0000-0000-000000000001', 'utf8'), 'sha256'), 'hex')
      and window_start = date_trunc('hour', now())
  ),
  30,
  'the messenger budget is counted atomically without charging the rejected write'
);
insert into app_private.messenger_messages(conversation_id, sender_id, sender_side, body)
select
  (select id from messenger_state),
  'c0000000-0000-0000-0000-000000000001',
  'participant',
  'Historiebericht ' || sequence
from generate_series(1, 120) sequence;
select is(
  jsonb_array_length(app_private.messenger_conversation_payload(
    (select id from messenger_state),
    true,
    'f0000000-0000-0000-0000-000000000001'
  ) -> 'messages'),
  100,
  'conversation snapshots return at most the most recent one hundred messages'
);

update app_private.group_leaders
set active_until = now() - interval '1 second'
where group_id = '23000000-0000-0000-0000-000000000001'
  and user_id = 'c0000000-0000-0000-0000-000000000001'
  and active_until is null;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.participant_messenger_snapshot('duindorp-halloween-2026') -> 'conversations'),
  0,
  'revoked group access removes an existing conversation from the participant snapshot'
);
set local role postgres;
select is(
  app_private.can_access_realtime_topic(
    'messenger:' || (select id::text from messenger_state),
    'c0000000-0000-0000-0000-000000000001'
  ),
  false,
  'revoked group access also removes the private Realtime subscription'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.participant_messenger_reply(
    (select id from messenger_state),
    (select version from messenger_state),
    'Niet meer bevoegd.',
    'participant-after-revoke',
    'hash-participant-after-revoke'
  ) $$,
  '42501', 'NOT_AUTHORIZED',
  'a revoked group actor cannot reply to the existing conversation'
);
select throws_ok(
  $$ select api.participant_messenger_mark_read((select id from messenger_state)) $$,
  '42501', 'NOT_AUTHORIZED',
  'a revoked group actor cannot mark the existing conversation as read'
);

select * from finish();
rollback;
