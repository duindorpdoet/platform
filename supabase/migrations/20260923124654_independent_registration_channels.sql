-- Group registrations and portal applications have separate, audited release
-- controls. Existing production behaviour is preserved: groups start closed,
-- while homes and neighbourhood businesses can already apply.
update app_private.events
set settings = settings || jsonb_build_object(
      'groupRegistrationOpen', coalesce((settings ->> 'groupRegistrationOpen')::boolean, (settings ->> 'registrationPublished')::boolean, false),
      'portalRegistrationOpen', coalesce((settings ->> 'portalRegistrationOpen')::boolean, true)
    ),
    settings_version = settings_version + 1
where not (settings ? 'groupRegistrationOpen')
   or not (settings ? 'portalRegistrationOpen');

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
    'registrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
      and (event.registration_open_at is null or event.registration_open_at <= now())
      and (event.registration_close_at is null or event.registration_close_at > now()),
    'groupRegistrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
      and (event.registration_open_at is null or event.registration_open_at <= now())
      and (event.registration_close_at is null or event.registration_close_at > now()),
    'portalRegistrationOpen', coalesce((event.settings ->> 'portalRegistrationOpen')::boolean, true),
    'worlds', coalesce((select jsonb_agg(jsonb_build_object('slug', world.slug, 'name', world.name, 'story', world.story, 'artworkPath', world.artwork_path) order by world.sort_order)
      from app_private.worlds world where world.event_id = event.id), '[]'::jsonb),
    'sponsors', coalesce((select jsonb_agg(jsonb_build_object('name', publication.approved_name, 'logoPath', publication.logo_path, 'url', publication.website_url) order by publication.sort_order, publication.approved_name)
      from app_private.sponsor_publications publication join app_private.sponsor_applications application on application.id = publication.sponsor_application_id where application.event_id = event.id), '[]'::jsonb),
    'content', coalesce((select jsonb_object_agg(content.page_key, content.structured_content order by content.page_key)
      from app_private.content_versions content where content.event_id = event.id and content.locale = 'nl-NL' and content.status = 'published'), '{}'::jsonb)
  ) from app_private.events event where event.slug = _event_slug
$$;

create or replace function api.admin_dashboard(_event_slug text)
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
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'registration_manage', actor)
    or app_private.has_capability(v_event_id, 'portals_manage', actor)
    or app_private.has_capability(v_event_id, 'groups_manage', actor)
    or app_private.has_capability(v_event_id, 'live_support', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'event', (select jsonb_build_object(
      'id', id,
      'title', title,
      'phase', phase,
      'date', local_date,
      'settingsVersion', settings_version,
      'groupRegistrationOpen', coalesce((settings ->> 'groupRegistrationOpen')::boolean, false),
      'portalRegistrationOpen', coalesce((settings ->> 'portalRegistrationOpen')::boolean, true)
    ) from app_private.events where id = v_event_id),
    'counts', jsonb_build_object(
      'registrations', (select count(*) from app_private.registrations where event_id = v_event_id and status = 'submitted'),
      'children', (select count(*) from app_private.registration_children where event_id = v_event_id and participation_status = 'active'),
      'portalApplications', (select count(*) from app_private.portal_applications where event_id = v_event_id and review_status = 'submitted'),
      'approvedPortals', (select count(*) from app_private.portals where event_id = v_event_id and approval_status = 'approved'),
      'groups', (select count(*) from app_private.walking_groups where event_id = v_event_id),
      'liveGroups', (select count(*) from app_private.walking_groups where event_id = v_event_id and status = 'live'),
      'openSupportCases', (select count(*) from app_private.support_cases where event_id = v_event_id and status in ('open', 'acknowledged')),
      'unconfirmedPayments', (select count(*) from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.event_id = v_event_id and payment.status not in ('confirmed', 'waived', 'refunded'))
    ),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('id', batch.id, 'kind', batch.kind, 'dryRun', batch.dry_run, 'status', batch.status, 'createdAt', batch.created_at) order by batch.created_at desc) from (select * from app_private.import_batches where event_id = v_event_id order by created_at desc limit 10) batch), '[]'::jsonb),
    'recentActivity', coalesce((select jsonb_agg(jsonb_build_object('action', audit.action, 'resourceType', audit.resource_type, 'createdAt', audit.created_at) order by audit.created_at desc) from (select * from app_private.audit_events where event_id = v_event_id order by created_at desc limit 20) audit), '[]'::jsonb)
  );
