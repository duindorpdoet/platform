begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table release_before(value jsonb);
update app_private.events set phase='draft',registration_open_at=now()-interval '2 years',registration_close_at=now()-interval '1 year',
 settings=settings||'{"releaseMode":"staging_test_open","registrationPublished":true,"groupRegistrationOpen":false,"portalRegistrationOpen":false}' where slug='duindorp-halloween-2026';
insert into release_before select to_jsonb(e) from app_private.events e where slug='duindorp-halloween-2026';
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','staging_test_open')$$,'staging redeploy succeeds after the historical registration deadline');
select is((select to_jsonb(e) from app_private.events e where slug='duindorp-halloween-2026'),(select value from release_before),'staging redeploy preserves dates, operator phase, channel closure and settings version exactly');
update app_private.events set settings=settings||'{"releaseMode":"production_open"}' where slug='duindorp-halloween-2026';
truncate release_before;insert into release_before select to_jsonb(e) from app_private.events e where slug='duindorp-halloween-2026';
select lives_ok($$select api.configure_release_mode('duindorp-halloween-2026','production_open')$$,'production redeploy retains the existing deadline rather than reopening enrollment');
select is((select to_jsonb(e) from app_private.events e where slug='duindorp-halloween-2026'),(select value from release_before),'production redeploy preserves all existing release control data');
select is(api.configure_release_mode('duindorp-halloween-2026','production_closed')->>'registrationPublished','false','explicit mode transition still applies the existing closure contract');
select throws_ok($$select api.configure_release_mode('duindorp-halloween-2026','invented')$$,'22023','INVALID_MODE','invalid release mode remains rejected');
select ok(not has_function_privilege('authenticated','api.configure_release_mode(text,text)','execute') and not has_function_privilege('anon','api.configure_release_mode(text,text)','execute'),'participants cannot modify release configuration');
select ok(has_function_privilege('service_role','api.configure_release_mode(text,text)','execute'),'existing trusted deployment service retains its authority');
select * from finish();
rollback;
