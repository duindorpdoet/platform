begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

select ok(not has_function_privilege('anon', 'api.push_subscription_state()', 'execute'),
  'anonymous visitors cannot inspect push preferences');
select ok(not has_function_privilege('anon', 'api.push_subscription_upsert(text,text,text,text,text)', 'execute'),
  'anonymous visitors cannot store a push endpoint');
select ok(not has_function_privilege('authenticated', 'api.push_test_targets_for_user(uuid)', 'execute'),
  'browser users cannot enumerate push delivery targets');
select ok(not has_function_privilege('authenticated', 'api.push_subscription_delivery_record(text,boolean,text,boolean)', 'execute'),
  'browser users cannot forge push delivery state');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(api.push_subscription_state() ->> 'enabled', 'false', 'push is opt-in and starts disabled');
select lives_ok($$select api.push_preference_set(true)$$, 'the account can explicitly opt in');
select lives_ok($$select api.push_subscription_upsert(
  'https://push.example.test/subscriptions/account-one-device',
  repeat('p', 32), repeat('a', 16), 'pgTAP browser', 'test device'
)$$, 'the account can store its own browser subscription');
select is(api.push_subscription_state() ->> 'activeSubscriptionCount', '1', 'the active device is counted');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select api.push_subscription_delete(
  'https://push.example.test/subscriptions/account-one-device'
)$$, 'another account receives no endpoint existence oracle');
reset role;

select is((select user_id::text from app_private.push_subscriptions where endpoint = 'https://push.example.test/subscriptions/account-one-device'),
  'a0000000-0000-0000-0000-000000000001', 'another account cannot remove or claim the endpoint by deleting it');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select api.push_preference_set(false)$$, 'the account can switch push off');
reset role;
select is((select active::text from app_private.push_subscriptions where endpoint = 'https://push.example.test/subscriptions/account-one-device'),
  'false', 'opting out deactivates account subscriptions');

select * from finish();
rollback;
