begin;
create extension if not exists pgtap with schema extensions;
select plan(35);

select ok(
  (select relrowsecurity from pg_class where oid = 'app_private.together_join_requests'::regclass),
  'capacity-review requests have RLS defense in depth'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'app_private.group_support_tickets'::regclass),
  'ticket threads have RLS defense in depth'
);
select ok(
  not has_table_privilege('authenticated', 'app_private.group_support_tickets', 'select'),
  'clients cannot query private tickets directly'
);
select ok(
  not has_function_privilege('anon', 'api.group_ticket_create(uuid,text,text,text,text,text)', 'execute'),
  'anonymous visitors cannot create tickets'
);

create temporary table feature_values(
  key text primary key,
  value jsonb not null
) on commit drop;
grant select, insert, update on feature_values to authenticated;
insert into feature_values
select 'target-code', jsonb_build_object('code', together_code)
from app_private.registrations
where reference = 'FIXTURE-10';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into feature_values values (
    'limit',
    api.admin_set_group_size_limit(
      'duindorp-halloween-2026', 10,
      (api.admin_dashboard('duindorp-halloween-2026') #>> '{event,settingsVersion}')::integer,
      'Contracttest bevestigt de limietinstelling'
    )
  ) $$,
  'an authorized organizer can set the shared group limit'
);
select is(
  (select value ->> 'maxGroupSize' from feature_values where key = 'limit'),
  '10',
  'the capacity command returns the applied limit'
);
select throws_ok(
  $$ select api.admin_set_group_size_limit(
    'duindorp-halloween-2026', 9,
    (api.admin_dashboard('duindorp-halloween-2026') #>> '{event,settingsVersion}')::integer,
    'Bestaande groepen mogen niet stilzwijgend breken'
  ) $$,
  '23514', 'GROUP_SIZE_LIMIT_BELOW_ACTIVE_PARTY',
  'lowering the limit cannot invalidate an existing non-overridden party'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_together_requests_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED',
  'an ordinary participant cannot inspect capacity-review requests'
);
select lives_ok(
  $$ select api.registration_save_draft(
    'duindorp-halloween-2026',
    jsonb_build_object(
      'adult', jsonb_build_object('name', 'Capaciteit ouder', 'phone', '0612345678'),
      'children', jsonb_build_array(jsonb_build_object('name', 'Capaciteit kind', 'age', '9', 'accessibilityNote', '')),
      'togetherCode', (select value ->> 'code' from feature_values where key = 'target-code'),
      'marketingConsent', false
    ), null
  ) $$,
  'a participant can request the code of an already full party'
);
select lives_ok(
  $$ insert into feature_values values (
    'registration',
    api.registration_submit('duindorp-halloween-2026', 'terms-test', 'privacy-test', 'capacity-submit', 'capacity-submit-hash')
  ) $$,
  'an over-limit request preserves the otherwise valid registration'
);

set local role postgres;
insert into feature_values
select 'request', jsonb_build_object('id', id, 'version', version)
from app_private.together_join_requests
where requested_by_registration_id = ((select value ->> 'id' from feature_values where key = 'registration'))::uuid;
select isnt(
  (select party_id from app_private.together_memberships where registration_id = ((select value ->> 'id' from feature_values where key = 'registration'))::uuid and left_at is null),
  (select membership.party_id from app_private.together_memberships membership join app_private.registrations registration on registration.id = membership.registration_id where registration.reference = 'FIXTURE-10' and membership.left_at is null),
  'an over-limit registration remains safely isolated pending review'
);
select is(
  (select status from app_private.together_join_requests where id = ((select value ->> 'id' from feature_values where key = 'request'))::uuid),
  'pending',
  'the overflow creates a pending organizer decision'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,togetherRequest,status}',
  'pending',
  'the participant sees that the together request awaits review'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_decide_together_request(
    ((select value ->> 'id' from feature_values where key = 'request'))::uuid,
    ((select value ->> 'version' from feature_values where key = 'request'))::integer,
    'accept', false, 'Geen override tijdens deze contracttest'
  ) $$,
  '23514', 'GROUP_SIZE_LIMIT_EXCEEDED',
  'an oversized merge cannot be accepted accidentally'
);
select lives_ok(
  $$ select api.admin_decide_together_request(
    ((select value ->> 'id' from feature_values where key = 'request'))::uuid,
    ((select value ->> 'version' from feature_values where key = 'request'))::integer,
    'accept', true, 'Bewuste uitzondering na veiligheidscontrole'
  ) $$,
  'an organizer can explicitly override the limit with an audit reason'
);

