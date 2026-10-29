begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir helpers/joint-route-fixture.inc
-- Exercise the same production validators at the last ten-minute choice and
-- across midnight. Each probe rolls back its synthetic appointments before
-- the fixed-date canonical integration fixture below is constructed.
create function pg_temp.joint_fixture_clock_probe(_starts timestamptz) returns void language plpgsql as $$
declare fixture jsonb; eid uuid; choices jsonb;
begin
 begin
  fixture:=pg_temp.joint_canonical_fixture(_starts);
  select id into eid from app_private.events where slug='duindorp-halloween-2026';
  if (select count(*) from jsonb_each(fixture))<>4 or exists(select 1 from jsonb_each(fixture)g
   where not app_private.departure_time_in_window(eid,(g.value->>'startsAt')::timestamptz)) then
   raise exception 'SYNTHETIC_DEPARTURE_WINDOW_INCOMPLETE';
  end if;
  choices:=app_private.exact_preference_options(eid);
  perform app_private.validate_exact_preferences(eid,(choices#>>'{allowedStartTimes,0}')::timestamptz,
   ((choices->'allowedEndTimes')->>-1)::timestamptz);
  if (select local_date from app_private.events where id=eid)<>((_starts+interval '3 hours') at time zone 'Europe/Amsterdam')::date then
   raise exception 'SYNTHETIC_COMPLETION_DAY_MISMATCH';
  end if;
  raise sqlstate 'ZQ001' using message='Rollback successful synthetic clock probe';
 exception when sqlstate 'ZQ001' then null;
 end;
end $$;
select lives_ok($$select pg_temp.joint_fixture_clock_probe('2032-10-31T23:20:00+01')$$,'four relative appointments include the 23:50 departure and selectable completion-day preferences');
select lives_ok($$select pg_temp.joint_fixture_clock_probe('2032-10-31T23:40:00+01')$$,'four relative appointments crossing midnight retain valid absolute windows and end preferences');
-- Every identity, address and event change is local synthetic transaction data.
create temp table joint_test(fixture jsonb,input jsonb,proposal jsonb,result jsonb,checkpoint jsonb,key text default gen_random_uuid()::text);
insert into joint_test(fixture) select pg_temp.joint_canonical_fixture();

create function pg_temp.joint_preservation() returns jsonb language sql as $$
 select jsonb_build_object('groups',(select jsonb_agg(to_jsonb(g) order by id) from app_private.walking_groups g),
 'schedules',(select jsonb_agg(to_jsonb(s) order by id) from app_private.group_schedule_revisions s),
 'publications',(select jsonb_agg(to_jsonb(p) order by id) from app_private.group_start_publications p),
 'intentions',(select jsonb_agg(to_jsonb(v) order by id) from app_private.live_route_visits v),
 'plans',(select jsonb_agg(to_jsonb(p) order by group_id) from app_private.live_route_plans p),
 'outbox',(select jsonb_agg(to_jsonb(o) order by id) from app_private.email_outbox o),
 'runs',(select jsonb_agg(to_jsonb(r) order by id) from app_private.group_runs r),
 'payments',(select jsonb_agg(to_jsonb(p) order by id) from app_private.payment_requests p))
$$;
select ok(not has_function_privilege('anon','api.admin_joint_route_planning_input(text)','execute'),'anonymous cannot read private planning inputs');
select ok(not has_function_privilege('anon','api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text)','execute'),'anonymous cannot apply a route proposal');
select ok(not has_table_privilege('authenticated','app_private.joint_route_plan_versions','insert'),'a browser cannot manufacture accepted versions');
select is(app_private.joint_route_proposal_hash('source','board','[{"groupId":"g","startsAt":"2026-10-31T17:00:00.000Z","visits":[{"sequence":1,"portalId":"p","kind":"ordinary","startsAt":"2026-10-31T17:01:00.000Z","visitSeconds":360,"bufferSeconds":60}]}]'),
 '9f59bfa75c277978a5851526b0630c271f911831bd5b65d668fc41e5ccee9c0a','Postgres shares the exact TypeScript UTF-8 digest vector');
grant all on joint_test to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated","user_metadata":{"event_admin":true}}',true);
select throws_ok($$select api.admin_joint_route_planning_input('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','participant metadata cannot authorize private planning');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026','{}',true,'Onbevoegde routeopdracht blokkeren',gen_random_uuid()::text)$$,'42501','NOT_AUTHORIZED','direct participant apply is denied');
reset role;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update joint_test set checkpoint=pg_temp.joint_preservation();
update joint_test set input=api.admin_joint_route_planning_input('duindorp-halloween-2026');
select is(pg_temp.joint_preservation(),(select checkpoint from joint_test),'fresh input never seeds, publishes, changes data or queues mail');
select is((select jsonb_array_length(input->'groups') from joint_test),4,'all four stored synthetic start appointments share one planning input');
select is((select input->'diagnostics' from joint_test),'[]'::jsonb,'synthetic start capacities and hard availability are valid');
select ok((select not(input::text like '%FICTIEF STARTPUNT%') and not(input::text like '%@%') and not(input::text like '%accessibility_note%') from joint_test),'input contains no participant email, free notes or private addresses');
select is((select (g->>'ordinaryStopAt')::timestamptz from joint_test,jsonb_array_elements(input->'groups') g where g->>'id'='23000000-0000-0000-0000-000000000001'),
 (select global_ordinary_stop_at from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),'ordinary deadline comes from real hard boundaries rather than a derived transfer cutoff');
update joint_test set proposal=pg_temp.joint_proposal();
select lives_ok($$select app_private.validate_joint_route_proposal(input,proposal->'groups') from joint_test$$,'a jointly spaced complete physical calendar passes independent server validation');

savepoint early;
update joint_test set proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{groups,0,visits,0,startsAt}','"2026-10-31T16:59:59Z"'));
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een seconde te vroeg mag ook via directe API niet',key) from joint_test$$,'23514','PORTAL_EFFECTIVE_WINDOW_CONFLICT','zero early tolerance is enforced through direct apply');
rollback to early;
savepoint too_close;
update joint_test set proposal=pg_temp.joint_rehash(jsonb_set(proposal,'{groups,1,visits,0,startsAt}','"2026-10-31T17:04:59Z"'));
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Vier minuten negenenvijftig is te weinig ontvangstafstand',key) from joint_test$$,'23514','JOINT_ROUTE_ARRIVAL_OR_CAPACITY_CONFLICT','headway +4:59 is rejected even with overlap capacity twenty');
rollback to too_close;
savepoint wrong_hash;
update joint_test set proposal=jsonb_set(proposal,'{proposalHash}','"forged"');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'De client mag een ander voorstel niet onder dezelfde hash opslaan',key) from joint_test$$,'23514','JOINT_ROUTE_HASH_MISMATCH','forged proposal hash cannot authorize a different plan');
rollback to wrong_hash;
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,false,'Expliciete beoordeling en bevestiging ontbreken',key) from joint_test$$,'22023','JOINT_ROUTE_CONFIRMATION_REQUIRED','review confirmation is required');
update joint_test set checkpoint=pg_temp.joint_preservation();
select lives_ok($$update joint_test set result=api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Synthetisch gezamenlijk routevoorstel expliciet beoordelen',key)$$,'valid proposal is atomically accepted without publishing or mail');
select is(api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Synthetisch gezamenlijk routevoorstel expliciet beoordelen',key),result,'same command retry returns the exact durable result') from joint_test;
select is((select count(*)::integer from app_private.joint_route_plan_versions),1,'repeated apply creates one immutable accepted version');
select is((select count(*)::integer from app_private.live_route_visits where retired_at is null and kind='ordinary'),4,'all planned ordinary visits are stored exactly once');
select is((select count(*)::integer from app_private.live_route_visits where retired_at is null and kind='finale'),4,'each group retains exactly its reserved finale');
select ok((select bool_and(app_private.canonical_route_group_current((plan->>'groupId')::uuid)) from joint_test,jsonb_array_elements(proposal->'groups') plan),'stored board and every accepted group plan have the same times');
select is((select jsonb_agg(jsonb_build_object('groupId',plan->>'groupId','sequence',visit->'sequence','seconds',visit->'walkSeconds','meters',visit->'walkMeters') order by plan->>'groupId',(visit->>'sequence')::integer)
 from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'before') plan cross join lateral jsonb_array_elements(plan->'visits') visit where visit->>'kind'<>'start'),
 (select jsonb_agg(jsonb_build_object('groupId',plan->>'groupId','sequence',visit->'sequence','seconds',visit->'walkSeconds','meters',visit->'walkMeters') order by plan->>'groupId',(visit->>'sequence')::integer)
 from joint_test,jsonb_array_elements(proposal->'groups') plan cross join lateral jsonb_array_elements(plan->'visits') visit),
 'fresh baseline carries the same authoritative incoming walks as the accepted physical route');
select is((pg_temp.joint_preservation()->'publications'),(select checkpoint->'publications' from joint_test),'acceptance preserves every confirmed publication');
select is((pg_temp.joint_preservation()->'outbox'),(select checkpoint->'outbox' from joint_test),'acceptance queues no participant messages');
select is((pg_temp.joint_preservation()->'payments'),(select checkpoint->'payments' from joint_test),'acceptance preserves financial state');
select throws_ok($$update app_private.joint_route_plan_versions set reason='Een geaccepteerd voorstel overschrijven mag niet'$$,'23514','ACCEPTED_ROUTE_VERSION_IMMUTABLE','accepted history cannot be overwritten');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal||'{"valid":false}',true,'Andere opdracht mag dezelfde sleutel niet hergebruiken',key) from joint_test$$,'23505','IDEMPOTENCY_CONFLICT','an idempotency key cannot be reused for changed intent');

