-- Continuous routes, separately published group schedules and verified house
-- onboarding. Existing published route-plan rows stay readable so a rollout
-- never invalidates an already-issued instruction; all new dynamic runs use
-- reservations and exactly one released stop at a time.

create type app_private.start_time_preference as enum ('early', 'indifferent', 'later');
create type app_private.schedule_state as enum ('draft', 'published', 'superseded');
create type app_private.reservation_kind as enum ('ordinary', 'finale');
create type app_private.reservation_status as enum ('held', 'active', 'completed', 'cancelled', 'expired');
create type app_private.dynamic_stop_kind as enum ('ordinary', 'finale');

create table app_private.portal_registration_intakes (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  normalized_email text not null check (normalized_email = lower(trim(normalized_email)) and char_length(normalized_email) between 3 and 320),
  contact_name text not null check (char_length(contact_name) between 2 and 120),
  phone text not null check (char_length(phone) between 6 and 32),
  private_address jsonb not null,
  claimed_user_id uuid references auth.users(id) on delete restrict,
  application_id uuid references app_private.portal_applications(id) on delete restrict,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, normalized_email),
  check ((claimed_at is null and claimed_user_id is null and application_id is null)
      or (claimed_at is not null and claimed_user_id is not null and application_id is not null))
);

create table app_private.start_points (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  private_address text not null check (char_length(private_address) between 3 and 300),
  latitude numeric(9,6),
  longitude numeric(9,6),
  walking_node_id uuid references app_private.walking_nodes(id) on delete restrict,
  accessible boolean,
  accessibility_notes text check (accessibility_notes is null or char_length(accessibility_notes) <= 500),
  max_gathering_groups integer not null default 1 check (max_gathering_groups > 0),
  max_gathering_children integer not null default 20 check (max_gathering_children > 0),
  verified_at timestamptz,
  verified_by uuid references auth.users(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, id),
  check ((latitude is null) = (longitude is null)),
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180)
);

alter table app_private.start_slots add column start_point_id uuid references app_private.start_points(id) on delete restrict;

-- One physical point per legacy row preserves the exact verified node/address.
-- Administrators can subsequently merge equal points while retaining every
-- exact start time as its own slot.
insert into app_private.start_points(
  id, event_id, name, private_address, latitude, longitude, walking_node_id,
  max_gathering_groups, max_gathering_children, verified_at
)
select
  slot.id, slot.event_id, slot.location_name, coalesce(slot.private_address, slot.location_name),
  slot.latitude, slot.longitude,
  (select node.id from app_private.walking_nodes node
   where node.event_id = slot.event_id and node.kind = 'start'
     and node.external_id is not distinct from slot.external_id
   order by node.verified_at desc nulls last, node.id limit 1),
  slot.max_groups, slot.max_children, slot.location_verified_at
from app_private.start_slots slot
on conflict (id) do nothing;

update app_private.start_slots slot set start_point_id = slot.id where start_point_id is null;
create index start_slots_point_time_idx on app_private.start_slots(start_point_id, starts_at) where active;

alter table app_private.registrations
  add column start_time_preference app_private.start_time_preference not null default 'indifferent',
  add column requested_ordinary_stop_at timestamptz,
  add column preference_change_status text not null default 'editable'
    check (preference_change_status in ('editable', 'locked', 'change_requested'));

create table app_private.event_route_settings (
  event_id uuid primary key references app_private.events(id) on delete cascade,
  first_start_at timestamptz,
  early_preference_latest_at timestamptz,
  later_preference_earliest_at timestamptz,
  global_ordinary_stop_at timestamptz,
  allowed_personal_stop_times timestamptz[] not null default '{}'::timestamptz[],
  ordinary_visit_seconds integer not null default 300 check (ordinary_visit_seconds between 60 and 1800),
  route_buffer_seconds integer not null default 120 check (route_buffer_seconds between 0 and 1800),
  reservation_ttl_seconds integer not null default 1200 check (reservation_ttl_seconds between 300 and 3600),
  final_portal_id uuid unique references app_private.portals(id) on delete restrict,
  finale_opens_at timestamptz,
  finale_last_arrival_at timestamptz,
  finale_closes_at timestamptz,
  finale_show_seconds integer not null default 360 check (finale_show_seconds between 60 and 3600),
  finale_turnover_seconds integer not null default 0 check (finale_turnover_seconds between 0 and 1800),
  finale_planning_transfer_seconds integer not null default 900 check (finale_planning_transfer_seconds between 60 and 3600),
  finale_max_concurrent_groups integer not null default 1 check (finale_max_concurrent_groups > 0),
  finale_max_concurrent_children integer not null default 20 check (finale_max_concurrent_children > 0),
  finale_safe_approach text,
  finale_waiting_area text,
  finale_exit_route text,
  finale_accessible_entrance text,
  finale_contact text,
  emergency_destination_name text,
  emergency_instructions text,
  finale_available boolean not null default true,
  planner_mode text not null default 'disabled' check (planner_mode in ('disabled', 'shadow', 'dynamic')),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  version integer not null default 1 check (version > 0),
  check (first_start_at is null or global_ordinary_stop_at is null or first_start_at < global_ordinary_stop_at),
  check (finale_opens_at is null or finale_last_arrival_at is null or finale_opens_at <= finale_last_arrival_at),
  check (finale_last_arrival_at is null or finale_closes_at is null or finale_last_arrival_at <= finale_closes_at)
);

create table app_private.group_schedule_revisions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  revision integer not null check (revision > 0),
  state app_private.schedule_state not null default 'draft',
  start_slot_id uuid not null references app_private.start_slots(id) on delete restrict,
  effective_ordinary_stop_at timestamptz not null,
  expected_finale_arrival_at timestamptz,
  queue_number integer check (queue_number is null or queue_number > 0),
  preference_match text not null default 'neutral' check (preference_match in ('good', 'small_deviation', 'large_deviation', 'neutral')),
  input_snapshot jsonb not null default '{}'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  supersedes_id uuid references app_private.group_schedule_revisions(id),
  unique (group_id, revision),
  check ((state = 'published' and published_at is not null) or state <> 'published')
);
create unique index group_schedule_one_published_idx on app_private.group_schedule_revisions(group_id) where state = 'published';
create index group_schedule_start_load_idx on app_private.group_schedule_revisions(start_slot_id, state);

alter table app_private.walking_groups
  add column current_schedule_revision_id uuid references app_private.group_schedule_revisions(id) on delete restrict,
  add column route_mode text not null default 'legacy' check (route_mode in ('legacy', 'dynamic'));

create table app_private.portal_reservations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete restrict,
  portal_id uuid not null references app_private.portals(id) on delete restrict,
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  run_id uuid references app_private.group_runs(id) on delete restrict,
  kind app_private.reservation_kind not null,
  status app_private.reservation_status not null default 'held',
  reserved_from timestamptz not null,
  reserved_until timestamptz not null,
  child_count integer not null check (child_count > 0),
  expires_at timestamptz,
  cancelled_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  check (reserved_from < reserved_until),
  check (expires_at is null or expires_at > created_at)
);
create index portal_reservations_capacity_idx
  on app_private.portal_reservations(portal_id, reserved_from, reserved_until)
  where status in ('held', 'active');
create index portal_reservations_run_idx on app_private.portal_reservations(run_id, status, kind);
create unique index portal_reservations_one_active_ordinary_run_idx
  on app_private.portal_reservations(run_id) where kind = 'ordinary' and status in ('held', 'active');
create unique index portal_reservations_one_active_finale_run_idx
  on app_private.portal_reservations(run_id) where kind = 'finale' and status in ('held', 'active');

create table app_private.dispatch_decisions (
  id bigint generated always as identity primary key,
  event_id uuid not null references app_private.events(id) on delete restrict,
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  sequence integer not null check (sequence > 0),
  selected_portal_id uuid references app_private.portals(id) on delete restrict,
  selected_kind app_private.dynamic_stop_kind,
  decision text not null check (decision in ('ordinary', 'finale', 'wait', 'emergency')),
  input_snapshot jsonb not null,
  candidate_summary jsonb not null default '[]'::jsonb,
  reason text not null,
  planner_version integer not null default 1,
  created_at timestamptz not null default now(),
  unique (run_id, sequence)
);

create table app_private.route_alerts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  group_id uuid references app_private.walking_groups(id) on delete cascade,
  run_id uuid references app_private.group_runs(id) on delete cascade,
  portal_id uuid references app_private.portals(id) on delete cascade,
  priority text not null check (priority in ('info', 'warning', 'urgent')),
  code text not null,
  message text not null,
  status text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id),
  resolution_reason text
);
create index route_alerts_open_idx on app_private.route_alerts(event_id, priority, created_at) where status = 'open';

alter table app_private.group_runs alter column active_plan_version_id drop not null;
alter table app_private.group_runs add column schedule_revision_id uuid references app_private.group_schedule_revisions(id) on delete restrict;

alter table app_private.run_stops alter column plan_stop_id drop not null;
alter table app_private.run_stops
  add column portal_id uuid references app_private.portals(id) on delete restrict,
  add column reservation_id uuid references app_private.portal_reservations(id) on delete restrict,
  add column stop_kind app_private.dynamic_stop_kind;
alter table app_private.run_stops add constraint run_stops_source_check check (
  (plan_stop_id is not null and portal_id is null and reservation_id is null and stop_kind is null)
  or (plan_stop_id is null and portal_id is not null and reservation_id is not null and stop_kind is not null)
);
create unique index run_stops_dynamic_reservation_idx on app_private.run_stops(reservation_id) where reservation_id is not null;

create table app_private.group_safe_departures (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  run_id uuid references app_private.group_runs(id) on delete restrict,
  responsible_adult_user_id uuid not null references auth.users(id) on delete restrict,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check (char_length(reason) between 10 and 500),
  created_at timestamptz not null default now()
);

create trigger portal_registration_intakes_touch before update on app_private.portal_registration_intakes
for each row execute function app_private.touch_updated_at();
create trigger start_points_touch before update on app_private.start_points
for each row execute function app_private.touch_updated_at();
create trigger event_route_settings_touch before update on app_private.event_route_settings
for each row execute function app_private.touch_updated_at();
create trigger portal_reservations_touch before update on app_private.portal_reservations
for each row execute function app_private.touch_updated_at();

do $$
declare item text;
begin
  foreach item in array array[
    'portal_registration_intakes','start_points','event_route_settings','group_schedule_revisions',
    'portal_reservations','dispatch_decisions','route_alerts','group_safe_departures'
  ] loop
    execute format('alter table app_private.%I enable row level security', item);
    execute format('revoke all on table app_private.%I from public, anon, authenticated', item);
  end loop;
end $$;

create or replace function api.portal_registration_begin(
  _event_slug text,
  _email text,
  _contact_name text,
  _phone text,
  _street text,
  _house_number text,
  _addition text,
  _postal_code text,
  _opaque_subject_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_record app_private.events;
  v_normalized_email text := lower(trim(_email));
  normalized_postal_code text := upper(replace(trim(_postal_code), ' ', ''));
  bucket_count integer;
  intake_id uuid;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, false) then
    raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;
  if v_normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or char_length(v_normalized_email) > 320
     or char_length(trim(_contact_name)) not between 2 and 120
     or char_length(trim(_phone)) not between 6 and 32
     or char_length(trim(_street)) not between 2 and 120
     or char_length(trim(_house_number)) not between 1 and 12
     or char_length(coalesce(trim(_addition), '')) > 12
     or normalized_postal_code !~ '^[0-9]{4}[A-Z]{2}$'
     or char_length(trim(coalesce(_opaque_subject_hash, ''))) < 16 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, count, expires_at)
  values ('portal_registration', _opaque_subject_hash, date_trunc('hour', now()), 1, date_trunc('hour', now()) + interval '2 hours')
  on conflict (scope, opaque_subject_hash, window_start)
  do update set count = app_private.rate_limit_buckets.count + 1
  returning count into bucket_count;
  if bucket_count > 8 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;

  perform pg_advisory_xact_lock(hashtextextended(event_record.id::text || ':portal-intake:' || v_normalized_email, 0));
  insert into app_private.portal_registration_intakes(
    event_id, normalized_email, contact_name, phone, private_address
  ) values (
    event_record.id, v_normalized_email, trim(_contact_name), trim(_phone),
    jsonb_build_object(
      'street', trim(_street),
      'houseNumber', trim(_house_number),
      'addition', nullif(trim(_addition), ''),
      'postalCode', normalized_postal_code
    )
  )
  on conflict (event_id, normalized_email) do update
    set contact_name = excluded.contact_name,
        phone = excluded.phone,
        private_address = excluded.private_address,
        version = app_private.portal_registration_intakes.version + 1
    where app_private.portal_registration_intakes.claimed_at is null
  returning id into intake_id;

  if intake_id is null then
    select id into intake_id from app_private.portal_registration_intakes
    where event_id = event_record.id and app_private.portal_registration_intakes.normalized_email = v_normalized_email;
  end if;
  return jsonb_build_object('accepted', true, 'intakeId', intake_id);
end;
$$;

