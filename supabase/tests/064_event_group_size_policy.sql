begin;
create extension if not exists pgtap with schema extensions;
select plan(27);
create temp table size_values(key text primary key,value jsonb) on commit drop;
grant select,insert,update on size_values to authenticated;
create function pg_temp.save_size(_maximum integer,_target integer default null) returns jsonb language plpgsql as $$
declare p jsonb;
begin
 p:=api.admin_group_size_policy_preview('duindorp-halloween-2026',_maximum,_target);
 return api.admin_group_size_policy_save('duindorp-halloween-2026',_maximum,_target,
  (p->>'settingsVersion')::integer,p->>'impactHash','Groepsbeleid bewust gecontroleerd en gewijzigd');
end $$;
create function pg_temp.size_fixture(_children integer) returns uuid language plpgsql as $$
declare eventid uuid; household uuid:=gen_random_uuid();registration uuid:=gen_random_uuid();child uuid; groupid uuid;
begin
 select id into eventid from app_private.events where slug='duindorp-halloween-2026';
 insert into app_private.households(id,label,primary_contact_user_id) values(household,'Groot testgezin','f0000000-0000-0000-0000-000000000001');
 insert into app_private.household_members(household_id,user_id,relation_role) values(household,'f0000000-0000-0000-0000-000000000001','owner');
 insert into app_private.registrations(id,event_id,household_id,status,reference,submitted_at) values(registration,eventid,household,'submitted','DPH-2026-'||upper(substr(replace(registration::text,'-',''),1,8)),now());
 for i in 1.._children loop
  insert into app_private.children(household_id,first_name,age_at_event) values(household,'Testkind '||i,8) returning id into child;
  insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registration,child,250);
 end loop;
 insert into app_private.walking_groups(event_id,code,status) values(eventid,'GS-'||substr(replace(registration::text,'-',''),1,8),'draft') returning id into groupid;
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(groupid,registration,1);
 return groupid;
