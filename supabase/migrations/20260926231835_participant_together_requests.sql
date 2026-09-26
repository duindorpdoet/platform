-- Participants can manage their own pending request without resolving another household.
begin;
create function api.registration_together_snapshot(_registration_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare registration app_private.registrations; party app_private.together_parties; event_record app_private.events;
  member_count integer; locked boolean; pending boolean;
begin
  select * into registration from app_private.registrations where id = _registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where id = registration.event_id;
  select p.* into party from app_private.together_parties p join app_private.together_memberships m on m.party_id=p.id
    where m.registration_id=registration.id and m.left_at is null;
  select count(*)::integer into member_count from app_private.together_memberships m
    join app_private.registrations r on r.id=m.registration_id and r.status='submitted' and r.event_id=registration.event_id
    where m.party_id=party.id and m.left_at is null;
  locked := registration.status <> 'submitted' or party.id is null or party.locked_at is not null
    or event_record.phase not in ('draft','registration_open','registration_closed','planning')
    or exists(select 1 from app_private.together_memberships m join app_private.group_registrations a on a.registration_id=m.registration_id and a.superseded_at is null
      join app_private.walking_groups g on g.id=a.group_id where m.party_id=party.id and m.left_at is null
      and (g.status <> 'draft' or a.published_at is not null or exists(select 1 from app_private.group_schedule_revisions s where s.group_id=g.id and s.state='published')));
  pending := exists(select 1 from app_private.together_join_requests q where q.source_party_id=party.id and q.status='pending');
  return jsonb_build_object('registrationId', registration.id, 'togetherCode', registration.together_code,
    'clusterReference', party.cluster_reference, 'memberCount', member_count,
    'confirmed', member_count > 1, 'canRequest', not locked and not pending,
    'locked', locked, 'realtimeTopic', 'registration:' || registration.id::text,
    'requests', coalesce((select jsonb_agg(item order by is_pending desc, created_at desc, id) from (
      select q.id, q.created_at, q.status='pending' is_pending, jsonb_build_object('id', q.id, 'version', q.version,
        'status', q.status, 'requestedCode', q.requested_code, 'createdAt', q.created_at,
        'direction', case when q.requested_by_registration_id=registration.id or exists (
          select 1 from app_private.together_memberships m where m.registration_id=registration.id and m.party_id=q.source_party_id
            and m.joined_at<=q.created_at and (m.left_at is null or m.left_at>=q.created_at)) then 'outgoing' else 'incoming' end,
        'canWithdraw', q.status='pending' and exists(select 1 from app_private.registrations requester
          where requester.id=q.requested_by_registration_id and app_private.is_household_member(requester.household_id))) item
      from app_private.together_join_requests q where q.event_id=registration.event_id and (
        q.requested_by_registration_id=registration.id or exists(select 1 from app_private.together_memberships m
          where m.registration_id=registration.id and m.party_id in(q.source_party_id,q.target_party_id)
            and m.joined_at<=q.created_at and (m.left_at is null or m.left_at>=q.created_at)))
      order by (q.status='pending') desc,q.created_at desc,q.id limit 20
    ) requests), '[]'::jsonb));
end;
$$;

create function api.registration_together_request(_registration_id uuid, _together_code text, _idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare registration app_private.registrations; event_record app_private.events; source_id uuid; target_id uuid;
  code text:=upper(trim(_together_code)); request app_private.together_join_requests; preview jsonb;
  receipt app_private.command_receipts; request_hash text; result jsonb;
begin
  select * into registration from app_private.registrations where id=_registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if code is null or code !~ '^[A-HJ-NP-Z2-9]{4}$' then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  if char_length(coalesce(_idempotency_key,'')) not between 10 and 100 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  select * into event_record from app_private.events where id=registration.event_id for update;
  select * into registration from app_private.registrations where id=_registration_id for update;
  request_hash:=encode(extensions.digest(jsonb_build_array(registration.id,code)::text,'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='together.participantRequest' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023'; end if;
    return receipt.safe_result;
  end if;
  if registration.status<>'submitted' or event_record.phase not in('draft','registration_open','registration_closed','planning') then
    raise exception 'TOGETHER_LOCKED' using errcode='23514'; end if;
  select party_id into source_id from app_private.together_memberships where registration_id=registration.id and left_at is null;
  select m.party_id into target_id from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null
    where r.event_id=registration.event_id and r.together_code=code and r.status='submitted';
  if source_id is null or target_id is null or source_id=target_id then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  perform id from app_private.together_parties where id in(source_id,target_id) order by id for update;
  select * into request from app_private.together_join_requests where source_party_id=source_id and status='pending';
  if request.id is not null then
    if request.requested_by_registration_id<>registration.id or request.requested_code<>code then
      raise exception 'OPEN_TOGETHER_REQUEST' using errcode='23514'; end if;
  else
    preview:=app_private.together_merge_preview(event_record.id,source_id,target_id);
    -- Capacity above the configured limit remains an explicit organizer decision;
    -- locked/publication/group conflicts cannot be introduced through this new entrypoint.
    if jsonb_array_length((preview->'blockers') - 'over_capacity')>0 or (preview->>'projectedChildren')::integer>20 then
      raise exception 'TOGETHER_REQUEST_BLOCKED' using errcode='23514'; end if;
    insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,
      requested_code,child_count_at_request,group_limit_at_request)
    values(event_record.id,source_id,target_id,registration.id,code,(preview#>>'{source,childCount}')::integer,
      (preview->>'maxGroupSize')::integer) returning * into request;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(event_record.id,auth.uid(),'together.join_requested','registration',registration.id,
        jsonb_build_object('requestId',request.id,'requiresApproval',true));
  end if;
  result:=jsonb_build_object('id',request.id,'status',request.status,'version',request.version);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'together.participantRequest',_idempotency_key,request_hash,result,now()+interval '10 years');
  return result;
end;
$$;

-- Participant channels remain scoped to the registration's own household.
create or replace function app_private.can_access_realtime_topic(_topic text, _actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select _actor is not null and case
    when _topic like 'registration:%' then exists (select 1 from app_private.registrations r
      where r.id::text = split_part(_topic, ':', 2) and app_private.is_household_member(r.household_id, _actor))
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

create function app_private.notify_participant_together_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare registration_id uuid;
begin
  if tg_table_name='together_memberships' then
    -- Existing members also need the new count/reference, as does a leaving member.
    for registration_id in select distinct m.registration_id from app_private.together_memberships m
      where m.party_id=any(case when tg_op='INSERT' then array[new.party_id]
        when tg_op='DELETE' then array[old.party_id] else array[old.party_id,new.party_id] end)
        and m.left_at is null
      union select case when tg_op='DELETE' then old.registration_id else new.registration_id end
    loop
      perform realtime.send(jsonb_build_object('registrationId',registration_id),'snapshot_changed','registration:'||registration_id::text,true);
    end loop;
  else
    for registration_id in select distinct m.registration_id from app_private.together_memberships m
      where m.party_id in(new.source_party_id,new.target_party_id) and m.left_at is null
      union select new.requested_by_registration_id
    loop
      perform realtime.send(jsonb_build_object('registrationId',registration_id),'snapshot_changed','registration:'||registration_id::text,true);
    end loop;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
create trigger participant_together_requests_changed after insert or update on app_private.together_join_requests
for each row execute function app_private.notify_participant_together_change();
create trigger participant_together_memberships_changed after insert or update or delete on app_private.together_memberships
for each row execute function app_private.notify_participant_together_change();
revoke all on function app_private.notify_participant_together_change() from public,anon,authenticated;
revoke all on function api.registration_together_snapshot(uuid) from public,anon;
revoke all on function api.registration_together_request(uuid,text,text) from public,anon;
grant execute on function api.registration_together_snapshot(uuid) to authenticated;
grant execute on function api.registration_together_request(uuid,text,text) to authenticated;
select pg_notify('pgrst','reload schema');
commit;
