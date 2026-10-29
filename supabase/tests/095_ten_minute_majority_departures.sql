begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table departures(label text primary key, group_id uuid, registration_ids uuid[], slot_id uuid, finale_at timestamptz, result jsonb, input_hash text, command_key text);
create function pg_temp.departure_fixture(_label text, _families integer, _children integer default 1)
returns uuid language plpgsql as $$
declare g uuid; h uuid; r uuid; c uuid; e uuid := (select id from app_private.events where slug='duindorp-halloween-2026'); ids uuid[] := '{}';
begin
  insert into app_private.walking_groups(event_id,code,status,route_mode) values(e,'TEN-'||_label,'draft','dynamic') returning id into g;
  for i in 1.._families loop
    insert into app_private.households(label,primary_contact_user_id) values('Departure fixture','f0000000-0000-0000-0000-000000000001') returning id into h;
    insert into app_private.household_members(household_id,user_id,relation_role) values(h,'f0000000-0000-0000-0000-000000000001','owner');
    insert into app_private.registrations(event_id,household_id,status,reference,preferred_start_at,desired_end_at)
      values(e,h,'submitted','TEN-'||gen_random_uuid(),'2026-10-31T16:00:00Z','2026-10-31T19:00:00Z') returning id into r;
    for j in 1.._children loop
      insert into app_private.children(household_id,first_name,age_at_event) values(h,'Departure fixture',8) returning id into c;
      insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(e,r,c,250);
    end loop;
    insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(g,r,1);
    ids := array_append(ids,r);
  end loop;
  insert into departures(label,group_id,registration_ids) values(_label,g,ids);
  return g;
end;
$$;
update app_private.event_route_settings set first_start_at='2026-10-31T16:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T17:00:00Z',
  finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',finale_show_seconds=600,
  finale_turnover_seconds=120,finale_planning_transfer_seconds=900,finale_max_concurrent_groups=20,
  finale_max_concurrent_children=500,planner_mode='dynamic'
where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
select pg_temp.departure_fixture('B',3),pg_temp.departure_fixture('A',1,10),pg_temp.departure_fixture('C',1),
  pg_temp.departure_fixture('D',1),pg_temp.departure_fixture('E',1);
-- B's minority has ten children, but only the original family registration votes.
insert into app_private.children(household_id,first_name,age_at_event)
select household_id,'Minority fixture '||i,8 from app_private.registrations r cross join generate_series(1,9) i
where r.id=(select registration_ids[1] from departures where label='B');
insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)
select r.event_id,r.id,c.id,250 from app_private.registrations r join app_private.children c on c.household_id=r.household_id
where r.id=(select registration_ids[1] from departures where label='B')
  and not exists(select 1 from app_private.registration_children x where x.child_id=c.id);
update app_private.registrations set preferred_start_at='2026-10-31T15:00:00Z',desired_end_at='2026-10-31T15:30:00Z'
where id=(select registration_ids[1] from departures where label='B');
select is(app_private.dominant_start_preference(registration_ids),'2026-10-31T16:00:00Z'::timestamptz,'start majority counts one vote per original family, not children') from departures where label='B';
select is(app_private.dominant_end_preference(registration_ids),'2026-10-31T19:00:00Z'::timestamptz,'end majority survives an earlier minority with more children') from departures where label='B';
select is(app_private.dominant_end_preference(array[registration_ids[1],registration_ids[1],registration_ids[2],registration_ids[3]]),
  '2026-10-31T19:00:00Z'::timestamptz,'duplicate registration references do not add votes') from departures where label='B';
select is(app_private.dominant_start_preference(array[registration_ids[3],registration_ids[1],registration_ids[2]]),
  app_private.dominant_start_preference(registration_ids),'shuffled original families produce the same start majority') from departures where label='B';
select is(app_private.dominant_end_preference(array[registration_ids[3],registration_ids[1],registration_ids[2]]),
  app_private.dominant_end_preference(registration_ids),'shuffled original families produce the same end majority') from departures where label='B';
