begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic addresses/identities only. Admin creation itself never inserts Auth users.
create temp table activation_config as select e.slug,e.settings_version,
 jsonb_build_object('parentName','Uitgenodigde Ouder','email','activation-new@example.invalid','phone','0612345678',
  'preferredStartAt',(app_private.exact_preference_options(e.id)->'allowedStartTimes')->>0,
  'desiredEndAt',(app_private.exact_preference_options(e.id)->'allowedEndTimes')->>0,
  'children',jsonb_build_array(jsonb_build_object('name','Kind Een','age',6),jsonb_build_object('name','Kind Twee','age',8),jsonb_build_object('name','Kind Drie','age',10))) payload
 from app_private.events e where slug='duindorp-halloween-2026';
update app_private.events set settings=jsonb_set(settings,'{groupRegistrationOpen}','false') where slug='duindorp-halloween-2026';
create temp table activation_results(kind text primary key,result jsonb,token text);
grant all on activation_results to authenticated;
grant select on activation_config to authenticated;
select ok(not has_function_privilege('anon','api.admin_registration_create(text,jsonb,integer,uuid,text)','execute'),'anonymous callers cannot use the organizer exception');
select ok(not has_function_privilege('authenticated','api.worker_registration_activation_mail_payload(uuid)','execute'),'private invitation material belongs only to the mail worker');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_registration_create(slug,payload,settings_version,'b7010000-0000-0000-0000-000000000010','Synthetische late inschrijving') from activation_config$$,'42501','NOT_AUTHORIZED','a participant cannot invoke administrator creation');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$insert into activation_results(kind,result) select 'new',api.admin_registration_create(slug,payload,settings_version,'b7010000-0000-0000-0000-000000000010','Synthetische late inschrijving') from activation_config$$,'organizer creates one family with three children while public registration is closed');
select is((select result->>'activationStatus' from activation_results where kind='new'),'pending','new registration waits for first verified claim');
select is((select api.admin_registration_create(c.slug,c.payload,c.settings_version,'b7010000-0000-0000-0000-000000000010','Synthetische late inschrijving') from activation_config c),(select result from activation_results where kind='new'),'retry returns the exact command receipt');
select is((select api.admin_registration_create(c.slug,c.payload,c.settings_version,'b7010000-0000-0000-0000-000000000011','Andere poging zelfde gezin')->>'existing' from activation_config c),'true','another create for the same event/email points to the existing registration');
select is((select item->'activation'->>'status' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='new')),'pending','pending family is durable and visible in the actual admin roster');
select is((select item->>'paidChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='new')),'0','pending registration derives paid count from real payment status');
select ok((select item->'presentChildCount'='null'::jsonb from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='new')),'unassigned registration has no inferred attendance count');
select ok((api.admin_registration_creation_options('duindorp-halloween-2026'))?&array['eventVersion','groups','parties','allowedStartTimes','allowedEndTimes'],'organizer options reuse real preference/group/together fields');
reset role;
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='new';
select is((select count(*)::integer from app_private.registration_children where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),3,'one registration owns all three stable child identities');
select ok((select h.primary_contact_user_id is null from app_private.registrations r join app_private.households h on h.id=r.household_id where r.id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),'administrator does not invent a verified owner');
select is((select count(*)::integer from app_private.household_members m join app_private.registrations r on r.household_id=m.household_id where r.id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),0,'administrator creates no fictitious household member');
select is((select count(*)::integer from auth.users where email='activation-new@example.invalid'),0,'administrator creates no Auth account');
select is((select count(*)::integer from app_private.email_outbox where payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),1,'successful creation queues exactly one invitation');
select is((select count(*)::integer from app_private.email_outbox where message_type='registration_received' and payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),0,'creation does not also queue a generic registration receipt');
select is((select p.status::text from app_private.payment_requests p where p.registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),'awaiting_link','pending participation is never automatically marked paid');
select ok((select not(o.payload?'token') and o.payload->>'invitationVersion'='1' from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),'outbox carries a revision, never the invitation bearer');
select ok((select api.worker_registration_activation_mail_payload(o.id)->>'actionPath'='/uitnodiging/inschrijving/'||(select token from activation_results where kind='new') from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),'service-only renderer builds the current secure activation path');
insert into auth.users(id,email,email_confirmed_at,created_at,updated_at) values
 ('b7010000-0000-0000-0000-000000000001','activation-new@example.invalid',now(),now(),now()),
 ('b7010000-0000-0000-0000-000000000002','activation-wrong@example.invalid',now(),now(),now()),
 ('b7010000-0000-0000-0000-000000000003','activation-existing@example.invalid',now(),now()-interval '1 year',now());
insert into auth.sessions(id,user_id,created_at,updated_at,aal) values
 ('b7020000-0000-0000-0000-000000000001','b7010000-0000-0000-0000-000000000001',now()-interval '1 hour',now(),'aal1'),
 ('b7020000-0000-0000-0000-000000000002','b7010000-0000-0000-0000-000000000001',clock_timestamp()+interval '1 second',now(),'aal1'),
 ('b7020000-0000-0000-0000-000000000003','b7010000-0000-0000-0000-000000000002',clock_timestamp()+interval '1 second',now(),'aal1'),
 ('b7020000-0000-0000-0000-000000000004','b7010000-0000-0000-0000-000000000003',now()-interval '1 hour',now(),'aal1');
-- An earlier real household must not hide the new event registration after claim.
insert into app_private.households(id,label,primary_contact_user_id) values('b7030000-0000-0000-0000-000000000001','Eerder huishouden','b7010000-0000-0000-0000-000000000001');
insert into app_private.household_members(household_id,user_id,relation_role,accepted_at) values('b7030000-0000-0000-0000-000000000001','b7010000-0000-0000-0000-000000000001','owner',now()-interval '1 day');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000001","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000001","iat":9999999999}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000001','fresh') from activation_results where kind='new'$$,'42501','FRESH_LOGIN_OR_EXPLICIT_CLAIM_REQUIRED','an old session with refreshed token timestamps cannot automatically activate');
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000002","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000003"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000002','fresh') from activation_results where kind='new'$$,'42501','INVITATION_UNAVAILABLE','another verified email cannot take ownership');
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000001","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000002"}',true);
select lives_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000003','fresh') from activation_results where kind='new'$$,'the correct fresh Auth session activates without reopening public registration');
select lives_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000003','fresh') from activation_results where kind='new'$$,'repeated verified callbacks are idempotent');
select is((api.registration_snapshot('duindorp-halloween-2026')#>>'{registration,id}'),(select result->>'registrationId' from activation_results where kind='new'),'parent snapshot chooses this event registration before an older unrelated household');
select is((api.registration_preferences_snapshot('duindorp-halloween-2026')->>'registrationId'),(select result->>'registrationId' from activation_results where kind='new'),'preference snapshot uses the same event household');
reset role;
select is((select count(*)::integer from app_private.audit_events where action='registration.activated' and resource_id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),1,'one actual activation audit despite callback retries');
select is((select count(*)::integer from app_private.registration_children where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='new')),3,'claim reuses all three existing children');
select is((select count(*)::integer from app_private.email_outbox where payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),1,'claim creates no second confirmation mail');
select ok((select api.worker_registration_activation_mail_payload(o.id) is null from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='new')),'already claimed invitations are not sent later by a stale worker');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into activation_results(kind,result) select 'existing',api.admin_registration_create(slug,jsonb_set(payload,'{email}','"activation-existing@example.invalid"'),settings_version,'b7010000-0000-0000-0000-000000000012','Bestaand account uitnodigen') from activation_config;
reset role;
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='existing';
update app_private.registration_activations set issued_at=now()-interval '8 days',expires_at=now()-interval '1 day' where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='existing');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000003","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000004"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000004','explicit') from activation_results where kind='existing'$$,'23514','INVITATION_EXPIRED','an expired invitation cannot grant ownership');
select lives_ok($$select api.registration_activation_renew(token,'b7040000-0000-0000-0000-000000000005') from activation_results where kind='existing'$$,'verified invited parent can request a new invitation after expiry and public closure');
select lives_ok($$select api.registration_activation_renew(token,'b7040000-0000-0000-0000-000000000005') from activation_results where kind='existing'$$,'renewal retry queues no duplicate invitation');
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000006','explicit') from activation_results where kind='existing'$$,'42501','INVITATION_UNAVAILABLE','the old reference is revoked by renewal');
reset role;
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='existing';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000003","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000004"}',true);
select lives_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000007','explicit') from activation_results where kind='existing'$$,'existing verified account can explicitly accept the newest invitation with an older valid session');
reset role;
select is((select count(*)::integer from auth.users where email='activation-existing@example.invalid'),1,'existing verified account is reused');
select is((select count(*)::integer from app_private.registration_children where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='existing')),3,'expiry and reissue preserve the same registration children');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into activation_results(kind,result) select 'correct',api.admin_registration_create(slug,jsonb_set(payload,'{email}','"activation-wrong@example.invalid"'),settings_version,'b7010000-0000-0000-0000-000000000013','E-mailadres wordt gecorrigeerd') from activation_config;
reset role;
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='correct';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_registration_invite('duindorp-halloween-2026',(result->>'registrationId')::uuid,1,'activation-correct@example.invalid','b7040000-0000-0000-0000-000000000008','Verkeerd getypt adres corrigeren') from activation_results where kind='correct'$$,'organizer can correct a still unclaimed address and reissue atomically');
select lives_ok($$select api.admin_registration_invite('duindorp-halloween-2026',(result->>'registrationId')::uuid,1,'activation-correct@example.invalid','b7040000-0000-0000-0000-000000000008','Verkeerd getypt adres corrigeren') from activation_results where kind='correct'$$,'exact correction retry returns the receipt without another mail');
select throws_ok($$select api.admin_registration_invite('duindorp-halloween-2026',(result->>'registrationId')::uuid,1,null,'b7040000-0000-0000-0000-000000000009','Oude versie opnieuw versturen') from activation_results where kind='correct'$$,'40001','STALE_VERSION','another admin cannot overwrite a stale pending registration version');
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000002","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000003"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000010','explicit') from activation_results where kind='correct'$$,'42501','INVITATION_UNAVAILABLE','the previous email and token lose claim rights immediately');
select throws_ok($$select api.registration_activation_renew(token,'b7040000-0000-0000-0000-000000000011') from activation_results where kind='correct'$$,'42501','INVITATION_UNAVAILABLE','the previous email cannot renew a corrected invitation');
reset role;
select is((select count(*)::integer from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='correct')),2,'correction adds exactly one new invitation');
select ok((select bool_and(api.worker_registration_activation_mail_payload(o.id) is null) from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='correct') and o.payload->>'invitationVersion'='1'),'old leased or pending invitation cannot render after correction');
select is((select o.recipient_email from app_private.email_outbox o where o.payload->>'registrationId'=(select result->>'registrationId' from activation_results where kind='correct') and o.payload->>'invitationVersion'='2'),'activation-correct@example.invalid','new invitation addresses only the corrected email');
select is((select (minimal_change->>'emailCorrected')::boolean from app_private.audit_events where action='registration.invitation_reissued' and resource_id=(select (result->>'registrationId')::uuid from activation_results where kind='correct')),true,'email correction is explicitly audited');
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='correct';
insert into auth.users(id,email,email_confirmed_at,created_at,updated_at) values('b7010000-0000-0000-0000-000000000004','activation-correct@example.invalid',now(),now(),now());
insert into auth.sessions(id,user_id,created_at,updated_at,aal) values('b7020000-0000-0000-0000-000000000005','b7010000-0000-0000-0000-000000000004',now()-interval '1 day',now(),'aal1');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000004","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000003"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000012','explicit') from activation_results where kind='correct'$$,'42501','VERIFIED_IDENTITY_REQUIRED','a signed identity cannot reuse another account session');
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000004","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000005"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000013',null) from activation_results where kind='correct'$$,'42501','INVITATION_UNAVAILABLE','null mode cannot bypass automatic freshness validation');
select lives_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000014','explicit') from activation_results where kind='correct'$$,'the corrected verified identity can explicitly activate the same stored children');
reset role;
create temp table activation_group as
 with made as(insert into app_private.walking_groups(event_id,code,display_name) select id,'activation-physical-fixture','Synthetische activatiegroep' from app_private.events where slug='duindorp-halloween-2026' returning id)
 select id from made;
