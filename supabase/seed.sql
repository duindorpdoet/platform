-- Uitsluitend lokale/testfixtures. Dit bestand wordt niet door `supabase db push`
-- op productie geladen. Alle namen, adressen en accounts hieronder zijn fictief.

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token,
  email_change_token_new, email_change, phone_change_token, email_change_token_current,
  reauthentication_token, created_at, updated_at
)
select fixture.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', fixture.email,
       crypt('local-test-only', gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
       '', '', '', '', '', '', '', now(), now()
from (values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'parent-a@example.invalid'),
  ('b0000000-0000-0000-0000-000000000001'::uuid, 'parent-b@example.invalid'),
  ('c0000000-0000-0000-0000-000000000001'::uuid, 'leader-a@example.invalid'),
  ('d0000000-0000-0000-0000-000000000001'::uuid, 'leader-b@example.invalid'),
  ('e0000000-0000-0000-0000-000000000001'::uuid, 'owner@example.invalid'),
  ('f0000000-0000-0000-0000-000000000001'::uuid, 'admin@example.invalid'),
  ('a0000000-0000-0000-0000-000000000002'::uuid, 'parent-size-1@example.invalid'),
  ('a0000000-0000-0000-0000-000000000005'::uuid, 'parent-size-5@example.invalid'),
  ('a0000000-0000-0000-0000-000000000007'::uuid, 'parent-size-7@example.invalid'),
  ('a0000000-0000-0000-0000-000000000010'::uuid, 'parent-size-10@example.invalid')
) fixture(id, email)
on conflict (id) do nothing;

