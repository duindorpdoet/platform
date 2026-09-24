-- Simplify house onboarding to the three verified contact fields while
-- retaining the operational checks that make an approved route location safe.

insert into app_private.worlds(event_id, slug, name, story, artwork_path, sort_order)
select
  event.id,
  'anders',
  'Anders… alleen snoep uitdelen',
  'Voor bewoners die zonder thema graag alleen een snoepje uitdelen.',
  null,
  coalesce((select max(existing.sort_order) + 1 from app_private.worlds existing where existing.event_id = event.id), 1)
from app_private.events event
on conflict (event_id, slug) do update
set name = excluded.name,
    story = excluded.story,
    artwork_path = excluded.artwork_path;

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
  normalized_postal_code text := upper(replace(trim(coalesce(_postal_code, '')), ' ', ''));
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
     or (nullif(trim(coalesce(_street, '')), '') is not null and char_length(trim(_street)) not between 2 and 120)
     or (nullif(trim(coalesce(_house_number, '')), '') is not null and char_length(trim(_house_number)) not between 1 and 12)
     or char_length(coalesce(trim(_addition), '')) > 12
     or (normalized_postal_code <> '' and normalized_postal_code !~ '^[0-9]{4}[A-Z]{2}$')
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
    jsonb_strip_nulls(jsonb_build_object(
      'street', nullif(trim(coalesce(_street, '')), ''),
      'houseNumber', nullif(trim(coalesce(_house_number, '')), ''),
      'addition', nullif(trim(coalesce(_addition, '')), ''),
      'postalCode', nullif(normalized_postal_code, '')
    ))
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
  world_slug text;
  contact_name text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select lower(trim(email)) into verified_email from auth.users where id = actor and email_confirmed_at is not null;
  if verified_email is null then raise exception 'EMAIL_NOT_CONFIRMED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or pg_column_size(_payload) > 65536 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  world_slug := lower(coalesce(nullif(trim(_payload ->> 'requestedWorldSlug'), ''), 'anders'));
  contact_name := coalesce(nullif(trim(_payload ->> 'contactName'), ''), 'bewoner');
  _payload := _payload || jsonb_build_object(
    'email', verified_email,
    'address', case when jsonb_typeof(_payload -> 'address') = 'object' then _payload -> 'address' else '{}'::jsonb end,
    'requestedWorldSlug', world_slug,
    'portalName', case
      when world_slug = 'anders' and nullif(trim(_payload ->> 'portalName'), '') is null
        then left('Snoeppunt van ' || contact_name, 120)
      else coalesce(_payload ->> 'portalName', '')
    end,
    'description', case
      when world_slug = 'anders' and nullif(trim(_payload ->> 'description'), '') is null
        then 'Hier delen we tijdens de avond graag een snoepje uit.'
      else coalesce(_payload ->> 'description', '')
    end,
    'intensity', case
      when coalesce(_payload ->> 'intensity', '') ~ '^[1-4]$' then _payload ->> 'intensity'
      when world_slug = 'anders' then '1'
      else '2'
    end,
    'warnings', case
      when jsonb_typeof(_payload -> 'warnings') = 'object' then _payload -> 'warnings'
      else jsonb_build_object('smoke', false, 'flashes', false, 'sound', false, 'actors', false, 'allergens', false)
    end,
    'availableFrom', coalesce(nullif(trim(_payload ->> 'availableFrom'), ''), '17:00'),
    'availableUntil', coalesce(nullif(trim(_payload ->> 'availableUntil'), ''), '21:00'),
    'accessibility', coalesce(_payload ->> 'accessibility', ''),
    'entrance', coalesce(_payload ->> 'entrance', ''),
    'availability', case when jsonb_typeof(_payload -> 'availability') = 'boolean' then _payload -> 'availability' else 'true'::jsonb end,
    'locationConsent', case when jsonb_typeof(_payload -> 'locationConsent') = 'boolean' then _payload -> 'locationConsent' else 'false'::jsonb end
  );

  perform pg_advisory_xact_lock(hashtextextended(event_record.id::text || ':portal-account:' || actor::text, 0));
  select * into application from app_private.portal_applications
  where event_id = event_record.id and applicant_user_id = actor
  order by (review_status not in ('withdrawn', 'rejected')) desc, created_at desc
  limit 1 for update;
  if application.id is null and not coalesce((event_record.settings ->> 'portalRegistrationOpen')::boolean, false) then
    raise exception 'PORTAL_REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;

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
  postal_code text;
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

  select lower(trim(email)) into actor_email from auth.users where id = actor and email_confirmed_at is not null;
  draft := application.private_draft_data;
  postal_code := upper(replace(trim(coalesce(draft #>> '{address,postalCode}', '')), ' ', ''));
  select world.id into v_world_id from app_private.worlds world
  where world.event_id = application.event_id and world.slug = lower(trim(draft ->> 'requestedWorldSlug'));
  if actor_email is null
     or lower(trim(coalesce(draft ->> 'email', ''))) <> actor_email
     or char_length(trim(coalesce(draft ->> 'contactName', ''))) not between 2 and 120
     or char_length(trim(coalesce(draft ->> 'phone', ''))) not between 6 and 32
     or (nullif(trim(coalesce(draft #>> '{address,street}', '')), '') is not null
       and char_length(trim(draft #>> '{address,street}')) not between 2 and 120)
     or (nullif(trim(coalesce(draft #>> '{address,houseNumber}', '')), '') is not null
       and char_length(trim(draft #>> '{address,houseNumber}')) not between 1 and 12)
     or char_length(trim(coalesce(draft #>> '{address,addition}', ''))) > 12
     or (postal_code <> '' and postal_code !~ '^[0-9]{4}[A-Z]{2}$')
     or char_length(trim(coalesce(draft ->> 'entrance', ''))) > 500
     or (nullif(trim(coalesce(draft ->> 'portalName', '')), '') is not null
       and char_length(trim(draft ->> 'portalName')) not between 2 and 120)
     or char_length(trim(coalesce(draft ->> 'description', ''))) > 1000
     or coalesce(draft ->> 'intensity', '') !~ '^[1-4]$'
     or v_world_id is null
     or coalesce(draft ->> 'availableFrom', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'availableUntil', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or coalesce(draft ->> 'accessibility', '') not in ('', 'step_free', 'steps', 'mixed', 'unknown')
     or coalesce(jsonb_typeof(draft -> 'warnings'), '') <> 'object'
     or (draft ->> 'availableUntil')::time <= (draft ->> 'availableFrom')::time then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  update app_private.portal_applications
  set review_status = 'submitted', requested_world_id = v_world_id, review_feedback = null,
      submitted_at = now(), reviewed_by = null, reviewed_at = null, version = version + 1
  where id = application.id returning * into application;
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

alter function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  set schema app_private;
alter function app_private.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  rename to admin_review_portal_application_before_house_requirements;

revoke all on function app_private.admin_review_portal_application_before_house_requirements(uuid, integer, text, text, numeric, numeric, text)
  from public, anon, authenticated;

create function api.admin_review_portal_application(
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
begin
  select * into application from app_private.portal_applications where id = _application_id;
  if application.id is null or not app_private.has_capability(application.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _decision = 'approved'
     and (
       coalesce(application.private_draft_data -> 'availability', 'false'::jsonb) <> 'true'::jsonb
       or coalesce(application.private_draft_data -> 'locationConsent', 'false'::jsonb) <> 'true'::jsonb
     ) then
    raise exception 'INCOMPLETE_APPLICATION' using errcode = '23514';
  end if;
  return app_private.admin_review_portal_application_before_house_requirements(
    _application_id, _expected_version, _decision, _world_slug,
    _latitude, _longitude, _reason
  );
end;
$$;

revoke all on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  from public, anon;
grant execute on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  to authenticated;

comment on function api.portal_registration_begin(text, text, text, text, text, text, text, text, text)
  is 'Creates a private pre-OTP house intake. Only email, contact name and phone are mandatory.';
comment on function api.portal_application_submit(uuid, integer, text, text)
  is 'Submits a house application with verified email, contact name and phone; operational details remain optional until approval.';
