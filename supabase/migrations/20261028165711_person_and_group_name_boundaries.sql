-- Person identities and walking-group labels are different domain fields.
-- Resolve display data at read time; preserve accounts, memberships, messages,
-- recipient identities and all previously sent mail payloads unchanged.
set lock_timeout = '5s';

create or replace function app_private.usable_person_name(_event uuid, _name text)
returns text language sql stable security definer set search_path = '' as $$
  select nullif(trim(_name),'') where nullif(trim(_name),'') is not null
    and trim(_name) !~ '[@[:cntrl:]]'
    and trim(_name) !~* '^(G[-–— ]?[0-9]+|SL-[0-9]{4}-[A-Z0-9]+|[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})$'
    and not exists(select 1 from app_private.walking_groups g where g.event_id=_event
      and trim(_name) in (g.system_code,g.code))
$$;
create or replace function app_private.participant_person_identity(_event uuid, _user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with account_name as (
    select p.user_id,p.display_name,app_private.usable_person_name(_event,p.display_name) name
    from app_private.profiles p where p.user_id=_user
  ), original_contacts as (
    -- A household contact name identifies its primary contact, never another
    -- adult or an arbitrarily selected member of a multi-household group.
    select d.id,d.payload #>> '{adult,name}' original_name,
      app_private.usable_person_name(_event,d.payload #>> '{adult,name}') name
    from app_private.registration_drafts d join app_private.households h on h.id=d.household_id
    where d.event_id=_event and h.primary_contact_user_id=_user
  ), unique_contact as (
    select min(name) name from original_contacts where name is not null
    having count(distinct name)=1
  )
  select jsonb_build_object('personName',coalesce((select name from account_name),(select name from unique_contact)),
    'source',case when (select name from account_name) is not null then 'profile'
      when (select name from unique_contact) is not null then 'registration_contact' else null end)
$$;
create or replace function app_private.participant_person_name(_event uuid, _user uuid)
returns text language sql stable security definer set search_path = '' as $$
  select app_private.participant_person_identity(_event,_user)->>'personName'
$$;
create or replace function app_private.registration_person_name(_registration uuid)
returns text language sql stable security definer set search_path = '' as $$
  select app_private.participant_person_name(r.event_id,h.primary_contact_user_id)
    from app_private.registrations r join app_private.households h on h.id=r.household_id where r.id=_registration
$$;
revoke all on function app_private.usable_person_name(uuid,text),
  app_private.participant_person_identity(uuid,uuid),app_private.participant_person_name(uuid,uuid),
  app_private.registration_person_name(uuid) from public,anon,authenticated;

create or replace function app_private.messenger_subject_metadata(_event_id uuid,_subject_kind text,_subject_id uuid,_participant_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare person_name text := app_private.participant_person_name(_event_id,_participant_user_id);
  household_label text; group_code text; group_name text; portal_name text; context_code text;
begin
  select min(h.label) into household_label from app_private.households h
    join app_private.household_members m on m.household_id=h.id and m.user_id=_participant_user_id and m.revoked_at is null
    where exists(select 1 from app_private.registrations r where r.household_id=h.id and r.event_id=_event_id and r.status<>'cancelled')
    having count(distinct h.id)=1;
  if _subject_kind='group' then
    select g.system_code,g.display_name into group_code,group_name from app_private.walking_groups g
      where g.id=_subject_id and g.event_id=_event_id;
  elsif _subject_kind='viewer' then
    select g.system_code,g.display_name into group_code,group_name from app_private.group_viewer_access v
      join app_private.walking_groups g on g.id=v.group_id where v.id=_subject_id and v.event_id=_event_id;
  elsif _subject_kind='portal' then
    select p.system_code,p.name into context_code,portal_name from app_private.portals p
      where p.id=_subject_id and p.event_id=_event_id;
  end if;
  return jsonb_build_object('personName',person_name,'householdLabel',household_label,
    'groupCode',group_code,'groupName',group_name,'portalName',portal_name,
    'subjectLabel',concat_ws(' · ',coalesce(person_name,'Deelnemer'),coalesce(group_code,context_code)),
    'systemCode',coalesce(group_code,context_code),'displayName',coalesce(person_name,'Deelnemer'));
end;
$$;

-- Payment projections already use this private name helper; keep their
-- authorization, financial data and recipient selection unchanged.
create or replace function app_private.payment_parent_name(_registration_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(app_private.registration_person_name(_registration_id),'Deelnemer')
$$;

create or replace function app_private.messenger_conversation_payload(
  _conversation_id uuid,
  _organization_view boolean,
  _actor uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conversation app_private.messenger_conversations;
  metadata jsonb;
begin
  select * into conversation from app_private.messenger_conversations where id = _conversation_id;
  if conversation.id is null then return null; end if;
  if (_organization_view and not app_private.messenger_is_organizer(conversation.event_id, _actor))
     or (not _organization_view and (
       conversation.participant_user_id <> _actor
       or not app_private.messenger_actor_can_use_subject(
         conversation.event_id, _actor, conversation.subject_kind, conversation.subject_id
       )
     )) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  metadata := app_private.messenger_subject_metadata(
    conversation.event_id, conversation.subject_kind, conversation.subject_id, conversation.participant_user_id
  );
  return jsonb_build_object(
    'id', conversation.id,
    'subjectKind', conversation.subject_kind,
    'subjectId', conversation.subject_id,
    'subjectLabel', metadata ->> 'subjectLabel',
    'systemCode', metadata -> 'systemCode',
    'displayName', metadata ->> 'displayName',
    'personName',metadata->'personName','householdLabel',metadata->'householdLabel',
    'groupCode',metadata->'groupCode','groupName',metadata->'groupName','portalName',metadata->'portalName',
    'status', conversation.status,
    'version', conversation.version,
    'claimedBy', case when _organization_view then to_jsonb(conversation.claimed_by) else null end,
    'updatedAt', conversation.updated_at,
    'unreadCount', (
      select count(*) from app_private.messenger_messages message
      where message.conversation_id = conversation.id and message.read_at is null
        and message.sender_side = case when _organization_view then 'participant' else 'organization' end
    ),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', message.id,
        'senderSide', message.sender_side,
        'senderName',case when message.sender_side='organization' then 'Organisatie'
          else app_private.participant_person_name(conversation.event_id,message.sender_id) end,
        'body', message.body,
        'createdAt', message.created_at,
        'isMine', message.sender_side = case when _organization_view then 'organization' else 'participant' end,
        'readAt', message.read_at,
        'mailStatus', (
          select outbox.status::text from app_private.email_outbox outbox
          where outbox.dedupe_key = case
            when message.sender_side = 'organization' then 'messenger-admin-reply:' || message.id::text
            else 'messenger-incoming-admin:' || conversation.id::text || ':' || to_char(message.created_at at time zone 'UTC', 'YYYYMMDDHH24')
          end limit 1
        )
      ) order by message.created_at, message.id)
      from (
        select recent.*
        from app_private.messenger_messages recent
        where recent.conversation_id = conversation.id
        order by recent.created_at desc, recent.id desc
        limit 100
      ) message
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.participant_messenger_context(
  _event_slug text,
  _role text,
  _group_id uuid default null,
  _portal_id uuid default null,
  _viewer_access_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  context_subject_kind text;
  context_subject_id uuid;
  metadata jsonb;
  conversation_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  case _role
    when 'walker' then context_subject_kind := 'group'; context_subject_id := _group_id;
    when 'group' then context_subject_kind := 'group'; context_subject_id := _group_id;
    when 'homeowner' then context_subject_kind := 'portal'; context_subject_id := _portal_id;
    when 'portal' then context_subject_kind := 'portal'; context_subject_id := _portal_id;
    when 'viewer' then context_subject_kind := 'viewer'; context_subject_id := _viewer_access_id;
    when 'user' then context_subject_kind := 'user'; context_subject_id := actor;
    else raise exception 'INVALID_MESSENGER_ROLE' using errcode = '22023';
  end case;
  if not app_private.messenger_actor_can_use_subject(
    event_record.id, actor, context_subject_kind, context_subject_id
  ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  metadata := app_private.messenger_subject_metadata(
    event_record.id, context_subject_kind, context_subject_id, actor
  );
  select candidate.id into conversation_id
  from app_private.messenger_conversations candidate
  where candidate.event_id = event_record.id
    and candidate.participant_user_id = actor
    and candidate.subject_kind = context_subject_kind
    and candidate.subject_id = context_subject_id
  order by (candidate.status <> 'closed') desc, candidate.last_message_at desc
  limit 1;
  return jsonb_build_object(
    'available', exists (
      select 1 from app_private.messenger_admin_presence presence
      where presence.event_id = event_record.id and presence.available_until > now()
    ),
    'subjectKind', context_subject_kind,
    'subjectId', context_subject_id,
    'subjectLabel', metadata ->> 'subjectLabel',
    'systemCode', metadata -> 'systemCode',
    'displayName', metadata ->> 'displayName',
    'personName',metadata->'personName','householdLabel',metadata->'householdLabel',
    'groupCode',metadata->'groupCode','groupName',metadata->'groupName','portalName',metadata->'portalName',
    'conversation', case when conversation_id is null then null
      else app_private.messenger_conversation_payload(conversation_id, false, actor) end
  );
end;
$$;

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
        'personName',app_private.registration_person_name(r.id),
        'parentName',coalesce(app_private.registration_person_name(r.id),'Deelnemer'),
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
        'personName',app_private.registration_person_name(registration.id),
        'householdLabel',registration.household_label,
        'parentEmail', registration.parent_email,
        'phone', registration.phone,
        'groupId', registration.group_id,
        'groupCode', registration.group_code,
        'groupName', coalesce(
          registration.group_name,
          case when registration.group_code is not null
            then 'Groep ' || registration.group_code
            else 'Nog niet ingedeeld'
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
          coalesce(app_private.registration_person_name(registration.id),'Deelnemer') as parent_name,
          lower(users.email) as parent_email,
          household.phone,
          household.label as household_label,
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
    'targetGroupSize',coalesce((event_record.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(event_record.id))),
    'inputHash',app_private.group_operations_hash(event_record.id),
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id,
        'systemCode', walking_group.system_code,
        'displayName', walking_group.display_name,
        'status', walking_group.status,
        'version', walking_group.version,
        'compositionConfirmed',walking_group.composition_confirmed_hash=app_private.start_group_composition_hash(walking_group.id),
        'compositionRevision',walking_group.composition_revision,
        'communication',coalesce((select jsonb_object_agg(mail.status,mail.n) from (select o.status,count(*) n from app_private.email_outbox o where o.payload->>'groupId'=walking_group.id::text and o.message_type in ('group_composition_confirmed','group_schedule_published','group_schedule_corrected') group by o.status) mail),'{}'),
        'confirmedAt',walking_group.composition_confirmed_at,
        'preferredStartAt',app_private.dominant_start_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=walking_group.id and a.superseded_at is null)),
        'start',app_private.published_start_projection(walking_group.id),
        'draftStart',(select jsonb_build_object('startsAt',slot.starts_at,'pointId',slot.start_point_id,'state',s.state) from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id where s.id=walking_group.current_schedule_revision_id),
        'locked', (walking_group.composition_confirmed_hash=app_private.start_group_composition_hash(walking_group.id)) or walking_group.status in ('ready', 'live', 'completed', 'stopped') or exists (
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
          'personName',app_private.registration_person_name(registration.id),
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
          'paymentEligible',exists(select 1 from app_private.payment_requests p where p.registration_id=registration.id and p.status in ('confirmed','waived')),
          'assignmentPublished', assignment.published_at is not null
        ) order by household.label, registration.reference)
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          join app_private.households household on household.id = registration.household_id
          left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
          left join app_private.together_memberships membership
            on membership.registration_id = registration.id and membership.left_at is null
          left join app_private.together_parties party on party.id = membership.party_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null and registration.status='submitted'), '[]'::jsonb)
      ) order by walking_group.system_number)
      from app_private.walking_groups walking_group where walking_group.event_id = event_record.id and walking_group.retired_at is null
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'householdLabel', household.label,
          'personName',app_private.registration_person_name(registration.id),
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
        'paymentEligible',exists(select 1 from app_private.payment_requests p where p.registration_id=registration.id and p.status in ('confirmed','waived')),
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
  -- A walking-group name is group context, never a person's identity.

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
        'personName',app_private.participant_person_name(new.event_id,recipient.id),
        'householdLabel',(select min(h.label) from app_private.households h
          where h.primary_contact_user_id=recipient.id and exists(select 1 from app_private.registrations r where r.household_id=h.id and r.event_id=new.event_id)
          having count(distinct h.id)=1),
        'requesterPersonName',app_private.registration_person_name(new.requested_by_registration_id),
        'targetContactName',app_private.registration_person_name(target_registration.id),
        'groupCode', v_system_code,
        'systemCode', v_system_code,
        'actionPath', '/omgeving/meeloper/groep'
      ))
    ) on conflict (dedupe_key) do nothing;
  end loop;
  return new;
