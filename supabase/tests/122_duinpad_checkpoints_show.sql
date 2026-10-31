begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
create temp table duinpad_qr_state(admin jsonb,attempt uuid,result jsonb,route_hash text,credential_hash text);
insert into duinpad_qr_state select null,null,null,
(select md5(jsonb_agg(to_jsonb(s)order by id)::text)from app_private.run_stops s),
(select md5(jsonb_agg(to_jsonb(c)order by id)::text)from app_private.portal_credentials c);
select ok(not has_function_privilege('authenticated','api.duinpad_show_reserve(uuid,uuid,uuid,text,uuid,text,text,text,bigint)','execute'),'browser role cannot impersonate a server show request');
select ok(not has_table_privilege('authenticated','app_private.duinpad_show_attempts','select'),'show payloads and history remain private');
select throws_ok($$select api.duinpad_checkpoint_admin('duindorp-halloween-2026','d1000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','participant cannot read checkpoint credentials');
select throws_ok($$select api.duinpad_checkpoint_admin('duindorp-halloween-2026','f0000000-0000-0000-0000-000000000001','link',jsonb_build_object('portalId',(select final_portal_id from app_private.event_route_settings limit 1),'label','Wrong','instruction','Wrong physical mapping'))$$,'P0001','INVALID_CHECKPOINT','QR1 can never alias the true finalepoort');
update duinpad_qr_state set admin=api.duinpad_checkpoint_admin('duindorp-halloween-2026','f0000000-0000-0000-0000-000000000001','create',jsonb_build_object('label','Duinpad ingang','instruction','Voor de heks aanmelden','ciphertext','synthetic-ciphertext','tokenHash',encode(extensions.digest('QR1-SYNTHETIC','sha256'),'hex'),'shortHash',encode(extensions.digest('QR1-SHORT','sha256'),'hex')));
select is((select admin#>>'{qr2,id}'from duinpad_qr_state),(select final_portal_id::text from app_private.event_route_settings limit 1),'QR2 uses the actual configured finalepoort identity');
select is((select md5(jsonb_agg(to_jsonb(s)order by id)::text)from app_private.run_stops s),(select route_hash from duinpad_qr_state),'creating a show checkpoint adds no ordinary route stop');
select is((select md5(jsonb_agg(to_jsonb(c)order by id)::text)from app_private.portal_credentials c),(select credential_hash from duinpad_qr_state),'creating QR1 preserves all existing QR2 and portal credentials');
select is(api.duinpad_checkpoint_admin('duindorp-halloween-2026','f0000000-0000-0000-0000-000000000001'),(select admin from duinpad_qr_state),'reading and downloading use the same persistent checkpoint material');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(api.duinpad_checkpoint_validate('duindorp-halloween-2026','QR1-SYNTHETIC')->>'stage','qr1','server-validated QR1 identifies only the registration stage');
select is(api.duinpad_checkpoint_validate('duindorp-halloween-2026','qr1-short')->>'stage','qr1','the persistent QR1 short code is case insensitive');
select is(api.duinpad_checkpoint_validate('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN'),null::jsonb,'QR2 credential cannot be substituted for QR1');
select throws_ok($$select api.duinpad_finale_validate('duindorp-halloween-2026','QR1-SYNTHETIC')$$,'22023','WRONG_PORTAL','QR1 cannot authorize a final arrival');
set local role postgres;
create function pg_temp.reserve(stage text,source text,actor uuid,attempt uuid) returns jsonb language plpgsql as $$
declare eid uuid;issued bigint;payload text;
begin
 select id into eid from app_private.events where slug='duindorp-halloween-2026';issued:=floor(extract(epoch from clock_timestamp()));
 payload:=case when source='visitor' then jsonb_build_object('stage',stage,'group_id','d8000000-0000-0000-0000-000000000001','label','Synthetic','event_id',attempt,'issued_at',issued)::text
 else jsonb_build_object('action','finale.go','group_id','d8000000-0000-0000-0000-000000000001','command_id',attempt,'event_scope_id',eid,'actor_subject',actor,'issued_at',issued)::text end;
 return api.duinpad_show_reserve(actor,eid,'d8000000-0000-0000-0000-000000000001',stage,attempt,source,payload,encode(extensions.digest(payload,'sha256'),'hex'),issued);
end $$;
update duinpad_qr_state set attempt=gen_random_uuid();
update duinpad_qr_state set result=pg_temp.reserve('qr1','visitor','d1000000-0000-0000-0000-000000000001',attempt);
select is((select result->>'dispatch'from duinpad_qr_state),'true','first QR1 registration gets one immediate attempt');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'registered','{"ok":true,"stage":"qr1"}');
select is(pg_temp.reserve('qr1','visitor','d1000000-0000-0000-0000-000000000002',gen_random_uuid())->>'dispatch','false','second account reuses the confirmed group registration');
select is((select count(*)from app_private.duinpad_show_attempts where stage='qr1'),1::bigint,'no second group_add is produced');
select is((select count(*)from app_private.duinpad_evenings),0::bigint,'QR1 never starts the evening clock');
select is(api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000001','duindorp-halloween-2026',null,'qr2'),null::jsonb,'a confirmed QR1 receipt never masquerades as a QR2 attempt after an interrupted browser flow');
insert into app_private.duinpad_actor_access(event_id,user_id,email,display_name,status,permissions,created_by)
select id,'d1000000-0000-0000-0000-000000000001','duinpad-1@example.invalid','Synthetic actor','active',array['finale.go'],'f0000000-0000-0000-0000-000000000001'from app_private.events where slug='duindorp-halloween-2026';
update duinpad_qr_state set attempt=gen_random_uuid();
select is(pg_temp.reserve('qr2','actor','d1000000-0000-0000-0000-000000000001',(select attempt from duinpad_qr_state))->>'dispatch','true','manual actor finale can request the shared slot without fabricating a visitor scan');
select is((select count(*)from app_private.duinpad_evenings),0::bigint,'manual actor Finale GO starts no visitor deadline');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'blocked','{"ok":false,"reason":"heks_not_ready"}');
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000001":"visited","d9000000-0000-0000-0000-000000000002":"skipped"}','show-business-scan');
update duinpad_qr_state set attempt=gen_random_uuid();
select is(pg_temp.reserve('qr2','visitor','d1000000-0000-0000-0000-000000000001',(select attempt from duinpad_qr_state))->>'dispatch','true','after an explicit block a new conscious visitor attempt can use the same business receipt');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'unknown','{"ok":false,"unknown":true}');
select is(pg_temp.reserve('qr2','actor','d1000000-0000-0000-0000-000000000001',gen_random_uuid())->>'dispatch','false','actor and visitor share an unknown physical slot');
select is(api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000001','duindorp-halloween-2026',(select attempt from duinpad_qr_state))->>'status','unknown','receipt recovery is read only and does not repost an execution payload');
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('d1000000-0000-0000-0000-000000000005','duinpad-operator@example.invalid',now(),'{}','{}');
insert into app_private.duinpad_actor_access(event_id,user_id,email,display_name,status,permissions,created_by)
select id,'d1000000-0000-0000-0000-000000000005','duinpad-operator@example.invalid','Replacement operator','active',array['finale.go'],'f0000000-0000-0000-0000-000000000001'from app_private.events where slug='duindorp-halloween-2026';
-- Transaction timestamps may tie; physical reservations have their own stable order.
update app_private.duinpad_show_attempts set created_at=statement_timestamp()where run_id='d8000000-0000-0000-0000-000000000001'and stage='qr2';
select is(api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000005','duindorp-halloween-2026',null,'qr2','d8000000-0000-0000-0000-000000000001')->>'status','unknown','current replacement finale actor can read only the shared physical slot without original actor rights');
select is((api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000005','duindorp-halloween-2026',null,'qr2','d8000000-0000-0000-0000-000000000001')->>'attemptId')::uuid,(select id from app_private.duinpad_show_attempts where run_id='d8000000-0000-0000-0000-000000000001'and stage='qr2'and attempt_order=(select max(attempt_order)from app_private.duinpad_show_attempts where run_id='d8000000-0000-0000-0000-000000000001'and stage='qr2')),'shared receipt follows the greatest reservation order even when timestamps tie');
select throws_ok($$select api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000005','duindorp-halloween-2026',null,'qr1','d8000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','replacement actor scope cannot read QR1 registration through shared finale recovery');
select throws_ok($$select api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000004','duindorp-halloween-2026',null,'qr2','d8000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','participant cannot choose a recovery run with an operator-only argument');
update app_private.duinpad_actor_access set status='revoked'where user_id='d1000000-0000-0000-0000-000000000005';
select throws_ok($$select api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000005','duindorp-halloween-2026',null,'qr2','d8000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','revoked replacement actor immediately loses shared recovery access');
select throws_ok($$select api.duinpad_show_receipt('d1000000-0000-0000-0000-000000000005','duindorp-halloween-2026',(select attempt from duinpad_qr_state),'qr2')$$,'42501','NOT_AUTHORIZED','an outsider with no route cannot inspect a known foreign attempt ID through SQL null authorization');
select throws_ok($$select api.duinpad_show_receipt(null,'duindorp-halloween-2026',(select attempt from duinpad_qr_state),'qr2')$$,'42501','NOT_AUTHORIZED','a missing authenticated account never authorizes a recovery read');
select ok(not has_function_privilege('authenticated','api.duinpad_show_receipt(uuid,text,uuid,text,uuid)','execute'),'raw recovery payloads remain service-only');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'blocked','{"ok":false}');
select is((select status from app_private.duinpad_show_attempts where id=(select attempt from duinpad_qr_state)),'unknown','ordinary failure cannot erase an unknown execution');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'not_dispatched','{"ok":false,"verified_not_executed":true}',true);
update duinpad_qr_state set attempt=gen_random_uuid();
select is(pg_temp.reserve('qr2','visitor','d1000000-0000-0000-0000-000000000001',(select attempt from duinpad_qr_state))->>'dispatch','true','verified non-execution permits a deliberate new attempt');
update app_private.duinpad_show_attempts set created_at=clock_timestamp()-interval '16 seconds'where id=(select attempt from duinpad_qr_state);
select is(pg_temp.reserve('qr2','actor','d1000000-0000-0000-0000-000000000001',gen_random_uuid())->>'status','unknown','stale requested execution becomes unknown and blocks replay');
select api.duinpad_show_finish((select attempt from duinpad_qr_state),'started','{"ok":true,"qlc_started":true,"audio_started":true}');
select is(pg_temp.reserve('qr2','visitor','d1000000-0000-0000-0000-000000000001',gen_random_uuid())->>'dispatch','false','a historical started group cannot be replayed');
select is((select count(*)from app_private.duinpad_finale_receipts),1::bigint,'physical retries never create another business scan');
select ok(not has_function_privilege('authenticated','app_private.duinpad_finale_record(text,uuid,jsonb,text,text)','execute'),'a browser cannot submit only a guessed validated credential ID');
select *from finish();
rollback;
