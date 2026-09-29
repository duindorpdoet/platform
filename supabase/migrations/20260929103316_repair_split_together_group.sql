-- Give group managers one bounded repair command for a together party that was
-- left across multiple draft walking groups. The target is chosen from current
-- database state, then the existing whole-party move command performs the
-- capacity, publication and locking checks atomically.

create function api.admin_group_repair_split_party(
  _event_slug text,
  _party_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  party_record app_private.together_parties;
  bundle_ids uuid[];
  active_member_count integer;
  location_count integer;
  target_group app_private.walking_groups;
  move_result jsonb;
begin
  select * into event_record
  from app_private.events
  where slug = _event_slug
  for update;

  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if event_record.phase not in ('draft', 'registration_open', 'registration_closed', 'planning') then
    raise exception 'GROUPS_FINALIZED' using errcode = '23514';
  end if;

  select * into party_record
  from app_private.together_parties
  where id = _party_id and event_id = event_record.id
  for update;
  if party_record.id is null then
    raise exception 'PARTY_NOT_FOUND' using errcode = 'P0002';
  end if;

  select count(*)::integer into active_member_count
  from app_private.together_memberships membership
  where membership.party_id = _party_id and membership.left_at is null;

  select coalesce(array_agg(registration.id order by registration.id), '{}'::uuid[])
  into bundle_ids
  from app_private.together_memberships membership
  join app_private.registrations registration
    on registration.id = membership.registration_id
  where membership.party_id = _party_id
    and membership.left_at is null
    and registration.event_id = event_record.id
    and registration.status = 'submitted';

  if cardinality(bundle_ids) < 2 or active_member_count <> cardinality(bundle_ids) then
    raise exception 'PARTY_NOT_REPAIRABLE' using errcode = '23514';
  end if;
  perform 1
  from app_private.registrations registration
  where registration.id = any(bundle_ids)
  order by registration.id
  for update;

  select count(distinct coalesce(assignment.group_id::text, 'unassigned'))::integer
  into location_count
  from unnest(bundle_ids) member_id
  left join app_private.group_registrations assignment
    on assignment.registration_id = member_id
   and assignment.superseded_at is null;
  if location_count < 2 then
    raise exception 'PARTY_NOT_SPLIT' using errcode = '23514';
  end if;

  -- Prefer the group containing the most registrations. Child count breaks a
  -- member-count tie; the immutable system order is the final deterministic
  -- tie-breaker so the correction never leaves the administrator stuck.
  select walking_group.* into target_group
  from app_private.walking_groups walking_group
  join (
    select
      assignment.group_id,
      count(*)::integer as member_count,
      sum((
        select count(*)
        from app_private.registration_children child
        where child.registration_id = assignment.registration_id
          and child.participation_status = 'active'
      ))::integer as child_count
    from app_private.group_registrations assignment
    where assignment.registration_id = any(bundle_ids)
      and assignment.superseded_at is null
    group by assignment.group_id
  ) ranked on ranked.group_id = walking_group.id
  where walking_group.event_id = event_record.id
  order by ranked.member_count desc, ranked.child_count desc, walking_group.system_number asc
  limit 1;
  if target_group.id is null then
    raise exception 'PARTY_REPAIR_TARGET_NOT_FOUND' using errcode = 'P0002';
  end if;

  move_result := api.admin_group_move_registration(
    _event_slug,
    bundle_ids[1],
    target_group.id
  );

  return move_result || jsonb_build_object(
    'partyId', _party_id,
    'targetSystemCode', target_group.system_code,
    'targetDisplayName', target_group.display_name
  );
end;
$$;

revoke execute on function api.admin_group_repair_split_party(text, uuid) from public, anon;
grant execute on function api.admin_group_repair_split_party(text, uuid) to authenticated;
