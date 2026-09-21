-- De Duindorpse Poorten van Halloween — core schema.
-- Operationele data staat buiten de Data API in app_private.

create schema if not exists app_private;
create schema if not exists api;

revoke all on schema app_private from public, anon, authenticated;
revoke all on schema api from public;
grant usage on schema api to anon, authenticated, service_role;

create type app_private.event_phase as enum ('draft', 'registration_open', 'registration_closed', 'planning', 'ready', 'live', 'paused', 'completed', 'archived');
create type app_private.registration_status as enum ('draft', 'submitted', 'cancelled');
create type app_private.payment_status as enum ('awaiting_link', 'awaiting_payment', 'reported', 'confirmed', 'partial', 'refund_due', 'refunded', 'waived');
create type app_private.review_status as enum ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'withdrawn');
create type app_private.portal_operation_status as enum ('scheduled', 'open', 'paused', 'closed');
create type app_private.plan_state as enum ('draft', 'valid', 'invalid', 'published', 'superseded');
create type app_private.run_status as enum ('ready', 'live', 'paused', 'completed', 'stopped');
create type app_private.run_stop_state as enum ('locked', 'active', 'completed');
create type app_private.stop_outcome as enum ('visited', 'mixed', 'all_skipped', 'system_skipped');
create type app_private.participant_stop_status as enum ('pending', 'visited', 'skipped');
create type app_private.attendance_status as enum ('present', 'absent', 'departed');
create type app_private.outbox_status as enum ('pending', 'processing', 'accepted', 'delivered', 'deferred', 'failed', 'unknown', 'suppressed', 'validated');

create table app_private.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) between 1 and 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0)
);

create table app_private.events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  title text not null check (char_length(title) between 3 and 160),
  local_date date not null,
  timezone text not null default 'Europe/Amsterdam',
  phase app_private.event_phase not null default 'draft',
  currency text not null default 'EUR' check (currency = 'EUR'),
  price_cents integer not null check (price_cents >= 0),
  registration_open_at timestamptz,
  registration_close_at timestamptz,
  change_deadline timestamptz,
  settings jsonb not null default '{}'::jsonb,
  settings_version integer not null default 1 check (settings_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_registration_window check (registration_open_at is null or registration_close_at is null or registration_open_at < registration_close_at)
);

create table app_private.event_capabilities (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  capability text not null check (capability in ('event_admin', 'registration_manage', 'payments_manage', 'portals_manage', 'groups_manage', 'live_support', 'content_manage')),
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoke_reason text,
  unique nulls not distinct (event_id, user_id, capability, revoked_at)
);
create unique index event_capabilities_one_active on app_private.event_capabilities(event_id, user_id, capability) where revoked_at is null;

create table app_private.households (
  id uuid primary key default gen_random_uuid(),
  label text not null check (char_length(label) between 1 and 120),
  primary_contact_user_id uuid not null references auth.users(id),
  phone text check (phone is null or char_length(phone) between 6 and 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0)
);

create table app_private.household_members (
  household_id uuid not null references app_private.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  relation_role text not null check (relation_role in ('owner', 'adult')),
  accepted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id),
  primary key (household_id, user_id, accepted_at)
);
create unique index household_members_one_active on app_private.household_members(household_id, user_id) where revoked_at is null;

create table app_private.household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references app_private.households(id) on delete cascade,
  recipient_email text not null,
  token_hash bytea not null unique,
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create table app_private.children (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references app_private.households(id) on delete restrict,
  first_name text not null check (char_length(first_name) between 1 and 80),
  age_at_event smallint check (age_at_event between 0 and 20),
  age_band text check (age_band is null or char_length(age_band) <= 40),
  accessibility_note text check (accessibility_note is null or char_length(accessibility_note) <= 500),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  check (age_at_event is not null or age_band is not null)
);

create table app_private.registration_drafts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  household_id uuid not null references app_private.households(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, household_id)
);

create table app_private.start_slots (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  external_id text,
  name text not null,
  location_name text not null,
  private_address text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  location_verified_at timestamptz,
  starts_at timestamptz not null,
  max_groups integer not null check (max_groups > 0),
  max_children integer not null check (max_children > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, external_id)
);

