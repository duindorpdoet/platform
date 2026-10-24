-- Existing legacy plan references remain intact. A released legacy stop can
-- carry its actual execution kind while capacity is linked through bound_stop_id.
alter table app_private.run_stops drop constraint run_stops_source_check;
alter table app_private.run_stops add constraint run_stops_source_check check (
 (plan_stop_id is not null and portal_id is null and reservation_id is null)
 or (plan_stop_id is null and portal_id is not null and reservation_id is not null and stop_kind is not null)
);

-- The existing isolated rehearsal rolls its own invented event back. Only that
-- private, server-created scope retains its old deterministic demonstration.
-- Normal event settings or a client-supplied claim cannot create this marker.
create table app_private.evening_isolated_rehearsals(event_id uuid primary key references app_private.events(id) on delete cascade,actor_id uuid not null);
alter table app_private.evening_isolated_rehearsals enable row level security;
revoke all on app_private.evening_isolated_rehearsals from public,anon,authenticated;
create function app_private.is_evening_isolated_rehearsal(_event_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.evening_isolated_rehearsals proof join app_private.events e on e.id=proof.event_id
  where proof.event_id=_event_id and e.slug='rehearsal-'||replace(e.id::text,'-','') and e.settings->'rehearsal'='true'::jsonb)
$$;
revoke all on function app_private.is_evening_isolated_rehearsal(uuid) from public,anon,authenticated;

create function app_private.release_evening_destination(_run_id uuid,_portal_id uuid,_reservation_id uuid,_kind app_private.dynamic_stop_kind,_sequence integer)
returns uuid language plpgsql security definer set search_path='' as $function$
declare r app_private.group_runs; candidate app_private.run_stops; stopid uuid; shift integer;
begin
 perform app_private.lock_evening_event((select g.event_id from app_private.group_runs gr join app_private.walking_groups g on g.id=gr.group_id where gr.id=_run_id));
 select * into r from app_private.group_runs where id=_run_id for update;
 select s.* into candidate from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id
 where s.run_id=r.id and s.state='locked' and coalesce(s.portal_id,p.portal_id)=_portal_id
  and not exists(select 1 from app_private.run_stop_location_snapshots snap where snap.run_stop_id=s.id)
  and not exists(select 1 from app_private.scan_evidence scan where scan.run_stop_id=s.id)
 order by s.sequence,s.id limit 1 for update of s;
 if exists(select 1 from app_private.run_stops s where s.run_id=r.id and s.sequence=_sequence and s.id is distinct from candidate.id) then
  if exists(select 1 from app_private.run_stops s where s.run_id=r.id and s.sequence=_sequence and s.state<>'locked') then raise exception 'STOP_SEQUENCE_CONFLICT' using errcode='23514';end if;
  select coalesce(max(sequence),0)+1000 into shift from app_private.run_stops where run_id=r.id;
  update app_private.run_stops set sequence=sequence+shift,version=version+1 where run_id=r.id and state='locked' and id is distinct from candidate.id;
 end if;
 if candidate.id is not null then
  update app_private.run_stops set sequence=_sequence,stop_kind=_kind,state='active',opened_at=clock_timestamp(),version=version+1 where id=candidate.id returning id into stopid;
  update app_private.portal_reservations set bound_stop_id=stopid,version=version+1 where id=_reservation_id;
 else
  insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
   values(r.id,_portal_id,_reservation_id,_kind,_sequence,'active',clock_timestamp()) returning id into stopid;
 end if;
 return stopid;
end;
$function$;
revoke all on function app_private.release_evening_destination(uuid,uuid,uuid,app_private.dynamic_stop_kind,integer) from public,anon,authenticated;

-- An automatic refresh never replaces the current instruction or an unreceived
-- pending arrival. The actual leader/admin command remains authoritative.
create or replace function api.worker_dispatch_due_groups(_event_slug text,_batch_size integer default 50)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare eventid uuid; candidate record; dispatched integer:=0; alerted integer:=0; alert_code text; alert_message text; inserted_count integer;
begin
 eventid:=app_private.current_event_id(_event_slug);perform app_private.lock_evening_event(eventid);
 if eventid is null then raise exception 'EVENT_NOT_FOUND' using errcode='P0002';end if;
 for candidate in
  select r.id,r.group_id,r.current_stop_id,coalesce(s.stop_kind::text,'ordinary') stop_kind,coalesce(s.portal_id,ps.portal_id) portal_id,
   coalesce(schedule.effective_ordinary_stop_at,cfg.global_ordinary_stop_at) cutoff_at,b.expires_at,
   exists(select 1 from app_private.scan_evidence where run_stop_id=s.id) scan_accepted
  from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  left join app_private.event_route_settings cfg on cfg.event_id=g.event_id
  left join app_private.group_schedule_revisions schedule on schedule.id=coalesce(r.schedule_revision_id,(select pub.schedule_id from app_private.group_start_publications pub where pub.id=app_private.run_start_publication(r.id)))
  left join app_private.run_stops s on s.id=r.current_stop_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
  left join app_private.portal_reservations b on b.id=s.reservation_id or b.bound_stop_id=s.id
  where g.event_id=eventid and r.status='live' and not app_private.is_evening_isolated_rehearsal(eventid)
  order by r.updated_at,r.id for update of r skip locked limit least(greatest(_batch_size,1),200)
 loop
  if candidate.current_stop_id is null then
   perform app_private.dispatch_next_stop(candidate.id,clock_timestamp());dispatched:=dispatched+1;
  elsif candidate.stop_kind='ordinary' and (candidate.cutoff_at<=clock_timestamp() or candidate.expires_at<=clock_timestamp()) then
   alert_code:=case when candidate.scan_accepted then 'ACTIVE_VISIT_AFTER_STOP' else 'CURRENT_DESTINATION_REVIEW_REQUIRED' end;
   alert_message:=case when candidate.scan_accepted then 'Het lopende bezoek duurt langer dan gepland. Rond veilig af; de organisatie controleert de aansluiting op de finale.' else 'De geplande tijd is voorbij. De huidige aanwijzing en een bewaarde aankomst blijven behouden; neem contact op met de organisatie.' end;
   insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
    select eventid,candidate.group_id,candidate.id,candidate.portal_id,'warning',alert_code,alert_message
    where not exists(select 1 from app_private.route_alerts where run_id=candidate.id and portal_id=candidate.portal_id and code=alert_code and status='open');
   get diagnostics inserted_count=row_count;alerted:=alerted+inserted_count;
  end if;
 end loop;
 return jsonb_build_object('dispatched',dispatched,'alerted',alerted);
end;
$function$;

-- Admission proof is evaluated at the accepted scan instant. A later poster
-- rotation or closure does not invalidate the arrival already accepted here.
create function app_private.has_valid_arrival_proof(_stop_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
  join app_private.scan_evidence e on e.run_stop_id=s.id join app_private.portal_credentials c on c.id=e.credential_id
  where s.id=_stop_id and c.portal_id=coalesce(s.portal_id,ps.portal_id) and c.version=e.credential_version
   and c.valid_from<=e.scanned_at and (c.valid_until is null or c.valid_until>e.scanned_at)
   and (c.revoked_at is null or c.revoked_at>e.scanned_at))