set local role postgres;
select is(
  (select party_id from app_private.together_memberships where registration_id = ((select value ->> 'id' from feature_values where key = 'registration'))::uuid and left_at is null),
  (select membership.party_id from app_private.together_memberships membership join app_private.registrations registration on registration.id = membership.registration_id where registration.reference = 'FIXTURE-10' and membership.left_at is null),
  'the approved registration joins the requested party'
);
select ok(
  exists (
    select 1 from app_private.together_parties party
    join app_private.together_memberships membership on membership.party_id = party.id
    join app_private.registrations registration on registration.id = membership.registration_id
    where registration.reference = 'FIXTURE-10' and membership.left_at is null
      and party.capacity_override_at is not null and party.capacity_override_reason is not null
  ),
  'the oversized party stores the explicit override decision'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(
  exists (
    select 1 from jsonb_array_elements(api.admin_planning_snapshot('duindorp-halloween-2026') -> 'parties') party
    where (party ->> 'togetherOverride')::boolean
  ),
  'the route planner receives the authorized oversize marker'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into feature_values values (
    'ticket',
    api.group_ticket_create(
      '23000000-0000-0000-0000-000000000001', 'planning', 'Vraag over de route',
      'Kunnen jullie het startmoment nog bevestigen?', 'ticket-create', 'ticket-create-hash'
    )
  ) $$,
  'a current group leader can open a ticket'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where dedupe_key like 'group-ticket:%'),
  2,
  'each message queues mail for both the organization and group leader'
);
select is(
  (select payload ->> 'actionPath' from app_private.email_outbox where message_type = 'group_ticket_message_leader' order by created_at desc limit 1),
  '/omgeving/meeloper/groep',
  'leader notification opens Hulp & contact in the unified participant environment'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.group_ticket_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED',
  'a participant who is not the current leader cannot read group tickets'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.group_ticket_snapshot('23000000-0000-0000-0000-000000000001')),
  1,
  'the current leader sees the private ticket thread'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.admin_group_ticket_snapshot('duindorp-halloween-2026')),
  1,
  'an organizer sees the event ticket inbox'
);
select lives_ok(
  $$ select api.group_ticket_mark_read(((select value ->> 'id' from feature_values where key = 'ticket'))::uuid) $$,
  'an organizer can mark the leader message as read'
);

set local role postgres;
select ok(
  exists (
    select 1 from app_private.group_support_ticket_messages
    where ticket_id = ((select value ->> 'id' from feature_values where key = 'ticket'))::uuid
      and sender_side = 'leader' and read_at is not null
  ),
  'the leader message stores its read receipt'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update feature_values set value = api.group_ticket_reply(
    ((value ->> 'id'))::uuid, (value ->> 'version')::integer,
    'Ja, het startmoment staat definitief vast.', 'ticket-reply', 'ticket-reply-hash'
  ) where key = 'ticket' $$,
  'an organizer can reply to the group leader'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where dedupe_key like 'group-ticket:%'),
  4,
  'an organizer reply again queues mail for both recipients'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.group_ticket_mark_read(((select value ->> 'id' from feature_values where key = 'ticket'))::uuid) $$,
  'the leader can mark the organization reply as read'
);

set local role postgres;
select ok(
  exists (
    select 1 from app_private.group_support_ticket_messages
    where ticket_id = ((select value ->> 'id' from feature_values where key = 'ticket'))::uuid
      and sender_side = 'organization' and read_at is not null
  ),
  'the organization reply stores the leader read receipt'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update feature_values set value = api.group_ticket_set_status(
    ((value ->> 'id'))::uuid, (value ->> 'version')::integer,
    'closed', 'Vraag is volledig beantwoord'
  ) where key = 'ticket' $$,
  'an organizer can close a resolved conversation'
);

select throws_ok(
  $$ select api.group_ticket_reply(
    ((select value ->> 'id' from feature_values where key = 'ticket'))::uuid,
    ((select value ->> 'version' from feature_values where key = 'ticket'))::integer,
    'Dit bericht mag niet meer worden geplaatst.', 'closed-reply', 'closed-reply-hash'
  ) $$,
  '40001', 'STALE_VERSION',
  'closed tickets reject new replies until explicitly reopened'
);
select is(
  api.admin_dashboard('duindorp-halloween-2026') #>> '{counts,openTickets}',
  '0',
  'closed tickets are not counted as open work'
);
select ok(
  has_function_privilege('authenticated', 'api.group_ticket_snapshot(uuid)', 'execute'),
  'authenticated clients reach the ticket authorization boundary only through RPC'
);
set local role postgres;
select ok(
  exists (select 1 from app_private.audit_events where action = 'group_ticket.created'),
  'ticket creation is present in the audit trail'
);

select * from finish();
rollback;
