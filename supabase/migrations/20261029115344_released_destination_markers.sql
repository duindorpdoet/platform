-- One validated coordinate pair from storage to routing and the released destination.
-- No event setting, publication, route/run or participant message is rewritten.
set lock_timeout='5s';
alter table app_private.portals add column public_entrance_instructions text
  check (char_length(coalesce(public_entrance_instructions,''))<=500);

create function app_private.portal_public_entrance(_portal uuid) returns text
language sql stable security definer set search_path='' as $$
 select nullif(trim(coalesce(p.public_entrance_instructions,a.private_draft_data->>'entrance','')),'')
 from app_private.portals p left join app_private.portal_applications a on a.id=p.application_id where p.id=_portal
$$;
-- Legacy plan stops and dynamic reservations both identify an already released destination.
create function app_private.portal_destination_in_use(_portal uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.portal_reservations reservation join app_private.group_runs run on run.id=reservation.run_id
  where reservation.portal_id=_portal and reservation.status in ('held','active') and run.status in ('live','paused'))
 or exists(select 1 from app_private.run_stops stop join app_private.group_runs run on run.id=stop.run_id
  left join app_private.route_plan_stops planned on planned.id=stop.plan_stop_id
  where run.status in ('live','paused') and stop.state='active' and coalesce(stop.portal_id,planned.portal_id)=_portal)
$$;
revoke all on function app_private.portal_destination_in_use(uuid) from public,anon,authenticated;

