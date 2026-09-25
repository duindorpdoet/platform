-- Include each child's age in the organizer-only group composition projection.
-- The underlying child records were already authorized for event and group managers;
-- this only enriches the existing bounded snapshot used by the grouping board.

create or replace function api.admin_group_composition_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  return jsonb_build_object(
    'eventId', event_record.id,
    'phase', event_record.phase,
    'editable', event_record.phase in ('draft', 'registration_open', 'registration_closed', 'planning'),
    'maxGroupSize', least(coalesce((event_record.settings ->> 'maxGroupSize')::integer, 20), 20),
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id,
        'systemCode', walking_group.system_code,
        'displayName', walking_group.display_name,
        'status', walking_group.status,
        'version', walking_group.version,
        'locked', walking_group.status in ('ready', 'live', 'completed', 'stopped') or exists (
          select 1 from app_private.group_registrations locked_assignment
          where locked_assignment.group_id = walking_group.id and locked_assignment.superseded_at is null
            and locked_assignment.published_at is not null
        ) or exists (
          select 1 from app_private.group_schedule_revisions schedule
          where schedule.group_id = walking_group.id and schedule.state = 'published'
        ),
        'childCount', (select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id
            and child.participation_status = 'active'
          where assignment.group_id = walking_group.id and assignment.superseded_at is null),
        'registrations', coalesce((select jsonb_agg(jsonb_build_object(
          'id', registration.id,
          'reference', registration.reference,
          'householdLabel', household.label,
          'parentEmail', primary_contact.email,
          'childCount', (select count(*) from app_private.registration_children child
            where child.registration_id = registration.id and child.participation_status = 'active'),
          'children', coalesce((select jsonb_agg(jsonb_build_object(
              'name', child_record.first_name,
              'age', child_record.age_at_event
            ) order by child_record.first_name, registration_child.id)
            from app_private.registration_children registration_child
            join app_private.children child_record on child_record.id = registration_child.child_id
            where registration_child.registration_id = registration.id
              and registration_child.participation_status = 'active'), '[]'::jsonb),
          'partyId', membership.party_id,
          'preferredStartAt', registration.preferred_start_at,
          'desiredEndAt', registration.desired_end_at,
          'assignmentPublished', assignment.published_at is not null
        ) order by household.label, registration.reference)
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          join app_private.households household on household.id = registration.household_id
          left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
          left join app_private.together_memberships membership
            on membership.registration_id = registration.id and membership.left_at is null
          where assignment.group_id = walking_group.id and assignment.superseded_at is null), '[]'::jsonb)
      ) order by walking_group.system_number)
      from app_private.walking_groups walking_group where walking_group.event_id = event_record.id
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'householdLabel', household.label,
        'parentEmail', primary_contact.email,
        'childCount', (select count(*) from app_private.registration_children child
          where child.registration_id = registration.id and child.participation_status = 'active'),
        'children', coalesce((select jsonb_agg(jsonb_build_object(
            'name', child_record.first_name,
            'age', child_record.age_at_event
          ) order by child_record.first_name, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child_record on child_record.id = registration_child.child_id
          where registration_child.registration_id = registration.id
            and registration_child.participation_status = 'active'), '[]'::jsonb),
        'partyId', membership.party_id,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'assignmentPublished', false
      ) order by household.label, registration.reference)
      from app_private.registrations registration
      join app_private.households household on household.id = registration.household_id
      left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
      left join app_private.together_memberships membership
        on membership.registration_id = registration.id and membership.left_at is null
      where registration.event_id = event_record.id and registration.status = 'submitted'
        and not exists (select 1 from app_private.group_registrations assignment
          where assignment.registration_id = registration.id and assignment.superseded_at is null)
    ), '[]'::jsonb)
  );
end;
$$;