-- A same-data explicit publication must not immediately invalidate its route.
update joint_test set checkpoint=jsonb_build_object('sourceHash',app_private.joint_route_source_hash((input->>'eventId')::uuid));
select lives_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000003',(select revision from app_private.group_schedule_revisions where id=(app_private.route_group_start_context('23000000-0000-0000-0000-000000000003')->>'scheduleId')::uuid),(select settings_version from app_private.events where slug='duindorp-halloween-2026'))$$,'the existing explicit confirmation flow remains available');
select lives_ok($$update app_private.group_schedule_revisions set state='published',published_at=clock_timestamp() where id=(app_private.route_group_start_context('23000000-0000-0000-0000-000000000003')->>'scheduleId')::uuid$$,'publishing the checked third appointment preserves the accepted physical calendar');
select is(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','draft to published with identical point/time/finale has the same semantic source hash') from joint_test;
select ok(app_private.canonical_route_group_current('23000000-0000-0000-0000-000000000003'),'same-appointment publication keeps its accepted route current');

savepoint alternative_draft;
insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,input_snapshot,created_by)
 select s.group_id,(select max(revision)+1 from app_private.group_schedule_revisions where group_id=s.group_id),'draft',s.start_slot_id,s.effective_ordinary_stop_at,s.expected_finale_arrival_at+interval '5 minutes',s.input_snapshot,'f0000000-0000-0000-0000-000000000001'
 from app_private.group_schedule_revisions s where s.id=(app_private.route_group_start_context('23000000-0000-0000-0000-000000000001')->>'scheduleId')::uuid;
