begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Reproduce the incident: the organizer switch is open but the deadline passed.
update app_private.events set registration_open_at = now() - interval '1 month',
  registration_close_at = now() - interval '1 day',
  settings = settings || '{"groupRegistrationOpen":true,"portalRegistrationOpen":false}'
where slug = 'duindorp-halloween-2026';
select is(api.event_public_snapshot('duindorp-halloween-2026')->>'groupRegistrationOpen', 'false',
  'an expired window overrides the switch before an explicit reopening');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.registration_submit('duindorp-halloween-2026','terms-2026-v1','privacy-2026-v1','window-closed','window-closed')$$,
  'P0001', 'REGISTRATION_CLOSED', 'submission also rejects the expired window');
select throws_ok($$select api.admin_set_registration_channel('duindorp-halloween-2026','groups',true,1,'Unauthorized reopening attempt')$$,
  '42501', 'NOT_AUTHORIZED', 'a parent cannot clear the deadline');

reset role;
create temp table channel_version as select settings_version as version from app_private.events where slug='duindorp-halloween-2026';
grant select, update on channel_version to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$update channel_version set version=(api.admin_set_registration_channel('duindorp-halloween-2026','groups',true,version,'Open registrations again after the old deadline')->>'settingsVersion')::integer$$,
  'an authorized opening clears the expired deadline');
select is(api.event_public_snapshot('duindorp-halloween-2026')->>'groupRegistrationOpen', 'true', 'visitors immediately see the open channel');
select is(api.event_public_snapshot('duindorp-halloween-2026')->>'portalRegistrationOpen', 'false', 'reopening groups preserves the portal closure');

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.registration_save_draft('duindorp-halloween-2026',
  '{"adult":{"name":"Testouder","phone":"0612345678"},"children":[{"name":"Testkind","age":"8"}],"startPreference":"indifferent","marketingConsent":false}',null)$$,
  'the reopened channel accepts a parent draft');
select lives_ok($$select api.registration_submit('duindorp-halloween-2026','terms-2026-v1','privacy-2026-v1','window-open','window-open')$$,
  'the reopened channel accepts an actual registration');

reset role;
select ok(exists(select 1 from app_private.audit_events where action='registration_channel.updated'
  and minimal_change->'registrationWindow'->>'previousCloseAt' is not null
  and minimal_change->'registrationWindow'->>'closeAt' is null), 'the removed deadline is audited');
update app_private.events set registration_open_at=now()+interval '1 day', registration_close_at=now()+interval '10 days'
where slug='duindorp-halloween-2026';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$update channel_version set version=(api.admin_set_registration_channel('duindorp-halloween-2026','groups',true,version,'Open now rather than at the future opening time')->>'settingsVersion')::integer$$,
  'explicit opening also clears a future opening time');
reset role;
select ok((select registration_open_at is null and registration_close_at=now()+interval '10 days' from app_private.events where slug='duindorp-halloween-2026'),
  'a valid future closing time is preserved');

-- Repair precisely the generated deadline, never a custom deadline or closure.
update app_private.events set local_date=make_date(extract(year from now())::integer+1,10,31), phase='registration_open',
  settings=settings||'{"releaseMode":"production_open","groupRegistrationOpen":true}',
  registration_open_at=now()-interval '1 day', registration_close_at=now()-interval '1 hour'
where slug='duindorp-halloween-2026';
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_open')$$, 'ordinary redeploy with a custom deadline succeeds');
select ok((select registration_close_at=now()-interval '1 hour' from app_private.events where slug='duindorp-halloween-2026'), 'redeploy preserves an intentional custom expired deadline');

-- Before October 25 the generated deadline is still valid; afterwards the
-- repair must remove it from an upcoming event that the organizer left open.
update app_private.events set local_date=greatest((now() at time zone timezone)::date,make_date(extract(year from now())::integer,10,31)),
  registration_open_at=null, registration_close_at=make_timestamptz(extract(year from now())::integer,10,25,23,59,0,timezone)
where slug='duindorp-halloween-2026';
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_open')$$, 'redeploy checks the legacy generated deadline');
select ok((select registration_close_at is null or registration_close_at>now() from app_private.events where slug='duindorp-halloween-2026'),
  'the legacy generated deadline cannot silently keep an upcoming open event closed');
create temp table repaired_event as select to_jsonb(e) value from app_private.events e where slug='duindorp-halloween-2026';
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_open')$$, 'the following redeploy succeeds');
select is((select to_jsonb(e) from app_private.events e where slug='duindorp-halloween-2026'),(select value from repaired_event), 'deadline repair is idempotent');

select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_closed')$$, 'explicit release closure still works');
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_open')$$, 'explicit release opening still works');
select ok((select registration_close_at is null from app_private.events where slug='duindorp-halloween-2026'), 'new openings no longer invent an October 25 deadline');

select * from finish();
rollback;
