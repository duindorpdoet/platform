-- A rehearsal writes only a fresh isolated event and rolls the entire fixture
-- transaction back before returning its measured report. It never opens a real run.
create or replace function api.redesign_rehearsal(_event_slug text,_scenario text)
returns jsonb language plpgsql security definer set search_path='' as $$
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
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26,now());
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
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','held',now(),now()+interval '2 hours',3) returning id into fixtureid;
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
end $$;
revoke all on function api.redesign_rehearsal(text,text) from public,anon;
grant execute on function api.redesign_rehearsal(text,text) to authenticated;
