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
create temp table participant_parties(name text,id uuid);
insert into participant_parties values('source',pg_temp.fixture_party()),('target',pg_temp.fixture_party());
create temp table participant_regs as select p.name,r.id,r.household_id,r.together_code,m.party_id
from participant_parties p join app_private.together_memberships m on m.party_id=p.id and m.left_at is null
join app_private.registrations r on r.id=m.registration_id;
update app_private.households set primary_contact_user_id='a0000000-0000-0000-0000-000000000001' where id=(select household_id from participant_regs where name='source');
update app_private.household_members set user_id='a0000000-0000-0000-0000-000000000001' where household_id=(select household_id from participant_regs where name='source');
create temp table participant_results(name text,value jsonb);
select ok(not has_function_privilege('anon','api.registration_together_snapshot(uuid)','execute'),'anonymous cannot inspect participant samenloop');
select ok(not has_function_privilege('anon','api.registration_together_request(uuid,text,text)','execute'),'anonymous cannot submit code');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'canRequest','true','household can request after registering');
select throws_ok($$select api.registration_together_snapshot((select id from participant_regs where name='target'))$$,'42501','NOT_AUTHORIZED','another household registration stays private');
select throws_ok($$select api.registration_together_request((select id from participant_regs where name='target'),(select together_code from participant_regs where name='source'),'participant-invalid-owner')$$,'42501','NOT_AUTHORIZED','cannot submit a request for another household');
select throws_ok($$select api.registration_together_request((select id from participant_regs where name='source'),'SL-2026-K7M4PQ','participant-invalid-cluster')$$,'22023','INVALID_TOGETHER_CODE','participant input remains exactly four characters, never a cluster lookup');
select throws_ok($$select api.registration_together_request((select id from participant_regs where name='source'),(select together_code from participant_regs where name='source'),'participant-own-code')$$,'22023','INVALID_TOGETHER_CODE','own party code is rejected');
insert into participant_results values('first',api.registration_together_request((select id from participant_regs where name='source'),(select lower(together_code) from participant_regs where name='target'),'participant-request-one'));
select is((select value->>'status' from participant_results where name='first'),'pending','new code remains pending approval');
select is(api.registration_together_request((select id from participant_regs where name='source'),(select together_code from participant_regs where name='target'),'participant-request-one'),(select value from participant_results where name='first'),'participant submission is idempotent');
select is((select count(*) from app_private.audit_events where action='together.join_requested' and resource_id=(select id from participant_regs where name='source')),1::bigint,'retry emits one request audit');
select is((select count(*) from app_private.together_memberships where party_id=(select party_id from participant_regs where name='source') and left_at is null),1::bigint,'request does not move memberships');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))#>>'{requests,0,status}','pending','participant sees requested status');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))#>>'{requests,0,canWithdraw}','true','requester can withdraw open request');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'canRequest','false','only one outgoing request is offered');
select ok(app_private.can_access_realtime_topic('registration:'||(select id from participant_regs where name='source')::text),'own household can subscribe to its private registration topic');
select ok(not app_private.can_access_realtime_topic('registration:'||(select id from participant_regs where name='target')::text),'participant cannot subscribe to another household');
select ok(not app_private.can_access_realtime_topic('admin-event:'||(select event_id from app_private.registrations where id=(select id from participant_regs where name='source'))::text),'participant receives no admin topic access');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.registration_together_snapshot((select id from participant_regs where name='target'))#>>'{requests,0,direction}','incoming','target household sees incoming request without source identity');
select is(api.registration_together_snapshot((select id from participant_regs where name='target'))#>>'{requests,0,canWithdraw}','false','target cannot withdraw someone else’s request');
select throws_ok($$select api.together_join_request_withdraw(((select value from participant_results where name='first')->>'id')::uuid,1,'Zelf annuleren')$$,'42501','NOT_AUTHORIZED','even an organizer cannot use the participant withdraw endpoint for another household');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.together_join_request_withdraw(((select value from participant_results where name='first')->>'id')::uuid,1,'Zelf annuleren')->>'status','withdrawn','requester can cancel pending request');
select lives_ok($$select api.together_join_request_withdraw(((select value from participant_results where name='first')->>'id')::uuid,1,'Zelf annuleren')$$,'withdrawal retry remains safe');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))#>>'{requests,0,status}','withdrawn','withdrawn status is visible');
select is((select status::text from app_private.registrations where id=(select id from participant_regs where name='source')),'submitted','withdrawing a request never cancels registration');
insert into participant_results values('second',api.registration_together_request((select id from participant_regs where name='source'),(select together_code from participant_regs where name='target'),'participant-request-two'));
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_decide_together_request(((select value from participant_results where name='second')->>'id')::uuid,1,'reject',false,'De aanvraag is niet akkoord')$$,'new request is still decided by organizer');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(exists(select 1 from jsonb_array_elements(api.registration_together_snapshot((select id from participant_regs where name='source'))->'requests') r where r->>'status'='rejected'),'rejected status remains visible');
insert into participant_results values('third',api.registration_together_request((select id from participant_regs where name='source'),(select together_code from participant_regs where name='target'),'participant-request-three'));
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_decide_together_request(((select value from participant_results where name='third')->>'id')::uuid,1,'accept',false,'De aanvraag is nu akkoord')$$,'organizer accepts after participant resubmission');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'confirmed','true','confirmed membership is authoritative after approval');
select matches(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'clusterReference','^SL-2026-[A-HJ-NP-Z2-9]{6}$','participant sees their own confirmed cluster number');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'memberCount','2','participant sees count without household identities');
select ok(exists(select 1 from jsonb_array_elements(api.registration_together_snapshot((select id from participant_regs where name='source'))->'requests') r where r->>'status'='accepted' and r->>'canWithdraw'='false'),'accepted request is visible but not withdrawable');
select throws_ok($$select api.together_join_request_withdraw(((select value from participant_results where name='third')->>'id')::uuid,1,'Zelf annuleren')$$,'40001','STALE_VERSION','concurrent approval prevents pending withdrawal from splitting the cluster');
select ok(strpos(api.registration_together_snapshot((select id from participant_regs where name='source'))::text,(select id::text from participant_regs where name='target'))=0,'snapshot does not disclose the other registration UUID');
select ok(not (api.registration_together_snapshot((select id from participant_regs where name='source')) ?| array['members','children','parentEmail','households','partyId']),'snapshot has no private household or member projection');
update app_private.together_parties set locked_at=now() where id=(select party_id from participant_regs where name='target');
select is(api.registration_together_snapshot((select id from participant_regs where name='source'))->>'canRequest','false','locked cluster cannot submit another request');
select * from finish();
rollback;