create or replace function api.portal_registration_claim(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  verified_email text;
  v_event_id uuid;
  intake app_private.portal_registration_intakes;
  application app_private.portal_applications;
  basis jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select lower(trim(email)) into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_event_id::text || ':portal-account:' || actor::text, 0));
  select * into application from app_private.portal_applications
  where event_id = v_event_id and applicant_user_id = actor
  order by (review_status not in ('withdrawn', 'rejected')) desc, created_at desc
  limit 1 for update;

  select * into intake from app_private.portal_registration_intakes
  where event_id = v_event_id and normalized_email = verified_email
  for update;
  if intake.id is null then
    if application.id is null then raise exception 'PORTAL_INTAKE_NOT_FOUND' using errcode = 'P0002'; end if;
    return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'existing', true);
  end if;

  basis := jsonb_build_object(
    'email', verified_email,
    'contactName', intake.contact_name,
    'phone', intake.phone,
    'address', intake.private_address
  );
  if application.id is null then
    insert into app_private.portal_applications(event_id, applicant_user_id, private_draft_data)
    values (v_event_id, actor, basis) returning * into application;
  elsif intake.application_id is null then
    update app_private.portal_applications
    set private_draft_data = private_draft_data || basis,
        version = version + 1
    where id = application.id
    returning * into application;
  end if;

  update app_private.portal_registration_intakes
  set claimed_user_id = actor, application_id = application.id, claimed_at = coalesce(claimed_at, now()), version = version + 1
  where id = intake.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'portal_registration.claimed', 'portal_application', application.id, jsonb_build_object('intakeId', intake.id))
  on conflict do nothing;
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'existing', intake.application_id is not null);
end;
$$;

create or replace function api.portal_application_save(
  _event_slug text,
  _payload jsonb,
  _expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  verified_email text;
  application app_private.portal_applications;
  next_status app_private.review_status;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select lower(trim(email)) into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or pg_column_size(_payload) > 65536 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(event_record.id::text || ':portal-account:' || actor::text, 0));
  select * into application from app_private.portal_applications
  where event_id = event_record.id and applicant_user_id = actor
  order by (review_status not in ('withdrawn', 'rejected')) desc, created_at desc
  limit 1 for update;
  if application.id is null and not coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, false) then
    raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;
  _payload := _payload || jsonb_build_object('email', verified_email);

  if application.id is null then
    insert into app_private.portal_applications(event_id, applicant_user_id, private_draft_data)
    values (event_record.id, actor, _payload) returning * into application;
  else
    if application.review_status in ('withdrawn', 'rejected') then raise exception 'APPLICATION_NOT_EDITABLE' using errcode = '23514'; end if;
    if _expected_version is not null and application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    next_status := case
      when application.review_status in ('submitted', 'approved') then 'changes_requested'::app_private.review_status
      else application.review_status
    end;
    update app_private.portal_applications
    set private_draft_data = _payload,
        review_status = next_status,
        review_feedback = case when next_status = 'changes_requested' then 'Gegevens door eigenaar gewijzigd; opnieuw beoordelen.' else review_feedback end,
        reviewed_by = case when next_status = 'changes_requested' then null else reviewed_by end,
        reviewed_at = case when next_status = 'changes_requested' then null else reviewed_at end,
        version = version + 1
    where id = application.id returning * into application;
  end if;
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'savedAt', application.updated_at);
end;
$$;

create or replace function api.portal_application_submit(
  _application_id uuid,
  _expected_version integer,
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
  application app_private.portal_applications;
  actor_email text;
  receipt app_private.command_receipts;
  v_world_id uuid;
  draft jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':portal.submit:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'portal.submit' and idempotency_key = _idempotency_key;
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
     or coalesce(draft ->> 'accessibility', '') not in ('', 'step_free', 'steps', 'mixed', 'unknown')
     or coalesce(jsonb_typeof(draft -> 'warnings'), '') <> 'object'
     or coalesce(draft -> 'availability', 'false'::jsonb) <> 'true'::jsonb
     or coalesce(draft -> 'locationConsent', 'false'::jsonb) <> 'true'::jsonb
     or (draft ->> 'availableUntil')::time <= (draft ->> 'availableFrom')::time then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  update app_private.portal_applications
  set review_status = 'submitted', requested_world_id = v_world_id, review_feedback = null,
      submitted_at = now(), reviewed_by = null, reviewed_at = null, version = version + 1
  where id = application.id returning * into application;
  select email into actor_email from auth.users where id = actor;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'portal:' || application.id::text || ':received:' || application.version::text,
    'portal_received', actor::text, actor_email,
    jsonb_build_object('applicationId', application.id, 'applicationVersion', application.version)
  ) on conflict (dedupe_key) do nothing;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (application.event_id, actor, 'portal_application.submitted', 'portal_application', application.id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'portal.submit', _idempotency_key, _request_hash,
    jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
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
  route_settings app_private.event_route_settings;
  v_world_id uuid;
  portal_record app_private.portals;
  draft jsonb;
  portal_name text;
  portal_description text;
  street text;
  house_number text;
  addition text;
  postal_code text;
  v_intensity smallint;
  available_from text;
  available_until text;
  opens_at timestamptz;
  closes_at timestamptz;
  v_visit_minutes integer;
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
        review_feedback = trim(_reason), reviewed_by = actor, reviewed_at = now(), version = version + 1
    where id = application.id returning * into application;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (application.event_id, actor, 'portal_application.' || _decision, 'portal_application', application.id,
      jsonb_build_object('reason', left(trim(_reason), 500)));
    return jsonb_build_object(
      'id', application.id, 'status', application.review_status, 'version', application.version,
      'portalId', (select id from app_private.portals where application_id = application.id)
    );
  end if;

  select * into event_record from app_private.events where id = application.event_id;
  select * into route_settings from app_private.event_route_settings where event_id = application.event_id;
  select world.id into v_world_id from app_private.worlds world
  where world.event_id = application.event_id and world.slug = lower(trim(_world_slug));
  if v_world_id is null then raise exception 'INVALID_WORLD' using errcode = '22023'; end if;

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
  v_intensity := (draft ->> 'intensity')::smallint;
  available_from := coalesce(draft ->> 'availableFrom', '18:00');
  available_until := coalesce(draft ->> 'availableUntil', '22:00');
  if available_from !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or available_until !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'INCOMPLETE_APPLICATION' using errcode = '23514';
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
  v_visit_minutes := ceil(coalesce(route_settings.ordinary_visit_seconds, 300)::numeric / 60)::integer;

  select * into portal_record from app_private.portals where application_id = application.id for update;
  if portal_record.id is null then
    insert into app_private.portals(event_id, application_id, world_id, name, description, intensity, approval_status, operation_status)
    values (application.event_id, application.id, v_world_id, portal_name, portal_description, v_intensity, 'approved', 'scheduled')
    returning * into portal_record;
    insert into app_private.portal_owners(portal_id, user_id) values (portal_record.id, application.applicant_user_id);
  else
    update app_private.portals
    set world_id = v_world_id, name = portal_name, description = portal_description, intensity = v_intensity,
        approval_status = 'approved', version = version + 1
    where id = portal_record.id returning * into portal_record;
  end if;

  insert into app_private.portal_private_locations(
    portal_id, street, house_number, addition, postal_code, city, latitude, longitude, verified_at, verified_by
  ) values (
    portal_record.id, street, house_number, addition, postal_code, 'Den Haag', _latitude, _longitude,
    case when _latitude is not null then now() else null end,
    case when _latitude is not null then actor else null end
  ) on conflict (portal_id) do update
    set street = excluded.street, house_number = excluded.house_number, addition = excluded.addition,
        postal_code = excluded.postal_code, latitude = excluded.latitude, longitude = excluded.longitude,
        verified_at = excluded.verified_at, verified_by = excluded.verified_by;

  insert into app_private.portal_publications(portal_id, published_title, teaser, public_area, published_at)
  values (portal_record.id, portal_name, portal_description, 'Duindorp', now())
  on conflict (portal_id) do update
    set published_title = excluded.published_title, teaser = excluded.teaser,
        published_at = now(), version = app_private.portal_publications.version + 1;
  delete from app_private.portal_windows where portal_id = portal_record.id;
  insert into app_private.portal_windows(
    portal_id, opens_at, closes_at, visit_minutes, buffer_minutes,
    max_concurrent_groups, max_children_per_visit, max_children_total
  ) values (
    portal_record.id, opens_at, closes_at, v_visit_minutes,
    ceil(coalesce(route_settings.route_buffer_seconds, 120)::numeric / 60)::integer,
    1, 32767, 2147483647
  );
  delete from app_private.portal_flags where portal_id = portal_record.id;
  insert into app_private.portal_flags(portal_id, flag_key, value)
  select portal_record.id, flag.key, flag.value::boolean
  from jsonb_each_text(coalesce(draft -> 'warnings', '{}'::jsonb)) flag
  where flag.key in ('smoke', 'flashes', 'sound', 'actors', 'allergens') and flag.value in ('true', 'false');
  update app_private.portal_applications
  set review_status = 'approved', requested_world_id = v_world_id, review_feedback = null,
      reviewed_by = actor, reviewed_at = now(), version = version + 1
  where id = application.id returning * into application;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    application.event_id, actor, 'portal_application.approved', 'portal_application', application.id,
    jsonb_build_object('portalId', portal_record.id, 'worldId', v_world_id,
      'locationVerified', _latitude is not null, 'reason', left(trim(_reason), 500))
  );
  return jsonb_build_object(
    'id', application.id, 'status', application.review_status, 'version', application.version,
    'portalId', portal_record.id, 'portalVersion', portal_record.version,
    'locationVerified', _latitude is not null
  );
end;
$$;

insert into app_private.event_route_settings(event_id)
select id from app_private.events on conflict (event_id) do nothing;

create or replace function app_private.copy_registration_preferences_from_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft jsonb;
  preference text;
  requested_stop text;
  parsed_stop timestamptz;
  route_settings app_private.event_route_settings;
begin
  select payload into draft from app_private.registration_drafts
  where event_id = new.event_id and household_id = new.household_id;
  preference := draft ->> 'startPreference';
  requested_stop := draft ->> 'ordinaryStopAt';
  if draft ? 'startPreference' and coalesce(preference, '') not in ('early', 'indifferent', 'later') then
    raise exception 'INVALID_START_PREFERENCE' using errcode = '22023';
  end if;
  if preference in ('early', 'indifferent', 'later') then
    new.start_time_preference := preference::app_private.start_time_preference;
  end if;
  if nullif(trim(requested_stop), '') is not null then
    begin
      parsed_stop := requested_stop::timestamptz;
    exception when others then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end;
    select * into route_settings from app_private.event_route_settings where event_id = new.event_id;
    if route_settings.global_ordinary_stop_at is null
       or parsed_stop > route_settings.global_ordinary_stop_at
       or not (parsed_stop = any(route_settings.allowed_personal_stop_times)) then
      raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
    end if;
    new.requested_ordinary_stop_at := parsed_stop;
  end if;
  return new;
end;
$$;

create trigger registrations_copy_preferences
before insert on app_private.registrations
for each row execute function app_private.copy_registration_preferences_from_draft();