grant select on activation_group to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$insert into activation_results(kind,result) select 'capacity',api.admin_registration_create(c.slug,jsonb_set(jsonb_set(c.payload,'{email}','"activation-wrong@example.invalid"'),'{groupId}',to_jsonb(g.id)),c.settings_version,'b7010000-0000-0000-0000-000000000014','Kinderen reserveren groepscapaciteit') from activation_config c cross join activation_group g$$,'pending children can be assigned with the same scoped capacity guard as administrator edits');
reset role;
update activation_results set token=app_private.registration_activation_token((result->>'registrationId')::uuid) where kind='capacity';
select is((select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=(select id from activation_group) and a.superseded_at is null),3,'all three pending children already reserve physical group capacity');
update app_private.walking_groups set start_slot_id=(select id from app_private.start_slots where start_point_id is not null order by id limit 1) where id=(select id from activation_group);
update app_private.start_slots set max_children=2 where id=(select start_slot_id from app_private.walking_groups where id=(select id from activation_group));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000002","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000003"}',true);
select throws_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000015','explicit') from activation_results where kind='capacity'$$,'23514','REGISTRATION_START_CAPACITY_EXCEEDED','activation revalidates an unstarted group when its physical start capacity has become insufficient');
reset role;
select ok((select a.activated_at is null from app_private.registration_activations a where a.registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='capacity')),'capacity conflict preserves the pending registration instead of granting ownership');
update app_private.walking_groups set status='live' where id=(select id from activation_group);
insert into app_private.group_runs(group_id,status,started_at) select id,'live',clock_timestamp() from activation_group;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select run.id,rc.id,'present' from app_private.group_runs run cross join app_private.registration_children rc
 where run.group_id=(select id from activation_group) and rc.registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='capacity');
