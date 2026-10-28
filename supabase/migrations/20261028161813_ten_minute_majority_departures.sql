-- Gathering capacity is independent of departure capacity. Do not rewrite any
-- existing slot, membership, confirmed appointment, publication or outbox row.
set lock_timeout = '5s';

create or replace function app_private.dominant_time_preference(_registrations uuid[], _field text)
returns timestamptz language sql stable security definer set search_path = '' as $$
  with votes as (
    select case _field when 'start' then r.preferred_start_at when 'end' then r.desired_end_at end as t
    from app_private.registrations r
    where r.id = any(_registrations) and r.status = 'submitted'
  ), expressed as (select t from votes where t is not null)
  select t from expressed group by t
  order by count(*) desc,
    (select sum(abs(extract(epoch from (other.t - expressed.t)))) from expressed other), t
  limit 1
$$;
create or replace function app_private.dominant_start_preference(_registrations uuid[])
returns timestamptz language sql stable security definer set search_path = '' as $$
  select app_private.dominant_time_preference(_registrations, 'start')
$$;
create or replace function app_private.dominant_end_preference(_registrations uuid[])
returns timestamptz language sql stable security definer set search_path = '' as $$
  select app_private.dominant_time_preference(_registrations, 'end')
$$;
create or replace function app_private.valid_departure_time(_starts_at timestamptz)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(extract(minute from _starts_at at time zone 'Europe/Amsterdam')::integer % 10 = 0
    and extract(second from _starts_at at time zone 'Europe/Amsterdam') = 0, false)
$$;
-- The old discrete preference choices bound the departure window; ten-minute
-- departures between those bounds are valid even when not an original choice.
create or replace function app_private.departure_time_in_window(_event uuid, _starts_at timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(app_private.valid_departure_time(_starts_at)
    and _starts_at >= coalesce(settings.first_start_at, choices.first_choice)
    and _starts_at <= least(settings.global_ordinary_stop_at,
      coalesce(choices.last_choice, coalesce(settings.first_start_at,choices.first_choice) + interval '150 minutes'))
    and _starts_at < settings.global_ordinary_stop_at, false)
  from app_private.event_route_settings settings
  cross join lateral (select min(value::timestamptz) first_choice, max(value::timestamptz) last_choice
    from jsonb_array_elements_text(app_private.exact_preference_options(settings.event_id)->'allowedStartTimes')) choices
  where settings.event_id = _event
$$;
create or replace function app_private.start_departure_key(_point uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(p.linked_portal_id, p.id) from app_private.start_points p where p.id = _point
$$;
revoke all on function app_private.dominant_time_preference(uuid[],text),
  app_private.dominant_start_preference(uuid[]), app_private.dominant_end_preference(uuid[]),
  app_private.valid_departure_time(timestamptz), app_private.departure_time_in_window(uuid,timestamptz), app_private.start_departure_key(uuid)
  from public, anon, authenticated;

-- Legacy slot IDs/capacities remain intact; every new departure nevertheless
-- has one group of departure capacity and uses the Amsterdam ten-minute grid.
create or replace function app_private.guard_departure_slot()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from app_private.events where id = new.event_id for update;
  if tg_op = 'INSERT' or new.starts_at is distinct from old.starts_at
    or new.start_point_id is distinct from old.start_point_id then
    if not app_private.valid_departure_time(new.starts_at) then
      raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'UPDATE' and (new.starts_at is distinct from old.starts_at
    or new.start_point_id is distinct from old.start_point_id) and exists (
      select 1 from app_private.group_schedule_revisions s
      where s.start_slot_id = old.id and (s.confirmed_at is not null or s.state = 'published')
    ) then raise exception 'START_APPOINTMENT_PROTECTED' using errcode = '23514'; end if;
  new.max_groups := 1;
  return new;
end;
$$;
create trigger departure_slot_guard before insert or update on app_private.start_slots
for each row execute function app_private.guard_departure_slot();
revoke all on function app_private.guard_departure_slot() from public, anon, authenticated;

create or replace function api.admin_startregie_slots_prepare(_event_slug text, _starts_at timestamptz[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); event_record app_private.events; settings app_private.event_route_settings;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_starts_at), 0) = 0 or cardinality(_starts_at) > 100
    or exists (select 1 from unnest(_starts_at) t where not app_private.valid_departure_time(t)) then
    raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode = '22023';
  end if;
  select * into settings from app_private.event_route_settings where event_id = event_record.id;
  if settings.first_start_at is null or settings.global_ordinary_stop_at is null or exists (
    select 1 from unnest(_starts_at) as requested(starts_at)
    where not app_private.departure_time_in_window(event_record.id, requested.starts_at)
  ) then raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514'; end if;
  insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
    location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
  select event_record.id, point.name || ' ' || to_char(requested.starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
    point.name, point.private_address,
    coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude),
    coalesce(point.marker_longitude, point.geocoded_longitude, point.longitude), point.verified_at,
    requested.starts_at, 1, point.max_gathering_children, true, point.id
  from app_private.start_points point cross join (select distinct t as starts_at from unnest(_starts_at) t) requested
  where point.event_id = event_record.id and app_private.start_point_ready_at(point.id, requested.starts_at)
    and not exists (select 1 from app_private.start_slots existing
      where existing.start_point_id = point.id and existing.starts_at = requested.starts_at)
  on conflict do nothing;
  return jsonb_build_object('starts', coalesce((select jsonb_agg(jsonb_build_object(
    'id', slot.id, 'startPointId', slot.start_point_id, 'startsAt', slot.starts_at,
    'maxGroups', 1, 'maxChildren', least(slot.max_children, point.max_gathering_children)
  ) order by slot.starts_at, slot.start_point_id)
  from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
  where slot.event_id = event_record.id and slot.active and slot.starts_at = any(_starts_at)
    and app_private.start_point_ready_at(point.id, slot.starts_at)), '[]'::jsonb));
end;
$$;

-- A minority household's desired end is not a veto. Original registration IDs
-- are read once each, including all households within together blocks.
create or replace function app_private.validate_group_schedule_exact_preferences()
returns trigger language plpgsql security definer set search_path = '' as $$
declare starts_at timestamptz; dominant_end timestamptz; dominant_start timestamptz;
  registration_ids uuid[]; settings app_private.event_route_settings; ordinary_limit timestamptz;
begin
  select slot.starts_at into starts_at from app_private.start_slots slot where slot.id = new.start_slot_id;
  select route_settings.* into settings from app_private.event_route_settings route_settings
    join app_private.start_slots slot on slot.event_id = route_settings.event_id where slot.id = new.start_slot_id;
  select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
    coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at), settings.global_ordinary_stop_at))
    into registration_ids, ordinary_limit
    from app_private.group_registrations a join app_private.registrations r on r.id = a.registration_id
    where a.group_id = new.group_id and a.superseded_at is null and r.status = 'submitted';
  dominant_end := app_private.dominant_end_preference(registration_ids);
  dominant_start := app_private.dominant_start_preference(registration_ids);
  if dominant_end is not null then
    if starts_at >= dominant_end then raise exception 'GROUP_START_NOT_BEFORE_DESIRED_END' using errcode = '23514'; end if;
    ordinary_limit := least(ordinary_limit, dominant_end - make_interval(secs => settings.finale_show_seconds + settings.finale_planning_transfer_seconds));
  end if;
  new.effective_ordinary_stop_at := least(new.effective_ordinary_stop_at, ordinary_limit);
  if new.effective_ordinary_stop_at < starts_at then
    raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode = '23514';
  end if;
  if new.expected_finale_arrival_at is null
    or new.expected_finale_arrival_at < greatest(settings.finale_opens_at,
      new.effective_ordinary_stop_at + make_interval(secs => settings.finale_planning_transfer_seconds))
    or new.expected_finale_arrival_at > settings.finale_last_arrival_at
    or new.expected_finale_arrival_at + make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds) > settings.finale_closes_at
    or (dominant_end is not null and new.expected_finale_arrival_at + make_interval(secs => settings.finale_show_seconds) > dominant_end) then
    raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode = '23514';
  end if;
  new.input_snapshot := new.input_snapshot || jsonb_build_object('dominantStartAt', dominant_start, 'dominantEndAt', dominant_end);
  return new;
