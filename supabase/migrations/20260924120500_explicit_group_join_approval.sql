-- Every request to walk together remains pending until an organizer accepts it.
-- The existing four-character invitation code stays an alias used only to ask;
-- it never grants access to a group, route or address.

alter table app_private.together_join_requests
  drop constraint together_join_requests_status_check;
alter table app_private.together_join_requests
  add constraint together_join_requests_status_check
  check (status in ('pending', 'accepted', 'rejected', 'withdrawn'));
alter table app_private.together_join_requests
  drop constraint together_join_requests_check1;
alter table app_private.together_join_requests
  add constraint together_join_requests_decision_complete check (
    (status = 'pending' and decided_by is null and decided_at is null and decision_reason is null and not limit_overridden)
    or (status in ('accepted', 'rejected') and decided_by is not null and decided_at is not null
        and char_length(decision_reason) between 10 and 500)
    or (status = 'withdrawn' and decided_by is not null and decided_at is not null
        and char_length(decision_reason) between 5 and 500 and not limit_overridden)
  );

create or replace function app_private.attach_registration_to_together_party(
  _registration_id uuid,
  _requested_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
  select coalesce((settings ->> 'maxGroupSize')::integer, 10) into max_group_size
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
$$;

create or replace function api.together_join_request_withdraw(
  _request_id uuid,
  _expected_version integer,
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
  registration app_private.registrations;
begin
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  select * into request_record from app_private.together_join_requests where id = _request_id for update;
  select * into registration from app_private.registrations where id = request_record.requested_by_registration_id;
  if request_record.id is null or actor is null or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if request_record.status = 'withdrawn' then
    return jsonb_build_object('id', request_record.id, 'status', request_record.status, 'version', request_record.version);
  end if;
  if request_record.status <> 'pending' or request_record.version <> _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  update app_private.together_join_requests
  set status = 'withdrawn', decided_by = actor, decided_at = now(), decision_reason = left(trim(_reason), 500),
      updated_at = now(), version = version + 1
  where id = request_record.id returning * into request_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (request_record.event_id, actor, 'together.join_withdrawn', 'together_join_request', request_record.id,
    jsonb_build_object('reason', left(trim(_reason), 500)));
  return jsonb_build_object('id', request_record.id, 'status', request_record.status, 'version', request_record.version);
end;
$$;

revoke execute on function api.together_join_request_withdraw(uuid, integer, text) from public, anon;
grant execute on function api.together_join_request_withdraw(uuid, integer, text) to authenticated;