create function app_private.routing_coordinate(_position jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select case when coalesce((_position->>'valid')::boolean,false)
 then jsonb_build_array((_position->>'longitude')::numeric,(_position->>'latitude')::numeric) else 'null'::jsonb end
$$;
revoke all on function app_private.portal_public_entrance(uuid),app_private.routing_coordinate(jsonb) from public,anon,authenticated;

create or replace function api.portal_room_update_v1(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; result jsonb; request_hash text; receipt app_private.command_receipts; minutes integer; newstate app_private.portal_operation_status;
begin
 select * into p from app_private.portals where id=_portal_id for update;
 perform app_private.poortkamer_require(_portal_id,case when _operation='details' then 'details' else 'live' end);
 request_hash:=encode(extensions.digest(jsonb_build_array(_portal_id,_operation,_payload)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.room' and idempotency_key=_key::text;
 if found then if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 perform app_private.poortkamer_budget('room',30);
 if _operation='status' then
  if (_payload->>'version') is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  minutes:=(_payload->>'minutes')::integer; newstate:=(_payload->>'state')::app_private.portal_operation_status;
  if newstate not in ('open','paused','closed') or (minutes is not null and (newstate<>'paused' or minutes not in (5,10,15,20,30))) then raise exception 'INVALID_STATE'; end if;
  result:=api.portal_set_operational_state(p.id,newstate,(_payload->>'version')::integer,_payload->>'reason');
  if newstate='paused' and minutes is not null then
   update app_private.portals set pause_until=now()+make_interval(mins=>minutes) where id=p.id;
   update app_private.portal_status_history set resume_at=now()+make_interval(mins=>minutes) where id=(select id from app_private.portal_status_history where portal_id=p.id order by created_at desc,id desc limit 1);
  end if;
 elsif _operation='checklist' then
  insert into app_private.portal_readiness(portal_id,item,done,changed_by) values(p.id,_payload->>'item',(_payload->>'done')::boolean,auth.uid())
  on conflict(portal_id,item) do update set done=excluded.done,changed_by=excluded.changed_by,changed_at=now();
  result:=jsonb_build_object('item',_payload->>'item');
  perform app_private.poortkamer_signal(p.id,'portal.readiness.updated',result,'De gedeelde gereedcheck is bijgewerkt.');
 elsif _operation='stock' then
  update app_private.portals set stock_status=_payload->>'stock',stock_help_requested_at=case when _payload->>'stock' in ('plenty','sufficient') then null else stock_help_requested_at end where id=p.id;
  result:=jsonb_build_object('stock',_payload->>'stock');
  perform app_private.poortkamer_signal(p.id,'portal.stock.updated',result,'De snoepvoorraad is bijgewerkt.');
 elsif _operation='help' then
  perform app_private.poortkamer_budget('stock_help',2);
  if exists(select 1 from app_private.portal_community_mutes where event_id=p.event_id and user_id=auth.uid() and until_at>now()) then raise exception 'COMMUNITY_MUTED' using errcode='42501'; end if;
  if (_payload->>'shareCommunity')::boolean is distinct from true then raise exception 'EXPLICIT_CONFIRMATION_REQUIRED'; end if;
  perform app_private.poortkamer_channels(p.event_id,p.id);
  insert into app_private.portal_room_messages(channel_id,actor_id,sender_portal_id,body,dedupe_key)
  select id,auth.uid(),p.id,p.system_code||' vraagt hulp met de snoepvoorraad. Neem contact op via deze poort in het Poortplein.',_key from app_private.portal_room_channels where event_id=p.event_id and name='Snoep & voorraad' and kind='community';
  update app_private.portals set stock_help_requested_at=now() where id=p.id;
  result:=jsonb_build_object('shared',true);
  perform app_private.poortkamer_signal(p.id,'portal.stock.help',result,'Er is hulp voor snoepvoorraad gevraagd op het Poortplein.');
 elsif _operation='details' then
  if p.version is distinct from (_payload->>'version')::integer then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if char_length(trim(_payload->>'name')) not between 2 and 160 or char_length(coalesce(_payload->>'description',''))>2000 or char_length(coalesce(_payload->>'publicEntranceInstructions',''))>500 then raise exception 'INVALID_DETAILS'; end if;
  update app_private.portals set name=trim(_payload->>'name'),description=_payload->>'description',public_entrance_instructions=case when _payload?'publicEntranceInstructions' then trim(coalesce(_payload->>'publicEntranceInstructions','')) else public_entrance_instructions end,version=version+1 where id=p.id;
  result:=jsonb_build_object('updated',true);
  perform app_private.poortkamer_signal(p.id,'portal.details.updated','{}','De poortgegevens zijn bijgewerkt.');
 else raise exception 'INVALID_OPERATION'; end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.room',_key::text,request_hash,result,now()+interval '30 days');
 return result;
end $$;

revoke all on function api.portal_room_update_v1(uuid,text,jsonb,uuid) from public,anon,authenticated;

alter function api.portal_room_snapshot(text,uuid) rename to portal_room_snapshot_before_entrance;
revoke all on function api.portal_room_snapshot_before_entrance(text,uuid) from public,anon,authenticated;
create function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.portal_room_snapshot_before_entrance(_event_slug,_portal_id);
 if result is null then return null; end if;
 return jsonb_set(result,'{portal,publicEntranceInstructions}',to_jsonb(coalesce(app_private.portal_public_entrance((result#>>'{portal,id}')::uuid),'')));
end $$;
revoke all on function api.portal_room_snapshot(text,uuid) from public,anon;
grant execute on function api.portal_room_snapshot(text,uuid) to authenticated;

alter function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) rename to admin_manual_portal_save_before_entrance;
revoke all on function api.admin_manual_portal_save_before_entrance(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; replay boolean; eid uuid; proposed_position jsonb;
begin
 if char_length(coalesce(_payload->>'publicEntranceInstructions',''))>500 then raise exception 'INVALID_DETAILS' using errcode='22023'; end if;
 -- Share the delegated command's event lock before reading the receipt, including concurrent retries.
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not (app_private.has_capability(eid,'portals_manage',auth.uid()) or app_private.has_capability(eid,'event_admin',auth.uid()))
  or (_portal_id is not null and not exists(select 1 from app_private.portals p where p.id=_portal_id and p.event_id=eid)) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 select exists(select 1 from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.manual.save' and idempotency_key=_payload->>'commandKey') into replay;
 if not replay and _portal_id is not null and coalesce(_payload->>'saveMode','')<>'draft'
  and (_payload?'latitude' or _payload?'longitude') and app_private.portal_destination_in_use(_portal_id) then
  select app_private.routing_position(l.marker_latitude,l.marker_longitude,(_payload->>'latitude')::numeric,(_payload->>'longitude')::numeric,null,null)
   into proposed_position from app_private.portal_private_locations l where l.portal_id=_portal_id;
  if app_private.routing_coordinate(proposed_position) is distinct from app_private.routing_coordinate(app_private.portal_location(_portal_id)) then
   raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 end if;
 result:=api.admin_manual_portal_save_before_entrance(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if not replay and _payload?'publicEntranceInstructions' and coalesce(_payload->>'saveMode','')<>'draft' then
  update app_private.portals set public_entrance_instructions=trim(coalesce(_payload->>'publicEntranceInstructions','')) where id=(result->>'id')::uuid;
 end if;
 return result;
end $$;
revoke all on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;

alter function api.admin_portal_records_snapshot(text) rename to admin_portal_records_snapshot_before_entrance;
revoke all on function api.admin_portal_records_snapshot_before_entrance(text) from public,anon,authenticated;
create function api.admin_portal_records_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.admin_portal_records_snapshot_before_entrance(_event_slug);
 return jsonb_set(result,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
   'publicEntranceInstructions',app_private.portal_public_entrance((item->>'id')::uuid),
   'latitude',app_private.portal_location((item->>'id')::uuid)->'latitude',
   'longitude',app_private.portal_location((item->>'id')::uuid)->'longitude')) from jsonb_array_elements(result->'portals') item),'[]'::jsonb));
end $$;
revoke all on function api.admin_portal_records_snapshot(text) from public,anon;
grant execute on function api.admin_portal_records_snapshot(text) to authenticated;

CREATE OR REPLACE FUNCTION app_private.published_start_projection(_group_id uuid, _at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.group_start_publications; result jsonb; position jsonb;
begin
  select * into p from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1;
  if p.id is null or exists(select 1 from app_private.walking_groups g where g.id=_group_id and g.retired_at is not null)
    or exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order) then return null; end if;
  result:=jsonb_build_object('startsAt',p.starts_at,'revision',p.revision,
    'publishedAt',p.published_at,'addressReleaseAt',p.starts_at-interval '1 hour',
    'addressReleased',_at>=p.starts_at-interval '1 hour','canStart',_at>=p.starts_at,'timePublished',true,
    'name','Startlocatie volgt','locationName','Startlocatie volgt','startPoint','Startlocatie volgt',
    'address',null,'startAddress',null,'coordinate',null,'linkedPortalId',null);
  if _at>=p.starts_at-interval '1 hour' then
    position:=app_private.routing_position((p.point_snapshot->>'marker_latitude')::numeric,(p.point_snapshot->>'marker_longitude')::numeric,(p.point_snapshot->>'geocoded_latitude')::numeric,(p.point_snapshot->>'geocoded_longitude')::numeric,(p.point_snapshot->>'latitude')::numeric,(p.point_snapshot->>'longitude')::numeric);
    result:=result||jsonb_build_object('name',p.point_snapshot->>'name',
      'locationName',p.point_snapshot->>'name','startPoint',p.point_snapshot->>'name',
      'address',p.point_snapshot->>'private_address','startAddress',p.point_snapshot->>'private_address',
      'linkedPortalId',p.point_snapshot->>'linked_portal_id',
      'safeApproach',p.point_snapshot->>'safe_approach','arrivalInstructions',p.point_snapshot->>'public_arrival_instructions',
      'locationSource',position->'source','coordinate',app_private.routing_coordinate(position));
  end if;
  return result;
end;
$function$
;



-- Enrich only the already-authorized, already-released current stop. No future lookup/pool is returned.
alter function api.group_snapshot(uuid) rename to group_snapshot_before_destination;
revoke all on function api.group_snapshot_before_destination(uuid) from public,anon,authenticated;
create function api.group_snapshot(_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; pid uuid; location jsonb; detail jsonb;
begin
 result:=api.group_snapshot_before_destination(_group_id);
 pid:=(result#>>'{run,currentStop,portal,id}')::uuid;
 if pid is not null then
  location:=app_private.portal_location(pid);
  select jsonb_build_object('coordinate',app_private.routing_coordinate(location),'locationSource',location->'source',
   'city',l.city,'publicEntranceInstructions',app_private.portal_public_entrance(pid)) into detail
   from app_private.portal_private_locations l where l.portal_id=pid;
  result:=jsonb_set(result,'{run,currentStop,portal}',(result#>'{run,currentStop,portal}')||detail);
 end if;
 return result;
end $$;
revoke all on function api.group_snapshot(uuid) from public,anon;
grant execute on function api.group_snapshot(uuid) to authenticated;

create or replace function app_private.start_ops_route_preview(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; s app_private.group_schedule_revisions; point app_private.start_points;
  slot app_private.start_slots; settings app_private.event_route_settings; r app_private.group_runs;
  last_lon numeric; last_lat numeric; at_time timestamptz; start_time timestamptz;
  stops jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; chosen uuid[]:='{}'::uuid[]; candidate record;
  meters bigint:=0; seconds bigint:=0; walk_m bigint; walk_s bigint; provisional boolean:=false;
  remaining integer; visited integer:=0; child_count integer; fixed_portal uuid;
  preserved_portal uuid; eligible integer; step_free boolean; needs_anders boolean;
  frozen_start jsonb; origin_position jsonb; published_start_time timestamptz;
  linked_start uuid; counts_as_first boolean;
begin
  select * into g from app_private.walking_groups where id=_group_id;
  select * into r from app_private.group_runs where group_id=g.id order by case when status in ('live','paused') then 0 else 1 end,created_at desc,id desc limit 1;
  select * into s from app_private.group_schedule_revisions where id=coalesce(r.schedule_revision_id,g.current_schedule_revision_id);
  select * into slot from app_private.start_slots where id=coalesce(s.start_slot_id,g.start_slot_id);
  select * into point from app_private.start_points where id=slot.start_point_id;
  select * into settings from app_private.event_route_settings where event_id=g.event_id;
  if point.id is null or slot.id is null then return jsonb_build_object('groupId',g.id,'hasConfirmedStart',false,'stops','[]'::jsonb,'warnings',jsonb_build_array('Kies en bevestig eerst een startpunt en tijd.')); end if;
  select count(*) into child_count from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
  select exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id
    join app_private.children c on c.id=rc.child_id where a.group_id=g.id and a.superseded_at is null
      and rc.participation_status='active' and nullif(trim(c.accessibility_note),'') is not null) into step_free;
  -- A published appointment/run retains its own frozen start, even if the editable point moves.
  if s.state='published' then
    select pub.point_snapshot,pub.starts_at into frozen_start,published_start_time
    from app_private.group_start_publications pub where pub.group_id=g.id and pub.schedule_id=s.id
    order by pub.publication_order desc limit 1;
  end if;
  if frozen_start is not null then
    origin_position:=app_private.routing_position((frozen_start->>'marker_latitude')::numeric,(frozen_start->>'marker_longitude')::numeric,
      (frozen_start->>'geocoded_latitude')::numeric,(frozen_start->>'geocoded_longitude')::numeric,
      (frozen_start->>'latitude')::numeric,(frozen_start->>'longitude')::numeric);
    linked_start:=(frozen_start->>'linked_portal_id')::uuid;
    counts_as_first:=coalesce((frozen_start->>'counts_as_first_portal_visit')::boolean,false);
  else
    origin_position:=app_private.start_point_location(point.id);
    linked_start:=point.linked_portal_id; counts_as_first:=point.counts_as_first_portal_visit;
  end if;
  needs_anders:=cardinality(app_private.world_coverage_missing(g.event_id))>0;
  last_lon:=(origin_position->>'longitude')::numeric;
  last_lat:=(origin_position->>'latitude')::numeric;
  start_time:=coalesce(published_start_time,slot.starts_at); at_time:=start_time;
  if r.id is not null then
    select * into s from app_private.group_schedule_revisions where id=r.schedule_revision_id;
    at_time:=greatest(at_time,statement_timestamp());
    select coalesce(array_agg(coalesce(rs.portal_id,ps.portal_id)),array[]::uuid[]),
      count(*) filter(where coalesce(rs.stop_kind::text,'ordinary')='ordinary' and rs.outcome in ('visited','mixed','all_skipped') and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=rs.id))
    into chosen,visited from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
    where rs.run_id=r.id and rs.state='completed';
    select coalesce(rs.portal_id,ps.portal_id) into preserved_portal from app_private.run_stops rs
      left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where rs.id=r.current_stop_id;
    select (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'longitude')::numeric,
      (app_private.portal_location(coalesce(rs.portal_id,ps.portal_id))->>'latitude')::numeric into last_lon,last_lat
      from app_private.run_stops rs left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id
      where rs.run_id=r.id and rs.state='completed' order by rs.sequence desc limit 1;
    last_lon:=coalesce(last_lon,(origin_position->>'longitude')::numeric);
    last_lat:=coalesce(last_lat,(origin_position->>'latitude')::numeric);
  end if;
  remaining:=case when g.desired_ordinary_visits is null then 10000 else greatest(0,g.desired_ordinary_visits-visited) end;
  if not counts_as_first and linked_start is not null and linked_start is distinct from preserved_portal then
    chosen:=array_append(chosen,linked_start);
  elsif counts_as_first and r.id is null then fixed_portal:=linked_start; end if;
  select count(*) into eligible from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
    where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')
      and p.id<>settings.final_portal_id;

  loop
    exit when remaining<=0 and preserved_portal is null;
    select q.* into candidate from (
      select p.id,p.name,p.system_code,p.world_id,w.name world,w.slug world_slug,l.*,
        coalesce(m.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
          (app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric)))::bigint walk_m,
        m.duration_seconds::bigint walk_s,
        true geographic,
        final_path.duration_seconds final_seconds
      from app_private.portals p join app_private.worlds w on w.id=p.world_id
      join app_private.portal_private_locations l on l.portal_id=p.id and app_private.portal_location_ready(p.id)
      left join lateral app_private.destination_estimate(last_lat,last_lon,(app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric) m on true
      left join lateral app_private.destination_estimate((app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,(app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric) final_path on true
      where p.event_id=g.event_id and app_private.portal_location_ready(p.id) and p.id<>settings.final_portal_id and not(p.id=any(chosen))
        and (p.id=preserved_portal or (p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')))
        and (p.id=preserved_portal or not step_free or exists(select 1 from app_private.portal_applications application where application.id=p.application_id and application.private_draft_data->>'accessibility'='step_free'))
        and (preserved_portal is null or p.id=preserved_portal)
        and (preserved_portal is not null or fixed_portal is null or p.id=fixed_portal)
    ) q where q.walk_s is not null and (q.id=preserved_portal or (
      at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds))::integer)<=coalesce(s.effective_ordinary_stop_at,settings.global_ordinary_stop_at)
      and q.final_seconds is not null
      and at_time+make_interval(secs=>(q.walk_s+coalesce(app_private.portal_service_seconds(q.id,at_time+make_interval(secs=>q.walk_s::integer)),settings.ordinary_visit_seconds+settings.route_buffer_seconds)+q.final_seconds)::integer)<=app_private.schedule_latest_finale_arrival(s.id)
      and exists(select 1 from app_private.portal_windows win where win.portal_id=q.id
        and at_time+make_interval(secs=>q.walk_s::integer)>=win.opens_at
        and at_time+make_interval(secs=>q.walk_s::integer)<win.closes_at
        and at_time+make_interval(secs=>(q.walk_s+win.visit_minutes*60+win.buffer_minutes*60)::integer)<=win.closes_at
        and win.max_children_per_visit>=child_count)))
    order by case when needs_anders and not exists(select 1 from unnest(chosen) c(id)
      join app_private.portals cp on cp.id=c.id join app_private.worlds cw on cw.id=cp.world_id where cw.slug='anders')
      then case when q.world_slug='anders' then 0 else 1 end else 0 end,q.walk_s,q.walk_m,q.id limit 1;
    if candidate.id is null then
      if fixed_portal is not null then warnings:=warnings||jsonb_build_array('De gekoppelde eerste poort past niet veilig in dit tijdvenster. Controleer de afspraak.'); end if;
      exit;
    end if;
    walk_m:=candidate.walk_m; walk_s:=candidate.walk_s;
    provisional:=provisional or candidate.geographic;
    at_time:=at_time+make_interval(secs=>walk_s::integer);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world',candidate.world,'kind','ordinary',
      'coordinate',app_private.routing_coordinate(app_private.portal_location(candidate.id)),'publicEntranceInstructions',app_private.portal_public_entrance(candidate.id),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,
      'status',case when candidate.id=preserved_portal then 'current' else 'expected' end));
    meters:=meters+walk_m; seconds:=seconds+walk_s+coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds);
    at_time:=at_time+make_interval(secs=>coalesce(app_private.portal_service_seconds(candidate.id,at_time),settings.ordinary_visit_seconds+settings.route_buffer_seconds));
    last_lon:=(app_private.portal_location(candidate.id)->>'longitude')::numeric;
    last_lat:=(app_private.portal_location(candidate.id)->>'latitude')::numeric;
    chosen:=array_append(chosen,candidate.id); remaining:=remaining-1; preserved_portal:=null; fixed_portal:=null;
  end loop;
  select p.id,p.name,p.system_code,l.*,m.distance_m,m.duration_seconds into candidate
    from app_private.portals p join app_private.portal_private_locations l on l.portal_id=p.id
    left join lateral app_private.destination_estimate(last_lat,last_lon,(app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric) m on true where p.id=settings.final_portal_id;
  if candidate.id is not null and app_private.portal_location_ready(candidate.id) and candidate.duration_seconds is not null then
    walk_m:=coalesce(candidate.distance_m,ceil(app_private.location_distance_m(last_lat,last_lon,
      (app_private.portal_location(candidate.id)->>'latitude')::numeric,(app_private.portal_location(candidate.id)->>'longitude')::numeric)))::bigint;
    walk_s:=candidate.duration_seconds;
    provisional:=true;
    at_time:=greatest(at_time+make_interval(secs=>walk_s::integer),settings.finale_opens_at);
    stops:=stops||jsonb_build_array(jsonb_build_object('portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,
      'address',concat_ws(' ',candidate.street,candidate.house_number,candidate.addition),'world','Finale','kind','finale',
      'coordinate',app_private.routing_coordinate(app_private.portal_location(candidate.id)),'publicEntranceInstructions',app_private.portal_public_entrance(candidate.id),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',walk_m,'walkMinutes',ceil(walk_s/60.0),'plannedArrivalAt',at_time,'expectedCompletionAt',at_time+make_interval(secs=>settings.finale_show_seconds),'physicalEndsAt',at_time+make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds),'status','expected'));
    meters:=meters+walk_m; seconds:=seconds+walk_s;
    if at_time>app_private.schedule_latest_finale_arrival(s.id) or not settings.finale_available then warnings:=warnings||jsonb_build_array('Controleer het finalevenster: deze verwachte aankomst past niet.'); end if;
  else warnings:=warnings||jsonb_build_array('De eindpoort heeft geen geldig opgeslagen adres of marker — controleer de eindpoort.'); end if;
  if needs_anders and not exists(select 1 from jsonb_array_elements(stops) stop
    join app_private.portals p on p.id=(stop->>'portalId')::uuid join app_private.worlds w on w.id=p.world_id
    where stop->>'kind'='ordinary' and w.slug='anders') then
    warnings:=warnings||jsonb_build_array('Geen haalbare gewone Anders-poort in deze route. Plan waar mogelijk een passend bezoek voor de ontbrekende wereldzegels; dit blokkeert startafspraken niet.');
  end if;
  if provisional then warnings:=warnings||jsonb_build_array('Afstanden zijn hemelsbreed; reistijden zijn schattingen. Kies zelf hoe je naar de volgende poort gaat.'); end if;
  if jsonb_array_length(stops)-1<least(remaining+jsonb_array_length(stops)-1,eligible) then warnings:=warnings||jsonb_build_array('Niet ieder beschikbaar huis past binnen de gekozen bezoekgrens en tijdvensters.'); end if;
  return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
    'start',jsonb_build_object('pointId',point.id,'name',case when frozen_start is not null then frozen_start->>'name' else point.name end,'address',case when frozen_start is not null then frozen_start->>'private_address' else point.private_address end,'coordinate',app_private.routing_coordinate(origin_position),'arrivalInstructions',case when frozen_start is not null then frozen_start->>'public_arrival_instructions' else point.public_arrival_instructions end,'startsAt',start_time),
    'stops',stops,'totalMeters',meters,'totalMinutes',ceil(seconds/60.0),'eligiblePortalCount',eligible,'warnings',warnings,
    'provisional',provisional,'distanceMethod','straight_line','travelTimeEstimated',true,'hasConfirmedStart',app_private.is_start_confirmation_current(s.id) or s.state='published');
end;
$function$;


create or replace function app_private.dispatch_next_stop_before_visit_preference(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  settings app_private.event_route_settings;
  source_lat numeric; source_lon numeric; final_lat numeric; final_lon numeric; frozen_position jsonb;
  needs_step_free boolean;
  v_child_count integer;
  candidate record;
  finale_reservation_id uuid;
  ordinary_reservation_id uuid;
  next_stop_id uuid;
  next_sequence integer;
  potential_count integer := 0;
  finale_path record;
  earliest_finale timestamptz;
  decision_number integer;
  candidate_summary jsonb := '[]'::jsonb;
begin
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.status <> 'live' or run_record.current_stop_id is not null then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = run_record.schedule_revision_id and state = 'published';
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(group_record.event_id::text || ':route-dispatch', 0));

  update app_private.portal_reservations set status = 'expired', version = version + 1
  where event_id = group_record.event_id and status = 'held' and expires_at <= _decision_at;
  select count(*) into v_child_count from app_private.run_participants where run_id = _run_id and attendance = 'present';
  select exists (
    select 1 from app_private.run_participants participant
    join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
    join app_private.children child on child.id = registration_child.child_id
    where participant.run_id = _run_id and participant.attendance = 'present'
      and nullif(trim(child.accessibility_note), '') is not null
  ) into needs_step_free;
  select coalesce(max(sequence), 0) + 1 into next_sequence from app_private.run_stops where run_id = _run_id;
  select coalesce(max(sequence), 0) + 1 into decision_number from app_private.dispatch_decisions where run_id = _run_id;

  select (app_private.portal_location(stop.portal_id)->>'latitude')::numeric,
    (app_private.portal_location(stop.portal_id)->>'longitude')::numeric into source_lat,source_lon
  from app_private.run_stops stop where stop.run_id=_run_id and stop.plan_stop_id is null and stop.state='completed'
  order by stop.sequence desc limit 1;
  if source_lat is null or source_lon is null then
    select app_private.routing_position((p.point_snapshot->>'marker_latitude')::numeric,(p.point_snapshot->>'marker_longitude')::numeric,
      (p.point_snapshot->>'geocoded_latitude')::numeric,(p.point_snapshot->>'geocoded_longitude')::numeric,
      (p.point_snapshot->>'latitude')::numeric,(p.point_snapshot->>'longitude')::numeric) into frozen_position
    from app_private.group_start_publications p where p.group_id=group_record.id and p.schedule_id=run_record.schedule_revision_id
    order by p.publication_order desc limit 1;
    source_lat:=(frozen_position->>'latitude')::numeric; source_lon:=(frozen_position->>'longitude')::numeric;
  end if;
  if source_lat is null or source_lon is null then raise exception 'SOURCE_POSITION_INVALID' using errcode='23514'; end if;
  select (app_private.portal_location(settings.final_portal_id)->>'latitude')::numeric,
    (app_private.portal_location(settings.final_portal_id)->>'longitude')::numeric into final_lat,final_lon;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.event_id=group_record.event_id
      and portal.approval_status='approved' and portal.lifecycle_status='active'
      and app_private.portal_location_ready(portal.id) and portal.operation_status in ('open', 'scheduled')
  ) then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_UNAVAILABLE',
      'De eindpoort is niet veilig beschikbaar. Activeer de voorbereide noodafsluiting.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
    values (group_record.event_id, _run_id, decision_number, 'emergency', jsonb_build_object('decidedAt', _decision_at), candidate_summary,
      'Eindpoort niet beschikbaar; geen adres automatisch gepubliceerd');
    return jsonb_build_object('decision', 'emergency', 'paused', true);
  end if;

  if app_private.group_has_visited_portal(group_record.event_id,group_record.id,settings.final_portal_id) then
    update app_private.group_runs set status='completed',current_stop_id=null,finished_at=clock_timestamp(),version=version+1 where id=_run_id;
    update app_private.walking_groups set status='completed',version=version+1 where id=group_record.id;
    return jsonb_build_object('decision','completed');
  end if;
  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      select portal.id as portal_id, portal.world_id, portal.name,
        source_path.distance_m as incoming_distance_m, source_path.duration_seconds as incoming_seconds,
        source_path.edge_ids as incoming_edge_ids,
        final_path.duration_seconds as finale_seconds,
        _decision_at + make_interval(secs => source_path.duration_seconds::integer) as arrival_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) as departure_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) as earliest_finale_at,
        source_path.duration_seconds
          + case when portal.world_id = (
              select previous_portal.world_id from app_private.run_stops previous_stop
              join app_private.portals previous_portal on previous_portal.id = previous_stop.portal_id
              where previous_stop.run_id = _run_id and previous_stop.state = 'completed'
              order by previous_stop.sequence desc limit 1
            ) then 120 else 0 end
          + (select count(*) * 30 from app_private.portal_reservations pressure
             where pressure.portal_id = portal.id and pressure.status in ('held', 'active')) as score
      from app_private.portals portal
      left join app_private.portal_applications application on application.id = portal.application_id
      join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
      cross join lateral app_private.destination_estimate(source_lat,source_lon,(app_private.portal_location(portal.id)->>'latitude')::numeric,(app_private.portal_location(portal.id)->>'longitude')::numeric) source_path
      cross join lateral app_private.destination_estimate((app_private.portal_location(portal.id)->>'latitude')::numeric,(app_private.portal_location(portal.id)->>'longitude')::numeric,final_lat,final_lon) final_path
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)
        and exists (
          select 1 from app_private.portal_windows portal_window
          where portal_window.portal_id = portal.id
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) >= portal_window.opens_at
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) < portal_window.closes_at
            and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer) <= portal_window.closes_at
            and portal_window.max_children_per_visit>=v_child_count
        )
        and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) <= schedule.effective_ordinary_stop_at
        and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= app_private.schedule_latest_finale_arrival(schedule.id)
        and app_private.portal_interval_available(portal.id,group_record.id,
          _decision_at+make_interval(secs=>source_path.duration_seconds::integer),
          _decision_at+make_interval(secs=>(source_path.duration_seconds+app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer),v_child_count,_decision_at)
      order by score, incoming_distance_m, portal.id
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds)
      ) returning id into ordinary_reservation_id;
      insert into app_private.run_stops(
        run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at
      ) values (
        _run_id, candidate.portal_id, ordinary_reservation_id, 'ordinary', next_sequence, 'active', _decision_at
      ) returning id into next_stop_id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop_id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
      insert into app_private.dispatch_decisions(
        event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
        input_snapshot, candidate_summary, reason
      ) values (
        group_record.event_id, _run_id, decision_number, candidate.portal_id, 'ordinary', 'ordinary',
        jsonb_build_object(
          'decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op geschatte reistijd, beschikbaarheid en finalehaalbaarheid'
      );
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'ordinary', 'portalId', candidate.portal_id));
      return jsonb_build_object('decision', 'ordinary', 'stopId', next_stop_id, 'portalId', candidate.portal_id);
    end loop;

    if _preferred_portal_id is not null then
      raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;

    select count(*) into potential_count
    from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and app_private.portal_location_ready(portal.id)
    cross join lateral app_private.destination_estimate(source_lat,source_lon,(app_private.portal_location(portal.id)->>'latitude')::numeric,(app_private.portal_location(portal.id)->>'longitude')::numeric) source_path
    cross join lateral app_private.destination_estimate((app_private.portal_location(portal.id)->>'latitude')::numeric,(app_private.portal_location(portal.id)->>'longitude')::numeric,final_lat,final_lon) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_location_ready(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.group_id=group_record.id
          and pub.schedule_id=run_record.schedule_revision_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not app_private.group_has_visited_portal(group_record.event_id,group_record.id,portal.id)
      and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)))::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + app_private.portal_service_seconds(portal.id,_decision_at+make_interval(secs=>source_path.duration_seconds::integer)) + final_path.duration_seconds)::integer) <= app_private.schedule_latest_finale_arrival(schedule.id);
    if potential_count > 0 then
      insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
      values (group_record.event_id, _run_id, decision_number, 'wait',
        jsonb_build_object('decidedAt', _decision_at, 'effectiveStopAt', schedule.effective_ordinary_stop_at),
        candidate_summary, 'Veilige kandidaten zijn tijdelijk bezet; opnieuw beoordelen');
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select group_record.event_id, group_record.id, _run_id, 'warning', 'NO_CURRENT_CAPACITY',
        'Geen gewone poort is nu reserveerbaar; automatische herbeoordeling is nodig.'
      where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'NO_CURRENT_CAPACITY');
      return jsonb_build_object('decision', 'wait', 'retryAfterSeconds', 120);
    end if;
  end if;

  select * into finale_path from app_private.destination_estimate(source_lat,source_lon,final_lat,final_lon);
  if finale_path.duration_seconds is null then raise exception 'FINAL_PORTAL_POSITION_INVALID' using errcode = '23514'; end if;
  earliest_finale := _decision_at + make_interval(secs => finale_path.duration_seconds::integer);
  finale_reservation_id := app_private.try_reserve_finale(_run_id, earliest_finale, _decision_at);
  if finale_reservation_id is null then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_WINDOW_FULL',
      'Geen veilig aankomstvenster bij de eindpoort beschikbaar; handmatige herplanning vereist.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_WINDOW_FULL');
    return jsonb_build_object('decision', 'wait', 'finaleFull', true);
  end if;
  update app_private.portal_reservations set status = 'active', version = version + 1 where id = finale_reservation_id;
  insert into app_private.run_stops(run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at)
  values (_run_id, settings.final_portal_id, finale_reservation_id, 'finale', next_sequence, 'active', _decision_at)
  returning id into next_stop_id;
  insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
  select next_stop_id, participant.id from app_private.run_participants participant
  where participant.run_id = _run_id and participant.attendance = 'present';
  update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
  insert into app_private.dispatch_decisions(
    event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
    input_snapshot, candidate_summary, reason
  ) values (
    group_record.event_id, _run_id, decision_number, settings.final_portal_id, 'finale', 'finale',
    jsonb_build_object('decidedAt', _decision_at, 'distanceMethod','straight_line_estimate','travelTimeEstimated',true, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$function$
;


-- A moved destination must never silently redirect a group already travelling to it.
-- Future route previews are invalidated by the existing location/version hash.
alter function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) rename to admin_location_marker_save_before_active_destination;
revoke all on function api.admin_location_marker_save_before_active_destination(text,text,uuid,numeric,numeric,text,boolean,integer) from public,anon,authenticated;
create function api.admin_location_marker_save(_event_slug text,_resource_type text,_resource_id uuid,
 _latitude numeric,_longitude numeric,_reason text,_restore_from_address boolean,_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if auth.uid() is null or eid is null or not (app_private.has_capability(eid,'event_admin',auth.uid())
  or app_private.has_capability(eid,case when _resource_type='start_point' then 'groups_manage' else 'portals_manage' end,auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=eid for no key update;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 if _resource_type in ('portal','final_portal') and exists(select 1 from app_private.portals p where p.id=_resource_id and p.event_id=eid)
  and app_private.portal_destination_in_use(_resource_id) then
  raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 return api.admin_location_marker_save_before_active_destination(_event_slug,_resource_type,_resource_id,
  _latitude,_longitude,_reason,_restore_from_address,_expected_version);
end $$;
revoke all on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) from public,anon;
grant execute on function api.admin_location_marker_save(text,text,uuid,numeric,numeric,text,boolean,integer) to authenticated;
