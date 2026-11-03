-- No external delivery, API requests or live payments. All fixtures roll back.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
create temp table fn_test_state(key text primary key,value jsonb);
create function pg_temp.fn_cmd(cmd text,body jsonb default '{}',key uuid default gen_random_uuid()) returns jsonb language sql as $$select api.frightnight_command('frightnight-2027-test',cmd,body,key)$$;
create function pg_temp.fn_pay(actor uuid) returns jsonb language plpgsql as $$declare o jsonb; begin
 o:=api.frightnight_payment_create('frightnight-2027-test',actor,gen_random_uuid());
 perform api.frightnight_payment_bind('frightnight-2027-test',(o->>'order_id')::uuid,'ct_'||(o->>'order_id'),null);
 return api.frightnight_payment_confirm('frightnight-2027-test','ct_'||(o->>'order_id'),'paid',(o->>'amount_cents')::integer,'EUR','test-paid:'||(o->>'order_id'),jsonb_build_object('order_id',o->>'order_id','event_id',o->>'event_id','testmode',true,'environment','staging'));
end$$;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values
 ('f7270000-0000-0000-0000-000000000001','fn-admin@example.invalid',now(),'{}','{}'),
 ('f7270000-0000-0000-0000-000000000002','fn-family-a@example.invalid',now(),'{}','{}'),
 ('f7270000-0000-0000-0000-000000000003','fn-family-b@example.invalid',now(),'{}','{}');
