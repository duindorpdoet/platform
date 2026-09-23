begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

create temporary table registration_channel_state(version integer) on commit drop;
insert into registration_channel_state
select settings_version from app_private.events where slug = 'duindorp-halloween-2026';
grant select, update on registration_channel_state to authenticated;

select ok(
  not has_function_privilege('anon', 'api.admin_set_registration_channel(text,text,boolean,integer,text)', 'execute'),
  'anonymous visitors cannot change registration channels'
);

set local role anon;
select is(
  api.event_public_snapshot('duindorp-halloween-2026')->>'groupRegistrationOpen',
  'true',
  'the local fixture publishes group registration as open'
);
select is(
  api.event_public_snapshot('duindorp-halloween-2026')->>'portalRegistrationOpen',
  'true',
  'the local fixture publishes portal registration as open'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_set_registration_channel('duindorp-halloween-2026', 'groups', false, (select version from registration_channel_state), 'Onbevoegde poging om kanaal te sluiten') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary parent cannot change a registration channel'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_channel_state set version = (api.admin_set_registration_channel('duindorp-halloween-2026', 'groups', false, version, 'Eerst verzamelen we voldoende deelnemende locaties')->>'settingsVersion')::integer $$,
  'an event admin can close group registration independently'
);

set local role anon;
select is(
  api.event_public_snapshot('duindorp-halloween-2026')->>'groupRegistrationOpen',
  'false',
  'closing groups is immediately visible in the public projection'
);
select is(
  api.event_public_snapshot('duindorp-halloween-2026')->>'portalRegistrationOpen',
  'true',
  'closing groups leaves portal applications open'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.registration_submit('duindorp-halloween-2026', 'terms-test', 'privacy-test', 'closed-groups', 'closed-groups-hash') $$,
  'P0001', 'REGISTRATION_CLOSED', 'the database rejects group submissions while that channel is closed'
);
select lives_ok(
  $$ select api.portal_application_save('duindorp-halloween-2026', '{"contactName":"Testbewoner","address":{"street":"Teststraat","houseNumber":"1"}}'::jsonb, null) $$,
  'portal applicants can still save while only groups are closed'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_channel_state set version = (api.admin_set_registration_channel('duindorp-halloween-2026', 'portals', false, version, 'Tijdelijk is de beschikbare routecapaciteit bereikt')->>'settingsVersion')::integer $$,
  'an event admin can close portal applications independently'
);

set local role anon;
select is(
  api.event_public_snapshot('duindorp-halloween-2026')->>'portalRegistrationOpen',
  'false',
  'closing portals is immediately visible in the public projection'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.portal_application_save('duindorp-halloween-2026', '{"contactName":"Tweede bewoner","address":{"street":"Teststraat","houseNumber":"2"}}'::jsonb, null) $$,
  'P0001', 'PORTAL_REGISTRATION_CLOSED', 'the database rejects portal drafts while that channel is closed'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_set_registration_channel('duindorp-halloween-2026', 'groups', true, 1, 'Deze versie is expres verouderd voor de test') $$,
  '40001', 'STALE_VERSION', 'stale admin screens cannot overwrite newer channel settings'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.audit_events where action = 'registration_channel.updated'),
  2,
  'each successful channel change is written to the audit log'
);

select * from finish();
rollback;