create or replace function api.registration_preferences_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  registration app_private.registrations;
  schedule_published boolean := false;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  select registration_record.* into registration
  from app_private.registrations registration_record
  where registration_record.event_id = event_record.id
    and registration_record.status <> 'cancelled'
    and app_private.is_household_member(registration_record.household_id, actor)
  order by registration_record.created_at desc limit 1;
  if registration.id is not null then
    select exists (
      select 1 from app_private.group_registrations assignment
      join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
      where assignment.registration_id = registration.id and assignment.superseded_at is null
    ) into schedule_published;
  end if;
  return jsonb_build_object(
    'registrationId', registration.id,
    'version', registration.version,
    'startPreference', coalesce(registration.start_time_preference::text, 'indifferent'),
    'ordinaryStopAt', registration.requested_ordinary_stop_at,
    'editable', registration.id is not null and not schedule_published and registration.preference_change_status = 'editable',
    'changeStatus', registration.preference_change_status,
    'confirmedSchedule', case when not schedule_published then null else (
      select jsonb_build_object(
        'startsAt', slot.starts_at, 'startPoint', point.name,
        'startAddress', point.private_address,
        'effectiveOrdinaryStopAt', schedule.effective_ordinary_stop_at,
        'expectedFinaleArrivalAt', schedule.expected_finale_arrival_at,
        'revision', schedule.revision
      )
      from app_private.group_registrations assignment
      join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
      join app_private.start_slots slot on slot.id = schedule.start_slot_id
      join app_private.start_points point on point.id = slot.start_point_id
      where assignment.registration_id = registration.id and assignment.superseded_at is null
      limit 1
    ) end,
    'event', jsonb_build_object(
      'firstStartAt', (select first_start_at from app_private.event_route_settings where event_id = event_record.id),
      'globalOrdinaryStopAt', (select global_ordinary_stop_at from app_private.event_route_settings where event_id = event_record.id),
      'allowedStopTimes', coalesce((select to_jsonb(allowed_personal_stop_times) from app_private.event_route_settings where event_id = event_record.id), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function api.registration_preferences_save(
  _registration_id uuid,
  _start_preference app_private.start_time_preference,
  _ordinary_stop_at timestamptz,
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
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if registration.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if registration.preference_change_status <> 'editable' or exists (
    select 1 from app_private.group_registrations assignment
    join app_private.group_schedule_revisions schedule on schedule.group_id = assignment.group_id and schedule.state = 'published'
    where assignment.registration_id = registration.id and assignment.superseded_at is null
  ) then raise exception 'PREFERENCES_LOCKED' using errcode = '23514'; end if;
  select * into settings from app_private.event_route_settings where event_id = registration.event_id;
  if _ordinary_stop_at is not null
     and (_ordinary_stop_at > settings.global_ordinary_stop_at
       or not (_ordinary_stop_at = any(settings.allowed_personal_stop_times))) then
    raise exception 'INVALID_STOP_PREFERENCE' using errcode = '22023';
  end if;
  update app_private.registrations
  set start_time_preference = _start_preference,
      requested_ordinary_stop_at = _ordinary_stop_at,
      version = version + 1
  where id = registration.id returning * into registration;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.preferences_updated', 'registration', registration.id,
    jsonb_build_object('startPreference', _start_preference, 'ordinaryStopAt', _ordinary_stop_at));
  return jsonb_build_object(
    'registrationId', registration.id, 'startPreference', registration.start_time_preference,
    'ordinaryStopAt', registration.requested_ordinary_stop_at, 'version', registration.version,
    'editable', true
  );
end;
$$;

create or replace function api.registration_preferences_request_change(
  _registration_id uuid,
  _start_preference app_private.start_time_preference,
  _ordinary_stop_at timestamptz,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if registration.id is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  update app_private.registrations set preference_change_status = 'change_requested', version = version + 1
  where id = registration.id returning * into registration;
  insert into app_private.support_cases(event_id, category, reporter, safe_description)
  values (
    registration.event_id, 'schedule_preference_change', actor,
    left('Nieuwe startvoorkeur: ' || _start_preference::text || '; nieuwe stop: ' || coalesce(_ordinary_stop_at::text, 'algemene grens') || '; ' || trim(_reason), 1000)
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.preference_change_requested', 'registration', registration.id,
    jsonb_build_object('startPreference', _start_preference, 'ordinaryStopAt', _ordinary_stop_at));
  return jsonb_build_object('requested', true, 'changeStatus', registration.preference_change_status, 'version', registration.version);
end;
$$;

create or replace function api.admin_route_configuration_snapshot(_event_slug text)
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
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', (
      select jsonb_build_object(
        'version', settings.version, 'plannerMode', settings.planner_mode,
        'firstStartAt', settings.first_start_at, 'globalOrdinaryStopAt', settings.global_ordinary_stop_at,
        'earlyPreferenceLatestAt', settings.early_preference_latest_at,
        'laterPreferenceEarliestAt', settings.later_preference_earliest_at,
        'allowedStopTimes', settings.allowed_personal_stop_times,
        'ordinaryVisitSeconds', settings.ordinary_visit_seconds, 'bufferSeconds', settings.route_buffer_seconds,
        'finalPortalId', settings.final_portal_id, 'finaleOpensAt', settings.finale_opens_at,
        'finaleLastArrivalAt', settings.finale_last_arrival_at, 'finaleClosesAt', settings.finale_closes_at,
        'finaleShowSeconds', settings.finale_show_seconds, 'finaleTurnoverSeconds', settings.finale_turnover_seconds,
        'finalePlanningTransferSeconds', settings.finale_planning_transfer_seconds,
        'finaleMaxGroups', settings.finale_max_concurrent_groups,
        'finaleMaxChildren', settings.finale_max_concurrent_children,
        'finaleSafeApproach', settings.finale_safe_approach,
        'finaleWaitingArea', settings.finale_waiting_area,
        'finaleExitRoute', settings.finale_exit_route,
        'finaleAccessibleEntrance', settings.finale_accessible_entrance,
        'finaleContact', settings.finale_contact,
        'finaleAvailable', settings.finale_available,
        'emergencyDestinationName', settings.emergency_destination_name,
        'emergencyInstructions', settings.emergency_instructions
      ) from app_private.event_route_settings settings where settings.event_id = v_event_id
    ),
    'startPoints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', point.id, 'name', point.name, 'privateAddress', point.private_address,
        'latitude', point.latitude, 'longitude', point.longitude,
        'walkingNodeId', point.walking_node_id, 'verified', point.verified_at is not null,
        'accessible', point.accessible, 'maxGroups', point.max_gathering_groups,
        'maxChildren', point.max_gathering_children, 'version', point.version,
        'slots', coalesce((select jsonb_agg(jsonb_build_object(
          'id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups,
          'maxChildren', slot.max_children, 'active', slot.active
        ) order by slot.starts_at) from app_private.start_slots slot where slot.start_point_id = point.id), '[]'::jsonb)
      ) order by point.name) from app_private.start_points point
      where point.event_id = v_event_id and point.active
    ), '[]'::jsonb),
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'name', portal.name, 'world', world.name,
        'operationStatus', portal.operation_status,
        'verified', location.verified_at is not null,
        'isFinal', portal.id = settings.final_portal_id
      ) order by portal.name)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = v_event_id and portal.approval_status = 'approved'
    ), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id, 'code', walking_group.code, 'status', walking_group.status,
        'version', walking_group.version, 'routeMode', walking_group.route_mode,
        'childCount', (select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
          where assignment.group_id = walking_group.id and assignment.superseded_at is null),
        'registrations', coalesce((select jsonb_agg(jsonb_build_object(
          'id', registration.id, 'reference', registration.reference,
          'startPreference', registration.start_time_preference,
          'ordinaryStopAt', registration.requested_ordinary_stop_at,
          'paymentEligible', payment.status in ('confirmed', 'waived')
        ) order by registration.reference)
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          left join app_private.payment_requests payment on payment.registration_id = registration.id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null), '[]'::jsonb),
        'schedule', case when schedule.id is null then null else jsonb_build_object(
          'id', schedule.id, 'revision', schedule.revision, 'state', schedule.state,
          'startSlotId', schedule.start_slot_id, 'effectiveStopAt', schedule.effective_ordinary_stop_at,
          'expectedFinaleArrivalAt', schedule.expected_finale_arrival_at,
          'preferenceMatch', schedule.preference_match, 'warnings', schedule.warnings
        ) end
      ) order by walking_group.code)
      from app_private.walking_groups walking_group
      left join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
      where walking_group.event_id = v_event_id
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', registration.id, 'reference', registration.reference,
        'childCount', (select count(*) from app_private.registration_children child where child.registration_id = registration.id and child.participation_status = 'active'),
        'startPreference', registration.start_time_preference,
        'ordinaryStopAt', registration.requested_ordinary_stop_at,
        'togetherKey', membership.party_id,
        'paymentStatus', payment.status,
        'paymentEligible', payment.status in ('confirmed', 'waived')
      ) order by registration.reference)
      from app_private.registrations registration
      left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where registration.event_id = v_event_id and registration.status = 'submitted'
        and not exists (select 1 from app_private.group_registrations assignment where assignment.registration_id = registration.id and assignment.superseded_at is null)
    ), '[]'::jsonb),
    'finaleFlow', coalesce((
      select jsonb_agg(jsonb_build_object(
        'window', flow.arrival_window,
        'groups', flow.group_count,
        'children', flow.child_count
      ) order by flow.arrival_window)
      from (
        select date_trunc('minute', schedule.expected_finale_arrival_at) as arrival_window,
          count(*) as group_count,
          sum((select count(*) from app_private.group_registrations assignment
            join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
            where assignment.group_id = schedule.group_id and assignment.superseded_at is null)) as child_count
        from app_private.group_schedule_revisions schedule
        join app_private.walking_groups walking_group on walking_group.id = schedule.group_id
        where walking_group.event_id = v_event_id and schedule.state in ('draft', 'published') and schedule.expected_finale_arrival_at is not null
        group by date_trunc('minute', schedule.expected_finale_arrival_at)
      ) flow
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app_private.walking_path_metrics(
  _event_id uuid,
  _from_node_id uuid,
  _to_node_id uuid,
  _requires_step_free boolean default false
)
returns table(distance_m bigint, duration_seconds bigint, edge_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  with recursive paths(node_id, distance_m, duration_seconds, edge_ids, visited) as (
    select _from_node_id, 0::bigint, 0::bigint, '{}'::uuid[], array[_from_node_id]::uuid[]
    where _from_node_id is not null and _to_node_id is not null
    union all
    select
      case when edge.from_node_id = paths.node_id then edge.to_node_id else edge.from_node_id end,
      paths.distance_m + edge.distance_m,
      paths.duration_seconds + edge.duration_seconds,
      paths.edge_ids || edge.id,
      paths.visited || case when edge.from_node_id = paths.node_id then edge.to_node_id else edge.from_node_id end
    from paths
    join app_private.walking_edges edge
      on edge.event_id = _event_id
      and edge.approved_at is not null
      and edge.closed_at is null
      and (not _requires_step_free or edge.wheelchair_accessible is true)
      and (edge.from_node_id = paths.node_id or edge.to_node_id = paths.node_id)
    where cardinality(paths.visited) < 100
      and not (case when edge.from_node_id = paths.node_id then edge.to_node_id else edge.from_node_id end = any(paths.visited))
  )
  select paths.distance_m, paths.duration_seconds, paths.edge_ids
  from paths where paths.node_id = _to_node_id
  order by paths.duration_seconds, paths.distance_m, paths.edge_ids
  limit 1
$$;

create or replace function api.admin_save_route_settings(
  _event_slug text,
  _settings jsonb,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  current_settings app_private.event_route_settings;
  next_mode text;
  next_final_portal uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_settings) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into current_settings from app_private.event_route_settings where event_id = v_event_id for update;
  if current_settings.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  next_mode := coalesce(_settings ->> 'plannerMode', current_settings.planner_mode);
  next_final_portal := coalesce(nullif(_settings ->> 'finalPortalId', '')::uuid, current_settings.final_portal_id);
  if next_mode not in ('disabled', 'shadow', 'dynamic') then raise exception 'INVALID_PLANNER_MODE' using errcode = '22023'; end if;
  if next_final_portal is not null and not exists (
    select 1 from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes node on node.portal_id = portal.id and node.verified_at is not null
    where portal.id = next_final_portal and portal.event_id = v_event_id and portal.approval_status = 'approved'
  ) then raise exception 'FINAL_PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  update app_private.event_route_settings set
    first_start_at = coalesce(nullif(_settings ->> 'firstStartAt', '')::timestamptz, first_start_at),
    early_preference_latest_at = coalesce(nullif(_settings ->> 'earlyPreferenceLatestAt', '')::timestamptz, early_preference_latest_at),
    later_preference_earliest_at = coalesce(nullif(_settings ->> 'laterPreferenceEarliestAt', '')::timestamptz, later_preference_earliest_at),
    global_ordinary_stop_at = coalesce(nullif(_settings ->> 'globalOrdinaryStopAt', '')::timestamptz, global_ordinary_stop_at),
    allowed_personal_stop_times = case when _settings ? 'allowedStopTimes'
      then array(select value::timestamptz from jsonb_array_elements_text(_settings -> 'allowedStopTimes') value order by value::timestamptz)
      else allowed_personal_stop_times end,
    ordinary_visit_seconds = coalesce((_settings ->> 'ordinaryVisitSeconds')::integer, ordinary_visit_seconds),
    route_buffer_seconds = coalesce((_settings ->> 'bufferSeconds')::integer, route_buffer_seconds),
    final_portal_id = next_final_portal,
    finale_opens_at = coalesce(nullif(_settings ->> 'finaleOpensAt', '')::timestamptz, finale_opens_at),
    finale_last_arrival_at = coalesce(nullif(_settings ->> 'finaleLastArrivalAt', '')::timestamptz, finale_last_arrival_at),
    finale_closes_at = coalesce(nullif(_settings ->> 'finaleClosesAt', '')::timestamptz, finale_closes_at),
    finale_show_seconds = coalesce((_settings ->> 'finaleShowSeconds')::integer, finale_show_seconds),
    finale_turnover_seconds = coalesce((_settings ->> 'finaleTurnoverSeconds')::integer, finale_turnover_seconds),
    finale_planning_transfer_seconds = coalesce((_settings ->> 'finalePlanningTransferSeconds')::integer, finale_planning_transfer_seconds),
    finale_max_concurrent_groups = coalesce((_settings ->> 'finaleMaxGroups')::integer, finale_max_concurrent_groups),
    finale_max_concurrent_children = coalesce((_settings ->> 'finaleMaxChildren')::integer, finale_max_concurrent_children),
    finale_safe_approach = case when _settings ? 'finaleSafeApproach' then nullif(trim(_settings ->> 'finaleSafeApproach'), '') else finale_safe_approach end,
    finale_waiting_area = case when _settings ? 'finaleWaitingArea' then nullif(trim(_settings ->> 'finaleWaitingArea'), '') else finale_waiting_area end,
    finale_exit_route = case when _settings ? 'finaleExitRoute' then nullif(trim(_settings ->> 'finaleExitRoute'), '') else finale_exit_route end,
    finale_accessible_entrance = case when _settings ? 'finaleAccessibleEntrance' then nullif(trim(_settings ->> 'finaleAccessibleEntrance'), '') else finale_accessible_entrance end,
    finale_contact = case when _settings ? 'finaleContact' then nullif(trim(_settings ->> 'finaleContact'), '') else finale_contact end,
    emergency_destination_name = case when _settings ? 'emergencyDestinationName' then nullif(trim(_settings ->> 'emergencyDestinationName'), '') else emergency_destination_name end,
    emergency_instructions = case when _settings ? 'emergencyInstructions' then nullif(trim(_settings ->> 'emergencyInstructions'), '') else emergency_instructions end,
    finale_available = coalesce((_settings ->> 'finaleAvailable')::boolean, finale_available),
    planner_mode = next_mode,
    updated_by = actor,
    version = version + 1
  where event_id = v_event_id returning * into current_settings;

  if current_settings.planner_mode in ('shadow', 'dynamic') and (
    current_settings.first_start_at is null or current_settings.global_ordinary_stop_at is null
    or current_settings.final_portal_id is null or current_settings.finale_opens_at is null
    or current_settings.finale_last_arrival_at is null or current_settings.finale_closes_at is null
  ) then raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514'; end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'route_settings.updated', 'event', v_event_id,
    jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('version', current_settings.version, 'plannerMode', current_settings.planner_mode);
end;
$$;

create or replace function api.admin_start_point_save(
  _event_slug text,
  _point_id uuid,
  _payload jsonb,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  node_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if jsonb_typeof(_payload) <> 'object' or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if nullif(_payload ->> 'walkingNodeId', '') is not null then
    select event_id into node_event_id from app_private.walking_nodes
    where id = (_payload ->> 'walkingNodeId')::uuid and kind in ('start', 'junction') and verified_at is not null;
    if node_event_id is distinct from v_event_id then raise exception 'START_NODE_NOT_VERIFIED' using errcode = '23514'; end if;
  end if;
  if coalesce((_payload ->> 'verified')::boolean, false) and (
    nullif(_payload ->> 'walkingNodeId', '') is null
    or nullif(_payload ->> 'latitude', '') is null
    or nullif(_payload ->> 'longitude', '') is null
  ) then raise exception 'START_POINT_NOT_ROUTE_READY' using errcode = '23514'; end if;
  if _point_id is null then
    insert into app_private.start_points(
      event_id, name, private_address, latitude, longitude, walking_node_id, accessible,
      accessibility_notes, max_gathering_groups, max_gathering_children, verified_at, verified_by
    ) values (
      v_event_id, trim(_payload ->> 'name'), trim(_payload ->> 'privateAddress'),
      nullif(_payload ->> 'latitude', '')::numeric, nullif(_payload ->> 'longitude', '')::numeric,
      nullif(_payload ->> 'walkingNodeId', '')::uuid, nullif(_payload ->> 'accessible', '')::boolean,
      nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      coalesce((_payload ->> 'maxGroups')::integer, 1), coalesce((_payload ->> 'maxChildren')::integer, 20),
      case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end
    ) returning * into point;
  else
    select * into point from app_private.start_points where id = _point_id and event_id = v_event_id for update;
    if point.id is null then raise exception 'START_POINT_NOT_FOUND' using errcode = 'P0002'; end if;
    if point.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.start_points set
      name = trim(_payload ->> 'name'), private_address = trim(_payload ->> 'privateAddress'),
      latitude = nullif(_payload ->> 'latitude', '')::numeric, longitude = nullif(_payload ->> 'longitude', '')::numeric,
      walking_node_id = nullif(_payload ->> 'walkingNodeId', '')::uuid,
      accessible = nullif(_payload ->> 'accessible', '')::boolean,
      accessibility_notes = nullif(trim(_payload ->> 'accessibilityNotes'), ''),
      max_gathering_groups = coalesce((_payload ->> 'maxGroups')::integer, max_gathering_groups),
      max_gathering_children = coalesce((_payload ->> 'maxChildren')::integer, max_gathering_children),
      verified_at = case when coalesce((_payload ->> 'verified')::boolean, false) then now() else null end,
      verified_by = case when coalesce((_payload ->> 'verified')::boolean, false) then actor else null end,
      version = version + 1
    where id = point.id returning * into point;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_point.saved', 'start_point', point.id,
    jsonb_build_object('version', point.version, 'verified', point.verified_at is not null, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', point.id, 'version', point.version, 'verified', point.verified_at is not null);
end;
$$;

create or replace function api.admin_start_slot_save(
  _event_slug text,
  _slot_id uuid,
  _start_point_id uuid,
  _starts_at timestamptz,
  _max_groups integer,
  _max_children integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  point app_private.start_points;
  slot app_private.start_slots;
  route_settings app_private.event_route_settings;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into point from app_private.start_points where id = _start_point_id and event_id = v_event_id and active;
  select * into route_settings from app_private.event_route_settings where event_id = v_event_id;
  if point.id is null or point.verified_at is null or point.walking_node_id is null
     or point.latitude is null or point.longitude is null or _max_groups < 1 or _max_children < 1
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
      point.name, point.private_address, point.latitude, point.longitude, point.verified_at,
      _starts_at, _max_groups, _max_children, point.id
    ) returning * into slot;
  else
    update app_private.start_slots set starts_at = _starts_at, max_groups = _max_groups,
      max_children = _max_children, start_point_id = point.id, location_name = point.name,
      private_address = point.private_address, latitude = point.latitude, longitude = point.longitude,
      location_verified_at = point.verified_at
    where id = _slot_id and event_id = v_event_id returning * into slot;
    if slot.id is null then raise exception 'START_SLOT_NOT_FOUND' using errcode = 'P0002'; end if;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'start_slot.saved', 'start_slot', slot.id, jsonb_build_object('startsAt', slot.starts_at, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at);
end;
$$;

create or replace function api.admin_apply_dynamic_plan(
  _event_slug text,
  _proposal jsonb,
  _input_hash text,
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
  v_event_id uuid;
  settings app_private.event_route_settings;
  group_item jsonb;
  registration_value jsonb;
  v_group_id uuid;
  v_schedule_id uuid;
  v_start_id uuid;
  v_effective_stop timestamptz;
  v_expected_finale timestamptz;
  v_group_number integer;
  receipt app_private.command_receipts;
  schedule_ids uuid[] := '{}'::uuid[];
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id;
  if settings.planner_mode not in ('shadow', 'dynamic') or settings.global_ordinary_stop_at is null or settings.final_portal_id is null then
    raise exception 'ROUTE_CONFIGURATION_INCOMPLETE' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':admin.applyDynamicPlan:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'admin.applyDynamicPlan' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
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
        and slot.location_verified_at is not null and point.verified_at is not null and point.walking_node_id is not null
    ) then raise exception 'INVALID_START' using errcode = '23514'; end if;
    if jsonb_typeof(group_item -> 'partyIds') <> 'array' or jsonb_array_length(group_item -> 'partyIds') = 0 then
      raise exception 'INVALID_GROUP' using errcode = '23514';
    end if;
    select least(
      settings.global_ordinary_stop_at,
      coalesce(min(registration.requested_ordinary_stop_at), settings.global_ordinary_stop_at)
    ) into v_effective_stop
    from app_private.registrations registration
    where registration.id in (select value::uuid from jsonb_array_elements_text(group_item -> 'partyIds'));
    v_expected_finale := coalesce(nullif(group_item ->> 'expectedFinaleArrivalAt', '')::timestamptz, v_effective_stop + interval '15 minutes');
    if v_effective_stop is null or v_expected_finale < settings.finale_opens_at or v_expected_finale > settings.finale_last_arrival_at then
      raise exception 'FINALE_WINDOW_CONFLICT' using errcode = '23514';
    end if;

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
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.proposal_saved', 'group_schedule_batch',
    jsonb_build_object('inputHash', _input_hash, 'groupCount', cardinality(schedule_ids)));
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'admin.applyDynamicPlan', _idempotency_key, _request_hash,
    jsonb_build_object('scheduleIds', schedule_ids, 'groupCount', cardinality(schedule_ids), 'published', false),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$$;

create or replace function api.admin_save_group_schedule(
  _group_id uuid,
  _start_slot_id uuid,
  _effective_stop_at timestamptz,
  _expected_finale_arrival_at timestamptz,
  _queue_number integer,
  _preference_match text,
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
  settings app_private.event_route_settings;
  current_schedule app_private.group_schedule_revisions;
  next_schedule app_private.group_schedule_revisions;
  next_revision integer;
begin
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or not app_private.has_capability(group_record.event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if group_record.route_mode <> 'dynamic' or _preference_match not in ('good', 'small_deviation', 'large_deviation', 'neutral')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if not exists (
    select 1 from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
    where slot.id = _start_slot_id and slot.event_id = group_record.event_id and slot.active
      and slot.location_verified_at is not null and point.verified_at is not null
  ) or _effective_stop_at > settings.global_ordinary_stop_at
     or _expected_finale_arrival_at < settings.finale_opens_at
     or _expected_finale_arrival_at > settings.finale_last_arrival_at then
    raise exception 'SCHEDULE_CONFLICT' using errcode = '23514';
  end if;
  select * into current_schedule from app_private.group_schedule_revisions where id = group_record.current_schedule_revision_id;
  select coalesce(max(revision), 0) + 1 into next_revision from app_private.group_schedule_revisions where group_id = group_record.id;
  insert into app_private.group_schedule_revisions(
    group_id, revision, start_slot_id, effective_ordinary_stop_at, expected_finale_arrival_at,
    queue_number, preference_match, input_snapshot, created_by, supersedes_id
  ) values (
    group_record.id, next_revision, _start_slot_id, _effective_stop_at, _expected_finale_arrival_at,
    _queue_number, _preference_match,
    jsonb_build_object('reason', left(trim(_reason), 500), 'previousRevision', current_schedule.revision),
    actor, current_schedule.id
  ) returning * into next_schedule;
  -- Keep the last published start active until this correction is explicitly
  -- confirmed. The draft pointer is for the admin board only.
  update app_private.walking_groups
  set current_schedule_revision_id = next_schedule.id, version = version + 1
  where id = group_record.id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group_schedule.revision_created', 'group_schedule', next_schedule.id,
    jsonb_build_object('groupId', group_record.id, 'revision', next_revision, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', next_schedule.id, 'revision', next_schedule.revision, 'state', next_schedule.state);
end;
$$;

create or replace function app_private.schedule_counts_for_publication(
  _schedule_id uuid,
  _group_id uuid,
  _state app_private.schedule_state,
  _batch_ids uuid[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _schedule_id = any(_batch_ids)
    or (
      _state = 'published'
      and not exists (
        select 1 from app_private.group_schedule_revisions replacement
        where replacement.id = any(_batch_ids)
          and replacement.group_id = _group_id
          and replacement.id <> _schedule_id
      )
    )
$$;

create or replace function api.admin_publish_group_schedules(
  _event_slug text,
  _schedule_ids uuid[],
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  settings app_private.event_route_settings;
  schedule app_private.group_schedule_revisions;
  recipient record;
  child_count integer;
  published_count integer := 0;
  service_interval interval;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_schedule_ids), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id for update;
  if settings.planner_mode <> 'dynamic' or not settings.finale_available or settings.final_portal_id is null then
    raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514';
  end if;
  service_interval := make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds);

  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.walking_groups walking_group on walking_group.id = candidate.group_id
    where candidate.id = any(_schedule_ids)
      and (walking_group.event_id <> v_event_id or candidate.state <> 'draft'
        or walking_group.current_schedule_revision_id <> candidate.id)
  ) or (select count(*) from app_private.group_schedule_revisions where id = any(_schedule_ids)) <> cardinality(_schedule_ids) then
    raise exception 'INVALID_SCHEDULE' using errcode = '23514';
  end if;

  -- Payment is a hard publication and start condition.
  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.group_registrations assignment on assignment.group_id = candidate.group_id and assignment.superseded_at is null
    join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
    left join app_private.payment_requests payment on payment.registration_id = registration.id
    where candidate.id = any(_schedule_ids) and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
  ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;

  -- Validate exact slot and physical gathering-place load across the complete batch.
  if exists (
    select 1
    from app_private.group_schedule_revisions candidate
    join app_private.start_slots slot on slot.id = candidate.start_slot_id
    join app_private.start_points point on point.id = slot.start_point_id
    where candidate.id = any(_schedule_ids) and (
      (select count(*) from app_private.group_schedule_revisions other
       where other.start_slot_id = slot.id
         and app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)) > slot.max_groups
      or
      (select coalesce(sum((select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
          where assignment.group_id = other.group_id and assignment.superseded_at is null)), 0)
       from app_private.group_schedule_revisions other
       where other.start_slot_id = slot.id
         and app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)) > slot.max_children
      or
      (select count(*) from app_private.group_schedule_revisions other
       join app_private.start_slots other_slot on other_slot.id = other.start_slot_id
       where other_slot.start_point_id = point.id and other_slot.starts_at = slot.starts_at
         and app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)) > point.max_gathering_groups
      or
      (select coalesce(sum((select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
          where assignment.group_id = other.group_id and assignment.superseded_at is null)), 0)
       from app_private.group_schedule_revisions other
       join app_private.start_slots other_slot on other_slot.id = other.start_slot_id
       where other_slot.start_point_id = point.id and other_slot.starts_at = slot.starts_at
         and app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)) > point.max_gathering_children
    )
  ) then raise exception 'START_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  -- Each projected finale arrival occupies the configured show/turnover period.
  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    where candidate.id = any(_schedule_ids) and (
      candidate.expected_finale_arrival_at is null
      or candidate.expected_finale_arrival_at < settings.finale_opens_at
      or candidate.expected_finale_arrival_at > settings.finale_last_arrival_at
      or (select count(*) from app_private.group_schedule_revisions other
          join app_private.walking_groups other_group on other_group.id = other.group_id and other_group.event_id = v_event_id
          where app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)
            and other.expected_finale_arrival_at < candidate.expected_finale_arrival_at + service_interval
            and other.expected_finale_arrival_at + service_interval > candidate.expected_finale_arrival_at
         ) > settings.finale_max_concurrent_groups
      or (select coalesce(sum((select count(*) from app_private.group_registrations assignment
            join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
            where assignment.group_id = other.group_id and assignment.superseded_at is null)), 0)
          from app_private.group_schedule_revisions other
          join app_private.walking_groups other_group on other_group.id = other.group_id and other_group.event_id = v_event_id
          where app_private.schedule_counts_for_publication(other.id, other.group_id, other.state, _schedule_ids)
            and other.expected_finale_arrival_at < candidate.expected_finale_arrival_at + service_interval
            and other.expected_finale_arrival_at + service_interval > candidate.expected_finale_arrival_at
         ) > settings.finale_max_concurrent_children
    )
  ) then raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  for schedule in
    select candidate.* from app_private.group_schedule_revisions candidate
    where candidate.id = any(_schedule_ids) order by candidate.group_id, candidate.revision
    for update
  loop
    update app_private.group_schedule_revisions
    set state = 'superseded'
    where group_id = schedule.group_id and state = 'published' and id <> schedule.id;
    update app_private.group_schedule_revisions
    set state = 'published', published_at = now()
    where id = schedule.id;
    update app_private.walking_groups
    set status = 'ready', start_slot_id = schedule.start_slot_id,
        current_schedule_revision_id = schedule.id, route_mode = 'dynamic', version = version + 1
    where id = schedule.group_id;
    update app_private.group_registrations set published_at = now()
    where group_id = schedule.group_id and superseded_at is null;
    update app_private.registrations set preference_change_status = 'locked', version = version + 1
    where id in (select registration_id from app_private.group_registrations where group_id = schedule.group_id and superseded_at is null);
    select count(*) into child_count from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
    where assignment.group_id = schedule.group_id and assignment.superseded_at is null;
    for recipient in
      select distinct users.id as user_id, lower(users.email) as email
      from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id
      join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
      join auth.users users on users.id = member.user_id and users.email_confirmed_at is not null
      where assignment.group_id = schedule.group_id and assignment.superseded_at is null
    loop
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      select
        'group-schedule:' || schedule.group_id::text || ':' || schedule.revision::text || ':' || recipient.user_id::text,
        case when schedule.revision = 1 then 'group_schedule_published' else 'group_schedule_corrected' end,
        recipient.user_id::text,
        recipient.email,
        jsonb_build_object(
          'groupId', schedule.group_id, 'revision', schedule.revision, 'childCount', child_count,
          'startsAt', slot.starts_at, 'startPoint', point.name,
          'startAddress', point.private_address, 'ordinaryStopAt', schedule.effective_ordinary_stop_at,
          'actionPath', '/omgeving/meeloper/groep'
        )
      from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
      where slot.id = schedule.start_slot_id
      on conflict (dedupe_key) do nothing;
    end loop;
    published_count := published_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.published', 'group_schedule_batch',
    jsonb_build_object('count', published_count, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', published_count);
end;
$$;

create or replace function app_private.try_reserve_finale(
  _run_id uuid,
  _earliest_arrival timestamptz,
  _decision_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  settings app_private.event_route_settings;
  v_child_count integer;
  candidate_time timestamptz;
  candidate_end timestamptz;
  active_groups integer;
  active_children integer;
  reservation_id uuid;
begin
  select * into run_record from app_private.group_runs where id = _run_id;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  if settings.final_portal_id is null or not settings.finale_available then return null; end if;
  select count(*) into v_child_count from app_private.run_participants
  where run_id = _run_id and attendance = 'present';
  if v_child_count = 0 or v_child_count > settings.finale_max_concurrent_children then return null; end if;

  update app_private.portal_reservations
  set status = 'cancelled', cancelled_reason = 'Vervangen door actuele finaleprognose', version = version + 1
  where run_id = _run_id and kind = 'finale' and status in ('held', 'active');
  candidate_time := greatest(
    settings.finale_opens_at,
    date_trunc('minute', _earliest_arrival) + case when date_trunc('minute', _earliest_arrival) < _earliest_arrival then interval '1 minute' else interval '0' end
  );
  while candidate_time <= settings.finale_last_arrival_at loop
    candidate_end := candidate_time + make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds);
    exit when candidate_end > settings.finale_closes_at;
    select count(*), coalesce(sum(reservation.child_count), 0)::integer
      into active_groups, active_children
    from app_private.portal_reservations reservation
    where reservation.portal_id = settings.final_portal_id
      and reservation.kind = 'finale' and reservation.status in ('held', 'active')
      and (reservation.expires_at is null or reservation.expires_at > _decision_at)
      and reservation.reserved_from < candidate_end and reservation.reserved_until > candidate_time;
    if active_groups < settings.finale_max_concurrent_groups
       and active_children + v_child_count <= settings.finale_max_concurrent_children then
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at
      ) values (
        group_record.event_id, settings.final_portal_id, group_record.id, _run_id, 'finale', 'held',
        candidate_time, candidate_end, v_child_count, settings.finale_closes_at
      ) returning id into reservation_id;
      return reservation_id;
    end if;
    candidate_time := candidate_time + interval '1 minute';
  end loop;
  return null;
end;
$$;

create or replace function app_private.dispatch_next_stop(
  _run_id uuid,
  _decision_at timestamptz default clock_timestamp(),
  _force_finale boolean default false,
  _preferred_portal_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  settings app_private.event_route_settings;
  source_node_id uuid;
  final_node_id uuid;
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

  select node.id into source_node_id
  from app_private.run_stops stop
  join app_private.walking_nodes node on node.portal_id = stop.portal_id and node.event_id = group_record.event_id and node.verified_at is not null
  where stop.run_id = _run_id and stop.plan_stop_id is null and stop.state = 'completed'
  order by stop.sequence desc limit 1;
  if source_node_id is null then
    select point.walking_node_id into source_node_id
    from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
    where slot.id = schedule.start_slot_id and point.verified_at is not null;
  end if;
  select node.id into final_node_id from app_private.walking_nodes node
  where node.event_id = group_record.event_id and node.kind = 'portal'
    and node.portal_id = settings.final_portal_id and node.verified_at is not null
  order by node.id limit 1;
  if source_node_id is null or final_node_id is null then raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514'; end if;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.operation_status in ('open', 'scheduled')
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

  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      select portal.id as portal_id, portal.world_id, portal.name,
        source_path.distance_m as incoming_distance_m, source_path.duration_seconds as incoming_seconds,
        source_path.edge_ids as incoming_edge_ids,
        final_path.duration_seconds as finale_seconds,
        _decision_at + make_interval(secs => source_path.duration_seconds::integer) as arrival_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) as departure_at,
        _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) as earliest_finale_at,
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
      join app_private.portal_applications application on application.id = portal.application_id
      join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
      join app_private.walking_nodes portal_node on portal_node.event_id = portal.event_id and portal_node.kind = 'portal'
        and portal_node.portal_id = portal.id and portal_node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
      cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and portal.operation_status = 'open'
        and (not needs_step_free or coalesce(application.private_draft_data ->> 'accessibility', '') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
        and exists (
          select 1 from app_private.portal_windows portal_window
          where portal_window.portal_id = portal.id
            and _decision_at + make_interval(secs => source_path.duration_seconds::integer) >= portal_window.opens_at
            and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer) <= portal_window.closes_at
        )
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
        and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at
        and not exists (
          select 1 from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')
            and (reservation.expires_at is null or reservation.expires_at > _decision_at)
            and reservation.reserved_from < _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds)::integer)
            and reservation.reserved_until > _decision_at + make_interval(secs => source_path.duration_seconds::integer)
        )
      order by score, portal.id
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
          'decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op veilige looptijd, beschikbaarheid en finalehaalbaarheid'
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
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes portal_node on portal_node.portal_id = portal.id and portal_node.event_id = group_record.event_id and portal_node.verified_at is not null
    cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
    cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and portal.operation_status = 'open'
      and not exists (select 1 from app_private.run_stops seen where seen.run_id = _run_id and seen.portal_id = portal.id)
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= settings.finale_last_arrival_at;
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

  select * into finale_path from app_private.walking_path_metrics(group_record.event_id, source_node_id, final_node_id, needs_step_free);
  if finale_path.duration_seconds is null then raise exception 'NO_SAFE_FINALE_PATH' using errcode = '23514'; end if;
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
    jsonb_build_object('decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$$;

create or replace function api.run_start(
  _group_id uuid,
  _present_registration_child_ids uuid[],
  _expected_group_version integer,
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
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
  dispatch_result jsonb;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_present_registration_child_ids), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id
        and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  if group_record.route_mode = 'dynamic' then
    select * into schedule from app_private.group_schedule_revisions
    where group_id = group_record.id and state = 'published'
    order by revision desc limit 1;
    if schedule.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode = '23514'; end if;
    if clock_timestamp() < (select starts_at from app_private.start_slots where id = schedule.start_slot_id) then
      raise exception 'START_TIME_NOT_REACHED' using errcode = '23514';
    end if;
    if exists (
      select 1 from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where assignment.group_id = _group_id and assignment.superseded_at is null
        and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
    ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at)
    values (_group_id, null, schedule.id, 'live', clock_timestamp()) returning id into v_run_id;
  else
    select id into plan_id from app_private.route_plan_versions
    where group_id = _group_id and state = 'published' order by revision desc limit 1;
    if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, status, started_at)
    values (_group_id, plan_id, 'live', clock_timestamp()) returning id into v_run_id;
  end if;

  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids)
      then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null
    and registration_child.participation_status = 'active';

  if group_record.route_mode = 'dynamic' then
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := app_private.dispatch_next_stop(v_run_id, clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id = v_run_id;
  else
    insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
    select v_run_id, stop.id, stop.position,
      case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when stop.position = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
    select id into first_stop_id from app_private.run_stops where run_id = v_run_id and sequence = 1;
    if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
    update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select first_stop_id, participant.id from app_private.run_participants participant
    where participant.run_id = v_run_id and participant.attendance = 'present';
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := jsonb_build_object('decision', 'legacy', 'stopId', first_stop_id);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (v_run_id, first_stop_id, 'run.started', actor, jsonb_build_object('routeMode', group_record.route_mode));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id, jsonb_build_object('routeMode', group_record.route_mode));
  result := jsonb_build_object('runId', v_run_id, 'dispatch', dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, result, now() + interval '2 days') returning * into receipt;
  return receipt.safe_result;