end $$;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select pg_temp.save_size(30)$$,'42501','NOT_AUTHORIZED','participants cannot set the event group policy');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.save_size(1)$$,'one child is a valid organizer policy');
select is(api.admin_dashboard('duindorp-halloween-2026')#>>'{event,maxGroupSize}','1','the dashboard reads the saved minimum of one');
select lives_ok($$select pg_temp.save_size(12);select pg_temp.save_size(20);select pg_temp.save_size(30);select pg_temp.save_size(45)$$,'12, 20, 30 and 45 persist through the same event policy');
select is(api.admin_group_composition_snapshot('duindorp-halloween-2026')->>'maxGroupSize','45','group composition has no hidden twenty-child ceiling');
select is(api.registration_preferences_snapshot('duindorp-halloween-2026')#>>'{event,maxGroupSize}','45','registration reads the same current policy');
select throws_ok($$select pg_temp.save_size(0)$$,'22023','INVALID_GROUP_LIMIT','zero is rejected without mutation');
select throws_ok($$select pg_temp.save_size(-1)$$,'22023','INVALID_GROUP_LIMIT','negative limits are rejected');
select throws_ok($$select pg_temp.save_size(null)$$,'22023','INVALID_GROUP_LIMIT','missing maximum is rejected');
select throws_ok($$select pg_temp.save_size(30,31)$$,'22023','INVALID_GROUP_LIMIT','target cannot exceed the event maximum');
select lives_ok($$select pg_temp.save_size(30,24)$$,'an explicit target of 24 is saved with maximum 30');
select is(api.admin_dashboard('duindorp-halloween-2026')#>>'{event,targetGroupSize}','24','the planner target is an explicit event preference');
select throws_ok($$select pg_temp.save_size(18,24)$$,'22023','INVALID_GROUP_LIMIT','lowering below an explicit target requires a valid new target');
select is(api.admin_dashboard('duindorp-halloween-2026')#>>'{event,maxGroupSize}','30','invalid target leaves the saved maximum unchanged');
select lives_ok($$select pg_temp.save_size(45)$$,'following the maximum is an explicit saved choice');
set local role postgres;
insert into size_values values('group45',jsonb_build_object('id',pg_temp.size_fixture(45)));
insert into size_values select 'registration45',jsonb_build_object('id',a.registration_id)
 from app_private.group_registrations a where a.group_id=(select (value->>'id')::uuid from size_values where key='group45') and a.superseded_at is null;
select is((select count(*)::int from app_private.registration_children c where c.registration_id=(select (value->>'id')::uuid from size_values where key='registration45')),45,'all forty-five children can be stored and assigned as one group');
select throws_ok($$insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)
 select r.event_id,r.id,c.id,250 from app_private.registrations r join app_private.children c on c.household_id=r.household_id
 where r.id=(select (value->>'id')::uuid from size_values where key='registration45') limit 1$$,'23514',null,'a forty-sixth participant cannot bypass the current policy');
insert into size_values select 'before-lowering',jsonb_build_object('group',to_jsonb(g),'members',(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.group_id=g.id),'children',(select jsonb_agg(to_jsonb(c) order by c.id) from app_private.registration_children c where c.registration_id=(select (value->>'id')::uuid from size_values where key='registration45')))
 from app_private.walking_groups g where g.id=(select (value->>'id')::uuid from size_values where key='group45');
set local role authenticated;
select throws_ok($$select api.admin_set_group_size_limit('duindorp-halloween-2026',18,(api.admin_dashboard('duindorp-halloween-2026')#>>'{event,settingsVersion}')::integer,'Oude client zonder gecontroleerd impactoverzicht')$$,'23514','GROUP_SIZE_IMPACT_REVIEW_REQUIRED','an old setter cannot silently lower below existing groups');
select lives_ok($$select pg_temp.save_size(18)$$,'reviewed lowering preserves an oversized existing group');
set local role postgres;
select is((select jsonb_build_object('group',to_jsonb(g),'members',(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.group_id=g.id),'children',(select jsonb_agg(to_jsonb(c) order by c.id) from app_private.registration_children c where c.registration_id=(select (value->>'id')::uuid from size_values where key='registration45'))) from app_private.walking_groups g where g.id=(select (value->>'id')::uuid from size_values where key='group45')),(select value from size_values where key='before-lowering'),'group IDs, children, membership IDs and complete prior rows survive lowering unchanged');
select throws_ok($$update app_private.events set settings=settings||'{"maxGroupSize":12.5}'::jsonb where slug='duindorp-halloween-2026'$$,'22023','INVALID_GROUP_LIMIT','direct writes cannot round fractional policy values');
select lives_ok($$update app_private.walking_groups set display_name='Bestaande veilige groep' where id=(select (value->>'id')::uuid from size_values where key='group45')$$,'metadata corrections are possible for an oversized existing group');
select lives_ok($$update app_private.registration_children set participation_status='cancelled' where id=(select id from app_private.registration_children where registration_id=(select (value->>'id')::uuid from size_values where key='registration45') order by id limit 1)$$,'a deliberate reduction can remain above the lowered policy');
select is((select count(*)::int from app_private.registration_children where registration_id=(select (value->>'id')::uuid from size_values where key='registration45') and participation_status='active'),44,'safe reduction removes no other child or membership');
select throws_ok($$update app_private.registration_children set participation_status='active' where registration_id=(select (value->>'id')::uuid from size_values where key='registration45') and participation_status='cancelled'$$,'23514','GROUP_SIZE_LIMIT_EXCEEDED','an old existing-exception status does not permit regrowth');
select ok(not has_function_privilege('anon','api.admin_group_size_policy_save(text,integer,integer,integer,text,text)','execute'),'anonymous clients cannot use the new setter');
select ok(not has_function_privilege('authenticated','app_private.event_group_size_limit(uuid)','execute'),'the policy implementation is private behind scoped APIs');
select * from finish();
rollback;