end;
$$;
drop trigger group_schedule_exact_preferences_guard on app_private.group_schedule_revisions;
create trigger group_schedule_exact_preferences_guard
before insert or update of start_slot_id, group_id, effective_ordinary_stop_at, expected_finale_arrival_at
on app_private.group_schedule_revisions for each row execute function app_private.validate_group_schedule_exact_preferences();

-- Preserve the existing canonical physical reception/finale capacity checks.
CREATE OR REPLACE FUNCTION app_private.validate_start_schedule_capacity(_event_id uuid, _schedule_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; settings app_private.event_route_settings; tick timestamptz; service_interval interval;
  load_groups integer; load_children bigint;
begin
  perform 1 from app_private.events where id=_event_id for update;
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
    if not app_private.valid_departure_time(candidate.starts_at) then
      raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode='23514'; end if;
    if not app_private.departure_time_in_window(_event_id,candidate.starts_at) then
      raise exception 'START_TIME_OUTSIDE_EVENT' using errcode='23514'; end if;
    if not app_private.start_point_ready_at(candidate.start_point_id,candidate.starts_at) then
      raise exception 'START_POINT_CLOSED' using errcode='23514'; end if;
    -- Coalesce aliases linked to the same real portal. Different slot IDs and
    -- start-point IDs never create a second departure at the same instant.
    select count(*) into load_groups from (
      select distinct r.group_id from app_private.start_schedule_reservations(_event_id) r
      where app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id)=app_private.reserved_departure_key(candidate.group_id,candidate.id,candidate.start_point_id)
        and r.starts_at=candidate.starts_at
      union select candidate.group_id
    ) physical_departures;
    if load_groups>1 then raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_slot_id=candidate.start_slot_id group by r.group_id) q;
    if load_groups>candidate.max_groups or load_children>candidate.max_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_point_id=candidate.start_point_id and r.starts_at=candidate.starts_at group by r.group_id) q;
    if load_groups>candidate.max_gathering_groups or load_children>candidate.max_gathering_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    if candidate.expected_finale_arrival_at is null or candidate.expected_finale_arrival_at<settings.finale_opens_at
      or candidate.expected_finale_arrival_at>settings.finale_last_arrival_at then
      raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    -- Half-open intervals, evaluated at every occupancy change. A group's
    -- overlapping old and new reservation contributes its children once.
    for tick in select distinct r.finale_at from app_private.start_schedule_reservations(_event_id) r
      where r.finale_at<candidate.expected_finale_arrival_at+service_interval
        and r.finale_at+service_interval>candidate.expected_finale_arrival_at
      union select candidate.expected_finale_arrival_at
    loop
      select count(*),coalesce(sum(n),0) into load_groups,load_children from (
        select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
        where r.finale_at<=tick and r.finale_at+service_interval>tick group by r.group_id) q;
      if load_groups>settings.finale_max_concurrent_groups or load_children>settings.finale_max_concurrent_children then
        raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    end loop;
    if exists(select 1 from app_private.start_points point where point.id=candidate.start_point_id and point.linked_portal_id is not null and
      not app_private.portal_interval_available(point.linked_portal_id,candidate.group_id,candidate.starts_at,
        candidate.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,candidate.starts_at)),
        (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null),statement_timestamp())) then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514';
    end if;
  end loop;
end;
$function$
;

-- Published reservations keep their physical portal as well as their instant.
create or replace function app_private.reserved_departure_key(_group uuid,_schedule uuid,_point uuid)
returns uuid language sql stable security definer set search_path='' as $$
  select coalesce((select coalesce((p.point_snapshot->>'linked_portal_id')::uuid,
      (p.slot_snapshot->>'start_point_id')::uuid)
    from app_private.group_start_publications p where p.group_id=_group and p.schedule_id is not distinct from _schedule
    order by p.publication_order desc limit 1),app_private.start_departure_key(_point))
$$;
revoke all on function app_private.reserved_departure_key(uuid,uuid,uuid) from public,anon,authenticated;

