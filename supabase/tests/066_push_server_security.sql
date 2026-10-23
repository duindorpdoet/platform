begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- Public P-256 generator point, with a synthetic all-zero auth salt. No push is sent.
create function pg_temp.push_fixture_key() returns text language sql immutable as $$
  select rtrim(translate(replace(encode(decode('046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5','hex'),'base64'),E'\n',''),'+/','-_'),'=')
$$;
grant execute on function pg_temp.push_fixture_key() to authenticated;
select ok(not has_function_privilege('anon','api.push_write_attempt()','execute'),'anonymous callers cannot debit or obtain account permits');
select ok(not has_function_privilege('authenticated','api.worker_push_target(uuid,uuid,text,uuid,uuid)','execute'),'participants cannot retrieve worker target keys');
select ok(not has_table_privilege('authenticated','app_private.push_subscriptions','insert'),'device admission cannot bypass the RPC guard');
select ok(app_private.valid_push_keys(pg_temp.push_fixture_key(),repeat('A',22)),'database verifies the real P-256 curve equation');
select ok(not app_private.valid_push_keys(rtrim(translate(replace(encode(decode('04'||repeat('00',64),'hex'),'base64'),E'\n',''),'+/','-_'),'='),repeat('A',22)),'an off-curve point of the correct length is rejected');
select ok(app_private.valid_push_endpoint('https://fcm.googleapis.com/fcm/send/fixture'),'Google exact origin admitted');
select ok(app_private.valid_push_endpoint('https://updates.push.services.mozilla.com/wpush/v2/fixture'),'Mozilla exact origin admitted');
select ok(app_private.valid_push_endpoint('https://web.push.apple.com/fixture'),'Apple exact origin admitted');
select ok(not app_private.valid_push_endpoint(endpoint),'unsafe endpoint blocked at storage: '||label)
from (values('http','http://fcm.googleapis.com/fcm/send/x'),('private IP','https://169.254.169.254/token'),
  ('IPv6','https://[::1]/token'),('lookalike','https://fcm.googleapis.com.attacker.invalid/token'),
  ('credentials','https://secret@fcm.googleapis.com/token'),('port','https://fcm.googleapis.com:444/token'),
  ('query','https://fcm.googleapis.com/token?secret=1'),('fragment','https://fcm.googleapis.com/token#x'),
  ('no device path','https://fcm.googleapis.com/'),('backslash',E'https://fcm.googleapis.com/a\\b'),
  ('control',E'https://fcm.googleapis.com/a\n'),('encoded backslash','https://fcm.googleapis.com/%5clocal')) cases(label,endpoint);

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.push_subscription_upsert('https://127.0.0.1/invalid','bad','bad')#>>'{error,code}','INVALID_SUBSCRIPTION','invalid direct RPC consumes an attempt and returns a safe failure') from generate_series(1,10);
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/eleventh',pg_temp.push_fixture_key(),repeat('A',22))#>>'{error,code}','PUSH_RATE_LIMIT','the eleventh write is denied even after ten invalid payloads');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/own-other-account',pg_temp.push_fixture_key(),repeat('A',22))->>'activeSubscriptionCount','1','rate quota belongs to the authenticated account');
set local role postgres;
select is((select count(*)::integer from app_private.push_write_permits where user_id='a0000000-0000-0000-0000-000000000001'),10,'invalid RPC debits persist instead of being rolled back');
delete from app_private.push_write_permits where user_id='a0000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/own-device-'||i,pg_temp.push_fixture_key(),repeat('A',22))->>'activeSubscriptionCount',i::text,'admit own device '||i) from generate_series(1,5) i;
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/own-device-6',pg_temp.push_fixture_key(),repeat('A',22))#>>'{error,code}','DEVICE_LIMIT_REACHED','a sixth active device is refused atomically');
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/own-device-1',pg_temp.push_fixture_key(),repeat('A',22))->>'activeSubscriptionCount','5','refreshing an existing device works at the five-device limit');
select ok(api.push_subscription_state()::text !~ '(endpoint|p256dh|auth_secret|fingerprint|fcm/send)','metadata contains no endpoint paths, keys or target fingerprints');
select is(api.push_subscription_upsert('https://fcm.googleapis.com/fcm/send/own-other-account',pg_temp.push_fixture_key(),repeat('A',22))#>>'{error,code}','ENDPOINT_OWNERSHIP_CONFLICT','one account cannot take over another account endpoint');
select is(api.push_subscription_delete('https://fcm.googleapis.com/fcm/send/own-other-account')->>'activeSubscriptionCount','5','deletion is scoped to the authenticated account');

set local role postgres;
create temporary table push_security_values as select s.id,app_private.push_target_fingerprint(s.endpoint,s.p256dh,s.auth_secret) fingerprint,
  (select id from app_private.push_subscriptions where endpoint='https://fcm.googleapis.com/fcm/send/own-other-account') other_id,
  (select app_private.push_target_fingerprint(endpoint,p256dh,auth_secret) from app_private.push_subscriptions where endpoint='https://fcm.googleapis.com/fcm/send/own-other-account') other_fingerprint
  from app_private.push_subscriptions s where endpoint='https://fcm.googleapis.com/fcm/send/own-device-1';
grant select on push_security_values to service_role;
set local role service_role;
select ok(api.worker_push_target(null,(select id from push_security_values),(select fingerprint from push_security_values),null,'c0000000-0000-0000-0000-000000000001') is null,'a target from another account is not released');
select is(api.worker_push_target(null,(select id from push_security_values),(select fingerprint from push_security_values),null,'a0000000-0000-0000-0000-000000000001')->>'subscriptionId',(select id::text from push_security_values),'a current own test device can pass revalidation');
set local role postgres;
update app_private.push_subscriptions set auth_secret=rtrim(translate(encode(decode(repeat('01',16),'hex'),'base64'),'+/','-_'),'=') where id=(select id from push_security_values);
set local role service_role;
select ok(api.worker_push_target(null,(select id from push_security_values),(select fingerprint from push_security_values),null,'a0000000-0000-0000-0000-000000000001') is null,'keys changed after claim cannot be sent with an old fingerprint');
set local role postgres;
update app_private.push_preferences set enabled=false where user_id='c0000000-0000-0000-0000-000000000001';
set local role service_role;
select ok(api.worker_push_target(null,(select other_id from push_security_values),(select other_fingerprint from push_security_values),null,'c0000000-0000-0000-0000-000000000001') is null,'revoked current preference never sends');
set local role postgres;
-- Simulate a pre-migration unsafe record, solely inside this rolled-back fixture.
alter table app_private.push_subscriptions disable trigger guard_push_subscription;
insert into app_private.push_subscriptions(id,user_id,endpoint,p256dh,auth_secret)
  values('66000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001','https://127.0.0.1/legacy',pg_temp.push_fixture_key(),repeat('A',22));
alter table app_private.push_subscriptions enable trigger guard_push_subscription;
insert into app_private.push_preferences(user_id,enabled) values('f0000000-0000-0000-0000-000000000001',true) on conflict(user_id) do update set enabled=true;
set local role service_role;
select is(api.worker_push_target(null,'66000000-0000-0000-0000-000000000001','irrelevant',null,'f0000000-0000-0000-0000-000000000001')->>'blocked','true','old unsafe destinations are quarantined before a send can be authorized');
set local role postgres;
select is((select active from app_private.push_subscriptions where id='66000000-0000-0000-0000-000000000001'),false,'unsafe legacy record is inactive after revalidation');
select * from finish();
rollback;
