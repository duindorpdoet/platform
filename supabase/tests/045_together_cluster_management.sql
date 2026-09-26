begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Transaction-local synthetic registrations; no shared fixture is changed permanently.
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
create function pg_temp.preview(_s uuid, _t uuid) returns jsonb language sql as $$
  select api.admin_together_merge_preview('duindorp-halloween-2026', _s, _t)
$$;
create function pg_temp.merge(_p jsonb, _key text default gen_random_uuid()::text) returns jsonb language sql as $$
  select api.admin_merge_together_parties('duindorp-halloween-2026', (_p #>> '{source,partyId}')::uuid,
    (_p #>> '{target,partyId}')::uuid, _p #>> '{source,stateToken}', _p #>> '{target,stateToken}', 'Handmatig gekoppeld na verzoek per e-mail', _key)
$$;
create temp table fixture(name text primary key, id uuid);
insert into fixture values ('single', pg_temp.fixture_party()), ('cluster', pg_temp.fixture_party(2)),
  ('other', pg_temp.fixture_party()), ('cluster2', pg_temp.fixture_party(2)), ('large', pg_temp.fixture_party(2, 10));
create temp table states(name text primary key, value jsonb);
create temp table memberships_before as select * from app_private.together_memberships;
create temp table registrations_before as select id, reference, together_code from app_private.registrations;
create temp table assignments_before as select * from app_private.group_registrations;

select is(app_private.ensure_together_party_cluster_reference((select id from fixture where name='single')), null::text, 'single active member does not acquire a cluster identity');
select matches((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='cluster')),
  '^SL-2026-[A-HJ-NP-Z2-9]{6}$', 'two submitted members automatically acquire a safe event-year reference');
select is(app_private.ensure_together_party_cluster_reference((select id from fixture where name='cluster')),
  (select cluster_reference from app_private.together_parties where id=(select id from fixture where name='cluster')), 'generator is idempotent');
select is((select count(*) from app_private.together_parties where cluster_reference is not null),
  (select count(distinct (event_id, cluster_reference)) from app_private.together_parties where cluster_reference is not null), 'references are unique within each event');
select throws_ok($$update app_private.together_parties set cluster_reference='SL-2026-ZZZZZZ' where id=(select id from fixture where name='cluster')$$,
  '23514','CLUSTER_REFERENCE_IMMUTABLE','an assigned reference cannot be replaced');
select throws_ok($$update app_private.together_parties set cluster_reference=null where id=(select id from fixture where name='cluster')$$,
  '23514','CLUSTER_REFERENCE_IMMUTABLE','an assigned reference cannot be cleared');
select throws_ok($$delete from app_private.together_parties where id=(select id from fixture where name='cluster')$$,
  '23514','CLUSTER_REFERENCE_IMMUTABLE','historical references cannot be deleted and recycled');
select throws_ok($$update app_private.together_parties set cluster_reference='' where id=(select id from fixture where name='single')$$,
  '23514',null,'empty references are invalid');
select throws_ok($$update app_private.together_parties set cluster_reference='SL-2026-IO01AA' where id=(select id from fixture where name='single')$$,
  '23514',null,'ambiguous characters are invalid');
select results_eq('select * from memberships_before order by id','select * from app_private.together_memberships order by id','ensuring identities never changes memberships');
select results_eq('select * from registrations_before order by id','select id, reference, together_code from app_private.registrations order by id','individual references and four-character codes remain unchanged');
select results_eq('select * from assignments_before order by id','select * from app_private.group_registrations order by id','identity generation never changes walking assignments');

-- Backfill an actual pre-feature party: suppress automatic generation while setting up old data.
alter table app_private.together_memberships disable trigger together_memberships_changed;
insert into fixture values ('backfill', pg_temp.fixture_party(2));
alter table app_private.together_memberships enable trigger together_memberships_changed;
create temp table backfill_before as select * from app_private.together_memberships where party_id=(select id from fixture where name='backfill');
select is((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='backfill')),null::text,'historical fixture has no cluster reference');
select matches(app_private.ensure_together_party_cluster_reference((select id from fixture where name='backfill')),'^SL-2026-[A-HJ-NP-Z2-9]{6}$','backfill repairs an existing two-member party');
select results_eq('select * from backfill_before order by id', $$select * from app_private.together_memberships where party_id=(select id from fixture where name='backfill') order by id$$,'backfill preserves membership ids and timestamps');

select ok(not has_function_privilege('anon','api.admin_together_management_snapshot(text,text,integer,integer)','execute'),'anonymous clients cannot read organizer snapshot');
select ok(not has_function_privilege('anon','api.admin_together_resolve_identifier(text,text)','execute'),'anonymous clients cannot resolve identities');
select ok(not has_function_privilege('anon','api.admin_merge_together_parties(text,uuid,uuid,text,text,text,text)','execute'),'anonymous clients cannot merge');
select ok(not has_function_privilege('authenticated','app_private.ensure_together_party_cluster_reference(uuid)','execute'),'authenticated clients cannot execute generator');
select ok(not has_function_privilege('authenticated','app_private.together_management_parties(uuid)','execute'),'private projection cannot be called directly');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_together_management_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','participant cannot read other households');
select throws_ok($$select api.admin_together_resolve_identifier('duindorp-halloween-2026',(select cluster_reference from app_private.together_parties where id=(select id from fixture where name='cluster')))$$,'42501','NOT_AUTHORIZED','knowledge of an SL code does not grant participant access');
select throws_ok($$select pg_temp.preview((select id from fixture where name='single'),(select id from fixture where name='other'))$$,'42501','NOT_AUTHORIZED','participant cannot preview private data');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.admin_together_resolve_identifier('duindorp-halloween-2026','  '||(select lower(cluster_reference) from app_private.together_parties where id=(select id from fixture where name='cluster'))||' ') ->> 'kind','cluster','resolver normalizes cluster identifier');
select is(api.admin_together_resolve_identifier('duindorp-halloween-2026',(select r.reference from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id where m.party_id=(select id from fixture where name='single') and m.left_at is null)) ->> 'partyId',(select id::text from fixture where name='single'),'DPH resolver returns authoritative party');
select is(api.admin_together_resolve_identifier('duindorp-halloween-2026',(select r.together_code from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id where m.party_id=(select id from fixture where name='single') and m.left_at is null)) ->> 'kind','together_code','four-character resolver remains supported');
select is(jsonb_array_length(api.admin_together_management_snapshot('duindorp-halloween-2026',(select cluster_reference from app_private.together_parties where id=(select id from fixture where name='cluster'))) -> 'confirmed'),1,'search matches cluster reference');
select is(jsonb_array_length(api.admin_together_management_snapshot('duindorp-halloween-2026',(select r.reference from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id where m.party_id=(select id from fixture where name='cluster') limit 1)) #> '{confirmed,0,members}'),2,'search for one registration returns complete cluster');
select is(jsonb_array_length(api.admin_together_management_snapshot('duindorp-halloween-2026','',1) -> 'confirmed'),1,'snapshot respects bounded page size');

insert into states values ('twoSingles', pg_temp.preview((select id from fixture where name='single'),(select id from fixture where name='other')));
select is((select value ->> 'canMerge' from states where name='twoSingles'),'true','two unassigned singles may merge');
insert into states values ('result',pg_temp.merge((select value from states where name='twoSingles'),'same-retry-command'));
select matches((select value ->> 'clusterReference' from states where name='result'),'^SL-2026-[A-HJ-NP-Z2-9]{6}$','manual two-single merge creates reference');
select is(pg_temp.merge((select value from states where name='twoSingles'),'same-retry-command'),(select value from states where name='result'),'retry returns identical saved result');
select is((select count(*) from app_private.audit_events where action='together.admin_merged' and resource_id=(select id from fixture where name='other')),1::bigint,'idempotent retry writes exactly one audit');
select is((select count(*) from app_private.together_memberships where party_id=(select id from fixture where name='other') and left_at is null),2::bigint,'two singles become one confirmed party');
select ok((select locked_at is not null from app_private.together_parties where id=(select id from fixture where name='single')),'source is historically locked');
select is(app_private.ensure_together_party_cluster_reference((select id from fixture where name='single')),null::text,'empty historical singleton never gets a usable reference');
select throws_ok($$select api.admin_merge_together_parties('duindorp-halloween-2026',(select id from fixture where name='single'),(select id from fixture where name='other'),'different','different','A different reason for retry','same-retry-command')$$,'22023','IDEMPOTENCY_CONFLICT','reusing a command key with different arguments fails');
insert into fixture values('third',pg_temp.fixture_party());
insert into states values('singleCluster',pg_temp.preview((select id from fixture where name='third'),(select id from fixture where name='other')));
select is(pg_temp.merge((select value from states where name='singleCluster')) ->> 'clusterReference',(select value ->> 'clusterReference' from states where name='result'),'single plus cluster preserves target reference');
insert into states values('clusterCluster',pg_temp.preview((select id from fixture where name='cluster'),(select id from fixture where name='other')));
insert into states values('sourceIdentity',(select to_jsonb(cluster_reference) from app_private.together_parties where id=(select id from fixture where name='cluster')));
select is(pg_temp.merge((select value from states where name='clusterCluster')) ->> 'clusterReference',(select value ->> 'clusterReference' from states where name='result'),'cluster plus cluster preserves target reference');
select is((select to_jsonb(cluster_reference) from app_private.together_parties where id=(select id from fixture where name='cluster')),(select value from states where name='sourceIdentity'),'historical source retains its identity');
select is((select count(*) from app_private.together_memberships where party_id=(select id from fixture where name='other') and left_at is null),5::bigint,'all source cluster memberships move atomically');
select results_eq('select * from assignments_before order by id','select * from app_private.group_registrations order by id','manual merges never silently move walking assignments');
select ok((pg_temp.preview((select id from fixture where name='other'),(select id from fixture where name='other')) -> 'blockers') ? 'same_party','same party is blocked');
select ok((pg_temp.preview((select id from fixture where name='large'),(select id from fixture where name='other')) -> 'blockers') ? 'over_capacity','projected size above current limit is blocked');
select throws_ok($$select pg_temp.merge(pg_temp.preview((select id from fixture where name='large'),(select id from fixture where name='other')))$$,'23514','MERGE_BLOCKED','capacity is enforced server-side');
update app_private.together_parties set locked_at=now() where id=(select id from fixture where name='cluster2');
select ok((pg_temp.preview((select id from fixture where name='cluster2'),(select id from fixture where name='other')) -> 'blockers') ? 'locked','locked source is blocked');
select ok((pg_temp.preview((select id from fixture where name='other'),(select id from fixture where name='cluster2')) -> 'blockers') ? 'locked','locked target is blocked');

insert into fixture values('staleSource',pg_temp.fixture_party()),('staleTarget',pg_temp.fixture_party());
insert into states values('stale',pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget')));
update app_private.registrations set preferred_start_at='2026-10-31 18:00:00+01' where id in(select registration_id from app_private.together_memberships where party_id=(select id from fixture where name='staleSource'));
select throws_ok($$select pg_temp.merge((select value from states where name='stale'))$$,'40001','STALE_VERSION','changed preview state cannot be silently accepted');
select throws_ok($$select api.admin_merge_together_parties('duindorp-halloween-2026',(select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget'),'state','state','short','reason-validation-key')$$,'22023','VALIDATION_ERROR','reason must have 10 to 500 characters');

insert into fixture values('groupA',(api.admin_group_create('duindorp-halloween-2026','Cluster tests A')->>'id')::uuid),('groupB',(api.admin_group_create('duindorp-halloween-2026','Cluster tests B')->>'id')::uuid);
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
select (select id from fixture where name='groupA'),registration_id,1 from app_private.together_memberships where party_id=(select id from fixture where name='staleSource') and left_at is null;
select ok((pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget'))->'blockers') ? 'different_groups','one assigned and one unassigned is blocked');
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
select (select id from fixture where name='groupB'),registration_id,1 from app_private.together_memberships where party_id=(select id from fixture where name='staleTarget') and left_at is null;
select ok((pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget'))->'blockers') ? 'different_groups','different walking groups are blocked');
select throws_ok($$select pg_temp.merge(pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget')))$$,'23514','MERGE_BLOCKED','group conflict is enforced in mutation');
update app_private.group_registrations set group_id=(select id from fixture where name='groupA') where group_id=(select id from fixture where name='groupB');
select is(pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget'))->>'canMerge','true','same draft walking group is allowed');
update app_private.group_registrations set published_at=now() where group_id=(select id from fixture where name='groupA');
select ok((pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget'))->'blockers') ? 'published','published assignment is blocked');
select throws_ok($$select pg_temp.merge(pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget')))$$,'23514','MERGE_BLOCKED','published state enforced in mutation');
update app_private.group_registrations set published_at=null where group_id=(select id from fixture where name='groupA');
select lives_ok($$select pg_temp.merge(pg_temp.preview((select id from fixture where name='staleSource'),(select id from fixture where name='staleTarget')))$$,'same draft group merge succeeds');

-- Existing accept/reject contracts keep approval required and preserve retry identity.
insert into fixture values('joinSource',pg_temp.fixture_party()),('joinTarget',pg_temp.fixture_party()),('rejectSource',pg_temp.fixture_party());
insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,requested_code,child_count_at_request,group_limit_at_request)
select p.event_id,s.id,t.id,m.registration_id,r.together_code,1,10
from fixture s cross join fixture t join app_private.together_parties p on p.id=t.id
join app_private.together_memberships m on m.party_id=s.id and m.left_at is null
join app_private.together_memberships tm on tm.party_id=t.id and tm.left_at is null
join app_private.registrations r on r.id=tm.registration_id
where s.name in('joinSource','rejectSource') and t.name='joinTarget';
select is((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='joinTarget')),null::text,'pending requests do not create a confirmed cluster');
select is(api.admin_decide_together_request((select id from app_private.together_join_requests where source_party_id=(select id from fixture where name='rejectSource')),1,'reject',false,'De aanvraag is niet akkoord')->>'status','rejected','reject remains a separate decision');
select is((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='joinTarget')),null::text,'rejection does not create a reference');
select is(api.admin_decide_together_request((select id from app_private.together_join_requests where source_party_id=(select id from fixture where name='joinSource')),1,'accept',false,'De aanvraag is wel akkoord')->>'status','accepted','accepted join preserves approval semantics');
insert into states values('acceptedReference',(select to_jsonb(cluster_reference) from app_private.together_parties where id=(select id from fixture where name='joinTarget')));
select lives_ok($$select api.admin_decide_together_request((select id from app_private.together_join_requests where source_party_id=(select id from fixture where name='joinSource')),1,'accept',false,'De aanvraag is wel akkoord')$$,'accepted request retry succeeds');
select is((select to_jsonb(cluster_reference) from app_private.together_parties where id=(select id from fixture where name='joinTarget')),(select value from states where name='acceptedReference'),'accept retry preserves generated identity');
select matches((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='joinTarget')),'^SL-2026-[A-HJ-NP-Z2-9]{6}$','accepted request creates cluster reference');
select ok(exists(select 1 from app_private.email_outbox where message_type='group_merge_approved' and payload->>'clusterReference'=(select cluster_reference from app_private.together_parties where id=(select id from fixture where name='joinTarget'))),'accepted mail contains safe cluster number');

-- Whole-party movement still uses exactly one representative registration.
select lives_ok($$select api.admin_group_move_registration('duindorp-halloween-2026',(select registration_id from app_private.together_memberships where party_id=(select id from fixture where name='other') and left_at is null order by registration_id limit 1),(select id from fixture where name='groupB'))$$,'one move call moves a whole five-registration cluster');
select is((select count(distinct a.group_id) from app_private.group_registrations a join app_private.together_memberships m on m.registration_id=a.registration_id and m.left_at is null where m.party_id=(select id from fixture where name='other') and a.superseded_at is null),1::bigint,'all cluster members share a walking group after one RPC');
select ok(exists(select 1 from jsonb_array_elements(api.admin_group_composition_snapshot('duindorp-halloween-2026')->'groups') g cross join lateral jsonb_array_elements(g->'registrations') r where r->>'clusterReference'=(select value->>'clusterReference' from states where name='result')),'group board snapshot exposes cluster identity');
select ok(exists(select 1 from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) r where r->>'clusterReference'=(select value->>'clusterReference' from states where name='result') and r->>'partyId'=(select id::text from fixture where name='other')),'roster exposes party and cluster identity');

-- Event boundaries and capability-scoped resolver access.
insert into app_private.events(slug,title,local_date,price_cents) values('together-other-event','Other event','2027-10-31',250);
insert into fixture values('foreignParty',pg_temp.fixture_party());
update app_private.together_parties set event_id=(select id from app_private.events where slug='together-other-event') where id=(select id from fixture where name='foreignParty');
select throws_ok($$select pg_temp.preview((select id from fixture where name='foreignParty'),(select id from fixture where name='other'))$$,'P0002','PARTY_NOT_FOUND','party from another event cannot be a mutation target');
select throws_ok($$select api.admin_together_resolve_identifier('together-other-event',(select cluster_reference from app_private.together_parties where id=(select id from fixture where name='other')))$$,'42501','NOT_AUTHORIZED','resolver cannot cross event authorization');
insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
select id,'a0000000-0000-0000-0000-000000000001','registration_manage','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_together_management_snapshot('duindorp-halloween-2026')$$,'registration managers can read samenloop overview');
select ok(app_private.can_access_realtime_topic('admin-event:'||(select id from app_private.events where slug='duindorp-halloween-2026')::text),'registration managers can subscribe to organizer refresh');
update app_private.event_capabilities set capability='groups_manage' where user_id='a0000000-0000-0000-0000-000000000001' and capability='registration_manage';
select lives_ok($$select api.admin_together_resolve_identifier('duindorp-halloween-2026',(select cluster_reference from app_private.together_parties where id=(select id from fixture where name='other')))$$,'group managers can resolve cluster identities');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- Signals are derived server-side; displaying a problem never repairs data.
insert into fixture values('cancelledMember',pg_temp.fixture_party(2));
update app_private.registrations set status='cancelled' where id=(select registration_id from app_private.together_memberships where party_id=(select id from fixture where name='cancelledMember') limit 1);
select ok(exists(select 1 from jsonb_array_elements(api.admin_together_management_snapshot('duindorp-halloween-2026')->'problems') p where p->>'partyId'=(select id::text from fixture where name='cancelledMember') and p->'problems' ? 'inactive_registration'),'cancelled registration membership is reported');
select throws_ok($$select pg_temp.merge(pg_temp.preview((select id from fixture where name='cancelledMember'),(select id from fixture where name='other')))$$,'23514','MERGE_BLOCKED','inactive members cannot be manually merged');
select throws_ok($$insert into app_private.together_memberships(party_id,registration_id) select (select id from fixture where name='other'),registration_id from app_private.together_memberships where party_id=(select id from fixture where name='cancelledMember') and left_at is null limit 1$$,'23505',null,'unique constraint prevents multiple active memberships');

-- Simulate a collision, then exhaustion. Both leave existing identities intact.
-- Inject a deterministic byte source into the private helper, then restore its exact definition.
create temp table original_random as select pg_get_functiondef('app_private.ensure_together_party_cluster_reference(uuid)'::regprocedure) definition;
alter table app_private.together_memberships disable trigger together_memberships_changed;
insert into fixture values('collision',pg_temp.fixture_party(2)),('collisionReserved',pg_temp.fixture_party()),('exhaustion',pg_temp.fixture_party(2));
alter table app_private.together_memberships enable trigger together_memberships_changed;
update app_private.together_parties set cluster_reference='SL-2026-AAAAAA' where id=(select id from fixture where name='collisionReserved');
create sequence pg_temp.random_calls;
create or replace function pg_temp.fixture_random_bytes(integer) returns bytea language plpgsql volatile as $$
begin return decode(case when nextval('pg_temp.random_calls')=1 then '000000000000' else '010101010101' end,'hex'); end;
$$;
do $$begin execute replace((select definition from original_random), 'extensions.gen_random_bytes(6)', 'pg_temp.fixture_random_bytes(6)'); end;$$;
select is(app_private.ensure_together_party_cluster_reference((select id from fixture where name='collision')),'SL-2026-BBBBBB','generator retries a collision and keeps the reserved reference');
create or replace function pg_temp.fixture_random_bytes(integer) returns bytea language sql volatile as $$select decode('000000000000','hex')$$;
select throws_ok($$select app_private.ensure_together_party_cluster_reference((select id from fixture where name='exhaustion'))$$,'54000','CLUSTER_REFERENCE_EXHAUSTED','exhausted retries fail safely rather than recycling');
select is((select cluster_reference from app_private.together_parties where id=(select id from fixture where name='exhaustion')),null::text,'failed generator leaves party unchanged');
do $$begin execute (select definition from original_random); end;$$;

select * from finish();
rollback;