insert into app_private.events(id,slug,title,local_date,price_cents) values('f7270000-0000-0000-0000-000000000010','fn-legacy-protected-2026','Protected legacy fixture',date '2026-10-31',350);
insert into app_private.event_capabilities(event_id,user_id,capability) values('f7270000-0000-0000-0000-000000000010','f7270000-0000-0000-0000-000000000001','event_admin');
insert into fn_test_state values('legacy-counts',jsonb_build_object('payments',(select count(*) from app_private.payment_requests),'outbox',(select count(*) from app_private.email_outbox),'groups',(select count(*) from app_private.walking_groups)));
select throws_ok($$select api.frightnight_bootstrap('frightnight-2027-test','f7270000-0000-0000-0000-000000000001','production','nocteiuvohesvqbowchw:staging:duindorphalloweenstg')$$,'42501','VERIFIED_STAGING_BINDING_REQUIRED','production cannot bootstrap a test edition');
select lives_ok($$select api.frightnight_bootstrap('frightnight-2027-test','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg')$$,'verified isolated edition can bootstrap');
select lives_ok($proof$do $block$ begin
 begin
  perform api.frightnight_initialize('frightnight-2027-test','f7270000-0000-0000-0000-000000000001','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
  if (select count(*) from app_private.fn_registrations where synthetic)<>4 then raise exception 'INITIALIZE_BAD_SYNTHETIC_COUNT'; end if;
  perform api.frightnight_initialize('frightnight-2027-test','f7270000-0000-0000-0000-000000000001','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
  if (select count(*) from app_private.fn_registrations where synthetic)<>4 or exists(select 1 from app_private.fn_registrations where synthetic and household_id is not null) then raise exception 'INITIALIZE_NOT_ISOLATED_OR_IDEMPOTENT'; end if;
  raise exception 'ROLLBACK_INITIALIZE_PROBE' using errcode='Z0001';
 exception when sqlstate 'Z0001' then null;
 end;
end $block$;$proof$,'service initialize seeds only ownerless synthetic data and is idempotent without impersonation');
select ok(not has_function_privilege('authenticated','api.frightnight_initialize(text,uuid,text)','EXECUTE'),'initialization is service-only');
select ok(not has_function_privilege('authenticated','api.frightnight_payment_confirm(text,text,text,integer,text,text,jsonb)','EXECUTE'),'browser cannot confirm payment');
select ok(not has_function_privilege('anon','api.frightnight_snapshot(text)','EXECUTE'),'anonymous actor cannot read personal snapshots');
select ok(not has_table_privilege('authenticated','app_private.fn_registrations','SELECT'),'private tables are not directly exposed');
select ok(not exists(select 1 from pg_tables where schemaname='app_private' and tablename like 'fn\_%' and not rowsecurity),'all new tables have RLS');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into fn_test_state select 'seed',pg_temp.fn_cmd('test.seed')->'result';
insert into fn_test_state select 'rotated-zone-code',pg_temp.fn_cmd('zone.qr',jsonb_build_object('zoneId',(select id from app_private.fn_zones where intensity=4)))->'result';
select is((pg_temp.fn_cmd('qr.issue',jsonb_build_object('zoneId',(select id from app_private.fn_zones where intensity=4)))->'result'->>'token'),(select value->>'code' from fn_test_state where key='rotated-zone-code'),'printing after a zone rotation preserves the exact newly returned credential');
select ok((select token_hash from app_private.fn_zones where intensity=4) is distinct from extensions.digest((select z->>'code' from fn_test_state s cross join lateral jsonb_array_elements(s.value->'zoneCodes')z where s.key='seed' and (z->>'zoneId')::uuid=(select id from app_private.fn_zones where intensity=4)),'sha256'),'rotated zone rejects the previous printed credential');
select is((select count(*) from app_private.fn_registrations where synthetic),4::bigint,'seed creates isolated synthetic families with no historical households');
select is((select count(*) from app_private.fn_registrations where synthetic and household_id is not null),0::bigint,'synthetic families never use existing households');
select is((select count(*) from app_private.fn_quests),6::bigint,'three riddles and three games are server configured');
select is((select count(*) from app_private.fn_walk_edges where verified),0::bigint,'seed never invents verified walking routes');
-- Timed resident pause is evaluated by the same server policy as routing.
select pg_temp.fn_cmd('zone.status',jsonb_build_object('zoneId',(select id from app_private.fn_zones where type='candy'),'expectedVersion',1,'status','paused','pauseUntil','2027-10-30T17:10:00+02:00','reason','Even rust'));
select is((select app_private.fn_zone_status(id) from app_private.fn_zones where type='candy'),'paused','timed pause blocks new arrivals before its end');
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T17:11:00+02:00"}');
select is((select app_private.fn_zone_status(id) from app_private.fn_zones where type='candy'),'open','expired pause can reopen only within approved opening hours');
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T21:45:00+02:00"}');
select is((select app_private.fn_zone_status(id) from app_private.fn_zones where type='candy'),'paused','expired pause does not reopen a zone outside its hours');
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T17:05:00+02:00"}');
select pg_temp.fn_cmd('zone.status',jsonb_build_object('zoneId',(select id from app_private.fn_zones where type='candy'),'expectedVersion',2,'status','open'));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('registration.save','{"label":"No consent family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1}')$$,'22023','REGISTRATION_CONSENT_REQUIRED','new signup requires explicit current test terms consent');
insert into fn_test_state select 'registration-a',pg_temp.fn_cmd('registration.save','{"label":"Family A","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":2,"stepFree":true}')->'snapshot';
select is((select (value#>>'{registration,amountCents}')::integer from fn_test_state where key='registration-a'),700,'server calculates full-person integer price');
select throws_ok($$select pg_temp.fn_cmd('journey.start','{"expectedVersion":1}')$$,'42501','PAID_REGISTRATION_REQUIRED','unpaid families cannot start');
select throws_ok($$select pg_temp.fn_cmd('test.seed')$$,'42501','NOT_AUTHORIZED','participants cannot seed data');
select throws_ok($$select pg_temp.fn_cmd('zone.status',jsonb_build_object('zoneId',(select id from app_private.fn_zones where type='candy'),'status','closed','expectedVersion',1))$$,'42501','NOT_AUTHORIZED','NULL-owned synthetic zone does not bypass resident authorization');
insert into fn_test_state select 'order-a',pg_temp.fn_pay('f7270000-0000-0000-0000-000000000002');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,paymentStatus}'),'paid','only provider confirmation activates registration');
select is((select count(*) from app_private.fn_mail_sink),1::bigint,'payment queues exactly one isolated sink confirmation');
select lives_ok($$select api.frightnight_payment_confirm('frightnight-2027-test',(select value->>'provider_ref' from fn_test_state where key='order-a'),'paid',700,'EUR',(select 'test-paid:'||(value->>'order_id') from fn_test_state where key='order-a'),(select jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging') from fn_test_state where key='order-a'))$$,'duplicate webhook is idempotent');
select is((select count(*) from app_private.fn_ledger where kind='receipt'),1::bigint,'duplicate webhook never doubles ledger');
select throws_ok($$select api.frightnight_payment_confirm('frightnight-2027-test',(select value->>'provider_ref' from fn_test_state where key='order-a'),'paid',1,'EUR','wrong-amount',(select jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging') from fn_test_state where key='order-a'))$$,'22023','PROVIDER_CONFIRMATION_MISMATCH','provider amount mismatch is rejected');
select lives_ok($$select api.frightnight_payment_confirm('frightnight-2027-test',(select value->>'provider_ref' from fn_test_state where key='order-a'),'open',700,'EUR','late-open',(select jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging') from fn_test_state where key='order-a'))$$,'out-of-order open is accepted without state regression');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,paymentStatus}','paid','paid never regresses to open');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select pg_temp.fn_cmd('registration.save','{"label":"Family B","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"avoidSmoke":true}');
select pg_temp.fn_pay('f7270000-0000-0000-0000-000000000003');
select lives_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002'),'f7270000-0000-0000-0000-000000000166','Synthetic refund intent only')$$,'finance creates a durable scoped refund intent');
select lives_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002'),'f7270000-0000-0000-0000-000000000166','Synthetic refund intent only')$$,'identical refund intent retry returns same order');
select throws_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000003'),'f7270000-0000-0000-0000-000000000166','Synthetic refund intent only')$$,'40001','IDEMPOTENCY_CONFLICT','refund key reuse for a different registration cannot refund the previous household');
select throws_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002'),'f7270000-0000-0000-0000-000000000167','A second full refund must not reach provider')$$,'40001','REFUND_ALREADY_REQUESTED','different command IDs cannot claim a second full refund for one paid order');
select is((select count(*) from app_private.fn_refunds),1::bigint,'refund contention leaves exactly one durable provider intent');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select (value->>'order_id')::uuid from fn_test_state where key='order-a'),'re_fixture','invented','f7270000-0000-0000-0000-000000000166','Synthetic refund intent only')$$,'22023','INVALID_REFUND_STATE','invalid refund state cannot release the provider claim');
select lives_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select (value->>'order_id')::uuid from fn_test_state where key='order-a'),'re_fixture','failed','f7270000-0000-0000-0000-000000000166','Synthetic refund intent only')$$,'verified provider failure is durably recorded before releasing a claim');
select lives_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002'),'f7270000-0000-0000-0000-000000000167','Retry after verified provider failure')$$,'a new intent is possible only after the previous provider failure is recorded');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,label}','Family B','second actor sees only own registration');
select ok(not(api.frightnight_snapshot('frightnight-2027-test')?'registrations'),'participant snapshot contains no regie roster');
select throws_ok($$select pg_temp.fn_cmd('journey.start',jsonb_build_object('expectedVersion',1,'code','wrong'))$$,'22023','INVALID_START_CODE','invalid start token is rejected');
-- Approved walk links are explicit fixtures, never represented as real geography.
insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,verified)
 select a.event_id,a.id,b.id,2,true from app_private.fn_zones a join app_private.fn_zones b on b.event_id=a.event_id and b.id<>a.id;
update app_private.fn_zones set capacity=2 where type='candy';
insert into fn_test_state select 'start-b',pg_temp.fn_cmd('journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='seed')),'f7270000-0000-0000-0000-000000000111');
update app_private.fn_walk_edges set source='synthetic-fixture',geometry='{"type":"LineString","coordinates":[[4.2593,52.0949],[4.2598,52.0952]]}'::jsonb;
select is(api.frightnight_walk('frightnight-2027-test',(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='start-b'))->>'source','synthetic-fixture','synthetic walking geometry is never labelled organisation verified');
select is(api.frightnight_walk('frightnight-2027-test',(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='start-b'))->>'available','false','synthetic geometry cannot become an available street instruction');
select is(api.frightnight_walk('frightnight-2027-test',(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='start-b'))->'geometry','null'::jsonb,'synthetic walking geometry is withheld from personal route responses');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into fn_test_state select 'walk-verification',jsonb_build_object('fromZoneId',(select id from app_private.fn_zones where type='finale'),'toZoneId',(select value#>>'{snapshot,current,zoneId}' from fn_test_state where key='start-b'),'minutes',2,'verified',true,'reason','Explicit controlled geometry validation fixture');
select throws_ok($$select pg_temp.fn_cmd('admin.walk.verify',(select value||'{"geometry":{"type":"Polygon","coordinates":[]}}'::jsonb from fn_test_state where key='walk-verification'))$$,'22023','INVALID_DUINDORP_WALK_GEOMETRY','walk verification rejects non-LineString geometry');
select throws_ok($$select pg_temp.fn_cmd('admin.walk.verify',(select value||'{"geometry":{"type":"LineString","coordinates":[[4.25,52.09],[5,50]]}}'::jsonb from fn_test_state where key='walk-verification'))$$,'22023','INVALID_DUINDORP_WALK_GEOMETRY','walk geometry cannot leave the bounded Duindorp region');
select throws_ok($$select pg_temp.fn_cmd('admin.walk.verify',(select value||'{"geometry":{"type":"LineString","coordinates":[[4.25,52.09]]}}'::jsonb from fn_test_state where key='walk-verification'))$$,'22023','INVALID_DUINDORP_WALK_GEOMETRY','walk geometry needs at least two points');
select lives_ok($$select pg_temp.fn_cmd('admin.walk.verify',(select value||'{"geometry":{"type":"LineString","coordinates":[[4.2593,52.0949],[4.2598,52.0952]]}}'::jsonb from fn_test_state where key='walk-verification'))$$,'authorized reviewed walking geometry can replace a synthetic fixture edge');
select is((select w.source from app_private.fn_walk_edges w where w.from_zone_id=(select (value->>'fromZoneId')::uuid from fn_test_state where key='walk-verification') and w.to_zone_id=(select (value->>'toZoneId')::uuid from fn_test_state where key='walk-verification')),'organisation-verified','reverification updates an existing fixture source as well as its geometry');
select ok(app_private.fn_walk_geometry_valid(null),'a missing path remains unavailable rather than fabricated');
select ok(not app_private.fn_walk_geometry_valid(jsonb_build_object('type','LineString','coordinates',(select jsonb_agg(jsonb_build_array(4.25,52.09)) from generate_series(1,5001)))),'walk validation bounds coordinate count at five thousand');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(api.frightnight_walk('frightnight-2027-test',(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='start-b'))->>'source','organisation-verified','current-destination endpoint returns the actual reviewed edge source');
select is((select value#>>'{snapshot,current,zone,type}' from fn_test_state where key='start-b'),'candy','first valid scan reserves suitable low-intensity zone');
select is((select sum(persons) from app_private.fn_destinations d join app_private.fn_zones z on z.id=d.zone_id where d.state='current' and z.type='candy'),2::bigint,'capacity measured in whole persons');
select is((pg_temp.fn_cmd('journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='seed')),'f7270000-0000-0000-0000-000000000111')->'result'),(select value->'result' from fn_test_state where key='start-b'),'exact command replay keeps the original command result');
select throws_ok($$select pg_temp.fn_cmd('journey.start','{"expectedVersion":999}','f7270000-0000-0000-0000-000000000111')$$,'40001','IDEMPOTENCY_CONFLICT','same key with different body conflicts');
select throws_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',1,'destinationId',(select value#>>'{snapshot,current,id}' from fn_test_state where key='start-b'),'code','wrong'))$$,'40001','VERSION_CONFLICT','stale scan cannot advance next destination');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
insert into fn_test_state select 'start-a',pg_temp.fn_cmd('journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='seed')));
select isnt((select value#>>'{snapshot,current,zoneId}' from fn_test_state where key='start-a'),(select value#>>'{snapshot,current,zoneId}' from fn_test_state where key='start-b'),'second family cannot reserve already full zone');
select lives_ok($$select pg_temp.fn_cmd('registration.save','{"label":"Family A","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"stepFree":true}')$$,'registration edit atomically reassesses a lower comfort limit');
select ok(coalesce((api.frightnight_snapshot('frightnight-2027-test')#>>'{current,zone,intensity}')::integer<=1,false) or ((api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,state}')='waiting' and api.frightnight_snapshot('frightnight-2027-test')->'current'='null'::jsonb),'lowered preference yields a suitable current destination or honest temporary wait');
insert into fn_test_state select 'invite-a',pg_temp.fn_cmd('party.invite')->'result';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='invite-a'),'consent',true))$$,'paid families explicitly join during walk');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,party,persons}')::integer,4,'shared route counts all people');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,party,maxIntensity}')::integer,1,'shared intensity takes lowest chosen maximum');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,party,avoidSmoke}','true','comfort preferences aggregate restrictively');
select ok(not exists(select 1 from app_private.fn_destinations d join app_private.fn_zones z on z.id=d.zone_id where d.state='current' group by z.id,z.capacity having sum(d.persons)>z.capacity),'join cannot overbook capacity');
select lives_ok($$select pg_temp.fn_cmd('party.leave')$$,'leaving produces two coherent independent routes');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,party,persons}')::integer,2,'leaving restores own family size');
select lives_ok($$select pg_temp.fn_cmd('quest.answer','{"questId":"riddle-1","answer":"kroon"}')$$,'correct server answer earns award');
select pg_temp.fn_cmd('quest.answer','{"questId":"riddle-1","answer":"kroon"}');
select is((select count(*) from app_private.fn_awards where registration_id=app_private.fn_registration((select event_id from app_private.fn_events),'f7270000-0000-0000-0000-000000000003') and award_key='quest:riddle-1'),1::bigint,'quest replay gives one award');
select throws_ok($$select pg_temp.fn_cmd('quest.answer','{"questId":"riddle-2","answer":"wrong"}')$$,'22023','ANSWER_INCORRECT','incorrect answer earns nothing');
select lives_ok($$select pg_temp.fn_cmd('journey.finish',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer))$$,'stop walking returns one final Duinpad destination');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{current,zone,type}','finale','Duinpad is last destination');
select lives_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}','code',(select code->>'code' from fn_test_state s cross join lateral jsonb_array_elements(s.value->'zoneCodes')code where s.key='seed' and code->>'name'='Oogstdorp · Duinpad')))$$,'finale scan completes walk');
select ok(exists(select 1 from app_private.fn_destinations where event_id=(select event_id from app_private.fn_events) and state='visited' and lease_until>app_private.fn_now(event_id)),'arrival scan retains a bounded physical occupancy hold');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,state}','finished','journey finished only after Duinpad visit');
select lives_ok($$select pg_temp.fn_cmd('beacon.complete')$$,'digital beacon is separate idempotent finale reward');
-- Closed, paused, expired and end-window routes require explicit recovery.
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select pg_temp.fn_cmd('admin.settings',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{event,version}')::integer,'paused',true));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('journey.skip',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}'))$$,'22023','EVENT_PAUSED','global pause prevents route transitions');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select pg_temp.fn_cmd('admin.settings',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{event,version}')::integer,'paused',false));
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T17:55:00+02:00"}');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}','code','unused'))$$,'40001','RESERVATION_EXPIRED_RESUME','expired lease requires explicit route recovery');
select lives_ok($$select pg_temp.fn_cmd('journey.resume',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer))$$,'expired lease recovers without a second active reservation');
select is((select count(*) from app_private.fn_destinations where party_id=(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,id}')::uuid and state='current'),1::bigint,'lease recovery keeps exactly one destination');
select throws_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}','code','wrong'))$$,'22023','INVALID_ZONE_CODE','ordinary scan still requires current zone credential');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T18:35:00+02:00"}');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}','code','unused'))$$,'40001','ROUTE_WINDOW_END_RESUME','ordinary visits cannot complete beyond chosen evening window');
select lives_ok($$select pg_temp.fn_cmd('journey.resume',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer))$$,'late recovery returns safely to Duinpad');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{current,zone,type}','finale','late family receives finale rather than a new ordinary house');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select pg_temp.fn_cmd('admin.settings',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{event,version}')::integer,'qrRequired',false));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test')#>>'{journey,version}')::integer,'destinationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{current,id}'))$$,'regie QR release allows authorized current visit button');
select is((select method from app_private.fn_visits where registration_id=(api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,id}')::uuid order by completed_at desc limit 1),'released','QR release is recorded as a separate explicit method');
-- Address/role privacy and Storage ownership checks.
select ok(not exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test')->'ownZones') z),'participant receives no other resident profiles');
select is(jsonb_array_length(api.frightnight_snapshot('frightnight-2027-test')->'ownZones'),0,'unassigned participant cannot edit a house');
select ok(not app_private.fn_photo_access((select event_id::text||'/'||id::text||'/f7270000-0000-0000-0000-000000000002/x.webp' from app_private.fn_zones limit 1)),'Storage policy rejects another house upload');
select throws_ok($$select pg_temp.fn_cmd('qr.issue',jsonb_build_object('zoneId',(select id from app_private.fn_zones where type='candy')))$$,'42501','NOT_AUTHORIZED','QR issuance requires actual resident ownership or event capability');
select lives_ok($$select pg_temp.fn_cmd('thanks.send',jsonb_build_object('zoneId',(select zone_id from app_private.fn_visits where registration_id=(api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,id}')::uuid limit 1),'text','Bedankt voor de mooie avond!'))$$,'thank-you requires an actual own visit');
select lives_ok($$select pg_temp.fn_cmd('evaluation.save','{"rating":5,"text":"Goed te testen"}')$$,'finished family can durably evaluate');
-- Activity capacity uses full-family seats under the same event lock.
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select pg_temp.fn_cmd('test.clock','{"time":"2027-10-30T13:30:00+02:00"}');
update app_private.fn_activities set capacity=3;
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities order by starts_at limit 1)))$$,'paid family books all its activity places atomically');
select lives_ok($$select pg_temp.fn_cmd('activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities order by starts_at limit 1)))$$,'repeated activity booking does not double seats');
select is((select sum(seats) from app_private.fn_bookings where status='booked'),2::bigint,'one family booking uses exactly all two places');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities order by starts_at limit 1)))$$,'22023','ACTIVITY_FULL','a second whole family cannot overbook remaining one place');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('activity.cancel',jsonb_build_object('activityId',(select id from app_private.fn_activities order by starts_at limit 1)))$$,'cancelling atomically releases places');
select is((select coalesce(sum(seats),0) from app_private.fn_bookings where status='booked'),0::bigint,'cancelled places are fully available once');
-- Explicitly shared registration is distinct from a shared route.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('f7270000-0000-0000-0000-000000000004','fn-adult@example.invalid',now(),'{}','{}');
insert into fn_test_state select 'adult-invite',pg_temp.fn_cmd('registration.invite')->'result';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('registration.accept',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='adult-invite'),'consent',true))$$,'adult explicitly accepts shared access to existing registration');
select is(api.frightnight_snapshot('frightnight-2027-test')#>>'{registration,label}','Family A','shared adult receives same paid family without new order');
select pg_temp.fn_cmd('notification.read',jsonb_build_object('notificationId',api.frightnight_snapshot('frightnight-2027-test')#>>'{notifications,0,id}'),'f7270000-0000-0000-0000-000000000144');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('registration.revoke','{"userId":"f7270000-0000-0000-0000-000000000004"}')$$,'registration owner can revoke shared adult');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(api.frightnight_snapshot('frightnight-2027-test')->'registration','null'::jsonb,'revoked adult loses registration immediately');
select throws_ok($$select pg_temp.fn_cmd('notification.read',jsonb_build_object('notificationId',(select value#>>'{snapshot,notifications,0,id}' from fn_test_state where key='start-a')),'f7270000-0000-0000-0000-000000000144')$$,'42501','NOT_AUTHORIZED','revoked member cannot replay an old private command receipt');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','payments',0,100)$$,'42501','NOT_AUTHORIZED','direct paginated finance API still enforces capability');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(jsonb_array_length(api.frightnight_admin_list('frightnight-2027-test','registrations',0,1)->'items'),1,'admin list bounds a page to requested size');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,1)->>'nextCursor')::integer,1,'admin list returns explicit continuation cursor');
select throws_ok($$select pg_temp.fn_cmd('test.cleanup',jsonb_build_object('confirmation','frightnight-2027-test','runId',api.frightnight_snapshot('frightnight-2027-test')#>>'{event,runId}'))$$,'42501','RETENTION_SCOPE_CONFLICT','months-long protected edition cannot be cleaned before retention expires');
-- A resident confirms the real account contact and a reviewed map location.
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
insert into fn_test_state select 'resident-zone',pg_temp.fn_cmd('zone.apply','{"name":"Resident test house","address":"Synthetic resident address","type":"candy","intensity":0,"capacity":8,"opensAt":"2027-10-30T13:00:00+02:00","closesAt":"2027-10-30T21:00:00+02:00"}')->'result';
update auth.users set email_confirmed_at=null where id='f7270000-0000-0000-0000-000000000004';
select throws_ok($$select pg_temp.fn_cmd('zone.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='resident-zone'),'expectedVersion',1,'confirmed',true))$$,'42501','EDITION_ACCESS_REQUIRED','an unverified Auth contact cannot activate a house');
update auth.users set email_confirmed_at=now() where id='f7270000-0000-0000-0000-000000000004';
select lives_ok($$select pg_temp.fn_cmd('zone.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='resident-zone'),'expectedVersion',1,'confirmed',true))$$,'actual verified owner confirms contact without external mail');
select throws_ok($$select pg_temp.fn_cmd('zone.location.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='resident-zone'),'expectedVersion',2,'confirmed',true,'latitude',55,'longitude',8))$$,'22023','VERIFIED_DUINDORP_LOCATION_REQUIRED','out-of-area browser coordinates cannot become a route location');
select lives_ok($$select pg_temp.fn_cmd('zone.location.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='resident-zone'),'expectedVersion',2,'confirmed',true,'latitude',52.095,'longitude',4.26))$$,'owner confirmation stores the location for later organization review');
select is((select review_status from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='resident-zone')),'submitted','client location confirmation never self-approves a house');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('admin.zone.review',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='resident-zone'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='resident-zone')),'decision','approved'))$$,'capability-bound organization can approve a confirmed house');
-- Real-time PSP holds and a payment arriving after the slot was reallocated.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values
 ('f7270000-0000-0000-0000-000000000005','fn-late@example.invalid',now(),'{}','{}'),
 ('f7270000-0000-0000-0000-000000000006','fn-on-time@example.invalid',now(),'{}','{}');
update app_private.fn_start_slots set capacity=2 where starts_at='2027-10-30T17:30:00+02:00';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select pg_temp.fn_cmd('registration.save','{"label":"Late paid family","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"startSlot":"2027-10-30T17:30:00+02:00"}');
insert into fn_test_state select 'late-order',api.frightnight_payment_create('frightnight-2027-test','f7270000-0000-0000-0000-000000000005','f7270000-0000-0000-0000-000000000155');
select api.frightnight_payment_bind('frightnight-2027-test',(select (value->>'order_id')::uuid from fn_test_state where key='late-order'),(select 'ct_'||(value->>'order_id') from fn_test_state where key='late-order'),null);
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000006","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('registration.save','{"label":"On-time family","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"startSlot":"2027-10-30T17:30:00+02:00"}')$$,'22023','START_SLOT_FULL','pending real-time payment hold protects all start places');
update app_private.fn_orders set hold_until=now()-interval '1 minute' where id=(select (value->>'order_id')::uuid from fn_test_state where key='late-order');
select lives_ok($$select pg_temp.fn_cmd('registration.save','{"label":"On-time family","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"startSlot":"2027-10-30T17:30:00+02:00"}')$$,'expired payment hold releases start places without touching provider status');
select pg_temp.fn_pay('f7270000-0000-0000-0000-000000000006');
select lives_ok($$select api.frightnight_payment_confirm('frightnight-2027-test',(select 'ct_'||(value->>'order_id') from fn_test_state where key='late-order'),'paid',700,'EUR','late-paid-capacity',(select jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging') from fn_test_state where key='late-order'))$$,'late paid status is recorded without inventing capacity');
select is((select status from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000005'),'draft','late paid family needs explicit rebooking rather than overbooked activation');
select is((select payment_status from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000005'),'paid','real provider receipt remains authoritative in compensation state');
select is((select sum(adults+children) from app_private.fn_registrations where start_slot='2027-10-30T17:30:00+02:00' and status='active' and payment_status='paid'),2::bigint,'paid start slot never exceeds physical capacity');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('registration.save','{"label":"Late paid family","routeType":"lantern","adults":1,"children":1,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":1,"startSlot":"2027-10-30T17:45:00+02:00"}')$$,'late paid family safely rebooks an available start without paying twice');
select is((select status from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000005'),'active','capacity-checked rebooking resolves compensation state');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('test.mail.retry',jsonb_build_object('sinkId',(select id from app_private.fn_mail_sink order by created_at limit 1)))$$,'mail retry is event-scoped and sink-only');
select is((select max(attempts) from app_private.fn_mail_sink),1,'retry updates sink attempts without a dispatcher');
select ok((api.frightnight_admin_list('frightnight-2027-test','sink',0,1)#>'{items,0,payload}') ? 'orderId','authorized sink preview receives the stored event-scoped transaction payload');
select ok(not has_function_privilege('authenticated','api.frightnight_payment_scope(text)','EXECUTE'),'provider-scope resolver remains server-only');
select throws_ok($$select pg_temp.fn_cmd('push.subscribe',jsonb_build_object('endpoint','https://push.example.invalid/device','keys',jsonb_build_object('p256dh',repeat('a',87),'auth',repeat('b',22)),'consent',false))$$,'42501','EXPLICIT_CONSENT_REQUIRED','push requires explicit consent');
select lives_ok($$select pg_temp.fn_cmd('push.subscribe',jsonb_build_object('endpoint','https://push.example.invalid/device','keys',jsonb_build_object('p256dh',repeat('a',87),'auth',repeat('b',22)),'consent',true))$$,'opt-in subscription is durable without an external dispatcher');
select is(api.frightnight_snapshot('frightnight-2027-test')->>'pushEnabled','true','own snapshot reports only push opt-in state');
select lives_ok($$select pg_temp.fn_cmd('push.unsubscribe','{}')$$,'actor can revoke own opt-in');
select is(api.frightnight_snapshot('frightnight-2027-test')->>'pushEnabled','false','unsubscribe is immediately durable');
select is((select count(*) from app_private.email_outbox),(select (value->>'outbox')::bigint from fn_test_state where key='legacy-counts'),'create/status/link/retry never changes legacy mail outbox');
select is((select count(*) from app_private.payment_requests),(select (value->>'payments')::bigint from fn_test_state where key='legacy-counts'),'new payments do not touch legacy trigger table');
select is((select count(*) from app_private.walking_groups),(select (value->>'groups')::bigint from fn_test_state where key='legacy-counts'),'new route engine does not activate legacy groups');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('test.reset','{"confirmation":"fn-legacy-protected-2026"}')$$,'42501','RESET_SCOPE_CONFLICT','reset requires exact server edition and run');
select lives_ok($$select pg_temp.fn_cmd('test.reset',jsonb_build_object('confirmation','frightnight-2027-test','runId',api.frightnight_snapshot('frightnight-2027-test')#>>'{event,runId}'))$$,'scoped reset archives synthetic data');
select is((select count(*) from app_private.fn_registrations where not synthetic and status<>'archived'),4::bigint,'reset preserves real tester registrations');
select is((select count(*) from app_private.events where slug='fn-legacy-protected-2026'),1::bigint,'reset preserves historical event');
select is((select count(*) from auth.users where id::text like 'f727%'),6::bigint,'reset never deletes auth identities');
select is((select count(*) from app_private.fn_ledger),4::bigint,'reset preserves financial ledger');
select lives_ok($$select pg_temp.fn_cmd('test.seed')$$,'scenario can reseed after archive without global deletion');
select ok((select start_token_hash from app_private.fn_events) is distinct from extensions.digest((select value->>'startCode' from fn_test_state where key='seed'),'sha256'),'reset and reseed cannot reactivate the previous run start credential');
select is((select count(*) from app_private.fn_registrations where synthetic and status<>'archived'),4::bigint,'reseed has exactly four active synthetic families');
select lives_ok($$select pg_temp.fn_cmd('test.copy','{"slug":"frightnight-2027-test-copy"}')$$,'test configuration copies into a fresh independently scoped edition');
-- A provider-confirmed full refund reconciles a previously uncertain intent;
-- no invented provider refund reference is needed after response loss.
select api.frightnight_payment_confirm('frightnight-2027-test',(select value->>'provider_ref' from fn_test_state where key='order-a'),'refunded',700,'EUR','provider-refund-reconcile',(select jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging') from fn_test_state where key='order-a'));
select is((select status from app_private.fn_refunds where command_key='f7270000-0000-0000-0000-000000000167'),'refunded','verified full refund reconciles an uncertain active intent');
select is((select provider_ref from app_private.fn_refunds where command_key='f7270000-0000-0000-0000-000000000167'),null,'refund reconciliation never invents a missing provider refund reference');
select lives_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test','f7270000-0000-0000-0000-000000000001',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002'),'f7270000-0000-0000-0000-000000000168','Already refunded provider-confirmed order')$$,'an already refunded order returns without a new provider intent');
select is((select count(*) from app_private.fn_refunds),2::bigint,'already refunded retry preserves the original intent history only');
-- Activity assignment grants one existing confirmed adult a single session.
insert into fn_test_state select 'staff-assignment',jsonb_build_object('activityId',(select a.id from app_private.fn_activities a join app_private.fn_events f on f.event_id=a.event_id and f.run_id=a.run_id order by a.id limit 1),'userId','f7270000-0000-0000-0000-000000000004','enabled',true);
select lives_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value from fn_test_state where key='staff-assignment'),'f7270000-0000-0000-0000-000000000177')$$,'event administrator assigns a confirmed adult to one activity');
select lives_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value from fn_test_state where key='staff-assignment'),'f7270000-0000-0000-0000-000000000177')$$,'activity access exact-key retry is idempotent');
select is((select count(*) from app_private.fn_activity_staff where user_id='f7270000-0000-0000-0000-000000000004'),1::bigint,'assignment replay never duplicates staff membership');
select throws_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value||'{"enabled":false}'::jsonb from fn_test_state where key='staff-assignment'),'f7270000-0000-0000-0000-000000000177')$$,'40001','IDEMPOTENCY_CONFLICT','staff access command key cannot change its enabled value');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select throws_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value from fn_test_state where key='staff-assignment'))$$,'42501','NOT_AUTHORIZED','limited activity staff cannot grant staff roles');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into app_private.fn_activities(id,event_id,name,starts_at,ends_at,capacity,run_id)select 'f7270000-0000-0000-0000-000000000188',f.event_id,'Other edition activity','2027-10-30T12:00:00Z','2027-10-30T13:00:00Z',10,f.run_id from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test-copy';
select throws_ok($$select pg_temp.fn_cmd('admin.activity.staff','{"activityId":"f7270000-0000-0000-0000-000000000188","userId":"f7270000-0000-0000-0000-000000000004","enabled":true}')$$,'42501','ACTIVITY_STAFF_SCOPE_REQUIRED','activity assignment cannot cross editions even when the admin owns both');
update auth.users set email_confirmed_at=null where id='f7270000-0000-0000-0000-000000000004';
select throws_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value from fn_test_state where key='staff-assignment'))$$,'42501','VERIFIED_ACTIVITY_STAFF_REQUIRED','an unconfirmed identity cannot receive activity access');
update auth.users set email_confirmed_at=now() where id='f7270000-0000-0000-0000-000000000004';
select lives_ok($$select pg_temp.fn_cmd('admin.activity.staff',(select value||'{"enabled":false}'::jsonb from fn_test_state where key='staff-assignment'))$$,'administrator can revoke the exact activity assignment');
select is((select count(*) from app_private.fn_activity_staff where user_id='f7270000-0000-0000-0000-000000000004'),0::bigint,'revocation immediately removes activity access');
select is((select count(*) from app_private.fn_audit where action in('activity.staff.granted','activity.staff.revoked')),2::bigint,'staff changes write explicit target audit once per successful command');
select is((select count(*) from app_private.fn_registrations where event_id=(select id from app_private.events where slug='frightnight-2027-test-copy')),0::bigint,'copy does not duplicate people, orders or historical permissions');
select throws_ok($$select api.frightnight_command('fn-legacy-protected-2026','test.reset','{"confirmation":"fn-legacy-protected-2026","isTest":true,"environment":"staging"}',gen_random_uuid())$$,'42501','EDITION_ACCESS_REQUIRED','forged browser test flag cannot reset a legacy edition');
update app_private.fn_events set retention_until=now()-interval '1 day' where event_id=(select id from app_private.events where slug='frightnight-2027-test-copy');
select lives_ok($$select api.frightnight_command('frightnight-2027-test-copy','test.cleanup',jsonb_build_object('confirmation','frightnight-2027-test-copy','runId',(select run_id from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-copy'))),gen_random_uuid())$$,'expired test edition can be archived in its explicit scope');
select is((select closed from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test')),false,'cleanup of expired sibling preserves protected source edition');
-- REG-02: durable, event-scoped audience changes and actor authorization.
create function pg_temp.fn_message_visible(mid uuid) returns boolean language sql as $$select exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test')->'announcements') m where (m->>'id')::uuid=mid)$$;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values
 ('f7270000-0000-0000-0000-000000000007','fn-roots@example.invalid',now(),'{}','{}'),
 ('f7270000-0000-0000-0000-000000000008','fn-content@example.invalid',now(),'{}','{}');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000007","role":"authenticated"}',true);
select pg_temp.fn_cmd('registration.save','{"label":"Roots audience family","routeType":"roots","adults":1,"children":0,"consent":true,"termsVersion":"2027-test-v1","maxIntensity":4}');
insert into app_private.event_capabilities(event_id,user_id,capability) select event_id,'f7270000-0000-0000-0000-000000000008','content_manage' from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into fn_test_state select 'message-all',pg_temp.fn_cmd('admin.announcement','{"text":"All participant message","audience":"all"}')->'result';
insert into fn_test_state select 'message-a',pg_temp.fn_cmd('admin.announcement',jsonb_build_object('text','Only registration A','audience','registration','registrationId',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002')),'f7270000-0000-0000-0000-000000000211')->'result';
select lives_ok($$select pg_temp.fn_cmd('admin.announcement',jsonb_build_object('text','Only registration A','audience','registration','registrationId',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000002')),'f7270000-0000-0000-0000-000000000211')$$,'announcement exact-key replay is idempotent');
select is((select count(*) from app_private.fn_announcements),2::bigint,'announcement replay never duplicates durable records');
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Different text","audience":"all"}','f7270000-0000-0000-0000-000000000211')$$,'40001','IDEMPOTENCY_CONFLICT','announcement key cannot change its original audience or content');
insert into fn_test_state select 'message-lantern',pg_temp.fn_cmd('admin.announcement','{"text":"Lantern participants","audience":"lantern"}')->'result';
-- A controlled current-zone fixture for B after earlier finale tests. This tests
-- message visibility only; it is not walking-path or route-transition evidence.
update app_private.fn_parties set state='walking',version=version+1 where id=(select m.party_id from app_private.fn_members m join app_private.fn_registrations r on r.id=m.registration_id where r.owner_id='f7270000-0000-0000-0000-000000000003');
insert into app_private.fn_destinations(event_id,party_id,zone_id,sequence,persons,membership_version,arrival_at,lease_until,walk_minutes,reason)
 select r.event_id,p.id,z.id,coalesce((select max(sequence) from app_private.fn_destinations where party_id=p.id),0)+1,r.adults+r.children,p.membership_version,app_private.fn_now(r.event_id)+interval '1 minute',app_private.fn_now(r.event_id)+interval '20 minutes',1,'Controlled current-zone notification fixture'
 from app_private.fn_registrations r join app_private.fn_members m on m.registration_id=r.id join app_private.fn_parties p on p.id=m.party_id join app_private.fn_events f on f.event_id=r.event_id join app_private.fn_zones z on z.event_id=r.event_id and z.run_id=f.run_id and z.type='candy' where r.owner_id='f7270000-0000-0000-0000-000000000003';
insert into fn_test_state select 'message-zone',pg_temp.fn_cmd('admin.announcement',jsonb_build_object('text','Current zone B only','audience','zone','zoneId',(select d.zone_id from app_private.fn_destinations d join app_private.fn_members m on m.party_id=d.party_id join app_private.fn_registrations r on r.id=m.registration_id where r.owner_id='f7270000-0000-0000-0000-000000000003' and d.state='current')))->'result';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000008","role":"authenticated"}',true);
insert into fn_test_state select 'message-roots',pg_temp.fn_cmd('admin.announcement','{"text":"Roots participants","audience":"roots"}')->'result';
select is(jsonb_array_length(api.frightnight_snapshot('frightnight-2027-test')->'announcements'),5,'content manager sees all own-edition audience messages without a registration');
select is((api.frightnight_admin_list('frightnight-2027-test','announcements',0,2)->>'total')::integer,5,'content manager can paginate every own-edition message');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,2)$$,'42501','NOT_AUTHORIZED','content permission does not expose participant management data');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-all')) and pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-a')) and pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-lantern')),'registration A sees all, own-registration and own-route messages');
select ok(not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-roots')) and not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-zone')),'registration A cannot read another route or current-zone target');
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Forged message","audience":"all"}')$$,'42501','NOT_AUTHORIZED','participant cannot publish an announcement');
insert into fn_test_state select 'participant-message-receipt',pg_temp.fn_cmd('notification.read','{"notificationId":"f7270000-0000-0000-0000-000000000299"}','f7270000-0000-0000-0000-000000000298');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select ok(not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-a')) and pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-zone')),'registration B sees its current zone but cannot read A-targeted message');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000007","role":"authenticated"}',true);
select ok(pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-roots')) and not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-lantern')),'roots registration sees only its own route audience');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.fn_cmd('admin.announcement',jsonb_build_object('id',(select value->>'announcementId' from fn_test_state where key='message-a'),'expectedVersion',1,'text','Now registration B only','audience','registration','registrationId',(select id from app_private.fn_registrations where owner_id='f7270000-0000-0000-0000-000000000003')))$$,'administrator changes a durable message audience transactionally');
select throws_ok($$select pg_temp.fn_cmd('admin.announcement',jsonb_build_object('id',(select value->>'announcementId' from fn_test_state where key='message-a'),'expectedVersion',1,'text','Stale audience update','audience','all'))$$,'40001','VERSION_CONFLICT','stale announcement update cannot widen its audience');
select is((select version from app_private.fn_announcements where id=(select (value->>'announcementId')::uuid from fn_test_state where key='message-a')),2,'exactly one audience change increments the stored version');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-a')),'changing audience immediately removes old participant visibility');
select ok(not exists(select 1 from jsonb_array_elements(pg_temp.fn_cmd('notification.read','{"notificationId":"f7270000-0000-0000-0000-000000000299"}','f7270000-0000-0000-0000-000000000298')#>'{snapshot,announcements}') m where m->>'id'=(select value->>'announcementId' from fn_test_state where key='message-a')),'replaying an old actor receipt cannot redisclose an announcement after audience removal');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select ok(pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-a')),'changing audience immediately grants only the new participant visibility');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into app_private.fn_registrations(id,event_id,label,route_type,adults,children,max_intensity,amount_cents,run_id,synthetic) select 'f7270000-0000-0000-0000-000000000221',f.event_id,'Foreign audience target','roots',1,0,3,350,f.run_id,true from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test-copy';
insert into app_private.fn_zones(id,event_id,name,address,type,intensity,capacity,opens_at,closes_at,token_hash,run_id,synthetic) select 'f7270000-0000-0000-0000-000000000222',f.event_id,'Foreign zone','Synthetic foreign target','candy',0,5,'2027-10-30T13:00Z','2027-10-30T20:00Z',extensions.digest('foreign-test-zone','sha256'),f.run_id,true from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test-copy';
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Foreign registration","audience":"registration","registrationId":"f7270000-0000-0000-0000-000000000221"}')$$,'42501','ANNOUNCEMENT_TARGET_SCOPE_REQUIRED','administrator cannot target a registration from another owned edition');
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Foreign zone","audience":"zone","zoneId":"f7270000-0000-0000-0000-000000000222"}')$$,'42501','ANNOUNCEMENT_TARGET_SCOPE_REQUIRED','administrator cannot target a zone from another owned edition');
select throws_ok($$select api.frightnight_command('frightnight-2027-test-copy','admin.announcement',jsonb_build_object('id',(select value->>'announcementId' from fn_test_state where key='message-all'),'expectedVersion',1,'text','Cross-edition update','audience','all'),gen_random_uuid())$$,'42501','ANNOUNCEMENT_SCOPE_REQUIRED','announcement ID cannot be updated through another edition');
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Bad audience","audience":"everyone-in-history"}')$$,'22023','INVALID_ANNOUNCEMENT','unrecognized audience cannot fall back to all participants');
select is((select count(*) from app_private.fn_mail_sink),4::bigint,'announcements never enqueue email or retry a payment capture');
select is((select count(*) from app_private.email_outbox),(select (value->>'outbox')::bigint from fn_test_state where key='legacy-counts'),'targeted announcements do not touch the legacy outbox');
-- REG-01: filtered total and pagination share one bounded event/actor set.
insert into app_private.fn_registrations(event_id,label,route_type,adults,children,max_intensity,amount_cents,run_id,synthetic) select f.event_id,'Filter% '||v.label,v.route,1,0,1,350,f.run_id,true from app_private.fn_events f join app_private.events e on e.id=f.event_id cross join(values('Alpha','lantern'),('Beta','roots'))v(label,route) where e.slug='frightnight-2027-test';
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'FILTER%','{}')->>'total')::integer,2,'case-insensitive literal search is applied before count and pagination');
select is(jsonb_array_length(api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'Filter%','{}')->'items'),1,'filtered first page remains bounded');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'Filter%','{}')->>'nextCursor')::integer,1,'filtered count yields a valid continuation cursor');
select isnt(api.frightnight_admin_list('frightnight-2027-test','registrations',1,1,'Filter%','{}')#>>'{items,0,id}',api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'Filter%','{}')#>>'{items,0,id}','second filtered page contains a different matching row');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,'Filter%','{"status":"draft","routeType":"roots"}')->>'total')::integer,1,'lifecycle and route filters narrow registration totals before pagination');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,'Family A','{"paymentStatus":"refunded"}')->>'total')::integer,1,'payment filter is distinct from registration lifecycle status');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,$$' OR true --$$,'{}')->>'total')::integer,0,'SQL-like search text is literal and cannot widen results');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,repeat('x',121),'{}')$$,'22023','INVALID_ADMIN_QUERY','oversized search is rejected before querying data');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',100001,50,'','{}')$$,'22023','INVALID_ADMIN_QUERY','oversized offset fails clearly instead of looping the same bounded page');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,'','{"eventId":"other"}')$$,'22023','INVALID_ADMIN_FILTER','caller cannot add an event-scope filter or unknown query field');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,50,'','{"status":42}')$$,'22023','INVALID_ADMIN_FILTER','filter values must have the documented string type');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','zones',0,50,'','{"routeType":"lantern"}')$$,'22023','INVALID_ADMIN_FILTER','zones cannot acquire a fabricated route-type binding');
select is((api.frightnight_admin_list('frightnight-2027-test','zones',0,10,'Oogstdorp','{"status":"open"}')->>'total')::integer,1,'zone status uses effective policy and filters archived closed runs from totals');
select is((api.frightnight_admin_list('frightnight-2027-test','payments',0,10,'Family A','{"status":"refunded","routeType":"lantern"}')->>'total')::integer,1,'payment search and status use own-event registration join before totals');
select pg_temp.fn_cmd('admin.content.save','{"key":"filter-live","body":"Needle content","published":true}');
select pg_temp.fn_cmd('admin.content.save','{"key":"filter-draft","body":"Needle content","published":false}');
select is((api.frightnight_admin_list('frightnight-2027-test','content',0,1,'Needle','{"status":"published"}')->>'total')::integer,1,'content published filter counts only matching text and publication state');
select pg_temp.fn_cmd('admin.content.save','{"key":"programme","body":"Additional programme draft","published":false}');
select pg_temp.fn_cmd('admin.content.save','{"key":"terms","body":"Supplement to fixed 2027-test-v1","published":false}');
select is((select count(*) from jsonb_array_elements(api.frightnight_public_content('frightnight-2027-test')) x where x->>'key' in('programme','terms')),0::bigint,'programme and terms drafts are absent from the public server projection');
select pg_temp.fn_cmd('admin.content.save','{"key":"programme","body":"Additional programme published","published":true}');
select pg_temp.fn_cmd('admin.content.save','{"key":"terms","body":"Supplement to fixed 2027-test-v1","published":true}');
select is((select count(*) from jsonb_array_elements(api.frightnight_public_content('frightnight-2027-test')) x where x->>'key' in('programme','terms')),2::bigint,'published programme and terms supplements are returned by the public server projection');
select is((select count(*) from jsonb_array_elements(api.frightnight_public_content('frightnight-2027-test-copy')) x where x->>'key' in('programme','terms')),0::bigint,'published programme and terms cannot leak into a different edition');

select is((api.frightnight_admin_list('frightnight-2027-test','audit',0,1,'announcement.saved','{}')->>'total')::bigint,(select count(*) from app_private.fn_audit where action='announcement.saved' and event_id=(select id from app_private.events where slug='frightnight-2027-test')),'audit search total uses matching action rather than page length');
select is((api.frightnight_admin_list('frightnight-2027-test','sink',0,1,'Family A','{"status":"sink","routeType":"lantern"}')->>'total')::integer,1,'sink search and route filter cannot expose other registrations or editions');
select is((api.frightnight_admin_list('frightnight-2027-test','bookings',0,10,'Family A','{"status":"cancelled","routeType":"lantern"}')->>'total')::integer,1,'booking query joins only same-event activities and registrations');
select is((api.frightnight_admin_list('frightnight-2027-test','parties',0,10,'Family A','{"routeType":"lantern"}')->>'total')::integer,1,'party search uses scoped current membership without duplicate count');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select pg_temp.fn_cmd('help.submit','{"category":"filterhelp","text":"Filter incident A"}');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select pg_temp.fn_cmd('help.submit','{"category":"filterhelp","text":"Filter incident B"}');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.fn_incidents set status='resolved' where text='Filter incident B';
select is((api.frightnight_admin_list('frightnight-2027-test','incidents',0,1,'Filter incident','{"status":"resolved","routeType":"lantern"}')->>'total')::integer,1,'incident status and route filter are applied before count and page');
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,10,'Foreign audience target','{}')->>'total')::integer,0,'search cannot discover matching records from another edition');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,10,'Family A','{}')$$,'42501','NOT_AUTHORIZED','adding search and filters cannot bypass participant capability guard');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into app_private.fn_registrations(id,event_id,label,route_type,adults,children,max_intensity,amount_cents,run_id,synthetic)
 select ('ffffffff-ffff-ffff-ffff-'||lpad(n::text,12,'0'))::uuid,f.event_id,case when n=1 then 'Rare needle after first hundred' else 'Bulk filter fixture '||n end,'lantern',1,0,1,350,f.run_id,true from app_private.fn_events f join app_private.events e on e.id=f.event_id cross join generate_series(1,505)n where e.slug='frightnight-2027-test';
