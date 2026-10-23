-- Existing RPCs read the current event policy; no membership or price changes.
set lock_timeout='5s';

-- Current canonical contract: app_private.attach_registration_to_together_party
CREATE OR REPLACE FUNCTION app_private.attach_registration_to_together_party(_registration_id uuid, _requested_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  registration_record app_private.registrations;
  normalized_code text := nullif(upper(trim(coalesce(_requested_code, ''))), '');
  target_party app_private.together_parties;
  own_party_id uuid;
  incoming_children integer;
  projected_children integer;
  max_group_size integer;
begin
  select * into registration_record from app_private.registrations
  where id = _registration_id for update;
  if registration_record.id is null then raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002'; end if;
  if exists (select 1 from app_private.together_memberships where registration_id = registration_record.id and left_at is null) then
    raise exception 'ALREADY_IN_PARTY' using errcode = '23505';
  end if;
  if normalized_code is not null and normalized_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;
  select app_private.event_group_size_limit(id) into max_group_size
  from app_private.events where id = registration_record.event_id;
  select count(*)::integer into incoming_children from app_private.registration_children child
  where child.registration_id = registration_record.id and child.participation_status = 'active';
  if incoming_children < 1 then raise exception 'EMPTY_REGISTRATION' using errcode = '23514'; end if;

  if normalized_code is not null then
    select party.* into target_party
    from app_private.registrations target
    join app_private.together_memberships membership on membership.registration_id = target.id and membership.left_at is null
    join app_private.together_parties party on party.id = membership.party_id and party.locked_at is null
    where target.event_id = registration_record.event_id and target.status = 'submitted'
      and target.together_code = normalized_code and target.id <> registration_record.id
    for update of party;
    if target_party.id is null then raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023'; end if;
  end if;

  insert into app_private.together_parties(event_id, public_label, creator_household_id, invite_token_hash, expires_at)
  values (
    registration_record.event_id, 'Samenloopcode ' || registration_record.together_code,
    registration_record.household_id,
    extensions.digest(convert_to('registration:' || registration_record.id::text, 'utf8'), 'sha256'),
    now() + interval '10 years'
  ) returning id into own_party_id;
  insert into app_private.together_memberships(party_id, registration_id)
  values (own_party_id, registration_record.id);

  if normalized_code is not null then
    projected_children := app_private.together_party_child_count(target_party.id) + incoming_children;
    insert into app_private.together_join_requests(
      event_id, source_party_id, target_party_id, requested_by_registration_id,
      requested_code, child_count_at_request, group_limit_at_request
    ) values (
      registration_record.event_id, own_party_id, target_party.id, registration_record.id,
      normalized_code, incoming_children, max_group_size
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration_record.event_id, actor, 'together.join_requested', 'registration', registration_record.id,
      jsonb_build_object('projectedChildren', projected_children, 'groupLimit', max_group_size, 'requiresApproval', true)
    );
  end if;
  return own_party_id;
end;
$function$
;

-- Current canonical contract: api.admin_together_requests_snapshot
CREATE OR REPLACE FUNCTION api.admin_together_requests_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', request.id,
      'version', request.version,
      'status', request.status,
      'requestedCode', request.requested_code,
      'registrationReference', registration.reference,
      'sourceChildren', app_private.together_party_child_count(request.source_party_id),
      'targetChildren', app_private.together_party_child_count(request.target_party_id),
      'projectedChildren', app_private.together_party_child_count(request.source_party_id)
        + app_private.together_party_child_count(request.target_party_id),
      'maxGroupSize', app_private.event_group_size_limit(event_record.id),
      'limitOverridden', request.limit_overridden,
      'createdAt', request.created_at,
      'decidedAt', request.decided_at
    ) order by (request.status = 'pending') desc, request.created_at desc)
    from app_private.together_join_requests request
    join app_private.registrations registration on registration.id = request.requested_by_registration_id
    where request.event_id = event_record.id
  ), '[]'::jsonb);
end;
$function$
;