$$;
revoke all on function app_private.has_valid_arrival_proof(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION api.redesign_rehearsal(_event_slug text, _scenario text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ownerid uuid:=auth.uid(); realevent uuid; eventid uuid:=gen_random_uuid(); homeid uuid:=gen_random_uuid(); registrationid uuid:=gen_random_uuid();
 groupid uuid:=gen_random_uuid(); planid uuid:=gen_random_uuid(); worldid uuid:=gen_random_uuid(); childids uuid[]:='{}'; rcids uuid[]:='{}'; portalids uuid[]:='{}'; tokens text[]:='{}';
 slotid uuid:=gen_random_uuid(); nodeid uuid; previousnode uuid:=gen_random_uuid(); runid uuid; activeid uuid; r app_private.group_runs; fixtureid uuid; portalid uuid; applicationid uuid; childid uuid; rcid uuid; participantid uuid;
 i integer; n integer; operation jsonb; scenarios jsonb:='{"start": [{"op": "empty", "title": "Start zonder aanwezigen weigeren", "history": 0, "sequence": 0, "status": "before", "seals": [0, 0, 0], "error": "EMPTY_GROUP"}, {"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Twee aanwezige kinderen bereiken de poort", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}, {"op": "snapshot", "title": "Afwezig kind krijgt geen zegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}], "arrival": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Precies de volgende bestemming staat klaar", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "inclusive": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Buiten blijven krijgt dezelfde aankomstzegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "wrong": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "wrong", "title": "Een verkeerde poortcode weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "WRONG_PORTAL"}], "duplicate": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Dezelfde opdracht blijft eenmalig", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "closed": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "close", "title": "Eigen oefenpoort sluiten", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij gesloten poort weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "PORTAL_UNAVAILABLE"}, {"op": "systemskip", "title": "Expliciete systeemoverslag zonder zegel", "history": 1, "sequence": 2, "status": "live", "seals": [0, 0, 0]}], "manual": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "skipall", "title": "Alle kinderen slaan de beleving over", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Zonder aankomst niet afronden", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "SCAN_REQUIRED"}, {"op": "scan", "title": "Alleen code bevestigen zonder definitieve zegels", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Met aankomst iedereen een zegel geven", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "offline": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "offline", "title": "Verbinding weg: geen serveropdracht ontvangen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Na herstel dezelfde aankomst bevestigen", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Herhaalde ontvangst maakt geen duplicaat", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "stale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "stale", "title": "Oude routeversie weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "STALE_VERSION"}], "early": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "departall", "title": "Eigen gezin sluit af zonder finale", "history": 2, "sequence": 0, "status": "stopped", "seals": [2, 2, 2]}], "part-departure": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "departone", "title": "Een kind vertrekt; de groep loopt door", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Vertrokken kind krijgt geen volgende zegel", "history": 2, "sequence": 3, "status": "live", "seals": [2, 1, 2]}], "finale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "arrive", "title": "Aankomst bij poort 3", "history": 3, "sequence": 4, "status": "live", "seals": [3, 3, 3]}, {"op": "arrive", "title": "Aankomst bij poort 4", "history": 4, "sequence": 5, "status": "live", "seals": [4, 4, 4]}, {"op": "arrive", "title": "Finaleaankomst telt ook bij buiten blijven", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "snapshot", "title": "Ieder aanwezig kind heeft precies een finalezegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "repeat", "title": "Geen dubbele finale of zesde zegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}]}'::jsonb; spec jsonb; report jsonb:='[]'; results jsonb; request jsonb; previous jsonb;
 problem text; currentportal uuid; token text; runversion integer; stopid uuid; leavingids uuid[]; choices jsonb; started timestamptz:=clock_timestamp(); tick timestamptz;
 actualhistory integer; actualseq integer; actualstatus text; sealcounts jsonb; view jsonb; ok boolean;
begin
 select id into realevent from app_private.events where slug=_event_slug;
 if ownerid is null or realevent is null or not (app_private.has_capability(realevent,'live_support',ownerid) or app_private.has_capability(realevent,'event_admin',ownerid)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 spec:=scenarios->_scenario;
 if spec is null then raise exception 'INVALID_SCENARIO'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ownerid::text||':redesign-rehearsal',0));
 begin
  insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings) values(eventid,'rehearsal-'||replace(eventid::text,'-',''),'Geïsoleerde generale',(now() at time zone 'Europe/Amsterdam')::date,'live',0,'{"rehearsal":true}');
  insert into app_private.evening_isolated_rehearsals(event_id,actor_id) values(eventid,ownerid);
  insert into app_private.households(id,label,primary_contact_user_id) values(homeid,'Oefengezin',ownerid);
  insert into app_private.household_members(household_id,user_id,relation_role) values(homeid,ownerid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(registrationid,eventid,homeid,'submitted','LAB-'||registrationid::text);
  for i in 1..3 loop
   insert into app_private.children(household_id,first_name,age_at_event) values(homeid,(array['Oefenkind A','Oefenkind B','Oefenkind C'])[i],8) returning id into childid;
   insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registrationid,childid,0) returning id into rcid;
   childids:=array_append(childids,childid);rcids:=array_append(rcids,rcid);
  end loop;
  insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,starts_at,max_groups,max_children) values(slotid,eventid,'lab-start','Oefenstart','Oefenlocatie','Geïsoleerd oefenadres',now()-interval '1 hour',1,20);
  insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at) values(previousnode,eventid,'lab-start','start',point(4.26,52.10),now());
  for i in 1..5 loop
   worldid:=gen_random_uuid();
   insert into app_private.worlds(id,event_id,slug,name,sort_order) values(worldid,eventid,'oefenwereld-'||i,'Oefenwereld '||i,i);
   applicationid:=gen_random_uuid();portalid:=gen_random_uuid();token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status) values(applicationid,eventid,ownerid,'approved');
   insert into app_private.portals(id,event_id,application_id,world_id,name,intensity,operation_status) values(portalid,eventid,applicationid,worldid,'Oefenpoort '||i,1,'open');
   insert into app_private.portal_owners(portal_id,user_id,role) values(portalid,ownerid,'owner');
   insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from) values(portalid,extensions.digest(token,'sha256'),extensions.digest(upper(token),'sha256'),1,now()-interval '1 minute');
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26+i*.0001,now());
   insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit) values(portalid,now()-interval '1 hour',now()+interval '5 hours',3,1,20);
   nodeid:=gen_random_uuid();
   insert into app_private.walking_nodes(id,event_id,kind,portal_id,coordinate,verified_at) values(nodeid,eventid,'portal',portalid,point(4.26+i*.0001,52.10),now());
   insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by) values(eventid,previousnode,nodeid,10,10,now(),ownerid);
   previousnode:=nodeid;
   portalids:=array_append(portalids,portalid);tokens:=array_append(tokens,token);
  end loop;
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id) values(groupid,eventid,'LAB-01','ready',slotid);
  insert into app_private.group_leaders(group_id,user_id,active_from,revision) values(groupid,ownerid,now()-interval '1 minute',1);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(groupid,registrationid,1,now());
  insert into app_private.route_plan_versions(id,group_id,revision,state,input_hash) values(planid,groupid,1,'draft',eventid::text);
  for i in 1..5 loop
   insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at) values(planid,i,portalids[i],now()+i*interval '5 minutes',now()+(i*5+3)*interval '1 minute');
  end loop;
  update app_private.route_plan_versions set state='published',published_at=now() where id=planid;
  update app_private.walking_groups set current_plan_version_id=planid where id=groupid;
  for operation in select * from jsonb_array_elements(spec) loop
   problem:=null;tick:=clock_timestamp();
   select * into r from app_private.group_runs where id=runid;
   if r.id is not null then
    select s.sequence,coalesce(s.portal_id,p.portal_id) into n,currentportal from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=r.current_stop_id;
    token:=tokens[array_position(portalids,currentportal)];
    select jsonb_object_agg(rp.id::text,case when rc.child_id=childids[2] then 'skipped' else 'visited' end) into choices
     from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present';
    request:=jsonb_build_object('run',runid,'stop',r.current_stop_id,'version',r.version,'token',token,'choices',choices,'key',gen_random_uuid()::text);
   end if;
   begin
    case operation->>'op'
    when 'empty' then perform api.run_start(groupid,'{}'::uuid[],(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'empty');
    when 'start' then
      results:=api.run_start(groupid,case when _scenario='start' then rcids[1:2] else rcids end,(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'start');
      runid:=(results->>'runId')::uuid;
      -- A genuine finale flag on the final isolated stop exercises the same completion transaction.
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','active',clock_timestamp()-interval '1 second',clock_timestamp()+interval '2 hours',3) returning id into fixtureid;
      update app_private.run_stops set stop_kind='finale',portal_id=portalids[5],reservation_id=fixtureid,plan_stop_id=null where run_id=runid and sequence=5;
    when 'arrive','wrong','stale','repeat' then
      if operation->>'op'='repeat' then request:=previous; end if;
      perform api.run_arrive_and_advance((request->>'run')::uuid,(request->>'stop')::uuid,(request->>'version')::integer-case when operation->>'op'='stale' then 1 else 0 end,
       case when operation->>'op'='wrong' then encode(extensions.gen_random_bytes(32),'hex') else request->>'token' end,request->'choices',request->>'key');
      previous:=request;
    when 'close' then perform api.portal_set_operational_state(currentportal,'closed',(select version from app_private.portals where id=currentportal),'Geïsoleerde generale');
    when 'systemskip' then perform api.run_system_skip(runid,r.current_stop_id,r.version,'Gesloten oefenpoort',gen_random_uuid()::text,'system-skip');
    when 'skipall' then perform api.run_bulk_skip_pending(runid,r.current_stop_id,r.version,'Met oefenouder bevestigd',gen_random_uuid()::text,'skip-all');
    when 'complete' then perform api.run_complete_stop(runid,r.current_stop_id,r.version,true,gen_random_uuid()::text,'manual-complete');
    when 'scan' then perform api.run_scan(runid,r.current_stop_id,r.version,token,'qr');
    when 'departone','departall' then
      select array_agg(rp.id order by rp.id) into leavingids from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present' and (operation->>'op'='departall' or rc.child_id=childids[2]);
      perform api.run_end_early(runid,r.version,leavingids,'Eigen oefengezin sluit af',gen_random_uuid()::text);
      -- Restore the immutable child order used by the measurement projection.
      select array_agg(rc.child_id order by array_position(rcids,rc.id)) into childids from app_private.registration_children rc where rc.id=any(rcids);
    when 'offline' then null; -- Simulated transport omission: deliberately issue no SQL command.
    when 'snapshot' then null;
    else raise exception 'INVALID_SCENARIO';
    end case;
   exception when others then problem:=SQLERRM;
   end;
   select * into r from app_private.group_runs where id=runid;
   select count(*) into actualhistory from app_private.run_stops where run_id=runid and state='completed';
   select coalesce(sequence,0) into actualseq from app_private.run_stops where id=r.current_stop_id;actualseq:=coalesce(actualseq,0);
   actualstatus:=coalesce(r.status::text,'before');
   select jsonb_agg((select count(*) from app_private.poortenboek_passport_seals seal where seal.event_id=eventid and seal.child_id=rc.child_id) order by array_position(rcids,rc.id)) into sealcounts from app_private.registration_children rc where rc.id=any(rcids);
   ok:=problem is not distinct from operation->>'error' and actualhistory=(operation->>'history')::integer and actualseq=(operation->>'sequence')::integer and actualstatus=operation->>'status' and sealcounts=operation->'seals';
   if _scenario='finale' and actualstatus='completed' then ok:=ok and (select count(*)=3 from app_private.poortenboek_passport_seals where event_id=eventid and finale); end if;
   view:=jsonb_build_object('connected',operation->>'op'<>'offline','parent',jsonb_build_object('status',actualstatus,'stop',case when actualseq=0 then 'Geen actieve bestemming' else 'Oefenpoort '||actualseq end,'sequence',actualseq,'version',coalesce(r.version,0),'arrived',actualhistory>0,'endedEarly',r.stopped_reason='all_participants_departed'),
    'gate',jsonb_build_object('name','Geïsoleerde oefenpoort','code','LAB','status',coalesce((select operation_status from app_private.portals where id=currentportal),'open'),'scanned',exists(select 1 from app_private.scan_evidence where run_stop_id=r.current_stop_id)),
    'children',(select jsonb_agg(jsonb_build_object('id',rc.id,'name',c.first_name,'attendance',coalesce(rp.attendance::text,'absent'),'choice','Eigen keuze','seals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id),'finaleSeals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id and finale)) order by array_position(rcids,rc.id)) from app_private.registration_children rc join app_private.children c on c.id=rc.child_id left join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=runid where rc.id=any(rcids)),
    'history',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'name','Oefenpoort '||sequence,'outcome',outcome,'arrived',outcome<>'system_skipped') order by sequence) from app_private.run_stops where run_id=runid and state='completed'),'[]'::jsonb));
   report:=report||jsonb_build_array(jsonb_build_object('title',operation->>'title','expectation',(operation-'op'-'title')::text,'actual',jsonb_build_object('error',problem,'history',actualhistory,'sequence',actualseq,'status',actualstatus,'seals',sealcounts)::text,'passed',coalesce(ok,false),'at',clock_timestamp(),'durationMs',round(extract(epoch from clock_timestamp()-tick)*1000),'command',operation->>'op','view',view));
  end loop;
  raise exception using errcode='P7711',message='ROLLBACK_ISOLATED_REHEARSAL';
 exception when sqlstate 'P7711' then null;
 end;
 return jsonb_build_object('scenarioId',_scenario,'title',_scenario,'startedAt',started,'endedAt',clock_timestamp(),'passed',not exists(select 1 from jsonb_array_elements(report) item where not (item->>'passed')::boolean),'steps',report,'environment','Isolated SQL transaction; fixtures rolled back; external transport is not measured');