create table app_private.registrations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete restrict,
  household_id uuid not null references app_private.households(id) on delete restrict,
  status app_private.registration_status not null default 'draft',
  reference text not null unique,
  start_preference_id uuid references app_private.start_slots(id),
  submitted_at timestamptz,
  terms_version text,
  terms_accepted_at timestamptz,
  privacy_version text,
  marketing_consent boolean not null default false,
  price_snapshot_cents integer not null default 0 check (price_snapshot_cents >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0)
);
create unique index registrations_one_active_per_event_household on app_private.registrations(event_id, household_id) where status <> 'cancelled';

create table app_private.registration_children (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete restrict,
  registration_id uuid not null references app_private.registrations(id) on delete restrict,
  child_id uuid not null references app_private.children(id) on delete restrict,
  participation_status text not null default 'active' check (participation_status in ('active', 'cancelled')),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  created_at timestamptz not null default now(),
  unique (event_id, child_id)
);

create table app_private.registration_revisions (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null references app_private.registrations(id) on delete restrict,
  version integer not null check (version > 0),
  changed_by uuid not null references auth.users(id),
  change_type text not null,
  totals_before jsonb not null default '{}'::jsonb,
  totals_after jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (registration_id, version)
);

create table app_private.together_parties (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  public_label text not null check (char_length(public_label) between 1 and 80),
  creator_household_id uuid not null references app_private.households(id) on delete restrict,
  invite_token_hash bytea not null unique,
  expires_at timestamptz not null,
  locked_at timestamptz,
  created_at timestamptz not null default now()
);

create table app_private.together_memberships (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references app_private.together_parties(id) on delete cascade,
  registration_id uuid not null references app_private.registrations(id) on delete cascade,
  joined_at timestamptz not null default now(),
  left_at timestamptz
);
create unique index together_membership_one_active on app_private.together_memberships(registration_id) where left_at is null;

create table app_private.worlds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  slug text not null,
  name text not null,
  story text not null default '',
  artwork_path text,
  sort_order integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, slug),
  unique (event_id, sort_order)
);

create table app_private.portal_applications (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  applicant_user_id uuid not null references auth.users(id),
  review_status app_private.review_status not null default 'draft',
  requested_world_id uuid references app_private.worlds(id),
  private_draft_data jsonb not null default '{}'::jsonb,
  uploaded_asset_refs jsonb not null default '[]'::jsonb,
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0)
);

create table app_private.portals (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete restrict,
  application_id uuid not null unique references app_private.portal_applications(id) on delete restrict,
  world_id uuid not null references app_private.worlds(id) on delete restrict,
  name text not null,
  description text not null default '',
  intensity smallint not null check (intensity between 1 and 4),
  approval_status app_private.review_status not null default 'approved' check (approval_status in ('approved', 'withdrawn', 'rejected')),
  operation_status app_private.portal_operation_status not null default 'scheduled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, id)
);