end;
$$;

create or replace function api.run_scan(
  _run_id uuid,
  _expected_stop_id uuid,
  _expected_run_version integer,
  _credential text,
  _method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select credential.* into credential_record
  from app_private.run_stops run_stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    -- A pause means "no new groups". A group already inside may still scan and
    -- finish safely; a direct close remains blocked.
    and portal.operation_status in ('open', 'paused')
    and credential.revoked_at is null and credential.valid_from <= now()
    and (credential.valid_until is null or credential.valid_until > now())
    and (
      (_method = 'qr' and credential.token_hash = extensions.digest(convert_to(_credential, 'utf8'), 'sha256'))
      or (_method = 'short_code' and credential.short_code_hash = extensions.digest(convert_to(upper(trim(_credential)), 'utf8'), 'sha256'))
    )
  order by credential.version desc limit 1;
  if credential_record.id is null then raise exception 'WRONG_PORTAL' using errcode = '22023'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
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
  v_world_id uuid;
  receipt app_private.command_receipts;
  result jsonb;
  dispatch_result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.completeStop:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.completeStop' and idempotency_key = _idempotency_key;
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
  if stop_record.stop_kind = 'finale' and visited_count = 0 then raise exception 'FINAL_PORTAL_REQUIRED' using errcode = '23514'; end if;
  if visited_count = 0 and not _all_skip_confirmed then raise exception 'ALL_SKIP_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  v_outcome := case
    when visited_count > 0 and skipped_count > 0 then 'mixed'::app_private.stop_outcome
    when visited_count > 0 then 'visited'::app_private.stop_outcome
    else 'all_skipped'::app_private.stop_outcome end;
  update app_private.run_stops set state = 'completed', outcome = v_outcome,
    completed_at = clock_timestamp(), completion_actor = actor, version = version + 1 where id = _stop_id;
  update app_private.portal_reservations set status = 'completed', version = version + 1
  where id = stop_record.reservation_id;
  select portal.world_id into v_world_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
  where stop.id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, v_world_id, v_outcome);

  if stop_record.stop_kind = 'finale' then
    update app_private.group_runs set status = 'completed', current_stop_id = null,
      finished_at = clock_timestamp(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    dispatch_result := jsonb_build_object('decision', 'completed');
  elsif stop_record.stop_kind = 'ordinary' then
    update app_private.group_runs set current_stop_id = null, version = version + 1
    where id = _run_id returning * into run_record;
    dispatch_result := app_private.dispatch_next_stop(_run_id, clock_timestamp());
    select * into run_record from app_private.group_runs where id = _run_id;
  else
    select * into next_stop from app_private.run_stops
    where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
    if next_stop.id is null then
      update app_private.group_runs set status = 'completed', current_stop_id = null,
        finished_at = clock_timestamp(), version = version + 1
      where id = _run_id returning * into run_record;
      update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    else
      update app_private.run_stops set state = 'active', opened_at = clock_timestamp(), version = version + 1 where id = next_stop.id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop.id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
      where id = _run_id returning * into run_record;
    end if;
    dispatch_result := jsonb_build_object('decision', case when next_stop.id is null then 'completed' else 'legacy' end);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.completed', actor, jsonb_build_object('outcome', v_outcome));
  result := jsonb_build_object(
    'runId', _run_id, 'status', run_record.status, 'version', run_record.version,
    'completedStopId', _stop_id, 'outcome', v_outcome,
    'hasNextStop', run_record.current_stop_id is not null, 'dispatch', dispatch_result
  );
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.completeStop', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$$;

create or replace function api.group_snapshot(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  run_record app_private.group_runs;
  leader boolean;
  support boolean;
  household_access boolean;
  schedule app_private.group_schedule_revisions;
  published_start boolean := false;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  leader := app_private.is_current_leader(_group_id, actor);
  support := app_private.has_capability(group_record.event_id, 'live_support', actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor);
  select exists (
    select 1 from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
    join app_private.group_registrations assignment on assignment.registration_id = registration.id
    where member.user_id = actor and member.revoked_at is null and assignment.group_id = _group_id and assignment.superseded_at is null
  ) into household_access;
  if not (leader or support or household_access) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into schedule from app_private.group_schedule_revisions
  where group_id = group_record.id and state = 'published'
  order by revision desc limit 1;
  if group_record.route_mode = 'dynamic' then
    published_start := coalesce(schedule.state = 'published', false);
  else
    published_start := exists (
      select 1 from app_private.route_plan_versions plan
      where plan.id = group_record.current_plan_version_id and plan.state = 'published'
    ) and exists (
      select 1 from app_private.group_registrations assignment
      where assignment.group_id = _group_id and assignment.superseded_at is null and assignment.published_at is not null
    );
  end if;
  select * into run_record from app_private.group_runs where group_id = _group_id order by created_at desc limit 1;

  return jsonb_build_object(
    'group', jsonb_build_object(
      'id', group_record.id, 'code', group_record.code, 'status', group_record.status,
      'version', group_record.version, 'routeMode', group_record.route_mode,
      'start', case when not published_start then null else (
        select jsonb_build_object(
          'name', point.name, 'locationName', point.name, 'address', point.private_address,
          'startsAt', slot.starts_at, 'queueNumber', schedule.queue_number
        ) from app_private.start_slots slot
        join app_private.start_points point on point.id = slot.start_point_id
        where slot.id = schedule.start_slot_id
      ) end,
      'effectiveOrdinaryStopAt', case when schedule.state = 'published' then schedule.effective_ordinary_stop_at else null end,
      'expectedFinaleArrivalAt', case when schedule.state = 'published' then schedule.expected_finale_arrival_at else null end
    ),
    'access', jsonb_build_object('leader', leader, 'support', support),
    'run', case when run_record.id is null then null else jsonb_build_object(
      'id', run_record.id, 'status', run_record.status, 'version', run_record.version,
      'lastServerConfirmation', run_record.updated_at,
      'emergencyInstruction', case when run_record.status = 'stopped' then run_record.stopped_reason else null end,
      'elapsedSeconds', greatest(0, extract(epoch from (now() - run_record.started_at))::integer),
      'remainingStopCount', case when group_record.route_mode = 'legacy' then (
        select count(*) from app_private.run_stops stop where stop.run_id = run_record.id and stop.state = 'locked'
      ) else null end,
      'waitingInstruction', run_record.status = 'live' and run_record.current_stop_id is null,
      'currentStop', (
        select jsonb_build_object(
          'id', stop.id, 'version', stop.version, 'sequence', stop.sequence,
          'kind', coalesce(stop.stop_kind::text, 'ordinary'), 'openedAt', stop.opened_at,
          'reservedArrivalAt', reservation.reserved_from,
          'portal', jsonb_build_object(
            'name', portal.name, 'description', portal.description, 'intensity', portal.intensity,
            'operationStatus', portal.operation_status, 'world', world.name,
            'address', concat_ws(' ', location.street, location.house_number, location.addition),
            'postalCode', location.postal_code,
            'coordinate', case when location.latitude is null then null else jsonb_build_array(location.longitude, location.latitude) end
          ),
          'scanAccepted', exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
        )
        from app_private.run_stops stop
        left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
        join app_private.worlds world on world.id = portal.world_id
        join app_private.portal_private_locations location on location.portal_id = portal.id
        left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
        where stop.id = run_record.current_stop_id and stop.state = 'active'
      ),
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', participant.id, 'firstName', child.first_name, 'attendance', participant.attendance,
          'rosterVersion', participant.roster_version,
          'isOwnChild', app_private.is_household_member(child.household_id, actor),
          'status', status.status, 'statusVersion', status.version, 'required', status.required_for_completion
        ) order by child.first_name)
        from app_private.run_participants participant
        join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
        join app_private.children child on child.id = registration_child.child_id
        left join app_private.stop_participant_statuses status
          on status.run_participant_id = participant.id and status.run_stop_id = run_record.current_stop_id
        where participant.run_id = run_record.id
          and (leader or support or app_private.is_household_member(child.household_id, actor))
      ), '[]'::jsonb),
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'sequence', stop.sequence, 'kind', coalesce(stop.stop_kind::text, 'ordinary'),
          'outcome', stop.outcome, 'completedAt', stop.completed_at,
          'portalName', portal.name, 'world', world.name
        ) order by stop.sequence)
        from app_private.run_stops stop
        left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
        join app_private.worlds world on world.id = portal.world_id
        where stop.run_id = run_record.id and stop.state = 'completed'
      ), '[]'::jsonb)
    ) end
  );