select is((api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'Rare needle after first hundred','{}')->>'total')::integer,1,'search finds a record beyond any prior hundred-row snapshot limit');
select is(api.frightnight_admin_list('frightnight-2027-test','registrations',0,1,'Rare needle after first hundred','{}')#>>'{items,0,label}','Rare needle after first hundred','searched page contains the remote match rather than first unfiltered rows');
select is(jsonb_array_length(api.frightnight_snapshot('frightnight-2027-test')->'registrations'),100,'regie personal-data snapshot remains capped at one hundred even above five hundred registrations');
select ok((api.frightnight_snapshot('frightnight-2027-test')#>>'{metrics,registrations}')::integer>500,'regie receives authoritative count above its bounded snapshot length');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{metrics,registrations}')::bigint,(select count(*) from app_private.fn_registrations where event_id=(select id from app_private.events where slug='frightnight-2027-test') and status<>'archived'),'dashboard registration count covers the full event without broadening DTOs');
select is((api.frightnight_snapshot('frightnight-2027-test')#>>'{metrics,paid}')::bigint,(select count(*) from app_private.fn_registrations where event_id=(select id from app_private.events where slug='frightnight-2027-test') and status<>'archived' and payment_status='paid'),'paid total follows confirmed server payment state independently of page length');
select ok((api.frightnight_snapshot('frightnight-2027-test')->'metrics') ?& array['started','completed','openZones','openIncidents'],'event administrator receives each authorized operational total');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'f7270000-0000-0000-0000-000000000006','payments_manage' from app_private.events where slug='frightnight-2027-test';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000006","role":"authenticated"}',true);
select ok((api.frightnight_snapshot('frightnight-2027-test')->'metrics') ?& array['registrations','paid'] and not((api.frightnight_snapshot('frightnight-2027-test')->'metrics') ?| array['started','completed','openZones','openIncidents']),'finance totals do not imply route, resident or support authority');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000008","role":"authenticated"}',true);
select ok(not(api.frightnight_snapshot('frightnight-2027-test')?'metrics'),'content manager cannot read event participation or support counts');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not(api.frightnight_snapshot('frightnight-2027-test')?'metrics'),'participant cannot read event-wide operational counts');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);

select is((api.frightnight_admin_list('frightnight-2027-test','sink',0,1,(select id::text from app_private.fn_mail_sink order by id limit 1),'{}')->>'total')::integer,1,'finance mail preview can find an exact capture UUID without scanning arbitrary pages');
insert into app_private.fn_activity_staff(event_id,activity_id,user_id) select event_id,activity_id,'f7270000-0000-0000-0000-000000000004' from app_private.fn_bookings limit 1;
insert into app_private.fn_bookings(event_id,activity_id,registration_id,seats,status)
 select r.event_id,a.id,r.id,1,'booked' from app_private.fn_registrations r join app_private.fn_activities a on a.event_id=r.event_id where r.owner_id='f7270000-0000-0000-0000-000000000003' and not exists(select 1 from app_private.fn_activity_staff fs where fs.activity_id=a.id) order by a.id limit 1;
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is((api.frightnight_admin_list('frightnight-2027-test','bookings',0,1,'Family ','{}')->>'total')::integer,1,'assigned activity staff totals include only bookings of their own activity');
select is((api.frightnight_admin_list('frightnight-2027-test','bookings',0,1,'Family B','{}')->>'total')::integer,0,'search cannot leak other activity counts to a limited staff member');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.fn_destinations set state='released' where state='current' and party_id=(select m.party_id from app_private.fn_members m join app_private.fn_registrations r on r.id=m.registration_id where r.owner_id='f7270000-0000-0000-0000-000000000003');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select ok(not pg_temp.fn_message_visible((select (value->>'announcementId')::uuid from fn_test_state where key='message-zone')),'current-zone message visibility ends when the destination is released');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select pg_temp.fn_cmd('admin.announcement','{"text":"Anonymous broadcast","audience":"all"}')$$,'42501','LOGIN_REQUIRED','anonymous command cannot create a durable audience message');
select throws_ok($$select api.frightnight_admin_list('frightnight-2027-test','registrations',0,10,'','{}')$$,'42501','LOGIN_REQUIRED','anonymous actor cannot enumerate filtered admin data');

-- Receipts retain an immutable command result, but every replay reprojects the
-- complete current snapshot through current capabilities and party state.
create function pg_temp.fn_replay_cmd(who uuid,cmd text,body jsonb default '{}',k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',who,'role','authenticated')::text,true);
 return api.frightnight_command('frightnight-2027-test-replay',cmd,body,k);
end$$;
create function pg_temp.fn_replay_pay(who uuid) returns void language plpgsql as $$declare o jsonb;begin
 o:=api.frightnight_payment_create('frightnight-2027-test-replay',who,gen_random_uuid());
 perform api.frightnight_payment_bind('frightnight-2027-test-replay',(o->>'order_id')::uuid,'ct_'||(o->>'order_id'),null);
 perform api.frightnight_payment_confirm('frightnight-2027-test-replay','ct_'||(o->>'order_id'),'paid',(o->>'amount_cents')::integer,'EUR','test-paid:'||(o->>'order_id'),jsonb_build_object('order_id',o->>'order_id','event_id',o->>'event_id','testmode',true,'environment','staging'));
end$$;
select api.frightnight_bootstrap('frightnight-2027-test-replay','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
-- Explicit service-only admission for these known synthetic fixture actors.
select api.frightnight_entry_grant('frightnight-2027-test-replay',u.id,clock_timestamp()+interval '1 hour',repeat('a',64)) from auth.users u where u.id between 'f7270000-0000-0000-0000-000000000001'::uuid and 'f7270000-0000-0000-0000-000000000008'::uuid;
insert into fn_test_state select 'replay-seed',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000001','test.seed')->'result';
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000001','test.walk.fixture');
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Replay family A","routeType":"lantern","adults":1,"children":0,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_replay_pay('f7270000-0000-0000-0000-000000000002');
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Replay family B","routeType":"lantern","adults":1,"children":0,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_replay_pay('f7270000-0000-0000-0000-000000000003');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'f7270000-0000-0000-0000-000000000002','event_admin' from app_private.events where slug='frightnight-2027-test-replay';
insert into fn_test_state select 'replay-admin-start',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('code',(select value->>'startCode' from fn_test_state where key='replay-seed'),'expectedVersion',1),'f7270000-0000-0000-0000-000000000301');
select ok((select value->'snapshot' from fn_test_state where key='replay-admin-start')?'registrations','fixture participant start receipt originally contains administrative projection');
update app_private.event_capabilities set revoked_at=now() where user_id='f7270000-0000-0000-0000-000000000002' and event_id=(select id from app_private.events where slug='frightnight-2027-test-replay');
insert into fn_test_state select 'replay-revoked-start',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('code',(select value->>'startCode' from fn_test_state where key='replay-seed'),'expectedVersion',1),'f7270000-0000-0000-0000-000000000301');
select ok(not((select value->'snapshot' from fn_test_state where key='replay-revoked-start') ?| array['registrations','zones','audit','health']),'participant receipt replay cannot recover revoked administrative data');
select is((select value->'result' from fn_test_state where key='replay-revoked-start'),(select value->'result' from fn_test_state where key='replay-admin-start'),'capability-safe replay preserves the immutable original command result');
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000003','journey.start',jsonb_build_object('code',(select value->>'startCode' from fn_test_state where key='replay-seed'),'expectedVersion',1));
insert into fn_test_state select 'replay-invite',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','party.invite')->'result';
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000003','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='replay-invite'),'consent',true));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
insert into fn_test_state select 'replay-first-body',jsonb_build_object('expectedVersion',(s#>>'{journey,version}')::integer,'destinationId',s#>>'{current,id}','code',(select z->>'code' from fn_test_state t cross join lateral jsonb_array_elements(t.value->'zoneCodes')z where t.key='replay-seed' and z->>'zoneId'=s#>>'{current,zoneId}')) from(select api.frightnight_snapshot('frightnight-2027-test-replay')s)q;
insert into fn_test_state select 'replay-first-response',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','journey.complete',(select value from fn_test_state where key='replay-first-body'),'f7270000-0000-0000-0000-000000000302');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000003','journey.complete',jsonb_build_object('expectedVersion',(s#>>'{journey,version}')::integer,'destinationId',s#>>'{current,id}','code',(select z->>'code' from fn_test_state t cross join lateral jsonb_array_elements(t.value->'zoneCodes')z where t.key='replay-seed' and z->>'zoneId'=s#>>'{current,zoneId}'))) from(select api.frightnight_snapshot('frightnight-2027-test-replay')s)q;
insert into fn_test_state select 'replay-after-shared-advance',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','journey.complete',(select value from fn_test_state where key='replay-first-body'),'f7270000-0000-0000-0000-000000000302');
select is((select value->'result' from fn_test_state where key='replay-after-shared-advance'),(select value->'result' from fn_test_state where key='replay-first-response'),'another member advancing the route does not mutate the original command result');
select isnt((select value#>>'{snapshot,current,id}' from fn_test_state where key='replay-after-shared-advance'),(select value#>>'{snapshot,current,id}' from fn_test_state where key='replay-first-response'),'old command replay never returns the formerly current destination as current');
select is((select value#>>'{snapshot,current,id}' from fn_test_state where key='replay-after-shared-advance'),api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{current,id}','replayed snapshot reflects the actual current shared destination');
select is((select jsonb_array_length(value#>'{snapshot,progress,visits}') from fn_test_state where key='replay-after-shared-advance'),2,'replayed transition adds no third visit after the other member progresses');

-- A valid invitation issued before another member is refunded must not reopen
-- a route/capacity claim. These are isolated provider-contract transactions.
create function pg_temp.fn_party_guard_digest() returns jsonb language sql as $$select to_jsonb(encode(extensions.digest(jsonb_build_object(
 'members',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_members t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'parties',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_parties t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'destinations',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_destinations t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'visits',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_visits t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'awards',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_awards t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'invites',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_invites t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'receipts',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_receipts t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay')),
 'audit',(select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from app_private.fn_audit t where event_id=(select id from app_private.events where slug='frightnight-2027-test-replay'))
)::text,'sha256'),'hex'))$$;
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','registration.save','{"label":"Paid independent family C","routeType":"lantern","adults":1,"children":0,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_replay_pay('f7270000-0000-0000-0000-000000000007');
insert into fn_test_state select 'guard-old-invitation',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','party.invite')->'result';
insert into fn_test_state select 'guard-target-party',to_jsonb(m.party_id) from app_private.fn_members m join app_private.fn_registrations r on r.id=m.registration_id join app_private.events e on e.id=r.event_id where r.owner_id='f7270000-0000-0000-0000-000000000002' and e.slug='frightnight-2027-test-replay';
select api.frightnight_payment_confirm('frightnight-2027-test-replay',o.provider_ref,'refunded',o.amount_cents,o.currency,'party-member-refund:'||o.id,jsonb_build_object('order_id',o.id,'event_id',o.event_id,'testmode',true,'environment','staging')) from app_private.fn_orders o join app_private.fn_registrations r on r.id=o.registration_id join app_private.events e on e.id=o.event_id where r.owner_id='f7270000-0000-0000-0000-000000000003' and e.slug='frightnight-2027-test-replay';
insert into fn_test_state select 'guard-refunded-before',pg_temp.fn_party_guard_digest();
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='guard-old-invitation'),'consent',true))$$,'22023','SAME_PAID_ROUTE_REQUIRED','valid pre-refund invitation cannot join a party with another refunded member');
select is(pg_temp.fn_party_guard_digest(),(select value from fn_test_state where key='guard-refunded-before'),'refused refunded-target join leaves all claims, histories, members, invitations, receipts and audit unchanged');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','party.invite')$$,'22023','SAME_PAID_ROUTE_REQUIRED','paid member cannot issue a new invitation while another group member is refunded');
select is(pg_temp.fn_party_guard_digest(),(select value from fn_test_state where key='guard-refunded-before'),'refused invite cannot create a token or mutate the refunded party');
insert into fn_test_state select 'guard-c-invitation',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','party.invite')->'result';
insert into fn_test_state select 'guard-source-before',pg_temp.fn_party_guard_digest();
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='guard-c-invitation'),'consent',true))$$,'22023','SAME_PAID_ROUTE_REQUIRED','paid member cannot merge an unpaid source group into a valid paid destination');
select is(pg_temp.fn_party_guard_digest(),(select value from fn_test_state where key='guard-source-before'),'rejected source group leaves both sides and invitation consumption unchanged');
update app_private.fn_registrations r set payment_status='unpaid',status='active' from app_private.events e where e.id=r.event_id and e.slug='frightnight-2027-test-replay' and owner_id='f7270000-0000-0000-0000-000000000003';
insert into fn_test_state select 'guard-unpaid-before',pg_temp.fn_party_guard_digest();
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='guard-old-invitation'),'consent',true))$$,'22023','SAME_PAID_ROUTE_REQUIRED','valid invitation rejects any unpaid target member even when the inviter remains paid');
select is(pg_temp.fn_party_guard_digest(),(select value from fn_test_state where key='guard-unpaid-before'),'unpaid-target denial has zero party, reservation, receipt or reward effects');
update app_private.fn_registrations r set payment_status='paid',status='draft' from app_private.events e where e.id=r.event_id and e.slug='frightnight-2027-test-replay' and owner_id='f7270000-0000-0000-0000-000000000003';
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='guard-old-invitation'),'consent',true))$$,'22023','SAME_PAID_ROUTE_REQUIRED','paid but inactive compensation-state member cannot enter a joint route');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000003','party.invite')$$,'42501','PAID_REGISTRATION_REQUIRED','a paid but inactive issuer cannot publish a new group invitation');
update app_private.fn_registrations r set status='active',route_type='roots' from app_private.events e where e.id=r.event_id and e.slug='frightnight-2027-test-replay' and owner_id='f7270000-0000-0000-0000-000000000003';
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='guard-old-invitation'),'consent',true))$$,'22023','SAME_PAID_ROUTE_REQUIRED','join validates the evening window of every target member rather than one representative');
update app_private.fn_registrations r set payment_status='refunded',status='cancelled',route_type='lantern' from app_private.events e where e.id=r.event_id and e.slug='frightnight-2027-test-replay' and owner_id='f7270000-0000-0000-0000-000000000003';
select lives_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','party.leave')$$,'paid family can safely leave a party containing a refunded family');
select is((select count(*) from app_private.fn_destinations where party_id=(select (value#>>'{}')::uuid from fn_test_state where key='guard-target-party') and state='current'),0::bigint,'remaining refunded party receives no new reservation during leave recalculation');
select is((select state from app_private.fn_parties where id=(select (value#>>'{}')::uuid from fn_test_state where key='guard-target-party')),'paused','unpaid remainder stays paused rather than resuming a route');
select ok((select value#>>'{snapshot,current,id}' is not null from(select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','notification.read','{"notificationId":"f7270000-0000-0000-0000-000000000399"}')value)x),'paid departing family retains its own valid independent destination');

-- Edition contact data belongs only to the signup owner; shared access and
-- operational listings never gain these fields. No Auth or email mutation.
insert into fn_test_state select 'contact-before',jsonb_build_object('auth',(select encode(extensions.digest(coalesce(email,''),'sha256'),'hex') from auth.users where id='f7270000-0000-0000-0000-000000000002'),'sink',(select count(*) from app_private.fn_mail_sink));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
insert into fn_test_state select 'contact-body',jsonb_build_object('registrationId',s#>>'{registration,id}','expectedVersion',(s#>>'{registration,version}')::integer,'contactName','  Test contact  ','contactPhone','+31 (0)70-123 45 67') from(select api.frightnight_snapshot('frightnight-2027-test-replay')s)q;
insert into fn_test_state select 'contact-response',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save',(select value from fn_test_state where key='contact-body'),'f7270000-0000-0000-0000-000000000350');
select is(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,contactName}','Test contact','owner contact name is normalized and survives a fresh server read');
select is(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,contactPhone}','+31 (0)70-123 45 67','owner contact telephone survives a fresh server read');
select is((select value#>>'{result,version}' from fn_test_state where key='contact-response'),api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,version}','contact write returns its authoritative registration version');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save',(select value from fn_test_state where key='contact-body'))$$,'40001','VERSION_CONFLICT','stale contact form cannot overwrite a later edit');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save','{"contactName":"Versionless"}')$$,'40001','VERSION_CONFLICT','contact mutation requires an explicit expected version');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,version}')::integer,'contactName','Test contact','contactPhone','<script>invalid</script>'))$$,'22023','INVALID_CONTACT','contact telephone accepts only bounded ordinary telephone characters');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,version}')::integer,'contactName',repeat('x',121)))$$,'22023','INVALID_CONTACT','contact name is bounded at one hundred and twenty characters');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000007','contact.save',jsonb_build_object('registrationId',(select value->>'registrationId' from fn_test_state where key='contact-body'),'expectedVersion',1,'contactName','Other family'))$$,'42501','CONTACT_OWNER_REQUIRED','another registered family cannot address an owner contact record by UUID');
insert into fn_test_state select 'contact-invite',pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','registration.invite')->'result';
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000004','registration.accept',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='contact-invite'),'consent',true));
select ok(not((api.frightnight_snapshot('frightnight-2027-test-replay')->'registration') ?| array['contactName','contactPhone']),'invited shared adult has no owner contact fields in their registration DTO');
select throws_ok($$select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000004','contact.save',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,version}')::integer,'contactName','Shared overwrite'))$$,'42501','CONTACT_OWNER_REQUIRED','shared adult cannot change the signup owner contact');
select pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Replay family A","routeType":"lantern","adults":1,"children":0,"maxIntensity":2}');
select is(api.frightnight_snapshot('frightnight-2027-test-replay')#>>'{registration,contactPhone}','+31 (0)70-123 45 67','ordinary registration edits preserve the independent owner contact fields');
select is((pg_temp.fn_replay_cmd('f7270000-0000-0000-0000-000000000002','contact.save',(select value from fn_test_state where key='contact-body'),'f7270000-0000-0000-0000-000000000350')->'result'),(select value->'result' from fn_test_state where key='contact-response'),'contact retry preserves its original result without a second mutation');
select is((select result from app_private.fn_receipts where actor_id='f7270000-0000-0000-0000-000000000002' and command_key='f7270000-0000-0000-0000-000000000350'),jsonb_build_object('result',(select value->'result' from fn_test_state where key='contact-response'),'snapshot',jsonb_build_object('registration',jsonb_build_object('id',(select value->'registrationId' from fn_test_state where key='contact-body')))),'stored contact receipt retains only stable result and registration binding, with no telephone or administrative roster');
select ok(not exists(select 1 from app_private.fn_receipts where result::text like '%contactPhone%' or result#>'{snapshot,registrations}' is not null),'all newly stored receipts omit contact fields and full administrative snapshots');
select is((select encode(extensions.digest(coalesce(email,''),'sha256'),'hex') from auth.users where id='f7270000-0000-0000-0000-000000000002'),(select value->>'auth' from fn_test_state where key='contact-before'),'contact editing never changes the Auth identity email');
select is((select count(*) from app_private.fn_mail_sink),(select (value->>'sink')::bigint from fn_test_state where key='contact-before'),'contact editing sends no email or transactional sink capture');
select ok(not exists(select 1 from app_private.fn_audit where action='contact.save' and (details::text like '%Test contact%' or details::text like '%123 45 67%')),'contact audit captures no submitted name or telephone value');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(not exists(select 1 from jsonb_array_elements(api.frightnight_admin_list('frightnight-2027-test-replay','registrations',0,100)->'items') x where x ?| array['contactName','contactPhone']),'administrative registration listing excludes owner contact fields');

-- A provider quote remains immutable across retries, failures and tariff edits.
-- The controller uses existing synthetic Auth fixtures in a fresh isolated event.
create function pg_temp.fn_quote_cmd(who uuid,cmd text,body jsonb default '{}',k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',who,'role','authenticated')::text,true);
 return api.frightnight_command('frightnight-2027-test-quotes',cmd,body,k);
end$$;
create function pg_temp.fn_quote_order(who uuid) returns jsonb language plpgsql as $$declare o jsonb;begin
 o:=api.frightnight_payment_create('frightnight-2027-test-quotes',who,gen_random_uuid());
 return api.frightnight_payment_bind('frightnight-2027-test-quotes',(o->>'order_id')::uuid,'ct_'||(o->>'order_id'),null);
end$$;
create function pg_temp.fn_quote_confirm(k text,st text,ev text) returns jsonb language plpgsql as $$declare o jsonb;begin
 select value into o from fn_test_state where key=k;
 return api.frightnight_payment_confirm('frightnight-2027-test-quotes',o->>'provider_ref',st,(o->>'amount_cents')::integer,'EUR',ev,jsonb_build_object('order_id',o->>'order_id','event_id',o->>'event_id','testmode',true,'environment','staging'));
end$$;
select api.frightnight_bootstrap('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
-- Explicit service-only admission for these known synthetic fixture actors.
select api.frightnight_entry_grant('frightnight-2027-test-quotes',u.id,clock_timestamp()+interval '1 hour',repeat('a',64)) from auth.users u where u.id between 'f7270000-0000-0000-0000-000000000001'::uuid and 'f7270000-0000-0000-0000-000000000008'::uuid;
insert into fn_test_state select 'quote-seed',pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','test.seed')->'result';
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','test.walk.fixture');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Quote family A","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'quote-a',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000002');
select is((select (value->>'amount_cents')::integer from fn_test_state where key='quote-a'),700,'first two-person checkout fixes its seven-euro server quote');
insert into fn_test_state select 'quote-a-before',to_jsonb(r) from app_private.fn_registrations r where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Unpaid upgrade attempt","routeType":"lantern","adults":2,"children":2,"maxIntensity":2}')$$,'22023','PAYMENT_QUOTE_LOCKED','an open seven-euro quote cannot become a four-person registration');
select is((select to_jsonb(r) from app_private.fn_registrations r where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a')),(select value from fn_test_state where key='quote-a-before'),'refused material edit changes neither people, price, version nor start slot');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Another evening","routeType":"roots","adults":1,"children":1,"maxIntensity":2}')$$,'22023','PAYMENT_QUOTE_LOCKED','a quoted registration cannot change its evening even before payment');
select lives_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Quote family A preferences","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"avoidSmoke":true,"startSlot":"2027-10-30T15:30:00Z"}')$$,'quote locking permits label, comfort and advisory start changes');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Quote family B failed attempt","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'quote-b-old',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000003');
select pg_temp.fn_quote_confirm('quote-b-old','failed','quote-b:failed');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Upgrade after failure","routeType":"lantern","adults":2,"children":2,"maxIntensity":2}')$$,'22023','PAYMENT_QUOTE_LOCKED','a failed attempt still locks people because late provider payment remains possible');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Unquoted tariff family","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','admin.settings',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{event,version}')::integer,'priceCents',500,'reason','Synthetic quote regression: new tariff without rewriting existing quotes'));
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Quote family A unchanged tariff","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:30:00Z"}');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,amountCents}')::integer,700,'a preference save after an event tariff increase preserves the open original quote');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Quote family B retry","routeType":"lantern","adults":1,"children":1,"maxIntensity":1}');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,amountCents}')::integer,700,'a failed-attempt preference save also preserves its original quote after tariff change');
insert into fn_test_state select 'quote-b-retry',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000003');
select is((select (value->>'amount_cents')::integer from fn_test_state where key='quote-b-retry'),700,'retry creates a new attempt at the existing immutable amount');
select isnt((select value->>'order_id' from fn_test_state where key='quote-b-retry'),(select value->>'order_id' from fn_test_state where key='quote-b-old'),'failed quote retry has its own auditable payment attempt');
select pg_temp.fn_quote_confirm('quote-b-retry','paid','quote-b:retry-paid');
select pg_temp.fn_quote_confirm('quote-b-old','expired','quote-b:late-expired');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentStatus}','paid','an older expired callback cannot regress the later paid retry registration');
select pg_temp.fn_quote_confirm('quote-b-old','paid','quote-b:late-paid');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,persons}')::integer,2,'late paid on an older failed quote activates only its original two places');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','active','matching late payment keeps the original registration eligible without free upgrades');
select pg_temp.fn_quote_confirm('quote-b-old','paid','quote-b:late-paid');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='quote-b-old') and kind='receipt'),1::bigint,'replayed late provider payment creates exactly one receipt for that attempt');
select pg_temp.fn_quote_confirm('quote-a','paid','quote-a:paid');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='quote-seed')));
select is((select persons from app_private.fn_destinations where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') and party_id=(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{journey,id}')::uuid and state='current'),2,'the old seven-euro callback releases a route reservation for two people only');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Unquoted tariff family","routeType":"lantern","adults":1,"children":1,"maxIntensity":2}');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,amountCents}')::integer,1000,'an existing unquoted registration can accept the current new tariff');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000005','registration.save','{"label":"Mismatch defensive fixture","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'quote-mismatch',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000005');
select is((select (value->>'amount_cents')::integer from fn_test_state where key='quote-mismatch'),1000,'new registrations receive the changed tariff without rewriting old attempts');
-- Deliberately simulate an inconsistent registration using private rollback-only
-- fixture SQL: no public command can perform this now that a quote exists.
update app_private.fn_registrations set adults=2,children=2,amount_cents=2000 where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-mismatch');
insert into app_private.fn_bookings(event_id,activity_id,registration_id,seats,status) select a.event_id,a.id,(select (value->>'registration_id')::uuid from fn_test_state where key='quote-mismatch'),4,'booked' from app_private.fn_activities a where a.event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') order by a.starts_at limit 1;
select pg_temp.fn_quote_confirm('quote-mismatch','paid','quote-mismatch:paid');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentStatus}','paid','an inconsistent quote still records the verified money as received');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','draft','an inconsistent old amount never grants active places');
select is((select count(*) from app_private.fn_bookings where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-mismatch') and status='booked'),0::bigint,'quote invalidation releases still-booked places under the same payment lock');
select ok(exists(select 1 from app_private.fn_notifications where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-mismatch') and title='Betaling ontvangen; bedrag afstemmen'),'quote mismatch creates a durable understandable compensation notification');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000005','registration.save','{"label":"Mismatch same people edited","routeType":"lantern","adults":2,"children":2,"maxIntensity":1,"startSlot":"2027-10-30T15:45:00Z"}');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','draft','start or preference edits cannot bypass quote-mismatch compensation gating');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000005','activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') limit 1)))$$,'42501','PAID_REGISTRATION_REQUIRED','mismatched payment cannot grant larger unpaid activity places');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000005','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='quote-seed')))$$,'42501','PAID_REGISTRATION_REQUIRED','a mismatch cannot start a route despite financial paid truth');
select pg_temp.fn_quote_confirm('quote-mismatch','paid','quote-mismatch:paid');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='quote-mismatch') and kind='receipt'),1::bigint,'mismatch reconciliation replay preserves one financial receipt without issuing rights');
select is((select count(*) from app_private.email_outbox),(select (value->>'outbox')::bigint from fn_test_state where key='legacy-counts'),'quote edits, late retries and compensation never enqueue legacy email');