update app_private.registrations set preferred_start_at=null,desired_end_at=null where id=any((select registration_ids from departures where label='E')::uuid[]);
select is(app_private.dominant_start_preference(registration_ids),null::timestamptz,'all neutral start preferences remain neutral') from departures where label='E';
select is(app_private.dominant_end_preference(registration_ids),null::timestamptz,'all neutral end preferences remain neutral') from departures where label='E';
select is(app_private.dominant_start_preference('{}'::uuid[]),null::timestamptz,'empty votes remain neutral');
-- Equal frequencies: absolute-distance minimum, then earliest.
update app_private.registrations r set preferred_start_at=case when r.id=d.registration_ids[1] then '2026-10-31T15:00:00Z'::timestamptz when r.id=d.registration_ids[2] then '2026-10-31T16:00:00Z'::timestamptz else '2026-10-31T18:00:00Z'::timestamptz end
from departures d where d.label='B' and r.id=any(d.registration_ids);
select is(app_private.dominant_start_preference(registration_ids),'2026-10-31T16:00:00Z'::timestamptz,'equal votes use the smallest total absolute deviation') from departures where label='B';
select is(app_private.dominant_start_preference(registration_ids[1:2]),'2026-10-31T15:00:00Z'::timestamptz,'equal absolute deviation uses the earlier time') from departures where label='B';
update app_private.registrations set preferred_start_at='2026-10-31T16:00:00Z',desired_end_at='2026-10-31T19:00:00Z' where id=any((select registration_ids from departures where label='B')::uuid[]);
select ok(app_private.valid_departure_time('2026-10-31T17:00:00+01:00') and app_private.valid_departure_time('2026-10-31T17:10:00+01:00'),'Amsterdam whole ten-minute instants are valid');
select ok(not app_private.valid_departure_time('2026-10-31T17:15:00+01:00') and not app_private.valid_departure_time('2026-10-31T17:10:01+01:00'),'off-grid minute and second values are invalid');
select throws_ok($$select api.admin_startregie_slots_prepare('duindorp-halloween-2026',array['2026-10-31T16:15:00Z'::timestamptz])$$,'22023','INVALID_DEPARTURE_INTERVAL','slot preparation rejects off-grid input server-side');
create temp table departure_points as
select gen_random_uuid() id, label from (values('one'),('two')) v(label);
insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,max_gathering_groups,max_gathering_children,active)
select p.id,e.id,'Departure '||p.label,'FICTIEF VERTREKADRES',52.1,4.27,10,100,true from departure_points p cross join app_private.events e where e.slug='duindorp-halloween-2026';
select lives_ok($$select api.admin_startregie_slots_prepare('duindorp-halloween-2026',array['2026-10-31T16:00:00Z'::timestamptz,'2026-10-31T16:10:00Z'::timestamptz,'2026-10-31T16:20:00Z'::timestamptz])$$,'valid ten-minute slots are prepared');
select is((select min(max_groups)::integer from app_private.start_slots where start_point_id in(select id from departure_points)),1,'prepared departure capacity is one even with gathering capacity ten');
update departures set slot_id=s.id from app_private.start_slots s where s.start_point_id=(select id from departure_points where label='one') and s.starts_at=case when label='A' then '2026-10-31T16:10:00Z'::timestamptz when label='C' then '2026-10-31T16:20:00Z'::timestamptz else '2026-10-31T16:00:00Z'::timestamptz end;
-- Preserve every start/majority assertion while giving distinct physical
-- groups valid finale arrival gaps. Keep 18:50 free for the real preference RPC
-- chain below; that appointment must still follow its dominant 19:00 end.
update departures set finale_at=case label when 'A' then '2026-10-31T18:45:00Z'::timestamptz
 when 'B' then '2026-10-31T18:55:00Z'::timestamptz when 'C' then '2026-10-31T19:00:00Z'::timestamptz else '2026-10-31T19:05:00Z'::timestamptz end;
