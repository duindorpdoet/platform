-- Actor-aware commands. Every SECURITY DEFINER function has a fixed search_path,
-- derives the actor from auth.uid(), and is explicitly granted per role.

create or replace function app_private.current_event_id(_slug text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from app_private.events where slug = _slug
$$;

create or replace function app_private.has_capability(_event_id uuid, _capability text, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and exists (
    select 1
    from app_private.event_capabilities capability
    where capability.event_id = _event_id
      and capability.user_id = _actor
      and capability.capability = _capability
      and capability.revoked_at is null
  )
$$;

create or replace function app_private.is_household_member(_household_id uuid, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and exists (
    select 1 from app_private.household_members member
    where member.household_id = _household_id
      and member.user_id = _actor
      and member.revoked_at is null
  )
$$;

create or replace function app_private.is_current_leader(_group_id uuid, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and exists (
    select 1 from app_private.group_leaders leader
    where leader.group_id = _group_id
      and leader.user_id = _actor
      and leader.active_from <= now()
      and (leader.active_until is null or leader.active_until > now())
  )
$$;

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into app_private.profiles(user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function app_private.handle_new_user();

create or replace function api.event_public_snapshot(_event_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'slug', event.slug,
    'title', event.title,
    'date', event.local_date,
    'timezone', event.timezone,
    'phase', event.phase,
    'priceCents', event.price_cents,
    'currency', event.currency,
    'registrationOpen', event.phase = 'registration_open'
      and (event.registration_open_at is null or event.registration_open_at <= now())
      and (event.registration_close_at is null or event.registration_close_at > now()),
    'worlds', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', world.slug,
        'name', world.name,
        'story', world.story,
        'artworkPath', world.artwork_path
      ) order by world.sort_order)
      from app_private.worlds world
      where world.event_id = event.id
    ), '[]'::jsonb),
    'sponsors', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', publication.approved_name,
        'logoPath', publication.logo_path,
        'url', publication.website_url
      ) order by publication.sort_order, publication.approved_name)
      from app_private.sponsor_publications publication
      join app_private.sponsor_applications application on application.id = publication.sponsor_application_id
      where application.event_id = event.id
    ), '[]'::jsonb)
  )
  from app_private.events event
  where event.slug = _event_slug
$$;

create or replace function api.my_context(_event_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with selected_event as (
    select id from app_private.events where slug = _event_slug
  )
  select case when auth.uid() is null then null else jsonb_build_object(
    'userId', auth.uid(),
    'households', coalesce((
      select jsonb_agg(jsonb_build_object('id', household.id, 'label', household.label, 'version', household.version))
      from app_private.household_members member
      join app_private.households household on household.id = member.household_id
      where member.user_id = auth.uid() and member.revoked_at is null
    ), '[]'::jsonb),
    'capabilities', coalesce((
      select jsonb_agg(capability.capability order by capability.capability)
      from app_private.event_capabilities capability, selected_event event
      where capability.event_id = event.id and capability.user_id = auth.uid() and capability.revoked_at is null
    ), '[]'::jsonb),
    'portalIds', coalesce((
      select jsonb_agg(owner.portal_id)
      from app_private.portal_owners owner
      join app_private.portals portal on portal.id = owner.portal_id
      join selected_event event on event.id = portal.event_id
      where owner.user_id = auth.uid() and owner.revoked_at is null
    ), '[]'::jsonb),
    'groupIds', coalesce((
      select jsonb_agg(distinct membership.group_id)
      from (
        select leader.group_id
        from app_private.group_leaders leader
        join app_private.walking_groups walking_group on walking_group.id = leader.group_id
        join selected_event event on event.id = walking_group.event_id
        where leader.user_id = auth.uid() and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
        union all
        select group_registration.group_id
        from app_private.household_members household_member
        join app_private.registrations registration on registration.household_id = household_member.household_id
        join app_private.group_registrations group_registration on group_registration.registration_id = registration.id and group_registration.superseded_at is null
        join app_private.walking_groups walking_group on walking_group.id = group_registration.group_id
        join selected_event event on event.id = walking_group.event_id
        where household_member.user_id = auth.uid() and household_member.revoked_at is null
      ) membership
    ), '[]'::jsonb)
  ) end
$$;

create or replace function api.registration_snapshot(_event_slug text)
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
  if v_event_id is null then return null; end if;
  return (
    select jsonb_build_object(
      'household', jsonb_build_object('id', household.id, 'label', household.label, 'phone', household.phone, 'version', household.version),
      'draft', case when draft.id is null then null else jsonb_build_object('payload', draft.payload, 'version', draft.version, 'updatedAt', draft.updated_at) end,
      'registration', case when registration.id is null then null else jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'priceCents', registration.price_snapshot_cents,
        'version', registration.version,
        'payment', (
          select jsonb_build_object('status', payment.status, 'amountCents', payment.amount_cents, 'externalUrl', payment.external_url, 'version', payment.version)
          from app_private.payment_requests payment where payment.registration_id = registration.id order by payment.created_at desc limit 1
        )
      ) end
    )
    from app_private.household_members member
    join app_private.households household on household.id = member.household_id
    left join app_private.registration_drafts draft on draft.household_id = household.id and draft.event_id = v_event_id
    left join app_private.registrations registration on registration.household_id = household.id and registration.event_id = v_event_id and registration.status <> 'cancelled'
    where member.user_id = actor and member.revoked_at is null
    order by member.accepted_at
    limit 1
  );
