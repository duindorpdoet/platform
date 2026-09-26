-- Human-facing cluster identity supplements, never replaces, party membership.
begin;

alter table app_private.together_parties add column cluster_reference text;
alter table app_private.together_parties add constraint together_cluster_reference_format
  check (cluster_reference is null or cluster_reference ~ '^SL-[0-9]{4}-[A-HJ-NP-Z2-9]{6}$');
alter table app_private.together_parties add constraint together_cluster_reference_unique
  unique (event_id, cluster_reference);

create function app_private.ensure_together_party_cluster_reference(_party_id uuid)
returns text language plpgsql set search_path = '' as $$
declare party app_private.together_parties; event_year text; candidate text; random_bytes bytea;
begin
  select * into party from app_private.together_parties where id = _party_id for update;
  if party.id is null then return null; end if;
  if party.cluster_reference is not null then return party.cluster_reference; end if;
  if (select count(distinct r.id) from app_private.together_memberships m
      join app_private.registrations r on r.id = m.registration_id
      where m.party_id = party.id and m.left_at is null
        and r.status = 'submitted' and r.event_id = party.event_id) < 2 then return null; end if;
  select to_char(local_date, 'YYYY') into event_year from app_private.events where id = party.event_id;
  -- 32 symbols divides the byte range exactly: no modulo bias, 30 random bits.
  for attempt in 1..32 loop
    random_bytes := extensions.gen_random_bytes(6);
    candidate := 'SL-' || event_year || '-';
    for digit in 0..5 loop
      candidate := candidate || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', get_byte(random_bytes, digit) % 32 + 1, 1);
    end loop;
    begin
      update app_private.together_parties set cluster_reference = candidate where id = party.id;
      return candidate;
    exception when unique_violation then
      -- Never recycle a historical reference; retry against the unique index.
    end;
  end loop;
  raise exception 'CLUSTER_REFERENCE_EXHAUSTED' using errcode = '54000';
end;
$$;
revoke all on function app_private.ensure_together_party_cluster_reference(uuid) from public, anon, authenticated;

create function app_private.protect_together_cluster_reference()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.cluster_reference is not null and (tg_op = 'DELETE'
      or new.cluster_reference is distinct from old.cluster_reference
      or new.event_id is distinct from old.event_id) then
    raise exception 'CLUSTER_REFERENCE_IMMUTABLE' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger together_cluster_reference_immutable before update or delete on app_private.together_parties
for each row execute function app_private.protect_together_cluster_reference();
revoke all on function app_private.protect_together_cluster_reference() from public, anon, authenticated;

-- Only identity is backfilled. No memberships, registrations or assignments move.
do $$
declare party_id uuid;
begin
  for party_id in select p.id from app_private.together_parties p
    join app_private.together_memberships m on m.party_id = p.id and m.left_at is null
    join app_private.registrations r on r.id = m.registration_id and r.event_id = p.event_id and r.status = 'submitted'
    where p.cluster_reference is null group by p.id having count(distinct r.id) >= 2 order by p.id
  loop perform app_private.ensure_together_party_cluster_reference(party_id); end loop;
end;
$$;

create function app_private.notify_together_membership_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare party_id uuid; event_id uuid;
begin
  for party_id in select distinct id from unnest(case when tg_op = 'INSERT' then array[new.party_id]
      when tg_op = 'DELETE' then array[old.party_id] else array[old.party_id, new.party_id] end) id order by id
  loop
    perform app_private.ensure_together_party_cluster_reference(party_id);
    select p.event_id into event_id from app_private.together_parties p where p.id = party_id;
    if event_id is not null then
      perform realtime.send(jsonb_build_object('partyId', party_id), 'snapshot_changed', 'admin-event:' || event_id::text, true);
    end if;
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger together_memberships_changed after insert or update or delete on app_private.together_memberships
for each row execute function app_private.notify_together_membership_change();
revoke all on function app_private.notify_together_membership_change() from public, anon, authenticated;

