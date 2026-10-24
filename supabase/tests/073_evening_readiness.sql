begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- Isolate this scenario from earlier browser guidance progress; rollback restores it.
delete from app_private.participant_tutorials where user_id='a0000000-0000-0000-0000-000000000001' and role='parent';
create temp table old_rows as select 'credentials' kind,md5(jsonb_agg(to_jsonb(c) order by c.id)::text) hash from app_private.portal_credentials c
 union all select 'publications',md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.group_start_publications p
 union all select 'children',md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c;
create function pg_temp.record_ready(kind text,id uuid,check_name text,source text default 'observed',key text default 'readiness-test-default-key',rev text default null,detail text default null,attest jsonb default '{}',done boolean default true) returns jsonb language sql as $$
 select api.record_evening_readiness(kind,id,check_name,source,rev,detail,attest,done,key)
$$;
create function pg_temp.subject(kind text,id uuid) returns jsonb language sql as $$
 select v from jsonb_array_elements(api.admin_evening_readiness('duindorp-halloween-2026')->'subjects') v where v->>'kind'=kind and v->>'id'=id::text
$$;
create function pg_temp.criterion(kind text,id uuid,check_name text) returns jsonb language sql as $$
 select v from jsonb_array_elements(pg_temp.subject(kind,id)->'criteria') v where v->>'check'=check_name
$$;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.admin_evening_readiness('duindorp-halloween-2026')$$,'actual admin can read readiness');
select is(pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'state','unknown','opening admin overview manufactures no participant proof');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','account_opened')$$,'42501','NOT_AUTHORIZED','admin cannot impersonate a participant observation');
select throws_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','account_opened')$$,'42501','NOT_AUTHORIZED','admin cannot impersonate a portal owner observation');
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','account_opened','manual','manual-group-contact-001',pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'revision','Gebeld met de verantwoordelijke','{"confirmed":true}')$$,'admin records explicit contact as manual evidence');
select is(pg_temp.subject('group','23000000-0000-0000-0000-000000000002')->>'observedHouseholds','0','manual contact is not a household observation');
select is(pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'state','complete','manual source has explicit aggregate status');
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','account_opened','manual','manual-group-contact-002',pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'revision','Nog niet ingelogd, opnieuw contact nodig','{"confirmed":true}',false)$$,'later explicit not-ready is recorded separately');
select is(pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'state','not_done','old positive cannot conceal later negative attestation');
select is(jsonb_array_length(pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->'evidence'),2,'both manual statements remain visible');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','account_opened','manual','manual-group-contact-002',pg_temp.criterion('group','23000000-0000-0000-0000-000000000002','account_opened')->>'revision','Veranderde inhoud met dezelfde sleutel','{"confirmed":true}',false)$$,'23505','IDEMPOTENCY_CONFLICT','idempotency key binds original server-hashed contents');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','start_time_seen','manual','manual-stale-publication','publication:old','Gecontroleerde oude publicatie','{"confirmed":true}')$$,'40001','STALE_READINESS_REVISION','stale publication cannot be attested as current');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_evening_readiness('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','participant cannot read organization-wide readiness');
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000001','account_opened','observed','own-account-opened-001')$$,'actual own adult can record opening own group');
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000001','account_opened','observed','own-account-opened-001')$$,'unknown-response retry returns original result');
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000001','account_opened','observed','own-account-opened-002')$$,'reopening is safely deduplicated per actual actor and revision');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000002','account_opened','observed','foreign-group-opening-01')$$,'42501','NOT_AUTHORIZED','adult cannot observe a different group');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000001','account_opened','observed','forged-actor-opening-01',null,null,'{"actor":"f0000000-0000-0000-0000-000000000001"}')$$,'22023','VALIDATION_ERROR','client-supplied actor is rejected');
select throws_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000001','tutorial_completed','observed','fake-tutorial-complete-01','tutorial:parent:1')$$,'23514','TUTORIAL_NOT_COMPLETED','observation cannot invent completed tutorial');
set local role postgres;
select is((select count(*) from app_private.evening_readiness_evidence where subject_type='group' and subject_id='23000000-0000-0000-0000-000000000001' and check_name='account_opened'),1::bigint,'retries and mounts produce one observed row');
select is((select actor_id from app_private.evening_readiness_evidence where subject_type='group' and subject_id='23000000-0000-0000-0000-000000000001' and check_name='account_opened'),'a0000000-0000-0000-0000-000000000001'::uuid,'actor is derived from authenticated server context');
select throws_ok($$update app_private.evening_readiness_evidence set done=false$$,'23514','READINESS_EVIDENCE_IMMUTABLE','even privileged updates cannot rewrite evidence');
select throws_ok($$delete from app_private.evening_readiness_evidence$$,'23514','READINESS_EVIDENCE_IMMUTABLE','history is not deleted');
insert into app_private.participant_tutorials(event_id,user_id,role,version,last_step,furthest_step,completed_at)
 select id,'a0000000-0000-0000-0000-000000000001','parent',1,13,13,now()-interval '1 day' from app_private.events where slug='duindorp-halloween-2026';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(pg_temp.criterion('group','23000000-0000-0000-0000-000000000001','tutorial_completed')->>'state','complete','actual existing completed tutorial is projected without invented evidence');
