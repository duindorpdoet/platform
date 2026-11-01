begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
-- This transaction models real participating portals from synthetic seed rows.
-- Keep an explicit fixture flag on one negative target; production has no bypass.
update app_private.portal_flags set value=false where flag_key='fixture'and portal_id<>'12000000-0000-0000-0000-000000000029';
update app_private.portals set operation_status='closed'where id='12000000-0000-0000-0000-000000000001';
update app_private.portals set approval_status='withdrawn',lifecycle_status='archived',operation_status='closed'where id in('12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000003');
insert into app_private.portal_status_history(portal_id,actor_id,state,reason)values('12000000-0000-0000-0000-000000000003','f0000000-0000-0000-0000-000000000001','open','Synthetic evidence of real past participation');

-- One additional account shares an address; another has no confirmed address.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values
 ('d1000000-0000-0000-0000-000000000005','DUINPAD-1@example.invalid',now(),'{}','{}'),
 ('d1000000-0000-0000-0000-000000000006',null,null,'{}','{}'),
 ('d1000000-0000-0000-0000-000000000007','never-started@example.invalid',now(),'{}','{}');
insert into app_private.household_members(household_id,user_id,relation_role)values
 ('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000005','adult'),
 ('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000006','adult');
insert into app_private.households(id,label,primary_contact_user_id)values('d2000000-0000-0000-0000-000000000004','Never started','d1000000-0000-0000-0000-000000000007');
insert into app_private.household_members(household_id,user_id,relation_role)values('d2000000-0000-0000-0000-000000000004','d1000000-0000-0000-0000-000000000007','owner');
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'd3000000-0000-0000-0000-000000000004',id,'d2000000-0000-0000-0000-000000000004','submitted','CLOSE-NEVER-START'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)values('d4000000-0000-0000-0000-000000000004','d2000000-0000-0000-0000-000000000004','No scan child',8);
insert into app_private.registration_children(id,event_id,registration_id,child_id,unit_price_cents)select 'd5000000-0000-0000-0000-000000000004',id,'d3000000-0000-0000-0000-000000000004','d4000000-0000-0000-0000-000000000004',0 from app_private.events where slug='duindorp-halloween-2026';
-- A real pending organizer registration is captured without inventing an account.
insert into app_private.households(id,label)values('d2000000-0000-0000-0000-000000000005','Pending activated family');
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'd3000000-0000-0000-0000-000000000005',id,'d2000000-0000-0000-0000-000000000005','submitted','CLOSE-PENDING'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)values('d4000000-0000-0000-0000-000000000005','d2000000-0000-0000-0000-000000000005','Pending child',8);
insert into app_private.registration_children(id,event_id,registration_id,child_id,unit_price_cents)select 'd5000000-0000-0000-0000-000000000005',id,'d3000000-0000-0000-0000-000000000005','d4000000-0000-0000-0000-000000000005',0 from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.registration_activations(registration_id,event_id,normalized_email,parent_name,invite_token_hash,created_by)select 'd3000000-0000-0000-0000-000000000005',id,'late-activation@example.invalid','Invited adult',extensions.digest(repeat('c',64),'sha256'),'f0000000-0000-0000-0000-000000000001'from app_private.events where slug='duindorp-halloween-2026';
-- This unfinished route has no scan; its business execution must stop without
-- manufacturing completed stops or invoking any physical completion trigger.
insert into app_private.walking_groups(id,event_id,code,status,route_mode)select 'd7000000-0000-0000-0000-000000000002',id,'CLOSE-ACTIVE','live','dynamic'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.group_runs(id,group_id,status,started_at)values('d8000000-0000-0000-0000-000000000002','d7000000-0000-0000-0000-000000000002','paused',now());

insert into app_private.household_invites(id,household_id,recipient_email,token_hash,invited_by,expires_at)values('d1300000-0000-0000-0000-000000000010','d2000000-0000-0000-0000-000000000001','pending-household@example.invalid',extensions.digest(repeat('d',64),'sha256'),'d1000000-0000-0000-0000-000000000001',now()+interval '1 day');
-- Existing actual finale data and an already ended household stay historic.
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','{"d9000000-0000-0000-0000-000000000001":"visited","d9000000-0000-0000-0000-000000000002":"skipped"}','close-fixture-first-scan');
create temp table closure_before as select
 (select count(*)from app_private.run_stop_arrivals)arrivals,(select count(*)from app_private.scan_evidence)scans,
 (select count(*)from app_private.duinpad_finale_receipts)finales,(select count(*)from app_private.duinpad_show_attempts)shows,
 (select count(*)from app_private.duinpad_actor_commands)commands,(select count(*)from app_private.poortenboek_passport_seals)physical_seals,
 (select count(*)from app_private.group_portal_visits)visits,
 (select evening_ends_at from app_private.duinpad_evenings where run_id='d8000000-0000-0000-0000-000000000001')deadline;
