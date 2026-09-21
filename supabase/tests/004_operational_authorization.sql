begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

select ok(not has_function_privilege('anon', 'api.admin_dashboard(text)', 'execute'), 'admin dashboard is not public');
select ok(not has_function_privilege('anon', 'api.portal_snapshot(text)', 'execute'), 'portal dashboard is not public');
select ok(not has_function_privilege('authenticated', 'api.submit_public_contact(text,text,text,text,text,text)', 'execute'), 'public contact writer is server-only');
select ok(not has_function_privilege('authenticated', 'api.bootstrap_first_admin(text,text)', 'execute'), 'admin bootstrap is never available to browsers');
select ok(has_function_privilege('service_role', 'api.bootstrap_first_admin(text,text)', 'execute'), 'admin bootstrap is restricted to the service role');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$ select api.admin_dashboard('duindorp-halloween-2026') $$, 'event admin can read dashboard');
select lives_ok($$ select api.admin_planning_snapshot('duindorp-halloween-2026') $$, 'groups manager can read planning inputs');

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$ select api.admin_dashboard('duindorp-halloween-2026') $$, '42501', 'NOT_AUTHORIZED', 'ordinary parent cannot read dashboard');
select throws_ok($$ select api.group_roster('23000000-0000-0000-0000-000000000001') $$, '42501', 'NOT_AUTHORIZED', 'unrelated household cannot read pre-run roster');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$ select api.group_roster('23000000-0000-0000-0000-000000000001') $$, '42501', 'NOT_AUTHORIZED', 'participating parent cannot enumerate other households in roster');

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(api.portal_snapshot('duindorp-halloween-2026') -> 'portal' is not null, 'portal owner can read own operational dashboard');

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(api.portal_snapshot('duindorp-halloween-2026'), null::jsonb, 'unrelated user receives no portal data');

select * from finish();
rollback;
