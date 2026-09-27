begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- Used only by guarded local acceptance scripts, never by a migration or seed.
create function pg_temp.fixture_party(_members integer default 1, _children integer default 1)
returns uuid language plpgsql as $$
declare p uuid := gen_random_uuid(); h uuid; r uuid; c uuid; e uuid := (select id from app_private.events where slug = 'duindorp-halloween-2026');
begin
  for i in 1.._members loop
    insert into app_private.households(label, primary_contact_user_id) values ('Cluster test ' || i, 'f0000000-0000-0000-0000-000000000001') returning id into h;
    insert into app_private.household_members(household_id,user_id,relation_role) values(h,'f0000000-0000-0000-0000-000000000001','owner');
    insert into app_private.registrations(event_id, household_id, status, reference, submitted_at)
      values(e, h, 'submitted', 'DPH-2026-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), now()) returning id into r;
    if i = 1 then insert into app_private.together_parties(id, event_id, public_label, creator_household_id, invite_token_hash, expires_at)
      values(p, e, 'Samenloop', h, extensions.gen_random_bytes(32), now() + interval '1 year'); end if;
    for j in 1.._children loop
      insert into app_private.children(household_id, first_name, age_at_event) values(h, 'Clusterkind ' || j, 8) returning id into c;
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents) values(e, r, c, 250);
    end loop;
    insert into app_private.together_memberships(party_id, registration_id) values(p, r);
  end loop;
  return p;
end;
$$;

create temp table f as select (select id from app_private.events where slug='duindorp-halloween-2026') event_id,
 pg_temp.fixture_party(2,1) team, pg_temp.fixture_party(1,1) outsider;
create temp table kids as select row_number() over(order by m.child_id)::int n,m.* from f,app_private.poortenboek_members(f.event_id,f.team) m;
create function pg_temp.child(_n int) returns uuid language sql as $$select child_id from kids where n=_n$$;
create function pg_temp.actor() returns uuid language sql as $$select 'f0000000-0000-0000-0000-000000000001'::uuid$$;
create function pg_temp.parent(_action text,_n int default 1,_digest text default null) returns jsonb language sql as $$
 select api.poortenboek_parent(pg_temp.actor(),'duindorp-halloween-2026',_action,pg_temp.child(_n),_digest,case when _digest is not null then repeat('encrypted',8) end,'Reset op verzoek van de ouder')$$;
create function pg_temp.action(_n int,_action text default 'snapshot',_payload jsonb default '{}',_key uuid default null) returns jsonb language sql as $$
 select api.poortenboek_child_action(repeat(_n::text,64),_action,_payload,_key)$$;
select is((select count(*) from f,app_private.poortenboek_members(event_id,team)),2::bigint,'confirmed parties derive exactly their children');
create temp table source_run as with inserted as(insert into app_private.group_runs(group_id,active_plan_version_id) select group_id,id from app_private.route_plan_versions limit 1 returning id) select id from inserted;
create temp table source_event as with inserted as(insert into app_private.journey_events(run_id,event_type) select id,'poortenboek.fixture' from source_run returning id) select id from inserted;
select is((select count(*) from source_event),1::bigint,'test uses a real event from an existing route plan');
select lives_ok($$insert into app_private.poortenboek_unlocks(event_id,child_id,source_event_id,kind) select event_id,pg_temp.child(1),source_event.id,'seal' from f,source_event$$,'future seals reference the existing route event journal');
select throws_ok($$insert into app_private.poortenboek_unlocks(event_id,child_id,source_event_id,kind) select event_id,pg_temp.child(1),source_event.id,'seal' from f,source_event$$,'23505',null,'same route event cannot award the same child seal twice');
select throws_ok($$insert into app_private.poortenboek_unlocks(event_id,child_id,source_event_id,kind) select event_id,pg_temp.child(2),-1,'seal' from f$$,'23503',null,'a nonexistent route event cannot award a seal');