end;
$$;

create or replace function api.registration_save_draft(
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
  v_event_id uuid;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  adult_name text := nullif(trim(_payload #>> '{adult,name}'), '');
  household_label text := nullif(trim(_payload #>> '{adult,householdLabel}'), '');
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if adult_name is null or household_label is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;

  if v_household_id is null then
    insert into app_private.households(label, primary_contact_user_id, phone)
    values (household_label, actor, nullif(trim(_payload #>> '{adult,phone}'), ''))
    returning id into v_household_id;
    insert into app_private.household_members(household_id, user_id, relation_role) values (v_household_id, actor, 'owner');
  else
    update app_private.households
    set label = household_label,
        phone = nullif(trim(_payload #>> '{adult,phone}'), ''),
        version = version + 1
    where id = v_household_id;
  end if;

  update app_private.profiles set display_name = adult_name, version = version + 1 where user_id = actor;

  insert into app_private.registration_drafts(event_id, household_id, payload)
  values (v_event_id, v_household_id, _payload)
  on conflict (event_id, household_id) do update
    set payload = excluded.payload,
        version = app_private.registration_drafts.version + 1
    where _expected_version is null or app_private.registration_drafts.version = _expected_version
  returning * into draft_record;

  if draft_record.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  return jsonb_build_object('id', draft_record.id, 'version', draft_record.version, 'savedAt', draft_record.updated_at);
end;
$$;

create or replace function api.registration_submit(
  _event_slug text,
  _terms_version text,
  _privacy_version text,
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
  event_record app_private.events;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  registration_record app_private.registrations;
  child jsonb;
  child_count integer;
  total integer;
  receipt app_private.command_receipts;
  actor_email text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if event_record.phase <> 'registration_open'
     or (event_record.registration_open_at is not null and event_record.registration_open_at > now())
     or (event_record.registration_close_at is not null and event_record.registration_close_at <= now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;

  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'registration.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null order by member.accepted_at limit 1;
  if v_household_id is null then raise exception 'HOUSEHOLD_REQUIRED' using errcode = '23514'; end if;

  select * into draft_record from app_private.registration_drafts
  where app_private.registration_drafts.event_id = event_record.id and app_private.registration_drafts.household_id = v_household_id for update;
  if draft_record.id is null then raise exception 'DRAFT_REQUIRED' using errcode = '23514'; end if;
  if jsonb_typeof(draft_record.payload -> 'children') <> 'array' then raise exception 'CHILDREN_REQUIRED' using errcode = '23514'; end if;
  child_count := jsonb_array_length(draft_record.payload -> 'children');
  if child_count < 1 then raise exception 'EMPTY_REGISTRATION' using errcode = '23514'; end if;
  if (select count(*) from app_private.registration_children where event_id = event_record.id and participation_status = 'active') + child_count > coalesce((event_record.settings ->> 'maxChildren')::integer, 300) then
    raise exception 'EVENT_CAPACITY_REACHED' using errcode = '23514';
  end if;
  total := child_count * event_record.price_cents;

  select * into registration_record from app_private.registrations
  where app_private.registrations.event_id = event_record.id and app_private.registrations.household_id = v_household_id and status <> 'cancelled' for update;
  if registration_record.id is null then
    insert into app_private.registrations(
      event_id, household_id, status, reference, submitted_at, terms_version, terms_accepted_at,
      privacy_version, marketing_consent, price_snapshot_cents
    ) values (
      event_record.id, v_household_id, 'submitted',
      upper('DPH-' || extract(year from event_record.local_date)::text || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
      now(), _terms_version, now(), _privacy_version,
      coalesce((draft_record.payload ->> 'marketingConsent')::boolean, false), total
    ) returning * into registration_record;

    for child in select value from jsonb_array_elements(draft_record.payload -> 'children') loop
      if nullif(trim(child ->> 'name'), '') is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
      with inserted_child as (
        insert into app_private.children(household_id, first_name, age_at_event, age_band, accessibility_note)
        values (
          v_household_id,
          trim(child ->> 'name'),
          case when child ->> 'age' ~ '^[0-9]{1,2}$' then (child ->> 'age')::smallint else null end,
          nullif(trim(child ->> 'ageBand'), ''),
          nullif(trim(child ->> 'accessibilityNote'), '')
        ) returning id
      )
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
      select event_record.id, registration_record.id, id, event_record.price_cents from inserted_child;
    end loop;

    insert into app_private.payment_requests(registration_id, purpose, amount_cents, reference, status)
    values (registration_record.id, 'event_registration', total, registration_record.reference, 'awaiting_link');

    select email into actor_email from auth.users where id = actor;
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'registration:' || registration_record.id::text || ':received:' || actor::text,
      'registration_received', actor::text, actor_email,
      jsonb_build_object('reference', registration_record.reference, 'childCount', child_count, 'amountCents', total, 'paymentStatus', 'awaiting_link')
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, actor, 'registration.submitted', 'registration', registration_record.id, jsonb_build_object('childCount', child_count, 'amountCents', total));
  end if;

  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'registration.submit', _idempotency_key, _request_hash,
    jsonb_build_object('id', registration_record.id, 'reference', registration_record.reference, 'status', registration_record.status, 'priceCents', registration_record.price_snapshot_cents),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$$;

create or replace function api.registration_report_payment(_registration_id uuid, _expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  payment app_private.payment_requests;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not exists (
    select 1 from app_private.registrations registration
    where registration.id = _registration_id and app_private.is_household_member(registration.household_id, actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.payment_requests
  set status = case when status in ('awaiting_link', 'awaiting_payment') then 'reported' else status end,
      version = version + 1
  where registration_id = _registration_id and version = _expected_version
  returning * into payment;
  if payment.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  insert into app_private.payment_entries(request_id, amount_cents, entry_type, reason)
  values (payment.id, 0, 'reported', 'Gemeld door deelnemer; nog niet gecontroleerd.');
  return jsonb_build_object('status', payment.status, 'version', payment.version);
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
  v_event_id uuid;
  application app_private.portal_applications;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into application from app_private.portal_applications
  where app_private.portal_applications.event_id = v_event_id and applicant_user_id = actor and review_status in ('draft', 'changes_requested')
  order by created_at desc limit 1 for update;
  if application.id is null then
    insert into app_private.portal_applications(event_id, applicant_user_id, private_draft_data)
    values (v_event_id, actor, _payload) returning * into application;
  else
    if _expected_version is not null and application.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.portal_applications set private_draft_data = _payload, version = version + 1
    where id = application.id returning * into application;
  end if;
  return jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version, 'savedAt', application.updated_at);
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
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'portal.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  update app_private.portal_applications
  set review_status = 'submitted', submitted_at = now(), version = version + 1
  where id = _application_id and applicant_user_id = actor and review_status in ('draft', 'changes_requested') and version = _expected_version
  returning * into application;
  if application.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if nullif(trim(application.private_draft_data #>> '{address,street}'), '') is null
     or nullif(trim(application.private_draft_data #>> '{address,houseNumber}'), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select email into actor_email from auth.users where id = actor;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values ('portal:' || application.id::text || ':received', 'portal_received', actor::text, actor_email, jsonb_build_object('applicationId', application.id));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (application.event_id, actor, 'portal_application.submitted', 'portal_application', application.id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'portal.submit', _idempotency_key, _request_hash, jsonb_build_object('id', application.id, 'status', application.review_status, 'version', application.version), now() + interval '30 days')
  returning * into receipt;
  return receipt.safe_result;
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
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  leader := app_private.is_current_leader(_group_id, actor);
  support := app_private.has_capability(group_record.event_id, 'live_support', actor) or app_private.has_capability(group_record.event_id, 'groups_manage', actor);
  select exists (
    select 1
    from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
    join app_private.group_registrations assignment on assignment.registration_id = registration.id
    where member.user_id = actor and member.revoked_at is null and assignment.group_id = _group_id and assignment.superseded_at is null
  ) into household_access;
  if not (leader or support or household_access) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select * into run_record from app_private.group_runs
  where group_id = _group_id order by created_at desc limit 1;

  return jsonb_build_object(
    'group', jsonb_build_object(
      'id', group_record.id,
      'code', group_record.code,
      'status', group_record.status,
      'version', group_record.version,
      'start', (
        select jsonb_build_object('name', slot.name, 'locationName', slot.location_name, 'startsAt', slot.starts_at)
        from app_private.start_slots slot where slot.id = group_record.start_slot_id
      )
    ),
    'access', jsonb_build_object('leader', leader, 'support', support),
    'run', case when run_record.id is null then null else jsonb_build_object(
      'id', run_record.id,
      'status', run_record.status,
      'version', run_record.version,
      'lastServerConfirmation', run_record.updated_at,
      'remainingStopCount', (
        select count(*) from app_private.run_stops stop where stop.run_id = run_record.id and stop.state = 'locked'
      ),
      'currentStop', (
        select jsonb_build_object(
          'id', stop.id,
          'version', stop.version,
          'sequence', stop.sequence,
          'openedAt', stop.opened_at,
          'portal', jsonb_build_object(
            'name', portal.name,
            'description', portal.description,
            'intensity', portal.intensity,
            'operationStatus', portal.operation_status,
            'world', world.name,
            'address', concat_ws(' ', location.street, location.house_number, location.addition),
            'postalCode', location.postal_code,
            'coordinate', case when location.latitude is null then null else jsonb_build_array(location.longitude, location.latitude) end
          ),
          'scanAccepted', exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
        )
        from app_private.run_stops stop
        join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = plan_stop.portal_id
        join app_private.worlds world on world.id = portal.world_id
        join app_private.portal_private_locations location on location.portal_id = portal.id
        where stop.id = run_record.current_stop_id and stop.state = 'active'
      ),
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', participant.id,
          'firstName', child.first_name,
          'attendance', participant.attendance,
          'rosterVersion', participant.roster_version,
          'isOwnChild', app_private.is_household_member(child.household_id, actor),
          'status', status.status,
          'statusVersion', status.version,
          'required', status.required_for_completion
        ) order by child.first_name)
        from app_private.run_participants participant
        join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
        join app_private.children child on child.id = registration_child.child_id
        left join app_private.stop_participant_statuses status on status.run_participant_id = participant.id and status.run_stop_id = run_record.current_stop_id
        where participant.run_id = run_record.id
          and (leader or support or app_private.is_household_member(child.household_id, actor))
      ), '[]'::jsonb),
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'sequence', stop.sequence,
          'outcome', stop.outcome,
          'completedAt', stop.completed_at,
          'portalName', portal.name,
          'world', world.name
        ) order by stop.sequence)
        from app_private.run_stops stop
        join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = plan_stop.portal_id
        join app_private.worlds world on world.id = portal.world_id
        where stop.run_id = run_record.id and stop.state = 'completed'
      ), '[]'::jsonb)
    ) end
  );
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
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(array_length(_present_registration_child_ids, 1), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  select id into plan_id from app_private.route_plan_versions where group_id = _group_id and state = 'published' order by revision desc limit 1;
  if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  insert into app_private.group_runs(group_id, active_plan_version_id, status, started_at)
  values (_group_id, plan_id, 'live', now()) returning id into v_run_id;
  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids) then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null and registration_child.participation_status = 'active';
  insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
  select v_run_id, stop.id, stop.position,
    case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
    case when stop.position = 1 then now() else null end
  from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
  select id into first_stop_id from app_private.run_stops where app_private.run_stops.run_id = v_run_id and sequence = 1;
  if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
  update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
  insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
  select first_stop_id, participant.id from app_private.run_participants participant where participant.run_id = v_run_id and participant.attendance = 'present';
  update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id) values (v_run_id, first_stop_id, 'run.started', actor);
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, jsonb_build_object('runId', v_run_id), now() + interval '2 days') returning * into receipt;
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
  join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = plan_stop.portal_id
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    and portal.operation_status = 'open'
    and credential.revoked_at is null
    and credential.valid_from <= now()
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

create or replace function api.run_update_participant(
  _run_id uuid,
  _stop_id uuid,
  _run_participant_id uuid,
  _new_status app_private.participant_stop_status,
  _expected_run_version integer,
  _expected_status_version integer,
  _reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  status_record app_private.stop_participant_statuses;
  participant_household uuid;
  leader boolean;
  own_child boolean;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  select status.* into status_record
  from app_private.stop_participant_statuses status
  where status.run_stop_id = _stop_id and status.run_participant_id = _run_participant_id for update;
  if status_record.id is null or status_record.version <> _expected_status_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select child.household_id into participant_household
  from app_private.run_participants participant
  join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
  join app_private.children child on child.id = registration_child.child_id
  where participant.id = _run_participant_id;
  leader := app_private.is_current_leader(run_record.group_id, actor);
  own_child := app_private.is_household_member(participant_household, actor);
  if not leader and not own_child then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _new_status = 'visited' then
    if not leader then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'skipped' then
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if leader and nullif(trim(_reason), '') is null then raise exception 'PARENT_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'pending' then
    if not own_child or status_record.status <> 'skipped' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  end if;
  update app_private.stop_participant_statuses
  set status = _new_status, version = version + 1, changed_by = actor, reason = _reason,
      decided_at = case when _new_status = 'pending' then null else now() end
  where id = status_record.id returning * into status_record;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participant.' || _new_status::text, actor, jsonb_build_object('runParticipantId', _run_participant_id));
  return jsonb_build_object('id', status_record.id, 'status', status_record.status, 'version', status_record.version);
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

create or replace function api.run_mark_departed(
  _run_id uuid,
  _stop_id uuid,
  _run_participant_id uuid,
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
  remaining integer;
begin
  if nullif(trim(_reason), '') is null then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) and not app_private.has_capability((select event_id from app_private.walking_groups where id = run_record.group_id), 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.run_participants set attendance = 'departed', departed_at = now(), roster_version = roster_version + 1
  where id = _run_participant_id and run_id = _run_id and attendance = 'present';
  if not found then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;
  update app_private.stop_participant_statuses set required_for_completion = false, exclusion_reason = 'departed', reason = _reason, version = version + 1, changed_by = actor
  where run_stop_id = _stop_id and run_participant_id = _run_participant_id;
  update app_private.group_runs set version = version + 1 where id = _run_id returning * into run_record;
  select count(*) into remaining from app_private.run_participants where run_id = _run_id and attendance = 'present';
  if remaining = 0 then
    update app_private.group_runs set status = 'stopped', stopped_reason = 'all_participants_departed', finished_at = now(), current_stop_id = null, version = version + 1 where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'stopped', version = version + 1 where id = run_record.group_id;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participant.departed', actor, jsonb_build_object('runParticipantId', _run_participant_id, 'reason', left(_reason, 200)));
  return jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'remainingParticipants', remaining);
end;
$$;

create or replace function api.portal_set_operational_state(_portal_id uuid, _state app_private.portal_operation_status, _expected_version integer, _reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
begin
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not exists (select 1 from app_private.portal_owners owner where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null)
     and not app_private.has_capability(portal.event_id, 'portals_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if portal.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  update app_private.portals set operation_status = _state, version = version + 1 where id = _portal_id returning * into portal;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.operation_state_changed', 'portal', portal.id, jsonb_build_object('state', _state, 'reason', left(coalesce(_reason, ''), 200)));
  return jsonb_build_object('id', portal.id, 'state', portal.operation_status, 'version', portal.version);
end;
$$;

create or replace function api.payment_confirm(
  _payment_request_id uuid,
  _amount_cents integer,
  _external_reference text,
  _reason text,
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
  payment app_private.payment_requests;
  registration app_private.registrations;
  receipt app_private.command_receipts;
begin
  select * into receipt from app_private.command_receipts where actor_id = actor and command_type = 'payment.confirm' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  select * into payment from app_private.payment_requests where id = _payment_request_id for update;
  if payment.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into registration from app_private.registrations where id = payment.registration_id;
  if registration.id is null or not app_private.has_capability(registration.event_id, 'payments_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _amount_cents <= 0 or nullif(trim(_reason), '') is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
  values (payment.id, _amount_cents, 'payment', actor, now(), _external_reference, _reason);
  update app_private.payment_requests
  set status = case when _amount_cents = amount_cents then 'confirmed'::app_private.payment_status when _amount_cents < amount_cents then 'partial'::app_private.payment_status else 'refund_due'::app_private.payment_status end,
      version = version + 1
  where id = payment.id returning * into payment;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'payment.confirmed', 'payment_request', payment.id, jsonb_build_object('amountCents', _amount_cents));
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'payment.confirm', _idempotency_key, _request_hash, jsonb_build_object('id', payment.id, 'status', payment.status, 'version', payment.version), now() + interval '1 year')
  returning * into receipt;
  return receipt.safe_result;
end;
$$;

create or replace function api.submit_public_contact(
  _event_slug text,
  _sender_name text,
  _sender_email text,
  _subject text,
  _body text,
  _opaque_subject_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  bucket_count integer;
  message_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if char_length(trim(_sender_name)) not between 1 and 120 or char_length(trim(_subject)) not between 3 and 160 or char_length(trim(_body)) not between 3 and 4000 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, count, expires_at)
  values ('contact', _opaque_subject_hash, date_trunc('hour', now()), 1, date_trunc('hour', now()) + interval '2 hours')
  on conflict (scope, opaque_subject_hash, window_start) do update set count = app_private.rate_limit_buckets.count + 1
  returning count into bucket_count;
  if bucket_count > 5 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;
  insert into app_private.contact_messages(event_id, sender_name, sender_email, subject, body)
  values (v_event_id, trim(_sender_name), lower(trim(_sender_email)), trim(_subject), trim(_body)) returning id into message_id;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values ('contact:' || message_id::text || ':received', 'contact_received', message_id::text, lower(trim(_sender_email)), jsonb_build_object('ticketReference', message_id, 'subject', trim(_subject)));
  return jsonb_build_object('reference', message_id, 'stored', true);
end;
$$;

create or replace function api.submit_public_sponsor(
  _event_slug text,
  _contact_name text,
  _contact_email text,
  _contribution_type text,
  _proposed_amount_cents integer,
  _message text,
  _opaque_subject_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  bucket_count integer;
  application_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if char_length(trim(_contact_name)) not between 1 and 120 or _proposed_amount_cents < 0 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, count, expires_at)
  values ('sponsor', _opaque_subject_hash, date_trunc('day', now()), 1, date_trunc('day', now()) + interval '2 days')
  on conflict (scope, opaque_subject_hash, window_start) do update set count = app_private.rate_limit_buckets.count + 1
  returning count into bucket_count;
  if bucket_count > 3 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;
  insert into app_private.sponsor_applications(event_id, contact_name, contact_email, contribution_type, proposed_amount_cents, message)
  values (v_event_id, trim(_contact_name), lower(trim(_contact_email)), trim(_contribution_type), _proposed_amount_cents, nullif(trim(_message), '')) returning id into application_id;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values ('sponsor:' || application_id::text || ':received', 'sponsor_received', application_id::text, lower(trim(_contact_email)), jsonb_build_object('applicationReference', application_id));
  return jsonb_build_object('reference', application_id, 'stored', true);
end;
$$;

create or replace function api.worker_claim_outbox(_batch_size integer, _lease_seconds integer)
returns setof app_private.email_outbox
language plpgsql
security definer
set search_path = ''
as $$
begin
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

create or replace function api.worker_update_outbox(
  _id uuid,
  _status app_private.outbox_status,
  _provider_id text default null,
  _error_code text default null,
  _next_attempt_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app_private.email_outbox
  set status = _status,
      provider_id = coalesce(_provider_id, provider_id),
      last_error_code = _error_code,
      next_attempt_at = coalesce(_next_attempt_at, next_attempt_at),
      lease_until = null
  where id = _id;
end;
$$;

create or replace function api.worker_store_email_event(
  _provider_event_id text,
  _outbox_id uuid,
  _kind text,
  _occurred_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted boolean;
begin
  insert into app_private.email_events(provider, provider_event_id, outbox_id, kind, occurred_at)
  values ('sendgrid', _provider_event_id, _outbox_id, _kind, _occurred_at)
  on conflict (provider, provider_event_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted and _outbox_id is not null then
    update app_private.email_outbox
    set status = case
      when _kind = 'delivered' then 'delivered'::app_private.outbox_status
      when _kind in ('bounce', 'dropped', 'spamreport') then 'failed'::app_private.outbox_status
      when _kind = 'deferred' and status not in ('delivered', 'failed') then 'deferred'::app_private.outbox_status
      else status
    end
    where id = _outbox_id;
  end if;
  return inserted;
end;
$$;

revoke execute on all functions in schema app_private from public, anon, authenticated;
revoke execute on all functions in schema api from public, anon, authenticated;

grant execute on function api.event_public_snapshot(text) to anon, authenticated;
grant execute on function api.my_context(text) to authenticated;
grant execute on function api.registration_snapshot(text) to authenticated;
grant execute on function api.registration_save_draft(text, jsonb, integer) to authenticated;
grant execute on function api.registration_submit(text, text, text, text, text) to authenticated;
grant execute on function api.registration_report_payment(uuid, integer) to authenticated;
grant execute on function api.portal_application_save(text, jsonb, integer) to authenticated;
grant execute on function api.portal_application_submit(uuid, integer, text, text) to authenticated;
grant execute on function api.group_snapshot(uuid) to authenticated;
grant execute on function api.run_start(uuid, uuid[], integer, text, text) to authenticated;
grant execute on function api.run_scan(uuid, uuid, integer, text, text) to authenticated;
grant execute on function api.run_update_participant(uuid, uuid, uuid, app_private.participant_stop_status, integer, integer, text) to authenticated;
grant execute on function api.run_complete_stop(uuid, uuid, integer, boolean, text, text) to authenticated;
grant execute on function api.run_mark_departed(uuid, uuid, uuid, integer, text) to authenticated;
grant execute on function api.portal_set_operational_state(uuid, app_private.portal_operation_status, integer, text) to authenticated;
grant execute on function api.payment_confirm(uuid, integer, text, text, text, text) to authenticated;

grant execute on function api.submit_public_contact(text, text, text, text, text, text) to service_role;
grant execute on function api.submit_public_sponsor(text, text, text, text, integer, text, text) to service_role;
grant execute on function api.worker_claim_outbox(integer, integer) to service_role;
grant execute on function api.worker_update_outbox(uuid, app_private.outbox_status, text, text, timestamptz) to service_role;
grant execute on function api.worker_store_email_event(text, uuid, text, timestamptz) to service_role;
