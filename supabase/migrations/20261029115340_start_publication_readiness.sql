-- Publication readiness uses stored server values. No settings, schedules,
-- publications, runs, reservations or participant communication are changed.
-- One read-only capacity assertion is shared by snapshots and locked writes.
create or replace function app_private.assert_start_schedule_capacity_readonly(_event_id uuid, _schedule_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; settings app_private.event_route_settings; tick timestamptz; service_interval interval;
  load_groups integer; load_children bigint;
begin
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  service_interval:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
  for candidate in select s.*,slot.start_point_id,slot.starts_at,slot.max_groups,slot.max_children,
    p.max_gathering_groups,p.max_gathering_children
    from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id and g.event_id=_event_id
    join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id
    where s.id=any(_schedule_ids)
  loop
    perform app_private.assert_group_schedule_timing(candidate.group_id,candidate.start_slot_id,candidate.effective_ordinary_stop_at,candidate.expected_finale_arrival_at);
    if not app_private.valid_departure_time(candidate.starts_at) then
      raise exception 'INVALID_DEPARTURE_INTERVAL' using errcode='23514'; end if;
    if not app_private.departure_time_in_window(_event_id,candidate.starts_at) then
      raise exception 'START_TIME_OUTSIDE_EVENT' using errcode='23514'; end if;
    if not app_private.start_point_ready_at(candidate.start_point_id,candidate.starts_at) then
      raise exception 'START_POINT_CLOSED' using errcode='23514'; end if;
    -- Coalesce aliases linked to the same real portal. Different slot IDs and
    -- start-point IDs never create a second departure at the same instant.
    select count(*) into load_groups from (
      select distinct r.group_id from app_private.start_schedule_reservations(_event_id) r
      where app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id)=app_private.reserved_departure_key(candidate.group_id,candidate.id,candidate.start_point_id)
        and r.starts_at=candidate.starts_at
      union select candidate.group_id
    ) physical_departures;
    if load_groups>1 then raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_slot_id=candidate.start_slot_id group by r.group_id) q;
    if load_groups>candidate.max_groups or load_children>candidate.max_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    select count(*),coalesce(sum(n),0) into load_groups,load_children from (
      select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(_event_id) r
      where r.start_point_id=candidate.start_point_id and r.starts_at=candidate.starts_at group by r.group_id) q;
    if load_groups>candidate.max_gathering_groups or load_children>candidate.max_gathering_children then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    if candidate.expected_finale_arrival_at is null or candidate.expected_finale_arrival_at<settings.finale_opens_at
      or candidate.expected_finale_arrival_at>settings.finale_last_arrival_at then
      raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    -- Half-open intervals, evaluated at every occupancy change. A group's
    -- overlapping old and new reservation contributes its children once.
    for tick in select distinct r.starts_at from app_private.finale_occupancy_intervals(_event_id,statement_timestamp()) r
      where r.starts_at<candidate.expected_finale_arrival_at+service_interval and r.ends_at>candidate.expected_finale_arrival_at
      union select candidate.expected_finale_arrival_at
    loop
      select count(*),coalesce(sum(n),0) into load_groups,load_children from (
        select r.group_id,max(r.children) n from app_private.finale_occupancy_intervals(_event_id,statement_timestamp()) r
        where r.starts_at<=tick and r.ends_at>tick group by r.group_id) q;
      if load_groups>settings.finale_max_concurrent_groups or load_children>settings.finale_max_concurrent_children
        or not exists(select 1 from app_private.portal_windows w where w.portal_id=settings.final_portal_id
          and candidate.expected_finale_arrival_at>=w.opens_at and candidate.expected_finale_arrival_at+service_interval<=w.closes_at
          and load_groups<=w.max_concurrent_groups and load_children<=w.max_children_total
          and (select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null)<=w.max_children_per_visit) then
        raise exception 'FINALE_CAPACITY_EXCEEDED' using errcode='23514'; end if;
    end loop;
    if exists(select 1 from app_private.start_points point where point.id=candidate.start_point_id and point.linked_portal_id is not null and
      not app_private.portal_interval_available(point.linked_portal_id,candidate.group_id,candidate.starts_at,
        candidate.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,candidate.starts_at)),
        (select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=candidate.group_id and a.superseded_at is null),statement_timestamp())) then
      raise exception 'START_POINT_CAPACITY_EXCEEDED' using errcode='23514';
    end if;
  end loop;
end;
$function$
;

revoke all on function app_private.assert_start_schedule_capacity_readonly(uuid,uuid[]) from public,anon,authenticated;

