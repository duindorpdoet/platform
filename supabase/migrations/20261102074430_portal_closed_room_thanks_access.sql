-- Central closure is the effective room state; retained operational history is
-- not rewritten. Existing room-capability access also applies to its inbox.
set lock_timeout='5s';

create or replace function app_private.event_house_thanks_can_read(_event uuid,_portal uuid)returns boolean
language sql stable security definer set search_path=''as $$
 select auth.uid()is not null and exists(
  select 1 from auth.users u join app_private.portals p on p.id=_portal and p.event_id=_event
  where u.id=auth.uid()and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())and u.email_confirmed_at is not null
  and(exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=u.id
    and o.revoked_at is null and o.suspended_at is null and o.accepted_at is not null)
   or(p.approval_status='approved'and(
    app_private.has_capability(p.event_id,'event_admin',u.id)
    or app_private.has_capability(p.event_id,'portals_manage',u.id)
    or app_private.has_capability(p.event_id,'live_support',u.id))))
 )
$$;
-- CREATE OR REPLACE preserves this private helper's existing owner-only ACL.

-- The legacy reaction counts belong to the same authorized room. Keep the
-- family/admin paths and safe legacy shape, without merging receipt cohorts.
create or replace function api.portal_thanks_snapshot(_event_slug text,_scope text default 'family',_portal_id uuid default null)returns jsonb
language plpgsql security definer set search_path=''as $$
declare eid uuid;result jsonb;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if _scope='house'then
  if not app_private.event_house_thanks_can_read(eid,_portal_id)then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
  select jsonb_build_object('familyCount',count(distinct t.household_id),'thanks',coalesce(jsonb_agg(
   jsonb_build_object('portalId',t.portal_id,'portalName',p.name,'world',w.name,'choice',t.choice)order by p.name,t.choice),'[]'::jsonb))into result
  from app_private.portal_thanks t join app_private.portals p on p.id=t.portal_id join app_private.worlds w on w.id=p.world_id
  where t.event_id=eid and t.portal_id=_portal_id;
  return result;
 end if;
 if _scope='family'and app_private.event_closure_exists(eid)then return api.portal_thanks_closed_snapshot(_event_slug);end if;
 return api.portal_thanks_snapshot_before_event_close(_event_slug,_scope,_portal_id);
end $$;

-- Shared event slot precedes portal locks, matching explicit central closure.
create function app_private.portal_operation_assert_allowed(_portal uuid,_state text)returns void
language plpgsql security invoker set search_path=''as $$
declare eid uuid;
begin
 select event_id into eid from app_private.portals where id=_portal;
 perform pg_advisory_xact_lock_shared(hashtextextended('event-closure:'||eid::text,0));
 if _state is distinct from 'closed'and app_private.event_closure_exists(eid)then
  raise exception 'EVENING_ENDED'using errcode='23514';
 end if;
end $$;
revoke all on function app_private.portal_operation_assert_allowed(uuid,text)from public,anon,authenticated,service_role;

-- Last-line protection for operational changes through existing management
-- writers too. A nonblocking shared slot avoids row->event lock inversion:
-- an in-progress central close wins, and this command can be retried by its user.
create function app_private.portal_closed_event_operation_guard()returns trigger
language plpgsql security invoker set search_path=''as $$
begin
 if new.operation_status='closed'or(TG_OP='UPDATE'and new.operation_status is not distinct from old.operation_status)then return new;end if;
 if not pg_try_advisory_xact_lock_shared(hashtextextended('event-closure:'||new.event_id::text,0))then
  raise exception 'EVENING_CLOSING'using errcode='23514';
 end if;
 if app_private.event_closure_exists(new.event_id)then raise exception 'EVENING_ENDED'using errcode='23514';end if;
 return new;
end $$;
revoke all on function app_private.portal_closed_event_operation_guard()from public,anon,authenticated,service_role;
create trigger portal_closed_event_operation_guard before insert or update of operation_status on app_private.portals
for each row execute function app_private.portal_closed_event_operation_guard();