-- A refunded retry must not be undone by payment on an older failed attempt.
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','registration.save','{"label":"Failed-paid-refunded-late fixture","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
select ok(not(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentQuoteLocked}')::boolean,'registration DTO reports unquoted state before its first attempt');
insert into fn_test_state select 'quote-refund-old',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000006');
select ok((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentQuoteLocked}')::boolean,'registration DTO exposes the server-owned immutable quote flag');
select pg_temp.fn_quote_confirm('quote-refund-old','failed','quote-refund:old-failed');
select ok((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentQuoteLocked}')::boolean,'failed attempts retain the immutable quote flag');
insert into fn_test_state select 'quote-refund-retry',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000006');
select pg_temp.fn_quote_confirm('quote-refund-retry','paid','quote-refund:retry-paid');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','test.clock','{"time":"2027-10-30T11:30:00Z"}');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') order by starts_at limit 1)));
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') order by starts_at desc limit 1)));
insert into fn_test_state select 'quote-checked-booking',jsonb_build_object('id',b.id,'activityId',b.activity_id) from app_private.fn_bookings b join app_private.fn_activities a on a.id=b.activity_id where b.registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-refund-retry') order by a.starts_at limit 1;
insert into fn_test_state select 'quote-booked-booking',jsonb_build_object('id',b.id,'activityId',b.activity_id) from app_private.fn_bookings b join app_private.fn_activities a on a.id=b.activity_id where b.registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-refund-retry') order by a.starts_at desc limit 1;
select lives_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','admin.activity.checkin',jsonb_build_object('bookingId',(select value->>'id' from fn_test_state where key='quote-checked-booking')))$$,'staff can check in an active paid registration before its refund');
select pg_temp.fn_quote_confirm('quote-refund-retry','refunded','quote-refund:retry-refunded');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000006","role":"authenticated"}',true);
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','cancelled','refunding the paid retry cancels its route rights');
select is((select status from app_private.fn_bookings where id=(select (value->>'id')::uuid from fn_test_state where key='quote-booked-booking')),'cancelled','refund releases future booked activity places');
select is((select status from app_private.fn_bookings where id=(select (value->>'id')::uuid from fn_test_state where key='quote-checked-booking')),'checked_in','refund preserves historical checked-in attendance');
select is((select (x->>'available')::integer from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-quotes')->'activities')x where x->>'id'=(select value->>'activityId' from fn_test_state where key='quote-booked-booking')),30,'refund returns all future booked seats to capacity');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','admin.activity.checkin',jsonb_build_object('bookingId',(select value->>'id' from fn_test_state where key='quote-booked-booking')))$$,'22023','BOOKING_NOT_ACTIVE','staff cannot check in a booking cancelled by refund');
select lives_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','activity.cancel',jsonb_build_object('activityId',(select value->>'activityId' from fn_test_state where key='quote-booked-booking')))$$,'owner can safely repeat cancellation after refund without paid status');
select is((select (x->>'available')::integer from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-quotes')->'activities')x where x->>'id'=(select value->>'activityId' from fn_test_state where key='quote-booked-booking')),30,'repeated cancellation never releases capacity twice');
update app_private.fn_bookings set status='booked' where id=(select (value->>'id')::uuid from fn_test_state where key='quote-booked-booking');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','admin.activity.checkin',jsonb_build_object('bookingId',(select value->>'id' from fn_test_state where key='quote-booked-booking')))$$,'22023','BOOKING_NOT_ACTIVE','even a stale booked row cannot bypass inactive registration check-in guard');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','activity.cancel',jsonb_build_object('activityId',(select value->>'activityId' from fn_test_state where key='quote-booked-booking')));

select pg_temp.fn_quote_confirm('quote-refund-old','paid','quote-refund:old-late-paid');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','cancelled','late paid on the older failed attempt cannot reactivate a refunded registration');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentStatus}','paid','money received after cancellation is recorded without restoring route rights');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','quest.answer','{"questId":"riddle-1","answer":"kroon"}')$$,'42501','PAID_REGISTRATION_REQUIRED','cancelled late payment cannot issue a new riddle award');
update app_private.fn_parties set state='finished' where id=(select party_id from app_private.fn_members where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-refund-old'));
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','beacon.complete')$$,'42501','PAID_REGISTRATION_REQUIRED','a formerly finished party cannot issue a new beacon award after cancellation');

select ok(exists(select 1 from app_private.fn_notifications where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-refund-old') and title='Betaling ontvangen na annulering'),'late money after cancellation creates a durable support and refund notification');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','registration.save','{"label":"Cancelled preference update","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T16:00:00Z"}');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','cancelled','advisory start and comfort changes cannot reactivate cancelled late payment');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','activity.book',jsonb_build_object('activityId',(select id from app_private.fn_activities where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') limit 1)))$$,'42501','PAID_REGISTRATION_REQUIRED','cancelled late payment cannot book new activity places');
select throws_ok($$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000006','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='quote-seed')))$$,'42501','PAID_REGISTRATION_REQUIRED','cancelled late payment cannot obtain a start reservation');
select is((api.frightnight_payment_for_refund('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000001',(select (value->>'registration_id')::uuid from fn_test_state where key='quote-refund-old'),'f7270000-0000-0000-0000-000000000397','Controlled refund of older late-paid attempt')->>'order_id'),(select value->>'order_id' from fn_test_state where key='quote-refund-old'),'finance can select the older still-paid attempt before the newer already-refunded attempt');
select pg_temp.fn_quote_confirm('quote-refund-old','refunded','quote-refund:old-refunded');
select pg_temp.fn_quote_confirm('quote-refund-old','paid','quote-refund:paid-after-own-refund');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,paymentStatus}','refunded','a paid callback after refund of that same attempt never regresses refund truth');
select is(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,status}','cancelled','the fully refunded registration remains cancelled after every late callback');
-- Reset archives test data; late provider truth must retain that archive boundary.
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000007','registration.save','{"label":"Archived pending quote fixture","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'quote-archive-old',pg_temp.fn_quote_order('f7270000-0000-0000-0000-000000000007');
update app_private.fn_registrations set synthetic=true where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-archive-old');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','test.reset',jsonb_build_object('confirmation','frightnight-2027-test-quotes','runId',(api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{event,runId}')));
select pg_temp.fn_quote_confirm('quote-archive-old','paid','quote-archive:late-paid');
select is((select status from app_private.fn_registrations where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-archive-old')),'archived','late verified payment preserves the reset archive boundary');
select is((select count(*) from app_private.fn_destinations where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') and party_id=(select party_id from app_private.fn_members where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-archive-old')) and state='current'),0::bigint,'archived late payment cannot acquire a destination or revive old jobs');

select is((select payload->>'fulfillment' from app_private.fn_mail_sink where dedupe_key=(select 'paid:'||(value->>'order_id') from fn_test_state where key='quote-a')),'active','paid sink confirms usable Nightpass only for an active matching registration');
select is((select payload->>'fulfillment' from app_private.fn_mail_sink where dedupe_key=(select 'paid:'||(value->>'order_id') from fn_test_state where key='late-order')),'start_required','paid sink preserves the original full-start-slot support state');
select is((select payload->>'fulfillment' from app_private.fn_mail_sink where dedupe_key=(select 'paid:'||(value->>'order_id') from fn_test_state where key='quote-mismatch')),'quote_mismatch','paid sink describes amount mismatch instead of asserting route readiness');
select is((select payload->>'fulfillment' from app_private.fn_mail_sink where dedupe_key=(select 'paid:'||(value->>'order_id') from fn_test_state where key='quote-refund-old')),'cancelled','paid sink describes receipt after cancellation without claiming restored rights');

-- Positive tariffs share the provider and transactional-mail contract.
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create function pg_temp.fn_price(p_value jsonb) returns jsonb language sql as $$select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000001','admin.settings',jsonb_build_object('expectedVersion',(select version from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes')),'priceCents',p_value))$$;
insert into fn_test_state select 'invalid-price-before',to_jsonb(f) from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test-quotes';
select throws_ok($$select pg_temp.fn_price('0')$$,'22023','INVALID_PRICE','zero price is rejected before any checkout can exist');
select throws_ok($$select pg_temp.fn_price('-1')$$,'22023','INVALID_PRICE','negative tariff is rejected explicitly');
select throws_ok($$select pg_temp.fn_price('100001')$$,'22023','INVALID_PRICE','per-person tariff above one thousand euros is rejected');
select throws_ok($$select pg_temp.fn_price('1.5')$$,'22023','INVALID_PRICE','fractional cents cannot be configured');
select throws_ok($$select pg_temp.fn_price('"350"')$$,'22023','INVALID_PRICE','a string cannot bypass the integer tariff contract');
select throws_ok($$select pg_temp.fn_price('null')$$,'22023','INVALID_PRICE','explicit null tariff is rejected');
select throws_ok($$update app_private.fn_events set price_cents=0 where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes')$$,'23514',null,'table constraint independently rejects zero tariff');
select throws_ok($$update app_private.fn_events set price_cents=100001 where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes')$$,'23514',null,'table constraint independently rejects excessive tariff');
select throws_ok($$update app_private.fn_registrations set amount_cents=0 where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a')$$,'23514',null,'registration amount cannot be zero even through privileged writes');
select throws_ok($$update app_private.fn_orders set amount_cents=100000001 where id=(select (value->>'order_id')::uuid from fn_test_state where key='quote-a')$$,'23514',null,'order amount is bounded at one hundred million cents');
select is((select to_jsonb(f) from app_private.fn_events f join app_private.events e on e.id=f.event_id where e.slug='frightnight-2027-test-quotes'),(select value from fn_test_state where key='invalid-price-before'),'invalid prices leave configuration and version unchanged');
select throws_ok($$update app_private.fn_orders set amount_cents=0 where id=(select (value->>'order_id')::uuid from fn_test_state where key='quote-a')$$,'23514',null,'provider order cannot represent zero cents');
select throws_ok($$update app_private.fn_registrations set amount_cents=100000001 where id=(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a')$$,'23514',null,'registration amount shares the bounded provider ceiling');
select lives_ok($$select pg_temp.fn_price('1')$$,'one-cent per-person tariff is valid');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000008','registration.save','{"label":"Minimum tariff boundary","routeType":"lantern","adults":1,"children":19,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,amountCents}')::integer,20,'twenty places at the minimum tariff remain positive integer cents');
select pg_temp.fn_price('100000');
select pg_temp.fn_quote_cmd('f7270000-0000-0000-0000-000000000008','registration.save','{"label":"Maximum tariff boundary","routeType":"lantern","adults":1,"children":19,"maxIntensity":1}');
select is((api.frightnight_snapshot('frightnight-2027-test-quotes')#>>'{registration,amountCents}')::integer,2000000,'maximum registration remains below the provider order ceiling');

-- Resident observations are a union of immutable registration identities and
-- explicit extra persons; they never create visits, scans or rewards.
create function pg_temp.fn_occ_cmd(who uuid,cmd text,body jsonb default '{}',k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',who,'role','authenticated')::text,true);
 return api.frightnight_command('frightnight-2027-test-occupancy',cmd,body,k);
end$$;
create function pg_temp.fn_occ(p_ids jsonb default '[]',p_extra integer default 0,k uuid default gen_random_uuid()) returns jsonb language sql as $$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone')),'observedDestinationIds',p_ids,'extraPersons',p_extra,'confirmedUncounted',true),k)$$;
select api.frightnight_bootstrap('frightnight-2027-test-occupancy','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
-- Explicit service-only admission for these known synthetic fixture actors.
select api.frightnight_entry_grant('frightnight-2027-test-occupancy',u.id,clock_timestamp()+interval '1 hour',repeat('a',64)) from auth.users u where u.id between 'f7270000-0000-0000-0000-000000000001'::uuid and 'f7270000-0000-0000-0000-000000000008'::uuid;
insert into fn_test_state select 'occ-seed',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','test.seed')->'result';
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','test.walk.fixture');
update app_private.fn_zones set owner_id='f7270000-0000-0000-0000-000000000004',capacity=6 where type='candy' and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
update app_private.fn_zones set status='paused' where type='fright' and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
insert into fn_test_state select 'occ-zone',to_jsonb(z) from app_private.fn_zones z where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy') and type='candy';
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Occupancy A","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Occupancy B","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
update app_private.fn_registrations set status='active',payment_status='paid' where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy') and owner_id is not null;
insert into fn_test_state select 'occ-start',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='occ-seed')));
select is((select count(*) from jsonb_object_keys(d.registration_sizes))::integer,1,'route assignment stores immutable registration identities') from app_private.fn_destinations d where d.id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
select is((select value#>>'{snapshot,current,visitReference}' from fn_test_state where key='occ-start'),upper(left((select value#>>'{snapshot,current,id}' from fn_test_state where key='occ-start'),8)),'participant receives an anonymous reference for the current party');
insert into fn_test_state select 'occ-known',jsonb_build_array(value#>>'{snapshot,current,id}') from fn_test_state where key='occ-start';
select pg_temp.fn_occ((select value from fn_test_state where key='occ-known'),0);
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,2,'the same two persons in app claim and observation count once');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'overlapPersons')::integer,2,'overlap is reported explicitly');
select pg_temp.fn_occ((select value from fn_test_state where key='occ-known'),1);
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,3,'only explicitly uncounted extra persons add to the union');
select is((select count(*) from app_private.fn_visits where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy')),0::bigint,'resident observation cannot fabricate a visit');
select is((select count(*) from app_private.fn_awards where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy')),0::bigint,'resident observation cannot issue an award');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not((api.frightnight_snapshot('frightnight-2027-test-occupancy')#>'{current,zone,occupancy}') ?| array['candidates','observedDestinationIds']),'participant sees aggregate occupancy without other destination identifiers');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(jsonb_array_length(app_private.fn_zone_occupancy_json((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->'candidates'),1,'owner gets only scoped anonymous observation candidates');
select ok(not((app_private.fn_zone_occupancy_json((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))#>'{candidates,0}') ?| array['label','registrationId','ownerId','contactName','contactPhone']),'observation candidate contains no household or contact identity');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000003','zone.occupancy',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',3,'observedDestinationIds','[]'::jsonb,'extraPersons',0,'confirmedUncounted',true))$$,'42501','NOT_AUTHORIZED','another household cannot change a resident observation');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',1,'observedDestinationIds','[]'::jsonb,'extraPersons',0,'confirmedUncounted',true))$$,'40001','VERSION_CONFLICT','stale observation version cannot replace newer physical information');
select throws_ok($$select pg_temp.fn_occ((select value||value from fn_test_state where key='occ-known'),0)$$,'22023','INVALID_OCCUPANCY_OBSERVATION','duplicate destination identities are rejected');
select throws_ok($$select pg_temp.fn_occ('["f7270000-0000-0000-0000-000000000099"]',0)$$,'42501','OBSERVATION_DESTINATION_UNAVAILABLE','nonexistent or foreign observation IDs cannot bind into this zone');
select throws_ok($$select pg_temp.fn_occ('[]',1001)$$,'22023','INVALID_OCCUPANCY_OBSERVATION','extra persons are bounded');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone')),'observedDestinationIds','[]'::jsonb,'extraPersons',1))$$,'22023','INVALID_OCCUPANCY_OBSERVATION','extra count requires explicit confirmation that these people are uncounted');
-- Truthful overcapacity is retained; it may never evict an already walking family.
select lives_ok($$select pg_temp.fn_occ((select value from fn_test_state where key='occ-known'),8)$$,'a resident can truthfully report more physical people than nominal capacity');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,10,'overfull physical observation is visible rather than discarded');
select is((select state from app_private.fn_destinations where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start')),'current','physical overcapacity never silently revokes an underway lease');
insert into fn_test_state select 'occ-b-start',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000003','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='occ-seed')));
select isnt((select value#>>'{snapshot,current,zoneId}' from fn_test_state where key='occ-b-start'),(select value->>'id' from fn_test_state where key='occ-zone'),'new assignment avoids the physically full zone');
-- Waiting is correct for temporary fullness; this separate fixture explicitly
-- requests return so later cross-zone/privacy tests have a real finale claim.
update fn_test_state set value=pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000003','journey.finish',jsonb_build_object('expectedVersion',(value#>>'{snapshot,journey,version}')::integer)) where key='occ-b-start';
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.profile',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone')),'name','Occupancy zone','description','','capacity',9,'opensAt','2027-10-30T15:00Z','closesAt','2027-10-30T19:00Z'))$$,'22023','CAPACITY_BELOW_RESERVATIONS','profile capacity uses the same physical and app union');
-- Real observation TTL is independent of accelerated event time.
with t as(select clock_timestamp()-interval '6 minutes' n) update app_private.fn_zones set observed_at=t.n,observation_expires_at=t.n+interval '5 minutes' from t where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone');
select is(app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'observationStale','true','old nonempty observation is explicitly stale after five real minutes');
select is(app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'admissionBlocked','true','stale physical information blocks new admissions');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,10,'expiry never assumes physical visitors have left');
select pg_temp.fn_occ('[]',0);
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,2,'fresh explicit empty observation releases physical holds but preserves app claim');
with t as(select clock_timestamp()-interval '6 minutes' n) update app_private.fn_zones set observed_at=t.n,observation_expires_at=t.n+interval '5 minutes' from t where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone');
select is(app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'admissionBlocked','false','an expired empty observation does not block the zone');
update app_private.fn_destinations set arrival_at='2027-10-30T13:00Z',lease_until='2027-10-30T14:00Z' where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'appPersons')::integer,2,'expired current travel lease remains reserved until explicit recovery');
-- Simulate a shared party splitting after observation: immutable registration
-- snapshots preserve former members physically present, then overlap new claims.
select pg_temp.fn_occ((select value from fn_test_state where key='occ-known'),0);
update app_private.fn_destinations set state='released' where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,2,'explicitly observed people remain counted after their old route claim is released');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'),(select (value#>>'{snapshot,journey,id}')::uuid from fn_test_state where key='occ-start'))->>'effectivePersons')::integer,2,'prospective regrouping of the same registration never counts it twice');
insert into app_private.fn_destinations(event_id,party_id,zone_id,sequence,persons,registration_sizes,membership_version,arrival_at,lease_until,walk_minutes,reason)
 select event_id,party_id,zone_id,99,persons,registration_sizes,membership_version,'2027-10-30T15:07Z','2027-10-30T15:30Z',2,'Explicit isolated immutable identity fixture' from app_private.fn_destinations where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,2,'new app claim and old physical observation union by registration identity');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'),(select (value#>>'{snapshot,journey,id}')::uuid from fn_test_state where key='occ-b-start'))->>'effectivePersons')::integer,4,'a distinct prospective household adds its own persons to capacity');

-- Observation receipts retain the stable command result only; current projection
-- must remain fresh after another legitimate owner update.
insert into fn_test_state select 'occ-replay-body',jsonb_build_object('zoneId',(select value->>'id' from fn_test_state where key='occ-zone'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone')),'observedDestinationIds',(select jsonb_build_array(id) from app_private.fn_destinations where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy')),'extraPersons',1,'confirmedUncounted',true);
insert into fn_test_state select 'occ-replay-response',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',(select value from fn_test_state where key='occ-replay-body'),'f7270000-0000-0000-0000-000000000998');
select pg_temp.fn_occ('[]',0);
insert into fn_test_state select 'occ-replay-current',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',(select value from fn_test_state where key='occ-replay-body'),'f7270000-0000-0000-0000-000000000998');
select is((select value->'result' from fn_test_state where key='occ-replay-current'),(select value->'result' from fn_test_state where key='occ-replay-response'),'repeated observation retains only its stable command result');
select is((select count(*) from app_private.fn_audit where action='zone.occupancy.updated' and details->>'commandId'='f7270000-0000-0000-0000-000000000998'),1::bigint,'observation replay never writes a second physical update');
select is((select value#>>'{snapshot,ownZones,0,occupancy,extraPersons}' from fn_test_state where key='occ-replay-current'),'0','observation replay projects the fresh occupancy rather than stale receipt state');
select ok(not exists(select 1 from app_private.fn_receipts where command_key='f7270000-0000-0000-0000-000000000998' and result::text like '%Occupancy A%'),'observation receipt stores no participant roster');
-- Cross-zone and old unseen history are never arbitrary occupancy inputs.
select throws_ok($$select pg_temp.fn_occ(jsonb_build_array((select value#>>'{snapshot,current,id}' from fn_test_state where key='occ-b-start')),0)$$,'42501','OBSERVATION_DESTINATION_UNAVAILABLE','a current destination in another zone cannot be reported here');
select throws_ok($$select pg_temp.fn_occ(jsonb_build_array((select value#>>'{snapshot,current,id}' from fn_test_state where key='replay-after-shared-advance')),0)$$,'42501','OBSERVATION_DESTINATION_UNAVAILABLE','a destination from another edition cannot enter the physical union');
insert into fn_test_state select 'occ-old-unseen',jsonb_build_array(id) from app_private.fn_destinations where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
update app_private.fn_destinations set state='visited',created_at=clock_timestamp()-interval '61 minutes' where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
select throws_ok($$select pg_temp.fn_occ((select value from fn_test_state where key='occ-old-unseen'),0)$$,'42501','OBSERVATION_DESTINATION_UNAVAILABLE','unseen historical visits older than one hour are not observation candidates');
update app_private.fn_destinations set created_at=clock_timestamp() where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
select lives_ok($$select pg_temp.fn_occ((select value from fn_test_state where key='occ-old-unseen'),0)$$,'a recent completed visit remains physically observable after its app hold ends');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,2,'recent visited observation does not double count its still-active arrival hold');
update app_private.fn_destinations set state='current' where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
-- A former four-person shared party is physically observed. After its members
-- split into separate claims at this same zone, immutable identities union once.
update app_private.fn_destinations set state='visited',created_at=clock_timestamp(),persons=4,registration_sizes=registration_sizes||jsonb_build_object((select value#>>'{snapshot,registration,id}' from fn_test_state where key='occ-b-start'),2) where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
update app_private.fn_destinations set state='current',zone_id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone') where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-b-start');
select pg_temp.fn_occ((select value from fn_test_state where key='occ-known'),0);
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'effectivePersons')::integer,4,'old shared-party observation and split current claims count each registration once');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'observedKnownPersons')::integer,4,'departing members remain physically counted from the immutable observed snapshot');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->>'overlapPersons')::integer,4,'split claims overlap both immutable known family identities');
select is((app_private.fn_zone_occupancy((select (value->>'id')::uuid from fn_test_state where key='occ-zone'),(select (value#>>'{snapshot,journey,id}')::uuid from fn_test_state where key='occ-b-start'))->>'effectivePersons')::integer,4,'prospective regrouping after split cannot double-count existing known members');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not((api.frightnight_snapshot('frightnight-2027-test-occupancy')#>'{current,zone,occupancy}') ?| array['candidates','observedDestinationIds']),'participant cannot see another arrival reference even when multiple families share the zone');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select api.frightnight_command('frightnight-2027-test-occupancy','zone.occupancy','{}',gen_random_uuid())$$,'42501','LOGIN_REQUIRED','anonymous physical occupancy updates are refused');

select throws_ok($$select pg_temp.fn_occ((select jsonb_agg(gen_random_uuid()) from generate_series(1,51)),0)$$,'22023','INVALID_OCCUPANCY_OBSERVATION','observed group list is bounded to fifty destinations');

-- Bounded resident candidate pagination may never hide currently selected
-- physical holds and thereby silently clear them on the next form submission.
update app_private.fn_destinations set created_at=clock_timestamp()-interval '2 hours' where id=(select (value#>>'{snapshot,current,id}')::uuid from fn_test_state where key='occ-start');
insert into app_private.fn_destinations(event_id,party_id,zone_id,sequence,state,persons,registration_sizes,membership_version,arrival_at,lease_until,walk_minutes,reason)
 select event_id,party_id,zone_id,1000+g,'visited',persons,registration_sizes,membership_version,arrival_at,lease_until,walk_minutes,'Bounded candidate-list fixture' from app_private.fn_destinations cross join generate_series(1,51)g where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(jsonb_array_length(app_private.fn_zone_occupancy_json((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->'candidates'),50,'resident candidate list stays bounded after more than fifty arrivals');
select ok(exists(select 1 from jsonb_array_elements(app_private.fn_zone_occupancy_json((select (value->>'id')::uuid from fn_test_state where key='occ-zone'))->'candidates')candidate where candidate->>'destinationId'=(select value#>>'{snapshot,current,id}' from fn_test_state where key='occ-start')),'selected older physical hold remains visible before unselected recent arrivals');


select ok(not exists(select 1 from app_private.fn_receipts where command_key='f7270000-0000-0000-0000-000000000998' and result::text~'(candidates|observedDestinationIds)'),'physical-observation receipt retains aggregate result without other destination references');
update app_private.fn_zones set owner_id='f7270000-0000-0000-0000-000000000001' where id=(select (value->>'id')::uuid from fn_test_state where key='occ-zone');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.occupancy',(select value from fn_test_state where key='occ-replay-body'),'f7270000-0000-0000-0000-000000000998')$$,'42501','NOT_AUTHORIZED','former zone owner cannot replay an old observation after ownership is removed');

-- Provider acknowledgement is delegated by the exact durable refund intent;
-- revoking the initiating staff member cannot erase a completed PSP effect.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values('f7270000-0000-0000-0000-000000000009','fn-refund-ack@example.invalid',now(),'{}','{}');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'f7270000-0000-0000-0000-000000000009','payments_manage' from app_private.events where slug='frightnight-2027-test-quotes';
insert into fn_test_state select 'ack-order',api.frightnight_payment_for_refund('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a'),'f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement');
select lives_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','pending','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'known intent records the contract-provider pending request before staff revocation');
update app_private.event_capabilities set revoked_at=clock_timestamp() where event_id=(select id from app_private.events where slug='frightnight-2027-test-quotes') and user_id='f7270000-0000-0000-0000-000000000009';
select throws_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a'),gen_random_uuid(),'Revoked actor cannot start a new intent')$$,'42501','EDITION_ACCESS_REQUIRED','role revocation prevents any new refund intent');
update auth.users set banned_until=clock_timestamp()+interval '1 day' where id='f7270000-0000-0000-0000-000000000009';
select throws_ok($$select api.frightnight_payment_for_refund('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'registration_id')::uuid from fn_test_state where key='quote-a'),gen_random_uuid(),'Banned actor cannot start a new intent')$$,'42501','EDITION_ACCESS_REQUIRED','Auth ban also prevents any new refund intent');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000008',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'42501','REFUND_REQUEST_REQUIRED','another actor cannot acknowledge somebody else refund claim');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='quote-refund-old'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'42501','REFUND_REQUEST_REQUIRED','another order cannot be substituted into an authorized claim');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded',gen_random_uuid(),'Known authorized refund acknowledgement')$$,'42501','REFUND_REQUEST_REQUIRED','a new idempotency key cannot acknowledge an existing external request');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','A changed reason')$$,'42501','REFUND_REQUEST_REQUIRED','reason is part of exact previously authorized claim context');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'42501','REFUND_REQUEST_REQUIRED','refund acknowledgement cannot cross edition boundary');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_other_provider','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'40001','REFUND_PROVIDER_CONFLICT','known pending provider binding is immutable after staff revocation');
select lives_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'actual provider acknowledgement completes the exact claim after ban and capability revocation');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='ack-order') and kind='refund'),1::bigint,'post-revocation acknowledgement creates exactly one refund ledger entry');
select is((select status from app_private.fn_orders where id=(select (value->>'order_id')::uuid from fn_test_state where key='ack-order')),'refunded','financial truth records the provider refund independently of staff current access');
select lives_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_ack_fixture','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'exact acknowledged refund retry remains valid after actor revocation');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='ack-order') and kind='refund'),1::bigint,'acknowledgement retry never creates a second financial refund');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),'re_other_provider','refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'40001','REFUND_PROVIDER_CONFLICT','a refunded receipt still rejects substitution of a different provider refund');
select throws_ok($$select api.frightnight_payment_refund_record('frightnight-2027-test-quotes','f7270000-0000-0000-0000-000000000009',(select (value->>'order_id')::uuid from fn_test_state where key='ack-order'),null,'refunded','f7270000-0000-0000-0000-000000000997','Known authorized refund acknowledgement')$$,'40001','REFUND_PROVIDER_CONFLICT','null cannot erase an already bound provider refund on retry');
select lives_ok($$select pg_temp.fn_quote_confirm('quote-a','refunded','ack:provider-reconcile')$$,'provider reconciliation remains accepted after the initiating actor ban');
select pg_temp.fn_quote_confirm('quote-a','paid','ack:late-paid-after-refund');
select is((select status from app_private.fn_orders where id=(select (value->>'order_id')::uuid from fn_test_state where key='ack-order')),'refunded','out-of-order provider paid cannot undo the acknowledged refund');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='ack-order') and kind='refund'),1::bigint,'provider reconciliation and late callback preserve one refund ledger');

