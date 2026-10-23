begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table ops_values(eid uuid,event_version integer,first_schedule uuid,first_revision integer,first_group_version integer,first_key text default gen_random_uuid()::text,publication_count integer);
insert into ops_values(eid,event_version,first_group_version,publication_count)
select e.id,e.settings_version,g.version,(select count(*) from app_private.group_start_publications)
  from app_private.events e join app_private.walking_groups g on g.event_id=e.id and g.id='23000000-0000-0000-0000-000000000001'
  where e.slug='duindorp-halloween-2026';
grant select,update on ops_values to authenticated;
update app_private.event_route_settings set first_start_at='2026-10-31T15:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',
  finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',
  finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic'
where event_id=(select eid from ops_values);
update app_private.walking_groups set desired_ordinary_visits=3 where id='23000000-0000-0000-0000-000000000001';
create temp table protected_ops_rows as select 'registration' kind,md5(jsonb_agg(to_jsonb(r) order by r.id)::text) fingerprint
  from app_private.registration_children r union all select 'credentials',md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.portal_credentials r
  union all select 'seals',md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text),'[]'::jsonb)::text) from app_private.poortenboek_passport_seals r;

select ok(not has_function_privilege('authenticated','app_private.published_start_projection(uuid,timestamptz)','execute'),'participants cannot supply their own release clock');
select ok(not has_table_privilege('authenticated','app_private.group_start_publications','select'),'published private snapshots are not directly readable');
select ok(not app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'legacy coordinate verification is not fabricated as an explicit walking check');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,false,'Veilige fictieve testaanloop')$$,'23514','SAFE_CONNECTION_REQUIRED','a nonempty approach alone cannot replace the explicit safety checkbox');
select throws_ok($$select api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,true,' ')$$,'23514','SAFE_CONNECTION_REQUIRED','a checked box cannot replace a concrete approach');
select lives_ok($$select api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,true,'Gecontroleerde fictieve aanloop via de stoep en het zebrapad')$$,'explicit verification succeeds at a real approved fixture node');
select lives_ok($$update ops_values set first_schedule=(api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-31T16:30:00Z',(select first_group_version from ops_values),'neutral','Nieuwe fictieve vertrekafspraak als concept')->>'id')::uuid$$,'a working start assignment is saved through the real command');
set local role postgres;
update ops_values set first_revision=s.revision from app_private.group_schedule_revisions s where s.id=first_schedule;
select is((select route_mode from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),'legacy','saving a correction does not switch the previously published dispatch mode');
select is((select count(*)::integer from app_private.group_start_publications),(select publication_count from ops_values),'saving a concept creates no participant publication');
select is((select confirmed_at from app_private.group_schedule_revisions where id=(select first_schedule from ops_values)),null::timestamptz,'saving does not implicitly confirm');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,start,startsAt}','2026-10-31T17:30:00+00:00','the previously published time remains active during a new concept');
select ok(api.group_snapshot('23000000-0000-0000-0000-000000000001')::text not like '%NIET-BESTAAND TESTADRES%','parent response contains no early start address');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',999,(select event_version from ops_values))$$,'40001','STALE_REVISION','a stale confirmation cannot confirm a replacement revision');
select lives_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',(select first_revision from ops_values),(select event_version from ops_values))$$,'the actual current revision can be explicitly confirmed');
select is((select item->>'state' from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,groups}') item where item->>'groupId'='23000000-0000-0000-0000-000000000001'),'confirmed','confirmed working status survives a new snapshot request');
select is(jsonb_typeof(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,routes,23000000-0000-0000-0000-000000000001,stops}'),'array','the authorized route preview comes from real server planning');
select throws_ok($$select api.admin_startregie_publish('duindorp-halloween-2026',array[(select first_schedule from ops_values)],'Oud commando zonder verwachte revisie wordt geweigerd')$$,'40001','EXPECTED_REVISION_REQUIRED','an older command cannot bypass the revision-bearing publication boundary');
select throws_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values),'65000000-0000-0000-0000-000000000099'::uuid],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',1),jsonb_build_object('id','65000000-0000-0000-0000-000000000099','revision',1)),(select event_version from ops_values),gen_random_uuid()::text)$$,'40001','STALE_REVISION','a mixed valid/invalid batch is rejected atomically');
select lives_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',(select first_revision from ops_values))),(select event_version from ops_values),(select first_key from ops_values))$$,'the selected confirmed start time can be explicitly published');
select lives_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',(select first_revision from ops_values))),(select event_version from ops_values),(select first_key from ops_values))$$,'an exact publication retry returns the same receipt');
select throws_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select first_schedule from ops_values)],jsonb_build_array(jsonb_build_object('id',(select first_schedule from ops_values),'revision',999)),(select event_version from ops_values),(select first_key from ops_values))$$,'23505','IDEMPOTENCY_CONFLICT','a key cannot be reused for different publication content');
set local role postgres;
select is((select count(*)::integer from app_private.group_start_publications),(select publication_count+1 from ops_values),'batch rejection and retry add exactly one immutable publication');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T15:29:00Z')->>'name','Startlocatie volgt','T minus 61 has a generic name instead of a location-like name');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T15:29:00Z')->'coordinate','null'::jsonb,'T minus 61 contains no map coordinate');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T15:29:00Z')->'address','null'::jsonb,'T minus 61 contains no address');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T15:30:00Z')->>'address','NIET-BESTAAND TESTADRES','the exact T minus 60 boundary reveals the frozen first address');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T16:29:59Z')->>'canStart','false','address release does not allow an early start');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T16:30:00Z')->>'canStart','true','the server time predicate reaches its boundary at the published start');
select ok(not exists(select 1 from app_private.email_outbox where dedupe_key like 'group-schedule:23000000-0000-0000-0000-000000000001:%' and (payload?'startPoint' or payload?'startAddress')),'queued time-publication notifications do not contain early location secrets');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.registration_preferences_snapshot('duindorp-halloween-2026')#>>'{confirmedSchedule,startsAt}','2026-10-31T16:30:00+00:00','registration portal reads the immutable published time');
select is(api.registration_preferences_snapshot('duindorp-halloween-2026')#>'{confirmedSchedule,startAddress}','null'::jsonb,'registration portal cannot leak the address ahead of the same boundary');
select ok(api.group_snapshot('23000000-0000-0000-0000-000000000001')->'run'='null'::jsonb,'time publication does not expose future route destinations');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role postgres;
create function pg_temp.ops_present_child() returns uuid language sql security definer set search_path='' as $$select c.id from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id where a.group_id='23000000-0000-0000-0000-000000000001' and a.superseded_at is null and c.participation_status='active' limit 1$$;
-- Temporary helper only supplies fixture IDs, never a production clock override.
set local role postgres;
grant execute on function pg_temp.ops_present_child() to authenticated;
update ops_values set first_group_version=g.version from app_private.walking_groups g where g.id='23000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$select api.run_start('23000000-0000-0000-0000-000000000001',array[pg_temp.ops_present_child()],(select first_group_version from ops_values),'not-yet-startable-fixture','fixture')$$,'23514','START_TIME_NOT_REACHED','an alternative direct departure command cannot start before the published time');
set local role postgres;
select throws_ok($$update app_private.group_start_publications set starts_at=now() where schedule_id=(select first_schedule from ops_values)$$,'23514','PUBLISHED_APPOINTMENT_IMMUTABLE','even an accidental trusted update cannot rewrite an existing publication');
select throws_ok($$delete from app_private.group_start_publications where schedule_id=(select first_schedule from ops_values)$$,'23514','PUBLISHED_APPOINTMENT_IMMUTABLE','a publication cannot be silently deleted');
update app_private.start_points set private_address='GEWIJZIGD NOG BESLOTEN TESTADRES',version=version+1 where id='20000000-0000-0000-0000-000000000001';
select ok(not app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'an address change invalidates the walking verification');
select is((select s.state::text from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id where g.id='23000000-0000-0000-0000-000000000001'),'draft','relevant point changes produce a new working draft');
select is(app_private.published_start_projection('23000000-0000-0000-0000-000000000001','2026-10-31T15:30:00Z')->>'address','NIET-BESTAAND TESTADRES','the changed live point cannot overwrite a previously published address');
select throws_ok($$update app_private.start_points set active=false where id='20000000-0000-0000-0000-000000000001'$$,'23514','START_POINT_IN_USE','an assigned start point cannot be archived');
select is((select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.registration_children r),(select fingerprint from protected_ops_rows where kind='registration'),'start changes preserve existing child IDs and registration relations');
select is((select md5(jsonb_agg(to_jsonb(r) order by r.id)::text) from app_private.portal_credentials r),(select fingerprint from protected_ops_rows where kind='credentials'),'start changes do not rotate QR or short-code credentials');
select is((select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text),'[]'::jsonb)::text) from app_private.poortenboek_passport_seals r),(select fingerprint from protected_ops_rows where kind='seals'),'choosing, confirming and publishing a start grants no fabricated seal');
select * from finish();
rollback;
