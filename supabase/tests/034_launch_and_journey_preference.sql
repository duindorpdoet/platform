begin;
create extension if not exists pgtap with schema extensions;
select plan(13);
select ok(not has_function_privilege('authenticated', 'api.configure_release_mode(text,text)', 'execute'), 'participants cannot open a release');
select ok(not has_function_privilege('anon', 'api.group_journey_preference(uuid)', 'execute'), 'anonymous users cannot read group preference');
select ok(not has_function_privilege('authenticated', 'app_private.dispatch_next_stop_before_visit_preference(uuid,timestamptz,boolean,uuid)', 'execute'), 'participants cannot bypass the preference dispatcher');
update app_private.events set settings = settings || '{"groupRegistrationOpen":false,"portalRegistrationOpen":false,"releaseMode":"production_closed"}'::jsonb;
select is(api.configure_release_mode('duindorp-halloween-2026', 'production_open')->>'groupRegistrationOpen', 'true', 'explicit live release opens participant registration');
select is(api.configure_release_mode('duindorp-halloween-2026', 'production_open')->>'portalRegistrationOpen', 'false', 'live opening preserves separate house-channel setting');
update app_private.events set settings = settings || '{"groupRegistrationOpen":false}'::jsonb;
select is(api.configure_release_mode('duindorp-halloween-2026', 'production_open')->>'groupRegistrationOpen', 'false', 'redeploy respects a subsequent organizer closure');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',1,3)$$,
  '23514','DYNAMIC_JOURNEY_REQUIRED','legacy routes cannot accept an unsupported visit limit');
set local role postgres;
update app_private.walking_groups set route_mode='dynamic' where id='23000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',1,3)$$,
  '42501','NOT_AUTHORIZED','only the leader can set the shared visit preference');
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',1,0)$$,
  '22023','INVALID_VISIT_PREFERENCE','zero houses is not accepted as a numeric preference');
select is(api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',1,3)->>'desiredOrdinaryVisits','3','leader saves optional maximum');
select throws_ok($$select api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',1,8)$$,
  '40001','STALE_VERSION','stale preference cannot overwrite another change');
select is(api.group_journey_preference_save('23000000-0000-0000-0000-000000000001',2,null)->'desiredOrdinaryVisits','null'::jsonb,'leader can restore continuous route');
select ok(not (api.group_journey_preference('23000000-0000-0000-0000-000000000001') ? 'start'), 'preference endpoint contains no start address');
select * from finish();
rollback;
