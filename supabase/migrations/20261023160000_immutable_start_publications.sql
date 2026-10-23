-- Published appointments are separate from mutable working points and drafts.
-- No existing participant, QR, route, seal or payment row is rewritten.
alter table app_private.start_points
  add column if not exists walking_connection_verified_at timestamptz,
  add column if not exists walking_connection_verified_by uuid references auth.users(id);
alter table app_private.group_schedule_revisions
  add column if not exists confirmed_at timestamptz,
  add column if not exists confirmed_by uuid references auth.users(id),
  add column if not exists confirmed_settings_version integer,
  add column if not exists confirmed_point_version integer,
  add column if not exists confirmed_route_settings_version integer,
  add column if not exists confirmed_starts_at timestamptz,
  add column if not exists confirmed_start_point_id uuid references app_private.start_points(id),
  add column if not exists confirmed_composition_hash text;

create table if not exists app_private.group_start_publications (
  id uuid primary key default gen_random_uuid(),
  publication_order bigint generated always as identity unique,
  event_id uuid not null references app_private.events(id),
  group_id uuid not null references app_private.walking_groups(id),
  source_key text not null,
  schedule_id uuid references app_private.group_schedule_revisions(id),
  revision integer not null,
  starts_at timestamptz not null,
  published_at timestamptz not null default clock_timestamp(),
  published_by uuid references auth.users(id),
  point_snapshot jsonb not null,
  slot_snapshot jsonb not null,
  unique(group_id, source_key)
);
alter table app_private.group_start_publications enable row level security;
revoke all on app_private.group_start_publications from public, anon, authenticated;
create index if not exists group_start_publications_latest_idx
  on app_private.group_start_publications(group_id,published_at desc,id desc);

create or replace function app_private.preserve_start_publication()
returns trigger language plpgsql set search_path='' as $$
begin raise exception 'PUBLISHED_APPOINTMENT_IMMUTABLE' using errcode='23514'; end;
$$;
drop trigger if exists preserve_start_publication on app_private.group_start_publications;
create trigger preserve_start_publication before update or delete on app_private.group_start_publications
for each row execute function app_private.preserve_start_publication();

create or replace function app_private.capture_published_start(_group_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups; s app_private.group_schedule_revisions;
  slot app_private.start_slots; p app_private.start_points; plan app_private.route_plan_versions;
  source text; rev integer; pub_at timestamptz;
begin
  select * into g from app_private.walking_groups where id=_group_id;
  if g.id is null then return; end if;
  select * into s from app_private.group_schedule_revisions
    where group_id=g.id and state='published' order by revision desc limit 1;
  if s.id is not null then
    select * into slot from app_private.start_slots where id=s.start_slot_id;
    source := 'schedule:'||s.id; rev:=s.revision; pub_at:=s.published_at;
  elsif g.route_mode='legacy' then
    -- A route-only revision cannot replace an already published departure.
    if exists(select 1 from app_private.group_start_publications where group_id=g.id) then return; end if;
    select * into plan from app_private.route_plan_versions
      where id=g.current_plan_version_id and state='published';
    if plan.id is null or not exists(select 1 from app_private.group_registrations
      where group_id=g.id and superseded_at is null and published_at is not null) then return; end if;
    select * into slot from app_private.start_slots where id=g.start_slot_id;
    source:='legacy:'||plan.id; rev:=plan.revision; pub_at:=plan.published_at;
  else return;
  end if;
  select * into p from app_private.start_points where id=slot.start_point_id;
  if slot.id is null then return; end if;
  insert into app_private.group_start_publications(event_id,group_id,source_key,schedule_id,
    revision,starts_at,published_at,published_by,point_snapshot,slot_snapshot)
  values(g.event_id,g.id,source,s.id,rev,slot.starts_at,coalesce(pub_at,clock_timestamp()),
    auth.uid(),case when p.id is not null then to_jsonb(p) else jsonb_build_object(
      'name',slot.location_name,'private_address',slot.private_address,
      'latitude',slot.latitude,'longitude',slot.longitude) end,
    to_jsonb(slot)) on conflict(group_id,source_key) do nothing;
end;
$$;

create or replace function app_private.capture_published_start_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='walking_groups' then perform app_private.capture_published_start(new.id);
  else perform app_private.capture_published_start(new.group_id); end if;
  return new;
end;
$$;
drop trigger if exists capture_published_start on app_private.walking_groups;
create trigger capture_published_start after insert or update of current_plan_version_id,start_slot_id,route_mode
on app_private.walking_groups for each row execute function app_private.capture_published_start_trigger();
drop trigger if exists capture_published_start on app_private.route_plan_versions;
create trigger capture_published_start after insert or update of state,published_at
on app_private.route_plan_versions for each row execute function app_private.capture_published_start_trigger();
drop trigger if exists capture_published_start on app_private.group_registrations;
create trigger capture_published_start after insert or update of published_at
on app_private.group_registrations for each row execute function app_private.capture_published_start_trigger();
drop trigger if exists capture_published_start on app_private.group_schedule_revisions;
create trigger capture_published_start after insert or update of state,published_at
on app_private.group_schedule_revisions for each row execute function app_private.capture_published_start_trigger();
-- Only copy already-published appointments into the new append-only table.
select app_private.capture_published_start(id) from app_private.walking_groups;

create or replace function app_private.published_start_projection(
  _group_id uuid, _at timestamptz default clock_timestamp())
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.group_start_publications; result jsonb;
begin
  select * into p from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1;
  if p.id is null then return null; end if;
  result:=jsonb_build_object('startsAt',p.starts_at,'revision',p.revision,
    'publishedAt',p.published_at,'addressReleaseAt',p.starts_at-interval '1 hour',
    'addressReleased',_at>=p.starts_at-interval '1 hour','canStart',_at>=p.starts_at,'timePublished',true,
    'name','Startlocatie volgt','locationName','Startlocatie volgt','startPoint','Startlocatie volgt',
    'address',null,'startAddress',null,'coordinate',null,'linkedPortalId',null);
  if _at>=p.starts_at-interval '1 hour' then
    result:=result||jsonb_build_object('name',p.point_snapshot->>'name',
      'locationName',p.point_snapshot->>'name','startPoint',p.point_snapshot->>'name',
      'address',p.point_snapshot->>'private_address','startAddress',p.point_snapshot->>'private_address',
      'linkedPortalId',p.point_snapshot->>'linked_portal_id',
      'safeApproach',p.point_snapshot->>'safe_approach','arrivalInstructions',p.point_snapshot->>'public_arrival_instructions',
      'coordinate',jsonb_build_array(
        coalesce(p.point_snapshot->>'marker_longitude',p.point_snapshot->>'geocoded_longitude',p.point_snapshot->>'longitude')::numeric,
        coalesce(p.point_snapshot->>'marker_latitude',p.point_snapshot->>'geocoded_latitude',p.point_snapshot->>'latitude')::numeric));
  end if;
  return result;
end;
$$;

create or replace function app_private.start_point_safe_connection(_point_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select p.active and p.walking_connection_verified_at is not null
      and length(trim(coalesce(p.safe_approach,'')))>0 and n.verified_at is not null
      and exists(select 1 from app_private.walking_edges edge where edge.event_id=p.event_id
        and edge.approved_at is not null and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
      and app_private.location_distance_m(
        coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
        coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),
        n.coordinate[1]::numeric,n.coordinate[0]::numeric)<=75
    from app_private.start_points p join app_private.walking_nodes n
      on n.id=p.walking_node_id and n.event_id=p.event_id where p.id=_point_id),false)