end;
$$;

create or replace function api.group_viewer_snapshot(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  run_record app_private.group_runs;
  schedule app_private.group_schedule_revisions;
  v_completed integer := 0;
  published_start boolean := false;
begin
  if actor is null or not app_private.has_active_viewer_access(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into schedule from app_private.group_schedule_revisions
  where group_id = group_record.id and state = 'published'
  order by revision desc limit 1;
  published_start := case when group_record.route_mode = 'dynamic' then coalesce(schedule.state = 'published', false) else exists (
    select 1 from app_private.route_plan_versions plan where plan.id = group_record.current_plan_version_id and plan.state = 'published'
  ) end;
  select * into run_record from app_private.group_runs where group_id = _group_id order by created_at desc limit 1;
  if run_record.id is not null then
    select count(*) filter (where state = 'completed') into v_completed from app_private.run_stops where run_id = run_record.id;
  end if;
  return jsonb_build_object(
    'group', jsonb_build_object(
      'code', group_record.code, 'status', group_record.status,
      'start', case when not published_start then null else (
        select jsonb_build_object('name', point.name, 'startsAt', slot.starts_at)
        from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
        where slot.id = schedule.start_slot_id
      ) end
    ),
    'progress', jsonb_build_object(
      'status', coalesce(run_record.status::text, 'waiting'),
      'completed', v_completed,
      'lastUpdatedAt', coalesce(run_record.updated_at, group_record.updated_at)
    ),
    'history', case when run_record.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'sequence', stop.sequence, 'world', world.name,
        'outcome', stop.outcome, 'completedAt', stop.completed_at,
        'kind', coalesce(stop.stop_kind::text, 'ordinary')
      ) order by stop.sequence)
      from app_private.run_stops stop
      left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
      join app_private.worlds world on world.id = portal.world_id
      where stop.run_id = run_record.id and stop.state = 'completed'
    ), '[]'::jsonb) end
  );