select ok(not has_function_privilege('authenticated','api.poortenboek_parent(uuid,text,text,uuid,text,text,text)','execute'),'browser cannot assert another parent actor');
select ok(not has_function_privilege('anon','api.poortenboek_child_action(text,text,jsonb,uuid)','execute'),'anonymous browser cannot access child RPC');
select ok(has_function_privilege('service_role','api.poortenboek_login(text,text,text,text)','execute'),'server may perform login');
select ok(not has_table_privilege('authenticated','app_private.poortenboek_codes','select'),'encrypted codes are not exposed to authenticated clients');
select ok(not has_table_privilege('anon','app_private.poortenboek_sessions','select'),'session hashes are not exposed');
select ok((select bool_and(relrowsecurity) from pg_class join pg_namespace ns on ns.oid=relnamespace where ns.nspname='app_private' and relname like 'poortenboek_%' and relkind='r'),'every child table uses RLS');
select ok((pg_temp.parent('view')->>'needsCode')::boolean,'first targeted view requests server provisioning');
select lives_ok($$select pg_temp.parent('view',1,repeat('a',64))$$,'owner provisions child code');
select lives_ok($$select pg_temp.parent('view',2,repeat('b',64))$$,'second child has own code');
select throws_ok($$select api.poortenboek_parent('f0000000-0000-0000-0000-000000000002','duindorp-halloween-2026','view',pg_temp.child(1))$$,'42501','NOT_AUTHORIZED','unrelated parent cannot read code');
select throws_ok($$select api.poortenboek_parent('f0000000-0000-0000-0000-000000000002','duindorp-halloween-2026','renew',pg_temp.child(1),repeat('c',64),repeat('encrypted',8))$$,'42501','NOT_AUTHORIZED','unrelated parent cannot renew');
select ok(not(api.poortenboek_parent(pg_temp.actor(),'duindorp-halloween-2026','list')::text ~ 'ciphertext|code_digest|encrypted'),'parent lists contain no credentials');
select throws_ok($$insert into app_private.poortenboek_codes(event_id,child_id,code_digest,ciphertext) select event_id,pg_temp.child(2),repeat('a',64),repeat('encrypted',8) from f$$,'23505',null,'digest uniqueness rejects collisions atomically');
select is(api.poortenboek_login(repeat('e',64),repeat('9',64),repeat('f',64),repeat('d',64))->>'ok','false','unknown code never logs in');
select is(api.poortenboek_login(repeat('a',64),repeat('1',64),repeat('f',64),repeat('d',64))->>'ok','true','known code opens independent child session');
select is(api.poortenboek_login(repeat('b',64),repeat('2',64),repeat('f',64),repeat('d',64))->>'ok','true','second child can log in');
select is((select expires_at-created_at from app_private.poortenboek_sessions where token_hash=repeat('1',64)),interval '12 hours','absolute expiry is exactly twelve hours');
create temp table original_expiry as select expires_at from app_private.poortenboek_sessions where token_hash=repeat('1',64);
select is(jsonb_array_length(pg_temp.action(1)->'companions'),2,'snapshot exposes confirmed microteam');
select ok(not(pg_temp.action(1)::text ~ 'household|lastName|email|address|birth|payment|registrationId|childId|token_hash'),'child snapshot has no household private data');
select is(pg_temp.action(1)->>'welcomeRequired','true','new session requires welcome');
select is(pg_temp.action(1,'welcome')->>'welcomeRequired','false','welcome is acknowledged within this session');
select is((select expires_at from app_private.poortenboek_sessions where token_hash=repeat('1',64)),(select expires_at from original_expiry),'activity does not extend expiry');
select is(pg_temp.action(1,'checklist','{"values":[true,true,true,true,true,true]}')->'checklist','[true,true,true,true,true,true]'::jsonb,'personal checklist persists');
select is(pg_temp.action(2)->'checklist','[false,false,false,false,false,false]'::jsonb,'checklist cannot change another child');
select throws_ok($$select pg_temp.action(1,'checklist','{}')$$,'P0001','INVALID_INPUT','missing checklist rejected');
create temp table election as select (app_private.poortenboek_election(event_id,team)).* from f;
create temp table options as select id,row_number() over(order by sort_order,id)::int n from app_private.poortenboek_name_options where event_id=(select event_id from f);
create function pg_temp.vote(_n int,_choices int[],_round text default 'round_one',_key uuid default gen_random_uuid()) returns jsonb language sql as $$
 select pg_temp.action(_n,'vote',jsonb_build_object('electionId',(select id from election),'round',_round,'choices',(select jsonb_agg(id order by rank) from unnest(_choices) with ordinality c(n,rank) join options using(n))),_key)$$;
