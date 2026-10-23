do $$ begin
  if to_regprocedure('app_private.admin_startregie_snapshot_before_ops(text)') is null then
    alter function api.admin_startregie_snapshot(text) set schema app_private;
    alter function app_private.admin_startregie_snapshot(text) rename to admin_startregie_snapshot_before_ops;
  end if;
end $$;
revoke all on function app_private.admin_startregie_snapshot_before_ops(text) from public,anon,authenticated;

create or replace function api.admin_startregie_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item),'[]'::jsonb),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.group_start_publications p1 where p1.group_id=g.id order by p1.publication_order desc limit 1) pub on true
    where g.event_id=e.id;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$$;

create or replace function app_private.start_point_working_revision()
returns trigger language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; new_id uuid; rev integer;
begin
  if row(new.name,new.private_address,new.latitude,new.longitude,new.marker_latitude,new.marker_longitude,new.geocoded_latitude,new.geocoded_longitude,
    new.safe_approach,new.walking_node_id,new.linked_portal_id,new.counts_as_first_portal_visit,new.available_from,new.available_until)
    is not distinct from row(old.name,old.private_address,old.latitude,old.longitude,old.marker_latitude,old.marker_longitude,old.geocoded_latitude,old.geocoded_longitude,
    old.safe_approach,old.walking_node_id,old.linked_portal_id,old.counts_as_first_portal_visit,old.available_from,old.available_until) then return new; end if;
  for g in select g1.* from app_private.walking_groups g1 join app_private.group_schedule_revisions s1 on s1.id=g1.current_schedule_revision_id
    join app_private.start_slots slot on slot.id=s1.start_slot_id where slot.start_point_id=new.id
      and not exists(select 1 from app_private.group_runs where group_id=g1.id) order by g1.id for update of g1
  loop
    select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id;
    select coalesce(max(revision),0)+1 into rev from app_private.group_schedule_revisions where group_id=g.id;
    insert into app_private.group_schedule_revisions(group_id,revision,start_slot_id,effective_ordinary_stop_at,
      expected_finale_arrival_at,queue_number,preference_match,input_snapshot,warnings,created_by,supersedes_id)
    values(g.id,rev,s.start_slot_id,s.effective_ordinary_stop_at,s.expected_finale_arrival_at,s.queue_number,s.preference_match,
      s.input_snapshot||jsonb_build_object('pointVersion',new.version,'reason','Startpunt gewijzigd: controleer en bevestig de nieuwe afspraak'),
      jsonb_build_array('Startpunt gewijzigd; controleer loopaansluiting en bevestig opnieuw.'),auth.uid(),s.id) returning id into new_id;
    update app_private.walking_groups set current_schedule_revision_id=new_id,version=version+1 where id=g.id;
  end loop;
  return new;
end;
$$;
drop trigger if exists start_point_working_revision on app_private.start_points;
create trigger start_point_working_revision after update on app_private.start_points
for each row execute function app_private.start_point_working_revision();
revoke all on function app_private.start_point_working_revision() from public,anon,authenticated;
revoke all on function api.admin_startregie_snapshot(text) from public,anon;
grant execute on function api.admin_startregie_snapshot(text) to authenticated;
