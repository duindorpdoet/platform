alter table app_private.portal_applications
  add column review_feedback text check (review_feedback is null or char_length(review_feedback) between 10 and 500);

alter table app_private.portal_windows
  add column max_children_total integer not null default 2147483647 check (max_children_total > 0);

-- Browser uploads cannot prove that bytes match a claimed MIME type. Uploads
-- therefore pass through the authenticated application endpoint, which sniffs
-- the file signature before using the privileged storage client.
drop policy if exists "application owners upload private images" on storage.objects;
drop policy if exists "application owners update private images" on storage.objects;

create or replace function app_private.can_access_application_asset(_object_name text, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null
    and split_part(_object_name, '/', 1) = application.applicant_user_id::text
    and application.id::text = split_part(_object_name, '/', 2)
    and (
      application.applicant_user_id = _actor
      or app_private.has_capability(application.event_id, 'portals_manage', _actor)
    )
  from app_private.portal_applications application
  where application.id::text = split_part(_object_name, '/', 2)
$$;

create or replace function api.admin_portal_applications_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'worlds', coalesce((
      select jsonb_agg(jsonb_build_object('id', world.id, 'slug', world.slug, 'name', world.name) order by world.sort_order)
      from app_private.worlds world where world.event_id = v_event_id
    ), '[]'::jsonb),
    'applications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', application.id,
        'status', application.review_status,
        'version', application.version,
        'submittedAt', application.submitted_at,
        'reviewFeedback', application.review_feedback,
        'applicantEmail', lower(users.email),
        'draft', application.private_draft_data,
        'requestedWorldSlug', world.slug,
        'portal', case when portal.id is null then null else jsonb_build_object(
          'id', portal.id,
          'version', portal.version,
          'name', portal.name,
          'locationVerified', location.verified_at is not null,
          'latitude', location.latitude,
          'longitude', location.longitude
        ) end
      ) order by application.created_at desc)
      from app_private.portal_applications application
      join auth.users users on users.id = application.applicant_user_id
      left join app_private.worlds world on world.id = application.requested_world_id
      left join app_private.portals portal on portal.application_id = application.id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      where application.event_id = v_event_id and application.review_status <> 'draft'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_review_portal_application(
  _application_id uuid,
  _expected_version integer,
  _decision text,
  _world_slug text,
  _latitude numeric,
  _longitude numeric,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  application app_private.portal_applications;
  event_record app_private.events;
  v_world_id uuid;
  portal_record app_private.portals;
  draft jsonb;
  portal_name text;
  portal_description text;
  street text;
  house_number text;
  addition text;
  postal_code text;
  intensity smallint;
  visit_minutes integer;
  max_concurrent_groups integer;
  max_children_per_visit integer;
  max_children_total integer;
  available_from text;
  available_until text;
  opens_at timestamptz;
  closes_at timestamptz;
begin
  if _decision not in ('approved', 'changes_requested', 'rejected') then raise exception 'INVALID_DECISION' using errcode = '22023'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  if (_latitude is null) <> (_longitude is null)
     or (_latitude is not null and (_latitude not between -90 and 90 or _longitude not between -180 and 180)) then
    raise exception 'INVALID_COORDINATE' using errcode = '22023';
  end if;

  select * into application from app_private.portal_applications where id = _application_id for update;
  if application.id is null or not app_private.has_capability(application.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if application.review_status <> 'submitted' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;

  if _decision in ('changes_requested', 'rejected') then
    update app_private.portal_applications
    set review_status = _decision::app_private.review_status,
        review_feedback = trim(_reason),
        reviewed_by = actor,
        reviewed_at = now(),
        version = version + 1
    where id = application.id
    returning * into application;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (application.event_id, actor, 'portal_application.' || _decision, 'portal_application', application.id, jsonb_build_object('reason', left(trim(_reason), 500)));
    return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'portalId', null);
  end if;

  select * into event_record from app_private.events where id = application.event_id;
  select world.id into v_world_id from app_private.worlds world
  where world.event_id = application.event_id and world.slug = lower(trim(_world_slug));
  if v_world_id is null then raise exception 'INVALID_WORLD' using errcode = '22023'; end if;
  if exists (select 1 from app_private.portals portal where portal.application_id = application.id) then
    raise exception 'ALREADY_APPROVED' using errcode = '23505';
  end if;

  draft := application.private_draft_data;
  portal_name := nullif(trim(draft ->> 'portalName'), '');
  portal_description := nullif(trim(draft ->> 'description'), '');
  street := nullif(trim(draft #>> '{address,street}'), '');
  house_number := nullif(trim(draft #>> '{address,houseNumber}'), '');
  addition := nullif(trim(draft #>> '{address,addition}'), '');
  postal_code := upper(replace(trim(draft #>> '{address,postalCode}'), ' ', ''));
  if portal_name is null or portal_description is null or street is null or house_number is null
     or postal_code is null or postal_code !~ '^[0-9]{4}[A-Z]{2}$'
     or coalesce(draft ->> 'intensity', '') !~ '^[1-4]$' then
    raise exception 'INCOMPLETE_APPLICATION' using errcode = '23514';
  end if;
  intensity := (draft ->> 'intensity')::smallint;
  available_from := coalesce(draft ->> 'availableFrom', '18:00');
  available_until := coalesce(draft ->> 'availableUntil', '22:00');
  if available_from !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or available_until !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'visitMinutes', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxConcurrentGroups', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxChildrenPerVisit', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxChildrenTotal', '') !~ '^[0-9]+$' then
    raise exception 'INCOMPLETE_APPLICATION' using errcode = '23514';
  end if;
  visit_minutes := (draft ->> 'visitMinutes')::integer;
  max_concurrent_groups := (draft ->> 'maxConcurrentGroups')::integer;
  max_children_per_visit := (draft ->> 'maxChildrenPerVisit')::integer;
  max_children_total := (draft ->> 'maxChildrenTotal')::integer;
  if visit_minutes not between 1 and 30 or max_concurrent_groups not between 1 and 20
     or max_children_per_visit not between 1 and 100 or max_children_total not between max_children_per_visit and 5000 then
    raise exception 'INVALID_CAPACITY' using errcode = '22023';
  end if;
  opens_at := make_timestamptz(
    extract(year from event_record.local_date)::integer, extract(month from event_record.local_date)::integer,
    extract(day from event_record.local_date)::integer, split_part(available_from, ':', 1)::integer,
    split_part(available_from, ':', 2)::integer, 0, event_record.timezone
  );
  closes_at := make_timestamptz(
    extract(year from event_record.local_date)::integer, extract(month from event_record.local_date)::integer,
    extract(day from event_record.local_date)::integer, split_part(available_until, ':', 1)::integer,
    split_part(available_until, ':', 2)::integer, 0, event_record.timezone
  );
  if closes_at <= opens_at then raise exception 'INVALID_WINDOW' using errcode = '22023'; end if;

  insert into app_private.portals(event_id, application_id, world_id, name, description, intensity, approval_status, operation_status)
  values (application.event_id, application.id, v_world_id, portal_name, portal_description, intensity, 'approved', 'scheduled')
  returning * into portal_record;
  insert into app_private.portal_private_locations(portal_id, street, house_number, addition, postal_code, city, latitude, longitude, verified_at, verified_by)
  values (
    portal_record.id, street, house_number, addition, postal_code, 'Den Haag', _latitude, _longitude,
    case when _latitude is not null then now() else null end,
    case when _latitude is not null then actor else null end
  );
  insert into app_private.portal_publications(portal_id, published_title, teaser, public_area, published_at)
  values (portal_record.id, portal_name, portal_description, 'Duindorp', now());
  insert into app_private.portal_owners(portal_id, user_id) values (portal_record.id, application.applicant_user_id);
  insert into app_private.portal_windows(portal_id, opens_at, closes_at, visit_minutes, buffer_minutes, max_concurrent_groups, max_children_per_visit, max_children_total)
  values (portal_record.id, opens_at, closes_at, visit_minutes, 2, max_concurrent_groups, max_children_per_visit, max_children_total);
  insert into app_private.portal_flags(portal_id, flag_key, value)
  select portal_record.id, flag.key, flag.value::boolean
  from jsonb_each_text(coalesce(draft -> 'warnings', '{}'::jsonb)) flag
  where flag.key in ('smoke', 'flashes', 'sound', 'actors', 'allergens') and flag.value in ('true', 'false');
  update app_private.portal_applications
  set review_status = 'approved', requested_world_id = v_world_id, review_feedback = null, reviewed_by = actor,
      reviewed_at = now(), version = version + 1
  where id = application.id
  returning * into application;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    application.event_id, actor, 'portal_application.approved', 'portal_application', application.id,
    jsonb_build_object('portalId', portal_record.id, 'worldId', v_world_id, 'locationVerified', _latitude is not null, 'reason', left(trim(_reason), 500))
  );
  return jsonb_build_object(
    'id', application.id,
    'status', application.review_status,
    'version', application.version,
    'portalId', portal_record.id,
    'portalVersion', portal_record.version,
    'locationVerified', _latitude is not null
  );
end;
$$;

create or replace function api.admin_verify_portal_location(
  _portal_id uuid,
  _expected_portal_version integer,
  _latitude numeric,
  _longitude numeric,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal_record app_private.portals;
begin
  if _latitude not between -90 and 90 or _longitude not between -180 and 180 then raise exception 'INVALID_COORDINATE' using errcode = '22023'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into portal_record from app_private.portals where id = _portal_id for update;
  if portal_record.id is null or not app_private.has_capability(portal_record.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if portal_record.version <> _expected_portal_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  update app_private.portal_private_locations
  set latitude = _latitude, longitude = _longitude, verified_at = now(), verified_by = actor
  where portal_id = portal_record.id;
  update app_private.portals set version = version + 1 where id = portal_record.id returning * into portal_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal_record.event_id, actor, 'portal.location_verified', 'portal', portal_record.id, jsonb_build_object('reason', left(trim(_reason), 500)));
  return jsonb_build_object('portalId', portal_record.id, 'portalVersion', portal_record.version, 'locationVerified', true);
end;
$$;

create or replace function api.portal_application_submit(_application_id uuid, _expected_version integer, _idempotency_key text, _request_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  application app_private.portal_applications;
  actor_email text;
  receipt app_private.command_receipts;
  v_world_id uuid;
  draft jsonb;
  visit_minutes integer;
  max_concurrent_groups integer;
  max_children_per_visit integer;
  max_children_total integer;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'portal.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into application from app_private.portal_applications
  where id = _application_id and applicant_user_id = actor for update;
  if application.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if application.version <> _expected_version or application.review_status not in ('draft', 'changes_requested') then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  draft := application.private_draft_data;
  select world.id into v_world_id from app_private.worlds world
  where world.event_id = application.event_id and world.slug = lower(trim(draft ->> 'requestedWorldSlug'));
  if nullif(trim(draft ->> 'contactName'), '') is null
     or char_length(trim(draft ->> 'contactName')) not between 2 and 120
     or char_length(trim(coalesce(draft ->> 'phone', ''))) not between 6 and 32
     or nullif(trim(draft #>> '{address,street}'), '') is null
     or nullif(trim(draft #>> '{address,houseNumber}'), '') is null
     or upper(replace(trim(coalesce(draft #>> '{address,postalCode}', '')), ' ', '')) !~ '^[0-9]{4}[A-Z]{2}$'
     or nullif(trim(draft ->> 'entrance'), '') is null
     or nullif(trim(draft ->> 'portalName'), '') is null
     or char_length(trim(draft ->> 'portalName')) not between 2 and 120
     or char_length(trim(coalesce(draft ->> 'description', ''))) not between 10 and 1000
     or coalesce(draft ->> 'intensity', '') !~ '^[1-4]$'
     or v_world_id is null
     or coalesce(draft ->> 'availableFrom', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'availableUntil', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'visitMinutes', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxConcurrentGroups', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxChildrenPerVisit', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'maxChildrenTotal', '') !~ '^[0-9]+$'
     or coalesce(draft ->> 'accessibility', '') not in ('step_free', 'steps', 'mixed', 'unknown')
     or coalesce(jsonb_typeof(draft -> 'warnings'), '') <> 'object'
     or coalesce(draft -> 'availability', 'false'::jsonb) <> 'true'::jsonb
     or coalesce(draft -> 'locationConsent', 'false'::jsonb) <> 'true'::jsonb then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  visit_minutes := (draft ->> 'visitMinutes')::integer;
  max_concurrent_groups := (draft ->> 'maxConcurrentGroups')::integer;
  max_children_per_visit := (draft ->> 'maxChildrenPerVisit')::integer;
  max_children_total := (draft ->> 'maxChildrenTotal')::integer;
  if (draft ->> 'availableUntil')::time <= (draft ->> 'availableFrom')::time
     or visit_minutes not between 1 and 30 or max_concurrent_groups not between 1 and 20
     or max_children_per_visit not between 1 and 100 or max_children_total not between max_children_per_visit and 5000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  update app_private.portal_applications
  set review_status = 'submitted', requested_world_id = v_world_id, review_feedback = null,
      submitted_at = now(), reviewed_by = null, reviewed_at = null, version = version + 1
  where id = application.id
  returning * into application;
  select email into actor_email from auth.users where id = actor;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values ('portal:' || application.id::text || ':received:' || application.version::text, 'portal_received', actor::text, actor_email, jsonb_build_object('applicationId', application.id));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (application.event_id, actor, 'portal_application.submitted', 'portal_application', application.id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'portal.submit', _idempotency_key, _request_hash, jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version), now() + interval '30 days')
  returning * into receipt;
  return receipt.safe_result;
end;
$$;

create or replace function api.portal_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  return (
    select jsonb_build_object(
      'application', jsonb_build_object(
        'id', application.id, 'status', application.review_status, 'version', application.version,
        'draft', application.private_draft_data, 'reviewFeedback', application.review_feedback
      ),
      'portal', case when portal.id is null then null else jsonb_build_object(
        'id', portal.id, 'name', portal.name, 'description', portal.description, 'intensity', portal.intensity,
        'approvalStatus', portal.approval_status, 'operationStatus', portal.operation_status, 'version', portal.version,
        'world', world.name,
        'hasCredential', exists (select 1 from app_private.portal_credentials credential where credential.portal_id = portal.id and credential.revoked_at is null),
        'nextArrival', (
          select min(plan_stop.planned_arrival_at)
          from app_private.route_plan_stops plan_stop
          join app_private.route_plan_versions plan on plan.id = plan_stop.plan_version_id and plan.state = 'published'
          join app_private.group_runs run on run.active_plan_version_id = plan.id and run.status in ('ready', 'live', 'paused')
          where plan_stop.portal_id = portal.id and plan_stop.planned_arrival_at >= now()
        )
      ) end
    )
    from app_private.portal_applications application
    left join app_private.portals portal on portal.application_id = application.id
    left join app_private.worlds world on world.id = portal.world_id
    where application.event_id = v_event_id and application.applicant_user_id = actor
    order by application.created_at desc limit 1
  );
end;
$$;

create or replace function api.admin_planning_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'parties', coalesce((select jsonb_agg(jsonb_build_object(
      'id', registration.id,
      'childCount', (select count(*) from app_private.registration_children child where child.registration_id = registration.id and child.participation_status = 'active'),
      'requestedStartId', registration.start_preference_id,
      'togetherKey', membership.party_id
    ) order by registration.id)
    from app_private.registrations registration
    left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
    where registration.event_id = v_event_id and registration.status = 'submitted'
      and not exists (select 1 from app_private.group_registrations assignment where assignment.registration_id = registration.id and assignment.superseded_at is null)), '[]'::jsonb),
    'starts', coalesce((select jsonb_agg(jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups, 'maxChildren', slot.max_children) order by slot.starts_at, slot.id) from app_private.start_slots slot where slot.event_id = v_event_id and slot.active and slot.location_verified_at is not null), '[]'::jsonb),
    'portals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', portal.id, 'worldId', portal.world_id, 'opensAt', portal_window.opens_at, 'closesAt', portal_window.closes_at,
      'visitMinutes', portal_window.visit_minutes, 'maxConcurrentGroups', portal_window.max_concurrent_groups,
      'maxChildren', portal_window.max_children_per_visit, 'maxTotalChildren', portal_window.max_children_total
    ) order by portal.id)
    from app_private.portals portal
    join lateral (select * from app_private.portal_windows candidate where candidate.portal_id = portal.id order by candidate.opens_at limit 1) portal_window on true
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    where portal.event_id = v_event_id and portal.approval_status = 'approved'), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id,
        'code', walking_group.code,
        'status', walking_group.status,
        'planId', plan.id,
        'revision', plan.revision,
        'planState', plan.state,
        'portalIds', coalesce((
          select jsonb_agg(stop.portal_id order by stop.position)
          from app_private.route_plan_stops stop where stop.plan_version_id = plan.id
        ), '[]'::jsonb)
      ) order by walking_group.code)
      from app_private.walking_groups walking_group
      join app_private.route_plan_versions plan on plan.id = walking_group.current_plan_version_id
      where walking_group.event_id = v_event_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app_private.validate_portal_total_capacity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
  v_children integer;
  v_existing_children integer;
  v_limit integer;
begin
  select plan.group_id into v_group_id from app_private.route_plan_versions plan where plan.id = new.plan_version_id;
  select count(*) into v_children
  from app_private.group_registrations assignment
  join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
  where assignment.group_id = v_group_id and assignment.superseded_at is null;
  select window_record.max_children_total into v_limit
  from app_private.portal_windows window_record
  where window_record.portal_id = new.portal_id and new.planned_arrival_at >= window_record.opens_at and new.planned_departure_at <= window_record.closes_at
  order by window_record.opens_at limit 1;
  if v_limit is null then return new; end if;
  select coalesce(sum(group_size.children), 0)::integer into v_existing_children
  from app_private.route_plan_stops existing
  join app_private.route_plan_versions plan on plan.id = existing.plan_version_id and plan.state in ('valid', 'published')
  join lateral (
    select count(*)::integer as children
    from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
    where assignment.group_id = plan.group_id and assignment.superseded_at is null
  ) group_size on true
  where existing.portal_id = new.portal_id and existing.id is distinct from new.id
    and plan.group_id <> v_group_id;
  if v_existing_children + v_children > v_limit then raise exception 'PORTAL_TOTAL_CAPACITY_EXCEEDED' using errcode = '23514'; end if;
  return new;
end;
$$;

create trigger route_plan_stops_total_capacity
before insert or update of plan_version_id, portal_id, planned_arrival_at, planned_departure_at
on app_private.route_plan_stops
for each row execute function app_private.validate_portal_total_capacity();

-- Route revisions for one group are alternatives, not concurrent visitors.
-- Keep the original route validation contract while counting other groups
-- only once, irrespective of how many concept or published revisions exist.
create or replace function app_private.validate_route_plan_stop()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  plan_record record;
  window_record app_private.portal_windows;
  portal_world_id uuid;
  source_node_id uuid;
  target_node_id uuid;
  active_children integer;
  overlapping_groups integer;
begin
  select plan.id as plan_id, plan.state, walking_group.id as group_id, walking_group.event_id,
         slot.external_id as start_external_id
    into plan_record
  from app_private.route_plan_versions plan
  join app_private.walking_groups walking_group on walking_group.id = plan.group_id
  join app_private.start_slots slot on slot.id = walking_group.start_slot_id
  where plan.id = new.plan_version_id;
  if plan_record.plan_id is null then raise exception 'INVALID_ROUTE_PLAN' using errcode = '23514'; end if;
  if new.position < 1 or new.planned_departure_at <= new.planned_arrival_at then
    raise exception 'INVALID_ROUTE_TIMING' using errcode = '23514';
  end if;

  select portal.world_id into portal_world_id
  from app_private.portals portal
  join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
  where portal.id = new.portal_id and portal.event_id = plan_record.event_id and portal.approval_status = 'approved';
  if portal_world_id is null then raise exception 'PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  select candidate.* into window_record
  from app_private.portal_windows candidate
  where candidate.portal_id = new.portal_id
    and new.planned_arrival_at >= candidate.opens_at
    and new.planned_departure_at <= candidate.closes_at
    and new.planned_departure_at = new.planned_arrival_at + make_interval(mins => candidate.visit_minutes)
  order by candidate.opens_at limit 1;
  if window_record.id is null then raise exception 'PORTAL_WINDOW_CONFLICT' using errcode = '23514'; end if;

  select count(*) into active_children
  from app_private.group_registrations assignment
  join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
  where assignment.group_id = plan_record.group_id and assignment.superseded_at is null;
  if active_children = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if active_children > window_record.max_children_per_visit then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  if exists (
    select 1 from app_private.route_plan_stops existing
    join app_private.portals portal on portal.id = existing.portal_id
    where existing.plan_version_id = new.plan_version_id and existing.id is distinct from new.id
      and (existing.portal_id = new.portal_id or portal.world_id = portal_world_id)
  ) then raise exception 'DUPLICATE_PORTAL_OR_WORLD' using errcode = '23514'; end if;

  select count(distinct existing_plan.group_id) into overlapping_groups
  from app_private.route_plan_stops existing
  join app_private.route_plan_versions existing_plan on existing_plan.id = existing.plan_version_id
  where existing.portal_id = new.portal_id and existing.id is distinct from new.id
    and existing_plan.group_id <> plan_record.group_id
    and existing_plan.state in ('valid', 'published')
    and existing.planned_arrival_at < new.planned_departure_at
    and existing.planned_departure_at > new.planned_arrival_at;
  if overlapping_groups >= window_record.max_concurrent_groups then raise exception 'PORTAL_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  select node.id into target_node_id
  from app_private.walking_nodes node
  where node.event_id = plan_record.event_id and node.kind = 'portal' and node.portal_id = new.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if new.position = 1 then
    select node.id into source_node_id
    from app_private.walking_nodes node
    where node.event_id = plan_record.event_id and node.kind = 'start'
      and node.external_id = plan_record.start_external_id and node.verified_at is not null
    order by node.id limit 1;
  else
    select node.id into source_node_id
    from app_private.route_plan_stops previous_stop
    join app_private.walking_nodes node on node.portal_id = previous_stop.portal_id
      and node.event_id = plan_record.event_id and node.kind = 'portal' and node.verified_at is not null
    where previous_stop.plan_version_id = new.plan_version_id and previous_stop.position = new.position - 1
    order by node.id limit 1;
  end if;
  if not app_private.has_approved_walking_path(plan_record.event_id, source_node_id, target_node_id) then
    raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function app_private.guard_published_route_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid;
  v_state app_private.plan_state;
begin
  if tg_table_name = 'route_plan_versions' then
    if old.state = 'published' then
      raise exception 'PUBLISHED_PLAN_IMMUTABLE' using errcode = '55000';
    end if;
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  v_plan_id := case when tg_op = 'DELETE' then old.plan_version_id else new.plan_version_id end;
  select state into v_state from app_private.route_plan_versions where id = v_plan_id;
  if v_state = 'published' then
    raise exception 'PUBLISHED_PLAN_IMMUTABLE' using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger route_plan_versions_immutable
before update or delete on app_private.route_plan_versions
for each row execute function app_private.guard_published_route_plan();

create trigger route_plan_stops_immutable
before insert or update or delete on app_private.route_plan_stops
for each row execute function app_private.guard_published_route_plan();

create or replace function api.admin_create_plan_revision(
  _group_id uuid,
  _portal_ids uuid[],
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  v_revision integer;
  v_plan_id uuid;
  v_start_time timestamptz;
begin
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if coalesce(array_length(_portal_ids, 1), 0) not between 1 and 50
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if group_record.start_slot_id is null then raise exception 'INVALID_START' using errcode = '23514'; end if;

  select coalesce(max(revision), 0) + 1 into v_revision
  from app_private.route_plan_versions where group_id = group_record.id;
  select starts_at into v_start_time from app_private.start_slots where id = group_record.start_slot_id;

  insert into app_private.route_plan_versions(group_id, revision, state, generated_by, supersedes_id, input_hash)
  values (
    group_record.id,
    v_revision,
    'valid',
    actor,
    group_record.current_plan_version_id,
    md5(group_record.id::text || ':' || v_revision::text || ':' || array_to_string(_portal_ids, ','))
  ) returning id into v_plan_id;

  update app_private.walking_groups
  set current_plan_version_id = v_plan_id, version = version + 1
  where id = group_record.id;

  insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
  select v_plan_id, portal.position::integer, portal.id,
    v_start_time + make_interval(mins => (portal.position::integer - 1) * 8),
    v_start_time + make_interval(mins => (portal.position::integer - 1) * 8 + 5)
  from unnest(_portal_ids) with ordinality as portal(id, position)
  order by portal.position;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'route_plan.revision_created', 'route_plan_version', v_plan_id,
    jsonb_build_object('groupId', group_record.id, 'revision', v_revision, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('planId', v_plan_id, 'groupId', group_record.id, 'revision', v_revision, 'published', false);
end;
$$;

create or replace function api.admin_publish_plans(_event_slug text, _plan_ids uuid[], _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  affected integer;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(array_length(_plan_ids, 1), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if (select count(distinct plan.id) from app_private.route_plan_versions plan join app_private.walking_groups walking_group on walking_group.id = plan.group_id where plan.id = any(_plan_ids) and walking_group.event_id = v_event_id and plan.state = 'valid') <> (select count(distinct id) from unnest(_plan_ids) wanted(id)) then raise exception 'INVALID_PLAN' using errcode = '23514'; end if;

  update app_private.route_plan_stops
  set planned_arrival_at = planned_arrival_at
  where plan_version_id = any(_plan_ids);

  update app_private.route_plan_versions set state = 'published', published_at = now() where id = any(_plan_ids) and state = 'valid';
  get diagnostics affected = row_count;
  update app_private.walking_groups walking_group
  set status = case when walking_group.status = 'draft' then 'ready' else walking_group.status end,
      version = version + 1
  where walking_group.current_plan_version_id = any(_plan_ids);
  update app_private.group_registrations assignment set published_at = now() where assignment.group_id in (select plan.group_id from app_private.route_plan_versions plan where plan.id = any(_plan_ids));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.published', 'route_plan_batch', jsonb_build_object('planCount', affected, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', affected);
end;
$$;

create or replace function api.worker_claim_outbox(_batch_size integer, _lease_seconds integer)
returns setof app_private.email_outbox
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A worker can die after the provider accepted a message but before the local
  -- acknowledgement. Retrying that row blindly could duplicate mail, so an
  -- expired processing lease becomes an explicit reconciliation state.
  update app_private.email_outbox
  set status = 'unknown', lease_until = null, last_error_code = 'WORKER_LEASE_EXPIRED_AFTER_CLAIM'
  where status = 'processing' and lease_until < now();

  return query
  with candidates as (
    select id from app_private.email_outbox
    where status in ('pending', 'deferred')
      and next_attempt_at <= now()
      and (lease_until is null or lease_until < now())
    order by next_attempt_at, created_at
    for update skip locked
    limit least(greatest(_batch_size, 1), 50)
  )
  update app_private.email_outbox outbox
  set status = 'processing', lease_until = now() + make_interval(secs => least(greatest(_lease_seconds, 10), 300)), attempts = attempts + 1
  from candidates where outbox.id = candidates.id
  returning outbox.*;
end;
$$;

create or replace function api.run_complete_stop(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _all_skip_confirmed boolean,
  _idempotency_key text,
  _request_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  required_count integer;
  pending_count integer;
  visited_count integer;
  skipped_count integer;
  v_outcome app_private.stop_outcome;
  next_stop app_private.run_stops;
  world_id uuid;
  receipt app_private.command_receipts;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  -- Serialize the same actor/command/key before looking for its receipt. This
  -- makes simultaneous retries return one committed result instead of letting
  -- the loser observe a stale run between the receipt check and row lock.
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.completeStop:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'run.completeStop' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    if run_record.id is null or not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select count(*) filter (where required_for_completion),
         count(*) filter (where required_for_completion and status = 'pending'),
         count(*) filter (where status = 'visited'),
         count(*) filter (where status = 'skipped')
    into required_count, pending_count, visited_count, skipped_count
  from app_private.stop_participant_statuses where run_stop_id = _stop_id;
  if required_count = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if pending_count > 0 then raise exception 'PENDING_PARTICIPANTS' using errcode = '23514'; end if;
  if visited_count > 0 and not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  if visited_count = 0 and not _all_skip_confirmed then raise exception 'ALL_SKIP_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  v_outcome := case when visited_count > 0 and skipped_count > 0 then 'mixed'::app_private.stop_outcome when visited_count > 0 then 'visited'::app_private.stop_outcome else 'all_skipped'::app_private.stop_outcome end;
  update app_private.run_stops set state = 'completed', outcome = v_outcome, completed_at = now(), completion_actor = actor, version = version + 1 where id = _stop_id;
  select portal.world_id into world_id
  from app_private.route_plan_stops plan_stop join app_private.portals portal on portal.id = plan_stop.portal_id
  where plan_stop.id = stop_record.plan_stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome) values (_run_id, _stop_id, world_id, v_outcome);
  select * into next_stop from app_private.run_stops where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
  if next_stop.id is null then
    update app_private.group_runs set status = 'completed', current_stop_id = null, finished_at = now(), version = version + 1 where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
  else
    update app_private.run_stops set state = 'active', opened_at = now(), version = version + 1 where id = next_stop.id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select next_stop.id, participant.id from app_private.run_participants participant
    where participant.run_id = _run_id and participant.attendance = 'present';
    update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1 where id = _run_id returning * into run_record;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.completed', actor, jsonb_build_object('outcome', v_outcome));
  result := jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'completedStopId', _stop_id, 'outcome', v_outcome, 'hasNextStop', next_stop.id is not null);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.completeStop', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$$;

create or replace function api.payment_set_external_link(
  _payment_request_id uuid,
  _expected_version integer,
  _external_url text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  payment app_private.payment_requests;
  registration app_private.registrations;
  normalized_url text := trim(_external_url);
begin
  if char_length(normalized_url) not between 20 and 1000
     or normalized_url !~ '^https://([a-z0-9-]+[.])*tikkie[.]me/'
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select request.* into payment
  from app_private.payment_requests request
  join app_private.registrations registration_record on registration_record.id = request.registration_id
  where request.id = _payment_request_id for update of request;
  select * into registration from app_private.registrations where id = payment.registration_id;
  if payment.id is null or not (
    app_private.has_capability(registration.event_id, 'event_admin', actor)
    or app_private.has_capability(registration.event_id, 'payments_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if payment.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if payment.status not in ('awaiting_link', 'awaiting_payment') then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.payment_requests
  set external_url = normalized_url, status = 'awaiting_payment', version = version + 1
  where id = payment.id returning * into payment;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'payment.external_link_set', 'payment_request', payment.id, jsonb_build_object('provider', 'tikkie', 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', payment.id, 'status', payment.status, 'version', payment.version, 'externalUrl', payment.external_url);
end;
$$;

create or replace function api.admin_payments_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'payments_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', payment.id,
      'reference', payment.reference,
      'registrationReference', registration.reference,
      'amountCents', payment.amount_cents,
      'netCollectedCents', coalesce(ledger.net_collected_cents, 0),
      'status', payment.status,
      'version', payment.version,
      'externalUrl', payment.external_url,
      'reportedAt', ledger.reported_at,
      'updatedAt', payment.updated_at
    ) order by payment.updated_at desc, payment.reference)
    from app_private.payment_requests payment
    join app_private.registrations registration on registration.id = payment.registration_id
    left join lateral (
      select
        coalesce(sum(entry.amount_cents) filter (where entry.entry_type <> 'reported'), 0)::integer as net_collected_cents,
        max(entry.created_at) filter (where entry.entry_type = 'reported') as reported_at
      from app_private.payment_entries entry where entry.request_id = payment.id
    ) ledger on true
    where registration.event_id = v_event_id
  ), '[]'::jsonb);
end;
$$;

create or replace function api.together_leave(_registration_id uuid, _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  membership app_private.together_memberships;
  party app_private.together_parties;
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select member.* into membership from app_private.together_memberships member
  where member.registration_id = registration.id and member.left_at is null for update;
  if membership.id is null then raise exception 'NOT_IN_PARTY' using errcode = '23514'; end if;
  select * into party from app_private.together_parties where id = membership.party_id for update;
  if party.locked_at is not null then raise exception 'PARTY_LOCKED' using errcode = '23514'; end if;
  update app_private.together_memberships set left_at = now() where id = membership.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'together_party.left', 'together_party', party.id,
    jsonb_build_object('registrationId', registration.id, 'reason', left(trim(_reason), 300)));
  return jsonb_build_object('registrationId', registration.id, 'partyId', party.id, 'left', true);
end;
$$;

create unique index if not exists content_versions_one_published
on app_private.content_versions(event_id, page_key, locale)
where status = 'published';

create or replace function api.admin_content_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (app_private.has_capability(v_event_id, 'content_manage', actor) or app_private.has_capability(v_event_id, 'event_admin', actor)) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'versions', coalesce((select jsonb_agg(jsonb_build_object(
      'id', content.id, 'pageKey', content.page_key, 'locale', content.locale, 'content', content.structured_content,
      'status', content.status, 'version', content.version, 'publishedAt', content.published_at, 'createdAt', content.created_at
    ) order by content.page_key, content.locale, content.version desc) from app_private.content_versions content where content.event_id = v_event_id), '[]'::jsonb),
    'sponsors', coalesce((select jsonb_agg(jsonb_build_object(
      'id', application.id, 'contactName', application.contact_name, 'contactEmail', application.contact_email,
      'contributionType', application.contribution_type, 'proposedAmountCents', application.proposed_amount_cents,
      'message', application.message, 'status', application.review_status, 'version', application.version,
      'publication', case when publication.sponsor_application_id is null then null else jsonb_build_object(
        'approvedName', publication.approved_name, 'websiteUrl', publication.website_url, 'sortOrder', publication.sort_order, 'publishedAt', publication.published_at
      ) end
    ) order by application.created_at desc) from app_private.sponsor_applications application
      left join app_private.sponsor_publications publication on publication.sponsor_application_id = application.id
      where application.event_id = v_event_id), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_save_content_draft(_event_slug text, _page_key text, _locale text, _content jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); v_event_id uuid; next_version integer; created app_private.content_versions;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not (app_private.has_capability(v_event_id, 'content_manage', actor) or app_private.has_capability(v_event_id, 'event_admin', actor)) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if trim(coalesce(_page_key, '')) !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' or trim(coalesce(_locale, '')) !~ '^[a-z]{2}-[A-Z]{2}$'
     or jsonb_typeof(_content) <> 'object' or octet_length(_content::text) > 50000 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select coalesce(max(version), 0) + 1 into next_version from app_private.content_versions where event_id = v_event_id and page_key = trim(_page_key) and locale = trim(_locale);
  insert into app_private.content_versions(event_id, page_key, locale, structured_content, status, created_by, version)
  values (v_event_id, trim(_page_key), trim(_locale), _content, 'draft', actor, next_version) returning * into created;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'content.draft_created', 'content_version', created.id, jsonb_build_object('pageKey', created.page_key, 'locale', created.locale, 'version', created.version));
  return jsonb_build_object('id', created.id, 'pageKey', created.page_key, 'locale', created.locale, 'status', created.status, 'version', created.version);
end;
$$;

create or replace function api.admin_publish_content(_content_version_id uuid, _expected_version integer, _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); content app_private.content_versions;
begin
  select * into content from app_private.content_versions where id = _content_version_id for update;
  if content.id is null or not (app_private.has_capability(content.event_id, 'content_manage', actor) or app_private.has_capability(content.event_id, 'event_admin', actor)) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if content.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if content.status <> 'draft' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.content_versions set status = 'archived'
  where event_id = content.event_id and page_key = content.page_key and locale = content.locale and status = 'published';
  update app_private.content_versions set status = 'published', published_at = now() where id = content.id returning * into content;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (content.event_id, actor, 'content.published', 'content_version', content.id,
    jsonb_build_object('pageKey', content.page_key, 'locale', content.locale, 'version', content.version, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', content.id, 'status', content.status, 'version', content.version, 'publishedAt', content.published_at);
end;
$$;

create or replace function api.admin_publish_sponsor(
  _application_id uuid, _expected_version integer, _approved_name text, _website_url text, _sort_order integer, _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); application app_private.sponsor_applications; publication app_private.sponsor_publications;
begin
  select * into application from app_private.sponsor_applications where id = _application_id for update;
  if application.id is null or not (app_private.has_capability(application.event_id, 'content_manage', actor) or app_private.has_capability(application.event_id, 'event_admin', actor)) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if char_length(trim(coalesce(_approved_name, ''))) not between 1 and 120 or _sort_order not between 0 and 10000
     or (nullif(trim(coalesce(_website_url, '')), '') is not null and trim(_website_url) !~ '^https://[^[:space:]]+$')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  insert into app_private.sponsor_publications(sponsor_application_id, approved_name, website_url, sort_order, published_at, published_by)
  values (application.id, trim(_approved_name), nullif(trim(_website_url), ''), _sort_order, now(), actor)
  on conflict (sponsor_application_id) do update set approved_name = excluded.approved_name, website_url = excluded.website_url,
    sort_order = excluded.sort_order, published_at = excluded.published_at, published_by = excluded.published_by
  returning * into publication;
  update app_private.sponsor_applications set review_status = 'approved', version = version + 1, updated_at = now() where id = application.id returning * into application;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (application.event_id, actor, 'sponsor.published', 'sponsor_application', application.id,
    jsonb_build_object('approvedName', publication.approved_name, 'sortOrder', publication.sort_order, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'publishedAt', publication.published_at);
end;
$$;

create or replace function api.event_public_snapshot(_event_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'slug', event.slug, 'title', event.title, 'date', event.local_date, 'timezone', event.timezone,
    'phase', event.phase, 'priceCents', event.price_cents, 'currency', event.currency,
    'registrationOpen', event.phase = 'registration_open'
      and (event.registration_open_at is null or event.registration_open_at <= now())
      and (event.registration_close_at is null or event.registration_close_at > now()),
    'worlds', coalesce((select jsonb_agg(jsonb_build_object('slug', world.slug, 'name', world.name, 'story', world.story, 'artworkPath', world.artwork_path) order by world.sort_order)
      from app_private.worlds world where world.event_id = event.id), '[]'::jsonb),
    'sponsors', coalesce((select jsonb_agg(jsonb_build_object('name', publication.approved_name, 'logoPath', publication.logo_path, 'url', publication.website_url) order by publication.sort_order, publication.approved_name)
      from app_private.sponsor_publications publication join app_private.sponsor_applications application on application.id = publication.sponsor_application_id where application.event_id = event.id), '[]'::jsonb),
    'content', coalesce((select jsonb_object_agg(content.page_key, content.structured_content order by content.page_key)
      from app_private.content_versions content where content.event_id = event.id and content.locale = 'nl-NL' and content.status = 'published'), '{}'::jsonb)
  ) from app_private.events event where event.slug = _event_slug
$$;

revoke execute on function api.admin_portal_applications_snapshot(text) from public, anon;
revoke execute on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text) from public, anon;
revoke execute on function api.admin_verify_portal_location(uuid, integer, numeric, numeric, text) from public, anon;
revoke execute on function app_private.validate_portal_total_capacity() from public, anon, authenticated;
revoke execute on function app_private.guard_published_route_plan() from public, anon, authenticated;
revoke execute on function api.admin_create_plan_revision(uuid, uuid[], text) from public, anon;
revoke execute on function api.payment_set_external_link(uuid, integer, text, text) from public, anon;
revoke execute on function api.together_leave(uuid, text) from public, anon;
revoke execute on function api.admin_content_snapshot(text) from public, anon;
revoke execute on function api.admin_save_content_draft(text, text, text, jsonb) from public, anon;
revoke execute on function api.admin_publish_content(uuid, integer, text) from public, anon;
revoke execute on function api.admin_publish_sponsor(uuid, integer, text, text, integer, text) from public, anon;
grant execute on function api.admin_portal_applications_snapshot(text) to authenticated;
grant execute on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text) to authenticated;
grant execute on function api.admin_verify_portal_location(uuid, integer, numeric, numeric, text) to authenticated;
grant execute on function api.admin_create_plan_revision(uuid, uuid[], text) to authenticated;
grant execute on function api.payment_set_external_link(uuid, integer, text, text) to authenticated;
grant execute on function api.together_leave(uuid, text) to authenticated;
grant execute on function api.admin_content_snapshot(text) to authenticated;
grant execute on function api.admin_save_content_draft(text, text, text, jsonb) to authenticated;
grant execute on function api.admin_publish_content(uuid, integer, text) to authenticated;
grant execute on function api.admin_publish_sponsor(uuid, integer, text, text, integer, text) to authenticated;