select is((select count(*)from app_private.event_closures),0::bigint,'release/ordinary use never closes an event');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000003","role":"authenticated","user_metadata":{"admin":true}}',true);
set local role authenticated;
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Hijack','No',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','metadata does not authorize a participant to close');
select throws_ok($$select api.event_closure_admin_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','participant cannot inspect campaign administration');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.event_closure_admin_snapshot('duindorp-halloween-2026')->>'closed','false','opening modal is read only');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026',E'Bad\nHeader','Text',gen_random_uuid())$$,'22023','VALIDATION_ERROR','subject newline is rejected');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',repeat('x',20001),gen_random_uuid())$$,'22023','VALIDATION_ERROR','body limit is enforced server side');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026',repeat('x',200)||' ','Body',gen_random_uuid())$$,'22023','VALIDATION_ERROR','raw subject length includes trailing spaces');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',repeat('x',20000)||' ',gen_random_uuid())$$,'22023','VALIDATION_ERROR','raw body length includes trailing spaces');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',repeat('x',20000)||E'\n',gen_random_uuid())$$,'22023','VALIDATION_ERROR','raw body length includes trailing newlines');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',E' \n\t ',gen_random_uuid())$$,'22023','VALIDATION_ERROR','whitespace-only body is rejected at the direct authenticated RPC');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026',repeat('x',199)||'🎃','Body',gen_random_uuid())$$,'22023','VALIDATION_ERROR','direct RPC subject length matches JS UTF-16 emoji units');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',repeat('x',19999)||'🎃',gen_random_uuid())$$,'22023','VALIDATION_ERROR','direct RPC body length matches JS UTF-16 emoji units');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject',chr(160),gen_random_uuid())$$,'22023','VALIDATION_ERROR','NBSP-only body matches JS trim rejection');
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026',chr(65279),'Body',gen_random_uuid())$$,'22023','VALIDATION_ERROR','BOM-only subject matches JS trim rejection');


