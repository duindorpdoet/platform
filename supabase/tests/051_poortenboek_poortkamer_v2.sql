begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table v2 as
select e.id event_id,g.id group_id,g.current_plan_version_id plan_id,s.id plan_stop_id,s.portal_id
from app_private.events e
join app_private.walking_groups g on g.event_id=e.id
join app_private.route_plan_stops s on s.plan_version_id=g.current_plan_version_id
where e.slug='duindorp-halloween-2026'
  and g.code='G-02'
  and s.portal_id='12000000-0000-0000-0000-000000000001'
order by g.code,s.position limit 1;
create temp table v2_children as
select rc.id registration_child_id,rc.child_id,gr.registration_id,
  app_private.poortenboek_team(rc.event_id,rc.child_id) team_id,row_number() over(order by rc.child_id)::int n
from v2 join app_private.group_registrations gr on gr.group_id=v2.group_id and gr.superseded_at is null
join app_private.registration_children rc on rc.registration_id=gr.registration_id and rc.participation_status='active';

select ok((select count(*) from v2_children)>1,'fixture route has multiple active children');
select ok(not has_table_privilege('authenticated','app_private.poortenboek_passport_seals','select'),'child seals are not directly exposed');
select ok(not has_table_privilege('authenticated','app_private.portal_presentations','select'),'portal presentations are server projected');
select ok(not has_function_privilege('authenticated','api.portal_v2_command(uuid,text,jsonb,uuid)','execute'),'inner portal V2 command is not client callable');
select ok(has_function_privilege('authenticated','api.portal_room_update(uuid,text,jsonb,uuid)','execute'),'authorized adults use the guarded room contract');

-- The owner can tune access separately, suspend it immediately, and reactivate it.
insert into app_private.portal_owners(portal_id,user_id,role,first_name,last_name)
select portal_id,'a0000000-0000-0000-0000-000000000002','viewer','Tijdelijke','Poortwachter' from v2;
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_team_command((select portal_id from v2),'access','{"userId":"a0000000-0000-0000-0000-000000000002","accessLevel":"manage"}',gen_random_uuid())$$,'owner changes editing access separately from role');
select is((select access_level from app_private.portal_owners where portal_id=(select portal_id from v2) and user_id='a0000000-0000-0000-0000-000000000002'),'manage','separate editing access is persisted');
select lives_ok($$select api.portal_team_command((select portal_id from v2),'suspend','{"userId":"a0000000-0000-0000-0000-000000000002"}',gen_random_uuid())$$,'owner temporarily deactivates a member');
select is(app_private.poortkamer_role((select portal_id from v2),'a0000000-0000-0000-0000-000000000002'),null::text,'suspended member immediately loses authorization');
select ok(exists(select 1 from jsonb_array_elements(api.portal_room_snapshot('duindorp-halloween-2026',(select portal_id from v2))->'team') m where m->>'userId'='a0000000-0000-0000-0000-000000000002' and m->>'suspendedAt' is not null),'owner can see suspended status in team management');
select lives_ok($$select api.portal_team_command((select portal_id from v2),'reactivate','{"userId":"a0000000-0000-0000-0000-000000000002"}',gen_random_uuid())$$,'owner safely reactivates the same membership');
select is(app_private.poortkamer_role((select portal_id from v2),'a0000000-0000-0000-0000-000000000002'),'viewer','reactivated member regains only the existing role');
select is((select string_agg(channel->>'name','|' order by position) from jsonb_array_elements(api.portal_room_snapshot('duindorp-halloween-2026',(select portal_id from v2))->'channels') with ordinality item(channel,position) where channel->>'kind'='community'),'Algemeen|Hulp gevraagd','V2 navigation exposes only the two event-wide Praatkamer channels');