-- One set-based projection shared by the bounded overview, resolver and preview.
-- Authorization belongs to each API entrypoint; this private function is never granted.
create function app_private.together_management_parties(_event_id uuid)
returns table(party_id uuid, projection jsonb) language sql stable set search_path = '' as $$
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
      coalesce((e.settings ->> 'maxGroupSize')::integer, 10) max_size,
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
$$;
revoke all on function app_private.together_management_parties(uuid) from public, anon, authenticated;

create function app_private.require_together_manager(_event_slug text)
returns app_private.events language plpgsql stable set search_path = '' as $$
declare event_record app_private.events; actor uuid := auth.uid();
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return event_record;
end;
$$;
revoke all on function app_private.require_together_manager(text) from public, anon, authenticated;

create function api.admin_together_management_snapshot(_event_slug text, _query text default '', _limit integer default 100, _offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
      'maxGroupSize', coalesce((event_record.settings ->> 'maxGroupSize')::integer, 10),
      'confirmed', coalesce((select jsonb_agg(projection order by projection ->> 'clusterReference', party_id)
        from (select * from confirmed order by projection ->> 'clusterReference', party_id limit _limit offset _offset) page), '[]'::jsonb),
      'requests', coalesce((select jsonb_agg(data order by created_at, id) from (select * from requests order by created_at, id limit _limit offset _offset) page), '[]'::jsonb),
      'problems', coalesce((select jsonb_agg(projection order by party_id) from (select * from problems order by party_id limit _limit offset _offset) page), '[]'::jsonb),
      'totals', jsonb_build_object('confirmed', (select count(*) from confirmed), 'requests', (select count(*) from requests), 'problems', (select count(*) from problems)))
  );
end;
$$;