set local role postgres;
update app_private.events set phase='draft'where slug='duindorp-halloween-2026';
set local role authenticated;
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject','Text',gen_random_uuid())$$,'23514','EVENT_NOT_CLOSABLE','a draft event cannot be closed accidentally');
set local role postgres;
update app_private.events set phase='archived'where slug='duindorp-halloween-2026';
set local role authenticated;
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject','Text',gen_random_uuid())$$,'23514','EVENT_NOT_CLOSABLE','an archived event remains protected');
set local role postgres;
update app_private.events set phase='registration_open',local_date=date'2099-10-31'where slug='duindorp-halloween-2026';
set local role authenticated;
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject','Text',gen_random_uuid())$$,'23514','EVENT_NOT_CLOSABLE','a future event cannot be closed');
set local role postgres;
update app_private.events set local_date=date'2026-10-31',settings=jsonb_set(settings,'{rehearsal}','true')where slug='duindorp-halloween-2026';
set local role authenticated;
select throws_ok($$select api.event_closure_confirm('duindorp-halloween-2026','Subject','Text',gen_random_uuid())$$,'23514','EVENT_NOT_CLOSABLE','rehearsal events cannot start a real organization campaign');
set local role postgres;
update app_private.events set settings=settings-'rehearsal'where slug='duindorp-halloween-2026';
set local role authenticated;
-- Production may retain registration_open after the real event date. Only this
-- explicit confirmed action changes phase; deployment and preview never do.
select is(api.event_closure_confirm('duindorp-halloween-2026','  Edited subject 🎃  ',E'Original body\n\nPersonal added paragraph <script>literal</script>',gen_random_uuid())->>'existing','false','first intentional confirmation closes exactly once');
select is(api.event_closure_confirm('duindorp-halloween-2026','Competing overwrite','Should not replace',gen_random_uuid())#>>'{closure,subject}','  Edited subject 🎃  ','a second organizer/request receives the existing immutable content');
set local role postgres;
select is((select count(*)from app_private.event_closures),1::bigint,'one central closure/campaign');
select ok(exists(select 1 from app_private.event_closure_portals where portal_id='12000000-0000-0000-0000-000000000001'),'an operationally closed participating portal remains in the frozen set');
select ok(not exists(select 1 from app_private.event_closure_portals where portal_id='12000000-0000-0000-0000-000000000002'),'withdrawn portal without participation evidence is excluded');
select ok(exists(select 1 from app_private.event_closure_portals where portal_id='12000000-0000-0000-0000-000000000003'),'an archived portal with real prior opening evidence remains included');
select ok(not exists(select 1 from app_private.event_closure_portals where portal_id='12000000-0000-0000-0000-000000000029'),'explicit fixture portal is excluded even while approved and active');

select is((select used from app_private.portal_room_budgets where user_id='f0000000-0000-0000-0000-000000000001'and kind='event_closure_confirm'),1,'first close consumes the existing rate budget; duplicate confirmation consumes none');
select is((select count(*)from app_private.email_outbox where message_type='event_closure_thanks'),0::bigint,'confirm persists recipients without synchronously sending or creating all provider jobs');
select is((select count(*)from app_private.event_closure_accounts where account_id::text like 'd1000000-%'),7::bigint,'all adult accounts include nonleaders, unstarted and missing-contact accounts');
select is((select count(*)from app_private.event_closure_mail_recipients where normalized_email like 'duinpad-%'),4::bigint,'different adults receive mail, normalized duplicate addresses share one campaign mail');
select is((select count(*)from app_private.event_closure_children where child_id::text like 'd4000000-%'),5::bigint,'all registered children include no-route/no-scan and pending-activation children');
select is((select status::text from app_private.group_runs where id='d8000000-0000-0000-0000-000000000002'),'stopped','unfinished business execution is stopped');
select is((select stopped_reason from app_private.group_runs where id='d8000000-0000-0000-0000-000000000002'),'event_closed_by_organization','business stop has explicit administrative origin');
select is((select count(*)from app_private.run_stop_arrivals),(select arrivals from closure_before),'no fictitious arrival');
select is((select count(*)from app_private.scan_evidence),(select scans from closure_before),'no fictitious scan');
select is((select count(*)from app_private.duinpad_finale_receipts),(select finales from closure_before),'no finale scan right consumed');
select is((select count(*)from app_private.duinpad_show_attempts),(select shows from closure_before),'no show reserved');
select is((select count(*)from app_private.duinpad_actor_commands),(select commands from closure_before),'no physical command');
select is((select count(*)from app_private.poortenboek_passport_seals),(select physical_seals from closure_before),'physical child seals remain real history');
select is((select count(*)from app_private.group_portal_visits),(select visits from closure_before),'visitor statistics remain physical');
select is((select evening_ends_at from app_private.duinpad_evenings where run_id='d8000000-0000-0000-0000-000000000001'),(select deadline from closure_before),'old two-hour deadline preserved');
select throws_ok($$update app_private.event_closures set body='overwrite'$$,'23514','EVENT_CLOSURE_IMMUTABLE','confirmed message cannot be edited in place');
select is(api.worker_event_closures(1)->>'processed','1','fanout respects bounded batch');
select ok((api.worker_event_closures(25)->>'processed')::integer>0,'remaining durable recipients progress on a later worker tick');
select is(api.worker_event_closures(25)->>'processed','0','fanout retries produce no additional outbox jobs');
select is((select count(*)from app_private.email_outbox where message_type='event_closure_thanks'),(select count(*)from app_private.event_closure_mail_recipients),'each deduplicated address has exactly one outbox command');
select ok((select bool_and(payload->>'subject'='  Edited subject 🎃  'and payload->>'body'=E'Original body\n\nPersonal added paragraph <script>literal</script>')from app_private.email_outbox where message_type='event_closure_thanks'),'outbox preserves full definitive subject and exact extra paragraphs as text');
select is((select count(distinct outbox_id)from app_private.event_closure_mail_recipients),(select count(*)from app_private.event_closure_mail_recipients),'every address maps to its own unique durable provider job');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000007","role":"authenticated"}',true);
set local role authenticated;
select is(api.event_closure_snapshot('duindorp-halloween-2026')->>'closed','true','account without any route sees the retrospective');
select is(api.event_closure_snapshot('duindorp-halloween-2026')#>>'{closure,body}',E'Original body\n\nPersonal added paragraph <script>literal</script>','app receives exact same definitive body');
select ok(jsonb_array_length(api.event_closure_snapshot('duindorp-halloween-2026')->'portals')>1,'unstarted family receives every frozen participating portal');
select is(api.participant_context('duindorp-halloween-2026')#>>'{event,eveningClosure,subject}','  Edited subject 🎃  ','normal existing status refresh includes closure');
select ok((api.event_closure_acknowledge('duindorp-halloween-2026',(api.event_closure_snapshot('duindorp-halloween-2026')#>>'{closure,id}')::uuid)#>>'{closure,readAt}')is not null,'read acknowledgement persists on server');
select throws_ok($$select api.event_closure_acknowledge('duindorp-halloween-2026',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','foreign closure acknowledgement is refused');
select throws_ok($$select api.run_start('d7000000-0000-0000-0000-000000000001','{}',1,'closed-start','closed-start')$$,'23514','EVENING_ENDED','new route cannot start');
select throws_ok($$select api.run_scan('d8000000-0000-0000-0000-000000000001','db000000-0000-0000-0000-000000000001',1,'ignored','qr')$$,'23514','EVENING_ENDED','ordinary scan blocked');
select throws_ok($$select api.duinpad_finale_confirm('duindorp-halloween-2026','ignored','{}','closed-finale')$$,'23514','EVENING_ENDED','finale confirm blocked before any new receipt/show');
select throws_ok($$select api.duinpad_checkpoint_validate('duindorp-halloween-2026','ignored')$$,'23514','EVENING_ENDED','QR1 validation blocked');
set local role postgres;
-- Gift projection is usable by an existing child code even with no route start.
insert into app_private.poortenboek_codes(event_id,child_id,code_digest,ciphertext)select id,'d4000000-0000-0000-0000-000000000004',repeat('a',64),repeat('x',40)from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.poortenboek_sessions(code_id,token_hash)select id,repeat('b',64)from app_private.poortenboek_codes where child_id='d4000000-0000-0000-0000-000000000004';
create temp table gifted_book as select api.poortenboek_child_action(repeat('b',64),'snapshot')result;
select is((select result#>>'{journey,complete}'from gifted_book),'true','Nachtpas of child with no physical route is complete');
select is((select jsonb_array_length(result#>'{journey,seals}')from gifted_book),(select count(*)::integer from app_private.event_closure_portals),'every frozen portal has a gift seal');
select ok((select bool_and(s->>'source'='event_closure'and not(s?'stopId'))from gifted_book,jsonb_array_elements(result#>'{journey,seals}')s),'gift source is explicit and no physical stop id is invented');
select ok((select bool_or((s->>'finale')::boolean)from gifted_book,jsonb_array_elements(result#>'{journey,seals}')s),'real configured final gate is included');
select ok((select bool_and((s->'presentation')?&array['version','portalCode','world','worldSlug','publicName','shortDescription','story','symbol','color','imagePath','accessibility','intensity'])from gifted_book,jsonb_array_elements(result#>'{journey,seals}')s),'gift seal presentation preserves every existing app/PDF field');
select ok((select bool_and(jsonb_typeof(s#>'{presentation,publicName}')='string'and length(s#>>'{presentation,publicName}')>0 and jsonb_typeof(s#>'{presentation,intensity}')='number')from gifted_book,jsonb_array_elements(result#>'{journey,seals}')s),'gifted gate names and intensity use the existing display types');

select lives_ok($$select api.poortenboek_child_action(repeat('b',64),'chapter_read','{"chapter":6}')$$,'gifted final story chapter can be read without falsifying source story unlocks');
select is((select count(*)from app_private.poortenboek_passport_seals),(select physical_seals from closure_before),'gift snapshot/reading never writes physical seal history');
update app_private.registration_children set participation_status='cancelled'where id='d5000000-0000-0000-0000-000000000004';
select throws_ok($$select api.poortenboek_child_action(repeat('b',64),'chapter_read','{"chapter":5}')$$,'42501','CHILD_SESSION_INVALID','revoked child participation cannot claim a gifted chapter');
select is((select count(*)from app_private.poortenboek_chapter_reads where child_id='d4000000-0000-0000-0000-000000000004'and chapter=5),0::bigint,'revoked child read creates no administrative chapter acknowledgement');
update app_private.registration_children set participation_status='active'where id='d5000000-0000-0000-0000-000000000004';
update app_private.registrations set status='cancelled'where id='d3000000-0000-0000-0000-000000000004';
select throws_ok($$select api.poortenboek_child_action(repeat('b',64),'chapter_read','{"chapter":5}')$$,'42501','CHILD_SESSION_INVALID','withdrawn registration cannot claim a gifted chapter');
select is((select count(*)from app_private.poortenboek_chapter_reads where child_id='d4000000-0000-0000-0000-000000000004'and chapter=5),0::bigint,'withdrawn registration leaves chapter acknowledgement unchanged');
update app_private.registrations set status='submitted'where id='d3000000-0000-0000-0000-000000000004';

-- A late unrelated adult is not retrospectively entitled by a new membership.
insert into auth.users(id,email,email_confirmed_at)values('d1000000-0000-0000-0000-000000000008','late-unrelated@example.invalid',now());
insert into app_private.household_members(household_id,user_id,relation_role)values('d2000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000008','adult');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000008","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select api.event_closure_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','a new arbitrary account gains no frozen campaign entitlement');
set local role postgres;
-- Activate a frozen, pending registration using the existing verified session API.
insert into auth.users(id,email,email_confirmed_at)values('d1000000-0000-0000-0000-000000000009','late-activation@example.invalid',now());
insert into auth.sessions(id,user_id,created_at,updated_at)values('d1100000-0000-0000-0000-000000000009','d1000000-0000-0000-0000-000000000009',clock_timestamp(),clock_timestamp());
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000009","role":"authenticated","session_id":"d1100000-0000-0000-0000-000000000009"}',true);
set local role authenticated;
select is(api.registration_activation_claim(repeat('c',64),gen_random_uuid(),'explicit')->>'activated','true','existing pending registration may genuinely activate after closure');
select is(api.event_closure_snapshot('duindorp-halloween-2026')->>'closed','true','later activated participant receives the same retrospective');
select is(api.account_app_snapshot('duindorp-halloween-2026')#>>'{eveningClosure,subject}','  Edited subject 🎃  ','normal late account login receives the closure');
set local role postgres;
select is((select count(*)from app_private.event_closure_accounts where account_id='d1000000-0000-0000-0000-000000000009'),1::bigint,'late account receives one durable account receipt');
select is(api.worker_event_closures(25)->>'processed','1','first mail for a genuine late activation is durably queued once');
select is(api.worker_event_closures(25)->>'processed','0','late activation retry never queues another campaign mail');
select is((select count(*)from app_private.email_outbox where message_type='event_closure_thanks'and recipient_email='late-activation@example.invalid'),1::bigint,'late activated email has one logical mail command');

insert into auth.users(id,email,email_confirmed_at)values('d1000000-0000-0000-0000-000000000010','pending-household@example.invalid',now());
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000010","role":"authenticated"}',true);
set local role authenticated;
select is(api.household_invite_accept(repeat('d',64))->>'accepted','true','a genuinely frozen pending adult invitation can be accepted after closure');
select is(api.event_closure_snapshot('duindorp-halloween-2026')->>'closed','true','accepted frozen household invitation has the same retrospective');
set local role postgres;
select is((select count(*)from app_private.event_closure_accounts where account_id='d1000000-0000-0000-0000-000000000010'),1::bigint,'late invited adult receives one account receipt');
select is(api.worker_event_closures(25)->>'processed','1','late invited adult receives one first campaign mail');
select is(api.worker_event_closures(25)->>'processed','0','late household invitation produces no duplicate campaign on retry');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000009","role":"authenticated","session_id":"d1100000-0000-0000-0000-000000000009"}',true);
update auth.users set email='changed-after-campaign@example.invalid'where id='d1000000-0000-0000-0000-000000000009';
select api.event_closure_snapshot('duindorp-halloween-2026');
select is(api.worker_event_closures(25)->>'processed','0','changing email does not create a second campaign for the same account');

alter table app_private.duinpad_evenings disable trigger duinpad_evening_immutable;
update app_private.duinpad_evenings set first_finale_scan_at=statement_timestamp()-interval '2 hours',evening_ends_at=statement_timestamp();
alter table app_private.duinpad_evenings enable trigger duinpad_evening_immutable;
select is(api.worker_duinpad_evenings()->>'queued','0','expired pending two-hour worker adds no extra generic thanks after closure');
select is(api.worker_duinpad_evenings()->>'queued','0','second old worker tick stays idempotent');
select is((select count(*)from app_private.email_outbox where message_type='duinpad_evening_thanks'),0::bigint,'no post-central generic campaign created');
select is(api.worker_dispatch_due_groups('duindorp-halloween-2026')->>'eventClosed','true','background route dispatcher stops without physical work');
select lives_ok($$select app_private.dispatch_all_due_routes()$$,'whole existing minute dispatcher safely skips a centrally closed event');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'requeued','0','retry action never requeues pending or accepted campaign jobs');
set local role postgres;
create temp table closure_retry_cases as select id,recipient_email,row_number()over(order by id)case_no from app_private.email_outbox where message_type='event_closure_thanks'order by id limit 5;
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)values('d1200000-0000-0000-0000-000000000001','test',1,'resend','sender@example.invalid','Local mock','reply@example.invalid',repeat('a',64));
update app_private.email_outbox o set status=case c.case_no when 3 then 'unknown'::app_private.outbox_status when 4 then 'accepted'::app_private.outbox_status else 'failed'::app_private.outbox_status end,accepted_at=case when c.case_no=4 then clock_timestamp()end,provider_id=case when c.case_no=4 then 'local-provider-accepted'end,attempts=1 from closure_retry_cases c where o.id=c.id;
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,outbox_id,channel,message_type,recipient_hash,payload_hash,credential_hash,status,first_attempt_at)
select 'test','closure-retry:'||c.id,'d1200000-0000-0000-0000-000000000001','resend',c.id,'transactional','event_closure_thanks',extensions.digest(c.recipient_email,'sha256'),repeat('b',64),repeat('c',64),case when c.case_no=3 then 'unknown'else 'failed'end,case when c.case_no=5 then clock_timestamp()-interval '24 hours'else clock_timestamp()end from closure_retry_cases c where c.case_no in(2,3,5);
set local role authenticated;
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'requeued','2','operator requeues only an unattempted failure and a definitive recent Resend rejection');
select is(api.event_closure_retry_failed('duindorp-halloween-2026')->>'requeued','0','repeating recovery does not requeue the same attempts');
set local role postgres;
select ok((select bool_and(o.status='pending'and o.next_attempt_at>clock_timestamp()+interval '29 seconds')from app_private.email_outbox o join closure_retry_cases c on c.id=o.id where c.case_no in(1,2)),'recovery uses bounded delay and the existing outbox records');
select is((select e.status from app_private.mail_envelopes e join closure_retry_cases c on c.id=e.outbox_id where c.case_no=2),'deferred','definitive rejection retains its provider idempotency key and envelope');
select is((select e.status from app_private.mail_envelopes e join closure_retry_cases c on c.id=e.outbox_id where c.case_no=3),'unknown','unknown provider outcome remains unknown');
select is((select o.status::text from app_private.email_outbox o join closure_retry_cases c on c.id=o.id where c.case_no=4),'accepted','accepted provider delivery never becomes a new send');
select is((select e.status from app_private.mail_envelopes e join closure_retry_cases c on c.id=e.outbox_id where c.case_no=5),'failed','outside provider idempotency window requires reconciliation, not blind retry');
update app_private.portal_room_budgets set used=10,window_at=now()where user_id='f0000000-0000-0000-0000-000000000001'and kind='event_closure_retry_failed';
set local role authenticated;
select throws_ok($$select api.event_closure_retry_failed('duindorp-halloween-2026')$$,'P0001','RATE_LIMITED','operator retry uses the existing abuse budget');
select is(api.event_closure_confirm('duindorp-halloween-2026','Overwrite','Overwrite',gen_random_uuid())->>'existing','true','duplicate confirmation remains safe and successful independently of retry rate budget');
set local role postgres;


set local role postgres;
select ok(not has_table_privilege('authenticated','app_private.event_closures','SELECT'),'operational closure table remains private');
select ok(not has_function_privilege('authenticated','api.worker_event_closures(integer)','EXECUTE'),'participant cannot dispatch campaign mail');
select ok(not has_function_privilege('anon','api.event_closure_confirm(text,text,text,uuid)','EXECUTE'),'anonymous cannot confirm closure');
select *from finish();
rollback;