-- Confirmed composition has no appointment yet and must still be schedulable.
update app_private.walking_groups set composition_confirmed_hash=app_private.start_group_composition_hash(id),composition_confirmed_at=clock_timestamp(),status='ready'
where id=(select group_id from departures where label='B');
create temp table departure_preserved as select md5(jsonb_agg(to_jsonb(a) order by a.id)::text) assignments,
  (select count(*) from app_private.email_outbox) mails from app_private.group_registrations a;
update departures set input_hash=app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')),command_key=gen_random_uuid()::text;
create temp table departure_payload as select jsonb_build_object('groups',jsonb_agg(jsonb_build_object('key',group_id,'startId',slot_id,
  'effectiveStopAt','2026-10-31T18:30:00Z','expectedFinaleArrivalAt',finale_at,'preferenceMatch','good') order by label desc)) value
from departures where label in('B','A','C');
select lives_ok($$update departures set result=api.admin_group_operations_apply('duindorp-halloween-2026','distribute',input_hash,(select value from departure_payload),command_key) where label='B'$$,'three intact groups receive 17:00, 17:10 and 17:20 concepts including a confirmed composition');
select is(api.admin_group_operations_apply('duindorp-halloween-2026','distribute',input_hash,(select value from departure_payload),command_key),result,'exact repeated distribution returns its receipt without creating revisions') from departures where label='B';
select is((select count(*)::integer from app_private.group_schedule_revisions s where s.group_id in(select group_id from departures)),3,'exact retry creates only one revision per selected group');
select is((select md5(jsonb_agg(to_jsonb(a) order by a.id)::text) from app_private.group_registrations a),(select assignments from departure_preserved),'saving preserves original group membership and together blocks');
select is((select count(*) from app_private.email_outbox),(select mails from departure_preserved),'calculating and saving a concept queues no participant mail');
select is((select s.input_snapshot->>'dominantEndAt' from app_private.group_schedule_revisions s join departures d on d.group_id=s.group_id where d.label='B'),'2026-10-31T19:00:00+00:00','saved snapshot exposes the server-computed dominant end');
select throws_ok($$select api.admin_save_group_schedule((select group_id from departures where label='D'),(select slot_id from departures where label='B'),'2026-10-31T18:30:00Z','2026-10-31T18:45:00Z',null,'good','Tweede groep in bestaand vertrek moet worden geweigerd')$$,'23514','START_DEPARTURE_OCCUPIED','existing occupancy blocks a second group despite gathering capacity');
select lives_ok($$select api.admin_save_group_schedule((select group_id from departures where label='D'),(select id from app_private.start_slots where start_point_id=(select id from departure_points where label='two') and starts_at='2026-10-31T16:00:00Z'),'2026-10-31T18:30:00Z',(select finale_at from departures where label='D'),null,'good','Andere poort mag hetzelfde vertrek gebruiken')$$,'distinct physical start points can start simultaneously');
select throws_ok($$select api.admin_save_group_schedule((select group_id from departures where label='E'),(select slot_id from departures where label='C'),'2026-10-31T18:30:00Z','2026-10-31T19:01:00Z',null,'neutral','Finale voor een gewenste eindtijd kan niet overschreden worden')$$,'23514','START_DEPARTURE_OCCUPIED','insufficient departure slots fail atomically');
update app_private.registrations set desired_end_at='2026-10-31T16:25:00Z' where id=any((select registration_ids from departures where label='E')::uuid[]);
select throws_ok($$select api.admin_save_group_schedule((select group_id from departures where label='E'),(select slot_id from departures where label='C'),'2026-10-31T18:30:00Z','2026-10-31T18:45:00Z',null,'neutral','Onhaalbare groepseindtijd moet duidelijk falen')$$,'23514','GROUP_END_TIME_INFEASIBLE','a genuinely dominant infeasible end is a clear conflict');
-- Reassigning existing unconfirmed concepts releases only the selected old
-- draft reservations, atomically. Preserve history while swapping and cycling.
create temp table prior_departure_revisions as select g.id group_id,g.current_schedule_revision_id schedule_id
from app_private.walking_groups g join departures d on d.group_id=g.id where d.label in('A','B','C');
select lives_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','distribute',
  app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')),
  jsonb_build_object('groups',(select jsonb_agg(jsonb_build_object('key',d.group_id,'startId',
    case when d.label='A' then (select slot_id from departures where label='B') else (select slot_id from departures where label='A') end,
    'effectiveStopAt','2026-10-31T18:30:00Z','expectedFinaleArrivalAt',d.finale_at,'preferenceMatch','good'))
    from departures d where d.label in('A','B'))),gen_random_uuid()::text)$$,
  'two existing draft appointments can swap slots in one transaction');
