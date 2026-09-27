begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table family(event_id uuid, household_id uuid, registration_id uuid, child_id uuid);
do $$
declare e uuid := (select id from app_private.events where slug='duindorp-halloween-2026'); h uuid; r uuid; c uuid;
begin
  insert into app_private.households(label, primary_contact_user_id)
    values ('Parent entry test', 'f0000000-0000-0000-0000-000000000001') returning id into h;
  insert into app_private.household_members(household_id,user_id,relation_role)
    values(h,'f0000000-0000-0000-0000-000000000001','owner');
  insert into app_private.registrations(event_id,household_id,status,reference,submitted_at)
    values(e,h,'submitted','DPH-2026-PARENTENTRY',now()) returning id into r;
  for i in 1..2 loop
    insert into app_private.children(household_id,first_name,age_at_event)
      values(h,'Parent entry child '||i,8) returning id into c;
    insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)
      values(e,r,c,250);
    insert into family values(e,h,r,c);
  end loop;
end $$;
create function pg_temp.kid(_n int) returns uuid language sql as $$
  select child_id from family order by child_id offset _n-1 limit 1
$$;
create function pg_temp.open_book(_n int,_token text,_previous text default null,_digest text default null) returns jsonb language sql as $$
  select api.poortenboek_parent_open('f0000000-0000-0000-0000-000000000001',
    'duindorp-halloween-2026',pg_temp.kid(_n),repeat(_token,64),
    case when _previous is not null then repeat(_previous,64) end,
    case when _digest is not null then repeat(_digest,64) end,
    case when _digest is not null then repeat('encrypted',8) end)
$$;

select ok(not has_function_privilege('anon','api.poortenboek_parent_open(uuid,text,uuid,text,text,text,text)','execute'),'anon cannot invoke parent login');
select ok(not has_function_privilege('authenticated','api.poortenboek_parent_open(uuid,text,uuid,text,text,text,text)','execute'),'ordinary clients cannot assert parent identity');
select ok(has_function_privilege('service_role','api.poortenboek_parent_open(uuid,text,uuid,text,text,text,text)','execute'),'verified server can invoke parent login');
select is(pg_temp.open_book(1,'1')->>'needsCode','true','first opening asks server to provision a code');
select is((select count(*) from app_private.poortenboek_sessions s join app_private.poortenboek_codes c on c.id=s.code_id where c.child_id in(select child_id from family)),0::bigint,'provisioning preview creates no session');
create temp table opened as select pg_temp.open_book(1,'1',null,'a') payload;
select is((select payload->>'ok' from opened),'true','owner opens own registered child without code login');
select ok(not (select payload ?| array['code','ciphertext','token','token_hash'] from opened),'no credential in parent login response');
select is((select expires_at-created_at from app_private.poortenboek_sessions where token_hash=repeat('1',64)),interval '12 hours','parent entry uses exactly twelve hours');
select is(api.poortenboek_child_action(repeat('1',64),'snapshot')->>'welcomeRequired','true','parent entry gets its own welcome scene');
select is((select count(*) from app_private.audit_events where actor_id='f0000000-0000-0000-0000-000000000001' and action='poortenboek.parent_login' and resource_id=pg_temp.kid(1)),1::bigint,'opening is audited with the verified parent and child IDs');
select is((select minimal_change from app_private.audit_events where action='poortenboek.parent_login' and resource_id=pg_temp.kid(1)),'{}'::jsonb,'audit has no code, token or personal payload');

select throws_ok($$select api.poortenboek_parent_open('f0000000-0000-0000-0000-000000000002','duindorp-halloween-2026',pg_temp.kid(1),repeat('2',64),repeat('1',64))$$,'42501','NOT_AUTHORIZED','another household cannot open the child');
select throws_ok($$select api.poortenboek_parent_open(null,'duindorp-halloween-2026',pg_temp.kid(1),repeat('2',64))$$,'42501','NOT_AUTHORIZED','missing parent identity rejected');
select throws_ok($$select api.poortenboek_parent_open('f0000000-0000-0000-0000-000000000001','not-this-event',pg_temp.kid(1),repeat('2',64))$$,'42501','NOT_AUTHORIZED','another event cannot be selected');
select throws_ok($$select api.poortenboek_parent_open('f0000000-0000-0000-0000-000000000001','duindorp-halloween-2026',pg_temp.kid(1),'raw-token')$$,'P0001','INVALID_INPUT','raw tokens rejected');
select lives_ok($$select api.poortenboek_child_action(repeat('1',64),'snapshot')$$,'failed selection leaves previous session usable');

