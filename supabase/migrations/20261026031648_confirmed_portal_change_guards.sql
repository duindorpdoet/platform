alter function api.admin_portal_change_impact(uuid) rename to admin_portal_change_impact_before_guard;
revoke all on function api.admin_portal_change_impact_before_guard(uuid) from public,anon,authenticated;
create function api.admin_portal_change_impact(_portal_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; eid uuid;
begin
 result:=api.admin_portal_change_impact_before_guard(_portal_id);
 select event_id into eid from app_private.portals where id=_portal_id;
 result:=result||jsonb_build_object('confirmedGroups',coalesce((select jsonb_agg(jsonb_build_object('code',g.system_code,'startsAt',slot.starts_at)) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points point on point.id=slot.start_point_id where point.linked_portal_id=_portal_id and app_private.is_start_confirmation_current(s.id)),'[]'));
 return result||jsonb_build_object('inputHash',md5(result::text||app_private.live_planboard_hash(eid)));
end $$;
revoke all on function api.admin_portal_change_impact(uuid) from public,anon;
grant execute on function api.admin_portal_change_impact(uuid) to authenticated;

alter function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) rename to admin_manual_portal_save_before_guard;
revoke all on function api.admin_manual_portal_save_before_guard(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; impact jsonb; sensitive boolean; protected boolean; result jsonb; pub record;
begin
 perform 1 from app_private.events where slug=_event_slug for no key update;
 -- The underlying command verifies authorization and the full request hash on replay.
 if _portal_id is null or exists(select 1 from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.manual.save' and idempotency_key=_payload->>'commandKey') then return api.admin_manual_portal_save_before_guard(_event_slug,_portal_id,_payload,_expected_version,_reason); end if;
 select * into p from app_private.portals where id=_portal_id;
 impact:=api.admin_portal_change_impact(_portal_id);
 sensitive:=coalesce(_payload->>'saveMode','')<>'draft' and (
  (coalesce(nullif(_payload->>'lifecycleStatus',''),p.lifecycle_status) is distinct from p.lifecycle_status)
  or (coalesce(nullif(_payload->>'approvalStatus',''),p.approval_status::text) is distinct from p.approval_status::text)
  or (coalesce(nullif(_payload->>'operationStatus',''),p.operation_status::text) is distinct from p.operation_status::text)
  or (_payload ? 'plannedOpensAt' and app_private.parse_amsterdam_instant(_payload->>'plannedOpensAt') is distinct from (select min(opens_at) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'plannedClosesAt' and app_private.parse_amsterdam_instant(_payload->>'plannedClosesAt') is distinct from (select max(closes_at) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'maxGroups' and (_payload->>'maxGroups')::integer is distinct from (select min(max_concurrent_groups) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'maxChildren' and (_payload->>'maxChildren')::integer is distinct from (select min(max_children_per_visit) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'visitMinutes' and (_payload->>'visitMinutes')::integer is distinct from (select min(visit_minutes) from app_private.portal_windows where portal_id=p.id))
  or (_payload ? 'bufferMinutes' and (_payload->>'bufferMinutes')::integer is distinct from (select min(buffer_minutes) from app_private.portal_windows where portal_id=p.id)));
 protected:=jsonb_array_length(impact->'publishedGroups')>0 or jsonb_array_length(impact->'confirmedGroups')>0 or (impact->>'pendingStops')::integer>0 or (impact->>'reservations')::integer>0;
 if sensitive then
  if (_payload ? 'impactHash' and _payload->>'impactHash' is distinct from impact->>'inputHash') then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  if protected and (_payload->>'impactHash' is distinct from impact->>'inputHash' or not coalesce((_payload->>'impactConfirmed')::boolean,false)) then raise exception 'CONFIRMATION_REQUIRED' using errcode='23514'; end if;
  if (impact->>'pendingStops')::integer>0 or (impact->>'reservations')::integer>0 then raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 end if;
 result:=api.admin_manual_portal_save_before_guard(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if _payload ? 'contactEmail' and coalesce(_payload->>'saveMode','')<>'draft' and p.contact_email is distinct from nullif(lower(trim(_payload->>'contactEmail')),'') then
  update app_private.portal_team_invites set revoked_at=clock_timestamp() where portal_id=p.id and email=p.contact_email and accepted_at is null and revoked_at is null;
 end if;
 if sensitive and protected then
  for pub in select g.id group_id,publication.starts_at from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) publication where publication.point_snapshot->>'linked_portal_id'=p.id::text loop
   if not exists(select 1 from app_private.portals current join app_private.portal_windows win on win.portal_id=current.id where current.id=p.id and current.lifecycle_status='active' and current.approval_status='approved' and current.operation_status not in ('paused','closed') and pub.starts_at>=win.opens_at and pub.starts_at+make_interval(mins=>win.visit_minutes+win.buffer_minutes)<=win.closes_at) then raise exception 'RESOLVE_ACTIVE_ASSIGNMENTS_FIRST' using errcode='23514'; end if;
  end loop;
 end if;
 return result;
end $$;
revoke all on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;

create function api.admin_portal_remove_reviewed(_portal_id uuid,_expected_version integer,_input_hash text,_reason text,_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; impact jsonb; receipt app_private.command_receipts; hashed text; result jsonb;
begin
 select event_id into eid from app_private.portals where id=_portal_id;
 if eid is null or auth.uid() is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=eid for no key update;
 hashed:=md5(jsonb_build_array(_portal_id,_expected_version,_input_hash,_reason)::text);
 if length(coalesce(_key,'')) not between 16 and 200 then raise exception 'INVALID_INPUT'; end if;
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.remove.reviewed' and idempotency_key=_key;
 if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 impact:=api.admin_portal_change_impact(_portal_id);
 if impact->>'inputHash' is distinct from _input_hash then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 result:=api.admin_manual_portal_remove(_portal_id,_expected_version,_reason);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.remove.reviewed',_key,hashed,result,now()+interval '7 days');
 return result;
end $$;
revoke all on function api.admin_portal_remove_reviewed(uuid,integer,text,text,text) from public,anon;
grant execute on function api.admin_portal_remove_reviewed(uuid,integer,text,text,text) to authenticated;

create function api.admin_portal_operation_reviewed(_portal_id uuid,_state text,_expected_version integer,_input_hash text,_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; receipt app_private.command_receipts; impact jsonb; hashed text; result jsonb;
begin
 select event_id into eid from app_private.portals where id=_portal_id;
 if eid is null or auth.uid() is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=eid for no key update;
 if length(coalesce(_key,'')) not between 16 and 200 or _state not in ('open','paused','closed') then raise exception 'INVALID_INPUT'; end if;
 hashed:=md5(jsonb_build_array(_portal_id,_state,_expected_version,_input_hash)::text);
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.operation.reviewed' and idempotency_key=_key;
 if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if;return receipt.safe_result;end if;
 impact:=api.admin_portal_change_impact(_portal_id);
 if impact->>'inputHash' is distinct from _input_hash then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 result:=api.portal_set_operational_state(_portal_id,_state::app_private.portal_operation_status,_expected_version,'Operationele poortstatus na actuele impactcontrole door organisatie');
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.operation.reviewed',_key,hashed,result,now()+interval '7 days');
 return result;
end $$;
revoke all on function api.admin_portal_operation_reviewed(uuid,text,integer,text,text) from public,anon;
grant execute on function api.admin_portal_operation_reviewed(uuid,text,integer,text,text) to authenticated;

-- Poortkamer sees only accepted route expectations and authorized group counts.
-- Draft replacement starts do not replace the previously published reception.
alter function api.portal_arrivals_snapshot(uuid) rename to portal_arrivals_snapshot_before_live_routes;
revoke all on function api.portal_arrivals_snapshot_before_live_routes(uuid) from public,anon,authenticated;
create function api.portal_arrivals_snapshot(_portal_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; arrivals jsonb; expectations jsonb;
begin
 result:=api.portal_arrivals_snapshot_before_live_routes(_portal_id);
 -- An immutable legacy proposal is history once the group uses dynamic dispatch.
 -- Held/current reservations and the immutable published start remain authoritative.
 result:=jsonb_set(result,'{arrivals}',coalesce((select jsonb_agg(a) from jsonb_array_elements(result->'arrivals') a
  where not (a->>'classification'='assigned' and a->>'state'='planned'
   and exists(select 1 from app_private.walking_groups g where g.id=(a->>'groupId')::uuid and g.route_mode='dynamic')
   and not exists(select 1 from app_private.portal_reservations r where r.group_id=(a->>'groupId')::uuid and r.portal_id=_portal_id and r.status in ('held','active','completed')))), '[]'));

 select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'displayName',g.display_name,'groupCode',g.system_code,'systemCode',g.system_code,
  'plannedArrivalAt',v.starts_at,'plannedDepartureAt',v.starts_at+make_interval(secs=>v.duration_seconds+v.buffer_seconds),
  'expectedChildren',(select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null),
  'state','planned','classification','forecast','source','route_intent') order by v.starts_at),'[]') into expectations
 from app_private.live_route_visits v join app_private.live_route_plans plan on plan.group_id=v.group_id join app_private.walking_groups g on g.id=v.group_id and g.retired_at is null
 where v.portal_id=_portal_id and v.retired_at is null and v.run_stop_id is null and v.kind<>'start' and not exists(select 1 from app_private.group_runs ended where ended.group_id=g.id and ended.status in ('stopped','completed'))
 and exists(select 1 from app_private.live_route_visits manual where manual.group_id=g.id and manual.retired_at is null and manual.source='manual')
 and (exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.status in ('live','paused')) or exists(select 1 from app_private.current_start_publication(g.id) pub where pub.schedule_id=plan.schedule_id))
 and not exists(select 1 from jsonb_array_elements(result->'arrivals') a where a->>'groupId'=g.id::text and a->>'classification'='assigned');
 select coalesce(jsonb_agg(a order by a->>'plannedArrivalAt'),'[]') into arrivals from (
  select a from jsonb_array_elements(result->'arrivals') a where a->>'classification'<>'forecast' or not exists(select 1 from jsonb_array_elements(expectations) x where x->>'groupId'=a->>'groupId')
  union all select a from jsonb_array_elements(expectations) a
 ) current_arrivals;
 return result||jsonb_build_object('arrivals',arrivals,'forecastAvailable',coalesce((result->>'forecastAvailable')::boolean,false) or jsonb_array_length(expectations)>0,
 'assignedGroups',(select count(*) from jsonb_array_elements(arrivals) a where a->>'classification'='assigned' and a->>'state'<>'completed'),
 'assignedChildren',coalesce((select sum((a->>'expectedChildren')::integer) from jsonb_array_elements(arrivals) a where a->>'classification'='assigned' and a->>'state'<>'completed'),0),
 'completedGroups',(select count(*) from jsonb_array_elements(arrivals) a where a->>'state'='completed'),
 'forecastGroups',(select count(*) from jsonb_array_elements(arrivals) a where a->>'classification'='forecast' and a->>'state'<>'completed'),
 'forecastChildren',coalesce((select sum((a->>'expectedChildren')::integer) from jsonb_array_elements(arrivals) a where a->>'classification'='forecast' and a->>'state'<>'completed'),0),
 'nextArrivalAt',(select min(a->>'plannedArrivalAt') from jsonb_array_elements(arrivals) a where a->>'state'<>'completed'),
 'remainingGroups',(select count(*) from jsonb_array_elements(arrivals) a where a->>'state'<>'completed'),
 'expectedTotal',coalesce((select sum((a->>'expectedChildren')::integer) from jsonb_array_elements(arrivals) a where a->>'state'<>'completed'),0));
end $$;
revoke all on function api.portal_arrivals_snapshot(uuid) from public,anon;
grant execute on function api.portal_arrivals_snapshot(uuid) to authenticated;

-- Archive preserves historical team identities while ending their active rights.
alter function api.admin_manual_portal_remove(uuid,integer,text) rename to admin_manual_portal_remove_before_access_cleanup;
revoke all on function api.admin_manual_portal_remove_before_access_cleanup(uuid,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_remove(_portal_id uuid,_expected_version integer,_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.admin_manual_portal_remove_before_access_cleanup(_portal_id,_expected_version,_reason);
 if not coalesce((result->>'deleted')::boolean,false) then
  update app_private.portal_owners set revoked_at=clock_timestamp() where portal_id=_portal_id and revoked_at is null;
  update app_private.portal_team_invites set revoked_at=clock_timestamp() where portal_id=_portal_id and accepted_at is null and revoked_at is null;
 end if;
 return result;
end $$;
revoke all on function api.admin_manual_portal_remove(uuid,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_remove(uuid,integer,text) to authenticated;
