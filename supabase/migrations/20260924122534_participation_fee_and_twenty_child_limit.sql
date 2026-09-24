-- New registrations use the new event price. Existing registration snapshots,
-- invoices and payment entries (including unpaid requests) remain unchanged.
update app_private.events
set price_cents = 250,
    settings = settings || jsonb_build_object('maxGroupSize', 20),
    settings_version = settings_version + 1,
    updated_at = now()
where slug = 'duindorp-halloween-2026';

create or replace function api.admin_set_group_size_limit(
  _event_slug text,
  _max_group_size integer,
  _expected_settings_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  previous_limit integer;
  largest_existing_party integer;
begin
  if _max_group_size is null or _max_group_size not between 2 and 20
     or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if event_record.settings_version <> _expected_settings_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select coalesce(max(party_size.child_count), 0)
  into largest_existing_party
  from (
    select app_private.together_party_child_count(party.id) as child_count
    from app_private.together_parties party
    where party.event_id = event_record.id and party.locked_at is null
      and party.capacity_override_at is null
  ) party_size;
  if largest_existing_party > _max_group_size then
    raise exception 'GROUP_SIZE_LIMIT_BELOW_ACTIVE_PARTY' using errcode = '23514',
      detail = jsonb_build_object(
        'largestExistingParty', largest_existing_party,
        'requestedLimit', _max_group_size
      )::text;
  end if;
  previous_limit := coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10);
  update app_private.events
  set settings = settings || jsonb_build_object('maxGroupSize', _max_group_size),
      settings_version = settings_version + 1,
      updated_at = now()
  where id = event_record.id
  returning * into event_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    event_record.id, actor, 'group_size_limit.updated', 'event', event_record.id,
    jsonb_build_object('from', previous_limit, 'to', _max_group_size, 'reason', left(trim(_reason), 500))
  );
  return jsonb_build_object(
    'settingsVersion', event_record.settings_version,
    'maxGroupSize', _max_group_size
  );
end;
$$;


alter function api.registration_preferences_snapshot(text) set schema app_private;
alter function app_private.registration_preferences_snapshot(text) rename to registration_preferences_snapshot_before_fee;
revoke execute on function app_private.registration_preferences_snapshot_before_fee(text) from public, anon, authenticated;
create function api.registration_preferences_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; event_record app_private.events;
begin
  result := app_private.registration_preferences_snapshot_before_fee(_event_slug);
  select * into event_record from app_private.events where slug = _event_slug;
  return jsonb_set(result, '{event}', coalesce(result -> 'event', '{}'::jsonb) || jsonb_build_object(
    'priceCents', event_record.price_cents,
    'maxGroupSize', least(coalesce((event_record.settings ->> 'maxGroupSize')::integer, 20), 20)
  ), true);
end;
$$;
revoke execute on function api.registration_preferences_snapshot(text) from public, anon;
grant execute on function api.registration_preferences_snapshot(text) to authenticated;

-- Shared guards also cover direct admin assignment, merged households and
-- child activation. Existing oversized history is not deleted or split.
create function app_private.enforce_twenty_child_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare total integer; target uuid;
begin
  if tg_table_name = 'together_memberships' then
    if new.left_at is not null then return new; end if;
    perform 1 from app_private.together_parties where id = new.party_id for update;
    select count(*)::integer into total
    from app_private.registration_children child
    where child.participation_status = 'active'
      and (child.registration_id = new.registration_id or child.registration_id in (
        select membership.registration_id from app_private.together_memberships membership
        where membership.party_id = new.party_id and membership.left_at is null and membership.id <> new.id
      ));
  elsif tg_table_name = 'group_registrations' then
    if new.superseded_at is not null then return new; end if;
    perform 1 from app_private.walking_groups where id = new.group_id for update;
    select count(*)::integer into total
    from app_private.registration_children child
    where child.participation_status = 'active'
      and (child.registration_id = new.registration_id or child.registration_id in (
        select assignment.registration_id from app_private.group_registrations assignment
        where assignment.group_id = new.group_id and assignment.superseded_at is null and assignment.id <> new.id
      ));
  else
    if new.participation_status <> 'active' then return new; end if;
    perform 1 from app_private.registrations where id = new.registration_id for update;
    select count(*)::integer + 1 into total from app_private.registration_children child
    where child.registration_id = new.registration_id and child.participation_status = 'active' and child.id <> new.id;
    if total > 20 then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514'; end if;
    for target in select party_id from app_private.together_memberships
      where registration_id = new.registration_id and left_at is null order by party_id loop
      perform 1 from app_private.together_parties where id = target for update;
      select count(*)::integer + 1 into total from app_private.registration_children child
      join app_private.together_memberships membership on membership.registration_id = child.registration_id
      where membership.party_id = target and membership.left_at is null
        and child.participation_status = 'active' and child.id <> new.id;
      if total > 20 then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514'; end if;
    end loop;
    for target in select group_id from app_private.group_registrations
      where registration_id = new.registration_id and superseded_at is null order by group_id loop
      perform 1 from app_private.walking_groups where id = target for update;
      select count(*)::integer + 1 into total from app_private.registration_children child
      join app_private.group_registrations assignment on assignment.registration_id = child.registration_id
      where assignment.group_id = target and assignment.superseded_at is null
        and child.participation_status = 'active' and child.id <> new.id;
      if total > 20 then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514'; end if;
    end loop;
  end if;
  if total > 20 then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514'; end if;
  return new;
end;
$$;
create trigger together_memberships_twenty_child_limit before insert or update of party_id, registration_id, left_at
on app_private.together_memberships for each row execute function app_private.enforce_twenty_child_limit();
create trigger group_registrations_twenty_child_limit before insert or update of group_id, registration_id, superseded_at
on app_private.group_registrations for each row execute function app_private.enforce_twenty_child_limit();
create trigger registration_children_twenty_child_limit before insert or update of registration_id, participation_status
on app_private.registration_children for each row execute function app_private.enforce_twenty_child_limit();
revoke execute on function app_private.enforce_twenty_child_limit() from public, anon, authenticated;

create function app_private.guard_registration_draft_child_limit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if jsonb_typeof(new.payload -> 'children') = 'array'
    and jsonb_array_length(new.payload -> 'children') > 20 then
    raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger registration_draft_twenty_child_limit before insert or update of payload
on app_private.registration_drafts for each row execute function app_private.guard_registration_draft_child_limit();
revoke execute on function app_private.guard_registration_draft_child_limit() from public, anon, authenticated;
