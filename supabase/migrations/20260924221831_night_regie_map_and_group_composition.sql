-- Organizer-only live map data and a manual, pre-publication group board.
-- Private addresses and contacts remain behind explicit capabilities; realtime
-- messages contain identifiers only and tell clients to refetch a bounded RPC.

create or replace function api.admin_portal_operations_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'portals_manage', actor)
    or app_private.has_capability(event_record.id, 'live_support', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'eventId', event_record.id,
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'portalId', portal.id, 'applicationId', application.id,
        'code', portal.system_code, 'systemCode', portal.system_code, 'name', portal.name,
        'world', world.name, 'worldSlug', world.slug,
        'operationStatus', portal.operation_status, 'approvalStatus', portal.approval_status,
        'version', portal.version, 'isFinal', portal.id = route_settings.final_portal_id,
        'contactName', nullif(trim(application.private_draft_data ->> 'contactName'), ''),
        'phone', nullif(trim(application.private_draft_data ->> 'phone'), ''), 'email', applicant.email,
        'address', case when location.portal_id is null then null else jsonb_build_object(
          'street', location.street, 'houseNumber', location.house_number, 'addition', location.addition,
          'postalCode', location.postal_code, 'city', location.city
        ) end,
        'formattedAddress', case when location.portal_id is null then null else
          concat_ws(' ', location.street, location.house_number, location.addition)
            || ', ' || location.postal_code || ' ' || location.city end,
        'locationVerified', location.verified_at is not null,
        'coordinate', case when location.verified_at is not null
          and location.latitude is not null and location.longitude is not null
          then jsonb_build_array(location.longitude, location.latitude) else null end,
        'messageTarget', jsonb_build_object(
          'kind', 'portal', 'portalId', portal.id, 'userId', application.applicant_user_id,
          'label', portal.system_code || ' · ' || portal.name
        ),
        'activeReservations', (select count(*) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')),
        'expectedChildren', (select coalesce(sum(reservation.child_count), 0) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active'))
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_applications application on application.id = portal.application_id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join app_private.event_route_settings route_settings on route_settings.event_id = portal.event_id
      where portal.event_id = event_record.id and portal.approval_status = 'approved'
    ), '[]'::jsonb)
  );
end;
$$;