create or replace function app_private.validate_start_schedule_capacity(_event_id uuid,_schedule_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
begin
  perform 1 from app_private.events where id=_event_id for update;
  perform app_private.assert_start_schedule_capacity_readonly(_event_id,_schedule_ids);
end $$;
revoke all on function app_private.validate_start_schedule_capacity(uuid,uuid[]) from public,anon,authenticated;

create or replace function app_private.start_publication_reason(_code text)
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object('code',_code,'message',case _code
    when 'ROUTE_SETTINGS_MISSING' then 'De opgeslagen planningskaders ontbreken. Open Kaders en sla ze op.'
    when 'PLANNER_MODE_NOT_DYNAMIC' then 'De opgeslagen plannerstand is niet Dynamisch plannen. Kies deze stand in Kaders en sla op.'
    when 'FINAL_PORTAL_MISSING' then 'Er is geen laatste poort opgeslagen. Kies de aangewezen laatste poort in Kaders.'
    when 'FINAL_PORTAL_NOT_ELIGIBLE' then 'De aangewezen laatste poort is niet goedgekeurd en actief. Controleer deze poort.'
    when 'FINALE_OPERATION_UNAVAILABLE' then 'De laatste poort staat gesloten of gepauzeerd. Controleer bij Poorten de echte beschikbaarheid; alleen gepland geopend of open kan worden gepubliceerd.'
    when 'FINALE_NOT_CONFIRMED_AVAILABLE' then 'Laatste poort veilig beschikbaar is nog niet bevestigd in de opgeslagen Kaders. Controleer de echte beschikbaarheid, vink deze instelling aan en sla op. De ingevulde tijden blijven behouden.'
    when 'FINAL_PORTAL_POSITION_INVALID' then 'De laatste poort heeft geen geldig opgeslagen adres en ingangspin. Controleer de finalepoort.'
    when 'START_WINDOW_INCOMPLETE' then 'Het opgeslagen startvenster of einde van de gewone poorten ontbreekt. Controleer Kaders.'
    when 'FINALE_TIMES_MISSING' then 'Opening, laatste aankomst of definitieve sluiting van de finale ontbreekt in de opgeslagen Kaders.'
    when 'FINALE_TIME_ORDER_INVALID' then 'De opgeslagen finaletijden staan niet in de volgorde opening, laatste aankomst, definitieve sluiting.'
    when 'FINALE_SERVICE_DOES_NOT_FIT' then 'Show en wisseltijd passen niet tussen de opgeslagen finaleopening en definitieve sluiting.'
    when 'FINALE_PHYSICAL_WINDOW_CONFLICT' then 'Show en wisseltijd passen niet in een echte opening van de finalepoort. Controleer de poortopening en het aparte finalevenster.'
    when 'FINALE_CAPACITY_EXCEEDED' then 'De finale heeft op het opgeslagen moment onvoldoende ruimte voor de groepen of kinderen. Controleer de verdeling; groepen tegelijk blijft een echte capaciteit.'
    when 'START_POINT_CAPACITY_EXCEEDED' then 'De opgeslagen startplek of gekoppelde eerste poort heeft op dit moment onvoldoende ruimte.'
    when 'START_DEPARTURE_OCCUPIED' then 'Bij deze startpoort vertrekt op dit tienminutenslot al een andere groep.'
    when 'GROUP_END_TIME_INFEASIBLE' then 'De opgeslagen route overschrijdt een harde gewone poortgrens, overdracht, finalevenster of de maximale groepsuitloop inclusief show. Controleer de tijden van deze groep.'
    when 'START_POINT_CLOSED' then 'Het opgeslagen startpunt is op dit tijdstip niet beschikbaar of de locatie is nog niet bevestigd.'
    when 'START_POINT_NOT_VERIFIED' then 'Bevestig eerst de opgeslagen locatie van het startpunt.'
    when 'INVALID_DEPARTURE_INTERVAL' then 'De opgeslagen vertrektijd valt niet op een heel tienminutenslot.'
    when 'START_TIME_OUTSIDE_EVENT' then 'De opgeslagen vertrektijd ligt buiten het ingestelde startvenster.'
    when 'STALE_REVISION' then 'Deze conceptrevisie is niet meer de actuele opgeslagen afspraak. Vernieuw en beoordeel de nieuwe revisie.'
    when 'STALE_VERSION' then 'De evenementinstellingen zijn intussen gewijzigd. Vernieuw en beoordeel de actuele opgeslagen afspraken.'
    when 'GROUP_ALREADY_STARTED' then 'Een geselecteerde groep is al onderweg. Wijzig de begonnen route alleen via avondregie.'
    else 'De opgeslagen afspraak is nog niet gereed. Controleer de indeling ('||_code||').' end,
    'action',case when _code in ('FINAL_PORTAL_NOT_ELIGIBLE','FINALE_OPERATION_UNAVAILABLE','FINAL_PORTAL_POSITION_INVALID','FINALE_PHYSICAL_WINDOW_CONFLICT') then 'portals'
      when _code in ('START_POINT_CLOSED','START_POINT_NOT_VERIFIED') then 'points'
      when _code in ('ROUTE_SETTINGS_MISSING','PLANNER_MODE_NOT_DYNAMIC','FINAL_PORTAL_MISSING','FINALE_NOT_CONFIRMED_AVAILABLE','START_WINDOW_INCOMPLETE','FINALE_TIMES_MISSING','FINALE_TIME_ORDER_INVALID','FINALE_SERVICE_DOES_NOT_FIT') then 'settings'
      else 'planning' end,
    'field',case _code when 'PLANNER_MODE_NOT_DYNAMIC' then 'plannerMode' when 'FINAL_PORTAL_MISSING' then 'finalPortalId'
      when 'FINALE_NOT_CONFIRMED_AVAILABLE' then 'finaleAvailable' when 'START_WINDOW_INCOMPLETE' then 'firstStartAt'
      when 'FINALE_TIMES_MISSING' then 'finaleTimes' when 'FINALE_TIME_ORDER_INVALID' then 'finaleTimes'
      when 'FINALE_SERVICE_DOES_NOT_FIT' then 'finaleTimes' else null end)
$$;
revoke all on function app_private.start_publication_reason(text) from public,anon,authenticated;

create or replace function app_private.start_publication_readiness(_event_id uuid,_schedule_ids uuid[] default '{}'::uuid[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare settings app_private.event_route_settings; final app_private.portals; reasons jsonb:='[]'::jsonb;
  service interval; code text; event_version integer;
begin
  select * into settings from app_private.event_route_settings where event_id=_event_id;
  select settings_version into event_version from app_private.events where id=_event_id;
  if settings.event_id is null then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('ROUTE_SETTINGS_MISSING'));
  else
    service:=make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds);
    if settings.planner_mode is distinct from 'dynamic' then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('PLANNER_MODE_NOT_DYNAMIC')); end if;
    if settings.final_portal_id is null then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINAL_PORTAL_MISSING'));
    else
      select * into final from app_private.portals where id=settings.final_portal_id and event_id=_event_id;
      if final.id is null or final.approval_status<>'approved' or final.lifecycle_status<>'active' then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINAL_PORTAL_NOT_ELIGIBLE')); end if;
      if final.id is not null and final.operation_status not in ('open','scheduled') then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_OPERATION_UNAVAILABLE')); end if;
      if not coalesce(app_private.portal_location_ready(settings.final_portal_id),false) then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINAL_PORTAL_POSITION_INVALID')); end if;
    end if;
    if not settings.finale_available then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_NOT_CONFIRMED_AVAILABLE')); end if;
    if settings.first_start_at is null or settings.global_ordinary_stop_at is null then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('START_WINDOW_INCOMPLETE')); end if;
    if settings.finale_opens_at is null or settings.finale_last_arrival_at is null or settings.finale_closes_at is null then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_TIMES_MISSING'));
    elsif settings.finale_opens_at>settings.finale_last_arrival_at or settings.finale_last_arrival_at>settings.finale_closes_at then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_TIME_ORDER_INVALID'));
    elsif settings.finale_opens_at+service>settings.finale_closes_at then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_SERVICE_DOES_NOT_FIT'));
    elsif settings.final_portal_id is not null and not exists(select 1 from app_private.portal_windows w where w.portal_id=settings.final_portal_id
      and greatest(w.opens_at,settings.finale_opens_at)<=settings.finale_last_arrival_at
      and greatest(w.opens_at,settings.finale_opens_at)+service<=least(w.closes_at,settings.finale_closes_at)) then
      reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('FINALE_PHYSICAL_WINDOW_CONFLICT'));
    end if;
  end if;
  if cardinality(_schedule_ids)>0 then
    if (select count(*) from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
      where s.id=any(_schedule_ids) and g.event_id=_event_id and g.retired_at is null
        and g.current_schedule_revision_id=s.id and s.state in ('draft','published'))<>cardinality(_schedule_ids) then
      reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('STALE_REVISION'));
    elsif exists(select 1 from app_private.group_runs r join app_private.group_schedule_revisions s on s.group_id=r.group_id where s.id=any(_schedule_ids)) then
      reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('GROUP_ALREADY_STARTED'));
    elsif jsonb_array_length(reasons)=0 then
      begin
        perform app_private.assert_start_schedule_capacity_readonly(_event_id,_schedule_ids);
      exception when check_violation then
        get stacked diagnostics code=message_text;
        reasons:=reasons||jsonb_build_array(app_private.start_publication_reason(code));
      end;
    end if;
  end if;
  return jsonb_build_object('ready',jsonb_array_length(reasons)=0,'reasons',reasons,
    'routeSettingsVersion',settings.version,'eventSettingsVersion',event_version);