create table app_private.portal_private_locations (
  portal_id uuid primary key references app_private.portals(id) on delete cascade,
  street text not null,
  house_number text not null,
  addition text,
  postal_code text not null,
  city text not null default 'Den Haag',
  latitude numeric(9,6),
  longitude numeric(9,6),
  verified_at timestamptz,
  verified_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table app_private.portal_publications (
  portal_id uuid primary key references app_private.portals(id) on delete cascade,
  published_title text not null,
  teaser text not null default '',
  image_path text,
  public_area text,
  optional_public_point point,
  exact_address_consent_at timestamptz,
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table app_private.portal_owners (
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  accepted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (portal_id, user_id, accepted_at)
);
create unique index portal_owners_one_active on app_private.portal_owners(portal_id, user_id) where revoked_at is null;

create table app_private.portal_windows (
  id uuid primary key default gen_random_uuid(),
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  opens_at timestamptz not null,
  closes_at timestamptz not null,
  visit_minutes integer not null check (visit_minutes > 0),
  buffer_minutes integer not null default 0 check (buffer_minutes >= 0),
  max_concurrent_groups integer not null check (max_concurrent_groups > 0),
  max_children_per_visit integer not null check (max_children_per_visit > 0),
  check (opens_at < closes_at)
);

create table app_private.portal_flags (
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  flag_key text not null,
  value boolean not null,
  primary key (portal_id, flag_key)
);

create table app_private.portal_credentials (
  id uuid primary key default gen_random_uuid(),
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  token_hash bytea not null,
  short_code_hash bytea,
  version integer not null check (version > 0),
  valid_from timestamptz not null,
  valid_until timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (portal_id, version)
);

create table app_private.walking_nodes (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  external_id text,
  kind text not null check (kind in ('portal', 'start', 'junction')),
  portal_id uuid references app_private.portals(id) on delete cascade,
  coordinate point not null,
  is_public boolean not null default false,
  verified_at timestamptz,
  verified_by uuid references auth.users(id),
  unique (event_id, external_id)
);

create table app_private.walking_edges (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  external_id text,
  from_node_id uuid not null references app_private.walking_nodes(id) on delete cascade,
  to_node_id uuid not null references app_private.walking_nodes(id) on delete cascade,
  distance_m integer not null check (distance_m > 0),
  duration_seconds integer not null check (duration_seconds > 0),
  wheelchair_accessible boolean,
  geometry_geojson jsonb,
  approved_at timestamptz,
  approved_by uuid references auth.users(id),
  closed_at timestamptz,
  unique (event_id, external_id),
  check (from_node_id <> to_node_id)
);

create table app_private.walking_groups (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete restrict,
  code text not null,
  status text not null default 'draft' check (status in ('draft', 'ready', 'live', 'completed', 'stopped')),
  start_slot_id uuid references app_private.start_slots(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (event_id, code),
  unique (event_id, id)
);

create table app_private.group_registrations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  registration_id uuid not null references app_private.registrations(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  published_at timestamptz,
  superseded_at timestamptz,
  assignment_revision integer not null check (assignment_revision > 0)
);
create unique index group_registration_one_active on app_private.group_registrations(registration_id) where superseded_at is null;

create table app_private.group_leaders (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  active_from timestamptz not null,
  active_until timestamptz,
  revision integer not null check (revision > 0),
  assigned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (group_id, revision),
  check (active_until is null or active_from < active_until)
);
create unique index group_leader_one_current on app_private.group_leaders(group_id) where active_until is null;

create table app_private.route_plan_versions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  revision integer not null check (revision > 0),
  state app_private.plan_state not null default 'draft',
  generated_by uuid references auth.users(id),
  published_at timestamptz,
  supersedes_id uuid references app_private.route_plan_versions(id),
  input_hash text not null,
  conflicts jsonb not null default '[]'::jsonb,
  score jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (group_id, revision),
  unique (group_id, input_hash)
);

alter table app_private.walking_groups add column current_plan_version_id uuid references app_private.route_plan_versions(id);

create table app_private.route_plan_stops (
  id uuid primary key default gen_random_uuid(),
  plan_version_id uuid not null references app_private.route_plan_versions(id) on delete restrict,
  position integer not null check (position > 0),
  portal_id uuid not null references app_private.portals(id) on delete restrict,
  planned_arrival_at timestamptz not null,
  planned_departure_at timestamptz not null,
  incoming_edge_ids uuid[] not null default '{}'::uuid[],
  created_at timestamptz not null default now(),
  unique (plan_version_id, position),
  unique (plan_version_id, portal_id),
  check (planned_arrival_at < planned_departure_at)
);

create table app_private.group_runs (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references app_private.walking_groups(id) on delete restrict,
  active_plan_version_id uuid not null references app_private.route_plan_versions(id) on delete restrict,
  status app_private.run_status not null default 'ready',
  current_stop_id uuid,
  started_at timestamptz,
  finished_at timestamptz,
  stopped_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0)
);
create unique index group_runs_one_active on app_private.group_runs(group_id) where status in ('ready', 'live', 'paused');

create table app_private.run_participants (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  registration_child_id uuid not null references app_private.registration_children(id) on delete restrict,
  attendance app_private.attendance_status not null default 'present',
  joined_at timestamptz not null default now(),
  departed_at timestamptz,
  roster_version integer not null default 1 check (roster_version > 0),
  unique (run_id, registration_child_id)
);

create table app_private.run_stops (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  plan_stop_id uuid not null references app_private.route_plan_stops(id) on delete restrict,
  sequence integer not null check (sequence > 0),
  state app_private.run_stop_state not null default 'locked',
  outcome app_private.stop_outcome,
  opened_at timestamptz,
  completed_at timestamptz,
  completion_actor uuid references auth.users(id),
  completion_reason text,
  version integer not null default 1 check (version > 0),
  unique (run_id, sequence),
  unique (run_id, plan_stop_id),
  check ((state = 'completed' and outcome is not null and completed_at is not null) or state <> 'completed')
);
alter table app_private.group_runs add constraint group_runs_current_stop_fk foreign key (current_stop_id) references app_private.run_stops(id);

create table app_private.stop_participant_statuses (
  id uuid primary key default gen_random_uuid(),
  run_stop_id uuid not null references app_private.run_stops(id) on delete restrict,
  run_participant_id uuid not null references app_private.run_participants(id) on delete restrict,
  status app_private.participant_stop_status not null default 'pending',
  required_for_completion boolean not null default true,
  exclusion_reason text,
  version integer not null default 1 check (version > 0),
  changed_by uuid references auth.users(id),
  reason text,
  decided_at timestamptz,
  unique (run_stop_id, run_participant_id),
  check (required_for_completion or exclusion_reason is not null)
);

create table app_private.scan_evidence (
  id uuid primary key default gen_random_uuid(),
  run_stop_id uuid not null references app_private.run_stops(id) on delete restrict,
  credential_id uuid not null references app_private.portal_credentials(id) on delete restrict,
  credential_version integer not null,
  actor_id uuid not null references auth.users(id),
  validation_method text not null check (validation_method in ('qr', 'short_code', 'support_override')),
  scanned_at timestamptz not null default now(),
  unique (run_stop_id)
);

create table app_private.group_seals (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  run_stop_id uuid not null references app_private.run_stops(id) on delete restrict,
  world_id uuid not null references app_private.worlds(id) on delete restrict,
  outcome app_private.stop_outcome not null,
  awarded_at timestamptz not null default now(),
  unique (run_stop_id)
);

create table app_private.journey_events (
  id bigint generated always as identity primary key,
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  stop_id uuid references app_private.run_stops(id) on delete restrict,
  event_type text not null,
  actor_id uuid references auth.users(id),
  safe_metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create table app_private.payment_requests (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid references app_private.registrations(id) on delete restrict,
  sponsor_application_id uuid,
  purpose text not null,
  method text not null default 'tikkie_manual' check (method = 'tikkie_manual'),
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null default 'EUR' check (currency = 'EUR'),
  reference text not null unique,
  external_url text,
  status app_private.payment_status not null default 'awaiting_link',
  due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check ((registration_id is not null)::integer + (sponsor_application_id is not null)::integer = 1)
);

create table app_private.payment_entries (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references app_private.payment_requests(id) on delete restrict,
  amount_cents integer not null,
  entry_type text not null check (entry_type in ('payment', 'correction', 'refund', 'waiver', 'reported')),
  checked_by uuid references auth.users(id),
  checked_at timestamptz,
  external_reference text,
  reason text not null,
  created_at timestamptz not null default now()
);

create table app_private.sponsor_applications (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  contact_user_id uuid references auth.users(id),
  contact_name text not null,
  contact_email text not null,
  contribution_type text not null,
  proposed_amount_cents integer check (proposed_amount_cents is null or proposed_amount_cents >= 0),
  message text,
  review_status app_private.review_status not null default 'submitted',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
alter table app_private.payment_requests add constraint payment_requests_sponsor_fk foreign key (sponsor_application_id) references app_private.sponsor_applications(id) on delete restrict;

create table app_private.sponsor_publications (
  sponsor_application_id uuid primary key references app_private.sponsor_applications(id) on delete cascade,
  approved_name text not null,
  logo_path text,
  website_url text,
  sort_order integer not null default 0,
  published_at timestamptz not null,
  published_by uuid not null references auth.users(id)
);

create table app_private.contact_messages (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  sender_name text not null,
  sender_email text not null,
  subject text not null,
  body text not null,
  status text not null default 'new' check (status in ('new', 'assigned', 'resolved', 'closed')),
  assigned_to uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table app_private.content_versions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  page_key text not null,
  locale text not null default 'nl-NL',
  structured_content jsonb not null,
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  version integer not null check (version > 0),
  unique (event_id, page_key, locale, version)
);

create table app_private.support_cases (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  group_id uuid references app_private.walking_groups(id),
  portal_id uuid references app_private.portals(id),
  category text not null,
  status text not null default 'open' check (status in ('open', 'acknowledged', 'resolved', 'closed')),
  reporter uuid references auth.users(id),
  safe_description text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table app_private.email_outbox (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  message_type text not null,
  recipient_ref text not null,
  recipient_email text not null,
  payload jsonb not null,
  status app_private.outbox_status not null default 'pending',
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  provider_id text,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app_private.email_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider = 'sendgrid'),
  provider_event_id text not null,
  outbox_id uuid references app_private.email_outbox(id) on delete set null,
  kind text not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique (provider, provider_event_id)
);

create table app_private.command_receipts (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete cascade,
  command_type text not null,
  idempotency_key text not null,
  request_hash text not null,
  safe_result jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (actor_id, command_type, idempotency_key)
);

create table app_private.audit_events (
  id bigint generated always as identity primary key,
  event_id uuid references app_private.events(id) on delete restrict,
  actor_id uuid references auth.users(id),
  action text not null,
  resource_type text not null,
  resource_id uuid,
  correlation_id text,
  minimal_change jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table app_private.rate_limit_buckets (
  scope text not null,
  opaque_subject_hash text not null,
  window_start timestamptz not null,
  count integer not null default 1 check (count > 0),
  blocked_until timestamptz,
  expires_at timestamptz not null,
  primary key (scope, opaque_subject_hash, window_start)
);

create table app_private.import_batches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  kind text not null,
  dry_run boolean not null,
  source_hash text not null,
  status text not null check (status in ('validating', 'invalid', 'ready', 'applied', 'failed')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  applied_at timestamptz
);

create table app_private.import_errors (
  id bigint generated always as identity primary key,
  batch_id uuid not null references app_private.import_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  field_name text,
  error_code text not null,
  message text not null
);

create or replace function app_private.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles','events','households','children','registration_drafts','start_slots','registrations','worlds',
    'portal_applications','portals','portal_private_locations','portal_publications','walking_groups','group_runs',
    'payment_requests','sponsor_applications','contact_messages','support_cases','email_outbox'
  ] loop
    execute format('create trigger %I_touch before update on app_private.%I for each row execute function app_private.touch_updated_at()', table_name, table_name);
  end loop;
end $$;

create index household_members_user_active_idx on app_private.household_members(user_id, household_id) where revoked_at is null;
create index children_household_active_idx on app_private.children(household_id) where archived_at is null;
create index registrations_event_status_idx on app_private.registrations(event_id, status);
create index registration_children_registration_idx on app_private.registration_children(registration_id);
create index portal_applications_actor_idx on app_private.portal_applications(event_id, applicant_user_id, review_status);
create index portals_event_status_idx on app_private.portals(event_id, approval_status, operation_status);
create index portal_owners_user_active_idx on app_private.portal_owners(user_id, portal_id) where revoked_at is null;
create index group_registrations_group_active_idx on app_private.group_registrations(group_id) where superseded_at is null;
create index group_leaders_user_current_idx on app_private.group_leaders(user_id, group_id) where active_until is null;
create index run_participants_run_attendance_idx on app_private.run_participants(run_id, attendance);
create index run_stops_run_state_idx on app_private.run_stops(run_id, state, sequence);
create index stop_status_stop_required_idx on app_private.stop_participant_statuses(run_stop_id, required_for_completion, status);
create index email_outbox_claim_idx on app_private.email_outbox(status, next_attempt_at, lease_until);
create index email_events_outbox_idx on app_private.email_events(outbox_id, occurred_at);
create index audit_event_resource_idx on app_private.audit_events(event_id, resource_type, resource_id, created_at desc);
create index rate_limit_expiry_idx on app_private.rate_limit_buckets(expires_at);

do $$
declare
  item record;
begin
  for item in select tablename from pg_tables where schemaname = 'app_private' loop
    execute format('alter table app_private.%I enable row level security', item.tablename);
    execute format('revoke all on table app_private.%I from public, anon, authenticated', item.tablename);
  end loop;
end $$;

revoke execute on all functions in schema app_private from public, anon, authenticated;
revoke execute on all functions in schema api from public, anon, authenticated;
