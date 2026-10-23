create or replace function app_private.parse_amsterdam_instant(_value text)
returns timestamptz language plpgsql immutable set search_path='' as $$
declare result timestamptz; wall timestamp;
begin
  if _value is null or _value='' then return null; end if;
  if _value !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}([.]\d{1,6})?)?(Z|[+-]\d{2}:\d{2})$' then
    raise exception 'INVALID_AMSTERDAM_TIME' using errcode='22023'; end if;
  result:=_value::timestamptz; wall:=result at time zone 'Europe/Amsterdam';
  if (result-interval '1 hour') at time zone 'Europe/Amsterdam'=wall
    or (result+interval '1 hour') at time zone 'Europe/Amsterdam'=wall then
    raise exception 'AMBIGUOUS_AMSTERDAM_TIME' using errcode='22023'; end if;
  if right(_value,1)<>'Z' and _value !~ '[+-]00:00$'
    and (_value !~ '[+]0[12]:00$' or regexp_replace(_value,'[+-]\d{2}:\d{2}$','')::timestamp<>wall) then
    raise exception 'INVALID_AMSTERDAM_TIME' using errcode='22023'; end if;
  return result;
end;
$$;

create or replace function app_private.start_point_ready_at(_point_id uuid,_starts_at timestamptz)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select app_private.start_point_safe_connection(p.id)
    and (p.available_from is null or _starts_at>=p.available_from)
    and (p.available_until is null or _starts_at<p.available_until)
    and (p.linked_portal_id is null or exists(select 1 from app_private.portals portal
      join app_private.portal_private_locations location on location.portal_id=portal.id and location.verified_at is not null
      where portal.id=p.linked_portal_id and portal.approval_status='approved' and portal.lifecycle_status='active'
        and portal.operation_status in ('open','scheduled') and exists(select 1 from app_private.portal_windows w
          where w.portal_id=portal.id and _starts_at>=w.opens_at and _starts_at<w.closes_at)))
    from app_private.start_points p where p.id=_point_id),false)
$$;

create or replace function app_private.validate_start_point_capacity_edit()
returns trigger language plpgsql security definer set search_path='' as $$
declare ids uuid[];
begin
  if row(new.max_gathering_children,new.max_gathering_groups) is not distinct from row(old.max_gathering_children,old.max_gathering_groups) then return new; end if;
  select array_agg(s.id) into ids from app_private.group_schedule_revisions s
    join app_private.start_slots slot on slot.id=s.start_slot_id and slot.start_point_id=new.id
    join app_private.walking_groups g on g.id=s.group_id
    where s.state='published' or s.id=g.current_schedule_revision_id;
  perform app_private.validate_start_schedule_capacity(new.event_id,coalesce(ids,'{}'::uuid[]));
  return new;
end;
$$;
drop trigger if exists validate_start_point_capacity_edit on app_private.start_points;
create trigger validate_start_point_capacity_edit after update on app_private.start_points
for each row execute function app_private.validate_start_point_capacity_edit();

create or replace function app_private.validate_finale_capacity_edit()
returns trigger language plpgsql security definer set search_path='' as $$
declare ids uuid[];
begin
  if row(new.finale_max_concurrent_groups,new.finale_max_concurrent_children,new.finale_show_seconds,new.finale_turnover_seconds,
    new.finale_opens_at,new.finale_last_arrival_at,new.finale_closes_at)
    is not distinct from row(old.finale_max_concurrent_groups,old.finale_max_concurrent_children,old.finale_show_seconds,old.finale_turnover_seconds,
    old.finale_opens_at,old.finale_last_arrival_at,old.finale_closes_at) then return new; end if;
  select array_agg(s.id) into ids from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
    where g.event_id=new.event_id and (s.state='published' or s.id=g.current_schedule_revision_id);
  perform app_private.validate_start_schedule_capacity(new.event_id,coalesce(ids,'{}'::uuid[]));
  return new;
end;
$$;
drop trigger if exists validate_finale_capacity_edit on app_private.event_route_settings;
create trigger validate_finale_capacity_edit after update on app_private.event_route_settings
for each row execute function app_private.validate_finale_capacity_edit();
revoke all on function app_private.parse_amsterdam_instant(text),app_private.validate_start_point_capacity_edit(),
  app_private.validate_finale_capacity_edit(),app_private.start_point_ready_at(uuid,timestamptz) from public,anon,authenticated;