select throws_ok($$select pg_temp.vote(1,array[1,1,2])$$,'P0001','INVALID_OPTIONS','ranked choices must differ');
select lives_ok($$select pg_temp.vote(1,array[1,2,3],'round_one','11111111-1111-4111-8111-111111111111')$$,'ranked ballot is accepted');
select lives_ok($$select pg_temp.vote(1,array[1,2,3],'round_one','11111111-1111-4111-8111-111111111111')$$,'same command retry is idempotent');
select is((select count(*) from app_private.poortenboek_ballots where election_id=(select id from election)),1::bigint,'retry stores exactly one ballot');
select throws_ok($$select pg_temp.vote(1,array[3,2,1],'round_one','11111111-1111-4111-8111-111111111111')$$,'P0001','IDEMPOTENCY_CONFLICT','same key cannot replace its payload');
select is((select sparks from app_private.poortenboek_scores((select id from election)) where option_id=(select id from options where n=1)),3::bigint,'first choice has three sparks');
select is((select sparks from app_private.poortenboek_scores((select id from election)) where option_id=(select id from options where n=2)),2::bigint,'second choice has two sparks');
select is((select sparks from app_private.poortenboek_scores((select id from election)) where option_id=(select id from options where n=3)),1::bigint,'third choice has one spark');
select is(pg_temp.action(2)#>'{election,ownChoices}','[]'::jsonb,'other child cannot see individual votes');
select lives_ok($$select pg_temp.vote(1,array[2,1,3])$$,'own choice editable while round open');
select lives_ok($$select pg_temp.vote(2,array[1,2,3])$$,'last eligible ballot advances the round');
select is(pg_temp.action(1)#>>'{election,phase}','round_two','all eligible ballots close first round');
select is(jsonb_array_length(pg_temp.action(1)#>'{election,options}'),3,'exactly three finalists');
select throws_ok($$select pg_temp.vote(1,array[1,2,3])$$,'P0001','VOTING_CLOSED','closed first round refuses writes');
select throws_ok($$select pg_temp.vote(1,array[20],'round_two')$$,'P0001','INVALID_OPTIONS','non-finalist cannot receive final vote');
select lives_ok($$select pg_temp.vote(1,array[1],'round_two')$$,'first final ballot');
select lives_ok($$select pg_temp.vote(2,array[2],'round_two')$$,'second final ballot');
select is(pg_temp.action(1)#>>'{election,phase}','finished','final round closes after everyone votes');
select is((select winner_id from app_private.poortenboek_elections where id=(select id from election)),(select id from options where n in(1,2) order by md5((select event_id::text||team::text from f)||id::text) limit 1),'equal final votes and sparks use deterministic event/team tie break');
select is(pg_temp.action(1)#>>'{election,magicTiebreak}','true','tie is disclosed without exposing other votes');
select throws_ok($$update app_private.poortenboek_name_options set label='Changed' where id=(select id from options where n=1)$$,'P0001','OPTION_IN_USE','used labels cannot change');
select throws_ok($$delete from app_private.poortenboek_name_options where id=(select id from options where n=1)$$,'P0001','OPTION_IN_USE','used option cannot disappear');
select throws_ok($$update app_private.poortenboek_name_options set active=false where id=(select id from options where n=1)$$,'P0001','OPTION_IN_USE','used option cannot become invalid');
select lives_ok($$select pg_temp.parent('reset')$$,'owner resets team election before final close');
select ok((pg_temp.action(1)#>>'{election,id}')::uuid<>(select id from election),'reset creates separate generation');
select is((select count(*) from app_private.audit_events where action='poortenboek.election_reset' and resource_id=(select team from f)),1::bigint,'reset audited');
select lives_ok($$select pg_temp.parent('renew',1,repeat('c',64))$$,'renewal replaces code atomically');
select is(api.poortenboek_login(repeat('a',64),repeat('3',64),repeat('f',64),repeat('d',64))->>'ok','false','renewed old code immediately invalid');
select throws_ok($$select pg_temp.action(1)$$,'42501','CHILD_SESSION_INVALID','renewal revokes old session');
select is(api.poortenboek_login(repeat('c',64),repeat('3',64),repeat('f',64),repeat('d',64))->>'ok','true','new code accepted');
select is(pg_temp.action(3)->'checklist','[true,true,true,true,true,true]'::jsonb,'renewal preserves personal progress');
select lives_ok($$select pg_temp.action(3,'logout')$$,'logout revokes own session');
select throws_ok($$select pg_temp.action(3)$$,'42501','CHILD_SESSION_INVALID','logged-out token cannot fetch data');
select lives_ok($$select pg_temp.parent('revoke',2)$$,'owner revokes all sessions');
select throws_ok($$select pg_temp.action(2)$$,'42501','CHILD_SESSION_INVALID','revoked token cannot fetch data');
select is(api.poortenboek_login(repeat('b',64),repeat('4',64),repeat('f',64),repeat('d',64))->>'ok','true','revoke leaves code usable for new login');
update app_private.poortenboek_sessions set created_at=now()-interval '13 hours',expires_at=now()-interval '1 hour' where token_hash=repeat('4',64);
select throws_ok($$select pg_temp.action(4)$$,'42501','CHILD_SESSION_INVALID','expired session cannot be used');
select ok(not exists(select 1 from app_private.audit_events where action like 'poortenboek.%' and minimal_change::text ~ 'encrypted|token_hash|code_digest'),'audits contain no credentials');

-- Administrative group assignments must not expand a child's microteam.
create temp table walking as with inserted as(insert into app_private.walking_groups(event_id,code) select event_id,'PB-TEST' from f returning id) select * from inserted;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
 select walking.id,m.registration_id,1 from walking,f,app_private.together_memberships m where m.party_id in(f.team,f.outsider) and m.left_at is null;
select is((select count(*) from f,app_private.poortenboek_members(event_id,team)),2::bigint,'same walking group never creates companions');
select is((app_private.poortenboek_election((select event_id from f),(select outsider from f))).phase,'direct','single child chooses directly');
create temp table single_election as select (app_private.poortenboek_election(event_id,outsider)).* from f;
insert into app_private.poortenboek_ballots(election_id,child_id,round,choices) select id,eligible_children[1],'direct',array[(select id from options where n=4)] from single_election;
select is((app_private.poortenboek_advance((select id from single_election))).winner_id,(select id from options where n=4),'single ballot directly determines name');

-- A passed deadline with no votes invents no winner; valid first-round votes are a fallback.
update app_private.poortenboek_elections set round_one_deadline=now()-interval '2 hours',round_two_deadline=now()-interval '1 hour' where team_id=(select team from f) and phase<>'superseded';
create temp table expired_election as select id from app_private.poortenboek_elections where team_id=(select team from f) and phase<>'superseded';
select is((app_private.poortenboek_advance((select id from expired_election))).winner_id,null::uuid,'no ballots at deadline leaves name open');
insert into app_private.poortenboek_ballots(election_id,child_id,round,choices) select id,pg_temp.child(1),'round_one',array[(select id from options where n=1),(select id from options where n=2),(select id from options where n=3)] from expired_election;
-- Recompute the finalists as if that valid ballot had arrived before the first deadline.
update app_private.poortenboek_elections set phase='round_one' where id=(select id from expired_election);
select is((app_private.poortenboek_advance((select id from expired_election))).winner_id,(select id from options where n=1),'no final ballots falls back to first-round sparks');
update app_private.poortenboek_settings set round_one_deadline=now()-interval '2 hours',round_two_deadline=now()-interval '1 hour',closes_at=now()+interval '1 hour' where event_id=(select event_id from f);
select lives_ok($$select pg_temp.parent('reset')$$,'reset remains useful between ordinary deadline and final close');
select ok((select round_one_deadline>now() and round_two_deadline<=now()+interval '1 hour' from app_private.poortenboek_elections where team_id=(select team from f) and phase<>'superseded'),'reset reopens finite rounds within final close');
update app_private.poortenboek_settings set round_one_deadline=now()-interval '3 hours',round_two_deadline=now()-interval '2 hours',closes_at=now()-interval '1 hour' where event_id=(select event_id from f);
select throws_ok($$select pg_temp.parent('reset')$$,'P0001','ELECTION_LOCKED','parent cannot reset after final close');

-- Live membership controls every projection; historical election membership gives no access.
update app_private.together_memberships set left_at=now() where registration_id=(select registration_id from kids where n=2) and left_at is null;
select is((select count(*) from f,app_private.poortenboek_members(event_id,team)),1::bigint,'departed household disappears immediately');
select is((app_private.poortenboek_election((select event_id from f),(select team from f))).phase,'direct','membership change supersedes stale election');
select is((select checklist from app_private.poortenboek_progress where child_id=pg_temp.child(1)),array[true,true,true,true,true,true],'membership change preserves personal progress');
update app_private.registration_children set participation_status='cancelled' where child_id=pg_temp.child(1);
select is(api.poortenboek_login(repeat('c',64),repeat('5',64),repeat('f',64),repeat('d',64))->>'ok','false','cancelled participation cannot log in');

-- Repeated guesses consume durable per-code, device and IP budgets without logging input.
select api.poortenboek_login(repeat('8',64),md5(i::text)||md5(i::text),repeat('7',64),repeat('6',64)) from generate_series(1,13) i;
select ok((select blocked_until>now() from app_private.poortenboek_throttles where subject_hash='code:'||repeat('8',64)),'repeated code guesses trigger temporary block');
select is((select attempts from app_private.poortenboek_throttles where subject_hash='device:'||repeat('6',64)),13,'device budget persists across failed attempts');
select is((select attempts from app_private.poortenboek_throttles where subject_hash='ip:'||repeat('7',64)),13,'IP budget persists across failed attempts');

select * from finish();
rollback;
