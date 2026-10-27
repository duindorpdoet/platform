-- Isolated rollback fixtures for arrival/leadership tests. Existing appointments
-- stay immutable: append a synthetic already-startable appointment instead of
-- giving the application a clock override or weakening its time gate.
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
select p.event_id,p.group_id,'fixture-start-available:'||p.id,p.revision,clock_timestamp()-interval '1 minute',
  clock_timestamp(),p.point_snapshot,p.slot_snapshot||jsonb_build_object('starts_at',clock_timestamp()-interval '1 minute')
from app_private.group_start_publications p join app_private.walking_groups g on g.id=p.group_id
where g.event_id=(select id from app_private.events where slug='duindorp-halloween-2026')
  and p.source_key like 'legacy:%' on conflict(group_id,source_key) do nothing;

-- Explicit synthetic replacement appointment for current route regressions.
-- Keep original future windows/plans intact; add a real current reception window.
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
 select w.portal_id,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '6 hours',w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total
 from app_private.portal_windows w where not exists(select 1 from app_private.portal_windows current_window where current_window.portal_id=w.portal_id and current_window.opens_at<=clock_timestamp() and current_window.closes_at>clock_timestamp());
update app_private.event_route_settings set first_start_at=clock_timestamp()-interval '2 hours',global_ordinary_stop_at=clock_timestamp()+interval '3 hours',
 allowed_personal_stop_times=array[clock_timestamp()+interval '2 hours'],final_portal_id='12000000-0000-0000-0000-000000000030',
 finale_opens_at=clock_timestamp()-interval '1 hour',finale_last_arrival_at=clock_timestamp()+interval '5 hours',finale_closes_at=clock_timestamp()+interval '6 hours',
 finale_show_seconds=60,finale_turnover_seconds=120,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
create temp table legacy_start_fixture_slots as select slot.id original_id,extensions.gen_random_uuid() new_id from app_private.start_slots slot where slot.event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,active,start_point_id)
 select mapping.new_id,slot.event_id,'fixture-evening:'||slot.id,slot.name,slot.location_name,slot.private_address,slot.latitude,slot.longitude,slot.location_verified_at,clock_timestamp()-interval '1 minute',slot.max_groups,slot.max_children,slot.active,slot.start_point_id
 from legacy_start_fixture_slots mapping join app_private.start_slots slot on slot.id=mapping.original_id;
with schedules as (
 insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
 select g.id,coalesce((select max(s.revision) from app_private.group_schedule_revisions s where s.group_id=g.id),0)+1,'published',mapping.new_id,clock_timestamp()+interval '3 hours',clock_timestamp()+interval '4 hours','neutral',clock_timestamp()
 from app_private.walking_groups g join legacy_start_fixture_slots mapping on mapping.original_id=g.start_slot_id
 where g.route_mode='legacy' and not exists(select 1 from app_private.group_runs where group_id=g.id) and not exists(select 1 from app_private.finale_publication_commitments commitment where commitment.publication_id=(select latest.id from app_private.group_start_publications latest where latest.group_id=g.id order by publication_order desc limit 1)) and exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null)
 returning id,group_id
) update app_private.walking_groups g set current_schedule_revision_id=s.id from schedules s where g.id=s.group_id;