end $$;
revoke all on function app_private.start_publication_readiness(uuid,uuid[]) from public,anon,authenticated;

-- A scoped read-only preflight checks the very revisions shown in the dialog.
create or replace function api.admin_startregie_publication_readiness(_event_slug text,_expected_revisions jsonb,_expected_settings_version integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; result jsonb; ids uuid[]; reasons jsonb;
begin
  select * into e from app_private.events where slug=_event_slug;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if jsonb_typeof(_expected_revisions) is distinct from 'array' or jsonb_array_length(_expected_revisions) not between 1 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  select array_agg((item->>'id')::uuid) into ids from jsonb_array_elements(_expected_revisions) item;
  result:=app_private.start_publication_readiness(e.id,ids); reasons:=result->'reasons';
  if e.settings_version is distinct from _expected_settings_version then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('STALE_VERSION')); end if;
  if exists(select 1 from jsonb_array_elements(_expected_revisions) item where not exists(select 1 from app_private.group_schedule_revisions s
    join app_private.walking_groups g on g.id=s.group_id where s.id=(item->>'id')::uuid and s.revision=(item->>'revision')::integer
      and g.event_id=e.id and g.retired_at is null and g.current_schedule_revision_id=s.id)) then
    if not reasons @> '[{"code":"STALE_REVISION"}]'::jsonb then reasons:=reasons||jsonb_build_array(app_private.start_publication_reason('STALE_REVISION')); end if;
  end if;
  return result||jsonb_build_object('ready',jsonb_array_length(reasons)=0,'reasons',reasons);