update app_private.walking_groups set current_schedule_revision_id=(select id from app_private.group_schedule_revisions where group_id=walking_groups.id order by revision desc limit 1) where id='23000000-0000-0000-0000-000000000001';
select is((select (g#>>'{finale,reservedAt}')::timestamptz from jsonb_array_elements(api.admin_joint_route_planning_input('duindorp-halloween-2026')->'groups') g where g->>'id'='23000000-0000-0000-0000-000000000001'),
 (select expected_finale_arrival_at from app_private.group_schedule_revisions where id=(select pub.schedule_id from app_private.current_start_publication('23000000-0000-0000-0000-000000000001') pub)),'an alternative draft cannot combine a frozen published start with its different unconfirmed finale');
select is(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','unconfirmed alternative revision does not silently replace the active appointment') from joint_test;
rollback to alternative_draft;

savepoint changed_window;
update app_private.portal_windows set max_concurrent_groups=1 where portal_id='12000000-0000-0000-0000-000000000001';
select isnt(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','actual portal capacity changes invalidate the source hash') from joint_test;
select ok(not app_private.canonical_route_group_current('23000000-0000-0000-0000-000000000001'),'accepted route is visibly stale after a physical capacity change');
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Oud voorstel na capaciteitswijziging blokkeren',gen_random_uuid()::text) from joint_test$$,'40001','JOINT_ROUTE_PROPOSAL_STALE','direct API refuses stale physical settings');
rollback to changed_window;
savepoint changed_policy;
update app_private.portals set arrival_headway_seconds=600 where id='12000000-0000-0000-0000-000000000001';
select isnt(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','per-portal headway changes invalidate route source') from joint_test;
rollback to changed_policy;
savepoint changed_marker;
update app_private.portal_private_locations set marker_latitude=52.109,marker_longitude=4.279 where portal_id='12000000-0000-0000-0000-000000000001';
select isnt(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','stored entrance marker changes invalidate route source') from joint_test;
rollback to changed_marker;
savepoint changed_intention;
update app_private.live_route_visits set starts_at=starts_at+interval '1 minute',version=version+1 where group_id='23000000-0000-0000-0000-000000000001' and sequence=1;
select is(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','editable board rows are separate from static planning requirements') from joint_test;
select ok(not app_private.canonical_route_group_current('23000000-0000-0000-0000-000000000001'),'a changed board time is detected even when its schedule ID is identical');
rollback to changed_intention;

-- Structured admin creation preserves real declarations and does not stale
-- unrelated routes when the new family has not yet been assigned to a group.
create temp table joint_intake as select jsonb_build_object('parentName','Synthetische late ouder','email','joint-structured@example.invalid',
 'preferredStartAt',app_private.exact_preference_options(id)#>'{allowedStartTimes,0}',
 'desiredEndAt',(app_private.exact_preference_options(id)->'allowedEndTimes')->-1,
 'children','[{"name":"Vrije opmerking","age":6,"accessibilityNote":"Synthetische vrije opmerking","stepFreeRequired":false},{"name":"Expliciete behoefte","age":8,"stepFreeRequired":true},{"name":"Nog controleren","age":9,"accessibilityNote":"Synthetisch onbekend","stepFreeRequired":null}]'::jsonb) payload,null::jsonb result from app_private.events where slug='duindorp-halloween-2026';
select throws_ok($$select api.admin_registration_create('duindorp-halloween-2026',jsonb_set(payload,'{children,0,stepFreeRequired}','"true"'),(select settings_version from app_private.events where slug='duindorp-halloween-2026'),gen_random_uuid(),'Een tekst is geen expliciete booleaanse verklaring') from joint_intake$$,'22023','VALIDATION_ERROR','admin cannot smuggle string accessibility flags');
select lives_ok($$update joint_intake set result=api.admin_registration_create('duindorp-halloween-2026',payload,(select settings_version from app_private.events where slug='duindorp-halloween-2026'),gen_random_uuid(),'Drie synthetische kinderen met echte expliciete verklaring')$$,'closed-channel admin intake supports explicit false, true and unreviewed declarations');
select is((select count(*)::integer from app_private.registration_children rc join app_private.children c on c.id=rc.child_id,joint_intake i where rc.registration_id=(i.result->>'registrationId')::uuid and c.step_free_required is true),1,'only the explicitly required child is declared step-free');
select is((select count(*)::integer from app_private.registration_children rc join app_private.children c on c.id=rc.child_id,joint_intake i where rc.registration_id=(i.result->>'registrationId')::uuid and app_private.child_step_free_requirement(c.id) is null),1,'unknown non-empty note remains review-needed');
select is(app_private.joint_route_source_hash((input->>'eventId')::uuid),checkpoint->>'sourceHash','unassigned late intake does not invalidate other families accepted routes') from joint_test;

savepoint begun;
insert into app_private.group_runs(group_id,active_plan_version_id,schedule_revision_id,status,started_at)
 select id,current_plan_version_id,(app_private.route_group_start_context(id)->>'scheduleId')::uuid,'live','2026-10-31T16:00:00Z' from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001';
update joint_test set proposal=pg_temp.joint_rehash(proposal||jsonb_build_object('sourceHash',app_private.joint_route_source_hash((input->>'eventId')::uuid),'boardHash',app_private.live_planboard_hash((input->>'eventId')::uuid)));
select throws_ok($$select api.admin_joint_route_plan_apply('duindorp-halloween-2026',proposal,true,'Een inmiddels begonnen groep nooit automatisch herschrijven',gen_random_uuid()::text) from joint_test$$,'23514','GROUP_ALREADY_STARTED','even refreshed hashes cannot rewrite a started group');
select * from finish();
rollback;