end;
$$;

create or replace function api.participant_context(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  assigned_start timestamptz;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then return null; end if;
  select slot.starts_at into assigned_start
  from (
    select leader.group_id, 0 as priority
    from app_private.group_leaders leader
    join app_private.walking_groups walking_group on walking_group.id = leader.group_id
    where walking_group.event_id = event_record.id and leader.user_id = actor
      and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
    union all
    select assignment.group_id, 1
    from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
      and registration.event_id = event_record.id and registration.status <> 'cancelled'
    join app_private.group_registrations assignment on assignment.registration_id = registration.id and assignment.superseded_at is null
    where member.user_id = actor and member.revoked_at is null
  ) membership
  join app_private.walking_groups walking_group on walking_group.id = membership.group_id
  left join app_private.group_schedule_revisions schedule
    on schedule.group_id = walking_group.id and schedule.state = 'published'
  join app_private.start_slots slot
    on slot.id = case when walking_group.route_mode = 'dynamic' then schedule.start_slot_id else walking_group.start_slot_id end
  left join app_private.route_plan_versions plan on plan.id = walking_group.current_plan_version_id
  where (walking_group.route_mode = 'dynamic' and schedule.id is not null)
     or (walking_group.route_mode = 'legacy' and plan.state = 'published')
  order by membership.priority limit 1;

  return jsonb_build_object(
    'event', jsonb_build_object(
      'id', event_record.id, 'title', event_record.title, 'localDate', event_record.local_date,
      'phase', event_record.phase,
      'startsAt', coalesce(assigned_start, (select first_start_at from app_private.event_route_settings where event_id = event_record.id)),
      'paymentDeadline', (event_record.local_date - 1),
      'supportEmail', coalesce(nullif(event_record.settings ->> 'supportEmail', ''), 'organisatie@duindorpdoet.nl'),
      'supportPhone', nullif(event_record.settings ->> 'supportPhone', '')
    ),
    'roles', coalesce((
      select jsonb_agg(role_record.payload order by role_record.sort_order)
      from (
        select 1 as sort_order, jsonb_build_object(
          'key', 'walker', 'label', 'Meeloper',
          'groupId', (
            select membership.group_id from (
              select leader.group_id, 0 as priority
              from app_private.group_leaders leader
              join app_private.walking_groups walking_group on walking_group.id = leader.group_id
              where walking_group.event_id = event_record.id and leader.user_id = actor
                and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
              union all
              select assignment.group_id, 1
              from app_private.household_members member
              join app_private.registrations registration on registration.household_id = member.household_id
                and registration.event_id = event_record.id and registration.status <> 'cancelled'
              join app_private.group_registrations assignment on assignment.registration_id = registration.id and assignment.superseded_at is null
              where member.user_id = actor and member.revoked_at is null
            ) membership order by membership.priority limit 1
          )
        ) as payload
        where exists (
          select 1 from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          where member.user_id = actor and member.revoked_at is null
            and registration.event_id = event_record.id and registration.status <> 'cancelled'
        ) or exists (
          select 1 from app_private.group_leaders leader
          join app_private.walking_groups walking_group on walking_group.id = leader.group_id
          where walking_group.event_id = event_record.id and leader.user_id = actor
            and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
        )
        union all
        select 2, jsonb_build_object(
          'key', 'viewer', 'label', 'Meekijker', 'accessId', access.id,
          'groupId', access.group_id, 'expiresAt', access.expires_at
        ) from (
          select candidate.* from app_private.group_viewer_access candidate
          where candidate.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
            and (candidate.expires_at is null or candidate.expires_at > now())
          order by candidate.created_at limit 1
        ) access
        union all
        select 3, jsonb_build_object('key', 'homeowner', 'label', 'Huiseigenaar', 'portalId', portal.id)
        from (
          select candidate.* from app_private.portal_owners candidate
          join app_private.portals owned_portal on owned_portal.id = candidate.portal_id
          where owned_portal.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
          order by candidate.accepted_at limit 1
        ) owner join app_private.portals portal on portal.id = owner.portal_id
      ) role_record
    ), '[]'::jsonb),
    'preferences', coalesce((
      select jsonb_build_object('reducedMotion', preference.reduced_motion, 'readableMode', preference.readable_mode)
      from app_private.participant_preferences preference
      where preference.event_id = event_record.id and preference.user_id = actor
    ), jsonb_build_object('reducedMotion', false, 'readableMode', false))
  );
end;
$$;

alter table app_private.portals add column pause_after_current boolean not null default false;

-- The legacy trigger only followed precomputed plan stops. Dynamic stops carry
-- their portal directly, so availability must resolve either source. A paused
-- portal accepts the group already inside while remaining unavailable to the
-- dispatcher for every new assignment.
create or replace function app_private.block_unavailable_portal_visit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  portal_state app_private.portal_operation_status;
begin
  if new.status = 'visited' and old.status is distinct from 'visited' then
    select portal.operation_status into portal_state
    from app_private.run_stops run_stop
    left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
    join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
    where run_stop.id = new.run_stop_id;
    if portal_state is null or portal_state not in ('open', 'paused') then
      raise exception 'PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create or replace function api.portal_set_operational_state(
  _portal_id uuid,
  _state app_private.portal_operation_status,
  _expected_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  affected record;
begin
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null or portal.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (
    select 1 from app_private.portal_owners owner
    where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null
  ) and not app_private.has_capability(portal.event_id, 'portals_manage', actor)
    and not app_private.has_capability(portal.event_id, 'live_support', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _state in ('paused', 'closed') and char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  update app_private.portals
  set operation_status = _state, pause_after_current = _state = 'paused', version = version + 1
  where id = _portal_id returning * into portal;

  if exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    if _state = 'open' then
      update app_private.event_route_settings set finale_available = true, version = version + 1
      where event_id = portal.event_id;
    elsif _state = 'paused' then
      update app_private.event_route_settings set finale_available = false, version = version + 1
      where event_id = portal.event_id;
      update app_private.portal_reservations set status = 'cancelled',
        cancelled_reason = 'Laatste poort pauzeert', version = version + 1
      where portal_id = portal.id and kind = 'finale' and status = 'held';
    end if;
  end if;

  if _state in ('paused', 'closed') then
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = case when _state = 'closed' then 'Poort direct gesloten' else 'Poort pauzeert na huidige groep' end,
      version = version + 1
    where portal_id = _portal_id and status = 'held' and kind = 'ordinary';
  end if;
  if _state = 'closed' and exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    update app_private.event_route_settings set finale_available = false, version = version + 1 where event_id = portal.event_id;
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = 'Laatste poort direct gesloten', version = version + 1
    where portal_id = portal.id and kind = 'finale' and status in ('held', 'active');
    for affected in
      select run.id as run_id, run.group_id
      from app_private.group_runs run
      join app_private.walking_groups walking_group on walking_group.id = run.group_id
      where walking_group.event_id = portal.event_id and walking_group.route_mode = 'dynamic'
        and run.status in ('live', 'paused')
    loop
      update app_private.group_runs set status = 'paused', version = version + 1 where id = affected.run_id;
      insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
      select portal.event_id, affected.group_id, affected.run_id, portal.id, 'urgent', 'FINALE_UNAVAILABLE',
        'De eindpoort is gesloten. Gebruik uitsluitend de goedgekeurde noodafsluiting.'
      where not exists (select 1 from app_private.route_alerts where run_id = affected.run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    end loop;
  elsif _state = 'closed' then
    for affected in
      select stop.id as stop_id, stop.run_id, reservation.id as reservation_id
      from app_private.run_stops stop
      join app_private.group_runs run on run.id = stop.run_id and run.current_stop_id = stop.id and run.status = 'live'
      join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
      left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
      where stop.portal_id = portal.id and stop.state = 'active'
        and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
      for update of stop, run
    loop
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
      where id = affected.stop_id;
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Poort direct gesloten',
        reason = left(trim(_reason), 500), changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.stop_id and required_for_completion;
      update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Poort direct gesloten', version = version + 1
      where id = affected.reservation_id;
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      values (affected.run_id, affected.stop_id, portal.world_id, 'system_skipped')
      on conflict (run_stop_id) do nothing;
      update app_private.group_runs set current_stop_id = null, version = version + 1
      where id = affected.run_id;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.stop_id, 'stop.system_skipped', actor,
        jsonb_build_object('portalId', portal.id, 'reason', left(trim(_reason), 500)));
      perform app_private.dispatch_next_stop(affected.run_id, clock_timestamp());
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.operation_state_changed', 'portal', portal.id,
    jsonb_build_object('state', _state, 'reason', left(coalesce(trim(_reason), ''), 500)));
  return jsonb_build_object('id', portal.id, 'state', portal.operation_status, 'version', portal.version, 'pauseAfterCurrent', portal.pause_after_current);
end;
$$;

create or replace function api.run_support_override(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  v_event_id uuid;
  credential_id uuid;
begin
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select event_id into v_event_id from app_private.walking_groups where id = run_record.group_id;
  if run_record.status <> 'live' or not app_private.has_capability(v_event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select credential.id into credential_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portal_credentials credential on credential.portal_id = coalesce(stop.portal_id, plan_stop.portal_id) and credential.revoked_at is null
  where stop.id = _stop_id order by credential.version desc limit 1;
  if credential_id is null then raise exception 'NO_ACTIVE_CREDENTIAL' using errcode = '23514'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  select _stop_id, credential.id, credential.version, actor, 'support_override'
  from app_private.portal_credentials credential where credential.id = credential_id
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.support_override', actor, jsonb_build_object('reason', left(trim(_reason), 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.support_override', 'group_run', _run_id,
    jsonb_build_object('stopId', _stop_id, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('accepted', true, 'stopId', _stop_id, 'override', true);
end;
$$;

create or replace function api.admin_safe_withdraw_group(
  _run_id uuid,
  _responsible_adult_user_id uuid,
  _expected_run_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
begin
  select * into run_record from app_private.group_runs where id = _run_id for update;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if run_record.id is null or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.has_capability(group_record.event_id, 'live_support', actor) or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from app_private.group_registrations assignment
    join app_private.registrations registration on registration.id = assignment.registration_id
    join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
    where assignment.group_id = group_record.id and assignment.superseded_at is null and member.user_id = _responsible_adult_user_id
  ) then raise exception 'RESPONSIBLE_ADULT_NOT_IN_GROUP' using errcode = '23514'; end if;
  insert into app_private.group_safe_departures(group_id, run_id, responsible_adult_user_id, recorded_by, reason)
  values (group_record.id, run_record.id, _responsible_adult_user_id, actor, trim(_reason));
  update app_private.group_runs set status = 'stopped', current_stop_id = null, stopped_reason = trim(_reason),
    finished_at = clock_timestamp(), version = version + 1 where id = run_record.id returning * into run_record;
  update app_private.walking_groups set status = 'stopped', version = version + 1 where id = group_record.id;
  update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Veilige afmelding', version = version + 1
  where run_id = run_record.id and status in ('held', 'active');
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.safe_departure_recorded', 'group_run', run_record.id,
    jsonb_build_object('responsibleAdultUserId', _responsible_adult_user_id, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('runId', run_record.id, 'status', run_record.status, 'version', run_record.version);
end;
$$;

create or replace function api.admin_redirect_group(
  _run_id uuid,
  _target text,
  _preferred_portal_id uuid,
  _expected_run_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  stop_record app_private.run_stops;
  dispatch_result jsonb;
begin
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' or run_record.status <> 'live' then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  if not (
    app_private.has_capability(group_record.event_id, 'live_support', actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _target not in ('ordinary', 'finale')
     or (_target = 'ordinary' and _preferred_portal_id is null)
     or (_target = 'finale' and _preferred_portal_id is not null) then
    raise exception 'INVALID_REDIRECT_TARGET' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  if run_record.current_stop_id is not null then
    select * into stop_record from app_private.run_stops where id = run_record.current_stop_id for update;
    if stop_record.stop_kind = 'finale' then
      raise exception 'FINAL_DESTINATION_ALREADY_PUBLISHED' using errcode = '23514';
    end if;
    if exists (select 1 from app_private.scan_evidence where run_stop_id = stop_record.id) then
      raise exception 'VISIT_IN_PROGRESS' using errcode = '23514';
    end if;
    update app_private.run_stops
    set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
      completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
    where id = stop_record.id;
    update app_private.stop_participant_statuses
    set status = 'skipped', required_for_completion = false,
      exclusion_reason = 'Bestemming door organisatie gewijzigd',
      reason = 'Bestemming door organisatie gewijzigd', changed_by = actor,
      decided_at = clock_timestamp(), version = version + 1
    where run_stop_id = stop_record.id and status = 'pending';
    update app_private.portal_reservations
    set status = 'cancelled', cancelled_reason = 'Bestemming door organisatie gewijzigd', version = version + 1
    where id = stop_record.reservation_id and status in ('held', 'active');
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, stop_record.id, 'stop.admin_redirected', actor,
      jsonb_build_object('target', _target, 'reason', left(trim(_reason), 500)));
    update app_private.group_runs set current_stop_id = null, version = version + 1 where id = _run_id;
  end if;

  dispatch_result := app_private.dispatch_next_stop(
    _run_id,
    clock_timestamp(),
    _target = 'finale',
    case when _target = 'ordinary' then _preferred_portal_id else null end
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.destination_redirected', 'group_run', _run_id,
    jsonb_build_object('target', _target, 'preferredPortalId', _preferred_portal_id, 'reason', left(trim(_reason), 500)));
  return dispatch_result;
end;
$$;

create or replace function api.admin_activate_emergency_closure(
  _event_slug text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  settings app_private.event_route_settings;
  affected record;
  affected_count integer := 0;
  instruction text;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'live_support', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  select * into settings from app_private.event_route_settings where event_id = event_record.id for update;
  if nullif(trim(settings.emergency_destination_name), '') is null
     or nullif(trim(settings.emergency_instructions), '') is null then
    raise exception 'EMERGENCY_PLAN_NOT_CONFIGURED' using errcode = '23514';
  end if;
  instruction := 'Noodafsluiting: ga samen naar ' || settings.emergency_destination_name || '. ' || settings.emergency_instructions;
  update app_private.event_route_settings set finale_available = false, version = version + 1
  where event_id = event_record.id;
  update app_private.portals set operation_status = 'closed', version = version + 1
  where id = settings.final_portal_id and operation_status <> 'closed';

  for affected in
    select run.id as run_id, run.group_id, run.current_stop_id
    from app_private.group_runs run
    join app_private.walking_groups walking_group on walking_group.id = run.group_id
    where walking_group.event_id = event_record.id and walking_group.route_mode = 'dynamic'
      and run.status in ('ready', 'live', 'paused')
    for update of run
  loop
    if affected.current_stop_id is not null then
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Noodafsluiting geactiveerd',
        reason = instruction, changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.current_stop_id and required_for_completion;
      update app_private.run_stops
      set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = instruction, version = version + 1
      where id = affected.current_stop_id and state = 'active';
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      select affected.run_id, stop.id, portal_for_stop.world_id, 'system_skipped'
      from app_private.run_stops stop
      left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal_for_stop on portal_for_stop.id = coalesce(stop.portal_id, plan_stop.portal_id)
      where stop.id = affected.current_stop_id
      on conflict (run_stop_id) do nothing;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.current_stop_id, 'stop.emergency_interrupted', actor,
        jsonb_build_object('reason', instruction));
    end if;
    update app_private.portal_reservations
    set status = 'cancelled', cancelled_reason = 'Noodafsluiting geactiveerd', version = version + 1
    where run_id = affected.run_id and status in ('held', 'active');
    update app_private.group_runs
    set status = 'stopped', current_stop_id = null, stopped_reason = instruction,
      finished_at = clock_timestamp(), version = version + 1
    where id = affected.run_id;
    update app_private.walking_groups set status = 'stopped', version = version + 1 where id = affected.group_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    values (event_record.id, affected.group_id, affected.run_id, settings.final_portal_id,
      'urgent', 'EMERGENCY_CLOSURE', instruction);
    affected_count := affected_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'event.emergency_closure_activated', 'event', event_record.id,
    jsonb_build_object('affectedGroups', affected_count, 'reason', left(trim(_reason), 500),
      'destination', settings.emergency_destination_name));
  return jsonb_build_object('activated', true, 'affectedGroups', affected_count, 'instruction', instruction);
end;
$$;

create or replace function api.worker_dispatch_due_groups(_event_slug text, _batch_size integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  candidate record;
  dispatched integer := 0;
  alerted integer := 0;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  for candidate in
    select run.id, run.group_id, run.current_stop_id, run.updated_at, schedule.effective_ordinary_stop_at,
      stop.stop_kind, stop.opened_at, stop.reservation_id, reservation.expires_at as reservation_expires_at
    from app_private.group_runs run
    join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
    join app_private.group_schedule_revisions schedule on schedule.id = run.schedule_revision_id
    left join app_private.run_stops stop on stop.id = run.current_stop_id
    left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
    where walking_group.event_id = v_event_id and run.status = 'live'
    order by run.updated_at
    for update of run skip locked
    limit least(greatest(_batch_size, 1), 200)
  loop
    if candidate.current_stop_id is null then
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    elsif candidate.stop_kind = 'ordinary' and candidate.effective_ordinary_stop_at <= clock_timestamp() then
      if exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
        insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
        select v_event_id, candidate.group_id, candidate.id, 'warning', 'ACTIVE_VISIT_AFTER_STOP',
          'De stopgrens is bereikt tijdens een lopend bezoek; rond veilig af en ga daarna naar de eindpoort.'
        where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'ACTIVE_VISIT_AFTER_STOP');
        alerted := alerted + 1;
      else
        update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
          completed_at = clock_timestamp(), completion_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.current_stop_id and state = 'active';
        update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
          exclusion_reason = 'Stopgrens bereikt zonder bevestigde scan', reason = 'Automatische overgang naar laatste poort',
          decided_at = clock_timestamp(), version = version + 1
        where run_stop_id = candidate.current_stop_id and status = 'pending';
        update app_private.portal_reservations set status = 'cancelled',
          cancelled_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.reservation_id and status in ('held', 'active');
        update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
        insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
        values (candidate.id, candidate.current_stop_id, 'stop.cutoff_redirected', jsonb_build_object('reason', 'Stopgrens bereikt zonder bevestigde scan'));
        perform app_private.dispatch_next_stop(candidate.id, clock_timestamp(), true, null);
        dispatched := dispatched + 1;
      end if;
    elsif candidate.stop_kind = 'ordinary'
      and candidate.reservation_expires_at <= clock_timestamp()
      and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
        completed_at = clock_timestamp(), completion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', version = version + 1
      where id = candidate.current_stop_id and state = 'active';
      update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
        exclusion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', reason = 'Automatische herplanning naar een veilige actuele bestemming',
        decided_at = clock_timestamp(), version = version + 1
      where run_stop_id = candidate.current_stop_id and status = 'pending';
      update app_private.portal_reservations set status = 'expired', version = version + 1
      where id = candidate.reservation_id and status in ('held', 'active');
      update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (candidate.id, candidate.current_stop_id, 'stop.reservation_expired',
        jsonb_build_object('reason', 'Aankomstvenster verlopen zonder bevestigde scan'));
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      values (v_event_id, candidate.group_id, candidate.id, 'warning', 'DESTINATION_EXPIRED_REPLANNED',
        'De vorige aankomstreservering verliep zonder scan; de groep kreeg een nieuwe veilige serverbestemming.');
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    end if;
    if candidate.updated_at < clock_timestamp() - interval '10 minutes' then
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select v_event_id, candidate.group_id, candidate.id, 'warning', 'STALE_GROUP_CONNECTION',
        'De groep heeft langer dan tien minuten geen serverbevestiging gegeven.'
      where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'STALE_GROUP_CONNECTION');
      alerted := alerted + 1;
    end if;
  end loop;
  return jsonb_build_object('dispatched', dispatched, 'alerts', alerted);
end;
$$;

create or replace function app_private.dispatch_all_due_routes()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare event_slug text;
begin
  for event_slug in
    select event.slug from app_private.events event
    join app_private.event_route_settings settings on settings.event_id = event.id and settings.planner_mode = 'dynamic'
    where event.phase in ('ready', 'live', 'paused')
  loop
    perform api.worker_dispatch_due_groups(event_slug, 100);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'duindorp-halloween-route-dispatch') then
    perform cron.unschedule('duindorp-halloween-route-dispatch');
  end if;
  perform cron.schedule('duindorp-halloween-route-dispatch', '* * * * *', 'select app_private.dispatch_all_due_routes()');
end $$;

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
        'approvalStatus', portal.approval_status, 'operationStatus', portal.operation_status,
        'pauseAfterCurrent', portal.pause_after_current, 'version', portal.version, 'world', world.name,
        'isFinal', portal.id = route_settings.final_portal_id,
        'hasCredential', exists (
          select 1 from app_private.portal_credentials credential
          where credential.portal_id = portal.id and credential.revoked_at is null
        ),
        'nextArrival', (
          select min(candidate.arrival_at)
          from (values
            ((select min(plan_stop.planned_arrival_at)
              from app_private.route_plan_stops plan_stop
              join app_private.route_plan_versions plan on plan.id = plan_stop.plan_version_id and plan.state = 'published'
              join app_private.group_runs run on run.active_plan_version_id = plan.id and run.status in ('ready', 'live', 'paused')
              where plan_stop.portal_id = portal.id and plan_stop.planned_arrival_at >= now())),
            ((select min(reservation.reserved_from)
              from app_private.portal_reservations reservation
              where reservation.portal_id = portal.id and reservation.status in ('held', 'active') and reservation.reserved_until >= now()))
          ) candidate(arrival_at)
        )
      ) end
    )
    from app_private.portal_applications application
    left join app_private.portals portal on portal.application_id = application.id
    left join app_private.worlds world on world.id = portal.world_id
    left join app_private.event_route_settings route_settings on route_settings.event_id = application.event_id
    where application.event_id = v_event_id and application.applicant_user_id = actor
    order by (application.review_status not in ('withdrawn', 'rejected')) desc, application.created_at desc limit 1
  );