CREATE OR REPLACE FUNCTION api.portal_set_operational_state(_portal_id uuid, _state app_private.portal_operation_status, _expected_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  affected record;
begin
  perform app_private.poortkamer_require(_portal_id,'live');
  perform app_private.portal_operation_assert_allowed(_portal_id,_state::text);
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null or portal.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (
    select 1 from app_private.portal_owners owner
    where owner.portal_id = _portal_id and owner.user_id = actor and owner.revoked_at is null
  ) and not app_private.has_capability(portal.event_id, 'event_admin', actor)
    and not app_private.has_capability(portal.event_id, 'portals_manage', actor)
    and not app_private.has_capability(portal.event_id, 'live_support', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if _state in ('paused', 'closed') and char_length(trim(coalesce(_reason, ''))) not between 5 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  update app_private.portals
  set pause_until = null, operation_status = _state, pause_after_current = _state = 'paused', version = version + 1
  where id = _portal_id returning * into portal;

  if exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    if _state = 'open' then
      update app_private.event_route_settings set finale_available = true, version = version + 1
      where event_id = portal.event_id;
    elsif _state = 'paused' then
      update app_private.event_route_settings set finale_available = false, version = version + 1
      where event_id = portal.event_id;
      update app_private.portal_reservations set status = 'cancelled',
        cancelled_reason = 'Laatste poort pauzeert', version = version + 1
      where portal_id = portal.id and kind = 'finale' and status = 'held';
    end if;
  end if;

  if _state in ('paused', 'closed') then
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = case when _state = 'closed' then 'Poort direct gesloten' else 'Poort pauzeert na huidige groep' end,
      version = version + 1
    where portal_id = _portal_id and status = 'held' and kind = 'ordinary';
  end if;
  if _state = 'closed' and exists (
    select 1 from app_private.event_route_settings settings
    where settings.event_id = portal.event_id and settings.final_portal_id = portal.id
  ) then
    update app_private.event_route_settings set finale_available = false, version = version + 1 where event_id = portal.event_id;
    update app_private.portal_reservations set status = 'cancelled',
      cancelled_reason = 'Laatste poort direct gesloten', version = version + 1
    where portal_id = portal.id and kind = 'finale' and status in ('held', 'active');
    for affected in
      select run.id as run_id, run.group_id
      from app_private.group_runs run
      join app_private.walking_groups walking_group on walking_group.id = run.group_id
      where walking_group.event_id = portal.event_id and walking_group.route_mode = 'dynamic'
        and run.status in ('live', 'paused')
    loop
      update app_private.group_runs set status = 'paused', version = version + 1 where id = affected.run_id;
      insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
      select portal.event_id, affected.group_id, affected.run_id, portal.id, 'urgent', 'FINALE_UNAVAILABLE',
        'De eindpoort is gesloten. Gebruik uitsluitend de goedgekeurde noodafsluiting.'
      where not exists (select 1 from app_private.route_alerts where run_id = affected.run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    end loop;
  elsif _state = 'closed' then
    for affected in
      select stop.id as stop_id, stop.run_id, reservation.id as reservation_id
      from app_private.run_stops stop
      join app_private.group_runs run on run.id = stop.run_id and run.current_stop_id = stop.id and run.status = 'live'
      join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
      left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
      where stop.portal_id = portal.id and stop.state = 'active'
        and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
      for update of stop, run
    loop
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
        completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
      where id = affected.stop_id;
      update app_private.stop_participant_statuses
      set status = case when status = 'pending' then 'skipped'::app_private.participant_stop_status else status end,
        required_for_completion = false,
        exclusion_reason = 'Poort direct gesloten',
        reason = left(trim(_reason), 500), changed_by = actor,
        decided_at = coalesce(decided_at, clock_timestamp()), version = version + 1
      where run_stop_id = affected.stop_id and required_for_completion;
      update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Poort direct gesloten', version = version + 1
      where id = affected.reservation_id;
      insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
      values (affected.run_id, affected.stop_id, portal.world_id, 'system_skipped')
      on conflict (run_stop_id) do nothing;
      update app_private.group_runs set current_stop_id = null, version = version + 1
      where id = affected.run_id;
      insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
      values (affected.run_id, affected.stop_id, 'stop.system_skipped', actor,
        jsonb_build_object('portalId', portal.id, 'reason', left(trim(_reason), 500)));
      perform app_private.dispatch_next_stop(affected.run_id, clock_timestamp());
    end loop;
  end if;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.operation_state_changed', 'portal', portal.id,
    jsonb_build_object('state', _state, 'reason', left(coalesce(trim(_reason), ''), 500)));
  insert into app_private.portal_status_history(portal_id,actor_id,state,reason) values(portal.id,actor,_state,left(trim(_reason),500));
  perform app_private.poortkamer_signal(portal.id,'portal.room.status',jsonb_build_object('state',_state),'De poortstatus is gewijzigd.');
  return jsonb_build_object('id', portal.id, 'state', portal.operation_status, 'version', portal.version, 'pauseAfterCurrent', portal.pause_after_current);
end;
$function$;

CREATE OR REPLACE FUNCTION api.portal_room_update(_portal_id uuid, _operation text, _payload jsonb, _key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result jsonb;
  portal app_private.portals;
  help_channel uuid;
begin
  if _operation='status'then
    perform app_private.poortkamer_require(_portal_id,'live');
    perform app_private.portal_operation_assert_allowed(_portal_id,_payload->>'state');
  end if;
  if _operation in (
    'incident_create',
    'incident_status',
    'presentation_save',
    'presentation_submit',
    'presentation_activate',
    'simulation_start',
    'simulation_step',
    'simulation_reset'
  ) then
    return api.portal_v2_command(_portal_id, _operation, _payload, _key);
  end if;

  result := api.portal_room_update_v1(_portal_id, _operation, _payload, _key);
  if _operation <> 'help' then
    return result;
  end if;

  select * into portal
  from app_private.portals
  where id = _portal_id;
  perform app_private.poortkamer_channels(portal.event_id, portal.id);

  select id into help_channel
  from app_private.portal_room_channels
  where event_id = portal.event_id
    and portal_id is null
    and kind = 'community'
    and name = 'Hulp gevraagd'
    and archived_at is null;

  update app_private.portal_room_messages message
  set channel_id = help_channel
  where message.actor_id = auth.uid()
    and message.dedupe_key = _key
    and exists (
      select 1
      from app_private.portal_room_channels retired
      where retired.id = message.channel_id
        and retired.kind = 'community'
        and retired.name = 'Snoep & voorraad'
        and retired.archived_at is not null
    );

  if not found then
    insert into app_private.portal_room_messages(
      channel_id,
      actor_id,
      sender_portal_id,
      body,
      dedupe_key
    ) values (
      help_channel,
      auth.uid(),
      portal.id,
      portal.system_code || ' vraagt hulp met de snoepvoorraad. Neem contact op via deze poort in het Poortplein.',
      _key
    ) on conflict (actor_id, dedupe_key) do nothing;
  end if;

  return result;
end
$function$;

CREATE OR REPLACE FUNCTION app_private.poortkamer_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; row record; eid uuid;
begin
 -- Event gate before portal rows: an ended event never auto-resumes a room.
 for eid in select distinct event_id from app_private.portals where operation_status='paused'and pause_until<=now()and approval_status='approved'order by event_id loop
  perform pg_advisory_xact_lock_shared(hashtextextended('event-closure:'||eid::text,0));
  if app_private.event_closure_exists(eid)then continue;end if;
  for p in select * from app_private.portals where event_id=eid and operation_status='paused'and pause_until<=now()and approval_status='approved'order by id for update skip locked loop
  update app_private.portals set operation_status='open',pause_until=null,pause_after_current=false,version=version+1 where id=p.id;
  update app_private.event_route_settings set finale_available=true,version=version+1 where event_id=p.event_id and final_portal_id=p.id;
  insert into app_private.portal_status_history(portal_id,state,reason) values(p.id,'open','Getimede pauze verstreken');
  perform app_private.poortkamer_signal(p.id,'portal.pause.auto_resumed','{}','De getimede pauze is voorbij. De poort is weer open.');
 end loop;
 end loop;
 for p in select * from app_private.portals where not app_private.event_closure_exists(event_id)and operation_status='paused' and pause_until>now() and pause_until<=now()+interval '1 minute' loop
  perform app_private.poortkamer_push(p.id,'pause_1','pause:'||p.id||':'||p.pause_until);
 end loop;
 for row in
  with upcoming as(
   select id::text key,portal_id,reserved_from arrival from app_private.portal_reservations where status in ('held','active')
   union all
   select s.id::text,s.portal_id,s.planned_arrival_at from app_private.route_plan_stops s join app_private.route_plan_versions v on v.id=s.plan_version_id and v.state='published'
   join app_private.walking_groups g on g.id=v.group_id and g.route_mode<>'dynamic'
  ) select *,case when arrival<=now()+interval '3 minutes' then 'next_3' else 'next_10' end kind from upcoming where arrival>now() and arrival<=now()+interval '10 minutes'
 loop perform app_private.poortkamer_push(row.portal_id,row.kind,row.kind||':'||row.key); end loop;
 for row in select e.id,coalesce(s.portal_id,plan.portal_id) portal_id from app_private.scan_evidence e join app_private.run_stops s on s.id=e.run_stop_id left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id where e.scanned_at>now()-interval '5 minutes'
 loop if row.portal_id is not null then perform app_private.poortkamer_push(row.portal_id,'arrived','arrived:'||row.id); end if; end loop;
 -- Delete messages and cascaded reactions/reports; retain membership/audit history.
 delete from app_private.portal_room_messages m using app_private.portal_room_channels c,app_private.events e where m.channel_id=c.id and c.event_id=e.id and now()>=((e.local_date+interval '1 month') at time zone e.timezone);
 delete from app_private.portal_push_outbox where completed_at<now()-interval '30 days';
end $function$;

CREATE OR REPLACE FUNCTION api.portal_room_snapshot(_event_slug text, _portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;pid uuid;closed_at timestamptz;
begin
 result:=api.portal_room_snapshot_before_reception_policy(_event_slug,_portal_id);
 pid:=(result#>>'{portal,id}')::uuid;
 if pid is null then return result;end if;
 select c.closed_at into closed_at from app_private.event_closures c join app_private.portals p on p.event_id=c.event_id where p.id=pid;
 if closed_at is not null then
  result:=jsonb_set(result,'{portal}',(result->'portal')||jsonb_build_object('state','closed','pauseUntil',null,'pauseAfterCurrent',false));
 end if;
 result:=jsonb_set(result,'{portal}',(result->'portal')||app_private.portal_planning_policy(pid)
  ||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid)));
 return result||jsonb_build_object('eventClosed',closed_at is not null,'closedAt',closed_at,'canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid),
  'impact',jsonb_build_object('actualGroups',coalesce((result#>>'{visits,recap,groups}')::integer,0),
   'actualChildren',coalesce((result#>>'{visits,recap,children}')::integer,0)),
  'registeredImpact',app_private.portal_registered_impact(pid));
end $function$;

-- Existing PUBLIC/anon/authenticated/service grants and function owners are
-- preserved; new private helpers have no API execution grants. No mail work.
notify pgrst,'reload schema';