end;
$$;

revoke all on function app_private.messenger_subject_metadata(uuid,text,uuid,uuid),app_private.messenger_conversation_payload(uuid,boolean,uuid),app_private.payment_parent_name(uuid),app_private.enqueue_together_request_email() from public,anon,authenticated;
notify pgrst, 'reload schema';

-- New walking-group notifications resolve the specific adult recipient at
-- enqueue time. No existing outbox row, recipient or mail identity is changed.
create or replace function app_private.enrich_group_mail_person_name()
returns trigger language plpgsql security definer set search_path = '' as $$
declare event_id uuid; recipient_id uuid;
begin
  if new.message_type not in ('group_composition_confirmed','group_schedule_published','group_schedule_corrected') then return new; end if;
  select g.event_id into event_id from app_private.walking_groups g where g.id::text=new.payload->>'groupId';
  select u.id into recipient_id from auth.users u where u.id::text=new.recipient_ref;
  if event_id is not null and recipient_id is not null then
    new.payload := new.payload || jsonb_build_object('personName',app_private.participant_person_name(event_id,recipient_id));
  end if;
  return new;
end;
$$;
create trigger group_mail_person_name before insert on app_private.email_outbox
for each row execute function app_private.enrich_group_mail_person_name();
revoke all on function app_private.enrich_group_mail_person_name() from public,anon,authenticated;