create function api.admin_group_composition_snapshot(_event_slug text)
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
          'children', coalesce((select jsonb_agg(child_record.first_name order by child_record.first_name)
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
        'children', coalesce((select jsonb_agg(child_record.first_name order by child_record.first_name)
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

create function api.admin_group_create(_event_slug text, _display_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); event_record app_private.events; created_group app_private.walking_groups; normalized_name text;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;
  normalized_name := nullif(regexp_replace(trim(coalesce(_display_name, '')), '[[:space:]]+', ' ', 'g'), '');
  if normalized_name is not null and (char_length(normalized_name) not between 2 and 80 or normalized_name ~ '[[:cntrl:]]') then
    raise exception 'INVALID_GROUP_NAME' using errcode = '22023';
  end if;
  insert into app_private.walking_groups(event_id, code, status, display_name, route_mode)
  values (event_record.id, 'pending', 'draft', normalized_name, 'dynamic') returning * into created_group;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'group.created', 'walking_group', created_group.id,
    jsonb_build_object('systemCode', created_group.system_code, 'displayName', created_group.display_name));
  perform realtime.send(jsonb_build_object('resource', 'group_composition', 'id', created_group.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('id', created_group.id, 'systemCode', created_group.system_code,
    'displayName', created_group.display_name, 'version', created_group.version);
end;
$$;

create function api.admin_group_move_registration(
  _event_slug text,
  _registration_id uuid,
  _target_group_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  selected_registration app_private.registrations;
  target_group app_private.walking_groups;
  selected_party_id uuid;
  bundle_ids uuid[];
  bundle_children integer;
  target_children integer;
  max_group_size integer;
  member_id uuid;
  active_assignment app_private.group_registrations;
  next_revision integer;
begin
  select * into event_record from app_private.events where slug = _event_slug for update;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;
  select * into selected_registration from app_private.registrations
  where id = _registration_id and event_id = event_record.id and status = 'submitted' for update;
  if selected_registration.id is null then raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002'; end if;
  select party_id into selected_party_id from app_private.together_memberships
  where registration_id = selected_registration.id and left_at is null;
  select coalesce(array_agg(registration.id order by registration.id), array[selected_registration.id]) into bundle_ids
  from app_private.registrations registration
  where registration.event_id = event_record.id and registration.status = 'submitted' and (
    (selected_party_id is null and registration.id = selected_registration.id)
    or (selected_party_id is not null and exists (select 1 from app_private.together_memberships membership
      where membership.party_id = selected_party_id and membership.registration_id = registration.id and membership.left_at is null))
  );
  perform 1 from app_private.registrations where id = any(bundle_ids) order by id for update;

  if _target_group_id is not null then
    select * into target_group from app_private.walking_groups
    where id = _target_group_id and event_id = event_record.id for update;
    if target_group.id is null then raise exception 'GROUP_NOT_FOUND' using errcode = 'P0002'; end if;
    if target_group.status <> 'draft' or exists (select 1 from app_private.group_schedule_revisions schedule
      where schedule.group_id = target_group.id and schedule.state = 'published') then
      raise exception 'GROUPS_FINALIZED' using errcode = '23514';
    end if;
  end if;

  if exists (
    select 1 from app_private.group_registrations assignment
    join app_private.walking_groups source_group on source_group.id = assignment.group_id
    where assignment.registration_id = any(bundle_ids) and assignment.superseded_at is null
      and (assignment.published_at is not null or source_group.status <> 'draft'
        or exists (select 1 from app_private.group_schedule_revisions schedule
          where schedule.group_id = source_group.id and schedule.state = 'published'))
  ) then raise exception 'GROUPS_FINALIZED' using errcode = '23514'; end if;

  select count(*)::integer into bundle_children from app_private.registration_children child
  where child.registration_id = any(bundle_ids) and child.participation_status = 'active';
  max_group_size := least(coalesce((event_record.settings ->> 'maxGroupSize')::integer, 20), 20);
  if _target_group_id is not null then
    select count(*)::integer into target_children
    from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id
      and child.participation_status = 'active'
    where assignment.group_id = _target_group_id and assignment.superseded_at is null
      and not (assignment.registration_id = any(bundle_ids));
    if target_children + bundle_children > max_group_size then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514';
    end if;
  end if;

  foreach member_id in array bundle_ids loop
    select * into active_assignment from app_private.group_registrations assignment
    where assignment.registration_id = member_id and assignment.superseded_at is null for update;
    if active_assignment.group_id is not distinct from _target_group_id then continue; end if;
    if active_assignment.id is not null then
      update app_private.group_registrations set superseded_at = now() where id = active_assignment.id;
      update app_private.walking_groups set version = version + 1, updated_at = now()
      where id = active_assignment.group_id;
    end if;
    if _target_group_id is not null then
      select coalesce(max(assignment_revision), 0) + 1 into next_revision
      from app_private.group_registrations where registration_id = member_id;
      insert into app_private.group_registrations(group_id, registration_id, assignment_revision)
      values (_target_group_id, member_id, next_revision);
    end if;
    active_assignment := null;
  end loop;
  if _target_group_id is not null then
    update app_private.walking_groups set version = version + 1, updated_at = now() where id = _target_group_id;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, actor, 'group.registration_moved', 'registration', selected_registration.id,
    jsonb_build_object('targetGroupId', _target_group_id, 'registrationIds', to_jsonb(bundle_ids),
      'childCount', bundle_children));
  perform realtime.send(jsonb_build_object('resource', 'group_composition', 'registrationId', selected_registration.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return jsonb_build_object('movedRegistrations', cardinality(bundle_ids), 'childCount', bundle_children,
    'targetGroupId', _target_group_id);
end;
$$;

create or replace function app_private.can_access_realtime_topic(_topic text, _actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select _actor is not null and case
    when _topic like 'group:%' then exists (
      select 1 from app_private.walking_groups walking_group
      where walking_group.id::text = split_part(_topic, ':', 2) and (
        app_private.is_current_leader(walking_group.id, _actor)
        or app_private.has_capability(walking_group.event_id, 'live_support', _actor)
        or exists (
          select 1 from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          join app_private.group_registrations assignment on assignment.registration_id = registration.id
          where member.user_id = _actor and member.revoked_at is null
            and assignment.group_id = walking_group.id and assignment.superseded_at is null
        )
      )
    )
    when _topic like 'portal:%' then exists (
      select 1 from app_private.portals portal where portal.id::text = split_part(_topic, ':', 2) and (
        exists (select 1 from app_private.portal_owners owner
          where owner.portal_id = portal.id and owner.user_id = _actor and owner.revoked_at is null)
        or app_private.has_capability(portal.event_id, 'portals_manage', _actor)
      )
    )
    when _topic like 'messenger:%' then exists (
      select 1 from app_private.messenger_conversations conversation
      where conversation.id::text = split_part(_topic, ':', 2) and (
        app_private.messenger_is_organizer(conversation.event_id, _actor)
        or (conversation.participant_user_id = _actor and app_private.messenger_actor_can_use_subject(
          conversation.event_id, _actor, conversation.subject_kind, conversation.subject_id
        ))
      )
    )
    when _topic like 'messenger-admin:%' then app_private.messenger_is_organizer(
      nullif(split_part(_topic, ':', 2), '')::uuid, _actor
    )
    when _topic like 'admin-event:%' then exists (
      select 1 from app_private.events event_record
      where event_record.id::text = split_part(_topic, ':', 2) and (
        app_private.has_capability(event_record.id, 'event_admin', _actor)
        or app_private.has_capability(event_record.id, 'groups_manage', _actor)
        or app_private.has_capability(event_record.id, 'portals_manage', _actor)
        or app_private.has_capability(event_record.id, 'live_support', _actor)
      )
    )
    else false end
$$;

create function app_private.notify_admin_portal_status_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('resource', 'portal', 'id', new.id, 'version', new.version),
    'snapshot_changed', 'admin-event:' || new.event_id::text, true);
  return new;
end;
$$;
create trigger admin_portal_status_broadcast
after update of operation_status on app_private.portals
for each row when (old.operation_status is distinct from new.operation_status)
execute function app_private.notify_admin_portal_status_change();

revoke execute on function api.admin_group_composition_snapshot(text) from public, anon;
revoke execute on function api.admin_group_create(text, text) from public, anon;
revoke execute on function api.admin_group_move_registration(text, uuid, uuid) from public, anon;
grant execute on function api.admin_group_composition_snapshot(text) to authenticated;
grant execute on function api.admin_group_create(text, text) to authenticated;
grant execute on function api.admin_group_move_registration(text, uuid, uuid) to authenticated;
revoke execute on function app_private.notify_admin_portal_status_change() from public, anon, authenticated;