-- Keep all other reviewed group operations unchanged. Distribution is a draft
-- schedule command, so it neither confirms composition nor queues any mail.
alter function api.admin_group_operations_apply(text,text,text,jsonb,text) set schema app_private;
alter function app_private.admin_group_operations_apply(text,text,text,jsonb,text) rename to group_operations_apply_before_departure_slots;
revoke all on function app_private.group_operations_apply_before_departure_slots(text,text,text,jsonb,text) from public, anon, authenticated;
create or replace function api.admin_group_operations_apply(_event_slug text,_action text,_input_hash text,_payload jsonb,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e app_private.events; g app_private.walking_groups; settings app_private.event_route_settings;
  item jsonb; slot app_private.start_slots; registration_ids uuid[]; seen uuid[] := '{}';
  schedule_ids uuid[] := '{}'; receipt app_private.command_receipts; request_hash text; result jsonb;
  created jsonb; dominant_start timestamptz; dominant_end timestamptz;
  ordinary_limit timestamptz; effective_stop timestamptz; finale_arrival timestamptz; child_count integer;
  previous_schedules jsonb := '{}'; previous_schedule app_private.group_schedule_revisions;
begin
  if _action is distinct from 'distribute' then
    return app_private.group_operations_apply_before_departure_slots(_event_slug,_action,_input_hash,_payload,_idempotency_key);
  end if;
  select * into e from app_private.events where slug = _event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text || ':route-dispatch',0));
  if length(coalesce(_idempotency_key,'')) not between 16 and 200
    or jsonb_typeof(_payload->'groups') is distinct from 'array'
    or jsonb_array_length(_payload->'groups') not between 1 and 500 then
    raise exception 'INVALID_PLAN' using errcode = '22023'; end if;
  request_hash := encode(extensions.digest(jsonb_build_object('event',e.id,'action',_action,'inputHash',_input_hash,'payload',_payload)::text,'sha256'),'hex');
  select * into receipt from app_private.command_receipts
    where actor_id = auth.uid() and command_type = 'groups.distribute' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if _input_hash is distinct from app_private.group_operations_hash(e.id) then
    raise exception 'STALE_GROUP_INPUT' using errcode = '40001'; end if;
  select * into settings from app_private.event_route_settings where event_id = e.id;
  perform 1 from app_private.walking_groups where event_id = e.id order by id for update;
  -- Validate the entire movable cohort before releasing its old draft-only
  -- reservations. This permits atomic swaps/cycles; publications never leave
  -- the occupancy set and rollback restores every old pointer on any conflict.
  for item in select * from jsonb_array_elements(_payload->'groups') loop
    select * into g from app_private.walking_groups where id = (item->>'key')::uuid and event_id = e.id and retired_at is null;
    if g.id is null or g.id = any(seen) or g.status not in ('draft','ready')
      or exists(select 1 from app_private.group_runs r where r.group_id = g.id)
      or exists(select 1 from app_private.group_schedule_revisions current_schedule
        where current_schedule.id = g.current_schedule_revision_id
          and (current_schedule.confirmed_at is not null or current_schedule.state = 'published'))
      or exists(select 1 from app_private.current_start_publication(g.id)) then
      raise exception 'START_APPOINTMENT_PROTECTED' using errcode = '23514'; end if;
    select * into previous_schedule from app_private.group_schedule_revisions where id = g.current_schedule_revision_id;
    previous_schedules := previous_schedules || jsonb_build_object(g.id::text,
      jsonb_build_object('id',previous_schedule.id,'revision',previous_schedule.revision));
    seen := array_append(seen,g.id);
  end loop;
  update app_private.walking_groups set current_schedule_revision_id = null where id = any(seen);
  seen := '{}';
  for item in select * from jsonb_array_elements(_payload->'groups') loop
    select * into g from app_private.walking_groups where id = (item->>'key')::uuid and event_id = e.id and retired_at is null;
    if g.id is null or g.id = any(seen) or g.status not in ('draft','ready')
      or exists(select 1 from app_private.group_runs r where r.group_id = g.id)
      or exists(select 1 from app_private.group_schedule_revisions s where s.id = g.current_schedule_revision_id
        and (s.confirmed_at is not null or s.state = 'published'))
      or exists(select 1 from app_private.current_start_publication(g.id)) then
      raise exception 'START_APPOINTMENT_PROTECTED' using errcode = '23514'; end if;
    select * into slot from app_private.start_slots where id = (item->>'startId')::uuid and event_id = e.id and active;
    if slot.id is null or not app_private.departure_time_in_window(e.id,slot.starts_at)
      or not app_private.start_point_ready_at(slot.start_point_id,slot.starts_at) then
      raise exception 'INVALID_START' using errcode = '23514'; end if;
    select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
      coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at),settings.global_ordinary_stop_at))
      into registration_ids, ordinary_limit
      from app_private.group_registrations a join app_private.registrations r on r.id = a.registration_id and r.status = 'submitted'
      where a.group_id = g.id and a.superseded_at is null;
    select count(*) into child_count from app_private.registration_children c
      where c.registration_id = any(registration_ids) and c.participation_status = 'active';
    if child_count < 1 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
    dominant_start := app_private.dominant_start_preference(registration_ids);
    dominant_end := app_private.dominant_end_preference(registration_ids);
    if dominant_end is not null then ordinary_limit := least(ordinary_limit,
      dominant_end - make_interval(secs => settings.finale_show_seconds + settings.finale_planning_transfer_seconds)); end if;
    effective_stop := coalesce(nullif(item->>'effectiveStopAt','')::timestamptz,ordinary_limit);
    finale_arrival := nullif(item->>'expectedFinaleArrivalAt','')::timestamptz;
    if effective_stop > ordinary_limit or effective_stop < slot.starts_at then
      raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode = '23514'; end if;
    created := api.admin_save_group_schedule(g.id,slot.id,effective_stop,finale_arrival,null,
      coalesce(item->>'preferenceMatch','neutral'),'Automatische slotverdeling na actuele preview');
    update app_private.group_schedule_revisions set supersedes_id = (previous_schedules->g.id::text->>'id')::uuid,
      input_snapshot = input_snapshot || item
      || jsonb_build_object('previousRevision',previous_schedules->g.id::text->'revision',
        'dominantStartAt',dominant_start,'dominantEndAt',dominant_end,
        'effectiveStopAt',effective_stop,'expectedFinaleArrivalAt',finale_arrival)
      where id = (created->>'id')::uuid;
    schedule_ids := array_append(schedule_ids,(created->>'id')::uuid);
    seen := array_append(seen,g.id);
  end loop;
  perform app_private.validate_start_schedule_capacity(e.id,schedule_ids);
  result := jsonb_build_object('plannedGroups',cardinality(schedule_ids),'scheduleIds',schedule_ids);
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change)
    values(e.id,auth.uid(),'groups.distribute','group_operations',jsonb_build_object('inputHash',_input_hash,'result',result));
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'groups.distribute',_idempotency_key,request_hash,result,now() + interval '7 days');
  perform realtime.send(jsonb_build_object('resource','group_composition'),'snapshot_changed','admin-event:' || e.id,true);
  return result;
end;
$$;
revoke all on function api.admin_group_operations_apply(text,text,text,jsonb,text),
  api.admin_startregie_slots_prepare(text,timestamptz[]) from public, anon;
grant execute on function api.admin_group_operations_apply(text,text,text,jsonb,text),
  api.admin_startregie_slots_prepare(text,timestamptz[]) to authenticated;
notify pgrst, 'reload schema';