select is(pg_temp.open_book(1,'2')->>'ok','true','another device may open the same child');
select lives_ok($$select api.poortenboek_child_action(repeat('1',64),'checklist','{"values":[true,false,false,false,false,false]}')$$,'first child keeps personal progress');
select is(pg_temp.open_book(2,'3','1','b')->>'ok','true','parent switches directly to second child');
select throws_ok($$select api.poortenboek_child_action(repeat('1',64),'snapshot')$$,'42501','CHILD_SESSION_INVALID','switch revokes previous browser child session');
select lives_ok($$select api.poortenboek_child_action(repeat('2',64),'snapshot')$$,'switch leaves another device session intact');
select is(api.poortenboek_child_action(repeat('3',64),'snapshot')->'checklist','[false,false,false,false,false,false]'::jsonb,'second child does not inherit first child progress');
select is(pg_temp.open_book(1,'4','3')->>'ok','true','parent can return to first child');
select is(api.poortenboek_child_action(repeat('4',64),'snapshot')->'checklist','[true,false,false,false,false,false]'::jsonb,'first child progress survives switching');
select is((select count(*) from app_private.poortenboek_codes where child_id in(select child_id from family)),2::bigint,'opening reuses existing codes without renewal');
select is((select code_digest from app_private.poortenboek_codes where child_id=pg_temp.kid(1)),repeat('a',64),'original code stays unchanged');

update app_private.household_members set revoked_at=now() where household_id in(select household_id from family);
select throws_ok($$select pg_temp.open_book(1,'5')$$,'42501','NOT_AUTHORIZED','revoked owner cannot open child');
update app_private.household_members set revoked_at=null where household_id in(select household_id from family);
update app_private.registration_children set participation_status='cancelled' where child_id=pg_temp.kid(1);
select throws_ok($$select pg_temp.open_book(1,'5')$$,'42501','NOT_AUTHORIZED','cancelled child cannot be opened');
update app_private.registration_children set participation_status='active' where child_id=pg_temp.kid(1);
update app_private.registrations set status='cancelled' where id in(select registration_id from family);
select throws_ok($$select pg_temp.open_book(1,'5')$$,'42501','NOT_AUTHORIZED','cancelled registration cannot be opened');
update app_private.registrations set status='submitted' where id in(select registration_id from family);
update app_private.children set archived_at=now() where id=pg_temp.kid(1);
select throws_ok($$select pg_temp.open_book(1,'5')$$,'42501','NOT_AUTHORIZED','archived child cannot be opened');
update app_private.children set archived_at=null where id=pg_temp.kid(1);

select lives_ok($$select api.poortenboek_parent('f0000000-0000-0000-0000-000000000001','duindorp-halloween-2026','renew',pg_temp.kid(1),repeat('c',64),repeat('encrypted',8))$$,'code renewal remains available after parent entry');
select throws_ok($$select api.poortenboek_child_action(repeat('4',64),'snapshot')$$,'42501','CHILD_SESSION_INVALID','code renewal revokes parent-opened session');
select throws_ok($$select api.poortenboek_child_action(repeat('2',64),'snapshot')$$,'42501','CHILD_SESSION_INVALID','code renewal also revokes other devices');
select is(pg_temp.open_book(1,'5')->>'ok','true','owner can open after code renewal');
select lives_ok($$select api.poortenboek_child_action(repeat('5',64),'logout')$$,'parent-opened child session can log out normally');
select throws_ok($$select api.poortenboek_child_action(repeat('5',64),'snapshot')$$,'42501','CHILD_SESSION_INVALID','logout invalidates parent-opened session');

select * from finish();
rollback;
