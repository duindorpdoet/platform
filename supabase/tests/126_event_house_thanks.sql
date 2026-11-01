begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
-- All accounts/recipients here are synthetic; this transaction never sends mail.
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
-- Exercise normal operational gates, retaining one explicitly marked test gate.
update app_private.portal_flags set value=false where flag_key='fixture';
update app_private.portal_flags set value=true where flag_key='fixture'and portal_id='12000000-0000-0000-0000-000000000025';
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values
 ('e1000000-0000-0000-0000-000000000001','Resident@Example.invalid',now(),'{}','{}'),
 ('e1000000-0000-0000-0000-000000000002','resident@example.invalid',now(),'{}','{}'),
 ('e1000000-0000-0000-0000-000000000003',null,null,'{}','{}'),
 ('e1000000-0000-0000-0000-000000000004','revoked-resident@example.invalid',now(),'{}','{}'),
 ('e1000000-0000-0000-0000-000000000005','suspended-resident@example.invalid',now(),'{}','{}');
insert into app_private.portal_owners(portal_id,user_id,role)select '12000000-0000-0000-0000-000000000001',id,'crew'from auth.users where id::text like'e1000000-%';
update app_private.portal_owners set revoked_at=now()where user_id='e1000000-0000-0000-0000-000000000004';
update app_private.portal_owners set suspended_at=now()where user_id='e1000000-0000-0000-0000-000000000005';
insert into app_private.portal_team_invites(portal_id,email,first_name,last_name,role,token_hash,invited_by)values('12000000-0000-0000-0000-000000000001','pending-resident@example.invalid','Pending','Synthetic','viewer',extensions.digest('not-a-real-invitation','sha256'),'f0000000-0000-0000-0000-000000000001');
insert into app_private.household_members(household_id,user_id,relation_role)values('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000004','adult');
insert into app_private.portal_thanks(event_id,household_id,portal_id,choice)select id,'d2000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','beautiful'from app_private.events where slug='duindorp-halloween-2026';
-- The closure cohort excludes draft/cancelled registrations and nonparticipants.
insert into app_private.households(id,label,primary_contact_user_id)values('e6000000-0000-0000-0000-000000000001','Draft synthetic','d1000000-0000-0000-0000-000000000002'),('e6000000-0000-0000-0000-000000000002','Cancelled synthetic','d1000000-0000-0000-0000-000000000002');
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'e7000000-0000-0000-0000-000000000001',id,'e6000000-0000-0000-0000-000000000001','draft','THANKS-DRAFT'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'e7000000-0000-0000-0000-000000000002',id,'e6000000-0000-0000-0000-000000000002','cancelled','THANKS-CANCELLED'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)values('e8000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-000000000001','Draft child',8),('e8000000-0000-0000-0000-000000000002','e6000000-0000-0000-0000-000000000002','Cancelled child',8);
insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)select id,'e7000000-0000-0000-0000-000000000001','e8000000-0000-0000-0000-000000000001',0 from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)select id,'e7000000-0000-0000-0000-000000000002','e8000000-0000-0000-0000-000000000002',0 from app_private.events where slug='duindorp-halloween-2026';
update app_private.portals set approval_status='draft',lifecycle_status='archived'where id='12000000-0000-0000-0000-000000000029';
update app_private.portals set approval_status='withdrawn',lifecycle_status='archived'where id in('12000000-0000-0000-0000-000000000026','12000000-0000-0000-0000-000000000027');
insert into app_private.portal_status_history(portal_id,actor_id,state,reason)values('12000000-0000-0000-0000-000000000027','f0000000-0000-0000-0000-000000000001','open','Synthetic actual participation evidence');
update app_private.portals set operation_status='closed'where id='12000000-0000-0000-0000-000000000028';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic thanks','A fixed test message','e2000000-0000-0000-0000-000000000001');
select is((select count(*)from app_private.event_house_thanks),0::bigint,'closing writes no thanks on behalf of families');
select is((select count(*)from app_private.event_closure_registrations where registration_id::text like'e7000000-%'),0::bigint,'draft and cancelled registrations are not frozen participants');
select is((select count(*)from app_private.event_closure_children where child_id::text like'e8000000-%'),0::bigint,'children of draft and cancelled registrations receive no administrative participation');
select ok(not exists(select 1 from app_private.event_closure_portals where portal_id in('12000000-0000-0000-0000-000000000025','12000000-0000-0000-0000-000000000026','12000000-0000-0000-0000-000000000029')),'explicit test gates and nonparticipating draft or withdrawn houses are excluded');
select is((select count(*)from app_private.event_closure_portals where portal_id in('12000000-0000-0000-0000-000000000027','12000000-0000-0000-0000-000000000028')),2::bigint,'closed or archived houses that did participate remain eligible');