-- The isolated server rehearsal also creates a genuine valid departure.
-- A rehearsal writes only a fresh isolated event and rolls the entire fixture
-- transaction back before returning its measured report. It never opens a real run.
create or replace function api.redesign_rehearsal(_event_slug text,_scenario text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ownerid uuid:=auth.uid(); realevent uuid; eventid uuid:=gen_random_uuid(); homeid uuid:=gen_random_uuid(); registrationid uuid:=gen_random_uuid();
 groupid uuid:=gen_random_uuid(); planid uuid:=gen_random_uuid(); worldid uuid:=gen_random_uuid(); childids uuid[]:='{}'; rcids uuid[]:='{}'; portalids uuid[]:='{}'; tokens text[]:='{}';
 slotid uuid:=gen_random_uuid(); nodeid uuid; previousnode uuid:=gen_random_uuid(); runid uuid; activeid uuid; r app_private.group_runs; fixtureid uuid; portalid uuid; applicationid uuid; childid uuid; rcid uuid; participantid uuid;
 i integer; n integer; operation jsonb; scenarios jsonb:='{"start": [{"op": "empty", "title": "Start zonder aanwezigen weigeren", "history": 0, "sequence": 0, "status": "before", "seals": [0, 0, 0], "error": "EMPTY_GROUP"}, {"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Twee aanwezige kinderen bereiken de poort", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}, {"op": "snapshot", "title": "Afwezig kind krijgt geen zegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}], "arrival": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Precies de volgende bestemming staat klaar", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "inclusive": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Buiten blijven krijgt dezelfde aankomstzegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "wrong": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "wrong", "title": "Een verkeerde poortcode weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "WRONG_PORTAL"}], "duplicate": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Dezelfde opdracht blijft eenmalig", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "closed": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "close", "title": "Eigen oefenpoort sluiten", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij gesloten poort weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "PORTAL_UNAVAILABLE"}, {"op": "systemskip", "title": "Expliciete systeemoverslag zonder zegel", "history": 1, "sequence": 2, "status": "live", "seals": [0, 0, 0]}], "manual": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "skipall", "title": "Alle kinderen slaan de beleving over", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Zonder aankomst niet afronden", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "SCAN_REQUIRED"}, {"op": "scan", "title": "Alleen code bevestigen zonder definitieve zegels", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Met aankomst iedereen een zegel geven", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "offline": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "offline", "title": "Verbinding weg: geen serveropdracht ontvangen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Na herstel dezelfde aankomst bevestigen", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Herhaalde ontvangst maakt geen duplicaat", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "stale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "stale", "title": "Oude routeversie weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "STALE_VERSION"}], "early": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "departall", "title": "Eigen gezin sluit af zonder finale", "history": 2, "sequence": 0, "status": "stopped", "seals": [2, 2, 2]}], "part-departure": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "departone", "title": "Een kind vertrekt; de groep loopt door", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Vertrokken kind krijgt geen volgende zegel", "history": 2, "sequence": 3, "status": "live", "seals": [2, 1, 2]}], "finale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "arrive", "title": "Aankomst bij poort 3", "history": 3, "sequence": 4, "status": "live", "seals": [3, 3, 3]}, {"op": "arrive", "title": "Aankomst bij poort 4", "history": 4, "sequence": 5, "status": "live", "seals": [4, 4, 4]}, {"op": "arrive", "title": "Finaleaankomst telt ook bij buiten blijven", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "snapshot", "title": "Ieder aanwezig kind heeft precies een finalezegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "repeat", "title": "Geen dubbele finale of zesde zegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}]}'::jsonb; spec jsonb; report jsonb:='[]'; results jsonb; request jsonb; previous jsonb;
 problem text; currentportal uuid; token text; runversion integer; stopid uuid; leavingids uuid[]; choices jsonb; started timestamptz:=clock_timestamp(); tick timestamptz;
 actualhistory integer; actualseq integer; actualstatus text; sealcounts jsonb; view jsonb; ok boolean;
begin
 select id into realevent from app_private.events where slug=_event_slug;
 if ownerid is null or realevent is null or not (app_private.has_capability(realevent,'live_support',ownerid) or app_private.has_capability(realevent,'event_admin',ownerid)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 spec:=scenarios->_scenario;
 if spec is null then raise exception 'INVALID_SCENARIO'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ownerid::text||':redesign-rehearsal',0));
 begin
  insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings) values(eventid,'rehearsal-'||replace(eventid::text,'-',''),'Geïsoleerde generale',(now() at time zone 'Europe/Amsterdam')::date,'live',0,'{"rehearsal":true}');
  insert into app_private.households(id,label,primary_contact_user_id) values(homeid,'Oefengezin',ownerid);
  insert into app_private.household_members(household_id,user_id,relation_role) values(homeid,ownerid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(registrationid,eventid,homeid,'submitted','LAB-'||registrationid::text);
  for i in 1..3 loop
   insert into app_private.children(household_id,first_name,age_at_event) values(homeid,(array['Oefenkind A','Oefenkind B','Oefenkind C'])[i],8) returning id into childid;
   insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registrationid,childid,0) returning id into rcid;
   childids:=array_append(childids,childid);rcids:=array_append(rcids,rcid);
  end loop;
  insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,starts_at,max_groups,max_children) values(slotid,eventid,'lab-start','Oefenstart','Oefenlocatie','Geïsoleerd oefenadres',date_bin(interval '10 minutes',now(),'2000-01-01Z'::timestamptz)-interval '1 hour',1,20);
  insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at) values(previousnode,eventid,'lab-start','start',point(4.26,52.10),now());
  for i in 1..5 loop
   worldid:=gen_random_uuid();
   insert into app_private.worlds(id,event_id,slug,name,sort_order) values(worldid,eventid,'oefenwereld-'||i,'Oefenwereld '||i,i);
   applicationid:=gen_random_uuid();portalid:=gen_random_uuid();token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status) values(applicationid,eventid,ownerid,'approved');
   insert into app_private.portals(id,event_id,application_id,world_id,name,intensity,operation_status) values(portalid,eventid,applicationid,worldid,'Oefenpoort '||i,1,'open');
   insert into app_private.portal_owners(portal_id,user_id,role) values(portalid,ownerid,'owner');
   insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from) values(portalid,extensions.digest(token,'sha256'),extensions.digest(upper(token),'sha256'),1,now()-interval '1 minute');
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26,now());
   insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit) values(portalid,now()-interval '1 hour',now()+interval '5 hours',3,1,20);
   nodeid:=gen_random_uuid();
   insert into app_private.walking_nodes(id,event_id,kind,portal_id,coordinate,verified_at) values(nodeid,eventid,'portal',portalid,point(4.26+i*.0001,52.10),now());
   insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by) values(eventid,previousnode,nodeid,10,10,now(),ownerid);
   previousnode:=nodeid;
   portalids:=array_append(portalids,portalid);tokens:=array_append(tokens,token);
  end loop;
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id) values(groupid,eventid,'LAB-01','ready',slotid);
  insert into app_private.group_leaders(group_id,user_id,active_from,revision) values(groupid,ownerid,now()-interval '1 minute',1);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(groupid,registrationid,1,now());
  insert into app_private.route_plan_versions(id,group_id,revision,state,input_hash) values(planid,groupid,1,'draft',eventid::text);
  for i in 1..5 loop
   insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at) values(planid,i,portalids[i],now()+i*interval '5 minutes',now()+(i*5+3)*interval '1 minute');
  end loop;
  update app_private.route_plan_versions set state='published',published_at=now() where id=planid;
  update app_private.walking_groups set current_plan_version_id=planid where id=groupid;
  for operation in select * from jsonb_array_elements(spec) loop
   problem:=null;tick:=clock_timestamp();
   select * into r from app_private.group_runs where id=runid;
   if r.id is not null then
    select s.sequence,coalesce(s.portal_id,p.portal_id) into n,currentportal from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=r.current_stop_id;
    token:=tokens[array_position(portalids,currentportal)];
    select jsonb_object_agg(rp.id::text,case when rc.child_id=childids[2] then 'skipped' else 'visited' end) into choices
     from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present';
    request:=jsonb_build_object('run',runid,'stop',r.current_stop_id,'version',r.version,'token',token,'choices',choices,'key',gen_random_uuid()::text);
   end if;
   begin
    case operation->>'op'
    when 'empty' then perform api.run_start(groupid,'{}'::uuid[],(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'empty');
    when 'start' then
      results:=api.run_start(groupid,case when _scenario='start' then rcids[1:2] else rcids end,(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'start');
      runid:=(results->>'runId')::uuid;
      -- A genuine finale flag on the final isolated stop exercises the same completion transaction.
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','held',now(),now()+interval '2 hours',3) returning id into fixtureid;
      update app_private.run_stops set stop_kind='finale',portal_id=portalids[5],reservation_id=fixtureid,plan_stop_id=null where run_id=runid and sequence=5;
    when 'arrive','wrong','stale','repeat' then
      if operation->>'op'='repeat' then request:=previous; end if;
      perform api.run_arrive_and_advance((request->>'run')::uuid,(request->>'stop')::uuid,(request->>'version')::integer-case when operation->>'op'='stale' then 1 else 0 end,
       case when operation->>'op'='wrong' then encode(extensions.gen_random_bytes(32),'hex') else request->>'token' end,request->'choices',request->>'key');
      previous:=request;
    when 'close' then perform api.portal_set_operational_state(currentportal,'closed',(select version from app_private.portals where id=currentportal),'Geïsoleerde generale');
    when 'systemskip' then perform api.run_system_skip(runid,r.current_stop_id,r.version,'Gesloten oefenpoort',gen_random_uuid()::text,'system-skip');
    when 'skipall' then perform api.run_bulk_skip_pending(runid,r.current_stop_id,r.version,'Met oefenouder bevestigd',gen_random_uuid()::text,'skip-all');
    when 'complete' then perform api.run_complete_stop(runid,r.current_stop_id,r.version,true,gen_random_uuid()::text,'manual-complete');
    when 'scan' then perform api.run_scan(runid,r.current_stop_id,r.version,token,'qr');
    when 'departone','departall' then
      select array_agg(rp.id order by rp.id) into leavingids from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present' and (operation->>'op'='departall' or rc.child_id=childids[2]);
      perform api.run_end_early(runid,r.version,leavingids,'Eigen oefengezin sluit af',gen_random_uuid()::text);
      -- Restore the immutable child order used by the measurement projection.
      select array_agg(rc.child_id order by array_position(rcids,rc.id)) into childids from app_private.registration_children rc where rc.id=any(rcids);
    when 'offline' then null; -- Simulated transport omission: deliberately issue no SQL command.
    when 'snapshot' then null;
    else raise exception 'INVALID_SCENARIO';
    end case;
   exception when others then problem:=SQLERRM;
   end;
   select * into r from app_private.group_runs where id=runid;
   select count(*) into actualhistory from app_private.run_stops where run_id=runid and state='completed';
   select coalesce(sequence,0) into actualseq from app_private.run_stops where id=r.current_stop_id;actualseq:=coalesce(actualseq,0);
   actualstatus:=coalesce(r.status::text,'before');
   select jsonb_agg((select count(*) from app_private.poortenboek_passport_seals seal where seal.event_id=eventid and seal.child_id=rc.child_id) order by array_position(rcids,rc.id)) into sealcounts from app_private.registration_children rc where rc.id=any(rcids);
   ok:=problem is not distinct from operation->>'error' and actualhistory=(operation->>'history')::integer and actualseq=(operation->>'sequence')::integer and actualstatus=operation->>'status' and sealcounts=operation->'seals';
   if _scenario='finale' and actualstatus='completed' then ok:=ok and (select count(*)=3 from app_private.poortenboek_passport_seals where event_id=eventid and finale); end if;
   view:=jsonb_build_object('connected',operation->>'op'<>'offline','parent',jsonb_build_object('status',actualstatus,'stop',case when actualseq=0 then 'Geen actieve bestemming' else 'Oefenpoort '||actualseq end,'sequence',actualseq,'version',coalesce(r.version,0),'arrived',actualhistory>0,'endedEarly',r.stopped_reason='all_participants_departed'),
    'gate',jsonb_build_object('name','Geïsoleerde oefenpoort','code','LAB','status',coalesce((select operation_status from app_private.portals where id=currentportal),'open'),'scanned',exists(select 1 from app_private.scan_evidence where run_stop_id=r.current_stop_id)),
    'children',(select jsonb_agg(jsonb_build_object('id',rc.id,'name',c.first_name,'attendance',coalesce(rp.attendance::text,'absent'),'choice','Eigen keuze','seals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id),'finaleSeals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id and finale)) order by array_position(rcids,rc.id)) from app_private.registration_children rc join app_private.children c on c.id=rc.child_id left join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=runid where rc.id=any(rcids)),
    'history',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'name','Oefenpoort '||sequence,'outcome',outcome,'arrived',outcome<>'system_skipped') order by sequence) from app_private.run_stops where run_id=runid and state='completed'),'[]'::jsonb));
   report:=report||jsonb_build_array(jsonb_build_object('title',operation->>'title','expectation',(operation-'op'-'title')::text,'actual',jsonb_build_object('error',problem,'history',actualhistory,'sequence',actualseq,'status',actualstatus,'seals',sealcounts)::text,'passed',coalesce(ok,false),'at',clock_timestamp(),'durationMs',round(extract(epoch from clock_timestamp()-tick)*1000),'command',operation->>'op','view',view));
  end loop;
  raise exception using errcode='P7711',message='ROLLBACK_ISOLATED_REHEARSAL';
 exception when sqlstate 'P7711' then null;
 end;
 return jsonb_build_object('scenarioId',_scenario,'title',_scenario,'startedAt',started,'endedAt',clock_timestamp(),'passed',not exists(select 1 from jsonb_array_elements(report) item where not (item->>'passed')::boolean),'steps',report,'environment','Isolated SQL transaction; fixtures rolled back; external transport is not measured');
