begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/registration-management.inc
-- Share a preference party with another household; a targeted move must not
-- move this sibling registration or leave a preference that undoes the move.
update app_private.together_memberships set left_at=clock_timestamp() where registration_id='22000000-0000-0000-0000-000000000003' and left_at is null;
insert into app_private.together_memberships(party_id,registration_id)
 select party_id,'22000000-0000-0000-0000-000000000003' from app_private.together_memberships where registration_id='22000000-0000-0000-0000-000000000001' and left_at is null;
create temp table management_test as select '22000000-0000-0000-0000-000000000001'::uuid reg,
 '23000000-0000-0000-0000-000000000001'::uuid source,'23000000-0000-0000-0000-000000000002'::uuid target,
 pg_temp.registration_management_fixture() fixture,null::jsonb preview,null::jsonb payload,null::jsonb result,null::jsonb checkpoint,
 null::jsonb allmail,null::jsonb ledger,null::jsonb sibling,null::uuid original_child,null::uuid original_rc,null::uuid added_rc,
 null::jsonb first_result,null::text old_hash,null::integer old_revision,gen_random_uuid()::text key;
grant select,update on management_test to authenticated;
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg);
update management_test set original_child=(preview#>>'{children,0,childId}')::uuid,original_rc=(preview#>>'{children,0,id}')::uuid;
-- A paid historical link remains evidence; it is not offered again by the
-- existing child payment projector unless the aggregate is awaiting_payment.
update app_private.payment_requests set external_url='https://tikkie.me/pay/synthetic-historical-paid' where registration_id=(select reg from management_test) and status='confirmed';
insert into app_private.payment_entries(request_id,amount_cents,entry_type,checked_by,checked_at,reason)
 select p.id,p.amount_cents,'payment','f0000000-0000-0000-0000-000000000001',now(),'Synthetisch reeds ontvangen bijdrage voor behoud van betaalhistorie'
 from app_private.payment_requests p where p.registration_id=(select reg from management_test)
 and not exists(select 1 from app_private.payment_entries entry where entry.request_id=p.id and entry.entry_type<>'reported');
-- A previous journey belongs to a different physical group. Editing a future
-- registration must retain its earned passport and actual historical identities.
insert into app_private.group_runs(id,group_id,active_plan_version_id,status,started_at,finished_at)
 select 'd1050000-0000-0000-0000-000000000001',id,current_plan_version_id,'completed','2026-10-31T15:00:00Z','2026-10-31T15:20:00Z' from app_private.walking_groups where id='23000000-0000-0000-0000-000000000003';
insert into app_private.run_participants(id,run_id,registration_child_id,attendance)
 select 'd1050000-0000-0000-0000-000000000002','d1050000-0000-0000-0000-000000000001',original_rc,'present' from management_test;
insert into app_private.run_stops(id,run_id,plan_stop_id,sequence,state,outcome,opened_at,completed_at)
 select 'd1050000-0000-0000-0000-000000000003','d1050000-0000-0000-0000-000000000001',stop.id,1,'completed','visited','2026-10-31T15:05:00Z','2026-10-31T15:10:00Z'
 from app_private.route_plan_stops stop where stop.plan_version_id=(select current_plan_version_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000003') order by position limit 1;
insert into app_private.poortenboek_passport_seals(event_id,child_id,team_id,run_id,run_stop_id,portal_id,world_id,presentation_snapshot,earned_at,finale)
 select r.event_id,t.original_child,'23000000-0000-0000-0000-000000000003','d1050000-0000-0000-0000-000000000001','d1050000-0000-0000-0000-000000000003',p.id,p.world_id,'{"title":"Eerder verdiend synthetisch paspoortzegel"}','2026-10-31T15:10:00Z',false
 from management_test t join app_private.registrations r on r.id=t.reg join app_private.run_stops historical_stop on historical_stop.id='d1050000-0000-0000-0000-000000000003' join app_private.route_plan_stops old_plan_stop on old_plan_stop.id=historical_stop.plan_stop_id join app_private.portals p on p.id=old_plan_stop.portal_id;

update management_test set ledger=(select jsonb_agg(to_jsonb(entry) order by entry.id) from app_private.payment_entries entry join app_private.payment_requests p on p.id=entry.request_id where p.registration_id=reg),
 sibling=(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.registration_id='22000000-0000-0000-0000-000000000003'),
 checkpoint=jsonb_build_object('pubs',(select jsonb_agg(to_jsonb(p) order by publication_order) from app_private.group_start_publications p),
 'schedules',(select jsonb_agg(to_jsonb(s) order by s.id) from app_private.group_schedule_revisions s where s.group_id in(source,target)),
 'passport',(select to_jsonb(seal) from app_private.poortenboek_passport_seals seal where seal.child_id=original_child),
 'historicalRun',(select to_jsonb(run) from app_private.group_runs run where run.id='d1050000-0000-0000-0000-000000000001'));
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg);
select ok(jsonb_array_length(coalesce(ledger,'[]'))>0,'paid-child fixture includes actual immutable payment evidence') from management_test;
select ok(not has_function_privilege('anon','api.admin_registration_management_preview(text,uuid)','execute'),'anonymous cannot inspect private registration management');
select ok(not has_function_privilege('anon','api.admin_registration_manage_apply(text,uuid,text,jsonb,text,text,text)','execute'),'anonymous cannot use admin change commands');
select ok(not has_function_privilege('authenticated','app_private.admin_registration_scope_begin(uuid,uuid,uuid[],uuid)','execute'),'authenticated clients cannot manufacture a confirmed-composition exception');
select ok(not has_table_privilege('authenticated','app_private.registration_management_scopes','insert'),'private command scope cannot be forged with table access');
select set_config('app.admin_registration_scope','true',true);
select throws_ok($$update app_private.group_registrations set superseded_at=clock_timestamp() where registration_id=(select reg from management_test) and superseded_at is null$$,'23514','COMPOSITION_REOPEN_REQUIRED','a forged client GUC does not bypass the confirmed composition guard');


savepoint checked_not_published;
insert into app_private.group_start_withdrawals(event_id,group_id,through_publication_order,actor_id,reason)
 select p.event_id,p.group_id,p.publication_order,'f0000000-0000-0000-0000-000000000001','Synthetisch onderscheid tussen intern gecontroleerd en gepubliceerd' from management_test t cross join lateral app_private.current_start_publication(t.target) p;
update app_private.group_schedule_revisions set state='draft' where id=(select (fixture#>>'{target,scheduleId}')::uuid from management_test);
select is((app_private.admin_registration_group_choice(target)->>'compositionConfirmed')::boolean,true,'composition-only confirmation remains separately recognizable') from management_test;
select is((app_private.admin_registration_group_choice(target)->>'startChecked')::boolean,true,'an internally checked unpublished appointment stays recognizable as checked') from management_test;
select is((app_private.admin_registration_group_choice(target)->>'startConfirmed')::boolean,false,'an internally checked unpublished appointment is never presented as a definite participant start') from management_test;
rollback to checked_not_published;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_registration_management_preview('duindorp-halloween-2026',(select reg from management_test))$$,'42501','NOT_AUTHORIZED','being the parent does not grant organizer capability');
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',(select reg from management_test),'move','{"targetGroupId":"23000000-0000-0000-0000-000000000002"}','anything','Niet bevoegd via directe RPC',gen_random_uuid()::text)$$,'42501','NOT_AUTHORIZED','direct unauthorized admin move is rejected');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((preview#>>'{sourceGroup,startConfirmed}')::boolean,true,'preview separates a genuinely confirmed start from composition-only confirmation') from management_test;
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',(select reg from management_test),'edit_children','{}',(select preview->>'inputHash' from management_test),'Ontbrekende kinderen mogen deelname niet verwijderen',gen_random_uuid()::text)$$,'22023','VALIDATION_ERROR','missing children array cannot cancel the entire household');
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',(select reg from management_test),'edit_children','null'::jsonb,(select preview->>'inputHash' from management_test),'Null payload mag geen impliciete annulering zijn',gen_random_uuid()::text)$$,'22023','VALIDATION_ERROR','a JSON null payload is never an empty participation edit');
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',(select reg from management_test),'edit_children','{"children":[]}',(select preview->>'inputHash' from management_test),'Laatste kind synthetisch verwijderen',gen_random_uuid()::text)$$,'23514','LAST_CHILD_REQUIRES_CANCELLATION','last-child removal requires an explicit participation cancellation');
update management_test set payload=jsonb_build_object('children',jsonb_build_array((preview#>'{children,0}')||'{"firstName":"Gecorrigeerde testnaam"}'::jsonb,'{"id":null,"firstName":"Nieuw synthetisch kind","ageAtEvent":8,"accessibilityNote":null}'::jsonb));
select lives_ok($$update management_test set result=api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',payload,preview->>'inputHash','Kind toevoegen en naam corrigeren',key)$$,'organizer can edit and add a child inside a confirmed published group');
select is(api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',payload,preview->>'inputHash','Kind toevoegen en naam corrigeren',key),result,'exact edit retry returns the same durable receipt') from management_test;
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',payload,preview->>'inputHash','Andere wijziging met zelfde sleutel',key) from management_test$$,'23505','IDEMPOTENCY_CONFLICT','same command key cannot authorize a different edit');
reset role;
select is((select count(*)::integer from app_private.registration_children c,management_test t where c.registration_id=t.reg and c.participation_status='active'),2,'added children reserve capacity immediately');
select is((select child_id from app_private.registration_children c,management_test t where c.id=t.original_rc),(select original_child from management_test),'name correction retains stable child and passport identity');
select is((select first_name from app_private.children c,management_test t where c.id=t.original_child),'Gecorrigeerde testnaam','correction updates the existing child profile');
select is((select group_id from app_private.group_registrations a,management_test t where a.registration_id=t.reg and a.superseded_at is null),(select source from management_test),'editing keeps the whole household in its current group');
select is((select price_snapshot_cents from app_private.registrations r,management_test t where r.id=t.reg),(select sum(unit_price_cents)::integer from app_private.registration_children c,management_test t where c.registration_id=t.reg and c.participation_status='active'),'registration amount uses existing price snapshots plus the event price for additions');
select is((select jsonb_agg(to_jsonb(entry) order by entry.id) from app_private.payment_entries entry join app_private.payment_requests p on p.id=entry.request_id,management_test t where p.registration_id=t.reg),(select ledger from management_test),'editing preserves every previously recorded payment entry');
select is((select external_url from app_private.payment_requests p,management_test t where p.registration_id=t.reg order by p.created_at desc limit 1),'https://tikkie.me/pay/synthetic-historical-paid','adding a child preserves the historically paid request URL') ;
select ok(app_private.is_start_confirmation_current((fixture#>>'{source,scheduleId}')::uuid),'child edit keeps the original start confirmation current') from management_test;
select is((select jsonb_agg(to_jsonb(s) order by s.id) from app_private.group_schedule_revisions s,management_test t where s.group_id in(t.source,t.target)),(select checkpoint->'schedules' from management_test),'confirmed and published schedule rows remain byte-for-byte unchanged');
select is((select jsonb_agg(to_jsonb(p) order by publication_order) from app_private.group_start_publications p),(select checkpoint->'pubs' from management_test),'immutable publications are never rewritten by a child edit');
update management_test set added_rc=(select id from app_private.registration_children c where c.registration_id=reg and c.id<>original_rc and c.participation_status='active');
-- Remove a previously paid participant, retaining the stable identity, all
-- financial history and any existing evidence. The added sibling remains active.
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg),key=gen_random_uuid()::text;
update management_test set payload=jsonb_build_object('children',(select jsonb_agg(value) from jsonb_array_elements(preview->'children') where value->>'id'=added_rc::text));
select lives_ok($$update management_test set result=api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',payload,preview->>'inputHash','Deelname betaald kind verwijderen zonder historie te wissen',key)$$,'organizer may remove paid participation without deleting its financial history');
select is((select participation_status from app_private.registration_children c,management_test t where c.id=t.original_rc),'cancelled','removal is a participation cancellation, not an identity deletion');
select ok(exists(select 1 from app_private.children c,management_test t where c.id=t.original_child),'removed child identity remains available for its historical passport and visits');
select is((select to_jsonb(seal) from app_private.poortenboek_passport_seals seal,management_test t where seal.child_id=t.original_child),(select checkpoint->'passport' from management_test),'paid participation removal preserves the actual earlier earned passport seal byte-for-byte');
select is((select jsonb_agg(to_jsonb(entry) order by entry.id) from app_private.payment_entries entry join app_private.payment_requests p on p.id=entry.request_id,management_test t where p.registration_id=t.reg),(select ledger from management_test),'paid child removal retains the exact ledger');
select is((select count(*)::integer from app_private.registration_children c,management_test t where c.registration_id=t.reg and c.participation_status='active'),1,'removed children no longer reserve future participation capacity');
-- A real ordinary visit is held fixed: the physical child limit still applies.
savepoint route_capacity;
insert into app_private.live_route_plans(group_id,event_id,schedule_id) select source,(select event_id from app_private.registrations where id=reg),(fixture#>>'{source,scheduleId}')::uuid from management_test;
insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind)
 select (select event_id from app_private.registrations where id=reg),source,1,'12000000-0000-0000-0000-000000000001',(fixture#>>'{source,startsAt}')::timestamptz+interval '20 minutes',300,0,'ordinary' from management_test;
update app_private.portal_windows set max_children_per_visit=1 where portal_id='12000000-0000-0000-0000-000000000001';
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg);
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',jsonb_build_object('children',(select jsonb_agg(value) from jsonb_array_elements(preview->'children') where value->>'participationStatus'='active')||'[{"id":null,"firstName":"Past niet","ageAtEvent":8}]'::jsonb),preview->>'inputHash','Extra kind mag echte poortlimiet niet overschrijden',gen_random_uuid()::text) from management_test$$,'23514','REGISTRATION_ROUTE_CAPACITY_EXCEEDED','adding children cannot bypass an accepted ordinary house child limit');
rollback to route_capacity;
-- Snapshot every existing other-recipient message before the move.
insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 select 'management-source:'||u.id,'group_composition_confirmed',u.id::text,u.email,jsonb_build_object('groupId',g.id,'compositionRevision',g.composition_revision,'compositionHash',g.composition_confirmed_hash,'groupName',g.system_code,'groupCode',g.system_code,'actionPath','/omgeving/meeloper/groep')
 from management_test t join app_private.walking_groups g on g.id=t.source join auth.users u on u.id in('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001');
insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
 select 'management-target:'||u.id,'group_composition_confirmed',u.id::text,u.email,jsonb_build_object('groupId',g.id,'compositionRevision',g.composition_revision,'compositionHash',g.composition_confirmed_hash,'groupName',g.system_code,'groupCode',g.system_code,'actionPath','/omgeving/meeloper/groep')
 from management_test t join app_private.walking_groups g on g.id=t.target join auth.users u on u.id='a0000000-0000-0000-0000-000000000002';
-- The current majority can legitimately differ from the immutable published
-- snapshot. A supported composition revision anchors that current deadline.
update app_private.registrations set desired_end_at=(select s.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds)-interval '10 minutes' from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id join app_private.event_route_settings settings on settings.event_id=g.event_id where s.id=(select (fixture#>>'{target,scheduleId}')::uuid from management_test)) where id='22000000-0000-0000-0000-000000000002';
update management_test set allmail=(select jsonb_agg(to_jsonb(o) order by o.id) from app_private.email_outbox o where o.recipient_ref<>'a0000000-0000-0000-0000-000000000001'),
 old_hash=(select composition_confirmed_hash from app_private.walking_groups where id=target),old_revision=(select composition_revision from app_private.walking_groups where id=target),
 preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg),key=gen_random_uuid()::text;
select is((preview#>>'{together,otherHouseholds}')::integer,1,'preview makes the related household split visible') from management_test;
-- Physical gathering capacity, not a browser-only group size warning.
savepoint gathering_capacity;
update app_private.start_slots set max_children=5 where id=(select start_slot_id from app_private.group_schedule_revisions where id=(select (fixture#>>'{target,scheduleId}')::uuid from management_test));
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),api.admin_registration_management_preview('duindorp-halloween-2026',reg)->>'inputHash','Doelcapaciteit echt valideren',gen_random_uuid()::text) from management_test$$,'23514','REGISTRATION_PHYSICAL_CAPACITY_OR_TIME_CONFLICT','full target departure/gathering capacity rejects the entire move');
rollback to gathering_capacity;
select lives_ok($$update management_test set result=api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),preview->>'inputHash','Precies dit gezin naar bevestigde doelgroep verplaatsen',key)$$,'one whole household moves between two confirmed published groups');
update management_test set first_result=result;
select is(api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),preview->>'inputHash','Precies dit gezin naar bevestigde doelgroep verplaatsen',key),result,'retry does not create a second assignment or move message') from management_test;
select is((select count(*)::integer from app_private.group_registrations a,management_test t where a.registration_id=t.reg and a.superseded_at is null),1,'one active household group membership after move');
select is((select group_id from app_private.group_registrations a,management_test t where a.registration_id=t.reg and a.superseded_at is null),(select target from management_test),'all active children now inherit the target household assignment');
select is((select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.registration_id='22000000-0000-0000-0000-000000000003'),(select sibling from management_test),'the other household in the old together party never moves');
select isnt((select party_id from app_private.together_memberships m,management_test t where m.registration_id=t.reg and m.left_at is null),(select party_id from app_private.together_memberships where registration_id='22000000-0000-0000-0000-000000000003' and left_at is null),'the moved household receives its own coherent preference party');
select is((select jsonb_agg(to_jsonb(o) order by o.id) from app_private.email_outbox o where o.recipient_ref not in('a0000000-0000-0000-0000-000000000001','registration:22000000-0000-0000-0000-000000000001')),(select allmail from management_test),'every other recipient outbox row remains byte-for-byte unchanged');
select is((select count(*)::integer from app_private.email_outbox where message_type='registration_group_changed'),1,'exactly one targeted household change message is queued');
select is((select recipient_email from app_private.email_outbox where message_type='registration_group_changed'),'parent-a@example.invalid','only the actual moved primary parent receives the change email');
select is((select status from app_private.email_outbox where dedupe_key='management-source:a0000000-0000-0000-0000-000000000001'),'suppressed','old pending source confirmation for the moved parent is suppressed');
select ok(app_private.registration_management_composition_mail_current(target,old_hash,old_revision),'earlier authorized target composition message remains current through the scoped revision') from management_test;
select is((select jsonb_agg(to_jsonb(p) order by publication_order) from app_private.group_start_publications p),(select checkpoint->'pubs' from management_test),'moving a family preserves every immutable start publication');
select is((select jsonb_agg(to_jsonb(s) order by s.id) from app_private.group_schedule_revisions s,management_test t where s.group_id in(t.source,t.target)),(select checkpoint->'schedules' from management_test),'source and target start schedule rows, times and confirmations remain unchanged');
select ok(app_private.is_start_confirmation_current((fixture#>>'{target,scheduleId}')::uuid),'target start remains confirmed for existing and moved families') from management_test;
select ok(app_private.is_start_confirmation_current((fixture#>>'{source,scheduleId}')::uuid),'source start also remains confirmed after the supported composition change') from management_test;
select is(app_private.schedule_latest_finale_arrival((fixture#>>'{target,scheduleId}')::uuid),(select desired_end_at+interval '30 minutes'-make_interval(secs=>(select finale_show_seconds from app_private.event_route_settings where event_id=r.event_id)) from app_private.registrations r where r.id='22000000-0000-0000-0000-000000000002'),'live finale deadline follows the supported new majority instead of the old frozen desired end') from management_test;
select is((select count(*)::integer from app_private.registration_management_scopes),0,'no reusable bypass scope survives the command');
select is(api.worker_registration_management_mail_payload((select id from app_private.email_outbox where message_type='registration_group_changed'))->>'groupCode','G-02','worker resolves the current target group rather than the old family group');
select ok(not(api.worker_registration_management_mail_payload((select id from app_private.email_outbox where message_type='registration_group_changed'))::text like '%FICTIEF GEZINSSTARTADRES%'),'pre-release targeted email does not expose the start address');
-- A later edit reprojects children without invalidating the mandatory move mail.
update management_test set checkpoint=checkpoint||jsonb_build_object('paymentBeforeNameCorrection',(select to_jsonb(p) from app_private.payment_requests p where p.registration_id=reg order by p.created_at desc limit 1));
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg);
select lives_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',jsonb_build_object('children',(select jsonb_agg(value||'{"firstName":"Naam na verhuizing"}'::jsonb) from jsonb_array_elements(preview->'children') where value->>'participationStatus'='active')),preview->>'inputHash','Naamscorrectie na de verplaatsing',gen_random_uuid()::text) from management_test$$,'child correction after a move preserves the move notification generation');
select ok(api.worker_registration_management_mail_payload((select id from app_private.email_outbox where message_type='registration_group_changed')) is not null,'mandatory change email is not silently lost after a child edit');
select is((select to_jsonb(p) from app_private.payment_requests p,management_test t where p.registration_id=t.reg order by p.created_at desc limit 1),(select checkpoint->'paymentBeforeNameCorrection' from management_test),'name-only correction preserves the complete existing payment aggregate byte-for-byte');
select is((api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),'older-preview','Zelfde groep expliciet opnieuw gekozen',gen_random_uuid()::text)->>'changed')::boolean,false,'same-group selection is a no-op even with an older preview') from management_test;
select is((select count(*)::integer from app_private.email_outbox where message_type='registration_group_changed'),1,'same-group no-op never queues or supersedes the existing move mail');
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',source),'stale','Verouderd concept mag geen echte verhuizing uitvoeren',gen_random_uuid()::text) from management_test$$,'40001','STALE_VERSION','stale real move cannot overwrite current membership');
-- A real second move has a new generation and suppresses the outdated first.
select lives_ok($$update management_test set result=api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',source),api.admin_registration_management_preview('duindorp-halloween-2026',reg)->>'inputHash','Tweede echte gerichte gezinsverplaatsing',gen_random_uuid()::text)$$,'a later real second move is its own supported command');
select is((select count(*)::integer from app_private.email_outbox where message_type='registration_group_changed'),2,'two real moves have exactly two historical mail events');
select is((select count(*)::integer from app_private.email_outbox where message_type='registration_group_changed' and status='suppressed'),1,'only the stale earlier pending move confirmation is superseded');
select is(api.worker_registration_management_mail_payload((select id from app_private.email_outbox where message_type='registration_group_changed' and payload->>'commandId'=(select first_result->>'commandId' from management_test))),null::jsonb,'worker cannot send the stale first move after a later move');
-- A prepared list is not a begun journey. Only future roster rows change;
-- additions do not become fictitiously present and removals leave identities.
savepoint prepared_group;
insert into app_private.group_runs(id,group_id,schedule_revision_id,status)
 select 'd1050000-0000-0000-0000-000000000004',source,(fixture#>>'{source,scheduleId}')::uuid,'ready' from management_test;
insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select 'd1050000-0000-0000-0000-000000000004',added_rc,'present' from management_test;
select is(app_private.admin_registration_group_started(source),false,'a prepared run without actual departure or arrival is not a begun group') from management_test;
update management_test set preview=api.admin_registration_management_preview('duindorp-halloween-2026',reg);
select lives_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'edit_children',jsonb_build_object('children',(select jsonb_agg(value) from jsonb_array_elements(preview->'children') where value->>'participationStatus'='active')||'[{"id":null,"firstName":"Voorbereid nieuw kind","ageAtEvent":8}]'::jsonb),preview->>'inputHash','Kind toevoegen aan nog niet gestarte voorbereide lijst',gen_random_uuid()::text) from management_test$$,'child editing remains supported before a prepared group actually starts');
select is((select count(*)::integer from app_private.run_participants where run_id='d1050000-0000-0000-0000-000000000004'),2,'prepared future roster includes the added child under its existing registration');
select is((select count(*)::integer from app_private.run_participants where run_id='d1050000-0000-0000-0000-000000000004' and attendance='present'),1,'the added child is reserved but is not automatically marked actually present');
select lives_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),api.admin_registration_management_preview('duindorp-halloween-2026',reg)->>'inputHash','Hele inschrijving verplaatsen vóór voorbereid vertrek',gen_random_uuid()::text) from management_test$$,'an unstarted prepared roster does not generically block the household move');
select is((select count(*)::integer from app_private.run_participants where run_id='d1050000-0000-0000-0000-000000000004' and attendance='present'),0,'the old prepared group no longer counts moved children as present');
select ok((select started_at is null from app_private.group_runs where id='d1050000-0000-0000-0000-000000000004'),'administrator changes never start the prepared group');
rollback to prepared_group;
savepoint sole_leader;
update app_private.group_leaders set active_until=now() where group_id=(select source from management_test) and active_until is null;
insert into app_private.group_leaders(group_id,user_id,active_from,revision,assigned_by) select source,'a0000000-0000-0000-0000-000000000001',clock_timestamp()-interval '1 minute',2,'f0000000-0000-0000-0000-000000000001' from management_test;
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),api.admin_registration_management_preview('duindorp-halloween-2026',reg)->>'inputHash','Eerst bevoegde vervanger aanwijzen voor de brongroep',gen_random_uuid()::text) from management_test$$,'23514','GROUP_LEADER_REPLACEMENT_REQUIRED','moving a sole source leader requires the existing replacement procedure');
rollback to sole_leader;
-- Started groups keep all live histories and cannot be silently rewritten.
savepoint started_group;
insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at) select source,(fixture#>>'{source,scheduleId}')::uuid,'live',clock_timestamp() from management_test;
select throws_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026',reg,'move',jsonb_build_object('targetGroupId',target),api.admin_registration_management_preview('duindorp-halloween-2026',reg)->>'inputHash','Gestarte groep mag niet stil worden herschreven',gen_random_uuid()::text) from management_test$$,'23514','REGISTRATION_GROUP_ALREADY_STARTED','a begun group requires an explicit supported transfer procedure');
rollback to started_group;
select is((select count(*)::integer from app_private.group_runs run,management_test t where run.group_id in(t.source,t.target)),0,'rejected begun-group scenario leaves both current groups unstarted');
select is((select to_jsonb(run) from app_private.group_runs run where run.id='d1050000-0000-0000-0000-000000000001'),(select checkpoint->'historicalRun' from management_test),'all earlier journey evidence survives edits and both moves unchanged');
select is((select settings->>'groupRegistrationOpen' from app_private.events where slug='duindorp-halloween-2026'),'false','admin edits and moves never reopen public participation');
select * from finish();
rollback;
