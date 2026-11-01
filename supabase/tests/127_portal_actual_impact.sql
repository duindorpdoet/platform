begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
update app_private.portal_flags set value=false where flag_key='fixture';

select ok(not has_function_privilege('anon','api.portal_visits_snapshot(uuid)','EXECUTE'),'anonymous visit access remains forbidden');
select ok(has_function_privilege('authenticated','api.portal_visits_snapshot(uuid)','EXECUTE'),'existing authenticated visit endpoint remains available');
select ok(not has_function_privilege('anon','api.portal_room_snapshot(text,uuid)','EXECUTE'),'anonymous room access remains forbidden');
select ok(has_function_privilege('authenticated','api.portal_room_snapshot(text,uuid)','EXECUTE'),'existing authenticated room endpoint remains available');
select ok(not has_function_privilege('authenticated','app_private.portal_actual_visits(uuid)','EXECUTE'),'private aggregate cannot bypass room authorization');
select ok(not has_function_privilege('service_role','app_private.portal_actual_visits(uuid)','EXECUTE'),'private helper adds no service-role surface');
select is((select prosecdef from pg_proc where oid='app_private.portal_actual_visits(uuid)'::regprocedure),false,'new helper is security invoker');
select is((select provolatile::text from pg_proc where oid='app_private.portal_actual_visits(uuid)'::regprocedure),'s','complete physical projection is stable');

