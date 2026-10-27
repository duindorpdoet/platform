alter table app_private.group_runs add column finale_only boolean not null default false;

-- One verified physical-portal mapping and ETA assessment for every caller.
create or replace function app_private.shortest_portal_walk(_event_id uuid,_source_node uuid,_portal_id uuid,_step_free boolean)
returns table(node_id uuid,distance_m bigint,duration_seconds bigint,edge_ids uuid[])
language sql stable security definer set search_path='' as $function$
 select n.id,m.distance_m,m.duration_seconds,m.edge_ids from app_private.walking_nodes n
 join app_private.portal_private_locations l on l.portal_id=n.portal_id and l.verified_at is not null
 cross join lateral app_private.walking_path_metrics(_event_id,_source_node,n.id,_step_free) m
 where n.event_id=_event_id and n.portal_id=_portal_id and n.verified_at is not null
  and exists(select 1 from app_private.walking_nodes source where source.id=_source_node and source.event_id=_event_id and source.verified_at is not null)
  and abs(n.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<.000001
  and abs(n.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<.000001
  and exists(select 1 from app_private.walking_edges edge where edge.event_id=_event_id and edge.approved_at is not null and edge.closed_at is null and (edge.from_node_id=n.id or edge.to_node_id=n.id))
 order by m.duration_seconds,m.distance_m,n.id,m.edge_ids limit 1
$function$;

create or replace function app_private.evening_route_candidates(
 _context jsonb,_source_node uuid,_departure_at timestamptz,_seen uuid[],_remaining_visits integer,_only_portal uuid default null
) returns jsonb language plpgsql volatile security definer set search_path='' as $function$
declare candidate record; incoming record; outgoing record; physical jsonb; codes jsonb; reasons jsonb; result jsonb:='[]';
 candidate_event_id uuid:=(_context->>'eventId')::uuid; candidate_group_id uuid:=(_context->>'groupId')::uuid;
 finale_id uuid:=(_context->>'finalePortalId')::uuid; configured_finale uuid;
 children integer:=(_context->>'childCount')::integer; step_free boolean:=coalesce((_context->>'requiresStepFree')::boolean,false);
 arrival_at timestamptz; occupied_until timestamptz; final_earliest timestamptz; status_label text;
begin
 select cfg.final_portal_id into configured_finale from app_private.event_route_settings cfg where cfg.event_id=candidate_event_id;
 for candidate in
  select p.*,l.street,l.house_number,l.addition,
   coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude) longitude,
   coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude) latitude,w.name world,
   coalesce(info.information->>'accessibility',a.private_draft_data->>'accessibility','unknown') accessibility
  from app_private.portals p join app_private.worlds w on w.id=p.world_id
  left join app_private.portal_private_locations l on l.portal_id=p.id
  left join app_private.portal_applications a on a.id=p.application_id
  left join app_private.portal_visit_information info on info.portal_id=p.id
  where p.event_id=candidate_event_id and p.id is distinct from finale_id and p.id is distinct from configured_finale and (_only_portal is null or p.id=_only_portal)
  order by p.system_number,p.id
 loop
  select * into incoming from app_private.shortest_portal_walk(candidate_event_id,_source_node,candidate.id,step_free);
  arrival_at:=_departure_at+make_interval(secs=>incoming.duration_seconds::integer);
  physical:=app_private.assess_ordinary_portal(candidate_event_id,candidate_group_id,candidate.id,arrival_at,children,coalesce((_context->>'serverNowAt')::timestamptz,clock_timestamp()));
  codes:=physical->'blockingCodes';reasons:=physical->'reasons';occupied_until:=(physical->>'occupiedUntil')::timestamptz;
  select * into outgoing from app_private.shortest_portal_walk(candidate_event_id,incoming.node_id,finale_id,step_free);
  final_earliest:=occupied_until+make_interval(secs=>outgoing.duration_seconds::integer);
  if incoming.duration_seconds is null then codes:=codes||'"NO_SAFE_WALKING_PATH"'::jsonb;reasons:=reasons||'"Geen gecontroleerde wandelroute vanaf de bevestigde plek."'::jsonb;end if;
  if outgoing.duration_seconds is null then codes:=codes||'"NO_SAFE_FINALE_PATH"'::jsonb;reasons:=reasons||'"Geen gecontroleerde aansluitroute naar de finale."'::jsonb;end if;
  if step_free and candidate.accessibility<>'step_free' then codes:=codes||'"PORTAL_ACCESSIBILITY_CONFLICT"'::jsonb;reasons:=reasons||'"De praktische toegankelijkheid van deze poort past niet bij deze groep."'::jsonb;end if;
  if candidate.id::text=_context#>>'{currentStop,portalId}' then
   codes:=codes||'"CURRENT_DESTINATION"'::jsonb;reasons:=reasons||'"Dit is de huidige vrijgegeven bestemming."'::jsonb;
  elsif candidate.id=any(coalesce(_seen,'{}'::uuid[])) then
   codes:=codes||'"PORTAL_ALREADY_IN_ROUTE"'::jsonb;reasons:=reasons||'"Deze poort komt al in deze route voor."'::jsonb;
  end if;
  if candidate.id::text=_context->>'gatheringPortalId' and not coalesce((_context->>'startCountsAsVisit')::boolean,false) then
   codes:=codes||'"GATHERING_ONLY"'::jsonb;reasons:=reasons||'"Dit is alleen jullie verzamelpunt en telt niet als huisbezoek."'::jsonb;
  end if;
  if _remaining_visits is not null and _remaining_visits<=0 then codes:=codes||'"ORDINARY_VISIT_LIMIT_REACHED"'::jsonb;reasons:=reasons||'"Het gekozen maximumaantal gewone poorten is bereikt."'::jsonb;end if;
  if _context->>'ordinaryStopAt' is null then codes:=codes||'"ORDINARY_CUTOFF_REQUIRED"'::jsonb;reasons:=reasons||'"De stopgrens voor gewone poorten ontbreekt."'::jsonb;
  elsif occupied_until>(_context->>'ordinaryStopAt')::timestamptz then codes:=codes||'"ORDINARY_CUTOFF_REACHED"'::jsonb;reasons:=reasons||'"Dit bezoek en de buffer passen niet vóór de stopgrens."'::jsonb;end if;
  if _context->>'finaleArrivalAt' is null then codes:=codes||'"FINAL_RESERVATION_REQUIRED"'::jsonb;reasons:=reasons||'"Er ontbreekt een geldige finale-afspraak."'::jsonb;
  elsif final_earliest>(_context->>'finaleArrivalAt')::timestamptz then codes:=codes||'"FINAL_RESERVATION_MISSED"'::jsonb;reasons:=reasons||'"Na dit huis is de vaste finale-afspraak niet meer haalbaar."'::jsonb;end if;
  status_label:=case when candidate.lifecycle_status='archived' then 'Gearchiveerd' when candidate.approval_status<>'approved' then 'Nog niet goedgekeurd'
   when candidate.operation_status='paused' then 'Pauze' when candidate.operation_status='closed' then 'Gesloten' when candidate.operation_status='scheduled' then 'Gepland' when candidate.operation_status='open' then 'Open' else 'Niet beschikbaar' end;
  result:=result||jsonb_build_array(jsonb_build_object('id',candidate.id,'portalId',candidate.id,'code',candidate.system_code,'name',candidate.name,'world',candidate.world,
   'worldId',candidate.world_id,'address',case when candidate.approval_status='approved' then concat_ws(' ',candidate.street,candidate.house_number,candidate.addition) else null end,
   'coordinate',case when candidate.longitude is not null and candidate.latitude is not null then jsonb_build_array(candidate.longitude,candidate.latitude) else null end,
   'status',status_label,'operationStatus',candidate.operation_status,'eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
   'capacity',physical#>'{capacity,maxChildren}','capacityDetails',physical->'capacity','expectedAt',arrival_at,'plannedArrivalAt',arrival_at,
   'plannedDepartureAt',physical->'plannedDepartureAt','occupiedUntil',occupied_until,'finaleEarliestAt',final_earliest,
   'nodeId',incoming.node_id,'walkSeconds',incoming.duration_seconds,'walkMeters',incoming.distance_m,'incomingEdgeIds',incoming.edge_ids,
   'finaleWalkSeconds',outgoing.duration_seconds,
   'score',incoming.duration_seconds+case when candidate.world_id=(select p.world_id from app_private.portals p where p.id=(_context->>'lastConfirmedPortalId')::uuid) then 120 else 0 end
    +greatest(0,coalesce((physical#>>'{capacity,peakGroups}')::integer,1)-1)*30));
 end loop;
 return result;
end;
$function$;
revoke all on function app_private.shortest_portal_walk(uuid,uuid,uuid,boolean),app_private.evening_route_candidates(jsonb,uuid,timestamptz,uuid[],integer,uuid) from public,anon,authenticated;

create or replace function api.admin_route_command_options(_run_id uuid)
returns jsonb language plpgsql volatile security definer set search_path='' as $function$
declare actor uuid:=auth.uid(); r app_private.group_runs; g app_private.walking_groups; context jsonb; candidates jsonb;
 portals jsonb; adults jsonb; finale jsonb; general_reason text; remaining integer;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 if actor is null or g.id is null or not (app_private.has_capability(g.event_id,'groups_manage',actor) or app_private.has_capability(g.event_id,'live_support',actor)) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if r.status not in ('live','paused') then raise exception 'RUN_NOT_ACTIVE' using errcode='23514';end if;
 context:=app_private.evening_route_context(g.id);
 if context->>'runId' is distinct from r.id::text then raise exception 'RUN_NOT_CURRENT' using errcode='40001';end if;
 remaining:=case when context->>'ordinaryVisitLimit' is null then null else greatest(0,(context->>'ordinaryVisitLimit')::integer-(context->>'completedOrdinaryVisits')::integer) end;
 candidates:=app_private.evening_route_candidates(context,(context->>'sourceNodeId')::uuid,(context->>'serverNowAt')::timestamptz,
  array(select v::uuid from jsonb_array_elements_text(context->'seenPortalIds') v),remaining);
 general_reason:=case when g.route_mode<>'dynamic' then 'Deze bestaande route moet eerst in Startregie worden aangevuld.'
   when r.status<>'live' then 'De tocht staat op pauze. Hervat de tocht voordat je haar omleidt.'
   when context#>>'{currentStop,kind}'='finale' then 'De finale is al vrijgegeven.'
   when coalesce((context#>>'{currentStop,scanAccepted}')::boolean,false) then 'Het huidige bezoek is al begonnen. Rond dit bezoek eerst af.' end;
 select coalesce(jsonb_agg(jsonb_build_object('id',row->'id','code',row->'code','name',row->'name','address',row->'address',
   'status',row->'status','eligible',general_reason is null and (row->>'eligible')::boolean,
   'reasons',case when general_reason is null then row->'reasons' else (row->'reasons')||jsonb_build_array(general_reason) end,
   'capacity',row->'capacity','capacityDetails',row->'capacityDetails','expectedAt',row->'expectedAt') order by row->>'code'),'[]')
 into portals from jsonb_array_elements(candidates) row;
 with raw as (
  select distinct a.user_id,app_private.readiness_actor_label('group',g.id,a.user_id) label,u.email
  from app_private.readiness_group_adults(g.id) a join auth.users u on u.id=a.user_id
 ), labeled as (
  select *,count(*) over(partition by label) duplicates,row_number() over(partition by label order by user_id) ordinal from raw
 )
 select coalesce(jsonb_agg(jsonb_build_object('userId',user_id,'label',case when duplicates>1 then label||' · '||coalesce(nullif(email,''),'contactpersoon '||ordinal) else label end) order by label,user_id),'[]') into adults from labeled;
 finale:=app_private.run_finale_details(r.id,clock_timestamp());
 return jsonb_build_object('runVersion',r.version,'groupCode',g.system_code,'portals',portals,'adults',adults,
   'finale',jsonb_build_object('eligible',general_reason is null and (finale->>'eligible')::boolean,
     'reasons',case when general_reason is not null then jsonb_build_array(general_reason) else
      case finale->>'code' when 'FINAL_RESERVATION_MISSED' then jsonb_build_array('De vaste finale-afspraak is niet meer haalbaar. Organisatiecontrole en herplanning zijn nodig.')
       when 'FINAL_RESERVATION_REQUIRED' then jsonb_build_array('Er ontbreekt een geldige gepubliceerde finale-afspraak.')
       when 'NO_SAFE_FINALE_PATH' then jsonb_build_array('Er is geen gecontroleerde wandelroute vanaf de bevestigde plek naar de finale.')
       when 'FINALE_CAPACITY_EXCEEDED' then jsonb_build_array('De vaste finale-afspraak heeft onvoldoende ontvangstcapaciteit.')
       when 'FINALE_UNAVAILABLE' then jsonb_build_array('De gepubliceerde finale is niet beschikbaar.')
       when 'FINAL_RESERVATION_CONFLICT' then jsonb_build_array('De vaste finale-afspraak vraagt controle door de organisatie.') else '[]'::jsonb end end,
     'reservedArrivalAt',finale->'reservedArrivalAt','waitingUntil',finale->'waitingUntil'));
end;
$function$;
revoke all on function api.admin_route_command_options(uuid) from public,anon;
grant execute on function api.admin_route_command_options(uuid) to authenticated;

-- Stop at the first candidate that passes the shared full assessment. This
-- avoids evaluating every house's capacity again for each future route stop.
create or replace function app_private.pick_evening_route_candidate(
 _context jsonb,_source_node uuid,_departure_at timestamptz,_seen uuid[],_remaining_visits integer,_preferred_portal uuid default null
) returns jsonb language plpgsql volatile security definer set search_path='' as $function$
declare option record; assessed jsonb; candidate_event uuid:=(_context->>'eventId')::uuid;
 previous_world uuid; needs_step_free boolean:=coalesce((_context->>'requiresStepFree')::boolean,false);
begin
 if _source_node is null or _departure_at is null or (_remaining_visits is not null and _remaining_visits<=0) then return null;end if;
 select p.world_id into previous_world from app_private.portals p where p.id=coalesce((_context->>'scoringPreviousPortalId')::uuid,(_context->>'lastConfirmedPortalId')::uuid);
 for option in
  select p.id,m.duration_seconds+case when p.world_id=previous_world then 120 else 0 end
    +(select count(*)*30 from app_private.portal_reservations b where b.portal_id=p.id and b.status in ('held','active') and (b.expires_at is null or b.expires_at>clock_timestamp())) score
  from app_private.portals p
  left join app_private.portal_applications a on a.id=p.application_id
  left join app_private.portal_visit_information info on info.portal_id=p.id
  cross join lateral app_private.shortest_portal_walk(candidate_event,_source_node,p.id,needs_step_free) m
  where p.event_id=candidate_event and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled')
   and p.id is distinct from (_context->>'finalePortalId')::uuid
   and p.id is distinct from (select cfg.final_portal_id from app_private.event_route_settings cfg where cfg.event_id=candidate_event)
   and not(p.id=any(coalesce(_seen,'{}'::uuid[])))
   and (_preferred_portal is null or p.id=_preferred_portal)
   and (coalesce((_context->>'startCountsAsVisit')::boolean,false) or p.id is distinct from (_context->>'gatheringPortalId')::uuid)
   and (not needs_step_free or coalesce(info.information->>'accessibility',a.private_draft_data->>'accessibility','unknown')='step_free')
  order by score,p.id
 loop
  assessed:=app_private.evening_route_candidates(_context,_source_node,_departure_at,_seen,_remaining_visits,option.id)->0;
  if (assessed->>'eligible')::boolean then return assessed;end if;
 end loop;
 return null;
end;
$function$;
revoke all on function app_private.pick_evening_route_candidate(jsonb,uuid,timestamptz,uuid[],integer,uuid) from public,anon,authenticated;

create or replace function app_private.compute_evening_route_preview(_group_id uuid,_revision integer default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $function$
declare context jsonb:=app_private.evening_route_context(_group_id); origin jsonb; stops jsonb:='[]'; warnings jsonb:='[]'; blockers jsonb:='[]'; checklist jsonb:='[]';
 candidates jsonb; selected jsonb; current_stop jsonb; finale jsonb; finale_walk record; capacity jsonb; last_location app_private.run_stop_location_snapshots;
 source_node uuid; seen uuid[]; at_time timestamptz; from_time timestamptz; target timestamptz; planned_finale timestamptz;
 remaining integer; selected_visits integer:=0; available integer:=0; meters bigint:=0; total_minutes integer:=0; first_portal uuid; finale_id uuid; preview_event_id uuid;
 final_stop_present boolean:=false; iteration integer:=0; live boolean; valid_start boolean;
begin
 if context is null then return null;end if;
 preview_event_id:=(context->>'eventId')::uuid;live:=context->>'mode'='live';from_time:=(context->>'calculatedFromAt')::timestamptz;
 at_time:=(context->>'remainingFromAt')::timestamptz;source_node:=(context->>'remainingSourceNodeId')::uuid;
 finale_id:=(context->>'finalePortalId')::uuid;target:=(context->>'finaleArrivalAt')::timestamptz;
 current_stop:=context->'currentStop';origin:=context->'start';valid_start:=coalesce((context->>'hasConfirmedStart')::boolean,false);
 seen:=array(select v::uuid from jsonb_array_elements_text(context->'seenPortalIds') v);
 remaining:=case when coalesce((context->>'finaleOnly')::boolean,false) then 0 else (context->>'remainingOrdinaryVisits')::integer end;
 if live then
  if context->>'lastConfirmedStopId' is not null then
   select * into last_location from app_private.run_stop_location_snapshots where run_stop_id=(context->>'lastConfirmedStopId')::uuid;
   origin:=jsonb_build_object('pointId',context->'sourceNodeId','name','Laatste bevestigde plek · '||(select p.system_code from app_private.portals p where p.id=(context->>'lastConfirmedPortalId')::uuid),
    'address',case when last_location.run_stop_id is not null then concat_ws(' ',last_location.address->>'street',last_location.address->>'houseNumber',last_location.address->>'addition') else 'Eerder bevestigde poort' end,
    'coordinate',case when last_location.longitude is not null and last_location.latitude is not null then jsonb_build_array(last_location.longitude,last_location.latitude) else null end,'startsAt',from_time);
  else origin:=origin||jsonb_build_object('startsAt',from_time);end if;
 end if;
 if not valid_start then blockers:=blockers||'"Kies en bevestig eerst een startpunt en tijd."'::jsonb;end if;
 if (context->>'childCount')::integer<=0 then blockers:=blockers||'"Er zijn geen kinderen om deze route te plannen."'::jsonb;end if;
 if source_node is null and not coalesce(current_stop->>'kind'='finale' and (current_stop->>'scanAccepted')::boolean,false) then blockers:=blockers||'"De gecontroleerde wandelverbinding vanaf de bevestigde plek ontbreekt."'::jsonb;end if;
 if not live and context#>>'{start,pointId}' is not null and not exists(select 1 from app_private.start_points p where p.id=(context#>>'{start,pointId}')::uuid and p.event_id=preview_event_id and p.active) then
  blockers:=blockers||'"Het bevestigde startpunt is niet beschikbaar."'::jsonb;
 end if;
 if current_stop is not null and current_stop<>'null'::jsonb then
  stops:=stops||jsonb_build_array(current_stop||jsonb_build_object('sequence',1));
  meters:=coalesce((current_stop->>'walkMeters')::bigint,0);
  final_stop_present:=current_stop->>'kind'='finale';
  if current_stop->>'kind'='ordinary' then selected_visits:=selected_visits+1;end if;
  if exists(select 1 from app_private.portals p where p.id=(current_stop->>'portalId')::uuid and p.operation_status='closed') then
   blockers:=blockers||'"De huidige bestemming is gesloten. De vrijgegeven instructie blijft herkenbaar; organisatiecontrole is nodig."'::jsonb;
  end if;
 end if;
 if coalesce((context->>'terminal')::boolean,false) then
  stops:='[]';source_node:=null;final_stop_present:=true;blockers:='[]';
 elsif not final_stop_present and source_node is not null and valid_start then
  candidates:=app_private.evening_route_candidates(context,source_node,at_time,seen,null);
  select count(*) into available from jsonb_array_elements(candidates) row where (row->>'eligible')::boolean;
  if not live and coalesce((context->>'startCountsAsVisit')::boolean,false) and (context->>'gatheringPortalId')::uuid is distinct from finale_id then first_portal:=(context->>'gatheringPortalId')::uuid;end if;
  loop
   exit when remaining is not null and remaining<=0;
   exit when iteration>=500;
   selected:=app_private.pick_evening_route_candidate(context,source_node,at_time,seen,remaining,first_portal);
   if selected is null then
    if first_portal is not null then
     blockers:=blockers||'"De gekoppelde eerste poort past niet veilig bij deze groep of afspraak."'::jsonb;
    end if;
    exit;
   end if;
   stops:=stops||jsonb_build_array(selected||jsonb_build_object('portalId',selected->'id','kind','ordinary','status','expected',
    'sequence',jsonb_array_length(stops)+1,'walkMinutes',ceil((selected->>'walkSeconds')::numeric/60.0)));
   meters:=meters+coalesce((selected->>'walkMeters')::bigint,0);
   at_time:=(selected->>'occupiedUntil')::timestamptz;source_node:=(selected->>'nodeId')::uuid;
   seen:=array_append(seen,(selected->>'id')::uuid);selected_visits:=selected_visits+1;
   if remaining is not null then remaining:=remaining-1;end if;
   context:=context||jsonb_build_object('scoringPreviousPortalId',selected->'id');first_portal:=null;iteration:=iteration+1;
  end loop;
 end if;
 if not final_stop_present then
  if finale_id is null or target is null then blockers:=blockers||'"Er ontbreekt een geldige finale-afspraak."'::jsonb;
  else
   select * into finale_walk from app_private.shortest_portal_walk(preview_event_id,source_node,finale_id,coalesce((context->>'requiresStepFree')::boolean,false));
   if finale_walk.duration_seconds is null then blockers:=blockers||'"Er is geen gecontroleerde wandelroute naar de finale."'::jsonb;
   else
    planned_finale:=greatest(target,at_time+make_interval(secs=>finale_walk.duration_seconds::integer));
    if planned_finale>target+make_interval(secs=>(context->>'finaleGraceSeconds')::integer) then blockers:=blockers||'"De vaste finale-afspraak is niet meer haalbaar; herplanning is nodig."'::jsonb;end if;
    select app_private.assess_finale_reservation(preview_event_id,_group_id,finale_id,target,
      coalesce((context->>'finaleOccupiedUntil')::timestamptz,target+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds)),(context->>'childCount')::integer,clock_timestamp())
      into capacity from app_private.event_route_settings cfg where cfg.event_id=preview_event_id;
    if not coalesce((capacity->>'eligible')::boolean,false) then blockers:=blockers||coalesce(capacity->'reasons',jsonb_build_array('De finale is niet beschikbaar.'));end if;
    select jsonb_build_object('portalId',p.id,'code',p.system_code,'name',p.name,'world',w.name,'kind','finale','status','expected',
      'address',concat_ws(' ',l.street,l.house_number,l.addition),'coordinate',jsonb_build_array(coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)),
      'sequence',jsonb_array_length(stops)+1,'walkMeters',finale_walk.distance_m,'walkMinutes',ceil(finale_walk.duration_seconds/60.0),
      'plannedArrivalAt',planned_finale,'reservedArrivalAt',case when (context->>'finaleReserved')::boolean then target else null end,
      'reservationId',context->'finaleReservationId','waitingUntil',target-make_interval(secs=>finale_walk.duration_seconds::integer))
     into finale from app_private.portals p join app_private.worlds w on w.id=p.world_id join app_private.portal_private_locations l on l.portal_id=p.id where p.id=finale_id and p.event_id=preview_event_id;
    if finale is not null then stops:=stops||jsonb_build_array(finale);meters:=meters+finale_walk.distance_m;end if;
   end if;
  end if;
 else
  if current_stop is not null and current_stop<>'null'::jsonb then planned_finale:=(current_stop->>'plannedArrivalAt')::timestamptz;end if;
 end if;
 total_minutes:=greatest(0,ceil(extract(epoch from coalesce(planned_finale,at_time,from_time)-from_time)/60.0)::integer);
 checklist:=jsonb_build_array(
  jsonb_build_object('code','position','label',case when live then 'Bevestigde positie en actuele tijd' else 'Bevestigde startafspraak' end,'status',case when valid_start and (context->>'sourceNodeId') is not null then 'pass' else 'blocked' end,
    'detail',case when live then 'Rekenen vanaf de actuele serverklok. Historie en de huidige bestemming blijven behouden.' else 'Voorbereiding vanaf het bevestigde of gepubliceerde startmoment.' end),
  jsonb_build_object('code','capacity','label','Fysieke ontvangstcapaciteit','status',case when jsonb_array_length(blockers)=0 then 'pass' else 'blocked' end,'detail','Nieuwe verwachte bezoeken gebruiken dezelfde huiscapaciteit en tijdvakcontrole als de feitelijke toewijzing.'),
  jsonb_build_object('code','finale','label','Finale-afspraak','status',case when target is not null and jsonb_array_length(blockers)=0 then 'pass' else 'blocked' end,
    'detail',case when (context->>'finaleReserved')::boolean then 'De route behoudt de gepubliceerde reservering en revisie.' else 'De verwachte finale wordt bij geldige publicatie daadwerkelijk gereserveerd.' end));
 if context->>'ordinaryVisitLimit' is not null then checklist:=checklist||jsonb_build_array(jsonb_build_object('code','visit-limit','label','Bewust gekozen bezoekgrens','status','info','detail',format('Maximaal %s gewone poorten. Niet ieder geschikt huis hoeft in deze route te worden opgenomen.',context->>'ordinaryVisitLimit')));end if;
 return jsonb_build_object('groupId',_group_id,'revision',coalesce(_revision,app_private.start_ops_route_revision(preview_event_id)),'generatedAt',clock_timestamp(),
  'mode',context->'mode','calculatedFromAt',from_time,'remainingMinutes',total_minutes,'start',origin,'publishedStart',context->'start',
  'stops',stops,'history',context->'history','currentStopId',current_stop->'id','terminal',context->'terminal',
  'totalMeters',meters,'totalMinutes',total_minutes,'eligiblePortalCount',available,'warnings',warnings,'blockers',blockers,'feasible',jsonb_array_length(blockers)=0,
  'checklist',checklist,'provisional',false,'hasConfirmedStart',valid_start,'expectedFinaleArrivalAt',target,
  'finaleReservationId',context->'finaleReservationId','publicationId',context->'publicationId','safeWaitingInstruction',context->'safeWaitingInstruction',
  'excludedCandidates',coalesce((select jsonb_agg(jsonb_build_object('code',row->'code','name',row->'name','reasons',row->'reasons') order by row->>'code') from jsonb_array_elements(coalesce(candidates,'[]')) row where not (row->>'eligible')::boolean),'[]'));
end;
$function$;
revoke all on function app_private.compute_evening_route_preview(uuid,integer) from public,anon,authenticated;

create or replace function app_private.start_ops_route_preview(_group_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $function$
 select app_private.compute_evening_route_preview(_group_id,null)
$function$;
revoke all on function app_private.start_ops_route_preview(uuid) from public,anon,authenticated;

-- A lost response can be retried with the same actual actor, version and choice.
-- The persistent finale preference also applies to later worker decisions.
create or replace function api.admin_redirect_group(_run_id uuid,_target text,_preferred_portal_id uuid,_expected_run_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor uuid:=auth.uid(); r app_private.group_runs; g app_private.walking_groups; s app_private.run_stops;
 context jsonb; option_data jsonb; result jsonb; finale jsonb; fingerprint text; receipt app_private.command_receipts; remaining integer;
begin
 if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform app_private.lock_evening_event((select wg.event_id from app_private.group_runs gr join app_private.walking_groups wg on wg.id=gr.group_id where gr.id=_run_id));
 select * into r from app_private.group_runs where id=_run_id for update;
 select * into g from app_private.walking_groups where id=r.group_id;
 if g.id is null or not (app_private.has_capability(g.event_id,'live_support',actor) or app_private.has_capability(g.event_id,'groups_manage',actor)) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001';end if;
 if _target is null or _target not in ('ordinary','finale') or (_target='ordinary' and _preferred_portal_id is null) or (_target='finale' and _preferred_portal_id is not null) then
  raise exception 'INVALID_REDIRECT_TARGET' using errcode='22023';end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode='22023';end if;
 fingerprint:=encode(extensions.digest(convert_to(jsonb_build_array(g.event_id,_run_id,_expected_run_version,_target,_preferred_portal_id,trim(_reason))::text,'UTF8'),'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='admin.redirectGroup' and idempotency_key='v1:'||fingerprint;
 if receipt.id is not null then return receipt.safe_result;end if;
 if r.version<>_expected_run_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
 if g.route_mode<>'dynamic' or r.status<>'live' then raise exception 'RUN_NOT_DISPATCHABLE' using errcode='23514';end if;
 context:=app_private.evening_route_context(g.id);
 if context->>'runId' is distinct from r.id::text then raise exception 'RUN_NOT_CURRENT' using errcode='40001';end if;
 if _target='finale' then
  finale:=app_private.run_finale_details(r.id,clock_timestamp());
  if not coalesce((finale->>'eligible')::boolean,false) then raise exception '%',finale->>'code' using errcode='23514';end if;
 end if;
 if r.current_stop_id is not null then
  select * into s from app_private.run_stops where id=r.current_stop_id for update;
  if s.stop_kind='finale' then raise exception 'FINAL_DESTINATION_ALREADY_PUBLISHED' using errcode='23514';end if;
  if exists(select 1 from app_private.scan_evidence where run_stop_id=s.id) then raise exception 'VISIT_IN_PROGRESS' using errcode='23514';end if;
 end if;
 if _target='ordinary' then
  remaining:=case when context->>'ordinaryVisitLimit' is null then null else greatest(0,(context->>'ordinaryVisitLimit')::integer-(context->>'completedOrdinaryVisits')::integer) end;
  option_data:=app_private.evening_route_candidates(context,(context->>'sourceNodeId')::uuid,clock_timestamp(),
   array(select v::uuid from jsonb_array_elements_text(context->'seenPortalIds') v),remaining,_preferred_portal_id)->0;
  if not coalesce((option_data->>'eligible')::boolean,false) then raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514',detail=(option_data->'reasons')::text;end if;
 end if;
 update app_private.group_runs set finale_only=(_target='finale'),version=version+1 where id=r.id and finale_only is distinct from (_target='finale');
 if s.id is not null then
  update app_private.run_stops set state='completed',outcome='system_skipped',completed_at=clock_timestamp(),completion_actor=actor,completion_reason=trim(_reason),version=version+1 where id=s.id;
  update app_private.stop_participant_statuses set status='skipped',required_for_completion=false,exclusion_reason='Bestemming door organisatie gewijzigd',reason='Bestemming door organisatie gewijzigd',changed_by=actor,decided_at=clock_timestamp(),version=version+1 where run_stop_id=s.id and status='pending';
  update app_private.portal_reservations set status='cancelled',cancelled_reason='Bestemming door organisatie gewijzigd',version=version+1 where id=s.reservation_id and status in ('held','active');
  insert into app_private.journey_events(run_id,stop_id,event_type,actor_id,safe_metadata)
   values(r.id,s.id,'stop.admin_redirected',actor,jsonb_build_object('target',_target,'reason',trim(_reason)));
  update app_private.group_runs set current_stop_id=null,version=version+1 where id=r.id;
 end if;
 result:=app_private.dispatch_next_stop(r.id,clock_timestamp(),_target='finale',_preferred_portal_id);
 if _target='ordinary' and not exists(select 1 from app_private.group_runs gr join app_private.run_stops rs on rs.id=gr.current_stop_id where gr.id=r.id and rs.portal_id=_preferred_portal_id and rs.state='active') then
  raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514';end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(g.event_id,actor,'group.destination_redirected','group_run',r.id,jsonb_build_object('target',_target,'preferredPortalId',_preferred_portal_id,'reason',trim(_reason)));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(actor,'admin.redirectGroup','v1:'||fingerprint,fingerprint,result,now()+interval '2 days');
 return result;
end;
$function$;

CREATE OR REPLACE FUNCTION app_private.assess_ordinary_portal(_event_id uuid, _group_id uuid, _portal_id uuid, _arrival_at timestamp with time zone, _children integer, _decision_at timestamp with time zone DEFAULT statement_timestamp(), _visit_end timestamp with time zone DEFAULT NULL::timestamp with time zone, _occupied_until timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; cfg app_private.event_route_settings; w app_private.portal_windows;
  codes jsonb:='[]'; reasons jsonb:='[]'; visit_end timestamptz; occupied_until timestamptz;
  peak_groups integer:=0; peak_children integer:=0; total_children integer:=0;
  visit_seconds integer; buffer_seconds integer;
begin
  select * into p from app_private.portals where id=_portal_id and event_id=_event_id;
  select * into cfg from app_private.event_route_settings where event_id=_event_id;
  if p.id is null then return jsonb_build_object('eligible',false,'blockingCodes',jsonb_build_array('PORTAL_NOT_ROUTE_READY'),'reasons',jsonb_build_array('Deze poort hoort niet bij dit evenement.')); end if;
  if _children is null or _children<=0 then codes:=codes||'"EMPTY_GROUP"'::jsonb; reasons:=reasons||'"Er zijn geen aanwezige kinderen om toe te wijzen."'::jsonb; end if;
  if p.approval_status<>'approved' or p.lifecycle_status<>'active' then
    codes:=codes||'"PORTAL_NOT_APPROVED"'::jsonb; reasons:=reasons||'"Deze poort is niet goedgekeurd en actief."'::jsonb; end if;
  if p.operation_status not in ('open','scheduled') then
    codes:=codes||'"PORTAL_NOT_OPEN"'::jsonb; reasons:=reasons||jsonb_build_array(case when p.operation_status='paused' then 'Deze poort heeft pauze.' else 'Deze poort ontvangt geen nieuwe groepen.' end); end if;
  if not exists(select 1 from app_private.portal_private_locations l where l.portal_id=p.id and l.verified_at is not null)
    or not app_private.portal_has_verified_walking_connection(p.id) then
    codes:=codes||'"PORTAL_NOT_VERIFIED"'::jsonb; reasons:=reasons||'"Locatie en veilige wandelverbinding zijn nog niet bevestigd."'::jsonb; end if;
  select pw.* into w from app_private.portal_windows pw where pw.portal_id=p.id and _arrival_at>=pw.opens_at and _arrival_at<pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,pw.visit_minutes*60)))<=pw.closes_at
    and coalesce(_visit_end,_arrival_at+make_interval(mins=>pw.visit_minutes))>=_arrival_at+make_interval(mins=>pw.visit_minutes)
    order by pw.opens_at,pw.id limit 1;
  if w.id is null then
    if _arrival_at is null then
      codes:=codes||'"ARRIVAL_TIME_REQUIRED"'::jsonb; reasons:=reasons||'"De verwachte aankomst is nog niet bekend."'::jsonb;
    else
      codes:=codes||'"PORTAL_WINDOW_CONFLICT"'::jsonb; reasons:=reasons||'"De verwachte aankomst en het bezoek passen niet binnen de openingstijd."'::jsonb;
    end if;
  else
    visit_end:=coalesce(_visit_end,_arrival_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,w.visit_minutes*60)));
    occupied_until:=greatest(visit_end,coalesce(_occupied_until,visit_end+make_interval(secs=>greatest(cfg.route_buffer_seconds,w.buffer_minutes*60))));
    visit_seconds:=extract(epoch from visit_end-_arrival_at)::integer;
    buffer_seconds:=extract(epoch from occupied_until-visit_end)::integer;
    if _children>w.max_children_per_visit then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb;
      reasons:=reasons||jsonb_build_array(format('%s kinderen; deze poort kan maximaal %s kinderen ontvangen.',_children,w.max_children_per_visit)); end if;
    with bookings as materialized (
      select * from app_private.ordinary_portal_bookings(_event_id,p.id,_decision_at)
      where not historical and group_id<>_group_id and starts_at<occupied_until and ends_at>_arrival_at
    ), ticks as (select _arrival_at at_time union select starts_at from bookings where starts_at>_arrival_at and starts_at<occupied_until),
    per_group as (select t.at_time,b.group_id,max(b.children) children from ticks t join bookings b on b.starts_at<=t.at_time and b.ends_at>t.at_time group by t.at_time,b.group_id),
    totals as (select at_time,count(*)::integer groups,coalesce(sum(children),0)::integer children from per_group group by at_time)
    select coalesce(max(groups),0)+1,coalesce(max(children),0)+_children into peak_groups,peak_children from totals;
    if peak_groups>w.max_concurrent_groups then
      codes:=codes||'"PORTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('Dit tijdvak heeft ruimte voor %s gelijktijdige groepen; het is al bezet.',w.max_concurrent_groups)); end if;
    if peak_children>w.max_children_per_visit and not (_children>w.max_children_per_visit) then
      codes:=codes||'"PORTAL_CHILD_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('In dit tijdvak zouden %s kinderen tegelijk aankomen; er is ruimte voor %s.',peak_children,w.max_children_per_visit)); end if;
    with bookings as materialized (select * from app_private.ordinary_portal_bookings(_event_id,p.id,_decision_at)),
    history as (select group_id,sum(children)::integer children from bookings where historical group by group_id),
    future as (select b.group_id,max(b.children)::integer children from bookings b where not b.historical and b.ends_at>_decision_at
      and b.group_id<>_group_id and not exists(select 1 from history h where h.group_id=b.group_id) group by b.group_id)
    select coalesce((select sum(children) from history where group_id<>_group_id),0)
      +coalesce((select sum(children) from future),0)
      +greatest(_children,coalesce((select children from history where group_id=_group_id),0)) into total_children;
    if w.max_children_total is not null and total_children>w.max_children_total then
      codes:=codes||'"PORTAL_TOTAL_CAPACITY_EXCEEDED"'::jsonb; reasons:=reasons||jsonb_build_array(format('De totale ontvangstcapaciteit van %s kinderen bij deze poort is bereikt.',w.max_children_total)); end if;
  end if;
  return jsonb_build_object('eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
    'windowId',w.id,'plannedArrivalAt',_arrival_at,'plannedDepartureAt',visit_end,'occupiedUntil',occupied_until,
    'visitSeconds',visit_seconds,'bufferSeconds',buffer_seconds,'capacity',jsonb_build_object('groupChildren',_children,
      'maxChildren',w.max_children_per_visit,'maxGroups',w.max_concurrent_groups,'peakGroups',peak_groups,
      'peakChildren',peak_children,'totalChildren',total_children,'maxChildrenTotal',w.max_children_total));
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.evening_route_context(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; r app_private.group_runs; s app_private.group_schedule_revisions;
 p app_private.group_start_publications; point app_private.start_points; slot app_private.start_slots; cfg app_private.event_route_settings;
 c app_private.finale_publication_commitments; released app_private.run_stop_location_snapshots;
 decision_at timestamptz:=clock_timestamp(); from_at timestamptz; after_current_at timestamptz;
 is_live boolean; confirmed boolean:=false; step_free boolean; children integer; visited integer:=0; remaining integer;
 point_data jsonb; node_data jsonb; source_node uuid; remaining_node uuid; current_stop jsonb; history jsonb;
 seen uuid[]:='{}'; last_stop uuid; last_portal uuid; current_node uuid; current_portal uuid;
 scan_at timestamptz; arrival_at timestamptz; walk record; service_seconds integer; buffer_seconds integer;
begin
 select * into g from app_private.walking_groups where id=_group_id;
 if g.id is null then return null;end if;
 select * into cfg from app_private.event_route_settings where event_id=g.event_id;
 select * into r from app_private.group_runs where group_id=g.id
  order by (status in ('live','paused','ready')) desc,created_at desc,id desc limit 1;
 is_live:=coalesce(r.status in ('live','paused'),false);
 if is_live then
  select * into p from app_private.group_start_publications where id=app_private.run_start_publication(r.id);
  select * into s from app_private.group_schedule_revisions where id=coalesce(r.schedule_revision_id,p.schedule_id);
  point_data:=p.point_snapshot;from_at:=decision_at;confirmed:=p.id is not null;
  select count(*) into children from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null;
  select exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   join app_private.children ch on ch.id=rc.child_id where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null and nullif(trim(ch.accessibility_note),'') is not null) into step_free;
 else
  select * into s from app_private.group_schedule_revisions where id=g.current_schedule_revision_id;
  if s.state='draft' and app_private.is_start_confirmation_current(s.id) then
   select * into slot from app_private.start_slots where id=s.start_slot_id;
   select * into point from app_private.start_points where id=slot.start_point_id;
   select jsonb_build_object('id',n.id,'coordinate',jsonb_build_array(n.coordinate[0],n.coordinate[1])) into node_data from app_private.walking_nodes n where n.id=point.walking_node_id and n.event_id=g.event_id;
   point_data:=to_jsonb(point)||jsonb_build_object('walking_node_snapshot',node_data);from_at:=slot.starts_at;
   confirmed:=app_private.start_point_safe_connection(point.id);
  else
   select * into p from app_private.group_start_publications where group_id=g.id order by publication_order desc limit 1;
   if p.id is not null then
    select * into s from app_private.group_schedule_revisions where id=p.schedule_id;
    point_data:=p.point_snapshot;from_at:=p.starts_at;confirmed:=true;
   end if;
  end if;
  select count(*) into children from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
  select exists(select 1 from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id and rc.participation_status='active'
   join app_private.children ch on ch.id=rc.child_id where a.group_id=g.id and a.superseded_at is null and nullif(trim(ch.accessibility_note),'') is not null) into step_free;
 end if;
 source_node:=app_private.frozen_walking_source(g.event_id,(point_data->>'walking_node_id')::uuid,
  (point_data#>>'{walking_node_snapshot,coordinate,0}')::numeric,(point_data#>>'{walking_node_snapshot,coordinate,1}')::numeric);
 select * into c from app_private.finale_publication_commitments where publication_id=p.id;
 if is_live then
  select stop.id,coalesce(stop.portal_id,old_stop.portal_id) into last_stop,last_portal from app_private.run_stops stop
   left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   where stop.run_id=r.id and stop.state='completed' and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id)
   order by stop.sequence desc limit 1;
  if last_stop is not null then
   select * into released from app_private.run_stop_location_snapshots where run_stop_id=last_stop;
   if released.run_stop_id is not null then
    source_node:=app_private.frozen_walking_source(g.event_id,released.walking_node_id,released.node_longitude,released.node_latitude);
   else
    -- Controlled legacy identity fallback; no historical IDs are rewritten.
    select node.id into source_node from app_private.walking_nodes node join app_private.portal_private_locations l on l.portal_id=node.portal_id
     where node.event_id=g.event_id and node.portal_id=last_portal and node.verified_at is not null and l.verified_at is not null
      and abs(node.coordinate[0]-coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude)::double precision)<.000001
      and abs(node.coordinate[1]-coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)::double precision)<.000001 order by node.id limit 1;
   end if;
  end if;
  select coalesce(array_agg(distinct coalesce(stop.portal_id,old_stop.portal_id) order by coalesce(stop.portal_id,old_stop.portal_id)),'{}'),
    count(distinct coalesce(stop.portal_id,old_stop.portal_id)) filter(where stop.state='completed' and coalesce(stop.stop_kind::text,'ordinary')='ordinary'
     and coalesce(stop.portal_id,old_stop.portal_id) is distinct from coalesce(c.portal_id,cfg.final_portal_id)
     and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id))
   into seen,visited from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   where stop.run_id=r.id and stop.state in ('active','completed');
  select jsonb_build_object('id',stop.id,'planStopId',stop.plan_stop_id,'portalId',portal.id,'code',portal.system_code,'name',portal.name,'world',world.name,
    'sequence',stop.sequence,'kind',coalesce(stop.stop_kind::text,'ordinary'),'status','current',
    'address',case when snap.run_stop_id is not null then concat_ws(' ',snap.address->>'street',snap.address->>'houseNumber',snap.address->>'addition') else concat_ws(' ',l.street,l.house_number,l.addition) end,
    'coordinate',jsonb_build_array(coalesce(snap.longitude,l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(snap.latitude,l.marker_latitude,l.geocoded_latitude,l.latitude)),
    'reservedArrivalAt',b.reserved_from,'scanAccepted',exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id))
   into current_stop from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   join app_private.portals portal on portal.id=coalesce(stop.portal_id,old_stop.portal_id)
   join app_private.worlds world on world.id=portal.world_id join app_private.portal_private_locations l on l.portal_id=portal.id
   left join app_private.run_stop_location_snapshots snap on snap.run_stop_id=stop.id
   left join app_private.portal_reservations b on b.id=stop.reservation_id or b.bound_stop_id=stop.id
   where stop.id=r.current_stop_id and stop.state='active';
 end if;
 if r.id is not null then
  select coalesce(jsonb_agg(jsonb_build_object('id',stop.id,'planStopId',stop.plan_stop_id,'portalId',coalesce(stop.portal_id,old_stop.portal_id),
    'code',portal.system_code,'name',portal.name,'sequence',stop.sequence,'outcome',stop.outcome,'completedAt',stop.completed_at,
    'arrivalConfirmed',exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id)) order by stop.sequence),'[]')
   into history from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   join app_private.portals portal on portal.id=coalesce(stop.portal_id,old_stop.portal_id) where stop.run_id=r.id and stop.state='completed';
 end if;
 remaining:=case when g.desired_ordinary_visits is null then null else greatest(0,g.desired_ordinary_visits-visited) end;
 after_current_at:=from_at;remaining_node:=source_node;
 if current_stop is not null then
  current_portal:=(current_stop->>'portalId')::uuid;
  select * into released from app_private.run_stop_location_snapshots where run_stop_id=r.current_stop_id;
  if released.run_stop_id is not null then current_node:=app_private.frozen_walking_source(g.event_id,released.walking_node_id,released.node_longitude,released.node_latitude);
  else select id into current_node from app_private.walking_nodes where portal_id=current_portal and event_id=g.event_id and verified_at is not null order by id limit 1;end if;
  select min(scanned_at) into scan_at from app_private.scan_evidence where run_stop_id=r.current_stop_id;
  select * into walk from app_private.walking_path_metrics(g.event_id,source_node,current_node,step_free);
  select greatest(1,coalesce(extract(epoch from b.service_until-b.reserved_from)::integer,extract(epoch from ps.planned_departure_at-ps.planned_arrival_at)::integer,cfg.ordinary_visit_seconds,300)),
    greatest(0,extract(epoch from b.reserved_until-b.service_until)::integer) into service_seconds,buffer_seconds
   from app_private.run_stops stop left join app_private.route_plan_stops ps on ps.id=stop.plan_stop_id
   left join app_private.portal_reservations b on b.id=stop.reservation_id or b.bound_stop_id=stop.id where stop.id=r.current_stop_id;
  service_seconds:=coalesce(service_seconds,cfg.ordinary_visit_seconds,300);buffer_seconds:=coalesce(buffer_seconds,cfg.route_buffer_seconds,0);
  arrival_at:=coalesce(scan_at,from_at+make_interval(secs=>walk.duration_seconds::integer));
  after_current_at:=greatest(from_at,arrival_at+make_interval(secs=>service_seconds))+make_interval(secs=>buffer_seconds);
  remaining_node:=current_node;
  current_stop:=current_stop||jsonb_build_object('plannedArrivalAt',arrival_at,'walkMeters',case when scan_at is null then walk.distance_m else 0 end,'walkMinutes',case when scan_at is null then ceil(walk.duration_seconds/60.0) else 0 end);
  if current_stop->>'kind'='ordinary' and remaining is not null then remaining:=greatest(0,remaining-1);end if;
 end if;
 if is_live and coalesce((current_stop->>'scanAccepted')::boolean,false) then last_stop:=r.current_stop_id;last_portal:=current_portal;source_node:=current_node;end if;
 return jsonb_build_object('groupId',g.id,'eventId',g.event_id,'groupCode',g.system_code,'runId',case when is_live then r.id else null end,
  'groupStatus',g.status,'terminal',not is_live and r.status in ('completed','stopped') and p.id is not distinct from app_private.run_start_publication(r.id),
  'runVersion',case when is_live then r.version else null end,'runStatus',case when is_live then r.status else null end,'mode',case when is_live then 'live' else 'preview' end,
  'serverNowAt',decision_at,'calculatedFromAt',from_at,'remainingFromAt',after_current_at,'sourceNodeId',source_node,'remainingSourceNodeId',remaining_node,
  'lastConfirmedStopId',last_stop,'lastConfirmedPortalId',last_portal,'gatheringPortalId',point_data->>'linked_portal_id','startCountsAsVisit',coalesce((point_data->>'counts_as_first_portal_visit')::boolean,false),'childCount',children,'requiresStepFree',step_free,'hasConfirmedStart',confirmed,'publicationId',p.id,'scheduleId',s.id,
  'start',jsonb_build_object('pointId',point_data->>'id','name',point_data->>'name','address',point_data->>'private_address','startsAt',coalesce(p.starts_at,slot.starts_at),
    'coordinate',case when coalesce(point_data->>'marker_longitude',point_data->>'geocoded_longitude',point_data->>'longitude') is not null and coalesce(point_data->>'marker_latitude',point_data->>'geocoded_latitude',point_data->>'latitude') is not null then jsonb_build_array(coalesce(point_data->>'marker_longitude',point_data->>'geocoded_longitude',point_data->>'longitude')::numeric,coalesce(point_data->>'marker_latitude',point_data->>'geocoded_latitude',point_data->>'latitude')::numeric) else null end),
  'ordinaryStopAt',least(s.effective_ordinary_stop_at,cfg.global_ordinary_stop_at),'ordinaryVisitLimit',g.desired_ordinary_visits,'completedOrdinaryVisits',visited,'remainingOrdinaryVisits',remaining,
  'seenPortalIds',to_jsonb(seen),'historyRunId',r.id,'historyIsPreviousRun',not is_live,'history',coalesce(history,'[]'),'currentStop',current_stop,
  'finalePortalId',coalesce(c.portal_id,cfg.final_portal_id),'finaleArrivalAt',coalesce(c.reserved_arrival_at,s.expected_finale_arrival_at),
  'finaleOnly',coalesce(r.finale_only,false),'finaleOccupiedUntil',c.occupied_until,'finaleServiceUntil',c.service_until,'finaleGraceSeconds',coalesce(c.grace_seconds,cfg.finale_turnover_seconds,120),'finaleReserved',c.publication_id is not null,
  'finaleReservationId',(select b.id from app_private.portal_reservations b where b.start_publication_id=c.publication_id),
  'safeWaitingInstruction',c.safe_waiting_instruction);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb; cached_route_revision integer;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  cached_route_revision:=app_private.start_ops_route_revision(e.id);
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item),'[]'::jsonb),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',cached_route_revision) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.group_start_publications p1 where p1.group_id=g.id order by p1.publication_order desc limit 1) pub on true
    where g.event_id=e.id;
  select coalesce(jsonb_object_agg(g.id,app_private.compute_evening_route_preview(g.id,cached_route_revision)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',cached_route_revision,'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;

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
  preview_group record; preview_data jsonb; cached_route_revision integer;
begin
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
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
  if exists (
    select 1 from app_private.group_schedule_revisions candidate
    join app_private.group_registrations assignment on assignment.group_id = candidate.group_id and assignment.superseded_at is null
    join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
    left join app_private.payment_requests payment on payment.registration_id = registration.id
    where candidate.id = any(_schedule_ids) and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
  ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;

  -- The confirmation must still describe the current event and checked point.
  if exists(select 1 from app_private.group_schedule_revisions s
    join app_private.start_slots slot on slot.id=s.start_slot_id
    join app_private.start_points p on p.id=slot.start_point_id
    join app_private.walking_groups g on g.id=s.group_id
    join app_private.events e on e.id=g.event_id
    where s.id=any(_schedule_ids) and (s.confirmed_at is null
      or s.confirmed_settings_version is distinct from e.settings_version
      or s.confirmed_composition_hash is distinct from app_private.start_group_composition_hash(g.id)
      or s.confirmed_point_version is distinct from p.version
      or s.confirmed_route_settings_version is distinct from settings.version
      or s.confirmed_starts_at is distinct from slot.starts_at or s.confirmed_start_point_id is distinct from p.id
      or not slot.active
      or not app_private.start_point_ready_at(p.id,slot.starts_at))) then
    raise exception 'START_NOT_CONFIRMED' using errcode='23514'; end if;
  if exists(select 1 from app_private.group_runs r join app_private.group_schedule_revisions s on s.group_id=r.group_id
    where s.id=any(_schedule_ids)) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514'; end if;
  perform app_private.validate_start_schedule_capacity(v_event_id,_schedule_ids);
  cached_route_revision:=app_private.start_ops_route_revision(v_event_id);
  for preview_group in select candidate.group_id from app_private.group_schedule_revisions candidate where candidate.id=any(_schedule_ids) loop
    preview_data:=app_private.compute_evening_route_preview(preview_group.group_id,cached_route_revision);
    if not coalesce((preview_data->>'feasible')::boolean,false) then raise exception 'ROUTE_NOT_FEASIBLE' using errcode='23514',detail=(preview_data->'blockers')::text;end if;
  end loop;

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
    for recipient in
      select distinct users.id as user_id, lower(users.email) as email
      from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id
      join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
      join auth.users users on users.id = member.user_id and users.email_confirmed_at is not null
      where assignment.group_id = schedule.group_id and assignment.superseded_at is null
    loop
      insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
      select
        'group-schedule:' || schedule.group_id::text || ':' || schedule.revision::text || ':' || recipient.user_id::text,
        case when schedule.revision = 1 then 'group_schedule_published' else 'group_schedule_corrected' end,
        recipient.user_id::text,
        recipient.email,
        jsonb_build_object(
          'groupId', schedule.group_id, 'revision', schedule.revision, 'childCount', child_count,
          'startsAt', slot.starts_at, 'addressReleaseAt', slot.starts_at-interval '1 hour',
          'ordinaryStopAt', schedule.effective_ordinary_stop_at,
          'actionPath', '/omgeving/meeloper/groep'
        )
      from app_private.start_slots slot join app_private.start_points point on point.id = slot.start_point_id
      where slot.id = schedule.start_slot_id
      on conflict (dedupe_key) do nothing;
    end loop;
    published_count := published_count + 1;
  end loop;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'group_schedule.published', 'group_schedule_batch',
    jsonb_build_object('count', published_count, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', published_count);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop_before_visit_preference(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  settings app_private.event_route_settings;
  source_node_id uuid;
  final_node_id uuid;
  needs_step_free boolean;
  v_child_count integer;
  candidate record;
  finale_reservation_id uuid;
  ordinary_reservation_id uuid;
  next_stop_id uuid;
  next_sequence integer;
  potential_count integer := 0;
  finale_path record;
  earliest_finale timestamptz;
  decision_number integer;
  route_context jsonb;
  candidate_summary jsonb := '[]'::jsonb;
  frozen_publication_id uuid; commitment app_private.finale_publication_commitments; finale_details jsonb; waiting_until timestamptz;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.status <> 'live' or run_record.current_stop_id is not null then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = run_record.schedule_revision_id and state = 'published';
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  route_context:=app_private.evening_route_context(group_record.id)||jsonb_build_object('serverNowAt',_decision_at,'calculatedFromAt',_decision_at);
  frozen_publication_id:=app_private.run_start_publication(run_record.id);
  perform app_private.ensure_finale_commitment(frozen_publication_id);
  select * into commitment from app_private.finale_publication_commitments where finale_publication_commitments.publication_id=frozen_publication_id;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
  if commitment.publication_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_REQUIRED',_decision_at);end if;
  finale_details:=app_private.run_finale_details(_run_id,_decision_at);
  if not (finale_details->>'eligible')::boolean then return app_private.pause_for_finale_conflict(_run_id,finale_details->>'code',_decision_at);end if;
  finale_reservation_id:=app_private.try_reserve_finale(_run_id,(finale_details->>'earliestArrivalAt')::timestamptz,_decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  if _decision_at>=(finale_details->>'waitingUntil')::timestamptz then
    if _preferred_portal_id is not null then raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514';end if;
    _force_finale:=true;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(group_record.event_id::text || ':route-dispatch', 0));

  update app_private.portal_reservations set status = 'expired', version = version + 1
  where event_id = group_record.event_id and status = 'held' and expires_at <= _decision_at;
  select count(*) into v_child_count from app_private.run_participants where run_id = _run_id and attendance = 'present';
  select exists (
    select 1 from app_private.run_participants participant
    join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
    join app_private.children child on child.id = registration_child.child_id
    where participant.run_id = _run_id and participant.attendance = 'present'
      and nullif(trim(child.accessibility_note), '') is not null
  ) into needs_step_free;
  select coalesce(max(sequence), 0) + 1 into next_sequence from app_private.run_stops where run_id = _run_id;
  select coalesce(max(sequence), 0) + 1 into decision_number from app_private.dispatch_decisions where run_id = _run_id;

  source_node_id:=(app_private.evening_route_context(group_record.id)->>'sourceNodeId')::uuid;
  select node.id into final_node_id from app_private.walking_nodes node
  where node.event_id = group_record.event_id and node.kind = 'portal'
    and node.portal_id = commitment.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if source_node_id is null or final_node_id is null then raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514'; end if;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.operation_status in ('open', 'scheduled')
  ) then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_UNAVAILABLE',
      'De eindpoort is niet veilig beschikbaar. Activeer de voorbereide noodafsluiting.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
    values (group_record.event_id, _run_id, decision_number, 'emergency', jsonb_build_object('decidedAt', _decision_at), candidate_summary,
      'Eindpoort niet beschikbaar; geen adres automatisch gepubliceerd');
    return jsonb_build_object('decision', 'emergency', 'paused', true);
  end if;

  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      with chosen as materialized (select app_private.pick_evening_route_candidate(route_context,source_node_id,_decision_at,
        array(select v::uuid from jsonb_array_elements_text(route_context->'seenPortalIds') v),
        case when route_context->>'ordinaryVisitLimit' is null then null else greatest(0,(route_context->>'ordinaryVisitLimit')::integer-(route_context->>'completedOrdinaryVisits')::integer) end,
        _preferred_portal_id) data)
      select (data->>'id')::uuid portal_id,(data->>'worldId')::uuid world_id,data->>'name' name,
        (data->>'walkMeters')::bigint incoming_distance_m,(data->>'walkSeconds')::bigint incoming_seconds,
        array(select v::uuid from jsonb_array_elements_text(data->'incomingEdgeIds') v) incoming_edge_ids,
        (data->>'finaleWalkSeconds')::bigint finale_seconds,(data->>'expectedAt')::timestamptz arrival_at,
        (data->>'occupiedUntil')::timestamptz departure_at,(data->>'plannedDepartureAt')::timestamptz service_until,
        (data->>'finaleEarliestAt')::timestamptz earliest_finale_at,(data->>'score')::bigint score
      from chosen where data is not null
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at, service_until
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds), candidate.service_until
      ) returning id into ordinary_reservation_id;
      insert into app_private.run_stops(
        run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at
      ) values (
        _run_id, candidate.portal_id, ordinary_reservation_id, 'ordinary', next_sequence, 'active', _decision_at
      ) returning id into next_stop_id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop_id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
      insert into app_private.dispatch_decisions(
        event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
        input_snapshot, candidate_summary, reason
      ) values (
        group_record.event_id, _run_id, decision_number, candidate.portal_id, 'ordinary', 'ordinary',
        jsonb_build_object(
          'decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op veilige looptijd, beschikbaarheid en finalehaalbaarheid'
      );
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'ordinary', 'portalId', candidate.portal_id));
      return jsonb_build_object('decision', 'ordinary', 'stopId', next_stop_id, 'portalId', candidate.portal_id);
    end loop;

    if _preferred_portal_id is not null then
      raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;

    select count(*) into potential_count
    from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes portal_node on portal_node.portal_id = portal.id and portal_node.event_id = group_record.event_id and portal_node.verified_at is not null
    cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
    cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.id=frozen_publication_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= commitment.reserved_arrival_at+make_interval(secs=>commitment.grace_seconds);
    if potential_count > 0 then
      insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
      values (group_record.event_id, _run_id, decision_number, 'wait',
        jsonb_build_object('decidedAt', _decision_at, 'effectiveStopAt', schedule.effective_ordinary_stop_at),
        candidate_summary, 'Veilige kandidaten zijn tijdelijk bezet; opnieuw beoordelen');
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select group_record.event_id, group_record.id, _run_id, 'warning', 'NO_CURRENT_CAPACITY',
        'Geen gewone poort is nu reserveerbaar; automatische herbeoordeling is nodig.'
      where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'NO_CURRENT_CAPACITY');
      return jsonb_build_object('decision', 'wait', 'retryAfterSeconds', 120);
    end if;
  end if;

  select * into finale_path from app_private.walking_path_metrics(group_record.event_id, source_node_id, final_node_id, needs_step_free);
  if finale_path.duration_seconds is null then raise exception 'NO_SAFE_FINALE_PATH' using errcode = '23514'; end if;
  earliest_finale := _decision_at + make_interval(secs => finale_path.duration_seconds::integer);
  finale_reservation_id := app_private.try_reserve_finale(_run_id, earliest_finale, _decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  waiting_until:=commitment.reserved_arrival_at-make_interval(secs=>finale_path.duration_seconds::integer);
  if _decision_at<waiting_until then
    if not exists(select 1 from app_private.dispatch_decisions d where d.run_id=_run_id and d.decision='wait'
      and d.input_snapshot->>'waitingReason'='finale_window'
      and d.input_snapshot->>'reservationId'=finale_reservation_id::text
      and (d.input_snapshot->>'waitingUntil')::timestamptz=waiting_until) then
      insert into app_private.dispatch_decisions(event_id,run_id,sequence,decision,input_snapshot,candidate_summary,reason)
      values(group_record.event_id,_run_id,decision_number,'wait',jsonb_build_object('decidedAt',_decision_at,
        'waitingReason','finale_window','waitingUntil',waiting_until,'reservationId',finale_reservation_id,
        'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction),candidate_summary,'Wachten tot vertrek voor de vaste gepubliceerde finale-afspraak');
    end if;
    return jsonb_build_object('decision','wait','waitingReason','finale_window','waitingUntil',waiting_until,
      'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction,'reservationId',finale_reservation_id);
  end if;
  update app_private.portal_reservations set status = 'active', version = version + 1 where id = finale_reservation_id;
  insert into app_private.run_stops(run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at)
  values (_run_id, settings.final_portal_id, finale_reservation_id, 'finale', next_sequence, 'active', _decision_at)
  returning id into next_stop_id;
  insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
  select next_stop_id, participant.id from app_private.run_participants participant
  where participant.run_id = _run_id and participant.attendance = 'present';
  update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
  insert into app_private.dispatch_decisions(
    event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
    input_snapshot, candidate_summary, reason
  ) values (
    group_record.event_id, _run_id, decision_number, settings.final_portal_id, 'finale', 'finale',
    jsonb_build_object('decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; requested integer; visited integer; reached boolean := false; first_portal uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into r from app_private.group_runs where id = _run_id for update;
  select desired_ordinary_visits into requested from app_private.walking_groups where id = r.group_id;
  if requested is not null then
    visited:=(app_private.evening_route_context(r.group_id)->>'completedOrdinaryVisits')::integer;
    reached := visited >= requested;
  end if;
  if reached and _preferred_portal_id is not null then raise exception 'ORDINARY_VISIT_LIMIT_REACHED' using errcode='23514';end if;
  if not reached and not exists(select 1 from app_private.run_stops where run_id=_run_id and state in ('active','completed')) then
    select (p.point_snapshot->>'linked_portal_id')::uuid into first_portal
      from app_private.group_start_publications p where p.id=app_private.run_start_publication(r.id)
      and (p.point_snapshot->>'counts_as_first_portal_visit')::boolean=true
      and (p.point_snapshot->>'linked_portal_id')::uuid is distinct from (app_private.evening_route_context(r.group_id)->>'finalePortalId')::uuid
      order by p.publication_order desc limit 1;
  end if;
  return app_private.dispatch_next_stop_before_visit_preference(
    _run_id, _decision_at, _force_finale or reached or coalesce(r.finale_only,false), case when reached then null else coalesce(_preferred_portal_id,first_portal) end);
end;
$function$
;