create function api.admin_together_resolve_identifier(_event_slug text, _identifier text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare event_record app_private.events; identifier text := upper(trim(_identifier)); resolved_party_id uuid; reg app_private.registrations; kind text; result jsonb;
begin
  event_record := app_private.require_together_manager(_event_slug);
  if identifier is null or length(identifier) not between 4 and 80 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if identifier ~ '^SL-[0-9]{4}-[A-HJ-NP-Z2-9]{6}$' then
    kind := 'cluster';
    select p.id into resolved_party_id from app_private.together_parties p where p.event_id = event_record.id and p.cluster_reference = identifier;
  else
    kind := case when identifier ~ '^[A-HJ-NP-Z2-9]{4}$' then 'together_code' else 'registration' end;
    select * into reg from app_private.registrations r where r.event_id = event_record.id and r.status = 'submitted'
      and (case when kind = 'together_code' then r.together_code = identifier else r.reference = identifier end);
    select m.party_id into resolved_party_id from app_private.together_memberships m where m.registration_id = reg.id and m.left_at is null;
  end if;
  select projection into result from app_private.together_management_parties(event_record.id) p where p.party_id = resolved_party_id;
  if result is null or (result ->> 'memberCount')::integer = 0 then raise exception 'IDENTIFIER_NOT_FOUND' using errcode = 'P0002'; end if;
  return result || jsonb_build_object('kind', kind, 'registrationId', coalesce(reg.id::text, result #>> '{members,0,id}'),
    'registrationReference', coalesce(reg.reference, result #>> '{members,0,reference}'));
end;
$$;

create function app_private.together_merge_preview(_event_id uuid, _source_party_id uuid, _target_party_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare source jsonb; target jsonb; blockers text[] := array[]::text[]; projected integer; max_size integer;
begin
  select projection into source from app_private.together_management_parties(_event_id) where party_id = _source_party_id;
  select projection into target from app_private.together_management_parties(_event_id) where party_id = _target_party_id;
  if source is null or target is null then raise exception 'PARTY_NOT_FOUND' using errcode = 'P0002'; end if;
  projected := (source ->> 'childCount')::integer + (target ->> 'childCount')::integer;
  max_size := (target ->> 'maxGroupSize')::integer;
  if _source_party_id = _target_party_id then blockers := array_append(blockers, 'same_party'); end if;
  if (source ->> 'locked')::boolean or (target ->> 'locked')::boolean then blockers := array_append(blockers, 'locked'); end if;
  if (source ->> 'published')::boolean or (target ->> 'published')::boolean then blockers := array_append(blockers, 'published'); end if;
  if source ->> 'phase' not in ('draft', 'registration_open', 'registration_closed', 'planning') then blockers := array_append(blockers, 'event_locked'); end if;
  if source -> 'assignmentKeys' <> target -> 'assignmentKeys' or jsonb_array_length(source -> 'assignmentKeys') <> 1
      or jsonb_array_length(target -> 'assignmentKeys') <> 1 then blockers := array_append(blockers, 'different_groups'); end if;
  if projected > max_size then blockers := array_append(blockers, 'over_capacity'); end if;
  if (source ->> 'memberCount')::integer < 1 or (target ->> 'memberCount')::integer < 1
      or (source -> 'problems') ?| array['inactive_registration', 'duplicate_membership']
      or (target -> 'problems') ?| array['inactive_registration', 'duplicate_membership'] then blockers := array_append(blockers, 'invalid_membership'); end if;
  -- An outgoing request represents an explicit, still undecided participant intent.
  -- Decide/withdraw it through the existing workflow before manually merging that party.
  if (source ->> 'outgoingRequest')::boolean or (target ->> 'outgoingRequest')::boolean then blockers := array_append(blockers, 'open_outgoing_request'); end if;
  return jsonb_build_object('source', source, 'target', target, 'projectedChildren', projected,
    'projectedRegistrations', (source ->> 'memberCount')::integer + (target ->> 'memberCount')::integer,
    'maxGroupSize', max_size, 'blockers', to_jsonb(blockers), 'canMerge', cardinality(blockers) = 0);
end;
$$;
revoke all on function app_private.together_merge_preview(uuid, uuid, uuid) from public, anon, authenticated;

create function api.admin_together_merge_preview(_event_slug text, _source_party_id uuid, _target_party_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare event_record app_private.events;
begin
  event_record := app_private.require_together_manager(_event_slug);
  return app_private.together_merge_preview(event_record.id, _source_party_id, _target_party_id);
end;
$$;

create function api.admin_merge_together_parties(_event_slug text, _source_party_id uuid, _target_party_id uuid,
  _expected_source_state text, _expected_target_state text, _reason text, _idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare event_record app_private.events; preview jsonb; result jsonb; request_hash text; receipt app_private.command_receipts;
  moved_ids uuid[]; member record; reference text;
begin
  event_record := app_private.require_together_manager(_event_slug);
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500
      or char_length(coalesce(_idempotency_key, '')) not between 10 and 100
      or _expected_source_state is null or _expected_target_state is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  -- Same event-first lock order as registration submission, group moves and decisions.
  perform id from app_private.events where id = event_record.id for update;
  request_hash := encode(extensions.digest(jsonb_build_array(event_record.id, _source_party_id, _target_party_id,
    _expected_source_state, _expected_target_state, trim(_reason))::text, 'sha256'), 'hex');
  select * into receipt from app_private.command_receipts where actor_id = auth.uid()
    and command_type = 'together.adminMerge' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '22023'; end if;
    return receipt.safe_result;
  end if;
  -- Child/cancellation commands lock registrations before their party; follow that
  -- order and freeze the rows represented in the preview before recomputing it.
  perform r.id from app_private.registrations r
    where r.event_id = event_record.id and exists (select 1 from app_private.together_memberships m
      where m.registration_id = r.id and m.party_id in (_source_party_id, _target_party_id) and m.left_at is null)
    order by r.id for update;
  perform id from app_private.together_parties where event_id = event_record.id and id in (_source_party_id, _target_party_id) order by id for update;
  perform g.id from app_private.walking_groups g where g.event_id = event_record.id and exists (
    select 1 from app_private.group_registrations a join app_private.together_memberships m on m.registration_id = a.registration_id
    where a.group_id = g.id and a.superseded_at is null and m.left_at is null and m.party_id in (_source_party_id, _target_party_id)
  ) order by g.id for update;
  preview := app_private.together_merge_preview(event_record.id, _source_party_id, _target_party_id);
  if preview #>> '{source,stateToken}' <> _expected_source_state or preview #>> '{target,stateToken}' <> _expected_target_state then
    raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not (preview ->> 'canMerge')::boolean then raise exception 'MERGE_BLOCKED' using errcode = '23514', detail = (preview -> 'blockers')::text; end if;
  for member in select id, registration_id from app_private.together_memberships
      where party_id = _source_party_id and left_at is null order by id for update
  loop
    update app_private.together_memberships set left_at = now() where id = member.id;
    insert into app_private.together_memberships(party_id, registration_id) values (_target_party_id, member.registration_id);
  end loop;
  update app_private.together_join_requests set target_party_id = _target_party_id, version = version + 1, updated_at = now()
    where target_party_id = _source_party_id and status = 'pending';
  update app_private.together_parties set locked_at = now() where id = _source_party_id;
  reference := app_private.ensure_together_party_cluster_reference(_target_party_id);
  select array_agg(registration_id order by registration_id) into moved_ids from app_private.together_memberships
    where party_id = _target_party_id and left_at is null;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, auth.uid(), 'together.admin_merged', 'together_party', _target_party_id,
      jsonb_build_object('sourcePartyId', _source_party_id, 'targetPartyId', _target_party_id,
        'sourceClusterReference', preview #>> '{source,clusterReference}', 'targetClusterReference', reference,
        'registrationIds', to_jsonb(moved_ids), 'childCount', preview -> 'projectedChildren', 'reason', trim(_reason)));
  result := jsonb_build_object('partyId', _target_party_id, 'clusterReference', reference, 'childCount', preview -> 'projectedChildren');
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
    values (auth.uid(), 'together.adminMerge', _idempotency_key, request_hash, result, now() + interval '10 years');
  perform realtime.send(jsonb_build_object('partyId', _target_party_id), 'snapshot_changed', 'admin-event:' || event_record.id::text, true);
  return result;
end;
$$;

revoke all on function api.admin_together_management_snapshot(text, text, integer, integer) from public, anon;
revoke all on function api.admin_together_resolve_identifier(text, text) from public, anon;
revoke all on function api.admin_together_merge_preview(text, uuid, uuid) from public, anon;
revoke all on function api.admin_merge_together_parties(text, uuid, uuid, text, text, text, text) from public, anon;
grant execute on function api.admin_together_management_snapshot(text, text, integer, integer) to authenticated;
grant execute on function api.admin_together_resolve_identifier(text, text) to authenticated;
grant execute on function api.admin_together_merge_preview(text, uuid, uuid) to authenticated;
grant execute on function api.admin_merge_together_parties(text, uuid, uuid, text, text, text, text) to authenticated;

-- Preserve the latest decision and retry contract, adding target identity and refresh.
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
$$;

revoke execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text)
  from public, anon;
grant execute on function api.admin_decide_together_request(uuid, integer, text, boolean, text)
  to authenticated;

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
$$;


-- A complete, organizer-only registration roster for the backoffice. The old
-- registrations tab only exposed exceptional change and together requests,
-- which made normal submitted registrations invisible to organizers.

create or replace function api.admin_registrations_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
begin
  select * into event_record
  from app_private.events
  where slug = _event_slug;

  if event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'registration_manage', actor)
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'submittedAt', registration.submitted_at,
        'updatedAt', registration.updated_at,
        'parentName', registration.parent_name,
        'parentEmail', registration.parent_email,
        'phone', registration.phone,
        'groupId', registration.group_id,
        'groupCode', registration.group_code,
        'groupName', coalesce(
          registration.group_name,
          case when registration.group_code is not null
            then 'Groep ' || registration.group_code
            else 'Groep van ' || registration.parent_name
          end
        ),
        'togetherCode', registration.together_code,
        'partyId', registration.party_id,
        'clusterReference', registration.cluster_reference,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'childCount', registration.child_count,
        'children', registration.children,
        'priceCents', registration.price_snapshot_cents
      )
      order by registration.submitted_at desc nulls last, registration.created_at desc, registration.id
    )
    from (
      select
        submitted.*,
        coalesce((
          select count(*)::integer
          from app_private.registration_children registration_child
          where registration_child.registration_id = submitted.id
            and registration_child.participation_status = 'active'
        ), 0) as child_count,
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', registration_child.id,
            'name', child.first_name,
            'age', child.age_at_event,
            'accessibilityNote', child.accessibility_note,
            'status', registration_child.participation_status
          ) order by child.first_name, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child on child.id = registration_child.child_id
          where registration_child.registration_id = submitted.id
        ), '[]'::jsonb) as children
      from (
        select
          registration.id,
          registration.reference,
          registration.status,
          registration.submitted_at,
          registration.created_at,
          registration.updated_at,
          registration.together_code,
          membership.party_id,
          party.cluster_reference,
          registration.preferred_start_at,
          registration.desired_end_at,
          registration.price_snapshot_cents,
          coalesce(
            nullif(trim(draft.payload #>> '{adult,name}'), ''),
            nullif(trim(profile.display_name), ''),
            household.label,
            'Ouder'
          ) as parent_name,
          lower(users.email) as parent_email,
          household.phone,
          assigned_group.id as group_id,
          assigned_group.system_code as group_code,
          assigned_group.display_name as group_name
        from app_private.registrations registration
        join app_private.households household on household.id = registration.household_id
        join auth.users users on users.id = household.primary_contact_user_id
        left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
        left join app_private.together_parties party on party.id = membership.party_id
        left join app_private.profiles profile on profile.user_id = household.primary_contact_user_id
        left join app_private.registration_drafts draft
          on draft.event_id = registration.event_id and draft.household_id = registration.household_id
        left join lateral (
          select walking_group.id, walking_group.system_code, walking_group.display_name
          from app_private.group_registrations assignment
          join app_private.walking_groups walking_group on walking_group.id = assignment.group_id
          where assignment.registration_id = registration.id and assignment.superseded_at is null
          order by assignment.assigned_at desc, assignment.id desc
          limit 1
        ) assigned_group on true
        where registration.event_id = event_record.id
          and registration.status <> 'draft'
      ) submitted
    ) registration
  ), '[]'::jsonb);