create or replace function app_private.enqueue_messenger_notification(
  _conversation_id uuid,
  _message_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  conversation app_private.messenger_conversations;
  message app_private.messenger_messages;
  event_record app_private.events;
  recipient_email text;
begin
  select * into conversation from app_private.messenger_conversations where id = _conversation_id;
  select * into message from app_private.messenger_messages where id = _message_id and conversation_id = _conversation_id;
  select * into event_record from app_private.events where id = conversation.event_id;
  if conversation.id is null or message.id is null then raise exception 'MESSENGER_MESSAGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if message.sender_side = 'participant' then
    recipient_email := lower(trim(event_record.settings ->> 'supportEmail'));
    if recipient_email is not null and recipient_email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'messenger-incoming-admin:' || conversation.id::text || ':' || to_char(message.created_at at time zone 'UTC', 'YYYYMMDDHH24'),
        'messenger_incoming_admin', conversation.id::text, recipient_email,
        jsonb_build_object('conversationId', conversation.id, 'actionPath', '/admin?section=messenger')
      ) on conflict (dedupe_key) do nothing;
    end if;
  else
    select lower(users.email) into recipient_email from auth.users users
    where users.id = conversation.participant_user_id and users.email_confirmed_at is not null;
    if recipient_email is not null then
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      values (
        'messenger-admin-reply:' || message.id::text,
        'messenger_admin_reply', conversation.id::text, recipient_email,
        jsonb_build_object('conversationId', conversation.id,
          'personName',app_private.participant_person_name(conversation.event_id,conversation.participant_user_id),
          'actionPath', '/omgeving')
      ) on conflict (dedupe_key) do nothing;
    end if;
  end if;