end $$;
revoke all on function api.redesign_rehearsal(text,text) from public,anon;
grant execute on function api.redesign_rehearsal(text,text) to authenticated;

-- Manual first appointments derive the same majority deadline as proposals.
CREATE OR REPLACE FUNCTION api.admin_startregie_move_group(_group_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _expected_group_version integer, _preference_match text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid(); group_record app_private.walking_groups; point_record app_private.start_points;
  settings app_private.event_route_settings; portal_record app_private.portals; slot_record app_private.start_slots;
  schedule_record app_private.group_schedule_revisions; result jsonb; group_children integer; occupied_groups integer; occupied_children integer; registration_ids uuid[]; dominant_end timestamptz; effective_stop timestamptz; finale_arrival timestamptz;
begin
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if actor is null or group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if exists(select 1 from app_private.group_runs where group_id=group_record.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  if _expected_group_version is distinct from group_record.version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
    or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  select * into point_record from app_private.start_points
    where id = _start_point_id and event_id = group_record.event_id and active for update;
  if point_record.id is null then raise exception 'START_POINT_NOT_AVAILABLE' using errcode = '23514'; end if;
  if not app_private.start_point_safe_connection(point_record.id) then raise exception 'START_POINT_NOT_VERIFIED' using errcode='23514'; end if;
  if not (app_private.start_point_location(point_record.id)->>'valid')::boolean then
    raise exception 'START_POINT_MARKER_INVALID' using errcode = '23514';
  end if;
  if settings.first_start_at is null or settings.global_ordinary_stop_at is null
    or _starts_at < settings.first_start_at or _starts_at > settings.global_ordinary_stop_at then
    raise exception 'START_TIME_OUTSIDE_EVENT' using errcode = '23514';
  end if;
  if (point_record.available_from is not null and _starts_at < point_record.available_from)
    or (point_record.available_until is not null and _starts_at > point_record.available_until) then
    raise exception 'START_POINT_CLOSED' using errcode = '23514';
  end if;
  if point_record.linked_portal_id is not null then
    select * into portal_record from app_private.portals where id = point_record.linked_portal_id;
    if portal_record.lifecycle_status <> 'active' or portal_record.approval_status <> 'approved'
      or not exists (select 1 from app_private.portal_windows portal_window where portal_window.portal_id = portal_record.id
        and _starts_at >= portal_window.opens_at and _starts_at < portal_window.closes_at) then
      raise exception 'LINKED_PORTAL_NOT_OPEN' using errcode = '23514';
    end if;
  end if;

  select * into slot_record from app_private.start_slots
    where start_point_id = point_record.id and starts_at = _starts_at and active for update;
  if slot_record.id is null then
    insert into app_private.start_slots(event_id, name, location_name, private_address, latitude, longitude,
      location_verified_at, starts_at, max_groups, max_children, active, start_point_id)
    values (group_record.event_id, point_record.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point_record.name, point_record.private_address,
      coalesce(point_record.marker_latitude, point_record.geocoded_latitude, point_record.latitude),
      coalesce(point_record.marker_longitude, point_record.geocoded_longitude, point_record.longitude),
      point_record.verified_at, _starts_at, point_record.max_gathering_groups,
      point_record.max_gathering_children, true, point_record.id)
    returning * into slot_record;
  end if;

  select count(*)::integer,
    coalesce(sum((select count(*) from app_private.group_registrations assignment
      join app_private.registration_children child on child.registration_id = assignment.registration_id
        and child.participation_status = 'active'
      where assignment.group_id = other_group.id and assignment.superseded_at is null)), 0)::integer
  into occupied_groups, occupied_children
  from app_private.walking_groups other_group
  join app_private.group_schedule_revisions other_schedule on other_schedule.id = other_group.current_schedule_revision_id
  join app_private.start_slots other_slot on other_slot.id = other_schedule.start_slot_id
  where other_group.event_id = group_record.event_id and other_group.id <> group_record.id
    and other_slot.start_point_id = point_record.id and other_slot.starts_at = _starts_at;
  select count(*)::integer into group_children from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id
      and child.participation_status = 'active'
    where assignment.group_id = group_record.id and assignment.superseded_at is null;
  if occupied_groups + 1 > least(slot_record.max_groups, point_record.max_gathering_groups)
    or occupied_children + group_children > least(slot_record.max_children, point_record.max_gathering_children) then
    raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode = '23514';
  end if;

  select * into schedule_record from app_private.group_schedule_revisions where id = group_record.current_schedule_revision_id;
  select array_agg(distinct a.registration_id), least(settings.global_ordinary_stop_at,
    coalesce(schedule_record.effective_ordinary_stop_at,settings.global_ordinary_stop_at),
    coalesce(min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at),settings.global_ordinary_stop_at))
    into registration_ids,effective_stop from app_private.group_registrations a
    join app_private.registrations r on r.id=a.registration_id and r.status='submitted'
    where a.group_id=group_record.id and a.superseded_at is null;
  dominant_end := app_private.dominant_end_preference(registration_ids);
  if dominant_end is not null then effective_stop := least(effective_stop,
    dominant_end-make_interval(secs=>settings.finale_show_seconds+settings.finale_planning_transfer_seconds)); end if;
  finale_arrival := coalesce(schedule_record.expected_finale_arrival_at,
    greatest(settings.finale_opens_at,effective_stop+make_interval(secs=>settings.finale_planning_transfer_seconds)));
  result := api.admin_save_group_schedule(
    group_record.id, slot_record.id, effective_stop, finale_arrival,
    schedule_record.queue_number, _preference_match, _reason
  );
  perform realtime.send(jsonb_build_object('resource', 'start_planning', 'groupId', group_record.id),
    'snapshot_changed', 'admin-event:' || group_record.event_id::text, true);
  return result || jsonb_build_object('previousStartSlotId', schedule_record.start_slot_id,
    'startPointId', point_record.id, 'startsAt', slot_record.starts_at);
end;
$function$;

-- Earlier feasible finale gaps preserve their explicitly shortened ordinary route.
CREATE OR REPLACE FUNCTION api.admin_apply_dynamic_plan(_event_slug text, _proposal jsonb, _input_hash text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  settings app_private.event_route_settings;
  group_item jsonb;
  registration_value jsonb;
  v_group_id uuid;
  v_schedule_id uuid;
  v_start_id uuid;
  v_effective_stop timestamptz;
  v_expected_finale timestamptz;
  v_group_number integer; v_dominant_end timestamptz; v_proposed_stop timestamptz;
  receipt app_private.command_receipts;
  schedule_ids uuid[] := '{}'::uuid[]; canonical_request_hash text; actual_children integer;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id;
  if settings.planner_mode not in ('shadow', 'dynamic') or settings.global_ordinary_stop_at is null or settings.final_portal_id is null then
    raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514';
  end if;
  if length(coalesce(_idempotency_key,'')) not between 8 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode='22023'; end if;
  canonical_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object('proposal',_proposal,'inputHash',_input_hash)::text,'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':admin.applyDynamicPlan:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'admin.applyDynamicPlan' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> canonical_request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if _input_hash is distinct from app_private.start_planning_input_hash(v_event_id) then raise exception 'STALE_PLANNING_INPUT' using errcode='40001'; end if;
  if jsonb_typeof(_proposal -> 'groups') <> 'array' or jsonb_array_length(_proposal -> 'groups') = 0 then
    raise exception 'EMPTY_PLAN' using errcode = '23514';
  end if;
  select coalesce(max(nullif(regexp_replace(code, '[^0-9]', '', 'g'), '')::integer), 0)
  into v_group_number from app_private.walking_groups where event_id = v_event_id;

  for group_item in select value from jsonb_array_elements(_proposal -> 'groups') loop
    v_group_number := v_group_number + 1;
    v_start_id := (group_item ->> 'startId')::uuid;
    if not exists (
      select 1 from app_private.start_slots slot
      join app_private.start_points point on point.id = slot.start_point_id
      where slot.id = v_start_id and slot.event_id = v_event_id and slot.active
        and app_private.start_point_ready_at(point.id,slot.starts_at)
    ) then raise exception 'INVALID_START' using errcode = '23514'; end if;
    if jsonb_typeof(group_item -> 'partyIds') <> 'array' or jsonb_array_length(group_item -> 'partyIds') = 0 then
      raise exception 'INVALID_GROUP' using errcode = '23514';
    end if;
    select least(
      settings.global_ordinary_stop_at,
      coalesce(min(registration.requested_ordinary_stop_at) filter(where registration.requested_ordinary_stop_at is distinct from registration.desired_end_at), settings.global_ordinary_stop_at)
    ) into v_effective_stop
    from app_private.registrations registration
    where registration.id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'));
    v_dominant_end := app_private.dominant_end_preference(array(select value::uuid from jsonb_array_elements_text(group_item->'partyIds')));
    if v_dominant_end is not null then v_effective_stop := least(v_effective_stop,
      v_dominant_end-make_interval(secs=>settings.finale_show_seconds+settings.finale_planning_transfer_seconds)); end if;
    v_proposed_stop := nullif(group_item->>'effectiveStopAt','')::timestamptz;
    if v_proposed_stop > v_effective_stop then raise exception 'GROUP_END_TIME_INFEASIBLE' using errcode='23514'; end if;
    v_effective_stop := coalesce(v_proposed_stop,v_effective_stop);
    v_expected_finale := coalesce(nullif(group_item ->> 'expectedFinaleArrivalAt', '')::timestamptz,
      greatest(settings.finale_opens_at,v_effective_stop+make_interval(secs=>settings.finale_planning_transfer_seconds)));
    if v_effective_stop is null or v_expected_finale < settings.finale_opens_at or v_expected_finale > settings.finale_last_arrival_at then
      raise exception 'FINALE_WINDOW_CONFLICT' using errcode = '23514';
    end if;

    select count(*) into actual_children from app_private.registration_children c
      where c.registration_id in(select value::uuid from jsonb_array_elements_text(group_item->'partyIds')) and c.participation_status='active';
    if actual_children<1 or actual_children is distinct from (group_item->>'childCount')::integer
      or actual_children>app_private.event_group_size_limit(v_event_id) then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514'; end if;
    -- Unpaid is an operational warning; financial status is preserved.

    insert into app_private.walking_groups(event_id, code, status, start_slot_id, route_mode)
    values (v_event_id, 'D-' || to_char(v_group_number, 'FM000'), 'draft', v_start_id, 'dynamic')
    returning id into v_group_id;
    for registration_value in select value from jsonb_array_elements(group_item -> 'partyIds') loop
      if not exists (
        select 1 from app_private.registrations registration
        where registration.id = (registration_value #>> '{}')::uuid and registration.event_id = v_event_id and registration.status = 'submitted'
      ) or exists (
        select 1 from app_private.group_registrations assignment
        where assignment.registration_id = (registration_value #>> '{}')::uuid and assignment.superseded_at is null
      ) then raise exception 'INVALID_REGISTRATION' using errcode = '23514'; end if;
      insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
      values (v_group_id, (registration_value #>> '{}')::uuid, 1);
    end loop;

    if exists (
      select 1 from app_private.together_memberships selected_membership
      where selected_membership.registration_id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'))
        and selected_membership.left_at is null
        and exists (
          select 1 from app_private.together_memberships sibling
          join app_private.registrations sibling_registration on sibling_registration.id = sibling.registration_id
          where sibling.party_id = selected_membership.party_id and sibling.left_at is null
            and sibling_registration.event_id = v_event_id and sibling_registration.status = 'submitted'
            and not (sibling.registration_id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds')))
            and not exists (
              select 1 from app_private.group_registrations assigned
              where assigned.registration_id = sibling.registration_id and assigned.superseded_at is null
            )
        )
    ) then raise exception 'TOGETHER_PARTY_SPLIT' using errcode = '23514'; end if;

    insert into app_private.group_schedule_revisions(
      group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
      expected_finale_arrival_at, preference_match, input_snapshot, warnings, created_by
    ) values (
      v_group_id, 1, 'draft', v_start_id, v_effective_stop, v_expected_finale,
      coalesce(group_item ->> 'preferenceMatch', 'neutral'), group_item,
      coalesce(group_item -> 'warnings', '[]'::jsonb), actor
    ) returning id into v_schedule_id;
    update app_private.walking_groups set current_schedule_revision_id = v_schedule_id, version = version + 1 where id = v_group_id;
    schedule_ids := array_append(schedule_ids, v_schedule_id);
  end loop;
  perform app_private.validate_start_schedule_capacity(v_event_id,schedule_ids);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.proposal_saved', 'group_schedule_batch',
    jsonb_build_object('inputHash', _input_hash, 'groupCount', cardinality(schedule_ids)));
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'admin.applyDynamicPlan', _idempotency_key, canonical_request_hash,
    jsonb_build_object('scheduleIds', schedule_ids, 'groupCount', cardinality(schedule_ids), 'published', false),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$
;

-- Existing occupancy includes the immutable departure instant and physical gate.
CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'readiness',app_private.start_point_readiness(p.id),
    'confirmed',app_private.start_point_readiness(p.id)->'confirmed',
    'latitude',app_private.start_point_location(p.id)->'latitude','longitude',app_private.start_point_location(p.id)->'longitude',
    'locationSource',app_private.start_point_location(p.id)->'source',
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'location',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude),
    'latitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'latitude',
    'longitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'longitude',
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item left join app_private.portal_private_locations l on l.portal_id=(item->>'id')::uuid),'[]'::jsonb),true);
  -- Replace only the obsolete marker test. Unassigned groups, capacity and
  -- publication checks remain independent and unchanged.
  base:=jsonb_set(base,'{warnings}',coalesce((select jsonb_agg(w) from jsonb_array_elements(base->'warnings') w
    where w->>'code' not in ('MISSING_MARKER','WALKING_ROUTE_MISSING')),'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object(
      'code','MISSING_MARKER','resourceId',p.id,'resourceType','start_point','action','kaart',
      'message',p.public_label||' — '||case r->>'confirmationReason'
        when 'START_POINT_POSITION_MISSING' then 'Geen opgeslagen positie — plaats een marker.'
        when 'START_POINT_POSITION_INVALID' then 'Ongeldige positie — controleer de coördinaten en sla opnieuw op.'
        when 'START_POINT_ADDRESS_MISSING' then 'Adres ontbreekt — vul het adres van deze startlocatie in.'
        when 'LINKED_PORTAL_NOT_AVAILABLE' then 'Gekoppelde poort niet beschikbaar — controleer deze poort.'
        when 'LINKED_START_PORTAL_POSITION_INVALID' then 'De gekoppelde eerste poort '||coalesce(r->>'linkedPortalName','')||' heeft geen geldig adres en positie — controleer deze poort.'
        else 'Controleer het opgeslagen adres en de marker van deze startlocatie.' end) order by p.name)
      from app_private.start_points p cross join lateral(select app_private.start_point_readiness(p.id) r) c
      where p.event_id=e.id and p.active and not (r->>'canConfirm')::boolean), '[]'::jsonb),true);
  base:=jsonb_set(base,'{stats,missingMarkers}',to_jsonb((select count(*) from app_private.start_points p
    where p.event_id=e.id and p.active and not (app_private.start_point_location(p.id)->>'valid')::boolean)),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,
      'appointmentProtected',s.confirmed_at is not null or pub.publication_order is not null,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.current_start_publication(g.id)) pub on true
    where g.event_id=e.id and g.retired_at is null;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and g.retired_at is null and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'startPointId',app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id),
    'startsAt',r.starts_at,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  base:=jsonb_set(base,'{groups}',coalesce((select jsonb_agg(item) from jsonb_array_elements(base->'groups') item join app_private.walking_groups g on g.id=(item->>'id')::uuid where g.retired_at is null),'[]'));
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;

