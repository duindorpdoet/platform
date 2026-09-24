-- A house can be approved once the organisation can identify and contact the
-- resident and has a complete address. Operational decoration and preferences
-- can be completed after approval.

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
  applicant_email text;
  draft jsonb;
  address jsonb;
  contact_name text;
  phone text;
  street text;
  house_number text;
  postal_code text;
  world_slug text;
  available_from text;
  available_until text;
begin
  select application_record.*
  into application
  from app_private.portal_applications application_record
  where application_record.id = _application_id
  for update of application_record;

  if application.id is null
     or not app_private.has_capability(application.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  select lower(trim(users.email))
  into applicant_email
  from auth.users users
  where users.id = application.applicant_user_id
    and users.email_confirmed_at is not null;

  if _decision <> 'approved' then
    return app_private.admin_review_portal_application_before_house_requirements(
      _application_id, _expected_version, _decision, _world_slug,
      _latitude, _longitude, _reason
    );
  end if;

  draft := application.private_draft_data;
  address := case
    when jsonb_typeof(draft -> 'address') = 'object' then draft -> 'address'
    else '{}'::jsonb
  end;
  contact_name := nullif(trim(draft ->> 'contactName'), '');
  phone := nullif(trim(draft ->> 'phone'), '');
  street := nullif(trim(address ->> 'street'), '');
  house_number := nullif(trim(address ->> 'houseNumber'), '');
  postal_code := upper(replace(trim(coalesce(address ->> 'postalCode', '')), ' ', ''));

  if applicant_email is null
     or applicant_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or char_length(applicant_email) > 320
     or contact_name is null or char_length(contact_name) not between 2 and 120
     or phone is null or char_length(phone) not between 6 and 32
     or street is null or char_length(street) not between 2 and 120
     or house_number is null or char_length(house_number) not between 1 and 12
     or postal_code !~ '^[0-9]{4}[A-Z]{2}$' then
    raise exception 'CONTACT_ADDRESS_REQUIRED' using errcode = '23514';
  end if;

  world_slug := lower(coalesce(
    nullif(trim(_world_slug), ''),
    nullif(trim(draft ->> 'requestedWorldSlug'), ''),
    'anders'
  ));
  available_from := coalesce(nullif(trim(draft ->> 'availableFrom'), ''), '17:00');
  available_until := coalesce(nullif(trim(draft ->> 'availableUntil'), ''), '21:00');
  if available_from !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or available_until !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    available_from := '17:00';
    available_until := '21:00';
  elsif available_until::time <= available_from::time then
    available_from := '17:00';
    available_until := '21:00';
  end if;

  draft := draft || jsonb_build_object(
    'email', applicant_email,
    'contactName', contact_name,
    'phone', phone,
    'address', address || jsonb_build_object(
      'street', street,
      'houseNumber', house_number,
      'postalCode', postal_code
    ),
    'requestedWorldSlug', world_slug,
    'portalName', coalesce(
      nullif(trim(draft ->> 'portalName'), ''),
      case when world_slug = 'anders'
        then left('Snoeppunt van ' || contact_name, 120)
        else left('Poort van ' || contact_name, 120)
      end
    ),
    'description', coalesce(
      nullif(trim(draft ->> 'description'), ''),
      case when world_slug = 'anders'
        then 'Hier delen we tijdens de avond graag een snoepje uit.'
        else 'Meer informatie over deze poort volgt.'
      end
    ),
    'intensity', case
      when coalesce(draft ->> 'intensity', '') ~ '^[1-4]$' then draft ->> 'intensity'
      else '1'
    end,
    'warnings', case
      when jsonb_typeof(draft -> 'warnings') = 'object' then draft -> 'warnings'
      else jsonb_build_object('smoke', false, 'flashes', false, 'sound', false, 'actors', false, 'allergens', false)
    end,
    'availableFrom', available_from,
    'availableUntil', available_until,
    'accessibility', case
      when coalesce(draft ->> 'accessibility', '') in ('', 'step_free', 'steps', 'mixed', 'unknown')
        then coalesce(draft ->> 'accessibility', '')
      else ''
    end
  );

  update app_private.portal_applications
  set private_draft_data = draft
  where id = application.id;

  return app_private.admin_review_portal_application_before_house_requirements(
    _application_id, _expected_version, 'approved', world_slug,
    _latitude, _longitude, _reason
  );
end;
$$;

revoke all on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  from public, anon;
grant execute on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  to authenticated;

comment on function api.admin_review_portal_application(uuid, integer, text, text, numeric, numeric, text)
  is 'Reviews a house application. Approval requires only a verified email, contact name, phone and complete address; missing operational details receive safe defaults and can be completed later.';