$$;

create or replace function app_private.invalidate_start_point_connection()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if row(new.private_address,new.latitude,new.longitude,new.geocoded_latitude,new.geocoded_longitude,
      new.marker_latitude,new.marker_longitude,new.walking_node_id,new.safe_approach,new.linked_portal_id)
    is distinct from row(old.private_address,old.latitude,old.longitude,old.geocoded_latitude,old.geocoded_longitude,
      old.marker_latitude,old.marker_longitude,old.walking_node_id,old.safe_approach,old.linked_portal_id) then
    new.walking_connection_verified_at:=null; new.walking_connection_verified_by:=null;
  end if;
  if old.active and not new.active and exists(select 1 from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    where slot.start_point_id=old.id and g.status not in ('finished','cancelled')) then
    raise exception 'START_POINT_IN_USE' using errcode='23514';
  end if;
  return new;
end;
$$;
drop trigger if exists invalidate_start_point_connection on app_private.start_points;
create trigger invalidate_start_point_connection before update on app_private.start_points
for each row execute function app_private.invalidate_start_point_connection();

create or replace function api.admin_startregie_verify_point(
  _event_slug text,_point_id uuid,_expected_version integer,
  _safe_connection_checked boolean,_safe_approach text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; p app_private.start_points; n app_private.walking_nodes; d numeric;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into p from app_private.start_points where id=_point_id and event_id=e.id for update;
  if p.id is null or p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if _safe_connection_checked is distinct from true or length(trim(coalesce(_safe_approach,''))) not between 1 and 1000 then
    raise exception 'SAFE_CONNECTION_REQUIRED' using errcode='23514'; end if;
  select candidate.* into n from app_private.walking_nodes candidate where candidate.event_id=e.id and candidate.verified_at is not null
    and exists(select 1 from app_private.walking_edges edge where edge.event_id=e.id and edge.approved_at is not null and edge.closed_at is null
      and (edge.from_node_id=candidate.id or edge.to_node_id=candidate.id))
    order by app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),candidate.coordinate[1]::numeric,candidate.coordinate[0]::numeric),candidate.id limit 1;
  d:=app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
    coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric);
  if n.id is null or d is null or d>75 then raise exception 'CONNECTION_TOO_FAR' using errcode='23514'; end if;
  -- A relevant edit invalidates first; a separate update records this explicit check.
  update app_private.start_points set safe_approach=trim(_safe_approach),walking_node_id=n.id where id=p.id;
  update app_private.start_points set walking_connection_verified_at=clock_timestamp(),walking_connection_verified_by=auth.uid(),
    verified_at=clock_timestamp(),verified_by=auth.uid(),version=version+1 where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(e.id,auth.uid(),'start_point.safe_connection_verified','start_point',p.id,jsonb_build_object('version',p.version,'distanceMeters',round(d)));
  perform realtime.send(jsonb_build_object('resource','start_point','id',p.id),'snapshot_changed','admin-event:'||e.id,true);
  return jsonb_build_object('id',p.id,'version',p.version,'verified',true);