-- A child can change only the identity belonging to its server session.
insert into app_private.poortenboek_codes(event_id,child_id,code_digest,ciphertext)
select v2.event_id,c.child_id,repeat('7',64),repeat('encrypted',8) from v2,v2_children c where c.n=1;
insert into app_private.poortenboek_sessions(code_id,token_hash)
select id,repeat('8',64) from app_private.poortenboek_codes where code_digest=repeat('7',64);
select lives_ok($$select api.poortenboek_child_action(repeat('8',64),'identity','{"avatarId":"moon-knight","lanternShape":"crystal","lanternColor":"violet"}',gen_random_uuid())$$,'child stores a curated identity');
select is((select avatar_id from app_private.poortenboek_child_identity where child_id=(select child_id from v2_children where n=1)),'moon-knight','identity belongs to session child');
select ok(not exists(select 1 from app_private.poortenboek_child_identity where child_id=(select child_id from v2_children where n=2)),'identity action never mutates a companion');
select lives_ok($$select api.poortenboek_child_action(repeat('8',64),'practice','{"heldMs":1400}',gen_random_uuid())$$,'practice gate records completion');
select is((select count(*) from app_private.poortenboek_practice),1::bigint,'practice is stored once');
select lives_ok($$select api.poortenboek_child_action(repeat('8',64),'practice','{"heldMs":1400}',gen_random_uuid())$$,'practice replay stays idempotent');
select is((select count(*) from app_private.poortenboek_practice),1::bigint,'practice replay creates no visit or extra record');
select is((select count(*) from app_private.poortenboek_team_progress),0::bigint,'practice never increments real team progress');

-- Banner results are team-size independent, deterministic and private until complete.
insert into app_private.poortenboek_banner_votes(event_id,team_id,child_id,choices)
select v2.event_id,c.team_id,c.child_id,
  '{"shape":"shield","color":"violet","secondaryColor":"cyan","border":"stars","symbol":"gate","lantern":"crystal","glow":"magic"}'::jsonb
from v2,v2_children c;
select is(app_private.poortenboek_resolve_banner((select event_id from v2),(select team_id from v2_children limit 1))->>'symbol','gate','server resolves complete banner vote');
select is(app_private.poortenboek_resolve_banner((select event_id from v2),(select team_id from v2_children limit 1))->>'symbol','gate','banner resolution is stable on retry');

-- Owner writes a reviewed presentation; only an admin can approve it.
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_room_update((select portal_id from v2),'presentation_submit',
  '{"publicName":"De Gloeiende Testpoort","shortDescription":"Een veilige goedgekeurde testbeschrijving.","story":"Een kort verhaal dat na het bezoek in het persoonlijke boek blijft staan.","symbol":"gate","color":"violet","imagePath":"/images/poortkamer-v2/gate-presentation-hero-wide.webp","accessibility":"De doorgang is vlak en verlicht.","intensity":2}',gen_random_uuid())$$,'portal manager submits an immutable presentation');
select set_config('test.presentation',(select id::text from app_private.portal_presentations where portal_id=(select portal_id from v2) order by version desc limit 1),true);
select lives_ok($$update app_private.portal_presentations set public_name='Onzichtbare wijziging' where id=current_setting('test.presentation')::uuid$$,'submitted content can be revised into a new review attempt before approval');
-- Restore the intended submitted state after the direct fixture edit.
update app_private.portal_presentations set public_name='De Gloeiende Testpoort',status='submitted' where id=current_setting('test.presentation')::uuid;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_portal_v2_command('duindorp-halloween-2026','presentation_approve',current_setting('test.presentation')::uuid,'{}',gen_random_uuid())$$,'authorized organizer approves presentation');
select throws_ok($$update app_private.portal_presentations set public_name='Historie overschreven' where id=current_setting('test.presentation')::uuid$$,'P0001','PRESENTATION_IMMUTABLE','approved presentation content is immutable');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.portal_room_update((select portal_id from v2),'presentation_activate',jsonb_build_object('presentationId',current_setting('test.presentation')),gen_random_uuid())$$,'portal owner activates only the approved version');
select lives_ok($$select api.portal_room_update((select portal_id from v2),'presentation_submit',
  '{"publicName":"Af te wijzen testpoort","shortDescription":"Deze tweede testversie gaat door de afwijzingsflow.","story":"Een tweede testverhaal voor de expliciete afwijzingsroute.","symbol":"moon","color":"cyan","accessibility":"Geen extra informatie opgegeven","intensity":2}',gen_random_uuid())$$,'owner can submit a later review version');