select set_config('request.jwt.claims','{"role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','missing identity cannot inspect impact');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated","user_metadata":{"admin":true}}',true);
select throws_ok($$select api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','participant and editable metadata do not grant portal access');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,groups}','0','active reservation and planned finale are not physical visits');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,children}','0','planned roster is not child attendance');
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000030')->'impact','{"actualGroups":0,"actualChildren":0}'::jsonb,'authorized room exposes explicit zero impact');
select throws_ok($$select api.portal_room_snapshot('unknown-event','12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','room event boundary remains enforced');

-- Real parent/party scan: both the entered and outside-waiting child arrived.
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000001":"visited","d9000000-0000-0000-0000-000000000002":"skipped"}','impact-real-party-arrival');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,groups}','1','canonical visit, scan, receipt and arrivals deduplicate one group');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,children}','2','outside waiting child counts as actually arrived');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{visits,0,children}','2','visit row uses actual children rather than only entered children');
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000030')->'impact','{"actualGroups":1,"actualChildren":2}'::jsonb,'room certificate uses the same verified physical totals');

-- A different household reaches the already completed finale stop later.
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000003":"skipped"}','impact-real-late-arrival');
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000003":"skipped"}','impact-real-late-arrival');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,groups}','1','late household receipt does not invent a second group');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,children}','3','late real child arrival is included once after duplicate confirmation');

set local role postgres;
-- A second historic group has the same real child identity. Several stops and
-- proof paths must not turn that child into several unique children.
insert into app_private.walking_groups(id,event_id,code,status,route_mode)
select ('e7000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,id,'IMPACT-'||n,'live','dynamic'
from app_private.events,generate_series(2,4)n where slug='duindorp-halloween-2026';
insert into app_private.group_runs(id,group_id,status,started_at)
select ('e8000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('e7000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'live',now()-interval '20 minutes'from generate_series(2,4)n;
insert into app_private.portal_reservations(id,event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
select ('e5000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,id,'12000000-0000-0000-0000-000000000030',
 ('e7000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('e8000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 'finale','completed',now()-interval '20 minutes',now()-interval '17 minutes',3
from app_private.events,generate_series(2,4)n where slug='duindorp-halloween-2026';
insert into app_private.run_stops(id,run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
select ('eb000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('e8000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '12000000-0000-0000-0000-000000000030',('e5000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'finale',1,'active',now()-interval '20 minutes'from generate_series(2,4)n;
insert into app_private.run_participants(id,run_id,registration_child_id)
values('e9000000-0000-0000-0000-000000000002','e8000000-0000-0000-0000-000000000002','d5000000-0000-0000-0000-000000000001');
insert into app_private.scan_evidence(run_stop_id,credential_id,credential_version,actor_id,validation_method)
select s.id,c.id,c.version,'f0000000-0000-0000-0000-000000000001','qr'
from app_private.run_stops s cross join lateral(select * from app_private.portal_credentials where portal_id='12000000-0000-0000-0000-000000000030'order by version desc limit 1)c
where s.id::text like 'eb000000-%';
insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id)
select g.event_id,r.id,s.id,'e9000000-0000-0000-0000-000000000002','d4000000-0000-0000-0000-000000000001',e.id,true,now()-interval '15 minutes','f0000000-0000-0000-0000-000000000001'
from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id join app_private.scan_evidence e on e.run_stop_id=s.id where s.id='eb000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,groups}','2','another real group adds one while bare active scans add nothing');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,children}','3','same child arriving with another group remains one unique child');
select is(jsonb_array_length(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')->'visits'),2,'unconfirmed scan-only group is absent from history');

set local role postgres;
-- Pre-ledger legacy completion carries actual group-level scan evidence, but
-- cannot prove a child count. System skips remain excluded even with a scan.
insert into app_private.run_participants(id,run_id,registration_child_id)
select ('e9000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 ('e8000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('d5000000-0000-0000-0000-'||lpad((case when n=4 then 2 else n end)::text,12,'0'))::uuid from generate_series(3,4)n;
insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id,status)
select ('eb000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('e9000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'skipped'from generate_series(3,4)n;
update app_private.run_stops set state='completed',outcome='all_skipped',completed_at=now()-interval '10 minutes'where id='eb000000-0000-0000-0000-000000000003';
update app_private.run_stops set state='completed',outcome='system_skipped',completed_at=now()-interval '9 minutes'where id='eb000000-0000-0000-0000-000000000004';
set local role authenticated;
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,groups}','3','reviewed pre-ledger scan plus completed outside visit counts its group');
select is(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')#>>'{recap,children}','3','legacy group size is never guessed as child attendance');
select is(jsonb_array_length(api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')->'visits'),3,'system-skip scan adds no received group');

set local role postgres;
-- The same child departing or later withdrawing does not erase real history.
update app_private.run_participants set departed_at=now(),attendance='absent'where id='d9000000-0000-0000-0000-000000000001';
update app_private.registration_children set participation_status='cancelled'where id='d5000000-0000-0000-0000-000000000001';
update app_private.portal_owners set revoked_at=now()where portal_id='12000000-0000-0000-0000-000000000030'and role='owner'and revoked_at is null;
insert into app_private.portal_owners(portal_id,user_id,role,access_level)
values('12000000-0000-0000-0000-000000000030','d1000000-0000-0000-0000-000000000004','owner','manage');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
set local role authenticated;
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000030')->'impact','{"actualGroups":3,"actualChildren":3}'::jsonb,'owner reads history even after actual child departure or withdrawal');
select throws_ok($$select api.portal_visits_snapshot('12000000-0000-0000-0000-000000000029')$$,'42501','NOT_AUTHORIZED','one portal owner cannot read another portal impact');
set local role postgres;
update app_private.portal_owners set suspended_at=now()where portal_id='12000000-0000-0000-0000-000000000030'and user_id='d1000000-0000-0000-0000-000000000004';
set local role authenticated;
select throws_ok($$select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','suspended owner cannot read impact or certificate');
set local role postgres;
update app_private.portal_owners set suspended_at=null,revoked_at=now()where portal_id='12000000-0000-0000-0000-000000000030'and user_id='d1000000-0000-0000-0000-000000000004';
set local role authenticated;
select throws_ok($$select api.portal_visits_snapshot('12000000-0000-0000-0000-000000000030')$$,'42501','NOT_AUTHORIZED','revoked owner cannot read impact');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
-- Central closure grants display seals without manufacturing physical impact.
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic closure','Synthetic test body',gen_random_uuid());
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000030')->'impact','{"actualGroups":3,"actualChildren":3}'::jsonb,'central closure does not inflate actual impact');
select is(api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000029')->'impact','{"actualGroups":0,"actualChildren":0}'::jsonb,'unvisited gate stays zero despite frozen gift targets');
set local role postgres;
select ok(exists(select 1 from app_private.event_closure_portals where portal_id='12000000-0000-0000-0000-000000000029'),'negative impact case is an actual closure gift target');
select is((select count(*)from app_private.run_stop_arrivals where run_stop_id='db000000-0000-0000-0000-000000000001'),3::bigint,'physical child history remains exactly the three genuine arrivals');
select is((select count(*)from app_private.duinpad_show_attempts),0::bigint,'impact reads never create a physical show');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),0::bigint,'impact reads create no house mail');
select * from finish();
rollback;
