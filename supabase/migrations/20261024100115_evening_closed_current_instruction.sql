-- A house status change cannot silently replace an issued arrival command.
-- Preserve its identity, version and capacity claim. Actual accepted scans can
-- still finish; new admission and all future dispatch use current availability.
begin;
create or replace function api.portal_set_operational_state(
 _portal_id uuid,_state app_private.portal_operation_status,_expected_version integer,_reason text
) returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor uuid:=auth.uid(); portal app_private.portals; affected record; finale boolean;
begin
 if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 perform app_private.lock_evening_event((select p.event_id from app_private.portals p where p.id=_portal_id));
 perform app_private.poortkamer_require(_portal_id,'live');
 select * into portal from app_private.portals where id=_portal_id for update;
 if portal.id is null or _expected_version is null or portal.version<>_expected_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
 if _state is null then raise exception 'INVALID_STATE' using errcode='22023';end if;
 if not exists(select 1 from app_private.portal_owners o where o.portal_id=_portal_id and o.user_id=actor and o.revoked_at is null)
  and not app_private.has_capability(portal.event_id,'event_admin',actor)
  and not app_private.has_capability(portal.event_id,'portals_manage',actor)
  and not app_private.has_capability(portal.event_id,'live_support',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if _state in ('paused','closed') and char_length(trim(coalesce(_reason,''))) not between 5 and 500 then raise exception 'REASON_REQUIRED' using errcode='22023';end if;
 update app_private.portals set pause_until=null,operation_status=_state,pause_after_current=_state='paused',version=version+1
  where id=_portal_id returning * into portal;
 select exists(select 1 from app_private.event_route_settings s where s.event_id=portal.event_id and s.final_portal_id=portal.id) into finale;
 if finale and _state in ('open','paused','closed') then
  update app_private.event_route_settings set finale_available=_state='open',version=version+1 where event_id=portal.event_id;
  if _state in ('paused','closed') then
   -- Keep fixed publication appointments and their exact reservations. Closing
   -- a venue is not permission to move, cancel or overbook those commitments.
   -- An existing current arrival may finish, then future dispatch pauses. Runs
   -- with no issued destination pause immediately without inventing a stop.
   for affected in select r.id,r.group_id,r.status,r.current_stop_id from app_private.group_runs r
    join app_private.walking_groups g on g.id=r.group_id
    where g.event_id=portal.event_id and r.status in ('live','paused') order by r.id for update of r
   loop
    if affected.current_stop_id is null and affected.status='live' then
     update app_private.group_runs set status='paused',version=version+1 where id=affected.id;
    end if;
    insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
     select portal.event_id,affected.group_id,affected.id,portal.id,'urgent','FINALE_UNAVAILABLE',
      'De laatste poort ontvangt nu geen nieuwe groepen. De vaste afspraak blijft bewaard; vraag de organisatie om hulp.'
     where not exists(select 1 from app_private.route_alerts where run_id=affected.id and portal_id=portal.id and code='FINALE_UNAVAILABLE' and status='open');
   end loop;
  end if;
 end if;
 if _state='closed' then
  for affected in select r.id,r.group_id,s.id stop_id from app_private.group_runs r
   join app_private.walking_groups g on g.id=r.group_id
   join app_private.run_stops s on s.id=r.current_stop_id and s.state='active'
   left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
   where g.event_id=portal.event_id and r.status in ('live','paused') and coalesce(s.portal_id,ps.portal_id)=portal.id
    and not app_private.has_valid_arrival_proof(s.id) order by r.id for update of r,s
  loop
   insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
    select portal.event_id,affected.group_id,affected.id,portal.id,'warning','CURRENT_DESTINATION_REVIEW_REQUIRED',
     'De huidige poort is gesloten. De bestaande instructie blijft bewaard; neem contact op met de organisatie vóór het bezoek.'
    where not exists(select 1 from app_private.route_alerts where run_id=affected.id and portal_id=portal.id and code='CURRENT_DESTINATION_REVIEW_REQUIRED' and status='open');
  end loop;
 end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(portal.event_id,actor,'portal.operation_state_changed','portal',portal.id,jsonb_build_object('state',_state,'reason',left(coalesce(trim(_reason),''),500)));
 insert into app_private.portal_status_history(portal_id,actor_id,state,reason) values(portal.id,actor,_state,left(trim(_reason),500));
 perform app_private.poortkamer_signal(portal.id,'portal.room.status',jsonb_build_object('state',_state),'De poortstatus is gewijzigd.');
 return jsonb_build_object('id',portal.id,'state',portal.operation_status,'version',portal.version,'pauseAfterCurrent',portal.pause_after_current);
end;
$function$;
revoke execute on function api.portal_set_operational_state(uuid,app_private.portal_operation_status,integer,text) from public,anon;
grant execute on function api.portal_set_operational_state(uuid,app_private.portal_operation_status,integer,text) to authenticated;
commit;