select is((select count(*)::integer from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
  join prior_departure_revisions previous on previous.group_id=g.id where s.supersedes_id=previous.schedule_id and g.id in(select group_id from departures where label in('A','B'))),2,
  'swapped appointments retain superseded schedule identity');
select lives_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','distribute',
  app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')),
  jsonb_build_object('groups',(select jsonb_agg(jsonb_build_object('key',d.group_id,'startId',case when d.label='A' then d.slot_id when d.label='B' then (select slot_id from departures where label='C') else (select slot_id from departures where label='B') end,
    'effectiveStopAt','2026-10-31T18:30:00Z','expectedFinaleArrivalAt',d.finale_at,'preferenceMatch','good'))
    from departures d where d.label in('A','B','C'))),gen_random_uuid()::text)$$,
  'three existing concepts can be reassigned together without transient occupancy conflicts');

create temp table batch_rollback_before as select
  (select md5(jsonb_agg(to_jsonb(g) order by g.id)::text) from app_private.walking_groups g) groups_hash,
  (select md5(jsonb_agg(to_jsonb(s) order by s.id)::text) from app_private.group_schedule_revisions s) schedules_hash,
  (select count(*) from app_private.email_outbox) mails;
select throws_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','distribute',
  app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')),
  jsonb_build_object('groups',jsonb_build_array(
    jsonb_build_object('key',(select group_id from departures where label='A'),'startId',(select slot_id from departures where label='A'),'effectiveStopAt','2026-10-31T18:30:00Z','expectedFinaleArrivalAt',(select finale_at from departures where label='A'),'preferenceMatch','good'),
    jsonb_build_object('key',(select group_id from departures where label='B'),'startId',(select id from app_private.start_slots where start_point_id=(select id from departure_points where label='two') and starts_at='2026-10-31T16:00:00Z'),'effectiveStopAt','2026-10-31T18:30:00Z','expectedFinaleArrivalAt',(select finale_at from departures where label='B'),'preferenceMatch','good'))),gen_random_uuid()::text)$$,
  '23514','START_DEPARTURE_OCCUPIED','a real occupancy conflict after a valid first row rejects the whole batch');
select is((select md5(jsonb_agg(to_jsonb(g) order by g.id)::text) from app_private.walking_groups g),(select groups_hash from batch_rollback_before),
  'failed batch restores every old group pointer and version');
select is((select md5(jsonb_agg(to_jsonb(s) order by s.id)::text) from app_private.group_schedule_revisions s),(select schedules_hash from batch_rollback_before),
  'failed batch leaves no partial revision or changed supersedes history');
select is((select count(*) from app_private.email_outbox),(select mails from batch_rollback_before),'failed distribution also creates no participant mail');

-- An explicitly confirmed appointment cannot be silently redistributed.
update app_private.group_schedule_revisions set confirmed_at=clock_timestamp() where group_id=(select group_id from departures where label='B');
select throws_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','distribute',app_private.group_operations_hash((select id from app_private.events where slug='duindorp-halloween-2026')),(select value from departure_payload),gen_random_uuid()::text)$$,'23514','START_APPOINTMENT_PROTECTED','automatic distribution preserves a confirmed appointment');

select ok((select (item->>'appointmentProtected')::boolean from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,groups}') item
  where item->>'groupId'=(select group_id::text from departures where label='B')),
  'snapshot marks even a stale raw confirmation as protected for automatic distribution');
