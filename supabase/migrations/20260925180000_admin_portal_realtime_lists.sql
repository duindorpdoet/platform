-- One private, deduplicated organizer projection for every house intake and
-- every approved operational portal. Realtime payloads contain identifiers
-- only; clients must refetch this capability-protected snapshot for PII.

alter table app_private.portal_registration_intakes
  add column system_number integer,
  add column system_code text;

update app_private.portal_registration_intakes intake
set system_number = application.system_number,
    system_code = application.system_code
from app_private.portal_applications application
where application.id = intake.application_id;

do $$
declare intake_record record; assigned_number integer;
begin
  for intake_record in
    select id, event_id
    from app_private.portal_registration_intakes
    where system_number is null
    order by created_at, id
  loop
    assigned_number := app_private.next_event_identity_number(intake_record.event_id, 'portal');
    update app_private.portal_registration_intakes
    set system_number = assigned_number,
        system_code = 'P-' || lpad(assigned_number::text, 2, '0')
    where id = intake_record.id;
  end loop;
end;
$$;

alter table app_private.portal_registration_intakes
  alter column system_number set not null,
  alter column system_code set not null,
  add constraint portal_registration_intakes_system_number_positive check (system_number > 0),
  add constraint portal_registration_intakes_system_code_format check (system_code ~ '^P-[0-9]{2,}$'),
  add constraint portal_registration_intakes_event_system_number_unique unique (event_id, system_number),
  add constraint portal_registration_intakes_event_system_code_unique unique (event_id, system_code);

create or replace function app_private.assign_portal_registration_intake_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.system_number is null then
    new.system_number := app_private.next_event_identity_number(new.event_id, 'portal');
  end if;
  new.system_code := 'P-' || lpad(new.system_number::text, 2, '0');
  return new;
end;
$$;

create trigger portal_registration_intakes_assign_identity
before insert on app_private.portal_registration_intakes
for each row execute function app_private.assign_portal_registration_intake_identity();

create trigger portal_registration_intakes_identity_immutable
before update on app_private.portal_registration_intakes
for each row execute function app_private.prevent_system_identity_change();

-- A verified account that continues an existing intake keeps the code already
-- shown to the organizer. Direct authenticated drafts still receive a fresh
-- identity from the same event counter.
create or replace function app_private.assign_portal_application_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare intake_number integer;
begin
  if new.system_number is null then
    select intake.system_number into intake_number
    from app_private.portal_registration_intakes intake
    join auth.users applicant on applicant.id = new.applicant_user_id
    where intake.event_id = new.event_id
      and intake.normalized_email = lower(trim(applicant.email))
    order by intake.created_at desc
    limit 1;
    new.system_number := coalesce(intake_number, app_private.next_event_identity_number(new.event_id, 'portal'));
  end if;
  new.system_code := 'P-' || lpad(new.system_number::text, 2, '0');
  return new;
end;
$$;

