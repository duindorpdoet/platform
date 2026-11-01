begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000001":"visited","d9000000-0000-0000-0000-000000000002":"skipped"}','frozen-first-scan');
-- A newly accepted adult may access their household but is not retroactively
-- added to the first-scan cohort or its closing-mail list.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
values('d1000000-0000-0000-0000-000000000005','new-adult@example.invalid',now(),'{}','{}');
insert into app_private.household_members(household_id,user_id,relation_role)
values('d2000000-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000005','adult');
-- Independent household has no own scan but belongs to the frozen cohort.
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(api.duinpad_finale_snapshot('duindorp-halloween-2026')->>'recorded','false','a cohort member need not have an own scan');
alter table app_private.duinpad_evenings disable trigger duinpad_evening_immutable;
update app_private.duinpad_evenings set first_finale_scan_at=statement_timestamp()-interval '2 hours',evening_ends_at=statement_timestamp();
alter table app_private.duinpad_evenings enable trigger duinpad_evening_immutable;
select is(api.duinpad_finale_snapshot('duindorp-halloween-2026')->>'eveningEnded','true','the same deadline closes a non-scanning household');
select throws_ok($$select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000003":"visited"}','after-deadline')$$,'23514','EVENING_ENDED','worker lag cannot admit a new final scan');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select is(api.duinpad_finale_snapshot('duindorp-halloween-2026')->>'eveningEnded','true','a new household adult still sees the actual expired run deadline');
select throws_ok($$select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000003":"visited"}','late-new-adult')$$,'23514','EVENING_ENDED','accepting a new adult after first scan cannot reopen the group finale');
select is((select count(*)from app_private.duinpad_evening_members where account_id='d1000000-0000-0000-0000-000000000005'),0::bigint,'frozen mail cohort receives no retroactive new adult');
select is((select count(*)from app_private.duinpad_finale_receipts),1::bigint,'late membership creates no extra scan receipt');
insert into app_private.walking_groups(id,event_id,code,status,route_mode)
select 'd7000000-0000-0000-0000-000000000002',id,'DUINPAD-REASSIGNED','live','dynamic'from app_private.events where slug='duindorp-halloween-2026';
update app_private.group_registrations set superseded_at=clock_timestamp()where registration_id='d3000000-0000-0000-0000-000000000001'and superseded_at is null;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at)
values('d7000000-0000-0000-0000-000000000002','d3000000-0000-0000-0000-000000000001',2,now());
insert into app_private.group_runs(id,group_id,status,started_at)
values('d8000000-0000-0000-0000-000000000002','d7000000-0000-0000-0000-000000000002','paused',now());
insert into app_private.group_leaders(group_id,user_id,active_from,revision,assigned_by)
values('d7000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000001',now()-interval '1 minute',1,'f0000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(api.group_snapshot('d7000000-0000-0000-0000-000000000002')#>>'{run,ownEveningFinished}','true','reassigned current group still carries the personal closed evening');
select is(api.group_snapshot('d7000000-0000-0000-0000-000000000002')#>>'{run,duinpadEveningEnded}','true','deadline-specific UI flag also survives reassignment');
select is(api.group_snapshot('d7000000-0000-0000-0000-000000000002')->'duinpadFinale','{"eveningEnded":true}'::jsonb,'new group receives only the personal closed boolean, no old private finale destination');
select throws_ok($$select api.run_start('d7000000-0000-0000-0000-000000000002','{}',1,'ended-new-start','ended-new-start')$$,'23514','EVENING_ENDED','reassignment cannot open a new native route start');
select throws_ok($$select api.run_set_state('d8000000-0000-0000-0000-000000000002','live',1,'Herstart oude avond')$$,'23514','EVENING_ENDED','old cohort cannot resume a fresh assigned run');
select throws_ok($$select api.run_scan('d8000000-0000-0000-0000-000000000002',gen_random_uuid(),1,'SYNTHETIC','qr')$$,'23514','EVENING_ENDED','old cohort cannot use a new ordinary scan after deadline');
select is(api.duinpad_finale_confirm('duindorp-halloween-2026','old-code','{}','ended-receipt')->>'duplicate','true','own receipt recovery remains available after closing and reassignment');
set local role postgres;
select is(api.worker_duinpad_evenings()->>'queued','4','all frozen adults receive one closing mail despite reassignment');
select *from finish();
rollback;
