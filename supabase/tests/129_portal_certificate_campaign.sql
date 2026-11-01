begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
update app_private.portal_flags set value=false where flag_key='fixture'and portal_id in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000003','12000000-0000-0000-0000-000000000005');
update app_private.portals set lifecycle_status='archived'where id='12000000-0000-0000-0000-000000000003';
update app_private.portals set approval_status='withdrawn'where id='12000000-0000-0000-0000-000000000005';
update app_private.portal_owners set revoked_at=now()where revoked_at is null and portal_id in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000003','12000000-0000-0000-0000-000000000004','12000000-0000-0000-0000-000000000005');
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
select ('c1000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case n when 1 then 'cert-owner@example.invalid'when 2 then 'cert-shared@example.invalid'when 3 then 'CERT-SHARED@example.invalid'
 when 11 then null when 12 then 'invalid-address'when 20 then 'CERT-OWNER@example.invalid'else 'cert-'||n||'@example.invalid'end,
 case when n=8 then null else now()end,'{}','{}'from generate_series(1,20)n;
update auth.users set deleted_at=now()where id='c1000000-0000-0000-0000-000000000009';
update auth.users set banned_until=now()+interval '1 day'where id='c1000000-0000-0000-0000-000000000010';
insert into app_private.portal_owners(portal_id,user_id,role)
select ('12000000-0000-0000-0000-'||lpad((case when n=17 then 3 when n=18 then 4 when n=19 then 5 when n>=13 then 2 else 1 end)::text,12,'0'))::uuid,
 ('c1000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n in(1,17,18,19,20)then 'owner'when n=4 then 'viewer'when n=3 then 'actor'when n=13 then 'portal_manager'
 when n=14 then 'coadmin'when n=15 then 'reception'when n=16 then 'tech'else 'crew'end
from generate_series(1,20)n where n<>7 order by case when n in(1,17,18,19,20)then 0 else 1 end,n;
-- The same crew account is linked to two houses. The second actor shares that
-- account's normalized address. Neither relationship may create a second mail.
insert into app_private.portal_owners(portal_id,user_id,role)
values('12000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000002','tech');
update app_private.portal_owners set suspended_at=now()where user_id='c1000000-0000-0000-0000-000000000005';
update app_private.portal_owners set revoked_at=now()where user_id='c1000000-0000-0000-0000-000000000006';

select is((select count(*)from app_private.portal_certificate_campaigns),0::bigint,'migration creates no certificate campaign');
select is((select count(*)from app_private.email_outbox where message_type='portal_certificate_ready'),0::bigint,'migration sends and queues no certificate mail');
select ok(not has_function_privilege('anon','api.portal_certificate_admin_snapshot(text)','execute'),'campaign administration is not anonymous');
select ok(not has_function_privilege('authenticated','api.worker_portal_certificates(integer)','execute'),'users cannot run certificate fanout');
select ok(not has_function_privilege('authenticated','api.worker_portal_certificate_mail(uuid)','execute'),'mail material remains service only');
select ok(has_function_privilege('service_role','api.worker_portal_certificate_mail(uuid)','execute'),'existing service worker can obtain authorized material');
select ok(not has_function_privilege('authenticated','app_private.portal_certificate_candidates(uuid)','execute'),'private audience helper cannot expose team accounts');
select is((select count(*)from pg_class where oid in('app_private.portal_certificate_campaigns'::regclass,'app_private.portal_certificate_accounts'::regclass,'app_private.portal_certificate_recipients'::regclass)and relrowsecurity),3::bigint,'all campaign tables have RLS');
select ok(not has_table_privilege('authenticated','app_private.portal_certificate_accounts','select'),'no direct account cohort read grant');
select ok(not has_table_privilege('service_role','app_private.portal_certificate_recipients','insert'),'service operates through bounded RPCs rather than table grants');

select set_config('request.jwt.claims','{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"admin":true}}',true);
set local role authenticated;
select throws_ok($$select api.portal_certificate_admin_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','portal ownership and editable metadata do not authorize a campaign');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','No','No',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','portal owner cannot activate an organization campaign');
select throws_ok($$select api.portal_certificate_retry_failed('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','portal owner cannot retry campaign mail');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')->>'ready','false','certificate campaign is not ready before central closure');
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')->>'confirmed','false','opening preview never confirms a campaign');
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')->'message','null'::jsonb,'unconfirmed copy comes from the single frontend defaults source');
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')->'counts','{"participatingHouses":2,"teamAccounts":11,"uniqueEmailRecipients":6,"missingContactAccounts":3}'::jsonb,'preview excludes viewers, invalid users, retired/test houses and deduplicates accounts/addresses');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','Subject','Body',gen_random_uuid())$$,'23514','CERTIFICATES_NOT_READY','explicit confirm cannot claim an unready certificate');
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic event closure','Synthetic body',gen_random_uuid());
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')->>'ready','true','existing central closure makes the certificate ready');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026',E'Bad\nHeader','Body',gen_random_uuid())$$,'22023','VALIDATION_ERROR','subject header injection is rejected');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026',repeat('x',199)||'🎃','Body',gen_random_uuid())$$,'22023','VALIDATION_ERROR','subject limit counts JS UTF16 units');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','Subject',repeat('x',19999)||'🎃',gen_random_uuid())$$,'22023','VALIDATION_ERROR','body limit counts JS UTF16 units');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','Subject',chr(160),gen_random_uuid())$$,'22023','VALIDATION_ERROR','JS trim whitespace-only body is rejected');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','Subject',repeat('x',20000)||' ',gen_random_uuid())$$,'22023','VALIDATION_ERROR','raw trailing whitespace counts toward body limit');
select throws_ok($$select api.portal_certificate_confirm('duindorp-halloween-2026','Subject','Body',null)$$,'22023','VALIDATION_ERROR','confirm requires its command identity');
select is(api.portal_certificate_confirm('duindorp-halloween-2026','  Edited certificate 🎃  ',E'  Exact first line\n\nExtra invitation to next year.  ',gen_random_uuid())->>'existing','false','one deliberate admin confirmation creates the campaign');
select is(api.portal_certificate_confirm('duindorp-halloween-2026','Competing replacement','Must not overwrite',gen_random_uuid())->>'existing','true','repeat or competing command returns the existing campaign');
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')#>>'{campaign,subject}','  Edited certificate 🎃  ','confirmed subject stays verbatim and immutable');
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')#>>'{message,body}',E'  Exact first line\n\nExtra invitation to next year.  ','confirmed body stays verbatim including added paragraphs');
set local role postgres;
select is((select count(*)from app_private.portal_certificate_campaigns),1::bigint,'exactly one campaign per event');
select is((select count(*)from app_private.portal_certificate_accounts),8::bigint,'captured cohort includes every eligible working team role once');
select is((select count(*)from app_private.portal_certificate_recipients),6::bigint,'one durable target per normalized account address across houses');
select is((select count(*)from app_private.portal_certificate_accounts where account_id='c1000000-0000-0000-0000-000000000002'and cardinality(portal_ids)=2),1::bigint,'one account retains both authorized original portal bindings');
select is((select count(*)from app_private.portal_certificate_accounts where account_id in('c1000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000005','c1000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000007','c1000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000010','c1000000-0000-0000-0000-000000000011','c1000000-0000-0000-0000-000000000012','c1000000-0000-0000-0000-000000000017','c1000000-0000-0000-0000-000000000018','c1000000-0000-0000-0000-000000000019')),0::bigint,'no missing/unconfirmed/deleted/banned/viewer/nonmember/inactive portal recipient is frozen');
select is((select count(*)from app_private.email_outbox where message_type='portal_certificate_ready'),0::bigint,'confirm captures targets without synchronous mail fanout');
select is((select used from app_private.portal_room_budgets where kind='portal_certificate_confirm'and user_id='f0000000-0000-0000-0000-000000000001'),1,'only first valid confirmation consumes the abuse budget');
select throws_ok($$update app_private.portal_certificate_campaigns set body='overwrite'$$,'23514','CERTIFICATE_CAMPAIGN_IMMUTABLE','confirmed campaign text cannot be rewritten');
select throws_ok($$update app_private.portal_certificate_accounts set normalized_email='other@example.invalid'$$,'23514','CERTIFICATE_CAMPAIGN_IMMUTABLE','frozen account address cannot be rebound');
select throws_ok($$select api.worker_portal_certificates(0)$$,'22023','INVALID_INPUT','fanout rejects an empty batch');
select throws_ok($$select api.worker_portal_certificates(26)$$,'22023','INVALID_INPUT','fanout cannot exceed 25 recipients');
select is(api.worker_portal_certificates(1)->>'processed','1','bounded fanout processes one address');
select is((select count(*)from app_private.email_outbox where message_type='portal_certificate_ready'),1::bigint,'batch one creates only one outbox command');
select is(api.worker_portal_certificates(25)->>'processed','5','later cron tick resumes remaining durable targets');
select is(api.worker_portal_certificates(25)->>'processed','0','repeated worker ticks never duplicate mail');
select is((select count(distinct dedupe_key)from app_private.email_outbox where message_type='portal_certificate_ready'),6::bigint,'each frozen address has one fixed logical outbox identity');
select ok((select bool_and(payload->>'subject'='  Edited certificate 🎃  'and payload->>'body'=E'  Exact first line\n\nExtra invitation to next year.  'and payload->>'actionPath'='/mijn-huis')from app_private.email_outbox where message_type='portal_certificate_ready'),'all outbox messages retain exact confirmed copy and safe room path');
select ok((select bool_and(api.worker_portal_certificate_mail(id)->>'subject'='  Edited certificate 🎃  ')from app_private.email_outbox where message_type='portal_certificate_ready'),'service material reads authoritative immutable campaign content');
update app_private.portal_owners set suspended_at=now()where user_id='c1000000-0000-0000-0000-000000000002';
select ok(api.worker_portal_certificate_mail((select id from app_private.email_outbox where recipient_email='cert-shared@example.invalid'and message_type='portal_certificate_ready'))is not null,'shared address remains authorized through its other captured active account');
update app_private.portal_owners set revoked_at=now()where user_id='c1000000-0000-0000-0000-000000000003';
select ok(api.worker_portal_certificate_mail((select id from app_private.email_outbox where recipient_email='cert-shared@example.invalid'and message_type='portal_certificate_ready'))is null,'dispatch refuses an address after every captured binding loses access');
update auth.users set email='new-manager@example.invalid'where id='c1000000-0000-0000-0000-000000000013';
select ok(api.worker_portal_certificate_mail((select id from app_private.email_outbox where recipient_email='cert-13@example.invalid'and message_type='portal_certificate_ready'))is null,'email change never grants an old address a campaign copy');
update auth.users set email='cert-13@example.invalid'where id='c1000000-0000-0000-0000-000000000013';
update app_private.portal_owners set role='viewer'where user_id='c1000000-0000-0000-0000-000000000016';
select ok(api.worker_portal_certificate_mail((select id from app_private.email_outbox where recipient_email='cert-16@example.invalid'and message_type='portal_certificate_ready'))is null,'downgrading tech to viewer is rechecked at dispatch');
update app_private.portal_owners set role='tech'where user_id='c1000000-0000-0000-0000-000000000016';