insert into auth.identities(id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select
  users.id,
  users.id::text,
  users.id,
  jsonb_build_object('sub', users.id::text, 'email', users.email, 'email_verified', true),
  'email',
  now(),
  users.created_at,
  users.updated_at
from auth.users users
where users.email like '%@example.invalid'
on conflict (provider_id, provider) do nothing;

update app_private.events
set phase = 'registration_open',
    registration_open_at = timestamptz '2026-09-01 00:00:00+02',
    registration_close_at = timestamptz '2026-10-25 23:59:00+01',
    settings = settings || '{"fixture":true,"termsVersion":"test-v1","privacyVersion":"test-v1","groupRegistrationOpen":true,"portalRegistrationOpen":true}'::jsonb
where slug = 'duindorp-halloween-2026';

do $$
declare
  v_event_id uuid;
  v_admin uuid := 'f0000000-0000-0000-0000-000000000001';
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_world_ids uuid[];
  v_application_id uuid;
  v_portal_id uuid;
  v_node_id uuid;
  v_previous_node_id uuid;
  i integer;
begin
  select id into v_event_id from app_private.events where slug = 'duindorp-halloween-2026';
  select array_agg(id order by sort_order) into v_world_ids from app_private.worlds where event_id = v_event_id;

  insert into app_private.event_capabilities(event_id, user_id, capability, granted_by)
  select v_event_id, v_admin, capability, v_admin
  from unnest(array['event_admin','registration_manage','payments_manage','portals_manage','groups_manage','live_support','content_manage']) capability
  on conflict do nothing;

  for i in 1..30 loop
    v_application_id := ('11000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    v_portal_id := ('12000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    v_node_id := ('13000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into app_private.portal_applications(id, event_id, applicant_user_id, review_status, requested_world_id, private_draft_data, submitted_at, reviewed_by, reviewed_at)
    values (v_application_id, v_event_id, v_owner, 'approved', v_world_ids[((i - 1) % 6) + 1], jsonb_build_object('fixture', true), now(), v_admin, now())
    on conflict (id) do nothing;
    insert into app_private.portals(id, event_id, application_id, world_id, name, description, intensity, approval_status, operation_status)
    values (v_portal_id, v_event_id, v_application_id, v_world_ids[((i - 1) % 6) + 1], 'Testpoort ' || lpad(i::text, 2, '0'), 'Fictieve poort voor lokale tests.', ((i - 1) % 4) + 1, 'approved', 'open')
    on conflict (id) do nothing;
    insert into app_private.portal_private_locations(portal_id, street, house_number, postal_code, city, latitude, longitude, verified_at, verified_by)
    values (v_portal_id, 'NIET-BESTAAND TESTADRES', i::text, '0000AA', 'Teststad', 52.10 + i * 0.0001, 4.27 + i * 0.0001, now(), v_admin)
    on conflict (portal_id) do nothing;
    insert into app_private.portal_publications(portal_id, published_title, teaser, public_area, published_at)
    values (v_portal_id, 'Testpoort ' || lpad(i::text, 2, '0'), 'Fictieve teaser voor tests.', 'Duindorp', now())
    on conflict (portal_id) do nothing;
    insert into app_private.portal_owners(portal_id, user_id) values (v_portal_id, v_owner) on conflict do nothing;
    insert into app_private.portal_windows(portal_id, opens_at, closes_at, visit_minutes, buffer_minutes, max_concurrent_groups, max_children_per_visit)
    values (v_portal_id, timestamptz '2026-10-31 18:00:00+01', timestamptz '2026-10-31 22:00:00+01', 5, 2, 10, 12)
    on conflict do nothing;
    insert into app_private.portal_flags(portal_id, flag_key, value)
    values (v_portal_id, 'fixture', true) on conflict do nothing;
    insert into app_private.portal_credentials(portal_id, token_hash, short_code_hash, version, valid_from, valid_until)
    values (
      v_portal_id,
      extensions.digest(convert_to('TEST-PORTAL-' || lpad(i::text, 2, '0') || '-TOKEN', 'utf8'), 'sha256'),
      extensions.digest(convert_to('TEST-' || lpad(i::text, 2, '0'), 'utf8'), 'sha256'),
      1,
      timestamptz '2026-01-01 00:00:00+01',
      timestamptz '2026-11-01 00:00:00+01'
    ) on conflict do nothing;
    insert into app_private.walking_nodes(id, event_id, external_id, kind, portal_id, coordinate, verified_at, verified_by)
    values (v_node_id, v_event_id, 'fixture-portal-' || i, 'portal', v_portal_id, point(4.27 + i * 0.0001, 52.10 + i * 0.0001), now(), v_admin)
    on conflict (id) do nothing;
    if v_previous_node_id is not null then
      insert into app_private.walking_edges(event_id, external_id, from_node_id, to_node_id, distance_m, duration_seconds, wheelchair_accessible, approved_at, approved_by)
      values (v_event_id, 'fixture-edge-' || (i - 1) || '-' || i, v_previous_node_id, v_node_id, 120, 90, true, now(), v_admin)
      on conflict do nothing;
    end if;
    v_previous_node_id := v_node_id;
  end loop;
end $$;

do $$
declare
  v_event_id uuid;
  v_admin uuid := 'f0000000-0000-0000-0000-000000000001';
  v_slot_id uuid := '20000000-0000-0000-0000-000000000001';
  v_household_id uuid;
  v_registration_id uuid;
  v_child_id uuid;
  v_group_id uuid;
  v_plan_id uuid;
  v_parent uuid;
  v_size integer;
  sizes integer[] := array[1,5,7,10];
  child_index integer;
  group_index integer := 0;
begin
  select id into v_event_id from app_private.events where slug = 'duindorp-halloween-2026';
  insert into app_private.start_slots(id, event_id, external_id, name, location_name, private_address, latitude, longitude, location_verified_at, starts_at, max_groups, max_children)
  values (v_slot_id, v_event_id, 'fixture-start-1', 'Teststart 1', 'Fictieve testlocatie', 'NIET-BESTAAND TESTADRES', 52.1, 4.27, now(), timestamptz '2026-10-31 18:30:00+01', 10, 100)
  on conflict (id) do nothing;
  insert into app_private.walking_nodes(id, event_id, external_id, kind, coordinate, verified_at, verified_by)
  values ('13000000-0000-0000-0000-000000000999', v_event_id, 'fixture-start-1', 'start', point(4.27, 52.1), now(), v_admin)
  on conflict (id) do nothing;
  insert into app_private.walking_edges(event_id, external_id, from_node_id, to_node_id, distance_m, duration_seconds, wheelchair_accessible, approved_at, approved_by)
  values (v_event_id, 'fixture-edge-start-1', '13000000-0000-0000-0000-000000000999', '13000000-0000-0000-0000-000000000001', 80, 60, true, now(), v_admin)
  on conflict (event_id, external_id) do nothing;

  foreach v_size in array sizes loop
    group_index := group_index + 1;
    v_parent := ('a0000000-0000-0000-0000-' || lpad(v_size::text, 12, '0'))::uuid;
    v_household_id := ('21000000-0000-0000-0000-' || lpad(group_index::text, 12, '0'))::uuid;
    v_registration_id := ('22000000-0000-0000-0000-' || lpad(group_index::text, 12, '0'))::uuid;
    v_group_id := ('23000000-0000-0000-0000-' || lpad(group_index::text, 12, '0'))::uuid;
    v_plan_id := ('24000000-0000-0000-0000-' || lpad(group_index::text, 12, '0'))::uuid;
    insert into app_private.households(id, label, primary_contact_user_id, phone)
    values (v_household_id, 'Testgezin ' || v_size, v_parent, '0000000000') on conflict (id) do nothing;
    insert into app_private.household_members(household_id, user_id, relation_role) values (v_household_id, v_parent, 'owner') on conflict do nothing;
    insert into app_private.registrations(id, event_id, household_id, status, reference, submitted_at, terms_version, terms_accepted_at, privacy_version, price_snapshot_cents)
    values (v_registration_id, v_event_id, v_household_id, 'submitted', 'FIXTURE-' || v_size, now(), 'test-v1', now(), 'test-v1', v_size * 200)
    on conflict (id) do nothing;
    perform app_private.attach_registration_to_together_party(v_registration_id, null);
    for child_index in 1..v_size loop
      v_child_id := ('2500' || lpad(group_index::text, 4, '0') || '-0000-0000-0000-' || lpad(child_index::text, 12, '0'))::uuid;
      insert into app_private.children(id, household_id, first_name, age_at_event)
      values (v_child_id, v_household_id, 'Testkind ' || child_index, 8 + (child_index % 3)) on conflict (id) do nothing;
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
      values (v_event_id, v_registration_id, v_child_id, 200) on conflict do nothing;
    end loop;
    insert into app_private.payment_requests(registration_id, purpose, amount_cents, reference, status)
    values (v_registration_id, 'event_registration', v_size * 200, 'PAY-FIXTURE-' || v_size, 'confirmed') on conflict (reference) do nothing;
    insert into app_private.walking_groups(id, event_id, code, status, start_slot_id)
    values (v_group_id, v_event_id, 'TEST-' || v_size, 'ready', v_slot_id) on conflict (id) do nothing;
    insert into app_private.group_registrations(group_id, registration_id, published_at, assignment_revision)
    values (v_group_id, v_registration_id, now(), 1) on conflict do nothing;
    insert into app_private.group_leaders(group_id, user_id, active_from, revision, assigned_by)
    values (v_group_id, 'c0000000-0000-0000-0000-000000000001', timestamptz '2026-01-01 00:00:00+01', 1, 'f0000000-0000-0000-0000-000000000001')
    on conflict do nothing;
    insert into app_private.route_plan_versions(id, group_id, revision, state, generated_by, input_hash)
    values (v_plan_id, v_group_id, 1, 'valid', 'f0000000-0000-0000-0000-000000000001', 'fixture-' || v_size)
    on conflict (id) do nothing;
    insert into app_private.route_plan_stops(plan_version_id, position, portal_id, planned_arrival_at, planned_departure_at)
    select v_plan_id, portal_number,
      ('12000000-0000-0000-0000-' || lpad(portal_number::text, 12, '0'))::uuid,
      timestamptz '2026-10-31 18:30:00+01' + make_interval(mins => (portal_number - 1) * 8),
      timestamptz '2026-10-31 18:35:00+01' + make_interval(mins => (portal_number - 1) * 8)
    from generate_series(1, 6) portal_number
    on conflict do nothing;
    update app_private.route_plan_versions set state = 'published', published_at = now() where id = v_plan_id and state = 'valid';
    update app_private.walking_groups set current_plan_version_id = v_plan_id where id = v_group_id;
  end loop;

  -- Een lege groep bewijst dat starten niet op arraygedrag mag vertrouwen.
  insert into app_private.walking_groups(id, event_id, code, status, start_slot_id)
  values ('23000000-0000-0000-0000-000000000099', v_event_id, 'TEST-EMPTY', 'ready', v_slot_id) on conflict (id) do nothing;
  insert into app_private.group_leaders(group_id, user_id, active_from, revision, assigned_by)
  values ('23000000-0000-0000-0000-000000000099', 'c0000000-0000-0000-0000-000000000001', timestamptz '2026-01-01 00:00:00+01', 1, 'f0000000-0000-0000-0000-000000000001')
  on conflict do nothing;
end $$;