-- Current canonical contract: api.admin_decide_together_request
CREATE OR REPLACE FUNCTION api.admin_decide_together_request(_request_id uuid, _expected_version integer, _decision text, _override_limit boolean, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  request_record app_private.together_join_requests;
  event_record app_private.events;
  source_children integer;
  target_children integer;
  projected_children integer;
  max_group_size integer;
  membership_record record;
  recorded_change jsonb;
  expected_status text;
begin
  if _expected_version is null or _expected_version < 1
     or _override_limit is null
     or _decision is null or _decision not in ('accept', 'reject')
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  expected_status := case when _decision = 'accept' then 'accepted' else 'rejected' end;

  select * into request_record
  from app_private.together_join_requests
  where id = _request_id;
  if request_record.id is null then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into event_record
  from app_private.events
  where id = request_record.event_id
  for update;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  -- Re-read under the event lock; all party-moving commands lock the event first.
  select * into request_record from app_private.together_join_requests where id = _request_id for update;

  -- A retry is idempotent only for the same terminal decision and the version
  -- used by the original call (or the returned terminal version). An opposite
  -- decision and unrelated stale versions keep the optimistic-lock failure.
  if request_record.status in ('accepted', 'rejected') then
    if request_record.status <> expected_status
       or _expected_version not in (request_record.version - 1, request_record.version) then
      raise exception 'STALE_VERSION' using errcode = '40001';
    end if;

    select audit.minimal_change
    into recorded_change
    from app_private.audit_events audit
    where audit.resource_type = 'together_join_request'
      and audit.resource_id = request_record.id
      and audit.action = case
        when request_record.status = 'accepted' then 'together.capacity_request_accepted'
        else 'together.capacity_request_rejected'
      end
    order by audit.created_at desc, audit.id desc
    limit 1;

    projected_children := coalesce(
      (recorded_change ->> 'projectedChildren')::integer,
      case
        when request_record.status = 'accepted'
          then app_private.together_party_child_count(request_record.target_party_id)
        else request_record.child_count_at_request
          + app_private.together_party_child_count(request_record.target_party_id)
      end
    );
    max_group_size := coalesce(
      (recorded_change ->> 'groupLimit')::integer,
      request_record.group_limit_at_request,
      (event_record.settings ->> 'maxGroupSize')::integer,
      10
    );

    return jsonb_build_object(
      'id', request_record.id,
      'status', request_record.status,
      'version', request_record.version,
      'projectedChildren', projected_children,
      'maxGroupSize', max_group_size,
      'limitOverridden', request_record.limit_overridden
    );
  end if;

  if request_record.status <> 'pending' or request_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  -- Lock both parties in deterministic order before recalculating capacity.
  perform id
  from app_private.together_parties
  where id in (request_record.source_party_id, request_record.target_party_id)
  order by id
  for update;
  if exists (
    select 1
    from app_private.together_parties
    where id in (request_record.source_party_id, request_record.target_party_id)
      and locked_at is not null
  ) then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;

  source_children := app_private.together_party_child_count(request_record.source_party_id);
  target_children := app_private.together_party_child_count(request_record.target_party_id);
  projected_children := source_children + target_children;
  max_group_size := app_private.event_group_size_limit(event_record.id);

  if _decision = 'accept' then
    if projected_children > max_group_size and not _override_limit then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514',
        detail = jsonb_build_object(
          'projectedChildren', projected_children,
          'maxGroupSize', max_group_size
        )::text;
    end if;

    if projected_children>max_group_size then
      insert into app_private.group_size_override_commands(event_id,party_id,actor_id,approved_registration_ids,approved_children,settings_version,reason)
      select event_record.id,request_record.target_party_id,actor,
       array_agg(distinct m.registration_id order by m.registration_id),projected_children,event_record.settings_version,trim(_reason)
      from app_private.together_memberships m where m.party_id in(request_record.source_party_id,request_record.target_party_id) and m.left_at is null;
    end if;

    for membership_record in
      select *
      from app_private.together_memberships
      where party_id = request_record.source_party_id
        and left_at is null
      order by joined_at, id
      for update
    loop
      update app_private.together_memberships
      set left_at = now()
      where id = membership_record.id;

      insert into app_private.together_memberships(party_id, registration_id)
      values (request_record.target_party_id, membership_record.registration_id);
    end loop;

    update app_private.together_join_requests
    set target_party_id = request_record.target_party_id,
        updated_at = now(),
        version = version + 1
    where target_party_id = request_record.source_party_id
      and id <> request_record.id
      and status = 'pending';

    update app_private.together_parties
    set capacity_override_at = case
          when projected_children > max_group_size then now()
          else capacity_override_at
        end,
        capacity_override_by = case
          when projected_children > max_group_size then actor
          else capacity_override_by
        end,
        capacity_override_reason = case
          when projected_children > max_group_size then left(trim(_reason), 500)
          else capacity_override_reason
        end
    where id = request_record.target_party_id;

    update app_private.together_parties
    set locked_at = now()
    where id = request_record.source_party_id;

    perform app_private.ensure_together_party_cluster_reference(request_record.target_party_id);
  end if;

  update app_private.together_join_requests
  set status = expected_status,
      decided_by = actor,
      decided_at = now(),
      decision_reason = left(trim(_reason), 500),
      limit_overridden = _decision = 'accept' and projected_children > max_group_size,
      updated_at = now(),
      version = version + 1
  where id = request_record.id
  returning * into request_record;

  insert into app_private.audit_events(
    event_id,
    actor_id,
    action,
    resource_type,
    resource_id,
    minimal_change
  )
  values (
    event_record.id,
    actor,
    case
      when _decision = 'accept' then 'together.capacity_request_accepted'
      else 'together.capacity_request_rejected'
    end,
    'together_join_request',
    request_record.id,
    jsonb_build_object(
      'sourceChildren', source_children,
      'targetChildren', target_children,
      'projectedChildren', projected_children,
      'groupLimit', max_group_size,
      'limitOverridden', request_record.limit_overridden,
      'reason', left(trim(_reason), 500)
    )
  );

  perform realtime.send(jsonb_build_object('requestId', request_record.id),
    'snapshot_changed', 'admin-event:' || event_record.id::text, true);

  return jsonb_build_object(
    'id', request_record.id,
    'status', request_record.status,
    'version', request_record.version,
    'projectedChildren', projected_children,
    'maxGroupSize', max_group_size,
    'limitOverridden', request_record.limit_overridden
  );
end;
$function$
;

-- Current canonical contract: api.registration_preferences_snapshot
CREATE OR REPLACE FUNCTION api.registration_preferences_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; event_record app_private.events;
begin
  result := app_private.registration_preferences_snapshot_before_fee(_event_slug);
  select * into event_record from app_private.events where slug = _event_slug;
  return jsonb_set(result, '{event}', coalesce(result -> 'event', '{}'::jsonb) || jsonb_build_object(
    'priceCents', event_record.price_cents,
    'maxGroupSize', app_private.event_group_size_limit(event_record.id)
  ), true);
end;
$function$
;

-- Current canonical contract: api.admin_group_composition_snapshot
CREATE OR REPLACE FUNCTION api.admin_group_composition_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'maxGroupSize', app_private.event_group_size_limit(event_record.id),
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
          'clusterReference', party.cluster_reference,
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
          left join app_private.together_parties party on party.id = membership.party_id
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
          'clusterReference', party.cluster_reference,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'assignmentPublished', false
      ) order by household.label, registration.reference)
      from app_private.registrations registration
      join app_private.households household on household.id = registration.household_id
      left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
      left join app_private.together_memberships membership
        on membership.registration_id = registration.id and membership.left_at is null
          left join app_private.together_parties party on party.id = membership.party_id
      where registration.event_id = event_record.id and registration.status = 'submitted'
        and not exists (select 1 from app_private.group_registrations assignment
          where assignment.registration_id = registration.id and assignment.superseded_at is null)
    ), '[]'::jsonb)
  );