select set_config('test.rejected',(select id::text from app_private.portal_presentations where portal_id=(select portal_id from v2) and status='submitted' order by version desc limit 1),true);
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_portal_v2_command('duindorp-halloween-2026','presentation_reject',current_setting('test.rejected')::uuid,'{"note":"Onveilige inhoud voor jonge bezoekers."}',gen_random_uuid())$$,'organizer can explicitly reject unsafe presentation content');
select is((select status from app_private.portal_presentations where id=current_setting('test.rejected')::uuid),'rejected','rejected content can never become active');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- Complete one authoritative existing route stop. The trigger awards each
-- present visited child one immutable seal and counts the team once.
create temp table v2_run as with inserted as (
  insert into app_private.group_runs(group_id,active_plan_version_id,status,started_at)
    select group_id,plan_id,'live',now() from v2 returning id
) select id from inserted;
insert into app_private.run_participants(run_id,registration_child_id)
select v2_run.id,c.registration_child_id from v2_run,v2_children c;
create temp table v2_stop as with inserted as (
  insert into app_private.run_stops(run_id,plan_stop_id,sequence,state,opened_at)
    select v2_run.id,v2.plan_stop_id,1,'active',now() from v2_run,v2 returning id
) select id from inserted;
insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id,status,decided_at)
select v2_stop.id,p.id,'visited',now() from v2_stop,app_private.run_participants p where p.run_id=(select id from v2_run);
update app_private.run_stops set state='completed',outcome='visited',completed_at=now() where id=(select id from v2_stop);
select is((select count(*) from app_private.poortenboek_passport_seals where run_stop_id=(select id from v2_stop)),(select count(*) from v2_children),'one seal per active visited child');
select is((select count(*) from app_private.poortenboek_team_progress where run_stop_id=(select id from v2_stop)),1::bigint,'team progress counts the visit exactly once');
select is((select count(*) from app_private.poortenboek_story_chapters where chapter=2 and child_id in(select child_id from v2_children)),(select count(*) from v2_children),'first visit unlocks chapter two once per child');
select is((select presentation_id from app_private.poortenboek_passport_seals limit 1),current_setting('test.presentation')::uuid,'seal pins the active approved presentation version');
select ok((select presentation_snapshot::text !~* 'street|address|email|phone|contact' from app_private.poortenboek_passport_seals limit 1),'passport snapshot contains no address or contact data');
select throws_ok($$insert into app_private.poortenboek_passport_seals select * from app_private.poortenboek_passport_seals limit 1$$,'23505',null,'duplicate authoritative event cannot create a second child seal');

-- Incidents have no medical categories; simulation is explicitly isolated and removable.
select throws_ok($$insert into app_private.portal_incidents(event_id,portal_id,category,description,created_by) select event_id,portal_id,'medical','Medische categorie bestaat niet','e0000000-0000-0000-0000-000000000001' from v2$$,'23514',null,'medical incident category is impossible');
select lives_ok($$select api.portal_room_update((select portal_id from v2),'incident_create','{"category":"technical","urgency":"high","description":"De lichtcontroller is onverwacht uitgevallen.","callbackRequested":true}',gen_random_uuid())$$,'adult team reports a non-medical incident');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_room_snapshot('duindorp-halloween-2026')->'incidents') i where i->>'urgency'='high'),'incident appears in organizer cockpit snapshot');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.real_seals',(select count(*)::text from app_private.poortenboek_passport_seals),true);
select set_config('test.sim',(api.portal_room_update((select portal_id from v2),'simulation_start','{}',gen_random_uuid())->>'id'),true);
select lives_ok($$select api.portal_room_update((select portal_id from v2),'simulation_step',jsonb_build_object('simulationRunId',current_setting('test.sim'),'phase','seal'),gen_random_uuid())$$,'simulation can exercise a seal phase');
select is((select count(*)::text from app_private.poortenboek_passport_seals),current_setting('test.real_seals'),'simulation never writes a real seal');
select lives_ok($$select api.portal_room_update((select portal_id from v2),'simulation_reset',jsonb_build_object('simulationRunId',current_setting('test.sim')),gen_random_uuid())$$,'simulation reset removes only marked simulation data');
select ok(not exists(select 1 from app_private.portal_simulation_runs where id=current_setting('test.sim')::uuid),'simulation run was deleted');
select is((select count(*)::text from app_private.poortenboek_passport_seals),current_setting('test.real_seals'),'simulation reset preserves real visit results');

select * from finish();
rollback;
