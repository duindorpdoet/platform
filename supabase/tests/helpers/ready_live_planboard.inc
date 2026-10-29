-- Test-only, explicit route setup. Normal snapshot reads deliberately create
-- no physical route. These regressions exercise reviewed manual intentions;
-- joint planner validation itself is covered independently by 110 and 111.
create function pg_temp.ready_live_planboard(_event_slug text) returns jsonb
language plpgsql as $$
declare result jsonb; g record; preview jsonb; stop jsonb; win record; n integer; active record;ctx jsonb; position jsonb;travel record;cursor_at timestamptz;arrival timestamptz;seconds integer;buffer integer;actual_stop uuid;
begin
 result:=api.admin_live_planboard_snapshot(_event_slug);
 for g in select groups.*from app_private.walking_groups groups join app_private.events e on e.id=groups.event_id
  where e.slug=_event_slug and groups.current_schedule_revision_id is not null and groups.retired_at is null
  and not exists(select 1 from app_private.live_route_visits v where v.group_id=groups.id and v.kind<>'start'and v.retired_at is null)
 loop
  -- Explicitly unrestricted synthetic children: this fixture is about manual
  -- route commands, not interpretation of historical accessibility notes.
  update app_private.children set step_free_required=false where id in(select rc.child_id from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id=g.id and a.superseded_at is null);
  preview:=app_private.start_ops_route_preview_before_joint_routes(g.id); n:=0;
  ctx:=app_private.route_group_start_context(g.id);cursor_at:=(ctx->>'startsAt')::timestamptz;
  position:=app_private.routing_position((ctx#>>'{pointSnapshot,marker_latitude}')::numeric,(ctx#>>'{pointSnapshot,marker_longitude}')::numeric,
   (ctx#>>'{pointSnapshot,geocoded_latitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_longitude}')::numeric,(ctx#>>'{pointSnapshot,latitude}')::numeric,(ctx#>>'{pointSnapshot,longitude}')::numeric);
  if ctx#>>'{pointSnapshot,linked_portal_id}'is not null and not coalesce((ctx#>>'{pointSnapshot,counts_as_first_portal_visit}')::boolean,false)then
   n:=1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
    values(g.event_id,g.id,n,(ctx#>>'{pointSnapshot,linked_portal_id}')::uuid,cursor_at,30,0,'start','manual')
    on conflict(group_id,sequence)do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=30,buffer_seconds=0,kind='start',source='manual',retired_at=null,version=live_route_visits.version+1 where live_route_visits.run_stop_id is null;
  end if;
  for stop in select *from jsonb_array_elements(preview->'stops')loop
   n:=n+1;
   select *into travel from app_private.destination_estimate((position->>'latitude')::numeric,(position->>'longitude')::numeric,
    (app_private.portal_location((stop->>'portalId')::uuid)->>'latitude')::numeric,(app_private.portal_location((stop->>'portalId')::uuid)->>'longitude')::numeric);
   arrival:=greatest((stop->>'plannedArrivalAt')::timestamptz,cursor_at+make_interval(secs=>travel.duration_seconds::integer));
   if stop->>'kind'='finale'then arrival:=(ctx->>'expectedFinaleArrivalAt')::timestamptz;end if;
   select rs.id,res.reserved_from,res.reserved_until into active from app_private.group_runs r join app_private.run_stops rs on rs.id=r.current_stop_id
    join app_private.portal_reservations res on res.id=rs.reservation_id where r.group_id=g.id and r.status in('live','paused')and rs.portal_id=(stop->>'portalId')::uuid limit 1;
   if active.id is not null then arrival:=active.reserved_from;end if;
   stop:=stop||jsonb_build_object('plannedArrivalAt',arrival);
   select *into win from app_private.portal_effective_windows((stop->>'portalId')::uuid)w where(stop->>'plannedArrivalAt')::timestamptz>=w.opens_at and(stop->>'plannedArrivalAt')::timestamptz<=w.arrival_closes_at limit 1;
   if win.opens_at is null then raise exception 'TEST_REVIEWED_ROUTE_WINDOW_INVALID';end if;
   seconds:=case when active.id is not null then extract(epoch from active.reserved_until-active.reserved_from)::integer else win.visit_seconds end;
   buffer:=case when active.id is not null then 0 else win.buffer_seconds end;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source,run_stop_id)
    values(g.event_id,g.id,n,(stop->>'portalId')::uuid,arrival,seconds,buffer,stop->>'kind','manual',active.id)
    on conflict(group_id,sequence)do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,kind=excluded.kind,source='manual',retired_at=null,version=live_route_visits.version+1
     where live_route_visits.run_stop_id is null;
   cursor_at:=arrival+make_interval(secs=>seconds);position:=app_private.portal_location((stop->>'portalId')::uuid);
  end loop;
  perform app_private.accept_manual_route_intention(g.event_id,g.id,'Synthetische route expliciet beoordeeld voor planbordregressies');
 end loop;
 return api.admin_live_planboard_snapshot(_event_slug);
end $$;
