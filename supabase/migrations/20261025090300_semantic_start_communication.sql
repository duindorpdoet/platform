-- Semantic time events are independent of internal schedule/location revisions.
create table if not exists app_private.start_time_communications (
 id uuid primary key default gen_random_uuid(), group_id uuid not null references app_private.walking_groups(id),
 starts_at timestamptz not null, publication_order bigint not null unique, created_at timestamptz not null default clock_timestamp());
create index if not exists start_time_communications_group on app_private.start_time_communications(group_id,publication_order desc);
alter table app_private.start_time_communications enable row level security;
revoke all on app_private.start_time_communications from public,anon,authenticated;
create or replace function app_private.queue_start_time_communication(_schedule uuid)
returns void language plpgsql security definer set search_path='' as $$
declare p app_private.group_start_publications; previous app_private.group_start_publications; event app_private.start_time_communications; rec record; g app_private.walking_groups;
begin
 select * into p from app_private.group_start_publications where schedule_id=_schedule order by publication_order desc limit 1;
 select * into g from app_private.walking_groups where id=p.group_id;
 select * into previous from app_private.group_start_publications old where old.group_id=p.group_id and old.publication_order<p.publication_order
  and not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=old.group_id and w.through_publication_order>=old.publication_order) order by publication_order desc limit 1;
 select * into event from app_private.start_time_communications where group_id=p.group_id order by publication_order desc limit 1;
 if event.id is null or previous.starts_at is distinct from p.starts_at then
  insert into app_private.start_time_communications(group_id,starts_at,publication_order) values(p.group_id,p.starts_at,p.publication_order) returning * into event;
 end if;
 update app_private.email_outbox set status='suppressed',last_error_code='APPOINTMENT_SUPERSEDED',lease_until=null
 where payload->>'groupId'=p.group_id::text and message_type in ('group_schedule_published','group_schedule_corrected')
 and (payload->>'startsAt')::timestamptz is distinct from p.starts_at and status in ('pending','deferred');
 for rec in select * from app_private.group_adult_recipients(p.group_id) loop
  -- Gate-only publications retain the existing semantic event and its pending first mail.
  if previous.starts_at is not distinct from p.starts_at and exists(select 1 from app_private.email_outbox o where o.payload->>'groupId'=p.group_id::text and o.recipient_ref=rec.user_id::text and o.message_type in ('group_schedule_published','group_schedule_corrected') and (o.payload->>'startsAt')::timestamptz=p.starts_at and o.status not in ('suppressed','failed')) then continue;end if;
  insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
  values('start-time:'||event.id||':'||rec.user_id,'group_schedule_published',rec.user_id::text,rec.email,
   jsonb_build_object('groupId',g.id,'groupName',coalesce(g.display_name,g.system_code),'groupCode',g.system_code,'timeEventId',event.id,'revision',p.revision,'startsAt',p.starts_at,'addressReleaseAt',p.starts_at-interval '1 hour','actionPath','/omgeving/meeloper/groep')) on conflict(dedupe_key) do nothing;
 end loop;
end $$;
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
  and (o.status in ('accepted','delivered') or o.provider_id is not null) order by o.updated_at desc,o.created_at desc limit 1;
 if previous.id is not null and (previous.payload->>'startsAt')::timestamptz=publication.starts_at then return null;end if;
 kind:=case when previous.id is null then 'group_schedule_published' else 'group_schedule_corrected' end;
 result:=jsonb_build_object('groupId',publication.group_id,'groupName',message.payload->>'groupName','groupCode',message.payload->>'groupCode','messageType',kind,
  'startsAt',publication.starts_at,'oldStartsAt',previous.payload->'startsAt','addressReleaseAt',publication.starts_at-interval '1 hour',
  'addressReleased',clock_timestamp()>=publication.starts_at-interval '1 hour','actionPath','/omgeving/meeloper/groep');
 -- Persist exactly the safe content rendered by the worker for subsequent corrections/audit.
 update app_private.email_outbox set payload=result,message_type=kind where id=message.id;
 return result;