end;
$$;
revoke all on function app_private.enqueue_messenger_notification(uuid,uuid) from public,anon,authenticated;
notify pgrst, 'reload schema';

create or replace function api.participant_profile_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  context jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then return null; end if;
  context := api.participant_context(_event_slug);
  insert into app_private.participant_preferences(event_id, user_id)
  values (v_event_id, actor) on conflict (event_id, user_id) do nothing;
  return jsonb_build_object(
    'displayName',app_private.participant_person_name(v_event_id,actor),
    'personName',app_private.participant_person_name(v_event_id,actor),
    'email', (select lower(email) from auth.users where id = actor),
    'roles', context -> 'roles',
    'preferences', (
      select jsonb_build_object(
        'emailUpdates', preference.email_updates,
        'reducedMotion', preference.reduced_motion,
        'readableMode', preference.readable_mode,
        'optionalUpdatesConsent', preference.optional_updates_consent,
        'version', preference.version
      ) from app_private.participant_preferences preference
      where preference.event_id = v_event_id and preference.user_id = actor
    )
  );
end;
$$;

create or replace function api.worker_group_schedule_mail_payload(_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare message app_private.email_outbox; publication app_private.group_start_publications; previous app_private.email_outbox; result jsonb; kind text;
begin
 select * into message from app_private.email_outbox where id=_outbox_id and message_type in ('group_schedule_published','group_schedule_corrected','group_composition_confirmed','group_assignment_withdrawn') for update;
 if message.id is null or message.status in ('suppressed','delivered','failed') then return null;end if;
 if message.message_type='group_assignment_withdrawn' then
  if not exists(select 1 from app_private.registrations r join app_private.household_members m on m.household_id=r.household_id and m.user_id::text=message.recipient_ref and m.revoked_at is null and m.accepted_at is not null where r.event_id=(message.payload->>'eventId')::uuid and r.status='submitted') then return null;end if;
  return message.payload;
 end if;
 if not exists(select 1 from app_private.group_adult_recipients((message.payload->>'groupId')::uuid) r where r.user_id::text=message.recipient_ref and r.email=lower(message.recipient_email)) then return null;end if;
 if message.message_type='group_composition_confirmed' then
  if not exists(select 1 from app_private.walking_groups g where g.id=(message.payload->>'groupId')::uuid and g.retired_at is null and g.composition_revision=(message.payload->>'compositionRevision')::integer and g.composition_confirmed_hash=app_private.start_group_composition_hash(g.id) and g.composition_confirmed_hash=message.payload->>'compositionHash') then return null;end if;
  return message.payload;
 end if;
 select * into publication from app_private.current_start_publication((message.payload->>'groupId')::uuid);
 if publication.id is null or publication.starts_at is distinct from (message.payload->>'startsAt')::timestamptz then return null;end if;
 -- Only evidence of actual provider acceptance is treated as a previously communicated time.
 select * into previous from app_private.email_outbox o where o.id<>message.id and o.recipient_ref=message.recipient_ref
  and o.payload->>'groupId'=message.payload->>'groupId' and o.message_type in ('group_schedule_published','group_schedule_corrected')
  and (o.status in ('accepted','delivered') or o.provider_id is not null) order by coalesce((select t.publication_order from app_private.start_time_communications t where t.id=coalesce(nullif(o.payload->>'timeEventId','')::uuid,case when o.dedupe_key~'^start-time:[0-9a-f-]{36}:' then split_part(o.dedupe_key,':',2)::uuid end)),(select max(p.publication_order) from app_private.group_start_publications p where p.group_id=(o.payload->>'groupId')::uuid and p.revision=case when o.dedupe_key~'^group-schedule:[0-9a-f-]{36}:[0-9]+:' then split_part(o.dedupe_key,':',3)::integer when coalesce(o.payload->>'revision','')~'^[0-9]+$' then (o.payload->>'revision')::integer end),(select max(p.publication_order) from app_private.group_start_publications p where p.group_id=(o.payload->>'groupId')::uuid and p.starts_at=(o.payload->>'startsAt')::timestamptz and p.published_at<=o.created_at),0) desc,o.accepted_at desc nulls last,o.created_at desc,o.id desc limit 1;
 if previous.id is not null and (previous.payload->>'startsAt')::timestamptz=publication.starts_at then return null;end if;
 kind:=case when previous.id is null then 'group_schedule_published' else 'group_schedule_corrected' end;
 result:=jsonb_build_object('groupId',publication.group_id,'groupName',message.payload->>'groupName','groupCode',message.payload->>'groupCode','messageType',kind,
  'timeEventId',message.payload->'timeEventId','startsAt',publication.starts_at,'oldStartsAt',previous.payload->'startsAt','addressReleaseAt',publication.starts_at-interval '1 hour',
  'addressReleased',clock_timestamp()>=publication.starts_at-interval '1 hour','actionPath','/omgeving/meeloper/groep');
 -- Preserve recipient identity from new enqueue-time payloads. Older payloads
 -- keep their existing shape, provider identity and semantic history.
 if message.payload ? 'personName' then result:=result||jsonb_build_object('personName',message.payload->'personName');end if;
 -- Persist exactly the safe content rendered by the worker for subsequent corrections/audit.
 update app_private.email_outbox set payload=result,message_type=kind where id=message.id;
 return result;
end $$;
