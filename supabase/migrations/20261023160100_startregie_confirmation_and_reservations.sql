-- A physical group reserves both its current valid draft and last publication.
-- Deduplication is per resource/time; different start times remain reserved.
create or replace function app_private.start_schedule_reservations(_event_id uuid)
returns table(group_id uuid,schedule_id uuid,start_slot_id uuid,start_point_id uuid,
  starts_at timestamptz,child_count integer,finale_at timestamptz)
language sql stable security definer set search_path='' as $$
  with sizes as (
    select g.id,count(c.id)::integer children from app_private.walking_groups g
    left join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null
    left join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
    where g.event_id=_event_id and g.status not in ('finished','completed','stopped','cancelled')
      and not exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.status in ('stopped','completed')) group by g.id
  ), published as (
    select distinct on(p.group_id) p.* from app_private.group_start_publications p
    where p.event_id=_event_id order by p.group_id,p.publication_order desc
  )
  select g.id,s.id,slot.id,slot.start_point_id,slot.starts_at,z.children,s.expected_finale_arrival_at
  from app_private.walking_groups g join sizes z on z.id=g.id
  join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id and s.state='draft'
  join app_private.start_slots slot on slot.id=s.start_slot_id and slot.active
  where g.event_id=_event_id and app_private.start_point_safe_connection(slot.start_point_id)
  union
  select p.group_id,p.schedule_id,(p.slot_snapshot->>'id')::uuid,(p.slot_snapshot->>'start_point_id')::uuid,
    p.starts_at,z.children,s.expected_finale_arrival_at
  from published p join sizes z on z.id=p.group_id
  left join app_private.group_schedule_revisions s on s.id=p.schedule_id
$$;

create or replace function app_private.validate_start_schedule_capacity(_event_id uuid,_schedule_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
declare candidate record; settings app_private.event_route_settings; tick timestamptz; service_interval interval;
  load_groups integer; load_children bigint;
begin
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
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
  end loop;
end;
$$;

create or replace function api.admin_startregie_confirm_start(
  _event_slug text,_group_id uuid,_expected_revision integer,_expected_settings_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; g app_private.walking_groups; s app_private.group_schedule_revisions; p app_private.start_points;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  select * into g from app_private.walking_groups where id=_group_id and event_id=e.id for update;
  if g.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if exists(select 1 from app_private.group_runs where group_id=g.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id for update;
  if s.id is null or s.revision is distinct from _expected_revision or s.state<>'draft' then raise exception 'STALE_REVISION' using errcode='40001'; end if;
  select p1.* into p from app_private.start_points p1 join app_private.start_slots slot on slot.start_point_id=p1.id where slot.id=s.start_slot_id;
  if not app_private.start_point_safe_connection(p.id) then raise exception 'START_POINT_NOT_VERIFIED' using errcode='23514'; end if;
  if not app_private.start_point_ready_at(p.id,(select starts_at from app_private.start_slots where id=s.start_slot_id)) then raise exception 'START_POINT_NOT_AVAILABLE' using errcode='23514'; end if;
  if not exists(select 1 from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null) then
    raise exception 'EMPTY_GROUP' using errcode='23514'; end if;
  if exists(select 1 from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id
    left join app_private.payment_requests p1 on p1.registration_id=r.id where a.group_id=g.id and a.superseded_at is null
      and r.status='submitted' and coalesce(p1.status::text,'') not in ('confirmed','waived')) then
    raise exception 'PAYMENT_NOT_CONFIRMED' using errcode='23514'; end if;
  perform app_private.validate_start_schedule_capacity(e.id,array[s.id]);
  update app_private.group_schedule_revisions set confirmed_at=clock_timestamp(),confirmed_by=auth.uid(),
    confirmed_settings_version=e.settings_version,confirmed_point_version=p.version,
    confirmed_route_settings_version=(select version from app_private.event_route_settings where event_id=e.id),
    confirmed_starts_at=(select starts_at from app_private.start_slots where id=s.start_slot_id),
    confirmed_start_point_id=p.id,confirmed_composition_hash=app_private.start_group_composition_hash(g.id) where id=s.id returning * into s;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'group_start.confirmed','group_schedule',s.id,jsonb_build_object('revision',s.revision,'settingsVersion',e.settings_version));
  perform realtime.send(jsonb_build_object('resource','start_planning','groupId',g.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',s.id,'revision',s.revision,'state','confirmed','confirmedAt',s.confirmed_at);
end;
$$;

create or replace function api.admin_startregie_publish_times(
  _event_slug text,_schedule_ids uuid[],_expected_revisions jsonb,
  _expected_settings_version integer,_idempotency_key text,
  _reason text default 'Geselecteerde starttijden en gecontroleerde routes publiceren')
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; receipt app_private.command_receipts; fingerprint text; result jsonb;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if length(trim(coalesce(_idempotency_key,''))) not between 16 and 200
    or coalesce(cardinality(_schedule_ids),0) not between 1 and 500
    or jsonb_typeof(_expected_revisions) is distinct from 'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('event',e.id,'ids',_schedule_ids,
    'revisions',_expected_revisions,'settingsVersion',_expected_settings_version,'reason',_reason)::text,'UTF8'),'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='start_times.publish' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
    return receipt.safe_result;
  end if;
  if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if jsonb_array_length(_expected_revisions)<>cardinality(_schedule_ids)
    or exists(select 1 from unnest(_schedule_ids) candidate(id) where not exists(
      select 1 from jsonb_array_elements(_expected_revisions) expected
      join app_private.group_schedule_revisions s on s.id=candidate.id
      where expected->>'id'=s.id::text and (expected->>'revision')::integer=s.revision
        and exists(select 1 from app_private.walking_groups g where g.id=s.group_id and g.current_schedule_revision_id=s.id))) then
    raise exception 'STALE_REVISION' using errcode='40001'; end if;
  result:=app_private.publish_startregie_ops(_event_slug,_schedule_ids,_reason);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'start_times.publish',_idempotency_key,fingerprint,result,now()+interval '2 days');
  return result;
end;
$$;

revoke all on function app_private.start_schedule_reservations(uuid),app_private.validate_start_schedule_capacity(uuid,uuid[]) from public,anon,authenticated;
create or replace function api.admin_startregie_confirm_starts(
  _event_slug text,_expected_revisions jsonb,_expected_settings_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; g uuid; result jsonb:='[]'::jsonb;
begin
  if jsonb_typeof(_expected_revisions) is distinct from 'array'
    or jsonb_array_length(_expected_revisions) not between 1 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  for item in select * from jsonb_array_elements(_expected_revisions) loop
    select group_id into g from app_private.group_schedule_revisions where id=(item->>'id')::uuid;
    result:=result||jsonb_build_array(api.admin_startregie_confirm_start(_event_slug,g,(item->>'revision')::integer,_expected_settings_version));
  end loop;
  return jsonb_build_object('confirmed',result);
end;
$$;
revoke all on function api.admin_startregie_confirm_starts(text,jsonb,integer) from public,anon;
grant execute on function api.admin_startregie_confirm_starts(text,jsonb,integer) to authenticated;
revoke all on function api.admin_startregie_confirm_start(text,uuid,integer,integer),
  api.admin_startregie_publish_times(text,uuid[],jsonb,integer,text,text) from public,anon;
grant execute on function api.admin_startregie_confirm_start(text,uuid,integer,integer),
  api.admin_startregie_publish_times(text,uuid[],jsonb,integer,text,text) to authenticated;
