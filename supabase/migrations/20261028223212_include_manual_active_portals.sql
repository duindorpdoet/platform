-- A manual portal has no resident application. Its operational record remains
-- authoritative; listing it must not activate it or fabricate an application.
set lock_timeout = '5s';

alter function api.admin_portal_management_snapshot(text) set schema app_private;
alter function app_private.admin_portal_management_snapshot(text)
  rename to admin_portal_management_snapshot_before_manual_active;
revoke all on function app_private.admin_portal_management_snapshot_before_manual_active(text)
  from public, anon, authenticated;

create function api.admin_portal_management_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; v_event_id uuid;
begin
  -- Retain the existing capability check and every other snapshot section.
  result := app_private.admin_portal_management_snapshot_before_manual_active(_event_slug);
  select e.id into v_event_id from app_private.events e where e.slug = _event_slug;
  return jsonb_set(result, '{activePortals}', coalesce((
    select jsonb_agg(jsonb_build_object(
      'portalId', portal.id, 'applicationId', application.id,
      'code', portal.system_code, 'systemCode', portal.system_code,
      'name', portal.name, 'world', world.name, 'worldSlug', world.slug,
      'operationStatus', portal.operation_status, 'version', portal.version,
      'isFinal', portal.id = route_settings.final_portal_id,
      'contactName', coalesce(nullif(trim(portal.contact_name), ''),
        nullif(trim(application.private_draft_data ->> 'contactName'), ''), intake.contact_name),
      'phone', coalesce(nullif(trim(portal.contact_phone), ''),
        nullif(trim(application.private_draft_data ->> 'phone'), ''), intake.phone),
      'email', coalesce(nullif(trim(portal.contact_email), ''),
        nullif(trim(application.private_draft_data ->> 'email'), ''), intake.normalized_email, lower(applicant.email)),
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
    join app_private.worlds world on world.id = portal.world_id
    left join app_private.portal_applications application on application.id = portal.application_id
    left join app_private.portal_registration_intakes intake on intake.application_id = application.id
    left join auth.users applicant on applicant.id = application.applicant_user_id
    left join app_private.portal_private_locations location on location.portal_id = portal.id
    left join app_private.event_route_settings route_settings on route_settings.event_id = portal.event_id
    where portal.event_id = v_event_id and portal.approval_status = 'approved'
      and portal.lifecycle_status in ('approved', 'active')
  ), '[]'::jsonb));
end;
$$;
revoke all on function api.admin_portal_management_snapshot(text) from public, anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;
notify pgrst, 'reload schema';