-- Versioned resident review reasons are private operational data, including
-- when the same real actor legitimately owns a house and joins a walk.
insert into fn_test_state select 'hui-apply',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.apply','{"name":"HUI02 correction house","address":"Synthetic reviewed address","type":"candy","intensity":0,"capacity":8,"opensAt":"2027-10-30T15:00Z","closesAt":"2027-10-30T19:00Z","stepFree":true,"description":"Own review fixture"}')->'result';
create function pg_temp.fn_hui_body(decision text,reason text default null) returns jsonb language sql as $$select jsonb_build_object('zoneId',z.id,'expectedVersion',z.version,'decision',decision,'reason',reason) from app_private.fn_zones z where z.id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')$$;
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'expectedVersion',1,'confirmed',true));
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.location.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'expectedVersion',2,'confirmed',true,'latitude',52.095,'longitude',4.26));
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000002','admin.zone.review',pg_temp.fn_hui_body('changes_requested','Make an unsafe override'))$$,'42501','NOT_AUTHORIZED','participant cannot review a house even with its exact UUID');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('changes_requested'))$$,'22023','REVIEW_REASON_REQUIRED','requesting changes requires a visible bounded reason');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('rejected','  '))$$,'22023','REVIEW_REASON_REQUIRED','rejecting a house requires a nonempty trimmed reason');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('changes_requested',repeat('x',1001)))$$,'22023','REVIEW_REASON_REQUIRED','review explanation is bounded at one thousand characters');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('approved')-'expectedVersion')$$,'40001','VERSION_CONFLICT','review requires explicit current zone version');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',jsonb_build_object('zoneId','f7270000-0000-0000-0000-000000000222','expectedVersion',1,'decision','changes_requested','reason','Wrong edition cannot be reviewed'))$$,'42501','NOT_AUTHORIZED','review target must belong to the effective edition even when administrator owns both');
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('approved'));
-- Current claim is a controlled privacy fixture for a previously approved zone
-- that subsequently receives a change request. No scan/award is inserted.
update app_private.fn_destinations set zone_id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply') where sequence=99 and event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy');
insert into fn_test_state select 'hui-request-body',pg_temp.fn_hui_body('changes_requested','  Maak de doorgang vrij en bevestig de ligging opnieuw.  ');
insert into fn_test_state select 'hui-request',pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',(select value from fn_test_state where key='hui-request-body'),'f7270000-0000-0000-0000-000000000995');
select is((select review_status from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'changes_requested','organization can request changes transactionally');
select is((select status from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'closed','change request closes the zone for new routes');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is((select z->>'reviewReason' from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-occupancy')->'ownZones')z where z->>'id'=(select value->>'zoneId' from fn_test_state where key='hui-apply')),'Maak de doorgang vrij en bevestig de ligging opnieuw.','owner sees the normalized durable correction reason on fresh read');
select ok(not(app_private.fn_zone_json((select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply'),false)?'reviewReason'),'public zone projection never includes review reason even for the owner');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not((api.frightnight_snapshot('frightnight-2027-test-occupancy')#>'{current,zone}')?'reviewReason'),'participant current destination never contains private review reason');
select ok(not(app_private.fn_zone_json((select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply'),true)?'reviewReason'),'another family cannot obtain reason from a private-address zone projection');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select ok(not(app_private.fn_zone_json((select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply'),true)?'reviewReason'),'another personally admitted actor has no house-review reason access');
update app_private.fn_zones set owner_id='f7270000-0000-0000-0000-000000000002' where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not((api.frightnight_snapshot('frightnight-2027-test-occupancy')#>'{current,zone}')?'reviewReason') and not((api.frightnight_snapshot('frightnight-2027-test-occupancy')#>'{journey,current,zone}')?'reviewReason'),'dual-role owner participant keeps review reason out of both destination projections');
select ok(exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-occupancy')->'ownZones')z where z->>'id'=(select value->>'zoneId' from fn_test_state where key='hui-apply') and z->>'reviewReason'='Maak de doorgang vrij en bevestig de ligging opnieuw.'),'dual-role actor still receives reason in the explicit owner DTO only');
update app_private.fn_zones set owner_id='f7270000-0000-0000-0000-000000000004' where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply');
select is((pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',(select value from fn_test_state where key='hui-request-body'),'f7270000-0000-0000-0000-000000000995')->'result'),(select value->'result' from fn_test_state where key='hui-request'),'exact review replay preserves result without a second version increment');
select is((select count(*) from app_private.fn_audit where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy') and action='admin.zone.review' and details->>'commandId'='f7270000-0000-0000-0000-000000000995'),1::bigint,'review replay creates one audit entry only');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('approved')||jsonb_build_object('expectedVersion',(select value->'expectedVersion' from fn_test_state where key='hui-request-body')))$$,'40001','VERSION_CONFLICT','old review version cannot approve over a newer correction request');
update app_private.fn_zones set status='paused' where event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy') and type<>'finale' and id<>(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply');
insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,verified,source) select a.event_id,a.id,b.id,2,true,'synthetic-fixture' from app_private.fn_zones a join app_private.fn_zones b on b.event_id=a.event_id and b.id<>a.id where a.event_id=(select id from app_private.events where slug='frightnight-2027-test-occupancy') and (a.id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply') or b.id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')) on conflict do nothing;
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select (value#>>'{snapshot,journey,id}')::uuid from fn_test_state where key='occ-start'))));
select isnt(api.frightnight_snapshot('frightnight-2027-test-occupancy')#>>'{current,zoneId}',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'zone with requested corrections is excluded from actual routing');
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.apply',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'name','HUI02 corrected house','address','Synthetic reviewed address','type','candy','intensity',0,'capacity',8,'opensAt','2027-10-30T15:00Z','closesAt','2027-10-30T19:00Z','stepFree',true));
select is((select review_status from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'submitted','owner correction explicitly resubmits for review');
select is((select review_reason from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'Maak de doorgang vrij en bevestig de ligging opnieuw.','resubmission preserves last correction reason as owner reference');
select throws_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('approved'))$$,'22023','ZONE_CONFIRMATION_REQUIRED','edited house requires location reconfirmation before approval');
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000004','zone.location.confirm',jsonb_build_object('zoneId',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'expectedVersion',(select version from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'confirmed',true,'latitude',52.095,'longitude',4.26));
select lives_ok($$select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000001','admin.zone.review',pg_temp.fn_hui_body('approved'))$$,'organization approves the corrected and reconfirmed own house');
select is((select review_reason from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),null,'approval clears obsolete correction reason');
select pg_temp.fn_occ_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select (value#>>'{snapshot,journey,id}')::uuid from fn_test_state where key='occ-start'))));
select is(api.frightnight_snapshot('frightnight-2027-test-occupancy')#>>'{current,zoneId}',(select value->>'zoneId' from fn_test_state where key='hui-apply'),'approved corrected house becomes routable through the normal deterministic engine');
select ok(not exists(select 1 from app_private.fn_visits where zone_id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')),'review and correction never fabricate a completed visit');
select ok(not exists(select 1 from app_private.fn_receipts where command_key='f7270000-0000-0000-0000-000000000995' and result::text like '%Maak de doorgang%'),'review reason is not copied into command receipt');
select throws_ok($$update app_private.fn_zones set review_status='rejected',review_reason=null where id=(select (value->>'zoneId')::uuid from fn_test_state where key='hui-apply')$$,'23514',null,'table independently prevents rejected review without a reason');

-- Sales policy is independent from stopping a live event. Grid changes retain
-- existing paid appointments and real-time PSP holds without deleting slots.
create function pg_temp.fn_config_cmd(who uuid,cmd text,body jsonb default '{}',k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$begin perform set_config('request.jwt.claims',jsonb_build_object('sub',who,'role','authenticated')::text,true);return api.frightnight_command('frightnight-2027-test-config',cmd,body,k);end$$;
create function pg_temp.fn_config(p_values jsonb) returns jsonb language sql as $$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.settings',p_values||jsonb_build_object('expectedVersion',(select version from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-config'))))$$;
create function pg_temp.fn_config_confirm(state_key text,provider_status text,provider_event text) returns jsonb language sql as $$select api.frightnight_payment_confirm('frightnight-2027-test-config',value->>'provider_ref',provider_status,(value->>'amount_cents')::integer,'EUR',provider_event,jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging')) from fn_test_state where key=state_key$$;
select api.frightnight_bootstrap('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
select api.frightnight_entry_grant('frightnight-2027-test-config',u.id,clock_timestamp()+interval '1 hour',repeat('b',64)) from auth.users u where u.id between 'f7270000-0000-0000-0000-000000000001'::uuid and 'f7270000-0000-0000-0000-000000000008'::uuid;
insert into fn_test_state select 'config-seed',pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','test.seed')->'result';
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','test.walk.fixture');
select is((api.frightnight_snapshot('frightnight-2027-test-config')#>>'{event,startBlockMinutes}')::integer,15,'new edition defaults to fifteen-minute advisory blocks');
select is((select count(*) from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and enabled),16::bigint,'initial grid covers both exact evening windows');
select lives_ok($$select pg_temp.fn_config('{"enabledRoutes":[]}')$$,'both evening sales can be disabled explicitly without stopping the event');
select is((select enabled_routes from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-config')),array[]::text[],'empty evening set is persisted as an explicit no-new-sales policy');
select pg_temp.fn_config('{"enabledRoutes":["lantern","roots"]}');
select throws_ok($$select pg_temp.fn_config('{"enabledRoutes":["lantern","lantern"]}')$$,'22023','INVALID_SALES_SETTINGS','available evenings cannot duplicate or contain unknown values');
select throws_ok($$select pg_temp.fn_config('{"salesOpen":"false"}')$$,'22023','INVALID_SALES_SETTINGS','sales switch requires a real boolean');
select throws_ok($$select pg_temp.fn_config('{"startBlockMinutes":7}')$$,'22023','INVALID_START_BLOCK_MINUTES','grid interval is restricted to reviewed five ten fifteen or thirty minutes');
select throws_ok($$select pg_temp.fn_config('{"salesClosesAt":"not-a-date-value"}')$$,'22023','INVALID_SALES_SETTINGS','sales closing time is validated server-side');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','admin.settings','{"salesOpen":false,"expectedVersion":1}')$$,'42501','NOT_AUTHORIZED','participant cannot change sales or grid configuration');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Historical fifteen-minute family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:15Z","consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'config-a-order',api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000002','f7270000-0000-0000-0000-000000000991');
update fn_test_state set value=api.frightnight_payment_bind('frightnight-2027-test-config',(value->>'order_id')::uuid,'ct_'||(value->>'order_id'),null) where key='config-a-order';
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Paid current-grid family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:00Z","consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'config-b-order',api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000003',gen_random_uuid());
update fn_test_state set value=api.frightnight_payment_bind('frightnight-2027-test-config',(value->>'order_id')::uuid,'ct_'||(value->>'order_id'),null) where key='config-b-order';
select pg_temp.fn_config_confirm('config-b-order','paid','config-b-paid');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:15Z","capacity":1}')$$,'22023','CAPACITY_BELOW_BOOKINGS','capacity reduction counts open real-time payment holds');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:00Z","capacity":1}')$$,'22023','CAPACITY_BELOW_BOOKINGS','capacity reduction also counts active confirmed paid places');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T11:00Z","capacity":2}')$$,'22023','START_SLOT_NOT_FOUND','nonexistent start slot update fails explicitly');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:00Z","capacity":0}')$$,'22023','INVALID_START_SLOT_CAPACITY','start capacity cannot be zero');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:15Z","capacity":2}');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:00Z","capacity":2}');
insert into fn_test_state select 'config-slot-before',to_jsonb(ss) from app_private.fn_start_slots ss where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and starts_at='2027-10-30T15:15Z';
select pg_temp.fn_config('{"startBlockMinutes":30}');
select is((select count(*) from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and enabled),8::bigint,'thirty-minute grid enables exactly three lantern and five roots choices');
select is((select count(*) from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config')),16::bigint,'changing grid never deletes historical block rows');
select is((select capacity from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and starts_at='2027-10-30T15:15Z'),2,'disabled historical block preserves its configured capacity and hold');
select is((select capacity from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and starts_at='2027-10-30T15:00Z'),2,'retained current-grid block preserves its customized paid capacity');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select count(*) from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-config')->'startSlots')s),9::bigint,'participant sees enabled grid plus their own retained historical appointment');
select is((select s->>'historical' from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-config')->'startSlots')s where s->>'startsAt'='2027-10-30T15:15:00+00:00'),'true','own historical start is explicitly labelled');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Historical preference update","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:15Z"}')$$,'existing own historical start remains editable without losing its quote');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Cannot take retired block","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:15Z","consent":true,"termsVersion":"2027-test-v1"}')$$,'22023','START_SLOT_UNAVAILABLE','new family cannot reserve a retired historical block');
select is(api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000002','f7270000-0000-0000-0000-000000000991')->>'order_id',(select value->>'order_id' from fn_test_state where key='config-a-order'),'retry preserves the original quote and existing historical appointment');
insert into fn_test_state select 'config-a-before-close',to_jsonb(o) from app_private.fn_orders o where id=(select (value->>'order_id')::uuid from fn_test_state where key='config-a-order');
select pg_temp.fn_config('{"salesOpen":false}');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Closed sales new family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}')$$,'22023','SALES_CLOSED','sales closure rejects new registrations without creating a household');
select throws_ok($$select api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000002','f7270000-0000-0000-0000-000000000991')$$,'22023','SALES_CLOSED','sales closure rejects even an existing open checkout retry before any provider create');
select is((select to_jsonb(o) from app_private.fn_orders o where id=(select (value->>'order_id')::uuid from fn_test_state where key='config-a-order')),(select value from fn_test_state where key='config-a-before-close'),'rejected closed checkout neither changes quote nor extends its real-time hold');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Paid edit while sales closed","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:00Z"}')$$,'existing paid family can change label and comfort after sales closure');
select lives_ok($$select pg_temp.fn_config_confirm('config-a-order','paid','config-a-after-sales-closed')$$,'old genuine provider checkout may still confirm payment after sales closure');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is(api.frightnight_snapshot('frightnight-2027-test-config')#>>'{registration,status}','active','late provider truth retains active rights when the original historical hold still fits');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='config-seed')))$$,'sales closure does not stop a paid journey outside its advisory block but within evening window');
select is(api.frightnight_snapshot('frightnight-2027-test-config')#>>'{journey,state}','walking','advisory historical start is not a mandatory appointment');
select pg_temp.fn_config('{"salesOpen":true,"enabledRoutes":["roots"]}');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Disabled lantern family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}')$$,'22023','ROUTE_SALES_CLOSED','disabled evening cannot accept new registration');
select throws_ok($$select api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000002',gen_random_uuid())$$,'22023','ROUTE_SALES_CLOSED','disabled evening blocks new checkout calls without changing existing paid rights');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Disabled-route comfort edit","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:15Z","avoidSmoke":true}')$$,'existing disabled-route family can still manage their original contact and comfort');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(api.frightnight_snapshot('frightnight-2027-test-config')#>>'{journey,id}')::uuid)))$$,'disabling new route sales never pauses a previously active route');
select pg_temp.fn_config('{"enabledRoutes":["lantern","roots"],"salesClosesAt":"2027-10-30T15:06:00Z"}');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','test.clock','{"time":"2027-10-30T15:06:00Z"}');
select throws_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Timed closed sales","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}')$$,'22023','SALES_CLOSED','sales closes exactly at configured business-clock boundary');
select throws_ok($$select api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000002',gen_random_uuid())$$,'22023','SALES_CLOSED','business-clock closing boundary also blocks new provider checkout calls');
select is((select count(*) from app_private.fn_registrations where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and owner_id='f7270000-0000-0000-0000-000000000004'),0::bigint,'all denied sales registrations leave no participant row');
select pg_temp.fn_config('{"salesClosesAt":null,"startBlockMinutes":5}');
select is((select count(*) from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and enabled),48::bigint,'five-minute grid adds only bounded choices across both exact windows');
select is((select capacity from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and starts_at='2027-10-30T15:05Z'),100,'genuinely new grid slots receive explicit default capacity one hundred');
select is((select capacity from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and starts_at='2027-10-30T15:15Z'),2,'reenabling an old slot preserves its customized capacity');
select pg_temp.fn_config('{"startBlockMinutes":10,"salesOpen":false,"enabledRoutes":["roots"]}');
select is((select count(*) from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and enabled),24::bigint,'ten-minute grid is deterministic and non-destructive');
insert into fn_test_state select 'config-copy',pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','test.copy','{"slug":"frightnight-2027-test-config-copy"}');
select is((select sales_open from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-config-copy')),false,'edition copy preserves sales switch rather than reopening enrollment');
select is((select start_block_minutes from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-config-copy')),10,'edition copy preserves configured grid interval');
select is((select enabled_routes from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-config-copy')),array['roots'],'edition copy preserves available evening selection');
select is((select capacity from app_private.fn_start_slots where event_id=(select id from app_private.events where slug='frightnight-2027-test-config-copy') and starts_at='2027-10-30T15:00Z'),2,'configuration copy preserves matching block capacities without copying people or holds');
select is((select count(*) from app_private.fn_orders where event_id=(select id from app_private.events where slug='frightnight-2027-test-config-copy')),0::bigint,'configuration copy does not duplicate existing orders');

-- Reset archives synthetic claimants without rewriting financial order history.
-- An archived old open attempt cannot occupy a new scenario's last places.
select pg_temp.fn_config('{"salesOpen":true,"enabledRoutes":["lantern","roots"],"salesClosesAt":null}');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','admin.startslot.save','{"startsAt":"2027-10-30T15:40Z","capacity":2}');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Synthetic reset open hold","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:40Z","consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'config-reset-open',api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000004',gen_random_uuid());
update fn_test_state set value=api.frightnight_payment_bind('frightnight-2027-test-config',(value->>'order_id')::uuid,'ct_'||(value->>'order_id'),null) where key='config-reset-open';
update app_private.fn_registrations set synthetic=true where id=(select (value->>'registration_id')::uuid from fn_test_state where key='config-reset-open');
insert into fn_test_state select 'config-reset-order-before',to_jsonb(o) from app_private.fn_orders o where id=(select (value->>'order_id')::uuid from fn_test_state where key='config-reset-open');
select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000001','test.reset',jsonb_build_object('confirmation','frightnight-2027-test-config','runId',(api.frightnight_snapshot('frightnight-2027-test-config')#>>'{event,runId}')));
select is((select status from app_private.fn_registrations where id=(select (value->>'registration_id')::uuid from fn_test_state where key='config-reset-open')),'archived','reset archives synthetic registration even with a pending real-time order');
select is((select to_jsonb(o) from app_private.fn_orders o where id=(select (value->>'order_id')::uuid from fn_test_state where key='config-reset-open')),(select value from fn_test_state where key='config-reset-order-before'),'reset preserves exact open financial attempt including original hold timestamp');
select is(app_private.fn_slot_available((select id from app_private.events where slug='frightnight-2027-test-config'),'2027-10-30T15:40Z',null),2,'archived or cancelled registration open attempt no longer claims start capacity');
select lives_ok($$select pg_temp.fn_config_cmd('f7270000-0000-0000-0000-000000000005','registration.save','{"label":"Next scenario uses last places","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:40Z","consent":true,"termsVersion":"2027-test-v1"}')$$,'a new current-run family can choose all freed places after reset');
insert into fn_test_state select 'config-after-reset-order',api.frightnight_payment_create('frightnight-2027-test-config','f7270000-0000-0000-0000-000000000005',gen_random_uuid());
select is(app_private.fn_slot_available((select id from app_private.events where slug='frightnight-2027-test-config'),'2027-10-30T15:40Z',null),0,'only the new valid open hold consumes those two places');
select lives_ok($$select pg_temp.fn_config_confirm('config-reset-open','paid','config-reset-archived:latepaid')$$,'old checkout provider truth still reconciles after its synthetic owner was archived');
select is((select status from app_private.fn_registrations where id=(select (value->>'registration_id')::uuid from fn_test_state where key='config-reset-open')),'archived','late payment never reactivates archived scenario enrollment');
select is((select count(*) from app_private.fn_ledger where order_id=(select (value->>'order_id')::uuid from fn_test_state where key='config-reset-open') and kind='receipt'),1::bigint,'archived late receipt remains exactly once in financial ledger');
select is(app_private.fn_slot_available((select id from app_private.events where slug='frightnight-2027-test-config'),'2027-10-30T15:40Z',null),0,'late archived receipt does not steal new scenario capacity');
select is((select count(*) from app_private.fn_destinations where event_id=(select id from app_private.events where slug='frightnight-2027-test-config') and party_id in(select party_id from app_private.fn_members where registration_id=(select (value->>'registration_id')::uuid from fn_test_state where key='config-reset-open')) and state='current'),0::bigint,'archived payment truth creates no route claim');

-- Temporary ordinary pressure is not permission to prematurely finish a walk.
create function pg_temp.fn_wait_cmd(who uuid,cmd text,body jsonb default '{}',k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$begin perform set_config('request.jwt.claims',jsonb_build_object('sub',who,'role','authenticated')::text,true);return api.frightnight_command('frightnight-2027-test-wait',cmd,body,k);end$$;
create function pg_temp.fn_wait_pay(who uuid) returns jsonb language plpgsql as $$declare o jsonb;begin o:=api.frightnight_payment_create('frightnight-2027-test-wait',who,gen_random_uuid());perform api.frightnight_payment_bind('frightnight-2027-test-wait',(o->>'order_id')::uuid,'ct_'||(o->>'order_id'),null);return api.frightnight_payment_confirm('frightnight-2027-test-wait','ct_'||(o->>'order_id'),'paid',(o->>'amount_cents')::integer,'EUR','wait-paid:'||(o->>'order_id'),jsonb_build_object('order_id',o->>'order_id','event_id',o->>'event_id','testmode',true,'environment','staging'));end$$;
select api.frightnight_bootstrap('frightnight-2027-test-wait','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
select api.frightnight_entry_grant('frightnight-2027-test-wait',u.id,clock_timestamp()+interval '1 hour',repeat('c',64)) from auth.users u where u.id between 'f7270000-0000-0000-0000-000000000001'::uuid and 'f7270000-0000-0000-0000-000000000008'::uuid;
insert into fn_test_state select 'wait-seed',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.seed')->'result';
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.walk.fixture');
update app_private.fn_zones set status='closed' where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and type='fright';
update app_private.fn_zones set capacity=2 where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and type='candy';
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Waiting family A","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_wait_pay('f7270000-0000-0000-0000-000000000002');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','registration.save','{"label":"Waiting family B","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_wait_pay('f7270000-0000-0000-0000-000000000003');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='wait-seed')));
insert into fn_test_state select 'wait-b',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='wait-seed')));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,state}','waiting','full suitable candy and free finale produce a waiting state');
select is(api.frightnight_snapshot('frightnight-2027-test-wait')->'current','null'::jsonb,'temporary fullness does not release an early finale destination');
select alike(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,reason}','%tijdelijk%','temporary wait has explicit useful explanation');
select is((api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{progress,sparks}')::integer,0,'waiting grants no visits or light reward');
select is((select details->>'reason' from app_private.fn_audit where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and action='route.decision' order by id desc limit 1),'temporary-ordinary-unavailable','route audit distinguishes temporary ordinary pressure from final return');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.pause',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')))));
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','journey.resume',jsonb_build_object('expectedVersion',(select (value#>>'{snapshot,journey,version}')::integer from fn_test_state where key='wait-b')));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{current,zone,type}','candy','resuming after controlled capacity release selects the ordinary house');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','journey.pause',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,version}')::integer));
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','zone.status',jsonb_build_object('zoneId',z.id,'expectedVersion',z.version,'status','paused','pauseUntil','2027-10-30T15:20Z','reason','Temporary ordinary fixture pause')) from app_private.fn_zones z where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and type='candy';
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')))));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,state}','waiting','temporarily paused but still feasible ordinary house also defers finale');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.clock','{"time":"2027-10-30T15:21Z"}');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')))));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{current,zone,type}','candy','timed pause expiry and explicit resume restore a suitable ordinary destination');
select is(api.frightnight_walk('frightnight-2027-test-wait',(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{current,id}')::uuid)->'from',(select jsonb_build_object('latitude',latitude,'longitude',longitude) from app_private.fn_zones where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and type='finale'),'pause and resume of an unvisited house keeps verified Duinpad walking origin');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.clock','{"time":"2027-10-30T16:29Z"}');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000003')))));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{current,zone,type}','finale','when ordinary visit and verified return no longer fit finale becomes appropriate');
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,state}','walking','near-end finale selection still requires a real final scan');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.clock','{"time":"2027-10-30T15:05Z"}');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.finish',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')))));
select is(api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{current,zone,type}','finale','explicit personal stop remains an immediate safe final return despite viable ordinary houses');

-- Per-edition limits govern new changes without retroactively cancelling quotes.
create function pg_temp.fn_wait_settings(p_values jsonb) returns jsonb language sql as $$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','admin.settings',p_values||jsonb_build_object('expectedVersion',(select version from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait'))))$$;
select throws_ok($$select pg_temp.fn_wait_settings('{"maxRegistrationPersons":21,"maxPartyPersons":30}')$$,'22023','INVALID_PARTY_LIMITS','registration limit remains bounded by twenty real places');
select throws_ok($$select pg_temp.fn_wait_settings('{"maxPartyPersons":101}')$$,'22023','INVALID_PARTY_LIMITS','joint party limit is bounded at one hundred persons');
select throws_ok($$select pg_temp.fn_wait_settings('{"maxRegistrationPersons":5,"maxPartyPersons":4}')$$,'22023','INVALID_PARTY_LIMITS','joint maximum cannot be less than one permitted registration');
select lives_ok($$select pg_temp.fn_wait_settings('{"maxRegistrationPersons":20,"maxPartyPersons":100}')$$,'largest reviewed registration and joint limits are configurable');
select is((api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{event,maxPartyPersons}')::integer,100,'authorized event snapshot exposes exact configured joint maximum');
select is((api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{event,maxRegistrationPersons}')::integer,20,'event snapshot exposes exact configured registration maximum');
insert into fn_test_state select 'limit-party-invite',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','party.invite')->'result';
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000003','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='limit-party-invite'),'consent',true));
insert into fn_test_state select 'limit-existing-party',to_jsonb(d) from app_private.fn_destinations d where party_id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')) and state='current';
select pg_temp.fn_wait_settings('{"maxRegistrationPersons":1,"maxPartyPersons":2}');
select is((api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{event,maxRegistrationPersons}')::integer,1,'a smaller limit is stored without rewriting paid registrations');
select is((select to_jsonb(d) from app_private.fn_destinations d where id=(select (value->>'id')::uuid from fn_test_state where key='limit-existing-party')),(select value from fn_test_state where key='limit-existing-party'),'lowering joint limit preserves the existing oversized current reservation');
select lives_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','registration.save','{"label":"Old paid two-person family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"startSlot":"2027-10-30T15:00Z"}')$$,'old paid quote remains manageable when current registration maximum is smaller');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','journey.resume',jsonb_build_object('expectedVersion',(select version from app_private.fn_parties where id=(select party_id from app_private.fn_members where registration_id=app_private.fn_registration((select id from app_private.events where slug='frightnight-2027-test-wait'),'f7270000-0000-0000-0000-000000000002')))));
select is((api.frightnight_snapshot('frightnight-2027-test-wait')#>>'{journey,party,persons}')::integer,4,'existing four-person joint route remains intact after lowering the maximum');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Too large new family","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}')$$,'22023','REGISTRATION_TOO_LARGE','new registration cannot exceed current per-edition person maximum');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000004','registration.save','{"label":"Allowed one person","routeType":"lantern","adults":1,"children":0,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_wait_pay('f7270000-0000-0000-0000-000000000004');
insert into fn_test_state select 'limit-current-invite',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','party.invite')->'result';
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000004','party.join',jsonb_build_object('token',(select value->>'token' from fn_test_state where key='limit-current-invite'),'consent',true))$$,'22023','PARTY_TOO_LARGE','new member cannot enlarge an existing party above the new maximum');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','test.copy','{"slug":"frightnight-2027-test-limits-copy"}');
select is((select max_registration_persons from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-limits-copy')),1,'edition copy preserves configured registration maximum');
select is((select max_party from app_private.fn_events where event_id=(select id from app_private.events where slug='frightnight-2027-test-limits-copy')),2,'edition copy preserves configured joint maximum');
select throws_ok($$update app_private.fn_events set max_party=101 where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait')$$,'23514',null,'table independently enforces bounded party settings');
-- Durable help assignment uses existing confirmed scoped staff only.
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'f7270000-0000-0000-0000-000000000005','live_support' from app_private.events where slug='frightnight-2027-test-wait';
insert into fn_test_state select 'help-submitted',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','help.submit','{"category":"route","text":"Synthetic household question for staff assignment"}')->'result';
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(not(api.frightnight_snapshot('frightnight-2027-test-wait')?'incidentStaffChoices'),'participant receives no support-staff identity choices');
select is((select i->>'assigned' from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'ownIncidents')i where i->>'id'=(select value->>'incidentId' from fn_test_state where key='help-submitted')),'false','own new incident starts visibly unassigned');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000002','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo','f7270000-0000-0000-0000-000000000001'))$$,'42501','NOT_AUTHORIZED','participant cannot assign even their own incident');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo','f7270000-0000-0000-0000-000000000003'))$$,'42501','INVALID_ASSIGNEE','a confirmed participant without support capability cannot be assigned');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo',''))$$,'22023','INVALID_ASSIGNEE','empty string is not a substitute for explicit null unassignment');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'assignedTo','f7270000-0000-0000-0000-000000000001'))$$,'40001','VERSION_CONFLICT','assignment requires current incident version');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId','f7270000-0000-0000-0000-000000000299','expectedVersion',1,'assignedTo',null))$$,'42501','NOT_AUTHORIZED','incident from another edition or nonexistent target cannot be assigned');
insert into fn_test_state select 'help-assignment',pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo','f7270000-0000-0000-0000-000000000001'),'f7270000-0000-0000-0000-000000000994')->'result';
select is((select assigned_to from app_private.fn_incidents where id=(select (value->>'incidentId')::uuid from fn_test_state where key='help-submitted')),'f7270000-0000-0000-0000-000000000001'::uuid,'authorized support staff can durably assign a scoped event administrator');
select is((pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo','f7270000-0000-0000-0000-000000000001'),'f7270000-0000-0000-0000-000000000994')->'result'),(select value from fn_test_state where key='help-assignment'),'exact assignment replay is idempotent');
select is((select version from app_private.fn_incidents where id=(select (value->>'incidentId')::uuid from fn_test_state where key='help-submitted')),2,'assignment replay does not increment the incident version twice');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select i->>'assigned' from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'ownIncidents')i where i->>'id'=(select value->>'incidentId' from fn_test_state where key='help-submitted')),'true','own second read shows durable assignment status');
select ok(not exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'ownIncidents')i where i ?| array['assignedTo','assigneeEmail','assigneeName']),'own incident never exposes support actor UUID or contact identity');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select ok(exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'incidentStaffChoices')c where c->>'id'='f7270000-0000-0000-0000-000000000001'),'support role gets bounded current qualified staff choices');
select ok(not exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'incidentStaffChoices')c where c ?| array['email','phone','contactName','contactPhone']),'support choices contain no contact fields');
select is((select i->>'assignedTo' from jsonb_array_elements(api.frightnight_admin_list('frightnight-2027-test-wait','incidents',0,50)->'items')i where i->>'id'=(select value->>'incidentId' from fn_test_state where key='help-submitted')),'f7270000-0000-0000-0000-000000000001','authorized paginated incident DTO includes current staff assignment');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.reply',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'text','Stale reply'))$$,'40001','VERSION_CONFLICT','stale reply cannot overwrite a newer assignment');
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','admin.incident.resolve',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1))$$,'40001','VERSION_CONFLICT','stale resolve cannot silently close changed incident');
select lives_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.reply',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',2,'text','Het synthetische hulppunt heeft antwoord.'))$$,'versioned assigned support reply is durable');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is((select i->>'response' from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'ownIncidents')i where i->>'id'=(select value->>'incidentId' from fn_test_state where key='help-submitted')),'Het synthetische hulppunt heeft antwoord.','requesting household sees staff response on a new server read');
select lives_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',3,'assignedTo',null))$$,'support can explicitly clear assignment without changing incident status');
select lives_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','admin.incident.resolve',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',4))$$,'support resolves the exact current incident version');
select is((select status from app_private.fn_incidents where id=(select (value->>'incidentId')::uuid from fn_test_state where key='help-submitted')),'resolved','resolution status is durably independent from assignment');
update app_private.event_capabilities set revoked_at=clock_timestamp() where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and user_id='f7270000-0000-0000-0000-000000000005' and capability='live_support';
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000005','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',1,'assignedTo','f7270000-0000-0000-0000-000000000001'),'f7270000-0000-0000-0000-000000000994')$$,'42501','NOT_AUTHORIZED','revoked support role cannot replay a previously authorized assignment');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(not exists(select 1 from jsonb_array_elements(api.frightnight_snapshot('frightnight-2027-test-wait')->'incidentStaffChoices')c where c->>'id'='f7270000-0000-0000-0000-000000000005'),'revoked staff disappears immediately from available assignment choices');
select ok(not exists(select 1 from app_private.fn_audit where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and action='incident.assigned' and details::text~'(@|contactPhone|email|Synthetic household)'),'assignment audit contains IDs and versions without contact or incident message values');

