begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
-- Everything is synthetic and rolled back; no provider is contacted.
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
update app_private.portal_flags set value=false where flag_key='fixture';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic custom-only mail','Local fixture','e8100000-0000-0000-0000-000000000001');
create temp table defaults as select 'Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃'::text message;
select ok(not app_private.event_house_thanks_custom('all',(select message from defaults)),'the fixed nonempty general text is not a custom message');
select ok(not app_private.event_house_thanks_custom('all',U&'\FEFF\00A0'||replace((select message from defaults),' ',U&'\2002\000A')||U&'\202F\3000'),'Unicode whitespace around or inside the fixed text does not trigger mail');
select ok(not app_private.event_house_thanks_custom('personal',U&'\0009\000A\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF'),'every supported whitespace-only personal message is aggregate only');
select ok(app_private.event_house_thanks_custom('all',(select message||' Dank voor de rookvrije route!'from defaults)),'an actual extra sentence is custom');
select ok(app_private.event_house_thanks_custom('all','Onze kinderen vonden jullie decor prachtig.'),'an authored replacement is custom');
select ok(app_private.event_house_thanks_custom('personal','🎃'),'an authored short personal message is custom');

-- Mail entitlement is narrower than existing Poortkamer read access.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
select ('e8200000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n=11 then 'Owner11@Example.invalid'else 'owner'||n||'@example.invalid'end,now(),'{}','{}'from generate_series(2,13)n;
update app_private.portal_owners set revoked_at=now()where portal_id in(select ('12000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid from generate_series(2,13)n)and role='owner';
insert into app_private.portal_owners(portal_id,user_id,role)
select ('12000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('e8200000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n=7 then 'coadmin'else 'owner'end from generate_series(2,13)n;
update app_private.portal_owners set revoked_at=now()where user_id='e8200000-0000-0000-0000-000000000002';
update app_private.portal_owners set suspended_at=now()where user_id='e8200000-0000-0000-0000-000000000003';
update auth.users set email_confirmed_at=null where id='e8200000-0000-0000-0000-000000000004';
update auth.users set deleted_at=now()where id='e8200000-0000-0000-0000-000000000005';
update auth.users set banned_until=now()+interval'1 day'where id='e8200000-0000-0000-0000-000000000006';
update auth.users set email=null,email_confirmed_at=null where id='e8200000-0000-0000-0000-000000000012';
update app_private.portals set lifecycle_status='archived'where id='12000000-0000-0000-0000-000000000008';
update app_private.portals set approval_status='withdrawn'where id='12000000-0000-0000-0000-000000000009';
update app_private.portal_flags set value=true where portal_id='12000000-0000-0000-0000-000000000010'and flag_key='fixture';
update app_private.portals set operation_status='closed'where id in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000013');
insert into app_private.portal_owners(portal_id,user_id,role)values
 ('12000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000004','viewer'),
 ('12000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000004','crew'),
 ('12000000-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000004','actor'),
 ('12000000-0000-0000-0000-000000000014','d1000000-0000-0000-0000-000000000004','portal_manager'),
 ('12000000-0000-0000-0000-000000000015','d1000000-0000-0000-0000-000000000004','reception'),
 ('12000000-0000-0000-0000-000000000016','d1000000-0000-0000-0000-000000000004','tech');
-- The legacy initial-owner trigger promotes the first insert when none exists.
-- Explicitly set the role after insertion to exercise the intended negatives.
update app_private.portal_owners set role='coadmin'where user_id='e8200000-0000-0000-0000-000000000007';
update app_private.portal_owners set role='crew'where portal_id='12000000-0000-0000-0000-000000000002'and user_id='d1000000-0000-0000-0000-000000000004';
insert into app_private.portal_team_invites(portal_id,email,first_name,last_name,role,token_hash,invited_by)values('12000000-0000-0000-0000-000000000001','pending-owner@example.invalid','Pending','Synthetic','coadmin',extensions.digest('synthetic-unused-owner-invite','sha256'),'f0000000-0000-0000-0000-000000000001');

select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,(select message from defaults),'e8300000-0000-0000-0000-000000000001');
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','beautiful','','e8300000-0000-0000-0000-000000000002');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Dank voor jullie zelfgebouwde draak!','e8300000-0000-0000-0000-000000000003');
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','Dank voor de rustige ontvangst!','e8300000-0000-0000-0000-000000000004');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,U&'\00A0\FEFF','e8300000-0000-0000-0000-000000000005');
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','treats',U&'\2003\000A','e8300000-0000-0000-0000-000000000006');
do $$declare n integer;begin for n in 1..10 loop perform api.worker_house_thanks_fanout(25);exit when not exists(select 1 from app_private.event_house_thanks_targets where processed_at is null);end loop;end $$;
select is((select count(*)from app_private.event_house_thanks_receipts),(select count(*)from app_private.event_house_thanks_targets),'every reaction still creates its durable per-house receipt');
select is((select count(*)from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.event_house_thanks s on s.id=r.submission_id where not app_private.event_house_thanks_custom(s.kind,s.message)),0::bigint,'standard and empty personal reactions create no mail jobs');
select is((select count(*)from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id where not app_private.event_house_thanks_custom(s.kind,s.message)and r.missing_contacts<>0),0::bigint,'aggregate reactions create no misleading missing-contact repair work');
select is((select count(*)from app_private.event_house_thanks_mail_recipients m join app_private.event_house_thanks_receipts r on r.id=m.receipt_id where r.portal_id='12000000-0000-0000-0000-000000000001'),2::bigint,'a physically closed active house receives exactly its two custom messages');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email in('owner2@example.invalid','owner3@example.invalid','owner4@example.invalid','owner5@example.invalid','owner6@example.invalid','owner8@example.invalid','owner9@example.invalid','owner10@example.invalid','pending-owner@example.invalid')),0::bigint,'revoked/suspended/unverified/deleted/banned accounts, inactive and test houses and pending invite addresses receive no mail');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='owner7@example.invalid'),1::bigint,'an active coadmin receives the custom message');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='duinpad-4@example.invalid'),5::bigint,'crew, actor, portal_manager, reception and tech each receive the custom message for their own house');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='duinpad-4@example.invalid'and payload->>'portalId'='12000000-0000-0000-0000-000000000001'),0::bigint,'viewer retains room access without receiving mail');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='owner11@example.invalid'),1::bigint,'the verified primary owner address is normalized');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='owner13@example.invalid'),1::bigint,'operation_status closed does not exclude an active primary owner');
select is((select count(*)from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id where r.portal_id='12000000-0000-0000-0000-000000000012'and app_private.event_house_thanks_custom(s.kind,s.message)and r.missing_contacts=1),1::bigint,'an actual custom message records a missing primary-owner contact');
update auth.users set email='repaired-primary@example.invalid',email_confirmed_at=now()where id='e8200000-0000-0000-0000-000000000012';
update app_private.event_house_thanks_receipts set contacts_checked_at=now()-interval'6 minutes'where portal_id='12000000-0000-0000-0000-000000000012'and missing_contacts>0;
select api.worker_house_thanks_fanout(25);
select api.worker_house_thanks_fanout(25);
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='repaired-primary@example.invalid'),1::bigint,'restoring an eligible primary contact queues its missing custom message once');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
create temp table inbox as select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',null,1)body;
select is((select body->>'total'from inbox),'6','the existing viewer still sees all six reactions as counts');
select is((select body->>'aggregateOnlyCount'from inbox),'4','standard and blank messages are represented only by aggregate counts');
select is((select body->>'customMessageCount'from inbox),'2','custom count represents receipts, not households');
select is((select body->'counters'from inbox),'{"general":3,"personal":3,"beautiful":1,"welcome":1,"treats":1}'::jsonb,'general/personal and three reaction counters retain every reaction');
select is((select body->>'unread'from inbox),'2','only custom messages enter the unread count');
select is((select jsonb_array_length(body->'messages')from inbox),1,'custom inbox pagination is bounded');
select ok((select body->>'nextCursor'from inbox)is not null,'another custom message provides a next cursor');
select is(jsonb_array_length(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',(select(body->>'nextCursor')::uuid from inbox),1)->'messages'),1,'the next page contains only the remaining custom message');
select lives_ok($$select api.portal_thanks_read('duindorp-halloween-2026',(select(body->'messages'->0->>'id')::uuid from inbox))$$,'read status is still saved for the authorized viewer');
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'unread','1','marking one custom message read reduces only relevant unread');
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000004')$$,'42501','NOT_AUTHORIZED','unchanged read authorization rejects a foreign house');
select ok(not(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')::text~'householdId|owner@example|Oefenkind|d1000000'),'no private sender identifiers or addresses appear in counters or messages');

-- No edit can create a new notification or alter its frozen first payload.
create temp table counts_before as select count(*)n from app_private.email_outbox where message_type='house_thanks_received';
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Later alsnog eigen tekst','e8300000-0000-0000-0000-000000000007',(select id from app_private.event_house_thanks where household_id='d2000000-0000-0000-0000-000000000001'and kind='all'));
do $$declare rid uuid;begin for rid in select r.id from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id where s.household_id='d2000000-0000-0000-0000-000000000001'and s.kind='all'loop perform app_private.event_house_thanks_queue_mail(rid);end loop;end $$;
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),(select n from counts_before),'default -> custom edit creates no retrospective mail even when repair is explicitly invoked');
select is((select initial_message from app_private.event_house_thanks where household_id='d2000000-0000-0000-0000-000000000001'and kind='all'),(select message from defaults),'the original default remains frozen');
create temp table pending_personal as select o.id,o.payload from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.event_house_thanks s on s.id=r.submission_id where s.kind='personal'and s.household_id='d2000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','','e8300000-0000-0000-0000-000000000008',(select id from app_private.event_house_thanks where household_id='d2000000-0000-0000-0000-000000000002'and kind='personal'));
select ok(api.worker_house_thanks_mail((select id from pending_personal))is null,'removing written text blocks an already queued message before dispatch');
select is((select o.payload from app_private.email_outbox o join pending_personal p on p.id=o.id),(select payload from pending_personal),'removing text never rewrites a durable provider payload');
select is((select count(*)from app_private.email_outbox where message_type='house_thanks_received'),(select n from counts_before),'editing creates no extra jobs');
-- Simulate pre-release standard and viewer jobs: material check must block both.
create temp table stale_jobs as select o.id,row_number()over(order by o.created_at,o.id)n from app_private.email_outbox o where o.message_type='house_thanks_received'and api.worker_house_thanks_mail(o.id)is not null and o.payload->>'portalId'in('12000000-0000-0000-0000-000000000017','12000000-0000-0000-0000-000000000018','12000000-0000-0000-0000-000000000019')limit 3;
update app_private.email_outbox set payload=jsonb_set(payload,'{message}',to_jsonb((select message from defaults)))where id=(select id from stale_jobs where n=1);
select ok(api.worker_house_thanks_mail((select id from stale_jobs where n=1))is null,'a pre-release queued default payload cannot be dispatched even if current text is custom');
create temp table owner_change as select o.id,r.portal_id from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id where o.id=(select id from stale_jobs where n=2);
update app_private.portal_owners set role='viewer'where portal_id=(select portal_id from owner_change)and role in('owner','portal_manager','coadmin','crew','actor','reception','tech')and revoked_at is null;
select ok(api.worker_house_thanks_mail((select id from owner_change))is null,'a working team becoming viewers is rechecked before rendering or gateway dispatch');
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)values('e8400000-0000-0000-0000-000000000001','test',9002,'resend','test@example.invalid','Synthetic','test@example.invalid','synthetic-custom-config');
select is(api.worker_mail_prepare('test','synthetic-filtered-default','e8400000-0000-0000-0000-000000000001',(select id from stale_jobs where n=1),'transactional','house_thanks_received','owner@example.invalid','{}','hash','credential')->>'dispatch','false','the durable gateway independently rejects a queued standard payload');
update app_private.email_outbox set status='failed'where id in(select id from stale_jobs where n in(1,2));
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.event_closure_admin_snapshot('duindorp-halloween-2026')#>>'{mail,houseFailed}','0','ineligible failures are not offered as recoverable house mail');
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'houseRequeued','0','operator recovery never requeues a standard or viewer job');
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status)
select 'test','synthetic-filtered-unknown','e8400000-0000-0000-0000-000000000001','resend',id,'transactional','house_thanks_received',extensions.digest('owner@example.invalid','sha256'),'frozen-hash','frozen-credential','unknown'from pending_personal;
select api.worker_update_outbox_v2((select id from pending_personal),'suppressed',null,'HOUSE_THANKS_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from pending_personal)),'unknown','custom eligibility removal preserves an uncertain outbox outcome');
select is((select status from app_private.mail_envelopes where logical_key='synthetic-filtered-unknown'),'unknown','uncertain envelope remains unchanged');
select is(api.worker_mail_prepare('test','synthetic-filtered-unknown','e8400000-0000-0000-0000-000000000001',(select id from pending_personal),'transactional','house_thanks_received','owner@example.invalid','{}','frozen-hash','frozen-credential')->>'status','reconcile','unknown ineligible mail is reconciled without a provider replay');
update app_private.email_outbox set status='accepted',accepted_at=now(),provider_id='synthetic-existing-provider'where id=(select id from pending_personal);
select api.worker_update_outbox_v2((select id from pending_personal),'suppressed',null,'HOUSE_THANKS_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from pending_personal)),'accepted','existing accepted history is preserved');
update app_private.email_outbox set status='delivered'where id=(select id from pending_personal);
select api.worker_update_outbox_v2((select id from pending_personal),'suppressed',null,'HOUSE_THANKS_RECIPIENT_UNAVAILABLE',null);
select is((select status::text from app_private.email_outbox where id=(select id from pending_personal)),'delivered','existing delivered history is preserved');
-- Historical rows have no initial_message. Simulate that exact stored shape,
-- without any migration backfill, then use the normal authorized editing RPC.
alter table app_private.event_house_thanks disable trigger event_house_thanks_preserve_initial;
insert into app_private.event_house_thanks(id,event_id,household_id,kind,portal_id,choice,message,created_by)
select ('e8500000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,id,'d2000000-0000-0000-0000-000000000003','personal',('12000000-0000-0000-0000-'||lpad(case when n=1 then '11'else '13'end,12,'0'))::uuid,'welcome',case when n=1 then ''else 'De oorspronkelijke eigen tekst'end,'d1000000-0000-0000-0000-000000000003'from app_private.events,generate_series(1,2)n where slug='duindorp-halloween-2026';
alter table app_private.event_house_thanks enable trigger event_house_thanks_preserve_initial;
insert into app_private.event_house_thanks_receipts(submission_id,event_id,portal_id)select id,event_id,portal_id from app_private.event_house_thanks where id::text like'e8500000-%';
select is((select count(*)from app_private.event_house_thanks where id::text like'e8500000-%'and initial_message is null),2::bigint,'historical initial text stays nullable until an actual text edit');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000011','welcome','Nu pas eigen tekst','e8300000-0000-0000-0000-000000000009','e8500000-0000-0000-0000-000000000001');
select is((select initial_message from app_private.event_house_thanks where id='e8500000-0000-0000-0000-000000000001'),'','first real historical edit preserves the prior empty text');
select is(app_private.event_house_thanks_queue_mail((select id from app_private.event_house_thanks_receipts where submission_id='e8500000-0000-0000-0000-000000000001')),0,'a historically empty reaction cannot gain retrospective mail by editing');
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000013','treats','De oorspronkelijke eigen tekst','e8300000-0000-0000-0000-000000000010','e8500000-0000-0000-0000-000000000002');
select ok((select initial_message is null from app_private.event_house_thanks where id='e8500000-0000-0000-0000-000000000002'),'a choice-only historical edit performs no unnecessary text backfill');
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000013','treats','Een latere eigen tekst','e8300000-0000-0000-0000-000000000011','e8500000-0000-0000-0000-000000000002');
select is(app_private.event_house_thanks_queue_mail((select id from app_private.event_house_thanks_receipts where submission_id='e8500000-0000-0000-0000-000000000002')),1,'a historical custom message still gets its one eligible missing mail');
select is((select o.payload->>'message'from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id where r.submission_id='e8500000-0000-0000-0000-000000000002'),'De oorspronkelijke eigen tekst','a delayed first dispatch keeps the original authored text after an edit');
select is(app_private.event_house_thanks_queue_mail((select id from app_private.event_house_thanks_receipts where submission_id='e8500000-0000-0000-0000-000000000002')),0,'rechecking the historical custom receipt creates no duplicate');
select ok(not has_function_privilege('authenticated','app_private.event_house_thanks_custom(text,text)','execute'),'the custom predicate remains private');
select ok(not has_function_privilege('authenticated','app_private.event_portal_mail_recipient(uuid,uuid,text)','execute'),'shared working-team eligibility remains a private invoker helper');
select ok(not has_function_privilege('authenticated','api.worker_house_thanks_mail(uuid)','execute'),'the mail material lookup remains service only');
select ok(not has_table_privilege('authenticated','app_private.event_house_thanks','select'),'the new initial text column grants no direct data access');
select *from finish();
rollback;