end;
$$;
revoke all on function api.admin_startregie_verify_point(text,uuid,integer,boolean,text) from public,anon;
grant execute on function api.admin_startregie_verify_point(text,uuid,integer,boolean,text) to authenticated;
revoke all on function app_private.preserve_start_publication(),app_private.capture_published_start(uuid),
  app_private.capture_published_start_trigger(),app_private.published_start_projection(uuid,timestamptz),
  app_private.start_point_safe_connection(uuid),app_private.invalidate_start_point_connection() from public,anon,authenticated;

create or replace function app_private.start_planning_input_hash(_event_id uuid)
returns text language sql stable security definer set search_path='' as $$
  select encode(extensions.digest(convert_to(jsonb_build_object(
    'event',(select jsonb_build_object('settings',e.settings,'version',e.settings_version) from app_private.events e where e.id=_event_id),
    'routeSettings',(select to_jsonb(s) from app_private.event_route_settings s where s.event_id=_event_id),
    'points',(select jsonb_agg(to_jsonb(p) order by p.id) from app_private.start_points p where p.event_id=_event_id),
    'slots',(select jsonb_agg(to_jsonb(s) order by s.id) from app_private.start_slots s where s.event_id=_event_id),
    'groups',(select jsonb_agg(to_jsonb(g) order by g.id) from app_private.walking_groups g where g.event_id=_event_id),
    'registrations',(select jsonb_agg(jsonb_build_object('registration',to_jsonb(r),'payment',to_jsonb(p),
      'children',(select jsonb_agg(to_jsonb(c) order by c.id) from app_private.registration_children c where c.registration_id=r.id),
      'assignments',(select jsonb_agg(to_jsonb(a) order by a.id) from app_private.group_registrations a where a.registration_id=r.id)) order by r.id)
      from app_private.registrations r left join app_private.payment_requests p on p.registration_id=r.id where r.event_id=_event_id),
    'publications',(select jsonb_agg(to_jsonb(p) order by p.publication_order) from app_private.group_start_publications p where p.event_id=_event_id)
    )::text,'UTF8'),'sha256'),'hex')
$$;
revoke all on function app_private.start_planning_input_hash(uuid) from public,anon,authenticated;

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
revoke all on function app_private.start_point_ready_at(uuid,timestamptz) from public,anon,authenticated;

create or replace function app_private.portal_has_verified_walking_connection(_portal_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from app_private.portal_private_locations l
    join app_private.walking_nodes n on n.portal_id=l.portal_id and n.verified_at is not null
    where l.portal_id=_portal_id and l.verified_at is not null
      and abs(n.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<0.000001
      and abs(n.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<0.000001
      and exists(select 1 from app_private.walking_edges edge where edge.event_id=n.event_id and edge.approved_at is not null
        and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id)))
$$;
revoke all on function app_private.portal_has_verified_walking_connection(uuid) from public,anon,authenticated;

create or replace function app_private.start_group_composition_hash(_group_id uuid)
returns text language sql stable security definer set search_path='' as $$
  select encode(extensions.digest(convert_to(coalesce(jsonb_agg(jsonb_build_object(
    'assignment',jsonb_build_array(a.id,a.registration_id,a.assignment_revision),'registrationStatus',r.status,'paymentStatus',p.status,
    'children',(select jsonb_agg(jsonb_build_array(c.id,c.child_id,c.participation_status) order by c.id)
      from app_private.registration_children c where c.registration_id=r.id)) order by a.id),'[]'::jsonb)::text,'UTF8'),'sha256'),'hex')
  from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id
  left join app_private.payment_requests p on p.registration_id=r.id where a.group_id=_group_id and a.superseded_at is null
$$;
create or replace function app_private.is_start_confirmation_current(_schedule_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select s.confirmed_at is not null and s.confirmed_settings_version=e.settings_version
    and s.confirmed_point_version=p.version and s.confirmed_start_point_id=p.id and s.confirmed_starts_at=slot.starts_at
    and s.confirmed_route_settings_version=settings.version and slot.active
    and s.confirmed_composition_hash=app_private.start_group_composition_hash(g.id)
    and app_private.start_point_ready_at(p.id,slot.starts_at)
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id join app_private.event_route_settings settings on settings.event_id=e.id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=_schedule_id),false)
$$;
revoke all on function app_private.start_group_composition_hash(uuid),app_private.is_start_confirmation_current(uuid) from public,anon,authenticated;
