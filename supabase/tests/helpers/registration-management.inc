-- Local synthetic seed only. Invoke in the same psql session; the normal SQL
-- suite wraps it in BEGIN/ROLLBACK. Browser acceptance uses an owned reset stack.
create or replace function pg_temp.registration_management_fixture(_starts timestamptz default '2026-10-31T16:00:00Z') returns jsonb language plpgsql as $$
declare eid uuid; gid uuid; point uuid; schedule uuid; n integer:=0; result jsonb:='{}';
 relative_clock boolean:=_starts is distinct from '2026-10-31T16:00:00Z'::timestamptz;
begin
 perform set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
 select id into eid from app_private.events where slug='duindorp-halloween-2026';
 -- Runtime/browser fixtures can cross midnight. Keep their selectable end
 -- preferences on the completion day and bound departures by absolute time.
 -- The fixed October 31 fixture retains its original evening choice lists.
 update app_private.events set local_date=((_starts+case when relative_clock then interval '3 hours' else interval '0' end) at time zone 'Europe/Amsterdam')::date,
  settings=settings||'{"groupRegistrationOpen":false,"portalRegistrationOpen":false}'::jsonb where id=eid;
 update app_private.registrations set desired_end_at=_starts+interval '3 hours',requested_ordinary_stop_at=_starts+interval '3 hours',preferred_start_at=_starts where event_id=eid;
 update app_private.event_route_settings set first_start_at=_starts-interval '30 minutes',global_ordinary_stop_at=_starts+interval '2 hours',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=_starts+interval '30 minutes',finale_last_arrival_at=_starts+interval '3 hours',
  finale_closes_at=_starts+interval '4 hours',finale_available=true,planner_mode='dynamic',finale_show_seconds=360,finale_turnover_seconds=120,
  finale_planning_transfer_seconds=600,finale_max_concurrent_groups=20,finale_max_concurrent_children=500,
  preferred_start_min_local=case when relative_clock then time '00:00' else preferred_start_min_local end,
  preferred_start_max_local=case when relative_clock then time '23:50' else preferred_start_max_local end,
  preferred_start_step_minutes=case when relative_clock then 10 else preferred_start_step_minutes end,
  desired_end_min_local=case when relative_clock then time '00:00' else desired_end_min_local end,
  desired_end_max_local=case when relative_clock then time '23:50' else desired_end_max_local end,
  desired_end_step_minutes=case when relative_clock then 10 else desired_end_step_minutes end where event_id=eid;
 update app_private.portal_windows set opens_at=least(opens_at,_starts-interval '1 hour'),closes_at=greatest(closes_at,_starts+interval '5 hours'),max_concurrent_groups=20,max_children_per_visit=100,max_children_total=5000
  where portal_id in(select id from app_private.portals where event_id=eid);
 for gid in select id from app_private.walking_groups where id in('23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002') order by id loop
  n:=n+1;
  -- Select distinct real finale appointments before either immutable publication.
  update app_private.event_route_settings set finale_planning_transfer_seconds=600+(n-1)*600 where event_id=eid;
  point:=(api.admin_startregie_start_point_save('duindorp-halloween-2026',null,jsonb_build_object('name','Synthetic household start '||n,'publicLabel','Synthetic household start '||n,'pointType','gathering',
   'privateAddress','FICTIEF GEZINSSTARTADRES '||n,'geocodedLatitude',52.10+n*0.001,'geocodedLongitude',4.27+n*0.001,'publicArrivalInstructions','Synthetische ingang '||n,'active',true,'maxGroups',1,'maxChildren',30),null,'Synthetische fixture voor gericht gezinsbeheer')->>'id')::uuid;
  perform api.admin_startregie_confirm_point('duindorp-halloween-2026',point,(select version from app_private.start_points where id=point));
  schedule:=(api.admin_startregie_move_group(gid,point,_starts+make_interval(mins=>(n-1)*10),(select version from app_private.walking_groups where id=gid),'neutral','Synthetische fixture voor behoud van bevestigde afspraken')->>'id')::uuid;
  perform api.admin_startregie_confirm_start('duindorp-halloween-2026',gid,(select revision from app_private.group_schedule_revisions where id=schedule),(select settings_version from app_private.events where id=eid));
  update app_private.group_schedule_revisions set state='published',published_at=clock_timestamp() where id=schedule;
  update app_private.walking_groups set route_mode='dynamic',composition_confirmed_hash=app_private.start_group_composition_hash(gid),composition_confirmed_at=clock_timestamp(),composition_confirmed_by='f0000000-0000-0000-0000-000000000001',composition_revision=composition_revision+1 where id=gid;
  result:=result||jsonb_build_object(case when n=1 then 'source' else 'target' end,jsonb_build_object('groupId',gid,'pointId',point,'scheduleId',schedule,'startsAt',_starts+make_interval(mins=>(n-1)*10)));
 end loop;
 update app_private.event_route_settings set finale_planning_transfer_seconds=600 where event_id=eid;
 return result;
end $$;