-- Unknown provider outcomes and accepted messages cannot become a new send.
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)
values('cc000000-0000-0000-0000-000000000001','test',9101,'resend','synthetic@example.invalid','Synthetic','synthetic@example.invalid','synthetic-certificate');
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status)
select 'test','certificate-shared-unknown','cc000000-0000-0000-0000-000000000001','resend',id,'transactional','portal_certificate_ready',extensions.digest(recipient_email,'sha256'),'fixed-payload','fixed-credential','unknown'
from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid';
select api.worker_update_outbox_v2((select id from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid'),'suppressed',null,'RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid'),'unknown','suppression keeps the uncertain provider outcome unknown');
select is(api.worker_mail_prepare('test','certificate-shared-unknown','cc000000-0000-0000-0000-000000000001',(select id from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid'),'transactional','portal_certificate_ready','cert-shared@example.invalid','{}','fixed-payload','fixed-credential')->>'dispatch','false','signed gateway also refuses a now-unavailable unknown recipient');
select is(api.worker_mail_prepare('test','certificate-shared-unknown','cc000000-0000-0000-0000-000000000001',(select id from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid'),'transactional','portal_certificate_ready','cert-shared@example.invalid','{}','fixed-payload','fixed-credential')->>'status','reconcile','unknown non-dispatch retains the manual reconciliation boundary');
update app_private.email_outbox set status='accepted',accepted_at=now(),provider_id='synthetic-cert-accepted'where message_type='portal_certificate_ready'and recipient_email='cert-owner@example.invalid';
select api.worker_update_outbox_v2((select id from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-owner@example.invalid'),'suppressed',null,'RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-owner@example.invalid'),'accepted','accepted provider outcome is never suppressed or resent');

-- Reuse original jobs and provider identities only for conclusive failures.
update app_private.email_outbox set status='failed',attempts=1 where message_type='portal_certificate_ready'and recipient_email in('cert-13@example.invalid','cert-14@example.invalid','cert-15@example.invalid');
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status,first_attempt_at)
select 'test','certificate-retry-'||recipient_email,'cc000000-0000-0000-0000-000000000001','resend',id,'transactional','portal_certificate_ready',extensions.digest(recipient_email,'sha256'),'fixed-retry-payload','fixed-retry-credential','failed',
case when recipient_email='cert-15@example.invalid'then clock_timestamp()-interval '24 hours'else clock_timestamp()end
from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email in('cert-14@example.invalid','cert-15@example.invalid');
create temp table certificate_before_retry as select o.id,o.dedupe_key,o.recipient_email,o.payload,e.logical_key,e.payload_hash,e.credential_hash
from app_private.email_outbox o left join app_private.mail_envelopes e on e.outbox_id=o.id where o.message_type='portal_certificate_ready';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_certificate_admin_snapshot('duindorp-halloween-2026')#>>'{mail,retryableFailed}','2','admin preview distinguishes safe failed jobs from expired provider identities');
select is(api.portal_certificate_retry_failed('duindorp-halloween-2026')->>'requeued','2','authorized retry recovers only no-envelope and recent conclusive failed jobs');
select is((select status::text from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-15@example.invalid'),'failed','old failed provider identity requires manual reconciliation');
select is((select status::text from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-shared@example.invalid'),'unknown','admin retry never queues an unknown message');
select is((select status::text from app_private.email_outbox where message_type='portal_certificate_ready'and recipient_email='cert-owner@example.invalid'),'accepted','admin retry never queues an accepted message');
select is((select count(*)from certificate_before_retry b join app_private.email_outbox o on o.id=b.id left join app_private.mail_envelopes e on e.outbox_id=o.id
where(b.dedupe_key,b.recipient_email,b.payload,b.logical_key,b.payload_hash,b.credential_hash)is not distinct from(o.dedupe_key,o.recipient_email,o.payload,e.logical_key,e.payload_hash,e.credential_hash)),6::bigint,'recovery preserves every recipient, payload, outbox key and provider logical identity');
select is(api.portal_certificate_retry_failed('duindorp-halloween-2026')->>'requeued','0','repeating retry adds no duplicate command');
select is(api.portal_certificate_confirm('duindorp-halloween-2026','Again','Again',gen_random_uuid())->>'existing','true','unknown client outcome is resolved by the same event confirmation');
select is((select count(*)from app_private.email_outbox where message_type='portal_certificate_ready'),6::bigint,'reconfirming after mail processing never creates another recipient set');
select is((select count(*)from app_private.run_stop_arrivals),0::bigint,'campaign never manufactures child arrivals');
select is((select count(*)from app_private.duinpad_show_attempts),0::bigint,'campaign never operates a physical show');
select *from finish();
rollback;