end $function$
;

CREATE OR REPLACE FUNCTION api.run_start(_group_id uuid, _present_registration_child_ids uuid[], _expected_group_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
  dispatch_result jsonb;
  publication app_private.group_start_publications;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_group_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for no key update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_present_registration_child_ids), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id
        and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  if not app_private.is_evening_isolated_rehearsal(group_record.event_id) then
    if exists (
      select 1 from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where assignment.group_id = _group_id and assignment.superseded_at is null
        and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
    ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;
  end if;
  if group_record.route_mode = 'dynamic' then
    select * into schedule from app_private.group_schedule_revisions
    where group_id = group_record.id and state = 'published'
    order by revision desc limit 1;
    if schedule.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode = '23514'; end if;
    select * into publication from app_private.group_start_publications where group_id=group_record.id and schedule_id=schedule.id order by publication_order desc limit 1;
    if publication.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514';end if;
    if clock_timestamp() < publication.starts_at then
      raise exception 'START_TIME_NOT_REACHED' using errcode = '23514';
    end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at,start_publication_id)
    values (_group_id, null, schedule.id, 'live', clock_timestamp(),publication.id) returning id into v_run_id;
  else
    select id into plan_id from app_private.route_plan_versions
    where group_id = _group_id and state = 'published' order by revision desc limit 1;
    if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.group_start_publications where group_id=_group_id) then
    raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514'; end if;
  if clock_timestamp() < (select starts_at from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1) then raise exception 'START_TIME_NOT_REACHED' using errcode='23514'; end if;

    select * into publication from app_private.group_start_publications where group_id=_group_id order by publication_order desc limit 1;
    if not app_private.is_evening_isolated_rehearsal(group_record.event_id) and not exists(select 1 from app_private.finale_publication_commitments where publication_id=publication.id) then raise exception 'FINAL_RESERVATION_REQUIRED' using errcode='23514';end if;
    if publication.point_snapshot->>'walking_node_id' is not null and not exists(
      select 1 from app_private.route_plan_stops stop join app_private.walking_nodes node on node.portal_id=stop.portal_id and node.event_id=group_record.event_id and node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id,(publication.point_snapshot->>'walking_node_id')::uuid,node.id,false) safe_path
      where stop.plan_version_id=plan_id and stop.position=1) then raise exception 'NO_SAFE_WALKING_PATH' using errcode='23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at,start_publication_id)
    values (_group_id, plan_id, publication.schedule_id, 'live', clock_timestamp(),publication.id) returning id into v_run_id;
  end if;

  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids)
      then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null
    and registration_child.participation_status = 'active';

  if group_record.route_mode = 'dynamic' then
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := app_private.dispatch_next_stop(v_run_id, clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id = v_run_id;
  elsif app_private.is_evening_isolated_rehearsal(group_record.event_id) then
    insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
    select v_run_id, stop.id, stop.position,
      case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when stop.position = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
    select id into first_stop_id from app_private.run_stops where run_id = v_run_id and sequence = 1;
    if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
    update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select first_stop_id, participant.id from app_private.run_participants participant
    where participant.run_id = v_run_id and participant.attendance = 'present';
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := jsonb_build_object('decision', 'legacy', 'stopId', first_stop_id);
  else
    insert into app_private.run_stops(run_id,plan_stop_id,sequence,state)
      select v_run_id,stop.id,stop.position,'locked' from app_private.route_plan_stops stop where stop.plan_version_id=plan_id order by stop.position;
    update app_private.walking_groups set status='live',version=version+1 where id=_group_id;
    dispatch_result:=app_private.dispatch_next_stop(v_run_id,clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id=v_run_id;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (v_run_id, first_stop_id, 'run.started', actor, jsonb_build_object('routeMode', group_record.route_mode));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id, jsonb_build_object('routeMode', group_record.route_mode));
  result := jsonb_build_object('runId', v_run_id, 'dispatch', dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, result, now() + interval '2 days') returning * into receipt;
  return receipt.safe_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.evening_route_context(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g app_private.walking_groups; r app_private.group_runs; s app_private.group_schedule_revisions;
 p app_private.group_start_publications; point app_private.start_points; slot app_private.start_slots; cfg app_private.event_route_settings;
 c app_private.finale_publication_commitments; released app_private.run_stop_location_snapshots;
 decision_at timestamptz:=clock_timestamp(); from_at timestamptz; after_current_at timestamptz;
 is_live boolean; confirmed boolean:=false; step_free boolean; children integer; visited integer:=0; remaining integer; visit_limit integer; limit_source text;
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
   where stop.run_id=r.id and stop.state='completed' and (stop.outcome is distinct from 'system_skipped' and app_private.has_valid_arrival_proof(stop.id))
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
     and (stop.outcome is distinct from 'system_skipped' and app_private.has_valid_arrival_proof(stop.id)))
   into seen,visited from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   where stop.run_id=r.id and stop.state in ('active','completed');
  select jsonb_build_object('id',stop.id,'planStopId',stop.plan_stop_id,'portalId',portal.id,'code',portal.system_code,'name',portal.name,'world',world.name,
    'sequence',stop.sequence,'kind',coalesce(stop.stop_kind::text,'ordinary'),'status','current',
    'address',case when snap.run_stop_id is not null then concat_ws(' ',snap.address->>'street',snap.address->>'houseNumber',snap.address->>'addition') else concat_ws(' ',l.street,l.house_number,l.addition) end,
    'coordinate',jsonb_build_array(coalesce(snap.longitude,l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(snap.latitude,l.marker_latitude,l.geocoded_latitude,l.latitude)),
    'reservedArrivalAt',b.reserved_from,'scanAccepted',(stop.outcome is distinct from 'system_skipped' and app_private.has_valid_arrival_proof(stop.id)))
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
    'arrivalConfirmed',(stop.outcome is distinct from 'system_skipped' and app_private.has_valid_arrival_proof(stop.id))) order by stop.sequence),'[]')
   into history from app_private.run_stops stop left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
   join app_private.portals portal on portal.id=coalesce(stop.portal_id,old_stop.portal_id) where stop.run_id=r.id and stop.state='completed';
 end if;
 visit_limit:=g.desired_ordinary_visits;limit_source:=case when visit_limit is null then 'unbounded' else 'participant' end;
 if visit_limit is null and g.route_mode='legacy' then
  select count(distinct ps.portal_id) into visit_limit from app_private.route_plan_stops ps where ps.plan_version_id=coalesce(case when is_live then r.active_plan_version_id end,
   (select version.id from app_private.route_plan_versions version where version.group_id=g.id and version.state='published' order by version.revision desc limit 1))
   and ps.portal_id is distinct from coalesce(c.portal_id,cfg.final_portal_id);
  limit_source:='legacy_plan';
 end if;
 remaining:=case when visit_limit is null then null else greatest(0,visit_limit-visited) end;
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
  'ordinaryStopAt',least(s.effective_ordinary_stop_at,cfg.global_ordinary_stop_at),'ordinaryVisitLimit',visit_limit,'ordinaryVisitLimitSource',limit_source,'completedOrdinaryVisits',visited,'remainingOrdinaryVisits',remaining,
  'seenPortalIds',to_jsonb(seen),'historyRunId',r.id,'historyIsPreviousRun',not is_live,'history',coalesce(history,'[]'),'currentStop',current_stop,
  'finalePortalId',coalesce(c.portal_id,cfg.final_portal_id),'finaleArrivalAt',coalesce(c.reserved_arrival_at,s.expected_finale_arrival_at),
  'finaleOnly',coalesce(r.finale_only,false),'finaleOccupiedUntil',c.occupied_until,'finaleServiceUntil',c.service_until,'finaleGraceSeconds',coalesce(c.grace_seconds,cfg.finale_turnover_seconds,120),'finaleReserved',c.publication_id is not null,
  'finaleReservationId',(select b.id from app_private.portal_reservations b where b.start_publication_id=c.publication_id),
  'safeWaitingInstruction',c.safe_waiting_instruction);
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
  requested:=(app_private.evening_route_context(r.group_id)->>'ordinaryVisitLimit')::integer;
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
  if group_record.route_mode not in ('dynamic','legacy') then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = coalesce(run_record.schedule_revision_id,(select pub.schedule_id from app_private.group_start_publications pub where pub.id=app_private.run_start_publication(run_record.id))) and state in ('published','superseded');
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  route_context:=app_private.evening_route_context(group_record.id)||jsonb_build_object('serverNowAt',_decision_at,'calculatedFromAt',_decision_at);
  frozen_publication_id:=app_private.run_start_publication(run_record.id);
  perform app_private.ensure_finale_commitment(frozen_publication_id);
  select * into commitment from app_private.finale_publication_commitments where finale_publication_commitments.publication_id=frozen_publication_id;
  if commitment.publication_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_REQUIRED',_decision_at);end if;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
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
  select coalesce(max(sequence), 0) + 1 into next_sequence from app_private.run_stops where run_id = _run_id and state in ('active','completed');
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
      next_stop_id:=app_private.release_evening_destination(_run_id,candidate.portal_id,ordinary_reservation_id,'ordinary',next_sequence);
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
  next_stop_id:=app_private.release_evening_destination(_run_id,commitment.portal_id,finale_reservation_id,'finale',next_sequence);
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