end;
$function$
;

-- Current canonical contract: api.admin_group_move_registration
CREATE OR REPLACE FUNCTION api.admin_group_move_registration(_event_slug text, _registration_id uuid, _target_group_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  max_group_size := app_private.event_group_size_limit(event_record.id);
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
$function$
;

-- Current canonical contract: app_private.together_management_parties
CREATE OR REPLACE FUNCTION app_private.together_management_parties(_event_id uuid)
 RETURNS TABLE(party_id uuid, projection jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with child_data as (
    select rc.registration_id, count(*)::integer child_count,
      jsonb_agg(jsonb_build_object('name', c.first_name, 'age', c.age_at_event) order by c.first_name, c.id) children
    from app_private.registration_children rc
    join app_private.registrations r on r.id = rc.registration_id and r.event_id = _event_id
    join app_private.children c on c.id = rc.child_id
    where rc.participation_status = 'active' group by rc.registration_id
  ), group_data as (
    select g.id, jsonb_build_object('id', g.id, 'systemCode', g.system_code, 'displayName', g.display_name,
      'status', g.status, 'version', g.version,
      'locked', g.status <> 'draft' or exists (select 1 from app_private.group_registrations a
        where a.group_id = g.id and a.superseded_at is null and a.published_at is not null)
        or exists (select 1 from app_private.group_schedule_revisions s where s.group_id = g.id and s.state = 'published')) data
    from app_private.walking_groups g where g.event_id = _event_id
  ), member_data as (
    select m.party_id, r.id, r.reference, r.status, coalesce(cd.child_count, 0) child_count,
      a.group_id, coalesce((gd.data ->> 'locked')::boolean, false) group_locked,
      a.published_at is not null assignment_published,
      jsonb_build_object('id', r.id, 'reference', r.reference, 'togetherCode', r.together_code,
        'status', r.status, 'version', r.version, 'membershipId', m.id,
        'householdLabel', h.label,
        'parentName', coalesce(nullif(trim(d.payload #>> '{adult,name}'), ''), nullif(trim(pr.display_name), ''), h.label),
        'parentEmail', lower(u.email), 'childCount', coalesce(cd.child_count, 0), 'children', coalesce(cd.children, '[]'::jsonb),
        'preferredStartAt', r.preferred_start_at, 'desiredEndAt', r.desired_end_at,
        'walkingGroup', gd.data, 'assignmentPublished', a.published_at is not null) data,
      count(*) over (partition by r.id) active_memberships
    from app_private.together_memberships m
    join app_private.together_parties p on p.id = m.party_id and p.event_id = _event_id
    join app_private.registrations r on r.id = m.registration_id and r.event_id = _event_id
    join app_private.households h on h.id = r.household_id
    left join auth.users u on u.id = h.primary_contact_user_id
    left join app_private.profiles pr on pr.user_id = u.id
    left join app_private.registration_drafts d on d.event_id = r.event_id and d.household_id = r.household_id
    left join child_data cd on cd.registration_id = r.id
    left join app_private.group_registrations a on a.registration_id = r.id and a.superseded_at is null
    left join group_data gd on gd.id = a.group_id
    where m.left_at is null
  ), party_data as (
    select p.id, p.cluster_reference, p.locked_at, e.phase, e.settings_version,
      app_private.event_group_size_limit(e.id) max_size,
      count(*) filter (where m.status = 'submitted')::integer member_count,
      coalesce(sum(m.child_count) filter (where m.status = 'submitted'), 0)::integer child_count,
      jsonb_agg(m.data order by m.reference, m.id) members,
      jsonb_agg(distinct coalesce(m.group_id::text, 'unassigned')) assignment_keys,
      coalesce(jsonb_agg(distinct m.data -> 'walkingGroup') filter (where m.group_id is not null), '[]'::jsonb) walking_groups,
      bool_or(m.group_locked) group_locked, bool_or(m.assignment_published) published,
      (bool_or(m.status <> 'submitted') or exists (select 1 from app_private.together_memberships foreign_member
        join app_private.registrations foreign_registration on foreign_registration.id = foreign_member.registration_id
        where foreign_member.party_id = p.id and foreign_member.left_at is null and foreign_registration.event_id <> p.event_id)) invalid_member, bool_or(m.active_memberships > 1) duplicate_member,
      exists(select 1 from app_private.together_join_requests q where q.source_party_id = p.id and q.status = 'pending') outgoing_request,
      exists(select 1 from app_private.together_join_requests q where p.id in (q.source_party_id, q.target_party_id) and q.status = 'pending') pending_request
    from app_private.together_parties p join app_private.events e on e.id = p.event_id
    join member_data m on m.party_id = p.id where p.event_id = _event_id
    group by p.id, e.id
  ), projected as (
    select id, jsonb_build_object('partyId', id, 'clusterReference', cluster_reference,
      'members', members, 'memberCount', member_count, 'childCount', child_count,
      'walkingGroups', walking_groups, 'assignmentKeys', assignment_keys,
      'walkingGroup', case when jsonb_array_length(assignment_keys) = 1 and jsonb_array_length(walking_groups) = 1 then walking_groups -> 0 else null end,
      'partyLocked', locked_at is not null, 'locked', locked_at is not null or group_locked,
      'published', published, 'outgoingRequest', outgoing_request,
      'maxGroupSize', max_size, 'phase', phase, 'settingsVersion', settings_version,
      'problems', to_jsonb(array_remove(array[
        case when member_count >= 2 and cluster_reference is null then 'missing_reference' end,
        case when jsonb_array_length(assignment_keys) > 1 then 'split_groups' end,
        case when child_count > max_size then 'over_capacity' end,
        case when published and pending_request then 'published_pending' end,
        case when duplicate_member then 'duplicate_membership' end,
        case when invalid_member then 'inactive_registration' end,
        case when (locked_at is not null or group_locked) and pending_request then 'locked_pending' end
      ], null)),
      'searchText', concat_ws(' ', cluster_reference, (select string_agg(concat_ws(' ', value ->> 'reference', value ->> 'togetherCode',
        value ->> 'householdLabel', value ->> 'parentName', value ->> 'parentEmail', value -> 'children',
        value #>> '{walkingGroup,systemCode}', value #>> '{walkingGroup,displayName}'), ' ') from jsonb_array_elements(members)))) data
    from party_data
  ) select id, data || jsonb_build_object('stateToken', encode(extensions.digest(data::text, 'sha256'), 'hex')) from projected;
$function$
;

-- Current canonical contract: api.admin_together_management_snapshot
CREATE OR REPLACE FUNCTION api.admin_together_management_snapshot(_event_slug text, _query text DEFAULT ''::text, _limit integer DEFAULT 100, _offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_record app_private.events;
begin
  event_record := app_private.require_together_manager(_event_slug);
  if _limit is null or _limit not between 1 and 100 or _offset is null or _offset < 0 or length(coalesce(_query, '')) > 200 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  return (
    with parties as materialized (select * from app_private.together_management_parties(event_record.id)),
    matching as (select * from parties where strpos(lower(projection ->> 'searchText'), lower(trim(coalesce(_query, '')))) > 0),
    confirmed as (select * from matching where (projection ->> 'memberCount')::integer >= 2),
    problems as (select * from matching where jsonb_array_length(projection -> 'problems') > 0),
    requests as (select q.id, q.created_at, jsonb_build_object('id', q.id, 'version', q.version,
        'requestedCode', q.requested_code, 'registrationReference', r.reference,
        'source', s.projection, 'target', t.projection, 'createdAt', q.created_at,
        'projectedChildren', coalesce((s.projection ->> 'childCount')::integer, 0) + coalesce((t.projection ->> 'childCount')::integer, 0)) data
      from app_private.together_join_requests q
      join app_private.registrations r on r.id = q.requested_by_registration_id
      left join parties s on s.party_id = q.source_party_id left join parties t on t.party_id = q.target_party_id
      where q.event_id = event_record.id and q.status = 'pending'
        and strpos(lower(concat_ws(' ', s.projection ->> 'searchText', t.projection ->> 'searchText', q.requested_code)), lower(trim(coalesce(_query, '')))) > 0)
    select jsonb_build_object('eventId', event_record.id, 'realtimeTopic', 'admin-event:' || event_record.id::text,
      'maxGroupSize', app_private.event_group_size_limit(event_record.id),
      'confirmed', coalesce((select jsonb_agg(projection order by projection ->> 'clusterReference', party_id)
        from (select * from confirmed order by projection ->> 'clusterReference', party_id limit _limit offset _offset) page), '[]'::jsonb),
      'requests', coalesce((select jsonb_agg(data order by created_at, id) from (select * from requests order by created_at, id limit _limit offset _offset) page), '[]'::jsonb),
      'problems', coalesce((select jsonb_agg(projection order by party_id) from (select * from problems order by party_id limit _limit offset _offset) page), '[]'::jsonb),
      'totals', jsonb_build_object('confirmed', (select count(*) from confirmed), 'requests', (select count(*) from requests), 'problems', (select count(*) from problems)))
  );
end;
$function$
;

-- Current canonical contract: api.admin_dashboard
CREATE OR REPLACE FUNCTION api.admin_dashboard(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  eid uuid;
  base jsonb;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
  if exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('event_admin', 'registration_manage', 'portals_manage', 'groups_manage', 'live_support')) then
    base:=app_private.admin_dashboard_before_editorial (_event_slug);
    return jsonb_set(base,'{event}',coalesce(base->'event','{}')||(
      select jsonb_build_object('maxGroupSize',app_private.event_group_size_limit(e.id),
       'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
       'targetFollowsMaximum',not(e.settings?'targetGroupSize'),'settingsVersion',e.settings_version)
      from app_private.events e where e.id=eid));
  end if;
  if not exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('content_manage', 'content_publish', 'communications_manage', 'communications_send')) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  return jsonb_build_object('event', (
      select
        jsonb_build_object('id', e.id, 'title', e.title, 'phase', e.phase, 'date', e.local_date, 'settingsVersion', e.settings_version, 'maxGroupSize', app_private.event_group_size_limit(e.id), 'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)), 'targetFollowsMaximum',not(e.settings?'targetGroupSize'))
    from app_private.events e
    where
      e.id = eid), 'counts', '{}'::jsonb, 'imports', '[]'::jsonb, 'recentActivity', '[]'::jsonb);
end
$function$
;