end $$;
revoke all on function api.admin_startregie_publication_readiness(text,jsonb,integer) from public,anon;
grant execute on function api.admin_startregie_publication_readiness(text,jsonb,integer) to authenticated;

-- Keep the complete existing publication, revision, authorization and mail flow.
-- The added gate names the concrete failing setting; it never confirms safety.
alter function app_private.publish_group_schedules_ops(text,uuid[],text) rename to publish_group_schedules_ops_before_publication_readiness;
revoke all on function app_private.publish_group_schedules_ops_before_publication_readiness(text,uuid[],text) from public,anon,authenticated;
create or replace function app_private.publish_group_schedules_ops(_event_slug text,_schedule_ids uuid[],_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; readiness jsonb;
begin
  select * into e from app_private.events where slug=_event_slug for update;
  if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  readiness:=app_private.start_publication_readiness(e.id,_schedule_ids);
  if not (readiness->>'ready')::boolean then raise exception '%',readiness#>>'{reasons,0,code}' using errcode='23514',detail=readiness::text; end if;
  return app_private.publish_group_schedules_ops_before_publication_readiness(_event_slug,_schedule_ids,_reason);
end $$;
revoke all on function app_private.publish_group_schedules_ops(text,uuid[],text) from public,anon,authenticated;

alter function api.admin_startregie_snapshot(text) rename to admin_startregie_snapshot_before_publication_readiness;
alter function api.admin_startregie_snapshot_before_publication_readiness(text) set schema app_private;
revoke all on function app_private.admin_startregie_snapshot_before_publication_readiness(text) from public,anon,authenticated;
create or replace function api.admin_startregie_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb; eid uuid;
begin
  base:=app_private.admin_startregie_snapshot_before_publication_readiness(_event_slug);
  select id into eid from app_private.events where slug=_event_slug;
  return base||jsonb_build_object('publicationReadiness',app_private.start_publication_readiness(eid));
end $$;
revoke all on function api.admin_startregie_snapshot(text) from public,anon;
grant execute on function api.admin_startregie_snapshot(text) to authenticated;