end;
$$;

create or replace function api.portal_arrivals_snapshot(_portal_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal_record app_private.portals;
begin
  select * into portal_record from app_private.portals where id = _portal_id;
  if actor is null or portal_record.id is null or not (
    exists (select 1 from app_private.portal_owners owner where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null)
    or app_private.has_capability(portal_record.event_id, 'portals_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return (
    with arrival_rows as (
      select walking_group.id as group_id, walking_group.code as group_code,
        stop.planned_arrival_at, stop.planned_departure_at,
        coalesce(run_stop.state::text, 'planned') as state
      from app_private.route_plan_stops stop
      join app_private.route_plan_versions plan on plan.id = stop.plan_version_id and plan.state = 'published'
      join app_private.walking_groups walking_group on walking_group.id = plan.group_id
      left join app_private.group_runs run on run.active_plan_version_id = plan.id
      left join app_private.run_stops run_stop on run_stop.run_id = run.id and run_stop.plan_stop_id = stop.id
      where stop.portal_id = portal_record.id
      union all
      select walking_group.id, walking_group.code, reservation.reserved_from, reservation.reserved_until,
        case reservation.status when 'active' then 'active' when 'completed' then 'completed' else 'planned' end
      from app_private.portal_reservations reservation
      join app_private.walking_groups walking_group on walking_group.id = reservation.group_id
      where reservation.portal_id = portal_record.id and reservation.status in ('held', 'active', 'completed')
      union all
      select walking_group.id, walking_group.code, schedule.expected_finale_arrival_at,
        schedule.expected_finale_arrival_at + make_interval(secs => settings.finale_show_seconds + settings.finale_turnover_seconds),
        'planned'
      from app_private.group_schedule_revisions schedule
      join app_private.walking_groups walking_group on walking_group.id = schedule.group_id
      join app_private.event_route_settings settings on settings.event_id = walking_group.event_id and settings.final_portal_id = portal_record.id
      where schedule.state = 'published'
        and not exists (
          select 1 from app_private.portal_reservations reservation
          where reservation.group_id = schedule.group_id and reservation.portal_id = portal_record.id
            and reservation.status in ('held', 'active', 'completed')
        )
    ), enriched as (
      select arrival_rows.*,
        (select count(*) from app_private.group_registrations assignment
         join app_private.registration_children child on child.registration_id = assignment.registration_id
         where assignment.group_id = arrival_rows.group_id and assignment.superseded_at is null and child.participation_status = 'active') as expected_children
      from arrival_rows
    )
    select jsonb_build_object(
      'portalId', portal_record.id,
      'arrivals', coalesce((select jsonb_agg(jsonb_build_object(
        'groupCode', enriched.group_code, 'plannedArrivalAt', enriched.planned_arrival_at,
        'plannedDepartureAt', enriched.planned_departure_at,
        'expectedChildren', enriched.expected_children, 'state', enriched.state
      ) order by enriched.planned_arrival_at, enriched.group_code) from enriched), '[]'::jsonb),
      'expectedTotal', coalesce((select sum(expected_children) from enriched), 0)
    )
  );
end;
$$;

create or replace function api.admin_evening_cockpit(_event_slug text)
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
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'live_support', actor)
    or app_private.has_capability(v_event_id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'groupId', walking_group.id, 'groupCode', walking_group.code, 'groupVersion', walking_group.version,
        'status', walking_group.status, 'runId', run.id, 'runStatus', run.status, 'runVersion', run.version,
        'currentStopId', run.current_stop_id, 'currentPortal', portal.name,
        'currentKind', stop.stop_kind, 'lastConfirmedAt', run.updated_at,
        'currentCoordinate', case when location.latitude is null then null else jsonb_build_array(location.longitude, location.latitude) end,
        'leaderEmail', (select users.email from app_private.group_leaders leader
          join auth.users users on users.id = leader.user_id
          where leader.group_id = walking_group.id and leader.active_from <= now()
            and (leader.active_until is null or leader.active_until > now())
          order by leader.active_from desc limit 1),
        'responsibleAdults', coalesce((select jsonb_agg(distinct jsonb_build_object('userId', users.id, 'email', users.email))
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
          join auth.users users on users.id = member.user_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null), '[]'::jsonb),
        'elapsedSeconds', case when run.started_at is null then null else greatest(0, extract(epoch from (now() - run.started_at))::integer) end,
        'effectiveStopAt', schedule.effective_ordinary_stop_at,
        'expectedFinaleArrivalAt', coalesce(finale_reservation.reserved_from, schedule.expected_finale_arrival_at),
        'childCount', (select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
          where assignment.group_id = walking_group.id and assignment.superseded_at is null)
      ) order by walking_group.code)
      from app_private.walking_groups walking_group
      left join app_private.group_runs run on run.group_id = walking_group.id and run.status in ('ready', 'live', 'paused')
      left join app_private.run_stops stop on stop.id = run.current_stop_id
      left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      left join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
      left join app_private.portal_reservations finale_reservation on finale_reservation.run_id = run.id
        and finale_reservation.kind = 'finale' and finale_reservation.status in ('held', 'active')
      where walking_group.event_id = v_event_id
    ), '[]'::jsonb),
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'name', portal.name, 'operationStatus', portal.operation_status, 'version', portal.version,
        'isFinal', portal.id = settings.final_portal_id,
        'activeReservations', (select count(*) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')),
        'expectedChildren', (select coalesce(sum(reservation.child_count), 0) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active'))
      ) order by portal.id = settings.final_portal_id desc, portal.name)
      from app_private.portals portal
      join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = v_event_id and portal.approval_status = 'approved'
    ), '[]'::jsonb),
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', alert.id, 'priority', alert.priority, 'code', alert.code,
        'message', alert.message, 'groupId', alert.group_id, 'portalId', alert.portal_id,
        'createdAt', alert.created_at
      ) order by case alert.priority when 'urgent' then 0 when 'warning' then 1 else 2 end, alert.created_at)
      from app_private.route_alerts alert where alert.event_id = v_event_id and alert.status = 'open'
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function app_private.copy_registration_preferences_from_draft() from public, anon, authenticated;
revoke execute on function app_private.walking_path_metrics(uuid, uuid, uuid, boolean) from public, anon, authenticated;
revoke execute on function app_private.schedule_counts_for_publication(uuid, uuid, app_private.schedule_state, uuid[]) from public, anon, authenticated;
revoke execute on function app_private.try_reserve_finale(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function app_private.dispatch_next_stop(uuid, timestamptz, boolean, uuid) from public, anon, authenticated;
revoke execute on function app_private.dispatch_all_due_routes() from public, anon, authenticated;

revoke execute on function api.portal_registration_begin(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function api.portal_registration_begin(text, text, text, text, text, text, text, text, text) to service_role;

revoke execute on function api.worker_dispatch_due_groups(text, integer) from public, anon, authenticated;
grant execute on function api.worker_dispatch_due_groups(text, integer) to service_role;

do $$
declare signature text;
begin
  foreach signature in array array[
    'api.portal_registration_claim(text)',
    'api.portal_application_save(text,jsonb,integer)',
    'api.portal_application_submit(uuid,integer,text,text)',
    'api.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text)',
    'api.registration_preferences_snapshot(text)',
    'api.registration_preferences_save(uuid,app_private.start_time_preference,timestamptz,integer)',
    'api.registration_preferences_request_change(uuid,app_private.start_time_preference,timestamptz,text)',
    'api.admin_route_configuration_snapshot(text)',
    'api.admin_save_route_settings(text,jsonb,integer,text)',
    'api.admin_start_point_save(text,uuid,jsonb,integer,text)',
    'api.admin_start_slot_save(text,uuid,uuid,timestamptz,integer,integer,text)',
    'api.admin_apply_dynamic_plan(text,jsonb,text,text,text)',
    'api.admin_save_group_schedule(uuid,uuid,timestamptz,timestamptz,integer,text,text)',
    'api.admin_publish_group_schedules(text,uuid[],text)',
    'api.run_start(uuid,uuid[],integer,text,text)',
    'api.run_scan(uuid,uuid,integer,text,text)',
    'api.run_complete_stop(uuid,uuid,integer,boolean,text,text)',
    'api.admin_redirect_group(uuid,text,uuid,integer,text)',
    'api.admin_activate_emergency_closure(text,text)',
    'api.group_snapshot(uuid)',
    'api.group_viewer_snapshot(uuid)',
    'api.participant_context(text)',
    'api.portal_set_operational_state(uuid,app_private.portal_operation_status,integer,text)',
    'api.run_support_override(uuid,uuid,integer,text)',
    'api.admin_safe_withdraw_group(uuid,uuid,integer,text)',
    'api.portal_snapshot(text)',
    'api.portal_arrivals_snapshot(uuid)',
    'api.admin_evening_cockpit(text)'
  ] loop
    execute 'revoke execute on function ' || signature || ' from public, anon';
    execute 'grant execute on function ' || signature || ' to authenticated';
  end loop;
end $$;