end $$;
revoke all on function app_private.queue_start_time_communication(uuid) from public,anon,authenticated;
revoke all on function api.worker_group_schedule_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.worker_group_schedule_mail_payload(uuid) to service_role;

CREATE OR REPLACE FUNCTION app_private.publish_group_schedules_ops(_event_slug text, _schedule_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  settings app_private.event_route_settings;
  schedule app_private.group_schedule_revisions;
  recipient record;
  child_count integer;
  published_count integer := 0;
begin
  select id into v_event_id from app_private.events where slug = _event_slug for update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_schedule_ids), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  select * into settings from app_private.event_route_settings where event_id = v_event_id for update;
  if settings.planner_mode <> 'dynamic' or not settings.finale_available or settings.final_portal_id is null then
    raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514';
  end if;

  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.walking_groups walking_group on walking_group.id = candidate.group_id
    where candidate.id = any(_schedule_ids)
      and (walking_group.event_id <> v_event_id or candidate.state <> 'draft'
        or walking_group.current_schedule_revision_id <> candidate.id)
  ) or (select count(*) from app_private.group_schedule_revisions where id = any(_schedule_ids)) <> cardinality(_schedule_ids) then
    raise exception 'INVALID_SCHEDULE' using errcode = '23514';
  end if;

  -- Payment is a hard publication and start condition.
  -- Unpaid is an operational warning; financial status is preserved.


  -- The confirmation must still describe the current event and checked point.
  if exists(select 1 from app_private.group_schedule_revisions s
    join app_private.start_slots slot on slot.id=s.start_slot_id
    join app_private.start_points p on p.id=slot.start_point_id
    join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id
    where s.id=any(_schedule_ids) and (s.confirmed_at is null
      or s.confirmed_settings_version is distinct from e.settings_version
      or not app_private.start_composition_hash_current(s.id,g.id,s.confirmed_composition_hash)
      or s.confirmed_point_version is distinct from p.version
      or s.confirmed_route_settings_version is distinct from settings.version
      or s.confirmed_starts_at is distinct from slot.starts_at or s.confirmed_start_point_id is distinct from p.id
      or not slot.active
      or not app_private.start_point_ready_at(p.id,slot.starts_at))) then
    raise exception 'START_NOT_CONFIRMED' using errcode='23514'; end if;
  if exists(select 1 from app_private.group_runs r join app_private.group_schedule_revisions s on s.group_id=r.group_id
    where s.id=any(_schedule_ids)) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  perform app_private.validate_start_schedule_capacity(v_event_id,_schedule_ids);

  for schedule in
    select candidate.* from app_private.group_schedule_revisions candidate
    where candidate.id = any(_schedule_ids) order by candidate.group_id, candidate.revision
    for update
  loop
    update app_private.group_schedule_revisions
    set state = 'superseded'
    where group_id = schedule.group_id and state = 'published' and id <> schedule.id;
    update app_private.group_schedule_revisions
    set state = 'published', published_at = clock_timestamp()
    where id = schedule.id;
    update app_private.walking_groups
    set status = 'ready', start_slot_id = schedule.start_slot_id,
        current_schedule_revision_id = schedule.id, route_mode = 'dynamic', version = version + 1
    where id = schedule.group_id;
    update app_private.group_registrations set published_at = now()
    where group_id = schedule.group_id and superseded_at is null;
    update app_private.registrations set preference_change_status = 'locked', version = version + 1
    where id in (select registration_id from app_private.group_registrations where group_id = schedule.group_id and superseded_at is null);
    select count(*) into child_count from app_private.group_registrations assignment
    join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
    where assignment.group_id = schedule.group_id and assignment.superseded_at is null;
    perform app_private.queue_start_time_communication(schedule.id);
    published_count := published_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.published', 'group_schedule_batch',
    jsonb_build_object('count', published_count, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', published_count);
end;
$function$
;