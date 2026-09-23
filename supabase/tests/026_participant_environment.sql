begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

select ok((select relrowsecurity from pg_class where oid = 'app_private.group_viewer_invites'::regclass), 'viewer invites have RLS defense in depth');
select ok((select relrowsecurity from pg_class where oid = 'app_private.group_viewer_access'::regclass), 'viewer access has RLS defense in depth');
select ok((select relrowsecurity from pg_class where oid = 'app_private.participant_updates'::regclass), 'participant updates have RLS defense in depth');
select ok(not has_table_privilege('authenticated', 'app_private.group_viewer_access', 'select'), 'browser cannot query viewer access directly');
select ok(not has_function_privilege('anon', 'api.group_viewer_snapshot(uuid)', 'execute'), 'anonymous visitors cannot inspect viewer progress');
select ok(has_function_privilege('authenticated', 'api.participant_context(text)', 'execute'), 'authenticated users can discover only their own roles');

create temporary table participant_feature_values(key text primary key, value jsonb not null) on commit drop;
grant select, insert, update on participant_feature_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.group_viewer_invite_create('23000000-0000-0000-0000-000000000001', 'parent-b@example.invalid', null) $$,
  '42501', 'NOT_AUTHORIZED',
  'an ordinary adult cannot invite a group viewer'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.group_viewer_invite_create('23000000-0000-0000-0000-000000000001', 'parent-b@example.invalid', now() + interval '7 days') $$,
  'the current leader can create addressed, expiring viewer access'
);

set local role postgres;
insert into participant_feature_values
select 'viewer-token', jsonb_build_object('token', payload ->> 'inviteToken', 'inviteId', split_part(recipient_ref, ':', 2))
from app_private.email_outbox where message_type = 'group_viewer_invite' order by created_at desc limit 1;
select is((select count(*)::integer from app_private.email_outbox where message_type = 'group_viewer_invite'), 1, 'viewer invitation queues a SendGrid outbox message');
select ok((select (value ->> 'token') ~ '^[a-f0-9]{64}$' from participant_feature_values where key = 'viewer-token'), 'viewer token is high entropy and only present in the private outbox payload');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.group_viewer_invite_accept((select value ->> 'token' from participant_feature_values where key = 'viewer-token')) $$,
  '42501', 'RECIPIENT_MISMATCH',
  'an addressed invitation cannot be accepted by another account'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into participant_feature_values values ('viewer-access', api.group_viewer_invite_accept((select value ->> 'token' from participant_feature_values where key = 'viewer-token'))) $$,
  'the addressed account can accept the viewer invitation'
);
select is(
  api.participant_context('duindorp-halloween-2026') #>> '{roles,0,key}',
  'viewer',
  'accepted viewer access appears as a distinct role'
);
set local role postgres;
insert into app_private.portal_owners(portal_id, user_id)
values ('12000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.participant_context('duindorp-halloween-2026') -> 'roles'),
  2,
  'an account can hold two deliberate participant roles'
);
select is(
  api.participant_context('duindorp-halloween-2026') #>> '{roles,1,key}',
  'homeowner',
  'multi-role context keeps the homeowner experience separately selectable'
);
set local role postgres;
delete from app_private.portal_owners
where portal_id = '12000000-0000-0000-0000-000000000001' and user_id = 'b0000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.group_viewer_snapshot('23000000-0000-0000-0000-000000000001') $$,
  'an active viewer can load the redacted progress snapshot'
);
select ok(
  api.group_viewer_snapshot('23000000-0000-0000-0000-000000000001')::text !~ '(Testkind|NIET-BESTAAND|Testpoort)',
  'viewer snapshot contains no child names, private address, or portal names'
);
select throws_ok(
  $$ select api.group_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED',
  'viewer access does not grant the richer participant group snapshot'
);
select throws_ok(
  $$ select api.group_viewer_access_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED',
  'a viewer cannot list other viewer identities'
);

select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.group_viewer_access_snapshot('23000000-0000-0000-0000-000000000001') -> 'active'),
  1,
  'the leader can manage the one active viewer'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ insert into participant_feature_values values ('update', api.admin_publish_participant_update(
    'duindorp-halloween-2026', 'viewer', 'Veilige voortgang',
    'De groep is vertrokken; alleen bevestigde wereldstappen worden gedeeld.', 'important', true
  )) $$,
  'an authorized organizer can publish a role-specific update'
);
select is(
  (select (value ->> 'emailCount')::integer from participant_feature_values where key = 'update'),
  1,
  'publishing a viewer update queues one opted-in viewer email'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length(api.participant_updates_snapshot('duindorp-halloween-2026', 'viewer')),
  1,
  'viewer sees the role-specific update'
);
select lives_ok(
  $$ select api.participant_update_mark_read(((api.participant_updates_snapshot('duindorp-halloween-2026', 'viewer') -> 0 ->> 'id'))::uuid) $$,
  'viewer can mark an authorized update as read'
);
select ok(
  api.participant_updates_snapshot('duindorp-halloween-2026', 'viewer') -> 0 ->> 'readAt' is not null,
  'read state persists per account'
);
select lives_ok(
  $$ select api.participant_profile_snapshot('duindorp-halloween-2026') $$,
  'viewer can load private profile and preference data'
);
select lives_ok(
  $$ select api.participant_profile_update('duindorp-halloween-2026', 'Meekijker Test', false, true, true, false, 1) $$,
  'viewer can update display and accessibility preferences with optimistic locking'
);

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.participant_context('duindorp-halloween-2026') #>> '{roles,0,key}',
  'homeowner',
  'a portal owner receives the homeowner role'
);
select is(
  api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000001') ->> 'expectedTotal',
  '23',
  'homeowner cockpit aggregates expected children across published plans'
);
select ok(
  api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000001')::text !~ 'Testkind',
  'planned arrival windows never expose child names'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.portal_arrivals_snapshot('12000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED',
  'a group viewer cannot inspect homeowner arrival planning'
);
select lives_ok(
  $$ select api.group_viewer_access_revoke(((select value ->> 'accessId' from participant_feature_values where key = 'viewer-access'))::uuid, 'Contracttest trekt toegang in') $$,
  'a viewer can revoke their own access'
);
select is(
  jsonb_array_length(api.participant_context('duindorp-halloween-2026') -> 'roles'),
  0,
  'revoked viewer access disappears immediately from role discovery'
);
select throws_ok(
  $$ select api.group_viewer_snapshot('23000000-0000-0000-0000-000000000001') $$,
  '42501', 'NOT_AUTHORIZED',
  'revoked viewer access can no longer read progress'
);

select * from finish();
rollback;