CREATE OR REPLACE FUNCTION api.run_complete_stop(_run_id uuid, _stop_id uuid, _expected_run_version integer, _all_skip_confirmed boolean, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

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
  if not app_private.has_valid_arrival_proof(_stop_id) then raise exception 'WRONG_PORTAL';end if;

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
  elsif coalesce(stop_record.stop_kind::text,'ordinary')='ordinary' and not app_private.is_evening_isolated_rehearsal((select event_id from app_private.walking_groups where id=run_record.group_id)) then
    update app_private.group_runs set current_stop_id = null, version = version + 1
    where id = _run_id returning * into run_record;
    dispatch_result := app_private.dispatch_after_confirmed_arrival(_run_id);
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
$function$
;

CREATE OR REPLACE FUNCTION api.run_system_skip(_run_id uuid, _stop_id uuid, _expected_run_version integer, _reason text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  next_stop app_private.run_stops;
  receipt app_private.command_receipts;
  portal_state app_private.portal_operation_status;
  portal_id uuid;
  world_id uuid;
  v_event_id uuid;
  result jsonb; dispatch_result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.systemSkip' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
    if run_record.id is null or not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    return receipt.safe_result;
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select portal.id, portal.world_id, portal.operation_status into portal_id, world_id, portal_state
  from app_private.run_stops actual_stop left join app_private.route_plan_stops plan_stop on plan_stop.id=actual_stop.plan_stop_id
  join app_private.portals portal on portal.id=coalesce(actual_stop.portal_id,plan_stop.portal_id) where actual_stop.id=stop_record.id;
  if portal_id is null or portal_state is distinct from 'closed' then raise exception 'PORTAL_NOT_CLOSED' using errcode = '23514'; end if;
  if stop_record.stop_kind='finale' then raise exception 'FINAL_PORTAL_REQUIRED' using errcode='23514';end if;
  if exists(select 1 from app_private.scan_evidence where run_stop_id=_stop_id) or exists (select 1 from app_private.stop_participant_statuses where run_stop_id = _stop_id and status = 'visited') then
    raise exception 'VISIT_ALREADY_RECORDED' using errcode = '23514';
  end if;

  update app_private.stop_participant_statuses
  set required_for_completion = false, exclusion_reason = 'system_portal_closed', reason = left(_reason, 500), version = version + 1, changed_by = actor
  where run_stop_id = _stop_id and required_for_completion;
  update app_private.run_stops
  set state = 'completed', outcome = 'system_skipped', completed_at = now(), completion_actor = actor,
      completion_reason = left(_reason, 500), version = version + 1
  where id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, world_id, 'system_skipped');

  update app_private.portal_reservations set status='cancelled',cancelled_reason='Gesloten poort expliciet overgeslagen',version=version+1 where (id=stop_record.reservation_id or bound_stop_id=stop_record.id) and status in ('held','active');
  if app_private.is_evening_isolated_rehearsal(v_event_id) then
  select * into next_stop from app_private.run_stops where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
  if next_stop.id is null then
    update app_private.group_runs set status = 'completed', current_stop_id = null, finished_at = now(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
  else
    update app_private.run_stops set state = 'active', opened_at = now(), version = version + 1 where id = next_stop.id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select next_stop.id, participant.id from app_private.run_participants participant
    where participant.run_id = _run_id and participant.attendance = 'present';
    update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
    where id = _run_id returning * into run_record;
  end if;
  else
    update app_private.group_runs set current_stop_id=null,version=version+1 where id=_run_id;
    dispatch_result:=app_private.dispatch_after_confirmed_arrival(_run_id);
    select * into run_record from app_private.group_runs where id=_run_id;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.system_skipped', actor, jsonb_build_object('portalId', portal_id, 'reason', left(_reason, 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.system_skipped', 'group_run', _run_id, jsonb_build_object('stopId', _stop_id, 'portalId', portal_id, 'reason', left(_reason, 500)));
  result := jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'completedStopId', _stop_id, 'outcome', 'system_skipped', 'hasNextStop', run_record.current_stop_id is not null,'dispatch',dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.systemSkip', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.assert_finale_arrival_window(_run_id uuid, _stop_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s app_private.run_stops; b app_private.portal_reservations; grace integer; decision_at timestamptz:=clock_timestamp();
begin
 select * into s from app_private.run_stops where id=_stop_id and run_id=_run_id;
 if s.stop_kind::text is distinct from 'finale' then return; end if;
 -- A previously accepted real scan is still evidence when completion/retry
 -- happens after the admission window. It cannot become a second arrival.
 if app_private.has_valid_arrival_proof(s.id) then return; end if;
 select * into b from app_private.portal_reservations where (id=s.reservation_id or bound_stop_id=s.id) and run_id=_run_id and kind='finale' and status='active';
 if b.id is null then raise exception 'FINAL_RESERVATION_REQUIRED' using errcode='23514'; end if;
 select c.grace_seconds into grace from app_private.finale_publication_commitments c where c.publication_id=b.start_publication_id;
 if grace is null then select cfg.finale_turnover_seconds into grace from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id join app_private.event_route_settings cfg on cfg.event_id=g.event_id where r.id=_run_id;end if;
 if decision_at<b.reserved_from then raise exception 'FINAL_ARRIVAL_TOO_EARLY' using errcode='23514'; end if;
 if decision_at>b.reserved_from+make_interval(secs=>coalesce(grace,120)) then raise exception 'FINAL_RESERVATION_MISSED' using errcode='23514'; end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.run_scan(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
  inserted_count integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if app_private.has_valid_arrival_proof(_expected_stop_id) then return jsonb_build_object('accepted',true,'stopId',_expected_stop_id);end if;
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
  perform app_private.assert_finale_arrival_window(_run_id,_expected_stop_id);
 perform app_private.assert_physical_portal_admission(_run_id,_expected_stop_id);
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  get diagnostics inserted_count=row_count;
  if inserted_count>0 then
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  end if;
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.assert_arrival_credential(_run_id uuid, _stop_id uuid, _version integer, _credential text, _method text, _portal_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; p app_private.portals; credentialid uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if r.version<>_version or r.current_stop_id is distinct from _stop_id then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status<>'live' then raise exception 'RUN_NOT_LIVE'; end if;
 select portal.* into p from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 join app_private.portals portal on portal.id=coalesce(s.portal_id,plan.portal_id) where s.id=_stop_id and s.run_id=_run_id and s.state='active' for share of portal;
 if p.id is null or (_portal_id is not null and p.id<>_portal_id) then raise exception 'WRONG_PORTAL'; end if;
 if app_private.has_valid_arrival_proof(_stop_id) then return (select credential_id from app_private.scan_evidence where run_stop_id=_stop_id);end if;
 if p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 if _method not in ('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160 then raise exception 'WRONG_PORTAL'; end if;
 select c.id into credentialid from app_private.portal_credentials c where c.portal_id=p.id and c.revoked_at is null
 and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
 and ((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
 or (_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
 order by c.version desc limit 1;
 if credentialid is null then raise exception 'WRONG_PORTAL'; end if;
 perform app_private.assert_finale_arrival_window(_run_id,_stop_id);
 perform app_private.assert_physical_portal_admission(_run_id,_stop_id);
 return credentialid;
end $function$
;

CREATE OR REPLACE FUNCTION app_private.assert_physical_portal_admission(_run_id uuid, _stop_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; g app_private.walking_groups; s app_private.run_stops; p app_private.portals;
 cfg app_private.event_route_settings; w app_private.portal_windows; booking app_private.portal_reservations; ps app_private.route_plan_stops;
 decision_at timestamptz:=clock_timestamp(); children integer; usage jsonb; is_finale boolean; until_at timestamptz; max_groups integer;max_children integer;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 select * into s from app_private.run_stops where id=_stop_id and run_id=r.id and state='active';
 if s.id is null or r.current_stop_id is distinct from s.id then raise exception 'STALE_VERSION' using errcode='40001';end if;
 -- A retry or later completion of an accepted scan is never a second admission.
 if app_private.has_valid_arrival_proof(s.id) then return;end if;
 select * into ps from app_private.route_plan_stops where id=s.plan_stop_id;
 select * into p from app_private.portals where id=coalesce(s.portal_id,ps.portal_id) and event_id=g.event_id;
 select * into cfg from app_private.event_route_settings where event_id=g.event_id;
 select * into booking from app_private.portal_reservations where id=s.reservation_id or bound_stop_id=s.id order by id limit 1;
 if p.id is null or p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE' using errcode='23514';end if;
 select count(*) into children from app_private.run_participants where run_id=r.id and attendance='present' and departed_at is null;
 if children<=0 then raise exception 'EMPTY_GROUP' using errcode='23514';end if;
 is_finale:=s.stop_kind='finale' and cfg.final_portal_id=p.id;
 if is_finale then
  if not cfg.finale_available then raise exception 'FINALE_UNAVAILABLE' using errcode='23514';end if;
  max_groups:=cfg.finale_max_concurrent_groups;max_children:=cfg.finale_max_concurrent_children;
  until_at:=decision_at+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds);
 else
  -- Preserve a valid released instruction when its expected reception interval
  -- differs from the actual arrival; use that window's existing capacity limits.
  select * into w from app_private.portal_windows pw where pw.portal_id=p.id and
   ((decision_at>=pw.opens_at and decision_at<pw.closes_at) or (coalesce(booking.reserved_from,ps.planned_arrival_at)>=pw.opens_at and coalesce(booking.reserved_from,ps.planned_arrival_at)<pw.closes_at))
   order by (decision_at>=pw.opens_at and decision_at<pw.closes_at) desc,pw.opens_at,pw.id limit 1;
  if w.id is null then raise exception 'PORTAL_CAPACITY_UNAVAILABLE' using errcode='23514';end if;
  max_groups:=w.max_concurrent_groups;max_children:=w.max_children_per_visit;
  until_at:=decision_at+make_interval(secs=>greatest(cfg.ordinary_visit_seconds,w.visit_minutes*60)+greatest(cfg.route_buffer_seconds,w.buffer_minutes*60));
 end if;
 usage:=app_private.physical_portal_usage(g.event_id,p.id,g.id,decision_at,until_at,children,decision_at);
 if (usage->>'peakGroups')::integer>max_groups then raise exception 'PORTAL_CAPACITY_EXCEEDED' using errcode='23514';end if;
 if (usage->>'peakChildren')::integer>max_children then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode='23514';end if;
 if not is_finale and w.max_children_total is not null and (usage->>'totalChildren')::integer>w.max_children_total then raise exception 'PORTAL_TOTAL_CAPACITY_EXCEEDED' using errcode='23514';end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.run_support_override(_run_id uuid, _stop_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  v_event_id uuid;
  credential_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select event_id into v_event_id from app_private.walking_groups where id = run_record.group_id;
  if run_record.status <> 'live' or not app_private.has_capability(v_event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select credential.id into credential_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
  join app_private.portal_credentials credential on credential.portal_id = coalesce(stop.portal_id, plan_stop.portal_id) and credential.revoked_at is null and credential.valid_from<=clock_timestamp() and (credential.valid_until is null or credential.valid_until>clock_timestamp())
  where stop.id = _stop_id order by credential.version desc limit 1;
  if credential_id is null then raise exception 'NO_ACTIVE_CREDENTIAL' using errcode = '23514'; end if;
  perform app_private.assert_finale_arrival_window(_run_id,_stop_id);
  perform app_private.assert_physical_portal_admission(_run_id,_stop_id);
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  select _stop_id, credential.id, credential.version, actor, 'support_override'
  from app_private.portal_credentials credential where credential.id = credential_id
  on conflict (run_stop_id) do nothing;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.support_override', actor, jsonb_build_object('reason', left(trim(_reason), 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.support_override', 'group_run', _run_id,
    jsonb_build_object('stopId', _stop_id, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('accepted', true, 'stopId', _stop_id, 'override', true);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.block_unavailable_portal_visit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  portal_state app_private.portal_operation_status;
begin
  if new.status = 'visited' and old.status is distinct from 'visited' then
    select portal.operation_status into portal_state
    from app_private.run_stops run_stop
    left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
    join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
    where run_stop.id = new.run_stop_id;
    if (portal_state is null or portal_state not in ('open','paused')) and not app_private.has_valid_arrival_proof(new.run_stop_id) then
      raise exception 'PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.validate_ordinary_reservation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare assessment jsonb;
begin
  if new.bound_stop_id is not null and not exists(select 1 from app_private.run_stops s
    join app_private.group_runs r on r.id=s.run_id and r.group_id=new.group_id
    join app_private.walking_groups g on g.id=r.group_id and g.event_id=new.event_id
    left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
    where s.id=new.bound_stop_id and s.run_id=new.run_id and coalesce(s.portal_id,ps.portal_id)=new.portal_id and (s.stop_kind is null or s.stop_kind::text=new.kind::text))
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  if new.kind<>'ordinary' or new.status not in ('held','active') then return new; end if;
  if tg_op='UPDATE' and row(new.portal_id,new.group_id,new.run_id,new.child_count,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.child_count,old.reserved_from,old.reserved_until,old.service_until)
    then return new; end if;
  perform app_private.lock_evening_event(new.event_id);
  if not exists(select 1 from app_private.walking_groups g where g.id=new.group_id and g.event_id=new.event_id)
    or (new.run_id is not null and not exists(select 1 from app_private.group_runs r where r.id=new.run_id and r.group_id=new.group_id and r.status in ('ready','live','paused')))
    then raise exception 'INVALID_RESERVATION_SCOPE' using errcode='23514'; end if;
  -- Shrinking an existing current booking never evicts the released destination.
  if tg_op='UPDATE' and new.child_count<=old.child_count and row(new.portal_id,new.group_id,new.run_id,new.reserved_from,new.reserved_until,new.service_until)
    is not distinct from row(old.portal_id,old.group_id,old.run_id,old.reserved_from,old.reserved_until,old.service_until) then return new; end if;
  assessment:=app_private.assess_ordinary_portal(new.event_id,new.group_id,new.portal_id,new.reserved_from,new.child_count,
    clock_timestamp(),coalesce(new.service_until,new.reserved_until),new.reserved_until);
  if not (assessment->>'eligible')::boolean then raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.complete_bound_reservation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.state='completed' and old.state is distinct from new.state then
    update app_private.portal_reservations set
      status=case when new.outcome='system_skipped' then 'cancelled'::app_private.reservation_status else 'completed'::app_private.reservation_status end,
      cancelled_reason=case when new.outcome='system_skipped' then 'Bestemming expliciet gewijzigd' else cancelled_reason end,
      version=version+1
    where bound_stop_id=new.id and id is distinct from new.reservation_id and status in ('held','active');
  end if;
  if new.state='completed' and old.state is distinct from new.state then
    update app_private.route_alerts set status='resolved',resolved_at=clock_timestamp(),resolved_by=new.completion_actor,resolution_reason='Instructie afgerond of expliciet gewijzigd'
     where run_id=new.run_id and portal_id=coalesce(new.portal_id,(select ps.portal_id from app_private.route_plan_stops ps where ps.id=new.plan_stop_id)) and status='open' and code in ('ACTIVE_VISIT_AFTER_STOP','CURRENT_DESTINATION_REVIEW_REQUIRED');
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_route_command_options(_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 general_reason:=case when r.status<>'live' then 'De tocht staat op pauze. Hervat de tocht voordat je haar omleidt.'
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
 return jsonb_build_object('runVersion',r.version,'groupCode',g.system_code,'portals',portals,'adults',adults,'withdraw',jsonb_build_object('eligible',app_private.has_capability(g.event_id,'live_support',actor),'reasons',case when app_private.has_capability(g.event_id,'live_support',actor) then '[]'::jsonb else jsonb_build_array('Veilig afmelden is voorbehouden aan de avondregie. Neem contact op met de organisatie.') end),
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
$function$
;

CREATE OR REPLACE FUNCTION api.admin_redirect_group(_run_id uuid, _target text, _preferred_portal_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if g.route_mode not in ('dynamic','legacy') or r.status<>'live' then raise exception 'RUN_NOT_DISPATCHABLE' using errcode='23514';end if;
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
 if _target='ordinary' and not exists(select 1 from app_private.group_runs gr join app_private.run_stops rs on rs.id=gr.current_stop_id where gr.id=r.id and coalesce(rs.portal_id,(select portal_id from app_private.route_plan_stops where id=rs.plan_stop_id))=_preferred_portal_id and rs.state='active') then
  raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514';end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(g.event_id,actor,'group.destination_redirected','group_run',r.id,jsonb_build_object('target',_target,'preferredPortalId',_preferred_portal_id,'reason',trim(_reason)));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(actor,'admin.redirectGroup','v1:'||fingerprint,fingerprint,result,now()+interval '2 days');
 return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.group_snapshot(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; pid uuid; r app_private.group_runs; c app_private.finale_publication_commitments; p uuid; d app_private.dispatch_decisions; b app_private.portal_reservations; released app_private.run_stop_location_snapshots;
begin
 base:=app_private.group_snapshot_before_visit_information(_group_id);
 select * into r from app_private.group_runs where id=(base#>>'{run,id}')::uuid;
 p:=case when r.id is not null then app_private.run_start_publication(r.id) else
   (select pub.id from app_private.group_start_publications pub where pub.group_id=_group_id order by publication_order desc limit 1) end;
 select * into c from app_private.finale_publication_commitments where publication_id=p;
 if c.publication_id is not null then
   base:=jsonb_set(base,'{group,expectedFinaleArrivalAt}',to_jsonb(c.reserved_arrival_at),true);
 end if;
 if r.id is not null and (not coalesce((base#>>'{run,ownEveningFinished}')::boolean,false)
   or coalesce((base#>>'{access,leader}')::boolean,false) or coalesce((base#>>'{access,support}')::boolean,false)) then
   select * into d from app_private.dispatch_decisions where run_id=r.id order by sequence desc limit 1;
   if c.publication_id is not null then
     select * into b from app_private.portal_reservations where start_publication_id=c.publication_id;
     base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('reservedArrivalAt',c.reserved_arrival_at,
       'finaleReservation',jsonb_build_object('id',b.id,'publicationId',c.publication_id,'revision',(select pub.revision from app_private.group_start_publications pub where pub.id=c.publication_id),'reservedArrivalAt',c.reserved_arrival_at)),true);
   end if;
   if r.status='live' and r.current_stop_id is null and d.input_snapshot->>'waitingReason'='finale_window'
     and d.input_snapshot->>'reservationId'=b.id::text then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('waitingReason','finale_window',
        'waitingUntil',d.input_snapshot->'waitingUntil','safeWaitingInstruction',c.safe_waiting_instruction),true);
   elsif r.status='paused' and d.input_snapshot ? 'planningConflict' then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('planningConflict',d.input_snapshot->'planningConflict','safeWaitingInstruction',d.reason,'emergencyInstruction',d.reason),true);
   end if;
 end if;
 if r.current_stop_id is not null then
   select * into b from app_private.portal_reservations where id=(select s.reservation_id from app_private.run_stops s where s.id=r.current_stop_id)
     or bound_stop_id=r.current_stop_id order by created_at desc limit 1;
   if b.id is not null and base#>'{run,currentStop}' is not null and base#>'{run,currentStop}'<>'null'::jsonb then
     base:=jsonb_set(base,'{run,currentStop}',base#>'{run,currentStop}'||jsonb_build_object('plannedArrivalAt',b.reserved_from,'reservedArrivalAt',b.reserved_from,
       'arrivalWindow',jsonb_build_object('from',b.reserved_from,'until',case when b.kind='finale' then b.reserved_from+make_interval(secs=>coalesce(c.grace_seconds,(select cfg.finale_turnover_seconds from app_private.event_route_settings cfg join app_private.walking_groups g on g.event_id=cfg.event_id where g.id=r.group_id),120)) else coalesce(b.service_until,b.reserved_until) end)),true);
   end if;
 end if;
 pid:=(base#>>'{run,currentStop,portal,id}')::uuid;
 if pid is not null then
  base:=jsonb_set(base,'{run,currentDestinationNeedsReview}',to_jsonb(exists(select 1 from app_private.route_alerts where run_id=r.id and portal_id=pid and status='open' and code in ('ACTIVE_VISIT_AFTER_STOP','CURRENT_DESTINATION_REVIEW_REQUIRED'))),true);
  select * into released from app_private.run_stop_location_snapshots where run_stop_id=(base#>>'{run,currentStop,id}')::uuid and run_id=r.id and portal_id=pid;
  if released.run_stop_id is not null then
   base:=jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||jsonb_build_object(
    'address',concat_ws(' ',released.address->>'street',released.address->>'houseNumber',released.address->>'addition'),
    'postalCode',released.address->>'postalCode','coordinate',case when released.longitude is not null and released.latitude is not null then jsonb_build_array(released.longitude,released.latitude) else null end),true);
  end if;
 end if;

 if pid is null then return base; end if;
 return jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||app_private.portal_visit_information_projection(pid));
end $function$
;

CREATE OR REPLACE FUNCTION api.portal_arrivals_snapshot(_portal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); p app_private.portals;
begin
 select * into p from app_private.portals where id=_portal_id;
 if actor is null or p.id is null or not (
  exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=actor and o.revoked_at is null)
  or app_private.has_capability(p.event_id,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return (
 with latest_runs as materialized (
  select distinct on(r.group_id) r.* from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  where g.event_id=p.event_id order by r.group_id,r.created_at desc,r.id desc
 ), latest_publications as materialized (
  select distinct on(pub.group_id) pub.* from app_private.group_start_publications pub
  where pub.event_id=p.event_id order by pub.group_id,pub.publication_order desc
 ), raw_arrivals as (
  select g.id group_id,g.system_code group_code,g.display_name,s.planned_arrival_at,s.planned_departure_at,
    coalesce(rs.state::text,'planned') state,'assigned'::text classification,
    null::uuid reservation_id,null::uuid publication_id,null::integer publication_revision,
    case when r.status in ('live','paused') then (select count(*)::integer from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null) else null end children,
    2 priority
  from app_private.route_plan_stops s join app_private.route_plan_versions plan on plan.id=s.plan_version_id and plan.state='published'
  join app_private.walking_groups g on g.id=plan.group_id
  left join latest_runs r on r.group_id=g.id
  left join app_private.run_stops rs on rs.run_id=r.id and rs.plan_stop_id=s.id
  where s.portal_id=p.id and (
    (r.status in ('live','paused') and r.active_plan_version_id=plan.id and rs.state in ('active','completed'))
    or (g.route_mode='legacy' and (r.id is null or (r.status in ('completed','stopped') and plan.created_at>r.created_at))))
  union all
  select g.id,g.system_code,g.display_name,b.reserved_from,coalesce(b.service_until,b.reserved_until),
    case b.status when 'active' then 'active' when 'completed' then 'completed' else 'planned' end,'assigned',
    b.id,b.start_publication_id,pub.revision,b.child_count,case when b.status='completed' then 3 else 0 end
  from app_private.portal_reservations b join app_private.walking_groups g on g.id=b.group_id
  left join latest_runs r on r.group_id=b.group_id
  left join latest_publications current_pub on current_pub.group_id=b.group_id
  left join app_private.group_start_publications pub on pub.id=b.start_publication_id
  where b.portal_id=p.id and b.status in ('held','active','completed')
    and (b.status='completed' or
      ((b.expires_at is null or b.expires_at>clock_timestamp()) and
       ((b.run_id is not null and r.id=b.run_id and r.status in ('ready','live','paused'))
        or (b.run_id is null and (b.start_publication_id is null or b.start_publication_id=current_pub.id)
          and (coalesce(r.status::text,'') not in ('completed','stopped') or current_pub.id is distinct from app_private.run_start_publication(r.id))))))
  union all
  select g.id,g.system_code,g.display_name,s.expected_finale_arrival_at,
   s.expected_finale_arrival_at+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds),'planned','forecast',null,null,null,null,4
  from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
  join app_private.event_route_settings cfg on cfg.event_id=g.event_id and cfg.final_portal_id=p.id
  left join latest_runs r on r.group_id=g.id
  where s.state='published' and s.expected_finale_arrival_at is not null and p.operation_status in ('scheduled','open')
    and coalesce(r.status::text,'') not in ('completed','stopped')
    and not exists(select 1 from app_private.group_start_publications pub join app_private.finale_publication_commitments c on c.publication_id=pub.id where pub.schedule_id=s.id)
    and not exists(select 1 from app_private.portal_reservations b where b.group_id=g.id and b.portal_id=p.id and b.status in ('held','active','completed'))
 ), deduplicated as (
  select distinct on(group_id) * from raw_arrivals order by group_id,priority,planned_arrival_at desc,reservation_id
 ), enriched as (
  select d.*,coalesce(d.children,(select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=d.group_id and a.superseded_at is null)) expected_children from deduplicated d
 )
 select jsonb_build_object('portalId',p.id,'portalCode',p.system_code,'operationStatus',p.operation_status,'updatedAt',clock_timestamp(),
  'forecastAvailable',exists(select 1 from app_private.event_route_settings cfg where cfg.event_id=p.event_id and cfg.final_portal_id=p.id),
  'nextArrivalAt',(select min(planned_arrival_at) from enriched where state<>'completed'),
  'arrivals',coalesce((select jsonb_agg(jsonb_build_object('groupCode',e.group_code,'systemCode',e.group_code,
    'plannedArrivalAt',e.planned_arrival_at,'plannedDepartureAt',e.planned_departure_at,'expectedChildren',e.expected_children,'state',e.state,'classification',e.classification,
    'reservationId',e.reservation_id,'publicationId',e.publication_id,'revision',e.publication_revision) order by e.planned_arrival_at,e.group_code) from enriched e),'[]'::jsonb),
  'assignedGroups',(select count(*) from enriched where classification='assigned' and state<>'completed'),
  'assignedChildren',coalesce((select sum(expected_children) from enriched where classification='assigned' and state<>'completed'),0),
  'forecastGroups',(select count(*) from enriched where classification='forecast' and state<>'completed'),
  'forecastChildren',coalesce((select sum(expected_children) from enriched where classification='forecast' and state<>'completed'),0),
  'completedGroups',(select count(*) from enriched where state='completed'),'remainingGroups',(select count(*) from enriched where state<>'completed'),
  'expectedTotal',coalesce((select sum(expected_children) from enriched where state<>'completed'),0))
 );
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.compute_evening_route_preview(_group_id uuid, _revision integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   if coalesce((current_stop->>'scanAccepted')::boolean,false) then warnings:=warnings||jsonb_build_array('Het huidige huis is na de bevestigde aankomst gesloten. Rond dit bezoek samen af.');else blockers:=blockers||jsonb_build_array('De huidige bestemming is gesloten. De vrijgegeven instructie blijft herkenbaar; organisatiecontrole is nodig.');end if;
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
 if context->>'ordinaryVisitLimit' is not null then checklist:=checklist||jsonb_build_array(jsonb_build_object('code','visit-limit','label',case when context->>'ordinaryVisitLimitSource'='legacy_plan' then 'Bestaande gepubliceerde bezoekgrens' else 'Bewust gekozen bezoekgrens' end,'status','info','detail',format('Maximaal %s gewone poorten. Niet ieder geschikt huis hoeft in deze route te worden opgenomen.',context->>'ordinaryVisitLimit')));end if;
 return jsonb_build_object('groupId',_group_id,'revision',coalesce(_revision,app_private.start_ops_route_revision(preview_event_id)),'generatedAt',clock_timestamp(),
  'mode',context->'mode','calculatedFromAt',from_time,'remainingMinutes',total_minutes,'start',origin,'publishedStart',context->'start',
  'stops',stops,'history',context->'history','currentStopId',current_stop->'id','terminal',context->'terminal',
  'totalMeters',meters,'totalMinutes',total_minutes,'eligiblePortalCount',available,'warnings',warnings,'blockers',blockers,'feasible',jsonb_array_length(blockers)=0,
  'checklist',checklist,'provisional',false,'hasConfirmedStart',valid_start,'expectedFinaleArrivalAt',target,
  'finaleReservationId',context->'finaleReservationId','publicationId',context->'publicationId','safeWaitingInstruction',context->'safeWaitingInstruction',
  'excludedCandidates',coalesce((select jsonb_agg(jsonb_build_object('code',row->'code','name',row->'name','reasons',row->'reasons') order by row->>'code') from jsonb_array_elements(coalesce(candidates,'[]')) row where not (row->>'eligible')::boolean),'[]'));
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.evening_route_input(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare context jsonb:=app_private.evening_route_context(_group_id); eventid uuid:=(context->>'eventId')::uuid; decision_at timestamptz:=(context->>'serverNowAt')::timestamptz;
 result jsonb;
begin
 if eventid is null then return null;end if;
 select jsonb_build_object('contract','evening-route-v2','group',jsonb_build_object('id',g.id,'ordinaryLimit',context->'ordinaryVisitLimit'),
  'startPolicy',jsonb_build_array(context->'gatheringPortalId',context->'startCountsAsVisit'),'origin',context->'start','positionNode',context->'sourceNodeId','remainingNode',context->'remainingSourceNodeId','mode',context->'mode',
  'clockBucket',case when context->>'mode'='live' or exists(select 1 from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid and r.status in ('live','paused')) then floor(extract(epoch from decision_at)/30) end,
  'confirmed',context->'hasConfirmedStart','children',context->'childCount','stepFree',context->'requiresStepFree','terminal',coalesce((context->>'terminal')::boolean,false),
  'schedule',jsonb_build_object('revision',s.revision,'slot',s.start_slot_id,'cutoff',context->'ordinaryStopAt','finale',context->'finalePortalId','finaleAt',context->'finaleArrivalAt',
   'serviceUntil',coalesce((context->>'finaleServiceUntil')::timestamptz,(context->>'finaleArrivalAt')::timestamptz+make_interval(secs=>cfg.finale_show_seconds)),
   'occupiedUntil',coalesce((context->>'finaleOccupiedUntil')::timestamptz,(context->>'finaleArrivalAt')::timestamptz+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds)),
   'grace',context->'finaleGraceSeconds','waiting',coalesce(context->>'safeWaitingInstruction',
    case when nullif(trim(cfg.finale_waiting_area),'') is not null or nullif(trim(cfg.finale_safe_approach),'') is not null then concat_ws(' ',case when nullif(trim(cfg.finale_waiting_area),'') is not null then 'Wacht samen op de afgesproken plek: '||trim(cfg.finale_waiting_area)||'.' end,case when nullif(trim(cfg.finale_safe_approach),'') is not null then 'Volg deze afgesproken aanloop: '||trim(cfg.finale_safe_approach)||'.' end) else 'Blijf bij jullie groep en vraag de organisatie waar jullie veilig kunnen wachten.' end)),
  'settings',to_jsonb(cfg)-array['event_id','updated_at','updated_by','version'],
  'roster',coalesce((select jsonb_agg(jsonb_build_array(a.id,rc.id,rc.participation_status,ch.accessibility_note) order by a.id,rc.id)
   from app_private.group_registrations a join app_private.registration_children rc on rc.registration_id=a.registration_id join app_private.children ch on ch.id=rc.child_id where a.group_id=g.id and a.superseded_at is null),'[]'),
  'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'world',p.world_id,'approval',p.approval_status,'lifecycle',p.lifecycle_status,'operation',p.operation_status,
    'address',jsonb_build_array(l.street,l.house_number,l.addition),'coordinate',jsonb_build_array(coalesce(l.marker_longitude,l.geocoded_longitude,l.longitude),coalesce(l.marker_latitude,l.geocoded_latitude,l.latitude)),
    'verified',l.verified_at is not null,'practical',info.information,'legacyAccessibility',a.private_draft_data->>'accessibility') order by p.id)
    from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id left join app_private.portal_visit_information info on info.portal_id=p.id left join app_private.portal_applications a on a.id=p.application_id where p.event_id=eventid),'[]'),
  'windows',coalesce((select jsonb_agg(to_jsonb(w)-array['created_at','updated_at'] order by w.id) from app_private.portal_windows w join app_private.portals p on p.id=w.portal_id where p.event_id=eventid),'[]'),
  'nodes',coalesce((select jsonb_agg(jsonb_build_array(n.id,n.portal_id,n.coordinate::text,n.verified_at is not null) order by n.id) from app_private.walking_nodes n where n.event_id=eventid),'[]'),
  'edges',coalesce((select jsonb_agg(jsonb_build_array(edge.id,edge.from_node_id,edge.to_node_id,edge.distance_m,edge.duration_seconds,edge.wheelchair_accessible,edge.geometry_geojson,edge.approved_at is not null,edge.closed_at is not null) order by edge.id) from app_private.walking_edges edge where edge.event_id=eventid),'[]'),
  'bookings',coalesce((select jsonb_agg(jsonb_build_array(b.group_id,b.portal_id,b.kind,b.status,b.reserved_from,b.service_until,b.reserved_until,b.child_count,b.expires_at,b.expires_at is null or b.expires_at>decision_at,b.reserved_until>decision_at) order by b.id)
    from app_private.portal_reservations b where b.event_id=eventid and b.group_id<>g.id and b.status in ('held','active')),'[]'),
  'runs',coalesce((select jsonb_agg(jsonb_build_array(r.id,r.group_id,r.status,r.current_stop_id,r.finale_only,r.version,r.active_plan_version_id) order by r.id) from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'presence',coalesce((select jsonb_agg(jsonb_build_array(rp.id,rp.run_id,rp.attendance,rp.departed_at) order by rp.id) from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'stops',coalesce((select jsonb_agg(jsonb_build_array(rs.id,rs.run_id,coalesce(rs.portal_id,ps.portal_id),rs.state,rs.stop_kind,rs.outcome,rs.sequence,rs.opened_at,rs.completed_at) order by rs.id) from app_private.run_stops rs join app_private.group_runs r on r.id=rs.run_id join app_private.walking_groups wg on wg.id=r.group_id left join app_private.route_plan_stops ps on ps.id=rs.plan_stop_id where wg.event_id=eventid),'[]'),
  'scans',coalesce((select jsonb_agg(jsonb_build_array(scan.run_stop_id,scan.scanned_at) order by scan.id) from app_private.scan_evidence scan join app_private.run_stops scan_stop on scan_stop.id=scan.run_stop_id join app_private.group_runs r on r.id=scan_stop.run_id join app_private.walking_groups wg on wg.id=r.group_id where wg.event_id=eventid),'[]'),
  'historyArrivals',coalesce((select jsonb_agg(jsonb_build_array(a.run_stop_id,a.child_id,a.arrived_at,a.arrived) order by a.run_stop_id,a.child_id) from app_private.run_stop_arrivals a where a.event_id=eventid),'[]'),
  'legacyPlans',coalesce((select jsonb_agg(jsonb_build_array(p.group_id,p.id,p.state,rs.id,rs.portal_id,rs.planned_arrival_at,rs.planned_departure_at,rs.planned_departure_at>decision_at) order by p.id,rs.id) from app_private.route_plan_versions p join app_private.walking_groups wg on wg.id=p.group_id join app_private.route_plan_stops rs on rs.plan_version_id=p.id where wg.event_id=eventid and p.group_id<>g.id and p.state in ('valid','published')),'[]'))
 into result from app_private.walking_groups g left join app_private.group_schedule_revisions s on s.id=(context->>'scheduleId')::uuid left join app_private.event_route_settings cfg on cfg.event_id=g.event_id where g.id=_group_id;
 return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.portal_rotate_credential(_portal_id uuid, _expected_portal_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  credential app_private.portal_credentials;
  credential_token text;
  short_code text;
  next_version integer;
begin
  perform app_private.poortkamer_require(_portal_id,'details');
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = actor and owner.revoked_at is null)
     and not app_private.has_capability(portal.event_id, 'event_admin', actor)
    and not app_private.has_capability(portal.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if portal.version <> _expected_portal_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if portal.approval_status <> 'approved' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;

  select coalesce(max(version), 0) + 1 into next_version from app_private.portal_credentials where portal_id = portal.id;
  credential_token := encode(extensions.gen_random_bytes(32), 'hex');
  short_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  update app_private.portal_credentials set revoked_at = clock_timestamp() where portal_id = portal.id and revoked_at is null;
  insert into app_private.portal_credentials(portal_id, token_hash, short_code_hash, version, valid_from)
  values (
    portal.id,
    extensions.digest(convert_to(credential_token, 'utf8'), 'sha256'),
    extensions.digest(convert_to(short_code, 'utf8'), 'sha256'),
    next_version,
    now()
  ) returning * into credential;
  update app_private.portals set version = version + 1 where id = portal.id returning * into portal;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.credential_rotated', 'portal', portal.id, jsonb_build_object('credentialVersion', credential.version, 'reason', left(_reason, 300)));
  return jsonb_build_object(
    'portalId', portal.id,
    'portalVersion', portal.version,
    'credentialVersion', credential.version,
    'credential', credential_token,
    'shortCode', short_code
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION api.portal_print_access(_actor uuid, _portal_id uuid, _action text DEFAULT 'read'::text, _expected_version integer DEFAULT NULL::integer, _ciphertext text DEFAULT NULL::text, _token_hash bytea DEFAULT NULL::bytea, _short_hash bytea DEFAULT NULL::bytea)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; c app_private.portal_credentials; nextversion integer;
begin
 if _actor is null then raise exception 'NOT_AUTHORIZED'; end if;
 if _action='rotate' then perform app_private.lock_evening_event((select event_id from app_private.portals where id=_portal_id));end if;
 select * into p from app_private.portals where id=_portal_id for update;
 if p.id is null or not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null)
 and not app_private.has_capability(p.event_id,'portals_manage',_actor) then raise exception 'NOT_AUTHORIZED'; end if;
 if _action='rotate' then
  if not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage') and not app_private.has_capability(p.event_id,'portals_manage',_actor) then raise exception 'NOT_AUTHORIZED'; end if;
  if p.version is distinct from _expected_version then raise exception 'STALE_VERSION'; end if;
  if p.approval_status<>'approved' or _ciphertext is null or octet_length(_token_hash)<>32 or octet_length(_short_hash)<>32 then raise exception 'INVALID_INPUT'; end if;
  select coalesce(max(version),0)+1 into nextversion from app_private.portal_credentials where portal_id=p.id;
  update app_private.portal_credentials set revoked_at=clock_timestamp() where portal_id=p.id and revoked_at is null;
  insert into app_private.portal_credentials(portal_id,version,token_hash,short_code_hash,valid_from) values(p.id,nextversion,_token_hash,_short_hash,now()) returning * into c;
  insert into app_private.portal_print_material(credential_id,ciphertext) values(c.id,_ciphertext);
  update app_private.portals set version=version+1 where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(p.event_id,_actor,'portal.credential_rotated','portal',p.id,jsonb_build_object('credentialVersion',c.version,'reason','Expliciet vernieuwd in QR & printen'));
 elsif _action='read' then
  select * into c from app_private.portal_credentials where portal_id=p.id and revoked_at is null and valid_from<=now() and (valid_until is null or valid_until>now()) order by version desc limit 1;
 else raise exception 'INVALID_INPUT'; end if;
 return jsonb_build_object('credentialId',c.id,'credentialRevision',c.version,'portalVersion',p.version,
  'ciphertext',(select ciphertext from app_private.portal_print_material where credential_id=c.id),
  'legacy',c.id is not null and not exists(select 1 from app_private.portal_print_material where credential_id=c.id),
  'eventDate',(select local_date from app_private.events where id=p.event_id));
end $function$
;

CREATE OR REPLACE FUNCTION app_private.portal_visit_information_value(_portal uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.portals; draft jsonb; info jsonb; warnings jsonb; access text; notes text;
begin
 select information into info from app_private.portal_visit_information where portal_id=_portal;
 if info is not null then return info; end if;
 select * into p from app_private.portals where id=_portal;
 if p.id is null then return null; end if;
 select private_draft_data into draft from app_private.portal_applications where id=p.application_id;
 -- Old false defaults are not explicit declarations. Preserve only known positives.
 select jsonb_object_agg(k,coalesce(draft->'warnings'->k='true'::jsonb,false) or exists(
  select 1 from app_private.portal_flags f where f.portal_id=p.id and f.flag_key=k and f.value)) into warnings
 from unnest(array['smoke','flashes','sound','actors','allergens']) q(k);
 access:=case when draft->>'accessibility' in ('step_free','steps','mixed','unknown') then draft->>'accessibility'
  when p.accessibility_notes in ('step_free','steps','mixed','unknown') then p.accessibility_notes else 'unknown' end;
 notes:=coalesce(nullif(draft->>'accessibilityNotes',''),case when p.accessibility_notes not in ('step_free','steps','mixed','unknown') then p.accessibility_notes end,'');
 return jsonb_build_object('warningDisclosure','unknown','warnings',warnings,'warningNotes',coalesce(draft->>'warningNotes',''),
  'accessibility',access,'accessibilityNotes',notes);
end $function$
;

CREATE OR REPLACE FUNCTION api.admin_publish_plans(_event_slug text, _plan_ids uuid[], _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  affected integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.lock_evening_event(app_private.current_event_id(_event_slug));

  select id into v_event_id from app_private.events where slug = _event_slug for no key update;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(array_length(_plan_ids, 1), 0) = 0 or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
  if (select count(distinct plan.id) from app_private.route_plan_versions plan join app_private.walking_groups walking_group on walking_group.id = plan.group_id where plan.id = any(_plan_ids) and walking_group.event_id = v_event_id and plan.state = 'valid') <> (select count(distinct id) from unnest(_plan_ids) wanted(id)) then raise exception 'INVALID_PLAN' using errcode = '23514'; end if;

  if exists(select 1 from app_private.route_plan_versions plan where plan.id=any(_plan_ids)
    and not exists(select 1 from app_private.group_start_publications p where p.group_id=plan.group_id)) then
    raise exception 'START_TIME_PUBLICATION_REQUIRED' using errcode='23514'; end if;

  update app_private.route_plan_stops
  set planned_arrival_at = planned_arrival_at
  where plan_version_id = any(_plan_ids);

  raise exception 'EXPECTED_ROUTE_FINGERPRINT_REQUIRED' using errcode='40001';
  update app_private.route_plan_versions set state = 'published', published_at = now() where id = any(_plan_ids) and state = 'valid';
  get diagnostics affected = row_count;
  update app_private.walking_groups walking_group
  set status = case when walking_group.status = 'draft' then 'ready' else walking_group.status end,
      version = version + 1
  where walking_group.current_plan_version_id = any(_plan_ids);
  update app_private.group_registrations assignment set published_at = now() where assignment.group_id in (select plan.group_id from app_private.route_plan_versions plan where plan.id = any(_plan_ids));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, minimal_change)
  values (v_event_id, actor, 'route_plan.published', 'route_plan_batch', jsonb_build_object('planCount', affected, 'reason', left(trim(_reason), 500)));
  return jsonb_build_object('published', affected);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.validate_route_plan_stop()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  plan_record record;
  window_record app_private.portal_windows;
  portal_world_id uuid;
  source_node_id uuid;
  target_node_id uuid;
  active_children integer;
  overlapping_groups integer;
  assessment jsonb;
begin
  select plan.id as plan_id, plan.state, walking_group.id as group_id, walking_group.event_id,
         slot.external_id as start_external_id,slot.start_point_id
    into plan_record
  from app_private.route_plan_versions plan
  join app_private.walking_groups walking_group on walking_group.id = plan.group_id
  join app_private.start_slots slot on slot.id = walking_group.start_slot_id
  where plan.id = new.plan_version_id;
  perform app_private.lock_evening_event(plan_record.event_id);
  if plan_record.plan_id is null then raise exception 'INVALID_ROUTE_PLAN' using errcode = '23514'; end if;
  if new.position < 1 or new.planned_departure_at <= new.planned_arrival_at then
    raise exception 'INVALID_ROUTE_TIMING' using errcode = '23514';
  end if;

  select portal.world_id into portal_world_id
  from app_private.portals portal
  join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
  where portal.id = new.portal_id and portal.event_id = plan_record.event_id and portal.approval_status = 'approved';
  if portal_world_id is null then raise exception 'PORTAL_NOT_ROUTE_READY' using errcode = '23514'; end if;

  select candidate.* into window_record
  from app_private.portal_windows candidate
  where candidate.portal_id = new.portal_id
    and new.planned_arrival_at >= candidate.opens_at
    and new.planned_departure_at <= candidate.closes_at
    and new.planned_departure_at = new.planned_arrival_at + make_interval(mins => candidate.visit_minutes)
  order by candidate.opens_at limit 1;
  if window_record.id is null then raise exception 'PORTAL_WINDOW_CONFLICT' using errcode = '23514'; end if;

  select count(*) into active_children
  from app_private.group_registrations assignment
  join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
  where assignment.group_id = plan_record.group_id and assignment.superseded_at is null;
  if active_children = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if active_children > window_record.max_children_per_visit then raise exception 'PORTAL_CHILD_CAPACITY_EXCEEDED' using errcode = '23514'; end if;

  if exists (
    select 1 from app_private.route_plan_stops existing
    join app_private.portals portal on portal.id = existing.portal_id
    where existing.plan_version_id = new.plan_version_id and existing.id is distinct from new.id
      and (existing.portal_id = new.portal_id or portal.world_id = portal_world_id)
  ) then raise exception 'DUPLICATE_PORTAL_OR_WORLD' using errcode = '23514'; end if;

  assessment:=app_private.assess_ordinary_portal(plan_record.event_id,plan_record.group_id,new.portal_id,
    new.planned_arrival_at,active_children,statement_timestamp(),new.planned_departure_at,
    new.planned_departure_at+make_interval(mins=>window_record.buffer_minutes));
  if not (assessment->>'eligible')::boolean then
    raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text;
  end if;

  select node.id into target_node_id
  from app_private.walking_nodes node
  where node.event_id = plan_record.event_id and node.kind = 'portal' and node.portal_id = new.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if new.position = 1 then
    select node.id into source_node_id
    from app_private.walking_nodes node
    where node.event_id=plan_record.event_id and node.verified_at is not null and ((plan_record.start_point_id is not null and node.id=(select walking_node_id from app_private.start_points where id=plan_record.start_point_id)) or (plan_record.start_point_id is null and node.kind='start' and node.external_id=plan_record.start_external_id))
    order by node.id limit 1;
  else
    select node.id into source_node_id
    from app_private.route_plan_stops previous_stop
    join app_private.walking_nodes node on node.portal_id = previous_stop.portal_id
      and node.event_id = plan_record.event_id and node.kind = 'portal' and node.verified_at is not null
    where previous_stop.plan_version_id = new.plan_version_id and previous_stop.position = new.position - 1
    order by node.id limit 1;
  end if;
  if not app_private.has_approved_walking_path(plan_record.event_id, source_node_id, target_node_id) then
    raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_safe_withdraw_group(_run_id uuid, _responsible_adult_user_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups; receipt app_private.command_receipts; fingerprint text; result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if run_record.id is null or not app_private.has_capability(group_record.event_id, 'live_support', actor) or char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  fingerprint:=encode(extensions.digest(convert_to(jsonb_build_array(group_record.event_id,_run_id,_responsible_adult_user_id,_expected_run_version,trim(_reason))::text,'UTF8'),'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=actor and command_type='admin.safeWithdrawGroup' and idempotency_key='v1:'||fingerprint;
  if receipt.id is not null then return receipt.safe_result;end if;
  if run_record.version<>_expected_run_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
  if run_record.status not in ('live','paused') or run_record.id is distinct from (
    select r.id from app_private.group_runs r where r.group_id=group_record.id order by r.created_at desc,r.id desc limit 1
  ) then raise exception 'RUN_NOT_ACTIVE' using errcode='23514'; end if;
  if not exists (select 1 from app_private.readiness_group_adults(group_record.id) a where a.user_id=_responsible_adult_user_id) then raise exception 'RESPONSIBLE_ADULT_NOT_IN_GROUP' using errcode = '23514'; end if;
  insert into app_private.group_safe_departures(group_id, run_id, responsible_adult_user_id, recorded_by, reason)
  values (group_record.id, run_record.id, _responsible_adult_user_id, actor, trim(_reason));
  update app_private.group_runs set status = 'stopped', current_stop_id = null, stopped_reason = trim(_reason),
    finished_at = clock_timestamp(), version = version + 1 where id = run_record.id returning * into run_record;
  update app_private.walking_groups set status = 'stopped', version = version + 1 where id = group_record.id;
  update app_private.portal_reservations set status = 'cancelled', cancelled_reason = 'Veilige afmelding', version = version + 1
  where run_id = run_record.id and status in ('held', 'active');
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.safe_departure_recorded', 'group_run', run_record.id,
    jsonb_build_object('responsibleAdultUserId', _responsible_adult_user_id, 'reason', left(trim(_reason), 500)));
  result:=jsonb_build_object('runId',run_record.id,'status',run_record.status,'version',run_record.version);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
   values(actor,'admin.safeWithdrawGroup','v1:'||fingerprint,fingerprint,result,now()+interval '2 days');
  return result;
end;
$function$
;