select ok(not exists(select 1 from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,existingSchedules}') item
  where not (item ? 'startsAt' and item ? 'startPointId')),
  'occupancy snapshot exposes authoritative departure times and physical gates');

-- Reproduce the complete participant-preference -> first manual appointment chain.
select pg_temp.departure_fixture('RPC',3);
select lives_ok(format('select api.registration_exact_preferences_save(%L::uuid,%L::timestamptz,%L::timestamptz,%s)',r.id,
  '2026-10-31T16:00:00Z',case when r.id=d.registration_ids[1] then '2026-10-31T17:00:00Z' else '2026-10-31T19:00:00Z' end,r.version),
  'real participant preference RPC saves each original household end independently')
from departures d join app_private.registrations r on r.id=any(d.registration_ids) where d.label='RPC';
select ok((select bool_and(r.requested_ordinary_stop_at is null) from app_private.registrations r join departures d on r.id=any(d.registration_ids) where d.label='RPC'),
  'exact end RPC creates no derived ordinary-stop veto');
-- Simulate an existing row written by the old coupled RPC; do not migrate or rewrite original data.
update app_private.registrations set requested_ordinary_stop_at=desired_end_at
where id=(select registration_ids[1] from departures where label='RPC');
select lives_ok($$select api.admin_startregie_move_group((select group_id from departures where label='RPC'),
  (select id from departure_points where label='two'),'2026-10-31T17:10:00Z',
  (select g.version from app_private.walking_groups g join departures d on d.group_id=g.id where d.label='RPC'),
  'small_deviation','Eerste vertrekafspraak volgt de echte meerderheid ondanks afgeleide minderheidsstop')$$,
  'first manual appointment honors real RPC majority and ignores a legacy derived minority end');
select is((select s.expected_finale_arrival_at from app_private.group_schedule_revisions s join departures d on d.group_id=s.group_id where d.label='RPC'),
  '2026-10-31T18:50:00Z'::timestamptz,'manual first appointment computes its finale from dominant end, not global stop');
update app_private.registrations set requested_ordinary_stop_at='2026-10-31T18:00:00Z'
where id=(select registration_ids[1] from departures where label='RPC');
select lives_ok($$select api.admin_save_group_schedule((select group_id from departures where label='RPC'),
  (select s.start_slot_id from app_private.group_schedule_revisions s join departures d on d.group_id=s.group_id where d.label='RPC'),
  '2026-10-31T18:30:00Z','2026-10-31T18:50:00Z',null,'small_deviation','Losse expliciete gewone stoptijd blijft een afzonderlijke routegrens')$$,
  'a separate explicit ordinary-stop preference is respected');
select is((select s.effective_ordinary_stop_at from app_private.group_schedule_revisions s join app_private.walking_groups g on g.current_schedule_revision_id=s.id join departures d on d.group_id=g.id where d.label='RPC'),
  '2026-10-31T18:00:00Z'::timestamptz,'saved ordinary stop keeps the explicit ordinary boundary');
update app_private.registrations set requested_ordinary_stop_at=desired_end_at where id=(select registration_ids[1] from departures where label='RPC');
select lives_ok($$select api.registration_exact_preferences_save(r.id,r.preferred_start_at,'2026-10-31T17:30:00Z',r.version)
  from app_private.registrations r where r.id=(select registration_ids[1] from departures where label='RPC')$$,
  'editing an old derived preference clears only its derived ordinary value');
select is((select requested_ordinary_stop_at from app_private.registrations where id=(select registration_ids[1] from departures where label='RPC')),null::timestamptz,
  'old derived ordinary value is cleared only on an authorized preference edit');