end;
$$;

create or replace function api.admin_set_registration_channel(
  _event_slug text,
  _channel text,
  _open boolean,
  _expected_settings_version integer,
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
  setting_key text;
  previous_value boolean;
begin
  if _channel not in ('groups', 'portals')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or (_channel = 'groups' and app_private.has_capability(event_record.id, 'registration_manage', actor))
    or (_channel = 'portals' and app_private.has_capability(event_record.id, 'portals_manage', actor))
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.settings_version <> _expected_settings_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  setting_key := case when _channel = 'groups' then 'groupRegistrationOpen' else 'portalRegistrationOpen' end;
  previous_value := coalesce((event_record.settings ->> setting_key)::boolean, _channel = 'portals');
  update app_private.events
  set settings = settings || jsonb_build_object(setting_key, _open),
      settings_version = settings_version + 1
  where id = event_record.id
  returning * into event_record;

  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    event_record.id,
    actor,
    'registration_channel.updated',
    'event',
    event_record.id,
    jsonb_build_object('channel', _channel, 'from', previous_value, 'to', _open, 'reason', left(trim(_reason), 500))
  );

  return jsonb_build_object(
    'settingsVersion', event_record.settings_version,
    'groupRegistrationOpen', coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false),
    'portalRegistrationOpen', coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, true)
  );
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
  if not coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false)
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
  registrations_open boolean;
  verified_email text;
  application app_private.portal_applications;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select email into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select id, coalesce((settings ->> 'portalRegistrationOpen')::boolean, true)
  into v_event_id, registrations_open
  from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not registrations_open then raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001'; end if;
  if jsonb_typeof(_payload) <> 'object' then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  _payload := _payload || jsonb_build_object('email', verified_email);
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
  registrations_open boolean;
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
  select coalesce((event.settings ->> 'portalRegistrationOpen')::boolean, true)
  into registrations_open from app_private.events event where event.id = application.event_id;
  if not registrations_open then raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001'; end if;
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

create or replace function api.configure_release_mode(_event_slug text, _mode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare event_record app_private.events;
begin
  if _mode not in ('staging_test_open', 'production_closed') then raise exception 'INVALID_MODE' using errcode = '22023'; end if;
  update app_private.events
  set phase = case when _mode = 'staging_test_open' then 'registration_open'::app_private.event_phase else 'draft'::app_private.event_phase end,
      registration_open_at = case when _mode = 'staging_test_open' then now() - interval '1 minute' else null end,
      registration_close_at = case when _mode = 'staging_test_open' then make_timestamptz(extract(year from local_date)::integer, 10, 25, 23, 59, 0, timezone) else null end,
      settings = settings
        || jsonb_build_object('registrationPublished', _mode = 'staging_test_open', 'releaseMode', _mode)
        || case when _mode = 'staging_test_open'
          then jsonb_build_object('groupRegistrationOpen', true, 'portalRegistrationOpen', true)
          else '{}'::jsonb
        end,
      settings_version = settings_version + 1
  where slug = _event_slug returning * into event_record;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into app_private.audit_events(event_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, 'release.mode_configured', 'event', event_record.id, jsonb_build_object('mode', _mode));
  return jsonb_build_object(
    'phase', event_record.phase,
    'registrationPublished', event_record.settings -> 'registrationPublished',
    'groupRegistrationOpen', event_record.settings -> 'groupRegistrationOpen',
    'portalRegistrationOpen', event_record.settings -> 'portalRegistrationOpen'
  );
end;
$$;

revoke execute on function api.admin_set_registration_channel(text, text, boolean, integer, text) from public, anon, authenticated;
grant execute on function api.admin_set_registration_channel(text, text, boolean, integer, text) to authenticated;

revoke execute on function api.configure_release_mode(text, text) from public, anon, authenticated;
grant execute on function api.configure_release_mode(text, text) to service_role;