-- Editing exact end preferences leaves explicit ordinary-stop choices separate.
create or replace function api.registration_exact_preferences_save(
  _registration_id uuid,
  _preferred_start_at timestamptz,
  _desired_end_at timestamptz,
  _expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  settings app_private.event_route_settings;
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if actor is null or registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if registration.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if registration.preference_change_status <> 'editable' or exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
    where assignment.registration_id = registration.id and assignment.superseded_at is null
  ) then raise exception 'PREFERENCES_LOCKED' using errcode = '23514'; end if;
  perform app_private.validate_exact_preferences(registration.event_id, _preferred_start_at, _desired_end_at);
  select * into settings from app_private.event_route_settings where event_id = registration.event_id;
  update app_private.registrations
  set preferred_start_at = _preferred_start_at,
      desired_end_at = _desired_end_at,
      requested_ordinary_stop_at = case when registration.requested_ordinary_stop_at = registration.desired_end_at
        then null else registration.requested_ordinary_stop_at end,
      version = version + 1,
      updated_at = now()
  where id = registration.id returning * into registration;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.exact_preferences_updated', 'registration', registration.id,
    jsonb_build_object('preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at));
  return jsonb_build_object(
    'registrationId', registration.id, 'preferredStartAt', registration.preferred_start_at,
    'desiredEndAt', registration.desired_end_at, 'ordinaryStopAt', registration.requested_ordinary_stop_at,
    'version', registration.version, 'editable', true
  );
end;
$$;

-- All slot commands acquire the event mutex before locking or editing a slot.
CREATE OR REPLACE FUNCTION api.admin_start_slot_save(_event_slug text, _slot_id uuid, _start_point_id uuid, _starts_at timestamp with time zone, _max_groups integer, _max_children integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  slot app_private.start_slots;
  route_settings app_private.event_route_settings; effective_location jsonb;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into point from app_private.start_points where id = _start_point_id and event_id = v_event_id and active;
  select * into route_settings from app_private.event_route_settings where event_id = v_event_id;
  effective_location:=app_private.start_point_location(point.id);
  if point.id is null or not app_private.start_point_destination_ready(point.id) or _max_groups < 1 or _max_children < 1
     or (route_settings.first_start_at is not null and _starts_at < route_settings.first_start_at)
     or (route_settings.global_ordinary_stop_at is not null and _starts_at >= route_settings.global_ordinary_stop_at)
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if _slot_id is null then
    insert into app_private.start_slots(
      event_id, name, location_name, private_address, latitude, longitude, location_verified_at,
      starts_at, max_groups, max_children, start_point_id
    ) values (
      v_event_id, point.name || ' ' || to_char(_starts_at at time zone 'Europe/Amsterdam', 'HH24:MI'),
      point.name, point.private_address, (effective_location->>'latitude')::numeric, (effective_location->>'longitude')::numeric, coalesce(app_private.start_point_confirmation(point.id),point.verified_at),
      _starts_at, _max_groups, _max_children, point.id
    ) returning * into slot;
  else
    update app_private.start_slots set starts_at = _starts_at, max_groups = _max_groups,
      max_children = _max_children, start_point_id = point.id, location_name = point.name,
      private_address = point.private_address, latitude = (effective_location->>'latitude')::numeric, longitude = (effective_location->>'longitude')::numeric,
      location_verified_at = point.verified_at
    where id = _slot_id and event_id = v_event_id returning * into slot;
    if slot.id is null then raise exception 'START_SLOT_NOT_FOUND' using errcode = 'P0002'; end if;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_slot.saved', 'start_slot', slot.id, jsonb_build_object('startsAt', slot.starts_at, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at);
end;
$function$;