-- A valid proposal may deliberately shorten the ordinary route for an earlier finale gap.
select pg_temp.departure_fixture('NEW',1);
update app_private.group_registrations set superseded_at=clock_timestamp() where group_id=(select group_id from departures where label='NEW');
select lives_ok($$select api.admin_apply_dynamic_plan('duindorp-halloween-2026',jsonb_build_object('groups',jsonb_build_array(jsonb_build_object(
  'startId',(select id from app_private.start_slots where start_point_id=(select id from departure_points where label='two') and starts_at='2026-10-31T16:20:00Z'),
  'partyIds',(select to_jsonb(registration_ids) from departures where label='NEW'),'childCount',1,
  'effectiveStopAt','2026-10-31T17:30:00Z','expectedFinaleArrivalAt','2026-10-31T17:45:00Z','preferenceMatch','good'))),
  app_private.start_planning_input_hash((select id from app_private.events where slug='duindorp-halloween-2026')),gen_random_uuid()::text,'server hashes content')$$,
  'new-group plan persists a deliberately earlier ordinary stop for a feasible finale gap');
select is((select s.effective_ordinary_stop_at from app_private.group_schedule_revisions s join app_private.group_registrations a on a.group_id=s.group_id and a.superseded_at is null
  where a.registration_id=(select registration_ids[1] from departures where label='NEW')),'2026-10-31T17:30:00Z'::timestamptz,
  'new-group storage retains the planned earlier ordinary stop');
select throws_ok($$select api.admin_startregie_slots_prepare('duindorp-halloween-2026',array['2026-10-31T18:40:00Z'::timestamptz])$$,
  '23514','START_TIME_OUTSIDE_EVENT','ten-minute times outside the allowed start window are rejected');

select ok(not has_function_privilege('anon','api.admin_group_operations_apply(text,text,text,jsonb,text)','execute'),'anonymous cannot distribute');
select ok(not has_function_privilege('authenticated','app_private.group_operations_apply_before_departure_slots(text,text,text,jsonb,text)','execute'),'legacy operation implementation stays private');
-- Portal IDs and application IDs can name the same canonical physical door.
-- A manual alias keeps application_id NULL, preserving its unique constraint.
-- Gathering capacities remain per actual start point.
create temp table departure_alias as select application_id portal_id,gen_random_uuid() point_a,gen_random_uuid() point_b,gen_random_uuid() independent_point from app_private.portals where id='12000000-0000-0000-0000-000000000001';
do $$begin if(select count(*)from departure_alias)<>1 then raise exception 'SYNTHETIC_ALIAS_FIXTURE_MISSING';end if;end$$;
insert into app_private.portals
select (jsonb_populate_record(null::app_private.portals,to_jsonb(portal)||jsonb_build_object('id',alias.portal_id,'application_id',null,'system_number',9998,'system_code','TEN-PHYSICAL-ALIAS','name','Synthetische fysieke alias'))).*
 from app_private.portals portal cross join departure_alias alias where portal.id='12000000-0000-0000-0000-000000000001';
insert into app_private.portal_windows
select (jsonb_populate_record(null::app_private.portal_windows,to_jsonb(pw)||jsonb_build_object('id',gen_random_uuid(),'portal_id',alias.portal_id))).*
 from app_private.portal_windows pw join app_private.portals portal on portal.id=pw.portal_id cross join departure_alias alias where portal.id='12000000-0000-0000-0000-000000000001';
insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,max_gathering_groups,max_gathering_children,active,linked_portal_id,counts_as_first_portal_visit,point_type)
select alias.point_a,e.id,'Synthetisch aliassamenkomen A','FICTIEF TESTADRES',52.1,4.27,10,10,true,portal.id,false,'portal' from departure_alias alias cross join app_private.events e cross join app_private.portals portal where e.slug='duindorp-halloween-2026'and portal.id='12000000-0000-0000-0000-000000000001'
union all select alias.point_b,e.id,'Synthetisch aliassamenkomen B','FICTIEF TESTADRES',52.1,4.27,10,20,true,alias.portal_id,false,'portal' from departure_alias alias cross join app_private.events e where e.slug='duindorp-halloween-2026'
union all select alias.independent_point,e.id,'Synthetisch ander samenkomen','FICTIEF TESTADRES',52.1,4.27,10,30,true,null::uuid,false,'gathering' from departure_alias alias cross join app_private.events e where e.slug='duindorp-halloween-2026';
select is(app_private.start_departure_key(point_a),app_private.start_departure_key(point_b),'portal aliases share the same physical departure key even without a first visit')from departure_alias;
select is(app_private.start_departure_key(independent_point),independent_point,'an unlinked gathering point retains its independent identity')from departure_alias;
select pg_temp.departure_fixture('ALIAS-A',1),pg_temp.departure_fixture('ALIAS-B',1),pg_temp.departure_fixture('ALIAS-C',1);
select api.admin_startregie_slots_prepare('duindorp-halloween-2026',array['2026-10-31T16:00:00Z'::timestamptz]);
select lives_ok($$select api.admin_save_group_schedule((select group_id from departures where label='ALIAS-A'),(select slot.id from app_private.start_slots slot cross join departure_alias alias where slot.start_point_id=alias.point_a and slot.starts_at='2026-10-31T16:00:00Z'),'2026-10-31T16:45:00Z','2026-10-31T17:10:00Z',null,'good','Eerste fysieke alias behoudt eigen verzamelcapaciteit')$$,'the first physical departure can be saved');
select throws_ok($$select api.admin_save_group_schedule((select group_id from departures where label='ALIAS-B'),(select slot.id from app_private.start_slots slot cross join departure_alias alias where slot.start_point_id=alias.point_b and slot.starts_at='2026-10-31T16:00:00Z'),'2026-10-31T16:45:00Z','2026-10-31T17:25:00Z',null,'good','Tweede alias kan dezelfde fysieke poort niet dubbel plannen')$$,'23514','START_DEPARTURE_OCCUPIED','direct saving cannot reserve a second departure through a portal alias');
select lives_ok($$select api.admin_save_group_schedule((select group_id from departures where label='ALIAS-C'),(select slot.id from app_private.start_slots slot cross join departure_alias alias where slot.start_point_id=alias.independent_point and slot.starts_at='2026-10-31T16:00:00Z'),'2026-10-31T16:45:00Z','2026-10-31T17:30:00Z',null,'good','Andere verzamelplek houdt een onafhankelijk vertrek')$$,'a different gathering point can use the same ten-minute departure');
insert into app_private.group_start_publications(event_id,group_id,source_key,schedule_id,revision,starts_at,point_snapshot,slot_snapshot)
select group_row.event_id,group_row.id,'synthetic-frozen-alias',schedule.id,schedule.revision,slot.starts_at,to_jsonb(point),to_jsonb(slot)
from departures fixture join app_private.walking_groups group_row on group_row.id=fixture.group_id join app_private.group_schedule_revisions schedule on schedule.id=group_row.current_schedule_revision_id join app_private.start_slots slot on slot.id=schedule.start_slot_id join app_private.start_points point on point.id=slot.start_point_id where fixture.label='ALIAS-A';
update app_private.start_points set linked_portal_id='12000000-0000-0000-0000-000000000002'::uuid where id=(select point_a from departure_alias);
select is(app_private.reserved_departure_key(fixture.group_id,(select publication.schedule_id from app_private.group_start_publications publication where publication.group_id=fixture.group_id and publication.source_key='synthetic-frozen-alias'),alias.point_a),app_private.start_departure_key(alias.point_b),'published reservations canonicalize the frozen portal rather than the changed live point')from departure_alias alias cross join departures fixture join app_private.walking_groups group_row on group_row.id=fixture.group_id where fixture.label='ALIAS-A';
select is((select max_gathering_children from app_private.start_points where id=alias.point_a),10,'canonical departure identity leaves the actual gathering capacity intact')from departure_alias alias;
select is((select jsonb_build_object('id',point->'id','physicalDepartureKey',point->'physicalDepartureKey','maxChildren',point->'maxChildren')from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')->'startPoints')point where(point->>'id')::uuid=alias.point_b),jsonb_build_object('id',alias.point_b,'physicalDepartureKey',alias.portal_id,'maxChildren',20),'start proposals receive the canonical departure key separately from actual point and gathering capacity')from departure_alias alias;
select * from finish();
rollback;