update app_private.run_participants set attendance='departed',departed_at=clock_timestamp() where id=(select rp.id from app_private.run_participants rp join app_private.group_runs run on run.id=rp.run_id where run.group_id=(select id from activation_group) order by rp.id limit 1);
create temp table activation_run_before as select to_jsonb(r) value from app_private.group_runs r where r.group_id=(select id from activation_group);
create temp table activation_participants_before as select jsonb_agg(to_jsonb(rp) order by rp.id) value from app_private.run_participants rp join app_private.group_runs run on run.id=rp.run_id where run.group_id=(select id from activation_group);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b7010000-0000-0000-0000-000000000002","role":"authenticated","session_id":"b7020000-0000-0000-0000-000000000003"}',true);
select lives_ok($$select api.registration_activation_claim(token,'b7040000-0000-0000-0000-000000000016','explicit') from activation_results where kind='capacity'$$,'a later verified ownership claim never rewrites a started group or adds participant capacity');
reset role;
select is((select to_jsonb(r) from app_private.group_runs r where r.group_id=(select id from activation_group)),(select value from activation_run_before),'the started run is byte-for-byte unchanged by ownership claim');
select is((select jsonb_agg(to_jsonb(rp) order by rp.id) from app_private.run_participants rp join app_private.group_runs run on run.id=rp.run_id where run.group_id=(select id from activation_group)),(select value from activation_participants_before),'real attendance and departures are unchanged by ownership claim');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select item->>'presentChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='capacity')),'2','actual present count excludes the child who already departed');
select is((select item->>'activatedChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='capacity')),'3','activation count stays separate from real attendance');
select is((select item->>'paidChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='capacity')),'0','activation and attendance never manufacture a confirmed payment');
update app_private.registration_children set unit_price_cents=0 where id=(select id from app_private.registration_children where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='new') order by id limit 1);
select is((select item->>'paidChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='new')),'1','a genuinely waived child counts separately from two unpaid children');
update app_private.payment_requests set status='confirmed' where registration_id=(select (result->>'registrationId')::uuid from activation_results where kind='new');
select is((select item->>'paidChildCount' from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select result->>'registrationId' from activation_results where kind='new')),'3','actual confirmed family payment counts the two paid children and one waiver');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'c0000000-0000-0000-0000-000000000001','registration_manage' from app_private.events where slug='duindorp-halloween-2026';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.admin_registration_creation_options('duindorp-halloween-2026')->>'canManageGroups','false','registration-only organizer options do not grant group-management authority');
select throws_ok($$select api.admin_registration_create(slug,jsonb_set(payload,'{email}','"activation-reg-manager@example.invalid"')||jsonb_build_object('groupId',(select id from activation_group)),settings_version,gen_random_uuid(),'Groepstoewijzing zonder groepsbeheer blokkeren') from activation_config$$,'42501','NOT_AUTHORIZED','registration-only capability cannot attach a family to a group');
select throws_ok($$select api.admin_registration_create(slug,jsonb_set(payload,'{email}','"activation-reg-manager@example.invalid"')||jsonb_build_object('partyId',gen_random_uuid()),settings_version,gen_random_uuid(),'Samenloop zonder groepsbeheer blokkeren') from activation_config$$,'42501','NOT_AUTHORIZED','registration-only capability cannot attach a family to a together party');
select lives_ok($$select api.admin_registration_create(slug,jsonb_set(payload,'{email}','"activation-reg-manager@example.invalid"'),settings_version,gen_random_uuid(),'Bevoegde registratie zonder groep aanmaken') from activation_config$$,'registration-only organizer may still create an unassigned pending family');
reset role;
select is((select settings->>'groupRegistrationOpen' from app_private.events where slug='duindorp-halloween-2026'),'false','creation, login, claim and renewal never reopen public registration');
select * from finish();
rollback;
