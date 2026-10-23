-- Expand only. No existing IDs, credentials, payments or histories are replaced.
set lock_timeout = '5s';
create table if not exists app_private.run_stop_arrivals (
 event_id uuid not null references app_private.events(id),
 run_id uuid not null references app_private.group_runs(id),
 run_stop_id uuid not null references app_private.run_stops(id),
 run_participant_id uuid not null references app_private.run_participants(id),
 child_id uuid not null references app_private.children(id),
 scan_evidence_id uuid not null references app_private.scan_evidence(id),
 arrived boolean not null check (arrived),
 arrived_at timestamptz not null,
 actor_id uuid not null references auth.users(id),
 source text not null default 'confirmed_completion' check(source in ('confirmed_completion','reviewed_backfill')),
 primary key(run_stop_id,run_participant_id)
);
alter table app_private.run_stop_arrivals enable row level security;
revoke all on app_private.run_stop_arrivals from public,anon,authenticated;
create index if not exists run_stop_arrivals_child on app_private.run_stop_arrivals(event_id,child_id,run_stop_id);
alter table app_private.run_participants add column if not exists departure_reason text;

create or replace function app_private.assert_arrival_credential(_run_id uuid,_stop_id uuid,_version integer,_credential text,_method text,_portal_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; p app_private.portals; credentialid uuid;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if r.version<>_version or r.current_stop_id is distinct from _stop_id then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status<>'live' then raise exception 'RUN_NOT_LIVE'; end if;
 select portal.* into p from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 join app_private.portals portal on portal.id=coalesce(s.portal_id,plan.portal_id) where s.id=_stop_id and s.run_id=_run_id and s.state='active' for share of portal;
 if p.id is null or (_portal_id is not null and p.id<>_portal_id) then raise exception 'WRONG_PORTAL'; end if;
 if p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 if _method not in ('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160 then raise exception 'WRONG_PORTAL'; end if;
 select c.id into credentialid from app_private.portal_credentials c where c.portal_id=p.id and c.revoked_at is null
 and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
 and ((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
 or (_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
 order by c.version desc limit 1;
 if credentialid is null then raise exception 'WRONG_PORTAL'; end if;
 return credentialid;
end $$;
revoke all on function app_private.assert_arrival_credential(uuid,uuid,integer,text,text,uuid) from public,anon,authenticated;

create or replace function api.run_scan_validate(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_portal_id uuid default null,_method text default 'qr')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 return jsonb_build_object('valid',true);
end $$;
create or replace function api.run_scan(
  _run_id uuid,
  _expected_stop_id uuid,
  _expected_run_version integer,
  _credential text,
  _method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select credential.* into credential_record
  from app_private.run_stops run_stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    -- A pause means "no new groups". A group already inside may still scan and
    -- finish safely; a direct close remains blocked.
    and portal.operation_status in ('open', 'paused')
    and credential.revoked_at is null and credential.valid_from <= now()
    and (credential.valid_until is null or credential.valid_until > now())
    and (
      (_method = 'qr' and credential.token_hash = extensions.digest(convert_to(_credential, 'utf8'), 'sha256'))
      or (_method = 'short_code' and credential.short_code_hash = extensions.digest(convert_to(upper(trim(_credential)), 'utf8'), 'sha256'))
    )
  order by credential.version desc limit 1;
  if credential_record.id is null then raise exception 'WRONG_PORTAL' using errcode = '22023'; end if;
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
end;
$$;
create or replace function api.run_complete_stop(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _all_skip_confirmed boolean,
  _idempotency_key text,
  _request_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  required_count integer;
  pending_count integer;
  visited_count integer;
  skipped_count integer;
  v_outcome app_private.stop_outcome;
  next_stop app_private.run_stops;
  v_world_id uuid;
  receipt app_private.command_receipts;
  result jsonb;
  dispatch_result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.completeStop:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.completeStop' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash or receipt.safe_result->>'runId' is distinct from _run_id::text then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    if run_record.id is null or not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select count(*) filter (where required_for_completion),
         count(*) filter (where required_for_completion and status = 'pending'),
         count(*) filter (where status = 'visited'),
         count(*) filter (where status = 'skipped')
    into required_count, pending_count, visited_count, skipped_count
  from app_private.stop_participant_statuses where run_stop_id = _stop_id;
  if required_count = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if pending_count > 0 then raise exception 'PENDING_PARTICIPANTS' using errcode = '23514'; end if;
  if not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  if visited_count = 0 and not _all_skip_confirmed then raise exception 'ALL_SKIP_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  v_outcome := case
    when visited_count > 0 and skipped_count > 0 then 'mixed'::app_private.stop_outcome
    when visited_count > 0 then 'visited'::app_private.stop_outcome
    else 'all_skipped'::app_private.stop_outcome end;
  perform p.id from app_private.scan_evidence e join app_private.portal_credentials c on c.id=e.credential_id join app_private.portals p on p.id=c.portal_id where e.run_stop_id=_stop_id for share of p;
  -- Freeze historical presence before departure or later roster changes can occur.
  if not exists(select 1 from app_private.scan_evidence e join app_private.portal_credentials c on c.id=e.credential_id
    join app_private.portals p on p.id=c.portal_id where e.run_stop_id=_stop_id and c.revoked_at is null
    and c.version=e.credential_version and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now()) and p.operation_status in ('open','paused'))
  then raise exception 'WRONG_PORTAL'; end if;
  insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id)
  select g.event_id,_run_id,_stop_id,rp.id,rc.child_id,e.id,true,clock_timestamp(),actor
  from app_private.stop_participant_statuses st join app_private.run_participants rp on rp.id=st.run_participant_id and rp.run_id=_run_id
  join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.walking_groups g on g.id=run_record.group_id
  join app_private.scan_evidence e on e.run_stop_id=st.run_stop_id
  where st.run_stop_id=_stop_id and st.required_for_completion and st.status in ('visited','skipped')
  and rp.attendance='present' and rp.departed_at is null and rc.participation_status='active'
  on conflict do nothing;
  update app_private.run_stops set state = 'completed', outcome = v_outcome,
    completed_at = clock_timestamp(), completion_actor = actor, version = version + 1 where id = _stop_id;
  update app_private.portal_reservations set status = 'completed', version = version + 1
  where id = stop_record.reservation_id;
  select portal.world_id into v_world_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
  where stop.id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, v_world_id, v_outcome);

  if stop_record.stop_kind = 'finale' then
    update app_private.group_runs set status = 'completed', current_stop_id = null,
      finished_at = clock_timestamp(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    dispatch_result := jsonb_build_object('decision', 'completed');
  elsif stop_record.stop_kind = 'ordinary' then
    update app_private.group_runs set current_stop_id = null, version = version + 1
    where id = _run_id returning * into run_record;
    dispatch_result := app_private.dispatch_next_stop(_run_id, clock_timestamp());
    select * into run_record from app_private.group_runs where id = _run_id;
  else
    select * into next_stop from app_private.run_stops
    where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
    if next_stop.id is null then
      update app_private.group_runs set status = 'completed', current_stop_id = null,
        finished_at = clock_timestamp(), version = version + 1
      where id = _run_id returning * into run_record;
      update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
    else
      update app_private.run_stops set state = 'active', opened_at = clock_timestamp(), version = version + 1 where id = next_stop.id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop.id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
      where id = _run_id returning * into run_record;
    end if;
    dispatch_result := jsonb_build_object('decision', case when next_stop.id is null then 'completed' else 'legacy' end);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.completed', actor, jsonb_build_object('outcome', v_outcome));
  result := jsonb_build_object(
    'runId', _run_id, 'status', run_record.status, 'version', run_record.version,
    'completedStopId', _stop_id, 'outcome', v_outcome,
    'hasNextStop', run_record.current_stop_id is not null, 'dispatch', dispatch_result
  );
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.completeStop', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$$;
create or replace function api.run_update_participant(
  _run_id uuid,
  _stop_id uuid,
  _run_participant_id uuid,
  _new_status app_private.participant_stop_status,
  _expected_run_version integer,
  _expected_status_version integer,
  _reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  status_record app_private.stop_participant_statuses;
  participant_household uuid;
  leader boolean;
  own_child boolean;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.run_participants where id=_run_participant_id and run_id=_run_id and attendance='present' and departed_at is null) then raise exception 'INVALID_ATTENDANCE' using errcode='23514'; end if;
  select status.* into status_record
  from app_private.stop_participant_statuses status
  where status.run_stop_id = _stop_id and status.run_participant_id = _run_participant_id for update;
  if status_record.id is null or status_record.version <> _expected_status_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select child.household_id into participant_household
  from app_private.run_participants participant
  join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
  join app_private.children child on child.id = registration_child.child_id
  where participant.id = _run_participant_id;
  leader := app_private.is_current_leader(run_record.group_id, actor);
  own_child := app_private.is_household_member(participant_household, actor);
  if not leader and not own_child then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _new_status = 'visited' then
    if not leader then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if not exists (select 1 from app_private.scan_evidence where run_stop_id = _stop_id) then raise exception 'SCAN_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'skipped' then
    if status_record.status <> 'pending' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
    if leader and nullif(trim(_reason), '') is null then raise exception 'PARENT_CONFIRMATION_REQUIRED' using errcode = '23514'; end if;
  elsif _new_status = 'pending' then
    if not own_child or status_record.status <> 'skipped' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  end if;
  update app_private.stop_participant_statuses
  set status = _new_status, version = version + 1, changed_by = actor, reason = _reason,
      decided_at = case when _new_status = 'pending' then null else now() end
  where id = status_record.id returning * into status_record;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'participant.' || _new_status::text, actor, jsonb_build_object('runParticipantId', _run_participant_id));
  return jsonb_build_object('id', status_record.id, 'status', status_record.status, 'version', status_record.version);
end;
$$;
create or replace function app_private.record_arrival_seals(_stop_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare stoprec app_private.run_stops; eventid uuid; portalid uuid; worldid uuid; active_presentation app_private.portal_presentations;
  participant record; teamid uuid; total_stops integer; completed_stops integer; chapter integer;
  presentation jsonb; is_finale boolean;
begin
  select * into stoprec from app_private.run_stops where id=_stop_id;
  if stoprec.state<>'completed' or stoprec.outcome not in ('visited','mixed','all_skipped') then return; end if;
  select g.event_id,coalesce(stoprec.portal_id,plan.portal_id),p.world_id,coalesce(stoprec.stop_kind='finale',false)
    into eventid,portalid,worldid,is_finale
  from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  left join app_private.route_plan_stops plan on plan.id=stoprec.plan_stop_id
  join app_private.portals p on p.id=coalesce(stoprec.portal_id,plan.portal_id)
  where r.id=stoprec.run_id;
  perform pg_advisory_xact_lock(hashtextextended(portalid::text||':presentation',0));
  select * into active_presentation from app_private.portal_presentations
    where portal_id=portalid and status='active' order by version desc limit 1;
  if active_presentation.id is null then
    insert into app_private.portal_presentations(
      portal_id,version,status,world_id,public_name,short_description,story_fragment,
      symbol,color,image_path,accessibility,intensity,created_by,submitted_at,
      reviewed_by,reviewed_at,activated_at)
    select p.id,coalesce((select max(version)+1 from app_private.portal_presentations where portal_id=p.id),1),
      'active',p.world_id,coalesce(nullif(pub.published_title,''),p.name),
      coalesce(nullif(pub.teaser,''),'Een goedgekeurde poort uit de nacht van Duindorp.'),
      left(coalesce(nullif(w.story,''),'Achter deze poort werd de nacht even een andere wereld.'),1200),
      'gate','amber',case when pub.image_path ~ '^/images/[A-Za-z0-9_./-]+[.]webp$' then pub.image_path end,
      'Volg de aanwijzingen van de groepsleider.',p.intensity,o.user_id,now(),o.user_id,now(),now()
    from app_private.portals p join app_private.worlds w on w.id=p.world_id
    join lateral (select user_id from app_private.portal_owners where portal_id=p.id and role='owner' and revoked_at is null order by accepted_at limit 1) o on true
    left join app_private.portal_publications pub on pub.portal_id=p.id
    where p.id=portalid
    returning * into active_presentation;
  end if;
  if active_presentation.id is not null then
    presentation:=jsonb_build_object('version',active_presentation.version,'portalCode',(select system_code from app_private.portals where id=portalid),
      'world',(select name from app_private.worlds where id=active_presentation.world_id),'worldSlug',(select slug from app_private.worlds where id=active_presentation.world_id),'publicName',active_presentation.public_name,
      'shortDescription',active_presentation.short_description,'story',active_presentation.story_fragment,
      'symbol',active_presentation.symbol,'color',active_presentation.color,'imagePath',active_presentation.image_path,
      'accessibility',active_presentation.accessibility,'intensity',active_presentation.intensity);
  else
    select jsonb_build_object('version',pub.version,'portalCode',p.system_code,'world',w.name,'worldSlug',w.slug,'publicName',coalesce(nullif(pub.published_title,''),p.name),
      'shortDescription',coalesce(nullif(pub.teaser,''),'Een poort uit de nacht van Duindorp.'),'story',w.story,
      'symbol','gate','color','amber','imagePath',pub.image_path,'accessibility','Volg de aanwijzingen van de groepsleider.','intensity',p.intensity)
      into presentation from app_private.portals p join app_private.worlds w on w.id=p.world_id
      left join app_private.portal_publications pub on pub.portal_id=p.id where p.id=portalid;
  end if;
  for participant in
    select distinct rc.child_id from app_private.stop_participant_statuses status
    join app_private.run_participants rp on rp.id=status.run_participant_id
    join app_private.registration_children rc on rc.id=rp.registration_child_id
    where status.run_stop_id=stoprec.id and exists(select 1 from app_private.run_stop_arrivals arrival where arrival.run_stop_id=stoprec.id and arrival.run_participant_id=rp.id and arrival.child_id=rc.child_id and arrival.arrived)
  loop
    teamid:=app_private.poortenboek_team(eventid,participant.child_id);
    if teamid is null then continue; end if;
    insert into app_private.poortenboek_team_progress(event_id,team_id,run_id,run_stop_id,portal_id,world_id,completed_at,finale)
      values(eventid,teamid,stoprec.run_id,stoprec.id,portalid,worldid,stoprec.completed_at,is_finale) on conflict do nothing;
    insert into app_private.poortenboek_passport_seals(event_id,child_id,team_id,run_id,run_stop_id,portal_id,world_id,presentation_id,presentation_snapshot,earned_at,finale)
      values(eventid,participant.child_id,teamid,stoprec.run_id,stoprec.id,portalid,worldid,active_presentation.id,presentation,stoprec.completed_at,is_finale)
      on conflict do nothing;
    insert into app_private.poortenboek_story_chapters(event_id,child_id,chapter,source_run_id,source_stop_id)
      values(eventid,participant.child_id,1,stoprec.run_id,stoprec.id),(eventid,participant.child_id,2,stoprec.run_id,stoprec.id) on conflict do nothing;
    select count(*) into total_stops from app_private.run_stops where run_id=stoprec.run_id;
    select count(*) into completed_stops from app_private.poortenboek_passport_seals where event_id=eventid and child_id=participant.child_id and run_id=stoprec.run_id;
    if completed_stops*3>=greatest(total_stops,1) then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,3,stoprec.run_id,stoprec.id,now()) on conflict do nothing;
    end if;
    if completed_stops*3>=greatest(total_stops,1)*2 then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,4,stoprec.run_id,stoprec.id,now()) on conflict do nothing;
    end if;
    if is_finale or completed_stops>=greatest(total_stops-1,1) then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,5,stoprec.run_id,stoprec.id,now()) on conflict do nothing;
    end if;
    if is_finale then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,6,stoprec.run_id,stoprec.id,now()) on conflict do nothing;
    end if;
  end loop;
  perform realtime.send(jsonb_build_object('runStopId',stoprec.id),'snapshot_changed','admin-event:'||eventid,true);
  return;
end $$;
create or replace function app_private.poortenboek_record_completed_stop() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='completed' and old.state<>'completed' then perform app_private.record_arrival_seals(new.id); end if;
 return new;
end $$;
revoke all on function app_private.record_arrival_seals(uuid) from public,anon,authenticated;


create or replace function api.run_arrive_and_advance(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_participant_choices jsonb,_idempotency_key text,_portal_id uuid default null,_method text default 'qr')
returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; saved app_private.command_receipts; hashed text; result jsonb; entry record; statusrow app_private.stop_participant_statuses;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(coalesce(_idempotency_key,'')) not between 8 and 100 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=encode(extensions.digest(convert_to(jsonb_build_array(_run_id,_expected_stop_id,_expected_run_version,_credential,_participant_choices,_portal_id,_method)::text,'utf8'),'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.arriveAndAdvance' and idempotency_key=_idempotency_key;
 if saved.id is not null then
  if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return saved.safe_result;
 end if;
 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 if jsonb_typeof(_participant_choices) is distinct from 'object' or (select count(*) from jsonb_object_keys(_participant_choices))=0 then raise exception 'INVALID_ATTENDANCE'; end if;
 if exists(select 1 from jsonb_each_text(_participant_choices) c where c.value not in ('visited','skipped') or not exists(select 1 from app_private.run_participants p where p.id::text=c.key and p.run_id=_run_id and p.attendance='present' and p.departed_at is null))
 or exists(select 1 from app_private.run_participants p join app_private.stop_participant_statuses st on st.run_participant_id=p.id and st.run_stop_id=_expected_stop_id where p.run_id=_run_id and p.attendance='present' and st.required_for_completion and not (_participant_choices ? p.id::text))
 then raise exception 'INVALID_ATTENDANCE'; end if;
 perform api.run_scan(_run_id,_expected_stop_id,_expected_run_version,_credential,_method);
 for entry in select * from jsonb_each_text(_participant_choices) loop
  select * into statusrow from app_private.stop_participant_statuses where run_stop_id=_expected_stop_id and run_participant_id=entry.key::uuid for update;
  if statusrow.id is null then raise exception 'INVALID_ATTENDANCE'; end if;
  if statusrow.status::text<>entry.value then
   if statusrow.status='skipped' then perform api.run_update_participant(_run_id,_expected_stop_id,entry.key::uuid,'pending',_expected_run_version,statusrow.version,'Keuze bevestigd met eigen ouder');
    select * into statusrow from app_private.stop_participant_statuses where id=statusrow.id; end if;
   perform api.run_update_participant(_run_id,_expected_stop_id,entry.key::uuid,entry.value::app_private.participant_stop_status,_expected_run_version,statusrow.version,'Keuze bevestigd met ouder bij aankomst');
  end if;
 end loop;
 result:=api.run_complete_stop(_run_id,_expected_stop_id,_expected_run_version,true,_idempotency_key||':complete',hashed)||jsonb_build_object('accepted',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.arriveAndAdvance',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $$;

create or replace function api.run_confirm_arrival(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_participant_choices jsonb,_idempotency_key text,_portal_id uuid default null,_method text default 'qr')
returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; saved app_private.command_receipts; hashed text; result jsonb;
begin
 if auth.uid() is null or char_length(coalesce(_idempotency_key,'')) not between 8 and 100 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=encode(extensions.digest(convert_to(jsonb_build_array(_run_id,_expected_stop_id,_expected_run_version,_credential,_portal_id,_method)::text,'utf8'),'sha256'),'hex');
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.confirmArrival' and idempotency_key=_idempotency_key;
 if saved.id is not null then
  if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return saved.safe_result;
 end if;
 perform app_private.assert_arrival_credential(_run_id,_expected_stop_id,_expected_run_version,_credential,_method,_portal_id);
 result:=api.run_scan(_run_id,_expected_stop_id,_expected_run_version,_credential,_method);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.confirmArrival',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $$;

create or replace function api.run_end_early(_run_id uuid,_expected_run_version integer,_participant_ids uuid[],_reason text,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.group_runs; eventid uuid; item uuid; remaining integer; hashed text; saved app_private.command_receipts; result jsonb;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if cardinality(_participant_ids) is null or cardinality(_participant_ids)=0 or cardinality(_participant_ids)<>(select count(distinct i) from unnest(_participant_ids) i) then raise exception 'INVALID_ATTENDANCE'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 select event_id into eventid from app_private.walking_groups where id=r.group_id;
 -- Check household authority before returning any existing receipt.
 if r.id is null or exists(select 1 from unnest(_participant_ids) i where not exists(select 1 from app_private.run_participants p
 join app_private.registration_children rc on rc.id=p.registration_child_id join app_private.registrations reg on reg.id=rc.registration_id
 where p.id=i and p.run_id=_run_id and app_private.is_household_member(reg.household_id,auth.uid()))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=md5(jsonb_build_array(_run_id,_expected_run_version,_participant_ids,_reason)::text);
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='run.endEarly' and idempotency_key=_idempotency_key;
 if saved.id is not null then if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return saved.safe_result; end if;
 if r.version<>_expected_run_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status not in ('live','paused') then raise exception 'RUN_NOT_LIVE'; end if;
 if exists(select 1 from app_private.run_participants where id=any(_participant_ids) and (attendance<>'present' or departed_at is not null)) then raise exception 'INVALID_ATTENDANCE'; end if;
 select count(*) into remaining from app_private.run_participants where run_id=_run_id and attendance='present' and not(id=any(_participant_ids));
 if remaining>0 and app_private.is_current_leader(r.group_id,auth.uid()) then
  -- The leader's household cannot leave the remaining children without a handover.
  if not exists(select 1 from app_private.run_participants p join app_private.registration_children rc on rc.id=p.registration_child_id
   join app_private.registrations reg on reg.id=rc.registration_id where p.run_id=_run_id and p.attendance='present' and not(p.id=any(_participant_ids)) and app_private.is_household_member(reg.household_id,auth.uid()))
  then raise exception 'LEADERSHIP_HANDOVER_REQUIRED'; end if;
 end if;
 update app_private.run_participants set attendance='departed',departed_at=clock_timestamp(),departure_reason='early',roster_version=roster_version+1 where id=any(_participant_ids) and run_id=_run_id;
 update app_private.stop_participant_statuses set required_for_completion=false,exclusion_reason='departed',version=version+1,changed_by=auth.uid()
 where run_stop_id=r.current_stop_id and run_participant_id=any(_participant_ids);
 update app_private.group_runs set version=version+1,
 status=case when remaining=0 then 'stopped'::app_private.run_status else status end,
 current_stop_id=case when remaining=0 then null else current_stop_id end,
 stopped_reason=case when remaining=0 then 'all_participants_departed' else stopped_reason end,
 finished_at=case when remaining=0 then clock_timestamp() else finished_at end where id=_run_id;
 if remaining=0 then update app_private.walking_groups set status='stopped',version=version+1 where id=r.group_id; end if;
 insert into app_private.journey_events(run_id,stop_id,event_type,actor_id,safe_metadata) values(_run_id,r.current_stop_id,'household.departed',auth.uid(),jsonb_build_object('participants',_participant_ids,'reason','early'));
 result:=jsonb_build_object('ok',true,'remainingParticipants',remaining);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'run.endEarly',_idempotency_key,hashed,result,now()+interval '2 days');
 return result;
end $$;
revoke all on function api.run_scan_validate(uuid,uuid,integer,text,uuid,text),api.run_arrive_and_advance(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_confirm_arrival(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_end_early(uuid,integer,uuid[],text,text) from public,anon;
grant execute on function api.run_scan_validate(uuid,uuid,integer,text,uuid,text),api.run_arrive_and_advance(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_confirm_arrival(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_end_early(uuid,integer,uuid[],text,text) to authenticated;
create or replace function app_private.group_snapshot_before_codes(_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  run_record app_private.group_runs;
  leader boolean;
  support boolean;
  household_access boolean;
  schedule app_private.group_schedule_revisions;
  published_start boolean := false;
  own_finished boolean := false;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into group_record from app_private.walking_groups where id = _group_id;
  if group_record.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  leader := app_private.is_current_leader(_group_id, actor);
  support := app_private.has_capability(group_record.event_id, 'live_support', actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor);
  select exists (
    select 1 from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
    join app_private.group_registrations assignment on assignment.registration_id = registration.id
    where member.user_id = actor and member.revoked_at is null and assignment.group_id = _group_id and assignment.superseded_at is null
  ) into household_access;
  if not (leader or support or household_access) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into schedule from app_private.group_schedule_revisions
  where group_id = group_record.id and state = 'published'
  order by revision desc limit 1;
  if group_record.route_mode = 'dynamic' then
    published_start := coalesce(schedule.state = 'published', false);
  else
    published_start := exists (
      select 1 from app_private.route_plan_versions plan
      where plan.id = group_record.current_plan_version_id and plan.state = 'published'
    ) and exists (
      select 1 from app_private.group_registrations assignment
      where assignment.group_id = _group_id and assignment.superseded_at is null and assignment.published_at is not null
    );
  end if;
  select * into run_record from app_private.group_runs where group_id = _group_id order by created_at desc limit 1;
  own_finished:=exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id join app_private.children c on c.id=rc.child_id where rp.run_id=run_record.id and rp.departure_reason='early' and app_private.is_household_member(c.household_id,actor))
   and not exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id join app_private.children c on c.id=rc.child_id where rp.run_id=run_record.id and rp.attendance='present' and app_private.is_household_member(c.household_id,actor));

  return jsonb_build_object(
    'eventId', group_record.event_id,
    'group', jsonb_build_object(
      'id', group_record.id, 'code', group_record.code, 'status', group_record.status,
      'version', group_record.version, 'routeMode', group_record.route_mode,
      'start', case when not published_start then null else (
        select jsonb_build_object(
          'name', point.name, 'locationName', point.name, 'address', point.private_address,
          'startsAt', slot.starts_at, 'queueNumber', schedule.queue_number
        ) from app_private.start_slots slot
        join app_private.start_points point on point.id = slot.start_point_id
        where slot.id = schedule.start_slot_id
      ) end,
      'effectiveOrdinaryStopAt', case when schedule.state = 'published' then schedule.effective_ordinary_stop_at else null end,
      'expectedFinaleArrivalAt', case when schedule.state = 'published' then schedule.expected_finale_arrival_at else null end
    ),
    'access', jsonb_build_object('leader', leader, 'support', support),
    'run', case when run_record.id is null then null else jsonb_build_object(
       'id', run_record.id, 'status', run_record.status, 'version', run_record.version,
      'endedEarly',run_record.stopped_reason='all_participants_departed','ownEveningFinished',own_finished,
      'farewells',coalesce((select jsonb_object_agg(rp.id::text,jsonb_build_object('endedAt',rp.departed_at,'reason',rp.departure_reason)) from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id join app_private.children c on c.id=rc.child_id where rp.run_id=run_record.id and rp.departure_reason='early' and app_private.is_household_member(c.household_id,actor)),'{}'::jsonb),
      'lastServerConfirmation', run_record.updated_at,
      'emergencyInstruction', case when run_record.status = 'stopped' then run_record.stopped_reason else null end,
      'elapsedSeconds', greatest(0, extract(epoch from (now() - run_record.started_at))::integer),
      'remainingStopCount', case when group_record.route_mode = 'legacy' then (
        select count(*) from app_private.run_stops stop where stop.run_id = run_record.id and stop.state = 'locked'
      ) else null end,
      'waitingInstruction', run_record.status = 'live' and run_record.current_stop_id is null,
      'currentStop', (
        select jsonb_build_object(
          'id', stop.id, 'version', stop.version, 'sequence', stop.sequence,
          'kind', coalesce(stop.stop_kind::text, 'ordinary'), 'openedAt', stop.opened_at,
          'reservedArrivalAt', reservation.reserved_from,
          'portal', jsonb_build_object(
            'id', portal.id, 'systemCode', portal.system_code, 'name', portal.name, 'description', portal.description, 'intensity', portal.intensity,
            'operationStatus', portal.operation_status, 'world', world.name,
            'address', concat_ws(' ', location.street, location.house_number, location.addition),
            'postalCode', location.postal_code,
            'coordinate', case when location.latitude is null then null else jsonb_build_array(location.longitude, location.latitude) end
          ),
          'scanAccepted', exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = stop.id)
        )
        from app_private.run_stops stop
        left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
        join app_private.worlds world on world.id = portal.world_id
        join app_private.portal_private_locations location on location.portal_id = portal.id
        left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
        where stop.id = run_record.current_stop_id and stop.state = 'active' and (leader or support or not own_finished)
      ),
      'participants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', participant.id, 'firstName', child.first_name, 'attendance', participant.attendance,
          'rosterVersion', participant.roster_version,
          'childId', child.id,
          'isOwnChild', app_private.is_household_member(child.household_id, actor),
          'status', status.status, 'statusVersion', status.version, 'required', status.required_for_completion
        ) order by child.first_name)
        from app_private.run_participants participant
        join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
        join app_private.children child on child.id = registration_child.child_id
        left join app_private.stop_participant_statuses status
          on status.run_participant_id = participant.id and status.run_stop_id = run_record.current_stop_id
        where participant.run_id = run_record.id
          and (leader or support or app_private.is_household_member(child.household_id, actor))
      ), '[]'::jsonb),
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'sequence', stop.sequence, 'kind', coalesce(stop.stop_kind::text, 'ordinary'),
          'outcome', stop.outcome, 'arrivalConfirmed',exists(select 1 from app_private.run_stop_arrivals a where a.run_stop_id=stop.id), 'completedAt', stop.completed_at,
          'portalName', portal.name, 'world', world.name
        ) order by stop.sequence)
        from app_private.run_stops stop
        left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
        join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
        join app_private.worlds world on world.id = portal.world_id
        where stop.run_id = run_record.id and stop.state = 'completed' and (leader or support or not own_finished or exists(select 1 from app_private.run_stop_arrivals a join app_private.children c on c.id=a.child_id where a.run_stop_id=stop.id and app_private.is_household_member(c.household_id,actor)))
      ), '[]'::jsonb)
    ) end
  );
end;
$$;

create or replace function api.group_snapshot(_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; group_record app_private.walking_groups;
begin
  result := app_private.group_snapshot_before_codes(_group_id);
  select * into group_record from app_private.walking_groups where id = _group_id;
  return jsonb_set(result, '{group}', coalesce(result -> 'group', '{}'::jsonb) || jsonb_build_object(
    'code', group_record.system_code, 'systemCode', group_record.system_code, 'displayName', group_record.display_name
  ), true);
end;
$$;