select is(pg_temp.subject('group','23000000-0000-0000-0000-000000000001')->>'observedHouseholds','1','actual own adult observation counts one own household');
select is(jsonb_array_length(pg_temp.subject('group','23000000-0000-0000-0000-000000000001')->'householdDetails'),1,'organization gets household-level detail');
-- One adult's observation does not mark two households as having read the account.
update app_private.group_registrations set group_id='23000000-0000-0000-0000-000000000003' where group_id='23000000-0000-0000-0000-000000000002' and superseded_at is null;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000007","role":"authenticated"}',true);
select lives_ok($$select pg_temp.record_ready('group','23000000-0000-0000-0000-000000000003','account_opened','observed','one-of-two-households-01')$$,'one actual adult opens a group with two households');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(pg_temp.subject('group','23000000-0000-0000-0000-000000000003')->>'householdsTotal','2','both current households are counted');
select is(pg_temp.subject('group','23000000-0000-0000-0000-000000000003')->>'observedHouseholds','1','only the observed household is counted');
select is(pg_temp.criterion('group','23000000-0000-0000-0000-000000000003','account_opened')->>'state','unknown','one adult does not give the whole group a completed observed status');
-- Actual owner, current credential, and separate physical declaration.
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','account_opened','observed','owner-account-opened-001')$$,'actual owner records own account observation');
select throws_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','qr_tested','observed','owner-fake-physical-001',null)$$,'22023','OBSERVATION_NOT_ALLOWED','PDF/open action cannot manufacture physical QR evidence');
set local role postgres;
create temp table credential_revision as select app_private.evening_readiness_revision('portal','12000000-0000-0000-0000-000000000001','qr_tested') revision;
grant select on credential_revision to authenticated;
set local role authenticated;
select throws_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','qr_tested','manual','owner-physical-wrong-001',(select revision from credential_revision),'Geprinte poster gecontroleerd','{"confirmed":true,"printed":true,"scannedWithPhone":true,"shortCode":"WRONG"}')$$,'22023','PHYSICAL_QR_ATTESTATION_REQUIRED','physical declaration checks actual current short code');
select lives_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','qr_tested','manual','owner-physical-good-001',(select revision from credential_revision),'Geprinte poster met telefoon getest','{"confirmed":true,"printed":true,"scannedWithPhone":true,"shortCode":"test-01"}')$$,'valid explicit physical declaration is saved');
select lives_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','qr_tested','manual','owner-physical-good-001',(select revision from credential_revision),'Geprinte poster met telefoon getest','{"confirmed":true,"printed":true,"scannedWithPhone":true,"shortCode":"test-01"}')$$,'same physical retry is idempotent');
set local role postgres;
select ok(not exists(select 1 from app_private.evening_readiness_evidence where attestations::text like '%TEST-01%' or attestations::text like '%test-01%'),'evidence retains no actual short code');
select is((select count(*) from app_private.evening_readiness_evidence where check_name='qr_tested'),1::bigint,'physical retry appends no duplicate');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.portal_credentials c),(select hash from old_rows where kind='credentials'),'readiness does not rotate or rewrite credentials');
select is((select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.group_start_publications p),(select hash from old_rows where kind='publications'),'published appointments remain identical');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),(select hash from old_rows where kind='children'),'children and registration relations remain identical');
update app_private.portal_credentials set revoked_at=now() where portal_id='12000000-0000-0000-0000-000000000001';
insert into app_private.portal_credentials(portal_id,version,token_hash,short_code_hash,valid_from) values('12000000-0000-0000-0000-000000000001',2,extensions.digest('new-test-token','sha256'),extensions.digest('NEW-01','sha256'),now());
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(pg_temp.criterion('portal','12000000-0000-0000-0000-000000000001','qr_tested')->>'state','outdated','explicit new credential makes old physical evidence outdated');
select is(jsonb_array_length(pg_temp.criterion('portal','12000000-0000-0000-0000-000000000001','qr_tested')->'evidence'),1,'old physical declaration remains visible');
update app_private.portal_owners set suspended_at=now() where portal_id='12000000-0000-0000-0000-000000000001' and user_id='e0000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select pg_temp.record_ready('portal','12000000-0000-0000-0000-000000000001','account_opened','observed','owner-account-opened-001')$$,'42501','NOT_AUTHORIZED','suspension is checked before returning an old receipt');
set local role postgres;
select ok(not has_table_privilege('authenticated','app_private.evening_readiness_evidence','select'),'evidence table is private');
select ok(not has_function_privilege('anon','api.admin_evening_readiness(text)','execute'),'anonymous users cannot read organization readiness');
select ok(not has_function_privilege('authenticated','app_private.evening_readiness_rows(text,uuid,text)','execute'),'private projection cannot be called directly');
select * from finish();
rollback;