-- Router time budgets and map endpoints consume the identical visited origin.
create function pg_temp.fn_origin_cmd(cmd text,body jsonb default '{}') returns jsonb language plpgsql as $$begin perform set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000002","role":"authenticated"}',true);return api.frightnight_command('frightnight-2027-test-origin',cmd,body,gen_random_uuid());end$$;
select api.frightnight_bootstrap('frightnight-2027-test-origin','f7270000-0000-0000-0000-000000000001','staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
select api.frightnight_entry_grant('frightnight-2027-test-origin','f7270000-0000-0000-0000-000000000002',clock_timestamp()+interval '1 hour',repeat('d',64));
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into fn_test_state select 'origin-seed',api.frightnight_command('frightnight-2027-test-origin','test.seed','{}',gen_random_uuid())->'result';
select api.frightnight_command('frightnight-2027-test-origin','test.walk.fixture','{}',gen_random_uuid());
select pg_temp.fn_origin_cmd('registration.save','{"label":"Verified-origin family","routeType":"lantern","adults":1,"children":1,"maxIntensity":2,"consent":true,"termsVersion":"2027-test-v1"}');
insert into fn_test_state select 'origin-order',api.frightnight_payment_create('frightnight-2027-test-origin','f7270000-0000-0000-0000-000000000002',gen_random_uuid());
select api.frightnight_payment_bind('frightnight-2027-test-origin',(select (value->>'order_id')::uuid from fn_test_state where key='origin-order'),(select 'ct_'||(value->>'order_id') from fn_test_state where key='origin-order'),null);
select api.frightnight_payment_confirm('frightnight-2027-test-origin',value->>'provider_ref','paid',(value->>'amount_cents')::integer,'EUR','origin-paid',jsonb_build_object('order_id',value->>'order_id','event_id',value->>'event_id','testmode',true,'environment','staging')) from(select api.frightnight_payment_for_actor('frightnight-2027-test-origin','f7270000-0000-0000-0000-000000000002')value)s;
select pg_temp.fn_origin_cmd('journey.start',jsonb_build_object('expectedVersion',1,'code',(select value->>'startCode' from fn_test_state where key='origin-seed')));
insert into fn_test_state select 'origin-first',api.frightnight_snapshot('frightnight-2027-test-origin')->'current';
-- Explicit reviewed-edge CONTRACT fixtures: not a claim of a real street path.
update app_private.fn_walk_edges w set minutes=3,source='organisation-verified',geometry=jsonb_build_object('type','LineString','coordinates',jsonb_build_array(jsonb_build_array(a.longitude,a.latitude),jsonb_build_array(b.longitude,b.latitude))) from app_private.fn_zones a,app_private.fn_zones b where w.event_id=(select id from app_private.events where slug='frightnight-2027-test-origin') and a.id=w.from_zone_id and b.id=w.to_zone_id and a.id=(select (value->>'zoneId')::uuid from fn_test_state where key='origin-first');
select pg_temp.fn_origin_cmd('journey.complete',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-origin')#>>'{journey,version}')::integer,'destinationId',(select value->>'id' from fn_test_state where key='origin-first'),'code',(select z->>'code' from fn_test_state t cross join lateral jsonb_array_elements(t.value->'zoneCodes')z where t.key='origin-seed' and z->>'zoneId'=(select value->>'zoneId' from fn_test_state where key='origin-first'))));
insert into fn_test_state select 'origin-skipped',api.frightnight_snapshot('frightnight-2027-test-origin')->'current';
select pg_temp.fn_origin_cmd('journey.skip',jsonb_build_object('expectedVersion',(api.frightnight_snapshot('frightnight-2027-test-origin')#>>'{journey,version}')::integer,'destinationId',(select value->>'id' from fn_test_state where key='origin-skipped')));
insert into fn_test_state select 'origin-after-skip',api.frightnight_walk('frightnight-2027-test-origin',(api.frightnight_snapshot('frightnight-2027-test-origin')#>>'{current,id}')::uuid);
select is((select value->'from' from fn_test_state where key='origin-after-skip'),(select jsonb_build_object('latitude',latitude,'longitude',longitude) from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='origin-first')),'skipping an unvisited assignment never moves map origin away from last completed visit');
select is((api.frightnight_snapshot('frightnight-2027-test-origin')#>>'{current,walkMinutes}')::integer,3,'router uses the same verified last-visited edge minutes as the map adapter');
select is((select value#>'{geometry,coordinates,0}' from fn_test_state where key='origin-after-skip'),(select jsonb_build_array(longitude,latitude) from app_private.fn_zones where id=(select (value->>'zoneId')::uuid from fn_test_state where key='origin-first')),'reviewed contract geometry starts at the same verified origin');
select is((select value->'to' from fn_test_state where key='origin-after-skip'),(select jsonb_build_object('latitude',latitude,'longitude',longitude) from app_private.fn_zones where id=(api.frightnight_snapshot('frightnight-2027-test-origin')#>>'{current,zoneId}')::uuid),'map target remains exactly the single authorized current destination');

select pg_temp.fn_wait_settings('{"maxRegistrationPersons":20,"maxPartyPersons":20}');
select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000006','registration.save','{"label":"Unquoted registration before limit change","routeType":"lantern","adults":1,"children":1,"maxIntensity":1,"consent":true,"termsVersion":"2027-test-v1"}');
select pg_temp.fn_wait_settings('{"maxRegistrationPersons":1,"maxPartyPersons":2}');
select throws_ok($$select api.frightnight_payment_create('frightnight-2027-test-wait','f7270000-0000-0000-0000-000000000006',gen_random_uuid())$$,'22023','REGISTRATION_TOO_LARGE','an unquoted oversized old draft cannot obtain a new checkout after a lower limit');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'f7270000-0000-0000-0000-000000000006','live_support' from app_private.events where slug='frightnight-2027-test-wait';
update auth.users set banned_until=clock_timestamp()+interval '1 hour' where id='f7270000-0000-0000-0000-000000000006';
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',5,'assignedTo','f7270000-0000-0000-0000-000000000006'))$$,'42501','INVALID_ASSIGNEE','banned scoped support member cannot receive incident assignment');
update auth.users set banned_until=null,email_confirmed_at=null where id='f7270000-0000-0000-0000-000000000006';
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',5,'assignedTo','f7270000-0000-0000-0000-000000000006'))$$,'42501','INVALID_ASSIGNEE','unconfirmed scoped support member cannot receive incident assignment');
update auth.users set email_confirmed_at=now() where id='f7270000-0000-0000-0000-000000000006';
update app_private.event_capabilities set revoked_at=clock_timestamp() where event_id=(select id from app_private.events where slug='frightnight-2027-test-wait') and user_id='f7270000-0000-0000-0000-000000000006' and capability='live_support';
select throws_ok($$select pg_temp.fn_wait_cmd('f7270000-0000-0000-0000-000000000001','help.assign',jsonb_build_object('incidentId',(select value->>'incidentId' from fn_test_state where key='help-submitted'),'expectedVersion',5,'assignedTo','f7270000-0000-0000-0000-000000000006'))$$,'42501','INVALID_ASSIGNEE','revoked event support membership cannot be selected as assignee');
select set_config('request.jwt.claims','{"sub":"f7270000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(jsonb_array_length(api.frightnight_snapshot('frightnight-2027-test-wait')->'ownIncidents'),0,'another family in the same walking party cannot read the requesting household incident');

select * from finish();
rollback;
