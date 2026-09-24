-- Retrying the same organizer decision is safe. The request row remains the
-- serialization point: concurrent retries wait for the first transaction and
-- then return its recorded result without moving memberships or writing a
-- second audit event. Opposite/stale decisions still fail.

create or replace function api.admin_decide_together_request(
  _request_id uuid,
  _expected_version integer,
  _decision text,
  _override_limit boolean,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  where id = _request_id
  for update;
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
  max_group_size := coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10);

  if _decision = 'accept' then
    if projected_children > max_group_size and not _override_limit then
      raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514',
        detail = jsonb_build_object(
          'projectedChildren', projected_children,
          'maxGroupSize', max_group_size
        )::text;
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

  return jsonb_build_object(
    'id', request_record.id,
    'status', request_record.status,
    'version', request_record.version,
    'projectedChildren', projected_children,
    'maxGroupSize', max_group_size,
    'limitOverridden', request_record.limit_overridden
  );
end;
$$;

revoke execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text)
  from public, anon;
grant execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text)
  to authenticated;