end;
$$;

revoke all on function api.admin_registrations_snapshot(text) from public, anon;
grant execute on function api.admin_registrations_snapshot(text) to authenticated;

comment on function api.admin_registrations_snapshot(text)
  is 'Returns submitted registrations and private contact details only to event or registration administrators.';

select pg_notify('pgrst', 'reload schema');

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
        or app_private.has_capability(event_record.id, 'registration_manage', _actor)
        or app_private.has_capability(event_record.id, 'portals_manage', _actor)
        or app_private.has_capability(event_record.id, 'live_support', _actor)
      )
    )
    else false end
$$;


create or replace function app_private.enqueue_together_request_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_party app_private.together_parties;
  target_registration app_private.registrations;
  recipient record;
  v_type text;
  v_group_name text;
  v_system_code text;
begin
  if tg_op = 'INSERT' then v_type := 'group_merge_requested';
  elsif old.status = 'pending' and new.status = 'accepted' then v_type := 'group_merge_approved';
  elsif old.status = 'pending' and new.status = 'rejected' then v_type := 'group_merge_declined';
  else return new;
  end if;

  select * into target_party
  from app_private.together_parties
  where id = new.target_party_id;
  if target_party.id is null then return new; end if;

  select registration.* into target_registration
  from app_private.registrations registration
  where registration.event_id = new.event_id
    and registration.household_id = target_party.creator_household_id
    and registration.status <> 'cancelled'
  order by registration.created_at, registration.id
  limit 1;

  select walking_group.display_name, walking_group.system_code
  into v_group_name, v_system_code
  from app_private.group_registrations assignment
  join app_private.walking_groups walking_group on walking_group.id = assignment.group_id
  where assignment.registration_id = target_registration.id
    and assignment.superseded_at is null
  order by assignment.assigned_at desc, assignment.id desc
  limit 1;
  v_group_name := coalesce(v_group_name, v_system_code, target_party.public_label, 'de hoofdgroep');

  for recipient in
    select distinct candidates.id, candidates.email
    from (
      -- A pending request is actionable only for the primary contact of the
      -- target (head) party. The requesting household must not receive the
      -- head-group template as though it could approve its own request.
      select users.id, lower(users.email) as email
      from app_private.households household
      join app_private.household_members member
        on member.household_id = household.id
       and member.user_id = household.primary_contact_user_id
       and member.revoked_at is null
      join auth.users users
        on users.id = member.user_id
       and users.email is not null
      where v_type = 'group_merge_requested'
        and household.id = target_party.creator_household_id

      union all

      -- Terminal decisions concern every registered adult who belonged to
      -- either party when the request was made. Looking at that timestamp
      -- also survives an accepted request moving the source memberships into
      -- the target party before this AFTER trigger runs.
      select users.id, lower(users.email) as email
      from app_private.together_memberships membership
      join app_private.registrations registration
        on registration.id = membership.registration_id
      join app_private.household_members member
        on member.household_id = registration.household_id
       and member.revoked_at is null
      join auth.users users
        on users.id = member.user_id
       and users.email is not null
      where v_type in ('group_merge_approved', 'group_merge_declined')
        and membership.party_id in (new.source_party_id, new.target_party_id)
        and membership.joined_at <= new.created_at
        and (membership.left_at is null or membership.left_at >= new.created_at)
    ) candidates
  loop
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'group-merge:' || new.id::text || ':' || v_type || ':' || recipient.id::text,
      v_type, recipient.id::text, recipient.email,
      jsonb_strip_nulls(jsonb_build_object(
        'requestId', new.id,
        'requestedCode', new.requested_code,
        'clusterReference', case when v_type = 'group_merge_approved' then target_party.cluster_reference else null end,
        'groupName', v_group_name,
        'headGroup', v_group_name,
        'groupCode', v_system_code,
        'systemCode', v_system_code,
        'actionPath', '/omgeving/meeloper/groep'
      ))
    ) on conflict (dedupe_key) do nothing;
  end loop;
  return new;
end;
$$;


-- The generic admin broadcaster emits only resource/id to the authorized event topic.
create trigger together_requests_admin_broadcast after insert or update or delete on app_private.together_join_requests
for each row execute function app_private.notify_admin_portal_source_change();

create function app_private.notify_together_registration_status_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare party_id uuid;
begin
  for party_id in select m.party_id from app_private.together_memberships m
    where m.registration_id = new.id and m.left_at is null order by m.party_id
  loop perform app_private.ensure_together_party_cluster_reference(party_id); end loop;
  perform realtime.send(jsonb_build_object('registrationId', new.id), 'snapshot_changed', 'admin-event:' || new.event_id::text, true);
  return new;
end;
$$;
create trigger together_registration_status_changed after update of status on app_private.registrations
for each row when (old.status is distinct from new.status)
execute function app_private.notify_together_registration_status_change();
revoke all on function app_private.notify_together_registration_status_change() from public, anon, authenticated;

commit;