select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_thanks_closed_snapshot('duindorp-halloween-2026')->>'closed','true','a family without its own finale receives the closed-event thanks rights');
select is(jsonb_array_length(api.portal_thanks_closed_snapshot('duindorp-halloween-2026')->'portals')::bigint,(select count(*)from app_private.event_closure_portals),'all immutable participating houses are available');
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Een algemene dank!','e3000000-0000-0000-0000-000000000001')$$,'one confirmation durably stores the general thanks');
select is((select count(*)from app_private.event_house_thanks_targets),(select count(*)from app_private.event_closure_portals),'the frozen whole-event target set is atomically durable');
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Een algemene dank!','e3000000-0000-0000-0000-000000000001')$$,'a timeout retry returns the existing submission');
select throws_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Changed body','e3000000-0000-0000-0000-000000000001')$$,'23514','IDEMPOTENCY_CONFLICT','one request key cannot silently change its message');
select is((select count(*)from app_private.event_house_thanks),1::bigint,'retries create one general submission');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Other adult cannot replace it','e3000000-0000-0000-0000-000000000008')$$,'a second adult shares the household submission boundary');
select is((select message from app_private.event_house_thanks where kind='all'),'Een algemene dank!','a concurrent-style second confirmation never overwrites the accepted message');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','Dank voor de aandacht!','e3000000-0000-0000-0000-000000000002')$$,'a personal extra remains possible after the general and historical thanks');
select is((select count(*)from app_private.portal_thanks),1::bigint,'the historical during-evening reaction remains untouched');
select is((select count(*)from app_private.event_house_thanks),2::bigint,'general and personal thanks have independent uniqueness');
select throws_ok($$update app_private.event_closure_portals set portal_name='Changed after close'$$,'23514','EVENT_CLOSURE_IMMUTABLE','the shared targetset cannot drift after closure');
select throws_ok($$select api.portal_thanks_save('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001','welcome')$$,'23514','CLOSED_THANKS_REQUIRED','old cached clients must use the conscious new submission flow');
select throws_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','personal',gen_random_uuid(),'welcome','','e3000000-0000-0000-0000-000000000003')$$,'42501','NOT_AUTHORIZED','a foreign or made-up house is rejected');
select throws_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,repeat('x',501),'e3000000-0000-0000-0000-000000000004')$$,'22023','INVALID_INPUT','the server enforces the text limit');
savepoint simulated_worker_crash;
select api.worker_house_thanks_fanout(1);
rollback to simulated_worker_crash;
select is((select count(*)from app_private.event_house_thanks_receipts),0::bigint,'a worker crash rolls receipt creation back atomically');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),0::bigint,'a rolled-back worker batch leaves no partial mail jobs');
select api.worker_house_thanks_fanout(1);
select is((select count(*)from app_private.event_house_thanks_receipts),1::bigint,'a worker tick respects a one-house batch');
do $$declare n integer;begin for n in 1..20 loop perform api.worker_house_thanks_fanout(25);exit when not exists(select 1 from app_private.event_house_thanks_targets where processed_at is null);end loop;end $$;
select is((select count(*)from app_private.event_house_thanks_receipts),(select count(*)from app_private.event_house_thanks_targets),'resuming fan-out forgets no target');
create temp table thanks_counts as select count(*)n from app_private.email_outbox where message_type='house_thanks_received';
select api.worker_house_thanks_fanout(25);
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),(select n from thanks_counts),'reprocessing creates no duplicate mail jobs');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email in('revoked-resident@example.invalid','suspended-resident@example.invalid','pending-resident@example.invalid')),0::bigint,'revoked, suspended and unaccepted invite recipients receive no mail jobs');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','organization capability alone creates no resident inbox access');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select count(*)from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id where r.portal_id='12000000-0000-0000-0000-000000000001'and m.recipient_email='resident@example.invalid'),2::bigint,'each general/personal receipt mails a normalized shared address once');
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','treats','Aangepast <script>als tekst</script>','e3000000-0000-0000-0000-000000000005',(select id from app_private.event_house_thanks where kind='personal'and household_id='d2000000-0000-0000-0000-000000000001'))$$,'an explicit edit keeps message text editable');
select api.worker_house_thanks_fanout(25);
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),(select n from thanks_counts),'editing sends no new mail');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000002','beautiful','','e3000000-0000-0000-0000-000000000009')$$,'an extra personal thanks can also come before the general submission');
select lives_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Ander gezin, zelfde samenloop','e3000000-0000-0000-0000-000000000006')$$,'another household in the same together party keeps its own general thanks');
select throws_ok($$select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','forbidden edit','e3000000-0000-0000-0000-000000000007',(select id from app_private.event_house_thanks where kind='personal'and household_id='d2000000-0000-0000-0000-000000000001'))$$,'42501','NOT_AUTHORIZED','one household cannot edit another submission');
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','a family cannot inspect a resident inbox');
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',null,1)->>'total','2','a resident sees both new types for their own house');
select is(jsonb_array_length(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',null,1)->'messages'),1,'the resident inbox is bounded and paginated');
select ok(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',null,1)->>'nextCursor'is not null,'a second page is available');
select ok(not(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')::text~'d1000000|householdId|resident@example|Oefenkind'),'inbox exposes no household identifiers, child names or email addresses');
select lives_ok($$select api.portal_thanks_read('duindorp-halloween-2026',(select id from app_private.event_house_thanks_receipts where portal_id='12000000-0000-0000-0000-000000000001'limit 1))$$,'a resident can store their own read status');
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'unread','1','read status is durable per resident account');
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000002')$$,'42501','NOT_AUTHORIZED','a resident cannot read another house');
select ok(exists(select 1 from app_private.event_house_thanks_receipts where portal_id='12000000-0000-0000-0000-000000000001'and missing_contacts=1),'missing contact is recorded without hiding the received thanks');
update auth.users set email='repaired@example.invalid',email_confirmed_at=now()where id='e1000000-0000-0000-0000-000000000003';
update app_private.event_house_thanks_receipts set contacts_checked_at=now()-interval'6 minutes'where portal_id='12000000-0000-0000-0000-000000000001';
-- Drain the second household's queue before bounded contact repair.
do $$declare n integer;begin for n in 1..20 loop perform api.worker_house_thanks_fanout(25);end loop;end $$;
select is((select count(*)from app_private.event_house_thanks_mail_recipients where recipient_email='repaired@example.invalid'),3::bigint,'repair adds only the missing first mail per receipt');
select is((select count(*)from app_private.event_house_thanks_receipts where portal_id='12000000-0000-0000-0000-000000000001'and missing_contacts>0),0::bigint,'repaired contact state becomes explainable as complete');
create temp table repaired_counts as select count(*)n from app_private.email_outbox where message_type='house_thanks_received';
update app_private.email_outbox set status='suppressed',last_error_code='RECIPIENT_SUPPRESSED'where id=(select outbox_id from app_private.event_house_thanks_mail_recipients where recipient_email='repaired@example.invalid'limit 1);
select api.worker_house_thanks_fanout(25);
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),(select n from repaired_counts),'suppression is not bypassed or remail-retried by contact repair');
select ok(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')::text like'%suppressed%','resident inbox preserves explanatory blocked-mail state');
update app_private.portal_owners set suspended_at=now()where user_id='e1000000-0000-0000-0000-000000000003';
select ok(api.worker_house_thanks_mail((select outbox_id from app_private.event_house_thanks_mail_recipients where recipient_email='repaired@example.invalid'limit 1))is null,'dispatch revalidates suspended recipient access');
-- A provider-unknown receipt remains unknown when contact access disappears.
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)
 values('e4000000-0000-0000-0000-000000000001','test',9001,'resend','test@example.invalid','Synthetic test','test@example.invalid','synthetic-config');
create temp table unknown_house_mail as select o.id,o.recipient_email from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id where m.recipient_email='repaired@example.invalid'and o.status='pending'limit 1;
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status)
 select 'test','synthetic-unknown-house','e4000000-0000-0000-0000-000000000001','resend',id,'transactional','house_thanks_received',extensions.digest(recipient_email,'sha256'),'fixed-payload','fixed-credential','unknown'from unknown_house_mail;
select api.worker_update_outbox_v2((select id from unknown_house_mail),'suppressed',null,'EVENING_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from unknown_house_mail)),'unknown','a revoked recipient never turns an unknown provider outcome into suppressed or retryable');
select is((select status from app_private.mail_envelopes where logical_key='synthetic-unknown-house'),'unknown','access change never rewrites the provider envelope');
select is(api.worker_mail_prepare('test','synthetic-unknown-house','e4000000-0000-0000-0000-000000000001',(select id from unknown_house_mail),'transactional','house_thanks_received','repaired@example.invalid','{}','fixed-payload','fixed-credential')->>'dispatch','false','unknown outcome and revoked access cannot dispatch a provider retry');
select is(api.worker_mail_prepare('test','synthetic-unknown-house','e4000000-0000-0000-0000-000000000001',(select id from unknown_house_mail),'transactional','house_thanks_received','repaired@example.invalid','{}','fixed-payload','fixed-credential')->>'status','reconcile','uncertain non-dispatch remains explicitly reconcilable');
update app_private.email_outbox set status='accepted',accepted_at=now(),provider_id='synthetic-provider-id'where id=(select id from unknown_house_mail);
select api.worker_update_outbox_v2((select id from unknown_house_mail),'suppressed',null,'EVENING_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from unknown_house_mail)),'accepted','recipient changes preserve historical provider acceptance');
update app_private.email_outbox set status='delivered'where id=(select id from unknown_house_mail);
select api.worker_update_outbox_v2((select id from unknown_house_mail),'suppressed',null,'EVENING_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from unknown_house_mail)),'delivered','recipient changes preserve actual delivery history');
insert into app_private.email_outbox(id,dedupe_key,message_type,recipient_ref,recipient_email,payload,status)
 select 'e5000000-0000-0000-0000-000000000001','synthetic-old-generic','duinpad_evening_thanks','synthetic','synthetic@example.invalid',jsonb_build_object('eventId',id),'unknown'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status)
 values('test','synthetic-old-generic','e4000000-0000-0000-0000-000000000001','resend','e5000000-0000-0000-0000-000000000001','transactional','duinpad_evening_thanks',extensions.digest('synthetic@example.invalid','sha256'),'fixed-payload','fixed-credential','unknown');
select is(api.worker_mail_prepare('test','synthetic-old-generic','e4000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000001','transactional','duinpad_evening_thanks','synthetic@example.invalid','{}','fixed-payload','fixed-credential')->>'dispatch','false','central closure blocks even an uncertain old generic mail retry');
select is((select status from app_private.mail_envelopes where logical_key='synthetic-old-generic'),'unknown','blocking a stale generic retry preserves its unknown envelope history');
-- The same organizer recovery action also covers conclusive house-mail failures.
create temp table house_retry_candidates as select id,row_number()over(order by created_at,id)n from(select id,created_at from app_private.email_outbox where message_type='house_thanks_received'and status='pending'order by created_at,id limit 4)selected;
update app_private.email_outbox set status=case when n=4 then 'unknown'::app_private.outbox_status else 'failed'::app_private.outbox_status end,attempts=1 from house_retry_candidates t where email_outbox.id=t.id;
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status,first_attempt_at)
 select 'test','synthetic-house-retry-'||t.n,'e4000000-0000-0000-0000-000000000001','resend',o.id,'transactional','house_thanks_received',extensions.digest(o.recipient_email,'sha256'),'fixed-house-payload','fixed-house-credential',case when t.n=4 then 'unknown'else 'failed'end,case when t.n=3 then clock_timestamp()-interval '24 hours'else clock_timestamp()end from house_retry_candidates t join app_private.email_outbox o on o.id=t.id where t.n>1;
create temp table house_retry_identity as select o.id,o.dedupe_key,o.recipient_email,o.payload,e.logical_key,e.payload_hash,e.credential_hash from house_retry_candidates t join app_private.email_outbox o on o.id=t.id left join app_private.mail_envelopes e on e.outbox_id=o.id;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.event_closure_admin_snapshot('duindorp-halloween-2026')#>>'{mail,houseFailed}','3','organizer sees house-mail failures even when no campaign mail failed');
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'houseRequeued','2','one authorized action recovers only conclusive no-envelope/recent-Resend house failures');
select is((select count(*)from house_retry_candidates t join app_private.email_outbox o on o.id=t.id where t.n in(1,2)and o.status='pending'),2::bigint,'safe failed house jobs return to the same durable outbox queue');
select is((select status from app_private.mail_envelopes where logical_key='synthetic-house-retry-2'),'deferred','recent failed envelope reuses its existing logical provider identity');
select is((select status::text from app_private.email_outbox where id=(select id from house_retry_candidates where n=3)),'failed','expired failed provider identity requires manual reconciliation');
select is((select status::text from app_private.email_outbox where id=(select id from house_retry_candidates where n=4)),'unknown','operator recovery never requeues an uncertain delivery');
select is((select status::text from app_private.email_outbox where id=(select id from unknown_house_mail)),'delivered','recovery preserves an already delivered house message');
select is((select count(*)from house_retry_identity before join app_private.email_outbox o on o.id=before.id left join app_private.mail_envelopes e on e.outbox_id=o.id where (before.dedupe_key,before.recipient_email,before.payload,before.logical_key,before.payload_hash,before.credential_hash)is not distinct from(o.dedupe_key,o.recipient_email,o.payload,e.logical_key,e.payload_hash,e.credential_hash)),4::bigint,'recovery never changes recipient, payload, outbox key or provider logical identity');
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'houseRequeued','0','repeating recovery does not duplicate already requeued house jobs');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.event_closure_retry_failed('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','participants cannot recover privileged resident mail jobs');
select ok(not has_function_privilege('authenticated','app_private.event_evening_retry_outbox(uuid)','execute'),'shared retry helper remains privileged and private');
select ok(not has_function_privilege('authenticated','api.worker_house_thanks_fanout(integer)','execute'),'clients cannot run privileged mail fanout');
select ok(not has_table_privilege('authenticated','app_private.event_house_thanks','select'),'operational submission tables stay private');
select *from finish();
rollback;