create or replace function api.admin_portal_management_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'portals_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'eventId', event_record.id,
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'worlds', coalesce((
      select jsonb_agg(jsonb_build_object('id', world.id, 'slug', world.slug, 'name', world.name) order by world.sort_order)
      from app_private.worlds world where world.event_id = event_record.id
    ), '[]'::jsonb),
    'registrations', coalesce((
      with records as (
        select
          intake.id as intake_id,
          application.id as application_id,
          portal.id as portal_id,
          coalesce(application.system_code, intake.system_code) as system_code,
          intake.normalized_email as intake_email,
          intake.contact_name as intake_contact_name,
          intake.phone as intake_phone,
          intake.private_address as intake_address,
          intake.claimed_at,
          intake.created_at as intake_created_at,
          intake.updated_at as intake_updated_at,
          application.applicant_user_id,
          applicant.email as account_email,
          application.review_status::text as application_status,
          application.version as application_version,
          application.private_draft_data as draft,
          application.review_feedback,
          application.created_at as application_created_at,
          application.updated_at as application_updated_at,
          application.submitted_at,
          application.reviewed_at,
          requested_world.slug as requested_world_slug,
          portal.created_at as portal_created_at,
          portal.updated_at as portal_updated_at,
          portal.version as portal_version,
          portal.name as portal_name,
          location.verified_at as location_verified_at,
          location.latitude,
          location.longitude,
          location.street as location_street,
          location.house_number as location_house_number,
          location.addition as location_addition,
          location.postal_code as location_postal_code,
          location.city as location_city
        from app_private.portal_registration_intakes intake
        left join app_private.portal_applications application on application.id = intake.application_id
        left join auth.users applicant on applicant.id = application.applicant_user_id
        left join app_private.worlds requested_world on requested_world.id = application.requested_world_id
        left join app_private.portals portal on portal.application_id = application.id
        left join app_private.portal_private_locations location on location.portal_id = portal.id
        where intake.event_id = event_record.id

        union all

        select
          null::uuid as intake_id,
          application.id as application_id,
          portal.id as portal_id,
          application.system_code,
          null::text as intake_email,
          null::text as intake_contact_name,
          null::text as intake_phone,
          null::jsonb as intake_address,
          null::timestamptz as claimed_at,
          null::timestamptz as intake_created_at,
          null::timestamptz as intake_updated_at,
          application.applicant_user_id,
          applicant.email as account_email,
          application.review_status::text as application_status,
          application.version as application_version,
          application.private_draft_data as draft,
          application.review_feedback,
          application.created_at as application_created_at,
          application.updated_at as application_updated_at,
          application.submitted_at,
          application.reviewed_at,
          requested_world.slug as requested_world_slug,
          portal.created_at as portal_created_at,
          portal.updated_at as portal_updated_at,
          portal.version as portal_version,
          portal.name as portal_name,
          location.verified_at as location_verified_at,
          location.latitude,
          location.longitude,
          location.street as location_street,
          location.house_number as location_house_number,
          location.addition as location_addition,
          location.postal_code as location_postal_code,
          location.city as location_city
        from app_private.portal_applications application
        join auth.users applicant on applicant.id = application.applicant_user_id
        left join app_private.worlds requested_world on requested_world.id = application.requested_world_id
        left join app_private.portals portal on portal.application_id = application.id
        left join app_private.portal_private_locations location on location.portal_id = portal.id
        where application.event_id = event_record.id
          and not exists (
            select 1 from app_private.portal_registration_intakes intake
            where intake.application_id = application.id
          )
      ), normalized as (
        select records.*,
          coalesce(nullif(trim(records.draft ->> 'email'), ''), records.intake_email, lower(records.account_email)) as email,
          coalesce(nullif(trim(records.draft ->> 'contactName'), ''), records.intake_contact_name) as contact_name,
          coalesce(nullif(trim(records.draft ->> 'phone'), ''), records.intake_phone) as phone,
          coalesce(
            nullif(records.draft -> 'address', '{}'::jsonb),
            nullif(records.intake_address, '{}'::jsonb),
            case when records.location_street is not null or records.location_postal_code is not null then jsonb_build_object(
              'street', records.location_street,
              'houseNumber', records.location_house_number,
              'addition', records.location_addition,
              'postalCode', records.location_postal_code,
              'city', records.location_city
            ) end,
            '{}'::jsonb
          ) as address,
          case
            when records.application_status = 'submitted' then 'ready_for_review'
            when records.application_status = 'changes_requested' then 'changes_requested'
            when records.application_status = 'approved' then 'approved'
            when records.application_status in ('rejected', 'withdrawn') then 'closed'
            when records.claimed_at is not null or records.application_id is not null then 'activated_incomplete'
            else 'awaiting_otp'
          end as display_status,
          greatest(
            coalesce(records.intake_updated_at, '-infinity'::timestamptz),
            coalesce(records.application_updated_at, '-infinity'::timestamptz),
            coalesce(records.portal_updated_at, '-infinity'::timestamptz),
            coalesce(records.intake_created_at, records.application_created_at)
          ) as last_activity_at
        from records
      )
      select jsonb_agg(jsonb_build_object(
        'id', coalesce('intake:' || normalized.intake_id::text, 'application:' || normalized.application_id::text),
        'intakeId', normalized.intake_id,
        'applicationId', normalized.application_id,
        'portalId', normalized.portal_id,
        'code', normalized.system_code,
        'status', normalized.display_status,
        'applicationStatus', normalized.application_status,
        'applicationVersion', normalized.application_version,
        'email', normalized.email,
        'contactName', normalized.contact_name,
        'phone', normalized.phone,
        'address', normalized.address,
        'draft', coalesce(normalized.draft, '{}'::jsonb),
        'requestedWorldSlug', coalesce(normalized.requested_world_slug, normalized.draft ->> 'requestedWorldSlug'),
        'reviewFeedback', normalized.review_feedback,
        'lastActivityAt', normalized.last_activity_at,
        'progress', jsonb_build_object(
          'contact', normalized.email is not null and normalized.contact_name is not null and normalized.phone is not null,
          'address', nullif(trim(normalized.address ->> 'street'), '') is not null
            and nullif(trim(normalized.address ->> 'houseNumber'), '') is not null
            and nullif(trim(normalized.address ->> 'postalCode'), '') is not null,
          'experience', nullif(trim(normalized.draft ->> 'portalName'), '') is not null
            and nullif(trim(normalized.draft ->> 'description'), '') is not null
            and nullif(trim(normalized.draft ->> 'requestedWorldSlug'), '') is not null,
          'planning', nullif(trim(normalized.draft ->> 'availableFrom'), '') is not null
            and nullif(trim(normalized.draft ->> 'availableUntil'), '') is not null
            and coalesce(normalized.draft -> 'availability', 'false'::jsonb) = 'true'::jsonb
        ),
        'timeline', (
          select coalesce(jsonb_agg(jsonb_build_object('label', milestone.label, 'at', milestone.happened_at)
            order by milestone.happened_at), '[]'::jsonb)
          from (values
            ('Aanmelding gestart'::text, normalized.intake_created_at),
            ('Bewoner heeft poortomgeving geactiveerd'::text, normalized.claimed_at),
            ('Omgeving geopend'::text, normalized.application_created_at),
            ('Klaar voor beoordeling'::text, normalized.submitted_at),
            (case normalized.application_status
              when 'changes_requested' then 'Aanpassing gevraagd'
              when 'approved' then 'Goedgekeurd'
              when 'rejected' then 'Afgewezen'
              when 'withdrawn' then 'Ingetrokken'
              else null end, normalized.reviewed_at),
            ('Actieve poort aangemaakt'::text, normalized.portal_created_at),
            ('Locatie geverifieerd'::text, normalized.location_verified_at)
          ) milestone(label, happened_at)
          where milestone.label is not null and milestone.happened_at is not null
        ),
        'portal', case when normalized.portal_id is null then null else jsonb_build_object(
          'id', normalized.portal_id, 'version', normalized.portal_version, 'name', normalized.portal_name,
          'locationVerified', normalized.location_verified_at is not null,
          'latitude', normalized.latitude, 'longitude', normalized.longitude
        ) end
      ) order by normalized.last_activity_at desc, normalized.system_code)
      from normalized
    ), '[]'::jsonb),
    'activePortals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'portalId', portal.id,
        'applicationId', application.id,
        'code', portal.system_code,
        'systemCode', portal.system_code,
        'name', portal.name,
        'world', world.name,
        'worldSlug', world.slug,
        'operationStatus', portal.operation_status,
        'version', portal.version,
        'isFinal', portal.id = route_settings.final_portal_id,
        'contactName', coalesce(nullif(trim(application.private_draft_data ->> 'contactName'), ''), intake.contact_name),
        'phone', coalesce(nullif(trim(application.private_draft_data ->> 'phone'), ''), intake.phone),
        'email', coalesce(nullif(trim(application.private_draft_data ->> 'email'), ''), intake.normalized_email, lower(applicant.email)),
        'formattedAddress', concat_ws(' ', location.street, location.house_number, location.addition)
          || ', ' || location.postal_code || ' ' || location.city,
        'locationVerified', location.verified_at is not null,
        'coordinate', case when location.verified_at is not null and location.latitude is not null and location.longitude is not null
          then jsonb_build_array(location.longitude, location.latitude) else null end,
        'activeReservations', (select count(*) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')),
        'expectedChildren', (select coalesce(sum(reservation.child_count), 0) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active'))
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.portal_applications application on application.id = portal.application_id
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_registration_intakes intake on intake.application_id = application.id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join app_private.event_route_settings route_settings on route_settings.event_id = portal.event_id
      where portal.event_id = event_record.id and portal.approval_status = 'approved'
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function api.admin_portal_management_snapshot(text) from public, anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;

create or replace function app_private.notify_admin_portal_source_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare event_id uuid; record_id uuid;
begin
  if tg_op = 'DELETE' then event_id := old.event_id; record_id := old.id;
  else event_id := new.event_id; record_id := new.id;
  end if;
  perform realtime.send(jsonb_build_object('resource', tg_table_name, 'id', record_id),
    'snapshot_changed', 'admin-event:' || event_id::text, true);
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger admin_portal_intake_broadcast
after insert or update or delete on app_private.portal_registration_intakes
for each row execute function app_private.notify_admin_portal_source_change();

create trigger admin_portal_application_broadcast
after insert or update or delete on app_private.portal_applications
for each row execute function app_private.notify_admin_portal_source_change();

drop trigger if exists admin_portal_status_broadcast on app_private.portals;
create trigger admin_portal_record_broadcast
after insert or update or delete on app_private.portals
for each row execute function app_private.notify_admin_portal_source_change();

create or replace function app_private.notify_admin_portal_child_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare changed_portal_id uuid; event_id uuid; record_id uuid;
begin
  if tg_op = 'DELETE' then changed_portal_id := old.portal_id;
  else changed_portal_id := new.portal_id;
  end if;
  select portal.event_id into event_id from app_private.portals portal where portal.id = changed_portal_id;
  if event_id is not null then
    record_id := changed_portal_id;
    perform realtime.send(jsonb_build_object('resource', tg_table_name, 'portalId', record_id),
      'snapshot_changed', 'admin-event:' || event_id::text, true);
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger admin_portal_location_broadcast
after insert or update or delete on app_private.portal_private_locations
for each row execute function app_private.notify_admin_portal_child_change();

create trigger admin_portal_reservation_broadcast
after insert or update or delete on app_private.portal_reservations
for each row execute function app_private.notify_admin_portal_child_change();

revoke execute on function app_private.assign_portal_registration_intake_identity() from public, anon, authenticated;
revoke execute on function app_private.notify_admin_portal_source_change() from public, anon, authenticated;
revoke execute on function app_private.notify_admin_portal_child_change() from public, anon, authenticated;
